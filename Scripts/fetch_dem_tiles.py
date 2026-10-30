#!/usr/bin/env python3
"""Coverage-spike helper: fetch USGS 3DEP elevation for a bbox as 0.05-degree tiles (one request at a time),
stitch them, and write the gzipped uncompressed float32 tiled GeoTIFF that import_osm.py's load_dem expects.
usage: fetch_dem_tiles.py S W N E out.tif.gz tiledir   (bounds are multiples of 0.05)"""
import array, gzip, pathlib, struct, subprocess, sys, time
S, W, N, E = map(float, sys.argv[1:5]); out = pathlib.Path(sys.argv[5]); tiles = pathlib.Path(sys.argv[6]); tiles.mkdir(parents=True, exist_ok=True)
URL = 'https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage'
UA = 'peoplemaps-coverage-spike/0.1 (https://github.com/electropicks/peoplemaps)'
PX = 750; STEP = 0.05  # 750 px per 0.05 deg = the shipped 6.667e-5 deg (~5 m) cell
cols = round((E - W) / STEP); rows = round((N - S) / STEP); w, h = cols * PX, rows * PX
grid = array.array('f', bytes(4 * w * h))

def read_tiff(b):
    off = struct.unpack('<I', b[4:8])[0]; count = struct.unpack('<H', b[off:off+2])[0]; tags = {}
    for i in range(count):
        tag, typ, cnt, val = struct.unpack('<HHII', b[off+2+12*i:off+14+12*i])
        size = {3: 2, 4: 4, 12: 8}.get(typ, 1)
        tags[tag] = [val] if cnt * size <= 4 else list(struct.unpack('<' + {3: 'H', 4: 'I', 12: 'd'}.get(typ, 'B') * cnt, b[val:val+cnt*size]))
    tw, th, tw_w, tw_h = tags[256][0], tags[257][0], tags[322][0], tags[323][0]
    assert tags[259][0] == 1 and tags[258][0] == 32 and tags[339][0] == 3, 'expected uncompressed float32'
    g = array.array('f', bytes(4 * tw * th)); across = (tw + tw_w - 1) // tw_w
    for k, (o, c) in enumerate(zip(tags[324], tags[325])):
        t = array.array('f', b[o:o+c]); ty, tx = divmod(k, across)
        for r in range(tw_h):
            y = ty * tw_h + r
            if y >= th: break
            x0 = tx * tw_w; n = min(tw_w, tw - x0); g[y*tw+x0:y*tw+x0+n] = t[r*tw_w:r*tw_w+n]
    return tw, th, g

for r in range(rows):
    for c in range(cols):
        s = N - (r + 1) * STEP; west = W + c * STEP; f = tiles / f'{r}_{c}.tif'
        if not f.exists() or f.stat().st_size < 1_000_000:
            for attempt in range(4):
                q = f'{URL}?bbox={west:.2f},{s:.2f},{west+STEP:.2f},{s+STEP:.2f}&bboxSR=4326&imageSR=4326&size={PX},{PX}&format=tiff&pixelType=F32&interpolation=RSP_BilinearInterpolation&f=image'
                subprocess.run(['curl', '-s', '-A', UA, '--max-time', '120', q, '-o', str(f)], check=False); time.sleep(2)
                if f.exists() and f.read_bytes()[:2] == b'II': break
                time.sleep(10 * (attempt + 1))
            else: sys.exit(f'tile {r},{c} failed')
        tw, th, g = read_tiff(f.read_bytes()); assert (tw, th) == (PX, PX), (tw, th)
        for y in range(PX): grid[(r*PX+y)*w + c*PX : (r*PX+y)*w + c*PX + PX] = g[y*PX:(y+1)*PX]
        print('tile', r, c, flush=True)

T = 128; ac = (w + T - 1) // T; dn = (h + T - 1) // T; data = bytearray(); offs = []; cnts = []
for ty in range(dn):
    for tx in range(ac):
        offs.append(None); t = array.array('f', bytes(4 * T * T))
        for rr in range(T):
            y = ty * T + rr
            if y >= h: break
            x0 = tx * T; n = min(T, w - x0); t[rr*T:rr*T+n] = grid[y*w+x0:y*w+x0+n]
        data += t.tobytes()
n_tiles = ac * dn
# layout: header(8) | IFD | extra arrays | tile data
entries = [(256,3,1,w),(257,3,1,h),(258,3,1,32),(259,3,1,1),(262,3,1,1),(277,3,1,1),(284,3,1,1),(322,3,1,T),(323,3,1,T),(324,4,n_tiles,None),(325,4,n_tiles,None),(339,3,1,3),(33550,12,3,None),(33922,12,6,None)]
ifd_size = 2 + 12 * len(entries) + 4; extra = ifd_size + 8
tile_off_at = extra; tile_cnt_at = tile_off_at + 4 * n_tiles; scale_at = tile_cnt_at + 4 * n_tiles; tie_at = scale_at + 24; data_at = tie_at + 48
tile_offsets = [data_at + i * 4 * T * T for i in range(n_tiles)]
ifd = struct.pack('<H', len(entries))
for tag, typ, cnt, val in entries:
    if tag == 324: val = tile_off_at
    if tag == 325: val = tile_cnt_at
    if tag == 33550: val = scale_at
    if tag == 33922: val = tie_at
    ifd += struct.pack('<HHII', tag, typ, cnt, val)
ifd += struct.pack('<I', 0)
blob = b'II*\x00' + struct.pack('<I', 8) + ifd + struct.pack(f'<{n_tiles}I', *tile_offsets) + struct.pack(f'<{n_tiles}I', *([4*T*T]*n_tiles)) \
    + struct.pack('<3d', STEP/PX, STEP/PX, 0) + struct.pack('<6d', 0, 0, 0, W, N, 0) + bytes(data)
out.write_bytes(gzip.compress(blob, compresslevel=9, mtime=0)); print('wrote', out, len(blob), out.stat().st_size)

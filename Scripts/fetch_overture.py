#!/usr/bin/env python3
"""Fetches the Overture Maps Places inside the all-Seattle box into Data/seattle-overture-places.json.gz.

Not run by the importer: Overture keeps only its last two releases online (about 60 days), so the bounded
extract is archived in Data/ and import_osm.py / build_search.py read the archive. Run it only to take a newer release.

    python3 -m venv /tmp/overture-venv && /tmp/overture-venv/bin/pip install pyarrow
    /tmp/overture-venv/bin/python Scripts/fetch_overture.py [--release 2026-10-21.0] [--fetched YYYY-MM-DD]

Reads the public, anonymous S3 bucket with pyarrow only. Parquet row groups carry bbox statistics and the
files are spatially sorted, so only the row groups that can overlap the box are downloaded, and only the
columns kept below (no phones, emails, websites, socials or brands are ever read). Output is sorted by id and
gzipped with mtime=0, so the same release always gives the same bytes."""
import argparse, datetime, gzip, io, json, pathlib, struct, sys
import pyarrow as pa, pyarrow.fs as fs, pyarrow.parquet as pq

RELEASE = '2026-10-21.0'
BUCKET = 'overturemaps-us-west-2/release/{release}/theme=places/type=place/'
BOX = {'south': 47.49, 'north': 47.74, 'west': -122.44, 'east': -122.24}  # all of Seattle
READ = ['id', 'geometry', 'names', 'taxonomy', 'basic_category', 'confidence', 'operating_status', 'addresses', 'sources', 'bbox']
MAX_BYTES = 2_000_000_000  # a full download would be ~12 GB: stop instead
OUT = pathlib.Path(__file__).resolve().parents[1] / 'Data/seattle-overture-places.json.gz'


class Counting(io.RawIOBase):
    """Counts the bytes actually pulled from S3."""
    total = 0
    def __init__(self, f): self.f = f
    def readable(self): return True
    def seekable(self): return True
    def seek(self, offset, whence=0): return self.f.seek(offset, whence)
    def tell(self): return self.f.tell()
    def read(self, n=-1):
        data = self.f.read(n); Counting.total += len(data); return data
    def readinto(self, b):
        data = self.f.read(len(b)); b[:len(data)] = data; Counting.total += len(data); return len(data)
    def close(self): self.f.close(); super().close()


def overlaps(row_group, columns):
    """True unless the row group's bbox statistics put every row outside the box."""
    s = {}
    for c in range(row_group.num_columns):
        col = row_group.column(c)
        if col.path_in_schema.startswith('bbox.'):
            if col.statistics is None or not col.statistics.has_min_max:
                return True
            s[col.path_in_schema[5:]] = col.statistics
    return (s['xmax'].max >= BOX['west'] and s['xmin'].min <= BOX['east']
            and s['ymax'].max >= BOX['south'] and s['ymin'].min <= BOX['north'])


def point(wkb):
    order = '<' if wkb[0] == 1 else '>'
    kind = struct.unpack(order + 'I', wkb[1:5])[0]
    if kind != 1:
        return None
    return struct.unpack(order + 'dd', wkb[5:21])


def record(row):
    lon, lat = point(row['geometry'])
    address = (row['addresses'] or [{}])[0] or {}
    taxonomy = row['taxonomy'] or {}
    return {
        'id': row['id'],
        'name': (row['names'] or {}).get('primary'),
        'lon': round(lon, 7), 'lat': round(lat, 7),
        'taxonomy': {'primary': taxonomy.get('primary'), 'hierarchy': taxonomy.get('hierarchy') or []},
        'basic_category': row['basic_category'],
        'confidence': None if row['confidence'] is None else round(row['confidence'], 4),
        'operating_status': row['operating_status'],
        'address': {'freeform': address.get('freeform'), 'postcode': address.get('postcode')},
        'sources': [{k: s.get(k) for k in ('dataset', 'record_id', 'license', 'update_time')} for s in row['sources'] or []],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--release', default=RELEASE)
    ap.add_argument('--fetched', default=datetime.date.today().isoformat(), help='fetch date recorded in the archive header')
    ap.add_argument('--parts', type=int, help='only the first N part files (for testing)')
    ap.add_argument('--out', type=pathlib.Path, default=OUT)
    args = ap.parse_args()

    s3 = fs.S3FileSystem(anonymous=True, region='us-west-2')
    base = BUCKET.format(release=args.release)
    files = [i for i in s3.get_file_info(fs.FileSelector(base)) if i.path.endswith('.parquet')]
    if not files:
        sys.exit(f'no parts under s3://{base}')
    files.sort(key=lambda i: i.path)
    files = files[:args.parts]
    records, total_groups, read_groups = {}, 0, 0
    for info in files:
        f = pq.ParquetFile(Counting(s3.open_input_file(info.path)))
        md = f.metadata
        wanted = [g for g in range(md.num_row_groups) if overlaps(md.row_group(g), READ)]
        total_groups += md.num_row_groups; read_groups += len(wanted)
        before = Counting.total
        for g in wanted:
            if Counting.total > MAX_BYTES:
                sys.exit(f'stopping: {Counting.total / 1e9:.1f} GB downloaded, the bbox filter is not pruning enough')
            table = f.read_row_group(g, columns=READ)
            for row in table.to_pylist():
                b = row['bbox']
                if not (BOX['west'] <= b['xmin'] and b['xmax'] <= BOX['east'] and BOX['south'] <= b['ymin'] and b['ymax'] <= BOX['north']):
                    continue
                if row['geometry'] is None or point(row['geometry']) is None:
                    continue
                records[row['id']] = record(row)
        print(f'{info.path.rsplit("/", 1)[1][:12]}: {len(wanted)}/{md.num_row_groups} row groups, '
              f'{(Counting.total - before) / 1e6:.1f} MB read of {info.size / 1e6:.0f} MB, {len(records)} records so far', flush=True)
    print(f'row groups read {read_groups}/{total_groups}; {Counting.total / 1e6:.1f} MB downloaded in total', flush=True)

    header = {'release': args.release, 'fetched': args.fetched, 'bbox': BOX,
              'source': f's3://{base}', 'filter': 'bbox.xmin >= west, bbox.xmax <= east, bbox.ymin >= south, bbox.ymax <= north',
              'count': len(records)}
    body = ',\n'.join(json.dumps(records[k], ensure_ascii=False, sort_keys=True, separators=(',', ':')) for k in sorted(records))
    text = json.dumps(header, sort_keys=True, separators=(',', ':'))[:-1] + ',"places":[\n' + body + '\n]}\n'
    args.out.write_bytes(gzip.compress(text.encode(), compresslevel=9, mtime=0))
    print(f'{len(records)} places, {args.out.stat().st_size / 1e6:.2f} MB gzipped -> {args.out}')


if __name__ == '__main__':
    main()

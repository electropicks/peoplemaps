#!/usr/bin/env python3
"""Deterministic, deliberately conservative OSM + elevation to routing-graph compiler. No network."""
import array, collections, gzip, hashlib, json, math, pathlib, struct
import build_search

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'Core/Resources'
BBOX = [47.615, -122.390, 47.678, -122.300]  # S,W,N,E
MODES = ['drive', 'bike', 'walk']
ROAD = {'motorway','motorway_link','trunk','trunk_link','primary','primary_link',
        'secondary','secondary_link','tertiary','tertiary_link','residential',
        'unclassified','living_street','service'}
HIGHWAY = {'motorway','motorway_link','trunk','trunk_link'}
FOOT_ONLY = {'footway','path','pedestrian','steps','track'}
YES = {'yes','designated','permissive','official'}
DENY = {'no','private','customers','delivery','destination','agricultural','forestry','permit','use_sidepath'}
STRUCTURE = {'yes','viaduct','movable','cantilever','trestle'}
NOT_A_SIGNAL = {'emergency','blinker','ramp_meter','level_crossing'}

def inside(n):
    return BBOX[0] <= n['lat'] <= BBOX[2] and BBOX[1] <= n['lon'] <= BBOX[3]

def access(tags, mode):
    keys = {'drive': ['motorcar','motor_vehicle','vehicle','access'],
            'bike': ['bicycle','vehicle','access'], 'walk': ['foot','access']}[mode]
    if any(k + ':conditional' in tags for k in keys) or (mode != 'walk' and 'oneway:conditional' in tags):
        return False  # no temporal evaluator in this POC
    value = next((tags[k] for k in keys if k in tags), None)
    if value is not None and value not in YES:
        return False
    h = tags.get('highway','')
    if mode == 'drive':
        return h in ROAD and tags.get('service') not in {'driveway','parking_aisle','emergency_access'}
    if h in HIGHWAY:
        return False
    if mode == 'bike':
        return h in (ROAD | {'cycleway'}) or (h in {'path','footway','pedestrian'} and tags.get('bicycle') in YES)
    if h == 'cycleway':  # cycleways are walkable only where feet are explicitly allowed or separated
        return tags.get('foot') in YES or tags.get('segregated') == 'yes'
    if h in ROAD and sidewalk(tags) == 'separate' and tags.get('foot') not in YES:
        return False  # walk on the mapped sidewalks and crossings, not the road's centreline
    return h in (ROAD | FOOT_ONLY)

def directions(tags, mode):
    if mode == 'walk':
        return [1,-1]
    one = tags.get('oneway', 'yes' if tags.get('junction') == 'roundabout' or tags.get('highway') == 'motorway' else 'no')
    if mode == 'bike':
        one = tags.get('oneway:bicycle',one)
        if any(tags.get(k,'').startswith('opposite') for k in ['cycleway','cycleway:left','cycleway:right']):
            one = 'no'
    if one in {'yes','1','true'}: return [1]
    if one == '-1': return [-1]
    if one in {'no','0','false'}: return [1,-1]
    return []  # reversible/alternating/unknown not modeled

def distance(a,b):
    x = math.radians(b['lon']-a['lon']) * math.cos(math.radians((a['lat']+b['lat'])/2))
    y = math.radians(b['lat']-a['lat'])
    return math.hypot(x,y)*6371000

def facility(t, direction):
    if t.get('highway') == 'cycleway': return 'cycleway'
    if t.get('highway') in {'path','footway','pedestrian'}: return 'sharedPath'
    # US right-hand traffic. Only claim a track/lane for its direction.
    keys = ['cycleway:both','cycleway', 'cycleway:right' if direction == 1 else 'cycleway:left']
    values = [t.get(k) for k in keys]
    if 'track' in values: return 'track'
    if 'lane' in values: return 'lane'
    return 'none'

def sidewalk(t):
    """Sidewalk status of a road: separate (mapped as its own footway), yes, no, or None when unknown."""
    sides = [t.get('sidewalk:left'), t.get('sidewalk:right')]
    if 'separate' in (t.get('sidewalk'), t.get('sidewalk:both'), *sides): return 'separate'
    if t.get('sidewalk') in {'both','left','right','yes'} or t.get('sidewalk:both') == 'yes' or 'yes' in sides: return 'yes'
    if t.get('sidewalk') in {'no','none'} or t.get('sidewalk:both') == 'no' or sides == ['no','no']: return 'no'
    return None

PARKED = {'lane','yes','parallel','diagonal','perpendicular','street_side','on_street','half_on_kerb'}
def parked_both_sides(t):
    if t.get('parking:both') in PARKED or t.get('parking:lane:both') in PARKED: return True
    if t.get('parking:left') in PARKED and t.get('parking:right') in PARKED: return True
    if t.get('parking:both') == 'no' or t.get('parking:lane:both') in {'no','no_parking','no_stopping'}: return False
    return None

def lanes(t):
    try: return int(t.get('lanes','').split(';')[0])
    except ValueError: return None

def left_turn_lane(t, direction):
    """Whether this approach has a lane marked for left turns; None when turn lanes aren't mapped."""
    v = t.get('turn:lanes:forward' if direction == 1 else 'turn:lanes:backward') or t.get('turn:lanes')
    if v is None: return None
    return any('left' in lane.split(';') for lane in v.split('|'))

def road_class(t):
    """busy, arterial or local for a drivable road; None for service roads and paths."""
    h = t.get('highway','')
    if h not in ROAD or h in {'service','living_street'}: return None
    if h in {'residential','unclassified'}: return 'local'
    return 'busy' if (lanes(t) or 2) >= 4 or speed_mph(t.get('maxspeed')) >= 35 else 'arterial'

RANK = {None: 0, 'local': 1, 'arterial': 2, 'busy': 3}

def beside_roads(sidewalk_segments, road_segments, reach=25):
    """For each sidewalk polyline, the class of the nearest road within `reach` metres of its midpoint."""
    cell = 0.0005; grid = collections.defaultdict(list)
    for cls, pts in road_segments:
        for a, b in zip(pts, pts[1:]):
            for gx in range(int(min(a['lon'],b['lon'])/cell)-1, int(max(a['lon'],b['lon'])/cell)+2):
                for gy in range(int(min(a['lat'],b['lat'])/cell)-1, int(max(a['lat'],b['lat'])/cell)+2):
                    grid[(gx,gy)].append((cls,a,b))
    def gap(p, a, b):
        k = math.cos(math.radians(p['lat'])) * 111320; m = 110540
        ax, ay, bx, by = (a['lon']-p['lon'])*k, (a['lat']-p['lat'])*m, (b['lon']-p['lon'])*k, (b['lat']-p['lat'])*m
        dx, dy = bx-ax, by-ay; t = max(0, min(1, -(ax*dx+ay*dy)/((dx*dx+dy*dy) or 1)))
        return math.hypot(ax+t*dx, ay+t*dy)
    result = []
    for pts in sidewalk_segments:
        half = sum(distance(a,b) for a,b in zip(pts,pts[1:]))/2; run = 0; mid = pts[0]
        for a, b in zip(pts, pts[1:]):
            d = distance(a,b)
            if run + d >= half:
                f = (half-run)/(d or 1); mid = {'lat': a['lat']+(b['lat']-a['lat'])*f, 'lon': a['lon']+(b['lon']-a['lon'])*f}; break
            run += d
        best = min(((gap(mid,a,b), cls) for cls,a,b in grid.get((int(mid['lon']/cell), int(mid['lat']/cell)), [])), default=(math.inf, None), key=lambda x: x[0])
        result.append(best[1] if best[0] <= reach else None)
    return result

def crossing_control(tags):
    """signal, marked or unmarked for a crossing way or node; None when the tags don't say."""
    c, signals, markings = tags.get('crossing'), tags.get('crossing:signals'), tags.get('crossing:markings')
    if c == 'traffic_signals' or signals == 'yes': return 'signal'
    if c in {'marked','zebra','uncontrolled'} or (markings and markings != 'no'): return 'marked'
    if c == 'unmarked' or markings == 'no': return 'unmarked'
    return None

def load_dem(path):
    """Bilinear sampler over the bundled USGS 3DEP GeoTIFF (tiled, uncompressed float32, WGS84)."""
    b = gzip.decompress(path.read_bytes())
    off = struct.unpack('<I', b[4:8])[0]; count = struct.unpack('<H', b[off:off+2])[0]; tags = {}
    for i in range(count):
        tag, typ, cnt, val = struct.unpack('<HHII', b[off+2+12*i:off+14+12*i])
        size = {3:2, 4:4, 12:8}.get(typ, 1)
        if cnt*size <= 4: tags[tag] = [val & 0xffff if typ == 3 else val]
        else: tags[tag] = list(struct.unpack('<' + {3:'H',4:'I',12:'d'}.get(typ,'B')*cnt, b[val:val+cnt*size]))
    if tags[259][0] != 1 or tags[258][0] != 32 or tags.get(339, [1])[0] != 3: raise ValueError('expected uncompressed float32 DEM')
    w, h, tw, th = tags[256][0], tags[257][0], tags[322][0], tags[323][0]
    grid = array.array('f', bytes(4*w*h)); across = (w+tw-1)//tw
    for k, (o, c) in enumerate(zip(tags[324], tags[325])):
        tile = array.array('f', b[o:o+c]); ty, tx = divmod(k, across)
        for r in range(th):
            y = ty*th + r
            if y >= h: break
            x0 = tx*tw; n = min(tw, w-x0)
            grid[y*w+x0:y*w+x0+n] = tile[r*tw:r*tw+n]
    sx, sy = tags[33550][:2]; lon0, lat0 = tags[33922][3:5]
    def z(lat, lon):
        fx = (lon-lon0)/sx - 0.5; fy = (lat0-lat)/sy - 0.5
        x = min(max(int(fx), 0), w-2); y = min(max(int(fy), 0), h-2); ax = fx-x; ay = fy-y
        g = lambda i, j: grid[j*w+i]
        return (g(x,y)*(1-ax) + g(x+1,y)*ax)*(1-ay) + (g(x,y+1)*(1-ax) + g(x+1,y+1)*ax)*ay
    return z, hashlib.sha256(b).hexdigest()

def structure_elevations(ways, allnodes, z):
    """Bridges and tunnels: the DEM is the ground or water below, so interpolate along the structure
    between its ends on the ground. Returns {osm node id: metres} for nodes that are only on structures."""
    structural = [w for w in ways if w['tags'].get('bridge') in STRUCTURE or w['tags'].get('tunnel') == 'yes']
    on_ground = {n for w in ways if w not in structural for n in w['nodes']}
    known = {n: z(allnodes[n]['lat'], allnodes[n]['lon']) for w in structural for n in (w['nodes'][0], w['nodes'][-1]) if n in on_ground and n in allnodes}
    result = {}
    for _ in range(8):  # chains of structure ways resolve from their grounded ends inward
        progress = False
        for w in structural:
            ns = [n for n in w['nodes'] if n in allnodes]
            ends = [n for n in (ns[0], ns[-1]) if n in known or n in result]
            if not ends: continue
            za = known.get(ns[0], result.get(ns[0])); zb = known.get(ns[-1], result.get(ns[-1]))
            za = zb if za is None else za; zb = za if zb is None else zb
            total = sum(distance(allnodes[a], allnodes[b]) for a, b in zip(ns, ns[1:])) or 1; run = 0
            for i, n in enumerate(ns):
                if i: run += distance(allnodes[ns[i-1]], allnodes[n])
                if n in on_ground or n in result: continue
                result[n] = za + (zb-za)*run/total; progress = True
        if not progress: break
    return result

def profile(points, elevation_at, step=10):
    """Elevations sampled every `step` metres along a polyline, lightly smoothed, with cumulative distance."""
    samples = [(0.0, elevation_at(points[0]))]; run = 0.0
    for a, b in zip(points, points[1:]):
        d = distance(a, b); k = max(1, int(d // step))
        for i in range(1, k+1):
            f = i/k; p = {'lat': a['lat']+(b['lat']-a['lat'])*f, 'lon': a['lon']+(b['lon']-a['lon'])*f}
            samples.append((run + d*f, elevation_at(p)))
        run += d
    zs = [s[1] for s in samples]
    smooth = [zs[0]] + [(zs[i-1]+zs[i]+zs[i+1])/3 for i in range(1, len(zs)-1)] + [zs[-1]] if len(zs) > 2 else zs
    return [(s[0], v) for s, v in zip(samples, smooth)]

# Seattle's steepest streets are about 25%. A steeper DEM reading on a road is the retaining wall,
# freeway cut or overpass beside it, not the road, so it is clipped (climb) or left unknown (grade).
MAX_ROAD_GRADE = 0.30

def climb(prof, max_grade=MAX_ROAD_GRADE):
    return sum(min(max(0.0, b[1]-a[1]), max_grade*(b[0]-a[0])) for a, b in zip(prof, prof[1:]))

def approach_grade(prof, span=30):
    """Percent grade over the last `span` metres arriving at the end of the profile; uphill is positive.
    None when the reading is implausible for a road."""
    end_d, end_z = prof[-1]
    start = next((p for p in reversed(prof) if end_d - p[0] >= span), prof[0])
    d = end_d - start[0]
    grade = 0.0 if d < 5 else (end_z - start[1]) / d * 100
    return None if abs(grade) > MAX_ROAD_GRADE*100 else round(grade, 1)

def clip_ring(coords):
    # Sutherland-Hodgman against the extract rectangle, preserving OSM geometry.
    pts = coords[:-1] if coords and coords[0] == coords[-1] else coords[:]
    for axis, limit, greater in [(0,BBOX[1],True),(0,BBOX[3],False),(1,BBOX[0],True),(1,BBOX[2],False)]:
        prevpts, pts = pts, []
        if not prevpts: break
        a = prevpts[-1]
        for b in prevpts:
            ia = a[axis] >= limit if greater else a[axis] <= limit
            ib = b[axis] >= limit if greater else b[axis] <= limit
            if ia != ib:
                f = (limit-a[axis])/(b[axis]-a[axis])
                pts.append([round(a[j]+f*(b[j]-a[j]),7) for j in [0,1]])
            if ib: pts.append(b)
            a = b
    return pts+[pts[0]] if len(pts)>2 else []

def stitch(parts):
    rings=[]
    while parts:
        ring=parts.pop()
        while ring[0]!=ring[-1]:
            found=False
            for i,p in enumerate(parts):
                if p[0]==ring[-1]: ring+=p[1:]
                elif p[-1]==ring[-1]: ring+=list(reversed(p[:-1]))
                else: continue
                parts.pop(i);found=True;break
            if not found: break
        if ring[0]==ring[-1]: rings.append(ring)
    return rings

def point_in_ring(p, ring):
    hit=False
    for a,b in zip(ring,ring[1:]):
        if (a[1]>p[1]) != (b[1]>p[1]) and p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]: hit=not hit
    return hit

def node_blocks(nt, mode):
    """Whether a tagged OSM node (barrier, access) blocks a mode under this compiler's policy."""
    own = {'drive': ['motorcar','motor_vehicle'], 'bike': ['bicycle'], 'walk': ['foot']}[mode]
    if any(nt.get(k) in DENY for k in own): return True
    allowed = any(nt.get(k) in YES for k in own)
    if nt.get('access') in DENY and not allowed: return True
    barrier = nt.get('barrier')
    if not barrier or barrier in {'no','entrance','cattle_grid'} or allowed: return False
    if mode == 'drive': return True
    if mode == 'bike': return barrier not in {'bollard','cycle_barrier','kerb'}
    return barrier in {'wall','fence','hedge','retaining_wall'}

def control(nt, way_direction):
    """Traffic control a directed approach meets at this node: signal, stop, allstop, yield or None.
    `way_direction` is +1/-1 relative to the OSM way, matched against the node's direction tag."""
    kind = nt.get('highway')
    if kind == 'traffic_signals' and nt.get('traffic_signals') in NOT_A_SIGNAL: return None
    if kind not in {'traffic_signals','stop','give_way'}: return None
    d = nt.get('direction') or nt.get('traffic_signals:direction')
    if d in {'forward','backward'} and (d == 'forward') != (way_direction == 1): return None
    if kind == 'traffic_signals': return 'signal'
    if kind == 'give_way': return 'yield'
    return 'allstop' if nt.get('stop') == 'all' else 'stop'

def read_snapshot(basename):
    raw = ROOT/'Data/raw'/f'{basename}.json'
    archive = ROOT/'Data'/f'{basename}.json.gz'
    data = raw.read_bytes() if raw.exists() else gzip.decompress(archive.read_bytes())
    p = json.loads(data)
    if p.get('remark'): raise ValueError(p['remark'])
    if raw.exists(): archive.write_bytes(gzip.compress(data,mtime=0))  # archive a fresh download
    return p, {'file':str(archive.relative_to(ROOT)),'sha256':hashlib.sha256(data).hexdigest(),
               'osmBaseTimestamp':p['osm3s']['timestamp_osm_base']}

def read_sources():
    elements = {}; sources = []
    for basename in ['seattle-osm','seattle-parks']:
        p, source = read_snapshot(basename); sources.append(source)
        for e in p['elements']: elements[(e['type'],e['id'])] = e
    return elements, sources

def compile_restrictions(relations):
    restrictions=[]; excluded=collections.defaultdict(set); unsupported=[]
    for r in relations:
        t=r.get('tags',{})
        if t.get('type')!='restriction':continue
        m=r['members']; via=[x for x in m if x['role']=='via']; fr=[x['ref'] for x in m if x['role']=='from']; to=[x['ref'] for x in m if x['role']=='to']
        for mode,keys,exception in [('drive',['restriction:motorcar','restriction:motor_vehicle','restriction'],'motorcar'),('bike',['restriction:bicycle','restriction'],'bicycle')]:
            if exception in t.get('except','').split(';') or (mode=='drive' and 'motor_vehicle' in t.get('except','').split(';')): continue
            val=next((t[k] for k in keys if k in t),None)
            conditional=any(k+':conditional' in t for k in keys)
            if not val and not conditional:continue
            supported = len(via)==1 and via[0]['type']=='node' and len(fr)==1 and len(to)==1 and not conditional and val and (val.startswith('no_') or val.startswith('only_'))
            if supported:
                restrictions.append({'viaOSM':via[0]['ref'],'fromWay':fr[0],'toWay':to[0],'kind':val,'mode':mode,'osmID':r['id']})
            else:
                excluded[mode].update(fr+to+[x['ref'] for x in via if x['type']=='way'])
                unsupported.append({'osmID':r['id'],'mode':mode})
    return restrictions, excluded, unsupported

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    elements, sources = read_sources()
    dem_path = ROOT/'Data/seattle-dem.tif.gz'
    z, dem_sha = load_dem(dem_path)
    sources.append({'file':str(dem_path.relative_to(ROOT)),'sha256':dem_sha,
                    'source':'USGS 3DEP 3DEPElevation ImageServer exportImage, ~5 m bilinear, public domain'})
    allnodes={i:e for (typ,i),e in elements.items() if typ=='node'}
    allways={i:e for (typ,i),e in elements.items() if typ=='way'}
    relations=[e for (typ,i),e in elements.items() if typ=='relation']
    restrictions, excluded, unsupported = compile_restrictions(relations)

    ways=[]
    for w in allways.values():
        t=w.get('tags',{})
        if not t.get('highway') or t.get('area')=='yes':continue
        if not any(inside(allnodes[n]) for n in w['nodes'] if n in allnodes):continue
        if any(access(t,mode) for mode in MODES): ways.append(w)
    ways.sort(key=lambda w:w['id'])
    counts=collections.Counter(n for w in ways for n in set(w['nodes']))
    junctions={n for n,c in counts.items() if c>1}
    junctions.update(n for n,e in allnodes.items() if e.get('tags',{}).get('highway') in {'traffic_signals','stop','give_way','crossing'} or 'barrier' in e.get('tags',{}))
    junctions.update(r['viaOSM'] for r in restrictions)
    lifted=structure_elevations(ways, allnodes, z)
    def elevation(n): return lifted.get(n) if n in lifted else z(allnodes[n]['lat'], allnodes[n]['lon'])

    # The busiest road through each node, for crossings that a footway makes of it.
    crossed_class={}
    for w in ways:
        cls=road_class(w['tags'])
        for n in w['nodes']:
            if RANK[cls]>RANK[crossed_class.get(n)]: crossed_class[n]=cls

    nodes=[]; nodeindex={}; segments=[]; names={}; geometry=[]
    def index(n):
        if n not in nodeindex:
            nodeindex[n]=len(nodes); v=allnodes[n]
            nodes.append({'osm':n,'lat':v['lat'],'lon':v['lon'],'z':round(elevation(n),1)})
        return nodeindex[n]
    def name_index(s):
        return names.setdefault(s, len(names))
    for w in ways:
        t=w['tags']; ns=w['nodes']; start=0
        structural=t.get('bridge') in STRUCTURE or t.get('tunnel')=='yes'
        for end in range(1,len(ns)):
            if end!=len(ns)-1 and ns[end] not in junctions: continue
            segment=ns[start:end+1];start=end
            if any(n not in allnodes or not inside(allnodes[n]) for n in segment):continue
            pts=[allnodes[n] for n in segment]
            length=sum(distance(a,b) for a,b in zip(pts,pts[1:]))
            if length<0.5:continue
            per_dir={}
            for direction in [1,-1]:
                modes=[]
                for mode in MODES:
                    if w['id'] in excluded[mode] or not access(t,mode) or direction not in directions(t,mode):continue
                    if any(node_blocks(allnodes[n].get('tags',{}),mode) for n in segment):continue
                    modes.append(mode)
                end_node=segment[-1] if direction==1 else segment[0]
                per_dir[direction]={'modes':modes,'facility':facility(t,direction),
                                    'control':control(allnodes[end_node].get('tags',{}),direction)}
            if not per_dir[1]['modes'] and not per_dir[-1]['modes']:continue
            if structural:  # straight line between the structure's own end elevations
                za,zb=elevation(segment[0]),elevation(segment[-1])
                prof=[(0.0,za),(length,zb)]
            else:
                prof=profile(pts, lambda p: z(p['lat'],p['lon']))
                prof[0]=(0.0,elevation(segment[0])); prof[-1]=(prof[-1][0],elevation(segment[-1]))
            back=[(length-d,v) for d,v in reversed(prof)]
            stairs=t['highway']=='steps'
            s={'way':w['id'],'a':index(segment[0]),'b':index(segment[-1]),
               'g':[round(c,6) for p in pts for c in (p['lon'],p['lat'])],'m':round(length,2),
               'hw':t['highway'],'n':name_index(t.get('name','')),
               'up':round(climb(prof,10 if stairs else MAX_ROAD_GRADE),1),'down':round(climb(back,10 if stairs else MAX_ROAD_GRADE),1)}
            for key,value in [('lanes',lanes(t)),('maxspeed',t.get('maxspeed')),('surface',t.get('surface')),
                              ('sidewalk',sidewalk(t) if t['highway'] in ROAD else None),
                              ('parkedBothSides',parked_both_sides(t)),
                              ('movableBridge',True if t.get('bridge')=='movable' or 'bridge:movable' in t else None),
                              ('footway',t.get('footway') if t['highway']=='footway' else None)]:
                if value is not None: s[key]=value
            if t['highway']=='steps':
                try: s['steps']=int(t.get('step_count',''))
                except ValueError: s['steps']=max(1,round(length/0.3))
            if t.get('footway')=='crossing' or t['highway']=='footway' and 'crossing' in t:
                ctl=crossing_control(t) or next((crossing_control(allnodes[n].get('tags',{})) for n in segment if crossing_control(allnodes[n].get('tags',{}))),None)
                crossed=[crossed_class[n] for n in segment if n in crossed_class]
                s['crossing']={'control':ctl,'road':'busy' if 'busy' in crossed else 'arterial' if 'arterial' in crossed else 'local' if crossed else None}
            for direction,key in [(1,'f'),(-1,'r')]:
                d=per_dir[direction]; p=prof if direction==1 else back
                if not d['modes']: continue
                entry={'modes':d['modes']}
                grade=None if stairs else approach_grade(p)
                if grade is not None: entry['approachGrade']=grade
                if left_turn_lane(t,direction) is not None: entry['leftTurnLane']=left_turn_lane(t,direction)
                if d['facility']!='none': entry['facility']=d['facility']
                if d['control']: entry['control']=d['control']
                s[key]=entry
            segments.append(s); geometry.append((w,pts))
    sidewalks=[i for i,s in enumerate(segments) if s.get('footway')=='sidewalk']
    roads=[(road_class(w['tags']),pts) for w,pts in geometry if road_class(w['tags'])]
    for i,cls in zip(sidewalks,beside_roads([geometry[i][1] for i in sidewalks],roads)):
        if cls: segments[i]['besideRoad']=cls
    for n,i in nodeindex.items():
        nt=allnodes[n].get('tags',{})
        if nt.get('highway')=='traffic_signals' and nt.get('traffic_signals') not in NOT_A_SIGNAL: nodes[i]['signal']=True
        if crossing_control(nt)=='signal': nodes[i]['pedestrianSignal']=True
    mapped=[{**r,'via':nodeindex[r['viaOSM']]} for r in restrictions if r['viaOSM'] in nodeindex]

    features=[]; places=[]
    def coords(ns):return [[allnodes[n]['lon'],allnodes[n]['lat']] for n in ns if n in allnodes]
    def feature(geom,kind,name=''):
        features.append({'type':'Feature','properties':{'kind':kind,'name':name},'geometry':geom})
    for w in sorted(allways.values(),key=lambda w:w['id']):
        t=w.get('tags',{}); ns=w['nodes'];cs=coords(ns)
        if len(cs)<2:continue
        if t.get('highway') and any(inside(allnodes[n]) for n in ns if n in allnodes):
            feature({'type':'LineString','coordinates':cs},'arterial' if t['highway'] in {'primary','secondary','trunk','motorway'} else 'path' if t['highway'] in {'cycleway','footway','path','steps'} else 'road',t.get('name',''))
        if ns[0]==ns[-1] and (t.get('natural')=='water' or t.get('leisure') in {'park','garden','pitch'}):
            ring=clip_ring(cs)
            if ring:feature({'type':'Polygon','coordinates':[ring]},'water' if t.get('natural')=='water' else 'park',t.get('name',''))
    for r in relations:
        t=r.get('tags',{})
        if t.get('natural')!='water' and t.get('leisure')!='park':continue
        groups={role:stitch([allways[m['ref']]['nodes'][:] for m in r['members'] if m['type']=='way' and m['ref'] in allways and m['role']==role]) for role in ['outer','inner']}
        outers=[clip_ring(coords(ns)) for ns in groups['outer']];inners=[clip_ring(coords(ns)) for ns in groups['inner']]
        polys=[[ring]+[hole for hole in inners if hole and point_in_ring(hole[0],ring)] for ring in outers if ring]
        if polys:feature({'type':'MultiPolygon','coordinates':polys},'water' if t.get('natural')=='water' else 'park',t.get('name',''))
    # Offline search is an explicit bounded selection of named public POIs, never ranking by sponsorship.
    for (typ,i),e in sorted(elements.items()):
        t=e.get('tags',{});name=t.get('name','')
        category=t.get('amenity') if t.get('amenity') in {'cafe','library'} else t.get('tourism') if t.get('tourism') in {'museum','attraction','viewpoint'} else 'park' if t.get('leisure')=='park' else None
        if not name or not category:continue
        if typ=='node': c=[e['lon'],e['lat']]
        else:
            ns=e.get('nodes',[]) if typ=='way' else [n for m in e.get('members',[]) if m['type']=='way' and m['ref'] in allways for n in allways[m['ref']]['nodes']]
            cs=coords(ns)
            if not cs:continue
            c=[sum(x[j] for x in cs)/len(cs) for j in [0,1]]
        if not inside({'lon':c[0],'lat':c[1]}):continue
        if any(p['name']==name and math.hypot(p['lon']-c[0],p['lat']-c[1])<.002 for p in places):continue
        places.append({'id':f'{typ}/{i}','name':name,'lat':round(c[1],7),'lon':round(c[0],7),'category':category})
    places.sort(key=lambda p:p['name'].casefold())
    graph={'schemaVersion':2,'bounds':BBOX,'names':list(names),'nodes':nodes,'segments':segments,'restrictions':mapped,'places':places}
    # Shipped gzipped (39 MB -> ~5 MB installed); mtime=0 keeps the archive byte-for-byte reproducible.
    graph_gz=gzip.compress((json.dumps(graph,separators=(',',':'))+'\n').encode(),compresslevel=9,mtime=0)
    (OUT/'seattle-graph.json.gz').write_bytes(graph_gz)
    # Search reads its own, newer extract (places and addresses), kept apart so the graph's inputs don't change.
    search_json, search_source = read_snapshot('seattle-search'); sources.append(search_source)
    search=build_search.build(search_json, places, nodes, segments, inside, hashlib.sha256(graph_gz).hexdigest(), OUT/'seattle-search.sqlite.gz')
    (OUT/'seattle-map.geojson').write_text(json.dumps({'type':'FeatureCollection','features':features},separators=(',',':'))+'\n')
    directed={mode:sum(mode in s.get(k,{}).get('modes',[]) for s in segments for k in 'fr') for mode in MODES}
    report={'sources':sources,'bounds':BBOX,'nodes':len(nodes),'segments':len(segments),'directedEdgesByMode':directed,
            'places':len(places),'supportedRestrictions':len(mapped),'unsupportedRestrictionsConservativelyExcluded':unsupported,
            'surfaceTaggedSegments':sum('surface' in s for s in segments),
            'sidewalkTaggedRoadSegments':sum('sidewalk' in s for s in segments),
            'sidewalksBesideRoad':collections.Counter(s.get('besideRoad','none') for s in segments if s.get('footway')=='sidewalk'),
            'approachesWithTurnLaneData':sum('leftTurnLane' in s.get(k,{}) for s in segments for k in 'fr'),
            'crossingSegments':collections.Counter(str(s['crossing']['control']) for s in segments if 'crossing' in s),
            'signalNodes':sum('signal' in n for n in nodes),
            'structureNodesInterpolated':len(lifted),'search':search}
    (ROOT/'Data/provenance.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='unsupportedRestrictionsConservativelyExcluded'},indent=2,sort_keys=True))
    print('Conservative restriction exclusions:',len(unsupported))

def speed_mph(maxspeed):
    try: value=float((maxspeed or '').split(' ')[0])
    except ValueError: return 0
    return value if 'mph' in (maxspeed or '') else value/1.609344

if __name__=='__main__':main()

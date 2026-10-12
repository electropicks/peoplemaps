#!/usr/bin/env python3
"""Deterministic, deliberately conservative OSM-to-POC graph compiler. No network."""
import collections, gzip, hashlib, json, math, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'Core/Resources'
BBOX = [47.615, -122.390, 47.678, -122.300]  # S,W,N,E
ROAD = {'motorway','motorway_link','trunk','trunk_link','primary','primary_link',
        'secondary','secondary_link','tertiary','tertiary_link','residential',
        'unclassified','living_street','service'}
YES = {'yes','designated','permissive','official'}
DENY = {'no','private','customers','delivery','destination','agricultural','forestry','permit'}

def inside(n):
    return BBOX[0] <= n['lat'] <= BBOX[2] and BBOX[1] <= n['lon'] <= BBOX[3]

def access(tags, mode):
    keys = ['motorcar','motor_vehicle','vehicle','access'] if mode == 'drive' else ['bicycle','vehicle','access']
    if any(k + ':conditional' in tags for k in keys) or 'oneway:conditional' in tags:
        return False  # no temporal evaluator in this POC
    value = next((tags[k] for k in keys if k in tags), None)
    if value is not None and value not in YES:
        return False
    h = tags.get('highway','')
    if mode == 'drive':
        return h in ROAD and tags.get('service') not in {'driveway','parking_aisle','emergency_access'}
    if h in {'motorway','motorway_link','trunk','trunk_link'}:
        return False
    return h in (ROAD | {'cycleway','living_street'}) or (h in {'path','footway','pedestrian'} and tags.get('bicycle') in YES)

def directions(tags, mode):
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

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    elements={}; sources=[]
    for basename in ['seattle-osm','seattle-parks']:
        raw=ROOT/'Data/raw'/f'{basename}.json'
        archive=ROOT/'Data'/f'{basename}.json.gz'
        data=raw.read_bytes() if raw.exists() else gzip.decompress(archive.read_bytes())
        p=json.loads(data)
        if p.get('remark'): raise ValueError(p['remark'])
        archive.write_bytes(gzip.compress(data,mtime=0))
        sources.append({'file':str(archive.relative_to(ROOT)),'sha256':hashlib.sha256(data).hexdigest(),
                        'osmBaseTimestamp':p['osm3s']['timestamp_osm_base']})
        for e in p['elements']: elements[(e['type'],e['id'])]=e
    allnodes={i:e for (typ,i),e in elements.items() if typ=='node'}
    allways={i:e for (typ,i),e in elements.items() if typ=='way'}
    relations=[e for (typ,i),e in elements.items() if typ=='relation']
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
    roads=[]
    for w in allways.values():
        t=w.get('tags',{})
        if not t.get('highway') or t.get('area')=='yes':continue
        if not any(inside(allnodes[n]) for n in w['nodes'] if n in allnodes):continue
        if access(t,'drive') or access(t,'bike'): roads.append(w)
    counts=collections.Counter(n for w in roads for n in set(w['nodes']))
    junctions={n for n,c in counts.items() if c>1}
    junctions.update(n for n,e in allnodes.items() if e.get('tags',{}).get('highway') in {'traffic_signals','stop','give_way'} or 'barrier' in e.get('tags',{}))
    junctions.update(r['viaOSM'] for r in restrictions)
    nodes=[]; nodeindex={}; edges=[]
    def index(n):
        if n not in nodeindex:
            nodeindex[n]=len(nodes); v=allnodes[n]
            nodes.append({'osmID':n,'lat':v['lat'],'lon':v['lon'],'signal':v.get('tags',{}).get('highway')=='traffic_signals'})
        return nodeindex[n]
    for w in sorted(roads,key=lambda w:w['id']):
        t=w['tags']; ns=w['nodes']; start=0
        for end in range(1,len(ns)):
            if end!=len(ns)-1 and ns[end] not in junctions: continue
            segment=ns[start:end+1];start=end
            if any(n not in allnodes or not inside(allnodes[n]) for n in segment):continue
            length=sum(distance(allnodes[a],allnodes[b]) for a,b in zip(segment,segment[1:]))
            if length<0.5:continue
            for direction in [1,-1]:
                modes=[]
                for mode in ['drive','bike']:
                    if w['id'] in excluded[mode] or not access(t,mode) or direction not in directions(t,mode):continue
                    blocked=False
                    for n in segment:
                        nt=allnodes[n].get('tags',{}); barrier=nt.get('barrier')
                        if any(nt.get(k) in DENY for k in (['motorcar','motor_vehicle'] if mode=='drive' else ['bicycle'])): blocked=True
                        if nt.get('access') in DENY and nt.get('bicycle' if mode=='bike' else 'motor_vehicle') not in YES:blocked=True
                        if barrier and barrier not in {'no','entrance','cattle_grid'}:
                            if mode=='drive' and nt.get('motor_vehicle') not in YES and nt.get('motorcar') not in YES: blocked=True
                            if mode=='bike' and barrier not in {'bollard','cycle_barrier'} and nt.get('bicycle') not in YES: blocked=True
                    if not blocked:modes.append(mode)
                if not modes:continue
                seq=segment if direction==1 else list(reversed(segment))
                edges.append({'id':len(edges),'from':index(seq[0]),'to':index(seq[-1]),'wayID':w['id'],
                              'geometry':[[allnodes[n]['lon'],allnodes[n]['lat']] for n in seq],
                              'meters':round(length,2),'modes':modes,'highway':t['highway'],'name':t.get('name',''),
                              'surface':t.get('surface'),'maxspeed':t.get('maxspeed'),'incline':t.get('incline'),
                              'facility':facility(t,direction)})
    mapped=[]
    for r in restrictions:
        if r['viaOSM'] in nodeindex:
            mapped.append({**r,'via':nodeindex[r['viaOSM']]})
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
    graph={'schemaVersion':1,'bounds':BBOX,'nodes':nodes,'edges':edges,'restrictions':mapped,'places':places}
    (OUT/'seattle-graph.json').write_text(json.dumps(graph,separators=(',',':'))+'\n')
    (OUT/'seattle-map.geojson').write_text(json.dumps({'type':'FeatureCollection','features':features},separators=(',',':'))+'\n')
    report={'sources':sources,'bounds':BBOX,'nodes':len(nodes),'directedEdges':len(edges),'places':len(places),
            'supportedRestrictions':len(mapped),'unsupportedRestrictionsConservativelyExcluded':unsupported,
            'surfaceTaggedEdges':sum(e['surface'] is not None for e in edges),
            'inclineTaggedEdges':sum(e['incline'] is not None for e in edges),
            'motorwayEdges':sum(e['highway'].startswith('motorway') for e in edges)}
    (ROOT/'Data/provenance.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='unsupportedRestrictionsConservativelyExcluded'},indent=2))
    print('Conservative restriction exclusions:',len(unsupported))

if __name__=='__main__':main()

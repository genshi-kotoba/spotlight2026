extends RefCounted
## Presentation-only solids grown from the actual wall boundary and regional
## terrain. No cells, graph nodes, gates or floors are created or changed.
const Hex=preload("res://systems/map/hex_coord.gd")
const VERSION="scene-envelope-v2"
const GENERATOR="context-envelope-v3"
const C=Vector2(0.573576436351046,0.819152044288992)
const L=Vector2(0.819152044288992,-0.573576436351046)
const TAN_PITCH=0.7071067811865476
var _original:Array=[]
var _grounds:Array=[]
var _lookup:Dictionary={}
var _volumes:Array=[]
var _seed:int
var _minimum:float
var _maximum:float
var _base:float
var _site_bottom:float
var _counts:Dictionary={}
var _radius:float
var _serial:int=0
var _spawn_key:String
var _regions:Array=[]
var _height_groups:Dictionary={}
var _loops:Array=[]
var _runs:Array=[]
var _groups:Dictionary={}
var _core_count:int=0

static func generate(layer:Dictionary,seed:int)->Dictionary:
 var builder=load("res://systems/map/relief_2d/scene_envelope.gd").new()
 return builder.build(layer,seed)

func build(layer:Dictionary,seed:int)->Dictionary:
 _original=[];_grounds=[];_lookup={};_volumes=[];_counts={};_serial=0
 _regions=[];_height_groups={};_loops=[];_runs=[];_groups={};_core_count=0
 _spawn_key="%d,%d"%[int(layer.spawn[0]),int(layer.spawn[1])]
 _seed=seed;_radius=float(layer.get("outer_radius",1.0));_minimum=INF;_maximum=-INF
 var quantum=float(layer.get("height_quantum",.20))
 for cell:Dictionary in layer.get("cells",[]):
  var p=Vector2i(int(cell.q),int(cell.r));var plane=Hex.to_plane(p,_radius)
  var row={"coord":p,"key":_key(p),"p":plane,"height":float(cell.get("level",0))*quantum,"hull":_hex(plane),"terrain":str(cell.get("terrain","ground")),"region":""}
  for field in ["region_id","region","height_region","wall_region"]:
   if cell.has(field):row.region=str(cell[field]);break
  _original.append(row);_lookup[p]=row;_minimum=minf(_minimum,row.height);_maximum=maxf(_maximum,row.height)
  if row.terrain=="ground":_grounds.append(row)
 if _original.is_empty():return {"version":VERSION,"generator":GENERATOR,"cells":[],"volumes":[],"stats":{}}
 _original.sort_custom(func(a,b):return a.key<b.key)
 _grounds.sort_custom(func(a,b):return a.key<b.key)
 _base=minf(0.0,_minimum)-.24;_site_bottom=_minimum-14.0
 _index_regions(layer)
 _trace_boundary()
 _make_site()
 _make_context_foundations()
 _make_regional_cores()
 _make_courts()
 _seal_original_base()
 var group_rows=[]
 var ids=_groups.keys();ids.sort()
 for id in ids:group_rows.append(_groups[id])
 return {"version":VERSION,"generator":GENERATOR,"cells":[],"volumes":_volumes,"stats":{"generator":GENERATOR,"volume_count":_volumes.size(),"roles":_counts,"original_cells":_original.size(),"site_bottom":_site_bottom,"boundary_loops":_loops.size(),"boundary_runs":_runs.size(),"core_groups":_core_count,"groups":group_rows,"shape_contract":"connected boundary-run supports and geometry-fitted regional masses; original map unchanged"}}

func _index_regions(layer:Dictionary)->void:
 # Nodes are the actual broad gameplay regions. The target field is a much
 # finer height partition and is retained separately, never used as a prefab.
 var nodes:Array=layer.get("nodes",[]).duplicate()
 nodes.sort_custom(func(a,b):return str(a.get("id",""))<str(b.get("id","")))
 for node:Dictionary in nodes:
  var c=node.get("coord",[])
  if c.size()!=2:continue
  var coord=Vector2i(int(c[0]),int(c[1]));var deps={}
  for pair in node.get("footprint",[]):
   var k=_key(Vector2i(int(pair[0]),int(pair[1])))
   if _lookup.has(Vector2i(int(pair[0]),int(pair[1]))):deps[k]=true
  if _lookup.has(coord):deps[_key(coord)]=true
  _regions.append({"id":str(node.get("id",_key(coord))),"p":Hex.to_plane(coord,_radius),"deps":deps})
 var height_data:Dictionary=layer.get("metadata",{}).get("height",{})
 for target:Dictionary in height_data.get("region_target_field",[]):
  var c=target.get("coord",[])
  if c.size()==2:_height_groups[_key(Vector2i(int(c[0]),int(c[1])))]=int(target.get("group",-1))
 for row in _original:
  var best={};var distance=INF
  for region in _regions:
   var d=row.p.distance_squared_to(region.p)
   if d<distance:distance=d;best=region
  if row.region.is_empty():row.region=best.get("id","terrain")
  row.region_deps=best.get("deps",{}).duplicate()
  row.local_height_group=_height_groups.get(row.key,-1)

func _hex_vertex_key(coord:Vector2i,e:int)->Vector2i:
 var vx=[2,1,-1,-2,-1,1];var vy=[0,1,1,0,-1,-1]
 return Vector2i(3*coord.x+vx[e%6],2*coord.y+coord.x+vy[e%6])

func _trace_boundary()->void:
 var edges=[];var next_by_vertex={}
 for row in _original:
  var hull:PackedVector2Array=row.hull
  for e in 6:
   var a=hull[e];var b=hull[(e+1)%6];var out=((a+b)*.5-row.p).normalized()
   if _lookup.has(Hex.from_plane(row.p+out*sqrt(3.0)*_radius,_radius)):continue
   var edge={"a":a,"b":b,"row":row,"id":row.key+":"+str(e),"ka":_hex_vertex_key(row.coord,e),"kb":_hex_vertex_key(row.coord,e+1)}
   edges.append(edge)
   var k=edge.ka
   if not next_by_vertex.has(k):next_by_vertex[k]=[]
   next_by_vertex[k].append(edges.size()-1)
 var visited={}
 for start in edges.size():
  if visited.has(start):continue
  var chain=[];var index=start
  while not visited.has(index):
   visited[index]=true;chain.append(edges[index])
   var candidates:Array=next_by_vertex.get(edges[index].kb,[])
   var found=-1
   for candidate in candidates:
    if candidate==start or not visited.has(candidate):found=candidate;break
   if found<0:break
   index=found
  if chain.size()<3:continue
  var points=PackedVector2Array()
  for edge in chain:points.append(edge.a)
  if chain[-1].b.distance_to(chain[0].a)>.01*_radius:continue
  var loop_id=_loops.size();var area=_area(points)
  _loops.append({"id":loop_id,"edges":chain,"area":area})
  # Split the closed contour at two well-separated anchors, then simplify
  # staircase detail. Every simplified run retains ALL contributing edges.
  var farthest=1;var distance=0.0
  for i in range(1,points.size()):
   var d=points[i].distance_squared_to(points[0])
   if d>distance:distance=d;farthest=i
  var anchors=[0]
  _simplify_indices(points,0,farthest,anchors)
  anchors.append(farthest)
  var closed=points.duplicate();closed.append(points[0])
  _simplify_indices(closed,farthest,points.size(),anchors)
  anchors.append(points.size());anchors.sort()
  var loop_runs=[]
  for i in range(anchors.size()-1):
   var first=int(anchors[i]);var last=int(anchors[i+1]);var a=closed[first];var b=closed[last]
   if a.distance_to(b)<.6*_radius:continue
   var source=[];var deps={};var regions={};var low=INF;var high=-INF;var mean=0.0;var walls={};var height_groups={}
   for j in range(first,last):
    var edge=chain[j%chain.size()];var row:Dictionary=edge.row
    source.append(edge);deps[row.key]=true;deps.merge(row.region_deps)
    if row.terrain=="wall":walls[row.key]=true
    regions[row.region]=int(regions.get(row.region,0))+1
    height_groups[str(row.local_height_group)]=true
    low=minf(low,row.height);high=maxf(high,row.height);mean+=row.height
   var region_ids=regions.keys();region_ids.sort()
   var region=region_ids[0]
   for id in region_ids:
    if regions[id]>regions[region]:region=id
   var tangent=(b-a).normalized();var out=Vector2(tangent.y,-tangent.x)
   var run={"id":"loop_%02d_run_%03d"%[loop_id,i],"loop":loop_id,"a":a,"b":b,"tangent":tangent,"out":out,"length":a.distance_to(b),"edges":source,"deps":deps,"walls":walls,"region":region,"low":low,"high":high,"mean":mean/source.size(),"height_groups":height_groups,"outer":area>0.0}
   loop_runs.append(run);_runs.append(run)
  for i in loop_runs.size():
   var run=loop_runs[i];var before=loop_runs[posmod(i-1,loop_runs.size())];var after=loop_runs[(i+1)%loop_runs.size()]
   run.before=before.id;run.after=after.id
   run.turn_before=before.tangent.cross(run.tangent);run.turn_after=run.tangent.cross(after.tangent)

func _simplify_indices(points:PackedVector2Array,first:int,last:int,result:Array)->void:
 if last-first<2:return
 var best=-1;var distance=1.05*_radius
 for i in range(first+1,last):
  var d=points[i].distance_to(Geometry2D.get_closest_point_to_segment(points[i],points[first],points[last]))
  if d>distance:distance=d;best=i
 if best<0:return
 _simplify_indices(points,first,best,result);result.append(best);_simplify_indices(points,best,last,result)

func _make_site()->void:
 var lo=_original[0].p;var hi=lo
 for row in _original:lo=lo.min(row.p);hi=hi.max(row.p)
 var step=18.0*_radius
 var x0=int(floor((lo.x-50)/step));var z0=int(floor((lo.y-50)/step))
 var x1=int(ceil((hi.x+50)/step));var z1=int(ceil((hi.y+50)/step))
 var points={};var heights={}
 for x in range(x0,x1+1):
  for z in range(z0,z1+1):
   var index=Vector2i(x,z);var p=Vector2(x*step,z*step)
   if x>x0 and x<x1 and z>z0 and z<z1:p+=Vector2(_unit(x,z,19)-.5,_unit(x,z,23)-.5)*step*.25
   points[index]=p;heights[index]=_minimum-1.65+sin(p.x*.035+float(_seed%97))*.26+cos(p.y*.04)*.22
 for x in range(x0,x1):
  for z in range(z0,z1):
   var a=Vector2i(x,z);var b=a+Vector2i(1,0);var c=a+Vector2i(1,1);var d=a+Vector2i(0,1)
   var triangles=[[a,b,c],[a,c,d]] if (x+z)%2==0 else [[a,b,d],[b,c,d]]
   for tri in triangles:
    var poly=PackedVector2Array([points[tri[0]],points[tri[1]],points[tri[2]]]);var h=[]
    for index in tri:h.append(heights[index])
    _emit(poly,_site_bottom,0.0,"site","site_%03d"%_serial,{_spawn_key:true},_height_plane(poly,h))

func _empty_clearance(run:Dictionary,extent:float)->Dictionary:
 var out:Vector2=run.out;var tangent:Vector2=run.tangent;var deps={}
 var clearance=extent
 # The first 1.6 radii contain the actual staircase that the chord simplifies.
 # A later obstacle terminates a bay, rather than sending a mass through it.
 for row in _original:
  var along=(row.p-run.a).dot(tangent)
  if along<-.6*_radius or along>run.length+.6*_radius:continue
  var depth=(row.p-run.a).dot(out)
  if depth>1.65*_radius and depth<extent+_radius:
   clearance=minf(clearance,maxf(.35*_radius,depth-1.15*_radius));deps[row.key]=true
 return {"depth":clearance,"deps":deps}

func _run_strip(run:Dictionary,depth0:float,depth1:float,inset:float=.4)->PackedVector2Array:
 var a:Vector2=run.a;var b:Vector2=run.b;var out:Vector2=run.out;var t:Vector2=run.tangent
 # A bevel follows this run's measured span and available depth. Adjacent
 # strips share end vertices and small overlaps, so turns remain connected.
 var bevel=minf(run.length*.18,minf(depth0,depth1)*.36)
 return _ccw(PackedVector2Array([a-out*inset-t*.12*_radius,b-out*inset+t*.12*_radius,b+out*depth1+t*.12*_radius,b+out*depth1-t*bevel,a+out*depth0+t*bevel,a+out*depth0-t*.12*_radius]))

func _register(group:String,run:Dictionary,kind:String)->void:
 if _groups.has(group):return
 var walls=run.walls.keys();walls.sort();var deps=run.deps.keys();deps.sort()
 _groups[group]={"id":group,"kind":kind,"source_region":run.region,"source_segment":run.id,"source_wall_keys":walls,"source_boundary_keys":deps,"local_height_groups":run.height_groups.keys(),"source_start":[run.a.x,run.a.y],"source_end":[run.b.x,run.b.y],"local_height_min":run.low,"local_height_max":run.high,"local_height_mean":run.mean}

func _chain_metadata(group:String,runs:Array,kind:String)->Dictionary:
 var first:Dictionary=runs[0];_register(group,first,kind)
 var deps={};var walls={};var segments=[];var regions={};var height_groups={};var low=INF;var high=-INF;var mean=0.0
 for run in runs:
  deps.merge(run.deps);walls.merge(run.walls);segments.append(run.id);regions[run.region]=true;height_groups.merge(run.height_groups)
  low=minf(low,run.low);high=maxf(high,run.high);mean+=run.mean
 var by_id=_run_index()
 deps.merge(by_id[first.before].deps);deps.merge(by_id[runs[-1].after].deps)
 var keys=walls.keys();keys.sort();var source_keys=deps.keys();source_keys.sort()
 _groups[group].source_wall_keys=keys;_groups[group].source_boundary_keys=source_keys
 _groups[group].source_segments=segments;_groups[group].source_regions=regions.keys()
 _groups[group].local_height_min=low;_groups[group].local_height_max=high;_groups[group].local_height_mean=mean/runs.size()
 _groups[group].local_height_groups=height_groups.keys()
 _groups[group].path=[]
 for run in runs:_groups[group].path.append([run.a.x,run.a.y])
 _groups[group].path.append([runs[-1].b.x,runs[-1].b.y])
 return deps

func _path_band(runs:Array,inner:float,widths:Array,bulges:Dictionary={})->Array:
 # Every pair shares exactly the same join, with a bounded miter at a real
 # turn. Union removes internal edges before convex decomposition; there is
 # no independent end cap at each hex-stair simplification segment.
 var inside=[];var outside=[]
 for i in range(runs.size()+1):
  var before:Dictionary=runs[maxi(0,i-1)];var after:Dictionary=runs[mini(i,runs.size()-1)]
  var point:Vector2=after.a if i<runs.size() else before.b
  var normal:Vector2=before.out+after.out
  if normal.length_squared()<.01:normal=after.out
  normal=normal.normalized()
  var dot=maxf(.50,normal.dot(after.out))
  var width:float=(float(widths[maxi(0,i-1)])+float(widths[mini(i,widths.size()-1)]))*.5
  width+=float(bulges.get(i,0.0))
  inside.append(point+normal*(inner/dot));outside.append(point+normal*(width/dot))
 var polygons=[]
 for i in runs.size():
  var poly=_clean(_ccw(PackedVector2Array([inside[i],inside[i+1],outside[i+1],outside[i]])))
  if poly.size()>2 and absf(_area(poly))>.025*_radius*_radius:polygons.append(poly)
 # Union only connected footprints. A true concave contour is retained and
 # later decomposed into convex solids, never turned into a whole-site hull.
 var merged=[]
 for poly in polygons:
  var current:PackedVector2Array=poly;var restart=true
  while restart:
   restart=false
   for i in merged.size():
    var union=Geometry2D.merge_polygons(current,merged[i])
    if union.size()==1:
     current=_clean(_ccw(union[0]));merged.remove_at(i);restart=true;break
  merged.append(current)
 return merged

func _run_index()->Dictionary:
 var by_id={}
 for run in _runs:by_id[run.id]=run
 return by_id

func _local_relief(run:Dictionary)->float:
 # The local region footprint is explicitly in run.deps. A distant hidden
 # global minimum must not change an already revealed support silhouette.
 var low=float(run.low)
 for key in run.deps:
  var pair=String(key).split(",");var coord=Vector2i(int(pair[0]),int(pair[1]))
  if _lookup.has(coord):low=minf(low,float(_lookup[coord].height))
 return maxf(0.0,run.mean-low)+absf(run.mean)*.32

func _make_context_foundations()->void:
 var by_id=_run_index()
 for run in _runs:
  var clearance=_empty_clearance(run,8.5*_radius);run.deps.merge(clearance.deps)
  var relief=_local_relief(run)
  var region_factor=.88+float(abs(int(hash(run.region)))%7)*.035
  var width=(.55+sqrt(relief)*.64+sqrt(run.length/_radius)*.19)*_radius*region_factor
  run.clearance=clearance.depth
  run.depth=minf(width,clearance.depth)
  # Support actual high/steep retaining stretches, while low stretches stay
  # exposed down to the site. This deliberately does not form a full collar.
  run.support_active=run.outer and (relief>1.05 or run.high-run.low>.85) and run.length>2.5*_radius
  if run.clearance<1.5*_radius:run.depth=minf(run.depth,.50*_radius)
 var visited={}
 for start in _runs:
  if visited.has(start.id) or not start.outer:continue
  var chain=[start];visited[start.id]=true;var current:Dictionary=start
  var datum=float(start.low);var length=float(start.length);var regional_extent=10.0*_radius
  for region in _regions:
   if region.id==start.region:regional_extent=maxf(regional_extent,sqrt(float(region.deps.size()))*2.7*_radius);break
  # Geometry and actual region ownership define the chain first. Height may
  # change its support profile, never steal runs from a revealed neighbor.
  while true:
   var following:Dictionary=by_id[current.after]
   if visited.has(following.id) or not following.outer or following.region!=start.region:break
   if length+following.length>regional_extent or current.tangent.dot(following.tangent)<-.35:break
   chain.append(following);visited[following.id]=true;datum=minf(datum,following.low);length+=following.length;current=following
  var active=false
  for run in chain:
   if run.support_active:active=true
  if not active:continue
  var group="support_"+start.id;var deps=_chain_metadata(group,chain,"boundary_foundation_chain");var widths=[]
  for run in chain:widths.append(run.depth)
  _groups[group].depth_profile=widths.duplicate();_groups[group].shared_datum=datum-.28
  for poly in _path_band(chain,-.7*_radius,widths):_emit_capped(poly,datum-.28,"foundation",group,deps)

func _radial_clearance(origin:Vector2,direction:Vector2,maximum:float)->Dictionary:
 var depth=maximum;var deps={};var tangent=Vector2(-direction.y,direction.x)
 for row in _original:
  var offset:Vector2=row.p-origin;var forward=offset.dot(direction)
  if forward<1.5*_radius or forward>maximum+_radius or absf(offset.dot(tangent))>1.25*_radius:continue
  depth=minf(depth,maxf(0.0,forward-1.2*_radius));deps[row.key]=true
 return {"depth":depth,"deps":deps}

func _make_regional_cores()->void:
 var by_id=_run_index();var candidates=[]
 for start in _runs:
  if not start.outer or start.walls.is_empty() or start.out.dot(C)>.25 or start.clearance<4.0*_radius:continue
  var chain=[start];var length=float(start.length);var current:Dictionary=start;var source_region=str(start.region)
  var regional_extent=0.0
  for region in _regions:
   if region.id==source_region:regional_extent=sqrt(float(region.deps.size()))*3.0*_radius;break
  var bend=0.0
  while true:
   var following:Dictionary=by_id[current.after]
   if following.id==start.id or not following.outer or following.walls.is_empty():break
   if following.out.dot(C)>.45 or following.clearance<4.0*_radius:break
   if following.region!=source_region and absf(following.mean-start.mean)>.5:break
   if absf(following.mean-start.mean)>1.1 or length+following.length>maxf(12.0*_radius,regional_extent):break
   var dot=current.tangent.dot(following.tangent)
   if dot<-.20:break
   bend+=absf(current.tangent.cross(following.tangent));chain.append(following);length+=following.length;current=following
  # A core must genuinely wrap an existing corner. Straight single-wall bars
  # are rejected; the geometry determines how many wings the chain contains.
  if chain.size()<2 or bend<.38 or length<8.0*_radius:continue
  var inner=0.0;var clearance=INF;var low=INF;var high=-INF;var mean=0.0;var widths=[]
  for run in chain:
   for edge in run.edges:inner=maxf(inner,maxf((edge.a-run.a).dot(run.out),(edge.b-run.a).dot(run.out)))
   clearance=minf(clearance,run.clearance);low=minf(low,run.low);high=maxf(high,run.high);mean+=run.mean
  mean/=chain.size();inner+=.30*_radius
  var relief=_local_relief(start)
  var depth=minf(clearance-inner-.4*_radius,maxf(2.2*_radius,sqrt(length/_radius)*.65*_radius*(.82+clampf(relief*.12,0.0,.65))))
  if depth<2.1*_radius:continue
  var longest=0.0
  for run in chain:longest=maxf(longest,run.length)
  for run in chain:widths.append(inner+depth*(.68+.32*run.length/longest))
  var bulges={};var bulge_deps={}
  if high-low>.8 or relief>1.8:
   for i in range(1,chain.size()):
    var left:Dictionary=chain[i-1];var right:Dictionary=chain[i]
    var turn=absf(left.tangent.cross(right.tangent))
    if turn<.50:continue
    var normal=(left.out+right.out).normalized()
    var room=_radial_clearance(right.a,normal,9.0*_radius);bulge_deps.merge(room.deps)
    if room.depth<6.0*_radius:continue
    var widening=minf(room.depth-inner-depth-.5*_radius,depth*(.30+turn*.30))
    if widening>.75*_radius:bulges[i]=widening
  var poly=PackedVector2Array();var cap={};var desired=mean+.95+depth*.29+(high-low)*.25;var fits=false
  # Enlargements are earned only where they also preserve every original
  # occupied column and the all-ground camera bound. Fall back to the fitted
  # narrow wing if the larger actual corner is not feasible.
  for attempt in 3:
   var polygons=_path_band(chain,inner,widths,bulges)
   if polygons.size()==1:
    poly=polygons[0];cap=_cap(poly,desired)
    fits=not is_finite(_occupied_ceiling(poly)) and cap.height>=low+.65
    if fits:break
   if not bulges.is_empty():bulges={}
   else:
    depth=maxf(2.15*_radius,depth*.78);widths=[]
    for run in chain:widths.append(inner+depth*(.80+.20*run.length/longest))
  if not fits:continue
  var score=length*length*(1.0+bend*.2)
  candidates.append({"run":start,"runs":chain,"poly":poly,"depth":depth,"inner":inner,"width":length,"widths":widths,"top":minf(desired,cap.height),"score":score,"cap":cap,"low":low,"high":high,"mean":mean,"bulges":bulges,"bulge_deps":bulge_deps})
 candidates.sort_custom(func(a,b):return a.score>b.score if not is_equal_approx(a.score,b.score) else a.run.id<b.run.id)
 var occupied=[];var used_segments={}
 for candidate in candidates:
  var run:Dictionary=candidate.run;var blocked=false
  for part in candidate.runs:
   if used_segments.has(part.id):blocked=true;break
  if blocked:continue
  for previous in occupied:
   if not Geometry2D.intersect_polygons(candidate.poly,previous.poly).is_empty():blocked=true;break
   var c=(run.a+candidate.runs[-1].b)*.5;var pc=(previous.run.a+previous.runs[-1].b)*.5
   if c.distance_to(pc)<(candidate.depth+previous.depth)*1.2:blocked=true;break
  if blocked:continue
  var group="core_"+run.id;var deps=_chain_metadata(group,candidate.runs,"regional_corner_core");deps.merge(candidate.cap.keys);deps.merge(candidate.bulge_deps)
  # Nearby candidate validity and fit can affect conflict selection. Include
  # their local source heights even if the current candidate was rejected.
  var influence=_bounds(candidate.poly).grow(18.0*_radius)
  for nearby in _runs:
   if influence.has_point(nearby.a) or influence.has_point(nearby.b):deps.merge(nearby.deps)
  var support_widths=[]
  for width in candidate.widths:support_widths.append(width+.4*_radius)
  for support in _path_band(candidate.runs,-.7*_radius,support_widths,candidate.bulges):_emit_capped(support,candidate.low-.22,"foundation",group,deps)
  # A common top across every convex piece preserves the kinked mass silhouette.
  _emit_capped(candidate.poly,candidate.top,"core",group,deps)
  _groups[group].available_depth=run.clearance;_groups[group].core_width=candidate.width;_groups[group].core_depth=candidate.depth;_groups[group].core_top=candidate.top;_groups[group].corner_widenings=candidate.bulges
  # Only an actual regional height break can grow a raised terminal wing.
  if candidate.high-candidate.low>1.0 and candidate.runs[-1].length>5.0*_radius:
   var end:Dictionary=candidate.runs[-1];var terminal=_path_band([end],candidate.inner+.25*_radius,[candidate.inner+candidate.depth*.72])
   for poly in terminal:_emit_capped(poly,candidate.top+(candidate.high-candidate.low)*.45,"core",group,deps)
  for part in candidate.runs:used_segments[part.id]=true
  occupied.append(candidate);_core_count+=1

func _make_courts()->void:
 # Clockwise boundary components enclose real, nonwalkable holes. Their
 # floors follow that concave hole, rather than filling a hull across walls.
 for loop in _loops:
  if loop.area>=-3.0*_radius*_radius:continue
  var poly=PackedVector2Array();var deps={};var walls={};var low=INF;var source_runs=[];var first={}
  for run in _runs:
   if run.loop!=loop.id:continue
   if first.is_empty():first=run
   poly.append(run.a);deps.merge(run.deps);walls.merge(run.walls)
   low=minf(low,run.low);source_runs.append(run.id)
  if first.is_empty() or poly.size()<3:continue
  var group="court_loop_%02d"%loop.id
  _register(group,first,"enclosed_court_bottom")
  var wall_keys=walls.keys();wall_keys.sort()
  _groups[group].source_wall_keys=wall_keys;_groups[group].source_segments=source_runs
  _groups[group].source_boundary_keys=deps.keys()
  var top=low-.82
  # Regional bottoms sit between their own retaining base and the low site;
  # each one varies with the original local floor rather than a global plate.
  _emit_capped(_ccw(poly),top,"basin",group,deps)

func _seal_original_base()->void:
 # At the buried common datum, one convex patch per simplified run seals the
 # hex stairs. It is hidden below every old occupied floor, not a visible
 # honeycomb apron and not a giant hull under the whole map.
 for run in _runs:
  var points=PackedVector2Array()
  for edge in run.edges:
   points.append(edge.a);points.append(edge.b);points.append(edge.a-run.out*.06*_radius);points.append(edge.b-run.out*.06*_radius)
  var hull=_clean(Geometry2D.convex_hull(points))
  _emit(hull,_site_bottom,_base,"foundation","buried_skirt",run.deps)

func _emit_capped(poly:PackedVector2Array,desired:float,role:String,group:String,deps:Dictionary,plane:Array=[])->void:
 poly=_clean(_ccw(poly))
 if poly.size()<3:return
 # Clip the whole connected mass to a COMMON conservative top before convex
 # decomposition. Independent caps produce divergent puzzle tops and fins.
 var maximum=desired
 if not plane.is_empty():
  maximum=-INF
  for p in poly:maximum=maxf(maximum,plane[0]*p.x+plane[1]*p.y+plane[2])
 var cap=_cap(poly,maximum);var ceiling=minf(cap.height,_occupied_ceiling(poly)-.12)
 var reveal=deps.duplicate();reveal.merge(cap.keys);reveal.merge(_occupied_keys(poly))
 var top=minf(desired,ceiling);var clipped_plane=plane.duplicate()
 if not plane.is_empty() and maximum>ceiling:clipped_plane[2]-=maximum-ceiling
 var pieces=Geometry2D.decompose_polygon_in_convex(poly)
 for piece:PackedVector2Array in pieces:_emit(piece,_site_bottom,top,role,group,reveal,clipped_plane)

func _emit(poly:PackedVector2Array,bottom:float,top:float,role:String,group:String,deps:Dictionary,plane:Array=[])->void:
 if poly.size()<3 or absf(_area(poly))<.015:return
 poly=_clean(_ccw(poly))
 if poly.size()<3:return
 if poly.size()>12:
  var middle=poly.size()/2
  var left=PackedVector2Array();var right=PackedVector2Array([poly[0]])
  for i in range(middle+1):left.append(poly[i])
  for i in range(middle,poly.size()):right.append(poly[i])
  _emit(left,bottom,top,role,group,deps,plane)
  _emit(right,bottom,top,role,group,deps,plane)
  return
 var keys=deps.keys();keys.sort()
 if keys.is_empty():return
 var min_h=top
 if not plane.is_empty():
  min_h=INF
  for p in poly:min_h=minf(min_h,float(plane[0])*p.x+float(plane[1])*p.y+float(plane[2]))
 if min_h<=bottom+.01:return
 var footprint=[]
 for p in poly:footprint.append([p.x,p.y])
 var v={"id":"volume_%04d"%_serial,"group_id":group,"role":role,"footprint":footprint,"bottom":bottom,"top":top,"reveal_keys":keys}
 v.bottom_from_known_min=-14.0
 v.nonwalkable=true
 if _groups.has(group):
  v.source_wall_keys=_groups[group].source_wall_keys
  v.source_region=_groups[group].source_region
  v.source_segment=_groups[group].source_segment
 if not plane.is_empty():v.top_plane=plane
 if role=="site":v.top_from_known_min=float(plane[2])-_minimum
 elif group=="buried_skirt":v.top_from_known_min=-.24
 _volumes.append(v);_serial+=1;_counts[role]=int(_counts.get(role,0))+1

func _cap(poly:PackedVector2Array,desired:float)->Dictionary:
 var lo_l=INF;var hi_l=-INF;var lo_d=INF
 for p in poly:lo_l=minf(lo_l,p.dot(L));hi_l=maxf(hi_l,p.dot(L));lo_d=minf(lo_d,p.dot(C))
 var top=desired;var keys={}
 for g in _grounds:
  var lateral=g.p.dot(L)
  if lateral<lo_l-1.35*_radius or lateral>hi_l+1.35*_radius:continue
  var delta=lo_d-g.p.dot(C)
  if delta< -2.0*_radius:continue
  var limit=float(g.height)-.06+TAN_PITCH*(delta-1.0*_radius)
  keys[g.key]=true;top=minf(top,limit)
 return {"height":top,"keys":keys}

func _occupied_keys(poly:PackedVector2Array)->Dictionary:
 var result={};var bounds=_bounds(poly).grow(1.01*_radius)
 for row in _original:
  if bounds.has_point(row.p) and not Geometry2D.intersect_polygons(poly,row.hull).is_empty():result[row.key]=true
 return result

func _occupied_ceiling(poly:PackedVector2Array)->float:
 var result=INF;var bounds=_bounds(poly).grow(1.01*_radius)
 for row in _original:
  if bounds.has_point(row.p) and not Geometry2D.intersect_polygons(poly,row.hull).is_empty():result=minf(result,float(row.height))
 return result

func _clean(poly:PackedVector2Array)->PackedVector2Array:
 var result=PackedVector2Array()
 for p in poly:
  if result.is_empty() or p.distance_squared_to(result[-1])>.00000001:result.append(p)
 if result.size()>1 and result[0].distance_squared_to(result[-1])<.00000001:result.remove_at(result.size()-1)
 var changed=true
 while changed and result.size()>3:
  changed=false
  for i in result.size():
   var before=result[posmod(i-1,result.size())];var p=result[i];var after=result[(i+1)%result.size()]
   if absf((p-before).cross(after-p))<.00001:result.remove_at(i);changed=true;break
 return result

func _chamfer_box(center:Vector2,u:Vector2,v:Vector2,length:float,depth:float,bevel:float)->PackedVector2Array:
 var a=length*.5;var b=depth*.5;var raw=[Vector2(-a+bevel,-b),Vector2(a-bevel,-b),Vector2(a,-b+bevel),Vector2(a,b-bevel),Vector2(a-bevel,b),Vector2(-a+bevel,b),Vector2(-a,b-bevel),Vector2(-a,-b+bevel)]
 var poly=PackedVector2Array()
 for p in raw:poly.append(center+u*p.x+v*p.y)
 return _ccw(poly)
func _ccw(poly:PackedVector2Array)->PackedVector2Array:
 if _area(poly)<0:poly.reverse()
 return poly
func _area(poly:PackedVector2Array)->float:
 var area=0.0
 for i in poly.size():area+=poly[i].cross(poly[(i+1)%poly.size()])
 return area*.5
func _bounds(poly:PackedVector2Array)->Rect2:
 var r=Rect2(poly[0],Vector2.ZERO)
 for p in poly:r=r.expand(p)
 return r
func _hex(center:Vector2)->PackedVector2Array:
 var p=PackedVector2Array()
 for i in 6:p.append(center+Vector2.from_angle(TAU*i/6.0)*_radius)
 return p
func _height_plane(poly:PackedVector2Array,h:Array)->Array:
 var p=poly[1]-poly[0];var q=poly[2]-poly[0];var d=p.cross(q)
 var a=((h[1]-h[0])*q.y-(h[2]-h[0])*p.y)/d
 var b=(p.x*(h[2]-h[0])-q.x*(h[1]-h[0]))/d
 return [a,b,h[0]-a*poly[0].x-b*poly[0].y]
func _key(p:Vector2i)->String:return "%d,%d"%[p.x,p.y]
func _unit(q:int,r:int,salt:int)->float:
 var value=(_seed&0x7fffffff)^((q*374761393+r*668265263+salt*69069)&0x7fffffff)
 value=((value^(value>>13))*1274126177)&0x7fffffff
 return float(value^(value>>16))/2147483647.0

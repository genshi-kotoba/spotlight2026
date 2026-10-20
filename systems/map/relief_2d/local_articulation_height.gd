extends RefCounted
## Refine one exact, already selected network. Never reroll its macro graph.
const Hex=preload("res://systems/map/hex_coord.gd")
const Network=preload("res://systems/map/relief_2d/regional_network_height.gd")
const Regions=preload("res://systems/map/relief_2d/region_walls_height.gd")
const Features=preload("res://systems/map/relief_2d/regional_features_height.gd")
const VERSION="constrained-local-articulation-v1"
const DIRECTIONS=[Vector2i(1,0),Vector2i(0,1),Vector2i(-1,1),Vector2i(-1,0),Vector2i(0,-1),Vector2i(1,-1)]

static func refine(planar:Dictionary,data:Dictionary,c:Dictionary,seed_value:int,base:Dictionary,measure:Callable)->Dictionary:
 var graph=Network.refinement_graph(planar,data,c,base)
 if graph.has("error"):return graph
 data=graph.refinement_data;data._rw_cell_topology=Regions._cell_topology(data)
 # Per-refinement geometry only: no seed/config state survives this call.
 data._la_quality_windows=_quality_windows(data)
 var original:Array=base.levels;var pins:Dictionary=graph.pins
 var physical_witness=_physical_ascent_witness(original,data);var witness=[]
 for coord in physical_witness:
  var site=int(data.owner[coord])
  if site not in witness:witness.append(site)
  pins[site]=true
 for site in pins:graph.lower[site]=int(original[site]);graph.upper[site]=int(original[site])
 var closed=Network._close(graph.lower,graph.upper,graph.forward,graph.reverse)
 if not closed.feasible:return {"error":"Original local articulation invariants conflict"}
 graph.lower=closed.lower;graph.upper=closed.upper
 var points=[]
 for group in data.groups:
  var point=Vector2.ZERO
  for coord in group:point+=Hex.to_plane(coord,1)
  points.append(point/group.size())
 var protected={}
 for footprint in data.protected_footprints.values():
  for coord in footprint:protected[coord]=true
 data._la_required=protected
 var shoulders=_shoulders(original,data,points,protected)
 var gradients=_gradients(original,data,points)
 var before=_quality(original,data,protected);before.short_stair_features=0;var best_levels=original.duplicate();var best_targets=original.duplicate();var best_quality=before;var best_score=0.0;var chosen=-1;var candidates=[];var best_declined=[]
 var movable=0;var wide=0
 for site in original.size():
  if int(closed.lower[site])<int(closed.upper[site]):movable+=data.groups[site].size()
  if int(closed.upper[site])-int(closed.lower[site])>=2:wide+=data.groups[site].size()
 for variant in 4:
  var targets=_targets(original,data,points,gradients,shoulders,seed_value,variant)
  for row in base.network.regions:targets.append(int(row.level))
  var levels=Network._project(targets,graph)
  if levels.is_empty():continue
  levels=Network._optimize(levels,targets,graph,12)
  levels=_tidy(levels,graph,data,pins,original)
  levels=_tidy_small(levels,graph,data)
  var ground=levels.slice(0,original.size());var quality=_quality(ground,data,protected,before);var declined=[];var short_features=_short_stair_features(ground,shoulders,data);quality.short_stair_features=short_features.size()
  if quality.broad_stair_cells>before.broad_stair_cells or quality.near_stair_cells>before.near_stair_cells or quality.introduced_stair_cells>0 or not short_features.is_empty():
   var repair=_decline_feature(levels,targets,original,quality,before,shoulders,graph,data,pins,short_features)
   if repair.get("feasible",false):
    levels=repair.levels;targets=repair.targets;ground=levels.slice(0,original.size());quality=_quality(ground,data,protected,before);quality.short_stair_features=_short_stair_features(ground,shoulders,data).size();declined=repair.records
  var movement=0.0;var changed=0
  for site in original.size():
   movement+=absf(float(ground[site])-float(original[site]))*data.groups[site].size()
   if ground[site]!=original[site]:changed+=data.groups[site].size()
  var score=2.0*(before.flat_area-quality.flat_area)+4.0*(before.largest_flat-quality.largest_flat)+1.4*(before.broad_stair_cells-quality.broad_stair_cells)+.7*(before.near_stair_cells-quality.near_stair_cells)-12.0*maxi(0,quality.tiny_extrema-before.tiny_extrema)-7.0*maxi(0,quality.new_tips-before.new_tips)-.14*movement-1.0*quality.introduced_near_stair_cells
  var band_safe=quality.broad_stair_cells<=before.broad_stair_cells and quality.near_stair_cells<=before.near_stair_cells and quality.introduced_stair_cells==0 and quality.short_stair_features==0
  candidates.append({"variant":variant,"score":score,"changed_cells":changed,"quality":_summary(quality),"absolute_level_movement":movement,"band_safe":band_safe,"declined_features":declined})
  if band_safe and score>best_score:best_score=score;chosen=variant;best_levels=ground;best_targets=targets.slice(0,original.size());best_quality=quality;best_declined=declined
 var result=base.duplicate(true);result.levels=best_levels;result.targets=best_targets
 var owners:Dictionary=data._rf_owners;var local=Network._metrics(best_levels,base.network.relations,[],{},data,owners,points,[])
 local.merge(Network._plane_metrics(best_levels,Network._plane_windows(data),data,c),true)
 for key in local:result.local[key]=local[key]
 for key in ["local_plane_ratio","local_plane_component_ratio","worst_bin_plane_ratio","plane_bins","near_flat_ratio"]:result.network[key]=local[key]
 result.network.tips=Regions._tip_sites(best_levels,data).map(func(i):return [data.groups[i][0].x,data.groups[i][0].y])
 result.network.candidate_metrics_scope="original_macro_network_before_local_refinement"
 result.network.macro_score_scope="original_macro_selection_not_reranked"
 if result.network.tips.is_empty():result.network.limitations.erase("remaining_one_level_tips")
 elif "remaining_one_level_tips" not in result.network.limitations:result.network.limitations.append("remaining_one_level_tips")
 result.network.field="same-macro-network-with-constrained-local-articulation"
 var changed=0
 for site in original.size():
  if best_levels[site]!=original[site]:changed+=data.groups[site].size()
 result.articulation={"version":VERSION,"status":"refined_candidate" if chosen>=0 else "limited_no_local_candidate_improved_metrics","selected_variant":chosen,"macro_profile":base.profile,"macro_relations_preserved":true,"range_before":[original.min(),original.max()],"range_after":[best_levels.min(),best_levels.max()],"ascent_before":physical_witness.size()-1,"ascent_after":_physical_ascent_witness(best_levels,data).size()-1,"ascent_scope":"physical-coordinate-strict-unit-rise-DAG","witness_coords":physical_witness.map(func(p):return [p.x,p.y]),"witness_groups":witness,"pinned_ground_groups":pins.size(),"movable_ground_cells":movable,"movable_at_least_two_levels":wide,"changed_ground_cells":changed,"before":_summary(before),"after":_summary(best_quality),"candidates":candidates,"declined_features":best_declined,"shoulders":shoulders.map(func(row):return {"source_groups":row.sites,"source_level":row.level,"role":"court_shoulder" if row.sign>0 else "ridge_shoulder","width":row.width,"length":row.length}),"shape":"smooth-two-dimensional-contour-displacement-and-connected-shoulder-ribbons","limitations":["macro-contracts-can-force-local-stair-edges","integer-height-terraces-remain"]}
 return result

static func _short_stair_features(levels:Array,shoulders:Array,data:Dictionary)->Array:
 # Three height levels across two physical lanes already read as a wide stair
 # in a compact room. Only test an original connected same-height shoulder;
 # existing route climbs and two-tier shoulders do not trigger this guard.
 var result=[]
 for index in shoulders.size():
  var members={}
  for site in shoulders[index].sites:
   for coord in data.groups[site]:members[coord]=true
  var found=false
  for coord in members:
   for direction in DIRECTIONS:
    for across in DIRECTIONS:
     if across==direction or across==-direction:continue
     for side_rise in [-1,0,1]:
      var valid=true;var intercept=int(levels[data.owner[coord]])
      for y in 2:
       for x in 3:
        var p:Vector2i=coord+direction*x+across*y
        if not members.has(p) or int(levels[data.owner[p]])!=intercept+x+side_rise*y:valid=false;break
       if not valid:break
      if valid:found=true;break
     if found:break
    if found:break
   if found:break
  if found:result.append(index)
 return result

static func _decline_feature(levels:Array,targets:Array,original:Array,quality:Dictionary,before:Dictionary,shoulders:Array,graph:Dictionary,data:Dictionary,pins:Dictionary,short_features:Array=[])->Dictionary:
 # Preserve each whole source shoulder plus one physical ring, in a single
 # reprojection. The smaller-room guard never edits isolated metric witnesses.
 var chosen=short_features.duplicate();var long_chosen=-1;var best=0.0
 var needs_long_repair=quality.broad_stair_cells>before.broad_stair_cells or quality.near_stair_cells>before.near_stair_cells or quality.introduced_stair_cells>0
 if needs_long_repair:
  var changed={}
  for coord in quality._bands:
   if before._bands.has(coord):continue
   var site=int(data.owner[coord])
   if int(levels[site])!=int(original[site]):changed[site]=true
  if changed.is_empty():
   for coord in quality._near:
    if before._near.has(coord):continue
    var site=int(data.owner[coord])
    if int(levels[site])!=int(original[site]):changed[site]=true
  for index in shoulders.size():
   var row=shoulders[index];var contribution=0.0
   for site in changed:
    if not row.influence.has(site):continue
    var delta=int(levels[site])-int(original[site]);var matching=2.0 if delta*int(row.sign)>0 else .5
    contribution+=matching*absi(delta)*[3.0,1.5,.5][int(row.influence[site])]
   if contribution>best:best=contribution;long_chosen=index
  if long_chosen>=0 and long_chosen not in chosen:chosen.append(long_chosen)
 if chosen.is_empty():return {"feasible":false}
 chosen.sort()
 var lower:Array=graph.lower.duplicate();var upper:Array=graph.upper.duplicate();var local_targets=targets.duplicate();var records=[]
 for index in chosen:
  var feature=shoulders[index];var preserved=[];var count=0
  for site in feature.influence:
   if int(feature.influence[site])>1:continue
   preserved.append(int(site));count+=data.groups[site].size();lower[site]=int(original[site]);upper[site]=int(original[site]);local_targets[site]=int(original[site])
  records.append({"source_index":index,"source_groups":feature.sites,"source_level":feature.level,"preserved_groups":preserved,"preserved_ground_cells":count,"apron_physical_rings":1,"reason":"whole-original-flat-shoulder-declined-for-new-parallel-three-level-room-stairs" if index in short_features else "whole-shoulder-declined-because-its-changed-ground-created-new-coherent-stair-band","contribution_score":best if index==long_chosen else 0.0})
 var closed=Network._close(lower,upper,graph.forward,graph.reverse)
 if not closed.feasible:return {"feasible":false}
 var local_graph=graph.duplicate(false);local_graph.lower=closed.lower;local_graph.upper=closed.upper
 var proposed=Network._project(local_targets,local_graph)
 if proposed.is_empty():return {"feasible":false}
 proposed=Network._optimize(proposed,local_targets,local_graph,12);proposed=_tidy(proposed,local_graph,data,pins,original);proposed=_tidy_small(proposed,local_graph,data)
 return {"feasible":true,"levels":proposed,"targets":local_targets,"records":records}

static func _physical_ascent_witness(levels:Array,data:Dictionary)->Array:
 var ordered=data.owner.keys();ordered.sort_custom(func(a,b):
  var la=int(levels[data.owner[a]]);var lb=int(levels[data.owner[b]])
  return la<lb if la!=lb else (a.x<b.x if a.x!=b.x else a.y<b.y))
 var lengths={};var parents={};var best:Vector2i=ordered[0]
 for coord in ordered:
  lengths[coord]=0
  for other in Hex.neighbors(coord):
   if not data.owner.has(other) or int(levels[data.owner[other]])!=int(levels[data.owner[coord]])-1:continue
   var length=int(lengths.get(other,0))+1
   if length>int(lengths[coord]):lengths[coord]=length;parents[coord]=other
  if int(lengths[coord])>int(lengths[best]):best=coord
 var path=[best]
 while parents.has(path[-1]):path.append(parents[path[-1]])
 return path

static func _ascent_witness(levels:Array,data:Dictionary)->Array:
 var ordered=range(levels.size());ordered.sort_custom(func(a,b):return levels[a]<levels[b] if levels[a]!=levels[b] else a<b)
 var lengths=[];var parents=[];lengths.resize(levels.size());lengths.fill(0);parents.resize(levels.size());parents.fill(-1);var best=0
 for site in ordered:
  for other in data.edges[site]:
   if int(levels[other])==int(levels[site])-1 and int(lengths[other])+1>int(lengths[site]):lengths[site]=int(lengths[other])+1;parents[site]=other
  if int(lengths[site])>int(lengths[best]):best=site
 var path=[];var current=best
 while current>=0:path.append(current);current=int(parents[current])
 return path

static func _shoulders(levels:Array,data:Dictionary,points:Array,protected:Dictionary)->Array:
 var visited={};var result=[]
 for start in levels.size():
  if visited.has(start):continue
  var queue=[start];var cursor=0;visited[start]=true;var count=0;var free=0;var center=Vector2.ZERO
  while cursor<queue.size():
   var site=int(queue[cursor]);cursor+=1;count+=data.groups[site].size();center+=points[site]*data.groups[site].size()
   for coord in data.groups[site]:
    if not protected.has(coord):free+=1
   for other in data.edges[site]:
    if not visited.has(other) and int(levels[other])==int(levels[site]):visited[other]=true;queue.append(other)
  if count<8 or free<4:continue
  center/=count;var xx=0.0;var xy=0.0;var yy=0.0;var high=0;var low=0;var flow=Vector2.ZERO
  for site in queue:
   var p:Vector2=points[site]-center;xx+=p.x*p.x;xy+=p.x*p.y;yy+=p.y*p.y
   for other in data.edges[site]:
    flow+=(points[other]-points[site])*(int(levels[other])-int(levels[site]))
    if int(levels[other])>int(levels[site]):high+=1
    elif int(levels[other])<int(levels[site]):low+=1
  var angle=.5*atan2(2.0*xy,xx-yy);var axis=Vector2(cos(angle),sin(angle));var normal=Vector2(-axis.y,axis.x);var width=1.0;var length=2.0
  for site in queue:
   var p:Vector2=points[site]-center;width=maxf(width,absf(p.dot(normal)));length=maxf(length,absf(p.dot(axis)))
  var influence={};var expansion=queue.duplicate()
  for site in queue:influence[site]=0
  cursor=0
  while cursor<expansion.size():
   var site=int(expansion[cursor]);cursor+=1
   if int(influence[site])>=2:continue
   for other in data.edges[site]:
    if not influence.has(other):influence[other]=int(influence[site])+1;expansion.append(other)
  result.append({"sites":queue,"level":int(levels[start]),"center":center,"axis":axis,"normal":normal,"width":width,"length":length,"sign":1 if high>low else -1,"influence":influence,"flow":flow})
 return result

static func _gradients(levels:Array,data:Dictionary,points:Array)->Array:
 var result=[]
 for site in levels.size():
  var queue=[site];var distances={site:0};var cursor=0
  while cursor<queue.size():
   var here=int(queue[cursor]);cursor+=1
   if int(distances[here])>=2:continue
   for other in data.edges[here]:
    if not distances.has(other):distances[other]=int(distances[here])+1;queue.append(other)
  var xx=0.0;var xy=0.0;var yy=0.0;var xh=0.0;var yh=0.0
  for other in queue:
   var p:Vector2=points[other]-points[site];var h=float(levels[other])-float(levels[site]);xx+=p.x*p.x;xy+=p.x*p.y;yy+=p.y*p.y;xh+=p.x*h;yh+=p.y*h
  var det=xx*yy-xy*xy;var gradient=Vector2.ZERO
  if absf(det)>.000001:gradient=Vector2((xh*yy-yh*xy)/det,(yh*xx-xh*xy)/det)
  result.append(gradient)
 return result

static func _targets(original:Array,data:Dictionary,points:Array,gradients:Array,shoulders:Array,seed_value:int,variant:int)->Array:
 var phase=TAU*float((seed_value&65535))/65536.0;var a=Vector2(cos(.37+phase*.13),sin(.37+phase*.13));var b=Vector2(cos(1.93+phase*.19),sin(1.93+phase*.19));var result=[]
 var prepared=[]
 for index in shoulders.size():
  var row:Dictionary=shoulders[index];var shape=row.duplicate(false)
  if variant>0:
   var axis:Vector2=row.axis;var flow:Vector2=row.flow
   if flow.length()>.01:
    flow=flow.normalized()
    if flow.dot(axis)<0:flow=-flow
    axis=axis.lerp(flow,.50 if variant==2 else .25).normalized()
   axis=axis.rotated((.23 if variant%2==1 else -.23)*sin(phase+index*.71+.6))
   shape.axis=axis;shape.normal=Vector2(-axis.y,axis.x);shape.width=1.0;shape.length=2.0
   for site in row.sites:
    var p:Vector2=points[site]-row.center;shape.width=maxf(shape.width,absf(p.dot(shape.normal)));shape.length=maxf(shape.length,absf(p.dot(axis)))
  prepared.append(shape)
 var warp_phase=phase+(0.0 if variant==0 else .67*variant)
 for site in original.size():
  var p:Vector2=points[site]
  var warp=Vector2(sin(p.dot(a)*.28+warp_phase),sin(p.dot(b)*.22+warp_phase*1.71))
  warp+=.35*Vector2(sin(p.dot(b)*.41+warp_phase*.79),cos(p.dot(a)*.19+warp_phase*1.29))
  var delta=(2.0 if variant==0 else 2.25)*gradients[site].dot(warp);var shoulder_delta=0.0
  for index in prepared.size():
   var row=prepared[index]
   if not row.influence.has(site):continue
   var local:Vector2=p-row.center;var u=local.dot(row.axis);var v=local.dot(row.normal);var bend=.75*sin(u/maxf(2.0,row.length*.7)+phase+index*.73)+.12*u;var width=maxf(1.0,row.width*.75)
   if variant>0:
    var local_phase=phase+index*.73+variant*.91
    bend=minf(2.1,row.width*.65)*sin(u/maxf(2.5,row.length*.55)+local_phase)
    bend+=minf(.75,row.width*.23)*sin(u/maxf(1.8,row.length*.34)+local_phase*1.27)
    width=maxf(.95,row.width*(.58+.24*sin(u/maxf(2.0,row.length*.52)+local_phase*.83)))
   var cross=clampf(absf(v-bend)/width,0,1)
   var weight=[1.0,.65,.25][int(row.influence[site])]
   var offset=float(row.sign)*(1.8 if variant==0 else 2.0)*cross*cross*(3.0-2.0*cross)*weight
   if absf(offset)>absf(shoulder_delta):shoulder_delta=offset
  delta+=shoulder_delta
  result.append(float(original[site])+clampf(delta,-3.0,3.0))
 return result

static func _tidy(initial:Array,graph:Dictionary,data:Dictionary,pins:Dictionary,original:Array)->Array:
 var levels=initial.duplicate()
 for pass_index in 3:
  var changed=false
  for site in original.size():
   if pins.has(site) or data.groups[site].size()!=1 or data.edges[site].size()<2:continue
   var above=0;var below=0
   for other in data.edges[site]:
    if int(levels[other])>int(levels[site]):above+=1
    elif int(levels[other])<int(levels[site]):below+=1
   if above!=data.edges[site].size() and below!=data.edges[site].size():continue
   var proposed=int(levels[site])+(1 if above>0 else -1);var low=int(graph.lower[site]);var high=int(graph.upper[site])
   for other in graph.forward[site]:low=maxi(low,int(levels[other])-int(graph.forward[site][other]))
   for other in graph.reverse[site]:high=mini(high,int(levels[other])+int(graph.reverse[site][other]))
   if proposed>=low and proposed<=high:levels[site]=proposed;changed=true
  if not changed:break
 return levels

static func _quality_windows(data:Dictionary)->Dictionary:
 var coords:Array=data.owner.keys();var indices:Dictionary={};var owners:Array=[];var windows:Array=[]
 for i:int in coords.size():indices[coords[i]]=i;owners.append(int(data.owner[coords[i]]))
 for coord:Vector2i in coords:
  for direction:Vector2i in DIRECTIONS:
   for across:Vector2i in DIRECTIONS:
    if across==direction or across==-direction:continue
    var cells:=PackedInt32Array();var valid:=true
    for y:int in 3:
     for x:int in 4:
      var point:Vector2i=coord+direction*x+across*y
      if not indices.has(point):valid=false;break
      cells.append(int(indices[point]))
     if not valid:break
    if valid:windows.append(cells)
 return {"coords":coords,"owners":owners,"windows":windows}

static func _quality(levels:Array,data:Dictionary,protected:Dictionary,reference:Dictionary={})->Dictionary:
 var ground={};var seen={};var flat_area=0;var largest=0;var tips=0;var tiny=0
 for coord in data.owner:ground[coord]=int(levels[data.owner[coord]])
 for start in ground:
  if seen.has(start):continue
  var queue=[start];seen[start]=true;var cursor=0;var free=0;var above=false;var below=false
  while cursor<queue.size():
   var coord:Vector2i=queue[cursor];cursor+=1
   if not protected.has(coord):free+=1
   for n in Hex.neighbors(coord):
    if not ground.has(n):continue
    if ground[n]>ground[coord]:above=true
    elif ground[n]<ground[coord]:below=true
    elif not seen.has(n):seen[n]=true;queue.append(n)
  if free>=8:flat_area+=free
  if queue.size()<=3 and free>0 and above!=below:tiny+=1
  largest=maxi(largest,free)
 var bands={};var near={}
 var prepared:Dictionary=data.get("_la_quality_windows",{})
 if prepared.is_empty():prepared=_quality_windows(data)
 var coords:Array=prepared.coords;var owners:Array=prepared.owners
 for cells:PackedInt32Array in prepared.windows:
  var best:=13
  for side_rise:int in [-1,0,1]:
   var intercepts:Dictionary={};var at:=0;var minimum:=2147483647;var maximum:=-2147483648
   for y:int in 3:
    for x:int in 4:
     var value:int=int(levels[owners[cells[at]]])-x-side_rise*y;at+=1;intercepts[value]=int(intercepts.get(value,0))+1
     minimum=mini(minimum,value);maximum=maxi(maximum,value)
   var intercept:=0;var count:=0
   for value:int in intercepts:
    if int(intercepts[value])>count:intercept=value;count=int(intercepts[value])
   var max_error:=maxi(absi(minimum-intercept),absi(maximum-intercept))
   if max_error<=1:best=mini(best,12-count)
  if best<=1:
   for cell:int in cells:near[coords[cell]]=true
  if best==0:
   for cell:int in cells:bands[coords[cell]]=true
 for coord in ground:
  if protected.has(coord):continue
  var count=0;var high=0;var low=0
  for other in Hex.neighbors(coord):
   if not ground.has(other):continue
   count+=1
   if ground[other]>ground[coord]:high+=1
   elif ground[other]<ground[coord]:low+=1
  if count>=2 and (high==count or low==count):tips+=1
 var introduced=0;var introduced_near=0
 if not reference.is_empty():
  for coord in bands:
   if not reference._bands.has(coord):introduced+=1
  for coord in near:
   if not reference._near.has(coord):introduced_near+=1
 return {"flat_area":flat_area,"largest_flat":largest,"broad_stair_cells":bands.size(),"near_stair_cells":near.size(),"introduced_stair_cells":introduced,"introduced_near_stair_cells":introduced_near,"tiny_extrema":tiny,"new_tips":tips,"_bands":bands,"_near":near}

static func _summary(quality:Dictionary)->Dictionary:
 var result=quality.duplicate(false);result.erase("_bands");result.erase("_near");return result

static func _tiny_rows(levels:Array,data:Dictionary)->Array:
 # This caller only consumes extrema of at most three cells. Traverse the
 # same topology in the same order, without building discarded large rows.
 var topology:Dictionary=data.get("_rw_cell_topology",{})
 if topology.is_empty():topology=Regions._cell_topology(data)
 var coords:Array=topology.coords;var owners:Array=topology.owners;var neighbors:Array=topology.neighbors
 var elevations:=PackedInt32Array();elevations.resize(coords.size())
 for i:int in coords.size():elevations[i]=int(levels[owners[i]])
 var used:=PackedByteArray();used.resize(coords.size());used.fill(0)
 var result:Array=[]
 for start:int in coords.size():
  if used[start]!=0:continue
  var z:int=elevations[start];var queue:Array[int]=[start];var cursor:int=0
  var above:bool=false;var below:bool=false;used[start]=1
  while cursor<queue.size():
   var here:int=queue[cursor];cursor+=1
   for n:int in neighbors[here]:
    var other:int=elevations[n]
    if other==z:
     if used[n]==0:used[n]=1;queue.append(n)
    elif other>z:above=true
    else:below=true
  if queue.size()>3 or above==below:continue
  var free:bool=false
  for i:int in queue:
   if not data._la_required.has(coords[i]):free=true;break
  if not free:continue
  var cells:Array=[]
  for i:int in queue:cells.append([coords[i].x,coords[i].y])
  result.append({"cells":cells,"level":z,"kind":"peak" if below else "pit","expected_spawn_approach":int(topology.spawn) in queue})
 return result

static func _repair_graph(graph:Array)->Dictionary:
 # Arc ownership stays with the immutable refinement graph for this tidy call.
 var incoming:Array=[];var negative_edges:=0
 for i:int in graph.size():incoming.append([])
 for a:int in graph.size():
  for b:int in graph[a]:
   incoming[b].append(a)
   if int(graph[a][b])<0:negative_edges+=1
 return {"incoming":incoming,"negative_edges":negative_edges}

static func _repair_potential_feasible(levels:Array,forward:Array,reverse:Array)->bool:
 if levels.size()!=forward.size() or levels.size()!=reverse.size():return false
 for a:int in levels.size():
  for b:int in forward[a]:
   if int(levels[b])>int(levels[a])+int(forward[a][b]):return false
  for b:int in reverse[a]:
   if -int(levels[b])>-int(levels[a])+int(reverse[a][b]):return false
 return true

static func _repair_shortest(initial:Array,graph:Array,changed:Array,context:Dictionary,feasible:bool)->Array:
 # A checked feasible starting potential has no negative cycles. Any arc
 # initially violated by a patch touches a changed source or target, so visit
 # changed sites and sources of their incoming arcs before normal propagation.
 # Keep the generic full-queue solver unchanged for every unchecked case.
 if not feasible:return Network._shortest(initial,graph,int(context.negative_edges))
 if changed.is_empty():return initial.duplicate()
 var values:Array=initial.duplicate();var queued:Array=[];var depth:Array=[];var active:Array=[]
 queued.resize(values.size());queued.fill(false);depth.resize(values.size());depth.fill(0);active.resize(values.size());active.fill(false)
 for site:int in changed:
  active[site]=true
  for source:int in context.incoming[site]:active[source]=true
 var queue:Array=[]
 for site:int in values.size():
  if active[site]:queue.append(site);queued[site]=true
 var cursor:=0
 while cursor<queue.size():
  var a:int=queue[cursor];cursor+=1;queued[a]=false
  var row:Dictionary=graph[a]
  for b:int in row:
   var cost:int=row[b];var next:int=int(values[a])+cost
   if next>=int(values[b]):continue
   values[b]=next;depth[b]=int(depth[a])+(1 if cost<0 else 0)
   if depth[b]>int(context.negative_edges):return Network._shortest(initial,graph,int(context.negative_edges))
   if not queued[b]:queue.append(b);queued[b]=true
 return values

static func _tidy_small(initial:Array,graph:Dictionary,data:Dictionary)->Array:
 var levels=initial.duplicate()
 # Both arc arrays remain immutable throughout this local repair search.
 # Count negative arcs once rather than scanning every graph for every patch.
 var forward_context=_repair_graph(graph.forward);var reverse_context=_repair_graph(graph.reverse)
 for pass_index in 6:
  var feasible=_repair_potential_feasible(levels,graph.forward,graph.reverse)
  var rows=_tiny_rows(levels,data);var best=[];var remaining=rows.size();var cost=100000
  for row in rows:
   for grow in [false,true]:
    var patch=levels.duplicate();var value=int(row.level)+((-1 if row.kind=="peak" else 1) if not grow else 0);var sites={}
    for pair in row.cells:sites[int(data.owner[Vector2i(int(pair[0]),int(pair[1]))])]=true
    if grow:
     for site in sites.keys():
      for other in data.edges[site]:
       if absi(int(levels[other])-int(row.level))==1:sites[other]=true
    var changed=[]
    for site in sites:
     if int(patch[site])!=value:changed.append(int(site))
     patch[site]=value
    var lower_change=(row.kind=="peak")!=grow
    if lower_change:patch=_repair_shortest(patch,graph.forward,changed,forward_context,feasible)
    else:
     var negative=[]
     for h in patch:negative.append(-int(h))
     patch=_repair_shortest(negative,graph.reverse,changed,reverse_context,feasible)
     for i in patch.size():patch[i]=-int(patch[i])
    if patch.is_empty():continue
    var valid=true;var movement=0
    for i in patch.size():
     if int(patch[i])<int(graph.lower[i]) or int(patch[i])>int(graph.upper[i]):valid=false;break
     movement+=absi(int(patch[i])-int(levels[i]))
    if not valid:continue
    var count=_tiny_rows(patch,data).size()
    if count<remaining or (count==remaining and count<rows.size() and movement<cost):best=patch;remaining=count;cost=movement
  if best.is_empty():break
  levels=best
 return levels

static func validate_final(planar:Dictionary,data:Dictionary,levels:Array,c:Dictionary,choice:Dictionary)->String:
 var error=Network.validate_final(planar,data,levels,c,choice)
 if not error.is_empty():return error
 var report:Dictionary=choice.articulation
 if int(levels.min())!=int(report.range_before[0]) or int(levels.max())!=int(report.range_before[1]):return "Local articulation changed the original network height range"
 if _physical_ascent_witness(levels,data).size()-1<int(report.ascent_before):return "Local articulation reduced the original cumulative ascent"
 for site in report.witness_groups:
  if int(levels[site])!=int(choice.levels[site]):return "Outer fit changed a preserved local-articulation ascent witness"
 for row in choice.network.relations:
  if row.tier=="primary" and Network._median(row.high,levels)-Network._median(row.low,levels)!=int(row.actual_gap):return "Local articulation changed a primary realized wall gap"
 return ""

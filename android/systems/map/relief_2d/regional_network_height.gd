extends RefCounted
## A jointly solved regional height graph on the unchanged original map.
## Regional variables carry broad cores; negative difference arcs encode real
## high/low relations. The bounded queue solver supports those negative arcs.
const Hex=preload("res://systems/map/hex_coord.gd")
const Fit=preload("res://systems/map/relief_2d/contour_height.gd")
const Citadel=preload("res://systems/map/relief_2d/citadel_height.gd")
const Regions=preload("res://systems/map/relief_2d/region_walls_height.gd")
const Features=preload("res://systems/map/relief_2d/regional_features_height.gd")
const Wall=preload("res://systems/map/relief_2d/region_wall_profile.gd")
const VERSION="joint-regional-height-network-v1"
const CANDIDATES=6
const MAX_RELATIONS=6

static func select(planar:Dictionary,original:Dictionary,c:Dictionary,seed_value:int,measure:Callable)->Dictionary:
 if c.quantum>.25:return {"error":"regional_network requires quantum<=.25 for the current opaque actor"}
 var data=original.duplicate(false);data._rw_cell_topology=Regions._cell_topology(data)
 var budget=maxi(1,ceili(c.amplitude_levels*3.0))
 if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
 var owners={};var nodes=[];var points=[]
 for node in planar.nodes:
  for pair in node.footprint:owners[Vector2i(int(pair[0]),int(pair[1]))]=str(node.id)
 data._rf_owners=owners
 for group in data.groups:
  var point=Vector2.ZERO
  for coord in group:point+=Hex.to_plane(coord,1)
  points.append(point/group.size())
 var ordered=planar.nodes.duplicate();ordered.sort_custom(func(a,b):return str(a.id)<str(b.id))
 for node in ordered:
  var coord=Vector2i(int(node.coord[0]),int(node.coord[1]));var core=[int(data.owner[coord])]
  var support=Features._regional_patch(core,str(node.id),1,data)
  nodes.append({"id":str(node.id),"coord":node.coord,"group":core[0],"core":core,"support":support,"point":Hex.to_plane(coord,1),"distance":_bfs(core,data.edges)})
 var index={}
 for i in nodes.size():index[nodes[i].id]=i
 var side=Wall.sides(planar,data);var base=Wall.geometry(planar,data,c,budget,side)
 # These three callers read the same immutable base.forward. Share already
 # computed source distances across their historical cache namespaces.
 var cache={};var bands=Regions._bands(side,data,owners,base.forward,cache)
 _alias_distances(cache,"out","expanded_out")
 bands=Features._deduplicate_bands(bands,data,owners,base.forward,cache)
 _alias_distances(cache,"expanded_out","network_capacity")
 var available=_relations(bands,nodes,index,data,base,cache,side)
 available=_filled_capacities(available,planar,data,c,budget,side,base)
 var plane_windows=_plane_windows(data)
 var diagnostics=[];var best={};var joint_cache={}
 for variant in CANDIDATES:
  var authored=_assignment(nodes,data,c,seed_value,variant)
  var proposed=_choose(available,nodes,index,authored.values,seed_value,variant,c)
  var secondary=proposed.filter(func(e):return e.tier=="secondary")
  proposed=proposed.filter(func(e):return e.tier=="primary")
  var candidate={};var attempts=[]
  for target_gap in [14,10,7]:
   var wanted=proposed.duplicate(true)
   for edge in wanted:
    edge.gap=(4 if target_gap>=14 else (3 if target_gap>=10 else 2)) if edge.tier=="secondary" else mini(target_gap,maxi(7,int(edge.capacity)-3))
   var fit=_joint(planar,data,c,budget,side,base,nodes,index,wanted,joint_cache)
   attempts.append({"gap":target_gap,"relations":wanted.size(),"feasible":fit.get("feasible",false),"reason":fit.get("reason","")})
   if fit.get("feasible",false):candidate=fit;candidate.relations=wanted;break
  # Reassign an incompatible skeleton. Every leave-one-out subgraph can
  # recover the original 14/10-level goal; removal is not a forced downgrade.
  if candidate.is_empty():
   for target_gap in [14,10,7]:
    for removed_offset in proposed.size():
     var removed=(removed_offset+variant)%proposed.size();var wanted=[]
     for i in proposed.size():
      if i!=removed:wanted.append(proposed[i].duplicate(true))
     for edge in wanted:edge.gap=mini(target_gap,maxi(7,int(edge.capacity)-3))
     var fit=_joint(planar,data,c,budget,side,base,nodes,index,wanted,joint_cache)
     attempts.append({"gap":target_gap,"removed_pair":_edge_key(proposed[removed]),"relations":wanted.size(),"feasible":fit.get("feasible",false),"reason":fit.get("reason","")})
     if fit.get("feasible",false):candidate=fit;candidate.relations=wanted;break
    if not candidate.is_empty():break
  if candidate.is_empty() and proposed.size()>2:
   for target_gap in [10,7]:
    for removal_variant in 2:
     var a=(variant+removal_variant)%proposed.size();var b=(a+1+removal_variant)%proposed.size();var wanted=[]
     for i in proposed.size():
      if i!=a and i!=b:wanted.append(proposed[i].duplicate(true))
     for edge in wanted:edge.gap=mini(target_gap,maxi(7,int(edge.capacity)-3))
     var fit=_joint(planar,data,c,budget,side,base,nodes,index,wanted,joint_cache)
     attempts.append({"gap":target_gap,"removed_two_pairs":[_edge_key(proposed[a]),_edge_key(proposed[b])],"relations":wanted.size(),"feasible":fit.get("feasible",false),"reason":fit.get("reason","")})
     if fit.get("feasible",false):candidate=fit;candidate.relations=wanted;break
    if not candidate.is_empty():break
  if candidate.is_empty():
   var limited=_joint(planar,data,c,budget,side,base,nodes,index,[],joint_cache)
   attempts.append({"status":"explicit_limited_regional_network_without_major_edges","feasible":limited.get("feasible",false),"reason":limited.get("reason","")})
   if limited.get("feasible",false):candidate=limited;candidate.relations=[]
   else:diagnostics.append({"variant":variant,"status":"joint_assignment_rejected","attempts":attempts});continue
  candidate=_extend_secondary(candidate,secondary,nodes,index,data)
  var regional_targets=[]
  for i in data.groups.size():regional_targets.append(clampf(_macro_value(i,nodes,authored.values,variant),candidate.lower[i],candidate.upper[i]))
  regional_targets.append_array(authored.values)
  var coarse=_project(regional_targets,candidate)
  if coarse.is_empty():continue
  var region_values=[]
  for i in nodes.size():region_values.append(int(coarse[data.groups.size()+i]))
  var targets=_field(nodes,region_values,data,c,seed_value,variant)
  targets.append_array(region_values)
  var levels=_project(targets,candidate)
  if levels.is_empty():continue
  levels=_optimize(levels,targets,candidate,10)
  var all_levels=levels.duplicate();levels=levels.slice(0,data.groups.size())
  var local=_metrics(levels,candidate.relations,nodes,index,data,owners,points,all_levels)
  local.merge(_plane_metrics(levels,plane_windows,data,c),true)
  var measured:Dictionary=measure.call(levels)
  var small=Regions._small_components(levels,data);var tips=Regions._tip_sites(levels,data)
  var score=12.0*mini(4,int(local.realized_relations))+2.0*maxi(0,int(local.realized_relations)-4)+4.0*local.wall_relations+1.5*local.covered_regions+1.2*local.secondary_realized+1.0*local.regional_detrended_span+.1*measured.level_span-75.0*local.local_plane_ratio-45.0*local.worst_bin_plane_ratio-40.0*local.local_plane_component_ratio-15.0*local.near_flat_ratio-.6*tips.size()-1.5*small.unexpected_small_extrema
  diagnostics.append({"variant":variant,"status":"candidate","attempts":attempts,"realized_relations":local.realized_relations,"wall_relations":local.wall_relations,"route_relations":local.route_relations,"covered_regions":local.covered_regions,"near_flat_ratio":local.near_flat_ratio,"local_plane_ratio":local.local_plane_ratio,"worst_bin_plane_ratio":local.worst_bin_plane_ratio,"secondary_realized":local.secondary_realized,"regional_detrended_span":local.regional_detrended_span,"score":score})
  if best.is_empty() or score>best.score:
   var selected=candidate.selected;var records=[];var covered={}
   for edge in candidate.relations:
    var row=edge.duplicate(true)
    row.low_level=int(all_levels[data.groups.size()+int(index[row.low_id])]);row.high_level=int(all_levels[data.groups.size()+int(index[row.high_id])])
    row.actual_gap=_median(row.high,levels)-_median(row.low,levels)
    row.support_radius=1;records.append(row)
    if row.tier=="primary":covered[row.low_id]=true;covered[row.high_id]=true
   var region_records=[];var unsupported=[]
   for i in nodes.size():
    var row=nodes[i];var value=int(all_levels[data.groups.size()+i])
    region_records.append({"id":row.id,"level":value,"groups":row.core,"support_groups":row.support,"coord":row.coord,"relation_supported":covered.has(row.id),"profile":"regional-core-with-canonical-neighbor-path-curves"})
    if not covered.has(row.id):unsupported.append(row.id)
   var limits=[]
   if local.realized_relations<4:limits.append("fewer_than_four_jointly_realized_relations")
   if not unsupported.is_empty():limits.append("some_regions_have_coherent_core_but_no_selected_major_relation")
   if tips.size()>0:limits.append("remaining_one_level_tips")
   best={"levels":levels,"targets":targets.slice(0,data.groups.size()),"profile":"regional_network_%d"%variant,"score":score,"selected_walls":selected,"local":local,"candidate_count":CANDIDATES,"network":{"status":"network_candidate" if local.realized_relations>=4 else "limited_network_candidate","relations":records,"regions":region_records,"covered_regions":local.covered_regions,"total_regions":nodes.size(),"unsupported_regions":unsupported,"realized_relations":local.realized_relations,"secondary_realized":local.secondary_realized,"wall_relations":local.wall_relations,"route_relations":local.route_relations,"available_wall_relations":available.filter(func(e):return e.kind=="wall").size(),"available_route_relations":available.filter(func(e):return e.kind=="route").size(),"selected_wall_count":selected.size(),"selected_wall_arcs":candidate.wall_arcs,"boss_level":candidate.boss_level,"feature_centers":authored.centers,"field":"joint-regional-graph-with-nonlinear-path-profiles","spawn_policy":"fixed_baseline_no_global_monotonic_spine","limitations":limits,"near_flat_ratio":local.near_flat_ratio,"local_plane_ratio":local.local_plane_ratio,"worst_bin_plane_ratio":local.worst_bin_plane_ratio,"local_plane_component_ratio":local.local_plane_component_ratio,"plane_bins":local.plane_bins,"tips":tips.map(func(i):return [data.groups[i][0].x,data.groups[i][0].y])}}
 if best.is_empty():return {"error":"regional_network exhausted its bounded joint assignments; no coherent network satisfied the supplied anchors"}
 best.candidates=diagnostics
 return best

static func _relations(bands:Array,nodes:Array,index:Dictionary,data:Dictionary,base:Dictionary,cache:Dictionary,side:Dictionary)->Array:
 var result=[];var nearest=[];var pairs={}
 for band in bands:
  if band.capacity<8:continue
  var row=band.duplicate(true);row.kind="wall";row.path=[];result.append(row)
 # The geodesic Voronoi interface is a real physical connection, not a
 # guessed screen neighbor. It includes corridor cells with no node owner.
 for site in data.groups.size():
  var chosen=0;var distance=100000
  for i in nodes.size():
   if int(nodes[i].distance[site])<distance:distance=int(nodes[i].distance[site]);chosen=i
  nearest.append(chosen)
 result.append_array(_boundary_bands(side,nearest,nodes,data,base.forward,cache,bands))
 for site in data.edges.size():
  for n in data.edges[site]:
   var a=int(nearest[site]);var b=int(nearest[n])
   if a==b:continue
   var key="%d:%d"%[mini(a,b),maxi(a,b)];pairs[key]=[mini(a,b),maxi(a,b)]
 for pair in pairs.values():
  for flip in 2:
   var a=int(pair[flip]);var b=int(pair[1-flip]);var low=nodes[a];var high=nodes[b]
   var capacity=100000
   for site in low.core:
    var distances=Fit._distance(site,base.forward,cache,"network_capacity")
    for other in high.core:capacity=mini(capacity,int(distances[other]))
   if capacity<3:continue
   var path=_path(low.group,high.group,data.edges)
   if path.size()<4:continue
   result.append({"low_id":low.id,"high_id":high.id,"low":low.core,"high":high.core,"low_cells":_cells(low.core,data),"high_cells":_cells(high.core,data),"walls":[],"kind":"route","capacity":capacity,"path":path.map(func(i):var p:Vector2i=data.groups[i][0];return [p.x,p.y]),"patch_source":"original-region-cores-joined-by-physical-ground-path"})
 return result

static func _boundary_bands(side:Dictionary,nearest:Array,nodes:Array,data:Dictionary,forward:Array,cache:Dictionary,old:Array)->Array:
 var bins={};var used={};var result=[]
 # Short real boundary windows compete with old windows of the same owners.
 # Only exact geometric duplicates are removed during final selection.
 for w:Vector2i in side:
  var by_region={}
  for site in side[w].groups:
   var region=int(nearest[site])
   if not by_region.has(region):by_region[region]=[]
   by_region[region].append(int(site))
  for a in by_region:
   for b in by_region:
    if a==b:continue
    var low_id=str(nodes[a].id);var high_id=str(nodes[b].id)
    var key=low_id+">"+high_id
    # Opposite actual ground sides of an existing wall, including corridor
    # cells omitted by the old footprint-only, three-wall-window grammar.
    var across=false;var wall_point=Hex.to_plane(w,1)
    for sa in by_region[a]:
     for sb in by_region[b]:
      var pa=Hex.to_plane(data.groups[sa][0],1)-wall_point;var pb=Hex.to_plane(data.groups[sb][0],1)-wall_point
      if pa.length()>.01 and pb.length()>.01 and pa.normalized().dot(pb.normalized())<.25:across=true
    if not across:continue
    if not bins.has(key):bins[key]={"low_id":low_id,"high_id":high_id,"a":a,"b":b,"walls":{}}
    bins[key].walls[w]=true
 for key in bins:
  var row=bins[key];var visited={};var best={}
  for start in row.walls:
   if visited.has(start):continue
   var walls=[start];var cursor=0;visited[start]=true
   while cursor<walls.size():
    var w:Vector2i=walls[cursor];cursor+=1
    for n in Hex.neighbors(w):
     if row.walls.has(n) and not visited.has(n):visited[n]=true;walls.append(n)
   for root in walls:
    for radius in [0,1]:
     var window=[root]
     if radius==1:
      for n in Hex.neighbors(root):
       if row.walls.has(n):window.append(n)
     var patches={"low":{},"high":{}}
     for w in window:
      for site in side[w].direct_groups:
       if nearest[site]==row.a:patches.low[site]=true
       elif nearest[site]==row.b:patches.high[site]=true
     if patches.low.is_empty() or patches.high.is_empty():continue
     for role in ["low","high"]:
      var region=int(row.a if role=="low" else row.b);var seeds=patches[role].keys()
      for site in seeds:
       for n in data.edges[site]:
        if nearest[n]==region:patches[role][n]=true
     if _cells(patches.low.keys(),data)<3 or _cells(patches.high.keys(),data)<3:continue
     # Every physical edge is also a forward arc of cost <=1. A physical
     # path of at most eight edges proves capacity<9, so this window would
     # be discarded by the full shortest-distance calculation below.
     if _physical_path_within(patches.low,patches.high,data.edges,8):continue
     var capacity=100000
     for site in patches.low:
      var d=Fit._distance(site,forward,cache,"network_capacity")
      for other in patches.high:capacity=mini(capacity,int(d[other]))
     if capacity<9:continue
     var entry={"low_id":row.low_id,"high_id":row.high_id,"low":patches.low.keys(),"high":patches.high.keys(),"low_cells":_cells(patches.low.keys(),data),"high_cells":_cells(patches.high.keys(),data),"walls":window.map(func(p):return [p.x,p.y]),"kind":"wall","capacity":capacity,"path":[],"patch_source":"opposite-original-wall-sides-expanded-inside-physical-region-voronoi"}
     if best.is_empty() or entry.capacity+.3*entry.walls.size()>best.capacity+.3*best.walls.size():best=entry
  if not best.is_empty():result.append(best)
 return result

static func _physical_path_within(low:Dictionary,high:Dictionary,edges:Array,steps:int)->bool:
 var queue:Array=low.keys();var seen:Dictionary=low.duplicate()
 for site:int in queue:
  if high.has(site):return true
 var cursor:=0;var layer_end:int=queue.size()
 for depth:int in steps:
  while cursor<layer_end:
   var site:int=queue[cursor];cursor+=1
   for other:int in edges[site]:
    if seen.has(other):continue
    if high.has(other):return true
    seen[other]=true;queue.append(other)
  layer_end=queue.size()
  if cursor==layer_end:break
 return false

static func _filled_capacities(available:Array,planar:Dictionary,data:Dictionary,c:Dictionary,budget:int,side:Dictionary,base:Dictionary)->Array:
 var result=[];var seen={}
 for entry in available:
  if entry.kind!="wall":result.append(entry);continue
  var selected={};var keys=[]
  for pair in entry.walls:
   var coord=Vector2i(int(pair[0]),int(pair[1]));selected[coord]=true;keys.append("%d,%d"%[coord.x,coord.y])
  keys.sort();var identity=str(entry.low_id)+">"+str(entry.high_id)+":"+";".join(keys)
  if seen.has(identity):continue
  seen[identity]=true
  var geometry=Wall.geometry(planar,data,c,budget,side,selected,base)
  var initial=[];initial.resize(data.groups.size());initial.fill(100000)
  for site in entry.low:initial[site]=0
  var distance=_shortest(initial,geometry.forward);var capacity=100000
  for site in entry.high:capacity=mini(capacity,int(distance[site]))
  if capacity<7:continue
  var row=entry.duplicate(true);row.capacity=capacity;row.capacity_scope="whole_patch_with_own_opaque_filled_wall_geometry";result.append(row)
 return result

static func _extend_secondary(initial:Dictionary,proposed:Array,nodes:Array,index:Dictionary,data:Dictionary)->Dictionary:
 var candidate=initial;var accepted=candidate.relations.duplicate();var used={}
 # Every trial adds one arc to this candidate's private transpose graphs.
 # Restore a rejected arc in place; copying every unrelated row is redundant.
 var negative_edges=_negative_edge_count(candidate.forward)
 for row in accepted:used[_edge_key(row)]=true
 for proposed_edge in proposed:
  if used.has(_edge_key(proposed_edge)):continue
  var accepted_edge={}
  for flip in 2:
   var edge=proposed_edge.duplicate(true)
   if flip==1:
    var swap=edge.low_id;edge.low_id=edge.high_id;edge.high_id=swap
    swap=edge.low;edge.low=edge.high;edge.high=swap
    swap=edge.low_cells;edge.low_cells=edge.high_cells;edge.high_cells=swap
    edge.path.reverse()
    edge.capacity=edge.get("reverse_capacity",edge.capacity)
   for gap in [5,4,3]:
    var gf:Array=candidate.forward;var gr:Array=candidate.reverse
    var a:int=data.groups.size()+int(index[edge.high_id]);var b:int=data.groups.size()+int(index[edge.low_id])
    var cost:int=-gap
    # h[b] <= h[a]+cost cannot fit the already closed interval box.
    if int(candidate.lower[b])>int(candidate.upper[a])+cost:continue
    # Both extremal feasible potentials already satisfy this new arc. Their
    # forward / reverse closures therefore remain exactly unchanged.
    var unchanged:bool=int(candidate.upper[b])<=int(candidate.upper[a])+cost and int(candidate.lower[b])<=int(candidate.lower[a])+cost
    var had_arc:bool=gf[a].has(b);var previous:int=int(gf[a].get(b,0))
    Citadel._arc(gf,gr,a,b,cost)
    var trial_negative_edges:int=negative_edges+int(gf[a].has(b) and int(gf[a][b])<0)-int(had_arc and previous<0)
    var closed:Dictionary={"lower":candidate.lower,"upper":candidate.upper,"feasible":true} if unchanged else _close(candidate.lower,candidate.upper,gf,gr,trial_negative_edges)
    if not closed.feasible:
     if had_arc:gf[a][b]=previous;gr[b][a]=previous
     else:gf[a].erase(b);gr[b].erase(a)
     continue
    edge.gap=gap;accepted_edge=edge;candidate.lower=closed.lower;candidate.upper=closed.upper;negative_edges=trial_negative_edges;break
   if not accepted_edge.is_empty():break
  if not accepted_edge.is_empty():accepted.append(accepted_edge);used[_edge_key(accepted_edge)]=true
 candidate.relations=accepted
 return candidate

static func _assignment(nodes:Array,data:Dictionary,c:Dictionary,seed_value:int,variant:int)->Dictionary:
 # Farthest-point graph placement gives spatially separated feature masses.
 # Every regional target is derived from these broad coherent controls.
 var eligible=[]
 for i in nodes.size():
  if _cells(nodes[i].support,data)>=5:eligible.append(i)
 if eligible.is_empty():eligible=range(nodes.size())
 var centers=[];var start=eligible[int(floor(Fit._unit_hash(seed_value,variant,43,1001)*eligible.size()))%eligible.size()];centers.append(start)
 for count in mini(5,eligible.size()-1):
  var best=-1;var score=-INF
  for i in eligible:
   if i in centers:continue
   var distance=100000
   for center in centers:distance=mini(distance,int(nodes[center].distance[nodes[i].group]))
   var value=float(distance)+.5*Fit._unit_hash(seed_value,variant,i,1003)
   if value>score:score=value;best=i
  centers.append(best)
 var controls=[];var reports=[]
 for i in centers.size():
  var polarity=1 if variant%2==0 else -1
  if i>0:
   var nearest=0;var distance=100000
   for j in i:
    var d=int(nodes[centers[j]].distance[nodes[centers[i]].group])
    if d<distance:distance=d;nearest=j
   polarity=-1 if int(controls[nearest])>c.baseline_level else 1
  var level=c.baseline_level+polarity*maxi(1,roundi(c.amplitude_levels*(2.15+.45*Fit._unit_hash(seed_value,variant,i,1007))))
  controls.append(level);reports.append({"id":nodes[centers[i]].id,"role":"ridge" if polarity>0 else "court","target_level":level})
 var values=[]
 for i in nodes.size():
  var chosen=0;var distance=100000
  for j in centers.size():
   var d=int(nodes[centers[j]].distance[nodes[i].group])
   if d<distance:distance=d;chosen=j
  var control=int(controls[chosen]);var polarity=1 if control>c.baseline_level else -1
  var t=float(distance);var falloff=.48*t+.30*sin(t*.43)
  values.append(clampi(roundi(control-polarity*falloff),c.baseline_level-ceili(c.amplitude_levels*3),c.baseline_level+ceili(c.amplitude_levels*3)))
 return {"values":values,"centers":reports}

static func _choose(available:Array,nodes:Array,index:Dictionary,values:Array,seed_value:int,variant:int,c:Dictionary)->Array:
 var chosen=[];var used_pairs={};var used_walls={};var coverage={};var wall_count=0
 for slot in MAX_RELATIONS:
  var best={};var score=-INF
  for i in available.size():
   var edge=available[i]
   if (c.boss_mode=="highest" and str(edge.low_id).begins_with("boss-")) or (c.boss_mode=="lowest" and str(edge.high_id).begins_with("boss-")):continue
   if edge.capacity<9 or (edge.kind=="route" and edge.path.size()<14):continue
   var key=_edge_key(edge)
   if used_pairs.has(key):continue
   var overlap=false
   for p in edge.walls:
    if used_walls.has(Vector2i(int(p[0]),int(p[1]))):overlap=true;break
   if overlap:continue
   var fresh=int(not coverage.has(edge.low_id))+int(not coverage.has(edge.high_id))
   var spread=0.0
   if not chosen.is_empty():
    spread=100000.0;var point:Vector2=(nodes[index[edge.low_id]].point+nodes[index[edge.high_id]].point)*.5
    for row in chosen:
     var center:Vector2=(nodes[index[row.low_id]].point+nodes[index[row.high_id]].point)*.5
     spread=minf(spread,point.distance_to(center))
   var signed=int(values[index[edge.high_id]])-int(values[index[edge.low_id]])
   var value=12.0*fresh+.4*minf(25,spread)+.25*clampi(signed,-20,20)+.25*mini(30,int(edge.capacity))
   if edge.kind=="wall":value+=30.0 if wall_count<4 else 12.0
   value+=.3*Fit._unit_hash(seed_value,variant,i,1013)
   if value>score:score=value;best=edge
  if best.is_empty():break
  var edge=best.duplicate(true);edge.tier="primary";chosen.append(edge);used_pairs[_edge_key(edge)]=true
  for p in edge.walls:used_walls[Vector2i(int(p[0]),int(p[1]))]=true
  coverage[edge.low_id]=true;coverage[edge.high_id]=true
  if edge.kind=="wall":wall_count+=1
 # Moderate relations cover the regional connection graph as well. All are
 # chosen before the joint solve; no sequential absolute-height anchoring.
 var secondary_coverage={}
 for slot in mini(12,nodes.size()):
  var best={};var score=-INF
  for i in available.size():
   var edge=available[i]
   if edge.kind!="route" or edge.capacity<3 or used_pairs.has(_edge_key(edge)):continue
   var signed=int(values[index[edge.high_id]])-int(values[index[edge.low_id]])
   if signed<1:continue
   var fresh=int(not secondary_coverage.has(edge.low_id))+int(not secondary_coverage.has(edge.high_id))
   var unsupported=int(not coverage.has(edge.low_id))+int(not coverage.has(edge.high_id))
   var value=18.0*fresh+5.0*unsupported+.25*mini(20,signed)+.12*mini(20,int(edge.capacity))+.3*Fit._unit_hash(seed_value,variant,i,1019)
   if value>score:score=value;best=edge
  if best.is_empty():break
  var edge=best.duplicate(true);edge.tier="secondary"
  for reverse in available:
   if reverse.kind=="route" and reverse.low_id==edge.high_id and reverse.high_id==edge.low_id:edge.reverse_capacity=reverse.capacity;break
  chosen.append(edge);used_pairs[_edge_key(edge)]=true
  secondary_coverage[edge.low_id]=true;secondary_coverage[edge.high_id]=true
 return chosen

static func _edge_key(edge:Dictionary)->String:
 return str(edge.low_id)+":"+str(edge.high_id) if str(edge.low_id)<str(edge.high_id) else str(edge.high_id)+":"+str(edge.low_id)

static func _joint(planar:Dictionary,data:Dictionary,c:Dictionary,budget:int,side:Dictionary,base:Dictionary,nodes:Array,index:Dictionary,relations:Array,cache:Dictionary)->Dictionary:
 var specs=[]
 for edge in relations:specs.append(JSON.stringify([edge.low_id,edge.high_id,edge.low,edge.high,edge.walls]))
 specs.sort();var key=";".join(specs)
 if not cache.has(key):
  var selected={}
  for edge in relations:
   for p in edge.walls:selected[Vector2i(int(p[0]),int(p[1]))]=true
  var geometry=Wall.geometry(planar,data,c,budget,side,selected,base)
  var original=Features._base_bounds(data,c,budget,geometry)
  if original.has("error"):return {"feasible":false,"reason":original.error}
  var gf:Array=geometry.forward;var gr:Array=geometry.reverse;var lower:Array=original.lower.duplicate();var upper:Array=original.upper.duplicate();var count=data.groups.size()
  for i in nodes.size():gf.append({});gr.append({});lower.append(c.baseline_level-budget);upper.append(c.baseline_level+budget)
  for i in nodes.size():
   for site in nodes[i].core:_pair(gf,gr,count+i,int(site),1)
   for site in nodes[i].support:_pair(gf,gr,count+i,int(site),2)
  for edge in relations:
   for role in ["low","high"]:
    var regional=count+int(index[edge[role+"_id"]])
    for site in edge[role]:_pair(gf,gr,regional,int(site),1)
    for site in Features._regional_patch(edge[role],str(edge[role+"_id"]),1,data):_pair(gf,gr,regional,int(site),2)
  cache[key]={"forward":gf,"reverse":gr,"lower":lower,"upper":upper,"selected":selected,"wall_arcs":geometry.wall_arcs,"boss_level":original.boss_level}
 var template:Dictionary=cache[key]
 if not relations.is_empty():
  # This graph contains only physical/visibility/support nonnegative arcs.
  # Cache its closed anchor intervals for rejection only. Keep the original
  # template bounds below so every remaining solve has identical inputs.
  if not template.has("_anchor_probe"):
   template._anchor_probe=_close(template.lower,template.upper,template.forward,template.reverse,0)
  var probe:Dictionary=template._anchor_probe
  if not probe.feasible:return {"feasible":false,"reason":"joint_regional_relations_exceed_physical_wall_or_anchor_capacity"}
  for edge in relations:
   var a:int=data.groups.size()+int(index[edge.high_id]);var b:int=data.groups.size()+int(index[edge.low_id])
   if int(probe.lower[b])>int(probe.upper[a])-int(edge.gap):return {"feasible":false,"reason":"joint_regional_relations_exceed_physical_wall_or_anchor_capacity"}
 # All following graph writes are between appended regional nodes. Ground
 # dictionaries remain immutable through solve, secondary trials and refine.
 var gf:Array=template.forward.duplicate();var gr:Array=template.reverse.duplicate()
 for site:int in range(data.groups.size(),gf.size()):gf[site]=gf[site].duplicate();gr[site]=gr[site].duplicate()
 for edge in relations:
  Citadel._arc(gf,gr,data.groups.size()+int(index[edge.high_id]),data.groups.size()+int(index[edge.low_id]),-int(edge.gap))
 var closed=_close(template.lower,template.upper,gf,gr)
 if not closed.feasible:return {"feasible":false,"reason":"joint_regional_relations_exceed_physical_wall_or_anchor_capacity"}
 closed.forward=gf;closed.reverse=gr;closed.selected=template.selected;closed.wall_arcs=template.wall_arcs;closed.boss_level=template.boss_level
 return closed

static func _pair(gf:Array,gr:Array,a:int,b:int,cost:int):
 Citadel._arc(gf,gr,a,b,cost);Citadel._arc(gf,gr,b,a,cost)

static func _alias_distances(cache:Dictionary,source:String,destination:String):
 for key:String in cache.keys():
  if key.begins_with(source):cache[destination+key.substr(source.length())]=cache[key]

static func _negative_edge_count(graph:Array)->int:
 var count:=0
 for row:Dictionary in graph:
  for cost:int in row.values():
   if cost<0:count+=1
 return count

static func _shortest(initial:Array,graph:Array,negative_edges:int=-1)->Array:
 var values:Array=initial.duplicate();var queue:Array=[];var in_queue:Array=[];var depth:Array=[]
 if negative_edges<0:negative_edges=_negative_edge_count(graph)
 for i:int in values.size():queue.append(i);in_queue.append(true);depth.append(0)
 var cursor:=0
 while cursor<queue.size():
  var a:int=queue[cursor];cursor+=1;in_queue[a]=false
  var row:Dictionary=graph[a]
  for b:int in row:
   var cost:int=row[b];var next:int=int(values[a])+cost
   if next>=int(values[b]):continue
   values[b]=next;depth[b]=int(depth[a])+(1 if cost<0 else 0)
   # Preserve the original queue, relaxation order, and negative-cycle test.
   if depth[b]>negative_edges:return []
   if not in_queue[b]:queue.append(b);in_queue[b]=true
 return values

static func _close(lower:Array,upper:Array,gf:Array,gr:Array,negative_edges:int=-1)->Dictionary:
 var hi=_shortest(upper,gf,negative_edges)
 if hi.is_empty():return {"feasible":false}
 var negative=[]
 for value in lower:negative.append(-int(value))
 var lo=_shortest(negative,gr,negative_edges)
 if hi.is_empty() or lo.is_empty():return {"feasible":false}
 for i in lo.size():
  lo[i]=-int(lo[i])
  if int(lo[i])>int(hi[i]):return {"feasible":false}
 return {"lower":lo,"upper":hi,"feasible":true}

static func _project(targets:Array,bounds:Dictionary)->Array:
 var bounded=[]
 for i in targets.size():bounded.append(clampi(roundi(targets[i]),int(bounds.lower[i]),int(bounds.upper[i])))
 var hi=_shortest(bounded,bounds.forward)
 if hi.is_empty():return []
 var negative=[]
 for value in bounded:negative.append(-int(value))
 var lo=_shortest(negative,bounds.reverse)
 if hi.is_empty() or lo.is_empty():return []
 var levels=[]
 for i in bounded.size():levels.append(floori((float(hi[i])-float(lo[i]))*.5+.5))
 return levels

static func _optimize(initial:Array,targets:Array,bounds:Dictionary,passes:int)->Array:
 var levels=initial.duplicate()
 for pass_index in passes:
  var changed=false
  for offset in levels.size():
   var i=offset if pass_index%2==0 else levels.size()-1-offset
   var low=int(bounds.lower[i]);var high=int(bounds.upper[i])
   for b in bounds.forward[i]:low=maxi(low,int(levels[b])-int(bounds.forward[i][b]))
   for a in bounds.reverse[i]:high=mini(high,int(levels[a])+int(bounds.reverse[i][a]))
   var chosen=clampi(roundi(targets[i]),low,high)
   if chosen!=int(levels[i]):levels[i]=chosen;changed=true
  if not changed:break
 return levels

static func _macro_value(site:int,nodes:Array,values:Array,variant:int)->float:
 var chosen=0;var distance=100000
 for i in nodes.size():
  var d=int(nodes[i].distance[site])
  if d<distance:distance=d;chosen=i
 var direction=1.0 if (chosen+variant)%2==0 else -1.0
 return float(values[chosen])+direction*.35*float(distance)

static func _field(nodes:Array,values:Array,data:Dictionary,c:Dictionary,seed_value:int,variant:int)->Array:
 var result=[]
 for site in data.groups.size():
  var first=-1;var second=-1;var d1=100000;var d2=100000
  for i in nodes.size():
   var d=int(nodes[i].distance[site])
   if d<d1:second=first;d2=d1;first=i;d1=d
   elif d<d2:second=i;d2=d
  if first>second:
   var swap=first;first=second;second=swap;swap=d1;d1=d2;d2=swap
  var length=maxi(1,int(nodes[first].distance[nodes[second].group]))
  var t=clampf(float(d1-d2+length)/(2.0*length),0,1)
  var kind=(mini(first,second)+maxi(first,second)+variant)%3
  var shaped=t
  if kind==0:shaped=t*t*(3.0-2.0*t)
  elif kind==1:
   if t<.32:shaped=.40*_smooth(t/.32)
   elif t<.58:shaped=.40+.08*(t-.32)/.26
   else:shaped=.48+.52*_smooth((t-.58)/.42)
  else:shaped=t+.13*sin(t*PI)
  var value=lerpf(float(values[first]),float(values[second]),shaped)
  # Shoulder width belongs to actual regional cores; coherent low-frequency
  # rounding varies by connection, with no independent per-cell noise.
  var branch=maxf(0.0,float(d1+d2-length)*.5)
  var sign_value=1.0 if (first+variant)%2==0 else -1.0
  value+=sign_value*.45*sin(branch*.48)
  result.append(value)
 return result

static func _metrics(levels:Array,relations:Array,nodes:Array,index:Dictionary,data:Dictionary,owners:Dictionary,points:Array,all_levels:Array)->Dictionary:
 var result=Features._feature_metrics(levels,relations,points,data,owners)
 var covered={};var realized=0;var wall=0;var route=0;var secondary=0
 for edge in relations:
  var gap=_median(edge.high,levels)-_median(edge.low,levels)
  if edge.tier=="secondary":
   if gap>=2:secondary+=1
   continue
  if gap<5:continue
  realized+=1;covered[edge.low_id]=true;covered[edge.high_id]=true
  if edge.kind=="wall":wall+=1
  else:route+=1
 result.secondary_realized=secondary;result.realized_relations=realized;result.wall_relations=wall;result.route_relations=route;result.covered_regions=covered.size()
 var largest=0
 for base in range(int(levels.min()),int(levels.max())+1):
  var visited={}
  for start in levels.size():
   if visited.has(start) or int(levels[start])<base or int(levels[start])>base+2:continue
   var queue=[start];visited[start]=true;var cells=0;var cursor=0
   while cursor<queue.size():
    var a=int(queue[cursor]);cursor+=1;cells+=data.groups[a].size()
    for b in data.edges[a]:
     if not visited.has(b) and int(levels[b])>=base and int(levels[b])<=base+2:visited[b]=true;queue.append(b)
   largest=maxi(largest,cells)
 result.near_flat_cells=largest;result.near_flat_ratio=float(largest)/maxi(1,data.owner.size())
 return result

static func validate_final(planar:Dictionary,data:Dictionary,levels:Array,c:Dictionary,choice:Dictionary)->String:
 var budget=maxi(1,ceili(c.amplitude_levels*3.0))
 if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
 var geometry=Wall.geometry(planar,data,c,budget,Wall.sides(planar,data),choice.get("selected_walls",{}))
 for a in geometry.forward.size():
  for b in geometry.forward[a]:
   if int(levels[b])-int(levels[a])>int(geometry.forward[a][b]):return "Final regional_network violated a physical/opaque-wall arc"
 var owners={}
 for node in planar.nodes:
  for p in node.footprint:owners[Vector2i(int(p[0]),int(p[1]))]=str(node.id)
 var local=data.duplicate(false);local._rf_owners=owners
 for row in choice.network.regions:
  for site in row.groups:
   if absi(int(levels[site])-int(row.level))>1:return "Final regional_network exceeded a regional core window"
  for site in row.support_groups:
   if absi(int(levels[site])-int(row.level))>2:return "Final regional_network exceeded a regional support window"
 for edge in choice.network.relations:
  for role in ["low","high"]:
   for site in edge[role]:
    if absi(int(levels[site])-int(edge[role+"_level"]))>1:return "Final regional_network exceeded a relation core window"
   for site in Features._regional_patch(edge[role],str(edge[role+"_id"]),1,local):
    if absi(int(levels[site])-int(edge[role+"_level"]))>2:return "Final regional_network exceeded a relation support window"
  var minimum=5 if edge.tier=="primary" else maxi(0,int(edge.gap)-2)
  if _median(edge.high,levels)-_median(edge.low,levels)<minimum:return "Final regional_network lost a declared relation"
 return ""

static func _median(sites:Array,levels:Array)->int:
 var values=[]
 for site in sites:values.append(int(levels[site]))
 values.sort();return int(values[values.size()/2])
static func _cells(sites:Array,data:Dictionary)->int:
 var count=0
 for site in sites:count+=data.groups[site].size()
 return count
static func _bfs(sources:Array,edges:Array)->Array:
 var distance=[];distance.resize(edges.size());distance.fill(100000);var queue=sources.duplicate();var cursor=0
 for site in sources:distance[site]=0
 while cursor<queue.size():
  var a=int(queue[cursor]);cursor+=1
  for b in edges[a]:
   if int(distance[b])>int(distance[a])+1:distance[b]=int(distance[a])+1;queue.append(b)
 return distance
static func _path(a:int,b:int,edges:Array)->Array:
 var parents={a:-1};var queue=[a];var cursor=0
 while cursor<queue.size() and not parents.has(b):
  var here=int(queue[cursor]);cursor+=1
  for n in edges[here]:
   if not parents.has(n):parents[n]=here;queue.append(n)
 if not parents.has(b):return []
 var result=[b]
 while int(result[-1])!=a:result.append(int(parents[result[-1]]))
 result.reverse();return result

static func _smooth(value:float)->float:
 value=clampf(value,0,1);return value*value*(3.0-2.0*value)

static func _plane_windows(data:Dictionary)->Dictionary:
 var coords=data.owner.keys();var indices={};var offsets=[]
 for i in coords.size():indices[coords[i]]=i
 for q in range(-4,5):
  for r in range(maxi(-4,-q-4),mini(4,-q+4)+1):offsets.append(Vector2i(q,r))
 var points=[];var min_c=INF;var max_c=-INF;var min_l=INF;var max_l=-INF
 for coord in coords:
  var point=Hex.to_plane(coord,1);points.append(point)
  min_c=minf(min_c,point.dot(Citadel.C));max_c=maxf(max_c,point.dot(Citadel.C));min_l=minf(min_l,point.dot(Citadel.L));max_l=maxf(max_l,point.dot(Citadel.L))
 var windows=[]
 for center in coords.size():
  var members=[];var mean=Vector2.ZERO
  for delta in offsets:
   var other=indices.get(coords[center]+delta,-1)
   if other>=0:members.append(other)
  # Retain the historical accumulation order exactly.
  members.sort()
  for other in members:mean+=points[other]
  if members.size()<16:windows.append({});continue
  mean/=members.size();var rows=[];var xx=0.0;var xy=0.0;var yy=0.0
  for other in members:
   var p:Vector2=points[other]-mean;xx+=p.x*p.x;xy+=p.x*p.y;yy+=p.y*p.y;rows.append([data.owner[coords[other]],p.x,p.y])
  var center_point:Vector2=points[center]
  var bin_c=clampi(int(3.0*(center_point.dot(Citadel.C)-min_c)/maxf(.001,max_c-min_c)),0,2)
  var bin_l=clampi(int(3.0*(center_point.dot(Citadel.L)-min_l)/maxf(.001,max_l-min_l)),0,2)
  windows.append({"rows":rows,"xx":xx,"xy":xy,"yy":yy,"det":xx*yy-xy*xy,"bin":"%d,%d"%[bin_l,bin_c]})
 return {"coords":coords,"windows":windows}

static func _plane_metrics(levels:Array,prepared:Dictionary,data:Dictionary,c:Dictionary)->Dictionary:
 var good={};var gentle=0;var bins={};var tested=0
 for i in prepared.windows.size():
  var window=prepared.windows[i]
  if window.is_empty() or absf(float(window.det))<.000001:continue
  tested+=1;var h=0.0;var hh=0.0;var xh=0.0;var yh=0.0;var n=float(window.rows.size())
  for row in window.rows:
   var value=float(levels[int(row[0])]);h+=value;hh+=value*value;xh+=row[1]*value;yh+=row[2]*value
  var a=(xh*window.yy-yh*window.xy)/window.det;var b=(yh*window.xx-xh*window.xy)/window.det
  var rms=sqrt(maxf(0.0,(hh-h*h/n-a*xh-b*yh)/n))
  if not bins.has(window.bin):bins[window.bin]={"tested":0,"near_plane":0,"near_gentle":0}
  bins[window.bin].tested+=1
  if rms<=.75:
   good[prepared.coords[i]]=true;bins[window.bin].near_plane+=1
   if c.quantum*sqrt(a*a+b*b)<=.105:gentle+=1;bins[window.bin].near_gentle+=1
 var visited={};var largest=0
 for start in good:
  if visited.has(start):continue
  var queue=[start];visited[start]=true;var cursor=0
  while cursor<queue.size():
   var coord:Vector2i=queue[cursor];cursor+=1
   for n in Hex.neighbors(coord):
    if good.has(n) and not visited.has(n):visited[n]=true;queue.append(n)
  largest=maxi(largest,queue.size())
 var worst=0.0
 for key in bins:
  var row=bins[key];row.ratio=float(row.near_plane)/row.tested
  if row.tested>=20:worst=maxf(worst,row.ratio)
 return {"local_plane_ratio":float(good.size())/maxi(1,tested),"local_gentle_ratio":float(gentle)/maxi(1,tested),"local_plane_component":largest,"local_plane_component_ratio":float(largest)/maxi(1,data.owner.size()),"worst_bin_plane_ratio":worst,"plane_bins":bins}

## Opt-in local shaping graph. select() and old network outputs are unchanged.
static func refinement_graph(planar:Dictionary,original:Dictionary,c:Dictionary,choice:Dictionary)->Dictionary:
 var data=original.duplicate(false);data._rf_owners={}
 for node in planar.nodes:
  for pair in node.footprint:data._rf_owners[Vector2i(int(pair[0]),int(pair[1]))]=str(node.id)
 var nodes=[];var index={}
 for row in choice.network.regions:
  index[row.id]=nodes.size();nodes.append({"id":row.id,"core":row.groups,"support":row.support_groups})
 var budget=maxi(1,ceili(c.amplitude_levels*3.0))
 if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
 var side=Wall.sides(planar,data);var base=Wall.geometry(planar,data,c,budget,side)
 var graph=_joint(planar,data,c,budget,side,base,nodes,index,choice.network.relations,{})
 if not graph.feasible:return {"error":"Original regional network could not be reconstructed for local refinement"}
 var levels:Array=choice.levels;var pins={};var minimum=int(levels.min());var maximum=int(levels.max())
 for i in levels.size():graph.lower[i]=maxi(int(graph.lower[i]),minimum);graph.upper[i]=mini(int(graph.upper[i]),maximum)
 for i in nodes.size():graph.lower[levels.size()+i]=int(choice.network.regions[i].level);graph.upper[levels.size()+i]=int(choice.network.regions[i].level)
 for footprint in data.protected_footprints.values():
  for coord in footprint:pins[int(data.owner[coord])]=true
 for row in choice.network.relations:
  if row.tier=="primary":
   for site in row.low+row.high:pins[int(site)]=true
 for wall in graph.selected:
  for site in side[wall].direct_groups:pins[int(site)]=true
 for value in [minimum,maximum]:
  var kept=false
  for site in pins:
   if int(levels[site])==value:kept=true;break
  if not kept:
   var root=int(levels.find(value));var queue=[root];var cells=0
   for site in queue:
    pins[site]=true;cells+=data.groups[site].size()
    if cells>=3:break
    for neighbor in data.edges[site]:
     if int(levels[neighbor])==value and neighbor not in queue:queue.append(neighbor)
 graph.pins=pins;graph.refinement_data=data
 return graph

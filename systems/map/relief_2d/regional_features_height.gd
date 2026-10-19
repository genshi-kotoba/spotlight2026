extends RefCounted
## Several localized ridge/court features on the unchanged physical graph.
## Actual wall relations are selected and pinned jointly before fitting.
const Hex=preload("res://systems/map/hex_coord.gd")
const Fit=preload("res://systems/map/relief_2d/contour_height.gd")
const Citadel=preload("res://systems/map/relief_2d/citadel_height.gd")
const Regions=preload("res://systems/map/relief_2d/region_walls_height.gd")
const Wall=preload("res://systems/map/relief_2d/region_wall_profile.gd")
const VERSION="regional-features-joint-walls-v1"
const CANDIDATE_BUDGET=6

static func select(planar:Dictionary,data:Dictionary,c:Dictionary,seed_value:int,measure:Callable)->Dictionary:
 if c.quantum>.25:return {"error":"regional_features requires quantum<=.25 for the current opaque actor"}
 data=data.duplicate(false);data._rw_cell_topology=Regions._cell_topology(data)
 var budget=maxi(1,ceili(c.amplitude_levels*3.0))
 if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
 var side=Wall.sides(planar,data);var base=Wall.geometry(planar,data,c,budget,side)
 var owners={};var nodes={};var points=[]
 for node:Dictionary in planar.nodes:
  nodes[str(node.id)]=node
  for pair in node.footprint:owners[Vector2i(int(pair[0]),int(pair[1]))]=str(node.id)
 for group in data.groups:
  var p=Vector2.ZERO
  for coord:Vector2i in group:p+=Hex.to_plane(coord,1.0)
  points.append(p/group.size())
 data._rf_owners=owners
 var cache={};var raw_bands=Regions._bands(side,data,owners,base.forward,cache)
 var bands=_deduplicate_bands(raw_bands,data,owners,base.forward,cache)
 var diagnostics=[];var best={};var plans=_plans(bands,data,seed_value)
 for variant in plans.size():
  var plan:Array=plans[variant];var selected={}
  for band in plan:
   for pair in band.walls:selected[Vector2i(int(pair[0]),int(pair[1]))]=true
  var geometry=Wall.geometry(planar,data,c,budget,side,selected,base)
  var bounds=_base_bounds(data,c,budget,geometry)
  if bounds.has("error"):
   diagnostics.append({"variant":variant,"status":"rejected_candidate_boss_wall_bounds","reason":bounds.error})
   continue
  var accepted=[];var rejected=[]
  for index in plan.size():
   var band:Dictionary=plan[index];var fit=_anchor_band(band,bounds,data,c,geometry,index,variant)
   if fit.feasible:
    bounds=fit.bounds;var entry=band.duplicate(true);entry.low_level=fit.low;entry.high_level=fit.high
    entry.requested_gap=fit.high-fit.low;entry.support_radius=fit.support_radius;accepted.append(entry)
   else:rejected.append({"low_id":band.low_id,"high_id":band.high_id,"reason":"joint_selected_wall_anchor_capacity"})
  selected={}
  for band in accepted:
   for pair in band.walls:selected[Vector2i(int(pair[0]),int(pair[1]))]=true
  geometry=Wall.geometry(planar,data,c,budget,side,selected,base)
  var reset=_base_bounds(data,c,budget,geometry)
  if reset.has("error"):continue
  var exact=_repin(accepted,reset,data,geometry)
  if not exact.feasible:continue
  bounds=exact
  var uncovered=_uncovered_ridge(planar,accepted,bounds,data,c,geometry,variant,seed_value)
  bounds=uncovered.bounds
  var targets=_targets(accepted,bounds,data,c,variant,seed_value,uncovered.poles)
  var levels=Fit._project(targets,geometry.forward,geometry.reverse)
  levels=Fit._optimize(levels,targets,bounds.lower,bounds.upper,geometry.forward,geometry.reverse,data)
  levels=Regions._tidy_tips(levels,targets,bounds.lower,bounds.upper,geometry.forward,geometry.reverse,data)
  levels=Regions._tidy_components(levels,bounds.lower,bounds.upper,geometry.forward,geometry.reverse,data)
  levels=Regions._tidy_tips(levels,targets,bounds.lower,bounds.upper,geometry.forward,geometry.reverse,data)
  var local=_feature_metrics(levels,accepted,points,data,owners)
  var metrics:Dictionary=measure.call(levels);var small=Regions._small_components(levels,data);var tips=Regions._tip_sites(levels,data)
  var score=16.0*local.independent_sustained_five+1.2*local.regional_detrended_span+.45*metrics.level_span+2.0*local.support_cell_ratio-3.0*metrics.ground_flat_ratio-35.0*metrics.largest_ground_plateau_ratio-.08*metrics.largest_ground_plateau-1.2*small.unexpected_small_extrema-.8*tips.size()
  var plateau_safe=metrics.largest_ground_plateau<=maxf(12.0,.10*data.owner.size())
  var status="multi_feature_candidate" if local.independent_sustained_five>=2 else "limited_multi_feature_candidate"
  var record={"variant":variant,"selected":accepted,"rejected":rejected,"independent_sustained_five":local.independent_sustained_five,"regional_detrended_span":local.regional_detrended_span,"span":metrics.level_span,"flat_ratio":metrics.ground_flat_ratio,"small_extrema":small.unexpected_small_extrema,"tips":tips.size(),"largest_plateau":metrics.largest_ground_plateau,"plateau_safe":plateau_safe,"score":score}
  diagnostics.append(record)
  var better=best.is_empty()
  if not better:
   var rank=mini(2,int(local.independent_sustained_five));var previous_rank=mini(2,int(best.local.independent_sustained_five))
   if rank!=previous_rank:better=rank>previous_rank
   elif plateau_safe!=best.plateau_safe:better=plateau_safe
   else:better=score>best.score
  if better:
   var limits=[]
   if local.independent_sustained_five<2:limits.append("fewer_than_two_feasible_independent_five_level_wall_relations")
   if not plateau_safe:limits.append("large_connected_plateau_no_better_same_contrast_candidate")
   if tips.size()>0:limits.append("remaining_single_cell_extrema")
   if small.unexpected_small_extrema>0:limits.append("remaining_small_extrema")
   best={"levels":levels,"targets":targets,"score":score,"plateau_safe":plateau_safe,"profile":"regional_features_%d"%variant,"selected_walls":selected,"local":local,"candidate_count":plans.size(),"features":{"status":status,"selected_relations":accepted,"available_relations":bands.size(),"independent_sustained_five":local.independent_sustained_five,"regional_detrended_span":local.regional_detrended_span,"regional_residuals":local.regional_residuals,"feature_source":"original-wall-side-patches","field_partition":"nearest-authored-feature-gradient-continuation","spawn_policy":"fixed_baseline; no nonnegative halo or monotonic global spine","limitations":limits,"small_components":small,"tips":tips.map(func(i):return [data.groups[i][0].x,data.groups[i][0].y]),"boss_level":bounds.get("boss_level"),"additional_ridges":uncovered.poles,"selected_wall_count":selected.size(),"selected_wall_arcs":geometry.wall_arcs}}
 if best.is_empty():return {"error":"regional_features found no feasible original-graph field"}
 best.candidates=diagnostics
 return best

static func _deduplicate_bands(raw:Array,data:Dictionary,owners:Dictionary,forward:Array,cache:Dictionary)->Array:
 var result=[];var used={}
 for band in raw:
  if band.capacity<5 or band.walls.size()<3:continue
  var row=band.duplicate(true)
  for role in ["low","high"]:
   var patch={}
   for i in band[role]:patch[i]=true
   for i in band[role]:
    for n in data.edges[i]:
     var belongs=false
     for coord:Vector2i in data.groups[n]:
      if owners.get(coord,"")==band[role+"_id"]:belongs=true;break
     if belongs:patch[n]=true
   row[role]=patch.keys();row[role].sort()
  var count_low=0;var count_high=0
  for i in row.low:count_low+=data.groups[i].size()
  for i in row.high:count_high+=data.groups[i].size()
  if count_low<3 or count_high<3:continue
  var capacity=100000
  for low in row.low:
   var distance=Fit._distance(low,forward,cache,"expanded_out")
   for high in row.high:capacity=mini(capacity,int(distance[high]))
  if capacity<5:continue
  var key=str(row.low_id)+">"+str(row.high_id)
  if used.has(key):continue
  used[key]=true;row.low_cells=count_low;row.high_cells=count_high;row.capacity=capacity
  result.append(row)
 result.sort_custom(func(a,b):return a.capacity>b.capacity if a.capacity!=b.capacity else a.walls.size()>b.walls.size())
 return result

static func _plans(bands:Array,data:Dictionary,seed_value:int)->Array:
 var plans=[]
 for variant in mini(CANDIDATE_BUDGET,maxi(1,bands.size())):
  var plan=[];var used_regions={};var used_walls={}
  var first=variant%maxi(1,mini(bands.size(),12))
  var ordered=[]
  if not bands.is_empty():ordered.append(bands[first])
  for band in bands:
   if band not in ordered:ordered.append(band)
  for band in ordered:
   if used_regions.has(band.low_id) or used_regions.has(band.high_id):continue
   var overlap=false
   for pair in band.walls:
    var coord=Vector2i(int(pair[0]),int(pair[1]))
    if used_walls.has(coord):overlap=true;break
   if overlap:continue
   plan.append(band);used_regions[band.low_id]=true;used_regions[band.high_id]=true
   for pair in band.walls:used_walls[Vector2i(int(pair[0]),int(pair[1]))]=true
   if plan.size()>=2:break
  plans.append(plan)
 return plans

static func _base_bounds(data:Dictionary,c:Dictionary,budget:int,geometry:Dictionary)->Dictionary:
 var cache={};var spawn=int(data.owner[data.spawn]);var out=Fit._distance(spawn,geometry.forward,cache,"out");var incoming=Fit._distance(spawn,geometry.reverse,cache,"in")
 if out.has(-1) or incoming.has(-1):return {"error":"regional_features requires connected original ground"}
 var lower=[];var upper=[]
 for i in data.groups.size():
  lower.append(maxi(c.baseline_level-budget,c.baseline_level-int(incoming[i])))
  upper.append(mini(c.baseline_level+budget,c.baseline_level+int(out[i])))
 lower[spawn]=c.baseline_level;upper[spawn]=c.baseline_level
 var desired:Variant=null
 if c.boss_mode!="free":
  var boss=int(data.boss_group)
  if boss<0:return {"error":"Constrained Boss requires one boss node"}
  desired=c.baseline_level
  if c.boss_level!=null:desired=int(c.boss_level)
  elif c.boss_mode in ["above","below"]:desired+=1 if c.boss_mode=="above" else -1
  else:desired+=maxi(1,roundi(c.amplitude_levels*2.5))*(1 if c.boss_mode=="highest" else -1);desired=clampi(desired,int(lower[boss]),int(upper[boss]))
  if desired<lower[boss] or desired>upper[boss]:return {"error":"Boss/spawn anchor exceeds physical or opaque terrain capacity"}
  if c.boss_mode=="highest":
   for i in upper.size():upper[i]=mini(int(upper[i]),int(desired))
  elif c.boss_mode=="lowest":
   for i in lower.size():lower[i]=maxi(int(lower[i]),int(desired))
  lower[boss]=desired;upper[boss]=desired
 var closed=Fit._structure_close(lower,upper,geometry.forward,geometry.reverse)
 if not closed.feasible:return {"error":"Boss/spawn anchors conflict under selected opaque wall constraints"}
 closed.boss_level=desired
 return closed

static func _anchor_band(band:Dictionary,bounds:Dictionary,data:Dictionary,c:Dictionary,geometry:Dictionary,index:int,variant:int)->Dictionary:
 var nominal=c.baseline_level+roundi(c.amplitude_levels*(1.125 if index%2==0 else 2.25))
 if variant%2==1:nominal=c.baseline_level+roundi(c.amplitude_levels*(2.25 if index%2==0 else 1.125))
 for gap in [20,16,12,8,7]:
  var low_h=-100000;var high_h=100000
  for i in band.high:low_h=maxi(low_h,int(bounds.lower[i]));high_h=mini(high_h,int(bounds.upper[i]))
  for i in band.low:low_h=maxi(low_h,int(bounds.lower[i])+gap);high_h=mini(high_h,int(bounds.upper[i])+gap)
  if low_h>high_h:continue
  var middle=clampi(nominal,low_h,high_h)
  var tries=[middle,clampi(c.baseline_level+gap/2,low_h,high_h),low_h,high_h]
  for support_radius in [1,0]:
   for high in tries:
    var lower:Array=bounds.lower.duplicate();var upper:Array=bounds.upper.duplicate()
    for i in band.high:lower[i]=maxi(int(lower[i]),high-1);upper[i]=mini(int(upper[i]),high+1)
    for i in band.low:lower[i]=maxi(int(lower[i]),high-gap-1);upper[i]=mini(int(upper[i]),high-gap+1)
    if support_radius>0:
     for role in ["high","low"]:
      var value=int(high if role=="high" else high-gap)
      var patch=_regional_patch(band[role],str(band[role+"_id"]),support_radius,data)
      for site in patch:
       lower[site]=maxi(int(lower[site]),value-2);upper[site]=mini(int(upper[site]),value+2)
    var closed=Fit._structure_close(lower,upper,geometry.forward,geometry.reverse)
    if closed.feasible:
     closed.boss_level=bounds.get("boss_level")
     return {"feasible":true,"bounds":closed,"high":high,"low":high-gap,"support_radius":support_radius}
 return {"feasible":false}

static func _repin(accepted:Array,bounds:Dictionary,data:Dictionary,geometry:Dictionary)->Dictionary:
 var lower:Array=bounds.lower.duplicate();var upper:Array=bounds.upper.duplicate()
 for band in accepted:
  for role in ["high","low"]:
   var value=int(band[role+"_level"])
   for i in band[role]:lower[i]=maxi(int(lower[i]),value-1);upper[i]=mini(int(upper[i]),value+1)
   if band.support_radius>0:
    for i in _regional_patch(band[role],str(band[role+"_id"]),band.support_radius,data):
     lower[i]=maxi(int(lower[i]),value-2);upper[i]=mini(int(upper[i]),value+2)
 var result=Fit._structure_close(lower,upper,geometry.forward,geometry.reverse);result.boss_level=bounds.get("boss_level")
 return result

static func _uncovered_ridge(planar:Dictionary,accepted:Array,bounds:Dictionary,data:Dictionary,c:Dictionary,geometry:Dictionary,variant:int,seed_value:int)->Dictionary:
 var physical=[]
 for neighbors in data.edges:
  var row={}
  for n in neighbors:row[n]=1
  physical.append(row)
 var distance=[];distance.resize(data.groups.size());distance.fill(100000)
 var covered={}
 for band in accepted:
  covered[band.low_id]=true;covered[band.high_id]=true
  for role in ["high","low"]:
   for site in band[role]:
    var d=Citadel._distances(int(site),physical)
    for i in distance.size():distance[i]=mini(int(distance[i]),int(d[i]))
 var choices=[]
 for node in planar.nodes:
  if covered.has(str(node.id)) or node.footprint.size()<12:continue
  var coord=Vector2i(int(node.coord[0]),int(node.coord[1]));var site=int(data.owner[coord])
  var available=int(bounds.upper[site])
  if available<c.baseline_level+6:continue
  var score=float(distance[site])+minf(10.0,float(node.footprint.size())*.20)+Fit._unit_hash(seed_value,variant,site,829)*.1
  choices.append({"node":node,"site":site,"score":score,"available":available})
 choices.sort_custom(func(a,b):return a.score>b.score if not is_equal_approx(a.score,b.score) else str(a.node.id)<str(b.node.id))
 for candidate in choices.slice(0,4):
  var patch=_regional_patch([candidate.site],str(candidate.node.id),2,data)
  for requested in [18,14,10,6]:
   var value=mini(c.baseline_level+requested,candidate.available-1)
   if bounds.lower[candidate.site]==bounds.upper[candidate.site]:value=int(bounds.lower[candidate.site])
   if value<c.baseline_level+5:continue
   var lower:Array=bounds.lower.duplicate();var upper:Array=bounds.upper.duplicate()
   lower[candidate.site]=maxi(int(lower[candidate.site]),value-1);upper[candidate.site]=mini(int(upper[candidate.site]),value+1)
   for site in patch:lower[site]=maxi(int(lower[site]),value-2);upper[site]=mini(int(upper[site]),value+2)
   var fit=Fit._structure_close(lower,upper,geometry.forward,geometry.reverse)
   if fit.feasible:
    fit.boss_level=bounds.get("boss_level")
    var cells=0
    for site in patch:cells+=data.groups[site].size()
    return {"bounds":fit,"poles":[{"id":str(candidate.node.id),"role":"uncovered_broad_ridge","level":value,"groups":[candidate.site],"support_groups":patch,"support_cells":cells,"distance_to_relations":distance[candidate.site],"coord":candidate.node.coord}]}
 return {"bounds":bounds,"poles":[]}

static func validate_final(planar:Dictionary,data:Dictionary,levels:Array,c:Dictionary,choice:Dictionary)->String:
 var budget=maxi(1,ceili(c.amplitude_levels*3.0))
 if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
 data=data.duplicate(false);data._rf_owners={}
 for node in planar.nodes:
  for pair in node.footprint:data._rf_owners[Vector2i(int(pair[0]),int(pair[1]))]=str(node.id)
 var geometry=Wall.geometry(planar,data,c,budget,Wall.sides(planar,data),choice.get("selected_walls",{}))
 for a in geometry.forward.size():
  for b in geometry.forward[a]:
   if int(levels[b])-int(levels[a])>int(geometry.forward[a][b]):return "Final regional_features field violated a physical/opaque-wall arc"
 for band in choice.features.selected_relations:
  for role in ["high","low"]:
   for site in band[role]:
    if absi(int(levels[site])-int(band[role+"_level"]))>1:return "Final regional_features field exceeded a selected regional anchor window"
   if int(band.support_radius)>0:
    for site in _regional_patch(band[role],str(band[role+"_id"]),int(band.support_radius),data):
     if absi(int(levels[site])-int(band[role+"_level"]))>2:return "Final regional_features field exceeded a selected regional support window"
 for pole in choice.features.get("additional_ridges",[]):
  for site in pole.groups:
   if absi(int(levels[site])-int(pole.level))>1:return "Final regional_features field exceeded an additional ridge core window"
  for site in pole.support_groups:
   if absi(int(levels[site])-int(pole.level))>2:return "Final regional_features field exceeded an additional ridge support window"
 return ""

static func _regional_patch(sources:Array,region:String,radius:int,data:Dictionary)->Array:
 var queue=sources.duplicate();var distance={}
 for i in queue:distance[i]=0
 var cursor=0
 while cursor<queue.size():
  var here=int(queue[cursor]);cursor+=1
  if distance[here]>=radius:continue
  for n in data.edges[here]:
   if distance.has(n):continue
   var belongs=false
   for coord:Vector2i in data.groups[n]:
    if data._rf_owners.get(coord,"")==region:belongs=true;break
   if belongs:distance[n]=int(distance[here])+1;queue.append(n)
 return queue

static func _targets(accepted:Array,bounds:Dictionary,data:Dictionary,c:Dictionary,variant:int,seed_value:int,poles:Array)->Array:
 var physical=[]
 for neighbors in data.edges:
  var row={}
  for n in neighbors:row[n]=1
  physical.append(row)
 var sources=[]
 for band in accepted:
  for role in ["high","low"]:
   var distance=[];distance.resize(data.groups.size());distance.fill(100000)
   for site in band[role]:
    var d=Citadel._distances(int(site),physical)
    for i in distance.size():distance[i]=mini(int(distance[i]),int(d[i]))
   sources.append({"value":band[role+"_level"],"distance":distance,"role":role})
 for pole in poles:
  var distance=[];distance.resize(data.groups.size());distance.fill(100000)
  for site in pole.groups:
   var d=Citadel._distances(int(site),physical)
   for i in distance.size():distance[i]=mini(int(distance[i]),int(d[i]))
  sources.append({"value":pole.level,"distance":distance,"role":"high"})
 var targets=[];var grade=.58+.10*Fit._unit_hash(seed_value,variant,accepted.size(),809)
 for i in data.groups.size():
  var nearest=-1;var distance=100000
  for index in sources.size():
   var d=int(sources[index].distance[i])
   if d<distance:nearest=index;distance=d
  var target=(float(bounds.lower[i])+float(bounds.upper[i]))*.5
  if nearest>=0:
   var source=sources[nearest]
   # A hanging branch must keep the chosen feature's gradient. Blending
   # opposite profiles cancels the common distance term into a giant plane.
   target=float(source.value)+(-1.0 if source.role=="high" else 1.0)*grade*distance
  targets.append(clampf(target,float(bounds.lower[i]),float(bounds.upper[i])))

 return targets

static func _feature_metrics(levels:Array,accepted:Array,points:Array,data:Dictionary,owners:Dictionary)->Dictionary:
 var sustained=0;var support={};var rows=[]
 for band in accepted:
  var low=[];var high=[]
  for i in band.low:low.append(int(levels[i]));support[i]=true
  for i in band.high:high.append(int(levels[i]));support[i]=true
  low.sort();high.sort();var gap=int(high[high.size()/2])-int(low[low.size()/2])
  if gap>=5:sustained+=1
  rows.append({"low_id":band.low_id,"high_id":band.high_id,"gap":gap})
 var regional={}
 for coord:Vector2i in owners:
  if not data.owner.has(coord):continue
  var id=str(owners[coord])
  if not regional.has(id):regional[id]={"sum":0.0,"point":Vector2.ZERO,"count":0}
  regional[id].sum+=float(levels[data.owner[coord]]);regional[id].point+=Hex.to_plane(coord,1.0);regional[id].count+=1
 var samples=[]
 for id in regional:
  var row=regional[id];samples.append({"id":id,"p":row.point/row.count,"h":row.sum/row.count,"cells":row.count})
 var n=float(maxi(1,samples.size()));var mean_p=Vector2.ZERO;var mean_h=0.0
 for row in samples:mean_p+=row.p;mean_h+=row.h
 mean_p/=n;mean_h/=n
 var xx=0.0;var xy=0.0;var yy=0.0;var xh=0.0;var yh=0.0
 for row in samples:
  var p:Vector2=row.p-mean_p;var h=float(row.h)-mean_h
  xx+=p.x*p.x;xy+=p.x*p.y;yy+=p.y*p.y;xh+=p.x*h;yh+=p.y*h
 var det=xx*yy-xy*xy;var a=0.0;var b=0.0
 if absf(det)>.000001:a=(xh*yy-yh*xy)/det;b=(yh*xx-xh*xy)/det
 var residuals=[];var minimum=INF;var maximum=-INF
 for row in samples:
  var residual=float(row.h)-mean_h-a*(row.p.x-mean_p.x)-b*(row.p.y-mean_p.y)
  minimum=minf(minimum,residual);maximum=maxf(maximum,residual)
  residuals.append({"id":row.id,"mean_level":row.h,"detrended_level":residual,"cells":row.cells})
 var count=0
 for i in support:count+=data.groups[i].size()
 return {"independent_sustained_five":sustained,"regional_detrended_span":maximum-minimum if not samples.is_empty() else 0.0,"regional_residuals":residuals,"support_cell_ratio":float(count)/maxi(1,data.owner.size()),"measured_relations":rows}

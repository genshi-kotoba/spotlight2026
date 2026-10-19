extends RefCounted
## One dominant off-center mass, a connected low courtyard, and a graph ridge.
## All coordinates, walls, gameplay owners, gates and RNG streams are read-only.
const Hex=preload("res://systems/map/hex_coord.gd")
const Citadel=preload("res://systems/map/relief_2d/citadel_height.gd")
const Fit=preload("res://systems/map/relief_2d/contour_height.gd")
const VERSION:="eccentric-branch-massing-v3"
const CANDIDATES:=4
const QUALITY_CANDIDATES:=12

static func select(planar:Dictionary,data:Dictionary,c:Dictionary,seed_value:int,measure:Callable)->Dictionary:
	if c.quantum>0.25:return {"error":"eccentric_keep requires quantum<=0.25 for the 100-percent actor"}
	var budget:int=maxi(1,ceili(c.amplitude_levels*2.0))
	if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
	var geometry:Dictionary=Citadel._geometry(planar,data,c,budget)
	var forward:Array=geometry.forward;var reverse:Array=geometry.reverse
	var physical:Array=[]
	for neighbors:Array in data.edges:
		var row:Dictionary={}
		for b:int in neighbors:row[b]=1
		physical.append(row)
	var spawn:int=data.owner[data.spawn]
	var cache:Dictionary={}
	var out:Array=Fit._distance(spawn,forward,cache,"view_out")
	var incoming:Array=Fit._distance(spawn,reverse,cache,"view_in")
	if out.has(-1) or incoming.has(-1):return {"error":"eccentric_keep requires connected physical ground"}
	var lower:Array=[];var upper:Array=[]
	for i in data.groups.size():
		lower.append(maxi(c.baseline_level-budget,c.baseline_level-int(incoming[i])))
		upper.append(mini(c.baseline_level+budget,c.baseline_level+int(out[i])))
	var boss_level:Variant=null
	if c.boss_mode!="free":
		if data.boss_group<0:return {"error":"Constrained boss_mode requires exactly one boss node"}
		var desired:int=c.baseline_level
		if c.boss_level!=null:desired=int(c.boss_level)
		elif c.boss_mode in ["above","below"]:desired+=1 if c.boss_mode=="above" else -1
		else:desired+=maxi(1,roundi(c.amplitude_levels*1.2))*(1 if c.boss_mode=="highest" else -1);desired=clampi(desired,int(lower[data.boss_group]),int(upper[data.boss_group]))
		if desired<lower[data.boss_group] or desired>upper[data.boss_group]:return {"error":"Boss hard anchor exceeds actual ground or directed visibility capacity"}
		if (c.boss_mode=="highest" and desired<c.baseline_level) or (c.boss_mode=="lowest" and desired>c.baseline_level):return {"error":"Boss extremum conflicts with spawn baseline"}
		boss_level=desired
		if c.boss_mode=="highest":
			for i in upper.size():upper[i]=mini(int(upper[i]),desired)
		elif c.boss_mode=="lowest":
			for i in lower.size():lower[i]=maxi(int(lower[i]),desired)
		var pins:Dictionary={}
		if not Fit._pin(data.boss_group,desired,lower,upper,forward,reverse,pins):return {"error":"Boss hard anchor is infeasible"}
	var points:Array[Vector2]=[]
	for group:Array in data.groups:
		var point:=Vector2.ZERO
		for coord:Vector2i in group:point+=Hex.to_plane(coord,1.0)
		points.append(point/group.size())
	var nodes:Array=[]
	var centroid:=Vector2.ZERO
	for node:Dictionary in planar.nodes:
		var coord:=Vector2i(int(node.coord[0]),int(node.coord[1]))
		var group:int=data.owner[coord]
		centroid+=Hex.to_plane(coord,1.0)
		if node.footprint.size()>=9:nodes.append({"id":node.id,"group":group,"point":Hex.to_plane(coord,1.0),"footprint":node.footprint})
	centroid/=maxi(1,planar.nodes.size())
	if nodes.size()<2:
		var fallback_config:Dictionary=c.duplicate();fallback_config.strategy="contour_warp"
		var fallback:Dictionary=Fit.select(planar,data,fallback_config,seed_value,measure)
		if fallback.has("error"):return fallback
		fallback.massing={"status":"small_regions_warp_fallback","keep_node_ids":[],"courtyard_node_ids":[],"routes":[],"limitations":["fewer_than_two_substantial_regions"]}
		return fallback
	var radius:=1.0
	for node:Dictionary in nodes:radius=maxf(radius,node.point.distance_to(centroid))
	for node:Dictionary in nodes:
		var nearby:=0
		for other:Dictionary in nodes:
			if other.id!=node.id and other.point.distance_to(node.point)<16.0:nearby+=1
		node.priority=2.2*node.point.distance_to(centroid)/radius+0.12*mini(4,nearby)+0.05*Fit._unit_hash(seed_value,0,node.group,701)
	nodes.sort_custom(func(a,b):return a.priority>b.priority if a.priority!=b.priority else a.id<b.id)
	var hubs:Array=[]
	for node:Dictionary in nodes:
		if upper[node.group]<=c.baseline_level+3:continue
		var near:=false
		for hub:Dictionary in hubs:
			if hub.point.distance_to(node.point)<8.0:near=true
		if not near:hubs.append(node)
		if hubs.size()>=CANDIDATES:break
	if hubs.is_empty():hubs.append(nodes[0])
	var best:Dictionary={};var diagnostics:Array=[]
	var exploration:Array=[];var trigger:Dictionary={}
	for attempt in hubs.size()+2+QUALITY_CANDIDATES:
		var exploring:bool=attempt>=hubs.size()+2
		if exploring and attempt==hubs.size()+2 and not best.is_empty():
			trigger={"flat":best.metrics.ground_flat_ratio,"largest_plateau_ratio":best.metrics.largest_ground_plateau_ratio,"actual_cell_tips":_tip_sites(best.levels,data).size()}
			if budget>=8 and (trigger.flat>0.28 or trigger.largest_plateau_ratio>0.09 or trigger.actual_cell_tips>0):
				exploration=_exploration(hubs,nodes,best,forward,physical,cache,lower,upper,c)
		if exploring and attempt-hubs.size()-2>=exploration.size():continue
		var extra:Dictionary=exploration[attempt-hubs.size()-2] if exploring else {}
		var refining:bool=not exploring and attempt>=hubs.size()
		if refining and (best.is_empty() or (best.metrics.ground_flat_ratio<=0.20 and best.metrics.largest_ground_plateau_ratio<=0.08)):continue
		var variant:int=int(extra.variant) if exploring else (int(best.variant) if refining else attempt)
		var margin:int=int(extra.margin) if exploring else (attempt-hubs.size()+1 if refining else 0)
		var branch_bias:float=(0.22 if margin==1 else -0.22) if refining else 0.0
		var hub:Dictionary=extra.hub if exploring else hubs[variant]
		var court:Dictionary={};var court_score:float=-INF
		for node:Dictionary in ([extra.court] if exploring else ([best.court] if refining else nodes)):
			if refining or exploring:court=node;break
			if node.id==hub.id:continue
			var distances:Array=Fit._distance(node.group,forward,cache,"view_out")
			var physical_distances:Array=Fit._distance(node.group,physical,cache,"physical")
			var capacity:int=mini(int(upper[hub.group])-int(lower[node.group]),int(distances[hub.group]))
			var world:float=node.point.distance_to(hub.point)/sqrt(3.0)
			# A long route with the same net rise creates long rests. Prefer a
			# substantial but direct main climb, then let side branches carry
			# their own continuous shoulder/valley gradients.
			var route_length:float=float(physical_distances[hub.group])
			var score:float=minf(27.0,capacity)+0.06*maxf(0.0,float(capacity)-world)-0.24*maxf(0.0,route_length-42.0)-0.04*world
			if score>court_score:court=node;court_score=score
		if court.is_empty():continue
		var keep_nodes:Array=_near_nodes(hub,nodes,physical,cache,3)
		var court_nodes:Array=_near_nodes(court,nodes,physical,cache,2)
		var keep_sites:Dictionary={};var court_sites:Dictionary={}
		for node:Dictionary in keep_nodes:
			for group:int in _path(hub.group,node.group,data.edges):keep_sites[group]=true
		for node:Dictionary in court_nodes:
			for group:int in _path(court.group,node.group,data.edges):court_sites[group]=true
		var dk:Array=_multi_distance(keep_sites,data.edges)
		var dc:Array=_multi_distance(court_sites,data.edges)
		var climb:Array=_path(court.group,hub.group,data.edges)
		var trial_f:Array=forward.duplicate(true);var trial_r:Array=reverse.duplicate(true)
		for index in range(1,climb.size()):Citadel._arc(trial_f,trial_r,climb[index],climb[index-1],0)
		var selected:Dictionary={}
		var feasible_skips:int=margin
		var boss_headroom:int=mini(2,maxi(0,budget-1))
		for gap in range(mini(27,2*budget),0,-1):
			# Leave headroom beneath an extremum Boss. A target that exceeds
			# this ceiling then clips would turn the whole keep into a flat cap.
			var court_floor:int=int(lower[court.group])+ (boss_headroom if c.boss_mode=="lowest" and court.group!=data.boss_group else 0)
			var keep_ceiling:int=int(upper[hub.group])- (boss_headroom if c.boss_mode=="highest" and hub.group!=data.boss_group else 0)
			var lo:int=maxi(court_floor,int(lower[hub.group])-gap)
			var hi:int=mini(int(upper[court.group]),keep_ceiling-gap)
			if lo>hi:continue
			var low:int=clampi(c.baseline_level-roundi(gap*0.50),lo,hi)
			var tl:Array=lower.duplicate();var tu:Array=upper.duplicate()
			tl[court.group]=low;tu[court.group]=low;tl[hub.group]=low+gap;tu[hub.group]=low+gap
			var closed:Dictionary=Fit._structure_close(tl,tu,trial_f,trial_r)
			if closed.feasible:
				if feasible_skips>0:feasible_skips-=1;continue
				selected={"lower":closed.lower,"upper":closed.upper,"low":low,"high":low+gap,"gap":gap};break
		if selected.is_empty():continue
		var targets:Array=[]
		var axis:Vector2=(hub.point-court.point).normalized()
		var cross:=Vector2(-axis.y,axis.x)
		var phase:float=TAU*Fit._unit_hash(seed_value,variant,0,719)
		var warp:Dictionary={"axis":axis,"cross":cross,"frequency":0.12,"phase2":phase,"anisotropy":0.12}
		var density:Array=[]
		for point:Vector2 in points:
			var p:Vector2=point/sqrt(3.0)
			density.append(0.94+0.15*sin(p.dot(cross)*0.12+phase)+0.08*cos(p.dot(axis)*0.09))
		# Weighted propagation is only a smooth target intention. Every real
		# adjacency keeps its original unit capacity in the feasibility graph.
		var from_court:Array=Fit._weighted_distance(court.group,physical,density,points,warp)
		var from_keep:Array=Fit._weighted_distance(hub.group,physical,density,points,warp)
		var route_distance:float=maxf(1.0,float(from_court[hub.group]))
		for i in points.size():
			var p:Vector2=(points[i]-hub.point)/sqrt(3.0)
			var along:float=(float(from_court[i])-float(from_keep[i])+route_distance)*0.5
			var t:float=along/route_distance
			var branch:float=maxf(0.0,(float(from_court[i])+float(from_keep[i])-route_distance)*0.5)
			# The main climb keeps a nonzero grade at both ends. Branch distance
			# continues the terrain uphill from the court and downhill off the
			# keep, instead of letting every off-route room converge to an
			# equipotential ratio or a shared saturated height.
			var branch_grade:float=branch_bias+0.62*(1.0-2.0*t)+0.16*sin(p.dot(cross)*0.10+phase)
			var cross_grade:float=0.22*p.dot(cross)
			var target:float=lerpf(float(selected.low),float(selected.high),t)+branch*branch_grade+cross_grade
			targets.append(clampf(target,float(selected.lower[i]),float(selected.upper[i])))
		var levels:Array=Fit._project(targets,trial_f,trial_r)
		levels=Fit._optimize(levels,targets,selected.lower,selected.upper,trial_f,trial_r,data)
		levels=Fit._smooth_crease_tips(levels,targets,selected.lower,selected.upper,trial_f,trial_r,data)
		levels=Fit._smooth_structure_tips(levels,selected.lower,selected.upper,trial_f,trial_r,data)
		levels=_tidy_tips(levels,targets,selected.lower,selected.upper,trial_f,trial_r,data)
		var metrics:Dictionary=measure.call(levels)
		# Use the same strict real-cell tip predicate as the final independent
		# check; a candidate cannot pass shape selection by omitting a tip.
		metrics.ground_isolated_extrema=_tip_sites(levels,data).size()
		metrics.ground_isolated_extrema_ratio=float(metrics.ground_isolated_extrema)/maxi(1,data.owner.size())
		var mass:Dictionary=_mass_metrics(levels,data,dk,dc,keep_nodes,court_nodes,selected)
		metrics.merge(mass,true)
		var route:Dictionary=_cell_route(court,hub,levels,data,planar)
		var fixed:=0
		for i in selected.lower.size():
			if selected.lower[i]==selected.upper[i]:fixed+=1
		var score:float=2.0*minf(0.25,mass.keep_coverage)+1.8*mass.keep_coherence+1.5*mass.keep_cohort_high_fraction-0.08*maxi(0,mass.keep_node_median_span-8)+0.08*mass.mass_median_contrast+0.03*mini(27,metrics.level_span)-4.0*metrics.largest_ground_plateau_ratio-3.0*maxf(0.0,metrics.ground_flat_ratio-0.15)-0.025*maxi(0,int(route.get("longest_flat_edges",100))-7)-0.6*metrics.ground_isolated_extrema
		# Once a valid major body exists, avoid choosing a larger contrast that
		# brings back broad plains. This is a shape gate before the tie-break
		# score, not another reward for maximum feasible anchor span.
		var shape_pass:bool=metrics.ground_flat_ratio<=0.25 and metrics.largest_ground_plateau_ratio<=0.08 and metrics.ground_isolated_extrema==0 and mass.mass_median_contrast>=16 and mass.keep_cohort_high_fraction>=0.66
		var repair_pass:bool=metrics.ground_flat_ratio<=0.28 and metrics.largest_ground_plateau_ratio<=0.09 and metrics.ground_isolated_extrema==0 and mass.mass_median_contrast>=16 and mass.keep_cohort_high_fraction>=0.66 and int(route.get("net_levels",0))>=20
		diagnostics.append({"hub":hub.id,"court":court.id,"gap":selected.gap,"anchor_margin":margin,"branch_bias":branch_bias,"quality_exploration":exploring,"repair_pass":repair_pass,"score":score,"mass":mass,"span":metrics.level_span,"flat":metrics.ground_flat_ratio,"largest_plateau":metrics.largest_ground_plateau,"isolated_extrema":metrics.ground_isolated_extrema,"fixed_groups_under_selected_anchors":fixed,"route_edges":route.path.size()-1,"route_longest_flat_edges":route.get("longest_flat_edges",0)})
		var choose:bool=best.is_empty() or (shape_pass and not best.shape_pass) or (shape_pass==best.shape_pass and score>float(best.score))
		if exploring and not best.is_empty():
			choose=(repair_pass and not best.repair_pass) or (repair_pass==best.repair_pass and choose)
		if choose:
			var limitations:Array=[]
			if selected.gap<24:limitations.append("directed_or_physical_budget_limits_major_gap")
			if metrics.ground_flat_ratio>0.25:limitations.append("large_flat_interior")
			if metrics.largest_ground_plateau_ratio>0.10:limitations.append("large_connected_plateau")
			if mass.keep_coherence<0.90:limitations.append("high_band_has_secondary_components")
			if mass.keep_cohort_high_fraction<1.0:limitations.append("some_keep_nodes_below_shared_high_band")
			if metrics.ground_isolated_extrema>0:limitations.append("remaining_isolated_extrema")
			if route.get("longest_flat_edges",100)>10:limitations.append("long_rest_on_main_climb")
			best={"levels":levels,"profile":"eccentric_keep_%d"%variant,"score":score,"targets":targets,"local":mass,"boss_level":boss_level,"candidate_count":hubs.size(),"candidates":diagnostics,"visibility_arcs":geometry.visibility_arcs,"regional_budget":budget,"target_shape":{"kind":"connected-keep-courtyard-ridge","keep_ids":keep_nodes.map(func(n):return n.id),"court_ids":court_nodes.map(func(n):return n.id),"keep_center":[hub.point.x,hub.point.y],"courtyard_center":[court.point.x,court.point.y],"offset_ratio":hub.point.distance_to(centroid)/radius},"massing":{"status":"quality_candidate" if limitations.is_empty() else "limited_candidate","keep_node_ids":keep_nodes.map(func(n):return n.id),"courtyard_node_ids":court_nodes.map(func(n):return n.id),"requested_gap":27,"realized_anchor_gap":selected.gap,"routes":[route],"limitations":limitations,"visibility_scope":"conservative_terrain_guard_and_original_wall_profile; native_sampling_required"}}
			best.closure_lower=selected.lower;best.closure_upper=selected.upper
			best.height_forward=trial_f;best.height_reverse=trial_r
			best.metrics=metrics;best.variant=variant;best.court=court
			best.shape_pass=shape_pass
			best.repair_pass=repair_pass
			best.target_shape.kind="branch-continuing-geodesic-mass"
			best.target_shape.anchor_margin=margin;best.target_shape.branch_bias=branch_bias
	if best.is_empty():return {"error":"No feasible eccentric major mass under current physical, foundation and visibility constraints"}
	best.candidates=diagnostics
	best.candidate_count=diagnostics.size()
	best.massing.quality_exploration={"trigger":trigger,"additional_limit":QUALITY_CANDIDATES,"additional_attempts":exploration.size(),"additional_feasible":diagnostics.filter(func(row):return row.quality_exploration).size()}
	for a in forward.size():
		for b:int in forward[a]:
			if int(best.levels[b])-int(best.levels[a])>int(forward[a][b]):return {"error":"Internal eccentric directed height violation"}
	return best

static func _court_choices(hub:Dictionary,nodes:Array,forward:Array,physical:Array,cache:Dictionary,lower:Array,upper:Array)->Array:
	var choices:Array=[]
	for index in nodes.size():
		var node:Dictionary=nodes[index]
		if node.id==hub.id:continue
		var distances:Array=Fit._distance(node.group,forward,cache,"view_out")
		var physical_distances:Array=Fit._distance(node.group,physical,cache,"physical")
		var capacity:int=mini(int(upper[hub.group])-int(lower[node.group]),int(distances[hub.group]))
		var world:float=node.point.distance_to(hub.point)/sqrt(3.0)
		var route_length:float=float(physical_distances[hub.group])
		var score:float=minf(27.0,capacity)+0.06*maxf(0.0,float(capacity)-world)-0.24*maxf(0.0,route_length-42.0)-0.04*world
		choices.append({"node":node,"score":score,"order":index})
	choices.sort_custom(func(a,b):return a.score>b.score if a.score!=b.score else a.order<b.order)
	return choices

static func _exploration(hubs:Array,nodes:Array,best:Dictionary,forward:Array,physical:Array,cache:Dictionary,lower:Array,upper:Array,c:Dictionary)->Array:
	var result:Array=[]
	var original:Dictionary={}
	for hub:Dictionary in hubs:original[hub.id]=true
	# The same hub with a second courtyard tests a genuinely different path,
	# instead of repeatedly fitting the one route that produced the bad field.
	var incumbent:Dictionary=hubs[int(best.variant)]
	var courts:Array=_court_choices(incumbent,nodes,forward,physical,cache,lower,upper)
	for choice:Dictionary in courts:
		if choice.node.id==best.court.id:continue
		result.append({"hub":incumbent,"court":choice.node,"variant":int(best.variant),"margin":2})
		if result.size()==2:break
	# Other original hubs get their alternate court before new eccentric hubs.
	for index in hubs.size():
		if index==int(best.variant):continue
		courts=_court_choices(hubs[index],nodes,forward,physical,cache,lower,upper)
		if courts.size()>1:result.append({"hub":hubs[index],"court":courts[1].node,"variant":index,"margin":2})
	var phase_index:int=hubs.size()
	for node:Dictionary in nodes:
		if original.has(node.id) or upper[node.group]<=c.baseline_level+3:continue
		courts=_court_choices(node,nodes,forward,physical,cache,lower,upper)
		for index in mini(2,courts.size()):
			result.append({"hub":node,"court":courts[index].node,"variant":phase_index,"margin":2 if index==0 else 4})
			if result.size()>=QUALITY_CANDIDATES:return result
		phase_index+=1
	return result

static func _tip_sites(levels:Array,data:Dictionary)->Array:
	var result:Array=[]
	for i in levels.size():
		if data.groups[i].size()!=1:continue
		var degree:=0;var above:=0;var below:=0
		for coord:Vector2i in Hex.neighbors(data.groups[i][0]):
			if not data.owner.has(coord):continue
			degree+=1
			var z:int=levels[data.owner[coord]]
			if z>int(levels[i]):above+=1
			elif z<int(levels[i]):below+=1
		if degree>=2 and (above==degree or below==degree):result.append(i)
	return result

static func _tidy_tips(initial:Array,targets:Array,lower:Array,upper:Array,forward:Array,reverse:Array,data:Dictionary)->Array:
	var levels:Array=initial.duplicate()
	# A feasible single-site collapse can MOVE a tip to another site. Require
	# a strict decrease of the global tip count, including real cell adjacency.
	# Joining a neighbor expands the coherent contour by one step; all original
	# foundations, anchors, route constraints and view arcs stay hard.
	for pass_index in 4:
		var tips:Array=_tip_sites(levels,data)
		if tips.is_empty():break
		var best:Array=[];var best_count:int=tips.size();var best_cost:float=INF
		for i:int in tips:
			var proposals:Array=[]
			var neighbor:int=data.edges[i][0]
			proposals.append([i,int(levels[neighbor])])
			for b:int in data.edges[i]:proposals.append([b,int(levels[i])])
			for proposal:Array in proposals:
				var site:int=proposal[0];var value:int=proposal[1]
				var patch:Array=levels.duplicate();patch[site]=value
				if value<int(levels[site]):patch=Fit._envelope(patch,forward)
				else:
					var negative:Array=[]
					for z in patch:negative.append(-int(z))
					patch=Fit._envelope(negative,reverse)
					for index in patch.size():patch[index]=-int(patch[index])
				var valid:=true;var cost:=0.0
				for index in patch.size():
					patch[index]=int(patch[index])
					if patch[index]<lower[index] or patch[index]>upper[index]:valid=false;break
					if patch[index]!=levels[index]:cost+=1.0+absf(float(patch[index])-float(targets[index]))*data.groups[index].size()
				if not valid:continue
				var count:int=_tip_sites(patch,data).size()
				if count<tips.size() and (count<best_count or (count==best_count and cost<best_cost)):
					best=patch;best_count=count;best_cost=cost
		if best.is_empty():break
		levels=best
	return levels

static func _near_nodes(hub:Dictionary,nodes:Array,physical:Array,cache:Dictionary,count:int)->Array:
	var distances:Array=Fit._distance(hub.group,physical,cache,"physical")
	var choices:Array=nodes.duplicate()
	choices.sort_custom(func(a,b):return float(distances[a.group])+a.point.distance_to(hub.point)*0.15<float(distances[b.group])+b.point.distance_to(hub.point)*0.15)
	return choices.slice(0,mini(count,choices.size()))

static func _path(start:int,end:int,edges:Array)->Array:
	var parent:Dictionary={start:-1};var queue:Array=[start];var index:=0
	while index<queue.size() and not parent.has(end):
		var a:int=queue[index];index+=1
		for b:int in edges[a]:
			if not parent.has(b):parent[b]=a;queue.append(b)
	var result:Array=[end]
	while result[-1]!=start:result.append(parent[result[-1]])
	result.reverse();return result

static func _multi_distance(sites:Dictionary,edges:Array)->Array:
	var result:Array=[];result.resize(edges.size());result.fill(-1)
	var queue:Array=sites.keys();queue.sort()
	for site:int in queue:result[site]=0
	var index:=0
	while index<queue.size():
		var a:int=queue[index];index+=1
		for b:int in edges[a]:
			if result[b]<0:result[b]=int(result[a])+1;queue.append(b)
	return result

static func _mass_metrics(levels:Array,data:Dictionary,dk:Array,dc:Array,keep:Array,court:Array,anchors:Dictionary)->Dictionary:
	var selected:Dictionary={};var high_samples:Array=[];var low_samples:Array=[]
	var node_medians:Array=[]
	var threshold:int=int(anchors.high)-6
	for coord:Vector2i in data.owner:
		var group:int=data.owner[coord];var z:int=levels[group]
		if dk[group]<=4:high_samples.append(z)
		if dc[group]<=3:low_samples.append(z)
		if z>=threshold:selected[coord]=true
	var seen:Dictionary={};var largest:=0
	for start:Vector2i in selected:
		if seen.has(start):continue
		var queue:Array=[start];seen[start]=true;var cursor:=0
		while cursor<queue.size():
			var a:Vector2i=queue[cursor];cursor+=1
			for b:Vector2i in Hex.neighbors(a):
				if selected.has(b) and not seen.has(b):seen[b]=true;queue.append(b)
		largest=maxi(largest,queue.size())
	for node:Dictionary in keep:
		var samples:Array=[]
		for pair:Array in node.footprint:samples.append(int(levels[data.owner[Vector2i(int(pair[0]),int(pair[1]))]]))
		samples.sort();node_medians.append(int(samples[samples.size()/2]))
	high_samples.sort();low_samples.sort();node_medians.sort()
	var cohort:=0
	for z:int in node_medians:
		if z>=threshold:cohort+=1
	return {"keep_band_threshold":threshold,"keep_cells":selected.size(),"keep_largest_cells":largest,"keep_coverage":float(selected.size())/maxi(1,data.owner.size()),"keep_coherence":float(largest)/maxi(1,selected.size()),"keep_median":high_samples[high_samples.size()/2],"courtyard_median":low_samples[low_samples.size()/2],"mass_median_contrast":int(high_samples[high_samples.size()/2])-int(low_samples[low_samples.size()/2]),"keep_node_medians":node_medians,"keep_node_median_span":int(node_medians[-1])-int(node_medians[0]),"keep_cohort_high_fraction":float(cohort)/maxi(1,node_medians.size())}

static func _cell_route(low:Dictionary,high:Dictionary,levels:Array,data:Dictionary,planar:Dictionary)->Dictionary:
	var a:=Vector2i(int(low.footprint[0][0]),int(low.footprint[0][1]));var b:=a
	for node:Dictionary in planar.nodes:
		if node.id==low.id:a=Vector2i(int(node.coord[0]),int(node.coord[1]))
		if node.id==high.id:b=Vector2i(int(node.coord[0]),int(node.coord[1]))
	var parent:Dictionary={a:Vector2i(100000,100000)};var queue:Array=[a];var index:=0
	while index<queue.size() and not parent.has(b):
		var here:Vector2i=queue[index];index+=1
		for other:Vector2i in Hex.neighbors(here):
			if data.owner.has(other) and not parent.has(other) and int(levels[data.owner[other]])>=int(levels[data.owner[here]]):parent[other]=here;queue.append(other)
	if not parent.has(b):return {"from_id":low.id,"to_id":high.id,"path":[],"status":"no_monotonic_cell_route"}
	var route:Array=[b]
	while route[-1]!=a:route.append(parent[route[-1]])
	route.reverse()
	var z:Array=[]
	for coord:Vector2i in route:z.append(int(levels[data.owner[coord]]))
	var longest:=0;var current:=0
	for step_index in range(1,z.size()):
		current=current+1 if z[step_index]==z[step_index-1] else 0
		longest=maxi(longest,current)
	return {"from_id":low.id,"to_id":high.id,"path":route.map(func(p):return [p.x,p.y]),"levels":z,"net_levels":int(z[-1])-int(z[0]),"longest_flat_edges":longest,"status":"actual_monotonic_ground_route"}

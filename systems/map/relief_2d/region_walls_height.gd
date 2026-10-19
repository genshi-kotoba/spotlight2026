extends RefCounted
## Region cores and an approach spine fitted JOINTLY with filled opaque walls.
const Hex=preload("res://systems/map/hex_coord.gd")
const Citadel=preload("res://systems/map/relief_2d/citadel_height.gd")
const Fit=preload("res://systems/map/relief_2d/contour_height.gd")
const Ecc=preload("res://systems/map/relief_2d/eccentric_keep_height.gd")
const Wall=preload("res://systems/map/relief_2d/region_wall_profile.gd")
const VERSION:="regional-spines-and-filled-walls-v1"
const CANDIDATES:=8

static func select(planar:Dictionary,data:Dictionary,c:Dictionary,seed:int,measure:Callable)->Dictionary:
	if c.quantum>0.25:return {"error":"region_walls requires quantum<=.25 for the current actor"}
	data=data.duplicate(false)
	data._rw_cell_topology=_cell_topology(data)
	# A lowest Boss can forbid every positive keep. Preserve that explicit
	# policy with the existing feasible regional solver, and report the
	# absence of a selected retaining band instead of rejecting the map.
	if c.boss_mode=="lowest":return _limited_fallback(planar,data,c,seed,measure,"lowest_boss_requires_negative_regional_polarity")
	var budget:int=maxi(1,ceili(c.amplitude_levels*3.0))
	if c.boss_level!=null:budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
	var side:Dictionary=Wall.sides(planar,data)
	var geometry:Dictionary=Wall.geometry(planar,data,c,budget,side)
	var forward:Array=geometry.forward;var reverse:Array=geometry.reverse
	var physical:Array=[]
	for row:Array in data.edges:
		var values:Dictionary={}
		for b:int in row:values[b]=1
		physical.append(values)
	var spawn:int=data.owner[data.spawn];var cache:Dictionary={}
	var out:Array=Fit._distance(spawn,forward,cache,"out")
	var incoming:Array=Fit._distance(spawn,reverse,cache,"in")
	var sd:Array=Fit._distance(spawn,physical,cache,"physical")
	if sd.has(-1):return {"error":"region_walls requires connected original ground"}
	var lower:Array=[];var upper:Array=[]
	for i in data.groups.size():
		lower.append(maxi(c.baseline_level-budget,c.baseline_level-int(incoming[i])))
		upper.append(mini(c.baseline_level+budget,c.baseline_level+int(out[i])))
		if sd[i]<=6:lower[i]=maxi(int(lower[i]),c.baseline_level)
	var boss_level:Variant=null
	if c.boss_mode!="free":
		if data.boss_group<0:return {"error":"Constrained Boss requires one boss node"}
		var desired:int=c.baseline_level
		if c.boss_level!=null:desired=int(c.boss_level)
		elif c.boss_mode in ["above","below"]:desired+=1 if c.boss_mode=="above" else -1
		else:desired+=maxi(1,roundi(c.amplitude_levels*2.5))*(1 if c.boss_mode=="highest" else -1);desired=clampi(desired,int(lower[data.boss_group]),int(upper[data.boss_group]))
		if desired<lower[data.boss_group] and desired>=maxi(c.baseline_level-budget,c.baseline_level-int(incoming[data.boss_group])) and desired<=mini(c.baseline_level+budget,c.baseline_level+int(out[data.boss_group])):
			return _limited_fallback(planar,data,c,seed,measure,"required_boss_anchor_conflicts_with_soft_local_spawn_trend")
		if desired<lower[data.boss_group] or desired>upper[data.boss_group]:return {"error":"Explicit Boss anchor exceeds physical/terrain visibility capacity"}
		boss_level=desired
		if c.boss_mode=="highest":
			for i in upper.size():upper[i]=mini(int(upper[i]),desired)
		elif c.boss_mode=="lowest":
			for i in lower.size():lower[i]=maxi(int(lower[i]),desired)
		lower[data.boss_group]=desired;upper[data.boss_group]=desired
	var closed:Dictionary=Fit._structure_close(lower,upper,forward,reverse)
	if not closed.feasible:return {"error":"Boss and local low approach conflict under coupled constraints"}
	lower=closed.lower;upper=closed.upper
	var nodes:Array=[];var centroid:=Vector2.ZERO
	var full_owner:Dictionary={}
	for node:Dictionary in planar.nodes:
		var coord:=Vector2i(int(node.coord[0]),int(node.coord[1]));var group:int=data.owner[coord]
		var point:Vector2=Hex.to_plane(coord,1);centroid+=point
		for pair:Array in node.footprint:full_owner[Vector2i(int(pair[0]),int(pair[1]))]=node.id
		if node.footprint.size()>=9:nodes.append({"id":node.id,"group":group,"point":point,"footprint":node.footprint,"coord":coord})
	centroid/=maxi(1,planar.nodes.size())
	var bands:Array=_bands(side,data,full_owner,forward,cache)
	var node_index:Dictionary={}
	for n:Dictionary in nodes:node_index[n.id]=n
	var proposals:Array=[];var hub_used:Dictionary={}
	# Pick the wall relation before the summit. A far-away summit with a
	# capacity-one boundary is not a useful retaining structure.
	for band:Dictionary in bands:
		if band.capacity<6 or not node_index.has(band.high_id):continue
		var n:Dictionary=node_index[band.high_id]
		if upper[n.group]<=c.baseline_level+8:continue
		if hub_used.get(n.id,0)>=2:continue
		proposals.append({"hub":n,"band":band});hub_used[n.id]=int(hub_used.get(n.id,0))+1
		if proposals.size()>=CANDIDATES:break
	if proposals.is_empty():return _limited_fallback(planar,data,c,seed,measure,"no_meaningful_consecutive_wall_run_capacity")
	var points:Array[Vector2]=[]
	for group:Array in data.groups:
		var p:=Vector2.ZERO
		for coord:Vector2i in group:p+=Hex.to_plane(coord,1)
		points.append(p/group.size())
	var prior_config:Dictionary=c.duplicate();prior_config.strategy="eccentric_keep"
	var prior:Dictionary=Ecc.select(planar,data,prior_config,seed,measure)
	var best:Dictionary={};var diagnostics:Array=[]
	for variant in proposals.size():
		var hub:Dictionary=proposals[variant].hub
		var band:Dictionary=proposals[variant].band
		var desired_goal:int=mini(c.baseline_level+maxi(1,roundi(c.amplitude_levels*2.5)),int(upper[hub.group])-2)
		if desired_goal<=c.baseline_level:continue
		var spine:Array=Ecc._path(spawn,hub.group,data.edges)
		var keep:Array=Ecc._near_nodes(hub,nodes,physical,cache,3)
		var selected_walls:Dictionary={}
		for pair:Array in band.walls:selected_walls[Vector2i(int(pair[0]),int(pair[1]))]=true
		var coupled:Dictionary=Wall.geometry(planar,data,c,budget,side,selected_walls,geometry)
		var gf:Array=coupled.forward;var gr:Array=coupled.reverse
		for index in range(1,spine.size()):Citadel._arc(gf,gr,spine[index],spine[index-1],0)
		var bounds:Dictionary={};var accepted:Dictionary={};var goal:=0;var rejected:=0
		# Bounded headroom search: do not use the maximum anchor separation
		# when that separation leaves no room for interior gradients.
		for margin:int in [0,3,6]:
			var trial_goal:int=desired_goal-margin
			if trial_goal<=c.baseline_level:continue
			for gap in range(mini(10,int(band.capacity)-2),3,-2):
				var trial_l:Array=lower.duplicate();var trial_u:Array=upper.duplicate()
				trial_l[hub.group]=trial_goal;trial_u[hub.group]=trial_goal
				for node:Dictionary in keep:trial_l[node.group]=maxi(int(trial_l[node.group]),trial_goal-7)
				var core:Dictionary=Fit._structure_close(trial_l,trial_u,gf,gr)
				if not core.feasible:rejected+=1;continue
				var high_level:int=trial_goal-3
				for group:int in band.high:high_level=mini(high_level,int(core.upper[group])-1)
				for group:int in band.high:high_level=maxi(high_level,int(core.lower[group])+1)
				for group:int in band.low:trial_l[group]=maxi(int(core.lower[group]),high_level-gap-1);trial_u[group]=mini(int(core.upper[group]),high_level-gap+1)
				for group:int in band.high:trial_l[group]=maxi(int(core.lower[group]),high_level-1);trial_u[group]=mini(int(core.upper[group]),high_level+1)
				var fit:Dictionary=Fit._structure_close(trial_l,trial_u,gf,gr)
				if fit.feasible:
					bounds=fit;goal=trial_goal;accepted=band.duplicate(true);accepted.requested_gap=gap;break
				rejected+=1
			if not accepted.is_empty():break
		if accepted.is_empty():
			diagnostics.append({"hub":hub.id,"band":band,"status":"selected_fill_or_macro_anchors_infeasible","rejected_fits":rejected});continue
		var from_hub:Array=Fit._distance(hub.group,physical,cache,"physical")
		var keep_ids:Array=keep.map(func(n):return n.id)
		var targets:Array=[]
		var length:float=maxf(1.0,float(sd[hub.group]))
		var axis:Vector2=(hub.point-Hex.to_plane(data.spawn,1)).normalized()
		var cross:=Vector2(-axis.y,axis.x)
		for i in data.groups.size():
			var progress:float=(float(sd[i])-float(from_hub[i])+length)/(2.0*length)
			var branch:float=maxf(0.0,(float(sd[i])+float(from_hub[i])-length)*0.5)
			var grade:float=0.52*(1.0-2.0*progress)
			var target:float=lerpf(float(c.baseline_level),float(goal),progress)+grade*branch+0.12*(points[i]-hub.point).dot(cross)/sqrt(3.0)
			if not accepted.is_empty():
				if i in accepted.low or i in accepted.high:target=float(bounds.upper[i]+bounds.lower[i])*0.5
			targets.append(clampf(target,float(bounds.lower[i]),float(bounds.upper[i])))
		var primary_targets:Array=targets.duplicate()
		for target_variant in (1 if prior.has("error") else 2):
			targets=primary_targets.duplicate()
			if target_variant==1:
				var lift:float=float(goal)-float(prior.levels[hub.group])
				for i in targets.size():
					var intention:float=float(prior.levels[i])+lift*maxf(0.0,1.0-float(from_hub[i])/30.0)
					targets[i]=clampf(intention,float(bounds.lower[i]),float(bounds.upper[i]))
			var levels:Array=Fit._project(targets,gf,gr)
			levels=Fit._optimize(levels,targets,bounds.lower,bounds.upper,gf,gr,data)
			levels=_tidy_tips(levels,targets,bounds.lower,bounds.upper,gf,gr,data)
			levels=_tidy_components(levels,bounds.lower,bounds.upper,gf,gr,data)
			levels=_tidy_tips(levels,targets,bounds.lower,bounds.upper,gf,gr,data)
			var metrics:Dictionary=measure.call(levels)
			var profile:Dictionary=Wall.profile(planar,data,levels,c,side,selected_walls)
			var band_metrics:Dictionary=_band_metrics(bands,levels)
			var spawn_node:Dictionary={"id":"spawn","footprint":[[data.spawn.x,data.spawn.y]]}
			var route:Dictionary=Ecc._cell_route(spawn_node,hub,levels,data,planar)
			var tips:int=_tip_sites(levels,data).size()
			var small:Dictionary=_small_components(levels,data)
			var shape_safe:bool=metrics.ground_flat_ratio<=float(prior.get("metrics",metrics).ground_flat_ratio)+0.10 and metrics.largest_ground_plateau<=maxf(float(prior.get("metrics",metrics).largest_ground_plateau)*1.5,0.08*data.owner.size())
			var score:float=1.2*band_metrics.persistent_bands+0.18*band_metrics.p90_patch_delta+0.08*goal+1.0*(0 if accepted.is_empty() else 1)-3.0*metrics.largest_ground_plateau_ratio-1.0*metrics.ground_flat_ratio-5.0*tips-0.5*small.unexpected_small_extrema-0.05*int(route.get("longest_flat_edges",100))
			diagnostics.append({"hub":hub.id,"target_prior":target_variant,"goal":goal,"accepted_band":accepted,"rejected_fits":rejected,"bands":band_metrics,"flat":metrics.ground_flat_ratio,"largest_plateau":metrics.largest_ground_plateau,"tips":tips,"small_extrema":small.unexpected_small_extrema,"relative_shape_safe":shape_safe,"score":score})
			if best.is_empty() or (shape_safe and not best.shape_safe) or (shape_safe==best.shape_safe and score>best.score):
				var limits:Array=[]
				if accepted.is_empty():limits.append("no_feasible_selected_band_core")
				if band_metrics.persistent_bands==0:limits.append("no_sustained_wall_patch_contrast")
				if goal-c.baseline_level<16:limits.append("opaque_filled_wall_constraints_limit_positive_spawn_climb")
				if metrics.ground_flat_ratio>.25:limits.append("large_flat_interior")
				if tips>0:limits.append("remaining_actual_cell_tip")
				if small.unexpected_small_extrema>0:limits.append("remaining_small_component_extremum")
				if not shape_safe:limits.append("relative_shape_regression_no_safe_candidate")
				best={"levels":levels,"targets":targets,"shape_safe":shape_safe,"score":score,"profile":"region_walls_%d_%d"%[variant,target_variant],"boss_level":boss_level,"local":band_metrics,"candidate_count":nodes.size(),"visibility_arcs":geometry.visibility_arcs,"wall_arcs":geometry.wall_arcs,"selected_walls":selected_walls,"region":{"status":"regional_candidate" if limits.is_empty() else "limited_regional_candidate","keep_node_ids":keep_ids,"spawn_role":"low_local_approach","spawn_nonnegative_radius_edges":6,"selected_band":accepted,"band_measurements":band_metrics.rows,"routes":[route],"wall_roles":profile.counts,"wall_run_jumps":profile.wall_run_jumps,"limitations":limits,"actual_tips":_tip_sites(levels,data).map(func(i):return [data.groups[i][0].x,data.groups[i][0].y]),"small_components":small,"low_side_boundaries":profile.low_side_boundaries}}
	if best.is_empty():
		var fallback:Dictionary=_limited_fallback(planar,data,c,seed,measure,"meaningful_selected_fill_conflicts_with_macro_anchors")
		fallback.candidates=diagnostics;return fallback
	best.candidates=diagnostics;best.candidate_count=diagnostics.size()
	return best

static func _limited_fallback(planar:Dictionary,data:Dictionary,c:Dictionary,seed:int,measure:Callable,reason:String)->Dictionary:
	var config:Dictionary=c.duplicate();config.strategy="eccentric_keep"
	var result:Dictionary=Ecc.select(planar,data,config,seed,measure)
	if result.has("error"):return result
	result.region={"status":"limited_existing_regional_fallback","keep_node_ids":result.get("massing",{}).get("keep_node_ids",[]),"spawn_role":"boss_or_capacity_limited","selected_band":{},"routes":result.get("massing",{}).get("routes",[]),"limitations":[reason,"no_selected_structural_retaining_band"],"small_components":_small_components(result.levels,data)}
	result.selected_walls={};return result

static func _tidy_components(initial:Array,lower:Array,upper:Array,forward:Array,reverse:Array,data:Dictionary)->Array:
	var levels:Array=initial.duplicate()
	for pass_index in 3:
		var report:Dictionary=_small_components(levels,data)
		var tip_count:int=_tip_sites(levels,data).size()
		var best:Array=[];var count:int=report.unexpected_small_extrema;var cost:=INF
		if count==0:break
		for row:Dictionary in report.rows:
			if row.expected_spawn_approach:continue
			var patch:Array=levels.duplicate()
			var value:int=int(row.level)+(-1 if row.kind=="peak" else 1)
			for pair:Array in row.cells:patch[data.owner[Vector2i(int(pair[0]),int(pair[1]))]]=value
			if row.kind=="peak":patch=Fit._envelope(patch,forward)
			else:
				var negative:Array=[]
				for z in patch:negative.append(-int(z))
				patch=Fit._envelope(negative,reverse)
				for i in patch.size():patch[i]=-int(patch[i])
			var valid:=true;var changed:=0
			for i in patch.size():
				patch[i]=int(patch[i])
				if patch[i]<lower[i] or patch[i]>upper[i]:valid=false;break
				changed+=absi(int(patch[i])-int(levels[i]))*data.groups[i].size()
			if not valid:continue
			if _tip_sites(patch,data).size()>tip_count:continue
			var remaining:int=_small_components(patch,data).unexpected_small_extrema
			if remaining<count or (remaining==count and not best.is_empty() and changed<cost):best=patch;count=remaining;cost=changed
		if best.is_empty():break
		levels=best
	return levels

static func _group_owner(i:int,data:Dictionary,owners:Dictionary)->String:
	for coord:Vector2i in data.groups[i]:
		if owners.has(coord):return str(owners[coord])
	return ""

static func _spine_field(spine:Array,edges:Array)->Dictionary:
	var distance:Array=[];distance.resize(edges.size());distance.fill(-1)
	var index:Array=[];index.resize(edges.size());index.fill(-1)
	var queue:Array=spine.duplicate()
	for i in spine.size():distance[spine[i]]=0;index[spine[i]]=i
	var cursor:=0
	while cursor<queue.size():
		var a:int=queue[cursor];cursor+=1
		for b:int in edges[a]:
			if distance[b]<0:distance[b]=int(distance[a])+1;index[b]=index[a];queue.append(b)
	return {"distance":distance,"index":index}

static func _bands(side:Dictionary,data:Dictionary,owners:Dictionary,forward:Array,cache:Dictionary)->Array:
	var bins:Dictionary={}
	for wall:Vector2i in side:
		for a:Vector2i in side[wall].ground:
			for b:Vector2i in side[wall].ground:
				if Hex.distance(a,b)<2 or not owners.has(a) or not owners.has(b) or owners[a]==owners[b]:continue
				var key:String=str(owners[a])+">"+str(owners[b])
				if not bins.has(key):bins[key]={"low_id":owners[a],"high_id":owners[b],"walls":{}}
				bins[key].walls[wall]=true
	var result:Array=[]
	for key:String in bins:
		var row:Dictionary=bins[key];var used:Dictionary={}
		for start:Vector2i in row.walls:
			if used.has(start):continue
			var queue:Array=[start];var parent:Dictionary={start:null};used[start]=true;var cursor:=0
			while cursor<queue.size():
				var here:Vector2i=queue[cursor];cursor+=1
				for n:Vector2i in Hex.neighbors(here):
					if row.walls.has(n) and not used.has(n):used[n]=true;parent[n]=here;queue.append(n)
			if queue.size()<3:continue
			var path:Array=[queue[-1]]
			while parent[path[-1]]!=null:path.append(parent[path[-1]])
			path.reverse()
			for offset in range(0,path.size()-2,3):
				var window:Array=path.slice(offset,mini(offset+6,path.size()))
				var low:Dictionary={};var high:Dictionary={}
				for w:Vector2i in window:
					for coord:Vector2i in side[w].direct_ground:
						if owners.get(coord,"")==row.low_id:low[data.owner[coord]]=true
						elif owners.get(coord,"")==row.high_id:high[data.owner[coord]]=true
				if low.is_empty() or high.is_empty():continue
				var capacity:=100000
				for a:int in low:
					var d:Array=Fit._distance(a,forward,cache,"out")
					for b:int in high:capacity=mini(capacity,int(d[b]))
				result.append({"low_id":row.low_id,"high_id":row.high_id,"low":low.keys(),"high":high.keys(),"walls":window.map(func(p):return [p.x,p.y]),"capacity":capacity,"patch_source":"directly-touching-ground-on-consecutive-wall-run"})
	result.sort_custom(func(a,b):return a.capacity>b.capacity if a.capacity!=b.capacity else a.walls.size()>b.walls.size())
	return result

static func _cell_topology(data:Dictionary)->Dictionary:
	var coords:Array=data.owner.keys();var indices:Dictionary={};var owners:Array=[];var neighbors:Array=[];var tip_neighbors:Array=[]
	for i in coords.size():indices[coords[i]]=i;owners.append(int(data.owner[coords[i]]))
	for coord:Vector2i in coords:
		var row:Array=[]
		for n:Vector2i in Hex.neighbors(coord):
			if indices.has(n):row.append(int(indices[n]))
		neighbors.append(row)
	for group:Array in data.groups:
		var row:Array=[]
		if group.size()==1:
			for n:int in neighbors[indices[group[0]]]:row.append(owners[n])
		tip_neighbors.append(row)
	return {"coords":coords,"owners":owners,"neighbors":neighbors,"tip_neighbors":tip_neighbors,"spawn":indices[data.spawn]}

static func _tip_sites(levels:Array,data:Dictionary)->Array:
	var topology:Dictionary=data._rw_cell_topology
	var result:Array=[]
	for i in levels.size():
		if data.groups[i].size()!=1:continue
		var degree:=0;var above:=0;var below:=0
		for owner:int in topology.tip_neighbors[i]:
			degree+=1;var z:int=levels[owner]
			if z>int(levels[i]):above+=1
			elif z<int(levels[i]):below+=1
		if degree>=2 and (above==degree or below==degree):result.append(i)
	return result

static func _small_components(levels:Array,data:Dictionary)->Dictionary:
	var topology:Dictionary=data.get("_rw_cell_topology",{})
	if topology.is_empty():topology=_cell_topology(data)
	var coords:Array=topology.coords;var owners:Array=topology.owners;var neighbors:Array=topology.neighbors
	var used:Array=[];used.resize(coords.size());used.fill(false)
	var rows:Array=[];var count:=0;var spawn_info:Dictionary={}
	for start in coords.size():
		if used[start]:continue
		var z:int=levels[owners[start]];var queue:Array=[start];used[start]=true;var cursor:=0;var boundary:Dictionary={}
		while cursor<queue.size():
			var here:int=queue[cursor];cursor+=1
			for n:int in neighbors[here]:
				if int(levels[owners[n]])==z:
					if not used[n]:used[n]=true;queue.append(n)
				else:boundary[n]=int(levels[owners[n]])
		var above:=0;var below:=0
		for v:int in boundary.values():
			if v>z:above+=1
			elif v<z:below+=1
		var extrema:bool=not boundary.is_empty() and (above==boundary.size() or below==boundary.size())
		var expected_spawn:bool=topology.spawn in queue
		if expected_spawn:spawn_info={"cells":queue.map(func(i):return [coords[i].x,coords[i].y]),"level":z,"boundary_levels":boundary.values(),"raised_island":below==boundary.size() and not boundary.is_empty(),"low_approach":above==boundary.size() and not boundary.is_empty()}
		if queue.size()<=6 and extrema:
			rows.append({"cells":queue.map(func(i):return [coords[i].x,coords[i].y]),"level":z,"kind":"peak" if below>0 else "pit","expected_spawn_approach":expected_spawn})
			if not expected_spawn:count+=1
	return {"unexpected_small_extrema":count,"rows":rows,"spawn_component":spawn_info}

static func _band_metrics(bands:Array,levels:Array)->Dictionary:
	var rows:Array=[];var samples:Array=[];var persistent:=0
	for band:Dictionary in bands:
		var lo:Array=[];var hi:Array=[]
		for i:int in band.low:lo.append(int(levels[i]))
		for i:int in band.high:hi.append(int(levels[i]))
		lo.sort();hi.sort();var delta:int=int(hi[hi.size()/2])-int(lo[lo.size()/2])
		if delta<=0:continue
		samples.append(delta)
		if delta>=3 and band.walls.size()>=3:persistent+=1
		rows.append({"low_id":band.low_id,"high_id":band.high_id,"walls":band.walls,"low_median":lo[lo.size()/2],"high_median":hi[hi.size()/2],"median_delta":delta,"capacity":band.capacity})
	samples.sort()
	return {"persistent_bands":persistent,"p90_patch_delta":samples[int((samples.size()-1)*.9)] if not samples.is_empty() else 0,"rows":rows}

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

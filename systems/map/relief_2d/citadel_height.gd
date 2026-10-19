extends RefCounted
## Seeded regions on the real ground graph. Visibility arcs constrain HEIGHT
## only; they are never traversal, gate, discovery or node-ownership edges.
const Hex = preload("res://systems/map/hex_coord.gd")
const Regions = preload("res://systems/map/relief_2d/citadel_regions.gd")
const VERSION := "citadel-directed-regions-v1"
const VARIANTS := 4
const BLENDS := [0.28, 0.72]
const MAX_DETOUR_PAIRS := 24
const C := Vector2(0.573576436351046, 0.819152044288992)
const L := Vector2(0.819152044288992, -0.573576436351046)
const TAN_PITCH := 0.7071067811865476
# Covers the WHOLE owning hex, not just the .8-radius test poses. The
# silhouette check below protects torso/head sample rays with an extra margin.
const PLANAR_MARGIN := 2.0
const LATERAL_MARGIN := 2.2

static func select(planar: Dictionary, data: Dictionary, c: Dictionary, seed_value: int, measure: Callable) -> Dictionary:
	if c.quantum > 0.25:
		return {"error":"citadel requires quantum<=0.25 for the current 100-percent character"}
	var budget := maxi(1, ceili(c.amplitude_levels * 2.0))
	if c.boss_level != null: budget=maxi(budget,absi(int(c.boss_level)-c.baseline_level))
	var geometry := _geometry(planar,data,c,budget)
	var graph:Array=geometry.forward
	var reverse:Array=geometry.reverse
	var spawn:int=data.owner[data.spawn]
	var cache:Dictionary={}
	var spawn_out:Array=_cached_distances(spawn,graph,cache,"out")
	var spawn_in:Array=_cached_distances(spawn,reverse,cache,"in")
	if spawn_out.has(-1) or spawn_in.has(-1):return {"error":"citadel requires connected physical ground"}
	var lower:Array=[]
	var upper:Array=[]
	for i in data.groups.size():
		lower.append(maxi(c.baseline_level-budget,c.baseline_level-spawn_in[i]))
		upper.append(mini(c.baseline_level+budget,c.baseline_level+spawn_out[i]))
	var boss:int=data.boss_group
	var boss_level:Variant=null
	if c.boss_mode!="free":
		if boss<0:return {"error":"Constrained boss_mode requires exactly one boss"}
		var desired:int=c.baseline_level
		if c.boss_level!=null:desired=int(c.boss_level)
		elif c.boss_mode in ["above","below"]:desired+=1 if c.boss_mode=="above" else -1
		else:
			var sign_value:int=1 if c.boss_mode=="highest" else -1
			desired+=sign_value*maxi(1,roundi(c.amplitude_levels*1.2))
			desired=clampi(desired,int(lower[boss]),int(upper[boss]))
		if desired<lower[boss] or desired>upper[boss]:
			return {"error":"Boss/spawn anchor exceeds the traversal or local visibility height budget"}
		if (c.boss_mode=="highest" and desired<c.baseline_level) or (c.boss_mode=="lowest" and desired>c.baseline_level):
			return {"error":"Boss extremum conflicts with the spawn baseline"}
		if c.boss_level==null and ((c.boss_mode=="highest" and desired<=c.baseline_level) or (c.boss_mode=="lowest" and desired>=c.baseline_level)):
			return {"error":"Nonzero Boss extremum has no feasible local visibility budget"}
		boss_level=desired
		if c.boss_mode=="highest":
			for i in upper.size():upper[i]=mini(int(upper[i]),desired)
		elif c.boss_mode=="lowest":
			for i in lower.size():lower[i]=maxi(int(lower[i]),desired)
		if not _pin(boss,desired,lower,upper,graph,reverse,cache):
			return {"error":"Boss extremum conflicts with the spawn or local visibility constraints"}
	var fixed_lower:Array=lower.duplicate()
	var fixed_upper:Array=upper.duplicate()
	var features:Array=_close_detours(data)
	var best:Dictionary={}
	var best_score:float=-INF
	var evaluated:=0
	for variant in VARIANTS:
		lower=fixed_lower.duplicate();upper=fixed_upper.duplicate()
		var anchors:Array=[]
		var proposals:Array=Regions.proposals(planar,data,c,seed_value,variant)
		for proposal:Dictionary in proposals:
			var low:int=-100000
			var high:int=100000
			for group:int in proposal.groups:
				low=maxi(low,int(lower[group]));high=mini(high,int(upper[group]))
			if low>high:continue
			var z:int=clampi(int(proposal.desired),low,high)
			var accepted:Array=[]
			for group:int in proposal.groups:
				if _pin(group,z,lower,upper,graph,reverse,cache):accepted.append(group)
			if not accepted.is_empty():
				anchors.append({"site":proposal.site,"groups":accepted,"desired":proposal.desired,"level":z,"role":proposal.role})
		for alpha:float in BLENDS:
			var levels:Array=[]
			for i in lower.size():levels.append(floori(lerpf(float(lower[i]),float(upper[i]),alpha)+0.5))
			if levels.min()==levels.max():continue
			var m:Dictionary=measure.call(levels)
			var local:Dictionary=_local_metrics(levels,data,features)
			m.merge(local,true)
			var score:float=_score(m)
			evaluated+=1
			if score>best_score+0.0000001:
				best_score=score
				best={"levels":levels,"profile":"citadel_%d_blend_%02d" % [variant,roundi(alpha*100)],"score":score,"anchors":anchors.duplicate(true),"local":local,"boss_level":boss_level,"flat_interior":m.ground_flat_ratio}
	# A spread-out proposal pool can miss the small folded boundary responsible
	# for a useful local cliff. Refine only weak results, with at most four more
	# seed-stable candidates and the SAME hard feasible intervals/graph.
	var refinement_count:=0
	if not best.is_empty() and (int(best.local.citadel_local_contrast_p90)<6 or int(best.local.citadel_upper_components)<2 or float(best.flat_interior)>.25):
		for variant in VARIANTS:
			lower=fixed_lower.duplicate();upper=fixed_upper.duplicate()
			var anchors:Array=_detour_pins(features,lower,upper,graph,reverse,cache,c,seed_value,variant)
			if anchors.is_empty():continue
			for proposal:Dictionary in Regions.proposals(planar,data,c,seed_value,variant):
				var low:int=-100000
				var high:int=100000
				for group:int in proposal.groups:
					low=maxi(low,int(lower[group]));high=mini(high,int(upper[group]))
				if low>high:continue
				var z:int=clampi(int(proposal.desired),low,high)
				var accepted:Array=[]
				for group:int in proposal.groups:
					if _pin(group,z,lower,upper,graph,reverse,cache):accepted.append(group)
				if not accepted.is_empty():anchors.append({"site":proposal.site,"groups":accepted,"desired":proposal.desired,"level":z,"role":proposal.role})
			for alpha:float in BLENDS:
				var levels:Array=[]
				for i in lower.size():levels.append(floori(lerpf(float(lower[i]),float(upper[i]),alpha)+0.5))
				var m:Dictionary=measure.call(levels)
				var local:Dictionary=_local_metrics(levels,data,features)
				m.merge(local,true)
				var score:float=_score(m)
				evaluated+=1;refinement_count+=1
				if score>best_score+0.0000001:
					best_score=score
					best={"levels":levels,"profile":"citadel_detour_%d_blend_%02d" % [variant,roundi(alpha*100)],"score":score,"anchors":anchors.duplicate(true),"local":local,"boss_level":boss_level,"flat_interior":m.ground_flat_ratio}
	# A two-group map can have bounds [0,1] whose two interior blends both
	# round to zero. The feasible extremal fields remain valid directed fields;
	# use them only when rounding discarded every interior candidate.
	if best.is_empty():
		for levels:Array in [fixed_lower, fixed_upper]:
			if levels.min()==levels.max():continue
			var m:Dictionary=measure.call(levels)
			var local:Dictionary=_local_metrics(levels,data,features)
			m.merge(local,true)
			var score:float=_score(m)
			evaluated+=1
			if score>best_score:
				best_score=score
				best={"levels":levels.duplicate(),"profile":"citadel_feasible_extremum","score":score,"anchors":[],"local":local,"boss_level":boss_level}
	if best.is_empty():return {"error":"Nonzero relief has no feasible variation under the supplied platforms and anchors"}
	best.candidate_count=evaluated
	best.refinement_count=refinement_count
	best.visibility_arcs=geometry.visibility_arcs
	best.wall_witness_arcs=geometry.wall_arcs
	best.regional_budget=budget
	# Validate the exact integer field; never repair an invalid output by
	# scaling heights or by changing the physical map.
	for a in graph.size():
		for b:int in graph[a]:
			if int(best.levels[b])-int(best.levels[a])>int(graph[a][b]):
				return {"error":"Internal directed height constraint violation"}
	return best

static func _detour_pins(pairs:Array,lower:Array,upper:Array,forward:Array,reverse:Array,cache:Dictionary,c:Dictionary,seed_value:int,variant:int)->Array:
	# For H-L=g, feasibility is exactly g<=distance(L,H) plus the existing
	# anchor intervals. H must lie in [max(LH,LL+g), min(UH,UL+g)]. Pinning
	# those two values and propagating their bounds preserves all older pins.
	var anchors:Array=[]
	var used:Dictionary={}
	var shortlist:Array=[]
	var seen:Dictionary={}
	var target:int=maxi(6,roundi(c.amplitude_levels*1.5))
	for pair:Array in pairs:
		for orientation in 2:
			var h:int=pair[orientation]
			var l:int=pair[1-orientation]
			var key:=Vector2i(h,l)
			if h==l or seen.has(key):continue
			seen[key]=true
			var potential:int=mini(int(upper[h])-int(lower[l]),target)
			if potential<6:continue
			shortlist.append({"h":h,"l":l,"priority":potential+Regions._unit_hash(seed_value,variant,h,l,349)*1.5})
	shortlist.sort_custom(func(a,b):return a.priority>b.priority)
	if shortlist.size()>MAX_DETOUR_PAIRS:shortlist.resize(MAX_DETOUR_PAIRS)
	for round_index in 4:
		var choice:Dictionary={}
		var best_score:float=-INF
		for pair:Dictionary in shortlist:
			var h:int=pair.h
			var l:int=pair.l
			if used.has(h) or used.has(l):continue
			if mini(int(upper[h])-int(lower[l]),target)<6:continue
			var distance:Array=_cached_distances(l,forward,cache,"out")
			var gap:int=mini(mini(int(upper[h])-int(lower[l]),int(distance[h])),target)
			if gap<6 or maxi(int(lower[h]),int(lower[l])+gap)>mini(int(upper[h]),int(upper[l])+gap):continue
			var score:float=gap+Regions._unit_hash(seed_value,variant,h,l,347)*1.5
			if score>best_score:
				best_score=score;choice={"h":h,"l":l,"gap":gap}
		if choice.is_empty():break
		var h:int=choice.h
		var l:int=choice.l
		var gap:int=choice.gap
		var lo:int=maxi(int(lower[h]),int(lower[l])+gap)
		var hi:int=mini(int(upper[h]),int(upper[l])+gap)
		if lo>hi:break
		var high:int=clampi(c.baseline_level+roundi(c.amplitude_levels),lo,hi)
		if not _pin(h,high,lower,upper,forward,reverse,cache):break
		if not _pin(l,high-gap,lower,upper,forward,reverse,cache):break
		used[h]=true;used[l]=true
		anchors.append({"site":h,"groups":[h],"desired":high,"level":high,"role":"detour_high"})
		anchors.append({"site":l,"groups":[l],"desired":high-gap,"level":high-gap,"role":"detour_low"})
	return anchors

static func _pin(site:int,z:int,lower:Array,upper:Array,forward:Array,reverse:Array,cache:Dictionary)->bool:
	if z<lower[site] or z>upper[site]:return false
	var out:Array=_cached_distances(site,forward,cache,"out")
	var incoming:Array=_cached_distances(site,reverse,cache,"in")
	for i in lower.size():
		lower[i]=maxi(int(lower[i]),z-int(incoming[i]))
		upper[i]=mini(int(upper[i]),z+int(out[i]))
	return true

static func _cached_distances(site:int,edges:Array,cache:Dictionary,tag:String)->Array:
	var key:=tag+str(site)
	if not cache.has(key):cache[key]=_distances(site,edges)
	return cache[key]

static func _distances(start:int,edges:Array)->Array:
	# Integer nonnegative costs. Physical unit edges connect the map, so an
	# optimal path never needs more than N-1 cost; bounded Dial buckets suffice.
	var count:int=edges.size()
	var distances:Array=[]
	var buckets:Array=[]
	distances.resize(count);distances.fill(count)
	for i in count:buckets.append([])
	distances[start]=0;buckets[0].append(start)
	for distance in count:
		var cursor:=0
		while cursor<buckets[distance].size():
			var a:int=buckets[distance][cursor]
			cursor+=1
			if int(distances[a])!=distance:continue
			for b:int in edges[a]:
				var next:int=distance+int(edges[a][b])
				if next<int(distances[b]) and next<count:
					distances[b]=next;buckets[next].append(b)
	for i in count:
		if distances[i]==count:distances[i]=-1
	return distances

static func _arc(forward:Array,reverse:Array,a:int,b:int,cost:int)->void:
	if a==b:return
	if not forward[a].has(b) or cost<int(forward[a][b]):
		forward[a][b]=cost;reverse[b][a]=cost

static func _geometry(planar:Dictionary,data:Dictionary,c:Dictionary,budget:int)->Dictionary:
	var forward:Array=[]
	var reverse:Array=[]
	for i in data.groups.size():forward.append({});reverse.append({})
	for a in data.edges.size():
		for b:int in data.edges[a]:_arc(forward,reverse,a,b,1)
	var clear:float=0.55-float(c.quantum)-0.05
	var reach:float=(2.0*budget*float(c.quantum)+maxf(.1,c.wall_height)-clear)/TAN_PITCH+PLANAR_MARGIN
	var rows:Array=[]
	var bins:Dictionary={}
	var coords:Array=data.owner.keys()
	coords.sort_custom(_coord_less)
	for p:Vector2i in coords:
		var world:Vector2=Hex.to_plane(p,1)
		var row:Dictionary={"coord":p,"group":int(data.owner[p]),"l":world.dot(L),"d":world.dot(C)}
		rows.append(row)
		var bucket:=Vector2i(floori(row.l/LATERAL_MARGIN),floori(row.d/3.0))
		if not bins.has(bucket):bins[bucket]=[]
		bins[bucket].append(row)
	var visibility_arcs:=0
	var wall_arcs:=0
	for a:Dictionary in rows:
		for b:Dictionary in _near_rows(bins,float(a.l),float(a.d)-PLANAR_MARGIN,float(a.d)+reach):
			var delta:float=float(b.d)-float(a.d)
			# Negative center depth is safe for non-neighbor hexes: their
			# separating half-plane contains the whole actor-owning hex and the
			# torso sample width, and the camera ray moves away from B. Physical
			# neighbors already have the stricter unit-step traversal budget.
			if absf(float(b.l)-float(a.l))>LATERAL_MARGIN or delta<=0.0:continue
			var cost:=maxi(1,floori((clear+TAN_PITCH*maxf(0,delta-PLANAR_MARGIN))/c.quantum+0.00000001))
			_arc(forward,reverse,int(a.group),int(b.group),cost)
			visibility_arcs+=1
	# Walls have their OWN minimum neighbor foundation and real top cap.
	# Pinning an arbitrary neighboring ground as their "base" would shrink
	# valid high regions even when a different low neighbor supports the wall.
	return {"forward":forward,"reverse":reverse,"visibility_arcs":visibility_arcs,"wall_arcs":wall_arcs}

static func _near_rows(bins:Dictionary,lateral:float,min_d:float,max_d:float)->Array:
	var result:Array=[]
	var column:=floori(lateral/LATERAL_MARGIN)
	for x in range(column-1,column+2):
		for y in range(floori(min_d/3.0),floori(max_d/3.0)+1):
			if bins.has(Vector2i(x,y)):result.append_array(bins[Vector2i(x,y)])
	return result

static func wall_profile(planar:Dictionary,data:Dictionary,levels:Array,c:Dictionary)->Dictionary:
	var bins:Dictionary={}
	var lo:int=int(levels.min())
	var hi:int=int(levels.max())
	var clear:float=.55-c.quantum-.05
	var reach:float=((hi-lo)*c.quantum+maxf(.1,c.wall_height)-clear)/TAN_PITCH+PLANAR_MARGIN
	for p:Vector2i in data.owner:
		var world:Vector2=Hex.to_plane(p,1)
		var row:Dictionary={"l":world.dot(L),"d":world.dot(C),"height":float(levels[data.owner[p]])*c.quantum}
		var key:=Vector2i(floori(row.l/LATERAL_MARGIN),floori(row.d/3.0))
		if not bins.has(key):bins[key]=[]
		bins[key].append(row)
	var result:Dictionary={}
	for cell:Dictionary in planar.cells:
		if cell.terrain!="wall":continue
		var p:=Vector2i(int(cell.q),int(cell.r))
		var base:int=int(c.baseline_level)
		var found:=false
		for n:Vector2i in Hex.neighbors(p):
			if data.owner.has(n):
				if not found:base=int(levels[data.owner[n]]);found=true
				else:base=mini(base,int(levels[data.owner[n]]))
		var world:Vector2=Hex.to_plane(p,1)
		var dl:float=world.dot(L)
		var dc:float=world.dot(C)
		var cap:float=float(base)*c.quantum+maxf(.1,c.wall_height)
		for a:Dictionary in _near_rows(bins,dl,dc-reach,dc+PLANAR_MARGIN):
			var delta:float=dc-float(a.d)
			if absf(dl-float(a.l))>LATERAL_MARGIN or delta<=0:continue
			cap=minf(cap,float(a.height)+clear+TAN_PITCH*maxf(0,delta-PLANAR_MARGIN))
		# Detached manual wall cells can require a lower foundation. Traversal
		# remains entirely unchanged; never clamp the visible top above its cap.
		base=mini(base,floori((cap-.1)/c.quantum+0.00000001))
		var extra:float=maxf(.1,minf(maxf(.1,c.wall_height),cap-base*c.quantum))
		result[p]={"level":base,"wall_height":extra}
	return result

static func _close_detours(data:Dictionary)->Array:
	var coordinates:Array=data.owner.keys()
	coordinates.sort_custom(_coord_less)
	var result:Array=[]
	for p:Vector2i in coordinates:
		var near:Dictionary={p:0}
		var queue:Array=[p]
		var cursor:=0
		while cursor<queue.size():
			var here:Vector2i=queue[cursor];cursor+=1
			if int(near[here])>=5:continue
			for other:Vector2i in Hex.neighbors(here):
				if data.owner.has(other) and not near.has(other):
					near[other]=int(near[here])+1;queue.append(other)
		for q in range(-3,4):
			for r in range(-3,4):
				var delta:=Vector2i(q,r)
				var distance:int=Hex.distance(Vector2i.ZERO,delta)
				if distance<2 or distance>3:continue
				var other:Vector2i=p+delta
				if data.owner.has(other) and _coord_less(p,other) and not near.has(other):
					result.append([int(data.owner[p]),int(data.owner[other])])
	return result

static func _local_metrics(levels:Array,data:Dictionary,pairs:Array)->Dictionary:
	var contrasts:Array=[]
	var steep:=0
	for pair:Array in pairs:
		var delta:=absi(int(levels[pair[0]])-int(levels[pair[1]]))
		contrasts.append(delta)
		if delta>=6:steep+=1
	contrasts.sort()
	var samples:Array=[]
	for p:Vector2i in data.owner:samples.append(int(levels[data.owner[p]]))
	samples.sort()
	var low:int=samples[floori((samples.size()-1)*.25)]
	var high:int=samples[floori((samples.size()-1)*.75)]
	return {"citadel_detour_pairs":pairs.size(),"citadel_steep_detour_pairs":steep,
		"citadel_detour_ratio":float(steep)/maxi(1,pairs.size()),
		"citadel_local_contrast_p90":0 if contrasts.is_empty() else int(contrasts[floori((contrasts.size()-1)*.90)]),
		"citadel_local_contrast_max":0 if contrasts.is_empty() else int(contrasts[-1]),
		"citadel_upper_components":_band_components(levels,data,high,true),
		"citadel_lower_components":_band_components(levels,data,low,false),
		"citadel_middle_height_span":high-low}

static func _band_components(levels:Array,data:Dictionary,threshold:int,above:bool)->int:
	var selected:Dictionary={}
	for p:Vector2i in data.owner:
		var value:int=levels[data.owner[p]]
		if (value>=threshold if above else value<=threshold):selected[p]=true
	var seen:Dictionary={}
	var significant:=0
	for p:Vector2i in selected:
		if seen.has(p):continue
		var queue:Array=[p];seen[p]=true
		var cursor:=0
		while cursor<queue.size():
			var here:Vector2i=queue[cursor];cursor+=1
			for other:Vector2i in Hex.neighbors(here):
				if selected.has(other) and not seen.has(other):seen[other]=true;queue.append(other)
		if queue.size()>=maxi(4,data.owner.size()/100):significant+=1
	return significant

static func _score(m:Dictionary)->float:
	return 1.4*minf(1,float(m.citadel_local_contrast_p90)/8.0)+1.2*minf(1,float(m.citadel_detour_ratio)/.25)+.25*mini(4,int(m.citadel_upper_components))+.25*mini(4,int(m.citadel_lower_components))+.7*m.slope_edge_ratio+.7*m.ground_continuous_slope_ratio-4.0*m.largest_ground_plateau_ratio-1.5*m.ground_flat_ratio-12*m.ground_isolated_extrema_ratio+.03*mini(32,int(m.level_span))+.02*mini(16,int(m.longest_ascent_edges))

static func _coord_less(a:Vector2i,b:Vector2i)->bool:
	return a.x<b.x or (a.x==b.x and a.y<b.y)

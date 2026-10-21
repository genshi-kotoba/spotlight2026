extends RefCounted
## Height only: explicit long rising bands on the ORIGINAL ground graph.
## Geodesic poles describe a major form, never new corridors or adjacency.
const Hex = preload("res://systems/map/hex_coord.gd")
const Citadel = preload("res://systems/map/relief_2d/citadel_height.gd")
const VERSION := "graph-contour-targets-v1"
const WARP_VERSION := "coherent-phase-width-warp-v1"
const STRUCTURE_VERSION := "switchback-regional-height-v1"
const CANDIDATE_COUNT := 3
const HASH_MOD := 2147483647
const OPTIMIZATION_PASSES := 8

static func select(planar: Dictionary, data: Dictionary, c: Dictionary, seed_value: int, measure: Callable) -> Dictionary:
	if c.strategy == "contour_structure": return _select_structure(planar, data, c, seed_value, measure)
	if c.quantum > 0.25:
		return {"error": "contour requires quantum<=0.25 for the current 100-percent character"}
	var budget: int = maxi(1, ceili(c.amplitude_levels * 2.0))
	if c.boss_level != null:
		budget = maxi(budget, absi(int(c.boss_level) - c.baseline_level))
	# Physical paths remain unit-cost and bidirectional. The existing directed
	# terrain guard adds only conservative camera constraints, not traversal.
	var geometry: Dictionary = Citadel._geometry(planar, data, c, budget)
	var forward: Array = geometry.forward
	var reverse: Array = geometry.reverse
	var cache: Dictionary = {}
	var spawn: int = data.owner[data.spawn]
	var out: Array = _distance(spawn, forward, cache, "view_out")
	var incoming: Array = _distance(spawn, reverse, cache, "view_in")
	if out.has(-1) or incoming.has(-1):
		return {"error": "contour requires connected physical ground"}
	var lower: Array = []
	var upper: Array = []
	for i in data.groups.size():
		lower.append(maxi(c.baseline_level - budget, c.baseline_level - int(incoming[i])))
		upper.append(mini(c.baseline_level + budget, c.baseline_level + int(out[i])))
	var boss_level: Variant = null
	if c.boss_mode != "free":
		var boss: int = data.boss_group
		if boss < 0:
			return {"error": "Constrained boss_mode requires exactly one boss node"}
		var desired: int = c.baseline_level
		if c.boss_level != null:
			desired = int(c.boss_level)
		elif c.boss_mode in ["above", "below"]:
			desired += 1 if c.boss_mode == "above" else -1
		else:
			desired += maxi(1, roundi(c.amplitude_levels * 1.2)) * (1 if c.boss_mode == "highest" else -1)
			# Only an implicit extremum adapts to actual graph capacity.
			desired = clampi(desired, int(lower[boss]), int(upper[boss]))
		if desired < lower[boss] or desired > upper[boss]:
			return {"error": "Boss/spawn hard anchor exceeds the original ground path or terrain visibility budget"}
		if (c.boss_mode == "highest" and desired < c.baseline_level) or (c.boss_mode == "lowest" and desired > c.baseline_level):
			return {"error": "Boss extremum conflicts with the spawn baseline"}
		if c.boss_level == null and c.boss_mode in ["highest", "lowest"] and desired == c.baseline_level:
			return {"error": "Nonzero Boss extremum has no feasible terrain height budget"}
		boss_level = desired
		if c.boss_mode == "highest":
			for i in upper.size(): upper[i] = mini(int(upper[i]), desired)
		elif c.boss_mode == "lowest":
			for i in lower.size(): lower[i] = maxi(int(lower[i]), desired)
		if not _pin(boss, desired, lower, upper, forward, reverse, cache):
			return {"error": "Boss hard anchor conflicts with the spawn or terrain visibility constraints"}
	var physical: Array = []
	for neighbors: Array in data.edges:
		var row: Dictionary = {}
		for neighbor: int in neighbors: row[neighbor] = 1
		physical.append(row)
	var points: Array[Vector2] = []
	for group: Array in data.groups:
		var point := Vector2.ZERO
		for coord: Vector2i in group: point += Hex.to_plane(coord, 1.0)
		points.append(point / group.size())
	var best: Dictionary = {}
	var diagnostics: Array = []
	for variant in CANDIDATE_COUNT:
		var field: Dictionary = _warp_targets(data, points, physical, c, seed_value, variant, cache) if c.strategy == "contour_warp" else _targets(data, points, physical, c, seed_value, variant, cache)
		var targets: Array = field.targets
		for i in targets.size(): targets[i] = clampf(float(targets[i]), float(lower[i]), float(upper[i]))
		var levels: Array = _project(targets, forward, reverse)
		levels = _optimize(levels, targets, lower, upper, forward, reverse, data)
		levels = _smooth_crease_tips(levels, targets, lower, upper, forward, reverse, data)
		if levels.min() == levels.max(): continue
		var metrics: Dictionary = measure.call(levels)
		var local: Dictionary = Citadel._local_metrics(levels, data, Citadel._close_detours(data))
		var coherence: Dictionary = _coherence(levels, targets, data)
		local.merge(coherence, true)
		if c.strategy == "contour_warp": local.merge(_warp_metrics(levels, data), true)
		metrics.merge(local, true)
		var score: float = _warp_score(metrics) if c.strategy == "contour_warp" else _score(metrics)
		diagnostics.append({"profile": field.profile, "score": score, "span": metrics.level_span,
			"flat_ratio": metrics.ground_flat_ratio, "through_slope_ratio": metrics.ground_continuous_slope_ratio,
			"longest_ascent": metrics.longest_ascent_edges, "target_rmse": coherence.contour_target_rmse})
		if best.is_empty() or score > float(best.score) + 0.0000001:
			best = {"levels": levels, "profile": field.profile, "score": score, "anchors": field.poles,
				"targets": targets.duplicate(), "local": local, "boss_level": boss_level,
				"target_shape": field.shape, "flat_interior": metrics.ground_flat_ratio}
	if best.is_empty():
		return {"error": "Nonzero contour relief has no feasible variation under the supplied platforms and anchors"}
	for a in forward.size():
		if best.levels[a] < lower[a] or best.levels[a] > upper[a]:
			return {"error": "Internal contour hard-bound violation"}
		for b: int in forward[a]:
			if int(best.levels[b]) - int(best.levels[a]) > int(forward[a][b]):
				return {"error": "Internal contour directed constraint violation"}
	best.candidate_count = diagnostics.size()
	best.candidates = diagnostics
	best.visibility_arcs = geometry.visibility_arcs
	best.regional_budget = budget
	best.wall_witness_arcs = 0
	return best

static func _targets(data: Dictionary, points: Array[Vector2], physical: Array, c: Dictionary, seed_value: int, variant: int, cache: Dictionary) -> Dictionary:
	var count: int = data.groups.size()
	var first: int = _hash(seed_value, variant, count, 19) % count
	var first_distance: Array = _distance(first, physical, cache, "ground")
	var low: int = _farthest(first_distance, seed_value, variant)
	var low_distance: Array = _distance(low, physical, cache, "ground")
	var high: int = _farthest(low_distance, seed_value, variant + 7)
	var high_distance: Array = _distance(high, physical, cache, "ground")
	# A second graph axis breaks equidistant branch interiors without tiny noise.
	var side: int = first
	var side_score: float = -INF
	for i in count:
		var off_axis: float = float(low_distance[i] + high_distance[i] - low_distance[high])
		var score: float = off_axis + _unit_hash(seed_value, variant, i, 23) * 0.25
		if score > side_score: side = i; side_score = score
	var side_distance: Array = _distance(side, physical, cache, "ground")
	var other: int = _farthest(side_distance, seed_value, variant + 11)
	var other_distance: Array = _distance(other, physical, cache, "ground")
	var axis: Vector2 = (points[high] - points[low]).normalized()
	if axis == Vector2.ZERO: axis = Vector2.RIGHT
	var spawn: int = data.owner[data.spawn]
	var spawn_distance: Array = _distance(spawn, physical, cache, "ground")
	# Difference-of-distance fields flatten every branch hanging off the main
	# axis. The major rise therefore follows distance FROM spawn; a weaker
	# independently placed graph source gives those branches their own bearing.
	var origin: float = 0.10 * int(side_distance[spawn]) + 0.04 * points[spawn].dot(axis) / sqrt(3.0)
	var targets: Array = []
	var maximum := 0.0
	var width: float = maxf(3.0, c.amplitude_levels * [2.0, 1.5, 2.5][variant])
	if c.boss_mode in ["highest", "lowest"] and c.boss_level == null:
		# Shape below the implicit extremum rather than flattening a broad cap.
		width = maxf(1.0, c.amplitude_levels * [1.2, 1.0, 1.1][variant])
	var sign_value: float = -1.0 if _hash(seed_value, variant, count, 31) % 2 == 1 else 1.0
	for i in count:
		var along: float = 0.86 * int(spawn_distance[i]) + 0.10 * int(side_distance[i]) + 0.04 * points[i].dot(axis) / sqrt(3.0) - origin
		# Long rising/falling bands, with corners only at major ridge/troughs.
		# EVERY branch continues through the bands; no small per-tile noise,
		# constant anchor blend, amplitude-clipped broad plane, or extra edge.
		var target: float = sign_value * _triangle(along, width)
		targets.append(target)
		maximum = maxf(maximum, absf(target))
	var gain: float = minf(0.94, maxf(1.0, c.amplitude_levels * 2.0) / maxf(1.0, maximum))
	for i in count: targets[i] = c.baseline_level + float(targets[i]) * gain
	var poles: Array = []
	for role: String in ["main_axis_start", "main_axis_end", "branch_axis_start", "branch_axis_end"]:
		var site: int = {"main_axis_start": low, "main_axis_end": high, "branch_axis_start": side, "branch_axis_end": other}[role]
		var coord: Vector2i = data.groups[site][0]
		poles.append({"role": role, "site": site, "coord": [coord.x, coord.y], "desired": targets[site], "groups": [site], "hard": false})
	return {"targets": targets, "poles": poles, "profile": ["contour_long_bands", "contour_compact_bands", "contour_broad_bands"][variant],
		"shape": {"kind": "geodesic-rising-bands", "gain": gain, "fold_width": width, "sign": sign_value,
			"primary_graph_distance": int(low_distance[high]), "cross_graph_distance": int(side_distance[other])}}

static func _warp_targets(data: Dictionary, points: Array[Vector2], physical: Array, c: Dictionary, seed_value: int, variant: int, cache: Dictionary) -> Dictionary:
	# Keep the old contour target generator EXACT for the A/B strategy. This
	# strategy uses the same long major form, then varies its phase and width.
	var field: Dictionary = _targets(data, points, physical, c, seed_value, 0, cache)
	var count: int = points.size()
	var spawn: int = data.owner[data.spawn]
	var side: int = int(field.poles[2].site)
	var warp: Dictionary = _warp_parameters(seed_value, variant, c)
	var density: Array = []
	for point: Vector2 in points:
		var p: Vector2 = point / sqrt(3.0)
		# Density is a smooth large-area slope-width intention. It affects only
		# height targets; the feasibility graph keeps all real unit-cost edges.
		var wide: float = sin(p.dot(warp.axis) * warp.frequency + warp.phase)
		var cross: float = sin(p.dot(warp.cross) * warp.frequency * 0.71 + warp.phase2)
		density.append(clampf(0.90 + 0.32 * wide + 0.18 * cross, 0.42, 1.40))
	var source: Array = _weighted_distance(spawn, physical, density, points, warp)
	var secondary: Array = _weighted_distance(side, physical, density, points, warp)
	var phase_origin: float = _phase(points[spawn], warp)
	var origin: float = 0.10 * float(secondary[spawn])
	var width: float = float(field.shape.fold_width)
	var sign_value: float = float(field.shape.sign)
	var targets: Array = []
	var maximum := 0.0
	for i in count:
		var along: float = 0.90 * float(source[i]) + 0.10 * float(secondary[i]) - origin
		along += _phase(points[i], warp) - phase_origin
		var value: float = sign_value * _triangle(along, width)
		targets.append(value)
		maximum = maxf(maximum, absf(value))
	var gain: float = minf(0.94, maxf(1.0, c.amplitude_levels * 2.0) / maxf(1.0, maximum))
	for i in count: targets[i] = c.baseline_level + float(targets[i]) * gain
	for pole: Dictionary in field.poles: pole.desired = targets[int(pole.site)]
	field.targets = targets
	field.profile = "contour_warp_%d" % variant
	field.shape = {"kind": "weighted-geodesic-phase-warp", "gain": gain, "fold_width": width,
		"sign": sign_value, "spatial_scale_cells": warp.scale, "phase_amplitude_cells": warp.amplitude,
		"density_range": [0.42, 1.40], "anisotropy": warp.anisotropy,
		"source_graph": "original-physical-ground-edges", "width_changes": "smooth-weighted-phase-propagation"}
	return field

static func _warp_parameters(seed_value: int, variant: int, c: Dictionary) -> Dictionary:
	var angle: float = TAU * _unit_hash(seed_value, variant, 0, 401)
	var axis := Vector2(cos(angle), sin(angle))
	var scale: float = maxf(18.0, c.wavelength * 4.0) * [1.0, 1.18, 0.86][variant]
	return {"axis": axis, "cross": Vector2(-axis.y, axis.x), "frequency": TAU / scale,
		"scale": scale, "phase": TAU * _unit_hash(seed_value, variant, 1, 409),
		"phase2": TAU * _unit_hash(seed_value, variant, 2, 419),
		"amplitude": minf(4.0, maxf(1.2, c.amplitude_levels * 0.38)) * [1.0, 1.20, 0.82][variant],
		"anisotropy": [0.16, 0.22, 0.10][variant]}

static func _phase(point: Vector2, warp: Dictionary) -> float:
	var p: Vector2 = point / sqrt(3.0)
	var a: float = p.dot(warp.axis) * warp.frequency + warp.phase
	var b: float = p.dot(warp.cross) * warp.frequency * 0.71 + warp.phase2
	# At most two low-frequency waves. No per-cell random/noise term exists.
	return warp.amplitude * (sin(a) * cos(b) + 0.32 * sin(b * 0.72 + a * 0.35))

static func _weighted_distance(start: int, physical: Array, density: Array, points: Array[Vector2], warp: Dictionary) -> Array:
	# Dijkstra changes the desired elevation phase, never traversal capacity.
	# Heap order has explicit vertex-ID ties for repeatable height-only seeds.
	var distances: Array = []
	distances.resize(physical.size()); distances.fill(INF)
	distances[start] = 0.0
	var heap: Array = [[0.0, start]]
	while not heap.is_empty():
		var item: Array = _heap_pop(heap)
		var a: int = item[1]
		if float(item[0]) > float(distances[a]) + 0.000000001: continue
		for b: int in physical[a]:
			var heading: Vector2 = (points[b] - points[a]).normalized()
			var midpoint: Vector2 = (points[b] + points[a]) * 0.5 / sqrt(3.0)
			var bend: float = sin(midpoint.dot(warp.cross) * warp.frequency * 0.71 + warp.phase2) * 0.75
			var bearing: Vector2 = Vector2(cos(bend), sin(bend)).rotated(warp.axis.angle())
			var alignment: float = heading.dot(bearing)
			var cost: float = (float(density[a]) + float(density[b])) * 0.5 * (1.0 + warp.anisotropy * (alignment * alignment - 0.5))
			var next: float = float(distances[a]) + cost
			if next < float(distances[b]) - 0.000000001:
				distances[b] = next
				_heap_push(heap, [next, b])
	return distances

static func _heap_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var index: int = heap.size() - 1
	while index > 0:
		var parent: int = (index - 1) / 2
		if not _heap_less(item, heap[parent]): break
		heap[index] = heap[parent]
		index = parent
	heap[index] = item

static func _heap_pop(heap: Array) -> Array:
	var answer: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty(): return answer
	var index := 0
	while index * 2 + 1 < heap.size():
		var child: int = index * 2 + 1
		if child + 1 < heap.size() and _heap_less(heap[child + 1], heap[child]): child += 1
		if not _heap_less(heap[child], last): break
		heap[index] = heap[child]
		index = child
	heap[index] = last
	return answer

static func _heap_less(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[0]) if a[0] != b[0] else int(a[1]) < int(b[1])

static func _warp_metrics(levels: Array, data: Dictionary) -> Dictionary:
	# Same-level components are real short rests within a climb. Contract them
	# only for measuring net rise; all feasibility checks use ORIGINAL edges.
	var owner: Dictionary = {}
	var heights: Array = []
	for start in levels.size():
		if owner.has(start): continue
		var id: int = heights.size()
		heights.append(int(levels[start]))
		owner[start] = id
		var queue: Array[int] = [start]
		var cursor := 0
		while cursor < queue.size():
			var a: int = queue[cursor]; cursor += 1
			for b: int in data.edges[a]:
				if not owner.has(b) and levels[b] == levels[a]: owner[b] = id; queue.append(b)
	var ids: Array = range(heights.size())
	ids.sort_custom(func(a: int, b: int): return heights[a] < heights[b] if heights[a] != heights[b] else a < b)
	var gain: Array = []
	gain.resize(heights.size()); gain.fill(0)
	var neighbors: Array = []
	for id in heights.size(): neighbors.append({})
	for a in levels.size():
		for b: int in data.edges[a]:
			if owner[a] != owner[b] and int(levels[b]) > int(levels[a]): neighbors[owner[a]][owner[b]] = int(levels[b]) - int(levels[a])
	var net_rise := 0
	for id: int in ids:
		for other: int in neighbors[id]:
			gain[other] = maxi(int(gain[other]), int(gain[id]) + int(neighbors[id][other]))
			net_rise = maxi(net_rise, int(gain[other]))
	var samples: Array = []
	for i in levels.size():
		for cell in data.groups[i].size(): samples.append(int(levels[i]))
	samples.sort()
	var p10: int = samples[floori((samples.size() - 1) * 0.10)]
	var p90: int = samples[floori((samples.size() - 1) * 0.90)]
	var node_levels: Array = []
	var histogram: Dictionary = {}
	var largest := 0
	for id: String in data.protected_footprints:
		var group: int = data.owner[data.protected_footprints[id][0]]
		var z: int = levels[group]
		node_levels.append(z)
		histogram[z] = int(histogram.get(z, 0)) + 1
		largest = maxi(largest, int(histogram[z]))
	return {"contour_net_climb_levels": net_rise, "contour_rest_components": heights.size(),
		"contour_body_p10": p10, "contour_body_p90": p90, "contour_body_span": p90 - p10,
		"contour_node_levels": node_levels, "contour_node_distinct_levels": histogram.size(),
		"contour_node_largest_same_level_count": largest}

static func _warp_score(m: Dictionary) -> float:
	# Short rests and wide slopes are acceptable. Do not maximize stair edges
	# or strict +1 chains; retain large relief, net climb and intended direction.
	return 0.10 * mini(32, int(m.level_span)) + 0.065 * mini(24, int(m.contour_net_climb_levels)) + 0.30 * minf(0.50, m.ground_continuous_slope_ratio) + 0.25 * minf(0.45, m.slope_edge_ratio) - 2.0 * maxf(0.0, m.ground_flat_ratio - 0.18) - 2.5 * maxf(0.0, m.largest_ground_plateau_ratio - 0.12) - 10.0 * m.ground_isolated_extrema_ratio - 2.0 * m.contour_reversal_ratio - 0.16 * m.contour_target_rmse

static func _select_structure(planar: Dictionary, data: Dictionary, c: Dictionary, seed_value: int, measure: Callable, maximum_gap: int = 12) -> Dictionary:
	var warp_config: Dictionary = c.duplicate(); warp_config.strategy = "contour_warp"
	var background: Dictionary = select(planar, data, warp_config, seed_value, measure)
	if background.has("error"): return background
	if not planar.has("height_recipe"):
		background.structure = {"status": "no_recipe_warp_fallback", "climbs": [], "reason": "No persisted switchback-v1 height recipe supplied"}
		return background
	var recipe: Variant = planar.height_recipe
	if not recipe is Dictionary or recipe.get("version") != "switchback-v1" or not recipe.get("climbs") is Array or recipe.climbs.size() > 2 or recipe.size() != 2:
		return {"error": "contour_structure requires height_recipe switchback-v1 with 1..2 climbs"}
	if recipe.climbs.is_empty():
		background.structure = {"status":"no_recipe_warp_fallback","climbs":[],"reason":"Recipe contains no realized physical climb"}
		return background
	var nodes: Dictionary = {}
	var points: Array[Vector2] = []
	for node: Dictionary in planar.nodes: nodes[node.id] = node
	for group: Array in data.groups:
		var point := Vector2.ZERO
		for coord: Vector2i in group: point += Hex.to_plane(coord, 1.0)
		points.append(point / group.size())
	var geometry: Dictionary = Citadel._geometry(planar, data, c, int(background.regional_budget))
	var forward: Array = geometry.forward
	var reverse: Array = geometry.reverse
	var spawn: int = data.owner[data.spawn]
	var out: Array = Citadel._distances(spawn, forward)
	var incoming: Array = Citadel._distances(spawn, reverse)
	var lower: Array = []
	var upper: Array = []
	for i in data.groups.size():
		lower.append(maxi(c.baseline_level-int(background.regional_budget),c.baseline_level-int(incoming[i])))
		upper.append(mini(c.baseline_level+int(background.regional_budget),c.baseline_level+int(out[i])))
	if background.boss_level != null:
		var level: int = int(background.boss_level)
		if c.boss_mode == "highest":
			for i in upper.size(): upper[i] = mini(int(upper[i]),level)
		elif c.boss_mode == "lowest":
			for i in lower.size(): lower[i] = maxi(int(lower[i]),level)
		lower[data.boss_group] = level; upper[data.boss_group] = level
	var original_bounds: Dictionary = _structure_close(lower,upper,forward,reverse)
	lower=original_bounds.lower; upper=original_bounds.upper
	var room_bases: Dictionary = {}
	for node: Dictionary in planar.nodes:
		var center := Vector2i(int(node.coord[0]),int(node.coord[1]))
		room_bases[node.id] = int(background.levels[data.owner[center]])
	var reports: Array = []
	var accepted: Array = []
	var endpoint_pairs: Dictionary = {}
	for recipe_index in recipe.climbs.size():
		var climb: Variant = recipe.climbs[recipe_index]
		if not climb is Dictionary or not climb.get("from_id") is String or not climb.get("to_id") is String or climb.from_id == climb.to_id or not climb.get("path") is Array or climb.path.size() < 2 or climb.size() != 3:
			return {"error": "Malformed structural climb"}
		var pair_ids:Array=[climb.from_id,climb.to_id];pair_ids.sort()
		var pair_key:String=JSON.stringify(pair_ids)
		if endpoint_pairs.has(pair_key):return {"error":"Duplicate structural endpoint pair"}
		endpoint_pairs[pair_key]=true
		for id: String in [climb.from_id,climb.to_id]:
			if id != "spawn" and not nodes.has(id): return {"error": "Structural endpoint is not an existing node or spawn"}
		var a_coord: Vector2i = data.spawn if climb.from_id == "spawn" else Vector2i(int(nodes[climb.from_id].coord[0]),int(nodes[climb.from_id].coord[1]))
		var b_coord: Vector2i = data.spawn if climb.to_id == "spawn" else Vector2i(int(nodes[climb.to_id].coord[0]),int(nodes[climb.to_id].coord[1]))
		var path: Array[int] = []
		var coords: Array[Vector2i] = []
		var seen: Dictionary = {}
		for pair in climb.path:
			if not pair is Array or pair.size()!=2 or not (pair[0] is int or pair[0] is float) or not (pair[1] is int or pair[1] is float) or not is_finite(float(pair[0])) or not is_finite(float(pair[1])) or float(pair[0]) != floor(float(pair[0])) or float(pair[1]) != floor(float(pair[1])):
				return {"error": "Malformed structural path coordinate"}
			var coord:=Vector2i(int(pair[0]),int(pair[1]))
			if not data.owner.has(coord) or seen.has(coord) or (not coords.is_empty() and Hex.distance(coords[-1],coord)!=1):
				return {"error": "Structural path must be unique adjacent original ground"}
			seen[coord]=true;coords.append(coord)
			var group: int = data.owner[coord]
			if path.is_empty() or path[-1]!=group:path.append(group)
		if coords[0]!=a_coord or coords[-1]!=b_coord:return {"error": "Structural path endpoints must match exact existing centers"}
		var a: int = data.owner[a_coord]
		var b: int = data.owner[b_coord]
		var a_groups: Array = _structure_region(climb.from_id,nodes,data)
		var b_groups: Array = _structure_region(climb.to_id,nodes,data)
		var a_core: Array = _structure_core(climb.from_id,nodes,data,a_groups)
		var b_core: Array = _structure_core(climb.to_id,nodes,data,b_groups)
		var best: Dictionary = {}
		var preferred_sign: int = 1 if int(background.levels[b])>=int(background.levels[a]) else -1
		# Prefer major room bands. Boundary cells remain a transition skirt so
		# a valid visible cliff is not falsely forbidden by a flat entire room.
		for gap in range(maximum_gap,0,-1):
			for sign_value: int in [preferred_sign,-preferred_sign]:
				var delta: int = sign_value*gap
				var lo: int = maxi(int(lower[a]),int(lower[b])-delta)
				var hi: int = mini(int(upper[a]),int(upper[b])-delta)
				for group: int in a_core: lo=maxi(lo,int(lower[group])-2);hi=mini(hi,int(upper[group])+2)
				for group: int in b_core: lo=maxi(lo,int(lower[group])-delta-2);hi=mini(hi,int(upper[group])-delta+2)
				if lo>hi:continue
				var preferred:int=clampi(roundi((int(background.levels[a])+int(background.levels[b])-delta)*0.5),lo,hi)
				var choices: Array = [preferred,clampi(c.baseline_level-delta/2,lo,hi),(lo+hi)/2,lo,hi]
				var unique: Dictionary = {}
				for base in choices:
					base=int(base)
					if unique.has(base):continue
					unique[base]=true
					var trial_f:Array=forward.duplicate(true);var trial_r:Array=reverse.duplicate(true)
					for index in range(1,path.size()):
						if sign_value>0:Citadel._arc(trial_f,trial_r,path[index],path[index-1],0)
						else:Citadel._arc(trial_f,trial_r,path[index-1],path[index],0)
					var trial_lo:Array=lower.duplicate();var trial_hi:Array=upper.duplicate()
					for group:int in a_core:trial_lo[group]=maxi(int(trial_lo[group]),base-2);trial_hi[group]=mini(int(trial_hi[group]),base+2)
					for group:int in b_core:trial_lo[group]=maxi(int(trial_lo[group]),base+delta-2);trial_hi[group]=mini(int(trial_hi[group]),base+delta+2)
					trial_lo[a]=base;trial_hi[a]=base;trial_lo[b]=base+delta;trial_hi[b]=base+delta
					var closed:Dictionary=_structure_close(trial_lo,trial_hi,trial_f,trial_r)
					if not closed.feasible:continue
					var change:float=absi(base-int(background.levels[a]))+absi(base+delta-int(background.levels[b]))
					if best.is_empty() or change<float(best.change):
						best={"lower":closed.lower,"upper":closed.upper,"forward":trial_f,"reverse":trial_r,"from_level":base,"to_level":base+delta,"gap":gap,"delta":delta,"change":change,"path":path,"a":a,"b":b,"a_groups":a_groups,"b_groups":b_groups,"a_core":a_core,"b_core":b_core,"from_id":climb.from_id,"to_id":climb.to_id}
			if not best.is_empty():break
		var physical:Array=[]
		for neighbors:Array in data.edges:
			var row:Dictionary={}
			for neighbor:int in neighbors:row[neighbor]=1
			physical.append(row)
		var capacity:Array=Citadel._distances(a,physical)
		if best.is_empty():
			reports.append({"from_id":climb.from_id,"to_id":climb.to_id,"requested_gap":[8,12],"realized_gap":0,"status":"infeasible_under_physical_or_visibility_constraints","physical_endpoint_capacity":capacity[b]})
			continue
		lower=best.lower;upper=best.upper;forward=best.forward;reverse=best.reverse
		room_bases[climb.from_id]=best.from_level;room_bases[climb.to_id]=best.to_level
		accepted.append(best)
		reports.append({"from_id":climb.from_id,"to_id":climb.to_id,"requested_gap":[8,12],"realized_gap":best.gap,"realized_delta":best.delta,"from_level":best.from_level,"to_level":best.to_level,"status":"major_climb" if best.gap>=8 else "limited_climb","physical_endpoint_capacity":capacity[b],"path_edges":coords.size()-1,"core_cells_from":a_core.size(),"core_cells_to":b_core.size()})
	if accepted.is_empty():
		background.structure={"status":"recipe_infeasible_warp_fallback","climbs":reports}
		return background
	var targets:Array=_structure_targets(planar,data,points,room_bases,background,seed_value)
	for climb:Dictionary in accepted:
		for index in climb.path.size():
			var group:int=climb.path[index]
			var value:float=lerpf(float(climb.from_level),float(climb.to_level),float(index)/maxi(1,climb.path.size()-1))
			targets[group]=value
	for i in targets.size():targets[i]=clampf(float(targets[i]),float(lower[i]),float(upper[i]))
	var levels:Array=_project(targets,forward,reverse)
	levels=_optimize(levels,targets,lower,upper,forward,reverse,data)
	levels=_smooth_crease_tips(levels,targets,lower,upper,forward,reverse,data)
	levels=_smooth_structure_tips(levels,lower,upper,forward,reverse,data)
	for a in forward.size():
		if levels[a]<lower[a] or levels[a]>upper[a]:return {"error":"Internal structural height bound violation"}
		for b:int in forward[a]:
			if int(levels[b])-int(levels[a])>int(forward[a][b]):return {"error":"Internal structural directed constraint violation"}
	for index in accepted.size():
		var climb:Dictionary=accepted[index]
		var actual:Array=[]
		for group:int in climb.path:actual.append(int(levels[group]))
		var region_a:Array=[];var region_b:Array=[]
		for group:int in climb.a_groups:
			for cell in data.groups[group].size():region_a.append(int(levels[group]))
		for group:int in climb.b_groups:
			for cell in data.groups[group].size():region_b.append(int(levels[group]))
		region_a.sort();region_b.sort()
		# Reports and accepted indices can differ if an earlier link failed.
		for report:Dictionary in reports:
			if report.from_id!=climb.from_id or report.to_id!=climb.to_id:continue
			report.path_levels=actual
			report.room_a_range=[region_a[0],region_a[-1]];report.room_b_range=[region_b[0],region_b[-1]]
			report.room_median_delta=int(region_b[region_b.size()/2])-int(region_a[region_a.size()/2])
			report.room_a_p10_p90=[region_a[floori((region_a.size()-1)*0.10)],region_a[floori((region_a.size()-1)*0.90)]]
			report.room_b_p10_p90=[region_b[floori((region_b.size()-1)*0.10)],region_b[floori((region_b.size()-1)*0.90)]]
			report.status="major_regional_climb" if absi(report.room_median_delta)>=8 and report.realized_gap>=8 else "limited_regional_climb"
			report.monotonic=true
	var major:=0
	for report:Dictionary in reports:
		if report.status=="major_regional_climb":major+=1
	var local:Dictionary=Citadel._local_metrics(levels,data,Citadel._close_detours(data))
	local.merge(_coherence(levels,targets,data),true);local.merge(_warp_metrics(levels,data),true)
	var metrics:Dictionary=measure.call(levels);metrics.merge(local,true)
	if int(metrics.ground_isolated_extrema)>0 and maximum_gap==12:
		# These endpoint gaps are soft intent (8..12), unlike spawn/Boss pins.
		# One bounded quality retry relaxes them by one level. Never change a
		# real hard anchor, graph edge, wall, or camera guard to hide a tip.
		var retry:Dictionary=_select_structure(planar,data,c,seed_value,measure,11)
		if not retry.has("error") and int(measure.call(retry.levels).ground_isolated_extrema)<int(metrics.ground_isolated_extrema):
			retry.structure.quality_retry="soft_endpoint_gap_12_to_11"
			return retry
	var constraint_tips:Array=[]
	for i in levels.size():
		if data.groups[i].size()!=1 or data.edges[i].size()<2:continue
		var above:=0;var below:=0
		for b:int in data.edges[i]:
			if int(levels[b])>int(levels[i]):above+=1
			elif int(levels[b])<int(levels[i]):below+=1
		if above==data.edges[i].size() or below==data.edges[i].size():
			var coord:Vector2i=data.groups[i][0]
			constraint_tips.append({"coord":[coord.x,coord.y],"level":int(levels[i]),"bounds":[lower[i],upper[i]],"kind":"pit" if above>0 else "peak","reason":"current_region_anchor_choice_and_directed_constraints"})
	return {"levels":levels,"profile":"contour_structure_regions","score":_warp_score(metrics),"anchors":reports,"targets":targets,"local":local,"boss_level":background.boss_level,"target_shape":{"kind":"explicit-region-bands-and-switchbacks","interior_target_span":3.0,"transition_skirt":"original-room-boundary"},"structure":{"status":"structural_candidate" if major>0 else "limited_structure_candidate","climbs":reports,"selected_climbs":accepted.size(),"major_region_climbs":major,"constraint_tips":constraint_tips,"limitations":[] if constraint_tips.is_empty() else ["current_anchor_choice_forces_one_cell_tip"]},"candidate_count":1,"candidates":[],"visibility_arcs":geometry.visibility_arcs,"regional_budget":background.regional_budget,"wall_witness_arcs":0}

static func _smooth_structure_tips(initial:Array,lower:Array,upper:Array,forward:Array,reverse:Array,data:Dictionary)->Array:
	var levels:Array=initial.duplicate()
	# A zero-cost monotonic-path arc may prevent a LOCAL one-cell repair even
	# though advancing the same-height path rest as a whole is feasible. Close
	# that exact one-level change through directed constraints, then check all
	# existing hard pins and room-core bounds. Legacy warp remains unchanged.
	for pass_index in 4:
		var changes:=0
		for i in levels.size():
			if data.groups[i].size()!=1 or data.edges[i].size()<2:continue
			var above:=0;var below:=0
			for b:int in data.edges[i]:
				if int(levels[b])>int(levels[i]):above+=1
				elif int(levels[b])<int(levels[i]):below+=1
			if above!=data.edges[i].size() and below!=data.edges[i].size():continue
			var patch:Array=levels.duplicate()
			patch[i]=int(levels[i])+(1 if above>0 else -1)
			if above>0:
				var negative:Array=[]
				for level in patch:negative.append(-int(level))
				patch=_envelope(negative,reverse)
				for index in patch.size():patch[index]=-int(patch[index])
			else:patch=_envelope(patch,forward)
			var feasible:=true
			for index in patch.size():
				patch[index]=int(patch[index])
				if patch[index]<lower[index] or patch[index]>upper[index]:feasible=false;break
			if feasible:levels=patch;changes+=1
		if changes==0:break
	return levels

static func _structure_close(lower:Array,upper:Array,forward:Array,reverse:Array)->Dictionary:
	upper=_envelope(upper,forward)
	var negative:Array=[]
	for value in lower:negative.append(-int(value))
	lower=_envelope(negative,reverse)
	var feasible:=true
	for i in lower.size():
		lower[i]=-int(lower[i]);upper[i]=int(upper[i])
		if lower[i]>upper[i]:feasible=false
	return {"lower":lower,"upper":upper,"feasible":feasible}

static func _structure_region(id:String,nodes:Dictionary,data:Dictionary)->Array:
	var result:Array=[]
	if id=="spawn":return [int(data.owner[data.spawn])]
	for pair:Array in nodes[id].footprint:
		var group:int=data.owner[Vector2i(int(pair[0]),int(pair[1]))]
		if group not in result:result.append(group)
	result.sort()
	return result

static func _structure_core(id:String,nodes:Dictionary,data:Dictionary,groups:Array)->Array:
	if id=="spawn":return groups.duplicate()
	var footprint:Dictionary={}
	for pair:Array in nodes[id].footprint:footprint[Vector2i(int(pair[0]),int(pair[1]))]=true
	var core:Dictionary={}
	for coord:Vector2i in footprint:
		var inner:=true
		for neighbor:Vector2i in Hex.neighbors(coord):
			if not footprint.has(neighbor):inner=false;break
		if inner:core[int(data.owner[coord])]=true
	var center:=Vector2i(int(nodes[id].coord[0]),int(nodes[id].coord[1]))
	core[int(data.owner[center])]=true
	var result:Array=core.keys();result.sort()
	return result

static func _structure_targets(planar:Dictionary,data:Dictionary,points:Array[Vector2],room_bases:Dictionary,background:Dictionary,seed_value:int)->Array:
	var targets:Array=background.targets.duplicate()
	var assigned:Dictionary={}
	for node:Dictionary in planar.nodes:
		var groups:Array=_structure_region(node.id,{node.id:node},data)
		var angle:float=TAU*_unit_hash(seed_value,0,node.id.hash(),521)
		var axis:=Vector2(cos(angle),sin(angle))
		var center:=Hex.to_plane(Vector2i(int(node.coord[0]),int(node.coord[1])),1.0)
		var reach:=1.0
		for group:int in groups:reach=maxf(reach,absf((points[group]-center).dot(axis)))
		for group:int in groups:
			targets[group]=float(room_bases[node.id])+1.5*(points[group]-center).dot(axis)/reach
			assigned[group]=true
	# Transit and other unowned ground interpolate regional bases over actual
	# graph distance. This is a nonperiodic room field, not another global wave.
	var sources:Array=[]
	var values:Array=[]
	var physical:Array=[]
	for neighbors:Array in data.edges:
		var row:Dictionary={}
		for neighbor:int in neighbors:row[neighbor]=1
		physical.append(row)
	for node:Dictionary in planar.nodes:
		var coord:=Vector2i(int(node.coord[0]),int(node.coord[1]))
		sources.append(Citadel._distances(int(data.owner[coord]),physical));values.append(float(room_bases[node.id]))
	sources.append(Citadel._distances(int(data.owner[data.spawn]),physical));values.append(float(background.levels[data.owner[data.spawn]]))
	for i in targets.size():
		if assigned.has(i):continue
		var total:=0.0;var weight:=0.0
		for index in sources.size():
			var factor:float=1.0/pow(2.0+int(sources[index][i]),3.0)
			total+=values[index]*factor;weight+=factor
		targets[i]=total/maxf(0.000000001,weight)
	return targets

static func _triangle(value: float, width: float) -> float:
	var wrapped: float = fposmod(value + width, 4.0 * width)
	return wrapped - width if wrapped <= 2.0 * width else 3.0 * width - wrapped

static func _project(targets: Array, forward: Array, reverse: Array) -> Array:
	var high: Array = _envelope(targets, forward)
	var negative: Array = []
	for target in targets: negative.append(-float(target))
	var low: Array = _envelope(negative, reverse)
	var levels: Array = []
	for i in targets.size(): levels.append(floori((float(high[i]) - float(low[i])) * 0.5 + 0.5))
	return levels

static func _envelope(initial: Array, forward: Array) -> Array:
	var result: Array = initial.duplicate()
	var queue: Array[int] = []
	var queued: Array[bool] = []
	queued.resize(result.size()); queued.fill(true)
	for i in result.size(): queue.append(i)
	var cursor := 0
	while cursor < queue.size():
		var a: int = queue[cursor]; cursor += 1; queued[a] = false
		for b: int in forward[a]:
			var value: float = float(result[a]) + int(forward[a][b])
			if value < float(result[b]) - 0.000000001:
				result[b] = value
				if not queued[b]: queue.append(b); queued[b] = true
	return result

static func _optimize(initial: Array, targets: Array, lower: Array, upper: Array, forward: Array, reverse: Array, data: Dictionary) -> Array:
	var levels: Array = initial.duplicate()
	for pass_index in OPTIMIZATION_PASSES:
		var changes := 0
		for index in levels.size():
			var i: int = index if pass_index % 2 == 0 else levels.size() - 1 - index
			var low: int = int(lower[i])
			var high: int = int(upper[i])
			for b: int in forward[i]: low = maxi(low, int(levels[b]) - int(forward[i][b]))
			for a: int in reverse[i]: high = mini(high, int(levels[a]) + int(reverse[i][a]))
			var current: int = int(levels[i])
			var chosen: int = current
			var best: float = _cost(i, current, levels, targets, data)
			for value in [current - 1, current + 1]:
				if value < low or value > high: continue
				var cost: float = _cost(i, value, levels, targets, data)
				if cost < best - 0.000000001: best = cost; chosen = value
			if chosen != current: levels[i] = chosen; changes += 1
		if changes == 0: break
	return levels

static func _smooth_crease_tips(initial: Array, targets: Array, lower: Array, upper: Array, forward: Array, reverse: Array, data: Dictionary) -> Array:
	var levels: Array = initial.duplicate()
	# Roundoff at a major contour crease can leave a one-cell pit or spike.
	# Expand that tip into its same-height neighbor band; never change a hard
	# pin, multi-cell foundation, or physical connection to accomplish it.
	for pass_index in 3:
		var changes := 0
		for i in levels.size():
			if data.groups[i].size() != 1 or data.edges[i].size() < 2: continue
			var above := 0
			var below := 0
			for b: int in data.edges[i]:
				if int(levels[b]) > int(levels[i]): above += 1
				elif int(levels[b]) < int(levels[i]): below += 1
			if above != data.edges[i].size() and below != data.edges[i].size(): continue
			var value: int = int(levels[i]) + (1 if above > 0 else -1)
			var low: int = int(lower[i])
			var high: int = int(upper[i])
			for b: int in forward[i]: low = maxi(low, int(levels[b]) - int(forward[i][b]))
			for a: int in reverse[i]: high = mini(high, int(levels[a]) + int(reverse[i][a]))
			if value >= low and value <= high:
				levels[i] = value
				changes += 1
				continue
			# A visibility or Boss bound can require the exact tip height. Join
			# one adjacent ground group to it, with a directed envelope patch;
			# this preserves every hard bound and expands a real contour band.
			var best_patch: Array = []
			var best_cost := INF
			for b: int in data.edges[i]:
				var patch: Array = levels.duplicate()
				patch[b] = levels[i]
				if above > 0:
					patch = _envelope(patch, forward)
				else:
					var negative: Array = []
					for z in patch: negative.append(-int(z))
					patch = _envelope(negative, reverse)
					for index in patch.size(): patch[index] = -int(patch[index])
				var feasible := true
				var cost := 0.0
				for index in patch.size():
					patch[index] = int(patch[index])
					if patch[index] < lower[index] or patch[index] > upper[index]: feasible = false; break
					if patch[index] != levels[index]:
						var old_error: float = int(levels[index]) - float(targets[index])
						var new_error: float = int(patch[index]) - float(targets[index])
						cost += 1.0 + maxf(0.0, new_error * new_error - old_error * old_error) * data.groups[index].size()
				if feasible and cost < best_cost: best_patch = patch; best_cost = cost
			if not best_patch.is_empty(): levels = best_patch; changes += 1
		if changes == 0: break
	return levels

static func _cost(i: int, value: int, levels: Array, targets: Array, data: Dictionary) -> float:
	var error: float = value - float(targets[i])
	var cost: float = error * error * data.groups[i].size()
	for b: int in data.edges[i]:
		var gradient_error: float = (value - int(levels[b])) - (float(targets[i]) - float(targets[b]))
		cost += 0.35 * gradient_error * gradient_error
	return cost

static func _pin(site: int, level: int, lower: Array, upper: Array, forward: Array, reverse: Array, cache: Dictionary) -> bool:
	if level < lower[site] or level > upper[site]: return false
	var out: Array = _distance(site, forward, cache, "view_out")
	var incoming: Array = _distance(site, reverse, cache, "view_in")
	for i in lower.size():
		lower[i] = maxi(int(lower[i]), level - int(incoming[i]))
		upper[i] = mini(int(upper[i]), level + int(out[i]))
	return true

static func _distance(site: int, graph: Array, cache: Dictionary, kind: String) -> Array:
	var key: String = kind + str(site)
	if not cache.has(key): cache[key] = _nonnegative_distances(site, graph)
	return cache[key]

static func _nonnegative_distances(start: int, graph: Array) -> Array:
	# Same bounded integer Dial search as Citadel._distances. Only allocate
	# buckets actually reached and stop when the pending frontier is empty.
	var count: int = graph.size()
	var distances: Array = []
	distances.resize(count); distances.fill(count)
	var buckets: Array = []
	buckets.resize(count)
	distances[start] = 0; buckets[0] = [start]
	var pending := 1
	for distance: int in count:
		var bucket: Variant = buckets[distance]
		if bucket == null: continue
		var cursor := 0
		while cursor < bucket.size():
			var a: int = bucket[cursor]; cursor += 1; pending -= 1
			if int(distances[a]) != distance: continue
			var row: Dictionary = graph[a]
			for b: int in row:
				var next: int = distance + int(row[b])
				if next < int(distances[b]) and next < count:
					distances[b] = next
					if buckets[next] == null: buckets[next] = []
					buckets[next].append(b); pending += 1
		if pending == 0: break
	for i: int in count:
		if distances[i] == count: distances[i] = -1
	return distances

static func _farthest(distances: Array, seed_value: int, variant: int) -> int:
	var site := 0
	for i in distances.size():
		if int(distances[i]) > int(distances[site]) or (distances[i] == distances[site] and _hash(seed_value, variant, i, 41) < _hash(seed_value, variant, site, 41)):
			site = i
	return site

static func _coherence(levels: Array, targets: Array, data: Dictionary) -> Dictionary:
	var reversed := 0
	var directed := 0
	var squared := 0.0
	for i in levels.size():
		var error: float = int(levels[i]) - float(targets[i])
		squared += error * error * data.groups[i].size()
		for b: int in data.edges[i]:
			if b <= i: continue
			var intended: float = float(targets[b]) - float(targets[i])
			if absf(intended) < 0.20: continue
			directed += 1
			if (int(levels[b]) - int(levels[i])) * intended < 0.0: reversed += 1
	return {"contour_target_rmse": sqrt(squared / maxi(1, data.owner.size())),
		"contour_directional_edges": directed, "contour_reversed_edges": reversed,
		"contour_reversal_ratio": float(reversed) / maxi(1, directed)}

static func _score(m: Dictionary) -> float:
	# No reward for tiny peaks/valleys or an artificially high component count.
	# Sustained climb and target direction take precedence over total span.
	return 1.8 * m.ground_continuous_slope_ratio + 1.1 * m.slope_edge_ratio + 0.045 * mini(24, int(m.longest_ascent_edges)) + 0.025 * mini(32, int(m.level_span)) - 2.2 * m.ground_flat_ratio - 2.5 * m.largest_ground_plateau_ratio - 10.0 * m.ground_isolated_extrema_ratio - 2.0 * m.contour_reversal_ratio - 0.02 * m.contour_target_rmse

static func wall_profile(planar: Dictionary, data: Dictionary, levels: Array, c: Dictionary) -> Dictionary:
	# The user's accepted original wall appearance includes this exact profile.
	# Keep the full hex footprint and original min-neighbor/view-cap behavior.
	return Citadel.wall_profile(planar, data, levels, c)

static func target_rows(data: Dictionary, targets: Array, levels: Array) -> Array:
	var rows: Array = []
	for i in data.groups.size():
		var coord: Vector2i = data.groups[i][0]
		rows.append({"group": i, "coord": [coord.x, coord.y], "cells": data.groups[i].size(), "target": targets[i], "level": levels[i]})
	return rows

static func _hash(seed_value: int, variant: int, a: int, salt: int) -> int:
	var value: int = posmod(seed_value, HASH_MOD)
	value = posmod(value * 48271 + (variant + 1) * 69621 + salt * 7919, HASH_MOD)
	return posmod(value * 40699 + (a + 1) * 104729, HASH_MOD)

static func _unit_hash(seed_value: int, variant: int, a: int, salt: int) -> float:
	return float(_hash(seed_value, variant, a, salt)) / float(HASH_MOD - 1)

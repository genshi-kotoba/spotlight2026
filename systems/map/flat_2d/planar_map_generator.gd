extends RefCounted
## Native consolidation of the selected node-first WALK pipeline.
## Owns no run, RNG, cache, presentation, file I/O, or external event lifecycle.
const VERSION := "planar-walk-v1"
const Hex = preload("res://systems/map/hex_coord.gd")
const Domains = preload("res://systems/random/random_domains.gd")
const SpaceRefiner = preload("res://systems/map/flat_2d/hex_space_refiner.gd")
const AlchemyEvents = preload("res://systems/map/flat_2d/alchemy_event_catalog.gd")
const NodeGeometry = preload("res://systems/map/flat_2d/node_geometry.gd")
const SummitTemplate = preload("res://systems/map/flat_2d/summit_map_template.gd")
const _LEXICOGRAPHIC_DIRS: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -1),
	Vector2i(0, 1), Vector2i(1, -1), Vector2i(1, 0),
]
const DEFAULT_CONFIG := {
	"size": "small", "normal": 3, "elite": 1, "events": 8,
	"min_boss_content_nodes": 4, "transition_count": 6,
	"transition_steps": 1, "obstacle_rate": 0.06,
	"cell_space": 1, "space_jitter": true,
	"layout_candidates": 1,
	"layout_profile": "legacy",
	"route_profile": "legacy",
	"content_profile": "legacy",
}
const MAX_ATTEMPTS := 8
const EMBEDDING_TRIALS := 40
const PLACEMENT_LIMIT := 144
const COMPACT_MOVES := 6
var last_error: String = ""


func normalize_config(input: Dictionary) -> Dictionary:
	last_error = ""
	# Templates have their own complete policy. Do not merge WALK defaults or
	# weaken its ordinary content quotas for the final-floor exception.
	if input.has("template"):
		if input.size() != 1 or not input.template is String or input.template != SummitTemplate.VERSION:
			return _fail("Use only template=summit-v1 for the fixed summit map")
		return {"template": SummitTemplate.VERSION}
	for field in input:
		if field not in DEFAULT_CONFIG:
			return _fail("Unsupported generation config key: " + str(field))
	var c: Dictionary = DEFAULT_CONFIG.duplicate()
	c.merge(input, true)
	if c.size != "small":
		return _fail("The production WALK outline supports size=small")
	for field in ["normal", "elite", "events", "min_boss_content_nodes", "transition_count", "transition_steps", "cell_space", "layout_candidates"]:
		var value: Variant = c[field]
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floor(float(value)) or absf(float(value)) > 100000.0:
			return _fail(field + " must be an integer")
		c[field] = int(value)
	if c.cell_space not in [1, 3, 4, 7] or not c.space_jitter is bool:
		return _fail("Use cell_space=1, 3, 4, or 7 and a boolean space_jitter")
	if c.layout_candidates < 1 or c.layout_candidates > 4:
		return _fail("layout_candidates must be 1..4; one preserves legacy layout selection")
	if c.layout_profile not in ["legacy", "compact"]:
		return _fail("layout_profile must be legacy or compact")
	if c.route_profile not in ["legacy", "switchback"]:
		return _fail("route_profile must be legacy or switchback")
	if c.content_profile not in ["legacy", "alchemy_floor1", "alchemy_floor1_pile"]:
		return _fail("content_profile must be legacy, alchemy_floor1, or alchemy_floor1_pile")
	if c.content_profile == "alchemy_floor1":
		if c.normal != 3 or c.elite != 0 or c.events != 4 or c.min_boss_content_nodes != 4:
			return _fail("alchemy_floor1 requires normal=3, elite=0, events=4, min_boss_content_nodes=4")
	elif c.content_profile == "alchemy_floor1_pile":
		if c.normal != 3 or c.elite != 0 or c.events != 5 or c.min_boss_content_nodes != 4:
			return _fail("alchemy_floor1_pile requires normal=3, elite=0, events=5, min_boss_content_nodes=4")
	elif c.normal < 2 or c.normal > 8 or c.elite < 1 or c.elite > 5 or c.normal + c.elite < 4:
		return _fail("Use 2..8 normal, 1..5 elite, and at least four combat nodes")
	if c.events < 4 or c.events > 16:
		return _fail("events must be 4..16, including one shop and three services")
	if c.min_boss_content_nodes < 1 or c.min_boss_content_nodes > c.normal + c.elite + c.events - 3:
		return _fail("min_boss_content_nodes exceeds the content budget")
	if c.transition_count < 0 or c.transition_count > 6 or c.transition_steps != 1:
		return _fail("Use transition_count=0..6 and transition_steps=1")
	if not (c.obstacle_rate is float or c.obstacle_rate is int) or not is_finite(float(c.obstacle_rate)) or float(c.obstacle_rate) < 0.0 or float(c.obstacle_rate) > 0.22:
		return _fail("obstacle_rate must be a finite fraction in 0..0.22")
	c.obstacle_rate = float(c.obstacle_rate)
	# Keep legacy snapshots and normalized configs byte-compatible, including
	# callers which explicitly opt back into the original profile.
	if c.layout_profile == "legacy":
		c.erase("layout_profile")
	if c.route_profile == "legacy":
		c.erase("route_profile")
	if c.content_profile == "legacy":
		c.erase("content_profile")
	return c


func generate(seed_source, map_id: String, floor_index: int, config: Dictionary = {}) -> Dictionary:
	var c: Dictionary = normalize_config(config)
	if c.is_empty():
		return {}
	if map_id.strip_edges().is_empty() or floor_index < 1:
		return _fail("A nonempty map_id and positive floor_index are required")
	if c.has("template") and floor_index != 4:
		return _fail("summit-v1 is only valid on floor four")
	if not seed_source is Object or not seed_source.has_method("get_main_seed") or not seed_source.has_method("get_stream"):
		return _fail("seed_source must expose get_main_seed/get_stream")
	var main_seed: Variant = seed_source.get_main_seed()
	if not main_seed is String or main_seed.is_empty():
		return _fail("seed_source must already have an initialized main seed")
	if c.has("template"):
		# Fixed geometry consumes no layout, node, transition or height draws.
		# The supplied main seed remains the run identity, not a layout input.
		var result: Dictionary = SummitTemplate.build(main_seed, map_id)
		result.generator_version = VERSION
		result.generation_config = c
		return result
	var failures: Array = []
	var best: Dictionary = {}
	var best_data: Dictionary = {}
	var best_score := -INF
	var candidates: Array = []
	for attempt in MAX_ATTEMPTS:
		var layout: Variant = seed_source.get_stream(Domains.MAP_LAYOUT, [map_id], attempt)
		var types: Variant = seed_source.get_stream(Domains.MAP_NODES, [map_id], attempt)
		if layout == null or types == null:
			return _fail("Could not acquire map random streams")
		var plan: Dictionary = _make_plan(layout, c)
		var positions: Dictionary = _embed(plan, layout)
		if positions.is_empty():
			failures.append("compact induced-tree embedding rejected")
			continue
		var data: Dictionary = _scaffold(plan, positions, layout)
		if data.is_empty() or not _assign_types(data, types, c):
			failures.append("node type allocation rejected")
			continue
		_walk_contour(data, layout, c)
		var quality: Dictionary = _validate(data, c)
		if not quality.ok:
			failures.append(quality.error)
			continue
		var transitions: Dictionary = {"requested_count": c.transition_count, "applied_count": 0, "skipped_count": c.transition_count, "operations": []}
		if c.transition_count > 0:
			var transition_rng: Variant = seed_source.get_stream(Domains.MAP_TRANSITIONS, [map_id], attempt)
			if transition_rng == null:
				return _fail("Could not acquire map.transitions stream")
			transitions = _apply_transitions(data, transition_rng, c)
		quality = _validate(data, c)
		if not quality.ok:
			failures.append(quality.error)
			continue
		last_error = ""
		var result: Dictionary = _snapshot(data, str(main_seed), map_id, floor_index)
		if c.cell_space != 1:
			var space_rng: Variant = seed_source.get_stream(&"map.cell_space", [map_id], attempt)
			if space_rng == null:
				return _fail("Could not acquire map.cell_space stream")
			result = SpaceRefiner.new().apply(result, space_rng, c.space_jitter,c.cell_space)
		result.generator_version = VERSION
		result.generation_config = c
		result.generation_attempt = attempt
		result.generation_quality = quality
		result.generation_quality.transitions = transitions
		# Default remains first-valid, preserving existing seed layouts. Optional
		# bounded selection compares only maps which pass ALL gameplay rules.
		if c.layout_candidates == 1:
			return _compact_result(seed_source, result, data, c)
		var selection := _relief_layout_score(data, quality)
		candidates.append({"attempt":attempt,"score":selection.score,"compactness":quality.shape.compactness,"near_detour_steps":selection.near_detour_steps})
		if selection.score > best_score + 0.0000001:
			best = result
			best_score = selection.score
			if c.get("layout_profile", "legacy") == "compact" or c.get("route_profile", "legacy") == "switchback":
				best_data = data.duplicate(true)
		if candidates.size() >= c.layout_candidates:
			break
	if not best.is_empty():
		best.generation_quality.layout_selection = {"version":"compact-relief-layout-v1","requested":c.layout_candidates,"evaluated":candidates.size(),"chosen_attempt":best.generation_attempt,"score":best_score,"candidates":candidates}
		last_error=""
		return _compact_result(seed_source, best, best_data, c)
	return _fail("WALK generation exhausted %d bounded attempts: %s" % [MAX_ATTEMPTS, str(failures)])


func _compact_metric(data: Dictionary, include_shape: bool = true) -> Dictionary:
	# Symmetric three-axis envelope avoids a camera-specific packing direction.
	# The secondary objective brings room centres together without rewarding
	# extra corridor cells merely for filling an empty bay.
	var spans: Array = _axial_spans(data.floor)
	var centers: Dictionary = _centers(data)
	var centroid := Vector2.ZERO
	for p: Vector2i in centers.values():
		centroid += Vector2(p.x + p.y * 0.5, p.y * sqrt(3.0) * 0.5)
	centroid /= centers.size()
	var spread := 0.0
	for p: Vector2i in centers.values():
		spread += Vector2(p.x + p.y * 0.5, p.y * sqrt(3.0) * 0.5).distance_squared_to(centroid)
	var envelope: float = (spans[0]+1) * (spans[1]+1) + (spans[1]+1) * (spans[2]+1) + (spans[0]+1) * (spans[2]+1)
	var metric := {"score": envelope + spread * 0.10, "axial_envelope": envelope, "node_spread": spread}
	if include_shape:
		metric["shape"] = _shape(data.floor)
	return metric


func _compact_result(seed_source, original: Dictionary, data: Dictionary, c: Dictionary) -> Dictionary:
	if c.get("layout_profile", "legacy") != "compact":
		return _switchback_result(seed_source, original, data, c, original)
	var base_floor: Dictionary = data.floor.duplicate()
	var base_centers: Dictionary = _centers(data)
	var costs: Dictionary = {}
	for node: Dictionary in data.nodes:
		costs[node.id] = _transition_route(base_floor, base_centers[node.parent_id], base_centers[node.id]).cost
	var before: Dictionary = _compact_metric(data)
	var operations: Array = []
	var considered := 0
	var transitions: Dictionary = original.generation_quality.transitions.duplicate(true)
	for sweep in COMPACT_MOVES:
		var current: Dictionary = _compact_metric(data, false)
		var relocation: Dictionary = _relocation_context(data)
		var best: Dictionary = {}
		var best_score: float = current.score
		# Node and axial-direction order are stable; no layout or content stream
		# is consumed. The already selected logical plan and attempt stay intact.
		for node: Dictionary in data.nodes:
			if node.is_route_gate:
				continue
			for delta: Vector2i in Hex.DIRS:
				considered += 1
				var trial: Dictionary = _relocate(data, node.id, delta, relocation)
				if trial.is_empty():
					continue
				var metric: Dictionary = _compact_metric(trial, false)
				if metric.score >= best_score - 0.000001 or metric.axial_envelope > current.axial_envelope or trial.floor.size() > base_floor.size() + 6:
					continue
				var centers: Dictionary = _centers(trial)
				var valid := true
				# Preserve route capacity for relief: packing may bend a connection,
				# but never shorten any original owner-to-owner traversal cost.
				for other: Dictionary in trial.nodes:
					if _transition_route(trial.floor, centers[other.parent_id], centers[other.id]).cost < costs[other.id]:
						valid = false
						break
				# Declared transition buffers remain exactly +1 after every move.
				for operation: Dictionary in transitions.operations:
					if _transition_route(trial.floor, centers[operation.from], centers[operation.to]).cost != operation.after_cost:
						valid = false
						break
				if not valid or not _validate(trial, c).ok:
					continue
				best = trial
				best_score = metric.score
		if best.is_empty():
			break
		operations.append(best.transition_move)
		data.floor = best.floor
		data.domains = best.domains
		data.nodes = best.nodes
	if operations.is_empty():
		original.generation_quality.layout_compaction = {"version": "room-packing-v1", "applied_moves": 0, "placements_considered": considered, "before": before, "after": before, "operations": []}
		return _switchback_result(seed_source, original, data, c, original)
	var result: Dictionary = _snapshot(data, original.seed, original.map_id, original.floor_index)
	if c.cell_space != 1:
		# Legacy refinement was already evaluated as part of candidate selection.
		# Compact refinement has its own address; it cannot perturb legacy draws.
		var refinement_rng: Variant = seed_source.get_stream(&"map.compact_refinement", [original.map_id], original.generation_attempt)
		if refinement_rng == null:
			return _fail("Could not acquire map.compact_refinement stream")
		result = SpaceRefiner.new().apply(result, refinement_rng, c.space_jitter,c.cell_space)
	for key in ["generator_version", "generation_config", "generation_attempt"]:
		result[key] = original[key]
	result.generation_quality = _validate(data, c)
	# Paths are refreshed against final geometry; baseline cost and original
	# transition history remain available for exact gain verification.
	var final_centers: Dictionary = _centers(data)
	for operation: Dictionary in transitions.operations:
		var measured: Dictionary = _transition_route(data.floor, final_centers[operation.from], final_centers[operation.to])
		operation.after_cost = measured.cost
		operation.gain = measured.cost - operation.before_cost
		operation.path = _points(measured.path)
	result.generation_quality.transitions = transitions
	if original.generation_quality.has("layout_selection"):
		result.generation_quality.layout_selection = original.generation_quality.layout_selection
	result.generation_quality.layout_compaction = {"version": "room-packing-v1", "applied_moves": operations.size(), "placements_considered": considered, "before": before, "after": _compact_metric(data), "operations": operations, "policy": "whole rooms only; exact tree and four gate masks; no shorter original owner route; exact transition gains"}
	return _switchback_result(seed_source, result, data, c, original)


func _switchback_walk(state: Dictionary, path: Array, directions: Array, turns: int) -> void:
	state.steps += 1
	if state.steps > 10000 or state.found.size() >= 16:
		return
	var point: Vector2i = path.back()
	if state.goals.has(point):
		if path.size() >= 5 and path.size() <= 10 and turns >= 2 and turns <= 4:
			state.found.append({"path": path.duplicate(), "turns": turns})
		return
	if path.size() >= 10:
		return
	var choices: Array = []
	for index in 6:
		var next: Vector2i = point + Hex.DIRS[index]
		if not state.allowed.has(next) or next in path or state.allowed[next].has(state.from_id):
			continue
		var chord := false
		for neighbor: Vector2i in Hex.neighbors(next):
			if neighbor != point and neighbor in path:
				chord = true
		if chord:
			continue
		var next_turns: int = turns + (1 if not directions.is_empty() and directions.back() != index else 0)
		if next_turns > 4:
			continue
		var distance := 1000000
		for goal: Vector2i in state.goals:
			distance = mini(distance, Hex.distance(next, goal))
		if path.size() + distance > 10:
			continue
		choices.append({"point": next, "direction": index, "turns": next_turns, "distance": distance})
	choices.sort_custom(func(a,b): return a.distance < b.distance if a.distance != b.distance else a.direction < b.direction)
	for choice: Dictionary in choices:
		path.append(choice.point)
		directions.append(choice.direction)
		_switchback_walk(state, path, directions, choice.turns)
		path.pop_back()
		directions.pop_back()
		if state.steps > 10000 or state.found.size() >= 16:
			return


func _switchback_path(data: Dictionary, removed: Dictionary, from_id: String, to_id: String) -> Dictionary:
	var floor_cells: Dictionary = data.floor.duplicate()
	for point: Vector2i in removed: floor_cells.erase(point)
	var lows: Array = [1000000,1000000,1000000]
	var highs: Array = [-1000000,-1000000,-1000000]
	for point: Vector2i in data.floor:
		var values: Array = [point.x,point.y,point.x+point.y]
		for i in 3:
			lows[i] = mini(lows[i],values[i]-1)
			highs[i] = maxi(highs[i],values[i]+1)
	var allowed: Dictionary = {}
	var starts: Dictionary = {}
	var goals: Dictionary = {}
	for q in range(lows[0],highs[0]+1):
		for r in range(lows[1],highs[1]+1):
			var point := Vector2i(q,r)
			if floor_cells.has(point) or q+r < lows[2] or q+r > highs[2]:
				continue
			var incident: Dictionary = {}
			var safe := true
			for n: Vector2i in Hex.neighbors(point):
				if not floor_cells.has(n):
					continue
				var owner: String = floor_cells[n]
				if owner != from_id and owner != to_id:
					safe = false
					break
				incident[owner] = true
			if safe:
				allowed[point] = incident
				if incident.size() == 1 and incident.has(from_id): starts[point] = true
				if incident.size() == 1 and incident.has(to_id): goals[point] = true
	if goals.is_empty():
		return {}
	var state: Dictionary = {"allowed":allowed,"goals":goals,"from_id":from_id,"steps":0,"found":[]}
	for start: Vector2i in _sorted(starts):
		_switchback_walk(state,[start],[],0)
		if state.steps > 10000 or state.found.size() >= 16: break
	if state.found.is_empty():
		return {}
	state.found.sort_custom(func(a,b): return absi(a.path.size()-7) < absi(b.path.size()-7) if a.path.size() != b.path.size() else a.turns < b.turns)
	return state.found[0]


func _snapshot_bbox(snapshot: Dictionary) -> float:
	var low := Vector2(INF,INF)
	var high := Vector2(-INF,-INF)
	for cell: Dictionary in snapshot.cells:
		if cell.terrain != "ground": continue
		var p := Vector2(float(cell.q)+float(cell.r)*0.5,float(cell.r)*sqrt(3.0)*0.5)
		low = low.min(p)
		high = high.max(p)
	return (high.x-low.x+1.0)*(high.y-low.y+2.0/sqrt(3.0))


func _fine_shortest(ground: Dictionary, starts: Array, goals: Dictionary) -> Array:
	var queue: Array = starts.duplicate()
	var previous: Dictionary = {}
	for point: Vector2i in starts: previous[point] = point
	var cursor := 0
	while cursor < queue.size():
		var point: Vector2i = queue[cursor]
		cursor += 1
		if goals.has(point):
			var path: Array = [point]
			while previous[path.back()] != path.back(): path.append(previous[path.back()])
			path.reverse()
			return path
		for n: Vector2i in Hex.neighbors(point):
			if ground.has(n) and not previous.has(n):
				previous[n] = point
				queue.append(n)
	return []


func _switchback_result(seed_source, original: Dictionary, data: Dictionary, c: Dictionary, legacy: Dictionary) -> Dictionary:
	if c.get("route_profile", "legacy") != "switchback":
		return original
	var empty: Dictionary = {}
	for point: Vector2i in data.floor:
		if str(data.floor[point]).is_empty(): empty[point] = true
	var parts: Array = _components(empty)
	parts.sort_custom(func(a,b): return a.size() < b.size() if a.size() != b.size() else str(_sorted(a).front()) < str(_sorted(b).front()))
	var by_id: Dictionary = {}
	for node: Dictionary in data.nodes: by_id[node.id] = node
	var result: Dictionary = original
	var operations: Array = []
	var centers: Dictionary = _centers(data)
	for part: Dictionary in parts:
		if operations.size() >= 2: break
		var incident: Dictionary = _incident(data.floor, part)
		var ids: Array = _ids(incident)
		if ids.size() != 2 or "spawn" in ids or by_id[ids[0]].is_route_gate or by_id[ids[1]].is_route_gate or by_id[ids[0]].unlock_gates != by_id[ids[1]].unlock_gates:
			continue
		var found: Dictionary = _switchback_path(data, part, ids[0], ids[1])
		if found.is_empty(): continue
		var trial: Dictionary = data.duplicate(true)
		for point: Vector2i in part: trial.floor.erase(point)
		for point: Vector2i in found.path:
			trial.floor[point] = ""
			trial.domains[point] = by_id[ids[0]].unlock_gates.duplicate()
		if not _validate(trial,c).ok: continue
		var candidate: Dictionary = _snapshot(trial, original.seed, original.map_id, original.floor_index)
		if c.cell_space != 1:
			var refinement_rng: Variant = seed_source.get_stream(&"map.switchback_refinement",[original.map_id,ids[0],ids[1]],original.generation_attempt)
			if refinement_rng == null: return _fail("Could not acquire map.switchback_refinement stream")
			candidate = SpaceRefiner.new().apply(candidate,refinement_rng,c.space_jitter,c.cell_space)
		# A local outer-wall stair may use one extra coarse row, but it must fit
		# inside the original legacy map's total footprint area.
		if _snapshot_bbox(candidate) > _snapshot_bbox(legacy) + 0.000001: continue
		var before: int = _transition_route(data.floor,centers[ids[0]],centers[ids[1]]).cost
		var after: int = _transition_route(trial.floor,centers[ids[0]],centers[ids[1]]).cost
		operations.append({"from_id":ids[0],"to_id":ids[1],"coarse_path":_points(found.path),"turns":found.turns,"base_buffer_cost":before,"stairs_cost":after,"stairs_additional_cost":after-before})
		data.floor = trial.floor
		data.domains = trial.domains
		result = candidate
	if operations.is_empty():
		original.height_recipe = {"version":"switchback-v1","climbs":[]}
		original.generation_quality.switchbacks = {"version":"switchback-v1","applied_count":0,"connections":[],"fallback":"no bounded local connector passed exact topology and footprint limits"}
		return original
	for key in ["generator_version","generation_config","generation_attempt"]: result[key] = original[key]
	result.generation_quality = _validate(data,c)
	for key in ["transitions","layout_selection","layout_compaction"]:
		if original.generation_quality.has(key): result.generation_quality[key] = original.generation_quality[key]
	var ground: Dictionary = {}
	for cell: Dictionary in result.cells:
		if cell.terrain == "ground": ground[Vector2i(cell.q,cell.r)] = true
	var nodes: Dictionary = {}
	for node: Dictionary in result.nodes: nodes[node.id] = node
	var climbs: Array = []
	for operation: Dictionary in operations:
		var a: Dictionary = nodes[operation.from_id]
		var b: Dictionary = nodes[operation.to_id]
		var start := Vector2i(a.coord[0],a.coord[1])
		var goal := Vector2i(b.coord[0],b.coord[1])
		var path: Array = _fine_shortest(ground,[start],{goal:true})
		var region_a: Dictionary = {}
		var region_b: Dictionary = {}
		for point: Array in a.footprint: region_a[Vector2i(point[0],point[1])] = true
		for point: Array in b.footprint: region_b[Vector2i(point[0],point[1])] = true
		var boundary: Array = _fine_shortest(ground,_sorted(region_a),region_b)
		operation.shortest_center_edges = path.size()-1
		operation.shortest_boundary_edges = boundary.size()-1
		climbs.append({"from_id":operation.from_id,"to_id":operation.to_id,"path":_points(path)})
	result.height_recipe = {"version":"switchback-v1","climbs":climbs}
	result.generation_quality.switchbacks = {"version":"switchback-v1","applied_count":operations.size(),"connections":operations,"base_buffer_phase":original.generation_quality.transitions.duplicate(true),"base_attempt":original.generation_attempt,"legacy_bbox_area":_snapshot_bbox(legacy),"final_bbox_area":_snapshot_bbox(result),"policy":"at most two existing tree edges; no room movement; induced coarse paths; one-row axial margin per connector, at most two rows total; final area no larger than legacy"}
	var transitions: Dictionary = original.generation_quality.transitions.duplicate(true)
	var final_centers: Dictionary = _centers(data)
	for operation: Dictionary in transitions.operations:
		var measured: Dictionary = _transition_route(data.floor,final_centers[operation.from],final_centers[operation.to])
		operation.base_buffer_after_cost = operation.after_cost
		operation.base_buffer_gain = operation.gain
		operation.stairs_additional_cost = measured.cost-operation.after_cost
		operation.after_cost = measured.cost
		operation.gain = measured.cost-operation.before_cost
		operation.path = _points(measured.path)
	transitions.policy = "base buffer exactly +1; final cost and path include separately declared local switchback additions"
	result.generation_quality.transitions = transitions
	return result


func _relief_layout_score(data: Dictionary, quality: Dictionary) -> Dictionary:
	# High local detour capacity allows close-but-separated branches to carry
	# different elevations. Density outranks it; empty bays do not earn reward.
	var maximum := 0
	var adjacent: Dictionary = {}
	var ring: Array[Vector2i] = []
	for q in range(-2,3):
		for r in range(-2,3):
			var delta := Vector2i(q,r)
			if Hex.distance(Vector2i.ZERO,delta)==2: ring.append(delta)
	for cell: Vector2i in data.floor:
		var neighbors: Array[Vector2i] = []
		for n: Vector2i in Hex.neighbors(cell):
			if data.floor.has(n): neighbors.append(n)
		adjacent[cell] = neighbors
	for start: Vector2i in data.floor:
		var targets: Dictionary = {}
		for delta: Vector2i in ring:
			if data.floor.has(start+delta): targets[start+delta]=true
		var distances: Dictionary = {start:0}
		var queue: Array = [start]
		var cursor := 0
		while cursor < queue.size() and not targets.is_empty():
			var here: Vector2i = queue[cursor]; cursor += 1
			for n: Vector2i in adjacent[here]:
				if distances.has(n): continue
				var distance: int = int(distances[here])+1
				distances[n] = distance; queue.append(n)
				if targets.erase(n): maximum = maxi(maximum,distance)
	var shape: Dictionary = quality.shape
	var score: float = 12.0*shape.compactness-.4*shape.elongation-.4*shape.oriented_aspect-8.0*shape.outer_tail_excess+.025*mini(24,maximum)
	return {"score":score,"near_detour_steps":maximum}


func _fail(message: String) -> Dictionary:
	last_error = message
	return {}


func _rand(rng) -> float:
	return float(rng.int_range(0, 1000000)) / 1000000.0


func _sorted(cells: Dictionary) -> Array:
	var keys: Array = cells.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	return keys


func _ids(items: Dictionary) -> Array:
	var keys: Array = items.keys()
	keys.sort()
	return keys


func _disk(center: Vector2i, radius: int = 1) -> Array:
	var result: Array = []
	for q in range(-radius, radius + 1):
		for r in range(maxi(-radius, -q - radius), mini(radius, -q + radius) + 1):
			result.append(center + Vector2i(q, r))
	return result


func _line(a: Vector2i, b: Vector2i) -> Array:
	var result: Array = []
	var count: int = Hex.distance(a, b)
	for i in count + 1:
		var t: float = float(i) / count if count else 0.0
		var c: Vector2i = Hex._round_axial(lerpf(a.x, b.x, t) + 0.000001, lerpf(a.y, b.y, t) + 0.000002)
		if c not in result:
			result.append(c)
	return result


func _flood(floor_cells: Dictionary, start: Vector2i, blocked: Dictionary = {}) -> Dictionary:
	var reached: Dictionary = {}
	if not floor_cells.has(start) or blocked.has(start):
		return reached
	var queue: Array = [start]
	reached[start] = true
	var index := 0
	while index < queue.size():
		for n in Hex.neighbors(queue[index]):
			if floor_cells.has(n) and not blocked.has(n) and not reached.has(n):
				reached[n] = true
				queue.append(n)
		index += 1
	return reached


func _components(cells: Dictionary) -> Array:
	var remaining: Dictionary = cells.duplicate()
	var result: Array = []
	for start in _sorted(cells):
		if not remaining.has(start):
			continue
		var part: Dictionary = _flood(cells, start)
		for k in part:
			remaining.erase(k)
		result.append(part)
	return result


func _add(plan: Dictionary, parent: String) -> String:
	var id := "node-%02d" % plan.vertices.size()
	plan.vertices[id] = {"id": id, "parent_id": parent, "is_route_gate": false, "unlock_gates": []}
	plan.children[id] = []
	plan.children[parent].append(id)
	return id


func _branch(plan: Dictionary, parent: String, budget: int, rng, balanced: bool = false) -> String:
	var head: String = _add(plan, parent)
	if budget == 1:
		return head
	var stem: String = _add(plan, head)
	if budget == 2:
		return head
	if budget == 3:
		_add(plan, stem)
		return head
	var a: String = _add(plan, stem)
	var b: String = _add(plan, stem)
	var remaining: int = budget - 4
	if balanced:
		_balanced(plan, a, remaining / 2)
		_balanced(plan, b, remaining - remaining / 2)
	else:
		var pool: Array = [a, b]
		for i in remaining:
			var entries: Array = []
			for id in pool:
				if plan.children[id].size() < 2:
					entries.append({"value": id, "weight": 2.5 if plan.children[id].is_empty() else 1.0})
			pool.append(_add(plan, str(rng.weighted_pick(entries))))
	return head


func _balanced(plan: Dictionary, parent: String, budget: int) -> void:
	if budget < 4:
		for i in budget:
			parent = _add(plan, parent)
		return
	var left: int = budget / 2
	var a: String = _add(plan, parent)
	var b: String = _add(plan, parent)
	_balanced(plan, a, left - 1)
	_balanced(plan, b, budget - left - 1)


func _make_plan(rng, c: Dictionary) -> Dictionary:
	var count: int = c.normal + c.elite + c.events + 1
	var plan: Dictionary = {"vertices": {"spawn": {"id": "spawn", "parent_id": "", "is_route_gate": false, "unlock_gates": []}}, "children": {"spawn": []}}
	var chain_length: int = maxi(c.min_boss_content_nodes + 1, mini(7 + int(rng.pick([-1, 0, 1])), count - 6))
	var chain: Array = []
	var parent := "spawn"
	for i in chain_length:
		parent = _add(plan, parent)
		chain.append(parent)
	var boss: String = chain.back()
	plan.boss = boss
	var left: int = count - chain_length
	var root_budget: int = 4 if left >= 6 else 1
	if left >= 7:
		root_budget = maxi(4, mini(left - 2, root_budget + int(rng.pick([-1, 0, 1]))))
	root_budget = mini(root_budget, left - 2)
	var attach_index: int = int(rng.int_range(1, chain.size() - 2)) if chain.size() >= 4 else 1
	var side_head: String = _branch(plan, str(chain[mini(attach_index, chain.size() - 2)]), left - root_budget, rng, true)
	var root_head: String = _branch(plan, "spawn", root_budget, rng)
	# Reattach a singleton beside a substantial branch to a leaf of that branch.
	for pass_index in count:
		if _tree_metrics(plan).singleton_side_branches <= maxi(1, count / 10):
			break
		var moved := false
		for id in _ids(plan.vertices):
			var kids: Array = plan.children[id]
			if kids.size() != 2:
				continue
			var single := ""
			var other := ""
			for child in kids:
				if child != boss and plan.children[child].is_empty():
					single = child
				else:
					other = child
			if single.is_empty() or other.is_empty() or plan.children[other].is_empty():
				continue
			var leaves: Array = []
			_collect_leaves(plan, other, boss, leaves)
			if leaves.is_empty():
				continue
			leaves.sort()
			var target: String = str(rng.pick(leaves))
			plan.children[id].erase(single)
			plan.children[target].append(single)
			plan.vertices[single].parent_id = target
			moved = true
			break
		if not moved:
			break
	plan.pattern = str(rng.pick(["parallel", "nested"]))
	var main_gate: String = str(chain[0] if plan.pattern == "nested" else chain[mini(attach_index + 1, chain.size() - 2)])
	plan.vertices[main_gate].is_route_gate = true
	var other_gate: String = str(plan.children[root_head][0]) if plan.pattern == "parallel" and chain.size() < 4 else side_head
	plan.vertices[other_gate].is_route_gate = true
	# Public IDs, owner proofs, and transit metadata use the same Boss identity.
	plan.vertices["boss-1"] = plan.vertices[boss]
	plan.vertices["boss-1"].id = "boss-1"
	plan.vertices.erase(boss)
	plan.children["boss-1"] = plan.children[boss]
	plan.children.erase(boss)
	for id in _ids(plan.vertices):
		if plan.vertices[id].parent_id == boss:
			plan.vertices[id].parent_id = "boss-1"
		var child_index: int = plan.children[id].find(boss)
		if child_index >= 0:
			plan.children[id][child_index] = "boss-1"
	plan.boss = "boss-1"
	_set_unlocks(plan, "spawn", [])
	return plan


func _collect_leaves(plan: Dictionary, id: String, excluded: String, result: Array) -> void:
	if id == excluded:
		return
	if plan.children[id].is_empty():
		result.append(id)
	for child in plan.children[id]:
		_collect_leaves(plan, child, excluded, result)


func _set_unlocks(plan: Dictionary, id: String, unlocks: Array) -> void:
	plan.vertices[id].unlock_gates = unlocks.duplicate()
	var next: Array = unlocks.duplicate()
	if plan.vertices[id].is_route_gate:
		next.append(id)
	for child in plan.children[id]:
		_set_unlocks(plan, child, next)


func _subtree(plan: Dictionary, id: String, sizes: Dictionary, depths: Dictionary, depth: int = 0) -> int:
	depths[id] = depth
	var size := 1
	for child in plan.children[id]:
		size += _subtree(plan, child, sizes, depths, depth + 1)
	sizes[id] = size
	return size


func _tree_metrics(plan: Dictionary) -> Dictionary:
	var sizes: Dictionary = {}
	var depths: Dictionary = {}
	_subtree(plan, "spawn", sizes, depths)
	var result: Dictionary = {"useful_forks": 0, "substantial_forks": 0, "singleton_side_branches": 0}
	for id in _ids(plan.vertices):
		var children: Array = plan.children[id]
		if children.size() < 2:
			continue
		var substantial := 0
		var singleton := 0
		for child in children:
			if sizes[child] >= 2:
				substantial += 1
			else:
				singleton += 1
		if depths[id] >= 2:
			result.useful_forks += 1
			if substantial >= 2:
				result.substantial_forks += 1
		if substantial:
			result.singleton_side_branches += singleton
	return result


func _order(plan: Dictionary, id: String, sizes: Dictionary, result: Array) -> void:
	result.append(id)
	var children: Array = plan.children[id].duplicate()
	children.sort_custom(func(a, b): return a < b if sizes[a] == sizes[b] else sizes[a] > sizes[b])
	for child in children:
		_order(plan, child, sizes, result)


func _shape(cells: Dictionary) -> Dictionary:
	var points: Array = []
	var center := Vector2.ZERO
	for c in _sorted(cells):
		var p := Vector2(c.x + c.y * 0.5, c.y * sqrt(3.0) * 0.5)
		points.append(p)
		center += p
	center /= points.size()
	var xx := 0.0
	var yy := 0.0
	var xy := 0.0
	var radial: Array = []
	for point in points:
		var p: Vector2 = point - center
		xx += p.x * p.x
		yy += p.y * p.y
		xy += p.x * p.y
		radial.append(p.length())
	xx /= points.size()
	yy /= points.size()
	xy /= points.size()
	var root: float = sqrt((xx - yy) * (xx - yy) + 4.0 * xy * xy)
	var hi: float = (xx + yy + root) * 0.5
	var lo: float = (xx + yy - root) * 0.5
	var angle: float = 0.5 * atan2(2.0 * xy, xx - yy)
	var a := Vector2(cos(angle), sin(angle))
	var b := Vector2(-a.y, a.x)
	var w: float = _span(points, a)
	var h: float = _span(points, b)
	radial.sort()
	var body_radius: float = maxf(1.0, radial[int((radial.size() - 1) * 0.75)])
	var tail := 0.0
	for radius in radial:
		tail += pow(maxf(0.0, radius / body_radius - 1.35), 2.0)
	return {"elongation": sqrt(hi / lo) if lo > 0.000000001 else INF, "oriented_aspect": maxf(w / h, h / w), "compactness": points.size() * sqrt(3.0) * 0.5 / (w * h), "outer_tail_excess": tail / points.size()}


func _span(points: Array, axis: Vector2) -> float:
	var low := INF
	var high := -INF
	for p in points:
		var d: float = p.dot(axis)
		low = minf(low, d)
		high = maxf(high, d)
	var extent := 0.0
	for i in 6:
		extent = maxf(extent, absf(Vector2.from_angle(PI / 6.0 + i * PI / 3.0).dot(axis)) / sqrt(3.0))
	return high - low + extent * 2.0


func _straight_length(plan: Dictionary, positions: Dictionary, id: String, direction: Vector2i) -> int:
	var length := 1
	var ancestor: String = plan.vertices[id].parent_id
	while not ancestor.is_empty() and not plan.vertices[ancestor].parent_id.is_empty():
		var parent: String = plan.vertices[ancestor].parent_id
		if positions[ancestor] - positions[parent] != direction:
			break
		length += 1
		ancestor = parent
	return length


func _place(state: Dictionary, index: int) -> bool:
	if index == state.order.size():
		state.solution = state.positions.duplicate()
		return true
	state.steps += 1
	if state.steps > 1600:
		return false
	var id: String = state.order[index]
	var parent: String = state.plan.vertices[id].parent_id
	var p: Vector2i = state.positions[parent]
	var grand: String = state.plan.vertices[parent].parent_id
	var centroid := Vector2.ZERO
	for point in state.occupied:
		centroid += Vector2(point)
	centroid /= state.occupied.size()
	var coarse_index: PackedInt32Array=state.coarse_index
	var coarse_offsets: PackedInt32Array=state.coarse_offsets
	var coarse_stride: int=state.coarse_stride
	var coarse_origin: int=state.coarse_origin
	var parent_index: int=coarse_origin+p.x+p.y*coarse_stride
	var choices: Array = []
	for direction_index in Hex.DIRS.size():
		var direction: Vector2i=Hex.DIRS[direction_index]
		var k: Vector2i = p + direction
		# Low three bits count occupied neighbors; bit three marks occupancy.
		# A value of one is an empty cell touching only the occupied parent p.
		var candidate_index: int=parent_index+coarse_offsets[direction_index]
		if coarse_index[candidate_index]!=1:
			continue
		var free := 0
		for offset: int in coarse_offsets:
			# k is not occupied yet. Zero means both an empty cell and no
			# occupied neighbor, exactly the old _coarse_clear(n,k) condition.
			if coarse_index[candidate_index+offset]==0:
				free += 1
		if free < state.plan.children[id].size():
			continue
		var distance: int = Hex.distance(k, Vector2i.ZERO)
		var score: float = distance * distance * 0.6 + Vector2(k).distance_to(centroid) * 0.15 - free * 0.15
		if not grand.is_empty():
			var previous: Vector2i = p - state.positions[grand]
			var turn: int = previous.x * direction.y - previous.y * direction.x
			score += turn * (-0.34 if index % 2 else 0.34) + turn * (-0.7 if state.trial % 2 else 0.7)
		var straight: int = _straight_length(state.plan, state.positions, id, direction)
		score += maxi(0, straight - 2) * 1.2
		choices.append({"point": k, "score": score + _rand(state.rng) * (1.8 if state.trial < 8 else 3.5)})
	choices.sort_custom(func(a, b): return a.score < b.score if a.score != b.score else a.point.x < b.point.x or (a.point.x == b.point.x and a.point.y < b.point.y))
	for choice in choices:
		state.positions[id] = choice.point
		state.occupied[choice.point] = true
		var point_index: int=coarse_origin+int(choice.point.x)+int(choice.point.y)*coarse_stride
		coarse_index[point_index]+=8
		for offset: int in coarse_offsets:coarse_index[point_index+offset]+=1
		if _place(state, index + 1):
			return true
		state.positions.erase(id)
		state.occupied.erase(choice.point)
		coarse_index[point_index]-=8
		for offset: int in coarse_offsets:coarse_index[point_index+offset]-=1
		if state.steps > 1600:
			break
	return false


func _coarse_clear(point: Vector2i, parent: Vector2i, occupied: Dictionary) -> bool:
	for n in Hex.neighbors(point):
		if n != parent and occupied.has(n):
			return false
	return true


func _embed(plan: Dictionary, rng) -> Dictionary:
	var sizes: Dictionary = {}
	var depths: Dictionary = {}
	_subtree(plan, "spawn", sizes, depths)
	var depth_order: Array = []
	_order(plan, "spawn", sizes, depth_order)
	var breadth_order: Array = ["spawn"]
	var index := 0
	while index < breadth_order.size():
		var children: Array = plan.children[breadth_order[index]].duplicate()
		children.sort_custom(func(a, b): return a < b if sizes[a] == sizes[b] else sizes[a] > sizes[b])
		breadth_order.append_array(children)
		index += 1
	# Every placed coordinate is at most vertices.size()-1 steps from spawn.
	# Queries extend two steps beyond a placed parent; this private grid has
	# another guard cell and cannot truncate the original bounded search.
	var coarse_extent: int=plan.vertices.size()+2
	var coarse_stride: int=coarse_extent*2+1
	var coarse_origin: int=coarse_extent*coarse_stride+coarse_extent
	var coarse_offsets:=PackedInt32Array()
	for direction: Vector2i in Hex.DIRS:coarse_offsets.append(direction.x+direction.y*coarse_stride)
	var candidates: Array = []
	for trial in EMBEDDING_TRIALS:
		# Keep occupied's insertion order: the legacy centroid sums in that order.
		var coarse_index:=PackedInt32Array()
		coarse_index.resize(coarse_stride*coarse_stride)
		coarse_index[coarse_origin]=8
		for offset: int in coarse_offsets:coarse_index[coarse_origin+offset]=1
		var state: Dictionary = {"plan": plan, "rng": rng, "trial": trial, "order": breadth_order if trial % 3 == 2 else depth_order, "steps": 0, "positions": {"spawn": Vector2i.ZERO}, "occupied": {Vector2i.ZERO: true}, "coarse_index":coarse_index,"coarse_offsets":coarse_offsets,"coarse_stride":coarse_stride,"coarse_origin":coarse_origin}
		if not _place(state, 1):
			continue
		var tiles: Dictionary = {}
		var spread := 0.0
		var longest := 0
		var excess := 0
		for id in _ids(state.solution):
			var center: Vector2i = state.solution[id] * 3
			for k in [center] if plan.vertices[id].is_route_gate else _disk(center):
				tiles[k] = true
			var distance: int = Hex.distance(state.solution[id], Vector2i.ZERO)
			spread += distance * distance
			if id != "spawn":
				var parent: String = plan.vertices[id].parent_id
				var length: int = _straight_length(plan, state.solution, id, state.solution[id] - state.solution[parent])
				longest = maxi(longest, length)
				excess += maxi(0, length - 2)
		var shape: Dictionary = _shape(tiles)
		if shape.elongation > 1.76 or shape.oriented_aspect > 1.91:
			continue
		var score: float = shape.elongation * 2.0 + shape.oriented_aspect + spread / state.solution.size() * 0.065 - shape.compactness * 0.4 + excess * 0.35 + maxi(0, longest - 2) * 0.5 + shape.outer_tail_excess * 12.0
		candidates.append({"positions": state.solution, "score": score, "trial": trial})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b): return a.score < b.score if a.score != b.score else a.trial < b.trial)
	var entries: Array = []
	for candidate in candidates:
		if candidate.score <= candidates[0].score + 0.6 and entries.size() < 16:
			entries.append({"value": candidate.positions, "weight": exp(-(candidate.score - candidates[0].score) * 2.5)})
	var chosen: Dictionary = rng.weighted_pick(entries)
	var rotation: int = int(rng.int_range(0, 6))
	var result: Dictionary = {}
	for id in _ids(chosen):
		var k: Vector2i = chosen[id]
		for i in rotation:
			k = Vector2i(-k.y, k.x + k.y)
		result[id] = k * 3
	return result


func _scaffold(plan: Dictionary, positions: Dictionary, rng) -> Dictionary:
	var floor_cells: Dictionary = {}
	var domains: Dictionary = {}
	var nodes: Array = []
	var segments: Array = []
	for id in _ids(plan.vertices):
		var v: Dictionary = plan.vertices[id]
		var footprint: Array = [positions[id]] if v.is_route_gate else _disk(positions[id])
		for point in footprint:
			if floor_cells.has(point):
				return {}
			floor_cells[point] = id
			domains[point] = v.unlock_gates.duplicate()
		if id != "spawn":
			var node: Dictionary = v.duplicate(true)
			node.coord = positions[id]
			node.footprint = footprint
			nodes.append(node)
	for id in _ids(plan.vertices):
		var v: Dictionary = plan.vertices[id]
		if v.parent_id.is_empty():
			continue
		var path: Array = _line(positions[v.parent_id], positions[id])
		for point in path:
			if not floor_cells.has(point):
				floor_cells[point] = ""
				domains[point] = v.unlock_gates.duplicate()
		segments.append({"from": positions[v.parent_id], "to": positions[id], "path": path, "domain": v.unlock_gates.duplicate()})
	var gate_neighbors: Dictionary = {}
	for node in nodes:
		if node.is_route_gate:
			gate_neighbors[node.coord] = true
			for n in Hex.neighbors(node.coord):
				gate_neighbors[n] = true
	var allowed: Dictionary = floor_cells.duplicate()
	var candidates: Dictionary = {}
	for k in _sorted(floor_cells):
		var owner: String = floor_cells[k]
		if owner.is_empty() or plan.vertices[owner].is_route_gate:
			continue
		for n in Hex.neighbors(k):
			if not floor_cells.has(n) and not gate_neighbors.has(n):
				if not candidates.has(n):
					candidates[n] = {}
				candidates[n][owner] = true
	var shuffled: Array = _sorted(candidates)
	rng.shuffle_in_place(shuffled)
	for k in shuffled:
		if candidates[k].size() != 1:
			continue
		var owner: String = candidates[k].keys()[0]
		var safe := true
		for n in Hex.neighbors(k):
			if allowed.has(n) and allowed[n] != owner:
				safe = false
		if safe:
			allowed[k] = owner
			domains[k] = plan.vertices[owner].unlock_gates.duplicate()
	for segment in segments:
		var band: Dictionary = {}
		for k in segment.path:
			for n in _disk(k):
				if allowed.has(n) and (domains[n] == segment.domain or n in segment.path):
					band[n] = true
		segment.band = band
	return {"plan": plan, "floor": floor_cells, "required": floor_cells.duplicate(), "allowed": allowed, "domains": domains, "nodes": nodes, "segments": segments, "spawn": Vector2i.ZERO}


func _graph(data: Dictionary) -> Dictionary:
	var adjacency: Dictionary = {"spawn": {}}
	for node in data.nodes:
		adjacency[node.id] = {}
	var empty: Dictionary = {}
	for k in _sorted(data.floor):
		var owner: String = data.floor[k]
		if owner.is_empty():
			empty[k] = true
			continue
		for n in Hex.neighbors(k):
			if data.floor.has(n) and not str(data.floor[n]).is_empty() and data.floor[n] != owner:
				adjacency[owner][data.floor[n]] = true
				adjacency[data.floor[n]][owner] = true
	for part in _components(empty):
		var incident: Dictionary = _incident(data.floor, part)
		if incident.size() != 2:
			return {"ok": false, "error": "A transit component must connect exactly two owners"}
		var owners: Array = incident.keys()
		adjacency[owners[0]][owners[1]] = true
		adjacency[owners[1]][owners[0]] = true
	var edges: Array = []
	var ids: Array = adjacency.keys()
	ids.sort()
	for id in ids:
		var others: Array = adjacency[id].keys()
		others.sort()
		for other in others:
			if id < other:
				edges.append(id + "|" + other)
	return {"ok": true, "adjacency": adjacency, "edges": edges}


func _incident(floor_cells: Dictionary, part: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for k in _sorted(part):
		for n in Hex.neighbors(k):
			if floor_cells.has(n) and not str(floor_cells[n]).is_empty():
				result[floor_cells[n]] = true
	return result


func _event_run(adjacency: Dictionary, events: Dictionary) -> int:
	var maximum := 0
	for start in _ids(events):
		var queue: Array = [start]
		var distance: Dictionary = {start: 1}
		var index := 0
		while index < queue.size():
			var id: String = queue[index]
			maximum = maxi(maximum, distance[id])
			for other in _ids(adjacency[id]):
				if events.has(other) and not distance.has(other):
					distance[other] = distance[id] + 1
					queue.append(other)
			index += 1
	return maximum


func _allocations(movable: Array, combat_count: int, start: int, chosen: Array, result: Array) -> void:
	if chosen.size() == combat_count:
		for shop in movable:
			if shop not in chosen:
				result.append({"combat": chosen.duplicate(), "shop": shop})
		return
	for index in range(start, movable.size() - (combat_count - chosen.size()) + 1):
		chosen.append(movable[index])
		_allocations(movable, combat_count, index + 1, chosen, result)
		chosen.pop_back()


func _assign_types(data: Dictionary, rng, c: Dictionary) -> bool:
	var graph: Dictionary = _graph(data)
	if not graph.ok:
		return false
	var movable: Array = []
	var gates: Array = []
	var boss: String = data.plan.boss
	for node in data.nodes:
		if node.is_route_gate:
			gates.append(node.id)
		elif node.id != boss:
			movable.append(node.id)
	movable.sort()
	gates.sort()
	var combat_count: int = c.normal + c.elite - 2
	var allocations: Array = []
	# The default and gradual floor budgets fit bounded exhaustive allocation.
	if movable.size() <= 15 and combat_count <= 5:
		_allocations(movable, combat_count, 0, [], allocations)
	else:
		for sample in 4000:
			var shuffled: Array = movable.duplicate()
			rng.shuffle_in_place(shuffled)
			allocations.append({"combat": shuffled.slice(0, combat_count), "shop": shuffled[combat_count]})
	var eligible: Array = []
	var best_score := INF
	for allocation in allocations:
		var leaves := false
		for id in allocation.combat:
			if graph.adjacency[id].size() <= 1:
				leaves = true
		if leaves:
			continue
		var events: Dictionary = {}
		for id in movable:
			if id != allocation.shop and id not in allocation.combat:
				events[id] = true
		var run: int = _event_run(graph.adjacency, events)
		if run > 3:
			continue
		var triples := 0
		for id in _ids(events):
			var degree := 0
			for other in graph.adjacency[id]:
				if events.has(other):
					degree += 1
			triples += degree * (degree - 1) / 2
		var score: float = maxi(0, run - 2) * 10.0 + triples + (0.0 if graph.adjacency[allocation.shop].size() == 1 else 0.5)
		if score < best_score:
			best_score = score
			eligible.clear()
		if score == best_score:
			eligible.append(allocation)
	if eligible.is_empty():
		return false
	var chosen: Dictionary = rng.pick(eligible)
	var combats: Array = gates.duplicate()
	combats.append_array(chosen.combat)
	combats.sort()
	var tiers: Array = []
	for i in c.normal:
		tiers.append("battle")
	for i in c.elite:
		tiers.append("elite")
	rng.shuffle_in_place(tiers)
	var combat_types: Dictionary = {}
	for i in combats.size():
		combat_types[combats[i]] = tiers[i]
	var event_ids: Array = []
	for id in movable:
		if id not in chosen.combat and id != chosen.shop:
			event_ids.append(id)
	if c.get("content_profile", "legacy") == "alchemy_floor1":
		return _assign_alchemy_content(data, rng, chosen.shop, boss, combat_types, event_ids)
	if c.get("content_profile", "legacy") == "alchemy_floor1_pile":
		return _assign_alchemy_pile_content(data, rng, chosen.shop, boss, combat_types, event_ids)
	var subtypes: Array = ["herbs", "forge", "alchemy"]
	for i in c.events - 4:
		subtypes.append("random")
	rng.shuffle_in_place(subtypes)
	for node in data.nodes:
		node.type = "boss" if node.id == boss else "shop" if node.id == chosen.shop else str(combat_types.get(node.id, "event"))
		node.event_kind = subtypes[event_ids.find(node.id)] if node.type == "event" else "shop" if node.type == "shop" else ""
		node.content_id = "flat_2d/" + (node.event_kind if node.type == "event" else node.type)
		node.revisitable = node.type in ["event", "shop"]
	return true


func _assign_alchemy_content(data: Dictionary, rng, shop_id: String, boss_id: String, combat_types: Dictionary, event_ids: Array) -> bool:
	# The existing events budget includes a shop and a chest. Only the two
	# remaining slots draw identities, without replacement, from map.nodes.
	if event_ids.size() != 3:
		return false
	var chest_id: String = rng.pick(event_ids)
	var kinds: Array = AlchemyEvents.ids()
	rng.shuffle_in_place(kinds)
	var event_index := 0
	for node in data.nodes:
		node.type = "boss" if node.id == boss_id else "shop" if node.id == shop_id else "chest" if node.id == chest_id else str(combat_types.get(node.id, "event"))
		node.event_kind = ""
		node.content_id = "flat_2d/" + node.type
		if node.type == "event":
			node.event_kind = kinds[event_index]
			node.content_id = "alchemy/events/" + node.event_kind
			event_index += 1
		elif node.type == "shop":
			node.event_kind = "shop"
		node.revisitable = node.type in ["event", "shop"]
		if node.type == "event":
			node.body_capsule = NodeGeometry.event_capsule()
		else:
			node.body_radius = NodeGeometry.alchemy_radius(node.type)
	return event_index == 2


func _assign_alchemy_pile_content(data: Dictionary, rng, shop_id: String, boss_id: String, combat_types: Dictionary, service_ids: Array) -> bool:
	# The new profile adds one independent pile to the original content quota.
	# Pick both loot nodes before drawing the two actual event identities.
	if service_ids.size() != 4:
		return false
	var chest_id: String = rng.pick(service_ids)
	var pile_candidates: Array = service_ids.duplicate()
	pile_candidates.erase(chest_id)
	var pile_id: String = rng.pick(pile_candidates)
	var kinds: Array = AlchemyEvents.ids()
	rng.shuffle_in_place(kinds)
	var event_index := 0
	for node in data.nodes:
		node.type = "boss" if node.id == boss_id else "shop" if node.id == shop_id else "chest" if node.id == chest_id else "pile" if node.id == pile_id else str(combat_types.get(node.id, "event"))
		node.event_kind = ""
		node.content_id = "flat_2d/" + node.type
		if node.type == "event":
			node.event_kind = kinds[event_index]
			node.content_id = "alchemy/events/" + node.event_kind
			event_index += 1
		elif node.type == "shop":
			node.event_kind = "shop"
		node.revisitable = node.type in ["event", "shop"]
		if node.type == "event":
			node.body_capsule = NodeGeometry.event_capsule()
		else:
			node.body_radius = NodeGeometry.alchemy_radius(node.type)
	return event_index == 2


func _distances(band: Dictionary, goal: Vector2i) -> Dictionary:
	var distance: Dictionary = {goal: 0}
	var queue: Array = [goal]
	var index := 0
	while index < queue.size():
		for n in Hex.neighbors(queue[index]):
			if band.has(n) and not distance.has(n):
				distance[n] = distance[queue[index]] + 1
				queue.append(n)
		index += 1
	return distance


func _direction(a: Vector2i, b: Vector2i) -> int:
	return Hex.DIRS.find(b - a)


func _heading_gap(a: int, b: int) -> int:
	return mini(absi(a - b), 6 - absi(a - b))


func _repair_walk(floor_cells: Dictionary, allowed: Dictionary, band: Dictionary, position: Vector2i, goal: Vector2i, heading: int) -> void:
	var distance: Dictionary = _distances(band, goal)
	for step in band.size():
		if position == goal or not distance.has(position):
			return
		var candidates: Array = []
		for n in Hex.neighbors(position):
			if band.has(n) and distance.get(n, -1) == distance[position] - 1:
				candidates.append(n)
		candidates.sort_custom(func(a, b):
			var ga: int = _heading_gap(_direction(position, a), heading)
			var gb: int = _heading_gap(_direction(position, b), heading)
			return ga < gb if ga != gb else a.x < b.x or (a.x == b.x and a.y < b.y))
		if candidates.is_empty():
			return
		heading = _direction(position, candidates[0])
		position = candidates[0]
		floor_cells[position] = allowed[position]


func _walk_contour(data: Dictionary, rng, c: Dictionary) -> void:
	var floor_cells: Dictionary = {data.spawn: "spawn"}
	var headings: Dictionary = {}
	var brush_bands: Dictionary = {}
	for segment in data.segments:
		var band: Dictionary = segment.band
		var position: Vector2i = segment.from
		var heading: int = int(rng.int_range(0, 6))
		var distance: Dictionary = _distances(band, segment.to)
		for step in maxi(12, segment.path.size() * 5):
			if position == segment.to:
				break
			if _rand(rng) < 0.13:
				heading = (heading + int(rng.pick([-1, 1])) + 6) % 6
			var entries: Array = []
			for n in Hex.neighbors(position):
				if not band.has(n) or not distance.has(n):
					continue
				var delta: int = distance.get(position, 0) - distance[n]
				var weight: float = [7.0, 2.7, 0.65, 0.14][_heading_gap(_direction(position, n), heading)] * (3.5 if delta > 0 else 0.85 if delta == 0 else 0.22) * (0.65 if floor_cells.has(n) else 1.5)
				entries.append({"value": n, "weight": weight})
			if entries.is_empty():
				break
			var next: Vector2i = rng.weighted_pick(entries)
			heading = _direction(position, next)
			position = next
			floor_cells[position] = data.allowed[position]
			headings[position] = heading
			brush_bands[position] = band
		_repair_walk(floor_cells, data.allowed, band, position, segment.to, heading)
	# Every platform and true connection is authoritative required terrain.
	floor_cells.merge(data.required, true)
	var desired: int = mini(data.allowed.size(), roundi(data.required.size() + (data.allowed.size() - data.required.size()) * 0.18))
	var centers: Array = _sorted(floor_cells)
	for sweep in 3:
		rng.shuffle_in_place(centers)
		for center in centers:
			if floor_cells.size() >= desired:
				break
			if _rand(rng) > 0.82:
				continue
			var band: Dictionary = brush_bands.get(center, data.allowed)
			var flank: int = int(rng.pick([-1, 1]))
			var heading: int = (int(headings.get(center, 0)) + flank + int(rng.int_range(0, 2)) + 6) % 6
			var position: Vector2i = center
			for step in int(rng.int_range(1, 4)):
				if floor_cells.size() >= desired:
					break
				var entries: Array = []
				for n in Hex.neighbors(position):
					if band.has(n):
						entries.append({"value": n, "weight": [6.0, 2.0, 0.45, 0.08][_heading_gap(_direction(position, n), heading)] * (0.25 if floor_cells.has(n) else 2.0)})
				if entries.is_empty():
					break
				var next: Vector2i = rng.weighted_pick(entries)
				floor_cells[next] = data.allowed[next]
				heading = _direction(position, next)
				position = next
				if _rand(rng) < 0.2:
					heading = (heading + flank + 6) % 6
	var removable: Array = []
	for k in _sorted(floor_cells):
		if not data.required.has(k):
			removable.append(k)
	rng.shuffle_in_place(removable)
	var removed := 0
	var wanted: int = floori(floor_cells.size() * c.obstacle_rate)
	for k in removable:
		if removed >= wanted:
			break
		var owner: String = floor_cells[k]
		floor_cells.erase(k)
		if _flood(floor_cells, data.spawn).size() != floor_cells.size():
			floor_cells[k] = owner
		else:
			removed += 1
	data.floor = floor_cells
	data.obstacles_removed = removed
	_refresh_footprints(data)


func _refresh_footprints(data: Dictionary) -> void:
	for node in data.nodes:
		node.footprint = []
	for k in _sorted(data.floor):
		var owner: String = data.floor[k]
		if owner.is_empty() or owner == "spawn":
			continue
		for node in data.nodes:
			if node.id == owner:
				node.footprint.append(k)
				break


func _expected_edges(data: Dictionary) -> Array:
	var edges: Array = []
	for node in data.nodes:
		var pair: Array = [node.id, node.parent_id]
		pair.sort()
		edges.append(pair[0] + "|" + pair[1])
	edges.sort()
	return edges


func _validate(data: Dictionary, c: Dictionary) -> Dictionary:
	var floor_cells: Dictionary = data.floor
	if _flood(floor_cells, data.spawn).size() != floor_cells.size():
		return {"ok": false, "error": "Fully open floor is disconnected"}
	var graph: Dictionary = _graph(data)
	if not graph.ok or graph.edges != _expected_edges(data):
		return {"ok": false, "error": "Actual owner graph differs from the selected WALK tree"}
	var gates: Array = []
	var counts: Dictionary = {"battle": 0, "elite": 0, "event": 0, "shop": 0, "boss": 0}
	var alchemy_pile: bool = c.get("content_profile", "legacy") == "alchemy_floor1_pile"
	var alchemy: bool = c.get("content_profile", "legacy") in ["alchemy_floor1", "alchemy_floor1_pile"]
	if alchemy:
		counts.chest = 0
	if alchemy_pile:
		counts.pile = 0
	var events: Dictionary = {}
	var boss: Dictionary = {}
	for node in data.nodes:
		counts[node.type] += 1
		if node.type == "event":
			events[node.id] = true
		if node.type == "boss":
			boss = node
		if node.is_route_gate:
			gates.append(node)
			if node.type not in ["battle", "elite"] or node.footprint.size() != 1:
				return {"ok": false, "error": "A gate must be a one-cell combat footprint"}
		elif node.type in ["battle", "elite"] and graph.adjacency[node.id].size() <= 1:
			return {"ok": false, "error": "Ordinary combat cannot occupy a terminal leaf"}
		var footprint_cells: Dictionary = {}
		for k in node.footprint:
			footprint_cells[k] = true
		if _flood(footprint_cells, node.coord).size() != footprint_cells.size():
			return {"ok": false, "error": "Node footprint is disconnected"}
	var expected_events: int = c.events - (3 if alchemy_pile else 2 if alchemy else 1)
	if counts.battle != c.normal or counts.elite != c.elite or counts.shop != 1 or counts.event != expected_events or counts.boss != 1 or gates.size() != 2 or (alchemy and counts.chest != 1) or (alchemy_pile and counts.pile != 1):
		return {"ok": false, "error": "Content quota mismatch"}
	var event_run: int = _event_run(graph.adjacency, events)
	if event_run > 3:
		return {"ok": false, "error": "Event chain exceeds three nodes"}
	var queue: Array = ["spawn"]
	var distance: Dictionary = {"spawn": 0}
	var index := 0
	while index < queue.size():
		for other in graph.adjacency[queue[index]]:
			if not distance.has(other):
				distance[other] = distance[queue[index]] + 1
				queue.append(other)
		index += 1
	var boss_distance: int = distance.get(boss.id, 0) - 1
	if boss_distance < c.min_boss_content_nodes or boss.unlock_gates.size() >= 2:
		return {"ok": false, "error": "Boss content distance or optional gate requirement failed"}
	var boss_optional := false
	for mask in 4:
		var open: Dictionary = {}
		var blocked: Dictionary = {}
		for i in gates.size():
			if mask & (1 << i):
				open[gates[i].id] = true
			else:
				blocked[gates[i].coord] = true
		var reached: Dictionary = _flood(floor_cells, data.spawn, blocked)
		for k in floor_cells:
			if blocked.has(k):
				continue
			var expected := true
			for gate_id in data.domains[k]:
				expected = expected and open.has(gate_id)
			if reached.has(k) != expected:
				return {"ok": false, "error": "Local gate domain has a bypass or stranded floor"}
		if reached.has(boss.coord) and open.size() < 2:
			boss_optional = true
		for gate in gates:
			if open.has(gate.id):
				continue
			var prerequisites := true
			for gate_id in gate.unlock_gates:
				prerequisites = prerequisites and open.has(gate_id)
			if not prerequisites:
				continue
			var interactable := false
			for n in Hex.neighbors(gate.coord):
				interactable = interactable or reached.has(n)
			var next_blocked: Dictionary = blocked.duplicate()
			next_blocked.erase(gate.coord)
			var after: Dictionary = _flood(floor_cells, data.spawn, next_blocked)
			if not interactable or after.size() <= reached.size() + 1:
				return {"ok": false, "error": "A local gate opens no real region"}
	if not boss_optional:
		return {"ok": false, "error": "Boss has no optional-combat witness"}
	var shape: Dictionary = _shape(floor_cells)
	if shape.elongation > 1.85 or shape.oriented_aspect > 2.0:
		return {"ok": false, "error": "Actual floor exceeds compact shape limits"}
	var topology: Dictionary = _tree_metrics(data.plan)
	if data.nodes.size() >= 13 and (topology.useful_forks < 2 or topology.substantial_forks < 1 or topology.singleton_side_branches > maxi(1, data.nodes.size() / 10)):
		return {"ok": false, "error": "Recursive branch budget failed"}
	return {"ok": true, "ground_cells": floor_cells.size(), "boss_content_distance": boss_distance, "max_event_run": event_run, "counts": counts, "gate_masks": 4, "boss_with_unfinished_gate": boss_optional, "shape": shape, "topology": topology, "gate_pattern": data.plan.pattern, "obstacles_removed": data.get("obstacles_removed", 0)}


func _transition_route(floor_cells: Dictionary, start: Vector2i, goal: Vector2i) -> Dictionary:
	var distance: Dictionary = {start: 0}
	var previous: Dictionary = {}
	var queue: Array = [start]
	while not queue.is_empty():
		queue.sort_custom(func(a, b): return distance[a] < distance[b] if distance[a] != distance[b] else a.x < b.x or (a.x == b.x and a.y < b.y))
		var k: Vector2i = queue.pop_front()
		if k == goal:
			var path: Array = [goal]
			while path.back() != start:
				path.append(previous[path.back()])
			path.reverse()
			return {"cost": distance[k], "path": path}
		for n in Hex.neighbors(k):
			if not floor_cells.has(n):
				continue
			var cost: int = 0 if not str(floor_cells[k]).is_empty() and floor_cells[k] == floor_cells[n] else 1
			var value: int = distance[k] + cost
			if value < distance.get(n, 1000000):
				distance[n] = value
				previous[n] = k
				if n not in queue:
					queue.append(n)
	return {"cost": 1000000, "path": []}


func _centers(data: Dictionary) -> Dictionary:
	var result: Dictionary = {"spawn": data.spawn}
	for node in data.nodes:
		result[node.id] = node.coord
	return result


func _relocation_context(data: Dictionary) -> Dictionary:
	# A sweep tests many offsets against one unchanged layout. Keep only its
	# immutable lookup work here; every trial still owns its mutable output.
	var empty: Dictionary = {}
	for k in data.floor:
		if str(data.floor[k]).is_empty():
			empty[k] = true
	var joints: Array = []
	for part in _components(empty):
		joints.append({"cells": part, "incident": _incident(data.floor, part)})
	var by_id: Dictionary = {}
	for node in data.nodes:
		by_id[node.id] = node
	return {"centers": _centers(data), "keys": _sorted(data.floor), "joints": joints, "nodes": by_id}


func _relocate(data: Dictionary, node_id: String, delta: Vector2i, context: Dictionary = {}) -> Dictionary:
	if context.is_empty():
		context = _relocation_context(data)
	var old_centers: Dictionary = context.centers
	var centers: Dictionary = old_centers.duplicate()
	var moving: Dictionary = context.nodes.get(node_id, {})
	var removed_joints: Dictionary = {}
	for joint: Dictionary in context.joints:
		var incident: Dictionary = joint.incident
		if incident.has(node_id):
			if incident.size() != 2:
				return {}
			removed_joints.merge(joint.cells, true)
	var trial: Dictionary = {"plan": data.plan, "spawn": data.spawn, "nodes": data.nodes.duplicate(true), "floor": {}, "domains": {}, "obstacles_removed": data.get("obstacles_removed", 0)}
	for k in context["keys"]:
		if removed_joints.has(k):
			continue
		var next: Vector2i = k + delta if data.floor[k] == node_id else k
		if trial.floor.has(next):
			return {}
		trial.floor[next] = data.floor[k]
		trial.domains[next] = data.domains[k].duplicate()
	centers[node_id] += delta
	for node in trial.nodes:
		if node.id == node_id:
			node.coord = centers[node_id]
			# Relocation only moves this owner; joint reconstruction changes
			# empty transit cells. Translation preserves footprint sort order.
			for i in node.footprint.size():
				node.footprint[i] += delta
	var routes: Array = []
	for node in data.nodes:
		var a: String = node.parent_id
		var b: String = node.id
		if a != node_id and b != node_id:
			continue
		var endpoints: Dictionary = {a: true, b: true}
		var mask: Dictionary = {}
		for p in _line(centers[a], centers[b]) + _line(old_centers[a], old_centers[b]):
			for k in _disk(p, 2):
				mask[k] = true
		var empty_incident: Dictionary = {}
		var trial_empty: Dictionary = {}
		for k in trial.floor:
			if str(trial.floor[k]).is_empty():
				trial_empty[k] = true
		for part in _components(trial_empty):
			var incident: Dictionary = _incident(trial.floor, part)
			for k in part:
				empty_incident[k] = incident
		var queue: Array = [centers[a]]
		var parents: Dictionary = {centers[a]: centers[a]}
		var index := 0
		while index < queue.size() and not parents.has(centers[b]):
			# Translation preserves axial lexicographic order. This is the exact
			# order of _sorted(Hex.neighbors(queue[index])) without a temporary
			# Dictionary, keys Array, and comparator sort at every BFS step.
			for direction: Vector2i in _LEXICOGRAPHIC_DIRS:
				var n: Vector2i = queue[index] + direction
				if not parents.has(n) and _joint_safe(n, trial, mask, endpoints, empty_incident, moving.unlock_gates):
					parents[n] = queue[index]
					queue.append(n)
			index += 1
		if not parents.has(centers[b]):
			return {}
		var path: Array = [centers[b]]
		while path.back() != centers[a]:
			path.append(parents[path.back()])
		path.reverse()
		var transit: Array = []
		for k in path:
			if not trial.floor.has(k) or str(trial.floor[k]).is_empty():
				transit.append(k)
		if transit.size() > 5:
			return {}
		for k in transit:
			trial.floor[k] = ""
			trial.domains[k] = moving.unlock_gates.duplicate()
		routes.append({"from": a, "to": b, "path": _points(path), "transit_cells": _points(transit)})
	trial.transition_move = {"node_id": node_id, "from": _point(moving.coord), "to": _point(centers[node_id]), "delta": _point(delta), "routes": routes}
	return trial


func _joint_safe(k: Vector2i, trial: Dictionary, mask: Dictionary, endpoints: Dictionary, empty_incident: Dictionary, domain: Array) -> bool:
	if trial.floor.has(k) and not str(trial.floor[k]).is_empty():
		return endpoints.has(trial.floor[k])
	if not mask.has(k) or (trial.floor.has(k) and trial.domains[k] != domain):
		return false
	for n in Hex.neighbors(k):
		if not trial.floor.has(n):
			continue
		if not str(trial.floor[n]).is_empty():
			if not endpoints.has(trial.floor[n]):
				return false
		else:
			for owner in empty_incident.get(n, {}):
				if not endpoints.has(owner):
					return false
	return true


func _axial_spans(cells: Dictionary) -> Array:
	var lows: Array = [1000000, 1000000, 1000000]
	var highs: Array = [-1000000, -1000000, -1000000]
	for k in cells:
		var values: Array = [k.x, k.y, k.x + k.y]
		for i in 3:
			lows[i] = mini(lows[i], values[i])
			highs[i] = maxi(highs[i], values[i])
	return [highs[0] - lows[0], highs[1] - lows[1], highs[2] - lows[2]]


func _apply_transitions(data: Dictionary, rng, c: Dictionary) -> Dictionary:
	var base_floor: Dictionary = data.floor.duplicate()
	var base_centers: Dictionary = _centers(data)
	var base_shape: Dictionary = _shape(base_floor)
	var base_spans: Array = _axial_spans(base_floor)
	var graph: Dictionary = _graph(data)
	var by_id: Dictionary = {}
	for node in data.nodes:
		by_id[node.id] = node
	by_id.spawn = {"id": "spawn", "is_route_gate": false, "unlock_gates": [], "coord": data.spawn}
	var eligible: Array = []
	for node in data.nodes:
		if node.is_route_gate:
			continue
		var safe := true
		for other in graph.adjacency[node.id]:
			if by_id[other].is_route_gate or by_id[other].unlock_gates != node.unlock_gates:
				safe = false
		if safe:
			eligible.append(node.id)
	rng.shuffle_in_place(eligible)
	var candidates: Array = []
	for id in eligible:
		var offsets: Array = _disk(Vector2i.ZERO, 2)
		offsets.erase(Vector2i.ZERO)
		rng.shuffle_in_place(offsets)
		# Stable partition keeps seeded ordering within each movement distance.
		for radius in [1, 2]:
			for delta in offsets:
				if Hex.distance(Vector2i.ZERO, delta) == radius:
					candidates.append({"id": id, "delta": delta})
	var metadata: Dictionary = {"requested_count": c.transition_count, "applied_count": 0, "skipped_count": c.transition_count, "placements_considered": 0, "rejected_placements": 0, "operations": [], "baseline_cells": [], "baseline_centers": {}, "baseline_shape": base_shape, "policy": "complete-footprint relocation; short local joint reconstruction; final actual gain exactly one", "cost_rule": "0 inside one nonempty owner; 1 for every other adjacent ground edge"}
	for k in _sorted(base_floor):
		metadata.baseline_cells.append({"q": k.x, "r": k.y, "owner": base_floor[k]})
	for id in _ids(base_centers):
		metadata.baseline_centers[id] = _point(base_centers[id])
	var used: Dictionary = {}
	var relocation: Dictionary = _relocation_context(data)
	for candidate in candidates:
		if metadata.applied_count >= c.transition_count or metadata.placements_considered >= PLACEMENT_LIMIT:
			break
		if used.has(candidate.id):
			continue
		metadata.placements_considered += 1
		var trial: Dictionary = _relocate(data, candidate.id, candidate.delta, relocation)
		if trial.is_empty():
			metadata.rejected_placements += 1
			continue
		var from: String = by_id[candidate.id].parent_id
		var to: String = candidate.id
		var centers: Dictionary = _centers(trial)
		var before: int = _transition_route(base_floor, base_centers[from], base_centers[to]).cost
		var measured: Dictionary = _transition_route(trial.floor, centers[from], centers[to])
		var valid: bool = measured.cost - before == c.transition_steps
		for operation in metadata.operations:
			if _transition_route(trial.floor, centers[operation.from], centers[operation.to]).cost - operation.before_cost != c.transition_steps:
				valid = false
		var shape: Dictionary = _shape(trial.floor)
		var spans: Array = _axial_spans(trial.floor)
		if shape.oriented_aspect > base_shape.oriented_aspect + 0.2 or shape.compactness < base_shape.compactness * 0.85 or trial.floor.size() > base_floor.size() + 6 * (metadata.applied_count + 1):
			valid = false
		for i in 3:
			if spans[i] > base_spans[i] + 4:
				valid = false
		if not valid or not _validate(trial, c).ok:
			metadata.rejected_placements += 1
			continue
		metadata.operations.append({"from": from, "to": to, "before_cost": before, "after_cost": measured.cost, "gain": measured.cost - before, "path": _points(measured.path), "move": trial.transition_move})
		metadata.applied_count += 1
		used[candidate.id] = true
		data.floor = trial.floor
		data.domains = trial.domains
		data.nodes = trial.nodes
		relocation = _relocation_context(data)
	var final_centers: Dictionary = _centers(data)
	for operation in metadata.operations:
		var measured: Dictionary = _transition_route(data.floor, final_centers[operation.from], final_centers[operation.to])
		operation.after_cost = measured.cost
		operation.gain = measured.cost - operation.before_cost
		operation.path = _points(measured.path)
	metadata.skipped_count = c.transition_count - metadata.applied_count
	return metadata


func _point(p: Vector2i) -> Array:
	return [p.x, p.y]


func _points(points: Array) -> Array:
	var result: Array = []
	for point in points:
		result.append(_point(point))
	return result


func _snapshot(data: Dictionary, seed: String, map_id: String, floor_index: int) -> Dictionary:
	var cells: Dictionary = {}
	for k in data.floor:
		cells[k] = "ground"
		for n in Hex.neighbors(k):
			if not data.floor.has(n):
				cells[n] = "wall"
	var result: Dictionary = {"schema_version": 1, "map_id": map_id, "seed": seed, "floor_index": floor_index, "spawn": _point(data.spawn), "cells": [], "nodes": []}
	for k in _sorted(cells):
		result.cells.append({"q": k.x, "r": k.y, "terrain": cells[k]})
	var sorted_nodes: Array = data.nodes.duplicate()
	sorted_nodes.sort_custom(func(a, b): return a.id < b.id)
	for node in sorted_nodes:
		var id: String = "boss-1" if node.type == "boss" else node.id
		var unlocks: Array = node.unlock_gates.duplicate()
		unlocks.sort()
		var clean := {"id": id, "type": node.type, "coord": _point(node.coord), "footprint": _points(node.footprint), "is_route_gate": node.is_route_gate, "revisitable": node.revisitable, "unlock_gates": unlocks, "event_kind": node.event_kind, "content_id": node.content_id}
		if node.has("body_radius"):
			clean.body_radius = node.body_radius
		if node.has("body_capsule"):
			clean.body_capsule = node.body_capsule.duplicate(true)
		result.nodes.append(clean)
	return result

extends RefCounted
## Native consolidation of the selected node-first WALK pipeline.
## Owns no run, RNG, cache, presentation, file I/O, or external event lifecycle.
const VERSION := "planar-walk-v1"
const Hex = preload("res://systems/map/hex_coord.gd")
const Domains = preload("res://systems/random/random_domains.gd")
const DEFAULT_CONFIG := {
	"size": "small", "normal": 3, "elite": 1, "events": 8,
	"min_boss_content_nodes": 4, "transition_count": 6,
	"transition_steps": 1, "obstacle_rate": 0.06,
}
const MAX_ATTEMPTS := 8
const EMBEDDING_TRIALS := 40
const PLACEMENT_LIMIT := 144
var last_error: String = ""


func normalize_config(input: Dictionary) -> Dictionary:
	last_error = ""
	for field in input:
		if field not in DEFAULT_CONFIG:
			return _fail("Unsupported generation config key: " + str(field))
	var c: Dictionary = DEFAULT_CONFIG.duplicate()
	c.merge(input, true)
	if c.size != "small":
		return _fail("The production WALK outline supports size=small")
	for field in ["normal", "elite", "events", "min_boss_content_nodes", "transition_count", "transition_steps"]:
		var value: Variant = c[field]
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floor(float(value)) or absf(float(value)) > 100000.0:
			return _fail(field + " must be an integer")
		c[field] = int(value)
	if c.normal < 2 or c.normal > 8 or c.elite < 1 or c.elite > 5 or c.normal + c.elite < 4:
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
	return c


func generate(seed_source, map_id: String, floor_index: int, config: Dictionary = {}) -> Dictionary:
	var c: Dictionary = normalize_config(config)
	if c.is_empty():
		return {}
	if map_id.strip_edges().is_empty() or floor_index < 1:
		return _fail("A nonempty map_id and positive floor_index are required")
	if not seed_source is Object or not seed_source.has_method("get_main_seed") or not seed_source.has_method("get_stream"):
		return _fail("seed_source must expose get_main_seed/get_stream")
	var main_seed: Variant = seed_source.get_main_seed()
	if not main_seed is String or main_seed.is_empty():
		return _fail("seed_source must already have an initialized main seed")
	var failures: Array = []
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
			var transition_rng: Variant = seed_source.get_stream(&"map.transitions", [map_id], attempt)
			if transition_rng == null:
				return _fail("Could not acquire map.transitions stream")
			transitions = _apply_transitions(data, transition_rng, c)
		quality = _validate(data, c)
		if not quality.ok:
			failures.append(quality.error)
			continue
		last_error = ""
		var result: Dictionary = _snapshot(data, str(main_seed), map_id, floor_index)
		result.generator_version = VERSION
		result.generation_config = c
		result.generation_attempt = attempt
		result.generation_quality = quality
		result.generation_quality.transitions = transitions
		return result
	return _fail("WALK generation exhausted %d bounded attempts: %s" % [MAX_ATTEMPTS, str(failures)])


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
	var choices: Array = []
	for direction in Hex.DIRS:
		var k: Vector2i = p + direction
		if state.occupied.has(k) or not _coarse_clear(k, p, state.occupied):
			continue
		var free := 0
		for n in Hex.neighbors(k):
			if n != p and not state.occupied.has(n) and _coarse_clear(n, k, state.occupied):
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
		if _place(state, index + 1):
			return true
		state.positions.erase(id)
		state.occupied.erase(choice.point)
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
	var candidates: Array = []
	for trial in EMBEDDING_TRIALS:
		var state: Dictionary = {"plan": plan, "rng": rng, "trial": trial, "order": breadth_order if trial % 3 == 2 else depth_order, "steps": 0, "positions": {"spawn": Vector2i.ZERO}, "occupied": {Vector2i.ZERO: true}}
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
	if counts.battle != c.normal or counts.elite != c.elite or counts.shop != 1 or counts.event != c.events - 1 or counts.boss != 1 or gates.size() != 2:
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


func _relocate(data: Dictionary, node_id: String, delta: Vector2i) -> Dictionary:
	var centers: Dictionary = _centers(data)
	var old_centers: Dictionary = centers.duplicate()
	var moving: Dictionary = {}
	for node in data.nodes:
		if node.id == node_id:
			moving = node
	var empty: Dictionary = {}
	for k in data.floor:
		if str(data.floor[k]).is_empty():
			empty[k] = true
	var removed_joints: Dictionary = {}
	for part in _components(empty):
		var incident: Dictionary = _incident(data.floor, part)
		if incident.has(node_id):
			if incident.size() != 2:
				return {}
			removed_joints.merge(part, true)
	var trial: Dictionary = {"plan": data.plan, "spawn": data.spawn, "nodes": data.nodes.duplicate(true), "floor": {}, "domains": {}, "obstacles_removed": data.get("obstacles_removed", 0)}
	for k in _sorted(data.floor):
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
			var neighbors: Dictionary = {}
			for n in Hex.neighbors(queue[index]):
				neighbors[n] = true
			for n in _sorted(neighbors):
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
	_refresh_footprints(trial)
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
	for candidate in candidates:
		if metadata.applied_count >= c.transition_count or metadata.placements_considered >= PLACEMENT_LIMIT:
			break
		if used.has(candidate.id):
			continue
		metadata.placements_considered += 1
		var trial: Dictionary = _relocate(data, candidate.id, candidate.delta)
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
		result.nodes.append({"id": id, "type": node.type, "coord": _point(node.coord), "footprint": _points(node.footprint), "is_route_gate": node.is_route_gate, "revisitable": node.revisitable, "unlock_gates": unlocks, "event_kind": node.event_kind, "content_id": node.content_id})
	return result

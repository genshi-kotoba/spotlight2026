extends RefCounted
## Pure optional-site planner. Solver owns pins, feasible levels and final field.
## No RNG objects, files, cache, SeedService or node-type height policies.
const VERSION := "citadel-region-anchors-v1"
const MAX_POOL := 48
const MAX_REGIONS := 8
const HASH_MOD := 2147483647
const DIRS := [Vector2i(1,0),Vector2i(1,-1),Vector2i(0,-1),Vector2i(-1,0),Vector2i(-1,1),Vector2i(0,1)]

static func proposals(planar: Dictionary, data: Dictionary, c: Dictionary, noise_seed: int, variant: int) -> Array:
	var answer: Array = []
	var groups: Array = data.get("groups", [])
	var edges: Array = data.get("edges", [])
	var owner: Dictionary = data.get("owner", {})
	if groups.size() < 2 or edges.size() != groups.size() or owner.is_empty(): return answer
	var amplitude: float = float(c.get("amplitude_levels", 0.0))
	if amplitude <= 0.0: return answer
	variant = posmod(variant, 4)
	var blocked: Dictionary = {}
	var spawn: Variant = data.get("spawn")
	if spawn is Vector2i and owner.has(spawn): blocked[int(owner[spawn])] = true
	elif planar.get("spawn") is Array and planar.spawn.size() == 2:
		var spawn_coord := Vector2i(int(planar.spawn[0]), int(planar.spawn[1]))
		if owner.has(spawn_coord): blocked[int(owner[spawn_coord])] = true
	var boss: int = int(data.get("boss_group", -1))
	if boss >= 0: blocked[boss] = true
	var points: Array[Vector2] = []
	for group: Array in groups:
		var point := Vector2.ZERO
		for coordinate: Vector2i in group: point += _plane(coordinate)
		points.append(point / maxi(1, group.size()))
	var nodes: Dictionary = {}
	for node: Dictionary in planar.get("nodes", []):
		if node.get("coord") is Array and node.coord.size() == 2:
			var coordinate := Vector2i(int(node.coord[0]), int(node.coord[1]))
			if owner.has(coordinate):
				var site: int = int(owner[coordinate])
				if node.get("type", "") == "boss": blocked[site] = true
				elif not blocked.has(site): nodes[site] = true
	var boundary: Dictionary = {}
	for coordinate: Vector2i in owner:
		var site: int = int(owner[coordinate])
		if blocked.has(site): continue
		for direction: Vector2i in DIRS:
			if not owner.has(coordinate + direction):
				boundary[site] = true
				break
	var node_ids := _sorted_ids(nodes)
	var boundary_ids := _sorted_ids(boundary)
	var pool := _spread_sample(node_ids, points, mini(16, MAX_POOL), noise_seed, variant, 71)
	var pool_seen: Dictionary = {}
	for site: int in pool: pool_seen[site] = true
	var remaining: Array[int] = []
	for site: int in boundary_ids:
		if not pool_seen.has(site): remaining.append(site)
	var extra := _spread_sample(remaining, points, MAX_POOL - pool.size(), noise_seed, variant, 97)
	pool.append_array(extra)
	if pool.size() < MAX_REGIONS:
		for site in groups.size():
			if not blocked.has(site) and site not in pool:
				pool.append(site)
				if pool.size() >= mini(MAX_POOL, MAX_REGIONS): break
	pool.sort()
	if pool.size() < 2: return answer
	var distances: Dictionary = {}
	for site: int in pool: distances[site] = _distances(site, edges)
	var selected: Array[int] = []
	var roles: Array[String] = []
	var desired_count: int = mini(MAX_REGIONS, pool.size() - pool.size() % 2)
	while selected.size() < desired_count:
		var best_a := -1
		var best_b := -1
		var best_score := -INF
		for ai in pool.size():
			var a: int = pool[ai]
			if a in selected: continue
			for bi in range(ai + 1, pool.size()):
				var b: int = pool[bi]
				if b in selected: continue
				var graph_distance: int = distances[a][b]
				if graph_distance < 4: continue
				var near_a: float = _nearest_graph(a, selected, distances)
				var near_b: float = _nearest_graph(b, selected, distances)
				if not selected.is_empty() and minf(near_a, near_b) < 4.0: continue
				var plane_distance: float = points[a].distance_to(points[b]) / sqrt(3.0)
				# True geodesic detours across nearby separated ground are valuable.
				# Coverage is independent of node type and does not force a center peak.
				var folded: float = maxf(0.0, graph_distance - plane_distance) / maxf(2.0, plane_distance)
				var near_weight: float = clampf(1.0 - plane_distance / 9.0, 0.0, 1.0)
				var coverage: float = 0.0 if selected.is_empty() else minf(24.0, minf(near_a, near_b)) / 6.0
				var geometric: float = 0.0 if selected.is_empty() else minf(_nearest_plane(a, selected, points), _nearest_plane(b, selected, points)) / 4.0
				var score: float = folded * (0.5 + near_weight) + coverage * (1.2 + 0.2 * variant) + minf(2.0, geometric) + _unit_hash(noise_seed, variant, a, b, 131) * 0.25
				if score > best_score:
					best_score = score
					best_a = a
					best_b = b
		if best_a < 0: break
		var flip: bool = _hash(noise_seed, variant, best_a, best_b, 173) % 2 == 1
		selected.append(best_a); roles.append("low" if flip else "high")
		selected.append(best_b); roles.append("high" if flip else "low")
	# Small maps or a densely contracted foundation graph may not fit four
	# disjoint pairs. Keep useful optional proposals rather than duplicate sites.
	if selected.is_empty():
		selected.append(pool[_hash(noise_seed, variant, pool.size(), 0, 191) % pool.size()])
		roles.append("high")
	var reserved: Dictionary = blocked.duplicate()
	for site: int in selected: reserved[site] = true
	var used: Dictionary = {}
	var baseline: int = int(c.get("baseline_level", 0))
	for index in selected.size():
		var site: int = selected[index]
		var cluster := _cluster(site, edges, reserved, used, noise_seed, variant)
		for member: int in cluster: used[member] = true
		var factor: float = 0.8 + 0.4 * _unit_hash(noise_seed, variant, site, index, 211)
		var amount: int = maxi(1, floori(amplitude * factor + 0.5))
		var role: String = roles[index]
		answer.append({"site": site, "groups": cluster, "desired": baseline + (amount if role == "high" else -amount), "role": role})
	return answer

static func _cluster(site: int, edges: Array, reserved: Dictionary, used: Dictionary, seed_value: int, variant: int) -> Array[int]:
	var result: Array[int] = [site]
	var choices: Array[int] = []
	for neighbor: int in edges[site]:
		if not reserved.has(neighbor) and not used.has(neighbor): choices.append(neighbor)
	choices.sort_custom(func(a: int, b: int): return _hash(seed_value,variant,site,a,229) < _hash(seed_value,variant,site,b,229))
	var limit: int = 2 + _hash(seed_value, variant, site, 0, 233) % 2
	for neighbor: int in choices:
		result.append(neighbor)
		if result.size() >= limit: break
	return result

static func _spread_sample(items: Array[int], points: Array[Vector2], limit: int, seed_value: int, variant: int, salt: int) -> Array[int]:
	var result: Array[int] = []
	if limit <= 0 or items.is_empty(): return result
	var first: int = items[0]
	for item: int in items:
		if _hash(seed_value,variant,item,0,salt) < _hash(seed_value,variant,first,0,salt): first = item
	result.append(first)
	var nearest: Dictionary = {}
	for item: int in items: nearest[item] = points[item].distance_squared_to(points[first])
	while result.size() < mini(limit, items.size()):
		var best := -1
		var best_score := -INF
		for item: int in items:
			if item in result: continue
			var score: float = float(nearest[item]) * (0.92 + 0.16 * _unit_hash(seed_value,variant,item,0,salt+1))
			if score > best_score:
				best = item
				best_score = score
		result.append(best)
		for item: int in items: nearest[item] = minf(float(nearest[item]), points[item].distance_squared_to(points[best]))
	return result

static func _distances(site: int, edges: Array) -> Array[int]:
	var distance: Array[int] = []
	distance.resize(edges.size()); distance.fill(-1)
	distance[site] = 0
	var queue: Array[int] = [site]
	var index := 0
	while index < queue.size():
		var current: int = queue[index]
		for neighbor: int in edges[current]:
			if distance[neighbor] < 0:
				distance[neighbor] = distance[current] + 1
				queue.append(neighbor)
		index += 1
	return distance

static func _nearest_graph(site: int, selected: Array[int], distances: Dictionary) -> float:
	var nearest := INF
	for other: int in selected:
		var value: int = distances[site][other]
		if value >= 0: nearest = minf(nearest, value)
	return nearest

static func _nearest_plane(site: int, selected: Array[int], points: Array[Vector2]) -> float:
	var nearest := INF
	for other: int in selected: nearest = minf(nearest, points[site].distance_to(points[other]))
	return nearest

static func _sorted_ids(values: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for value in values: result.append(int(value))
	result.sort()
	return result

static func _plane(coordinate: Vector2i) -> Vector2:
	return Vector2(1.5 * coordinate.x, sqrt(3.0) * (coordinate.y + coordinate.x * 0.5))

static func _hash(seed_value: int, variant: int, a: int, b: int, salt: int) -> int:
	var value: int = posmod(seed_value, HASH_MOD)
	value = posmod(value * 48271 + (variant + 1) * 69621 + salt * 7919, HASH_MOD)
	value = posmod(value * 40699 + (a + 1) * 104729, HASH_MOD)
	return posmod(value * 32491 + (b + 1) * 15485863, HASH_MOD)

static func _unit_hash(seed_value: int, variant: int, a: int, b: int, salt: int) -> float:
	return float(_hash(seed_value, variant, a, b, salt)) / float(HASH_MOD - 1)

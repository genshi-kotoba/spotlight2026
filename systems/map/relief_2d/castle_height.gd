extends RefCounted
## Regional architectural targets on the EXISTING ground graph only.
## Wide bent upper district, lower flanking district, broad basins and a saddle.
const Hex = preload("res://systems/map/hex_coord.gd")
const VERSION := "castle-regional-backbone-v2"
const LAYOUT_COUNT := 3
const CANDIDATE_COUNT := LAYOUT_COUNT * 2


static func targets(data: Dictionary, c: Dictionary, noise_seed: int, variant: int) -> Array:
	var coordinates: Array = data.owner.keys()
	coordinates.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var points: Array[Vector2] = []
	var center := Vector2.ZERO
	for coord in coordinates:
		var p: Vector2 = Hex.to_plane(coord, 1.0)
		points.append(p)
		center += p
	center /= coordinates.size()
	var u: Vector2 = Hex.to_plane(Hex.DIRS[posmod(noise_seed * 48271 + 104729 + [0, 1, -1][variant], 6)], 1.0).normalized()
	var v := Vector2(-u.y, u.x)
	if posmod(noise_seed * 69621 + 15485863, 2) == 1: v = -v
	var span_u := 1.0
	var span_v := 1.0
	for p in points:
		span_u = maxf(span_u, absf((p - center).dot(u)) * 2.0)
		span_v = maxf(span_v, absf((p - center).dot(v)) * 2.0)
	var shift: float = [0.0, 0.05, -0.05][variant]
	var a := _nearest(points, center - u * span_u * 0.27 + v * span_v * (0.10 + shift), data, coordinates)
	var bend := _nearest(points, center + u * span_u * 0.03 + v * span_v * (0.27 + shift), data, coordinates)
	var b := _nearest(points, center + u * span_u * 0.28 + v * span_v * (0.13 + shift), data, coordinates)
	var spine: Array = _path(a, bend, data.edges)
	var second: Array = _path(bend, b, data.edges)
	for group in second:
		if group not in spine: spine.append(group)
	if spine.is_empty(): spine = [a]
	var high_distance := _distances(spine, data.edges)
	var far := _farthest(_distances([data.owner[data.spawn]], data.edges))
	var diameter_distance := _distances([far], data.edges)
	var diameter: float = maxf(8.0, diameter_distance[_farthest(diameter_distance)])
	# District widths grow with the actual traversable extent, not a tiny fixed
	# summit. No coarse/node types enter this regional plan.
	var region_extent: float = maxf(12.0, maxf(span_u, span_v) / sqrt(3.0))
	var width: float = region_extent * (0.22 + shift * 0.5)
	var height: float = c.amplitude_levels * 1.7
	var gradient: float = height / maxf(5.0, width * 1.45) * 7.0 / c.wavelength
	var lower_a := _nearest(points, center - u * span_u * 0.28 - v * span_v * 0.26, data, coordinates)
	var lower_b := _nearest(points, center + u * span_u * 0.17 - v * span_v * 0.25, data, coordinates)
	var flank: Array = _path(lower_a, lower_b, data.edges)
	if flank.is_empty(): flank = [lower_a]
	var mid_distance := _distances(flank, data.edges)
	var basin_a := _off_spine(points, center - u * span_u * 0.13 - v * span_v * 0.06, high_distance, diameter, data, coordinates)
	var basin_b := _off_spine(points, center + u * span_u * 0.30 - v * span_v * 0.17, high_distance, diameter, data, coordinates)
	var saddle := _off_spine(points, center - u * span_u * 0.31 - v * span_v * 0.03, high_distance, diameter, data, coordinates)
	var basins: Array = [_distances([basin_a], data.edges), _distances([basin_b], data.edges), _distances([saddle], data.edges)]
	var phase: float = float(posmod(noise_seed * 32452843 + 7919, 1009)) / 1009.0 * TAU
	var values: Array = []
	for i in data.groups.size():
		var p := Vector2.ZERO
		for coord in data.groups[i]: p += Hex.to_plane(coord, 1.0)
		p /= data.groups[i].size()
		var along: float = (p - center).dot(u) / span_u
		# Longitudinal tier variation prevents the connected upper district from
		# becoming one constant-height sheet. The flank has a separate lower band.
		var crest: float = height * (0.91 - 0.18 * along + 0.10 * sin(along * TAU + phase))
		var high: float = crest - float(high_distance.get(i, diameter)) * gradient
		var mid: float = height * (0.36 + 0.09 * sin(along * TAU - phase)) - float(mid_distance.get(i, diameter)) * gradient * 0.82
		var value := maxf(high, mid)
		# Deliberately wide negative districts. Radius is in real graph edges;
		# there is no tiny noise valley or per-cell peak/valley synthesis.
		for k in basins.size():
			var radius: float = region_extent * (0.23 if k < 2 else 0.16)
			var t := clampf(float(basins[k].get(i, diameter)) / maxf(4.0, radius), 0.0, 1.0)
			var depth: float = height * (0.92 if k < 2 else 0.43)
			value -= depth * (1.0 - t * t * (3.0 - 2.0 * t))
		values.append(value)
	var origin: float = values[data.owner[data.spawn]]
	for i in values.size(): values[i] += c.baseline_level - origin
	return values


static func _nearest(points: Array[Vector2], target: Vector2, data: Dictionary, coordinates: Array) -> int:
	var best := 0
	var score := INF
	for i in points.size():
		var candidate := points[i].distance_squared_to(target)
		if candidate < score:
			best = i
			score = candidate
	return data.owner[coordinates[best]]


static func _off_spine(points: Array[Vector2], target: Vector2, distances: Dictionary, diameter: float, data: Dictionary, coordinates: Array) -> int:
	var best := 0
	var score := INF
	for i in points.size():
		var d: float = distances.get(data.owner[coordinates[i]], diameter)
		var candidate: float = points[i].distance_to(target) - minf(d, diameter * 0.18) * 0.75
		if candidate < score:
			best = i
			score = candidate
	return data.owner[coordinates[best]]


static func _path(a: int, b: int, edges: Array) -> Array:
	var queue: Array = [a]
	var parents := {a: -1}
	var index := 0
	while index < queue.size() and not parents.has(b):
		var group: int = queue[index]
		index += 1
		for other in edges[group]:
			if not parents.has(other):
				parents[other] = group
				queue.append(other)
	if not parents.has(b): return []
	var result: Array = [b]
	while result[-1] != a: result.append(parents[result[-1]])
	result.reverse()
	return result


static func _distances(starts: Array, edges: Array) -> Dictionary:
	var queue: Array = []
	var distances := {}
	for group in starts:
		if not distances.has(group):
			distances[group] = 0
			queue.append(group)
	var index := 0
	while index < queue.size():
		var group: int = queue[index]
		index += 1
		for other in edges[group]:
			if not distances.has(other):
				distances[other] = distances[group] + 1
				queue.append(other)
	return distances


static func _farthest(distances: Dictionary) -> int:
	var best: int = distances.keys()[0]
	for group in distances:
		if distances[group] > distances[best] or (distances[group] == distances[best] and group < best): best = group
	return best

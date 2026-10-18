extends RefCounted
## Immutable, presentation-only CPU scatter. Generate from the complete floor once,
## then let the renderer filter entries by their owning key. Visibility is not input.
## All dimensions in configuration are relative to the snapshot outer radius.
const Hex: Script = preload("res://systems/map/hex_coord.gd")
const Catalog: Script = preload("res://systems/map/relief_2d/art_variant_catalog.gd")
const CONFIG_PATH: String = "res://data/config/relief_2d/rock_scatter.json"
const NAMESPACE: String = "map.rock-scatter.v1"
const INRADIUS: float = 0.8660254037844386
const ACTOR_FOOT_RADIUS_RATIO: float = 0.18
const HORIZONTAL_PITCH_DEGREES: float = 35.2643897
const EPSILON: float = 0.000001


static func generate(snapshot: Dictionary) -> Dictionary:
	var warnings: Array[String] = []
	var config: Dictionary = _load_config(warnings)
	var entries: Array[Dictionary] = []
	var stats: Dictionary = {
		"version": NAMESPACE, "config_warnings": warnings,
		"input_cells": 0, "valid_cells": 0, "ground_cells": 0,
		"invalid_cells": 0, "duplicate_cells": 0, "conflicting_cells": 0,
		"reservation_source": "none", "reservation_fallback": false,
		"reservations": 0, "protected_marks": 0, "reservation_error": "",
		"input_truncated": false, "candidate_budget_hit": false,
		"entry_budget_hit": false, "entries": 0,
		"rubble": {"wall_adjacent_cells": 0, "narrow_rejected": 0,
			"unsafe_pose_rejected": 0, "reservation_rejected": 0, "edge_on_rejected": 0,
			"eligible_cells": 0, "lottery_selected": 0,
			"lottery_rejected": 0, "conflict_rejected": 0, "placed": 0,
			"lottery_rate": 0.0, "actual_rate": 0.0},
		"pebble": {"proposed": 0, "support_rejected": 0,
			"reservation_rejected": 0, "rubble_conflict_rejected": 0,
			"spacing_rejected": 0, "placed": 0, "multiple_in_cell": 0,
			"count_cap_truncated_cells": 0,
			"density_sum": 0.0, "candidate_density_actual": 0.0}
	}
	if not bool(config.enabled):
		return {"entries": entries, "stats": stats, "config": config}
	var radius: float = _safe_number(snapshot.get("outer_radius"), 1.0, 0.01, 1024.0)
	var quantum: float = _safe_number(snapshot.get("height_quantum"), 0.2, 0.001, 1.0)
	var address: Array = [snapshot.get("seed", ""), snapshot.get("map_id", ""), snapshot.get("floor_index", 0)]
	var identity: String = JSON.stringify(address).sha256_text().substr(0, 16)
	var cells: Dictionary = _normalize_cells(snapshot.get("cells", []), config.limits, stats)
	var grounds: Array[Vector2i] = []
	for coord: Vector2i in cells:
		var cell: Dictionary = cells[coord]
		if str(cell.terrain) == "ground":
			grounds.append(coord)
	grounds.sort_custom(_coord_before)
	stats.ground_cells = grounds.size()
	stats.valid_cells = cells.size()
	stats.outer_radius = radius
	stats.height_quantum = quantum
	stats.actor_foot_radius = ACTOR_FOOT_RADIUS_RATIO * radius
	var reservations: Dictionary = _reservation_bins(snapshot, config, radius, stats)
	# Never scatter over omitted/invalid reservations after a defensive limit.
	if not str(stats.reservation_error).is_empty():
		return {"entries": entries, "stats": stats, "config": config}
	var rubble_candidates: Array[Dictionary] = []
	for coord: Vector2i in grounds:
		var candidate: Dictionary = _rubble_candidate(coord, cells, reservations, address, config, radius, quantum, identity, stats.rubble)
		if candidate.is_empty():
			continue
		stats.rubble.eligible_cells += 1
		# Exactly one independent Bernoulli draw for each safely eligible cell.
		if _fraction(address, "rubble", _key(coord), 0, "placement") >= float(config.rubble.probability):
			stats.rubble.lottery_rejected += 1
			continue
		stats.rubble.lottery_selected += 1
		candidate.priority = _fraction(address, "rubble", _key(coord), 0, "priority")
		rubble_candidates.append(candidate)
	rubble_candidates.sort_custom(_priority_before)
	var rubble_bins: Dictionary = {}
	for candidate: Dictionary in rubble_candidates:
		if entries.size() >= int(config.limits.max_entries):
			stats.entry_budget_hit = true
			break
		var plane: Vector2 = candidate.plane
		if _point_conflict(plane, float(config.rubble.minimum_separation_ratio) * radius, rubble_bins, radius):
			stats.rubble.conflict_rejected += 1
			continue
		entries.append(candidate)
		_bin_append(rubble_bins, _bin(plane, radius), candidate)
		stats.rubble.placed += 1
	var pebble_candidates: Array[Dictionary] = []
	var support_fractions: Dictionary = _pebble_support_fractions(stats.pebble)
	var support_margin: float = float(config.pebble.support_margin_ratio) * radius
	var max_support_fraction: float=float(config.pebble.foot_radius_fraction)
	for fraction: float in support_fractions.values(): max_support_fraction=maxf(max_support_fraction,fraction)
	var maximum_pebble_radius: float=float(config.pebble.max_width_ratio)*radius*max_support_fraction+support_margin
	stats.pebble.support_margin_world = support_margin
	var patch_span: float = lerpf(float(config.pebble.min_patch_span_cells), float(config.pebble.max_patch_span_cells), _fraction(address, "density", "floor", 0, "span"))
	var patch_angle: float = _fraction(address, "density", "floor", 0, "rotation") * TAU
	stats.pebble.patch_span_cells = patch_span
	stats.pebble.minimum_separation_world = float(config.pebble.minimum_separation_ratio) * radius
	for coord: Vector2i in grounds:
		var key: String = _key(coord)
		var center: Vector2 = Hex.to_plane(coord, radius)
		var density: float = _density(center, address, config.pebble, radius, patch_span, patch_angle)
		stats.pebble.density_sum += density
		var expected: float = float(config.pebble.candidate_density_per_cell) * density
		var draw: Dictionary = _poisson_count(expected, _fraction(address, "pebble", key, 0, "count"), int(config.limits.max_candidates_per_cell))
		var count: int = int(draw.count)
		if bool(draw.truncated):
			stats.pebble.count_cap_truncated_cells += 1
		for index: int in range(count):
			if pebble_candidates.size() >= int(config.limits.max_candidates):
				stats.candidate_budget_hit = true
				break
			var plane: Vector2 = _point_in_hex(center, radius, address, key, index)
			var width: float = lerpf(float(config.pebble.min_width_ratio), float(config.pebble.max_width_ratio), _fraction(address, "pebble", key, index, "width")) * radius
			var region: String = "pebble-%d" % (1 + mini(2, floori(_fraction(address, "pebble", key, index, "region") * 3.0)))
			var support_fraction: float = float(support_fractions[region])
			var foot_radius: float = maxf(width * float(config.pebble.foot_radius_fraction), width * support_fraction + support_margin)
			var cell: Dictionary = cells[coord]
			pebble_candidates.append({
				"id": "pebble:%s:%s:%d" % [identity, key, index],
				"kind": "pebble", "key": key, "plane": plane,
				"height": float(cell.level) * quantum, "width": width,
				"region": region, "foot_radius": foot_radius,
				"support_radius_fraction": support_fraction,
				"priority": _fraction(address, "pebble", key, index, "priority"),
				"coord": coord, "density": density
			})
		if bool(stats.candidate_budget_hit):
			break
	stats.pebble.proposed = pebble_candidates.size()
	pebble_candidates.sort_custom(_priority_before)
	var pebble_bins: Dictionary = {}
	var per_cell: Dictionary = {}
	for candidate: Dictionary in pebble_candidates:
		if entries.size() >= int(config.limits.max_entries):
			stats.entry_budget_hit = true
			break
		var coord: Vector2i = candidate.coord
		var plane: Vector2 = candidate.plane
		var foot_radius: float = float(candidate.foot_radius)
		if not _circle_supported(plane, foot_radius, coord, cells, radius):
			stats.pebble.support_rejected += 1
			continue
		if _circle_reserved(plane, foot_radius, reservations, radius):
			stats.pebble.reservation_rejected += 1
			continue
		if _near_rubble(plane, foot_radius + float(config.pebble.rubble_clearance_ratio) * radius, rubble_bins, radius):
			stats.pebble.rubble_conflict_rejected += 1
			continue
		if _point_conflict(plane, float(config.pebble.minimum_separation_ratio) * radius, pebble_bins, radius, foot_radius, maximum_pebble_radius):
			stats.pebble.spacing_rejected += 1
			continue
		entries.append(candidate)
		_bin_append(pebble_bins, _bin(plane, radius), candidate)
		var key: String = str(candidate.key)
		per_cell[key] = int(per_cell.get(key, 0)) + 1
		stats.pebble.placed += 1
	for key: String in per_cell:
		if int(per_cell[key]) > 1:
			stats.pebble.multiple_in_cell += 1
	entries.sort_custom(_id_before)
	stats.entries = entries.size()
	var eligible: int = int(stats.rubble.eligible_cells)
	if eligible > 0:
		stats.rubble.lottery_rate = float(stats.rubble.lottery_selected) / float(eligible)
		stats.rubble.actual_rate = float(stats.rubble.placed) / float(eligible)
	if not grounds.is_empty():
		stats.pebble.candidate_density_actual = float(stats.pebble.proposed) / float(grounds.size())
	return {"entries": entries, "stats": stats, "config": config}


static func _rubble_candidate(coord: Vector2i, cells: Dictionary, reservations: Dictionary, address: Array, config: Dictionary, radius: float, quantum: float, identity: String, stats: Dictionary) -> Dictionary:
	var walls: Array[Vector2i] = []
	var ground_count: int = 0
	for direction: Vector2i in Hex.DIRS:
		var neighbor: Vector2i = coord + direction
		if not cells.has(neighbor):
			continue
		var cell: Dictionary = cells[neighbor]
		if str(cell.terrain) == "wall":
			walls.append(neighbor)
		elif str(cell.terrain) == "ground":
			ground_count += 1
	if walls.is_empty():
		return {}
	stats.wall_adjacent_cells += 1
	if ground_count < int(config.rubble.min_ground_neighbors):
		stats.narrow_rejected += 1
		return {}
	var key: String = _key(coord)
	# One wall direction per cell, including corners. Retries only slide this edge.
	var wall_index: int = mini(walls.size() - 1, floori(_fraction(address, "rubble", key, 0, "wall") * float(walls.size())))
	var wall: Vector2i = walls[wall_index]
	var center: Vector2 = Hex.to_plane(coord, radius)
	var wall_center: Vector2 = Hex.to_plane(wall, radius)
	var normal: Vector2 = (wall_center - center).normalized()
	var tangent: Vector2 = Vector2(-normal.y, normal.x)
	var edge: Vector2 = (center + wall_center) * 0.5
	var width: float = lerpf(float(config.rubble.min_width_ratio), float(config.rubble.max_width_ratio), _fraction(address, "rubble", key, 0, "width")) * radius
	var half_width: float = width * 0.5
	var half_depth: float = width * 0.12 + 0.018 * radius
	var sprite_right:=Vector2(cos(deg_to_rad(35.0)),-sin(deg_to_rad(35.0)))
	var sprite_depth:=Vector2(-sprite_right.y,sprite_right.x)
	var wall_extent: float=absf(sprite_right.dot(normal))*half_width+absf(sprite_depth.dot(normal))*half_depth
	var edge_extent: float=absf(sprite_right.dot(tangent))*half_width+absf(sprite_depth.dot(tangent))*half_depth
	var lateral_limit: float = radius * (0.5 - float(config.rubble.wall_endpoint_margin_ratio)) - edge_extent
	if lateral_limit < 0.0:
		stats.unsafe_pose_rejected += 1
		return {}
	var reservation_rejected: bool = false
	for attempt: int in range(int(config.rubble.placement_attempts)):
		var gap: float = lerpf(float(config.rubble.min_wall_gap_ratio), float(config.rubble.max_wall_gap_ratio), _fraction(address, "rubble", key, attempt, "wall-gap")) * radius
		var shift: float = (_fraction(address, "rubble", key, attempt, "edge-offset") * 2.0 - 1.0) * lateral_limit
		var plane: Vector2 = edge - normal * (gap + wall_extent) + tangent * shift
		# Reserve a real ground footprint for the already-projected painting.
		# Its nearest edge has clearance from the wall; its full depth cannot
		# cover the central foot lane. Never squeeze art onto the wall plane.
		if gap + 2.0 * wall_extent > INRADIUS * radius - 0.24 * radius:
			continue
		var foot: PackedVector2Array = _rectangle(plane, sprite_right, sprite_depth, half_width, half_depth)
		if not _rectangle_supported(foot, coord, cells, radius):
			continue
		if _rectangle_reserved(foot, plane, sprite_right, sprite_depth, half_width, half_depth, reservations, radius):
			reservation_rejected = true
			continue
		var cell: Dictionary = cells[coord]
		return {
			"id": "rubble:%s:%s" % [identity, key], "kind": "rubble", "key": key,
			"plane": plane, "height": float(cell.level) * quantum, "width": width,
			"region": "rubble-%d" % (1 + mini(1, floori(_fraction(address, "rubble", key, 0, "region") * 2.0))),
			"wall_key": _key(wall), "wall_normal": normal, "wall_tangent": tangent,
			"wall_edge": PackedVector2Array([edge - tangent * radius * 0.5, edge + tangent * radius * 0.5]),
			"wall_gap": gap, "footprint": foot, "foot_half_width": half_width,
			"sprite_right":sprite_right,"sprite_depth":sprite_depth,"backset":width*.24,
			"wall_extent":wall_extent,"center_lane_radius":.24*radius,
			"foot_half_depth": half_depth, "ground_inset_depth": gap + 2.0 * wall_extent,
			"actor_center_exclusion": ACTOR_FOOT_RADIUS_RATIO * radius,
			"placement_attempt": attempt
		}
	if reservation_rejected:
		stats.reservation_rejected += 1
	else:
		stats.unsafe_pose_rejected += 1
	return {}


static func _normalize_cells(raw: Variant, limits: Dictionary, stats: Dictionary) -> Dictionary:
	var cells: Dictionary = {}
	var conflicts: Dictionary = {}
	if not raw is Array:
		return cells
	var values: Array = raw
	stats.input_cells = values.size()
	var count: int = mini(values.size(), int(limits.max_input_cells))
	stats.input_truncated = count < values.size()
	for index: int in range(count):
		var value: Variant = values[index]
		if not value is Dictionary:
			stats.invalid_cells += 1
			continue
		if not _integer(value.get("q"), 1000000) or not _integer(value.get("r"), 1000000) or not _integer(value.get("level"), 10000) or str(value.get("terrain", "")) not in ["ground", "wall"]:
			stats.invalid_cells += 1
			continue
		var coord: Vector2i = Vector2i(int(value.q), int(value.r))
		if conflicts.has(coord):
			stats.duplicate_cells += 1
			continue
		var cell: Dictionary = {"terrain": str(value.terrain), "level": int(value.level)}
		if cells.has(coord):
			stats.duplicate_cells += 1
			if cells[coord] != cell:
				cells.erase(coord)
				conflicts[coord] = true
				stats.conflicting_cells += 1
			continue
		cells[coord] = cell
	return cells


static func _reservation_bins(snapshot: Dictionary, config: Dictionary, radius: float, stats: Dictionary) -> Dictionary:
	var bins: Dictionary = {}
	var raw: Variant = []
	if snapshot.has("rock_reservations"):
		raw = snapshot.rock_reservations
		stats.reservation_source = "rock_reservations"
	else:
		raw = snapshot.get("nodes", [])
		stats.reservation_source = "snapshot.nodes"
		stats.reservation_fallback = true
	if not raw is Array:
		stats.reservation_error = "Reservations must be an array; scatter disabled for this floor"
		return bins
	var values: Array = raw
	if values.size() > int(config.limits.max_reservations):
		stats.reservation_error = "Reservation budget exceeded; scatter disabled for this floor"
		return bins
	for value: Variant in values:
		if not value is Dictionary or not _valid_pair(value.get("coord")):
			stats.reservation_error = "Malformed reservation coord; scatter disabled for this floor"
			return {}
		var coord: Vector2i = _pair(value.coord)
		var center: Vector2 = Hex.to_plane(coord, radius)
		var gate: bool = bool(value.get("is_gate", value.get("is_route_gate", false)))
		var protection: Dictionary = config.protection
		var center_radius: float = float(protection.gate_center_radius_ratio if gate else protection.node_center_radius_ratio) * radius
		center_radius += float(protection.clearance_ratio) * radius
		var circle: Dictionary = {"shape": "circle", "center": center, "radius": center_radius}
		_insert_reservation(bins, circle, center, center_radius, radius)
		stats.reservations += 1
		# Legacy fallback deliberately never substitutes logical node.footprint.
		var protected_raw: Variant = value.get("protected", value.get("height_flat_footprint", []))
		if not protected_raw is Array:
			stats.reservation_error = "Malformed protected marks; scatter disabled for this floor"
			return {}
		var protected_values: Array = protected_raw
		if protected_values.size() > int(config.limits.max_protected_per_reservation) or int(stats.protected_marks) + protected_values.size() > int(config.limits.max_total_protected):
			stats.reservation_error = "Protected-mark budget exceeded; scatter disabled for this floor"
			return {}
		for point: Variant in protected_values:
			if not _valid_pair(point):
				stats.reservation_error = "Malformed protected coordinate; scatter disabled for this floor"
				return {}
			var protected_center: Vector2 = Hex.to_plane(_pair(point), radius)
			var protected_radius: float = float(protection.gate_protected_hex_radius_ratio if gate else protection.protected_hex_radius_ratio) * radius
			protected_radius += float(protection.clearance_ratio) * radius
			var hex: Dictionary = {"shape": "hex", "center": protected_center, "radius": protected_radius, "polygon": _hex(protected_center, protected_radius)}
			_insert_reservation(bins, hex, protected_center, protected_radius, radius)
			stats.protected_marks += 1
	return bins


static func _circle_supported(plane: Vector2, foot_radius: float, coord: Vector2i, cells: Dictionary, radius: float) -> bool:
	var own: Dictionary = cells[coord]
	for direction: Vector2i in Hex.DIRS:
		var neighbor: Vector2i = coord + direction
		if cells.has(neighbor):
			var cell: Dictionary = cells[neighbor]
			if str(cell.terrain) == "ground" and int(cell.level) == int(own.level):
				continue
		# A one-level transition is also a support boundary: this foot is flat.
		if _circle_hex(plane, foot_radius, Hex.to_plane(neighbor, radius), radius):
			return false
	return true


static func _rectangle_supported(foot: PackedVector2Array, coord: Vector2i, cells: Dictionary, radius: float) -> bool:
	var own: Dictionary = cells[coord]
	for direction: Vector2i in Hex.DIRS:
		var neighbor: Vector2i = coord + direction
		if cells.has(neighbor):
			var cell: Dictionary = cells[neighbor]
			if str(cell.terrain) == "ground" and int(cell.level) == int(own.level):
				continue
		if _polygons_overlap(foot, _hex(Hex.to_plane(neighbor, radius), radius)):
			return false
	return true


static func _circle_reserved(plane: Vector2, foot_radius: float, bins: Dictionary, radius: float) -> bool:
	for x: int in range(floori((plane.x - foot_radius) / radius), floori((plane.x + foot_radius) / radius) + 1):
		for y: int in range(floori((plane.y - foot_radius) / radius), floori((plane.y + foot_radius) / radius) + 1):
			var values: Array = bins.get(Vector2i(x, y), [])
			for value: Dictionary in values:
				var center: Vector2 = value.center
				if str(value.shape) == "circle":
					var separation: float = foot_radius + float(value.radius)
					if plane.distance_squared_to(center) < separation * separation:
						return true
				elif _circle_hex(plane, foot_radius, center, float(value.radius)):
					return true
	return false


static func _rectangle_reserved(foot: PackedVector2Array, plane: Vector2, tangent: Vector2, normal: Vector2, half_width: float, half_depth: float, bins: Dictionary, radius: float) -> bool:
	var reach: float = half_width + half_depth
	for x: int in range(floori((plane.x - reach) / radius), floori((plane.x + reach) / radius) + 1):
		for y: int in range(floori((plane.y - reach) / radius), floori((plane.y + reach) / radius) + 1):
			var values: Array = bins.get(Vector2i(x, y), [])
			for value: Dictionary in values:
				if str(value.shape) == "circle":
					if _circle_rectangle(value.center, float(value.radius), plane, tangent, normal, half_width, half_depth):
						return true
				elif _polygons_overlap(foot, value.polygon):
					return true
	return false


static func _near_rubble(plane: Vector2, foot_radius: float, bins: Dictionary, radius: float) -> bool:
	var reach: float = radius + foot_radius
	for x: int in range(floori((plane.x - reach) / radius), floori((plane.x + reach) / radius) + 1):
		for y: int in range(floori((plane.y - reach) / radius), floori((plane.y + reach) / radius) + 1):
			var values: Array = bins.get(Vector2i(x, y), [])
			for value: Dictionary in values:
				if _circle_rectangle(plane, foot_radius, value.plane, value.sprite_right, value.sprite_depth, float(value.foot_half_width), float(value.foot_half_depth)):
					return true
	return false


static func _point_conflict(plane: Vector2, separation: float, bins: Dictionary, bin_size: float, foot_radius: float = 0.0, max_other_radius: float = 0.0) -> bool:
	# The baseline gap still applies, but enlarged fragments also need enough
	# space for both projected outlines. The search includes the largest neighbor.
	var reach: float=maxf(separation,foot_radius+max_other_radius)
	for x: int in range(floori((plane.x - reach) / bin_size), floori((plane.x + reach) / bin_size) + 1):
		for y: int in range(floori((plane.y - reach) / bin_size), floori((plane.y + reach) / bin_size) + 1):
			var values: Array = bins.get(Vector2i(x, y), [])
			for value: Dictionary in values:
				var other: Vector2 = value.plane
				var required: float=maxf(separation,foot_radius+float(value.get("foot_radius",0.0)))
				if plane.distance_squared_to(other) < required * required:
					return true
	return false

static func _insert_reservation(bins: Dictionary, value: Dictionary, center: Vector2, extent: float, bin_size: float) -> void:
	for x: int in range(floori((center.x - extent) / bin_size), floori((center.x + extent) / bin_size) + 1):
		for y: int in range(floori((center.y - extent) / bin_size), floori((center.y + extent) / bin_size) + 1):
			_bin_append(bins, Vector2i(x, y), value)


static func _bin_append(bins: Dictionary, coord: Vector2i, value: Dictionary) -> void:
	if not bins.has(coord):
		bins[coord] = []
	var values: Array = bins[coord]
	values.append(value)


static func _bin(plane: Vector2, size: float) -> Vector2i:
	return Vector2i(floori(plane.x / size), floori(plane.y / size))


static func _point_in_hex(center: Vector2, radius: float, address: Array, key: String, index: int) -> Vector2:
	# Six equal-area triangles, uniform barycentric area sampling. No ordinary
	# ground-cell border inset, so same-level neighbors do not reveal a grid.
	var sector: int = mini(5, floori(_fraction(address, "pebble", key, index, "sector") * 6.0))
	var radial: float = sqrt(_fraction(address, "pebble", key, index, "radius"))
	var mix_value: float = _fraction(address, "pebble", key, index, "triangle")
	var a: Vector2 = Vector2.from_angle(TAU * float(sector) / 6.0)
	var b: Vector2 = Vector2.from_angle(TAU * float(sector + 1) / 6.0)
	return center + a.lerp(b, mix_value) * radial * radius


static func _pebble_support_fractions(stats: Dictionary) -> Dictionary:
	# Match renderer_2d's centered horizontal image rect at its fixed pitch.
	# Camera yaw rotates this footprint without changing its circumradius.
	# Convex alpha-outline vertices contain the entire horizontal painted shape.
	var catalog: RefCounted = Catalog.new()
	var regions: Dictionary = catalog.get("regions")
	var fractions: Dictionary = {}
	var fallback_regions: Array[String] = []
	var pitch_sine: float = sin(deg_to_rad(HORIZONTAL_PITCH_DEGREES))
	for name: String in ["pebble-1", "pebble-2", "pebble-3"]:
		var region: Dictionary = regions.get(name, {})
		var dimensions: Vector2 = region.get("dimensions", Vector2.ONE)
		var aspect: float = dimensions.y / dimensions.x if dimensions.x > 0.0 and dimensions.y > 0.0 else 1.0
		var outline_raw: Variant = region.get("outline", [])
		var outline: Array = []
		var valid: bool = outline_raw is Array and outline_raw.size() >= 3 and outline_raw.size() <= 256
		if valid:
			outline = outline_raw
			for pair: Variant in outline:
				if not pair is Array or pair.size() != 2 or not (pair[0] is int or pair[0] is float) or not (pair[1] is int or pair[1] is float) or not is_finite(float(pair[0])) or not is_finite(float(pair[1])):
					valid = false
					break
		if not valid:
			# Missing legacy outline uses the complete image rectangle, as renderer.
			outline = [[0, 0], [1, 0], [1, 1], [0, 1]]
			fallback_regions.append(name)
		var fraction: float = 0.0
		for pair: Array in outline:
			var x: float = float(pair[0]) - 0.5
			var y: float = (float(pair[1]) - 0.5) * aspect / pitch_sine
			fraction = maxf(fraction, Vector2(x, y).length())
		fractions[name] = fraction
	stats.support_model = "horizontal-alpha-outline-circumradius"
	stats.support_pitch_degrees = HORIZONTAL_PITCH_DEGREES
	stats.support_radius_fractions = fractions.duplicate()
	stats.support_outline_fallback_regions = fallback_regions
	return fractions


static func _poisson_count(expected: float, draw: float, cap: int) -> Dictionary:
	# Bounded inverse CDF, using one stable draw for the entire count. A low
	# lambda still allows a natural 2+ candidates in one cell; no fixed quota.
	var count: int = 0
	var probability: float = exp(-expected)
	var cumulative: float = probability
	for index: int in range(cap):
		if draw < cumulative:
			return {"count": count, "truncated": false}
		count += 1
		probability *= expected / float(count)
		cumulative += probability
	return {"count": count, "truncated": draw >= cumulative}


static func _density(plane: Vector2, address: Array, config: Dictionary, radius: float, span: float, angle: float) -> float:
	var point: Vector2 = plane.rotated(angle) / (radius * Hex.SQRT3 * span)
	var origin: Vector2i = Vector2i(floori(point.x), floori(point.y))
	var blend: Vector2 = point - Vector2(origin)
	blend = Vector2(blend.x * blend.x * (3.0 - 2.0 * blend.x), blend.y * blend.y * (3.0 - 2.0 * blend.y))
	var a: float = _fraction(address, "density", _key(origin), 0, "value")
	var b: float = _fraction(address, "density", _key(origin + Vector2i(1, 0)), 0, "value")
	var c: float = _fraction(address, "density", _key(origin + Vector2i(0, 1)), 0, "value")
	var d: float = _fraction(address, "density", _key(origin + Vector2i(1, 1)), 0, "value")
	var noise: float = lerpf(lerpf(a, b, blend.x), lerpf(c, d, blend.x), blend.y)
	var patch: float = smoothstep(float(config.patch_low), float(config.patch_high), noise)
	return float(config.background_density_factor) + float(config.patch_density_factor) * patch


static func _circle_rectangle(point: Vector2, circle_radius: float, center: Vector2, tangent: Vector2, normal: Vector2, half_width: float, half_depth: float) -> bool:
	var delta: Vector2 = point - center
	var x: float = maxf(0.0, absf(delta.dot(tangent)) - half_width)
	var y: float = maxf(0.0, absf(delta.dot(normal)) - half_depth)
	return x * x + y * y < circle_radius * circle_radius + EPSILON


static func _circle_hex(point: Vector2, circle_radius: float, center: Vector2, radius: float) -> bool:
	var local: Vector2 = point - center
	var polygon: PackedVector2Array = _hex(Vector2.ZERO, radius)
	var inside: bool = true
	var nearest: float = INF
	for index: int in range(6):
		var a: Vector2 = polygon[index]
		var b: Vector2 = polygon[(index + 1) % 6]
		if (b - a).cross(local - a) < -EPSILON:
			inside = false
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(local, a, b)
		nearest = minf(nearest, local.distance_squared_to(closest))
	return inside or nearest < circle_radius * circle_radius + EPSILON


static func _hex(center: Vector2, radius: float) -> PackedVector2Array:
	var polygon: PackedVector2Array = PackedVector2Array()
	for index: int in range(6):
		polygon.append(center + Vector2.from_angle(TAU * float(index) / 6.0) * radius)
	return polygon


static func _rectangle(center: Vector2, tangent: Vector2, normal: Vector2, half_width: float, half_depth: float) -> PackedVector2Array:
	return PackedVector2Array([
		center - tangent * half_width - normal * half_depth,
		center + tangent * half_width - normal * half_depth,
		center + tangent * half_width + normal * half_depth,
		center - tangent * half_width + normal * half_depth
	])


static func _polygons_overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	# SAT is exact for these convex hexagons/rectangles, including corner cases.
	for polygon: PackedVector2Array in [a, b]:
		for index: int in range(polygon.size()):
			var edge: Vector2 = polygon[(index + 1) % polygon.size()] - polygon[index]
			var axis: Vector2 = Vector2(-edge.y, edge.x)
			var minimum_a: float = INF
			var maximum_a: float = -INF
			var minimum_b: float = INF
			var maximum_b: float = -INF
			for point: Vector2 in a:
				var projection: float = point.dot(axis)
				minimum_a = minf(minimum_a, projection)
				maximum_a = maxf(maximum_a, projection)
			for point: Vector2 in b:
				var projection: float = point.dot(axis)
				minimum_b = minf(minimum_b, projection)
				maximum_b = maxf(maximum_b, projection)
			if maximum_a < minimum_b - EPSILON or maximum_b < minimum_a - EPSILON:
				return false
	return true


static func _fraction(address: Array, kind: String, cell: String, index: int, field: String) -> float:
	return Catalog.fraction([NAMESPACE, address[0], address[1], address[2], kind, cell, index, field])


static func _key(coord: Vector2i) -> String:
	return "%d,%d" % [coord.x, coord.y]


static func _pair(value: Array) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1]))


static func _valid_pair(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _integer(value[0], 1000000) and _integer(value[1], 1000000)


static func _integer(value: Variant, limit: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and absf(float(value)) <= float(limit) and float(value) == floor(float(value))


static func _coord_before(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x or (a.x == b.x and a.y < b.y)


static func _priority_before(a: Dictionary, b: Dictionary) -> bool:
	return float(a.priority) < float(b.priority) or (float(a.priority) == float(b.priority) and str(a.id) < str(b.id))


static func _id_before(a: Dictionary, b: Dictionary) -> bool:
	return str(a.id) < str(b.id)


static func _safe_number(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	if not (value is int or value is float) or not is_finite(float(value)):
		return fallback
	return clampf(float(value), minimum, maximum)


static func _load_config(warnings: Array[String]) -> Dictionary:
	# Each numeric specification is [default, minimum, maximum]. Invalid types
	# fall back; finite out-of-range values are clamped and reported.
	var rules: Dictionary = {
		"rubble": {
			"probability": [0.2, 0.0, 1.0],
			"min_width_ratio": [0.65, 0.4, 0.98], "max_width_ratio": [0.95, 0.4, 0.98],
			"min_wall_gap_ratio": [0.025, 0.015, 0.11], "max_wall_gap_ratio": [0.055, 0.015, 0.11],
			"wall_endpoint_margin_ratio": [0.02, 0.005, 0.12],
			"minimum_separation_ratio": [1.85, 1.0, 4.0],
			"min_ground_neighbors": [3, 2, 5], "placement_attempts": [3, 1, 8]},
		"pebble": {
			"min_width_ratio": [0.20, 0.04, 0.5], "max_width_ratio": [0.36, 0.04, 0.5],
			"foot_radius_fraction": [0.38, 0.2, 0.5],
			"support_margin_ratio": [0.005, 0.001, 0.03],
			"candidate_density_per_cell": [0.60, 0.0, 3.0],
			"minimum_separation_ratio": [0.30, 0.15, 1.0],
			"background_density_factor": [0.18, 0.0, 1.0],
			"patch_density_factor": [1.64, 0.0, 3.0],
			"min_patch_span_cells": [2.0, 1.0, 8.0], "max_patch_span_cells": [4.0, 1.0, 8.0],
			"patch_low": [0.28, 0.0, 0.9], "patch_high": [0.72, 0.1, 1.0],
			"rubble_clearance_ratio": [0.12, 0.0, 0.5]},
		"protection": {
			"node_center_radius_ratio": [0.48, 0.2, 1.0],
			"protected_hex_radius_ratio": [0.78, 0.74, 1.0],
			"gate_center_radius_ratio": [1.0, 0.5, 2.0],
			"gate_protected_hex_radius_ratio": [0.96, 0.74, 1.0],
			"clearance_ratio": [0.025, 0.0, 0.1]},
		"limits": {
			"max_input_cells": [100000, 1, 250000],
			"max_candidates": [250000, 1, 1000000],
			"max_candidates_per_cell": [6, 1, 12],
			"max_entries": [60000, 1, 250000],
			"max_reservations": [10000, 1, 25000],
			"max_protected_per_reservation": [512, 1, 1024],
			"max_total_protected": [100000, 1, 250000]}
	}
	var source: Dictionary = {}
	if FileAccess.file_exists(CONFIG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if parsed is Dictionary:
			source = parsed
		else:
			warnings.append("Invalid config JSON; using bounded defaults")
	else:
		warnings.append("Config missing; using bounded defaults")
	var config: Dictionary = {"schema_version": 1, "enabled": true}
	if source.get("enabled", true) is bool:
		config.enabled = bool(source.get("enabled", true))
	else:
		warnings.append("enabled must be boolean; using true")
	for section: String in rules:
		var section_source: Dictionary = {}
		if source.get(section, {}) is Dictionary:
			section_source = source.get(section, {})
		else:
			warnings.append(section + " must be an object; using defaults")
		var section_config: Dictionary = {}
		var section_rules: Dictionary = rules[section]
		for field: String in section_rules:
			var rule: Array = section_rules[field]
			var value: Variant = section_source.get(field, rule[0])
			var number: float = _safe_number(value, float(rule[0]), float(rule[1]), float(rule[2]))
			if not (value is int or value is float) or not is_finite(float(value)) or float(value) != number:
				warnings.append(section + "." + field + " invalid/clamped")
			section_config[field] = int(number) if rule[0] is int else number
		config[section] = section_config
	for section: String in ["rubble", "pebble"]:
		var values: Dictionary = config[section]
		if float(values.min_width_ratio) > float(values.max_width_ratio):
			values.max_width_ratio = values.min_width_ratio
			warnings.append(section + " width range normalized")
	if float(config.rubble.min_wall_gap_ratio) > float(config.rubble.max_wall_gap_ratio):
		config.rubble.max_wall_gap_ratio = config.rubble.min_wall_gap_ratio
		warnings.append("rubble wall-gap range normalized")
	if float(config.pebble.min_patch_span_cells) > float(config.pebble.max_patch_span_cells):
		config.pebble.max_patch_span_cells = config.pebble.min_patch_span_cells
		warnings.append("pebble patch-span range normalized")
	if float(config.pebble.patch_low) >= float(config.pebble.patch_high):
		config.pebble.patch_low = 0.28
		config.pebble.patch_high = 0.72
		warnings.append("pebble patch thresholds reset")
	return config

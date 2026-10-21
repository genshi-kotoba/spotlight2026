extends RefCounted
## Continuous visual support on the existing flat-top axial lattice.
## Wall tops and gate/completed state never participate in actor support.
const Hex = preload("res://systems/map/hex_coord.gd")
const Validator = preload("res://systems/map/relief_2d/height_generator.gd")
const CORE_WEIGHT := 0.24
var last_error: String = ""
var _cells: Dictionary = {}
var _visibility_known: Dictionary = {}
var _restricted := false
var _supports: Dictionary = {}
var _quantum := 0.20
var _radius := 1.0
var _local_cliffs := false


func load_layer(layer: Dictionary) -> bool:
	# Prepare privately; a failed load leaves the previous support field intact.
	var validator := Validator.new()
	var event_flat_mode: String = validator._layer_event_flat_mode(layer)
	if event_flat_mode.is_empty():
		last_error = validator.last_error
		return false
	var foundation_mode: String = validator._layer_foundation_mode(layer)
	if foundation_mode.is_empty():
		last_error = validator.last_error
		return false
	var prepared: Dictionary = validator._prepare(layer, event_flat_mode, foundation_mode)
	if prepared.is_empty():
		last_error = validator.last_error
		return false
	var quantum: Variant = layer.get("height_quantum")
	var radius: Variant = layer.get("outer_radius")
	if not validator._number(quantum) or float(quantum) <= 0.0 or float(quantum) > 1.0 or not validator._number(radius) or float(radius) <= 0.0 or float(radius) > 1024.0:
		last_error = "Support layer requires finite positive height_quantum and outer_radius"
		return false
	var next: Dictionary = {}
	for cell in layer.cells:
		if not validator._integer(cell.get("level")):
			last_error = "Support layer cell level must be a bounded integer"
			return false
		var coord := Vector2i(int(cell.q), int(cell.r))
		next[coord] = {"level": int(cell.level), "terrain": cell.terrain}
	for coord in next:
		if next[coord].terrain != "ground":
			continue
		for neighbor in Hex.neighbors(coord):
			if next.has(neighbor) and next[neighbor].terrain == "ground" and absi(next[coord].level - next[neighbor].level) > 1:
				last_error = "Adjacent support ground levels differ by more than one"
				return false
	for node in layer.nodes:
		var reduced: bool = foundation_mode in ["partial", "center"] or (foundation_mode == "legacy" and event_flat_mode != "full" and node.type == "event")
		if reduced and not node.has("height_flat_footprint"):
			last_error = "Reduced node foundation requires height_flat_footprint: " + node.id
			return false
		var level: int = next[Vector2i(int(node.coord[0]), int(node.coord[1]))].level
		for coord in prepared.protected_footprints[node.id]:
			if next[coord].level != level:
				last_error = "Support node foundation is not one flat platform: " + node.id
				return false
	var supports: Dictionary = _build_supports(next, float(quantum), {}, false)
	_cells = next
	_supports = supports
	_visibility_known.clear()
	_restricted = false
	_quantum = float(quantum)
	_radius = float(radius)
	_local_cliffs = layer.get("metadata", {}).get("height", {}).get("support_boundary", "") == "local-real-barycentric-v1"
	last_error = ""
	return true


func set_visibility(known: Dictionary, restricted: bool = true) -> void:
	# Session uses "q,r" -> bool. Rebuild from visible ground only, replacing
	# earlier supports so revealed terrain cannot leak back through virtual walls.
	var effective := known if restricted else {}
	if _restricted == restricted and _visibility_known == effective: return
	_supports = _build_supports(_cells, _quantum, known, restricted)
	_visibility_known = effective.duplicate()
	_restricted = restricted


func _build_supports(cells: Dictionary, quantum: float, known: Dictionary, restricted: bool) -> Dictionary:
	# Every triangle shares canonical centers. Hidden ground is treated as a
	# virtual center; its height never contributes until its known flag is true.
	var ground: Dictionary = {}
	for coord in cells:
		if cells[coord].terrain != "ground":
			continue
		var visible: Variant = known.get("%d,%d" % [coord.x, coord.y], false)
		if restricted and (not visible is bool or not visible):
			continue
		ground[coord] = float(cells[coord].level) * quantum
	var supports: Dictionary = ground.duplicate()
	var virtual: Dictionary = {}
	for coord in ground:
		for neighbor in Hex.neighbors(coord):
			if not ground.has(neighbor):
				virtual[neighbor] = true
	for coord in virtual:
		var total := 0.0
		var count := 0
		for neighbor in Hex.neighbors(coord):
			if ground.has(neighbor):
				total += float(ground[neighbor])
				count += 1
		supports[coord] = total / count
	return supports


func level_height(coord: Vector2i) -> float:
	return float(_cells[coord].level) * _quantum if _cells.has(coord) else 0.0


func height_at(plane: Vector2) -> float:
	if _cells.is_empty() or not is_finite(plane.x) or not is_finite(plane.y):
		return 0.0
	var coord: Vector2i = Hex.from_plane(plane, _radius)
	var center: Vector2 = Hex.to_plane(coord, _radius)
	var local := plane - center
	var h: float = _supports.get(coord, 0.0)
	if local.length_squared() < 0.000000000001:
		return h
	for i in 6:
		var ac: Vector2i = coord + Hex.DIRS[i]
		var bc: Vector2i = coord + Hex.DIRS[(i + 1) % 6]
		var a: Vector2 = Hex.to_plane(ac, _radius) - center
		var b: Vector2 = Hex.to_plane(bc, _radius) - center
		var determinant: float = a.cross(b)
		var wa: float = local.cross(b) / determinant
		var wb: float = a.cross(local) / determinant
		var wc: float = 1.0 - wa - wb
		if minf(wa, minf(wb, wc)) < -0.000001:
			continue
		var weights := Vector3(_weight(wa), _weight(wb), _weight(wc))
		weights /= weights.x + weights.y + weights.z
		var ha: float = _supports.get(ac, 0.0)
		var hb: float = _supports.get(bc, 0.0)
		if _local_cliffs:
			# Missing vertices use only real vertices of THIS triangle. The
			# query-dependent value agrees on real-virtual edges, unlike a
			# constant average; a cliff cannot pull feet toward its other side.
			var real_a := _real_ground(ac)
			var real_b := _real_ground(bc)
			var real_c := _real_ground(coord)
			var total := 0.0
			var bary := 0.0
			if real_a: total += ha*wa; bary += wa
			if real_b: total += hb*wb; bary += wb
			if real_c: total += h*wc; bary += wc
			if bary > 0.0000001:
				var virtual_height := total/bary
				if not real_a: ha=virtual_height
				if not real_b: hb=virtual_height
				if not real_c: h=virtual_height
		return ha * weights.x + hb * weights.y + h * weights.z
	return h


func _real_ground(coord: Vector2i) -> bool:
	return _cells.has(coord) and _cells[coord].terrain == "ground" and (not _restricted or bool(_visibility_known.get("%d,%d" % [coord.x,coord.y],false)))


func _weight(barycentric: float) -> float:
	# Symmetric smooth weighting gives flat cores and agrees when the nearest
	# hex changes at an edge. Only actor feet use this; renderers keep hard hexes.
	var t: float = clampf((barycentric - CORE_WEIGHT) / (1.0 - CORE_WEIGHT), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

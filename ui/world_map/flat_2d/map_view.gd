extends Node2D

const HexCoord = preload("res://systems/map/hex_coord.gd")

const COLOR_GROUND := Color("#49666a")
const COLOR_GROUND_ALT := Color("#526d70")
const COLOR_WALL := Color("#293b43")
const COLOR_FOG := Color("#34454b")
const COLOR_GRID := Color("#88a0a0", 0.42)
const COLOR_FOG_GRID := Color("#65777a", 0.34)
const COLOR_GATE := Color("#e2a45f")
const COLOR_TEXT := Color("#e4eeee")
const COLOR_SPAWN := Color("#83e3d0")

var _cells: Array = []
var _nodes: Array = []
var _cells_by_coord: Dictionary = {}
var _cell_radius_px := 60.0
var _spawn_coord := Vector2i.ZERO
var _has_spawn := false
var _map_bounds := Rect2()
var _has_bounds := false


func set_view(data: Dictionary, cell_radius_px: float = 60.0) -> void:
	_cells = data.get("cells", []) if data.get("cells", []) is Array else []
	_nodes = data.get("nodes", []) if data.get("nodes", []) is Array else []
	_cell_radius_px = maxf(cell_radius_px, 1.0)
	_cells_by_coord.clear()
	_has_spawn = false
	_has_bounds = false
	_map_bounds = Rect2()

	for cell in _cells:
		if not cell is Dictionary:
			continue
		var coord := _cell_coord(cell)
		_cells_by_coord[coord] = cell
		_add_hex_bounds(HexCoord.to_plane(coord, _cell_radius_px))

	var spawn_value: Variant = data.get("spawn", [])
	if spawn_value is Array and spawn_value.size() >= 2:
		_spawn_coord = Vector2i(int(spawn_value[0]), int(spawn_value[1]))
		_has_spawn = true
	elif spawn_value is Vector2i:
		_spawn_coord = spawn_value
		_has_spawn = true

	queue_redraw()


func get_map_bounds() -> Rect2:
	return _map_bounds if _has_bounds else Rect2()


func _draw() -> void:
	for cell in _cells:
		if not cell is Dictionary:
			continue
		var coord := _cell_coord(cell)
		var center := HexCoord.to_plane(coord, _cell_radius_px)
		var known := bool(cell.get("known", false))
		var polygon := _hex_points(center)
		var fill := _cell_color(cell, known)
		var edge := COLOR_GRID if known else COLOR_FOG_GRID
		if known and bool(cell.get("gate_closed", false)):
			edge = COLOR_GATE
		draw_colored_polygon(polygon, fill)
		_draw_hex_outline(polygon, edge, 1.35)
		if known and bool(cell.get("gate_closed", false)):
			_draw_closed_gate(center)

	for node in _nodes:
		if not node is Dictionary or not _node_is_visible(node):
			continue
		_draw_node(node)

	if _has_spawn:
		_draw_spawn(HexCoord.to_plane(_spawn_coord, _cell_radius_px))


func _cell_coord(cell: Dictionary) -> Vector2i:
	return Vector2i(int(cell.get("q", 0)), int(cell.get("r", 0)))


func _node_coord(node: Dictionary) -> Vector2i:
	var coord_value: Variant = node.get("coord", [])
	if coord_value is Array and coord_value.size() >= 2:
		return Vector2i(int(coord_value[0]), int(coord_value[1]))
	return Vector2i.ZERO


func _node_is_visible(node: Dictionary) -> bool:
	if not bool(node.get("known", false)):
		return false
	var cell: Variant = _cells_by_coord.get(_node_coord(node))
	return cell is Dictionary and bool(cell.get("known", false))


func _cell_color(cell: Dictionary, known: bool) -> Color:
	if not known:
		return COLOR_FOG
	if String(cell.get("terrain", "ground")) == "wall":
		return COLOR_WALL
	var coord := _cell_coord(cell)
	return COLOR_GROUND_ALT if ((coord.x + coord.y) & 1) != 0 else COLOR_GROUND


func _hex_points(center: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(6):
		var angle := deg_to_rad(60.0 * float(i))
		points.append(center + Vector2(cos(angle), sin(angle)) * _cell_radius_px)
	return points


func _draw_hex_outline(points: PackedVector2Array, color: Color, width: float) -> void:
	var outline := PackedVector2Array()
	for point in points:
		outline.append(point)
	if not points.is_empty():
		outline.append(points[0])
	draw_polyline(outline, color, width, true)


func _draw_closed_gate(center: Vector2) -> void:
	var half_width := _cell_radius_px * 0.34
	draw_line(
		center + Vector2(-half_width, 0.0),
		center + Vector2(half_width, 0.0),
		COLOR_GATE,
		2.4,
		true
	)
	draw_line(
		center + Vector2(-half_width * 0.72, -3.5),
		center + Vector2(-half_width * 0.72, 3.5),
		COLOR_GATE,
		1.2,
		true
	)
	draw_line(
		center + Vector2(half_width * 0.72, -3.5),
		center + Vector2(half_width * 0.72, 3.5),
		COLOR_GATE,
		1.2,
		true
	)


func _draw_node(node: Dictionary) -> void:
	var center := HexCoord.to_plane(_node_coord(node), _cell_radius_px)
	var node_type := String(node.get("type", "event"))
	var marker_radius := minf(_cell_radius_px * 0.31, 19.0)
	var base_color := _node_color(node_type)
	var completed := bool(node.get("completed", false))
	var marker_color := base_color.lerp(Color("#c2d0d0"), 0.48) if completed else base_color

	if completed:
		draw_circle(center, marker_radius, marker_color, false, 2.0, true)
	else:
		draw_circle(center, marker_radius, Color("#203238"))
		draw_circle(center, marker_radius, marker_color, false, 1.8, true)

	var label := _node_label(node_type)
	var font_size := 10 if label == "BOSS" else clampi(roundi(_cell_radius_px * 0.21), 10, 14)
	var label_color := marker_color if completed else COLOR_TEXT
	var label_width := ThemeDB.fallback_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(
		ThemeDB.fallback_font,
		center + Vector2(-label_width * 0.5, float(font_size) * 0.36),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size,
		label_color
	)
	if bool(node.get("is_route_gate", false)) and not completed:
		_draw_lock_badge(center + Vector2(marker_radius * 0.68, -marker_radius * 0.66))


func _node_label(node_type: String) -> String:
	match node_type:
		"battle":
			return "B"
		"elite":
			return "E"
		"shop":
			return "$"
		"boss":
			return "BOSS"
		_:
			return "?"


func _node_color(node_type: String) -> Color:
	match node_type:
		"battle":
			return Color("#d77872")
		"elite":
			return Color("#c987d2")
		"shop":
			return Color("#e5c36d")
		"boss":
			return Color("#e77765")
		_:
			return Color("#70b8ad")


func _draw_lock_badge(center: Vector2) -> void:
	var body := Rect2(center + Vector2(-4.5, -1.0), Vector2(9.0, 7.0))
	draw_rect(body, COLOR_GATE, false, 1.5, true)
	draw_arc(center + Vector2(0.0, -1.5), 2.5, PI, TAU, 8, COLOR_GATE, 1.5, true)


func _draw_spawn(center: Vector2) -> void:
	draw_circle(center, 8.0, Color("#203238"))
	draw_circle(center, 7.0, COLOR_SPAWN, false, 1.7, true)
	draw_line(center + Vector2(-3.5, 0.0), center + Vector2(3.5, 0.0), COLOR_SPAWN, 1.4, true)
	draw_line(center + Vector2(0.0, -3.5), center + Vector2(0.0, 3.5), COLOR_SPAWN, 1.4, true)


func _add_hex_bounds(center: Vector2) -> void:
	for i in range(6):
		var angle := deg_to_rad(60.0 * float(i))
		var point := center + Vector2(cos(angle), sin(angle)) * _cell_radius_px
		if not _has_bounds:
			_map_bounds = Rect2(point, Vector2.ZERO)
			_has_bounds = true
		else:
			var left := minf(_map_bounds.position.x, point.x)
			var top := minf(_map_bounds.position.y, point.y)
			var right := maxf(_map_bounds.end.x, point.x)
			var bottom := maxf(_map_bounds.end.y, point.y)
			_map_bounds = Rect2(Vector2(left, top), Vector2(right - left, bottom - top))

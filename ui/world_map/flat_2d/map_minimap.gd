extends Control

const HexCoord = preload("res://systems/map/hex_coord.gd")

const PANEL_EDGE := Color("#91aaa8", 0.58)
const CAMERA_FILL := Color("#b6e4df", 0.10)
const CAMERA_EDGE := Color("#b7e5dc", 0.88)
const PLAYER_COLOR := Color("#a3ffe3")
const FIT_MARGIN := 9.0


class StaticCanvas extends Control:
	const HexCoord = preload("res://systems/map/hex_coord.gd")

	const COLOR_GROUND := Color("#49666a")
	const COLOR_GROUND_ALT := Color("#526d70")
	const COLOR_WALL := Color("#293b43")
	const COLOR_FOG := Color("#34454b")
	const COLOR_GRID := Color("#91a8a7", 0.55)
	const COLOR_FOG_GRID := Color("#65777a", 0.46)
	const COLOR_GATE := Color("#e2a45f")

	var _cells: Array = []
	var _nodes: Array = []
	var _cells_by_coord: Dictionary = {}
	var _spawn_coord := Vector2i.ZERO
	var _has_spawn := false
	var _cell_radius_px := 60.0
	var _draw_origin := Vector2.ZERO
	var _draw_scale := 0.0


	func set_view(data: Dictionary, cell_radius_px: float) -> void:
		_cells = data.get("cells", []) if data.get("cells", []) is Array else []
		_nodes = data.get("nodes", []) if data.get("nodes", []) is Array else []
		_cell_radius_px = maxf(cell_radius_px, 1.0)
		_cells_by_coord.clear()
		_has_spawn = false
		for cell in _cells:
			if cell is Dictionary:
				_cells_by_coord[_cell_coord(cell)] = cell
		var spawn_value: Variant = data.get("spawn", [])
		if spawn_value is Array and spawn_value.size() >= 2:
			_spawn_coord = Vector2i(int(spawn_value[0]), int(spawn_value[1]))
			_has_spawn = true
		elif spawn_value is Vector2i:
			_spawn_coord = spawn_value
			_has_spawn = true
		queue_redraw()


	func set_layout(origin: Vector2, draw_scale: float) -> void:
		_draw_origin = origin
		_draw_scale = draw_scale
		queue_redraw()


	func _draw() -> void:
		if _cells.is_empty() or _draw_scale <= 0.0:
			return
		draw_set_transform(_draw_origin, 0.0, Vector2(_draw_scale, _draw_scale))
		var line_width := 1.0 / _draw_scale
		for cell in _cells:
			if not cell is Dictionary:
				continue
			var coord := _cell_coord(cell)
			var center := HexCoord.to_plane(coord, _cell_radius_px)
			var known := bool(cell.get("known", false))
			var fill := _cell_color(cell, known)
			var edge := COLOR_GRID if known else COLOR_FOG_GRID
			if known and bool(cell.get("gate_closed", false)):
				edge = COLOR_GATE
			var polygon := _hex_points(center)
			draw_colored_polygon(polygon, fill)
			_draw_hex_outline(polygon, edge, line_width)
			if known and bool(cell.get("gate_closed", false)):
				_draw_closed_gate(center, line_width)

		for node in _nodes:
			if not node is Dictionary or not _node_is_visible(node):
				continue
			_draw_node(node, line_width)

		if _has_spawn:
			_draw_spawn(HexCoord.to_plane(_spawn_coord, _cell_radius_px), line_width)


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


	func _draw_closed_gate(center: Vector2, line_width: float) -> void:
		var half_width := _cell_radius_px * 0.34
		draw_line(center + Vector2(-half_width, 0.0), center + Vector2(half_width, 0.0), COLOR_GATE, line_width * 1.7, true)


	func _draw_node(node: Dictionary, line_width: float) -> void:
		var center := HexCoord.to_plane(_node_coord(node), _cell_radius_px)
		var node_type := String(node.get("type", "event"))
		var color := _node_color(node_type)
		var radius := 2.5 / _draw_scale
		if bool(node.get("completed", false)):
			draw_circle(center, radius, color.lerp(Color("#c2d0d0"), 0.48), false, line_width * 1.25, true)
		else:
			draw_circle(center, radius, color)
		if bool(node.get("is_route_gate", false)) and not bool(node.get("completed", false)):
			draw_circle(center, radius + line_width * 1.2, COLOR_GATE, false, line_width, true)


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


	func _draw_spawn(center: Vector2, line_width: float) -> void:
		var radius := 3.0 / _draw_scale
		draw_circle(center, radius, Color("#203238"))
		draw_circle(center, radius * 0.78, Color("#83e3d0"), false, line_width * 1.4, true)


var _static_canvas: StaticCanvas
var _map_data: Dictionary = {}
var _map_bounds := Rect2()
var _has_bounds := false
var _cell_radius_px := 60.0
var _map_scale := 0.0
var _map_origin := Vector2.ZERO
var _has_player := false
var _player_plane := Vector2.ZERO
var _view_rect := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_static_canvas = StaticCanvas.new()
	_static_canvas.name = "StaticCanvas"
	_static_canvas.anchor_right = 1.0
	_static_canvas.anchor_bottom = 1.0
	_static_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_static_canvas.show_behind_parent = true
	add_child(_static_canvas)
	resized.connect(_on_resized)
	_refresh_layout()
	_static_canvas.set_view(_map_data, _cell_radius_px)


func set_view(data: Dictionary, cell_radius_px: float = 60.0) -> void:
	_map_data = data
	_cell_radius_px = maxf(cell_radius_px, 1.0)
	_map_bounds = _calculate_map_bounds(data.get("cells", []), _cell_radius_px)
	_has_bounds = not _map_bounds.size.is_zero_approx()
	_has_player = false
	if _static_canvas != null:
		_static_canvas.set_view(data, _cell_radius_px)
	_refresh_layout()
	queue_redraw()


func set_player(plane: Vector2, view_rect: Rect2) -> void:
	_player_plane = plane
	_view_rect = view_rect
	_has_player = true
	queue_redraw()


func _on_resized() -> void:
	_refresh_layout()
	queue_redraw()


func _refresh_layout() -> void:
	if not _has_bounds or size.x <= FIT_MARGIN * 2.0 or size.y <= FIT_MARGIN * 2.0:
		_map_scale = 0.0
		_map_origin = Vector2.ZERO
	else:
		var available := size - Vector2(FIT_MARGIN * 2.0, FIT_MARGIN * 2.0)
		var scale_x := available.x / _map_bounds.size.x
		var scale_y := available.y / _map_bounds.size.y
		_map_scale = minf(scale_x, scale_y)
		var used_size := _map_bounds.size * _map_scale
		_map_origin = Vector2(FIT_MARGIN, FIT_MARGIN) + (available - used_size) * 0.5 - _map_bounds.position * _map_scale
	if _static_canvas != null:
		_static_canvas.set_layout(_map_origin, _map_scale)


func _draw() -> void:
	if _has_player and _has_bounds and _map_scale > 0.0:
		_draw_camera_window()
		_draw_player_marker()
	draw_rect(Rect2(Vector2.ZERO, size), PANEL_EDGE, false, 1.0, true)


func _draw_camera_window() -> void:
	if _view_rect.size.x <= 0.0 or _view_rect.size.y <= 0.0:
		return
	var top_left := _map_to_control(_view_rect.position * _cell_radius_px)
	var window_size := _view_rect.size * _cell_radius_px * _map_scale
	var left := maxf(top_left.x, 0.0)
	var top := maxf(top_left.y, 0.0)
	var right := minf(top_left.x + window_size.x, size.x)
	var bottom := minf(top_left.y + window_size.y, size.y)
	if right <= left or bottom <= top:
		return
	var window := Rect2(Vector2(left, top), Vector2(right - left, bottom - top))
	draw_rect(window, CAMERA_FILL, true)
	draw_rect(window, CAMERA_EDGE, false, 1.15, true)


func _draw_player_marker() -> void:
	var center := _map_to_control(_player_plane * _cell_radius_px)
	if center.x < 0.0 or center.y < 0.0 or center.x > size.x or center.y > size.y:
		return
	draw_circle(center, 5.2, Color("#163139"))
	draw_circle(center, 3.5, PLAYER_COLOR)
	draw_circle(center, 5.0, Color("#d4fff4"), false, 1.1, true)


func _map_to_control(map_point: Vector2) -> Vector2:
	return _map_origin + map_point * _map_scale


func _calculate_map_bounds(cells: Variant, radius: float) -> Rect2:
	if not cells is Array:
		return Rect2()
	var has_bounds := false
	var bounds := Rect2()
	for cell in cells:
		if not cell is Dictionary:
			continue
		var coord := Vector2i(int(cell.get("q", 0)), int(cell.get("r", 0)))
		var center := HexCoord.to_plane(coord, radius)
		for i in range(6):
			var angle := deg_to_rad(60.0 * float(i))
			var point := center + Vector2(cos(angle), sin(angle)) * radius
			if not has_bounds:
				bounds = Rect2(point, Vector2.ZERO)
				has_bounds = true
			else:
				var left := minf(bounds.position.x, point.x)
				var top := minf(bounds.position.y, point.y)
				var right := maxf(bounds.end.x, point.x)
				var bottom := maxf(bounds.end.y, point.y)
				bounds = Rect2(Vector2(left, top), Vector2(right - left, bottom - top))
	return bounds if has_bounds else Rect2()

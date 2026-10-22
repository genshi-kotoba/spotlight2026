class_name MapViewer
extends Control
## M 地图：地形独立渲染，节点标识保持屏幕尺寸；宿主负责传送校验与存档。
signal fast_travel_requested(node_id: String, map_id: String, fingerprint: String)

const MAP_VIEW := preload("res://ui/world_map/flat_2d/map_view.gd")
const HEX := preload("res://systems/map/hex_coord.gd")
const ZOOM_RATE := 1.12
const ZOOM_MIN := 0.55
const ZOOM_MAX := 3.5
const MARGIN_RATIO := 0.18
const DRAG_THRESHOLD := 7.0
const MARKER_RADIUS := 18.0
const TYPES := ["battle", "elite", "shop", "chest", "pile", "event", "boss"]
const LABELS := {"battle":"战斗", "elite":"精英", "shop":"商店", "chest":"宝箱", "pile":"残堆", "event":"随机事件", "boss":"首领"}
const GLYPHS := {"battle":"战", "elite":"精", "shop":"店", "chest":"箱", "pile":"残", "event":"?", "boss":"王"}
const COLORS := {"battle":Color("db8980"), "elite":Color("c898ef"), "shop":Color("e8c36b"), "chest":Color("dfb970"), "pile":Color("b7afa0"), "event":Color("70c6b5"), "boss":Color("df9dc9")}
const REASONS := {"pending_request":"请先处理当前节点", "node_unavailable":"节点尚未开放", "no_safe_landing":"尚无通往此节点的安全落点", "map_changed":"地图已切换，请重新打开地图", "fingerprint_changed":"地图已更新，请重新打开地图", "invalid_session":"当前地图不可用", "presentation_pending":"本层显示准备中，请稍候"}

class MarkerOverlay:
	extends Control
	var viewer
	func _draw() -> void:
		if is_instance_valid(viewer): viewer._draw_markers(self)

var _viewport: SubViewport
var _map: Node2D
var _camera: Camera2D
var _texture: TextureRect
var _map_area: Control
var _overlay: Control
var _legend: HBoxContainer
var _footer: PanelContainer
var _info: Label
var _hint: Label
var _radius := 60.0
var _actor := Vector2.ZERO
var _has_actor := false
var _dragging := false
var _drag_moved := false
var _press_at := Vector2.ZERO
var _press_id := ""
var _hovered_id := ""
var _fit_zoom := 1.0
var _zoom_scale := 1.0
var _nodes: Array = []
var _markers: Array[Dictionary] = []
var _known_cells: Dictionary = {}
var _travel_options: Dictionary = {}
var _map_id := ""
var _fingerprint := ""
var _requesting := false
var _pulse_clock := 0.0

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	_map_area = Control.new()
	_map_area.clip_contents = true
	_map_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map_area)
	_viewport = SubViewport.new()
	_viewport.world_2d = World2D.new()
	_viewport.transparent_bg = true
	_viewport.msaa_2d = Viewport.MSAA_4X
	add_child(_viewport)
	_texture = TextureRect.new()
	_texture.texture = _viewport.get_texture()
	_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_area.add_child(_texture)
	_map = MAP_VIEW.new()
	_viewport.add_child(_map)
	_camera = Camera2D.new()
	_camera.enabled = true
	_viewport.add_child(_camera)
	_overlay = MarkerOverlay.new()
	_overlay.viewer = self
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_area.add_child(_overlay)
	_legend = HBoxContainer.new()
	_legend.add_theme_constant_override("separation", 25)
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_legend)
	for kind: String in TYPES:
		var item := Label.new()
		item.text = "%s %s" % [GLYPHS[kind], LABELS[kind]]
		item.add_theme_font_size_override("font_size", 19)
		item.add_theme_color_override("font_color", COLORS[kind])
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_legend.add_child(item)
	_build_footer()
	resized.connect(_sync_viewport_size)
	visibility_changed.connect(_visibility_changed)
	_sync_viewport_size()

func _build_footer() -> void:
	_footer = PanelContainer.new()
	_footer.add_theme_stylebox_override("panel", CommonUiSkin.panel("strip", Vector4(16, 10, 16, 10)))
	add_child(_footer)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_footer.add_child(column)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	column.add_child(row)
	_info = Label.new()
	_info.text = "点击可达节点，传送到节点前一格"
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_info.add_theme_font_size_override("font_size", 26)
	_info.add_theme_color_override("font_color", CommonUiSkin.TEXT)
	row.add_child(_info)
	for pair: Array in [["−", func(): _zoom_at(_map_area.size * 0.5, 1.0 / ZOOM_RATE)], ["＋", func(): _zoom_at(_map_area.size * 0.5, ZOOM_RATE)], ["定位主角", _recenter], ["全图", _show_all]]:
		var button := Button.new()
		button.text = pair[0]
		button.custom_minimum_size = Vector2(144, 64)
		button.add_theme_font_size_override("font_size", 24)
		CommonUiSkin.style_button(button, Vector4(12, 5, 12, 5))
		button.pressed.connect(pair[1])
		row.add_child(button)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 24)
	_hint.add_theme_color_override("font_color", Color("bdb09a"))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_hint)

func set_map(data: Dictionary, cell_radius_px: float = 60.0) -> void:
	_radius = maxf(cell_radius_px, 1.0)
	_nodes = data.get("nodes", []).duplicate(true)
	_known_cells.clear()
	for cell: Dictionary in data.get("cells", []):
		if cell.get("known", false): _known_cells[Vector2i(cell.q, cell.r)] = true
	# Markers are drawn once in screen space, never twice at different zoom sizes.
	var terrain := data.duplicate()
	terrain["nodes"] = []
	_map.set_view(terrain, _radius)
	_travel_options.clear()
	_map_id = ""
	_fingerprint = ""
	_requesting = false
	_dragging = false
	_hovered_id = ""
	_rebuild_markers()
	_show_all()
	_update_info()

func set_travel_options(map_id: String, fingerprint: String, options: Dictionary) -> void:
	_map_id = map_id
	_fingerprint = fingerprint
	_travel_options = options.duplicate(true)
	_requesting = false
	_rebuild_markers()
	_update_info()

func set_actor(plane: Vector2) -> void:
	if _has_actor and _actor.is_equal_approx(plane): return
	_actor = plane
	_has_actor = true
	if is_instance_valid(_overlay): _overlay.queue_redraw()

func clear_actor() -> void:
	_has_actor = false
	if is_instance_valid(_overlay): _overlay.queue_redraw()

func show_feedback(message: String) -> void:
	_requesting = false
	_info.text = message

static func reason_text(result: Dictionary) -> String:
	return REASONS.get(str(result.get("reason", "")), "当前只能查看地图")

func _rebuild_markers() -> void:
	_markers.clear()
	for value: Variant in _nodes:
		if not value is Dictionary or not value.get("known", false): continue
		var node: Dictionary = value.duplicate()
		var option: Dictionary = _travel_options.get(node.id, {})
		var point: Array = option.get("marker_coord", node.coord)
		var c := Vector2i(int(point[0]), int(point[1]))
		if not _known_cells.has(c): continue
		node["marker_coord"] = point
		_markers.append(node)
	if is_instance_valid(_overlay): _overlay.queue_redraw()

func _sync_viewport_size() -> void:
	if not is_instance_valid(_viewport): return
	_legend.position = Vector2(10, 4)
	_legend.size = Vector2(maxf(size.x - 20, 1), 40)
	_footer.position = Vector2(0, maxf(size.y - 144, 48))
	_footer.size = Vector2(maxf(size.x, 1), 144)
	_map_area.position = Vector2(0, 50)
	_map_area.size = Vector2(maxf(size.x, 1), maxf(size.y - 202, 1))
	_viewport.size = Vector2i(_map_area.size)
	_fit_zoom = _compute_fit()
	_camera.zoom = Vector2.ONE * _camera_scale()
	_clamp_camera()
	_render_map()

func _compute_fit() -> float:
	var bounds: Rect2 = _map.get_map_bounds()
	if bounds.size.x <= 0 or bounds.size.y <= 0: return 1.0
	return maxf(0.01, minf(_map_area.size.x / (bounds.size.x + _radius * 2), _map_area.size.y / (bounds.size.y + _radius * 2)))

func _camera_scale() -> float:
	return maxf(_fit_zoom * _zoom_scale, 0.01)

func _show_all() -> void:
	_fit_zoom = _compute_fit()
	_zoom_scale = 1.0
	_camera.zoom = Vector2.ONE * _camera_scale()
	var bounds: Rect2 = _map.get_map_bounds()
	_camera.position = bounds.get_center()
	_clamp_camera()
	_render_map()

func _recenter() -> void:
	_camera.position = _actor * _radius if _has_actor else _map.get_map_bounds().get_center()
	_clamp_camera()
	_render_map()

func _clamp_camera() -> void:
	var bounds: Rect2 = _map.get_map_bounds()
	if bounds.size.x <= 0 or bounds.size.y <= 0: return
	var margin := Vector2.ONE * _radius * (1 + MARGIN_RATIO)
	var half := _map_area.size * 0.5 / _camera.zoom
	var low := bounds.position - margin + half
	var high := bounds.end + margin - half
	_camera.position = Vector2(clampf(_camera.position.x, minf(low.x, high.x), maxf(low.x, high.x)), clampf(_camera.position.y, minf(low.y, high.y), maxf(low.y, high.y)))

func _render_map() -> void:
	_camera.force_update_scroll()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_overlay.queue_redraw()

func _zoom_at(local_point: Vector2, factor: float) -> void:
	var next := clampf(_zoom_scale * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(next, _zoom_scale): return
	var offset := local_point - _map_area.size * 0.5
	var before := _camera.position + offset / _camera.zoom
	_zoom_scale = next
	_camera.zoom = Vector2.ONE * _camera_scale()
	var after := _camera.position + offset / _camera.zoom
	_camera.position += before - after
	if _dragging: _drag_moved = true
	_clamp_camera()
	_render_map()

func _visibility_changed() -> void:
	_dragging = false
	_drag_moved = false
	if is_visible_in_tree(): _render_map()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_dragging = false
		_drag_moved = false
		_press_id = ""

func _process(delta: float) -> void:
	if not is_visible_in_tree(): return
	_pulse_clock += delta
	if _pulse_clock >= 0.05:
		_pulse_clock = 0.0
		_overlay.queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _map_area.get_rect().has_point(event.position):
				grab_focus()
				_dragging = true
				_drag_moved = false
				_press_at = event.position
				_press_id = _node_at(event.position - _map_area.position)
			elif not event.pressed:
				var was_click := _dragging and not _drag_moved
				_dragging = false
				var released_id := _node_at(event.position - _map_area.position) if _map_area.get_rect().has_point(event.position) else ""
				if was_click and not _press_id.is_empty() and _press_id == released_id: _request_travel(released_id)
			accept_event()
		elif event.pressed and _map_area.get_rect().has_point(event.position):
			if event.button_index == MOUSE_BUTTON_WHEEL_UP: _zoom_at(event.position - _map_area.position, ZOOM_RATE)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _zoom_at(event.position - _map_area.position, 1.0 / ZOOM_RATE)
			accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			_drag_moved = _drag_moved or _press_at.distance_to(event.position) >= DRAG_THRESHOLD
			if _drag_moved:
				_camera.position -= event.relative / _camera.zoom
				_clamp_camera()
				_render_map()
		_hovered_id = _node_at(event.position - _map_area.position) if _map_area.get_rect().has_point(event.position) else ""
		_update_info()
		_overlay.queue_redraw()

func _request_travel(id: String) -> void:
	var option: Dictionary = _travel_options.get(id, {})
	if _requesting: return
	if not option.get("ok", false):
		show_feedback(reason_text(option))
		return
	_requesting = true
	fast_travel_requested.emit(id, _map_id, _fingerprint)

func _node_position(node: Dictionary) -> Vector2:
	var point: Array = node.marker_coord
	return _map.get_global_transform_with_canvas() * HEX.to_plane(Vector2i(int(point[0]), int(point[1])), _radius)

func _node_at(local_point: Vector2) -> String:
	var best := ""
	var distance := (MARKER_RADIUS + 7) * (MARKER_RADIUS + 7)
	for node: Dictionary in _markers:
		var d := _node_position(node).distance_squared_to(local_point)
		if d < distance:
			distance = d
			best = str(node.id)
	return best

func _update_info() -> void:
	if not is_instance_valid(_info): return
	if _map_id.is_empty():
		_info.text = "当前地图仅供查看"
		_hint.text = "拖动平移 · ＋ / − 缩放 · 右上角关闭"
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		return
	_hint.text = "点节点传送 · 拖动平移 · ＋ / − 缩放 · 到达后再点节点进入"
	if _hovered_id.is_empty():
		_info.text = "点击亮起的节点，传送到节点前一格；灰色节点暂不可达"
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		return
	for node: Dictionary in _markers:
		if str(node.id) != _hovered_id: continue
		var option: Dictionary = _travel_options.get(node.id, {})
		var name := str(node.get("display_name", LABELS.get(node.type, "节点")))
		var status := "已完成" if node.get("completed", false) else ("路线关口" if node.get("is_route_gate", false) else "未完成")
		var action := "点按传送至门前" if option.get("ok", false) else reason_text(option)
		_info.text = "%s · %s · %s" % [name, status, action]
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if option.get("ok", false) else Control.CURSOR_ARROW
		return

func _draw_markers(canvas: Control) -> void:
	var font := CommonUiSkin.relic_bold_font()
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.003)
	var clip := Rect2(Vector2.ZERO, _map_area.size).grow(MARKER_RADIUS)
	for node: Dictionary in _markers:
		var point := _node_position(node)
		if not clip.has_point(point): continue
		var available: bool = _travel_options.get(node.id, {}).get("ok", false)
		var done: bool = node.get("completed", false)
		var color: Color = COLORS.get(node.type, Color.WHITE)
		if not available: color = color.lerp(Color("73716b"), 0.65)
		if done: color.a = 0.65
		canvas.draw_circle(point, MARKER_RADIUS + 2, Color(0.04, 0.035, 0.03, 0.96), true, -1, true)
		if available and not done: canvas.draw_circle(point, MARKER_RADIUS + 4, Color(color, 0.12 + pulse * 0.12), false, 3, true)
		canvas.draw_circle(point, MARKER_RADIUS, color, false, 2, true)
		var glyph: String = GLYPHS.get(node.type, "?")
		if node.type == "event" and node.get("opened", false):
			glyph = str(node.get("display_name", "事件")).left(1)
		var width := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
		canvas.draw_string(font, point + Vector2(-width * 0.5, 7), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, color)
		if done:
			canvas.draw_circle(point + Vector2(15, 13), 5, Color("79b396"), true, -1, true)
		elif node.get("is_route_gate", false):
			canvas.draw_rect(Rect2(point + Vector2(11, -20), Vector2(9, 7)), Color("e2a45f"), true)
		if str(node.id) == _hovered_id:
			canvas.draw_circle(point, MARKER_RADIUS + 7, Color("fff0ba"), false, 2, true)
			var option: Dictionary = _travel_options.get(node.id, {})
			if available:
				var landing: Array = option.coord
				var to: Vector2 = _map.get_global_transform_with_canvas() * HEX.to_plane(Vector2i(int(landing[0]), int(landing[1])), _radius)
				canvas.draw_circle(to, 7, Color("f9e7a4"), false, 2, true)
	if _has_actor:
		var player := _map.get_global_transform_with_canvas() * (_actor * _radius)
		canvas.draw_circle(player, 9, Color("17231f"), true, -1, true)
		canvas.draw_circle(player, 6, Color("a4f5d5"), true, -1, true)
		canvas.draw_circle(player, 10, Color("ddffeb"), false, 2, true)

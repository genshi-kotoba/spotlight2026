extends Node2D
## Assembly only: planar state + drawings + Camera2D + cross-module bridge.
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const Hex = preload("res://systems/map/hex_coord.gd")
const MapView = preload("res://ui/world_map/flat_2d/map_view.gd")
const MiniMap = preload("res://ui/world_map/flat_2d/map_minimap.gd")
const MAP_PATH := "res://data/config/flat_2d/demo_map.json"
const SETTINGS_PATH := "res://data/config/flat_2d/demo_settings.json"
const LABELS := {"battle": "普通战斗", "elite": "精英战斗", "shop": "商店", "boss": "Boss", "event": "随机事件"}

@export var demo_interactions_enabled := true
var session = Session.new()
var cell_radius_px := 60.0
var map_scale := 4.0
var move_speed := 2.1
var speed_multiplier := 1.0
var paused := false
var _map_snapshot: Dictionary = {}
var _view: Node2D
var _mini: Control
var _player: Node2D
var _camera: Camera2D
var _bus: Node
var _header: Label
var _status: Label
var _prompt: Label
var _interaction: Button
var _pause_button: Button
var _zoom_label: Label
var _speed_label: Label
var _dialog: ConfirmationDialog
var _dialog_request_id := ""
var _selected := ""
var _last_cell := Vector2i(999999, 999999)
var _status_elapsed := 0.0
var _toast := ""
var _toast_left := 0.0
var _mouse_steering_held := false
var _mouse_cursor := Vector2.ZERO
var _manual_selection := false
var _selection_origin := Vector2.ZERO
var _target_marker: Node2D
var _render_actor_plane := Vector2.ZERO
var _render_path: Array[Vector2] = []
var _render_path_length := 0.0
var _hud_root: Control

class CircleActor extends Node2D:
	var radius := 10.8
	func _draw() -> void:
		draw_circle(Vector2.ZERO, radius + 3, Color(0.05, 0.11, 0.17))
		draw_circle(Vector2.ZERO, radius, Color(0.35, 1.0, 0.85))
		draw_arc(Vector2.ZERO, radius, 0, TAU, 32, Color.WHITE, 1.2, true)
		draw_circle(Vector2.ZERO, radius * 0.25, Color(0.06, 0.28, 0.28))

class TargetMarker extends Node2D:
	var radius := 40.0
	func _draw() -> void:
		draw_arc(Vector2.ZERO, radius, 0, TAU, 48, Color("fff0a8"), 2.0, true)
		for i in 4:
			var direction := Vector2.from_angle(TAU * i / 4.0)
			draw_line(direction * (radius + 3), direction * (radius + 10), Color("fff0a8"), 2.0, true)

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("101923"))
	_register_input()
	var config: Variant = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if config is Dictionary:
		cell_radius_px = clampf(float(config.get("cell_radius_px", 60)), 20, 200)
		map_scale = clampf(float(config.get("map_scale", 4)), 0.5, 16)
		move_speed = clampf(float(config.get("move_speed", 2.1)), 0.1, 10)
	# Render interpolation is local to this assembly; logical state stays fixed-step.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_view = MapView.new()
	add_child(_view)
	_target_marker = TargetMarker.new()
	_target_marker.radius = cell_radius_px * 0.6
	_target_marker.z_index = 10
	_target_marker.hide()
	add_child(_target_marker)
	_player = CircleActor.new()
	_player.radius = Session.FOOT_RADIUS * cell_radius_px
	_player.z_index = 20
	add_child(_player)
	_camera = Camera2D.new()
	_camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
	_camera.position_smoothing_enabled = false
	_camera.rotation_smoothing_enabled = false
	_camera.ignore_rotation = true
	_camera.drag_horizontal_enabled = false
	_camera.drag_vertical_enabled = false
	_player.add_child(_camera)
	_camera.make_current()
	_build_hud()
	_bus = get_node("/root/MapEvents")
	_bus.map_load_requested.connect(load_map)
	_bus.node_result_submitted.connect(submit_node_result)
	get_viewport().size_changed.connect(_update_camera)
	var data := _initial_snapshot()
	if data.is_empty() or not load_map(data):
		_toast = "地图加载失败：" + session.last_error
		push_error(_toast)
	set_process(true)
	set_physics_process(true)

## Run demo overrides the bootstrap; the shared view never resets SeedService.
func _initial_snapshot() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_PATH))
	return data if data is Dictionary else {}

func _register_input() -> void:
	var actions := {"map2d_left": [KEY_A, KEY_LEFT], "map2d_right": [KEY_D, KEY_RIGHT], "map2d_up": [KEY_W, KEY_UP], "map2d_down": [KEY_S, KEY_DOWN], "map2d_interact": [KEY_E], "map2d_pause": [KEY_ESCAPE], "map2d_cycle": [KEY_TAB]}
	for action in actions:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			for code in actions[action]:
				var event := InputEventKey.new()
				event.physical_keycode = code
				InputMap.action_add_event(action, event)

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	_hud_root = root
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	theme.default_font = font
	theme.default_font_size = 19
	root.theme = theme
	layer.add_child(root)
	var top := PanelContainer.new()
	top.position = Vector2(18, 18)
	top.size = Vector2(520, 100)
	root.add_child(top)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	top.add_child(box)
	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 22)
	box.add_child(_header)
	var controls := HBoxContainer.new()
	box.add_child(controls)
	_pause_button = _button("暂停 Esc", func(): _set_paused(not paused))
	controls.add_child(_pause_button)
	controls.add_child(_button("重开本图", _reset_map))
	controls.add_child(_button("恢复 400%", func(): map_scale = 4.0; _update_camera()))
	_zoom_label = Label.new()
	controls.add_child(_zoom_label)
	var speed_row := HBoxContainer.new()
	box.add_child(speed_row)
	_speed_label = Label.new()
	_speed_label.text = "移速 1.00×"
	_speed_label.custom_minimum_size.x = 120
	speed_row.add_child(_speed_label)
	var slider := HSlider.new()
	slider.min_value = 0.25
	slider.max_value = 4.0
	slider.step = 0.25
	slider.value = 1.0
	slider.custom_minimum_size = Vector2(230, 24)
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(value): speed_multiplier = value; _speed_label.text = "移速 %.2f×" % value)
	speed_row.add_child(slider)
	var mini_box := PanelContainer.new()
	mini_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mini_box.offset_left = -320
	mini_box.offset_right = -18
	mini_box.offset_top = 18
	mini_box.offset_bottom = 288
	root.add_child(mini_box)
	var mini_column := VBoxContainer.new()
	mini_box.add_child(mini_column)
	var mini_title := Label.new()
	mini_title.text = "总地图 · 青色圆点为主角"
	mini_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mini_column.add_child(mini_title)
	_mini = MiniMap.new()
	_mini.custom_minimum_size = Vector2(294, 230)
	_mini.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mini_column.add_child(_mini)
	var footer := PanelContainer.new()
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 18
	footer.offset_right = -18
	footer.offset_top = -147
	footer.offset_bottom = -18
	root.add_child(footer)
	var footer_box := VBoxContainer.new()
	footer.add_child(footer_box)
	var row := HBoxContainer.new()
	footer_box.add_child(row)
	_prompt = Label.new()
	_prompt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_prompt)
	_interaction = _button("交互 E", _interact)
	row.add_child(_interaction)
	var help := Label.new()
	help.text = "WASD / 方向键，或按住左键朝鼠标移动 · E 交互 · Tab 切换 · 滚轮缩放 · Esc 暂停"
	help.add_theme_color_override("font_color", Color("a9bbcc"))
	footer_box.add_child(help)
	var legend := Label.new()
	legend.text = "节点：B 普通战斗 · E 精英 · $ 商店 · ? 随机事件 · BOSS 首领 · 橙色锁为路线关口"
	legend.add_theme_color_override("font_color", Color("a9bbcc"))
	footer_box.add_child(legend)
	_status = Label.new()
	footer_box.add_child(_status)
	_dialog = ConfirmationDialog.new()
	_dialog.title = "节点接入演示"
	_dialog.ok_button_text = "模拟完成"
	_dialog.cancel_button_text = "取消并返回地图"
	_dialog.dialog_hide_on_ok = false
	_dialog.confirmed.connect(func(): _demo_result("completed"))
	_dialog.canceled.connect(func(): _demo_result("cancelled"))
	add_child(_dialog)

func _button(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button

## Public assembly API. On failure, neither the live map nor its state changes.
func load_map(snapshot: Dictionary, saved_state: Dictionary = {}) -> bool:
	var candidate = Session.new()
	if not candidate.load_map(snapshot) or (not saved_state.is_empty() and not candidate.restore_state(saved_state)):
		_show_toast("加载拒绝：" + candidate.last_error)
		return false
	session = candidate
	_map_snapshot = candidate.get_snapshot()
	_selected = ""
	_manual_selection = false
	_mouse_steering_held = false
	_last_cell = Vector2i(999999, 999999)
	_dialog.hide()
	_dialog_request_id = ""
	_set_paused(false)
	_sync_view()
	_sync_actor(false)
	_update_camera()
	_header.text = "纯 2D 地图 · 第 %d 层\nSeed %s" % [session.floor_index, session.seed.left(32)]
	_bus.map_loaded.emit(session.map_id, session.seed)
	if session != candidate:
		return true
	_bus.player_cell_entered.emit(session.map_id, _last_cell)
	if session != candidate:
		return true
	_emit_state()
	if session != candidate:
		return true
	if not session.pending.is_empty():
		# Rebind restored business state; this does not start a new encounter.
		_bus.node_interaction_restored.emit(session.pending.duplicate(true))
		if session != candidate:
			return true
		_show_toast("已恢复待结算节点；等待业务模块回传")
	return true

func capture_state() -> Dictionary:
	return session.capture_state()

func _reset_map() -> void:
	if not session.pending.is_empty():
		_show_toast("请先完成或取消当前节点")
		return
	load_map(_map_snapshot)
	_show_toast("只重开此地图状态；未重置局内种子系统")

func _sync_view() -> void:
	var data: Dictionary = session.get_view()
	_view.set_view(data, cell_radius_px)
	_mini.set_view(data, cell_radius_px)

func _sync_actor(emit_notifications: bool = true) -> void:
	# Teleports/load/results reset the interpolation history atomically.
	_render_path = [session.actor_plane]
	_render_path_length = 0.0
	_render_motion(1.0)
	_notify_actor_cell(emit_notifications)

func _notify_actor_cell(emit_notifications: bool = true) -> void:
	var c := Hex.from_plane(session.actor_plane, 1.0)
	if c != _last_cell:
		_last_cell = c
		if _bus and emit_notifications:
			var active = session
			_bus.player_cell_entered.emit(session.map_id, c)
			if session == active:
				_emit_state()

func _render_motion(fraction: float) -> void:
	var distance := _render_path_length * clampf(fraction, 0.0, 1.0)
	_render_actor_plane = session.actor_plane
	# Follow the collision-safe polyline, rather than cutting across corners
	# with a straight interpolation between the two physics endpoints.
	for i in range(1, _render_path.size()):
		var length := _render_path[i - 1].distance_to(_render_path[i])
		if distance <= length and length > 0.0000001:
			_render_actor_plane = _render_path[i - 1].lerp(_render_path[i], distance / length)
			break
		distance -= length
	_player.position = _render_actor_plane * cell_radius_px
	_camera.force_update_scroll()
	_update_minimap()

func _update_camera() -> void:
	if not is_inside_tree() or not is_instance_valid(_view) or not is_instance_valid(_camera):
		return
	var bounds: Rect2 = _view.get_map_bounds()
	var viewport := get_viewport_rect().size
	if bounds.size.x <= 0 or bounds.size.y <= 0 or viewport.x <= 0 or viewport.y <= 0:
		return
	var fit := minf(viewport.x / (bounds.size.x + cell_radius_px * 2), viewport.y / (bounds.size.y + cell_radius_px * 2))
	_camera.zoom = Vector2.ONE * fit * map_scale
	_camera.force_update_scroll()
	_zoom_label.text = "%d%%" % roundi(map_scale * 100)
	_update_minimap()

func _update_minimap() -> void:
	if not is_inside_tree() or not is_instance_valid(_mini):
		return
	var half := get_viewport_rect().size / (_camera.zoom * cell_radius_px * 2.0)
	_mini.set_player(_render_actor_plane, Rect2(_render_actor_plane - half, half * 2))

func _physics_process(delta: float) -> void:
	var direction := Vector2.ZERO
	if not paused and session.pending.is_empty() and DisplayServer.window_is_focused():
		direction = _movement_direction()
	_advance_motion(direction, delta)

func _advance_motion(direction: Vector2, delta: float) -> void:
	session.move_actor(direction * move_speed * speed_multiplier * minf(delta, 0.05))
	_render_path.assign(session.motion_path)
	_render_path_length = 0.0
	for i in range(1, _render_path.size()):
		_render_path_length += _render_path[i - 1].distance_to(_render_path[i])
	_notify_actor_cell()

func _movement_direction() -> Vector2:
	if get_viewport().gui_get_focus_owner() != null:
		return Vector2.ZERO
	var keyboard := Input.get_vector("map2d_left", "map2d_right", "map2d_up", "map2d_down")
	if not keyboard.is_zero_approx():
		return keyboard
	if not _mouse_steering_held or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return Vector2.ZERO
	var cursor := _mouse_cursor
	if not get_viewport_rect().has_point(cursor) or get_viewport().gui_get_hovered_control() != null:
		return Vector2.ZERO
	# Camera stays centered: this is continuous steering, not a world-space
	# click destination. A small screen deadzone avoids jitter near the actor.
	var offset := cursor - get_viewport_rect().get_center()
	return offset.normalized() if offset.length() > 12.0 else Vector2.ZERO

func _update_selection() -> void:
	var nearby: Array[String] = session.nearby_nodes()
	if _selected not in nearby or session.actor_plane.distance_to(_selection_origin) > 0.25:
		_manual_selection = false
	if not _manual_selection:
		_selected = nearby[0] if not nearby.is_empty() else ""
	_target_marker.visible = not _selected.is_empty()
	if not _selected.is_empty():
		var node: Dictionary = session.nodes[_selected]
		var point := Session.coord(node.coord)
		if not session.known.has(Session.key(point)):
			for value in node.footprint:
				if session.known.has(Session.key(Session.coord(value))):
					point = Session.coord(value)
					break
		_target_marker.position = Hex.to_plane(point, cell_radius_px)

func _process(delta: float) -> void:
	_render_motion(Engine.get_physics_interpolation_fraction())
	_toast_left = maxf(0, _toast_left - delta)
	_status_elapsed += delta
	_update_selection()
	_interaction.text = "进入关口 E" if not _selected.is_empty() and session.nodes[_selected].is_route_gate else "交互 E"
	_interaction.disabled = paused or not session.pending.is_empty() or _selected.is_empty()
	if not session.pending.is_empty():
		_prompt.text = "正在处理节点；等待结果回传"
	elif paused:
		_prompt.text = "已暂停 · 点击继续或按 Esc"
	elif _selected.is_empty():
		_prompt.text = "自由探索 · 灰雾只显示轮廓 · 橙色关口需完成本地战斗"
	else:
		var node: Dictionary = session.nodes[_selected]
		_prompt.text = "交互目标：%s  %s%s%s" % [LABELS[node.type], _selected, " · 路线关口" if node.is_route_gate else "", " · 可再次访问" if session.completed.has(_selected) else ""]
	if _status_elapsed >= 0.25:
		_status_elapsed = 0
		_status.text = "位置 (%d, %d) · 已完成 %d / %d · %.0f FPS%s" % [_last_cell.x, _last_cell.y, session.completed.size(), session.nodes.size(), Engine.get_frames_per_second(), " · " + _toast if _toast_left > 0 else ""]

func _input(event: InputEvent) -> void:
	# Use viewport-local event positions, including the first button press.
	# OS cursor polling can disagree with routed window events on macOS.
	if event is InputEventMouse:
		_mouse_cursor = event.position
	# Release must also reach us when a UI control consumes the event.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_mouse_steering_held = false

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("map2d_pause"):
		if session.pending.is_empty():
			_set_paused(not paused)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("map2d_interact") and not paused:
		_interact()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("map2d_cycle"):
		var nearby: Array[String] = session.nearby_nodes()
		if not nearby.is_empty():
			_selected = nearby[(nearby.find(_selected) + 1) % nearby.size()]
			_manual_selection = true
			_selection_origin = session.actor_plane
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not paused and session.pending.is_empty():
		_mouse_steering_held = true
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and not paused and session.pending.is_empty():
		map_scale = clampf(map_scale * (1.1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.1), 0.5, 16)
		_update_camera()
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	# A node's modal temporarily takes focus from the root window. Pending
	# already blocks movement, so do not leave the map paused on its return.
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and is_inside_tree():
		_mouse_steering_held = false
		if is_instance_valid(_pause_button) and session.pending.is_empty():
			_set_paused(true)

func _set_paused(value: bool) -> void:
	paused = value
	_mouse_steering_held = false
	if is_instance_valid(_player):
		_sync_actor(false)
	_pause_button.text = "继续 Esc" if paused else "暂停 Esc"

func _interact() -> void:
	_update_selection()
	if paused or _selected.is_empty():
		return
	var request: Dictionary = session.request_node(_selected)
	if request.is_empty():
		return
	_mouse_steering_held = false
	_sync_actor(false)
	var active = session
	_emit_state()
	if session != active or session.pending.get("request_id") != request.request_id:
		return
	_bus.node_interaction_requested.emit(request.duplicate(true))
	# A synchronous external result may already have resolved this request.
	if demo_interactions_enabled and session == active and session.pending.get("request_id") == request.request_id:
		_dialog_request_id = request.request_id
		_dialog.title = "路线关口 · 完成后开放后方" if request.is_route_gate else "节点接入演示"
		_dialog.dialog_text = "%s · %s\n\n这里只演示节点请求与结果回传。\n正式战斗、商店和事件由各自模块处理。\n%s" % [LABELS[request.type], request.node_id, "完成本关口将揭开后方迷雾并允许通行；取消不解锁。" if request.is_route_gate else "此节点不是路线关口；完成不改变后方区域的可达性。"]
		_dialog.popup_centered(Vector2i(570, 255))

func _demo_result(status: String) -> void:
	if _dialog_request_id.is_empty():
		return
	_bus.node_result_submitted.emit({"request_id": _dialog_request_id, "status": status})

func submit_node_result(result: Dictionary) -> bool:
	var active = session
	var request: Dictionary = session.pending.duplicate(true)
	var previous_known: int = session.known.size()
	if not session.resolve_request(result):
		_show_toast("结果拒绝：" + session.last_error)
		return false
	_dialog.hide()
	_dialog_request_id = ""
	_sync_view()
	_sync_actor()
	# Signal listeners may synchronously load another floor. Every event is
	# scoped to the completed request; never read a replacement map's ID.
	_bus.map_state_changed.emit(request.map_id, active.capture_state())
	_bus.node_interaction_resolved.emit(request.request_id, request.node_id, result.status)
	if result.status == "completed" and request.type == "boss":
		_bus.boss_cleared.emit(request.map_id, request.node_id)
		if session == active:
			_show_toast("Boss 已完成；其余未完成节点仍可继续探索")
	elif session == active:
		if result.status == "completed" and request.is_route_gate:
			_show_toast("关口已开放 · 新揭开 %d 格 · 可继续向后探索" % (session.known.size() - previous_known))
		else:
			_show_toast("节点已完成" if result.status == "completed" else "已返回地图，节点仍未完成")
	return true

func _emit_state() -> void:
	if _bus and not session.map_id.is_empty():
		_bus.map_state_changed.emit(session.map_id, session.capture_state())

func _show_toast(message: String) -> void:
	_toast = message
	_toast_left = 5.0

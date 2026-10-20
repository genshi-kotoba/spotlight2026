extends Node2D
## Assembly only: planar state + drawings + Camera2D + cross-module bridge.
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const Hex = preload("res://systems/map/hex_coord.gd")
const EventCatalog = preload("res://systems/map/flat_2d/alchemy_event_catalog.gd")
const MapView = preload("res://ui/world_map/flat_2d/map_view.gd")
const MiniMap = preload("res://ui/world_map/flat_2d/map_minimap.gd")
const RunPanel = preload("res://ui/hud/run_status_panel.gd")
const RunMenu = preload("res://ui/hud/run_menu_overlay.gd")
const MapViewerScript = preload("res://ui/world_map/map_viewer.gd")
const FastTravel = preload("res://systems/map/flat_2d/map_fast_travel.gd")
const TravelEffect = preload("res://ui/world_map/flat_2d/map_fast_travel_effect.gd")
const StepDust = preload("res://systems/map/flat_2d/actor_step_dust.gd")
const EntryFade = preload("res://ui/world_map/flat_2d/map_entry_fade.gd")
const MAP_PATH := "res://data/config/flat_2d/demo_map.json"
const SETTINGS_PATH := "res://data/config/flat_2d/demo_settings.json"
const LABELS := {"battle": "普通战斗", "elite": "精英战斗", "shop": "商店", "boss": "Boss", "event": "随机事件", "chest": "宝箱", "pile": "残堆"}
const WALK_ACCELERATION_DELAY := 2.0
const WALK_ACCELERATION_DURATION := 1.0
const WALK_ACCELERATION_MAX := 1.5
## 起步与停步的速度变化率，平面单位/秒²。按基础速度 4.2 算，起步约 0.10 秒、停步约 0.12 秒。
const WALK_START_ACCEL := 42.0
const WALK_STOP_ACCEL := 34.0
## 顶着障碍还按着方向时，先给这么久的宽限，再清零加速进度。
const WALK_BLOCKED_GRACE := 0.2

@export var demo_interactions_enabled := true
var session = Session.new()
var cell_radius_px := 60.0
var map_scale := 4.0
var move_speed := 2.1
## User-adjustable base speed; the continuous-walk bonus never changes it.
var speed_multiplier := 2.0
var _continuous_walk_seconds := 0.0
var _velocity := Vector2.ZERO
## 移动中按住加速键，直接吃满连续行走的加速档。
var _sprint_held := false
var _blocked_seconds := 0.0
var paused := false
var _map_snapshot: Dictionary = {}
var _view: Node2D
var _mini: Control
var _player: Node2D
var _camera: Camera2D
var _bus: Node
var _header: Label
var _seed_label: Label
var _status: Label
var _prompt: Label
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
## 右下信息面板的内容列：子类（跑图落点）往这里加行。
var _info_column: VBoxContainer
var _run_panel: RunStatusPanel
## 状态列内容签名，用来判断背包/血量/资源有没有被别的流程改动。
var _panel_signature := ""
var _run_menu: RunMenuOverlay
var _menu_paused_before := false
var _resume_after_focus := false
var _menu_map: Control
## 脚步尘：世界空间的角色表现，跟 _player.position 同一套显示坐标。
var _step_dust: Node2D
## 原地重建地图的黑场节拍，见 load_map_with_beat。
var _entry_fade: CanvasLayer
var _dust_last_position := Vector2.ZERO
var _travel_effect: CanvasLayer
var _fast_travel_busy := false
var _travel_failure := ""
var _travel_return_paused := false

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
	_view = _create_map_view()
	if _view.get_parent() == null:
		add_child(_view)
	_target_marker = TargetMarker.new()
	_target_marker.radius = cell_radius_px * 0.6
	_target_marker.z_index = 10
	_target_marker.hide()
	add_child(_target_marker)
	_player = _create_actor()
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
	_step_dust = StepDust.new()
	add_child(_step_dust)
	_build_hud()
	_entry_fade = EntryFade.new()
	_entry_fade.name = "MapEntryFade"
	add_child(_entry_fade)
	_travel_effect = TravelEffect.new()
	_travel_effect.name = "MapTravelEffect"
	add_child(_travel_effect)
	_travel_effect.finished.connect(_on_fast_travel_finished)
	_bus = get_node("/root/MapEvents")
	_bus.map_load_requested.connect(_on_map_load_requested)
	_bus.node_result_submitted.connect(submit_node_result)
	get_viewport().size_changed.connect(_update_camera)
	var data := _initial_snapshot()
	if data.is_empty() or not load_map(data, _initial_state()):
		_toast = "地图加载失败：" + session.last_error
		push_error(_toast)
	set_process(true)
	set_physics_process(true)

## Presentation hooks keep movement, discovery and business requests in this
## shared assembly. Height is never used to invent new routes or encounters.
func _create_map_view() -> Node2D:
	return MapView.new()

func _create_actor() -> Node2D:
	var actor := CircleActor.new()
	actor.radius = Session.FOOT_RADIUS * cell_radius_px
	return actor

func _prepare_presentation(_candidate: RefCounted) -> bool:
	return true

func _plane_to_display(point: Vector2) -> Vector2:
	return point * cell_radius_px

func _place_actor(point: Vector2) -> void:
	_player.position = _plane_to_display(point)

func _direction_to_plane(direction: Vector2) -> Vector2:
	return direction

## Run demo overrides the bootstrap; the shared view never resets SeedService.
func _handle_menu_hotkeys(event: InputEvent) -> bool:
	# Esc 设置 / Tab 背包 / M 地图；在对应页再按一次即退出，Esc 在任意页都能退出。
	if _run_menu == null or not event is InputEventKey or event.is_echo() or _dialog.visible:
		return false
	var open := _run_menu.is_open()
	var page := _run_menu.current_page()
	if event.is_action_pressed("ui_cancel"):
		if open:
			_run_menu.close()
		else:
			_open_run_menu(2)
	elif event.is_action_pressed("ui_focus_next"):
		if open and page == 1:
			_run_menu.close()
		else:
			_open_run_menu(1)
	elif event.is_action_pressed("menu_map"):
		if open and page == 0:
			_run_menu.close()
		else:
			_open_run_menu(0)
	else:
		return false
	get_viewport().set_input_as_handled()
	return true


func _on_minimap_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_open_run_menu(0)


func _open_run_menu(page: int = 1) -> void:
	if _run_menu == null or _fast_travel_busy:
		return
	if _run_panel != null and _run_panel._relic_book != null:
		_run_panel._relic_book._hide_tip()
	if _menu_map == null:
		# 查看器只发送节点请求；通行校验和传送由当前地图宿主处理。
		# 先挂进浮层再喂数据，查看器内部节点在 _ready 里才建好。
		_menu_map = MapViewerScript.new()
		_run_menu.set_map_viewer(_menu_map)
		_menu_map.fast_travel_requested.connect(_on_map_fast_travel)
	# 每次打开都重新喂一份"已探索视图"：地形、迷雾、已解锁节点和小地图同源。
	_menu_map.set_map(session.get_view(), cell_radius_px)
	var destinations: Dictionary = FastTravel.options(session)
	if not _fast_travel_ready():
		for destination: Dictionary in destinations.values():
			destination.ok = false
			destination.reason = "presentation_pending"
	_menu_map.set_travel_options(session.map_id, session.fingerprint, destinations)
	_update_minimap()
	if _menu_map != null and is_instance_valid(_menu_map):
		_menu_map.set_actor(_render_actor_plane)
	# 打开菜单即锁住外层地图：暂停会同时挡住移动、鼠标转向与滚轮缩放，
	# 免得在菜单里缩放地图时外面的大地图跟着一起动。
	if not _run_menu.is_open():
		_menu_paused_before = paused
	_set_paused(true)
	_run_menu.open(page)


func _on_run_menu_closed() -> void:
	if not _fast_travel_busy: _set_paused(_menu_paused_before)


func _on_map_fast_travel(node_id: String, map_id: String, fingerprint: String) -> void:
	if _fast_travel_busy: return
	if not _run_menu.is_open() or _run_menu.current_page() != 0 or _dialog.visible:
		_menu_map.show_feedback("请在地图页选择目的地")
		return
	if not _fast_travel_ready():
		_menu_map.show_feedback("本层显示准备中，请稍候")
		return
	var preview: Dictionary = FastTravel.preview(session, node_id, map_id, fingerprint)
	if not preview.ok:
		_menu_map.show_feedback(MapViewerScript.reason_text(preview))
		return
	var point := Vector2(float(preview.actor_plane[0]), float(preview.actor_plane[1]))
	var direction := _plane_to_display(point) - _plane_to_display(session.actor_plane)
	_fast_travel_busy = true
	_travel_failure = ""
	_travel_return_paused = _menu_paused_before
	_velocity = Vector2.ZERO
	_sprint_held = false
	_mouse_steering_held = false
	_reset_walk_acceleration()
	_run_menu.close()
	if not _travel_effect.play(_fast_travel_portrait(), direction,
			_commit_fast_travel.bind(node_id, map_id, fingerprint, session), _fast_travel_portrait):
		_travel_failure = "传送效果未就绪，请重试"
		_on_fast_travel_finished(false)


func _commit_fast_travel(node_id: String, map_id: String, fingerprint: String, active) -> bool:
	if session != active or not _fast_travel_ready():
		_travel_failure = "地图状态已改变，请重新选择"
		return false
	var previous: Dictionary = session.capture_state()
	var previous_path: Array[Vector2] = session.motion_path.duplicate()
	var result: Dictionary = FastTravel.travel(session, node_id, map_id, fingerprint)
	if not result.ok:
		_travel_failure = MapViewerScript.reason_text(result)
		return false
	# Save before publishing the new position to the renderer. An IO failure
	# leaves both the visible actor and the session at their original location.
	if _persist_fast_travel(previous) != OK:
		session.actor_plane = Vector2(float(previous.actor_plane[0]), float(previous.actor_plane[1]))
		session.motion_path = previous_path
		_travel_failure = "保存失败，仍停留原位置；请重试"
		return false
	_mouse_steering_held = false
	_reset_walk_acceleration()
	_selected = node_id if node_id in session.nearby_nodes() else ""
	_manual_selection = not _selected.is_empty()
	_selection_origin = session.actor_plane
	_sync_actor(false)
	_after_fast_travel()
	_update_camera()
	_bus.player_cell_entered.emit(active.map_id, _last_cell)
	if session != active:
		return false
	_emit_state()
	if session != active:
		return false
	return true


func _on_fast_travel_finished(success: bool) -> void:
	if not _fast_travel_busy: return
	_fast_travel_busy = false
	_set_paused(_travel_return_paused or not get_window().has_focus())
	if not get_window().has_focus(): _resume_after_focus = not _travel_return_paused
	if success:
		_show_toast("已到达节点前方 · E 交互")
	else:
		_open_run_menu(0)
		_menu_paused_before = _travel_return_paused
		_menu_map.show_feedback(_travel_failure)


func _cancel_fast_travel() -> void:
	_fast_travel_busy = false
	if is_instance_valid(_travel_effect): _travel_effect.cancel()


func _fast_travel_portrait() -> Dictionary:
	var feet := _player.get_global_transform_with_canvas().origin
	var radius := Session.FOOT_RADIUS * cell_radius_px * _camera.zoom.x
	return {"feet": feet, "body": Rect2(feet - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)}


## Formal hosts persist through their existing save gateway; flat demos remain
## usable without a run/save dependency. No schema or random stream is added.
func _persist_fast_travel(_previous_state: Dictionary) -> Error:
	return OK


func _fast_travel_ready() -> bool:
	return not session.map_id.is_empty()


func _after_fast_travel() -> void:
	pass


func _refresh_run_panel() -> void:
	if _run_panel == null:
		return
	# 血量、银币、万灵药取跑图状态；还没开局时先用占位值。
	if GlobalState != null and GlobalState.run_active and GlobalState.current_run != null:
		var run: RunStateMachine = GlobalState.current_run
		_run_panel.set_health(run.health, run.max_health, 0, [])
		RunRewards.ensure_state(run)
		_run_panel.set_resources(run.gold, int(run.inventory_state.elixir))
		_run_panel.set_items(run.items)
	else:
		_run_panel.set_health(60, 100, 0, [])
		_run_panel.set_resources(0, 0)
		_run_panel.set_items([])
	# 典籍残片与战斗界面读同一个存档文件。
	var catalog := RelicCatalog.load_definitions()
	var board := RelicBoard.new()
	var current := SaveGateway.current_run()
	var error := OK
	if current != null:
		board = RunRewards.board_for_run(current)
	else:
		error = board.load_from_file(catalog, RelicBoard.SAVE_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("地图界面读取典籍配置失败：%d" % error)
	_run_panel.set_relic_board(catalog, board)
	_panel_signature = _run_panel_signature()


## 背包、血量、银币、万灵药会在拾取、事件、商店、战后结算里被别的流程直接改动，
## 面板只在开局与典籍变动时刷过，中途入包的东西看不到。按签名变化补刷，比每帧重建便宜。
func _sync_run_panel() -> void:
	if _run_panel == null or _run_panel_signature() == _panel_signature:
		return
	_refresh_run_panel()


func _run_panel_signature() -> String:
	if GlobalState == null or not GlobalState.run_active or GlobalState.current_run == null:
		return "idle"
	var run: RunStateMachine = GlobalState.current_run
	var ids := PackedStringArray()
	for item: Variant in run.items:
		ids.append(str((item as Dictionary).get("item_id", "")) if item is Dictionary else "")
	return "%d|%d|%d|%d|%s" % [run.health, run.max_health, run.gold,
		int(run.inventory_state.elixir), ",".join(ids)]


func _initial_snapshot() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_PATH))
	return data if data is Dictionary else {}

func _initial_state() -> Dictionary:
	return {}

func _register_input() -> void:
	var actions := {"map2d_left": [KEY_A, KEY_LEFT], "map2d_right": [KEY_D, KEY_RIGHT], "map2d_up": [KEY_W, KEY_UP], "map2d_down": [KEY_S, KEY_DOWN], "map2d_interact": [KEY_E], "map2d_pause": [KEY_ESCAPE], "map2d_cycle": [KEY_Q], "map2d_sprint": [KEY_SHIFT]}
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
	theme.default_font_size = 16
	root.theme = theme
	layer.add_child(root)
	# 与战斗界面同源的左上状态列：头像、血条、背包、典籍。
	_run_panel = RunPanel.new()
	_run_panel.name = "RunStatusPanel"
	root.add_child(_run_panel)
	_refresh_run_panel()
	_run_panel.menu_requested.connect(_open_run_menu)
	var bar_style := _bar_style()
	# 冒险菜单：点头像打开，地图页里放的是同一份地图数据的放大版。
	_run_menu = RunMenu.new()
	_run_menu.name = "RunMenuOverlay"
	root.add_child(_run_menu)
	_run_menu.closed.connect(_on_run_menu_closed)
	_run_menu.relic_board_updated.connect(_refresh_run_panel)
	# 地图信息与调试控件放右下角，与左下的操作提示同高、左右对称。
	var top := PanelContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	top.grow_vertical = Control.GROW_DIRECTION_BEGIN
	top.offset_left = -950
	top.offset_right = -18
	top.offset_top = -166
	top.offset_bottom = -18
	top.add_theme_stylebox_override("panel", bar_style)
	root.add_child(top)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	top.add_child(box)
	_info_column = box
	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 20)
	_header.add_theme_color_override("font_color", Color(0.910, 0.706, 0.333))
	box.add_child(_header)
	_seed_label = Label.new()
	_seed_label.add_theme_font_size_override("font_size", 16)
	_seed_label.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	box.add_child(_seed_label)
	var controls := HBoxContainer.new()
	box.add_child(controls)
	controls.add_child(_button("重开本图", _reset_map))
	var speed_row := HBoxContainer.new()
	box.add_child(speed_row)
	_speed_label = Label.new()
	_update_speed_label()
	_speed_label.custom_minimum_size.x = 120
	_speed_label.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	speed_row.add_child(_speed_label)
	var slider := HSlider.new()
	slider.min_value = 0.25
	slider.max_value = 4.0
	slider.step = 0.25
	slider.value = speed_multiplier
	slider.custom_minimum_size = Vector2(230, 24)
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(value): speed_multiplier = value; _update_speed_label())
	speed_row.add_child(slider)
	var mini_box := PanelContainer.new()
	mini_box.add_theme_stylebox_override("panel", CommonUiSkin.panel("small"))
	mini_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mini_box.offset_left = -320
	mini_box.offset_right = -18
	mini_box.offset_top = 18
	mini_box.offset_bottom = 288
	root.add_child(mini_box)
	var mini_column := VBoxContainer.new()
	mini_box.add_child(mini_column)
	_mini = MiniMap.new()
	_mini.custom_minimum_size = Vector2(294, 230)
	_mini.mouse_filter = Control.MOUSE_FILTER_STOP
	_mini.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_mini.tooltip_text = "点开查看地图"
	_mini.gui_input.connect(_on_minimap_input)
	_mini.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mini_column.add_child(_mini)
	var footer := PanelContainer.new()
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_left = 18
	footer.offset_right = -970
	footer.offset_top = -166
	footer.offset_bottom = -18
	footer.add_theme_stylebox_override("panel", bar_style)
	root.add_child(footer)
	var footer_box := VBoxContainer.new()
	footer_box.add_theme_constant_override("separation", 6)
	footer.add_child(footer_box)
	var row := HBoxContainer.new()
	footer_box.add_child(row)
	_prompt = Label.new()
	_prompt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt.add_theme_font_size_override("font_size", 20)
	_prompt.add_theme_color_override("font_color", Color(0.949, 0.890, 0.776))
	row.add_child(_prompt)
	var help := Label.new()
	help.text = "WASD / 方向键移动 · E 交互 · 滚轮缩放 · Q 切换目标 · Tab 背包 · M 地图 · Esc 设置"
	help.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	footer_box.add_child(help)
	var legend := Label.new()
	legend.text = "节点：战斗 · 商店 · 宝箱 · ? 未开启事件 · Boss · 事件开启后显示名称或专属图"
	legend.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	footer_box.add_child(legend)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	footer_box.add_child(_status)
	_dialog = ConfirmationDialog.new()
	CommonUiSkin.style_dialog(_dialog)
	_dialog.title = "节点接入演示"
	_dialog.ok_button_text = "模拟完成"
	_dialog.cancel_button_text = "取消并返回地图"
	_dialog.dialog_hide_on_ok = false
	_dialog.confirmed.connect(func(): _demo_result("completed"))
	_dialog.canceled.connect(func(): _demo_result("cancelled"))
	add_child(_dialog)

func _bar_style() -> StyleBox:
	return CommonUiSkin.panel("strip", Vector4(16, 10, 16, 10))


func _button(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color(0.949, 0.890, 0.776))
	button.add_theme_color_override("font_disabled_color", Color(0.749, 0.682, 0.553, 0.65))
	CommonUiSkin.style_button(button, Vector4(12, 4, 12, 4))
	button.pressed.connect(action)
	return button


## Public assembly API. On failure, neither the live map nor its state changes.
func load_map(snapshot: Dictionary, saved_state: Dictionary = {}) -> bool:
	var candidate = Session.new()
	if not candidate.load_map(snapshot) or (not saved_state.is_empty() and not candidate.restore_state(saved_state)):
		_show_toast("加载拒绝：" + candidate.last_error)
		return false
	if not _prepare_presentation(candidate):
		return false
	_cancel_fast_travel()
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
	_header.text = "第 %d 层" % session.floor_index
	_seed_label.text = "Seed %s" % session.seed.left(32)
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

## 局内换层由业务模块经总线请求，走黑场节拍而不是直接换。
func _on_map_load_requested(snapshot: Dictionary, saved_state: Dictionary = {}) -> void:
	load_map_with_beat(snapshot, saved_state)

## 原地重建地图的入场节拍：黑场淡出，淡出的那一拍再重建，最后淡入。
## 首层进入不走这里，那时候的淡入由场景转场遮罩负责，叠加会变成两次黑幕。
func load_map_with_beat(snapshot: Dictionary, saved_state: Dictionary = {}) -> void:
	if _entry_fade == null or not _entry_fade.play(func() -> void: load_map(snapshot, saved_state)):
		# 节拍占着或没有节拍节点时不能吞掉请求，直接重建。
		load_map(snapshot, saved_state)

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
	# 瞬移后的第一帧不该被当成走路，把尘点基准一并归位。
	_dust_last_position = _player.position
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
	_place_actor(_render_actor_plane)
	_camera.force_update_scroll()
	_update_minimap()

## 尘点跟着角色在显示空间里走，不吃物理帧插值，直接读当帧的 _player.position。
func _update_movement_cues(delta: float) -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_step_dust):
		return
	var at: Vector2 = _player.position
	var motion := at - _dust_last_position
	_dust_last_position = at
	if motion.length() > 48.0:
		motion = Vector2.ZERO
	_step_dust.update(at, motion, delta)

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
	_update_minimap()

func _update_minimap() -> void:
	if not is_inside_tree() or not is_instance_valid(_mini):
		return
	var half := get_viewport_rect().size / (_camera.zoom * cell_radius_px * 2.0)
	var window := Rect2(_render_actor_plane - half, half * 2)
	_mini.set_player(_render_actor_plane, window)
	if _menu_map != null and is_instance_valid(_menu_map):
		_menu_map.set_actor(_render_actor_plane)

func _physics_process(delta: float) -> void:
	if _fast_travel_busy: return
	var direction := Vector2.ZERO
	if not paused and session.pending.is_empty() and DisplayServer.window_is_focused():
		direction = _movement_direction()
	# 按住加速键就直接进满档，跳过连续行走的蓄力段；松手后回到原来的蓄力判定。
	_sprint_held = not direction.is_zero_approx() and Input.is_action_pressed("map2d_sprint")
	_advance_motion(direction, delta)

func _advance_motion(direction: Vector2, delta: float) -> void:
	var step_delta := clampf(delta, 0.0, 0.05)
	var stopping := direction.is_zero_approx()
	if stopping:
		_sprint_held = false
		_reset_walk_acceleration()
	var rate := WALK_STOP_ACCEL if stopping else WALK_START_ACCEL
	_velocity = _velocity.move_toward(direction * move_speed * _walking_speed_multiplier(), rate * step_delta)
	var before: Vector2 = session.actor_plane
	session.move_actor(_velocity * step_delta)
	# Count collision-resolved movement, including sliding and direction changes.
	# A fully blocked frame resets the bonus instead of charging it at a wall.
	if session.actor_plane != before:
		_blocked_seconds = 0.0
		if not stopping:
			_continuous_walk_seconds = minf(_continuous_walk_seconds + step_delta,
				WALK_ACCELERATION_DELAY + WALK_ACCELERATION_DURATION)
	else:
		_blocked_seconds = 0.0 if stopping else _blocked_seconds + step_delta
		# 擦墙一帧不算停下，顶着障碍持续过宽限期才清零加速进度。
		if stopping or _blocked_seconds >= WALK_BLOCKED_GRACE:
			_reset_walk_acceleration()
	_render_path.assign(session.motion_path)
	_render_path_length = 0.0
	for i in range(1, _render_path.size()):
		_render_path_length += _render_path[i - 1].distance_to(_render_path[i])
	_notify_actor_cell()

func _walking_speed_multiplier() -> float:
	if _sprint_held:
		return speed_multiplier * WALK_ACCELERATION_MAX
	var progress := clampf((_continuous_walk_seconds - WALK_ACCELERATION_DELAY)
		/ WALK_ACCELERATION_DURATION, 0.0, 1.0)
	return speed_multiplier * lerpf(1.0, WALK_ACCELERATION_MAX, progress)

func _reset_walk_acceleration() -> void:
	_continuous_walk_seconds = 0.0
	_update_speed_label()

func _update_speed_label() -> void:
	if not is_instance_valid(_speed_label):
		return
	var text := "移速 %.2f×（基础 %.2f×）" % [_walking_speed_multiplier(), speed_multiplier]
	if _speed_label.text != text:
		_speed_label.text = text

func _movement_direction() -> Vector2:
	if get_viewport().gui_get_focus_owner() != null:
		return Vector2.ZERO
	var keyboard := Input.get_vector("map2d_left", "map2d_right", "map2d_up", "map2d_down")
	if not keyboard.is_zero_approx():
		return _direction_to_plane(keyboard)
	if not _mouse_steering_held or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return Vector2.ZERO
	var cursor := _mouse_cursor
	if not get_viewport_rect().has_point(cursor) or get_viewport().gui_get_hovered_control() != null:
		return Vector2.ZERO
	# Camera stays centered: this is continuous steering, not a world-space
	# click destination. A small screen deadzone avoids jitter near the actor.
	var offset := cursor - get_viewport_rect().get_center()
	return _direction_to_plane(offset.normalized()) if offset.length() > 12.0 else Vector2.ZERO

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
		_target_marker.position = _plane_to_display(Hex.to_plane(point, 1.0))

func _process(delta: float) -> void:
	_render_motion(Engine.get_physics_interpolation_fraction())
	_update_movement_cues(delta)
	_toast_left = maxf(0, _toast_left - delta)
	_status_elapsed += delta
	_update_selection()
	if not session.pending.is_empty():
		_prompt.text = "正在处理节点；等待结果回传"
	elif paused:
		_prompt.text = "已暂停 · Esc 设置 · Tab 背包 · M 地图"
	elif _selected.is_empty():
		_prompt.text = "自由探索 · 灰雾只显示轮廓 · 橙色关口需完成本地战斗"
	else:
		var node: Dictionary = session.nodes[_selected]
		_prompt.text = "交互目标：%s  %s%s%s" % [_node_label(node), _selected, " · 路线关口" if node.is_route_gate else "", " · 可再次访问" if session.completed.has(_selected) else ""]
	if _status_elapsed >= 0.25:
		_status_elapsed = 0
		_update_speed_label()
		_status.text = "位置 (%d, %d) · 已完成 %d / %d · %.0f FPS%s" % [_last_cell.x, _last_cell.y, session.completed.size(), session.nodes.size(), Engine.get_frames_per_second(), " · " + _toast if _toast_left > 0 else ""]

func _input(event: InputEvent) -> void:
	if _fast_travel_busy:
		get_viewport().set_input_as_handled()
		return
	if _handle_menu_hotkeys(event):
		return
	# Use viewport-local event positions, including the first button press.
	# OS cursor polling can disagree with routed window events on macOS.
	if event is InputEventMouse:
		_mouse_cursor = event.position
	# Release must also reach us when a UI control consumes the event.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_mouse_steering_held = false

func _unhandled_input(event: InputEvent) -> void:
	if _fast_travel_busy:
		get_viewport().set_input_as_handled()
		return
	if _handle_menu_hotkeys(event):
		return
	if event.is_action_pressed("map2d_pause"):
		if session.pending.is_empty():
			_set_paused(not paused)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("map2d_interact") and not paused:
		_interact()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("map2d_cycle") and not paused:
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
	if what == NOTIFICATION_ENTER_TREE:
		_reset_walk_acceleration()
	# A node's modal temporarily takes focus from the root window. Pending
	# already blocks movement, so do not leave the map paused on its return.
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and is_inside_tree():
		_mouse_steering_held = false
		_reset_walk_acceleration()
		if session.pending.is_empty():
			_resume_after_focus = not paused
			_set_paused(true)
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN and is_inside_tree() and _resume_after_focus:
		_resume_after_focus = false
		if _run_menu == null or not _run_menu.is_open():
			_set_paused(false)

func _set_paused(value: bool) -> void:
	paused = value
	_mouse_steering_held = false
	_reset_walk_acceleration()
	if is_instance_valid(_player):
		_sync_actor(false)

func _interact() -> void:
	_update_selection()
	if paused or _selected.is_empty():
		return
	var request: Dictionary = session.request_node(_selected)
	if request.is_empty():
		return
	_mouse_steering_held = false
	_reset_walk_acceleration()
	if request.type == "event": _sync_view()
	_sync_actor(false)
	var active = session
	_emit_state()
	if session != active or session.pending.get("request_id") != request.request_id:
		return
	_bus.node_interaction_requested.emit(request.duplicate(true))
	# A synchronous external result may already have resolved this request.
	if demo_interactions_enabled and _uses_demo_dialog(request) and session == active and session.pending.get("request_id") == request.request_id:
		_dialog_request_id = request.request_id
		_configure_node_dialog(request)

func _node_label(node: Dictionary) -> String:
	if node.type == "event" and session.opened.has(node.id):
		return EventCatalog.display_name(str(node.get("event_kind", ""))) if EventCatalog.has_event(str(node.get("event_kind", ""))) else "事件"
	return LABELS.get(node.type, "节点")

func _configure_node_dialog(request: Dictionary) -> void:
	var presentation_only: bool = session.floor_index == 1 and (request.type in ["chest", "pile"] or (request.type == "event" and str(request.content_id).begins_with("alchemy/events/")))
	_dialog.get_ok_button().visible = not presentation_only
	_dialog.cancel_button_text = "返回地图" if presentation_only else "取消并返回地图"
	if presentation_only:
		_dialog.title = _node_label(session.nodes[request.node_id])
		_dialog.dialog_text = "已开启此事件，可以离开并稍后再次访问。\n本轮仅接入地图节点展示，事件选项与效果待后续接入。" if request.type == "event" else "%s节点已接入地图。\n节点奖励由正式游戏入口处理。" % LABELS.get(request.type, "战利品")
	else:
		_dialog.title = "路线关口 · 完成后开放后方" if request.is_route_gate else "节点接入演示"
		_dialog.dialog_text = "%s · %s\n\n这里只演示节点请求与结果回传。\n正式战斗、商店和事件由各自模块处理。\n%s" % [LABELS.get(request.type,"节点"), request.node_id, "完成本关口将揭开后方迷雾并允许通行；取消不解锁。" if request.is_route_gate else "此节点不是路线关口；完成不改变后方区域的可达性。"]
	_dialog.popup_centered(Vector2i(570, 255))

func _uses_demo_dialog(_request: Dictionary) -> bool:
	return true

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

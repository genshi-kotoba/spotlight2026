class_name UseDiscardMenu
extends Control

## 背包与场景快捷栏共用的物品选项菜单。贴着格子的一侧竖排按钮，靠格子那头留一个指向格子的小尖角。
## 行由调用方给：enabled=false 的行变暗且不响应，danger=true 的行用红字（丢弃）。
## 同一实例可以反复 show_for 到不同格子上；点面板外或按 Esc 收起。

signal closed

const ROW_WIDTH := 124.0
const ROW_HEIGHT := 30.0
const ROW_GAP := 3.0
const PAD := 6.0
const NOTCH_WIDTH := 14.0
const NOTCH_HEIGHT := 7.0
const ANCHOR_GAP := 3.0
const EDGE_MARGIN := 8.0
const FONT_SIZE := 16
const ACCENT := Color(0.909804, 0.705882, 0.333333, 0.9)
const DANGER_COLOR := Color(0.85, 0.34, 0.30)
const HOVER_BG := Color(0.35, 0.24, 0.16, 0.9)
const PRESSED_BG := Color(0.16, 0.11, 0.08, 0.95)

var _plate: PanelContainer
var _rows: VBoxContainer
var _notch: Polygon2D


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_plate = PanelContainer.new()
	_plate.name = "Plate"
	_plate.add_theme_stylebox_override("panel", CommonUiSkin.panel("tooltip", Vector4(PAD, PAD, PAD, PAD)))
	add_child(_plate)
	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.add_theme_constant_override("separation", int(ROW_GAP))
	_plate.add_child(_rows)
	_notch = Polygon2D.new()
	_notch.name = "Notch"
	_notch.color = ACCENT
	add_child(_notch)


func is_open() -> bool:
	return visible


## rows 每项：{"label": String, "enabled": bool, "danger": bool, "action": Callable}。
func show_for(anchor: Control, rows: Array) -> void:
	if not is_instance_valid(anchor) or rows.is_empty():
		return
	_build_rows(rows)
	visible = true
	_layout(anchor)
	# 容器延后排版，再用最新尺寸校准一次，避免沿用上一次的宽度。
	_layout.call_deferred(anchor)


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _has_point(point: Vector2) -> bool:
	return visible and is_instance_valid(_plate) and _plate.get_rect().has_point(point)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
		accept_event()


func _input(event: InputEvent) -> void:
	# 关闭菜单但不吃掉面板外的点击：仍可直接点典籍格装配已选中的残片。
	if visible and event is InputEventMouseButton and event.pressed \
			and not _plate.get_global_rect().has_point(event.position):
		close()
	# 菜单开着时 Esc 只收菜单，不把冒险菜单一起关掉。
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _build_rows(rows: Array) -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	var normal := _row_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0))
	var hover := _row_style(HOVER_BG, ACCENT)
	var pressed := _row_style(PRESSED_BG, ACCENT)
	var inactive := _row_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0))
	for row: Variant in rows:
		var data: Dictionary = row
		var button := Button.new()
		button.text = str(data.get("label", ""))
		button.custom_minimum_size = Vector2(ROW_WIDTH, ROW_HEIGHT)
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not bool(data.get("enabled", true))
		button.add_theme_font_override("font", CommonUiSkin.relic_font())
		button.add_theme_font_size_override("font_size", FONT_SIZE)
		var color := DANGER_COLOR if bool(data.get("danger", false)) else CommonUiSkin.TEXT
		for state: String in ["font_color", "font_hover_color", "font_pressed_color"]:
			button.add_theme_color_override(state, color)
		button.add_theme_stylebox_override("normal", normal)
		button.add_theme_stylebox_override("hover", hover)
		button.add_theme_stylebox_override("pressed", pressed)
		button.add_theme_stylebox_override("disabled", inactive)
		if not button.disabled:
			button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			CommonUiSkin.bind_press_feel(button)
			var action: Callable = data.get("action", Callable())
			button.pressed.connect(_choose.bind(action))
		_rows.add_child(button)


func _choose(action: Callable) -> void:
	# 先收起再执行：动作会重建格子，菜单不能留在一格已经不在的位置上。
	close()
	if action.is_valid():
		action.call()


func _row_style(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	if border.a > 0.0:
		style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	return style


## 贴着格子下沿弹出；下方放不下就翻到上沿，尖角始终指着格子。
func _layout(anchor: Control) -> void:
	if not visible or not is_instance_valid(anchor):
		return
	var plate_size := _plate.get_combined_minimum_size()
	_plate.size = plate_size
	var anchor_rect := anchor.get_global_rect()
	var view := get_viewport_rect().size
	var pointing_up := true
	var y := anchor_rect.end.y + NOTCH_HEIGHT + ANCHOR_GAP
	if y + plate_size.y > view.y - EDGE_MARGIN:
		pointing_up = false
		y = anchor_rect.position.y - NOTCH_HEIGHT - ANCHOR_GAP - plate_size.y
	var x := clampf(anchor_rect.get_center().x - plate_size.x * 0.5, EDGE_MARGIN,
		maxf(EDGE_MARGIN, view.x - EDGE_MARGIN - plate_size.x))
	_plate.global_position = Vector2(x, y)
	var edge_y := y if pointing_up else y + plate_size.y
	_set_notch(pointing_up, Vector2(x + plate_size.x * 0.5, edge_y))


func _set_notch(pointing_up: bool, edge: Vector2) -> void:
	var half := NOTCH_WIDTH * 0.5
	if pointing_up:
		_notch.polygon = PackedVector2Array(
			[Vector2(0.0, 0.0), Vector2(-half, NOTCH_HEIGHT), Vector2(half, NOTCH_HEIGHT)])
		_notch.position = edge - Vector2(0.0, NOTCH_HEIGHT)
	else:
		_notch.polygon = PackedVector2Array(
			[Vector2(0.0, NOTCH_HEIGHT), Vector2(-half, 0.0), Vector2(half, 0.0)])
		_notch.position = edge

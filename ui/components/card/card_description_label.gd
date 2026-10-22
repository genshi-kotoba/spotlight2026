@tool
class_name CardDescriptionLabel
extends Label
## 固定字号的完整描述。输入先由真实 GUI 命中，再在拖动期间捕获，避免穿透弹窗。
signal interaction_started

const DRAG_THRESHOLD := 6.0
var input_enabled := true
var _button: WeakRef
var _pressed_surface: WeakRef
var _press_position := Vector2.ZERO
var _press_local_y := 0.0
var _press_line := 0
var _dragged := false
var _capturing := false
var _click_armed := false
var _overflow_preview: Label

func _ready() -> void:
	set_process_input(false)
	# Label 只绘制完整行；另用完整高度的子标签，让正文框裁出下一行的上沿。
	_overflow_preview = Label.new()
	_overflow_preview.name = "OverflowPreview"
	_overflow_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overflow_preview.clip_text = true
	_overflow_preview.max_lines_visible = 1
	add_child(_overflow_preview, false, Node.INTERNAL_MODE_BACK)
	resized.connect(_sync_overflow_preview)
	theme_changed.connect(_sync_overflow_preview)
	visibility_changed.connect(_on_visibility_changed)
	if not Engine.is_editor_hint():
		get_window().focus_exited.connect(cancel_interaction)
	_refresh_input()
	_sync_overflow_preview()

func set_content(full_text: String, visible_lines: int) -> void:
	text = full_text
	max_lines_visible = maxi(1, visible_lines)
	lines_skipped = clampi(lines_skipped, 0, maximum_scroll())
	vertical_alignment = VERTICAL_ALIGNMENT_TOP if maximum_scroll() > 0 else VERTICAL_ALIGNMENT_CENTER
	_refresh_input()
	_sync_overflow_preview()
	queue_redraw()

func maximum_scroll() -> int:
	return maxi(0, text.split("\n").size() - maxi(1, max_lines_visible))

func reset_scroll() -> void:
	cancel_interaction()
	lines_skipped = 0
	_sync_overflow_preview()
	queue_redraw()

func set_input_enabled(enabled: bool) -> void:
	input_enabled = enabled
	if not enabled: cancel_interaction()
	_refresh_input()

func bind_button(button: Button) -> void:
	var old := _interaction_button()
	if is_instance_valid(old) and old.gui_input.is_connected(_on_button_gui_input):
		old.gui_input.disconnect(_on_button_gui_input)
	_button = weakref(button) if button != null else null
	if button != null and not Engine.is_editor_hint():
		button.gui_input.connect(_on_button_gui_input)

func _interaction_button() -> Button:
	return _button.get_ref() as Button if _button != null else null

func _refresh_input() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if input_enabled and maximum_scroll() > 0 and not Engine.is_editor_hint() else Control.MOUSE_FILTER_IGNORE
	if maximum_scroll() == 0: cancel_interaction()

func _gui_input(event: InputEvent) -> void:
	_description_input(event, self)

func _on_button_gui_input(event: InputEvent) -> void:
	var button := _interaction_button()
	if is_instance_valid(button): _description_input(event, button)

func _description_input(event: InputEvent, surface: Control) -> void:
	if not input_enabled or maximum_scroll() == 0 or not is_visible_in_tree() or not event is InputEventMouseButton:
		return
	var point: Vector2 = surface.get_global_transform_with_canvas() * event.position
	var local_point: Vector2 = get_global_transform_with_canvas().affine_inverse() * point
	if not Rect2(Vector2.ZERO, size).has_point(local_point): return
	if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if event.pressed:
			var direction := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			_scroll_to(lines_skipped + direction * maxi(1, roundi(event.factor)))
		surface.accept_event()
	elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var button := _interaction_button()
		_click_armed = is_instance_valid(button) and not button.disabled and button.mouse_filter != Control.MOUSE_FILTER_IGNORE
		_pressed_surface = weakref(surface)
		_press_position = point
		_press_local_y = local_point.y
		_press_line = lines_skipped
		_dragged = false
		_capturing = true
		set_process_input(true)
		# 战斗的 _input 早于 GUI；让调用方清除它刚记录的拖牌候选。
		interaction_started.emit()
		surface.accept_event()

func _input(event: InputEvent) -> void:
	if not _capturing: return
	if not is_visible_in_tree() or not input_enabled:
		cancel_interaction()
		return
	if event is InputEventMouseMotion:
		if event.position.distance_to(_press_position) >= DRAG_THRESHOLD: _dragged = true
		if _dragged:
			var local_point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
			var height := get_theme_font("font").get_height(get_theme_font_size("font_size")) + get_theme_constant("line_spacing")
			_scroll_to(_press_line + roundi((_press_local_y - local_point.y) / maxf(1.0, height)))
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if event.position.distance_to(_press_position) >= DRAG_THRESHOLD: _dragged = true
		var button := _interaction_button()
		var surface := _pressed_surface.get_ref() as Control if _pressed_surface != null else null
		var hovered := get_viewport().gui_get_hovered_control()
		var can_click := _click_armed and not _dragged and is_instance_valid(surface) and surface.is_visible_in_tree() and not surface.is_queued_for_deletion() and surface.mouse_filter != Control.MOUSE_FILTER_IGNORE
		can_click = can_click and is_instance_valid(hovered) and (hovered == surface or surface.is_ancestor_of(hovered))
		can_click = can_click and is_instance_valid(button) and button.is_visible_in_tree() and not button.is_queued_for_deletion() and not button.disabled
		if can_click:
			var point: Vector2 = button.get_global_transform_with_canvas().affine_inverse() * event.position
			can_click = Rect2(Vector2.ZERO, button.size).has_point(point)
		cancel_interaction()
		get_viewport().set_input_as_handled()
		# 原按下事件已在 GUI 阶段消费，普通短点只转发一次原按钮行为。
		if can_click: button.pressed.emit()

func _scroll_to(line: int) -> void:
	lines_skipped = clampi(line, 0, maximum_scroll())
	_sync_overflow_preview()
	queue_redraw()

func _sync_overflow_preview() -> void:
	if not is_instance_valid(_overflow_preview): return
	_overflow_preview.visible = lines_skipped < maximum_scroll()
	if not _overflow_preview.visible: return
	var rows := text.split("\n")
	var next_row := lines_skipped + max_lines_visible
	_overflow_preview.text = rows[next_row]
	_overflow_preview.horizontal_alignment = horizontal_alignment
	_overflow_preview.label_settings = label_settings
	_overflow_preview.add_theme_font_override("font", get_theme_font("font"))
	_overflow_preview.add_theme_font_size_override("font_size", get_theme_font_size("font_size"))
	for color: StringName in [&"font_color", &"font_outline_color", &"font_shadow_color"]:
		_overflow_preview.add_theme_color_override(color, get_theme_color(color))
	for constant: StringName in [&"outline_size", &"shadow_offset_x", &"shadow_offset_y", &"shadow_outline_size", &"line_spacing", &"paragraph_spacing"]:
		_overflow_preview.add_theme_constant_override(constant, get_theme_constant(constant))
	# 先强制完成排版，再取实际字体回退后的行高。
	get_line_count()
	var y := 0.0
	for row in range(lines_skipped, next_row):
		y += get_line_height(row) + get_theme_constant("line_spacing") + get_theme_constant("paragraph_spacing")
	_overflow_preview.position = Vector2(0, y)
	_overflow_preview.size = Vector2(size.x, maxf(1.0, get_line_height(next_row)))

func cancel_interaction() -> void:
	_capturing = false
	_click_armed = false
	_pressed_surface = null
	set_process_input(false)

func _on_visibility_changed() -> void:
	if not is_visible_in_tree(): cancel_interaction()

func _exit_tree() -> void:
	cancel_interaction()

func _draw() -> void:
	if maximum_scroll() <= 0: return
	# 细轨道表明还有正文；它位于排版预留的右侧安全边距内。
	var track := Rect2(Vector2(size.x - 4.0, 4.0), Vector2(3.0, maxf(1.0, size.y - 8.0)))
	draw_rect(track, Color(0.95, 0.85, 0.6, 0.22))
	var total := maxi(1, text.split("\n").size())
	var thumb_height := maxf(12.0, track.size.y * max_lines_visible / total)
	var thumb_y := track.position.y + (track.size.y - thumb_height) * lines_skipped / maximum_scroll()
	draw_rect(Rect2(Vector2(track.position.x, thumb_y), Vector2(track.size.x, thumb_height)), Color(0.95, 0.85, 0.6, 0.85))

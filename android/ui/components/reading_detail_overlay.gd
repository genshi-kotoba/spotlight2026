class_name ReadingDetailOverlay
extends CanvasLayer
## 共享的持续阅读层。只发出动作意图，宿主继续负责校验、消费与保存。
signal action_requested(token: String)
signal closed
const CONTEXTS := ["shop", "reward", "backpack"]
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const EDGE := 24.0
static var _instances: Dictionary = {}
var _owner: WeakRef
var _owner_id := 0
var _data: CardData
var _card: Dictionary
var _action: Dictionary
var _root: Control
var _surface: VBoxContainer
var _reader: CardReadingPanel
var _action_button: Button
var _close_button: Button
var _closing := false
var _action_armed := false
var _opening_frame := 0
var _wait_open_release := false

static func open_card(owner: Node, data: CardData, card: Dictionary = {}, context: String = "backpack", action: Dictionary = {}) -> ReadingDetailOverlay:
	if not is_instance_valid(owner) or not owner.is_inside_tree() or data == null or context not in CONTEXTS:
		return null
	close_for(owner)
	var detail := ReadingDetailOverlay.new()
	detail._owner = weakref(owner)
	detail._owner_id = owner.get_instance_id()
	detail._data = data
	detail._card = card.duplicate(true)
	detail._action = action.duplicate(true)
	_instances[owner.get_instance_id()] = weakref(detail)
	owner.add_child(detail)
	return detail

static func close_for(owner: Node) -> void:
	if not is_instance_valid(owner): return
	var reference: Variant = _instances.get(owner.get_instance_id())
	var detail: ReadingDetailOverlay = reference.get_ref() if reference is WeakRef else null
	if is_instance_valid(detail): detail.close("owner")

static func is_open_for(owner: Node) -> bool:
	if not is_instance_valid(owner): return false
	var reference: Variant = _instances.get(owner.get_instance_id())
	var detail: ReadingDetailOverlay = reference.get_ref() if reference is WeakRef else null
	return is_instance_valid(detail) and not detail._closing and detail.visible

## 宿主的安全区可挂在自己或祖先的 reading_safe_rect 元数据中，单位为视口坐标。
static func safe_rect_for(node: Node) -> Rect2:
	var bounds := node.get_viewport().get_visible_rect()
	if OS.has_feature("android"):
		var safe := Rect2(DisplayServer.get_display_safe_area())
		var screen := Vector2(DisplayServer.screen_get_size())
		if screen.x > 0 and screen.y > 0 and safe.has_area():
			bounds = bounds.intersection(Rect2(safe.position / screen * bounds.size, safe.size / screen * bounds.size))
	var current := node
	while is_instance_valid(current):
		var supplied: Variant = current.get_meta("reading_safe_rect") if current.has_meta("reading_safe_rect") else null
		if supplied is Rect2 and supplied.has_area(): return bounds.intersection(supplied)
		current = current.get_parent()
	return bounds

func _ready() -> void:
	layer = 1100
	for tip: Node in get_tree().get_nodes_in_group("pinned_reading_tip"):
		if tip.has_method("hide_tip"): tip.hide_tip(true)
	_opening_frame = Engine.get_process_frames()
	var bridge := get_node_or_null("/root/MobileInput")
	_wait_open_release = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or (bridge != null and bridge.has_method("is_holding_for_reading") and bridge.is_holding_for_reading())
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.015, 0.012, 0.008, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(_on_shade_input)
	_root.add_child(shade)
	_surface = VBoxContainer.new()
	_surface.add_theme_constant_override("separation", 12)
	_surface.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_surface)
	_reader = CardReadingPanel.new()
	_reader.name = "Reader"
	_surface.add_child(_reader)
	# 从现有卡面唯一渲染入口取展示文本，包含 CSV 与副本变体，不复制文案规则。
	var view: CardView = CARD_SCENE.instantiate()
	view.hide()
	view.set_description_interactive(false)
	add_child(view)
	view.set_card(_data)
	view.set_enchantments(_card)
	var reading := view.reading_text()
	_reader.set_card_text(reading.title, reading.effect, CardReadingPanel.enchantment_text(_card))
	view.free()
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 16)
	_surface.add_child(actions)
	_action_button = _button(str(_action.get("text", "")))
	_action_button.name = "ConfirmReadingAction"
	_action_button.visible = not _action_button.text.is_empty()
	_action_button.disabled = not bool(_action.get("enabled", true))
	_action_button.gui_input.connect(_on_action_input)
	_action_button.pressed.connect(_on_action_pressed)
	actions.add_child(_action_button)
	_close_button = _button("关闭")
	_close_button.name = "CloseReadingDetail"
	_close_button.pressed.connect(close.bind("button"))
	actions.add_child(_close_button)
	ReadingSettings.connect_changed(_layout)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_layout.call_deferred()

func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	CommonUiSkin.style_button(button)
	button.custom_minimum_size = Vector2(160, 64)
	return button

func _layout() -> void:
	if _closing or _reader == null: return
	var owner := _owner.get_ref() as Node
	if not is_instance_valid(owner): return
	var bounds := safe_rect_for(owner).grow(-EDGE)
	_reader.fit_within(Rect2(bounds.position, Vector2(bounds.size.x, maxf(1, bounds.size.y - 88))))
	for button: Button in [_action_button, _close_button]:
		button.add_theme_font_size_override("font_size", ReadingSettings.body_size())
	_surface.custom_minimum_size = Vector2(_reader.size.x, 0)
	_surface.size = _surface.get_combined_minimum_size()
	_surface.position = bounds.position + (bounds.size - _surface.size) * 0.5

func _process(_delta: float) -> void:
	var owner := _owner.get_ref() as Node if _owner != null else null
	if not is_instance_valid(owner) or not owner.is_inside_tree() or owner.is_queued_for_deletion():
		close("owner_gone")
		return
	var current: Node = owner
	while is_instance_valid(current):
		if (current is CanvasItem and not current.is_visible_in_tree()) or (current is CanvasLayer and not current.visible):
			close("owner_hidden")
			return
		current = current.get_parent()
	if _wait_open_release:
		var bridge := get_node_or_null("/root/MobileInput")
		_wait_open_release = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or (bridge != null and bridge.has_method("is_holding_for_reading") and bridge.is_holding_for_reading())

func _input(event: InputEvent) -> void:
	if _closing: return
	# 隔离宿主快捷键及旧焦点的导航输入；鼠标 GUI 和 MobileInput 的原始触摸仍按原路径走。
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventAction:
		get_viewport().set_input_as_handled()
		if event.is_action_pressed("ui_cancel"): close("cancel")
		return
	if event is InputEventMouseButton and event.pressed: _action_armed = false

func _on_action_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_action_armed = not _wait_open_release and Engine.get_process_frames() > _opening_frame

func _on_action_pressed() -> void:
	if _closing or not _action_armed or _action_button.disabled: return
	_action_armed = false
	action_requested.emit(str(_action.get("token", "")))

func _on_shade_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_root.accept_event()
		if event.pressed and not _wait_open_release and Engine.get_process_frames() > _opening_frame:
			close("outside")

func close(_reason: String = "") -> void:
	if _closing: return
	_closing = true
	_action_armed = false
	if _reader != null: _reader.body.cancel_interaction()
	var bridge := get_node_or_null("/root/MobileInput") if is_inside_tree() else null
	if bridge != null and bridge.has_method("cancel_active_gesture"): bridge.cancel_active_gesture()
	_forget_owner()
	visible = false
	closed.emit()
	queue_free()

func _forget_owner() -> void:
	var reference: Variant = _instances.get(_owner_id)
	if reference is WeakRef and reference.get_ref() == self: _instances.erase(_owner_id)

func _exit_tree() -> void:
	ReadingSettings.disconnect_changed(_layout)
	_forget_owner()
	if not _closing:
		_closing = true
		var bridge := get_node_or_null("/root/MobileInput")
		if bridge != null and bridge.has_method("cancel_active_gesture"): bridge.cancel_active_gesture()
		closed.emit()

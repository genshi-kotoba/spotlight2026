class_name HoverTip
extends PanelContainer
## 鼠标悬停与触屏固定说明共用同一份文字与排版。
const FONT_SIZE := 22
const MIN_WIDTH := 360.0
const VIEW_MARGIN := 16.0
const CONTACT_RADIUS := 96.0
var _anchor_rect := Rect2()
var _anchor: WeakRef
var _context: WeakRef
var _pinned := false
var _contact := Vector2.INF
var _label: RichTextLabel
var _close_button: Button
var _source_text := ""
var _rich := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_label = RichTextLabel.new()
	_label.name = "TipLabel" # 保留既有宿主读取该节点的接口。
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.threaded = false
	_label.focus_mode = Control.FOCUS_NONE
	_label.add_theme_color_override("default_color", CommonUiSkin.TEXT)
	add_child(_label)
	_close_button = Button.new()
	_close_button.name = "ClosePinnedTip"
	_close_button.text = "关闭"
	_close_button.set_as_top_level(true)
	_close_button.focus_mode = Control.FOCUS_NONE
	CommonUiSkin.style_button(_close_button)
	_close_button.pressed.connect(hide_tip.bind(true))
	add_child(_close_button)
	get_viewport().size_changed.connect(_layout_tip)
	ReadingSettings.connect_changed(_reading_size_changed)
	_reading_size_changed()

func _exit_tree() -> void:
	ReadingSettings.disconnect_changed(_reading_size_changed)

func _reading_size_changed() -> void:
	if _label == null: return
	CommonUiSkin.setup_relic_text(_label, ReadingSettings.body_size())
	_close_button.add_theme_font_size_override("font_size", ReadingSettings.body_size())
	_update_text()
	_layout_tip()

func show_for(anchor: Control, text: String, rich: bool = false) -> void:
	if not is_instance_valid(anchor) or _pinned: return
	_anchor = weakref(anchor)
	_show(anchor.get_global_rect(), text, rich)

func show_at_rect(rect: Rect2, text: String, rich: bool = false) -> void:
	if _pinned: return
	var hovered := get_viewport().gui_get_hovered_control()
	_anchor = weakref(hovered) if is_instance_valid(hovered) else null
	_show(rect, text, rich)

func _show(rect: Rect2, text: String, rich: bool) -> void:
	if _label == null: return
	_context = weakref(get_parent())
	_source_text = text
	_rich = rich
	_anchor_rect = rect
	var bridge := get_node_or_null("/root/MobileInput")
	if bridge != null and bridge.has_method("is_holding_for_reading") and bridge.is_holding_for_reading():
		_pinned = true
		_contact = bridge.touch_position()
		add_to_group("pinned_reading_tip")
	_update_text()
	visible = true
	_layout_tip()
	_layout_tip.call_deferred()

## 非触摸调用方也能明确固定；不会把固定说明转成物品操作。
func pin_for(anchor: Control, text: String, rich: bool = false, contact: Vector2 = Vector2.INF) -> void:
	hide_tip(true)
	show_for(anchor, text, rich)
	_pinned = true
	_contact = contact
	add_to_group("pinned_reading_tip")
	_layout_tip()

func is_pinned() -> bool:
	return _pinned and visible

func _update_text() -> void:
	_label.bbcode_enabled = _rich
	var text := _source_text
	if _rich:
		var sizes := RegEx.new()
		sizes.compile("\\[font_size=[0-9]+\\]")
		text = sizes.sub(text, "[font_size=%d]" % (ReadingSettings.body_size() + 6), true)
	_label.text = text

func _layout_tip() -> void:
	if not visible or _label == null: return
	var view := ReadingDetailOverlay.safe_rect_for(self).grow(-VIEW_MARGIN)
	var pixels := ReadingSettings.body_size()
	var width := MIN_WIDTH if pixels == 22 else maxf(MIN_WIDTH, 600.0 * pixels / 32.0)
	var pad := Vector4(16, 84 if _pinned else 16, 16, 16)
	add_theme_stylebox_override("panel", CommonUiSkin.panel("tooltip", pad))
	var padding := get_theme_stylebox("panel").get_minimum_size()
	width = minf(width, maxf(1, view.size.x - padding.x))
	_label.custom_minimum_size = Vector2(width, 0)
	_label.size = Vector2(width, maxf(1, _label.size.y))
	var height := minf(float(_label.get_content_height()), maxf(1, view.size.y - padding.y))
	_label.custom_minimum_size = Vector2(width, height)
	_label.scroll_active = _pinned
	_label.mouse_filter = Control.MOUSE_FILTER_STOP if _pinned else Control.MOUSE_FILTER_IGNORE
	mouse_filter = Control.MOUSE_FILTER_STOP if _pinned else Control.MOUSE_FILTER_IGNORE
	size = Vector2(width, height) + padding
	var position := Vector2(_anchor_rect.position.x, _anchor_rect.end.y + 12)
	if position.y + size.y > view.end.y: position.y = _anchor_rect.position.y - size.y - 12
	if _pinned and _contact.is_finite():
		var avoid := Rect2(_contact - Vector2.ONE * CONTACT_RADIUS, Vector2.ONE * CONTACT_RADIUS * 2)
		var candidates := [Vector2(_contact.x - size.x * 0.5, avoid.position.y - size.y),
			Vector2(avoid.end.x, _contact.y - size.y * 0.5),
			Vector2(avoid.position.x - size.x, _contact.y - size.y * 0.5),
			Vector2(_contact.x - size.x * 0.5, avoid.end.y)]
		for candidate: Vector2 in candidates:
			var clamped := _clamped_position(candidate, view)
			if not Rect2(clamped, size).intersects(avoid):
				position = clamped
				break
	global_position = _clamped_position(position, view)
	_close_button.visible = _pinned
	_close_button.size = Vector2(124, 64)
	_close_button.global_position = global_position + Vector2(size.x - 140, 10)
	_sync_close_layer()

func _sync_close_layer() -> void:
	# 关闭按钮以 top_level 避开 PanelContainer 排版，绘制层级也必须显式带上祖先的 Z。
	var effective_z := z_index
	var item: CanvasItem = self
	while item.z_as_relative and not item.is_set_as_top_level():
		item = item.get_parent() as CanvasItem
		if item == null: break
		effective_z += item.z_index
	_close_button.z_as_relative = false
	_close_button.z_index = clampi(effective_z + 1, RenderingServer.CANVAS_ITEM_Z_MIN, RenderingServer.CANVAS_ITEM_Z_MAX)

func _clamped_position(point: Vector2, view: Rect2) -> Vector2:
	return Vector2(clampf(point.x, view.position.x, maxf(view.position.x, view.end.x - size.x)),
		clampf(point.y, view.position.y, maxf(view.position.y, view.end.y - size.y)))

func _process(_delta: float) -> void:
	if not visible: return
	if _pinned: _sync_close_layer()
	var context := _context.get_ref() as Node if _context != null else null
	var anchor := _anchor.get_ref() as Control if _anchor != null else null
	if not is_instance_valid(context) or not context.is_inside_tree() or context.is_queued_for_deletion():
		hide_tip(true)
	elif _anchor != null and (not is_instance_valid(anchor) or not anchor.is_visible_in_tree() or anchor.is_queued_for_deletion()):
		hide_tip(true)
	elif context is CanvasItem and not context.is_visible_in_tree():
		hide_tip(true)
	elif context is CanvasLayer and not context.visible:
		hide_tip(true)

func _input(event: InputEvent) -> void:
	if not is_pinned(): return
	if event.is_action_pressed("ui_cancel"):
		hide_tip(true)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not get_global_rect().has_point(event.position):
		hide_tip(true)
		get_viewport().set_input_as_handled()

## 输入桥在新手指按下时调用；关闭和该手势都被消费，不能穿透去用物品。
func consume_outside_touch(at: Vector2) -> bool:
	if not is_pinned() or get_global_rect().has_point(at): return false
	hide_tip(true)
	return true

func hide_tip(force: bool = false) -> void:
	if _pinned and not force: return
	_pinned = false
	visible = false
	if is_in_group("pinned_reading_tip"): remove_from_group("pinned_reading_tip")
	if _close_button != null: _close_button.hide()
	if _label != null: _label.get_v_scroll_bar().value = 0

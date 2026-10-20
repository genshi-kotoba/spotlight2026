extends CanvasLayer
## Presentation adapter for the existing reward-choice fan. No run mutation.
signal selected(index: int)
signal cancelled
const Upgrade = preload("res://systems/events/material_upgrade_event.gd")

class UpgradeFan:
	extends "res://ui/rewards/reward_choice_fan.gd"
	const MaterialUpgrade = preload("res://systems/events/material_upgrade_event.gd")
	const POTION_ART := ["蓝药剂.png", "绿药剂.png", "紫药剂.png", "黄药剂.png"]
	var _offers_by_id: Dictionary = {}

	func configure_offers(offers: Array) -> void:
		var ids: Array[String] = []
		for offer: Dictionary in offers:
			ids.append(str(offer.id))
			_offers_by_id[str(offer.id)] = offer.duplicate(true)
		# Reuse the fragment-sized presentation and the existing fan interaction.
		configure(ids, true)

	func _build_fragment(item: Control, id: String) -> void:
		var offer: Dictionary = _offers_by_id[id]
		if offer.kind == "fragment":
			super._build_fragment(item, str(offer.fragment_id))
			return
		var panel := Panel.new()
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel", Vector4(16, 16, 16, 16)))
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.add_child(panel)
		var potion := int(offer.potion)
		var art := ItemIcon.make("res://assets/ui/UI-022/" + str(POTION_ART[potion]), 180.0)
		art.position = Vector2(75, 18)
		item.add_child(art)
		var detail := RichTextLabel.new()
		CommonUiSkin.setup_relic_text(detail, 23)
		detail.position = Vector2(20, 215)
		detail.size = Vector2(290, 235)
		detail.text = "药水\n\n" + str(MaterialUpgrade.POTION_NAMES[potion]) + "\n\n战斗中使用一次"
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.scroll_active = false
		detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.add_child(detail)

	func set_locked(locked: bool) -> void:
		_set_hits(not locked and is_settled())


var _offers: Array = []
var _source_label := ""
var _root: Control
var _fan: UpgradeFan
var _title: Label
var _hint: Label
var _error: Label
var _confirm: Button
var _back: Button
var _selected_index := -1
var _submitted := false


func _ready() -> void:
	layer = 100
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	CatalogUi.install_theme(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.78)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_title = _label("素材升级 · 三选一", 32)
	_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_title.offset_top = 70
	_title.offset_bottom = 120
	_root.add_child(_title)
	_hint = _label("点击选择 · 悬停放大 · 确认升级后才消耗素材", 20)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_hint.offset_top = 124
	_hint.offset_bottom = 160
	_root.add_child(_hint)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 20)
	actions.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	actions.anchor_top = 0.84
	actions.anchor_bottom = 0.84
	actions.offset_left = -370
	actions.offset_right = 370
	actions.offset_top = 0
	actions.offset_bottom = 64
	_root.add_child(actions)
	_back = _button("取消升级")
	_back.pressed.connect(_cancel)
	actions.add_child(_back)
	_confirm = _button("确认升级")
	_confirm.disabled = true
	_confirm.pressed.connect(_submit)
	actions.add_child(_confirm)
	_error = _label("", 18)
	_error.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_error.offset_top = -100
	_error.offset_bottom = -50
	_error.add_theme_color_override("font_color", Color("ffad94"))
	_root.add_child(_error)
	_render()


func configure(offers: Array, source_label: String = "") -> void:
	_offers = offers.duplicate(true)
	_source_label = source_label
	if is_node_ready():
		_render()


func show_error(message: String) -> void:
	_submitted = false
	_error.text = message
	_confirm.disabled = _selected_index < 0
	_back.disabled = false
	if is_instance_valid(_fan):
		_fan.set_locked(false)


func _render() -> void:
	if _offers.is_empty():
		return
	_selected_index = -1
	_submitted = false
	_confirm.disabled = true
	_back.disabled = false
	_error.text = ""
	if is_instance_valid(_fan):
		_root.remove_child(_fan)
		_fan.queue_free()
	if not Upgrade.valid_offers(_offers) or _offers.size() != 3:
		_error.text = "升级候选不可用，请返回重新选择素材。"
		return
	_title.text = "素材升级 · 三选一"
	_hint.text = "点击选择 · 悬停放大 · 确认升级后才消耗素材"
	if not _source_label.is_empty():
		_hint.text = _source_label.get_slice("\n", 0) + " · 确认后消耗"
	_fan = UpgradeFan.new()
	_fan.name = "MaterialUpgradeFan"
	_fan.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fan.offset_top = 165
	_fan.offset_bottom = -215
	_fan.chosen.connect(_choose)
	_root.add_child(_fan)
	_fan.configure_offers(_offers)


func _choose(id: String) -> void:
	if _submitted:
		return
	for index in _offers.size():
		if _offers[index].id == id:
			_selected_index = index
			_hint.text = "已选择：" + Upgrade.label(_offers[index]) + " · 点击确认升级"
			_confirm.disabled = false
			return


func _submit() -> void:
	if _submitted or _selected_index < 0 or _selected_index >= _offers.size():
		return
	_submitted = true
	_confirm.disabled = true
	_back.disabled = true
	_fan.set_locked(true)
	selected.emit(_selected_index)


func _cancel() -> void:
	if not _submitted:
		cancelled.emit()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("ui_cancel"):
			_cancel()
		get_viewport().set_input_as_handled()


func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(230, 60)
	CommonUiSkin.style_button(button)
	return button

class_name NodeLootPopup
extends CanvasLayer
## 薄 UI：物资和完成状态统一交给 RunNodeLoot，关闭也必须经过事务。
signal finished
signal claimed(request: Dictionary)
var request: Dictionary = {}
var _run: RunStateMachine
var _description: RichTextLabel
var _heading: Label
var _image: TextureRect
var _status: Label
var _claim_button: Button
var _close_button: Button
var _working := false
var _claimed := false
var close_handler: Callable

func _ready() -> void:
	layer = 100
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.75)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(shade)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -430; panel.offset_right = 430
	panel.offset_top = -300; panel.offset_bottom = 300
	panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel", Vector4(42, 32, 42, 32)))
	root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 22)
	panel.add_child(column)
	_heading = _label("", 34)
	column.add_child(_heading)
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.custom_minimum_size = Vector2(0, 120)
	column.add_child(_image)
	_description = RichTextLabel.new()
	CommonUiSkin.setup_relic_text(_description, 26)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.custom_minimum_size.y = 140
	_description.add_theme_color_override("default_color", CommonUiSkin.TEXT)
	_description.focus_mode = Control.FOCUS_NONE
	_description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_description)
	_status = _label("", 19)
	column.add_child(_status)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 24)
	column.add_child(row)
	_close_button = _button("稍后领取", "LaterNodeLoot")
	_close_button.pressed.connect(_close)
	row.add_child(_close_button)
	_claim_button = _button("领取", "ClaimNodeLoot")
	_claim_button.pressed.connect(_claim)
	row.add_child(_claim_button)

func show_loot(pending: Dictionary) -> void:
	_run = SaveGateway.current_run()
	request = pending.duplicate(true)
	_heading.text = "发现残堆" if request.get("type") == "pile" else "发现宝箱"
	_image.texture = load("res://assets/map_nodes/alchemy/%s.png" % str(request.type))
	_ensure_offer()

func _ensure_offer() -> void:
	var error := RunNodeLoot.open(_run, request)
	_status.text = "可以稍后再来领取。" if error == OK else "开启未保存，请重试或返回地图（%d）。" % error
	_render()

func _render() -> void:
	var loot := RunNodeLoot.record(_run, request)
	_claim_button.text = "重试开启" if loot.is_empty() else ("已领取" if _claimed else "领取")
	_claim_button.disabled = _claimed
	_close_button.text = "继续探索" if _claimed else "稍后领取"
	_set_description("正在确认箱中物品……")
	var descriptions: Array[String] = []
	for entry: Dictionary in loot.get("entries", []):
		if entry.kind == "elixir": descriptions.append("万灵药 × %d" % int(entry.amount))
		elif entry.kind == "silver": descriptions.append("银币 × %d" % int(entry.amount))
		elif entry.kind == "potion": descriptions.append("药水 × 1\n%s" % RunRandomEvents.POTIONS[int(entry.potion)])
		else:
			var fragment: RelicFragmentData = RelicCatalog.resolve(str(entry.fragment_id))
			if fragment != null:
				descriptions.append("典籍残片\n" + fragment.rich_text(32))
			else:
				descriptions.append("典籍残片（描述暂不可用）")
	_set_description("\n\n".join(descriptions), true)

func _set_description(text: String, rich: bool = false) -> void:
	_description.bbcode_enabled = rich
	_description.text = text

func _claim() -> void:
	if _working or _claimed: return
	_working = true
	if RunNodeLoot.record(_run, request).is_empty():
		_ensure_offer(); _working = false; return
	var completed_request := request.duplicate(true)
	var error := RunNodeLoot.claim(_run, request)
	_working = false
	if error == OK:
		_claimed = true
		_status.text = "已领取并保存。"
		claimed.emit(completed_request)
	else:
		_refresh_request()
		_status.text = "领取未保存，物品未发放，可重试（%d）。" % error
	_render()

func _refresh_request() -> void:
	var session: RefCounted = EncounterFlow.session
	if session != null and session.pending.get("map_id") == request.get("map_id") and session.pending.get("node_id") == request.get("node_id"):
		request = session.pending.duplicate(true)

func _close() -> void:
	if _working: return
	_working = true
	var error: Error = OK if _claimed else close_handler.call(request) if close_handler.is_valid() else ERR_UNCONFIGURED
	_working = false
	if error != OK:
		_refresh_request()
		_status.text = "关闭未保存，请重试（%d）。" % error
		return
	set_process_input(false)
	finished.emit()
	queue_free()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("ui_cancel"): _close()
		get_viewport().set_input_as_handled()

func _label(text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", CommonUiSkin.TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _button(text: String, id: String) -> Button:
	var button := Button.new()
	button.name = id; button.text = text
	button.custom_minimum_size = Vector2(240, 60)
	CommonUiSkin.style_button(button)
	return button

class_name LootPopup
extends CanvasLayer
## 战利品与背包开包共用弹窗；选项/刷新状态全部由 RunRewards 持久化。
signal finished
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
var _mode := "rewards"
var _item_id := ""
var _root: Control
var _body: VBoxContainer
var _heading: Label
var _description: Label
var _options: VBoxContainer
var _actions: HBoxContainer
var _error: Label
var _refresh_button: Button
var _continue_button: Button
var _run: RunStateMachine
var _working := false

func _ready() -> void:
	layer = 100
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.78)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -620
	panel.offset_right = 620
	panel.offset_top = -380
	panel.offset_bottom = 380
	var style := StyleBoxFlat.new()
	style.bg_color = Color("211b16")
	style.border_color = Color("cba24d")
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 36
	style.content_margin_right = 36
	style.content_margin_top = 28
	style.content_margin_bottom = 28
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 16)
	panel.add_child(_body)
	_heading = _label("", 32)
	_body.add_child(_heading)
	_description = _label("", 20)
	_body.add_child(_description)
	_options = VBoxContainer.new()
	_options.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options.add_theme_constant_override("separation", 12)
	_body.add_child(_options)
	_error = _label("", 18)
	_error.add_theme_color_override("font_color", Color("ffad94"))
	_body.add_child(_error)
	_actions = HBoxContainer.new()
	_actions.alignment = BoxContainer.ALIGNMENT_END
	_actions.add_theme_constant_override("separation", 20)
	_body.add_child(_actions)
	_refresh_button = _button("刷新（剩余 1 次）")
	_refresh_button.pressed.connect(_refresh_offer)
	_actions.add_child(_refresh_button)
	_continue_button = _button("继续探索")
	_continue_button.pressed.connect(_continue)
	_actions.add_child(_continue_button)

func show_rewards() -> void:
	_run = SaveGateway.current_run()
	_mode = "rewards"
	_render()

func show_pack(item_id: String) -> void:
	_run = SaveGateway.current_run()
	_mode = "pack"
	_item_id = item_id
	var error := RunRewards.open_pack(_run, item_id)
	if error != OK:
		_heading.text = "暂时无法打开卡包"
		_description.text = "请在战斗结束后重试。错误码：%d" % error
		_refresh_button.hide()
		_continue_button.text = "关闭"
		return
	_render()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		# 不让 Esc/Tab/M 穿透弹窗打开底层菜单或移动角色。
		if event.is_action_pressed("ui_cancel") and _mode == "pack":
			_finish()
		get_viewport().set_input_as_handled()

func _render() -> void:
	for child: Node in _options.get_children():
		_options.remove_child(child)
		child.queue_free()
	_error.text = ""
	if _mode == "rewards":
		_render_rewards()
	else:
		_render_pack()

func _render_rewards() -> void:
	var rewards := RunRewards.pending(_run)
	_heading.text = "战斗胜利 · %s战斗奖励" % str(rewards.get("grade", ""))
	_description.text = "点击奖励收入背包，全部领取后可继续探索；卡包可稍后在背包中打开。"
	_refresh_button.hide()
	_continue_button.text = "继续探索"
	_continue_button.disabled = false
	var entries: Array = rewards.get("entries", []).duplicate()
	entries.append_array(rewards.get("bonus_entries", []))
	for entry: Dictionary in entries:
		var button := _button(("已领取 · " if entry.claimed else "领取 · ") + str(RunRewards.NAMES[entry.kind]) + " × %d" % int(entry.amount))
		if entry.id == "stolen_silver": button.text += "（追回被盗银币）"
		elif entry.id == "conch_rare": button.text += "（海螺额外奖励）"
		button.name = "Reward_" + str(entry.id)
		button.disabled = bool(entry.claimed)
		button.pressed.connect(_claim.bind(str(entry.id)))
		_options.add_child(button)
		if not entry.claimed:
			_continue_button.disabled = true

func _render_pack() -> void:
	var pack := RunRewards.item(_run, _item_id)
	if pack.is_empty():
		_finish()
		return
	_heading.text = str(RunRewards.NAMES[pack.kind]) + " · %d 选 1" % pack.options.size()
	_description.text = "选中的卡牌加入牌组；残片收入背包。关闭后选项与刷新次数会保留。"
	_refresh_button.visible = pack.kind in ["fragment_pack", "common_pack"]
	_refresh_button.disabled = bool(pack.rerolled)
	_refresh_button.text = "刷新已使用" if bool(pack.rerolled) else "刷新（剩余 1 次）"
	_continue_button.text = "稍后选择"
	_continue_button.disabled = false
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 42)
	_options.add_child(row)
	var fragments := RelicCatalog.load_definitions()
	var cards := FormalCardCatalog.load_definitions()
	for id: String in pack.options:
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 16)
		row.add_child(column)
		var title := id
		if pack.kind == "fragment_pack":
			var data: RelicFragmentData = fragments[id]
			title = data.display_name
			var detail := _label("%s\n\n%s\n\n%s" % [data.display_name, data.kind_name(), data.description], 24)
			detail.custom_minimum_size = Vector2(360, 330)
			detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			column.add_child(detail)
		else:
			var data: CardData = cards.cards[id]
			title = data.card_name
			var slot := Control.new()
			slot.custom_minimum_size = Vector2(480, 818) * 0.4
			column.add_child(slot)
			var view: CardView = CARD_SCENE.instantiate()
			view.scale = Vector2.ONE * 0.4
			view.size = Vector2(480, 818)
			view.set_card(data)
			slot.add_child(view)
			var hit := Button.new()
			hit.name = "CardChoice_" + id
			hit.flat = true
			for state: String in ["normal", "hover", "pressed", "focus"]:
				hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
			hit.size = slot.custom_minimum_size
			hit.tooltip_text = "选择 · " + title
			hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			hit.pressed.connect(_choose.bind(id))
			slot.add_child(hit)
		var choose := _button("选择 · " + title)
		choose.name = "Choose_" + id
		choose.pressed.connect(_choose.bind(id))
		column.add_child(choose)

func _claim(id: String) -> void:
	if _working:
		return
	_working = true
	var error := RunRewards.claim(_run, id)
	_working = false
	if error == OK:
		_render()
	else:
		_error.text = "领取失败，未重复发放，请重试。错误码：%d" % error

func _refresh_offer() -> void:
	var error := RunRewards.refresh_pack(_run, _item_id)
	if error == OK:
		_render()
	else:
		_error.text = "无法刷新（每包仅一次）。错误码：%d" % error

func _choose(id: String) -> void:
	if _working:
		return
	_working = true
	var error := RunRewards.choose(_run, _item_id, id)
	_working = false
	if error == OK:
		_finish()
	else:
		_error.text = "选择未保存，请重试。错误码：%d" % error

func _continue() -> void:
	if _mode == "rewards":
		var error := RunRewards.finish_rewards(_run)
		if error != OK:
			_error.text = "请先领取全部奖励。错误码：%d" % error
			return
	_finish()

func _finish() -> void:
	_root.hide()
	set_process_input(false)
	finished.emit()
	queue_free()

func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color("ecd7ab"))
	return label

func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(220, 60)
	button.add_theme_font_size_override("font_size", 22)
	return button

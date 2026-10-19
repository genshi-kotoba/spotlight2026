class_name LootPopup
extends CanvasLayer
## 战利品与背包开包共用弹窗；选项/刷新状态全部由 RunRewards 持久化。
signal finished
signal suspension_changed(suspended: bool)
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
var _enchantment_id := ""
var _shade: ColorRect
var _panel: PanelContainer
var _choice_surface: Control
var _choice_fan: RewardChoiceFan
var _choice_error: Label
var _choice_spacer: Control
var _shade_tween: Tween
var _suspended := false
var _selection_active := false
var _finishing := false

func _ready() -> void:
	layer = 100
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_shade = ColorRect.new()
	_shade.color = Color(0, 0, 0, 0.78)
	_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_shade)
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.offset_left = -620
	_panel.offset_right = 620
	_panel.offset_top = -380
	_panel.offset_bottom = 380
	var style := CommonUiSkin.panel("panel", Vector4(36, 28, 36, 28))
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 16)
	_panel.add_child(_body)
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
	if _selection_active and event is InputEventKey:
		# 悬置并非退出：所有场景快捷键仍锁住，只允许 Esc 关闭正在查看的大图。
		if event.pressed and not event.is_echo() and event.is_action_pressed("ui_cancel"):
			var bag := get_parent() as RunMenuOverlay
			if _suspended and bag != null and is_instance_valid(bag._peek_layer) and bag._peek_layer.visible:
				bag._peek_layer.hide()
			else:
				_toggle_suspension()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed:
		# 不让 Esc/Tab/M 穿透弹窗打开底层菜单或移动角色。
		if event.is_action_pressed("ui_cancel") and _mode != "rewards":
			_finish()
		get_viewport().set_input_as_handled()

func _render() -> void:
	_reset_choice_presentation()
	for child: Node in _options.get_children():
		_options.remove_child(child)
		child.queue_free()
	_error.text = ""
	if _mode == "rewards":
		_render_rewards()
	elif _mode == "enchantment_targets":
		_render_enchantment_targets()
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
	if pack.kind == "enchantment_book":
		_description.text = "先选择一种附魔，再选择牌组中的一张符合条件的卡牌。完成附魔才消耗书；关闭后保留原选项。"
	_refresh_button.visible = pack.kind in ["fragment_pack", "common_pack"]
	_refresh_button.disabled = bool(pack.rerolled)
	_refresh_button.text = "刷新已使用" if bool(pack.rerolled) else "刷新（剩余 1 次）"
	_continue_button.text = "稍后选择"
	_continue_button.disabled = false
	if pack.kind != "enchantment_book":
		_render_choice_fan(pack)
		return
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 42)
	_options.add_child(row)
	for id: String in pack.options:
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 16)
		row.add_child(column)
		var data: Dictionary = CardEnchantments.DEFINITIONS[id]
		var symbol := _label(str(data.symbol), 76)
		symbol.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(symbol)
		var detail := _label(str(data.text) + "\n\n适用：" + str(data.type), 24)
		detail.custom_minimum_size = Vector2(320, 260)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(detail)
		var choose := _button("选择 · " + str(data.symbol))
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
	if _working or _suspended or (_selection_active and not _choice_fan.is_settled()): return
	var error := RunRewards.refresh_pack(_run, _item_id)
	if error == OK:
		_render()
	else:
		_error.text = "无法刷新（每包仅一次）。错误码：%d" % error
		_sync_choice_error()

func _choose(id: String) -> void:
	if _working or _suspended or _finishing:
		return
	if RunRewards.item(_run, _item_id).get("kind") == "enchantment_book":
		_enchantment_id = id
		_mode = "enchantment_targets"
		_render()
		return
	_working = true
	var error := RunRewards.choose(_run, _item_id, id)
	_working = false
	if error == OK:
		_finish()
	else:
		_error.text = "选择未保存，请重试。错误码：%d" % error
		_sync_choice_error()

func _continue() -> void:
	if _selection_active:
		_toggle_suspension()
		return
	if _mode == "enchantment_targets":
		_mode = "pack"
		_render()
		return
	if _mode == "rewards":
		var error := RunRewards.finish_rewards(_run)
		if error != OK:
			_error.text = "请先领取全部奖励。错误码：%d" % error
			return
	_finish()

func _render_enchantment_targets() -> void:
	var data: Dictionary = CardEnchantments.DEFINITIONS[_enchantment_id]
	_heading.text = "选择卡牌附魔 · " + str(data.symbol)
	_description.text = str(data.text) + "\n适用：%s · 每张卡最多两个不同附魔。" % str(data.type)
	_refresh_button.hide()
	_continue_button.text = "返回附魔选择"
	_continue_button.disabled = false
	var targets := RunRewards.enchantment_targets(_run, _enchantment_id)
	if targets.is_empty():
		var empty := _label("没有符合附魔条件的卡牌", 28)
		empty.name = "NoEnchantmentTargets"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_options.add_child(empty)
		return
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 16)
	scroll.add_child(grid)
	var definitions: Dictionary = FormalCardCatalog.load_definitions().cards
	for card: Dictionary in targets:
		var column := VBoxContainer.new()
		grid.add_child(column)
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(480, 818) * 0.36
		column.add_child(slot)
		var view: CardView = CARD_SCENE.instantiate()
		view.set_card(definitions[str(card.card_id)])
		view.set_enchantments(card)
		view.scale = Vector2.ONE * 0.36
		view.apply_compact_layout(0.36)
		slot.add_child(view)
		var choose := _button("附魔（%d/2）" % card.enchantments.size())
		choose.custom_minimum_size = Vector2(172, 52)
		choose.name = "EnchantCopy_" + str(card.copy_id).validate_node_name()
		choose.tooltip_text = CardEnchantments.describe(card)
		choose.pressed.connect(_apply_enchantment.bind(str(card.copy_id)))
		column.add_child(choose)
		var hit := Button.new()
		hit.flat = true
		hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for state: String in ["normal", "hover", "pressed", "focus"]:
			hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		hit.tooltip_text = choose.tooltip_text
		hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		hit.pressed.connect(_apply_enchantment.bind(str(card.copy_id)))
		slot.add_child(hit)

func _apply_enchantment(copy_id: String) -> void:
	if _working: return
	_working = true
	var error := RunRewards.apply_book(_run, _item_id, _enchantment_id, copy_id)
	_working = false
	if error == OK:
		_finish()
	else:
		_error.text = "附魔未保存，附魔书和卡牌保持不变。错误码：%d" % error

func _finish() -> void:
	if _finishing: return
	_finishing = true
	_selection_active = false
	_root.hide()
	set_process_input(false)
	finished.emit()
	queue_free()

func is_selection_locked() -> bool:
	return _selection_active and not _finishing

func is_suspended() -> bool:
	return is_selection_locked() and _suspended

func _render_choice_fan(pack: Dictionary) -> void:
	_selection_active = true
	_suspended = false
	_panel.hide()
	_choice_surface = Control.new()
	_choice_surface.name = "PackSelection"
	_choice_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_choice_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_choice_surface)
	var title := _label(_heading.text, 32)
	title.name = "SelectionTitle"
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 70
	title.offset_bottom = 120
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_surface.add_child(title)
	var hint := _label("点击选择 · 悬停放大 · 悬置后可查看背包，选择不会取消", 20)
	hint.name = "SelectionHint"
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hint.offset_top = 124
	hint.offset_bottom = 156
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_surface.add_child(hint)
	_options.reparent(_choice_surface)
	_options.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_options.offset_top = 165
	_options.offset_bottom = -215
	_options.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_fan = RewardChoiceFan.new()
	_choice_fan.name = "RewardChoiceFan"
	_choice_fan.chosen.connect(_choose)
	_options.add_child(_choice_fan)
	_choice_fan.configure(pack.options, pack.kind == "fragment_pack")
	_actions.reparent(_choice_surface)
	_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_actions.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_actions.anchor_top = 0.84
	_actions.anchor_bottom = 0.84
	_actions.offset_left = -370
	_actions.offset_right = 370
	_actions.offset_top = 0
	_actions.offset_bottom = 64
	_choice_spacer = Control.new()
	_choice_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_spacer.custom_minimum_size = _refresh_button.custom_minimum_size
	_choice_spacer.visible = _refresh_button.visible
	_actions.add_child(_choice_spacer)
	_continue_button.text = "悬置"
	_continue_button.focus_mode = Control.FOCUS_NONE
	_refresh_button.focus_mode = Control.FOCUS_NONE
	_choice_error = _label("", 18)
	_choice_error.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_choice_error.offset_top = -100
	_choice_error.offset_bottom = -50
	_choice_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_choice_error.add_theme_color_override("font_color", Color("ffad94"))
	_choice_error.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_surface.add_child(_choice_error)
	_fade_shade(1.0)
	suspension_changed.emit(false)

func _toggle_suspension() -> void:
	if not _selection_active or _working: return
	_suspended = not _suspended
	_continue_button.text = "恢复选择" if _suspended else "悬置"
	_refresh_button.visible = not _suspended and RunRewards.item(_run, _item_id).get("kind") in ["fragment_pack", "common_pack"]
	_choice_spacer.visible = _refresh_button.visible
	_choice_surface.get_node("SelectionTitle").visible = not _suspended
	_choice_surface.get_node("SelectionHint").visible = not _suspended
	_choice_error.visible = not _suspended
	# 无色遮罩也不能误吞背包的悬停、滚轮与只读大图。
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE if _suspended else Control.MOUSE_FILTER_STOP
	if _suspended: _choice_fan.fold()
	else: _choice_fan.open()
	_fade_shade(0.0 if _suspended else 1.0)
	suspension_changed.emit(_suspended)

func _fade_shade(alpha: float) -> void:
	if _shade_tween != null and _shade_tween.is_valid(): _shade_tween.kill()
	_shade_tween = create_tween()
	_shade_tween.tween_property(_shade, "modulate:a", alpha, 0.16).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _sync_choice_error() -> void:
	if is_instance_valid(_choice_error): _choice_error.text = _error.text

func _reset_choice_presentation() -> void:
	_selection_active = false
	_suspended = false
	_choice_fan = null
	_choice_error = null
	if is_instance_valid(_choice_surface):
		_options.reparent(_body)
		_options.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_options.mouse_filter = Control.MOUSE_FILTER_PASS
		_body.move_child(_options, 2)
		_actions.reparent(_body)
		_actions.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_actions.alignment = BoxContainer.ALIGNMENT_END
		_choice_surface.queue_free()
		_choice_surface = null
	if is_instance_valid(_choice_spacer):
		_actions.remove_child(_choice_spacer)
		_choice_spacer.queue_free()
	_choice_spacer = null
	if _shade_tween != null and _shade_tween.is_valid(): _shade_tween.kill()
	_shade.modulate.a = 1.0
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.show()

func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color("ecd7ab"))
	return label

func _button(value: String) -> Button:
	var button := Button.new()
	CommonUiSkin.style_button(button)
	button.text = value
	button.custom_minimum_size = Vector2(220, 60)
	button.add_theme_font_size_override("font_size", 22)
	return button

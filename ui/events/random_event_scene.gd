extends Control
## 独立事件场景；显示与交互不直接修改卡组、银币或奖励。
var request: Dictionary = {}
var run: RunStateMachine
var _content: VBoxContainer
var _title: Label
var _status: Label
var _background: TextureRect
var _selected: Array[String] = []
var _generation := 0
var _leaving := false

func _ready() -> void:
	run = SaveGateway.current_run()
	if run == null or EncounterFlow.session == null or EncounterFlow.session.pending.get("type") != "event":
		SceneTransition.call_deferred("change_scene_to_file", EncounterFlow.MAP_SCENE)
		return
	request = EncounterFlow.session.pending.duplicate(true)
	_build()
	var error := RunRandomEvents.open(run, request)
	if error != OK: _status.text = "事件读取失败：%d" % error; return
	_refresh()

func _build() -> void:
	CatalogUi.install_theme(self)
	_background = TextureRect.new()
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.025, 0.035, 0.65)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", CatalogUi.panel_style(Color(0.078, 0.065, 0.055, 0.92)))
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 150; panel.offset_right = -150; panel.offset_top = 85; panel.offset_bottom = -85
	add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	margin.add_child(column)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 38)
	column.add_child(_title)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 23)
	column.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 12)
	scroll.add_child(_content)

func _refresh() -> void:
	_generation += 1
	_selected.clear()
	for child: Node in _content.get_children(): _content.remove_child(child); child.queue_free()
	var current := RunRandomEvents.state(run, request)
	if current.is_empty(): return
	var index := int(current.index)
	_title.text = "EV-%03d · %s" % [index + 1, RandomEventCatalog.NAMES[index]]
	_background.texture = load(RandomEventCatalog.background(index))
	_status.text = "生命 %d / %d · 银币 %d" % [run.health, run.max_health, run.gold]
	match str(current.stage):
		"choice":
			var choices := RandomEventCatalog.choices(index)
			for option in choices.size():
				_button(str(choices[option]), _choose.bind(option))
			if index == 2: _status.text += " · 已抽 %d / 3 次" % int(current.plays)
		"inputs", "reward":
			var count := 1 if current.stage == "reward" or index == 8 else 2
			_status.text += "\n请选择 %d 项；同名卡牌的不同副本可以分别选择。" % count
			for entry: Dictionary in RunRandomEvents.selectables(run, request):
				var button := _button(str(entry.label), func(): pass)
				button.toggle_mode = true
				button.toggled.connect(func(pressed: bool):
					if pressed: _selected.append(str(entry.id))
					else: _selected.erase(str(entry.id))
					if _selected.size() > count: _selected.erase(str(entry.id)); button.set_pressed_no_signal(false))
			_button("确认选择", _confirm)
			if current.stage == "inputs": _button("取消并离开", _cancel)
		"result":
			_status.text += "\n\n" + str(current.result)
			if index == 2 and int(current.plays) < 3 and not str(current.result).begins_with("已离开"):
				_button("继续抽取", _gamble_again)
				_button("结束事件并返回地图", _finish)
			else:
				_status.text += "\n\n事件结果已保存，正在返回地图……"
				_auto_finish(_generation)
		"done": call_deferred("_leave")

func _button(label: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size.y = 68
	button.add_theme_font_size_override("font_size", 23)
	button.pressed.connect(callback, CONNECT_DEFERRED)
	_content.add_child(button)
	return button

func _choose(option: int) -> void:
	_result(RunRandomEvents.choose(run, request, option))

func _confirm() -> void:
	_result(RunRandomEvents.select(run, request, _selected))

func _result(error: Error) -> void:
	if error != OK:
		_status.text = "无法完成：生命、银币或可选素材不足，或选择数量不符（%d）。" % error
	else: _refresh()

func _cancel() -> void:
	# 未消费素材；取消也走一次事务，不能丢弃已提交奖励。
	var before := RunRandomEvents.capture(run)
	var current := RunRandomEvents.state(run, request)
	current.stage = "result"; current.result = "已离开，无奖励"
	run.inventory_state.events[RunRandomEvents.key(request)] = current
	_result(RunRandomEvents.commit(run, before))

func _gamble_again() -> void:
	_result(RunRandomEvents.acknowledge(run, request, true))

func _auto_finish(generation: int) -> void:
	await get_tree().create_timer(2.0).timeout
	if is_inside_tree() and generation == _generation: _finish()

func _finish() -> void:
	_result(RunRandomEvents.acknowledge(run, request))

func _leave() -> void:
	if _leaving: return
	_leaving = true
	var session: RefCounted = EncounterFlow.session
	var before: Dictionary = session.capture_state()
	if not session.resolve_request({"request_id": request.request_id, "status": "completed"}):
		_status.text = session.last_error; _leaving = false; return
	var error := SaveGateway.save_current()
	if error != OK:
		session.restore_state(before)
		request = session.pending.duplicate(true)
		_status.text = "保存失败，点击重试。"
		_button("重试返回", _leave)
		_leaving = false
		return
	MapEvents.node_interaction_resolved.emit(str(request.request_id), str(request.node_id), "completed")
	error = SceneTransition.change_scene_to_file(EncounterFlow.MAP_SCENE)
	if error != OK: _leaving = false; _status.text = "返回地图失败：%d" % error; _button("重试返回", _return_map)

func _return_map() -> void:
	SceneTransition.change_scene_to_file(EncounterFlow.MAP_SCENE)

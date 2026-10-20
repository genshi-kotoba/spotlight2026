extends Control
## 独立事件场景；显示与交互不直接修改卡组、银币或奖励。
## 右侧整列的位置/宽高在 random_event_scene.tscn 的 OptionsColumn 中调整。
const DECK_PICKER := preload("res://ui/events/event_deck_picker.gd")
@export_group("选项按钮")
@export var option_button_min_size := Vector2(0, 76)
@export_range(12, 48, 1) var option_button_font_size := 23
@export_range(0, 48, 1) var option_button_spacing := 14

var request: Dictionary = {}
var run: RunStateMachine
@onready var _content: VBoxContainer = $OptionsColumn/OptionsScroll/Options
@onready var _title: Label = $OptionsColumn/EventTitle
@onready var _status: Label = $OptionsColumn/EventStatus
@onready var _background: TextureRect = $EventBackground
var _selected: Array[String] = []
var _generation := 0
var _leaving := false
var _deck_picker: CanvasLayer

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
	_content.add_theme_constant_override("separation", option_button_spacing)

func _refresh() -> void:
	if not is_instance_valid(run) or not run.active:
		RunResults.present(self)
		return
	_close_deck_picker()
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
			if index == 9 and current.stage == "inputs":
				_status.text += "\n从完整牌组中点击选择两张合成素材。"
				_button("打开牌组选择", _open_deck_picker)
				_button("取消并离开", _cancel)
				_open_deck_picker()
				return
			var count := 1 if current.stage == "reward" or index == 8 else 2
			_status.text += "\n请选择 %d 项；同名卡牌的不同副本可以分别选择。" % count
			for entry: Dictionary in RunRandomEvents.selectables(run, request):
				var button := _button(str(entry.label), func(): pass)
				if not str(entry.get("rich_label", "")).is_empty():
					_fragment_option(button, str(entry.rich_label))
				button.toggle_mode = true
				button.toggled.connect(func(pressed: bool):
					if pressed: _selected.append(str(entry.id))
					else: _selected.erase(str(entry.id))
					if _selected.size() > count: _selected.erase(str(entry.id)); button.set_pressed_no_signal(false))
			_button("确认选择", _confirm)
			if current.stage == "inputs": _button("取消并离开", _cancel)
		"result":
			_status.text += "\n\n" + _result_summary(current)
			for fragment_id: String in current.get("result_fragments", []):
				var fragment: RelicFragmentData = RelicCatalog.resolve(fragment_id)
				if fragment != null:
					_content.add_child(_fragment_detail(fragment.rich_text()))
			if index == 2 and int(current.plays) < 3 and not str(current.result).begins_with("已离开"):
				_button("继续抽取", _gamble_again)
				_button("结束事件并返回地图", _finish)
			else:
				_status.text += "\n\n事件结果已保存，稍后自动返回地图，也可立即返回。"
				var return_button := _button("返回地图", _finish)
				return_button.name = "EventReturnNow"
				_auto_finish(_generation)
		"done": call_deferred("_leave")

func _open_deck_picker() -> void:
	var current := RunRandomEvents.state(run, request)
	if _leaving or int(current.get("index", -1)) != 9 or current.get("stage") != "inputs": return
	if is_instance_valid(_deck_picker): return
	run.ensure_deck_cards()
	_deck_picker = DECK_PICKER.new()
	_deck_picker.name = "SynthesisDeckPicker"
	add_child(_deck_picker)
	_deck_picker.selection_confirmed.connect(_on_synthesis_selected)
	_deck_picker.dismissed.connect(_on_deck_picker_dismissed)
	_deck_picker.show_deck(run.deck_cards, _selected)
	_set_options_disabled(true)

func _on_synthesis_selected(copy_ids: Array[String]) -> void:
	_selected.assign(copy_ids)
	var error := RunRandomEvents.select(run, request, _selected)
	if error == OK:
		_refresh()
	else:
		_deck_picker.show_error("选择未提交，牌组未消耗。请重试或重新选择（%d）。" % error)

func _on_deck_picker_dismissed(copy_ids: Array[String]) -> void:
	_selected.assign(copy_ids)
	_close_deck_picker()

func _close_deck_picker() -> void:
	if is_instance_valid(_deck_picker):
		_deck_picker.queue_free()
	_deck_picker = null
	if is_instance_valid(_content): _set_options_disabled(false)

func _set_options_disabled(disabled: bool) -> void:
	for button: Button in _content.find_children("*", "Button", true, false):
		button.disabled = disabled

func _result_summary(current: Dictionary) -> String:
	var summary := str(current.get("result", ""))
	for fragment_id: String in current.get("result_fragments", []):
		var fragment: RelicFragmentData = RelicCatalog.resolve(fragment_id)
		if fragment == null:
			continue
		var heading := "获得典籍残片：" + fragment.display_name
		summary = summary.replace(heading + "\n" + fragment.description, heading)
	return summary

func _fragment_option(button: Button, rich_text: String) -> void:
	# 原按钮仍负责勾选；残片效果单列展示，避免按钮重复显示无颜色的辅助说明。
	# 右侧窄列中上下排列，避免残片说明和按钮并排把选项区撑出屏幕。
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.remove_child(button)
	_content.add_child(row)
	row.add_child(_fragment_detail(rich_text))
	button.text = button.text.get_slice("\n", 0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(button)

func _fragment_detail(rich_text: String) -> RichTextLabel:
	var detail := RichTextLabel.new()
	CommonUiSkin.setup_relic_text(detail, 23)
	detail.name = "FragmentDetails"
	detail.bbcode_enabled = true
	detail.text = rich_text
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.custom_minimum_size.y = 96
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.scroll_active = false
	detail.focus_mode = Control.FOCUS_NONE
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_theme_color_override("default_color", CommonUiSkin.TEXT)
	detail.resized.connect(_resize_fragment_detail.bind(detail))
	_resize_fragment_detail.call_deferred(detail)
	return detail

func _resize_fragment_detail(detail: RichTextLabel) -> void:
	if not is_instance_valid(detail) or detail.is_queued_for_deletion():
		return
	# 容器先决定换行宽度，再用内容高度扩展行；外层滚动区负责长列表。
	var height := maxf(1.0, float(detail.get_content_height()))
	if not is_equal_approx(detail.custom_minimum_size.y, height):
		detail.custom_minimum_size.y = height

func _button(label: String, callback: Callable) -> Button:
	var button := Button.new()
	CommonUiSkin.style_button(button)
	button.text = label
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size = option_button_min_size
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", option_button_font_size)
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
	if is_instance_valid(_deck_picker): return
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
	if not is_instance_valid(run) or not run.active: return
	# A click and the reading timer may arrive in the same frame. Acknowledge
	# only a result, and invalidate the timer before committing it once.
	if _leaving or RunRandomEvents.state(run, request).get("stage") != "result": return
	_generation += 1
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

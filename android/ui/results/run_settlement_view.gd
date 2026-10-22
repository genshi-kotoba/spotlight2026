extends Control
## 结束结算与历史详情共用：最终背包只读，文字复用典籍负面抖动效果。
signal confirmed
const BACKGROUNDS := preload("res://ui/battle/battle_environment.gd")
@export var fade_seconds := 0.8
@export var line_seconds := 0.55
@export var line_gap := 0.35
@export var hold_seconds := 1.0
@export var move_seconds := 0.65
var record: Dictionary = {}
var bag: RunMenuOverlay
var summary: VBoxContainer
var confirm_button: Button
var background: TextureRect
var outgoing: TextureRect
var _stage: Control
var _inventory: RunStateMachine
var _error: Label
var detail_ready := false
var _intro_tween: Tween
var _detail_opening := false
var _skip_hint: Label
var _skip_input: InputEvent
var _skip_release_frame := -1

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	CatalogUi.install_theme(self)
	resized.connect(_layout)
	get_window().focus_exited.connect(_clear_skip_input)

func show_record(data: Dictionary, intro: bool = true, frame: Texture2D = null) -> void:
	record = data.duplicate(true)
	background = TextureRect.new()
	background.name = "SettlementBackground"
	background.texture = TextCatalogService.art_texture(str(record.get("background_path", BACKGROUNDS.path_for_floor(1))))
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if frame != null:
		outgoing = TextureRect.new()
		outgoing.name = "OutgoingScene"
		outgoing.texture = frame
		outgoing.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		outgoing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(outgoing)
		outgoing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage = Control.new()
	_stage.size = Vector2(1920, 1080)
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage)
	_inventory = RunHistory.inventory_run(record)
	add_child(_inventory)
	bag = RunMenuOverlay.new()
	bag.name = "FinalBackpack"
	bag.settlement_mode = true
	bag.run_override = _inventory
	_stage.add_child(bag)
	bag._shade.color = Color.TRANSPARENT
	bag._close_button.hide()
	bag._page_title.text = "最终背包 · 仅供查看"
	summary = VBoxContainer.new()
	summary.name = "SettlementSummary"
	summary.position = Vector2(700, 270)
	summary.size = Vector2(520, 440)
	summary.add_theme_constant_override("separation", 24)
	summary.z_index = 510
	summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(summary)
	var lines := RunHistory.lines(record)
	for index in lines.size():
		var label := RichTextLabel.new()
		CommonUiSkin.setup_relic_text(label, 74 if index == 0 else 36)
		label.bbcode_enabled = true
		label.scroll_active = false
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.custom_minimum_size = Vector2(520, 110 if index == 0 else 86)
		label.add_theme_color_override("default_color", CatalogUi.INK)
		label.add_theme_color_override("font_outline_color", Color("18100c"))
		label.add_theme_constant_override("outline_size", 5)
		# 只为标题添加效果，其余句子完整、依次淡入。
		var content := lines[index].replace("[", "[lb]")
		if index == 0:
			content = "[color=#e9b85e]%s[/color]" % content if record.get("result") == "victory" else "[relic_motion seed=%d][color=%s]%s[/color][/relic_motion]" % [str(record.get("run_id", "")).hash(), RelicFragmentData.NEGATIVE_COLOR, content]
		label.text = "[center]%s[/center]" % content
		label.modulate.a = 0.0 if intro else 1.0
		summary.add_child(label)
	confirm_button = CatalogUi.button("返回主菜单" if intro else "返回记录列表", "ConfirmSettlement")
	confirm_button.position = Vector2(1580, 960)
	confirm_button.size = Vector2(200, 64)
	confirm_button.z_index = 20 # 相对背包的 500；低于卡牌大图的 630。
	confirm_button.hide()
	confirm_button.pressed.connect(_confirm)
	# open() 会把背包移到父节点最后，GUI 命中顺序不取决于 z_index。
	# 确定必须放进背包，避免可见的按钮被背包面板拦截；大图仍在它上方。
	bag.add_child(confirm_button)
	bag.move_child(confirm_button, bag._peek_layer.get_index())
	_error = CatalogUi.label("", 19)
	_error.position = Vector2(130, 860)
	_error.size = Vector2(300, 85)
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.z_index = 520
	_stage.add_child(_error)
	if intro:
		_skip_hint = CatalogUi.label("点击 / 轻触 / 按确认键跳过", 24)
		_skip_hint.name = "SettlementSkipHint"
		_skip_hint.position = Vector2(560, 900)
		_skip_hint.size = Vector2(800, 64)
		_skip_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_skip_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_skip_hint.add_theme_color_override("font_outline_color", Color("18100c"))
		_skip_hint.add_theme_constant_override("outline_size", 4)
		_skip_hint.z_index = 520
		_stage.add_child(_skip_hint)
	_layout()
	if intro: _animate()
	else: _show_detail()

func _animate() -> void:
	# 单条节点绑定时间线：跳过或释放时可整体取消，不留下等待中的协程。
	_intro_tween = create_tween()
	if is_instance_valid(outgoing):
		_intro_tween.tween_property(outgoing, "modulate:a", 0.0, fade_seconds)
		_intro_tween.tween_callback(_clear_outgoing)
	else:
		_intro_tween.tween_interval(fade_seconds)
	for line: Control in summary.get_children():
		_intro_tween.tween_property(line, "modulate:a", 1.0, line_seconds)
		if line != summary.get_child(summary.get_child_count() - 1):
			_intro_tween.tween_interval(line_gap)
	_intro_tween.tween_interval(hold_seconds)
	_intro_tween.tween_property(summary, "position", Vector2(124, 300), move_seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_intro_tween.parallel().tween_property(summary, "scale", Vector2.ONE * 0.6, move_seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_intro_tween.finished.connect(_show_detail, CONNECT_ONE_SHOT)

func _show_detail() -> void:
	if detail_ready or _detail_opening or not is_inside_tree() or is_queued_for_deletion(): return
	_detail_opening = true
	if _intro_tween != null and _intro_tween.is_valid(): _intro_tween.kill()
	_intro_tween = null
	_clear_outgoing()
	if is_instance_valid(_skip_hint): _skip_hint.hide()
	for line: Control in summary.get_children(): line.modulate.a = 1.0
	summary.position = Vector2(124, 300)
	summary.scale = Vector2.ONE * 0.6
	bag.open(1)
	bag._page_title.text = "最终背包 · 仅供查看"
	if bag._open_tween != null and bag._open_tween.is_running():
		bag._open_tween.finished.connect(_detail_opened, CONNECT_ONE_SHOT)
	else:
		_detail_opened()

func _detail_opened() -> void:
	if not _detail_opening or not is_inside_tree() or is_queued_for_deletion(): return
	_detail_opening = false
	confirm_button.show()
	detail_ready = true
	confirm_button.grab_focus()

func _clear_outgoing() -> void:
	if is_instance_valid(outgoing):
		outgoing.hide()
		outgoing.queue_free()
	outgoing = null

func _input(event: InputEvent) -> void:
	if _stage == null or not is_visible_in_tree() or is_queued_for_deletion(): return
	# 整个跳过手势（含触摸模拟鼠标及按键重复）只做跳过，不穿透到返回按钮。
	if _skip_input != null:
		if _is_skip_release(event): _clear_skip_input()
		get_viewport().set_input_as_handled()
		return
	if Engine.get_process_frames() == _skip_release_frame:
		get_viewport().set_input_as_handled()
		return
	if detail_ready: return
	var pressed: bool = (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) \
		or (event is InputEventScreenTouch and event.pressed) \
		or ((event is InputEventKey or event is InputEventAction or event is InputEventJoypadButton) \
			and not event.is_echo() and (event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel")))
	if not pressed: return
	_skip_input = event.duplicate()
	_show_detail()
	get_viewport().set_input_as_handled()

func _is_skip_release(event: InputEvent) -> bool:
	if event is InputEventMouseButton and _skip_input is InputEventMouseButton:
		return not event.pressed and event.button_index == _skip_input.button_index
	if event is InputEventScreenTouch and _skip_input is InputEventScreenTouch:
		return not event.pressed and event.index == _skip_input.index
	if event is InputEventKey and _skip_input is InputEventKey:
		return not event.pressed and event.keycode == _skip_input.keycode and event.physical_keycode == _skip_input.physical_keycode
	if event is InputEventAction and _skip_input is InputEventAction:
		return not event.pressed and event.action == _skip_input.action
	if event is InputEventJoypadButton and _skip_input is InputEventJoypadButton:
		return not event.pressed and event.device == _skip_input.device and event.button_index == _skip_input.button_index
	return false

func _clear_skip_input() -> void:
	_skip_input = null
	_skip_release_frame = Engine.get_process_frames()

func _confirm() -> void:
	if not detail_ready or _skip_input != null or Engine.get_process_frames() == _skip_release_frame: return
	# 确认焦点可留在大图下方；阅读或其他背包弹层未关闭时不能穿透返回。
	if is_instance_valid(bag._peek_layer) and bag._peek_layer.visible: return
	if is_instance_valid(bag._upgrade_layer) or is_instance_valid(bag._pack_popup): return
	if is_instance_valid(bag._item_menu) and bag._item_menu.visible: return
	confirmed.emit()

func _exit_tree() -> void:
	if _intro_tween != null and _intro_tween.is_valid(): _intro_tween.kill()
	_detail_opening = false

func show_error(message: String) -> void:
	_error.text = message
	confirm_button.disabled = false

func _layout() -> void:
	if _stage == null: return
	_stage.scale = Vector2.ONE * minf(size.x / 1920.0, size.y / 1080.0)
	_stage.position = (size - Vector2(1920, 1080) * _stage.scale) * 0.5

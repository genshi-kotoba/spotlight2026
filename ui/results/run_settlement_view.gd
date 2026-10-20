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

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	CatalogUi.install_theme(self)
	resized.connect(_layout)

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
	confirm_button = CatalogUi.button("确定", "ConfirmSettlement")
	confirm_button.position = Vector2(1580, 960)
	confirm_button.size = Vector2(200, 64)
	confirm_button.z_index = 20 # 相对背包的 500；低于卡牌大图的 630。
	confirm_button.hide()
	confirm_button.pressed.connect(func(): confirmed.emit())
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
	_layout()
	if intro: _animate()
	else: _show_detail()

func _animate() -> void:
	if is_instance_valid(outgoing):
		await create_tween().tween_property(outgoing, "modulate:a", 0.0, fade_seconds).finished
		outgoing.queue_free()
	else:
		await get_tree().create_timer(fade_seconds).timeout
	for line: Control in summary.get_children():
		await create_tween().tween_property(line, "modulate:a", 1.0, line_seconds).finished
		if line != summary.get_child(summary.get_child_count() - 1):
			await get_tree().create_timer(line_gap).timeout
	await get_tree().create_timer(hold_seconds).timeout
	var move := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	move.tween_property(summary, "position", Vector2(124, 300), move_seconds)
	move.tween_property(summary, "scale", Vector2.ONE * 0.6, move_seconds)
	await move.finished
	_show_detail()

func _show_detail() -> void:
	summary.position = Vector2(124, 300)
	summary.scale = Vector2.ONE * 0.6
	bag.open(1)
	bag._page_title.text = "最终背包 · 仅供查看"
	if bag._open_tween != null and bag._open_tween.is_running():
		await bag._open_tween.finished
	confirm_button.show()
	detail_ready = true

func show_error(message: String) -> void:
	_error.text = message
	confirm_button.disabled = false

func _layout() -> void:
	if _stage == null: return
	_stage.scale = Vector2.ONE * minf(size.x / 1920.0, size.y / 1080.0)
	_stage.position = (size - Vector2(1920, 1080) * _stage.scale) * 0.5

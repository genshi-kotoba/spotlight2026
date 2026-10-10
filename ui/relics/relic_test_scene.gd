extends Control

const BATTLE_SCENE := "res://ui/battle/battle_test_scene.tscn"

var _board := RelicBoard.new()
var _catalog: Dictionary = {}
var _selected := ""
var _slots: Array[RelicSlotButton] = []
var _palette: Array[RelicSlotButton] = []
var _detail: Label
var _status: Label
var _battle_button: Button


func _ready() -> void:
	_catalog = RelicCatalog.load_definitions()
	_build_ui()
	var error := _board.load_from_file(_catalog)
	if error == ERR_FILE_NOT_FOUND:
		_load_example()
	elif error != OK:
		_status.text = "配置读取失败（%d），可以重新编排并保存。" % error
	_refresh()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("151820")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 22)
	margin.add_child(page)
	page.add_child(_label("典籍残片 · 试验编排", 38, Color("ecd2a1")))
	page.add_child(_label("4 列 × 3 行  /  选择残片后点击格子，或直接拖放  /  格子之间拖动换位  /  右键移除", 22))
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 32)
	page.add_child(body)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 420
	left.add_theme_constant_override("separation", 12)
	body.add_child(left)
	left.add_child(_label("测试残片库 · 可放置多个副本", 23))
	for id: String in _catalog:
		var data: RelicFragmentData = _catalog[id]
		var button := RelicSlotButton.new()
		button.fragment_id = id
		button.text = "%s · %s\n%s" % [data.kind_name(), data.display_name, data.description]
		button.custom_minimum_size = Vector2(420, 108)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.add_theme_font_size_override("font_size", 21)
		button.add_theme_stylebox_override("normal", _style(data.tint(), false))
		button.add_theme_stylebox_override("hover", _style(data.tint(), true))
		button.pressed.connect(_select_fragment.bind(id))
		button.tooltip_text = data.description
		_palette.append(button)
		left.add_child(button)
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 16)
	body.add_child(center)
	center.add_child(_label("典籍页面  /  金：触发  ·  蓝：效果  ·  紫：存在", 23))
	var grid := GridContainer.new()
	grid.columns = RelicBoard.COLUMNS
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	center.add_child(grid)
	for index in RelicBoard.CELL_COUNT:
		var button := RelicSlotButton.new()
		button.cell_index = index
		button.custom_minimum_size = Vector2(215, 145)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.size_flags_vertical = Control.SIZE_EXPAND_FILL
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.add_theme_font_size_override("font_size", 22)
		button.pressed.connect(_place_selected.bind(index))
		button.gui_input.connect(_on_cell_input.bind(index))
		button.mouse_entered.connect(_show_range.bind(index))
		button.mouse_exited.connect(_clear_range)
		button.dropped.connect(_on_drop)
		_slots.append(button)
		grid.add_child(button)
	_detail = _label("悬停查看连接：四格只含上下左右，八格还包含对角。", 21)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size.y = 64
	center.add_child(_detail)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 16)
	page.add_child(footer)
	var example := Button.new()
	example.text = "载入示例"
	example.custom_minimum_size = Vector2(160, 58)
	example.pressed.connect(_load_example)
	footer.add_child(example)
	var clear := Button.new()
	clear.text = "清空页面"
	clear.custom_minimum_size = Vector2(160, 58)
	clear.pressed.connect(_clear_board)
	footer.add_child(clear)
	_status = _label("编排完成后点击战斗：保存配置并在整场战斗持续生效。", 21)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(_status)
	_battle_button = Button.new()
	_battle_button.text = "战斗 →"
	_battle_button.custom_minimum_size = Vector2(210, 64)
	_battle_button.add_theme_font_size_override("font_size", 28)
	_battle_button.pressed.connect(_enter_battle)
	footer.add_child(_battle_button)


func _select_fragment(id: String) -> void:
	_selected = id
	_refresh()
	_status.text = "已选中「%s」，点击目标格子放置；点击已占用格会替换残片。" % _catalog[id].display_name


func _place_selected(index: int) -> void:
	if not _selected.is_empty():
		_board.place(index, _selected, _catalog)
		_refresh()
	_show_range(index)


func _on_cell_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_board.place(index, "", _catalog)
		_refresh()
		accept_event()


func _on_drop(destination: int, payload: Dictionary) -> void:
	var source := int(payload.get("source", -1))
	if source >= 0:
		_board.swap_cells(source, destination)
	else:
		_board.place(destination, String(payload["fragment_id"]), _catalog)
	_refresh()
	_show_range(destination)


func _load_example() -> void:
	_board.cells.fill("")
	_board.place(0, "turn_strength", _catalog)
	_board.place(1, "on_card_gained", _catalog)
	_board.place(2, "gain_block", _catalog)
	_board.place(5, "deal_damage", _catalog)
	_board.place(6, "on_enemy_damaged", _catalog)
	_refresh()
	_status.text = "示例：抽牌 → 伤害/格挡 → 伤害触发邻格；每回合自动获得力量。"


func _clear_board() -> void:
	_board.cells.fill("")
	_refresh()
	_status.text = "页面已清空。空页面也可进入战斗测试。"


func _refresh() -> void:
	for button: RelicSlotButton in _palette:
		var data: RelicFragmentData = _catalog[button.fragment_id]
		button.add_theme_stylebox_override("normal", _style(data.tint(), button.fragment_id == _selected))
	for index in _slots.size():
		var button := _slots[index]
		button.fragment_id = _board.cells[index]
		var data: RelicFragmentData = _catalog.get(button.fragment_id)
		var coordinate := "%d · %d" % [index / RelicBoard.COLUMNS + 1, index % RelicBoard.COLUMNS + 1]
		button.text = coordinate + "\n空格" if data == null else "%s  /  %s\n%s\n%s" % [
			coordinate, data.kind_name(), data.display_name, data.description]
		button.tooltip_text = "右键移除 / 拖动换位" if data == null else data.description + "\n右键移除 / 拖动换位"
		var tint := Color("667084") if data == null else data.tint()
		button.add_theme_stylebox_override("normal", _style(tint, false))
		button.add_theme_stylebox_override("hover", _style(tint, true))


func _show_range(index: int) -> void:
	_refresh()
	var data: RelicFragmentData = _catalog.get(_board.cells[index])
	if data == null:
		_detail.text = "空格：选择残片后点击放置，或从左侧拖入。"
		return
	if data.kind != RelicFragmentData.Kind.TRIGGER:
		_detail.text = data.description + (" · 无需相邻触发即可生效。" if data.kind == RelicFragmentData.Kind.PRESENCE else " · 需要位于触发残片范围内。")
		return
	var connected := 0
	for neighbor: int in _board.neighbors(index, data.reach):
		var effect: RelicFragmentData = _catalog.get(_board.cells[neighbor])
		var tint := Color("667084") if effect == null else effect.tint()
		_slots[neighbor].add_theme_stylebox_override("normal", _style(tint, true))
		if effect != null and effect.kind == RelicFragmentData.Kind.EFFECT:
			connected += 1
	_detail.text = "%s · 已连接 %d 个效果残片。高亮格为覆盖范围，边界不跨行、不环绕。" % [data.description, connected]


func _clear_range() -> void:
	_refresh()


func _enter_battle() -> void:
	_battle_button.disabled = true
	var error := _board.save_to_file()
	if error == OK:
		error = get_tree().change_scene_to_file(BATTLE_SCENE)
	if error != OK:
		_status.text = "保存配置或进入战斗失败：%d" % error
		_battle_button.disabled = false


static func _label(content: String, font_size: int, tint: Color = Color("d9dce5")) -> Label:
	var label := Label.new()
	label.text = content
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", tint)
	return label


static func _style(tint: Color, highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("313541") if highlighted else Color("20242e")
	style.border_color = tint if highlighted else tint.darkened(0.4)
	style.set_border_width_all(3 if highlighted else 1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

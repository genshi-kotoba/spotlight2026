extends Control

const CATEGORY_LABELS := {"cards": "卡牌", "fragments": "典籍残片", "monsters": "怪物"}
const MODE_LABELS := ["显示所有", "显示已解锁", "显示未解锁"]

var category := "cards"
var display_mode: TextCatalogService.DisplayMode = TextCatalogService.DisplayMode.ALL
var visible_entries: Array[Dictionary] = []
var detail_entry: Dictionary = {}
var _grid: GridContainer
var _scroll: ScrollContainer
var _status: Label
var _mode_button: Button
var _category_buttons: Dictionary = {}
var _detail: Control
var _detail_card: CenterContainer
var _detail_fields: VBoxContainer


func _ready() -> void:
	var body := CatalogUi.shell(self, "图鉴", "按编号排列 · 点击查看详情 · 解锁状态属于当前档案")
	var navigation := HBoxContainer.new()
	navigation.name = "Categories"
	navigation.add_theme_constant_override("separation", 16)
	body.add_child(navigation)
	for key: String in CATEGORY_LABELS:
		var tab := CatalogUi.button(CATEGORY_LABELS[key], key)
		navigation.add_child(tab)
		_category_buttons[key] = tab
		tab.pressed.connect(func(): select_category(key))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	navigation.add_child(spacer)
	_mode_button = CatalogUi.button(MODE_LABELS[0], "DisplayMode")
	_mode_button.pressed.connect(cycle_display_mode)
	navigation.add_child(_mode_button)
	_status = CatalogUi.label("")
	_status.name = "Status"
	body.add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.name = "Entries"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(_scroll)
	_grid = GridContainer.new()
	_grid.columns = 6
	_grid.add_theme_constant_override("h_separation", 24)
	_grid.add_theme_constant_override("v_separation", 28)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid)
	_scroll.resized.connect(_resize_grid)
	_build_detail()
	TextCatalog.catalog_changed.connect(refresh)
	TextCatalog.progress_changed.connect(refresh)
	refresh()


func select_category(value: String) -> void:
	if not CATEGORY_LABELS.has(value):
		return
	category = value
	_detail.hide()
	detail_entry.clear()
	_scroll.scroll_vertical = 0
	refresh()


func cycle_display_mode() -> void:
	set_display_mode((int(display_mode) + 1) % MODE_LABELS.size())


func set_display_mode(value: int) -> void:
	if value < 0 or value >= MODE_LABELS.size():
		return
	display_mode = value as TextCatalogService.DisplayMode
	_scroll.scroll_vertical = 0
	refresh()


func refresh() -> void:
	if not is_node_ready():
		return
	visible_entries = TextCatalog.entries(category, display_mode)
	_mode_button.text = MODE_LABELS[int(display_mode)]
	for key: String in _category_buttons:
		_category_buttons[key].disabled = key == category
	CatalogUi.clear(_grid)
	var error := TextCatalog.error_message(category)
	_status.text = "%s · %s · %d 项" % [CATEGORY_LABELS[category], MODE_LABELS[int(display_mode)], visible_entries.size()]
	if not error.is_empty():
		_status.text = "数据读取失败：" + error
	elif visible_entries.is_empty():
		_status.text += "\n暂无条目。CSV 未填写，或当前筛选没有符合的条目。"
	for record: Dictionary in visible_entries:
		var tile := VBoxContainer.new()
		tile.name = "Entry_" + record.id
		tile.custom_minimum_size = Vector2(264, 480)
		tile.add_theme_constant_override("separation", 10)
		_grid.add_child(tile)
		var id_label := CatalogUi.label(record.id, 22)
		id_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		id_label.modulate = CatalogUi.MUTED
		tile.add_child(id_label)
		var hit := Button.new()
		hit.name = "OpenDetail"
		hit.custom_minimum_size = Vector2(264, 429)
		hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		hit.tooltip_text = "查看详情"
		tile.add_child(hit)
		var card := CatalogUi.preview(hit, record, category, 0.5)
		card.position = Vector2(12, 10)
		hit.pressed.connect(func(): open_detail(record.id))
	_resize_grid()
	if _detail.visible and not detail_entry.is_empty():
		open_detail(detail_entry.id)


func _resize_grid() -> void:
	if is_instance_valid(_grid) and is_instance_valid(_scroll):
		_grid.columns = maxi(1, int((_scroll.size.x - 20.0) / 288.0))


func open_detail(id: String) -> void:
	var record := TextCatalog.entry(category, id)
	if record.is_empty():
		_detail.hide()
		detail_entry.clear()
		return
	detail_entry = record
	CatalogUi.clear(_detail_card)
	CatalogUi.clear(_detail_fields)
	CatalogUi.preview(_detail_card, record, category, 0.8)
	var labels: Array = TextCatalogService.MONSTER_HEADERS if category == "monsters" else TextCatalogService.CARD_HEADERS
	for i: int in TextCatalogService.ENTRY_KEYS.size():
		var value := str(record.get(TextCatalogService.ENTRY_KEYS[i], ""))
		var field := CatalogUi.label(str(labels[i]) + "\n" + (value if not value.is_empty() else "（未填写）"), 26)
		field.name = TextCatalogService.ENTRY_KEYS[i]
		field.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		_detail_fields.add_child(field)
	var state := CatalogUi.label("解锁状态\n" + ("已解锁" if TextCatalog.is_unlocked(category, id) else "未解锁"), 26)
	state.name = "unlock_state"
	_detail_fields.add_child(state)
	_detail.show()
	_detail.get_node("Panel/Content/Heading/Close").grab_focus()


func _build_detail() -> void:
	_detail = Control.new()
	_detail.name = "Detail"
	add_child(_detail)
	_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.8)
	_detail.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	var style := CatalogUi.panel_style()
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", style)
	_detail.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 120
	panel.offset_right = -120
	panel.offset_top = 80
	panel.offset_bottom = -80
	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", 24)
	panel.add_child(content)
	var heading := HBoxContainer.new()
	heading.name = "Heading"
	content.add_child(heading)
	var title := CatalogUi.label("条目详情", 36)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var close := CatalogUi.button("关闭详情", "Close")
	heading.add_child(close)
	close.pressed.connect(close_detail)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 48)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(columns)
	_detail_card = CenterContainer.new()
	_detail_card.name = "Card"
	_detail_card.custom_minimum_size = Vector2(440, 0)
	columns.add_child(_detail_card)
	var scroll := ScrollContainer.new()
	scroll.name = "Properties"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(scroll)
	_detail_fields = VBoxContainer.new()
	_detail_fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_fields.add_theme_constant_override("separation", 22)
	scroll.add_child(_detail_fields)
	_detail.hide()


func close_detail() -> void:
	_detail.hide()
	detail_entry.clear()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _detail.visible:
		close_detail()
		get_viewport().set_input_as_handled()

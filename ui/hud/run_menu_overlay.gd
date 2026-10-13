class_name RunMenuOverlay
extends Control

## 冒险菜单浮层：点头像打开，顶部三页——地图 / 背包 / 设置。
## 地图页只查看：给小地图放大倍率，可拖动镜头，但不移动角色本体。
## 背包页与设置页先占位，卡组与物品的数量取跑图状态里的真值。

signal closed
## 设置页里的三个跑图级动作，由宿主场景决定怎么落地（存档、回主菜单、退出）。
signal abandon_requested
signal return_to_menu_requested
signal quit_requested

const PAGES: Array[String] = ["地图", "背包", "设置"]
const PANEL_RECT := Rect2(260, 130, 1400, 820)
const TAB_SIZE := Vector2(180, 48)
const TAB_GAP := 24.0
const TAB_TOP := 30.0
const CONTENT_RECT := Rect2(40, 100, 1320, 680)
const DECK_COLUMNS := 6
const DECK_CARD_SCALE := 0.18
const ITEM_COLUMNS := 5
const ITEM_ROWS := 4
const ZONE_RELIC_X := 0.0
const ZONE_DECK_X := 300.0
const ZONE_DECK_WIDTH := 620.0
const ZONE_ITEM_X := 960.0
const ZONE_TITLE_HEIGHT := 44.0
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")

var _shade: ColorRect
var _panel: Panel
var _tabs: Array[Label] = []
var _tab_marks: Array[ColorRect] = []
var _pages: Array[Control] = []
var _close_label: Label
var _map_slot: Control
var _map_source: Control
var _map_placeholder: Control
var _deck_grid: GridContainer
var _deck_title: Label
var _item_title: Label
var _relic_cells: Array[Label] = []
var _abandon_button: Button
var _abandon_confirm_row: HBoxContainer
var _current_page := 1


const MENU_ACTIONS := {"menu_map": KEY_M}


static func ensure_menu_actions() -> void:
	# 菜单快捷键：Esc / Tab 用引擎自带的 ui_cancel / ui_focus_next，地图键在这里注册。
	for action in MENU_ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = MENU_ACTIONS[action]
		InputMap.action_add_event(action, key)


func _ready() -> void:
	ensure_menu_actions()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()
	set_page(_current_page)


func open(page: int = -1) -> void:
	visible = true
	if page >= 0:
		set_page(page)
	_reset_abandon_confirm()
	_refresh_data()
	move_to_front()


func current_page() -> int:
	return _current_page


func close() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func set_page(index: int) -> void:
	_current_page = clampi(index, 0, PAGES.size() - 1)
	for page_index in _pages.size():
		_pages[page_index].visible = _current_page == page_index
		_tabs[page_index].add_theme_color_override("font_color",
			Color(1, 0.913, 0.722) if _current_page == page_index else Color(0.749, 0.682, 0.553))
		_tab_marks[page_index].visible = _current_page == page_index


func set_map_viewer(viewer: Control) -> void:
	# viewer 需带 set_map()/set_actor()：地图页里是真正的 MapView 渲染，可滚轮缩放、拖动平移。
	_map_source = viewer
	if viewer == null:
		return
	viewer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_slot.add_child(viewer)
	# 有真地图就把占位撤掉，别压在图上。
	if _map_placeholder != null and is_instance_valid(_map_placeholder):
		_map_placeholder.queue_free()
		_map_placeholder = null


func _refresh_data() -> void:
	var run: RunStateMachine = null
	if GlobalState != null and GlobalState.run_active and GlobalState.current_run != null:
		run = GlobalState.current_run
	_deck_title.text = "卡组 %d" % (run.deck.size() if run != null else 0)
	_item_title.text = "背包 %d / %d" % [
		run.items.size() if run != null else 0, ITEM_COLUMNS * ITEM_ROWS]
	_reload_deck(run)
	_reload_relics()


func _reload_deck(run: RunStateMachine) -> void:
	for child in _deck_grid.get_children():
		_deck_grid.remove_child(child)
		child.queue_free()
	if run == null:
		return
	for card_id in run.deck:
		var data := _card_data(String(card_id))
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(480.0, 818.0) * DECK_CARD_SCALE
		var view: CardView = CARD_SCENE.instantiate()
		view.scale = Vector2.ONE * DECK_CARD_SCALE
		view.size = Vector2(480.0, 818.0)
		if data != null:
			view.set_card(data)
		slot.add_child(view)
		_deck_grid.add_child(slot)


func _reload_relics() -> void:
	var catalog := RelicCatalog.load_definitions()
	var board := RelicBoard.new()
	var error := board.load_from_file(catalog, RelicBoard.SAVE_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("冒险菜单读取典籍配置失败：%d" % error)
	for index in _relic_cells.size():
		var data: RelicFragmentData = catalog.get(board.cells[index]) if index < board.cells.size() else null
		var label := _relic_cells[index]
		label.text = "—" if data == null else data.display_name
		label.tooltip_text = "空格" if data == null else "%s · %s" % [data.kind_name(), data.description]
		label.add_theme_color_override("font_color",
			Color(0.66, 0.6, 0.49) if data == null else Color(0.165, 0.129, 0.094))
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.937, 0.886, 0.741) if data != null else Color(0.886, 0.831, 0.682)
		style.set_corner_radius_all(3)
		label.add_theme_stylebox_override("normal", style)


func _card_data(card_id: String) -> CardData:
	for path in ["res://data/cards/%s.tres" % card_id, "res://data/cards/test/%s.tres" % card_id]:
		if ResourceLoader.exists(path):
			return load(path) as CardData
	return null


func _build() -> void:
	_shade = ColorRect.new()
	_shade.color = Color(0, 0, 0, 0.72)
	_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.gui_input.connect(_on_shade_input)
	add_child(_shade)

	_panel = Panel.new()
	_panel.position = PANEL_RECT.position
	_panel.size = PANEL_RECT.size
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.075, 0.063, 0.985)
	style.set_border_width_all(2)
	style.border_color = Color(0.910, 0.706, 0.333, 0.9)
	style.set_corner_radius_all(12)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var total_width := PAGES.size() * TAB_SIZE.x + (PAGES.size() - 1) * TAB_GAP
	var start_x := (PANEL_RECT.size.x - total_width) * 0.5
	for index in PAGES.size():
		var tab := Label.new()
		tab.text = PAGES[index]
		tab.position = Vector2(start_x + index * (TAB_SIZE.x + TAB_GAP), TAB_TOP)
		tab.size = TAB_SIZE
		tab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tab.add_theme_font_size_override("font_size", 24)
		tab.mouse_filter = Control.MOUSE_FILTER_STOP
		tab.gui_input.connect(_on_tab_input.bind(index))
		_panel.add_child(tab)
		_tabs.append(tab)

		var mark := ColorRect.new()
		mark.color = Color(0.910, 0.706, 0.333)
		mark.position = Vector2(start_x + index * (TAB_SIZE.x + TAB_GAP), TAB_TOP + TAB_SIZE.y - 4)
		mark.size = Vector2(TAB_SIZE.x, 3)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_panel.add_child(mark)
		_tab_marks.append(mark)

	_close_label = Label.new()
	_close_label.text = "关闭"
	_close_label.position = Vector2(PANEL_RECT.size.x - 116, TAB_TOP + 6)
	_close_label.size = Vector2(96, 40)
	_close_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_close_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_close_label.add_theme_font_size_override("font_size", 20)
	_close_label.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	_close_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_close_label.gui_input.connect(_on_close_input)
	_panel.add_child(_close_label)

	for index in PAGES.size():
		var page := Control.new()
		page.position = CONTENT_RECT.position
		page.size = CONTENT_RECT.size
		page.mouse_filter = Control.MOUSE_FILTER_PASS
		_panel.add_child(page)
		_pages.append(page)

	_build_map_page(_pages[0])
	_build_bag_page(_pages[1])
	_build_settings_page(_pages[2])


func _build_map_page(page: Control) -> void:
	_map_slot = Control.new()
	_map_slot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(_map_slot)
	_map_placeholder = _label("地图占位 · 等接入跑图快照", 20, Color(0.749, 0.682, 0.553))
	_map_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_map_slot.add_child(_map_placeholder)


func _build_bag_page(page: Control) -> void:
	# 三块：典籍（左）· 卡组（中，真卡面）· 背包（右）。
	_build_relic_zone(page)
	_build_deck_zone(page)
	_build_item_zone(page)


func _zone_title(page: Control, title: Label, x: float) -> void:
	title.position = Vector2(x, 0)
	title.size = Vector2(ZONE_DECK_WIDTH, 32)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.910, 0.706, 0.333))
	page.add_child(title)


func _zone_rule(page: Control, x: float, width: float) -> void:
	var rule := ColorRect.new()
	rule.color = Color(0.910, 0.706, 0.333, 0.22)
	rule.position = Vector2(x, 34)
	rule.size = Vector2(width, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(rule)


func _build_relic_zone(page: Control) -> void:
	var title := Label.new()
	title.text = "典籍"
	_zone_title(page, title, ZONE_RELIC_X)
	_zone_rule(page, ZONE_RELIC_X, 240.0)

	var panel_height := 16.0 * 2.0 + RelicBoard.ROWS * 44.0 + (RelicBoard.ROWS - 1) * 4.0
	var paper := _slot(Vector2(240.0, panel_height), Color(0.851, 0.788, 0.639),
		Color(0.910, 0.706, 0.333, 0.25))
	paper.position = Vector2(ZONE_RELIC_X, ZONE_TITLE_HEIGHT + 8.0)
	page.add_child(paper)

	var grid := GridContainer.new()
	grid.columns = RelicBoard.COLUMNS
	grid.position = Vector2(ZONE_RELIC_X + 22.0, ZONE_TITLE_HEIGHT + 24.0)
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 4)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(grid)
	for index in RelicBoard.CELL_COUNT:
		var label := Label.new()
		label.text = "—"
		label.custom_minimum_size = Vector2(45, 44)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.clip_text = true
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 16)
		_relic_cells.append(label)
		grid.add_child(label)


func _build_deck_zone(page: Control) -> void:
	_deck_title = Label.new()
	_deck_title.text = "卡组"
	_zone_title(page, _deck_title, ZONE_DECK_X)
	_zone_rule(page, ZONE_DECK_X, ZONE_DECK_WIDTH)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(ZONE_DECK_X, ZONE_TITLE_HEIGHT + 8.0)
	scroll.size = Vector2(ZONE_DECK_WIDTH, 608.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)

	_deck_grid = GridContainer.new()
	_deck_grid.columns = DECK_COLUMNS
	_deck_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_grid.add_theme_constant_override("h_separation", 14)
	_deck_grid.add_theme_constant_override("v_separation", 14)
	_deck_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(_deck_grid)


func _build_item_zone(page: Control) -> void:
	_item_title = Label.new()
	_item_title.text = "背包"
	_zone_title(page, _item_title, ZONE_ITEM_X)
	_zone_rule(page, ZONE_ITEM_X, ITEM_COLUMNS * 62.0)

	var items := GridContainer.new()
	items.position = Vector2(ZONE_ITEM_X, ZONE_TITLE_HEIGHT + 8.0)
	items.columns = ITEM_COLUMNS
	items.add_theme_constant_override("h_separation", 6)
	items.add_theme_constant_override("v_separation", 6)
	items.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(items)
	for index in ITEM_COLUMNS * ITEM_ROWS:
		items.add_child(_slot(Vector2(56, 56), Color(0.101, 0.074, 0.047, 0.62),
			Color(0.910, 0.706, 0.333, 0.38)))


func _build_settings_page(page: Control) -> void:
	var rows := [["音乐", "music_volume"], ["音效", "sfx_volume"]]
	for index in rows.size():
		var label := _label(rows[index][0], 18, Color(0.749, 0.682, 0.553))
		label.position = Vector2(400, 14 + index * 64)
		label.size = Vector2(120, 28)
		page.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = _setting(String(rows[index][1]), 0.7)
		slider.custom_minimum_size = Vector2(320, 24)
		slider.position = Vector2(520, 16 + index * 64)
		slider.focus_mode = Control.FOCUS_NONE
		slider.value_changed.connect(_on_volume_changed.bind(String(rows[index][1])))
		page.add_child(slider)
		var readout := _label("%d%%" % roundi(slider.value * 100.0), 16, Color(0.749, 0.682, 0.553))
		readout.position = Vector2(856, 16 + index * 64)
		readout.size = Vector2(80, 28)
		page.add_child(readout)
		slider.value_changed.connect(func(value: float) -> void:
			readout.text = "%d%%" % roundi(value * 100.0))

	var divider := ColorRect.new()
	divider.color = Color(0.910, 0.706, 0.333, 0.28)
	divider.position = Vector2(400, 156)
	divider.size = Vector2(520, 1)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(divider)

	var actions := [
		["退回主菜单", return_to_menu_requested, false],
		["退出游戏", quit_requested, false],
	]
	for index in actions.size():
		var button := Button.new()
		button.text = String(actions[index][0])
		button.position = Vector2(520, 208 + index * 72)
		button.size = Vector2(280, 56)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 20)
		button.add_theme_color_override("font_color", Color(0.949, 0.890, 0.776))
		button.add_theme_color_override("font_hover_color", Color(1.0, 0.914, 0.722))
		button.add_theme_stylebox_override("normal", _button_style(
			Color(0.141, 0.102, 0.075, 0.92), Color(0.910, 0.706, 0.333, 0.50)))
		button.add_theme_stylebox_override("hover", _button_style(
			Color(0.349, 0.220, 0.161, 1.0), Color(0.949, 0.749, 0.361, 1.0)))
		button.add_theme_stylebox_override("pressed", _button_style(
			Color(0.349, 0.220, 0.161, 1.0), Color(0.949, 0.749, 0.361, 1.0)))
		var requested: Signal = actions[index][1]
		button.pressed.connect(func() -> void:
			close()
			requested.emit())
		page.add_child(button)

	_build_abandon_row(page)


func _build_abandon_row(page: Control) -> void:
	_abandon_button = Button.new()
	_abandon_button.text = "放弃本局"
	_abandon_button.position = Vector2(520, 208 + 2 * 72)
	_abandon_button.size = Vector2(280, 56)
	_abandon_button.focus_mode = Control.FOCUS_NONE
	_abandon_button.add_theme_font_size_override("font_size", 20)
	_abandon_button.add_theme_color_override("font_color", Color(1.0, 0.769, 0.690))
	_abandon_button.add_theme_color_override("font_hover_color", Color(1.0, 0.85, 0.8))
	_abandon_button.add_theme_stylebox_override("normal", _button_style(
		Color(0.141, 0.102, 0.075, 0.92), Color(0.910, 0.706, 0.333, 0.50)))
	_abandon_button.add_theme_stylebox_override("hover", _button_style(
		Color(0.349, 0.220, 0.161, 1.0), Color(0.949, 0.749, 0.361, 1.0)))
	_abandon_button.add_theme_stylebox_override("pressed", _button_style(
		Color(0.349, 0.220, 0.161, 1.0), Color(0.949, 0.749, 0.361, 1.0)))
	_abandon_button.pressed.connect(_on_abandon_pressed)
	page.add_child(_abandon_button)

	# 二次确认就在设置面板里完成，不再另弹窗。
	_abandon_confirm_row = HBoxContainer.new()
	_abandon_confirm_row.position = Vector2(520, 208 + 2 * 72)
	_abandon_confirm_row.add_theme_constant_override("separation", 12)
	_abandon_confirm_row.visible = false
	page.add_child(_abandon_confirm_row)
	var confirm := Button.new()
	confirm.text = "确认放弃"
	confirm.custom_minimum_size = Vector2(160, 56)
	confirm.focus_mode = Control.FOCUS_NONE
	confirm.add_theme_font_size_override("font_size", 20)
	confirm.add_theme_color_override("font_color", Color(1.0, 0.769, 0.690))
	confirm.add_theme_stylebox_override("normal", _button_style(
		Color(0.290, 0.102, 0.086, 0.95), Color(0.949, 0.749, 0.361, 0.8)))
	confirm.add_theme_stylebox_override("hover", _button_style(
		Color(0.420, 0.145, 0.125, 1.0), Color(0.949, 0.749, 0.361, 1.0)))
	confirm.pressed.connect(func() -> void:
		close()
		abandon_requested.emit())
	_abandon_confirm_row.add_child(confirm)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.custom_minimum_size = Vector2(108, 56)
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.add_theme_font_size_override("font_size", 20)
	cancel.add_theme_color_override("font_color", Color(0.949, 0.890, 0.776))
	cancel.add_theme_stylebox_override("normal", _button_style(
		Color(0.141, 0.102, 0.075, 0.92), Color(0.910, 0.706, 0.333, 0.50)))
	cancel.add_theme_stylebox_override("hover", _button_style(
		Color(0.349, 0.220, 0.161, 1.0), Color(0.949, 0.749, 0.361, 1.0)))
	cancel.pressed.connect(_reset_abandon_confirm)
	_abandon_confirm_row.add_child(cancel)


func _on_abandon_pressed() -> void:
	_abandon_button.visible = false
	_abandon_confirm_row.visible = true


func _reset_abandon_confirm() -> void:
	if _abandon_button != null:
		_abandon_button.visible = true
	if _abandon_confirm_row != null:
		_abandon_confirm_row.visible = false

func _setting(key: String, fallback: float) -> float:
	if GlobalState != null:
		return float(GlobalState.settings.get(key, fallback))
	return fallback


func _on_volume_changed(value: float, key: String) -> void:
	if GlobalState != null:
		GlobalState.set_setting(key, value)


func _button_style(color: Color, edge: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_border_width_all(1)
	style.border_color = edge
	style.set_corner_radius_all(6)
	return style


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _slot(size: Vector2, color: Color, edge: Color) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_border_width_all(1)
	style.border_color = edge
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _on_shade_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()


func _on_close_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()


func _on_tab_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		set_page(index)



class_name RunMenuOverlay
extends Control

## 冒险菜单浮层：点头像打开背包，点右上角齿轮打开设置，点小地图打开地图页，M 键也进地图。
## 三个页面用 open(page) 直接指定，不再在面板里摆分页按钮。
## 地图页只查看：给小地图放大倍率，可拖动镜头，但不移动角色本体。
## 背包页与设置页先占位，卡组与物品的数量取跑图状态里的真值。

signal closed
## 设置页里的三个跑图级动作，由宿主场景决定怎么落地（存档、回主菜单、退出）。
signal abandon_requested
signal return_to_menu_requested
signal quit_requested

const PAGES: Array[String] = ["地图", "背包", "设置"]
const PANEL_RECT := Rect2(80, 50, 1760, 980)
const CONTENT_RECT := Rect2(40, 92, 1680, 860)
const DECK_COLUMNS := 5
const DECK_ROWS := 3
const DECK_CARD_SCALE := 0.2917
const DECK_CARD_SIZE := Vector2(140, 240)
const DECK_GAP := 6.0
const ITEM_COLUMNS := 7
const ITEM_VISIBLE_ROWS := 3
const ITEM_SLOT_SIZE := Vector2(78, 78)
const ITEM_GAP := 8.0
## 立绘比内容区更大，允许越出背包边框；右侧栏位后绘制，不会被压住。
const BAG_PORTRAIT_RECT := Rect2(-110, -30, 440, 940)
## 中栏上下两段：典籍在上、背包在下，两段左缘对齐。
## 典籍 4 列 × 5 行 96 的格子；背包 7 列 × 3 行 78 的格子，21 格一屏全见。
const BAG_RELIC_RECT := Rect2(330, 0, 612, 560)
const BAG_ITEM_RECT := Rect2(330, 566, 612, 294)
const BAG_DECK_RECT := Rect2(942, 0, 738, 860)
## 典籍格接近方形，4 列 × 5 行拼成一张整纸。
const RELIC_CELL_SIZE := Vector2(96, 96)
const RELIC_GAP := Vector2(8, 8)
const RELIC_SHEET_COLUMNS := 4
const ZONE_TITLE_HEIGHT := 44.0
const PEEK_CARD_SCALE := 0.79
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const PORTRAIT_TEXTURE := "res://assets/chr/CHR-001/IMG_20261012_212919.png"
const PORTRAIT_REGION := Rect2(164, 48, 742, 1856)
const RELIC_SCRAP_DIR := "res://assets/ui/UI-020"
const ITEM_ICON_SCRIPT := "res://ui/components/item_icon.gd"
const HOVER_TIP_SCRIPT := "res://ui/components/hover_tip.gd"
## 立绘越出面板左/下边框，是刻意的出血。
## 每张 UI-020 都画在同一张 773×951 画布上，内容只占一个格子；按各自墨迹裁切。
## 画布本身是 4 列×5 行，拼回去必须按 4 列排，否则接缝错位。
const RELIC_SCRAP_REGIONS: Array[Rect2] = [
	Rect2(23, 18, 199, 199), Rect2(201, 18, 201, 197), Rect2(388, 18, 193, 194),
	Rect2(560, 18, 195, 196), Rect2(23, 191, 199, 207), Rect2(201, 191, 199, 204),
	Rect2(381, 192, 201, 202), Rect2(565, 194, 190, 196), Rect2(23, 373, 196, 200),
	Rect2(194, 376, 209, 201), Rect2(384, 376, 192, 197), Rect2(560, 375, 195, 196),
	Rect2(23, 555, 193, 206), Rect2(199, 556, 202, 202), Rect2(381, 558, 202, 198),
	Rect2(565, 553, 190, 201), Rect2(23, 741, 185, 188), Rect2(192, 742, 202, 187),
	Rect2(378, 735, 206, 194), Rect2(572, 735, 183, 194),
]
const SLOT_FRAME_A := "res://assets/ui/UI-004/物品边框1.png"
const SLOT_FRAME_B := "res://assets/ui/UI-004/物品边框2.png"

var _shade: ColorRect
var _panel: Panel
var _page_title: Label
var _pages: Array[Control] = []
var _close_label: Label
var _map_slot: Control
var _map_source: Control
var _map_placeholder: Control
var _deck_grid: GridContainer
var _deck_scroll: ScrollContainer
var _peek_layer: Control
var _peek_view: CardView
var _deck_title: Label
var _item_tip: Control
var _item_grid: GridContainer
var _item_title: Label
var _relic_title: Label
var _relic_cells: Array[Label] = []
var _abandon_button: Button
var _abandon_confirm_row: HBoxContainer
var _current_page := 1
var _open_tween: Tween
## 测试装配用：非空时背包页读它，不读 GlobalState，也不落存档。
var run_override: RunStateMachine = null


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
	# 战斗里出牌区的卡片用了 1..10 的 z_index，浮层必须压在它们上面。
	z_index = 100
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
	_play_open_animation()


func _play_open_animation() -> void:
	# 打开时整层淡入 + 面板从 97% 弹回原大，别硬切。
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	modulate.a = 0.0
	_panel.pivot_offset = PANEL_RECT.size * 0.5
	_panel.scale = Vector2(0.97, 0.97)
	_open_tween = create_tween()
	_open_tween.set_parallel(true)
	_open_tween.tween_property(self, "modulate:a", 1.0, 0.16)
	_open_tween.tween_property(_panel, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func current_page() -> int:
	return _current_page


func close() -> void:
	if _peek_layer != null:
		_peek_layer.visible = false
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func set_page(index: int) -> void:
	_current_page = clampi(index, 0, PAGES.size() - 1)
	for page_index in _pages.size():
		var page: Control = _pages[page_index]
		var active := _current_page == page_index
		page.visible = active
		if active and is_inside_tree():
			# 换页淡一下，切页比硬切更容易看清"换了什么"。
			page.modulate.a = 0.0
			var tween := page.create_tween()
			tween.tween_property(page, "modulate:a", 1.0, 0.14)
	if _page_title != null:
		_page_title.text = PAGES[_current_page]


func set_run_override(run: RunStateMachine) -> void:
	run_override = run
	_refresh_data()


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
	var run: RunStateMachine = run_override
	if run == null and GlobalState != null and GlobalState.run_active and GlobalState.current_run != null:
		run = GlobalState.current_run
	_deck_title.text = "卡组 %d" % (run.deck.size() if run != null else 0)
	_item_title.text = "背包 %d / %d" % [
		run.items.size() if run != null else 0,
		ITEM_COLUMNS * ITEM_VISIBLE_ROWS]
	_reload_deck(run)
	_reload_relics()
	_reload_items(run)


func _reload_deck(run: RunStateMachine) -> void:
	for child in _deck_grid.get_children():
		_deck_grid.remove_child(child)
		child.queue_free()
	var card_count := run.deck.size() if run != null else 0
	# 一页固定 4×4：没有牌也把空槽画出来，页面结构不塌。
	var slot_count := maxi(DECK_COLUMNS * DECK_ROWS, card_count)
	for index in slot_count:
		var slot := Control.new()
		slot.custom_minimum_size = DECK_CARD_SIZE
		slot.size = DECK_CARD_SIZE
		slot.clip_contents = true
		if run != null and index < card_count:
			var card_id := String(run.deck[index])
			var data := _card_data(card_id)
			var view: CardView = CARD_SCENE.instantiate()
			view.scale = Vector2.ONE * DECK_CARD_SCALE
			view.size = Vector2(480.0, 818.0)
			if data != null:
				view.set_card(data)
			var deck_px := CardView.text_px_for(DECK_CARD_SCALE)
			view.apply_compact_layout(DECK_CARD_SCALE, deck_px.x, deck_px.y)
			slot.add_child(view)
			# 卡组里的牌点一下看大图。
			var peek := Button.new()
			peek.flat = true
			peek.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			peek.tooltip_text = "点击查看大图"
			peek.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			peek.pressed.connect(_peek_card.bind(card_id))
			slot.add_child(peek)
		else:
			_add_deck_empty(slot)
		_deck_grid.add_child(slot)


func _add_deck_empty(slot: Control) -> void:
	var panel := Panel.new()
	panel.size = DECK_CARD_SIZE
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.075, 0.06, 0.55)
	style.border_color = Color(0.45, 0.37, 0.22, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)
	slot.add_child(panel)


func _build_peek() -> void:
	# 卡组大图：压暗整屏 + 0.62 倍卡面，点任意处关闭。
	_peek_layer = Control.new()
	_peek_layer.name = "PeekLayer"
	_peek_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_peek_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_peek_layer.z_index = 130
	_peek_layer.visible = false
	add_child(_peek_layer)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.018, 0.016, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_peek_layer.visible = false)
	_peek_layer.add_child(shade)
	_peek_view = CARD_SCENE.instantiate()
	_peek_view.scale = Vector2.ONE * PEEK_CARD_SCALE
	_peek_view.position = (Vector2(1920.0, 1080.0) - Vector2(480.0, 818.0) * PEEK_CARD_SCALE) * 0.5
	_peek_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_peek_layer.add_child(_peek_view)


func _peek_card(card_id: String) -> void:
	var data := _card_data(card_id)
	if data == null:
		return
	_peek_view.set_card(data)
	# 大图与外面的卡是同一份预制件：只是 scale 不同，不重新排字。
	_peek_view.apply_compact_layout(PEEK_CARD_SCALE)
	_peek_layer.visible = true
	_peek_layer.modulate.a = 0.0
	_peek_layer.create_tween().tween_property(_peek_layer, "modulate:a", 1.0, 0.12)


func _reload_items(run: RunStateMachine) -> void:
	for child in _item_grid.get_children():
		_item_grid.remove_child(child)
		child.queue_free()
	var item_count := run.items.size() if run != null else 0
	# 无限背包：至少铺满两排 10 列，装得更多就继续往下长。
	var slot_count := maxi(ITEM_COLUMNS * ITEM_VISIBLE_ROWS, item_count)
	for index in slot_count:
		var slot := Control.new()
		slot.custom_minimum_size = ITEM_SLOT_SIZE
		slot.size = ITEM_SLOT_SIZE
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var frame := _texture_rect(
			_slot_frame(index % 2 == 0), Vector2.ZERO, ITEM_SLOT_SIZE)
		slot.add_child(_slot_plate())
		slot.add_child(frame)
		if run != null and index < item_count:
			var item: Variant = run.items[index]
			var item_id := str(item.get("item_id", "")) if item is Dictionary else str(item)
			var record: Dictionary = _item_record(item_id, str(item.get("name", "")) if item is Dictionary else item_id)
			var icon_script := load(ITEM_ICON_SCRIPT)
			var icon: Control = icon_script.make(str(record.get("icon_path", "")), 46.0)
			icon.position = Vector2(16, 16)
			slot.add_child(icon)
			# 图标占格子，名字与效果走和战斗 HUD 同一个悬停浮层。
			slot.mouse_filter = Control.MOUSE_FILTER_STOP
			var tip := _item_tooltip(item_id, record)
			slot.mouse_entered.connect(_show_item_tip.bind(slot, tip))
			slot.mouse_exited.connect(_hide_item_tip)
		_item_grid.add_child(slot)


func _show_item_tip(anchor: Control, text: String) -> void:
	if _item_tip == null:
		var tip_script := load(HOVER_TIP_SCRIPT)
		_item_tip = tip_script.new()
		_item_tip.name = "ItemTip"
		_item_tip.z_index = 140
		add_child(_item_tip)
	_item_tip.show_for(anchor, text)


func _hide_item_tip() -> void:
	if _item_tip != null:
		_item_tip.hide_tip()


func _item_record(item_id: String, display: String = "") -> Dictionary:
	var catalog := get_node_or_null("/root/TextCatalog")
	if catalog == null:
		return {}
	var record: Dictionary = catalog.entry("items", item_id)
	if record.is_empty() and not display.is_empty():
		for entry: Dictionary in catalog.entries("items"):
			if str(entry.get("name", "")) == display:
				return entry
	return record


func _item_tooltip(item_id: String, record: Dictionary) -> String:
	var display := str(record.get("name", item_id))
	var effect := str(record.get("effect", ""))
	return display if effect.is_empty() else "%s\n%s" % [display, effect]


func _reload_relics() -> void:
	var catalog := RelicCatalog.load_definitions()
	var board := RelicBoard.new()
	var error := board.load_from_file(catalog, RelicBoard.SAVE_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("冒险菜单读取典籍配置失败：%d" % error)
	var filled := 0
	for index in _relic_cells.size():
		var data: RelicFragmentData = catalog.get(board.cells[index]) if index < board.cells.size() else null
		var label := _relic_cells[index]
		label.text = "" if data == null else data.display_name
		label.tooltip_text = "空格" if data == null else "%s · %s" % [data.kind_name(), data.description]
		if data != null:
			filled += 1
		label.add_theme_color_override("font_color",
			Color(0.23, 0.17, 0.10, 0.82) if data == null else Color(0.165, 0.129, 0.094))
	_relic_title.text = "典籍 %d / %d" % [filled, RelicBoard.CELL_COUNT]


func _card_data(card_id: String) -> CardData:
	for path in [
		"res://data/cards/%s.tres" % card_id,
		"res://data/cards/test/%s.tres" % card_id,
		"res://data/cards/%s_1.tres" % card_id,
	]:
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

	_page_title = Label.new()
	_page_title.text = PAGES[_current_page]
	_page_title.position = Vector2(0, 26)
	_page_title.size = Vector2(PANEL_RECT.size.x, 44)
	_page_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_title.add_theme_font_size_override("font_size", 30)
	_page_title.add_theme_color_override("font_color", Color(0.910, 0.706, 0.333))
	_page_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_page_title)

	var title_rule := ColorRect.new()
	title_rule.color = Color(0.910, 0.706, 0.333, 0.25)
	title_rule.position = Vector2(48, 78)
	title_rule.size = Vector2(PANEL_RECT.size.x - 96, 1)
	title_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(title_rule)

	_close_label = Label.new()
	_close_label.text = "关闭"
	_close_label.position = Vector2(PANEL_RECT.size.x - 120, 26)
	_close_label.size = Vector2(96, 44)
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

	_build_peek()
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
	var map_hint := _label("滚轮缩放 · 拖动平移", 14, Color(0.749, 0.682, 0.553, 0.7))
	map_hint.position = Vector2(CONTENT_RECT.position.x + 4.0,
		CONTENT_RECT.size.y - 26.0)
	map_hint.size = Vector2(320, 22)
	page.add_child(map_hint)


func _build_bag_page(page: Control) -> void:
	# 立绘越出边框 · 中栏上典籍下背包 · 右栏卡组。
	_build_portrait_zone(page)
	_build_relic_zone(page)
	_build_item_zone(page)
	_build_deck_zone(page)


func _zone_title(page: Control, title: Label, x: float, y: float = 0.0) -> void:
	title.position = Vector2(x, y)
	title.size = Vector2(240, 32)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.910, 0.706, 0.333))
	page.add_child(title)


func _zone_rule(page: Control, x: float, width: float, y: float = 0.0) -> void:
	var rule := ColorRect.new()
	rule.color = Color(0.910, 0.706, 0.333, 0.22)
	rule.position = Vector2(x, y + 34)
	rule.size = Vector2(width, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(rule)


func _build_portrait_zone(page: Control) -> void:
	# 只裁立绘本体，避开 1144×1974 画布四周的透明边。
	var atlas := AtlasTexture.new()
	atlas.atlas = load(PORTRAIT_TEXTURE)
	atlas.region = PORTRAIT_REGION
	var portrait := TextureRect.new()
	portrait.texture = atlas
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.position = BAG_PORTRAIT_RECT.position
	portrait.size = BAG_PORTRAIT_RECT.size
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(portrait)


func _build_item_zone(page: Control) -> void:
	_item_title = Label.new()
	_item_title.text = "背包"
	_zone_title(page, _item_title, BAG_ITEM_RECT.position.x, BAG_ITEM_RECT.position.y)
	_zone_rule(page, BAG_ITEM_RECT.position.x, BAG_ITEM_RECT.size.x,
		BAG_ITEM_RECT.position.y)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(BAG_ITEM_RECT.position.x + 4.0,
		BAG_ITEM_RECT.position.y + ZONE_TITLE_HEIGHT)
	scroll.size = Vector2(BAG_ITEM_RECT.size.x - 12.0,
		BAG_ITEM_RECT.size.y - ZONE_TITLE_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	page.add_child(scroll)

	_item_grid = GridContainer.new()
	_item_grid.columns = ITEM_COLUMNS
	_item_grid.add_theme_constant_override("h_separation", int(ITEM_GAP))
	_item_grid.add_theme_constant_override("v_separation", int(ITEM_GAP))
	_item_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(_item_grid)


func _build_relic_zone(page: Control) -> void:
	var grid_width := RELIC_CELL_SIZE.x * RELIC_SHEET_COLUMNS \
		+ RELIC_GAP.x * (RELIC_SHEET_COLUMNS - 1)
	var grid_x := BAG_RELIC_RECT.position.x \
		+ (BAG_RELIC_RECT.size.x - grid_width) * 0.5
	_relic_title = Label.new()
	_relic_title.text = "典籍"
	_zone_title(page, _relic_title, grid_x)
	_zone_rule(page, grid_x, grid_width)

	var grid := GridContainer.new()
	grid.columns = RELIC_SHEET_COLUMNS
	grid.position = Vector2(grid_x, ZONE_TITLE_HEIGHT)
	grid.add_theme_constant_override("h_separation", int(RELIC_GAP.x))
	grid.add_theme_constant_override("v_separation", int(RELIC_GAP.y))
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(grid)
	for index in RelicBoard.CELL_COUNT:
		var cell := Control.new()
		cell.custom_minimum_size = RELIC_CELL_SIZE
		cell.size = RELIC_CELL_SIZE
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(_texture_rect(_relic_scrap(index + 1), Vector2.ZERO, RELIC_CELL_SIZE))
		var label := Label.new()
		label.text = "—"
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.clip_text = true
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 21)
		_relic_cells.append(label)
		cell.add_child(label)
		grid.add_child(cell)


func _build_deck_zone(page: Control) -> void:
	_deck_title = Label.new()
	_deck_title.text = "卡组"
	_zone_title(page, _deck_title, BAG_DECK_RECT.position.x)
	_zone_rule(page, BAG_DECK_RECT.position.x, BAG_DECK_RECT.size.x)

	_deck_scroll = ScrollContainer.new()
	_deck_scroll.position = Vector2(BAG_DECK_RECT.position.x + 2.0, ZONE_TITLE_HEIGHT)
	# 只露整 3 行，避免第 4 行露出半截像被裁；剩下用滚轮。
	var deck_rows_height := DECK_CARD_SIZE.y * 3.0 + DECK_GAP * 2.0
	_deck_scroll.size = Vector2(BAG_DECK_RECT.size.x - 4.0,
		minf(BAG_DECK_RECT.size.y - ZONE_TITLE_HEIGHT, deck_rows_height))
	_deck_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_deck_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	page.add_child(_deck_scroll)

	_deck_grid = GridContainer.new()
	_deck_grid.columns = DECK_COLUMNS
	_deck_grid.add_theme_constant_override("h_separation", int(DECK_GAP))
	_deck_grid.add_theme_constant_override("v_separation", int(DECK_GAP))
	_deck_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_deck_scroll.add_child(_deck_grid)


func _build_settings_page(page: Control) -> void:
	var sound_head := _label("声音", 20, Color(0.910, 0.706, 0.333, 0.85))
	sound_head.position = Vector2(580, 292)
	sound_head.size = Vector2(200, 28)
	page.add_child(sound_head)
	var rows := [["音乐", "music_volume"], ["音效", "sfx_volume"]]
	for index in rows.size():
		var label := _label(rows[index][0], 18, Color(0.749, 0.682, 0.553))
		label.position = Vector2(580, 344 + index * 64)
		label.size = Vector2(120, 28)
		page.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = _setting(String(rows[index][1]), 0.7)
		slider.custom_minimum_size = Vector2(320, 24)
		slider.position = Vector2(700, 346 + index * 64)
		slider.focus_mode = Control.FOCUS_NONE
		_skin_slider(slider)
		slider.value_changed.connect(_on_volume_changed.bind(String(rows[index][1])))
		page.add_child(slider)
		var readout := _label("%d%%" % roundi(slider.value * 100.0), 16, Color(0.749, 0.682, 0.553))
		readout.position = Vector2(1036, 346 + index * 64)
		readout.size = Vector2(80, 28)
		page.add_child(readout)
		slider.value_changed.connect(func(value: float) -> void:
			readout.text = "%d%%" % roundi(value * 100.0))

	var divider := ColorRect.new()
	divider.color = Color(0.910, 0.706, 0.333, 0.28)
	divider.position = Vector2(580, 486)
	divider.size = Vector2(520, 1)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(divider)

	var action_head := _label("对局", 20, Color(0.910, 0.706, 0.333, 0.85))
	action_head.position = Vector2(580, 514)
	action_head.size = Vector2(200, 28)
	page.add_child(action_head)

	var actions := [
		["退回主菜单", return_to_menu_requested, false],
		["退出游戏", quit_requested, false],
	]
	for index in actions.size():
		var button := Button.new()
		button.text = String(actions[index][0])
		button.position = Vector2(700, 566 + index * 72)
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


static var _grabber_texture_cache: Texture2D


static func _grabber_texture() -> Texture2D:
	# 默认滑块圆点是引擎灰白样式，和这套暗金面板不搭，这里画一颗金色圆点。
	if _grabber_texture_cache != null:
		return _grabber_texture_cache
	var side := 22
	var image := Image.create(side, side, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var center := Vector2(side, side) * 0.5
	for y in side:
		for x in side:
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(center)
			if distance > 10.0:
				continue
			image.set_pixel(x, y, Color(0.396, 0.290, 0.145) if distance > 8.0
				else Color(0.965, 0.784, 0.416))
	_grabber_texture_cache = ImageTexture.create_from_image(image)
	return _grabber_texture_cache


func _skin_slider(slider: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.078, 0.063, 0.052, 0.95)
	track.border_color = Color(0.910, 0.706, 0.333, 0.30)
	track.set_border_width_all(1)
	track.set_corner_radius_all(4)
	track.content_margin_top = 6.0
	track.content_margin_bottom = 6.0
	slider.add_theme_stylebox_override("slider", track)
	var filled := track.duplicate() as StyleBoxFlat
	filled.bg_color = Color(0.639, 0.475, 0.196, 1.0)
	filled.border_color = Color(0.910, 0.706, 0.333, 0.55)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)
	slider.add_theme_icon_override("grabber", _grabber_texture())
	slider.add_theme_icon_override("grabber_highlight", _grabber_texture())


func _build_abandon_row(page: Control) -> void:
	_abandon_button = Button.new()
	_abandon_button.text = "放弃本局"
	_abandon_button.position = Vector2(700, 710)
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
	_abandon_confirm_row.position = Vector2(700, 682)
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


func _texture_rect(texture: Texture2D, position: Vector2, size: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.position = position
	rect.size = size
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _slot_frame(dark: bool) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = load(SLOT_FRAME_B if dark else SLOT_FRAME_A)
	atlas.region = Rect2(12, 7, 708, 686) if dark else Rect2(34, 28, 665, 665)
	return atlas


## 物品格底板：边框图只有线框，空槽在深色面板上会飘，垫一块圆角深色让 24 格连成一片。
func _slot_plate() -> Panel:
	var plate := Panel.new()
	plate.position = Vector2(3, 3)
	plate.size = ITEM_SLOT_SIZE - Vector2(6, 6)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.135, 0.112, 0.088, 0.95)
	style.border_color = Color(0.910, 0.706, 0.333, 0.20)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	plate.add_theme_stylebox_override("panel", style)
	return plate


func _relic_scrap(index: int) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = load("%s/%d.png" % [RELIC_SCRAP_DIR, index])
	atlas.region = RELIC_SCRAP_REGIONS[clampi(index - 1, 0, RELIC_SCRAP_REGIONS.size() - 1)]
	return atlas


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



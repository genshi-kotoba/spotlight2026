class_name RunMenuOverlay
extends Control

## 冒险菜单浮层：点头像打开背包，点右上角齿轮打开设置，点小地图打开地图页，M 键也进地图。
## 三个页面用 open(page) 直接指定，不再在面板里摆分页按钮。
## 地图页只查看：给小地图放大倍率，可拖动镜头，但不移动角色本体。
## 背包使用 main 的真实牌组与物品，残片装配统一走 RunRewards 事务。

signal closed
signal relic_board_updated
signal potion_requested(item_id: String)
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
## 典籍格接近方形，4 列 × 5 行按原始画布顺序排列。
const RELIC_CELL_SIZE := Vector2(96, 96)
const RELIC_GAP := Vector2(8, 8)
const RELIC_SHEET_COLUMNS := 4
const ZONE_TITLE_HEIGHT := 44.0
const PEEK_CARD_SCALE := 0.79
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const PORTRAIT_TEXTURE := "res://assets/chr/CHR-001/IMG_20261012_212919.png"
const PORTRAIT_REGION := Rect2(164, 48, 742, 1856)
const ITEM_ICON_SCRIPT := "res://ui/components/item_icon.gd"
const HOVER_TIP_SCRIPT := "res://ui/components/hover_tip.gd"
const RELIC_DRAG_ITEM_SCRIPT := "res://ui/hud/relic_drag_item.gd"
const RELIC_DROP_CELL_SCRIPT := "res://ui/hud/relic_drop_cell.gd"
const ITEM_CAPACITY := ITEM_COLUMNS * ITEM_VISIBLE_ROWS # 一屏容量，不改变 main 背包规则。
## 立绘越出面板左/下边框，是刻意的出血。
const SLOT_FRAME_A := "res://assets/ui/UI-004/物品边框1.png"
const SLOT_FRAME_B := "res://assets/ui/UI-004/物品边框2.png"

var _shade: ColorRect
var _panel: Panel
var _page_title: Label
var _pages: Array[Control] = []
var _close_button: Button
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
var _relic_drop_cells: Array[RelicDropCell] = []
var _item_scroll: ScrollContainer
var _drag_ghost: Panel
var _drag_source: Control
var _drag_fragment := ""
var _drag_item_id := ""
var _drag_origin := -1
var _highlighted_cell: RelicDropCell
var _range_highlighted_cells: Array[int] = []
var _hovered_relic_cell := -1
var _relic_preview_board: RelicBoard
var _bag_highlight: Panel
var _abandon_button: Button
var _abandon_confirm_row: HBoxContainer
var _current_page := 1
var _open_tween: Tween
## 测试装配用：非空时背包页读它，不读 GlobalState，也不落存档。
var run_override: RunStateMachine = null


const MENU_ACTIONS := {"menu_map": KEY_M}


var _battle: BattleStateMachine
var _card_catalog: Dictionary = {}
var _battle_board: RelicBoard
var _resources: Label
var _bag_hint: Label
var _selected_fragment_id := ""
var _pack_popup: LootPopup


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
	z_index = 500
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
	_end_relic_drag(true)
	_selected_fragment_id = ""
	_hide_item_tip()
	if _peek_layer != null:
		_peek_layer.visible = false
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func set_page(index: int) -> void:
	_end_relic_drag(true)
	_selected_fragment_id = ""
	_hide_item_tip()
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
	_end_relic_drag(true)
	_hide_item_tip()
	var run := _active_run()
	var deck_ids: Array[String] = []
	var deck_copies: Array[Dictionary] = []
	if is_instance_valid(_battle):
		for zone: Array in [_battle.draw_pile, _battle.hand, _battle.play_zone, _battle.discard_pile]:
			for card: Dictionary in zone:
				if not bool(card.get("slot_empty", false)):
					deck_ids.append(str(card.card_id))
					deck_copies.append(card)
	elif run != null:
		run.ensure_deck_cards()
		deck_ids.assign(run.deck)
		deck_copies.assign(run.deck_cards)
	_deck_title.text = "卡组 %d" % deck_ids.size()
	_item_title.text = "背包 · %d 件" % (run.items.size() if run != null else 0)
	_reload_deck(deck_ids, deck_copies)
	_reload_relics()
	_reload_items(run)


func _reload_deck(deck_ids: Array[String], copies: Array[Dictionary] = []) -> void:
	for child in _deck_grid.get_children():
		_deck_grid.remove_child(child)
		child.queue_free()
	for index in deck_ids.size():
		var card_id: String = deck_ids[index]
		var data := _card_data(String(card_id))
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(480.0, 818.0) * DECK_CARD_SCALE
		var view: CardView = CARD_SCENE.instantiate()
		view.scale = Vector2.ONE * DECK_CARD_SCALE
		view.size = Vector2(480.0, 818.0)
		if data != null:
			view.set_card(data)
		view.apply_compact_layout(DECK_CARD_SCALE)
		view.tooltip_text = CardEnchantments.describe(copies[index]) if index < copies.size() else ""
		slot.tooltip_text = view.tooltip_text
		slot.add_child(view)
		var peek := Button.new()
		peek.flat = true
		peek.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		peek.tooltip_text = view.tooltip_text
		peek.pressed.connect(_peek_card.bind(card_id))
		slot.add_child(peek)
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
	for child: Node in _item_grid.get_children():
		_item_grid.remove_child(child)
		child.queue_free()
	var items: Array = run.items if run != null else []
	if run != null:
		RunRewards.ensure_state(run)
	_resources.text = "银币 %d  ·  万灵药 %d" % [run.gold, int(run.inventory_state.elixir)] if run != null else "银币 0  ·  万灵药 0"
	if is_instance_valid(_battle) and run != null: _resources.text = "银币 %d  ·  万灵药 %d" % [int(_battle.player.get("silver", run.gold)), int(run.inventory_state.elixir)]
	_bag_hint.text = "拖拽残片安装、换位或拖回背包；右键/Shift点击卸下。\n点击卡包打开；也可先点击残片，再点击典籍格安装。" if _can_edit_relics() else "战斗中仅查看，卡包与典籍编辑在战后开放。"
	var catalog := RelicCatalog.load_definitions()
	for index in maxi(ITEM_CAPACITY, items.size()):
		var slot: Control
		if index >= items.size():
			slot = _item_slot_empty(index)
		else:
			var item: Variant = items[index]
			var fragment: RelicFragmentData = RelicCatalog.resolve(str(item.get("fragment_id", "")), catalog) if item is Dictionary and item.get("kind") == "fragment" else null
			if fragment != null:
				slot = _relic_slot_item(fragment, index)
				slot.item_id = str(item.item_id)
			else:
				slot = _item_slot(run, index, index)
		_item_grid.add_child(slot)


func _show_item_tip(anchor: Control, text: String, rich: bool = false) -> void:
	if _drag_ghost != null:
		return
	if _item_tip == null:
		var tip_script := load(HOVER_TIP_SCRIPT)
		_item_tip = tip_script.new()
		_item_tip.name = "ItemTip"
		_item_tip.z_index = 140
		add_child(_item_tip)
	_item_tip.show_for(anchor, text, rich)


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
	_clear_relic_range()
	_hovered_relic_cell = -1
	var catalog := RelicCatalog.load_definitions()
	var board := _battle_board if _battle_board != null else (RunRewards.board_for_run(_active_run()) if _active_run() != null else RelicBoard.new())
	_relic_preview_board = board
	var filled := 0
	for index in _relic_cells.size():
		var data: RelicFragmentData = RelicCatalog.resolve(board.cells[index], catalog) if index < board.cells.size() else null
		var label := _relic_cells[index]
		label.text = "" if data == null else data.display_name
		# 悬停文案挂在格子上，格子建的时候已经连好浮层，这里只换内容。
		var cell := label.get_parent() as RelicDropCell
		if cell != null:
			cell.fragment_id = "" if data == null else data.fragment_id
			cell.editable = _can_edit_relics()
			cell.set_unlocked(board.is_unlocked(index))
			cell.set_meta("relic_tip", "" if data == null else data.rich_text(20))
			var piece := cell.get_node_or_null("PieceArt") as TextureRect
			if piece != null:
				piece.modulate = data.tint().lightened(0.35) if data != null else Color.WHITE
		if data != null:
			filled += 1
		label.add_theme_color_override("font_color",
			Color(0.23, 0.17, 0.10, 0.82) if data == null else data.tint())
		label.add_theme_color_override("font_outline_color", Color(0.09, 0.07, 0.05, 0.95))
		label.add_theme_constant_override("outline_size", 0 if data == null else 3)
	_relic_title.text = "典籍 %d / %d" % [filled, RelicBoard.CELL_COUNT]


## 拖拽中的残片：幽灵块跟手、落点高亮、松手落格。全部按屏幕坐标算，
## 因为幽灵块挂在浮层上，而格子挂在面板里的 GridContainer 上。


func _card_data(card_id: String) -> CardData:
	if _card_catalog.is_empty():
		var formal := FormalCardCatalog.load_definitions()
		if formal.error == OK:
			_card_catalog.merge(formal.cards)
		for path: String in BattleEffectResolver._resource_paths("res://data/cards"):
			var card := load(path) as CardData
			if card != null and not _card_catalog.has(str(card.card_id)):
				_card_catalog[str(card.card_id)] = card
	return _card_catalog.get(card_id)


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
	var style := CommonUiSkin.panel("panel")
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

	_close_button = Button.new()
	_close_button.name = "CloseMenu"
	_close_button.text = "关闭"
	CommonUiSkin.style_navigation_button(_close_button, "close", true)
	_close_button.position = Vector2(PANEL_RECT.size.x - 96, 20)
	_close_button.size = Vector2(64, 56)
	_close_button.pressed.connect(close)
	_panel.add_child(_close_button)

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

	_resources = _label("", 20, Color(0.949, 0.89, 0.776))
	# 五行典籍占满原来的上方留白，资源与提示各自留在标题行。
	_resources.position = Vector2(BAG_RELIC_RECT.position.x + 260.0, BAG_RELIC_RECT.position.y + 2.0)
	_resources.size = Vector2(BAG_RELIC_RECT.size.x - 260.0, 28)
	_resources.add_theme_font_size_override("font_size", 18)
	page.add_child(_resources)
	_bag_hint = _label("", 13, Color(0.749, 0.682, 0.553))
	_bag_hint.position = Vector2(BAG_ITEM_RECT.position.x + 166.0, BAG_ITEM_RECT.position.y + 2.0)
	_bag_hint.size = Vector2(BAG_ITEM_RECT.size.x - 166.0, 34)
	_bag_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_bag_hint)
	var scroll := ScrollContainer.new()
	_item_scroll = scroll
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
	var drop_script := load(RELIC_DROP_CELL_SCRIPT)
	for index in RelicBoard.CELL_COUNT:
		var cell: RelicDropCell = drop_script.new()
		cell.index = index
		cell.custom_minimum_size = RELIC_CELL_SIZE
		cell.size = RELIC_CELL_SIZE
		# 格子只有图和名字，名字和效果走和战斗 HUD 同一个悬停浮层。
		cell.mouse_filter = Control.MOUSE_FILTER_STOP
		cell.mouse_entered.connect(_on_relic_cell_hovered.bind(cell))
		cell.mouse_exited.connect(_on_relic_cell_hover_exited.bind(cell))
		cell.drag_requested.connect(_begin_relic_drag)
		cell.remove_requested.connect(_on_relic_remove_requested)
		var piece := _texture_rect(RelicPieceArt.slot_texture(index), Vector2.ZERO, RELIC_CELL_SIZE)
		piece.name = "PieceArt"
		cell.add_child(piece)
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
		_relic_drop_cells.append(cell)
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
		CommonUiSkin.style_button(button, Vector4.ZERO)
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
	CommonUiSkin.style_button(_abandon_button, Vector4.ZERO)
	_abandon_button.add_theme_color_override("font_color", Color(1.0, 0.769, 0.690))
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
	CommonUiSkin.style_button(confirm, Vector4.ZERO)
	confirm.add_theme_color_override("font_color", Color(1.0, 0.769, 0.690))
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
	CommonUiSkin.style_button(cancel, Vector4.ZERO)
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


func set_battle_context(battle: BattleStateMachine, catalog: Dictionary, board: RelicBoard) -> void:
	_battle = battle
	_card_catalog = catalog
	_battle_board = board


func _on_item_pressed(item_id: String) -> void:
	var active := _active_run()
	var item := RunRewards.item(active, item_id) if active != null else {}
	if item.get("kind") == "potion" and is_instance_valid(_battle):
		close()
		potion_requested.emit(item_id)
		return
	if not _can_edit_relics():
		return
	var run := _active_run()
	var selected := RunRewards.item(run, item_id)
	if selected.get("kind") == "fragment":
		_selected_fragment_id = item_id
		_bag_hint.text = "已选择残片，点击左侧典籍格安装或替换。"
	elif selected.get("kind") in RunRewards.PACKS and not is_instance_valid(_pack_popup):
		_pack_popup = LootPopup.new()
		add_child(_pack_popup)
		_pack_popup.finished.connect(_refresh_data, CONNECT_DEFERRED)
		_pack_popup.show_pack(item_id)

func _equip_selected(cell: int) -> void:
	if not _can_edit_relics() or _selected_fragment_id.is_empty():
		return
	var error := RunRewards.equip_fragment(SaveGateway.current_run(), _selected_fragment_id, cell)
	if error == OK:
		_selected_fragment_id = ""
		_refresh_data()
		relic_board_updated.emit()
	else:
		_bag_hint.text = "安装失败，未改变配置。错误码：%d" % error

func _relic_cell_input(event: InputEvent, cell: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_unmount_relic(cell)


func _item_slot_empty(index: int) -> Control:
	var slot := Control.new()
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.size = ITEM_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(_slot_plate())
	slot.add_child(_texture_rect(_slot_frame(index % 2 == 0), Vector2.ZERO, ITEM_SLOT_SIZE))
	return slot




func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _drag_ghost == null:
		return
	if event is InputEventMouseMotion:
		_highlight_relic_cell(_relic_cell_at(event.position))
		_position_relic_drag_preview(event.position)
		_highlight_bag_slot(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_drop_relic_at(event.position)
		get_viewport().set_input_as_handled()




func _in_item_zone(screen_position: Vector2) -> bool:
	if _item_scroll == null or not is_instance_valid(_item_scroll):
		return false
	return _item_scroll.get_global_rect().has_point(screen_position)


## 拖拽时给背包区域一个落点提示。
## 从典籍上拖出来的：残片接在现有物品后面，圈当前已用格数那一格；
## 从背包里拿起来的：圈它自己原来那一格，松手就回原位。
## 超过一屏时背包仍可滚动，21 格不是容量上限。


func _highlight_bag_slot(screen_position: Vector2) -> void:
	if not _in_item_zone(screen_position):
		_hide_bag_highlight()
		return
	if _drag_origin >= 0:
		var slot_count := _item_grid.get_child_count()
		if slot_count == 0:
			_hide_bag_highlight()
			return
		var used := _bag_used(_active_run())
		var slot := _item_grid.get_child(mini(used, slot_count - 1)) as Control
		if slot == null:
			_hide_bag_highlight()
			return
		_show_bag_highlight(slot.get_global_rect(), false)
		return
	# 背包里拿起来的：位置不变，圈原格。
	if _drag_source != null and is_instance_valid(_drag_source) and _drag_source is RelicDragItem:
		_show_bag_highlight((_drag_source as Control).get_global_rect(), false)
		return
	_hide_bag_highlight()




func _show_bag_highlight(rect: Rect2, full: bool) -> void:
	var panel := _ensure_bag_highlight()
	panel.global_position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", _bag_highlight_style(full))
	panel.visible = true




func _hide_bag_highlight() -> void:
	if _bag_highlight != null and is_instance_valid(_bag_highlight):
		_bag_highlight.visible = false




func _ensure_bag_highlight() -> Panel:
	if _bag_highlight != null and is_instance_valid(_bag_highlight):
		return _bag_highlight
	_bag_highlight = Panel.new()
	_bag_highlight.name = "BagHighlight"
	_bag_highlight.z_index = 130
	_bag_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_highlight.visible = false
	add_child(_bag_highlight)
	return _bag_highlight




func _bag_highlight_style(full: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(4)
	style.set_border_width_all(3)
	if full:
		style.bg_color = Color(0.88, 0.42, 0.32, 0.22)
		style.border_color = Color(0.88, 0.42, 0.32, 0.95)
	else:
		style.bg_color = Color(1.0, 0.87, 0.55, 0.20)
		style.border_color = Color(1.0, 0.87, 0.55, 0.95)
	return style


## 把某格的残片退回背包（摘下来）。Shift+点击和拖回背包都走这里。


func _relic_cell_at(screen_position: Vector2) -> int:
	for cell in _relic_drop_cells:
		if cell != null and is_instance_valid(cell) and cell.is_visible_in_tree() \
			and cell.unlocked and cell.get_global_rect().has_point(screen_position):
			return cell.index
	return -1




func _highlight_relic_cell(index: int) -> void:
	var cell: RelicDropCell = _relic_drop_cells[index] if index >= 0 and index < _relic_drop_cells.size() else null
	if cell == null or not cell.unlocked:
		cell = null
		index = -1
	if cell == _highlighted_cell:
		return
	if _highlighted_cell != null and is_instance_valid(_highlighted_cell):
		_highlighted_cell.set_highlight(false)
		_set_relic_slot_preview(_highlighted_cell, false)
	_highlighted_cell = cell
	if _highlighted_cell != null:
		_set_relic_slot_preview(_highlighted_cell, true)
	_update_relic_drag_art(index)
	_preview_relic_range(index, _drag_fragment)


func _set_relic_slot_preview(cell: RelicDropCell, previewing: bool) -> void:
	# 预览直接覆盖目标拼片，暂藏旧内容；离开后恢复，不改物品或棋盘。
	cell.get_node("PieceArt").visible = not previewing
	_relic_cells[cell.index].visible = not previewing


func _position_relic_drag_preview(screen_position: Vector2) -> void:
	if _drag_ghost == null:
		return
	if is_instance_valid(_highlighted_cell):
		_drag_ghost.global_position = _highlighted_cell.global_position
		_drag_ghost.scale = _highlighted_cell.get_global_transform().get_scale() / get_global_transform().get_scale()
	else:
		_drag_ghost.scale = Vector2.ONE
		_drag_ghost.position = screen_position - _drag_ghost.size * 0.5




func _end_relic_drag(restore: bool) -> void:
	_highlight_relic_cell(-1)
	_clear_relic_range()
	_hovered_relic_cell = -1
	_hide_bag_highlight()
	if _drag_ghost != null and is_instance_valid(_drag_ghost):
		_drag_ghost.queue_free()
	_drag_ghost = null
	if restore:
		if _drag_origin >= 0 and _drag_origin < _relic_cells.size():
			var label := _relic_cells[_drag_origin]
			label.text = str(label.get_meta("relic_tip_saved", label.text))
			label.set_meta("relic_tip_saved", "")
		elif _drag_source != null and is_instance_valid(_drag_source) and _drag_source is RelicDragItem:
			(_drag_source as RelicDragItem).set_lifted(false)
	_drag_item_id = ""
	_drag_source = null
	_drag_fragment = ""
	_drag_origin = -1


## 跟手的残片保留身份；进入可装配槽位时只替换该槽位的外形。


func _relic_drag_ghost(fragment_id: String) -> Panel:
	var catalog := RelicCatalog.load_definitions()
	var data: RelicFragmentData = RelicCatalog.resolve(fragment_id, catalog)
	var title := data.display_name if data != null else fragment_id
	var tint := data.tint() if data != null else Color(0.945, 0.867, 0.706)
	var ghost := Panel.new()
	ghost.z_index = 160
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.size = RELIC_CELL_SIZE
	ghost.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var piece := _texture_rect(RelicPieceArt.template_texture(), Vector2.ZERO, RELIC_CELL_SIZE)
	piece.name = "PieceArt"
	piece.modulate = tint.lightened(0.35)
	ghost.add_child(piece)
	var label := _label(title, 21, tint)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_outline_color", Color(0.09, 0.07, 0.05, 0.95))
	label.add_theme_constant_override("outline_size", 3)
	ghost.add_child(label)
	return ghost


func _update_relic_drag_art(index: int) -> void:
	if _drag_ghost == null or not is_instance_valid(_drag_ghost):
		return
	var piece := _drag_ghost.get_node_or_null("PieceArt") as TextureRect
	if piece != null:
		piece.texture = RelicPieceArt.slot_texture(index) if index >= 0 else RelicPieceArt.template_texture()
	_drag_ghost.set_meta("piece_slot", index)


func _clear_relic_range() -> void:
	for index in _range_highlighted_cells:
		if index >= 0 and index < _relic_drop_cells.size():
			var cell := _relic_drop_cells[index]
			if cell != null and is_instance_valid(cell):
				cell.set_range_highlight(false)
	_range_highlighted_cells.clear()


func _preview_relic_range(index: int, fragment_id: String) -> void:
	_clear_relic_range()
	if _relic_preview_board == null or not _relic_preview_board.is_unlocked(index):
		return
	var data := RelicCatalog.resolve(fragment_id)
	if data == null or data.kind != RelicFragmentData.Kind.TRIGGER:
		return
	# 只看当前残片的一跳范围，空的已解锁格也属于可影响范围。
	for neighbor in _relic_preview_board.neighbors(index, data.reach):
		if neighbor >= 0 and neighbor < _relic_drop_cells.size() \
				and _relic_preview_board.is_unlocked(neighbor):
			_relic_drop_cells[neighbor].set_range_highlight(true)
			_range_highlighted_cells.append(neighbor)


func _on_relic_cell_hovered(cell: RelicDropCell) -> void:
	if _drag_ghost != null:
		return
	_hovered_relic_cell = cell.index
	_preview_relic_range(cell.index, cell.fragment_id)
	_show_relic_tip(cell)


func _on_relic_cell_hover_exited(cell: RelicDropCell) -> void:
	_hide_item_tip()
	if _drag_ghost == null and _hovered_relic_cell == cell.index:
		_hovered_relic_cell = -1
		_clear_relic_range()


func _restore_relic_hover_at_pointer(screen_position: Vector2) -> void:
	if not is_inside_tree() or not is_visible_in_tree() or is_queued_for_deletion() \
			or _current_page != 1 or _drag_ghost != null:
		return
	var index := _relic_cell_at(screen_position)
	if index < 0:
		return
	var cell := _relic_drop_cells[index]
	if not cell.fragment_id.is_empty():
		_on_relic_cell_hovered(cell)


## 落格：从典籍格里拖来的走换位，从背包拖来的直接装。


func _show_relic_tip(cell: Control) -> void:
	var text := str(cell.get_meta("relic_tip", ""))
	if text.is_empty():
		return
	_show_item_tip(cell, text, true)




func _relic_slot_item(fragment: RelicFragmentData, index: int) -> Control:
	var slot: RelicDragItem = load(RELIC_DRAG_ITEM_SCRIPT).new()
	slot.fragment_id = fragment.fragment_id
	slot.editable = _can_edit_relics()
	slot.mouse_entered.connect(_show_item_tip.bind(slot, fragment.rich_text(20), true))
	slot.mouse_exited.connect(_hide_item_tip)
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.size = ITEM_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.mouse_default_cursor_shape = Control.CURSOR_DRAG
	slot.drag_requested.connect(_begin_relic_drag)
	slot.add_child(_slot_plate())
	slot.add_child(_texture_rect(_slot_frame(index % 2 == 0), Vector2.ZERO, ITEM_SLOT_SIZE))
	var piece := _texture_rect(RelicPieceArt.template_texture(), Vector2.ZERO, ITEM_SLOT_SIZE)
	piece.name = "PieceArt"
	piece.modulate = fragment.tint().lightened(0.35)
	slot.add_child(piece)
	var name_label := _label(fragment.display_name, 17, fragment.tint())
	name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.clip_text = true
	name_label.add_theme_color_override("font_outline_color", Color(0.09, 0.07, 0.05, 0.95))
	name_label.add_theme_constant_override("outline_size", 3)
	slot.set_name_label(name_label)
	slot.add_child(name_label)
	return slot




func _item_slot(run: RunStateMachine, item_index: int, slot_index: int) -> Control:
	var slot := Control.new()
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.size = ITEM_SLOT_SIZE
	slot.add_child(_slot_plate())
	slot.add_child(_texture_rect(
		_slot_frame(slot_index % 2 == 0), Vector2.ZERO, ITEM_SLOT_SIZE))
	var item: Variant = run.items[item_index]
	var item_id := str(item.get("item_id", "")) if item is Dictionary else str(item)
	var kind := str(item.get("kind", "")) if item is Dictionary else ""
	var display := str(RunRewards.NAMES.get(kind, item_id))
	if kind == "potion": display = "药水 · " + str(RunRandomEvents.POTIONS[int(item.get("potion", 0))])
	var record: Dictionary = _item_record(item_id, display)
	var icon_script := load(ITEM_ICON_SCRIPT)
	var icon: Control = icon_script.make_item(item, 46.0, str(record.get("icon_path", "")))
	icon.position = Vector2(16, 16)
	slot.add_child(icon)
	# 图标占格子，名字与效果走和战斗 HUD 同一个悬停浮层。
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	var tip := _item_tooltip(display, record)
	if kind in RunRewards.PACKS:
		tip += "\n点击打开（选项不重复，可刷新一次）"
	slot.mouse_entered.connect(_show_item_tip.bind(slot, tip))
	slot.mouse_exited.connect(_hide_item_tip)
	if kind in RunRewards.PACKS or kind == "potion":
		slot.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and (_can_edit_relics() or (kind == "potion" and is_instance_valid(_battle))):
				_on_item_pressed(item_id)
				slot.accept_event())
	return slot




func _active_run() -> RunStateMachine:
	return run_override if is_instance_valid(run_override) else SaveGateway.current_run()


func _can_edit_relics() -> bool:
	var run := _active_run()
	return run != null and run.active and run == SaveGateway.current_run() and run.current_battle == null and not is_instance_valid(_battle)


func _bag_used(run: RunStateMachine) -> int:
	return run.items.size() if run != null else 0


func _begin_relic_drag(source: Control, fragment_id: String) -> void:
	if not _can_edit_relics() or is_instance_valid(_pack_popup):
		return
	if source is RelicDropCell and not _selected_fragment_id.is_empty():
		_equip_selected(source.index)
		return
	if fragment_id.is_empty():
		return
	_end_relic_drag(true)
	_selected_fragment_id = ""
	_drag_source = source
	_drag_fragment = fragment_id
	_drag_origin = -1
	if source is RelicDropCell:
		_drag_origin = source.index
		var label := _relic_cells[_drag_origin]
		label.set_meta("relic_tip_saved", label.text)
		label.text = ""
	elif source is RelicDragItem:
		_drag_item_id = source.item_id
		_selected_fragment_id = source.item_id
		source.set_lifted(true)
	_drag_ghost = _relic_drag_ghost(fragment_id)
	add_child(_drag_ghost)
	_drag_ghost.position = get_local_mouse_position() - _drag_ghost.size * 0.5
	_highlight_relic_cell(_relic_cell_at(get_global_mouse_position()))
	_position_relic_drag_preview(get_global_mouse_position())
	_hide_item_tip()


func _drop_relic_at(screen_position: Vector2) -> void:
	var target := _relic_cell_at(screen_position)
	var fragment_id := _drag_fragment
	var item_id := _drag_item_id
	var origin := _drag_origin
	_end_relic_drag(true)
	if target >= 0:
		_selected_fragment_id = ""
		_apply_relic_drop(origin, target, fragment_id, item_id, screen_position)
	elif origin >= 0 and _in_item_zone(screen_position):
		_unmount_relic(origin)


func _apply_relic_drop(origin: int, target: int, fragment_id: String, item_id: String = "", screen_position: Vector2 = Vector2.INF) -> void:
	if not _can_edit_relics() or fragment_id.is_empty():
		return
	var run := _active_run()
	var error: Error
	if origin >= 0:
		error = RunRewards.move_fragment(run, origin, target)
	else:
		var item := RunRewards.item(run, item_id)
		if item.get("fragment_id", "") != fragment_id:
			return
		error = RunRewards.equip_fragment(run, item_id, target)
	if error != OK:
		_bag_hint.text = "装配保存失败，配置未改变。错误码：%d" % error
		return
	_refresh_data()
	relic_board_updated.emit()
	# 指针在拖拽中已经进入此格，松手后不会再发一次 mouse_entered。
	# 成功刷新后的格子保持原位置，在这里一次性恢复当前指针的悬停。
	_restore_relic_hover_at_pointer(screen_position)


func _on_relic_remove_requested(index: int) -> void:
	_unmount_relic(index)


func _unmount_relic(index: int) -> void:
	if not _can_edit_relics():
		return
	var error := RunRewards.unequip_fragment(_active_run(), index)
	if error != OK:
		_bag_hint.text = "卸下失败，配置未改变。错误码：%d" % error
		return
	_selected_fragment_id = ""
	_refresh_data()
	relic_board_updated.emit()

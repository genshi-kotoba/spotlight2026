class_name RunStatusPanel
extends Control

## 跑图与战斗共用的左上状态列：头像、金框血条、银币、万灵药、背包快捷栏、典籍面板与触发日志。
## 每一项的坐标、尺寸、贴图与字号逐条对齐 ui/battle/battle_test_scene.tscn（战斗侧为 .tscn 节点，
## 这里用代码建同一份）。改任意一侧请同步另一侧，不要只改一处。

signal menu_requested

const SANDBOX_RESOURCES := preload("res://systems/testing/sandbox_resources.gd")
const HP_BAR_RECT := Rect2(-16, 7, 444.44, 140.62)
const HP_FILL_RECT := Rect2(144, 41, 250, 26)
const HP_FILL_SLANT := 14.0
const BLOCK_MARKER_WIDTH := 16.0
const HP_NUMBER_RECT := Rect2(150, 47, 150, 28)
const BUFF_ROW_RECT := Rect2(150, 86, 380, 36)
const BUFF_ROW_SEPARATION := 8
## 血条不瞬移：短补间滑到新长度，格挡段跟着走。
const HEALTH_TRANSITION_TIME := 0.3
## 头像即入口：点开冒险菜单（地图 / 背包 / 设置）。
const PORTRAIT_HIT_RECT := Rect2(37, 11, 100, 115)
## 银币与万灵药：同一套图标 + 数字，两处只差贴图。
const COIN_RECT := Rect2(448, 36, 100, 30)
const ELIXIR_RECT := Rect2(560, 36, 100, 30)
const COUNT_ICON_SIZE := Vector2(30, 28.2)
const COUNT_LABEL_RECT := Rect2(36, 1, 64, 28)
const COUNT_FONT_SIZE := 19
const BACKPACK_PLATE_RECT := Rect2(14, 142, 310, 140)
const BACKPACK_ORIGIN := Vector2(24, 150)
const BACKPACK_SLOT := Vector2(38, 38)
const BACKPACK_STEP := 42.0
const BACKPACK_COLUMNS := 7
const BACKPACK_ROWS := 3
const RELIC_POSITION := Vector2(322, 132)
const RELIC_LOG_SIZE := Vector2(240, 72)
const BAR_BASE_TEXTURE := "res://assets/ui/UI-015/金-主角血条-主角血条底图.png"
const BAR_FRAME_TEXTURE := "res://assets/ui/UI-015/金-主角血条-金-主角血条底框.png"
const BAR_AVATAR_TEXTURE := "res://assets/ui/UI-015/金-主角血条-主角头像.png"
const COIN_TEXTURE := "res://assets/ui/UI-023/UI-023.png"
const ELIXIR_TEXTURE := "res://assets/ui/UI-028/UI-028.png"
const RESOURCE_ICON_REGION := Rect2(119, 90, 722, 678)
const BACKPACK_FRAME_A := "res://assets/ui/UI-004/物品边框1.png"
const BACKPACK_FRAME_B := "res://assets/ui/UI-004/物品边框2.png"
const BACKPACK_FRAME_REGION_A := Rect2(34, 28, 665, 665)
const BACKPACK_FRAME_REGION_B := Rect2(12, 7, 708, 686)
const BUFF_ICON_REGION := Rect2(59, 62, 754, 754)
const ITEM_ICON_SCRIPT := "res://ui/components/item_icon.gd"
const ITEM_TEXT := preload("res://ui/components/item_text.gd")
const HOVER_LIFT := preload("res://ui/components/hover_lift.gd")
const HOVER_TIP_SCRIPT := "res://ui/components/hover_tip.gd"
const USE_DISCARD_MENU_SCRIPT := "res://ui/components/use_discard_menu.gd"
const ITEM_ICON_SIZE := 26.0
const ITEM_ICON_INSET := Vector2(6, 6)
const BUFF_ICON_PATHS := {
	"poison": "res://assets/ui/UI-025/中毒.png",
	"strength": "res://assets/ui/UI-025/力量.png",
	"weak": "res://assets/ui/UI-025/虚弱.png",
}
const HP_COLOR := Color(0.756863, 0.239216, 0.262745)
const BLOCK_COLOR := Color(0.352941, 0.439216, 0.54902)
const HP_NUMBER_COLOR := Color(1.0, 0.878431, 0.847059)
const COUNT_COLOR := Color(0.909804, 0.705882, 0.333333)
const COLOR_TEXT := Color(0.949, 0.89, 0.776)

var _hp_fill: HealthFill
var _hp_block: ColorRect
var _hp_number: Label
var _buff_row: HBoxContainer
var _buff_icons: Dictionary = {}
var _coin_count: Label
var _elixir_count: Label
var _relic_book: RelicBookView
var _relic_title: Label
var _relic_log: Label
var _relic_events: Array[String] = []
var _slots: Array[Control] = []
var _item_tip = null
var _item_menu = null
var _pack_popup: LootPopup


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_hp_bar()
	_build_health()
	_build_buffs()
	_build_resources()
	_build_backpack()
	_build_relics()


func set_health(health: int, max_health: int, block: int = 0, buffs: Array = []) -> void:
	var ratio := clampf(float(health) / float(maxi(max_health, 1)), 0.0, 1.0)
	_apply_hp_ratio(ratio)
	_hp_block.visible = block > 0
	_hp_number.text = "%d/%d" % [health, max_health]
	_set_buffs(buffs, block)


func set_resources(silver: int, elixir: int, run: Node = null) -> void:
	var resource_run: Node = SaveGateway.current_run() if run == null else run
	_coin_count.text = SANDBOX_RESOURCES.text(silver, resource_run)
	_elixir_count.text = SANDBOX_RESOURCES.text(elixir, resource_run)


func set_relic_board(catalog: Dictionary, board: RelicBoard) -> void:
	if _relic_book != null:
		_relic_book.set_board(catalog, board)


func set_relic_activation_count(count: int) -> void:
	_relic_title.text = "典籍 · 生效 %d 次" % count
	_relic_title.visible = true


func set_relic_log(lines: Array) -> void:
	_relic_events.assign(lines)
	_relic_log.text = "\n".join(_relic_events)
	_relic_log.visible = not _relic_events.is_empty()


func append_relic_log(line: String) -> void:
	_relic_events.append(line)
	while _relic_events.size() > 3:
		_relic_events.pop_front()
	set_relic_log(_relic_events)


func flash_relic_cell(index: int) -> void:
	if _relic_book != null:
		_relic_book.flash_cell(index)


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.position = Vector2.ZERO
	return label


func _panel(rect: Rect2, style: StyleBoxFlat) -> Panel:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	return panel


func _plate_style(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_border_width_all(1)
	style.border_color = border
	style.set_corner_radius_all(radius)
	return style


func _atlas(path: String, region: Rect2) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = load(path)
	atlas.region = region
	return atlas


func _texture_rect(rect: Rect2, texture: Texture2D) -> TextureRect:
	var rect_node := TextureRect.new()
	rect_node.position = rect.position
	rect_node.size = rect.size
	rect_node.texture = texture
	rect_node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect_node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect_node


func _build_hp_bar() -> void:
	var bar := Control.new()
	bar.position = HP_BAR_RECT.position
	bar.size = HP_BAR_RECT.size
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	bar.add_child(_texture_rect(Rect2(Vector2.ZERO, HP_BAR_RECT.size), load(BAR_BASE_TEXTURE)))
	_hp_fill = HealthFill.new()
	_hp_fill.position = HP_FILL_RECT.position
	_hp_fill.size = HP_FILL_RECT.size
	_hp_fill.slant = HP_FILL_SLANT
	_hp_fill.fill_color = HP_COLOR
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_hp_fill)
	_hp_block = ColorRect.new()
	_hp_block.position = Vector2(HP_FILL_RECT.end.x, HP_FILL_RECT.position.y)
	_hp_block.size = Vector2(BLOCK_MARKER_WIDTH, HP_FILL_RECT.size.y)
	_hp_block.color = BLOCK_COLOR
	_hp_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_block.visible = false
	bar.add_child(_hp_block)
	bar.add_child(_texture_rect(Rect2(Vector2.ZERO, HP_BAR_RECT.size), load(BAR_FRAME_TEXTURE)))
	bar.add_child(_texture_rect(Rect2(Vector2.ZERO, HP_BAR_RECT.size), load(BAR_AVATAR_TEXTURE)))

	# 头像即入口：点开冒险菜单（地图 / 背包 / 设置）。
	var hit := Control.new()
	hit.position = PORTRAIT_HIT_RECT.position
	hit.size = PORTRAIT_HIT_RECT.size
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hit.tooltip_text = "打开冒险菜单"
	hit.gui_input.connect(_on_portrait_input)
	add_child(hit)


func _on_portrait_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		menu_requested.emit()


func _build_health() -> void:
	_hp_number = _label("0/0", 18, HP_NUMBER_COLOR)
	_hp_number.position = HP_NUMBER_RECT.position
	_hp_number.size = HP_NUMBER_RECT.size
	add_child(_hp_number)


func _apply_hp_ratio(ratio: float) -> void:
	var left := HP_FILL_RECT.position.x
	var bar_width := HP_FILL_RECT.size.x
	var fill_right := left + bar_width * ratio + HP_FILL_SLANT * ratio
	var initialized := _hp_fill.has_meta("ratio")
	var previous := float(_hp_fill.get_meta("ratio", ratio))
	_hp_fill.set_meta("ratio", ratio)
	if initialized and is_inside_tree() and not is_equal_approx(previous, ratio):
		var old_tween: Variant = _hp_fill.get_meta("tween") if _hp_fill.has_meta("tween") else null
		if old_tween is Tween and old_tween.is_valid():
			old_tween.kill()
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.set_parallel(true)
		tween.tween_property(_hp_fill, "ratio", ratio, HEALTH_TRANSITION_TIME).from_current()
		tween.tween_property(_hp_block, "offset_left", fill_right, HEALTH_TRANSITION_TIME)
		tween.tween_property(_hp_block, "offset_right",
			minf(fill_right + BLOCK_MARKER_WIDTH, left + bar_width + HP_FILL_SLANT), HEALTH_TRANSITION_TIME)
		_hp_fill.set_meta("tween", tween)
	elif not initialized:
		_hp_fill.ratio = ratio
		_hp_block.offset_left = fill_right
		_hp_block.offset_right = minf(fill_right + BLOCK_MARKER_WIDTH, left + bar_width + HP_FILL_SLANT)


func _build_buffs() -> void:
	_buff_row = HBoxContainer.new()
	_buff_row.position = BUFF_ROW_RECT.position
	_buff_row.size = BUFF_ROW_RECT.size
	_buff_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_buff_row.add_theme_constant_override("separation", BUFF_ROW_SEPARATION)
	add_child(_buff_row)


func _set_buffs(buffs: Array, block: int) -> void:
	for child in _buff_row.get_children():
		_buff_row.remove_child(child)
		child.queue_free()
	var entries: Array[Dictionary] = []
	if block > 0:
		entries.append({"text": "格挡 %d" % block, "color": Color(0.812, 0.890, 1.0),
			"edge": Color(0.561, 0.659, 0.769, 0.6)})
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		var debuff := buff_id in ["poison", "weak"]
		entries.append({
			"text": "%s %d" % [String({"poison": "中毒", "strength": "力量", "weak": "虚弱"}.get(buff_id, buff_id)),
				int(buff.get("layers", 0))],
			"color": Color(0.81, 0.89, 0.66) if debuff else COLOR_TEXT,
			"edge": Color(0.62, 0.75, 0.42, 0.6) if debuff else Color(0.910, 0.706, 0.333, 0.45),
		})
	for entry: Dictionary in entries:
		var chip := _label(String(entry["text"]), 16, Color(entry["color"]))
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.11, 0.078, 0.051, 0.78)
		style.set_corner_radius_all(13)
		style.set_border_width_all(1)
		style.border_color = Color(entry["edge"])
		style.content_margin_left = 9
		style.content_margin_right = 9
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		chip.add_theme_stylebox_override("normal", style)
		_buff_row.add_child(chip)


func _build_resources() -> void:
	var coin := _build_resource(COIN_RECT, COIN_TEXTURE)
	_coin_count = coin
	var elixir := _build_resource(ELIXIR_RECT, ELIXIR_TEXTURE)
	_elixir_count = elixir


func _build_resource(rect: Rect2, texture_path: String) -> Label:
	var holder := Control.new()
	holder.position = rect.position
	holder.size = rect.size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	holder.add_child(_texture_rect(Rect2(Vector2.ZERO, COUNT_ICON_SIZE),
		_atlas(texture_path, RESOURCE_ICON_REGION)))
	var count := _label("0", COUNT_FONT_SIZE, COUNT_COLOR)
	count.position = COUNT_LABEL_RECT.position
	count.size = COUNT_LABEL_RECT.size
	holder.add_child(count)
	return count


func _build_backpack() -> void:
	_panel(BACKPACK_PLATE_RECT,
		_plate_style(Color(0.055, 0.046, 0.038, 0.55), Color(0.91, 0.706, 0.333, 0.14), 8))
	var frames := [
		_atlas(BACKPACK_FRAME_A, BACKPACK_FRAME_REGION_A),
		_atlas(BACKPACK_FRAME_B, BACKPACK_FRAME_REGION_B),
	]
	for index in BACKPACK_COLUMNS * BACKPACK_ROWS:
		var column := index % BACKPACK_COLUMNS
		var row := index / BACKPACK_COLUMNS
		var slot := Control.new()
		slot.position = BACKPACK_ORIGIN + Vector2(BACKPACK_STEP * column, BACKPACK_STEP * row)
		slot.size = BACKPACK_SLOT
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(slot)
		var plate := Panel.new()
		plate.size = BACKPACK_SLOT
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.add_theme_stylebox_override("panel",
			_plate_style(Color(0.135, 0.112, 0.088, 0.95), Color(0.910, 0.706, 0.333, 0.20), 3))
		slot.add_child(plate)
		var frame := _texture_rect(Rect2(Vector2.ZERO, BACKPACK_SLOT), frames[index % 2])
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(frame)
		# 只动图标这一层：底板与边框原地不动，放大时不会挤到邻格。
		var art := Control.new()
		art.name = "ItemArt"
		art.position = ITEM_ICON_INSET
		art.size = Vector2(ITEM_ICON_SIZE, ITEM_ICON_SIZE)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.visible = false
		slot.add_child(art)
		# 悬停与点击一次性连好，刷新只换内容与 meta；反复 connect 会累积回调。
		slot.mouse_entered.connect(_on_slot_hover.bind(slot))
		slot.mouse_exited.connect(_hide_item_tip)
		slot.gui_input.connect(_on_slot_input.bind(slot))
		HOVER_LIFT.attach(art, slot)
		HOVER_LIFT.set_enabled(art, false)
		_slots.append(slot)


## 按背包界面同样的索引顺序填格：run.items[i] 进第 i 格，多出来的格子留空。
## 残片在场景里只糊图标不写字，名字与效果和背包内一样走悬停浮层。
func set_items(items: Array) -> void:
	var catalog := RelicCatalog.load_definitions()
	var icon_script := load(ITEM_ICON_SCRIPT)
	for index in _slots.size():
		var slot := _slots[index]
		var art: Control = slot.get_node("ItemArt")
		for extra: Node in art.get_children():
			art.remove_child(extra)
			extra.queue_free()
		art.visible = false
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.mouse_default_cursor_shape = Control.CURSOR_ARROW
		HOVER_LIFT.set_enabled(art, false)
		for key in ["item_tip", "item_tip_rich", "item_kind", "item_id"]:
			slot.remove_meta(key)
		if index >= items.size() or not (items[index] is Dictionary):
			continue
		var item: Dictionary = items[index]
		var kind := str(item.get("kind", ""))
		var item_id := str(item.get("item_id", ""))
		var rich := false
		var icon: Control
		var tip := ""
		if kind == "fragment":
			var fragment := RelicCatalog.resolve(str(item.get("fragment_id", "")), catalog)
			if fragment == null:
				continue
			icon = icon_script.make_item(item, ITEM_ICON_SIZE, "")
			icon.modulate = fragment.tint().lightened(0.35)
			tip = fragment.rich_text(20)
			rich = true
		else:
			var display := str(RunRewards.NAMES.get(kind, item_id))
			if kind == "potion":
				display = "药水 · " + str(RunRandomEvents.POTIONS[int(item.get("potion", 0))])
			var entry := ITEM_TEXT.record(item_id, display)
			icon = icon_script.make_item(item, ITEM_ICON_SIZE, str(entry.get("icon_path", "")))
			tip = ITEM_TEXT.tooltip(display, entry)
			if kind in RunRewards.PACKS:
				# 单击卡包出的是使用/丢弃的选项菜单，不是直接开包，说明里不再写点击打开。
				slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			elif kind == "potion":
				# 药水效果本身就是战斗效果，场景里点它没有可执行的结果，只做说明。
				tip += "\n战斗中可用"
		icon.name = "ItemIcon"
		icon.position = Vector2.ZERO
		art.add_child(icon)
		art.visible = true
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.set_meta("item_tip", tip)
		slot.set_meta("item_tip_rich", rich)
		slot.set_meta("item_kind", kind)
		slot.set_meta("item_id", item_id)
		HOVER_LIFT.set_enabled(art, true)


func _on_slot_hover(slot: Control) -> void:
	if slot.mouse_filter != Control.MOUSE_FILTER_STOP:
		return
	var tip := str(slot.get_meta("item_tip", ""))
	if tip.is_empty():
		return
	_show_item_tip(slot, tip, bool(slot.get_meta("item_tip_rich", false)))


func _on_slot_input(event: InputEvent, slot: Control) -> void:
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if slot.mouse_filter != Control.MOUSE_FILTER_STOP:
		return
	_open_item_menu(slot)


## 场景快捷栏的单击：和背包界面同一套选项，使用能不能点由同一份规则决定。
func _open_item_menu(slot: Control) -> void:
	var kind := str(slot.get_meta("item_kind", ""))
	var item_id := str(slot.get_meta("item_id", ""))
	if item_id.is_empty():
		return
	# 菜单就弹在格子下沿，和说明浮层是同一块地方。等 mouse_exited 收说明会有几帧重叠，
	# 所以这里在弹菜单前直接收掉。
	_hide_item_tip()
	_ensure_item_menu().show_for(slot, _item_rows(kind, item_id))


func _item_rows(kind: String, item_id: String) -> Array:
	if kind == "fragment":
		# 残片的使用是拖到典籍书上，菜单里只剩丢弃。
		return [_discard_row(item_id)]
	if kind in RunRewards.PACKS:
		return [{"label": "使用", "enabled": _run_editable(), "action": _open_pack.bind(item_id)},
			_discard_row(item_id)]
	if kind == "potion":
		# 药水效果全是战斗效果，跑图里点了没有可执行的结果，只留说明性的置灰使用。
		return [{"label": "使用", "enabled": false, "action": Callable()}, _discard_row(item_id)]
	return [_discard_row(item_id)]


func _discard_row(item_id: String) -> Dictionary:
	return {"label": "丢弃", "enabled": _run_editable(), "danger": true,
		"action": _discard_item.bind(item_id)}


func _discard_item(item_id: String) -> void:
	RunRewards.discard_item(SaveGateway.current_run(), item_id)


func _run_editable() -> bool:
	return RunRewards._can_edit(SaveGateway.current_run())


func _ensure_item_menu():
	if _item_menu == null:
		var menu_script := load(USE_DISCARD_MENU_SCRIPT)
		_item_menu = menu_script.new()
		_item_menu.name = "ItemMenu"
		_item_menu.z_index = 160
		add_child(_item_menu)
	return _item_menu


## 卡包走背包界面同一个 LootPopup、同一条 RunRewards.open_pack 生产入口，不另写一套。
func _open_pack(item_id: String) -> void:
	if is_instance_valid(_pack_popup):
		return
	_pack_popup = LootPopup.new()
	add_child(_pack_popup)
	_pack_popup.finished.connect(_on_pack_closed, CONNECT_DEFERRED)
	_pack_popup.show_pack(item_id)


func _on_pack_closed() -> void:
	var run := SaveGateway.current_run()
	set_items(run.items if run != null else [])


func _show_item_tip(anchor: Control, text: String, rich: bool = false) -> void:
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


func _build_relics() -> void:
	_relic_book = RelicBookView.new()
	_relic_book.open_requested.connect(func(): menu_requested.emit())
	_relic_book.position = RELIC_POSITION
	add_child(_relic_book)
	_relic_book.attach_tip(self, 120)

	_relic_title = _label("", 16, COLOR_TEXT)
	_relic_title.position = RELIC_POSITION + Vector2(0, -24)
	_relic_title.visible = false
	add_child(_relic_title)

	_relic_log = _label("", 16, Color(0.749, 0.682, 0.553))
	_relic_log.position = RELIC_POSITION + Vector2(0, RelicBookView.BOOK_SIZE.y + 8.0)
	_relic_log.size = RELIC_LOG_SIZE
	_relic_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_relic_log.clip_text = true
	_relic_log.visible = false
	add_child(_relic_log)


func _buff_icon(buff_id: String) -> Texture2D:
	if _buff_icons.has(buff_id):
		return _buff_icons[buff_id]
	var path: String = BUFF_ICON_PATHS.get(buff_id, "")
	if path.is_empty():
		return null
	var atlas := _atlas(path, BUFF_ICON_REGION)
	_buff_icons[buff_id] = atlas
	return atlas

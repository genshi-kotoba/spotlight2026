class_name RunStatusPanel
extends Control

## 跑图与战斗共用的左上状态列：头像、血条、buff 芯片、背包 16 格、典籍面板与触发日志。
## 坐标与尺寸与 PRG-017 的战斗界面规格一致（见 docs/12-战斗界面排版交付说明.md），
## 换场景时不要把常量抄成两份：要用这一份。

signal menu_requested

const AVATAR_POSITION := Vector2(24, 20)
const AVATAR_SIZE := Vector2(112, 112)
const HP_BAR_POSITION := Vector2(148, 36)
const HP_BAR_WIDTH := 240.0
const HP_BAR_HEIGHT := 20.0
const HP_NUMBER_POSITION := Vector2(148, 60)
const BUFF_ROW_POSITION := Vector2(236, 60)
const BUFF_ROW_SIZE := Vector2(400, 26)
const BACKPACK_ORIGIN := Vector2(24, 152)
const BACKPACK_SLOT := Vector2(40, 40)
const BACKPACK_STEP := 44.0
const BACKPACK_COLUMNS := 8
const BACKPACK_ROWS := 2
const RELIC_POSITION := Vector2(24, 268)
const RELIC_LOG_SIZE := Vector2(240, 72)
const AVATAR_TEXTURE := "res://assets/ui/UI-015/金-主角血条-主角头像.png"
const AVATAR_REGION := Rect2(400, 190, 640, 630)
const BLOCK_MARKER_WIDTH := 16.0
const HP_COLOR := Color(0.756863, 0.239216, 0.262745)
const COLOR_TEXT := Color(0.949, 0.89, 0.776)
const COLOR_PLAYER := Color(0.812, 0.890, 1.0)
const COLOR_ENEMY := Color(1.0, 0.769, 0.690)

var _hp_fill: ColorRect
var _hp_block: ColorRect
var _hp_number: Label
var _buff_row: HBoxContainer
var _relic_book: RelicBookView
var _relic_log: Label
var _relic_events: Array[String] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_avatar()
	_build_health()
	_build_buffs()
	_build_backpack()
	_build_relics()


func set_health(health: int, max_health: int, block: int = 0, buffs: Array = []) -> void:
	var ratio := clampf(float(health) / float(maxi(max_health, 1)), 0.0, 1.0)
	_hp_fill.offset_left = 1.0
	_hp_fill.offset_right = 1.0 + (HP_BAR_WIDTH - 2.0) * ratio
	_hp_block.visible = block > 0
	_hp_block.offset_left = _hp_fill.offset_right
	_hp_block.offset_right = minf(_hp_fill.offset_right + BLOCK_MARKER_WIDTH, HP_BAR_WIDTH - 1.0)
	_hp_number.text = "%d/%d" % [health, max_health]
	_set_buffs(buffs, block)


func set_relic_board(catalog: Dictionary, board: RelicBoard) -> void:
	if _relic_book != null:
		_relic_book.set_board(catalog, board)


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
	label.position = Vector2.ZERO
	return label


func _panel(position: Vector2, size: Vector2, color: Color, radius: int = 0) -> Panel:
	var panel := Panel.new()
	panel.position = position
	panel.size = size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = color
	if radius > 0:
		style.set_corner_radius_all(radius)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	return panel


func _build_avatar() -> void:
	var avatar := _panel(AVATAR_POSITION, AVATAR_SIZE, Color(0.13, 0.102, 0.063, 0.5), 56)
	var ring := StyleBoxFlat.new()
	ring.draw_center = false
	ring.set_border_width_all(1)
	ring.border_color = Color(0.788, 0.725, 0.561, 0.6)
	ring.set_corner_radius_all(56)
	var holder := avatar as Panel
	holder.add_theme_stylebox_override("panel", ring)
	var atlas := AtlasTexture.new()
	atlas.atlas = load(AVATAR_TEXTURE)
	atlas.region = AVATAR_REGION
	var portrait := TextureRect.new()
	portrait.texture = atlas
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.position = Vector2(4, 4)
	portrait.size = AVATAR_SIZE - Vector2(8, 8)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar.add_child(portrait)

	# 头像即入口：点开冒险菜单（地图 / 背包 / 设置）。
	var hit := Button.new()
	hit.flat = true
	hit.position = AVATAR_POSITION
	hit.size = AVATAR_SIZE
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hit.tooltip_text = "打开冒险菜单"
	hit.pressed.connect(func() -> void: menu_requested.emit())
	add_child(hit)


func _build_health() -> void:
	var board := _panel(HP_BAR_POSITION, Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT),
		Color(0.086, 0.059, 0.039), 3)
	var board_style := StyleBoxFlat.new()
	board_style.bg_color = Color(0.086, 0.059, 0.039)
	board_style.set_border_width_all(1)
	board_style.border_color = Color(0.910, 0.706, 0.333, 0.5)
	board_style.set_corner_radius_all(3)
	var board_panel := board as Panel
	board_panel.add_theme_stylebox_override("panel", board_style)

	_hp_fill = ColorRect.new()
	_hp_fill.color = HP_COLOR
	_hp_fill.position = Vector2(1, 1)
	_hp_fill.size = Vector2(HP_BAR_WIDTH - 2.0, HP_BAR_HEIGHT - 2.0)
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.add_child(_hp_fill)

	_hp_block = ColorRect.new()
	_hp_block.color = Color(0.353, 0.439, 0.549)
	_hp_block.position = Vector2(1, 1)
	_hp_block.size = Vector2(BLOCK_MARKER_WIDTH, HP_BAR_HEIGHT - 2.0)
	_hp_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_block.visible = false
	board.add_child(_hp_block)

	_hp_number = _label("0/0", 18, COLOR_PLAYER)
	_hp_number.position = HP_NUMBER_POSITION
	_hp_number.size = Vector2(140, 26)
	add_child(_hp_number)


func _build_buffs() -> void:
	_buff_row = HBoxContainer.new()
	_buff_row.position = BUFF_ROW_POSITION
	_buff_row.size = BUFF_ROW_SIZE
	_buff_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_buff_row.add_theme_constant_override("separation", 6)
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


func _build_backpack() -> void:
	for index in BACKPACK_COLUMNS * BACKPACK_ROWS:
		var column := index % BACKPACK_COLUMNS
		var row := index / BACKPACK_COLUMNS
		var slot := _panel(BACKPACK_ORIGIN + Vector2(BACKPACK_STEP * column, BACKPACK_STEP * row),
			BACKPACK_SLOT, Color(0.101, 0.074, 0.047, 0.62), 4)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.101, 0.074, 0.047, 0.62) if index % 7 != 0 else Color(0.275, 0.204, 0.118, 0.7)
		style.set_border_width_all(1)
		style.border_color = Color(0.910, 0.706, 0.333, 0.38)
		style.set_corner_radius_all(4)
		var slot_panel := slot as Panel
		slot_panel.add_theme_stylebox_override("panel", style)


func _build_relics() -> void:
	_relic_book = RelicBookView.new()
	_relic_book.open_requested.connect(func(): menu_requested.emit())
	_relic_book.position = RELIC_POSITION
	add_child(_relic_book)
	_relic_book.attach_tip(self, 120)

	_relic_log = _label("", 16, Color(0.749, 0.682, 0.553))
	_relic_log.position = Vector2(RELIC_POSITION.x,
		RELIC_POSITION.y + RelicBookView.BOOK_SIZE.y + 8.0)
	_relic_log.size = RELIC_LOG_SIZE
	_relic_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_relic_log.clip_text = true
	_relic_log.visible = false
	add_child(_relic_log)

class_name RelicBookView
extends Control

## 战斗与探索共用的典籍书：UI-026 书页 + 4×5 残片格。
## 只负责展示，不处理拖放；详细名称与效果走提示，编排在典籍页和背包页完成。

const BOOK_SIZE := Vector2(140, 181)
const BOOK_TEXTURE := "res://assets/ui/UI-026/UI-026.png"
const GRID_ORIGIN := Vector2(57, 30)
const CELL_SIZE := Vector2(18, 26)
const GRID_COLUMNS := 4
const GRID_ROWS := 5

var _cells: Array[Label] = []


func _ready() -> void:
	custom_minimum_size = BOOK_SIZE
	size = BOOK_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func set_board(catalog: Dictionary, board: RelicBoard) -> void:
	for index in _cells.size():
		var fragment: RelicFragmentData = null
		if board != null and index < board.cells.size():
			fragment = catalog.get(board.cells[index])
		var label := _cells[index]
		label.text = "" if fragment == null else fragment.display_name.substr(0, 1)
		label.tooltip_text = "空格" if fragment == null else "%s · %s" % [
			fragment.kind_name(), fragment.description,
		]
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.90, 0.84, 0.69, 0.92) if fragment != null else Color(0, 0, 0, 0)
		style.set_corner_radius_all(2)
		if fragment != null:
			style.set_border_width_all(1)
			style.border_color = Color(0.33, 0.24, 0.15, 0.55)
		label.add_theme_stylebox_override("normal", style)
		label.add_theme_color_override("font_color",
			Color(0.15, 0.11, 0.07) if fragment != null else Color(0, 0, 0, 0))


func flash_cell(index: int) -> void:
	if index < 0 or index >= _cells.size():
		return
	var label := _cells[index]
	var previous: Variant = label.get_meta("flash") if label.has_meta("flash") else null
	if previous is Tween and previous.is_valid():
		previous.kill()
	label.modulate = Color(1.8, 1.8, 1.8)
	var flash := label.create_tween()
	flash.tween_property(label, "modulate", Color.WHITE, 0.45).set_trans(Tween.TRANS_SPRING)
	label.set_meta("flash", flash)


func _build() -> void:
	var book := TextureRect.new()
	book.texture = load(BOOK_TEXTURE)
	book.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	book.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	book.size = BOOK_SIZE
	book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(book)

	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.position = GRID_ORIGIN
	grid.add_theme_constant_override("h_separation", 0)
	grid.add_theme_constant_override("v_separation", 0)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(grid)
	for index in GRID_COLUMNS * GRID_ROWS:
		var label := Label.new()
		label.custom_minimum_size = CELL_SIZE
		label.size = CELL_SIZE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.clip_text = true
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.35))
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		_cells.append(label)
		grid.add_child(label)

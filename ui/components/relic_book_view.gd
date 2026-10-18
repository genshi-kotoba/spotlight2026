class_name RelicBookView
extends Control

## 战斗与跑图共用的典籍书：UI-026 书页 + 4×5 色块格。
## 没有残片的格子什么都不画，露出书页上画死的网格；装上了才铺色块。
## 色块按行列奇偶走棋盘格，和背包页的典籍格用同一套取色。
## 只负责展示，不处理拖放；编排在背包页完成。

const BOOK_SIZE := Vector2(140, 181)
const BOOK_TEXTURE := "res://assets/ui/UI-026/UI-026.png"
const TRIGGER_COLOR := Color("d1a55b")
const SUPPORT_COLOR := Color("71b8cb")
const OUTLINE_COLOR := Color(0.235, 0.169, 0.102, 0.6)
const HOVER_TINT := Color(1.0, 0.96, 0.86, 0.22)
const HOVER_OUTLINE := Color(1.0, 0.94, 0.76, 0.9)
const FLASH_TINT := Color(1.0, 0.97, 0.84)
## 触发特效一次走完的时间，和落点高亮的时长对齐。
const FLASH_TIME := 0.55
## 鼠标掠过格缝时不要立刻收浮层，否则一格一格地闪。
const HIDE_DELAY := 0.08

## 悬停浮层由宿主给，组件自己不管层级。
var hover_tip: HoverTip = null

var _book_size := BOOK_SIZE
var _texture: Texture2D = load(BOOK_TEXTURE)
var _names := PackedStringArray()
var _tips := PackedStringArray()
var _flash := PackedFloat32Array()
var _flash_tweens := {}
var _hovered := -1
var _hide_timer: Timer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_clear_cells()
	_apply_size()
	_hide_timer = Timer.new()
	_hide_timer.one_shot = true
	_hide_timer.wait_time = HIDE_DELAY
	_hide_timer.timeout.connect(_hide_tip)
	add_child(_hide_timer)


## 建悬停浮层并接到书上。格子是斜四边形，没有 Control 可以当锚点，
## 浮层只能按矩形定位，所以挂成兄弟节点、靠 z_index 压在界面上层。
func attach_tip(parent: Node, z: int) -> void:
	hover_tip = HoverTip.new()
	hover_tip.name = "RelicTip"
	hover_tip.z_index = z
	parent.add_child(hover_tip)


func set_board(catalog: Dictionary, board: RelicBoard) -> void:
	_clear_cells()
	for index in RelicBookGeometry.CELL_COUNT:
		var fragment_id := ""
		if board != null and index < board.cells.size():
			fragment_id = board.cells[index]
		if fragment_id.is_empty():
			continue
		var fragment: RelicFragmentData = catalog.get(fragment_id)
		if fragment == null:
			continue
		_names[index] = fragment.display_name
		_tips[index] = "%s（%s）\n%s" % [
			fragment.display_name, fragment.kind_name(), fragment.description,
		]
	queue_redraw()


func flash_cell(index: int) -> void:
	if index < 0 or index >= RelicBookGeometry.CELL_COUNT:
		return
	# 同一格连着触发两次（触发位和效果位挨着）时，新的盖掉旧的，别叠着抖。
	var previous: Tween = _flash_tweens.get(index)
	if previous != null and previous.is_valid():
		previous.kill()
	var tween := create_tween()
	_flash_tweens[index] = tween
	tween.tween_method(_set_flash.bind(index), 1.0, 0.0, FLASH_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _draw() -> void:
	draw_texture_rect(_texture, Rect2(Vector2.ZERO, _book_size), false)
	for index in RelicBookGeometry.CELL_COUNT:
		_draw_cell(index)


func _draw_cell(index: int) -> void:
	var quad := RelicBookGeometry.cell_quad(index, _book_size)
	if quad.is_empty():
		return
	var filled := not _names[index].is_empty()
	# 空格一笔不画：书页上本来就画着网格，铺色块反而把它盖掉。
	if filled:
		draw_colored_polygon(quad, cell_color(index))
		draw_polyline(_closed(quad), OUTLINE_COLOR, 1.0, true)
	if index == _hovered and filled:
		draw_colored_polygon(quad, HOVER_TINT)
		draw_polyline(_closed(quad), HOVER_OUTLINE, 1.5, true)
	if _flash.size() == RelicBookGeometry.CELL_COUNT and _flash[index] > 0.0:
		_draw_burst(quad, _flash[index])


## 触发特效：格子亮一下，同时一圈光沿格子轮廓扩出去。
func _draw_burst(quad: PackedVector2Array, energy: float) -> void:
	draw_colored_polygon(quad, Color(FLASH_TINT, energy * 0.55))
	var spread := 1.0 - energy
	draw_polyline(_closed(_scaled(quad, 1.0 + 0.55 * spread)),
		Color(FLASH_TINT, energy * 0.8), maxf(1.0, 2.5 * energy), true)
	draw_polyline(_closed(_scaled(quad, 1.0 + 0.85 * spread)),
		Color(FLASH_TINT, energy * 0.35), 1.0, true)


## 绕格子重心缩放，用来画往外扩的光圈。
func _scaled(quad: PackedVector2Array, factor: float) -> PackedVector2Array:
	var center := Vector2.ZERO
	for point in quad:
		center += point
	center /= float(quad.size())
	var result := PackedVector2Array()
	for point in quad:
		result.append(center + (point - center) * factor)
	return result


## 棋盘格取色：按行列奇偶交替。背包页的典籍格也调这个。
static func cell_color(index: int) -> Color:
	var row := index / RelicBookGeometry.COLUMNS
	var column := index % RelicBookGeometry.COLUMNS
	if (row + column) % 2 == 1:
		return Color(TRIGGER_COLOR, 0.92)
	return Color(SUPPORT_COLOR, 0.92)


func _closed(quad: PackedVector2Array) -> PackedVector2Array:
	var points := quad.duplicate()
	points.append(quad[0])
	return points


func _apply_size() -> void:
	custom_minimum_size = _book_size
	size = _book_size
	queue_redraw()


func _clear_cells() -> void:
	_names.resize(RelicBookGeometry.CELL_COUNT)
	_tips.resize(RelicBookGeometry.CELL_COUNT)
	_flash.resize(RelicBookGeometry.CELL_COUNT)
	for index in RelicBookGeometry.CELL_COUNT:
		_names[index] = ""
		_tips[index] = ""
		_flash[index] = 0.0


func _set_flash(value: float, index: int) -> void:
	_flash[index] = value
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_hovered(RelicBookGeometry.cell_at(event.position, _book_size))


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_set_hovered(-1)


func _set_hovered(index: int) -> void:
	if index == _hovered:
		return
	_hovered = index
	queue_redraw()
	if _hide_timer == null:
		return
	if index < 0 or _tips[index].is_empty():
		_hide_timer.start(HIDE_DELAY)
		return
	_hide_timer.stop()
	_show_tip(index)


func _show_tip(index: int) -> void:
	if hover_tip == null or not is_instance_valid(hover_tip):
		return
	hover_tip.show_at_rect(_cell_rect(index), _tips[index])


func _hide_tip() -> void:
	if hover_tip != null and is_instance_valid(hover_tip):
		hover_tip.hide_tip()


## 格子的外接矩形，转成全局坐标给浮层定位。
func _cell_rect(index: int) -> Rect2:
	var quad := RelicBookGeometry.cell_quad(index, _book_size, 0.0)
	var rect := Rect2(quad[0], Vector2.ZERO)
	for point in quad:
		rect = rect.expand(point)
	return Rect2(global_position + rect.position, rect.size)

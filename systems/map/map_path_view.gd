class_name MapPathView
extends Node3D

## 路径的三层显示：路线边框、路线数字、光标。
##
## 路线与光标各持一个高亮池，互不干扰。这一点是刻意拆的：
## 早先两者共用一个池子，鼠标一扫过别的格子，光标就把整条路线擦掉，
## 要等角色走到下一格才刷新回来。
##
## 高亮画在格子外沿，不铺满格面：铺满会盖住地形颜色与描边，
## 格子本身的高差就看不出来了。格面中间空出来给数字。

@export var path_color := Color(0.40, 0.85, 0.50)
@export var invalid_color := Color(0.90, 0.32, 0.32)
@export var hover_color := Color(1.00, 0.94, 0.55)

var builder: MapBuilder

var _route: MapHighlightPool
var _cursor: MapHighlightPool
var _labels: MapTileLabel


func _ready() -> void:
	_route = MapHighlightPool.new()
	_route.name = "Route"
	add_child(_route)

	_cursor = MapHighlightPool.new()
	_cursor.name = "Cursor"
	add_child(_cursor)

	_labels = MapTileLabel.new()
	_labels.name = "Labels"
	add_child(_labels)


## 由装配方注入。之后所有位置查询都走它。
func setup(p_builder: MapBuilder) -> void:
	builder = p_builder
	_route.radius = builder.outer_radius
	_cursor.radius = builder.outer_radius


## 显示一条路线。每一格标出还剩几格，终点为 0。传空数组等同于清空路线。
func show_route(path: Array[Vector2i], color: Color = path_color) -> void:
	var positions: Array[Vector3] = []
	var texts := PackedStringArray()
	var total := path.size()

	for i in total:
		positions.append(builder.world_position(path[i]))
		texts.append(str(total - 1 - i))

	_route.set_cells(positions, color)

	# 只有一格时不标数字：悬停与不可达反馈都是单格，标了是噪声
	if total >= 2:
		_labels.show_all(positions, texts, color)
	else:
		_labels.clear()


func clear_route() -> void:
	_route.clear()
	_labels.clear()


## 光标：鼠标指着的那一格。只动光标层，路线层不受影响。
func show_hover(coord: Vector2i) -> void:
	_cursor.set_cells(_single(coord), hover_color)


## 光标：这一格去不了。
func show_invalid(coord: Vector2i) -> void:
	_cursor.set_cells(_single(coord), invalid_color)


func clear_cursor() -> void:
	_cursor.clear()


func _single(coord: Vector2i) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if builder != null and builder.layout.has_tile(coord):
		out.append(builder.world_position(coord))
	return out

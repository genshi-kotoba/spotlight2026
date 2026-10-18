class_name RelicBookGeometry
extends RefCounted

## UI-026 书页上那 4×5 网格的形状。
## 美术里的书页是斜的，格子是四边形而不是矩形；而且画上的网格是手绘的，
## 每一条横线、竖线的斜率都不一样，单个四角变换压不住。
## 所以这里直接存 5 条竖线 + 6 条横线的两个端点，格子取相邻线的交点。
## 只算形状，不碰残片数据，也不负责绘制。

const COLUMNS := 4
const ROWS := 5
const CELL_COUNT := COLUMNS * ROWS
const ART_SIZE := Vector2(670, 863)
## 色块四边各收一点，留出画上的格线；贴死会把书页糊成一块色板。
const CELL_INSET := 0.05

## 5 条竖线，每条两个端点（上、下），按列序排：左边界、三条内线、右边界。
## 单位是 UI-026 的源图像素，点可以落在格线两端之外，取的是直线交点。
## 这 11 条线是把人在标定页上手描的线拟合成一个透视变换后重算出来的，
## 所以格子天然按透视收敛，行高从左上的 98.8 递增到右下的 111.7。
const VERTICALS: Array[Vector2] = [
	Vector2(246.5, 92.7), Vector2(266.3, 619.5),
	Vector2(323.4, 120.2), Vector2(349.5, 646.0),
	Vector2(399.4, 147.4), Vector2(431.6, 672.1),
	Vector2(474.4, 174.2), Vector2(512.7, 697.9),
	Vector2(548.7, 200.8), Vector2(592.8, 723.4),
]

## 6 条横线，每条两个端点（左、右），按行序排：上边界、四条内线、下边界。
const HORIZONTALS: Array[Vector2] = [
	Vector2(246.5, 92.7), Vector2(548.7, 200.8),
	Vector2(250.2, 191.4), Vector2(556.9, 298.8),
	Vector2(254.0, 293.3), Vector2(565.5, 400.0),
	Vector2(258.0, 398.5), Vector2(574.3, 504.3),
	Vector2(262.1, 507.2), Vector2(583.4, 612.1),
	Vector2(266.3, 619.5), Vector2(592.8, 723.4),
]


## 返回第 index 格的四角，顺序左上、右上、右下、左下，单位是本控件的局部像素。
## inset 传 0 得到占满整格的四边形，用来做命中判定。
static func cell_quad(index: int, book_size: Vector2, inset: float = CELL_INSET) -> PackedVector2Array:
	if index < 0 or index >= CELL_COUNT:
		return PackedVector2Array()
	var column := index % COLUMNS
	var row := index / COLUMNS
	var quad := PackedVector2Array([
		_cross(VERTICALS, column, HORIZONTALS, row),
		_cross(VERTICALS, column + 1, HORIZONTALS, row),
		_cross(VERTICALS, column + 1, HORIZONTALS, row + 1),
		_cross(VERTICALS, column, HORIZONTALS, row + 1),
	])
	var scale := book_size / ART_SIZE
	var center := Vector2.ZERO
	for point in quad:
		center += point
	center /= 4.0
	var shrink := 1.0 - 2.0 * inset
	for i in quad.size():
		quad[i] = (center + (quad[i] - center) * shrink) * scale
	return quad


static func cell_center(index: int, book_size: Vector2) -> Vector2:
	var quad := cell_quad(index, book_size, 0.0)
	if quad.is_empty():
		return Vector2.ZERO
	return (quad[0] + quad[1] + quad[2] + quad[3]) * 0.25


## 落在哪一格；不在书上返回 -1。用不内收的整格，格与格之间没有死区。
static func cell_at(point: Vector2, book_size: Vector2) -> int:
	for index in CELL_COUNT:
		if Geometry2D.is_point_in_polygon(point, cell_quad(index, book_size, 0.0)):
			return index
	return -1


## 第 column 条竖线与第 row 条横线的交点。
static func _cross(verticals: Array[Vector2], column: int, horizontals: Array[Vector2], row: int) -> Vector2:
	var a0 := verticals[column * 2]
	var a1 := verticals[column * 2 + 1]
	var b0 := horizontals[row * 2]
	var b1 := horizontals[row * 2 + 1]
	var da := a1 - a0
	var db := b1 - b0
	var denominator := da.x * db.y - da.y * db.x
	# 两条线接近平行时退回四个端点的重心，免得除出口径外的坐标。
	if absf(denominator) < 0.0001:
		return (a0 + a1 + b0 + b1) * 0.25
	var t := ((b0.x - a0.x) * db.y - (b0.y - a0.y) * db.x) / denominator
	return a0 + da * t

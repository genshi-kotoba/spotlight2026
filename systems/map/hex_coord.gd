class_name HexCoord
extends RefCounted

## 平顶六边形的坐标数学。
##
## 逻辑层用轴向坐标 Vector2i(q, r)，运算时转立方坐标。
## 所有函数都是静态的，不依赖节点，可以单独测。

## 六个邻接方向。轴向坐标下与朝向无关，平顶尖顶都是这六个。
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

const SQRT3 := 1.7320508075688772


static func neighbors(coord: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir in DIRS:
		result.append(coord + dir)
	return result


static func distance(a: Vector2i, b: Vector2i) -> int:
	# 立方坐标下的距离，等价于 (|dq| + |dr| + |dq+dr|) / 2
	var dq := a.x - b.x
	var dr := a.y - b.y
	return maxi(maxi(absi(dq), absi(dr)), absi(dq + dr))


static func to_cube(coord: Vector2i) -> Vector3i:
	return Vector3i(coord.x, -coord.x - coord.y, coord.y)


static func from_cube(cube: Vector3i) -> Vector2i:
	return Vector2i(cube.x, cube.z)


## 轴向坐标转地面平面位置。返回值是 Vector2，3D 场景里对应 (x, z)。
static func to_plane(coord: Vector2i, outer_radius: float) -> Vector2:
	var x := outer_radius * 1.5 * coord.x
	var z := outer_radius * SQRT3 * (coord.y + coord.x * 0.5)
	return Vector2(x, z)


## 地面平面位置反查轴向坐标，用于把鼠标点击坐标换成格子。
static func from_plane(pos: Vector2, outer_radius: float) -> Vector2i:
	var q := (2.0 / 3.0 * pos.x) / outer_radius
	var r := (-1.0 / 3.0 * pos.x + SQRT3 / 3.0 * pos.y) / outer_radius
	return _round_axial(q, r)


## 浮点轴向坐标取整到最近的格子，先转立方再修约以免三轴和不等于零。
static func _round_axial(q: float, r: float) -> Vector2i:
	var x := q
	var z := r
	var y := -x - z

	var rx := roundi(x)
	var ry := roundi(y)
	var rz := roundi(z)

	var dx := absf(rx - x)
	var dy := absf(ry - y)
	var dz := absf(rz - z)

	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry

	return from_cube(Vector3i(rx, ry, rz))


## 编辑器里的文本布局用行列号书写，这里做行列与轴向的互转。
## 采用 odd-q 偏移：奇数列整体下移半格。
static func offset_to_axial(col: int, row: int) -> Vector2i:
	var q := col
	var r := row - (col - (col & 1)) / 2
	return Vector2i(q, r)


static func axial_to_offset(coord: Vector2i) -> Vector2i:
	var col := coord.x
	var row := coord.y + (coord.x - (coord.x & 1)) / 2
	return Vector2i(col, row)

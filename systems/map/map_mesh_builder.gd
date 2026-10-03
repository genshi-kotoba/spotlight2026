class_name MapMeshBuilder
extends RefCounted

## 按格子高度生成六边形棱柱网格。
##
## 几何规则：
##   - 所有棱柱从统一底面 y = 0 向上长，不悬浮。悬浮薄板会在高差处裂开缝隙。
##   - 只画暴露的面。被更高邻居挡住的那段侧壁不生成，避免共面重叠。
##   - 顶点坐标由同一个函数算出，并对半径做轻微外扩，盖住浮点误差造成的发丝缝。
##
## 整张地图合成一个 ArrayMesh，逐格颜色走顶点色，只占一次绘制调用。

const OUTER_RADIUS := 1.0
## 一个高度层级在世界里的尺寸。布局字符里的数字是层级，乘上它才是实际高度。
##
## 取 0.25：一层是半径的四分之一，台阶立面很短，叠起来是连绵起伏而不是一堵堵台墙。
## 十级加起来才 2.25 高。这是 MapBuilder 的导出属性，在编辑器里可以直接拖。
##
## 常量取自 MapLayout：爬升限值按世界高度判，两边必须用同一个换算比例，
## 各自留一份默认值迟早会漂移。
const STEP_HEIGHT := MapLayout.STEP_HEIGHT
const BASE_Y := 0.0
## 外扩系数。相邻六边形的共享边若各自独立计算，浮点误差会透出细缝，靠轻微重叠盖住。
const OUTER_SCALE := 1.001

## 描边宽度占外接圆半径的比例。
const BORDER_RATIO := 0.07
## 描边颜色。压暗到明显深于任何地形色，靠明度差把格子边界划出来。
const BORDER_COLOR := Color(0.13, 0.13, 0.16)
## 描边相对顶面的抬升，避免与顶面共面产生闪烁。
const BORDER_LIFT := 0.015

const CORNER_COUNT := 6

static var _dir_to_edge: PackedInt32Array = PackedInt32Array()


## 平顶六边形的第 i 个顶点。i = 0 时顶点指向 +X，顶点之间相隔 60 度。
static func corner(i: int, radius: float) -> Vector2:
	var angle := deg_to_rad(60.0 * i)
	return Vector2(cos(angle), sin(angle)) * radius


static func build(layout: MapLayout, radius: float = OUTER_RADIUS, step_height: float = STEP_HEIGHT) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 只放大六边形本身，不动格子间距。若连间距一起放大，格子越多偏移累积越明显，
	# 视觉位置会和逻辑坐标对不上。
	var corner_radius := radius * OUTER_SCALE

	for coord in layout.tiles:
		var tile: MapTile = layout.tiles[coord]
		_add_prism(surface, layout, tile, radius, corner_radius, step_height)

	# 不调 generate_tangents：它要求顶点带 UV，而这里的法线是手写的，用不到切线
	return surface.commit()


static func _add_prism(surface: SurfaceTool, layout: MapLayout, tile: MapTile, radius: float, corner_radius: float, step_height: float) -> void:
	var center := HexCoord.to_plane(tile.coord, radius)
	var top_y := BASE_Y + tile.height * step_height
	var color := MapTerrain.color_of(tile.terrain)

	# 顶面
	for i in CORNER_COUNT:
		var a := corner(i, corner_radius)
		var b := corner((i + 1) % CORNER_COUNT, corner_radius)
		_add_triangle(
			surface,
			_to_world(center + a, top_y),
			_to_world(center + b, top_y),
			_to_world(center, top_y),
			color
		)

	_add_border(surface, center, top_y, corner_radius)

	# 侧壁：只画邻格更低或没有邻格的那一段
	for dir_index in HexCoord.DIRS.size():
		var neighbor_coord: Vector2i = tile.coord + HexCoord.DIRS[dir_index]
		var neighbor: MapTile = layout.tiles.get(neighbor_coord)

		var exposed_from := BASE_Y
		if neighbor != null:
			if neighbor.height >= tile.height:
				continue  # 完全被挡住，不生成
			exposed_from = BASE_Y + neighbor.height * step_height

		var edge := _dir_edge(dir_index)
		var a2 := corner(edge, corner_radius)
		var b2 := corner((edge + 1) % CORNER_COUNT, corner_radius)
		var shade := color.darkened(0.35)

		_add_quad(
			surface,
			_to_world(center + a2, exposed_from),
			_to_world(center + b2, exposed_from),
			_to_world(center + b2, top_y),
			_to_world(center + a2, top_y),
			shade
		)


## 格子顶面外沿描一圈边，让相邻格子之间有明确界线。
##
## 用实心六边形环而不是线框：三维线宽固定一像素，俯视角下几乎看不见。
static func _add_border(surface: SurfaceTool, center: Vector2, top_y: float, radius: float) -> void:
	_add_ring(surface, center, top_y + BORDER_LIFT, radius, BORDER_RATIO, BORDER_COLOR)


## 一圈六边形环，不含格面。
##
## 高亮走这个形状而不是铺满格面：铺满会盖住地形颜色与描边，
## 格子本身的高差就看不出来了。边框只占外沿，格面仍然可见。
static func _add_ring(surface: SurfaceTool, center: Vector2, y: float, radius: float, ratio: float, color: Color) -> void:
	var inner := radius * (1.0 - ratio)

	for i in CORNER_COUNT:
		_add_quad(
			surface,
			_to_world(center + corner(i, inner), y),
			_to_world(center + corner(i, radius), y),
			_to_world(center + corner((i + 1) % CORNER_COUNT, radius), y),
			_to_world(center + corner((i + 1) % CORNER_COUNT, inner), y),
			color
		)


## 一块扁平的六边形面片，贴在格子顶面上做高亮用。
static func build_flat_hex(radius: float, y_offset: float, color: Color) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := radius * OUTER_SCALE

	for i in CORNER_COUNT:
		var a := corner(i, r)
		var b := corner((i + 1) % CORNER_COUNT, r)
		_add_triangle(
			surface,
			Vector3(0.0, y_offset, 0.0),
			Vector3(a.x, y_offset, a.y),
			Vector3(b.x, y_offset, b.y),
			color
		)

	return surface.commit()


## 一圈独立的六边形边框，供路径高亮使用。
## ratio 是环宽占外接圆半径的比例。
static func build_hex_ring(radius: float, ratio: float, y_offset: float, color: Color) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_ring(surface, Vector2.ZERO, y_offset, radius * OUTER_SCALE, ratio, color)
	return surface.commit()


static func _to_world(plane: Vector2, y: float) -> Vector3:
	# 地面平面上的 (x, z) 对应世界坐标的 X 与 Z
	return Vector3(plane.x, y, plane.y)


static func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	# Godot 的正面按顺时针绕序判定，而叉积按右手定则算出来指向面内，两者相反。
	# 这里交换 b、c 取反，才是朝外的着色法线。不换的话顶面法线朝下，
	# 整张地图会被当成背面受光，看着又暗又平，格子的高低差也看不出来。
	var normal := (c - a).cross(b - a).normalized()
	for v in [a, b, c]:
		surface.set_normal(normal)
		surface.set_color(color)
		surface.add_vertex(v)


static func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	# 顶点顺序 a-b-c 与 a-c-d 保证法线朝外
	_add_triangle(surface, a, b, c, color)
	_add_triangle(surface, a, c, d, color)


## 轴向方向索引对应的棱柱边索引。
## 方向与边的对应关系靠几何推导而不是硬编码，换朝向时不会静默错位。
static func _dir_edge(dir_index: int) -> int:
	if _dir_to_edge.is_empty():
		_build_dir_edge_table()
	return _dir_to_edge[dir_index]


static func _build_dir_edge_table() -> void:
	_dir_to_edge = PackedInt32Array()
	for dir in HexCoord.DIRS:
		var dir_plane := HexCoord.to_plane(dir, 1.0).normalized()
		var best_edge := 0
		var best_dot := -INF
		for e in CORNER_COUNT:
			var mid := (corner(e, 1.0) + corner((e + 1) % CORNER_COUNT, 1.0)) * 0.5
			var dot := mid.normalized().dot(dir_plane)
			if dot > best_dot:
				best_dot = dot
				best_edge = e
		_dir_to_edge.append(best_edge)

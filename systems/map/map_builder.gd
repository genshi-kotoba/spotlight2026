@tool
class_name MapBuilder
extends Node3D

## 把编辑器里的文本布局变成 3D 网格。
##
## 标了 @tool，所以在编辑器里改 layout_text 会立刻重建，不用运行游戏。
## 高度就在文本里设：一个字符一格，0 到 9 用数字、10 到 35 用大写字母，井号是墙体，@ 是起点。

## 演示地图：喀斯特地貌。
##
## 底图是宽缓的山脊与山谷，全程可走。另种了三座锥峰，锥面自带陡壁，
## 每座山切了一条螺旋小径盘上峰顶 —— 小径两侧是陡壁，所以那是唯一通路，上去要绕圈。
## 峰顶都上得去，不可达的只有谷侧零星六格。
##
## 458 格，高度 0 至 20 级（一层 0.25，最高 5.0 个世界单位），可达率 98%。
const DEFAULT_LAYOUT := """
	.............00002............
	...........000002446..........
	.........0000000246875........
	.......00000000224686431......
	.....000000000134667642000....
	...#000000011213578653210000..
	...0000002233BCDDE8755310000..
	...0000024455BCEEEEF75310000..
	...00000246AAEEGGGEF81110000..
	...000002469AEGIIIGEG1010000..
	...0023445598EGKKIGHG5031100..
	...2255B46688EGJIGGH87153311..
	...15BBDBB6788EEJIIA82175532..
	...5BFGGDDB87788E8982B997643..
	...5EDFHGDB83266854339BA8755..
	...5EDFFFDB824245847779B9877..
	...5EDDDDBB946416797579A9799..
	...@11CBBAA357#01797579B9777..
	....00C5A0179A111275579A975...
	......00046A8CAC625356888.....
	........056CCECED432446.......
	..........ACEGEFE4402.........
	"""

@export_multiline var layout_text: String = DEFAULT_LAYOUT:
	set(value):
		layout_text = value
		_request_rebuild()

@export var outer_radius: float = MapMeshBuilder.OUTER_RADIUS
@export var step_height: float = MapMeshBuilder.STEP_HEIGHT

## 解析后的地图数据。其他节点通过它做通行判定与寻路。
var layout: MapLayout

var _mesh_instance: MeshInstance3D
var _body: StaticBody3D
var _collision: CollisionShape3D
## 地图中心相对坐标原点的偏移，用来把地图挪回原点附近。
var _center := Vector3.ZERO


func _ready() -> void:
	rebuild()


## 手动重建。改了布局文本以外的参数时调用。
func rebuild() -> void:
	# step_height 要同时喂给数据层与网格层：数据层拿它把爬升限值换算成世界高度，
	# 网格层拿它决定台阶实际多高。两处必须同源，否则判定与看到的地形会对不上。
	layout = MapLayout.from_text(layout_text, step_height)
	_ensure_nodes()
	_center = _compute_center()
	_mesh_instance.mesh = MapMeshBuilder.build(layout, outer_radius, step_height)
	# 网格按坐标原样生成，这里整体平移，让地图大致落在原点附近。
	# 不做的话地图会偏在一边，编辑器里打开时角色和地图对不上。
	_mesh_instance.position = -_center
	_rebuild_collision()


## 格子顶面的世界高度。角色与路径高亮都贴在这个高度上。
func top_y(coord: Vector2i) -> float:
	var tile := layout.tile_at(coord)
	if tile == null:
		return 0.0
	return tile.height * step_height


## 地图在地面平面上的世界包围盒。
##
## 放在这里是因为只有它同时知道格子坐标、外接圆半径与居中偏移，
## 能把逻辑坐标换算成世界范围。相机拿不到这三样，不该自己算。
func world_bounds() -> AABB:
	if layout == null or layout.tiles.is_empty():
		return AABB()

	var box := AABB()
	var first := true
	for coord in layout.tiles:
		var point := world_position(coord)
		if first:
			box = AABB(point, Vector3.ZERO)
			first = false
		else:
			box = box.expand(point)

	# 只按格心算的话边缘会缺半个格子，这里把半径补回去
	return box.grow(outer_radius)


## 格子中心的世界坐标。
func world_position(coord: Vector2i) -> Vector3:
	var plane := HexCoord.to_plane(coord, outer_radius)
	return to_global(Vector3(plane.x, top_y(coord), plane.y) - _center)


## 世界坐标落在哪一格。传入的是碰撞体上的实际命中点。
func coord_at_world(world_pos: Vector3) -> Vector2i:
	var local := to_local(world_pos) + _center
	return HexCoord.from_plane(Vector2(local.x, local.z), outer_radius)


func _compute_center() -> Vector3:
	if layout == null or layout.tiles.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for coord in layout.tiles:
		var plane := HexCoord.to_plane(coord, outer_radius)
		sum += Vector3(plane.x, 0.0, plane.y)
	return sum / layout.tiles.size()


func _request_rebuild() -> void:
	# 编辑器里属性面板可能早于 _ready 触发，此时先只存值
	if not is_inside_tree():
		return
	rebuild()


func _ensure_nodes() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		return

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Mesh"
	_mesh_instance.material_override = _make_material()
	add_child(_mesh_instance)

	# 碰撞体挂在网格下，跟着网格一起平移，省得两处各算一次偏移
	_body = StaticBody3D.new()
	_body.name = "Body"
	_collision = CollisionShape3D.new()
	_collision.name = "Shape"
	_body.add_child(_collision)
	_mesh_instance.add_child(_body)


func _rebuild_collision() -> void:
	if _collision == null or _mesh_instance.mesh == null:
		return
	# 直接拿渲染网格生成三角网碰撞。格子有高低差，用平面近似会让拾取点偏到隔壁格。
	_collision.shape = _mesh_instance.mesh.create_trimesh_shape()


func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	material.metallic = 0.0
	return material

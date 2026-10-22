class_name MapHighlightPool
extends Node3D

## 一组格子高亮边框，从池子里复用。
##
## 只负责「把若干格点亮成某个颜色」，不关心这些格是路线还是光标。
##
## 路线与光标各自持有一个池子，因此互不干扰。早先两者共用一个池子，
## 鼠标一扫过别的格子，光标就把整条路线擦掉了。

## 边框宽度占外接圆半径的比例。地形描边是 0.07，高亮要更粗才压得住。
const RING_RATIO := 0.18
## 相对格面的抬升，避免与顶面共面产生闪烁。要比地形的描边抬升更高。
const LIFT := 0.03

## 格子外接圆半径。由装配方设置，取自地图。
var radius := 1.0

var _pool: Array[MeshInstance3D] = []
var _active := 0


## 一次性点亮若干格。positions 是世界坐标。传空数组等同于清空。
func set_cells(positions: Array[Vector3], color: Color) -> void:
	clear()
	for point in positions:
		var node := _obtain(_active)
		_active += 1
		node.mesh = MapMeshBuilder.build_hex_ring(radius, RING_RATIO, LIFT, color)
		node.global_position = point
		node.visible = true


func clear() -> void:
	for i in _active:
		_pool[i].visible = false
	_active = 0


func _obtain(index: int) -> MeshInstance3D:
	while _pool.size() <= index:
		var node := MeshInstance3D.new()
		node.name = "Cell%d" % _pool.size()
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		node.material_override = material
		add_child(node)
		_pool.append(node)
	return _pool[index]

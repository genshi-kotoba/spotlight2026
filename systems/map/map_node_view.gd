class_name MapNodeView
extends Node3D

## 种子生成结果的轻量占位表现。正式图标交付后只替换本层，不改分配逻辑。
const LIFT := 0.18

@export var font_size := 52
@export var pixel_size := 0.013
@export var flat_yaw_degrees := 45.0

var _markers: Array[Label3D] = []


func show_plan(builder: MapBuilder, plan: MapNodePlan) -> void:
	clear()
	if builder == null or plan == null:
		return
	for coord: Vector2i in plan.assignments:
		var kind: int = plan.assignments[coord]
		var label := Label3D.new()
		# Node 名称不能含稳定 ID 中的冒号；业务 ID 仍由 MapNodePlan.node_id() 提供。
		label.name = "Node_%d_%d" % [coord.x, coord.y]
		label.text = MapNodeKind.marker(kind)
		label.modulate = MapNodeKind.color(kind)
		label.font_size = font_size
		label.pixel_size = pixel_size
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label.rotation_degrees = Vector3(-90.0, flat_yaw_degrees, 0.0)
		label.outline_size = 8
		label.outline_modulate = Color(0.08, 0.08, 0.10)
		label.no_depth_test = false
		add_child(label)
		label.global_position = builder.world_position(coord) + Vector3(0.0, LIFT, 0.0)
		_markers.append(label)


func clear() -> void:
	for marker in _markers:
		marker.queue_free()
	_markers.clear()

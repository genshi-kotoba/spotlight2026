class_name MapCamera
extends Camera3D

## 可调视角的俯视相机。水平朝向与俯仰倾斜都能调，滚轮缩放，可平滑跟随一个节点。
##
## 俯仰角下限卡在 35 度：再低就会看到地块的侧面与背面，接缝和内部结构都会露出来。
##
## 相机只认识 Node3D 与一个包围盒，不认识 PlayerMover，也不认识地图数据。
## 跟谁、边界在哪，都由装配方注入。

const MIN_PITCH := 35.0
const MAX_PITCH := 80.0

@export var yaw_speed := 120.0
@export var pitch_speed := 80.0
@export var zoom_step := 1.5
@export var min_distance := 8.0
## 上限按演示地图 30 列乘 2.0 的宽度留出余量，能一眼看全整张图。
@export var max_distance := 75.0

@export var initial_yaw := 45.0
@export var initial_pitch := 55.0
@export var initial_distance := 24.0

## 跟随的收敛时间，秒。越小越硬贴，越大越飘。
##
## 与 PlayerMover.tiles_per_second 是联动的：角色每格耗时若短于这个值，
## 镜头会一直落在后面追。角色每格 0.17 秒，这里取 0.15 才跟得上。
@export var follow_smooth_time := 0.15

var yaw := 0.0
var pitch := 55.0
var distance := 24.0
var target := Vector3.ZERO

var _dragging := false
var _follow_node: Node3D = null
## 注视中心的允许范围。为空表示不限制。
var _has_bounds := false
var _bounds := AABB()
var _bounds_margin := 0.0


func _ready() -> void:
	yaw = initial_yaw
	pitch = initial_pitch
	distance = initial_distance
	_apply()


## 平滑跟随一个节点。传 null 取消跟随。
func follow(node: Node3D) -> void:
	_follow_node = node


## 限制注视中心的移动范围。传地图的世界包围盒即可。
##
## 夹的是注视中心而不是相机本身的位置：相机的实际位置由朝向、俯仰与距离算出来，
## 直接夹它会让视角在高差处跳变。
func set_bounds(box: AABB, margin: float = 0.0) -> void:
	_bounds = box
	_bounds_margin = margin
	_has_bounds = true
	_apply()


## 立即对准某点，不做插值。用于开局定位。
func snap_to(world_pos: Vector3) -> void:
	target = _clamp_target(world_pos)
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_set_distance(distance - zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_set_distance(distance + zoom_step)
			MOUSE_BUTTON_MIDDLE:
				_dragging = event.pressed
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		yaw -= event.relative.x * 0.4
		# 往下拖抬高俯视角，往上拖压低。方向与常见三维软件相反，
		# 是照实际操作手感定的，不要顺手改回去。
		_set_pitch(pitch + event.relative.y * 0.3)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var moved := false

	if Input.is_key_pressed(KEY_Q):
		yaw += yaw_speed * delta
		moved = true
	if Input.is_key_pressed(KEY_E):
		yaw -= yaw_speed * delta
		moved = true
	if Input.is_key_pressed(KEY_R):
		_set_pitch(pitch + pitch_speed * delta)
		moved = true
	if Input.is_key_pressed(KEY_F):
		_set_pitch(pitch - pitch_speed * delta)
		moved = true

	if _follow_node != null and is_instance_valid(_follow_node):
		var goal := _clamp_target(_follow_node.global_position)
		if not target.is_equal_approx(goal):
			if follow_smooth_time <= 0.0:
				target = goal
			else:
				var weight := 1.0 - exp(-delta / follow_smooth_time)
				target = target.lerp(goal, weight)
			moved = true

	if moved:
		_apply()


func _set_pitch(value: float) -> void:
	pitch = clampf(value, MIN_PITCH, MAX_PITCH)
	_apply()


func _set_distance(value: float) -> void:
	distance = clampf(value, min_distance, max_distance)
	_apply()


func _clamp_target(world_pos: Vector3) -> Vector3:
	if not _has_bounds:
		return world_pos
	var box := _bounds.grow(_bounds_margin)
	return Vector3(
		clampf(world_pos.x, box.position.x, box.end.x),
		world_pos.y,
		clampf(world_pos.z, box.position.z, box.end.z)
	)


func _apply() -> void:
	var pitch_rad := deg_to_rad(pitch)
	var yaw_rad := deg_to_rad(yaw)
	var offset := Vector3(
		cos(pitch_rad) * sin(yaw_rad),
		sin(pitch_rad),
		cos(pitch_rad) * cos(yaw_rad)
	) * distance

	global_position = target + offset
	look_at(target, Vector3.UP)

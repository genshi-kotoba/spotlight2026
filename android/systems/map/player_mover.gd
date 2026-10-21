class_name PlayerMover
extends Node3D

## 沿路径逐格移动。
##
## 两个细节不能省：
##   1. 移动锁在开始移动的瞬间就置位。不做的话连点两下会启动两条移动，角色来回抽搐。
##   2. 每进入一格就上报一次，让路径显示把走过的那格清掉，避免长路径下状态堆积。

signal move_started(from: Vector2i, to: Vector2i)
signal tile_entered(coord: Vector2i)
signal move_finished(coord: Vector2i)

## 每秒走过的格子数。6.0 时每格约 0.17 秒。
@export var tiles_per_second := 6.0

var builder: MapBuilder
var current_coord := Vector2i.ZERO

var _is_moving := false
var _path: Array[Vector2i] = []
var _step := 0
var _progress := 0.0
var _from_pos := Vector3.ZERO
var _to_pos := Vector3.ZERO


func setup(p_builder: MapBuilder, start_coord: Vector2i) -> void:
	builder = p_builder
	current_coord = start_coord
	global_position = builder.world_position(start_coord)


func is_moving() -> bool:
	return _is_moving


## 开始沿路径移动。路径少于两格或正在移动时返回 false，不打断当前移动。
func move_along(path: Array[Vector2i]) -> bool:
	if _is_moving:
		return false
	if path.size() < 2:
		return false

	_path = path
	_step = 0
	_progress = 0.0
	_is_moving = true
	_from_pos = builder.world_position(_path[0])
	_to_pos = builder.world_position(_path[1])
	global_position = _from_pos

	move_started.emit(_path[0], _path[_path.size() - 1])
	return true


func _process(delta: float) -> void:
	if not _is_moving:
		return

	_progress += delta * tiles_per_second

	while _progress >= 1.0 and _is_moving:
		_progress -= 1.0
		_step += 1
		current_coord = _path[_step]
		tile_entered.emit(current_coord)

		if _step >= _path.size() - 1:
			_finish()
			return

		_from_pos = builder.world_position(_path[_step])
		_to_pos = builder.world_position(_path[_step + 1])

	global_position = _from_pos.lerp(_to_pos, _progress)


func _finish() -> void:
	_is_moving = false
	_path = []
	global_position = builder.world_position(current_coord)
	move_finished.emit(current_coord)

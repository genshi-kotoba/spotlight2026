class_name MapInput
extends Node

## 悬停与点击的分发。
##
## 只管把「鼠标指着哪一格」翻译成事件，不碰地图数据，也不碰移动。
## 拾取交给物理射线打真实几何，见 _pick。

signal tile_hovered(coord: Vector2i)
signal tile_unhovered()
signal tile_clicked(coord: Vector2i)

## 没命中任何格子时的哨兵值。坐标都是小整数，不会撞上。
const NO_COORD := Vector2i(-99999, -99999)

## 射线长度。能覆盖整张地图即可，不需要精确。
@export var ray_length := 500.0

var builder: MapBuilder
var camera: Camera3D

var _hovered := NO_COORD


func setup(p_builder: MapBuilder, p_camera: Camera3D) -> void:
	builder = p_builder
	camera = p_camera


func _unhandled_input(event: InputEvent) -> void:
	if builder == null or camera == null:
		return

	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			return
		_update_hover(event.position)
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var coord := _pick(event.position)
			if coord != NO_COORD:
				tile_clicked.emit(coord)


func _update_hover(mouse_pos: Vector2) -> void:
	var coord := _pick(mouse_pos)
	if coord == _hovered:
		return

	_hovered = coord
	if coord == NO_COORD:
		tile_unhovered.emit()
	else:
		tile_hovered.emit(coord)


## 返回命中的格子坐标，没命中返回 NO_COORD。
##
## 打的是真实几何的三角网碰撞体，不是地面基准面。
## 早先的做法是与 y = 0 求交再换算，俯视角下看着对的点会算到隔壁格 ——
## 格子有高度差，射线先碰到的是抬起来的那一层的顶面或侧壁。
func _pick(mouse_pos: Vector2) -> Vector2i:
	var origin := camera.project_ray_origin(mouse_pos)
	var direction := camera.project_ray_normal(mouse_pos)

	var space := camera.get_world_3d().direct_space_state
	if space == null:
		return NO_COORD

	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction * ray_length
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return NO_COORD

	var coord := builder.coord_at_world(hit["position"])
	if not builder.layout.has_tile(coord):
		return NO_COORD
	return coord

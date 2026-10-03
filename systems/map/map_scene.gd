class_name MapScene
extends Node3D

## 地图场景的装配点。
##
## 子节点彼此不认识，全部在这里接线，靠信号通信。
## 悬停预览路径、点击寻路、逐格移动、把走过的格子从高亮里去掉，都串在这里。

@onready var builder: MapBuilder = $MapBuilder
@onready var path_view: MapPathView = $PathView
@onready var mover: PlayerMover = $Player
@onready var pointer: MapInput = $Input
@onready var camera: MapCamera = $Camera

## 悬停到不可达的格子时，是否把那一格标红。
@export var mark_unreachable_hover := true

## 相机注视中心在包围盒外还能多走多远。留一点余量，免得贴边太死。
@export var camera_bounds_margin := 2.0

## 本次移动的终点。走在中途时要靠它算出还剩哪一段路没走。
var _destination := Vector2i.ZERO


func _ready() -> void:
	path_view.setup(builder)
	pointer.setup(builder, camera)
	camera.set_bounds(builder.world_bounds(), camera_bounds_margin)

	if builder.layout.has_start:
		mover.setup(builder, builder.layout.start_coord)
	else:
		push_warning("MapScene: 布局里没有起点标记 @，角色停在地图原点")

	camera.snap_to(builder.world_position(mover.current_coord))
	camera.follow(mover)

	pointer.tile_hovered.connect(_on_tile_hovered)
	pointer.tile_unhovered.connect(_on_tile_unhovered)
	pointer.tile_clicked.connect(_on_tile_clicked)
	mover.move_started.connect(_on_move_started)
	mover.tile_entered.connect(_on_tile_entered)
	mover.move_finished.connect(_on_move_finished)


func _on_tile_hovered(coord: Vector2i) -> void:
	# 移动途中只更新光标，不动路线层。
	# 若这里去改路线层，鼠标每扫过一格就会把整条剩余路线擦掉一次。
	if mover.is_moving():
		path_view.show_hover(coord)
		return

	var path := builder.layout.find_path(mover.current_coord, coord)

	if path.size() >= 2:
		path_view.clear_cursor()
		path_view.show_route(path)
	elif mark_unreachable_hover:
		path_view.clear_route()
		path_view.show_invalid(coord)
	else:
		path_view.clear_route()
		path_view.show_hover(coord)


func _on_tile_unhovered() -> void:
	path_view.clear_cursor()
	# 移动途中不清路线，剩下的路还要显示
	if not mover.is_moving():
		path_view.clear_route()


func _on_tile_clicked(coord: Vector2i) -> void:
	# 移动中的点击由 PlayerMover 的移动锁兜住：它会让 move_along 返回 false，
	# 这里提前返回只是省掉一次多余的寻路
	if mover.is_moving():
		return

	var path := builder.layout.find_path(mover.current_coord, coord)
	if path.size() < 2:
		path_view.clear_route()
		path_view.show_invalid(coord)
		return

	mover.move_along(path)


func _on_move_started(_from: Vector2i, to: Vector2i) -> void:
	_destination = to


func _on_tile_entered(coord: Vector2i) -> void:
	# 从下一格开始显示，脚下这格当场熄灭。
	# 若从脚下这一格开始显示，要等走到再下一格才熄灭，看着会慢一拍。
	var remaining := builder.layout.find_path(coord, _destination)
	if remaining.size() > 1:
		remaining.remove_at(0)
	path_view.show_route(remaining)


func _on_move_finished(_coord: Vector2i) -> void:
	# 相机自己在跟随，这里不用再对准
	path_view.clear_route()

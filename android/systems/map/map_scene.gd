class_name MapScene
extends Node3D

## 地图场景的装配点。
##
## 子节点彼此不认识，全部在这里接线，靠信号通信。
## 悬停预览路径、点击寻路、逐格移动、把走过的格子从高亮里去掉，都串在这里。

signal node_plan_generated(plan: MapNodePlan)
signal map_node_entered(node_id: String, kind: int, coord: Vector2i)

@onready var builder: MapBuilder = $MapBuilder
@onready var path_view: MapPathView = $PathView
@onready var mover: PlayerMover = $Player
@onready var pointer: MapInput = $Input
@onready var camera: MapCamera = $Camera
@onready var node_view: MapNodeView = $NodeView

## 演示场景没有 PRG-003 单局协调者，因此在尚无随机上下文时用此值启动一局。
## 正式流程若已 begin_run/restore_snapshot，这里绝不会重置已有上下文。
@export var demo_seed_text := "map-demo-001"

## 地图实例稳定身份。它与主种子共同决定本图节点分布，并应写入局内存档。
@export var map_id := "map-001"

## 非法布局重试或玩法认可的重生成次数；普通重进场景不得自行增加。
@export_range(0, 2147483647) var node_occurrence := 0

## 悬停到不可达的格子时，是否把那一格标红。
@export var mark_unreachable_hover := true

## 相机注视中心在包围盒外还能多走多远。留一点余量，免得贴边太死。
@export var camera_bounds_margin := 2.0

## 本次移动的终点。走在中途时要靠它算出还剩哪一段路没走。
var _destination := Vector2i.ZERO

## 已生成的业务结果。存档应保存本计划，而不是每次打开地图都重新抽取。
var node_plan: MapNodePlan


func _ready() -> void:
	var node_error := OK
	if node_plan == null:
		var saved_plan: MapNodePlan
		if GlobalState.run_active and GlobalState.current_run != null:
			saved_plan = GlobalState.current_run.get_map_node_plan(map_id)
		if saved_plan != null:
			node_plan = saved_plan
		else:
			node_error = generate_node_plan()
	elif node_plan.map_id != map_id:
		node_error = ERR_INVALID_DATA
	if node_error != OK:
		push_error("MapScene: seeded node generation failed with error %d" % node_error)
	else:
		node_view.show_plan(builder, node_plan)

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


## 用当前单局主种子为本地图生成节点。正式游戏首次生成后应保存 node_plan；
## 读档直接装回保存的数据，不再次调用本方法消费随机流。
func generate_node_plan() -> Error:
	if map_id.strip_edges().is_empty() or node_occurrence < 0:
		return ERR_INVALID_PARAMETER

	if SeedService.get_main_seed().is_empty():
		var actual_seed := SeedService.begin_run(demo_seed_text)
		if actual_seed.is_empty():
			return SeedService.last_error

	var stream := SeedService.get_stream(RandomDomains.MAP_NODES, [map_id], node_occurrence)
	if stream == null:
		return SeedService.last_error

	node_plan = MapNodeDistributor.generate_first_map(builder.layout, stream, map_id)
	if node_plan == null:
		return stream.last_error if stream.last_error != OK else ERR_CANT_CREATE
	if GlobalState.run_active and GlobalState.current_run != null:
		var store_error := GlobalState.current_run.set_map_node_plan(node_plan)
		if store_error != OK:
			return store_error

	print("地图节点生成完成 seed=%s map=%s signature=%s" % [
		SeedService.get_main_seed(), map_id, node_plan.signature()
	])
	node_plan_generated.emit(node_plan)
	return OK


## 读档装配入口。调用方先用 MapNodePlan.from_dictionary() 完成严格校验；
## 可在场景入树前注入，也可在暂停输入后替换当前计划。
func apply_node_plan(restored: MapNodePlan) -> Error:
	if restored == null or restored.map_id != map_id:
		return ERR_INVALID_DATA
	node_plan = restored
	if is_node_ready():
		node_view.show_plan(builder, node_plan)
		node_plan_generated.emit(node_plan)
	return OK


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


func _on_move_finished(coord: Vector2i) -> void:
	# 相机自己在跟随，这里不用再对准
	path_view.clear_route()
	if node_plan != null and node_plan.has_node(coord):
		if GlobalState.run_active and GlobalState.current_run != null:
			var update_error := GlobalState.current_run.update_map_node(
				map_id, node_plan.node_id(coord), {
				"visited": true,
				"kind": node_plan.kind_at(coord),
			})
			if update_error != OK:
				push_error("MapScene: map node state write-back failed with error %d" % update_error)
				return
		map_node_entered.emit(node_plan.node_id(coord), node_plan.kind_at(coord), coord)

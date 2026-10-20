extends Node

const Hex = preload("res://systems/map/hex_coord.gd")
const Generator = preload("res://systems/map/flat_2d/planar_map_generator.gd")
const LocalHeight = preload("res://systems/map/relief_2d/local_articulation_height.gd")
const Regions = preload("res://systems/map/relief_2d/region_walls_height.gd")
var failures := 0

# 记录真实正式入口的首次 load_map 参数，避免恢复存档时重新绑定两次地图。
class CountedEntry extends "res://ui/main_menu/menu_map_entry.gd":
	var binds: Array[Dictionary] = []
	func load_map(snapshot: Dictionary, saved_state: Dictionary = {}) -> bool:
		binds.append(saved_state.duplicate(true))
		return super.load_map(snapshot, saved_state)

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_neighbor_order()
	_test_tiny_rows()
	var fixture := "res://.godot/fusion-optimization-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture.path_join("game.json")
	_check("隔离存档", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "fusion-optimization"
	_check("建立真实测试局", SaveGateway.start_new_run("fusion-optimization", config) == OK)
	var disk_before := FileAccess.get_file_as_string(SaveGateway.save_path)
	var random_before := JSON.stringify(SeedService.capture_snapshot())
	var prepared := GlobalState.build_save_payload()
	_check("只构建载荷与原接口内容相同", prepared.error == OK and JSON.stringify(prepared.payload) == JSON.stringify(GlobalState.capture_save_data()))
	_check("构建载荷不写盘、不改随机流或存档路径", disk_before == FileAccess.get_file_as_string(SaveGateway.save_path) and random_before == JSON.stringify(SeedService.capture_snapshot()) and GlobalState.save_path == SaveGateway.save_path)
	var view := CountedEntry.new()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())
	_check("初次地图只绑定一次", view.binds.size() == 1)
	# 改变可见状态，验证恢复传给第一次绑定的就是检查点，而不是出生状态。
	var origin: Vector2 = view.session.actor_plane
	for delta: Vector2 in [Vector2(0.2, 0), Vector2(-0.2, 0), Vector2(0, 0.2), Vector2(0, -0.2)]:
		view.session.move_actor(delta)
		if not view.session.actor_plane.is_equal_approx(origin): break
	var saved_position: Vector2 = view.session.actor_plane
	_check("测试角色离开出生位置", not saved_position.is_equal_approx(origin))
	_check("保存完整地图", SaveGateway.save_current() == OK)
	var saved := SaveGateway.map_checkpoint()
	var entry: Dictionary = view.map_run.get_floor(view.map_run.current_floor)
	var expected: Dictionary = entry.state.duplicate(true)
	get_tree().current_scene = null
	view.free()
	_check("模拟冷启动载入唯一存档", SaveGateway.load_current() == OK)
	view = CountedEntry.new()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())
	_check("冷恢复只绑定一次", view.binds.size() == 1)
	# JSON 读取将整数转成 float；统一规范化后再比较，不误判 state_version=1.0。
	_check("首次绑定即为真实保存状态", JSON.parse_string(JSON.stringify(view.binds[0])) == JSON.parse_string(JSON.stringify(expected)))
	_check("恢复后的地图位置、探索与节点访问状态保持", view.session.actor_plane.is_equal_approx(saved_position) and JSON.stringify(view.session.capture_state()) == JSON.stringify(expected) and not saved.is_empty())
	print("优化版本整合：全部通过" if failures == 0 else "优化版本整合：失败%d项" % failures)
	get_tree().quit(failures)

func _test_neighbor_order() -> void:
	var generator := Generator.new()
	var matches := true
	for q in range(-8, 9):
		for r in range(-8, 9):
			var origin := Vector2i(q, r)
			var neighbors := {}
			for coord: Vector2i in Hex.neighbors(origin): neighbors[coord] = true
			var actual: Array = []
			for direction: Vector2i in Generator._LEXICOGRAPHIC_DIRS: actual.append(origin + direction)
			matches = matches and actual == generator._sorted(neighbors)
	_check("289个坐标的BFS邻居顺序与旧算法完全一致", matches)

func _test_tiny_rows() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 20261019
	var data := {"owner": {}, "groups": [], "spawn": Vector2i.ZERO, "_la_required": {}}
	for q in range(-4, 5):
		for r in range(-4, 5):
			var coord := Vector2i(q, r)
			data.owner[coord] = data.groups.size()
			data.groups.append([coord])
			if (q + r) % 4 == 0: data._la_required[coord] = true
	var matches := true
	for iteration in 160:
		var levels: Array = []
		for group in data.groups: levels.append(random.randi_range(-3, 6))
		var expected: Array = []
		for row: Dictionary in Regions._small_components(levels, data).rows:
			if row.cells.size() > 3: continue
			for pair: Array in row.cells:
				if not data._la_required.has(Vector2i(pair[0], pair[1])):
					expected.append(row)
					break
		matches = matches and JSON.stringify(LocalHeight._tiny_rows(levels, data)) == JSON.stringify(expected)
		if iteration == 79: data._rw_cell_topology = Regions._cell_topology(data)
	_check("160组峰谷扫描与旧算法一致（缓存与无缓存拓扑）", matches)

func _check(label: String, passed: bool) -> void:
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

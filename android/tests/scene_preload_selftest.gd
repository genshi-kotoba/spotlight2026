extends Node
const TARGET := "res://tests/support/scene_transition_target.tscn"
const HELP := preload("res://tests/support/presentation_test_helper.gd")
var failures := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_run")

func _run() -> void:
	get_tree().current_scene = null
	var fixture := "res://.godot/scene-preload-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture.path_join("game.json")
	_check("使用隔离存档", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "preload-fixture"
	_check("建立测试局", SaveGateway.start_new_run("preload-fixture", config) == OK)
	var run := SaveGateway.current_run()
	var original := JSON.stringify(run.to_dictionary())
	var rng := JSON.stringify(SeedService.capture_snapshot())
	var file_before := FileAccess.get_file_as_string(SaveGateway.save_path)
	var cold_started := Time.get_ticks_usec()
	var first := await ScenePreloader.load_scene(TARGET)
	var cold_ms := (Time.get_ticks_usec() - cold_started) / 1000.0
	var hit_before := ScenePreloader.cache_hits
	var hot_started := Time.get_ticks_usec()
	var second := await ScenePreloader.load_scene(TARGET)
	var hot_ms := (Time.get_ticks_usec() - hot_started) / 1000.0
	_check("二次场景加载直接复用强引用缓存", first != null and first == second and ScenePreloader.cache_hits == hit_before + 1)
	print("PERF scene resource cold=%.3fms hot=%.3fms" % [cold_ms, hot_ms])
	var first_art := ""
	for floor_index in range(1, 5):
		var snapshot := _map(floor_index)
		ScenePreloader.prepare_map(snapshot, run.run_id)
		_check("第%d层所有节点都有预加载清单" % floor_index, int(ScenePreloader.stats().nodes) == snapshot.nodes.size())
		ScenePreloader.prioritize_node(snapshot.map_id, "normal")
		await _drain()
		for node: Dictionary in snapshot.nodes:
			var status := ScenePreloader.node_status(snapshot.map_id, node.id)
			_check("第%d层%s资源全部就绪" % [floor_index, node.type], not status.is_empty() and status.complete and int(status.failed) == 0)
		_check("预加载没有实例化场景或创建战斗", get_tree().current_scene == null and run.current_battle == null)
		if floor_index == 1:
			first_art = TextCatalog.entry("monsters", snapshot.nodes[0].content_id).art_path
		else:
			_check("换层释放旧怪物独有缓存", ScenePreloader.cached_resource(first_art) == null)
		var monster := TextCatalog.entry("monsters", snapshot.nodes[0].content_id)
		var raw: Variant = ScenePreloader.cached_text(monster.battle_text_path)
		_check("台词读取命中预加载且内容一致", raw is String and TextCatalog.read_text(monster.battle_text_path).text == raw)
		_check("新层不返回上一层节点状态", ScenePreloader.node_status("preload:floor-%03d" % (floor_index - 1), "normal").is_empty())
	_check("预加载不改变牌组、背包、进度或商店库存", original == JSON.stringify(run.to_dictionary()))
	_check("预加载不改变玩法随机快照", rng == JSON.stringify(SeedService.capture_snapshot()))
	_check("预加载不写存档", file_before == FileAccess.get_file_as_string(SaveGateway.save_path))
	var cached := ScenePreloader.cached_resource(ScenePreloader.BATTLE_SCENE)
	_check("所有战斗节点仅保留一个公共PackedScene", cached is PackedScene and await ScenePreloader.load_scene(ScenePreloader.BATTLE_SCENE) == cached)
	ScenePreloader.prepare_map(_map(1), "replacement-run")
	ScenePreloader.request_resource(first_art, false, true)
	await get_tree().process_frame
	await get_tree().process_frame
	ScenePreloader.prepare_map(_map(3), "replacement-run")
	await _drain()
	_check("连续换层时旧后台任务不会写回旧层节点", ScenePreloader.stats().map_id == "preload:floor-003" and ScenePreloader.node_status("preload:floor-001", "normal").is_empty())
	_check("旧楼层后台贴图收尾不会滞留缓存", ScenePreloader.cached_resource(first_art) == null)
	ScenePreloader.clear_map()
	_check("清理局内缓存保留公共场景", ScenePreloader.stats().nodes == 0 and ScenePreloader.cached_resource(ScenePreloader.BATTLE_SCENE) == cached)
	_check("拒绝无效路径且不锁住界面", ScenePreloader.request_resource("user://invalid.tscn") == ERR_INVALID_PARAMETER and not SceneTransition.is_loading())
	_check("缺失场景请求不会无限等待", await ScenePreloader.load_scene("res://missing-preload-scene.tscn") == null)
	_check("热缓存仍经统一转场并立即锁定输入", SceneTransition.change_scene_to_file(TARGET) == OK and SceneTransition.is_loading() and get_tree().paused)
	await HELP.map_ready(get_tree(), 20.0)
	_check("热加载场景真正完成初始化才解除遮罩", get_tree().current_scene.scene_file_path == TARGET and get_tree().current_scene.prepared and not get_tree().paused)
	print("PERF warm transition ", SceneTransition.last_metrics)
	print("场景预加载：全部通过" if failures == 0 else "场景预加载：失败%d项" % failures)
	get_tree().quit(failures)

func _map(index: int) -> Dictionary:
	var normal := ""
	var elite := ""
	var boss := ""
	for record: Dictionary in TextCatalog.entries("monsters"):
		if record.type == "普通 · 第%d层" % index and normal.is_empty():
			normal = record.id
		elif record.type == "精英 · 第%d层" % index and elite.is_empty():
			elite = record.id
		elif record.type == "BOSS · 第%d层" % index:
			boss = record.id
	# 第四层目前只有Boss；只验证资源策略，不生成或开放第四层地图。
	return {"map_id": "preload:floor-%03d" % index, "floor_index": index, "nodes": [
		{"id": "normal", "type": "battle", "content_id": normal if not normal.is_empty() else boss},
		{"id": "elite", "type": "elite", "content_id": elite if not elite.is_empty() else boss},
		{"id": "boss", "type": "boss", "content_id": boss},
		{"id": "shop", "type": "shop"}, {"id": "event", "type": "event"},
	]}

func _drain() -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while int(ScenePreloader.stats().queued) + int(ScenePreloader.stats().loading) > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.005).timeout
	_check("后台队列限流且能正常完成", ScenePreloader.stats().queued == 0 and ScenePreloader.stats().loading == 0)

func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

extends Node
const Hex = preload("res://systems/map/hex_coord.gd")
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const MAP_ENTRIES := ["res://ui/world_map/flat_2d/map_demo.tscn",
	"res://ui/world_map/flat_2d/map_run_demo.tscn", "res://ui/main_menu/menu_map_entry.tscn"]
const MENU := "res://ui/main_menu/main_menu.tscn"
var failures := 0
var fixture_root := ""

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	fixture_root = "res://.godot/map-entry-input-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("隔离测试存档", SaveGateway.load_current() == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-relic.json")
	# 测试节点留在 root，换场景不销毁测试协程。
	var menu: Node = load(MENU).instantiate()
	get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	await _frames(3)
	# 首次从地图 F6 启动时，磁盘已有本局，但还没有 current_run。
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "map-entry-input"
	_check("建立可继续的真实局", SaveGateway.start_new_run("map-entry-input-seed", config) == OK)
	_check("模拟冷启动已有存档", SaveGateway.load_current() == OK and SaveGateway.current_run() == null)
	for path: String in MAP_ENTRIES:
		_check("从未恢复本局的状态直接启动地图", SaveGateway.load_current() == OK and SaveGateway.current_run() == null)
		get_tree().change_scene_to_file(path)
		await _frames(8)
		var view: Node = get_tree().current_scene
		_check("地图入口可运行：" + path.get_file(), view.scene_file_path == path)
		_check("F6自动继续原存档而非新建覆盖", SaveGateway.current_run() != null and SaveGateway.current_run().run_id == "map-entry-input")
		var target := _approach(view)
		_check("存在可达敌人节点：" + path.get_file(), not target.is_empty())
		if target.is_empty():
			continue
		await _press_e()
		var scene: Node = get_tree().current_scene
		_check("真实E进入战斗且不弹模拟框：" + path.get_file(), scene.scene_file_path == EncounterFlow.BATTLE_SCENE)
		if scene.scene_file_path != EncounterFlow.BATTLE_SCENE:
			print("DIAG %s pending=%s dialog=%s" % [path, str(view.session.pending.get("node_id", "")), str(view._dialog.visible)])
			if not view.session.pending.is_empty():
				view.submit_node_result({"request_id": view.session.pending.request_id, "status": "cancelled"})
			get_tree().change_scene_to_file(MENU)
			await _frames(5)
			continue
		_check("战斗使用已分配的怪物", not scene._battle.enemies.is_empty() and TextCatalog.entry("monsters", str(scene._battle.enemies[0].enemy_id)).size() > 0)
		_check("开局已完成且玩家可编排，不停留在IDLE", scene._battle.active and scene._battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and not scene._busy and scene._battle.hand.size() > 0)
		var identity: String = SaveGateway.current_run().run_id
		scene._on_menu_return()
		await _frames(5)
		_check("原局身份和活动战斗保留", SaveGateway.current_run().run_id == identity and SaveGateway.current_run().current_battle != null)
		# 下一个地图入口必须恢复同一场待结算战斗，不重建或模拟完成它。
		_check("冷载入保存后的战斗", SaveGateway.load_current() == OK)
		get_tree().change_scene_to_file(path)
		await _frames(10)
		scene = get_tree().current_scene
		_check("同一入口冷恢复返回原战斗：" + path.get_file(), scene.scene_file_path == EncounterFlow.BATTLE_SCENE and SaveGateway.current_run().run_id == identity)
		if scene.scene_file_path == EncounterFlow.BATTLE_SCENE:
			var context := BattleEffectContext.new(scene._battle, scene._battle.enemies[0].enemy_id, scene._resolver.buff_catalog)
			context.damage_enemy(scene._battle.enemies[0].enemy_id, 999)
			await _frames(10)
			await preload("res://tests/support/reward_test_helper.gd").collect(get_tree())
			_check("胜利后回到统一地图", get_tree().current_scene.scene_file_path == EncounterFlow.MAP_SCENE)
			get_tree().current_scene._return_to_menu()
			await _frames(5)
	# 空档直接F6也要创建合法的真实局；新局只允许发生在空档。
	SaveGateway.save_path = fixture_root.path_join("fresh-game.json")
	_check("独立空存档夹具", SaveGateway.load_current() == OK and SaveGateway.current_run() == null)
	get_tree().change_scene_to_file(MAP_ENTRIES[0])
	await _frames(8)
	var new_map: Node = get_tree().current_scene
	_check("空档F6自动创建完整局内状态", new_map.scene_file_path == MAP_ENTRIES[0] and SaveGateway.current_run() != null and SaveGateway.current_run().active)
	_approach(new_map)
	await _press_e()
	_check("空档直接启动的地图也能用E进入战斗", get_tree().current_scene.scene_file_path == EncounterFlow.BATTLE_SCENE)
	print("地图入口真实输入：全部通过" if failures == 0 else "地图入口真实输入：失败%d项" % failures)
	get_tree().quit(failures)

func _approach(view: Node) -> String:
	view._set_paused(false)
	var reachable: Dictionary = view.session.reachable()
	for id: String in view.session.nodes:
		var node: Dictionary = view.session.nodes[id]
		if node.type not in ["battle", "elite"] or view.session.completed.has(id):
			continue
		for point: Array in node.footprint:
			for cell: Vector2i in Hex.neighbors(Session.coord(point)):
				var plane: Vector2 = Hex.to_plane(cell, 1.0)
				if reachable.has(Session.key(cell)) and view.session.can_stand(plane):
					view.session.actor_plane = plane
					if id not in view.session.nearby_nodes():
						continue
					view._sync_actor(false)
					view._selected = id
					view._manual_selection = true
					view._selection_origin = plane
					return id
	return ""

func _press_e() -> void:
	await preload("res://tests/support/presentation_test_helper.gd").route_ready(get_tree())
	var key := InputEventKey.new()
	key.keycode = KEY_E
	key.physical_keycode = KEY_E
	key.pressed = true
	get_viewport().push_input(key, true)
	await _frames(5)
	key = key.duplicate()
	key.pressed = false
	get_viewport().push_input(key, true)
	await _frames(3)

func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame
	await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())
	# 抽牌/结算表现异步播放；真实交互测试须等待可操作，不能用固定帧数猜测。
	var battle := get_tree().current_scene as BattleTestScene
	if battle != null and battle._battle != null and not battle._battle.rules.queue.paused:
		await preload("res://tests/support/presentation_test_helper.gd").battle_settled(battle)
		await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())

func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

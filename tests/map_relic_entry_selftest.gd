extends "res://tests/map_entry_input_selftest.gd"
## 使用曾导致首抽秒杀的布局，验证自然抽牌不触发典籍；只写隔离夹具。
const BOARD_CELLS := ["turn_strength", "on_card_gained", "gain_block", "deal_damage",
	"on_card_gained", "deal_damage", "on_enemy_damaged", "deal_damage",
	"deal_damage", "gain_block", "gain_block", "turn_strength"]

func _run() -> void:
	fixture_root = "res://.godot/map-relic-entry-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("隔离真实档案", SaveGateway.load_current() == OK)
	DirAccess.make_dir_recursive_absolute(fixture_root)
	EncounterFlow.relic_board_path = fixture_root.path_join("board.json")
	var board := RelicBoard.new()
	board.cells.assign(BOARD_CELLS)
	_check("复刻首抽连锁棋盘", board.save_to_file(EncounterFlow.relic_board_path) == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "map-relic-entry"
	config.initial_deck = []
	_check("建立空牌组真实局", SaveGateway.start_new_run("map-entry-input-seed", config) == OK)
	# 明确只给此隔离测试注入构筑，正式新局不再读取全局测试棋盘。
	SaveGateway.current_run().inventory_state.relic_board = board.to_dictionary()
	var view: Node = load(MAP_ENTRIES[0]).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	var target := _approach(view)
	_check("存在可达节点", not target.is_empty())
	await _press_e()
	var scene: Node = get_tree().current_scene
	print("DIAG after E: scene=%s current_battle=%s completed=%s" % [scene.scene_file_path, SaveGateway.current_run().current_battle, EncounterFlow.session.completed.has(target)])
	_check("原秒杀棋盘仍正常进入战斗界面", scene.scene_file_path == EncounterFlow.BATTLE_SCENE)
	if scene.scene_file_path == EncounterFlow.BATTLE_SCENE:
		var initial_health := int(scene._battle.enemies[0].max_health)
		_check("首抽受10张上限约束且不触发伤害格挡，玩家仍可出牌", scene._battle.active and scene._battle.hand.size() == 10 and int(scene._battle.enemies[0].health) == initial_health and int(scene._battle.player.block) == 0 and not scene._busy)
		_check("仅两个存在类力量生效，不弹胜利窗口", scene._relics.activation_count == 2 and scene.get_node_or_null("OpeningBattleResult") == null)
		_check("首抽结束后提示已切换到玩家编排", scene.hint_label.text.contains("请选择手牌"))
		await _frames(30)
		_check("停留战场，节点尚未错误结算", get_tree().current_scene == scene and not EncounterFlow.session.completed.has(target) and SaveGateway.current_run().current_battle == scene._battle)
		await _capture_battle()
		# 预留自然补牌与效果抽牌空间，不再依赖旧版无限手牌。
		for index in 3: scene._battle.discard_from_hand(str(scene._battle.hand[0].instance_id))
		var natural_draws := [0]
		scene._battle.rules.register_rule("test.natural_count", "card.drawn", func(event: BattleEvent):
			if int(event.payload.get("draw_reason", 0)) == BattleStateMachine.DrawReason.TURN_START: natural_draws[0] += 1)
		_check("正常切换到次回合", scene._battle.end_player_action() == OK)
		while scene._battle.rules.queue.paused and not scene._battle.player.get("battle_choice", {}).is_empty():
			var candidates: Array = scene._battle.player.battle_choice.candidates
			var ids: Array[String] = [str(candidates[0].instance_id)]
			scene._battle.submit_battle_choice(ids)
		_check("回合抽牌2张不触发典籍伤害格挡", scene._battle.turn_number == 2 and int(natural_draws[0]) == 2 and int(scene._battle.enemies[0].health) == initial_health and int(scene._battle.player.block) == 0 and scene._relics.activation_count == 4)
		# 此用例只测首抽/自然补牌隔离与效果抽牌致死，不绑死正式怪物血量。
		scene._battle.enemies[0].health = 3
		var context := BattleEffectContext.new(scene._battle, str(scene._battle.enemies[0].enemy_id), scene._resolver.buff_catalog)
		context.draw(1)
		_check("效果抽牌仍正常触发连锁并击败敌人", not scene._battle.active and scene._battle_result == "victory" and scene._relics.activation_count > 4)
		await _frames(10)
		await preload("res://tests/support/reward_test_helper.gd").collect(get_tree())
		_check("效果胜利仍完成节点并返回地图", get_tree().current_scene.scene_file_path == EncounterFlow.MAP_SCENE and get_tree().current_scene.session.completed.has(target))
		_check("玩家典籍配置未被禁用或改写", board.cells == BOARD_CELLS and SaveGateway.current_run().active)
	print("典籍首抽入场：全部通过" if failures == 0 else "典籍首抽入场：失败%d项" % failures)
	get_tree().quit(failures)

func _capture_battle() -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join("natural-draw-playable.png"))

extends Node

var failures := 0
var _catalog: Dictionary
var _battle_index := 400


func _ready() -> void:
	SeedService.begin_run("relic-system-selftest")
	_catalog = RelicCatalog.load_definitions()
	_check("五种测试残片从 CSV 读取", _catalog.size() == 5)
	_test_geometry_and_save()
	_test_draw_four()
	_test_damage_eight_and_repeat_events()
	_test_presence_and_buff_interaction()
	_test_cycle()
	_test_chain_budget()
	_test_lethal_draw()
	_test_inactive_effect()
	print("典籍系统全部通过" if failures == 0 else "典籍系统失败 %d 项" % failures)
	get_tree().quit(failures)


func _test_geometry_and_save() -> void:
	var board := RelicBoard.new()
	_check("页面固定 12 格", board.cells.size() == 12)
	_check("四格角落不越界", board.neighbors(0, RelicFragmentData.Reach.FOUR) == [1, 4])
	_check("四格中心只包含上下左右", board.neighbors(5, RelicFragmentData.Reach.FOUR) == [1, 4, 6, 9])
	_check("八格中心包含四个对角", board.neighbors(5, RelicFragmentData.Reach.EIGHT) == [0, 1, 2, 4, 6, 8, 9, 10])
	_check("最右格不跨行相连", board.neighbors(3, RelicFragmentData.Reach.EIGHT) == [2, 6, 7])
	board.place(2, "gain_block", _catalog)
	board.place(6, "deal_damage", _catalog)
	board.swap_cells(2, 6)
	_check("移动到占用格会交换而非丢失", board.cells[2] == "deal_damage" and board.cells[6] == "gain_block")
	var path := "res://.godot/relic_roundtrip_test.json"
	_check("配置可保存", board.save_to_file(path) == OK)
	_check("已有配置可再次保存替换", board.save_to_file(path) == OK)
	var restored := RelicBoard.new()
	_check("存档精确恢复布局", restored.load_from_file(_catalog, path) == OK and restored.cells == board.cells)
	DirAccess.remove_absolute(path)
	var malformed := board.to_dictionary()
	malformed["cells"][0] = "unknown"
	_check("未知残片数据被拒绝且原布局保留", restored.restore(malformed, _catalog) == ERR_INVALID_DATA and restored.cells == board.cells)


func _test_draw_four() -> void:
	var setup := _setup(_board({0: "on_card_gained", 1: "gain_block", 4: "gain_block", 5: "deal_damage"}))
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	battle.draw_cards(1)
	_check("抽牌触发两个相邻格挡", int(battle.player.block) == 2)
	_check("四格不激活对角伤害", int(battle.enemies[0].health) == 100)
	_cleanup(setup)


func _test_damage_eight_and_repeat_events() -> void:
	var setup := _setup(_board({5: "on_enemy_damaged", 0: "gain_block", 10: "deal_damage"}))
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	battle.apply_damage_to_enemy("enemy", 8)
	_check("八格触发对角 2 点伤害且无无限回跳", int(battle.enemies[0].health) == 90)
	_check("八格触发对角格挡", int(battle.player.block) == 1)
	battle.apply_damage_to_enemy("enemy", 8)
	_check("下一独立伤害事件可再次触发", int(battle.enemies[0].health) == 80 and int(battle.player.block) == 2)
	battle.apply_damage_to_enemy("enemy", 0)
	_check("零伤害不触发残片", int(battle.player.block) == 2)
	battle.apply_damage_to_player(3)
	_check("玩家自伤不触发敌人伤害条件", int(battle.enemies[0].health) == 80)
	battle.add_block(&"enemy", "enemy", 8)
	battle.apply_damage_to_enemy("enemy", 8)
	_check("全部被格挡的伤害不触发", int(battle.enemies[0].health) == 80)
	_cleanup(setup)


func _test_presence_and_buff_interaction() -> void:
	var setup := _setup(_board({0: "on_card_gained", 1: "deal_damage", 11: "turn_strength"}), 100, 1)
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	_check("存在类独立生效，首回合力量为 1", _strength(battle) == 1)
	_check("抽牌触发的 2 点伤害受力量影响变为 3", int(battle.enemies[0].health) == 97)
	var sequence: Array[String] = [String(battle.hand[0].instance_id)]
	battle.commit_player_sequence(sequence)
	_check("进入第二玩家回合重新获得力量且不跨回合累积", battle.turn_number == 2 and _strength(battle) == 1)
	_check("格挡仍在敌方回合末清零", int(battle.player.block) == 0)
	_cleanup(setup)


func _test_cycle() -> void:
	var setup := _setup(_board({1: "on_enemy_damaged", 6: "on_enemy_damaged", 5: "deal_damage"}))
	var battle: BattleStateMachine = setup.battle
	var relics: RelicBattleSystem = setup.relics
	battle.start_battle()
	battle.apply_damage_to_enemy("enemy", 8)
	_check("两个伤害触发器可互联但每条路径不重复", int(battle.enemies[0].health) == 84 and relics.activation_count == 4)
	_cleanup(setup)


func _test_chain_budget() -> void:
	var board := RelicBoard.new()
	for index in RelicBoard.CELL_COUNT:
		board.place(index, "on_enemy_damaged" if index < 6 else "deal_damage", _catalog)
	var setup := _setup(board, 100000)
	var battle: BattleStateMachine = setup.battle
	var relics: RelicBattleSystem = setup.relics
	var limit_events: Array[int] = [0]
	relics.chain_limited.connect(func() -> void: limit_events[0] += 1)
	battle.start_battle()
	battle.apply_damage_to_enemy("enemy", 1)
	_check("高密度连锁在 128 个效果内停止且发出提示", relics.activation_count == 128 and limit_events[0] == 1)
	_cleanup(setup)


func _test_lethal_draw() -> void:
	var setup := _setup(_board({0: "on_card_gained", 1: "deal_damage"}), 1)
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	_check("抽牌触发伤害可完成调用", battle.draw_cards(2) == OK)
	_check("抽牌致死立即胜利并停止后续抽牌", not battle.active and battle.phase == BattleStateMachine.Phase.VICTORY and battle.hand.size() == 1)
	_cleanup(setup)
	setup = _setup(_board({0: "on_card_gained", 1: "deal_damage"}), 1, 2)
	battle = setup.battle
	battle.start_battle()
	_check("状态机首抽致死不会被后续回合阶段覆盖", not battle.active and battle.phase == BattleStateMachine.Phase.VICTORY and battle.hand.size() == 1)
	_cleanup(setup)


func _test_inactive_effect() -> void:
	var setup := _setup(_board({0: "deal_damage", 11: "gain_block"}))
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	battle.draw_cards(1)
	_check("无触发条件的效果残片不自行生效", int(battle.enemies[0].health) == 100 and int(battle.player.block) == 0)
	_cleanup(setup)


func _setup(board: RelicBoard, enemy_health: int = 100, opening_draw_count: int = 0) -> Dictionary:
	_battle_index += 1
	var battle := BattleStateMachine.new()
	add_child(battle)
	var deck: Array[Dictionary] = [
		{"instance_id": "test-1", "card_id": "test_block"},
		{"instance_id": "test-2", "card_id": "test_block"},
	]
	var error := battle.initialize_battle({
		"map_id": "relic-test", "node_id": "test", "battle_index": _battle_index,
		"draw_count": opening_draw_count, "player": {"health": 100, "max_health": 100, "block": 0, "buffs": []},
		"enemies": [{"enemy_id": "enemy", "health": enemy_health, "max_health": enemy_health,
			"block": 0, "buffs": [], "actions": [{"damage": 6}]}], "deck_instances": deck,
	})
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	_check("战斗效果适配层接入", error == OK and resolver.attach_to_battle(battle) == OK)
	var relics := RelicBattleSystem.new()
	add_child(relics)
	_check("典籍接入战斗", relics.attach_to_battle(battle, board, _catalog, resolver.buff_catalog) == OK)
	# 战斗冻结构筑副本，编辑原配置不影响已经启动的战斗。
	board.cells.fill("")
	return {"battle": battle, "resolver": resolver, "relics": relics}


func _board(placements: Dictionary) -> RelicBoard:
	var board := RelicBoard.new()
	for index: int in placements:
		board.place(index, placements[index], _catalog)
	return board


func _strength(battle: BattleStateMachine) -> int:
	for buff: Dictionary in battle.player.buffs:
		if buff.buff_id == "strength":
			return int(buff.layers)
	return 0


func _cleanup(setup: Dictionary) -> void:
	(setup.relics as Node).free()
	(setup.resolver as Node).free()
	(setup.battle as Node).free()


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("  %s  %s" % ["通过" if passed else "失败", label])

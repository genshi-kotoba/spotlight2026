extends Node

var failures := 0
var _catalog: Dictionary
var _battle_index := 400


func _ready() -> void:
	SeedService.begin_run("relic-system-selftest")
	_catalog = RelicCatalog.load_definitions()
	_check("五种原型残片与33条正式残片均可读取", _catalog.keys().filter(func(id: String): return not id.contains("~")).size() == 38 and _catalog.has("on_card_gained") and _catalog.has("FRG-033"))
	_check("退役残片保留旧档解析但不生成或生效", _catalog.has("FRG-021") and "FRG-021" not in RelicCatalog.reward_ids(_catalog) and _catalog["FRG-021"].action_id.is_empty() and _catalog["FRG-021"].amount == 0)
	_test_geometry_and_save()
	_test_draw_four()
	_test_natural_draws()
	_test_eight_damage()
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
	_check("页面固定4列5行20格，初始开放9格", RelicBoard.COLUMNS == 4 and RelicBoard.ROWS == 5 and board.cells.size() == 20 and board.unlocked_cells == RelicBoard.DEFAULT_UNLOCKED)
	_check("封锁格拒绝放入且不改变板面", board.place(3, "gain_block", _catalog) == ERR_INVALID_PARAMETER and board.cells[3].is_empty())
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
	_check("存档精确恢复布局", restored.load_from_file(_catalog, path) == OK and restored.cells == board.cells and restored.unlocked_cells == board.unlocked_cells)
	DirAccess.remove_absolute(path)
	var malformed := board.to_dictionary()
	malformed["cells"][0] = "unknown"
	_check("未知残片数据被拒绝且原布局保留", restored.restore(malformed, _catalog) == ERR_INVALID_DATA and restored.cells == board.cells and restored.unlocked_cells == board.unlocked_cells)


func _test_draw_four() -> void:
	var setup := _setup(_board({0: "on_card_gained", 1: "gain_block", 4: "gain_block", 5: "deal_damage"}))
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	battle.draw_cards(1)
	_check("抽牌触发两个相邻格挡", int(battle.player.block) == 2)
	battle.draw_cards(1)
	_check("下一次效果抽牌仍可再次触发", int(battle.player.block) == 4)
	_check("四格不激活对角伤害", int(battle.enemies[0].health) == 100)
	_cleanup(setup)


func _test_eight_damage() -> void:
	# 采用正式的八邻域格挡触发器；伤害效果不会反过来满足自身条件。
	var setup := _setup(_board({5: "FRG-005", 0: "gain_block", 10: "deal_damage"}))
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	battle.add_block(&"player", "player", 1)
	battle.apply_damage_to_player(1)
	_check("正式八格触发器激活对角2点伤害和1点格挡", int(battle.enemies[0].health) == 98 and int(battle.player.block) == 1 and setup.relics.activation_count == 2)
	battle.apply_damage_to_player(1)
	_check("下一次独立格挡事实可再次触发八格效果", int(battle.enemies[0].health) == 96 and int(battle.player.block) == 1 and setup.relics.activation_count == 4)
	_cleanup(setup)


func _test_damage_eight_and_repeat_events() -> void:
	# 伤害条件只联动格挡，单独验证来源/零伤害/全格挡，不混入会再次满足条件的伤害效果。
	var setup := _setup(_board({5: "on_enemy_damaged", 0: "gain_block", 10: "gain_block"}))
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	battle.apply_damage_to_enemy("enemy", 8)
	_check("对敌人伤害触发八格内两个对角效果", int(battle.enemies[0].health) == 92 and int(battle.player.block) == 2)
	battle.apply_damage_to_enemy("enemy", 8)
	_check("下一独立伤害事件可再次触发", int(battle.enemies[0].health) == 84 and int(battle.player.block) == 4)
	var count: int = int(setup.relics.activation_count)
	battle.apply_damage_to_enemy("enemy", 0)
	_check("零伤害不触发残片", int(battle.player.block) == 4 and setup.relics.activation_count == count)
	battle.apply_damage_to_player(3, true)
	_check("玩家自伤不触发敌人伤害条件", int(battle.enemies[0].health) == 84 and setup.relics.activation_count == count)
	battle.add_block(&"enemy", "enemy", 8)
	battle.apply_damage_to_enemy("enemy", 8)
	_check("全部被格挡的伤害不触发", int(battle.enemies[0].health) == 84 and setup.relics.activation_count == count)
	_cleanup(setup)


func _test_presence_and_buff_interaction() -> void:
	var setup := _setup(_board({0: "on_card_gained", 1: "deal_damage", 10: "turn_strength"}), 100, 1)
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	_check("存在类独立生效，首回合力量为 1", _strength(battle) == 1)
	_check("首抽不触发典籍伤害", int(battle.enemies[0].health) == 100)
	var context := BattleEffectContext.new(battle, "enemy", setup.resolver.buff_catalog)
	context.draw(1)
	_check("效果抽牌仍触发典籍且受力量影响", int(battle.enemies[0].health) == 97)
	var sequence: Array[String] = [String(battle.hand[0].instance_id)]
	battle.commit_player_sequence(sequence)
	_check("进入第二玩家回合重新获得力量且不跨回合累积", battle.turn_number == 2 and _strength(battle) == 1)
	_check("第二回合自然抽牌也不触发典籍伤害", int(battle.enemies[0].health) == 97)
	_check("格挡仍在敌方回合末清零", int(battle.player.block) == 0)
	_cleanup(setup)


func _test_cycle() -> void:
	# 两个八格触发器的自身条件不同，效果只加格挡；分别控制谁补充中继次数。
	var setup := _setup(_board({1: "FRG-005", 6: "on_enemy_damaged", 5: "gain_block"}))
	var battle: BattleStateMachine = setup.battle
	var relics: RelicBattleSystem = setup.relics
	battle.start_battle()
	battle.add_block(&"player", "player", 1)
	battle.apply_damage_to_player(1)
	_check("互联触发器各消费中继次数后停止，不无限回跳", int(battle.player.block) == 3 and relics.activation_count == 3 and not bool(relics.state().chain_charges["1"]) and not bool(relics.state().chain_charges["6"]))
	battle.apply_damage_to_player(1)
	_check("另一条件未发生时不因新事件补充邻居中继次数", int(battle.player.block) == 3 and relics.activation_count == 4 and not bool(relics.state().chain_charges["6"]))
	battle.apply_damage_to_enemy("enemy", 8)
	_check("邻居自身条件发生后重新允许有限连锁", int(battle.enemies[0].health) == 92 and int(battle.player.block) == 6 and relics.activation_count == 7)
	_cleanup(setup)


func _test_chain_budget() -> void:
	var board := RelicBoard.new()
	_check("高密度夹具显式开放全部格子", board.set_unlocked_cells(range(RelicBoard.CELL_COUNT)) == OK)
	var placed := true
	# 一个条件反复补充、周围密集效果：明确触及128效果预算，避免先触及多触发器的512传播预算。
	for index in RelicBoard.CELL_COUNT:
		placed = board.place(index, "on_enemy_damaged" if index == 5 else "deal_damage", _catalog) == OK and placed
	_check("高密度夹具每个残片均实际装入", placed)
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
	_check("状态机首抽不触发致死典籍，完整抽两张后可出牌", battle.active and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and battle.hand.size() == 2 and int(battle.enemies[0].health) == 1)
	_cleanup(setup)


func _test_natural_draws() -> void:
	var setup := _setup(_board({0: "on_card_gained", 1: "deal_damage", 4: "gain_block", 10: "turn_strength"}), 100, 2)
	var battle: BattleStateMachine = setup.battle
	var reasons: Array[int] = []
	battle.rules.register_rule("test.draw_sources", "card.drawn", func(event: BattleEvent) -> void:
		reasons.append(int(event.payload.draw_reason)))
	battle.start_battle()
	_check("多张首抽保留事实与来源，不漏标后续张数", reasons == [BattleStateMachine.DrawReason.BATTLE_START, BattleStateMachine.DrawReason.BATTLE_START] and battle.hand.size() == 2)
	_check("自然首抽不触发伤害或格挡，存在类力量照常生效", int(battle.enemies[0].health) == 100 and int(battle.player.block) == 0 and _strength(battle) == 1 and setup.relics.activation_count == 1)
	var sequence: Array[String] = [str(battle.hand[0].instance_id)]
	battle.commit_player_sequence(sequence)
	_check("次回合洗回弃牌后仍标记为自然抽牌", battle.turn_number == 2 and reasons.size() == 3 and reasons.back() == BattleStateMachine.DrawReason.TURN_START)
	_check("回合抽牌无典籍连锁，存在类每回合只生效一次", int(battle.enemies[0].health) == 100 and int(battle.player.block) == 0 and _strength(battle) == 1 and setup.relics.activation_count == 2)
	_cleanup(setup)


func _test_inactive_effect() -> void:
	var setup := _setup(_board({0: "deal_damage", 10: "gain_block"}))
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
	var placed := true
	for index: int in placements:
		placed = board.place(index, placements[index], _catalog) == OK and placed
	_check("夹具残片均装入已开放格子", placed)
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

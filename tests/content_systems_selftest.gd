extends Node
var failures := 0
var serial := 0
class EventSession extends RefCounted:
	var map_id := "map-001"
	var pending: Dictionary = {}

func _ready() -> void:
	call_deferred("_run")

func _check(label: String, value: bool) -> void:
	if not value: failures += 1
	print(("通过 " if value else "失败 ") + label)

func _run() -> void:
	SeedService.begin_run("content-systems-fixed-seed")
	_check("正式残片33条、普通奖励26条、负面7条", TextCatalog.entries("fragments").size() == 33 and RelicCatalog.reward_ids().size() == 26 and RelicCatalog.negative_ids(RelicCatalog.load_definitions()).size() == 7)
	var board := RelicBoard.new()
	_check("行、列、上下、全局范围", board.neighbors(5, RelicFragmentData.Reach.ROW) == [4, 6, 7] and board.neighbors(5, RelicFragmentData.Reach.COLUMN) == [1, 9] and board.neighbors(5, RelicFragmentData.Reach.VERTICAL) == [1, 9] and board.neighbors(5, RelicFragmentData.Reach.ALL).size() == 11)
	_test_monsters()
	_test_nullification()
	_test_relics()
	_test_relic_contracts()
	_test_potions()
	await _test_events()
	print("内容系统回归全部通过" if failures == 0 else "内容系统回归失败 %d 项" % failures)
	get_tree().quit(failures)

func _setup(monster: String, fragment_cells: Dictionary = {}, deck: Array = []) -> Dictionary:
	serial += 1
	var enemy := MonsterCatalog.create(monster, 2)
	var battle := BattleStateMachine.new()
	add_child(battle)
	var instances: Array = []
	var cards: Array = deck if not deck.is_empty() else ["test_damage_enemy", "test_block", "test_heal", "test_damage_enemy"]
	for index in cards.size(): instances.append({"instance_id": "test-%d-%d" % [serial, index], "card_id": str(cards[index])})
	var error := battle.initialize_battle({"map_id": "map-001", "node_id": "monster-%d" % serial, "battle_index": serial,
		"draw_count": 0, "player": {"health": 10000, "max_health": 10000, "block": 0, "silver": 1000, "base_play_limit": 10},
		"enemies": [enemy], "deck_instances": instances})
	var resolver := BattleEffectResolver.new()
	battle.add_child(resolver)
	error = resolver.attach_to_battle(battle) if error == OK else error
	var relics := RelicBattleSystem.new()
	battle.add_child(relics)
	var board := RelicBoard.new()
	for index: int in fragment_cells: board.cells[index] = str(fragment_cells[index])
	error = relics.attach_to_battle(battle, board, RelicCatalog.load_definitions(), resolver.buff_catalog) if error == OK else error
	_check("初始化怪物%s" % monster, error == OK)
	battle.start_battle()
	battle.draw_cards(20, BattleStateMachine.DrawReason.BATTLE_START)
	return {"battle": battle, "resolver": resolver, "relics": relics}

func _attack(setup: Dictionary, amount: int, target := "", metadata: Dictionary = {}) -> void:
	var battle: BattleStateMachine = setup.battle
	metadata["source_card"] = str(battle.hand[0].instance_id) if not battle.hand.is_empty() else "test-source"
	battle.rules.submit("action.damage", {"side": "enemy", "target": str(battle.enemies[0].enemy_id) if target.is_empty() else target,
		"amount": amount, "ignore_block": false, "use_stats": true, "source_side": "player", "source_id": "player"}, metadata)

func _end_turn(battle: BattleStateMachine) -> void:
	battle.end_player_action()
	var guard := 0
	while battle.active and battle.rules.queue.paused and guard < 10:
		guard += 1
		var choice: Dictionary = battle.player.get("battle_choice", {})
		if not choice.is_empty():
			var ids: Array[String] = [str(choice.candidates[0].instance_id)]
			battle.submit_battle_choice(ids)
		else: break

func _test_monsters() -> void:
	for index in range(1, 24):
		var setup := _setup(str(index))
		var battle: BattleStateMachine = setup.battle
		_end_turn(battle)
		_check("怪物%d完成整回合并返回行动阶段" % index, battle.active and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and battle.turn_number == 2 and not battle.rules.queue.paused)
		if index in [17, 23]: _check("临时BOSS100血每回合10攻击", int(battle.enemies[0].max_health) == 100 and int(battle.player.health) == 9990)
		battle.free()
	var setup := _setup("11")
	var battle: BattleStateMachine = setup.battle
	_attack(setup, 999)
	_check("公爵致死变身而不提前胜利，并召唤两名随从", battle.active and battle.enemies.size() == 3 and int(battle.enemies[0].health) == 96 and int(battle.enemies[0].phase) == 2)
	battle.free()
	setup = _setup("19")
	battle = setup.battle
	_attack(setup, 7)
	_check("赎罪反射实际掉血", int(battle.enemies[0].health) == 92 and int(battle.player.health) == 9993)
	_end_turn(battle)
	_check("无效化通过队列暂停选择且整场保留", battle.hand.any(func(c: Dictionary): return bool(c.get("nullified", false))))
	battle.free()
	setup = _setup("18")
	battle = setup.battle
	for turn in 5: _end_turn(battle)
	_check("圣母超过5回合玩家1血无奖励退出", not battle.active and int(battle.player.health) == 1)
	battle.free()
	setup = _setup("15")
	battle = setup.battle
	_check("盗贼入场偷30%且每20币1层虚弱", int(battle.player.silver) == 700 and _layers(battle.enemies[0], "weak") == 15)
	_attack(setup, 999)
	_check("盗贼退还奖励单独计算扣50每回合", int(battle.player.get("stolen_refund", 0)) == 250)
	battle.free()
	setup = _setup("10")
	battle = setup.battle
	_end_turn(battle)
	_check("拾骨之年召唤嘲讽实验耗材并结算DOT", battle.enemies.size() == 2 and bool(battle.enemies[1].taunt) and int(battle.player.health) == 9990)
	_attack(setup, 100, str(battle.enemies[0].enemy_id))
	_check("嘲讽改变目标且耗材死亡给予BOSS力量", int(battle.enemies[0].health) == 135 and int(battle.enemies[1].health) == 0 and _layers(battle.enemies[0], "strength") == 2)
	battle.free()

func _layers(entity: Dictionary, id: String) -> int:
	for buff: Dictionary in entity.buffs:
		if str(buff.buff_id) == id: return int(buff.layers)
	return 0

func _test_nullification() -> void:
	var setup := _setup("20", {}, ["1", "1", "1", "1", "1"])
	var battle: BattleStateMachine = setup.battle
	var ids := ["1", "68", "67", "70", "69"]
	for index in ids.size():
		battle.hand[index].card_id = ids[index]
		battle.hand[index]["nullified"] = true
	var subject := str(battle.hand[0].instance_id)
	battle.hand[0]["enchantments"] = ["repeat_2"]
	battle.set_player_block(20)
	var resolutions := [0]
	battle.card_effect_requested.connect(func(_card: Dictionary, _target: Variant, _index: int): resolutions[0] += 1)
	var order: Array[String] = [subject]
	battle.commit_player_sequence(order)
	_check("无效化同时阻止主动伤害和重复附魔", int(battle.enemies[0].health) == 80 and int(resolutions[0]) == 1)
	_check("无效化阻止68扣血、67蓄积、69右侧诅咒", int(battle.player.health) == 10000 and battle.hand.size() == 4 and battle.hand.all(func(c: Dictionary): return int(c.get("recorded_block", 0)) == 0))
	# 无效化的70号不能给左侧仍有效的攻击牌提供增伤。
	var live := str(battle.discard_pile[0].instance_id)
	battle.discard_pile[0].nullified = false
	battle.discard_pile[0].enchantments = []
	battle.hand.push_front(battle.discard_pile.pop_front())
	order.assign([live])
	battle.commit_player_sequence(order)
	_check("无效化70号不提供手牌光环", int(battle.enemies[0].health) == 75)
	battle.free()

func _test_relic_contracts() -> void:
	# 检查每种正式触发入口，而不通过UI直接执行残片效果。
	var cases := [
		["FRG-002", 5, 1, "pointer.moved", {"distance": 4, "automatic": true}],
		["FRG-004", 0, 1, "card.discarded", {"from_hand": true, "card": {"card_id": "1", "instance_id": "fixture"}}],
		["FRG-005", 0, 5, "combatant.damaged", {"side": "player", "blocked": 1, "health_loss": 0, "damage": 1}],
		["FRG-006", 0, 1, "combatant.damaged", {"side": "player", "blocked": 0, "health_loss": 1, "damage": 1}],
		["FRG-007", 0, 1, "pointer.moved", {"distance": 1, "automatic": false}],
		["FRG-008", 5, 1, "combatant.damaged", {"side": "enemy", "entity_id": "20", "health_loss": 1, "damage": 1, "health_after": 79}],
		["FRG-009", 0, 11, "enemy.died", {"enemy_id": "fixture"}],
	]
	for fixture: Array in cases:
		var setup := _setup("20", {int(fixture[1]): str(fixture[0]), int(fixture[2]): "FRG-016"})
		var battle: BattleStateMachine = setup.battle
		battle.rules.submit(str(fixture[3]), fixture[4], {"dot": str(fixture[0]) == "FRG-008"})
		_check("正式触发入口%s只结算一次范围内效果" % str(fixture[0]), int(battle.player.block) == 1)
		battle.free()
	var setup := _setup("20", {0: "FRG-010", 1: "FRG-016"})
	var battle: BattleStateMachine = setup.battle
	battle.enemies[0].block = 100
	for index in 5: _attack(setup, 1)
	_check("五次攻击计数含被格挡攻击且每五次触发", int(battle.player.block) == 1 and int(battle.enemies[0].health) == 80)
	battle.free()
	setup = _setup("20", {0: "FRG-001", 1: "FRG-013", 4: "FRG-018"})
	battle = setup.battle
	battle.add_generated_card("1", "hand", "test"); battle.rules.flush()
	_attack(setup, 1)
	_attack(setup, 1)
	# 同一张伤害牌的多段伤害均+2；下一张不同牌只受本回合+1。
	battle.hand.reverse()
	_attack(setup, 1)
	_check("本回合增伤与下一张伤害牌加成独立", int(battle.enemies[0].health) == 70)
	battle.free()
	setup = _setup("20", {0: "FRG-001~FRG-029", 1: "FRG-016"})
	battle = setup.battle
	var size := battle.hand.size()
	battle.add_generated_card("1", "hand", "test"); battle.rules.flush()
	_check("触发负面强制弃最右牌", battle.hand.size() == size and not battle.discard_pile.is_empty())
	battle.free()
	setup = _setup("20", {0: "FRG-001~FRG-030", 1: "FRG-016", 2: "FRG-026", 3: "FRG-027", 4: "FRG-023"})
	battle = setup.battle
	battle.enemies[0].health = 60
	battle.add_generated_card("1", "hand", "test"); battle.rules.flush()
	_check("触发负面给敌人回复5血", int(battle.enemies[0].health) == 65)
	_check("减少弃牌机会并增加自然抽牌", setup.relics.manual_discard_count() == 0 and setup.relics.natural_draw_count(5) == 6)
	battle.turn_number = 3
	_check("第三回合起自然抽牌减少1", setup.relics.natural_draw_count(5) == 5)
	battle.free()
	setup = _setup("20", {0: "FRG-005", 1: "FRG-017"}, ["1", "1", "1", "1", "1", "1", "1", "1", "1", "1", "1"])
	battle = setup.battle
	battle.discard_from_hand(str(battle.hand[0].instance_id))
	# 保留一张待抽卡，敌方回合格挡触发的抽牌也必须正常入队。
	if battle.draw_pile.is_empty(): battle.draw_pile.append(battle.discard_pile.pop_back())
	battle.set_player_block(10)
	_end_turn(battle)
	_check("敌方回合格挡成功也能触发残片抽牌", setup.relics.activation_count >= 1 and battle.hand.size() == 10)
	battle.free()
	_check("玫瑰园增加选项数量", RelicCatalog.choice_bonus(["FRG-021"]) == 1)
	setup = _setup("20", {0: "FRG-001", 1: "FRG-015"})
	battle = setup.battle
	battle.change_buff_layers(&"enemy", "20", "poison", 4)
	battle.change_buff_layers(&"enemy", "20", "weak", 1, 1)
	battle.add_generated_card("1", "hand", "test"); battle.rules.flush()
	_end_turn(battle)
	_check("debuff延长保留毒层数并保留虚弱一回合", _layers(battle.enemies[0], "poison") == 4 and _layers(battle.enemies[0], "weak") == 1)
	battle.free()
	setup = _setup("20", {0: "FRG-001", 1: "FRG-012"})
	battle = setup.battle
	# 概率由种子固定。重复独立事实，验证有命中且不突破同卡两种不同附魔上限。
	for index in 300:
		battle.rules.submit("card.drawn", {"card": battle.hand[0], "draw_reason": BattleStateMachine.DrawReason.EFFECT})
	_check("5%附魔命中且不重复叠加相同附魔", battle.hand.any(func(c: Dictionary): return not c.get("enchantments", []).is_empty()) and battle.hand.all(func(c: Dictionary): return c.get("enchantments", []).size() <= 2 and (c.get("enchantments", []).size() < 2 or c.enchantments[0] != c.enchantments[1])))
	battle.free()

func _test_relics() -> void:
	var setup := _setup("20", {0: "FRG-001", 1: "FRG-016", 4: "FRG-031", 11: "FRG-022"})
	var battle: BattleStateMachine = setup.battle
	_check("开局和自然抽牌不激活残片", int(battle.player.block) == 0 and _layers(battle.enemies[0], "poison") == 0 and setup.relics.activation_count == 0)
	battle.add_generated_card("test_block", "hand", "test")
	battle.rules.flush()
	_check("效果获得卡牌触发四邻效果及愚人自动伤害", int(battle.player.block) == 1 and _layers(battle.enemies[0], "poison") == 2 and int(battle.enemies[0].health) == 78)
	battle.free()
	setup = _setup("20", {0: "FRG-023", 1: "FRG-025", 2: "FRG-020"}, ["test_block", "test_block", "test_block", "test_block", "test_block", "test_block", "test_block", "test_block", "test_block", "test_block", "test_block"])
	battle = setup.battle
	_check("手牌基础上限10减2后只能持有8张", battle.hand.size() == 8 and int(battle.player.hand_limit) == 8)
	_attack(setup, 8)
	_check("敌人少于3名每少1名伤害加1", int(battle.enemies[0].health) == 70)
	var size := battle.hand.size()
	setup.relics.request_manual_discard()
	_check("每回合手动弃牌机会暂停队列", battle.rules.queue.paused)
	var ids: Array[String] = [str(battle.hand[0].instance_id)]
	battle.submit_battle_choice(ids)
	_check("手动弃牌只弃一张不补抽且机会耗尽", battle.hand.size() == size - 1 and setup.relics.manual_discard_count() == 0)
	battle.free()
	setup = _setup("20", {0: "FRG-003", 1: "FRG-033", 2: "FRG-032", 3: "FRG-019"})
	battle = setup.battle
	_end_turn(battle)
	_check("回合末行触发获得50币，下回合牌位及保留空位", int(battle.player.silver) == 1050 and battle.effective_play_limit() >= 11)
	battle.free()
	setup = _setup("20", {0: "FRG-001~FRG-028", 1: "FRG-016"})
	battle = setup.battle
	battle.add_generated_card("test_block", "hand", "test")
	battle.rules.flush()
	_check("带负面残片触发时损失1生命", int(battle.player.health) == 9999 and int(battle.player.block) == 1)
	battle.free()
	setup = _setup("20", {0: "FRG-001", 1: "FRG-011"})
	battle = setup.battle
	for index in 4: battle.add_generated_card("test_block", "hand", "test"); battle.rules.flush()
	_check("额外指针每回合最多两次", int(setup.relics.state().extra_used) == 2 and int(setup.relics.state().extra_pointers) == 2)
	var order: Array[String] = [str(battle.hand[0].instance_id)]
	battle.commit_player_sequence(order)
	_check("额外遍历完成不递归生成指针", battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and battle.rules.last_error == OK)
	battle.free()

func _test_potions() -> void:
	var setup := _setup("20")
	var battle: BattleStateMachine = setup.battle
	battle.player["potions"] = [{"item_id": "p0", "potion": 0}, {"item_id": "p1", "potion": 1}, {"item_id": "p2", "potion": 2}, {"item_id": "p3", "potion": 3}]
	battle.rules.submit("potion.use", {"item_id": "p1"})
	battle.rules.submit("potion.use", {"item_id": "p1"})
	_check("药水仅消费一次并获得5格挡", int(battle.player.block) == 5 and battle.player.used_potions == ["p1"])
	battle.rules.submit("potion.use", {"item_id": "p3"})
	_check("药水增加本回合牌位", battle.effective_play_limit() == 11)
	battle.rules.submit("potion.use", {"item_id": "p2"})
	var before := battle.hand.size()
	var ids: Array[String] = [str(battle.hand[0].instance_id)]
	battle.submit_battle_choice(ids)
	_check("复制药水选择手牌后生成独立副本", battle.hand.size() == before + 1 and battle.hand.back().instance_id != battle.hand[0].instance_id)
	battle.free()

func _request(index: int, run: Node, session: EventSession) -> Dictionary:
	var request := {"map_id": "map-001", "node_id": "event-test-%d-%d" % [index, serial], "type": "event", "floor_index": 1, "request_id": "request-%d-%d" % [index, serial]}
	serial += 1
	session.pending = request.duplicate(true)
	_check("创建事件%d" % (index + 1), RunRandomEvents.open(run, request) == OK)
	var state := RunRandomEvents.state(run, request)
	state.index = index # 仅测试夹具覆盖身份，正式身份永远从种子派生。
	run.inventory_state.events[RunRandomEvents.key(request)] = state
	return request

func _test_events() -> void:
	var root := "res://.godot/content-systems-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(root)
	SaveGateway.profile_path = root.path_join("profile.json")
	SaveGateway.slot_paths.assign([root.path_join("1.json"), root.path_join("2.json"), root.path_join("3.json")])
	SaveGateway._active_slot = 1
	_check("隔离存档", SaveGateway._load_slot(1) == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "content-test"
	_check("事件测试新局", SaveGateway.start_new_run("event-seed", config) == OK)
	var run := SaveGateway.current_run()
	var session := EventSession.new()
	EncounterFlow.session = session
	for index in 12:
		_check("事件%d背景存在且种子固定" % (index + 1), ResourceLoader.exists(RandomEventCatalog.background(index)) and RandomEventCatalog.index_for_node("event-seed", "map", str(index)) == RandomEventCatalog.index_for_node("event-seed", "map", str(index)))
		run.gold = 5000; run.health = run.max_health
		var request := _request(index, run, session)
		if index == 8:
			var receipts: Array[String] = []
			RunRandomEvents.give_fragment(run, "FRG-001", receipts)
		var option := 0
		var size := run.deck.size()
		var error := RunRandomEvents.choose(run, request, option)
		if index in [8, 9]:
			var ids: Array = RunRandomEvents.selectables(run, request).slice(0, 1 if index == 8 else 2).map(func(e: Dictionary): return str(e.id))
			error = RunRandomEvents.select(run, request, ids)
			var offer := RunRandomEvents.state(run, request)
			_check("交换/合成三个选项不重复且保存重开不换", offer.offers.size() == 3 and RunRandomEvents.open(run, request) == OK and RunRandomEvents.state(run, request).offers == offer.offers)
			error = RunRandomEvents.select(run, request, [str(offer.offers[0])])
		if index == 9: _check("两张卡合成一张净删一张", run.deck.size() == size - 1)
		_check("事件%d完成选项并显示奖励" % (index + 1), error == OK and RunRandomEvents.state(run, request).stage == "result")
		var gold := run.gold
		_check("结果状态不可重复领取", RunRandomEvents.choose(run, request, option) != OK and run.gold == gold)
		_check("确认展示后完成节点", RunRandomEvents.acknowledge(run, request) == OK and RunRandomEvents.state(run, request).finished)
	# 保存失败必须连同生命、卡组和事件阶段一起回滚。
	for option in [1, 2]:
		run.gold = 5000
		var wish := _request(4, run, session)
		var enchant_before := 0
		for card: Dictionary in run.deck_cards: enchant_before += card.enchantments.size()
		var error := RunRandomEvents.choose(run, wish, option)
		if option == 2:
			var eligible := RunRandomEvents.selectables(run, wish)
			error = RunRandomEvents.select(run, wish, [str(eligible[0].id), str(eligible[1].id)])
		var enchant_after := 0
		for card: Dictionary in run.deck_cards: enchant_after += card.enchantments.size()
		_check("许愿池随机/指定两张不同卡附魔并仅扣一次银币", error == OK and enchant_after == enchant_before + 2 and run.gold == (4800 if option == 1 else 4500) and RunRandomEvents.state(run, wish).stage == "result")
	var gamble := _request(2, run, session)
	run.gold = 5000
	for play in 3:
		_check("赌桌第%d次抽取成功" % (play + 1), RunRandomEvents.choose(run, gamble, 0) == OK)
		_check("赌桌结果持久化且不能重复抽", RunRandomEvents.state(run, gamble).plays == play + 1 and RunRandomEvents.choose(run, gamble, 0) != OK)
		RunRandomEvents.acknowledge(run, gamble, true)
	_check("赌桌三次后强制结束且无法第四次抽取", RunRandomEvents.state(run, gamble).finished and RunRandomEvents.choose(run, gamble, 0) != OK)
	var conch := _request(11, run, session)
	_check("砸碎海螺生成带有一个负面程序的正式残片", RunRandomEvents.choose(run, conch, 2) == OK and str(run.items.back().fragment_id).contains("~") and not RelicCatalog.load_definitions()[str(run.items.back().fragment_id)].negative_action.is_empty())
	# 保存失败必须连同生命、卡组和事件阶段一起回滚。
	var request := _request(1, run, session)
	var before := RunRandomEvents.capture(run)
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("事件保存失败回滚银币生命与状态", RunRandomEvents.choose(run, request, 2) != OK and run.gold == int(before.gold) and run.health == int(before.health) and RunRandomEvents.state(run, request).stage == "choice")
	SaveGateway._load_error = old_error
	# 无素材时不能把事件卡死在输入阶段。
	run.items.clear(); run.inventory_state.relic_board = RelicBoard.new().to_dictionary()
	request = _request(8, run, session)
	_check("无残片交换不消费且保持可离开", RunRandomEvents.choose(run, request, 0) == ERR_UNAVAILABLE and RunRandomEvents.state(run, request).stage == "choice")
	# 本次新场景必须能实际装配，避免只测试纯逻辑而漏掉解析错误。
	request = _request(11, run, session)
	var scene: Control = load(RandomEventCatalog.SCENE).instantiate()
	add_child(scene)
	await get_tree().process_frame
	_check("事件场景可实际显示12号背景和选项", scene._title.text.contains("倾听海螺") and scene._content.get_child_count() == 4)
	scene.queue_free()

extends Node
## 真实状态机、规则队列与战场回放回归；存档始终隔离到 .godot。
const WAIT := preload("res://tests/support/presentation_test_helper.gd")
var failures := 0
var serial := 0

class ObservedScene extends "res://ui/battle/battle_test_scene.gd":
	var samples: Array[Dictionary] = []
	func _apply_presentation_snapshot(event: Dictionary) -> void:
		super._apply_presentation_snapshot(event)
		if event.kind in ["enemy_action", "enemy_action_end", "damage"]:
			samples.append({"kind": event.kind, "health": int(event.player.health),
				"time": Time.get_ticks_msec(), "index": int(event.get("action_index", 0))})

func _ready() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed: failures += 1

func _setup(id: String, health := 1000, block := 0, extra: Array = []) -> BattleStateMachine:
	serial += 1
	var battle := BattleStateMachine.new()
	add_child(battle)
	var enemies := [MonsterCatalog.create(id)]
	enemies.append_array(extra)
	_check("初始化 " + id, battle.initialize_battle({
		"map_id": "multi-action", "node_id": str(serial), "battle_index": serial,
		"draw_count": 0, "player": {"health": health, "max_health": health, "block": block},
		"enemies": enemies, "deck_instances": [
			{"instance_id": "choice-a", "card_id": "1"}, {"instance_id": "choice-b", "card_id": "1"}]}) == OK)
	var resolver := BattleEffectResolver.new()
	battle.add_child(resolver)
	_check("接入规则 " + id, resolver.attach_to_battle(battle) == OK)
	_check("开始战斗 " + id, battle.start_battle() == OK)
	return battle

func _events(battle: BattleStateMachine, type: String) -> Array:
	return battle.rules.queue.history.filter(func(e: Dictionary): return e.type == type)

func _attacks(battle: BattleStateMachine) -> Array:
	return _events(battle, "action.damage").filter(func(e: Dictionary): return e.metadata.has("monster_attack"))

func _run() -> void:
	SaveGateway.save_path = "res://.godot/monster-multi-%d/game.json" % Time.get_ticks_usec()
	_check("独立测试存档", SaveGateway.load_current() == OK)
	SeedService.begin_run("monster-multi-action-fixed")
	_test_counts()
	_test_summon_slot()
	_test_damage_and_heal()
	_test_buffs()
	_test_death()
	_test_pause()
	_test_choir()
	await _test_presentation()
	print("怪物多次行动：全部通过" if failures == 0 else "怪物多次行动：失败%d项" % failures)
	get_tree().quit(failures)

func _test_counts() -> void:
	var expected := {"1": 2, "2": 4, "3": 1, "4": 2, "5": 1, "6": 1, "7": 3,
		"8": 1, "9": 2, "10": 1, "11": 2, "12": 1, "13": 1, "14": 1, "15": 2,
		"16": 1, "17": 1, "18": 1, "19": 1, "20": 1, "21": 2, "22": 1, "23": 3}
	for id: String in expected:
		var battle := _setup(id)
		var decided := [0]
		battle.enemy_action_decided.connect(func(_id: String, _action: Dictionary):
			if battle.turn_number == 2: decided[0] += 1)
		battle.end_player_action()
		var requests := _events(battle, "enemy.action_requested").filter(func(e: Dictionary): return str(e.payload.enemy_id) == id)
		var ordered := requests.size() == int(expected[id])
		for index in requests.size():
			ordered = ordered and int(requests[index].payload.action_index) == index + 1 and int(requests[index].payload.action_count) == int(expected[id])
		_check("怪物%s按策划案次数独立行动并连续编号" % id, ordered)
		_check("新回合预先通知完整行动决定%s" % id, int(decided[0]) == battle.enemy_intent_actions().size())
		if id == "2":
			_check("躯壳四动最多格挡一次", requests.filter(func(e: Dictionary): return e.payload.action.has("block")).size() <= 1)
		if id == "4":
			_check("学徒先Buff后攻击", requests[0].payload.action.has("random_buff") and requests[1].payload.action.has("damage"))
		battle.free()
	var duke := _setup("11")
	duke.enemies[0].phase = 2
	_check("公爵第二形态意图为一动", MonsterCatalog.action_count(duke.enemies[0]) == 1)
	duke.end_player_action()
	_check("公爵第二形态只执行一次行动", _events(duke, "enemy.action_requested").size() == 1)
	duke.end_player_action()
	var phase_two := _events(duke, "enemy.action_requested")
	_check("公爵第二形态下一回合改为全队力量，不额外攻击", phase_two.size() == 2 and phase_two[1].payload.action.has("team_strength") and _attacks(duke).size() == 1)
	duke.free()

func _test_summon_slot() -> void:
	var battle := _setup("1")
	battle.end_player_action()
	battle.rules.queue.history.clear()
	battle.end_player_action()
	var requests := _events(battle, "enemy.action_requested")
	_check("炼金术士偶数回合召唤占一动，不追加第三次行动", requests.size() == 2 and requests[0].payload.action.has("damage") and requests[1].payload.action.has("summon") and battle.enemies.size() == 2 and _attacks(battle).size() == 1)
	battle.free()

func _test_damage_and_heal() -> void:
	var battle := _setup("7", 100, 3)
	battle.enemies[0].health = 10
	var healed: Array[int] = []
	battle.combatant_healed.connect(func(_side: StringName, _id: String, amount: int, _after: int): healed.append(amount))
	battle.end_player_action()
	var attacks := _attacks(battle)
	var losses := _events(battle, "combatant.damaged").filter(func(e: Dictionary): return e.payload.side == "player")
	_check("解剖者基础伤害与三次攻击均为2", int(MonsterCatalog.create("7").actions[0].damage) == 2 and attacks.size() == 3 and attacks.all(func(e: Dictionary): return int(e.payload.amount) == 2))
	_check("3点格挡逐次消耗，受到0/1/2伤害", losses.size() == 3 and [int(losses[0].payload.health_loss), int(losses[1].payload.health_loss), int(losses[2].payload.health_loss)] == [0, 1, 2] and int(battle.player.health) == 97)
	_check("全额吸血按每次实际掉血，格挡不吸血", int(battle.enemies[0].health) == 13 and healed == [1, 2])
	_check("一次行动完整收尾后才开始下一次", _events(battle, "flow.enemy.resolved").size() == 3)
	var trace: Array[String] = []
	for event: Dictionary in battle.rules.queue.history:
		if event.type in ["enemy.action_requested", "action.damage", "monster.heal", "flow.enemy.resolved"]:
			trace.append(str(event.type))
	_check("每次攻击的吸血均先于本次完成和下次行动", trace == [
		"enemy.action_requested", "action.damage", "flow.enemy.resolved",
		"enemy.action_requested", "action.damage", "monster.heal", "flow.enemy.resolved",
		"enemy.action_requested", "action.damage", "monster.heal", "flow.enemy.resolved"])
	battle.free()

func _test_buffs() -> void:
	var battle := _setup("7")
	battle.change_buff_layers(&"enemy", "7", "strength", 2, 1)
	battle.change_buff_layers(&"enemy", "7", "weak", 1, 1)
	battle.end_player_action()
	var damages := _events(battle, "combatant.damaged").filter(func(e: Dictionary): return e.payload.side == "player")
	_check("力量虚弱作用于每次攻击，本回合三次各3伤", damages.size() == 3 and damages.all(func(e: Dictionary): return int(e.payload.damage) == 3) and int(battle.player.health) == 991)
	_check("Buff仅在整个敌方回合结束后清除", battle.enemies[0].buffs.is_empty())
	battle.free()

func _test_death() -> void:
	for health in [2, 3]:
		var battle := _setup("7", health)
		battle.end_player_action()
		_check("玩家%d血致死立即取消剩余攻击" % health, not battle.active and _attacks(battle).size() == (1 if health == 2 else 2))
		battle.free()

func _test_pause() -> void:
	var battle := _setup("8", 100, 0, [MonsterCatalog.create("7")])
	battle.draw_cards(2, BattleStateMachine.DrawReason.BATTLE_START)
	battle.end_player_action()
	_check("遗言选择暂停时后续怪物尚未行动", battle.rules.queue.paused and _attacks(battle).size() == 1)
	var choice: Dictionary = battle.player.get("battle_choice", {})
	_check("存在弃牌候选", not choice.is_empty())
	if not choice.is_empty():
		var ids: Array[String] = [str(choice.candidates[0].instance_id)]
		battle.submit_battle_choice(ids)
	_check("恢复选择不重复前次行动、不漏解剖者三次攻击", not battle.rules.queue.paused and _attacks(battle).size() == 4 and _events(battle, "enemy.action_requested").size() == 4 and int(battle.player.health) == 90)
	battle.free()

func _test_choir() -> void:
	var found := false
	for attempt in 20:
		var battle := _setup("16")
		battle.end_player_action()
		if _attacks(battle).size() == 5:
			found = true
			_check("唱诗班五连击仍是一动，带独立段序", _events(battle, "enemy.action_requested").size() == 1 and _attacks(battle).all(func(e: Dictionary): return int(e.metadata.hit_count) == 5))
		battle.free()
		if found: break
	_check("已覆盖唱诗班五连击分支", found)

func _test_presentation() -> void:
	get_window().size = Vector2i(1920, 1080)
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.set_script(ObservedScene)
	scene.test_enemy_count = 1
	scene.relic_board_path = "res://.godot/monster-multi-empty-board.json"
	add_child(scene)
	await WAIT.battle_settled(scene)
	scene._battle.enemies.assign([MonsterCatalog.create("7")])
	scene._battle.player.health = 100
	scene._battle.player.max_health = 100
	scene._battle.enemy_intent_actions()
	await WAIT.battle_settled(scene)
	scene._refresh_combat_status()
	var slot: EnemySlot = scene.enemy_rack.slot_for("7")
	var preview := scene.intent_board.preview_for("7")
	_check("玩家回合意图显示解剖者2伤、3次行动", slot.intent_strip.cells.size() == 3 and slot.action_count_label.text == "3动" and preview.actions.all(func(a: Dictionary): return int(a.damage) == 2))
	var before := JSON.stringify(SeedService.capture_snapshot())
	for index in 5: scene._refresh_combat_status()
	_check("意图刷新不消耗种子随机流", before == JSON.stringify(SeedService.capture_snapshot()))
	scene._battle.end_player_action()
	var planned := scene._resolution_events.filter(func(e: Dictionary): return e.kind == "enemy_action")
	_check("正式场景接收三次行动快照", planned.size() == 3 and int(planned[2].action_index) == 3)
	_check("逻辑结算与异步回放解耦", int(scene._battle.player.health) == 94 and scene._busy)
	await WAIT.battle_settled(scene)
	var observed: Array = scene.get("samples")
	var hits := observed.filter(func(e: Dictionary): return e.kind == "damage")
	var starts := observed.filter(func(e: Dictionary): return e.kind == "enemy_action")
	_check("三次行动按顺序可见回放", starts.size() == 3 and hits.size() == 3 and int(hits[0].health) == 98 and int(hits[1].health) == 96 and int(hits[2].health) == 94)
	_check("连续小伤害不再同帧叠加", hits.size() == 3 and int(hits[1].time) - int(hits[0].time) >= 100 and int(hits[2].time) - int(hits[1].time) >= 100)
	_check("行动全部完成后才恢复玩家回合", not scene._busy and scene._battle.turn_number == 2 and scene.phase_label.text.begins_with("玩家回合"))
	scene.queue_free()
	await get_tree().process_frame

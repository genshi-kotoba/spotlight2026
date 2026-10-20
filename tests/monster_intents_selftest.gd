extends Node

var failures := 0
var checks := 0
var serial := 0
var requested: Array[Dictionary] = []
var late_birth_empty := false
var draw_before_ready := false

func _ready() -> void:
	SeedService.begin_run("monster-intents-selftest")
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.initialize_battle({
		"map_id": "intent-test", "node_id": "ready", "battle_index": 0, "draw_count": 0,
		"player": {"health": 500, "max_health": 500, "buffs": []},
		"enemies": [MonsterCatalog.create("2")], "deck_instances": []})
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	if error == OK: error = resolver.attach_to_battle(battle)
	if error == OK: error = battle.start_battle()
	_check("玩家可以操作时已有完整四动计划", error == OK and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and battle.enemies[0].get("intent_plan", []).size() == 4)
	resolver.free()
	battle.free()
	_test_saved_action_execution()
	_test_draw_ready_order()
	_test_phase_refresh()
	_test_summon_timing()
	_test_projection()
	_test_snapshots()
	_test_review_compatibility()
	_test_execution_projection_snapshots()
	_test_final_boss_integration()
	print("INTENTS: %d checks, %d failures" % [checks, failures])
	get_tree().quit(failures)

func _check(label: String, passed: bool) -> void:
	checks += 1
	print(("PASS " if passed else "FAIL ") + label)
	if not passed: failures += 1

func _make(monsters: Array, start_now := true) -> Dictionary:
	serial += 1
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.initialize_battle({
		"map_id": "intent-test", "node_id": "case-%d" % serial, "battle_index": serial, "draw_count": 0,
		"player": {"health": 500, "max_health": 500, "buffs": [], "silver": 0},
		"enemies": monsters, "deck_instances": []})
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	if error == OK: error = resolver.attach_to_battle(battle)
	if error == OK and start_now: error = battle.start_battle()
	_check("创建意图场景%d" % serial, error == OK)
	return {"battle": battle, "resolver": resolver}

func _free(setup: Dictionary) -> void:
	setup.resolver.free()
	setup.battle.free()

func _record(id: String, action: Dictionary) -> void:
	requested.append({"enemy_id": id, "action": action.duplicate(true)})

func _test_saved_action_execution() -> void:
	for monster in [2, 3, 7, 13, 16]:
		var setup := _make([MonsterCatalog.create(str(monster))])
		var battle: BattleStateMachine = setup.battle
		var expected := battle.enemy_intent_actions().duplicate(true)
		if monster == 7:
			var view := MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
			_check("吸血作为复合意图直接可见", view.actions[0].summary.contains("吸血") and "special" in view.actions[0].kinds)
		var rng := SeedService.capture_snapshot()
		battle.enemy_intent_actions()
		battle.enemy_intent_actions()
		_check("%d号重复读取计划不消耗RNG" % monster, SeedService.capture_snapshot() == rng)
		requested.clear()
		battle.enemy_action_requested.connect(_record)
		battle._begin_enemy_turn()
		_check("%d号执行与玩家看到的完整计划逐条一致" % monster, requested == expected)
		_free(setup)

func _test_draw_ready_order() -> void:
	var setup := _make([MonsterCatalog.create("2")], false)
	var battle: BattleStateMachine = setup.battle
	draw_before_ready = false
	battle.rules.register_rule("test.draw.ready", "test.natural_draw", func(_e: BattleEvent):
		draw_before_ready = not battle.enemies[0].has("intent_plan")
		battle.rules.publish("test.draw.reaction"))
	battle.rules.register_rule("test.draw.reaction", "test.draw.reaction", func(_e: BattleEvent):
		battle.enemies[0]["phase"] = 2)
	battle.turn_started.connect(func(_turn: int): battle.rules.publish("test.natural_draw"))
	battle.start_battle()
	_check("turn_started派生抽牌及其反应完成后才固定计划", draw_before_ready and battle.enemies[0].intent_phase == 2)
	var history := battle.rules.queue.history.map(func(e: Dictionary): return e.type)
	_check("意图ready事实排在自然抽牌反应后", history.find("enemy.intents_ready") > history.find("test.draw.reaction"))
	_free(setup)

func _test_phase_refresh() -> void:
	var setup := _make([MonsterCatalog.create("11"), MonsterCatalog.create("2")])
	var battle: BattleStateMachine = setup.battle
	var other_plan: Array = battle.enemies[1].intent_plan.duplicate(true)
	var rng := SeedService.capture_snapshot()
	battle.rules.submit("action.damage", {"side": "enemy", "target": "11", "amount": 100, "ignore_block": true})
	_check("11号转阶段时刷新为当轮二阶段一动", battle.enemies[0].phase == 2 and battle.enemies[0].intent_phase == 2 and battle.enemies[0].intent_plan.size() == 1)
	_check("转阶段不重抽未变化怪物", battle.enemies[1].intent_plan == other_plan and SeedService.capture_snapshot() == rng)
	_check("玩家阶段召唤者当轮已有计划", battle.enemies.size() == 3 and battle.enemies[2].monster_id == "14" and battle.enemies[2].intent_turn == battle.turn_number and not battle.enemies[2].intent_plan.is_empty())
	_free(setup)
	setup = _make([MonsterCatalog.create("21"), MonsterCatalog.create("2")])
	battle = setup.battle
	other_plan = battle.enemies[1].intent_plan.duplicate(true)
	battle.rules.submit("action.damage", {"side": "enemy", "target": "21", "amount": 500, "ignore_block": true})
	_check("死亡单位清空意图且其他单位计划不变", battle.enemies[0].intent_plan.is_empty() and battle.enemies[1].intent_plan == other_plan)
	_free(setup)

func _test_summon_timing() -> void:
	var setup := _make([MonsterCatalog.create("10")])
	var battle: BattleStateMachine = setup.battle
	var view := MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("10号预览明确开头召唤及4点生命损失威胁", str(view.triggers).contains("失去4生命") and battle.enemies.size() == 1)
	requested.clear()
	battle.enemy_action_requested.connect(_record)
	battle._begin_enemy_turn()
	_check("10号回合开始召唤5号并在本轮执行", requested.size() == 2 and requested[1].action.get("dot") == 4 and battle.player.health == 490)
	_free(setup)
	setup = _make([MonsterCatalog.create("1")])
	battle = setup.battle
	battle._start_player_turn() # even turn: attack, then summon
	requested.clear()
	late_birth_empty = false
	battle.enemy_action_requested.connect(_record)
	battle.rules.queue.event_processed.connect(func(event: BattleEvent):
		if event.type == "enemy.intents_changed" and battle.turn_number == 2:
			for actor: Dictionary in battle.enemies:
				if actor.get("monster_id") == "4":
					late_birth_empty = actor.get("intent_turn") == 2 and actor.get("intent_plan", [1]).is_empty())
	battle._begin_enemy_turn()
	_check("1号行动中召唤4号本轮为空计划且不额外行动", late_birth_empty and requested.size() == 2 and requested[1].action.get("summon") == "4")
	_check("晚出生4号下一玩家回合生成两动", battle.enemies.size() == 2 and battle.enemies[1].intent_turn == 3 and battle.enemies[1].intent_plan.size() == 2)
	_free(setup)

func _test_projection() -> void:
	var setup := _make([MonsterCatalog.create("4")])
	var battle: BattleStateMachine = setup.battle
	var before := battle.to_dictionary()
	var rng := SeedService.capture_snapshot()
	var view := MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("随机Buff仍明确随机且后续攻击显示5至6范围", view.action_count == 2 and view.actions[0].summary == "随机Buff" and view.actions[1].damage == 5 and view.actions[1].damage_max == 6)
	MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("纯投影不修改状态也不消费RNG", battle.to_dictionary() == before and SeedService.capture_snapshot() == rng)
	_free(setup)
	var uncertain := MonsterCatalog.create("4")
	uncertain.buffs = [{"buff_id": "weak", "layers": 5, "duration": 0}]
	setup = _make([uncertain, MonsterCatalog.create("20")])
	battle = setup.battle
	battle.player.buffs = [{"buff_id": "vulnerable", "layers": 1, "duration": 0}]
	view = MonsterIntentPreview.describe(battle.enemies[1], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("随机0伤害时易伤可能留存也可能消耗，后续攻击范围覆盖10至15", view.actions[0].damage == 10 and view.actions[0].damage_max == 15)
	battle.player.buffs[0].layers = 2
	view = MonsterIntentPreview.describe(battle.enemies[1], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("两层易伤在前击0或1后仍保证下一击15伤害", view.actions[0].damage == 15 and view.actions[0].damage_max == 15)
	_free(setup)
	var thief := MonsterCatalog.create("15")
	thief["stole"] = true
	thief.buffs = [{"buff_id": "weak", "layers": 5, "duration": 0}]
	setup = _make([thief])
	battle = setup.battle
	view = MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("15号数值投影包含敌方开头虚弱减一", view.actions[0].damage == 6 and view.actions[1].damage == 6 and battle.enemies[0].buffs[0].layers == 5)
	battle._begin_enemy_turn()
	_check("15号实际两击与投影一致", battle.player.health == 488)
	_free(setup)
	var duke := MonsterCatalog.create("11")
	duke.phase = 2
	setup = _make([duke, MonsterCatalog.create("20")])
	battle = setup.battle
	battle._start_player_turn()
	view = MonsterIntentPreview.describe(battle.enemies[1], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("先行团队力量投影到后续敌人", view.actions[0].damage == 11)
	battle._begin_enemy_turn()
	_check("团队力量实际后续攻击与投影一致", battle.player.health == 489)
	_free(setup)
	setup = _make([MonsterCatalog.create("16")])
	battle = setup.battle
	battle.enemies[0].intent_plan = [{"action_id": "monster-16", "damage": 2, "hits": 5}]
	battle.player.buffs = [{"buff_id": "vulnerable", "layers": 2, "duration": 0}]
	view = MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("五连击是一动且逐击易伤范围正确", view.action_count == 1 and view.actions[0].hits == 5 and view.actions[0].damage == 2 and view.actions[0].damage_max == 3)
	_check("易伤逐击投影提供准确明细", view.actions[0].hit_ranges == [[3, 3], [3, 3], [2, 2], [2, 2], [2, 2]])
	var actual_hits: Array[int] = []
	battle.rules.register_rule("test.vulnerable.hits", "combatant.damaged", func(event: BattleEvent):
		if str(event.metadata.get("monster_attack", "")) == "16": actual_hits.append(int(event.payload.damage)))
	battle._begin_enemy_turn()
	_check("两层易伤只放大前两击且实际总伤12", actual_hits == [3, 3, 2, 2, 2])
	_free(setup)
	setup = _make([MonsterCatalog.create("6"), MonsterCatalog.create("19")])
	battle = setup.battle
	view = MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("攻击与流血复合动作保留全部类别", "attack" in view.actions[0].kinds and "special" in view.actions[0].kinds and view.actions[0].summary.contains("流血"))
	view = MonsterIntentPreview.describe(battle.enemies[1], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("治疗与失效特殊动作保留两项", view.actions[0].summary.contains("治疗玩家10") and view.actions[0].summary.contains("失效"))
	var blank := battle.enemies[0].duplicate(true)
	blank.erase("intent_plan")
	view = MonsterIntentPreview.describe(blank, battle.player, [blank], setup.resolver.buff_catalog)
	_check("缺计划不伪造基础攻击", not view.ready and view.actions.is_empty())
	_free(setup)

func _restore(saved: Dictionary) -> Dictionary:
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.restore_from_dictionary(saved)
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	if error == OK: error = resolver.attach_to_battle(battle)
	return {"battle": battle, "resolver": resolver, "error": error}

func _test_snapshots() -> void:
	var setup := _make([MonsterCatalog.create("2")])
	var saved: Dictionary = setup.battle.to_dictionary()
	var rng := SeedService.capture_snapshot()
	var restored := _restore(saved)
	_check("现代安全边界存档原样恢复已固定计划", restored.error == OK and restored.battle.enemies[0].intent_plan == saved.enemies[0].intent_plan)
	_check("现代恢复不重抽RNG", SeedService.capture_snapshot() == rng)
	_free(restored)
	for field: String in ["intent_turn", "intent_phase", "intent_actor", "intent_plan"]:
		var bad := saved.duplicate(true)
		match field:
			"intent_turn": bad.enemies[0][field] = int(saved.turn_number) + 1
			"intent_phase": bad.enemies[0][field] = 99
			"intent_actor": bad.enemies[0][field] = "another-enemy"
			"intent_plan": bad.enemies[0][field] = [{"damage": 2, "hits": 0}]
		var rejected := _restore(bad)
		_check("损坏存档拒绝%s且不推进RNG" % field, rejected.error == ERR_INVALID_DATA and SeedService.capture_snapshot() == rng)
		_free(rejected)
	var legacy := saved.duplicate(true)
	legacy.erase("intent_version")
	for enemy: Dictionary in legacy.enemies:
		for key: String in ["intent_plan", "intent_turn", "intent_phase", "intent_actor"]: enemy.erase(key)
	restored = _restore(legacy)
	_check("旧v1玩家行动档恢复并挂规则后有完整计划", restored.error == OK and restored.battle.enemies[0].intent_plan.size() == 4)
	_check("旧档补齐不重放回合或抽牌", restored.battle.turn_number == saved.turn_number and restored.battle.hand == saved.hand and restored.battle.player == saved.player)
	rng = SeedService.capture_snapshot()
	restored.battle.ensure_enemy_intents()
	_check("旧档补齐只进行一次", SeedService.capture_snapshot() == rng)
	_free(restored)
	_free(setup)
	setup = _make([MonsterCatalog.create("2")], false)
	restored = _restore(setup.battle.to_dictionary())
	_check("新IDLE存档允许无计划并可正常开始", restored.error == OK and restored.battle.start_battle() == OK and restored.battle.enemies[0].intent_plan.size() == 4)
	_free(restored)
	_free(setup)

func _test_review_compatibility() -> void:
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.initialize_battle({
		"map_id": "intent-bare", "node_id": "wait", "battle_index": 90, "draw_count": 1,
		"player": {"health": 30, "max_health": 30, "buffs": []},
		"enemies": [{"enemy_id": "waiting", "health": 50, "max_health": 50, "buffs": [], "actions": [{"action_id": "wait"}]}],
		"deck_instances": [{"instance_id": "bare-card", "card_id": "bare-card"}]})
	if error == OK: error = battle.start_battle()
	var saved := battle.to_dictionary()
	var restored := BattleStateMachine.new()
	add_child(restored)
	var restore_error := restored.restore_from_dictionary(saved)
	_check("合法wait行动写入后可恢复", error == OK and restore_error == OK)
	var view := MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, {})
	_check("无效果行动明确显示等待并计为一动", view.ready and view.action_count == 1 and view.actions[0].summary == "等待")
	restored.free()
	var legacy := saved.duplicate(true)
	legacy.erase("intent_version")
	for actor: Dictionary in legacy.enemies:
		for key: String in ["intent_plan", "intent_turn", "intent_phase", "intent_actor"]: actor.erase(key)
	restored = BattleStateMachine.new()
	add_child(restored)
	restore_error = restored.restore_from_dictionary(legacy)
	var rng := SeedService.capture_snapshot()
	restored.ensure_enemy_intents()
	_check("裸旧v1恢复后再次prepare不重抽", SeedService.capture_snapshot() == rng)
	var commit_error := restored.commit_player_sequence(["bare-card"])
	_check("裸状态机旧v1恢复无需新attach即可直接commit", restore_error == OK and commit_error == OK and restored.turn_number == 2)
	rng = SeedService.capture_snapshot()
	_check("旧v1幂等补齐后可再次读取而不重抽", restored.enemy_intent_actions().size() == 1 and SeedService.capture_snapshot() == rng)
	restored.free()
	battle.free()

func _test_execution_projection_snapshots() -> void:
	var duke := MonsterCatalog.create("11")
	duke.phase = 2
	var setup := _make([duke, MonsterCatalog.create("20")])
	var battle: BattleStateMachine = setup.battle
	battle._start_player_turn()
	var observed: Array[int] = []
	battle.rules.queue.event_processed.connect(func(event: BattleEvent):
		if event.type != "enemy.intents_changed" or battle.phase != BattleStateMachine.Phase.ENEMY_ACTION: return
		var snapshot: Array = event.payload.enemies
		var target: Dictionary = snapshot[1]
		if target.buffs.is_empty(): return
		var projected := MonsterIntentPreview.describe(target, battle.player.duplicate(true), snapshot, setup.resolver.buff_catalog)
		observed.append(int(projected.actions[0].damage)))
	battle._begin_enemy_turn()
	_check("队列Buff已生效后的changed快照不会再叠团队力量", not observed.is_empty() and observed.all(func(amount: int): return amount == 11))
	_free(setup)
	var random_observed: Array[int] = []
	for attempt in 16:
		setup = _make([MonsterCatalog.create("4")])
		battle = setup.battle
		var this_battle := battle
		var this_resolver: BattleEffectResolver = setup.resolver
		battle.rules.queue.event_processed.connect(func(event: BattleEvent):
			if event.type != "enemy.intents_changed" or this_battle.phase != BattleStateMachine.Phase.ENEMY_ACTION: return
			var snapshot: Array = event.payload.enemies
			var target: Dictionary = snapshot[0]
			if not target.buffs.any(func(buff: Dictionary): return buff.buff_id == "strength"): return
			var projected := MonsterIntentPreview.describe(target, this_battle.player.duplicate(true), snapshot, this_resolver.buff_catalog)
			random_observed.append(int(projected.actions[1].damage_max)))
		battle._begin_enemy_turn()
		_free(setup)
		if not random_observed.is_empty(): break
	_check("随机力量实际生效后的changed快照仍保留5至6范围", not random_observed.is_empty() and random_observed.all(func(amount: int): return amount == 6))

func _test_final_boss_integration() -> void:
	var setup := _make([MonsterCatalog.create("23")])
	var battle: BattleStateMachine = setup.battle
	var view := MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("23号三动顺序为攻击8、力量1、格挡8", view.action_count == 3 and view.actions[0].damage == 8 and view.actions[1].summary == "力量+1" and view.actions[2].block == 8)
	_check("23号土星清理显示为触发而非第四动", view.triggers.size() == 1 and str(view.triggers).contains("逆行土星") and battle.hand.filter(FinalBossRules.is_saturn).size() == 1)
	var saved := battle.to_dictionary()
	var rng := SeedService.capture_snapshot()
	var restored := _restore(saved)
	_check("土星与三动计划可安全冷恢复且不重抽", restored.error == OK and restored.battle.hand == saved.hand and restored.battle.enemies[0].intent_plan == saved.enemies[0].intent_plan and SeedService.capture_snapshot() == rng)
	_free(restored)
	var plan := battle.enemy_intent_actions().duplicate(true)
	battle.apply_damage_to_enemy("23", 1000, true)
	_check("23号半血当轮仍一阶段且计划不变", battle.enemies[0].health == 153 and battle.enemies[0].phase == 1 and battle.enemies[0].boss_transition_pending and battle.enemy_intent_actions() == plan)
	requested.clear()
	battle.enemy_action_requested.connect(_record)
	var frozen: Array[Dictionary] = []
	battle.rules.queue.event_processed.connect(func(event: BattleEvent):
		if event.type == &"enemy.intents_changed" and battle.turn_number == 1:
			frozen.append(MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)))
	battle._begin_enemy_turn()
	_check("23号三动实际执行与缓存计划一致", requested == plan)
	_check("23号力量生效后执行中攻击预览仍冻结为8", not frozen.is_empty() and frozen.all(func(record: Dictionary): return int(record.actions[0].damage) == 8))
	view = MonsterIntentPreview.describe(battle.enemies[0], battle.player, battle.enemies, setup.resolver.buff_catalog)
	_check("23号下一回合转二阶段、攻击9且生成两张土星", battle.enemies[0].phase == 2 and battle.enemies[0].intent_phase == 2 and view.actions[0].damage == 9 and battle.hand.filter(FinalBossRules.is_saturn).size() == 2)
	_free(setup)
	setup = _make([MonsterCatalog.create("23")])
	battle = setup.battle
	battle.player.health = 1
	requested.clear()
	battle.enemy_action_requested.connect(_record)
	battle._begin_enemy_turn()
	_check("土星清理致死会中断敌方三动", not battle.active and battle.phase == BattleStateMachine.Phase.DEFEAT and requested.is_empty())
	_free(setup)

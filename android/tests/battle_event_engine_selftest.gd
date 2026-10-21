extends Node

var failures := 0


func _ready() -> void:
	SeedService.begin_run("battle-event-engine-selftest")
	_test_causal_order_and_pause()
	_test_priorities_and_execution_time_stats()
	_test_discard_in_middle_and_multiple_pauses()
	_test_lethal_cancels_remaining_effects()
	_test_event_budget()
	print("事件队列与规则引擎全部通过" if failures == 0 else "事件引擎失败 %d 项" % failures)
	get_tree().quit(failures)


func _test_causal_order_and_pause() -> void:
	var engine := BattleRuleEngine.new()
	var order: Array[String] = []
	var depth: Array[int] = [0, 0]
	engine.register_rule("A", "A", func(_event: BattleEvent) -> void:
		depth[0] += 1
		depth[1] = maxi(depth[1], depth[0])
		order.append("A")
		engine.submit("B")
		engine.submit("C")
		depth[0] -= 1)
	engine.register_rule("B", "B", func(_event: BattleEvent) -> void:
		depth[0] += 1
		depth[1] = maxi(depth[1], depth[0])
		order.append("B")
		engine.submit("D")
		depth[0] -= 1)
	for type: String in ["C", "D", "E"]:
		engine.register_rule(type, type, func(event: BattleEvent) -> void: order.append(event.type))
	engine.publish("A")
	engine.publish("E")
	engine.flush()
	_check("反应优先完成，兄弟事件保持顺序", order == ["A", "B", "D", "C", "E"])
	_check("submit 在规则处理中不递归执行", depth[1] == 1)
	var history := engine.queue.history
	_check("派生事件保留根事件和父事件 ID", history[1].root_id == history[0].id and history[2].parent_id == history[1].id)
	_check("事件日志可 JSON 序列化", JSON.parse_string(JSON.stringify(history)) is Array)
	engine.register_rule("pause", "pause", func(_event: BattleEvent) -> void: engine.queue.pause())
	engine.publish("pause")
	engine.publish("E")
	engine.flush()
	var size_before := order.size()
	_check("暂停保留后续事件", engine.queue.paused and engine.queue.pending_count() == 1)
	engine.queue.resume()
	engine.flush()
	engine.flush()
	_check("恢复只执行一次续接", order.size() == size_before + 1 and engine.queue.pending_count() == 0)
	engine.queue.event_processed.connect(func(event: BattleEvent) -> void:
		if event.type == "observed":
			engine.submit("E"))
	size_before = order.size()
	engine.submit("observed")
	_check("观察信号中提交的事件不会丢失", order.size() == size_before + 1 and engine.queue.pending_count() == 0)


func _test_priorities_and_execution_time_stats() -> void:
	var setup := _setup(501)
	var battle: BattleStateMachine = setup.battle
	var checks: Array[int] = [0]
	battle.rules.register_rule("test.cap", "action.damage", func(event: BattleEvent) -> void:
		checks[0] += 1
		event.payload.amount = mini(5, int(event.payload.amount)),
		50, func(event: BattleEvent) -> bool: return event.payload.side == "enemy")
	var context := BattleEffectContext.new(battle, "enemy", setup.resolver.buff_catalog)
	# 两条动作先入队：伤害加成必须在执行时读取刚加上的力量。
	battle.rules.queue.pause()
	context.add_buff(&"player", "player", &"strength", 3)
	context.damage_enemy("enemy", 8)
	battle.rules.queue.resume()
	battle.rules.flush()
	_check("自定义规则在 Buff 修正后、状态执行前运行", int(battle.enemies[0].health) == 295 and checks[0] == 1)
	var damage_event: Dictionary = {}
	for event: Dictionary in battle.rules.queue.history:
		if event.type == "action.damage":
			damage_event = event
	_check("事件日志保留基础值与规则修正结果", damage_event.payload.base_amount == 8 and damage_event.payload.amount == 5)
	_check("队列空闲时可保存恢复", bool(battle.to_dictionary().queue_idle))
	_cleanup(setup)


func _test_discard_in_middle_and_multiple_pauses() -> void:
	var setup := _setup(502)
	var battle: BattleStateMachine = setup.battle
	var resolver: BattleEffectResolver = setup.resolver
	var data := CardData.new()
	data.card_id = &"test_block"
	var choice := CardEffectDiscardChoice.new()
	choice.count = 1
	var strength := CardEffectBuff.new()
	strength.layers = 3
	var attack := CardEffectAttack.new()
	attack.amount = 8
	var heal := CardEffectHeal.new()
	heal.amount = 5
	data.effects.assign([choice, strength, attack, choice, heal])
	resolver.card_catalog["test_block"] = data
	var sequence: Array[String] = [String(battle.hand[0].instance_id)]
	battle.commit_player_sequence(sequence, {sequence[0]: "enemy"})
	_check("中途弃牌暂停整个队列，后面的伤害尚未发生", battle.has_pending_discard_choice() and battle.rules.queue.paused and int(battle.enemies[0].health) == 300)
	_check("暂停期间的快照不被标记为空闲", not bool(battle.to_dictionary().queue_idle))
	var chosen: Array[String] = [String(battle.hand[0].instance_id)]
	battle.submit_discard_choice(chosen)
	_check("恢复后先加力量再造成 11 点伤害，然后再次暂停", int(battle.enemies[0].health) == 289 and battle.has_pending_discard_choice() and int(battle.player.health) == 50)
	chosen = [String(battle.hand[0].instance_id)]
	battle.submit_discard_choice(chosen)
	_check("第二次恢复执行后续治疗并完成敌方回合", battle.turn_number == 2 and int(battle.player.health) == 49 and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION)
	_check("两次弃牌和效果牌都只进入弃牌堆一次", battle.discard_pile.size() == 3 and not battle.rules.queue.paused and battle.rules.queue.pending_count() == 0)
	_cleanup(setup)


func _test_lethal_cancels_remaining_effects() -> void:
	var setup := _setup(503)
	var battle: BattleStateMachine = setup.battle
	var data := CardData.new()
	data.card_id = &"test_block"
	var self_damage := CardEffectDamageSelf.new()
	self_damage.amount = 100
	var heal := CardEffectHeal.new()
	heal.amount = 100
	data.effects.assign([self_damage, heal])
	setup.resolver.card_catalog["test_block"] = data
	var sequence: Array[String] = [String(battle.hand[0].instance_id)]
	var completed: Array[int] = [0]
	battle.card_resolved.connect(func(_card: Dictionary, _pointer: int) -> void: completed[0] += 1)
	battle.commit_player_sequence(sequence)
	_check("致死事件判定败北并取消尚未执行的治疗", not battle.active and int(battle.player.health) == 0 and battle.phase == BattleStateMachine.Phase.DEFEAT)
	_check("致死卡仍发出一次表现事件且清空队列", completed[0] == 1 and battle.rules.queue.pending_count() == 0)
	_cleanup(setup)


func _test_event_budget() -> void:
	var engine := BattleRuleEngine.new()
	engine.queue.max_events_per_drain = 16
	engine.register_rule("loop", "loop", func(_event: BattleEvent) -> void: engine.submit("loop"))
	_check("异常规则循环有统一事件预算", engine.submit("loop") == ERR_CYCLIC_LINK and engine.queue.pending_count() == 0 and not engine.queue.processing)
	_check("循环错误保留在引擎诊断字段", engine.last_error == ERR_CYCLIC_LINK)


func _setup(index: int) -> Dictionary:
	var battle := BattleStateMachine.new()
	add_child(battle)
	var deck: Array[Dictionary] = []
	for card_index in 4:
		deck.append({"instance_id": "event-%d-%d" % [index, card_index], "card_id": "test_block"})
	battle.initialize_battle({"map_id": "event-test", "node_id": "test", "battle_index": index,
		"draw_count": 0, "player": {"health": 50, "max_health": 100, "block": 0, "buffs": []},
		"enemies": [{"enemy_id": "enemy", "health": 300, "max_health": 300, "block": 0,
			"buffs": [], "actions": [{"damage": 6}]}], "deck_instances": deck})
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	resolver.attach_to_battle(battle)
	battle.start_battle()
	battle.draw_cards(4)
	return {"battle": battle, "resolver": resolver}


func _cleanup(setup: Dictionary) -> void:
	(setup.resolver as Node).free()
	(setup.battle as Node).free()


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["通过" if passed else "失败", label])

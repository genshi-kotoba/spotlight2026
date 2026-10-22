class_name BattleEnchantmentRules
extends RefCounted
## 附魔规则仅消费队列事件并发布指令；交互暂停后仍回到原结算续接点。
const SKIP_ID := "enchantment:skip"
const MAX_DISCARD_REACTIONS := 64
var battle: BattleStateMachine
var formal: FormalCardRules

func _init(p_battle: BattleStateMachine, p_formal: FormalCardRules) -> void:
	battle = p_battle
	formal = p_formal
	for type: String in ["enchantment.prepare", "enchantment.prepare_next", "enchantment.choice_result",
			"enchantment.triggered", "enchantment.damage", "card.discarded",
			"combatant.damaged", "player.turn_started"]:
		battle.rules.register_rule("enchantments." + type, type, _event, 40)
	battle.rules.register_rule("enchantments.damage", "action.damage", _damage, 15)
	battle.rules.register_rule("enchantments.block", "action.block", _block, 15)
	battle.rules.register_rule("enchantments.pointer", "pointer.moved", _pointer, 40)

func state() -> Dictionary:
	if not battle.player.has("enchantment_state"): battle.player.enchantment_state = {}
	return battle.player.enchantment_state

func _event(event: BattleEvent) -> void:
	if not battle.active: return
	match event.type:
		"player.turn_started":
			state().merge({"pointer_repeat": 0, "pointer_rewind": 0, "discard_count": 0}, true)
		"enchantment.prepare":
			var stages: Array = []
			for number in [20, 21]:
				if CardEnchantments.has(event.payload.card, number): stages.append(number)
			state()["preparation"] = {"payload": event.payload.duplicate(true), "stages": stages,
				"index": 0, "metadata": event.metadata.duplicate(true), "boosts": {}}
			battle.rules.publish("enchantment.prepare_next")
		"enchantment.prepare_next": _prepare_next()
		"enchantment.choice_result": _choice(event)
		"enchantment.triggered": _triggered(event.payload.card)
		"enchantment.damage": _publish_damage(event)
		"card.discarded": _discarded(event)
		"combatant.damaged": _damaged(event)

func _prepare_next() -> void:
	var preparation: Dictionary = state().get("preparation", {})
	if preparation.is_empty(): return
	var index := int(preparation.index)
	var stages: Array = preparation.stages
	if index >= stages.size():
		var metadata: Dictionary = preparation.metadata.duplicate(true)
		metadata.merge(preparation.boosts, true)
		metadata["enchantment_boost_source"] = str(preparation.payload.card.instance_id)
		battle.rules.publish("card.effects_compile", preparation.payload, metadata)
		state().erase("preparation")
		return
	preparation.index = index + 1
	if battle.hand.is_empty():
		battle.rules.publish("enchantment.prepare_next")
		return
	var candidates: Array = battle.hand.duplicate(true)
	candidates.append({"instance_id": SKIP_ID, "card_id": "1", "choice_text": "跳过，不弃牌"})
	battle.request_battle_choice("enchantment_%d" % int(stages[index]), candidates, 1)

func _choice(event: BattleEvent) -> void:
	var preparation: Dictionary = state().get("preparation", {})
	if preparation.is_empty(): return
	var id := str(event.payload.ids[0])
	if id != SKIP_ID:
		var flag := "enchantment_damage_boost" if event.payload.mode == "enchantment_20" else "enchantment_block_boost"
		preparation.boosts[flag] = true
		battle.rules.publish("action.discard", {"instance_id": id, "reason": "enchantment"}, preparation.metadata)
	battle.rules.publish("enchantment.prepare_next", {}, preparation.metadata)

func _triggered(card: Dictionary) -> void:
	if CardEnchantments.has(card, 16): battle.rules.publish("action.draw", {"count": 1})
	if CardEnchantments.has(card, 5):
		var copy := card.duplicate(true)
		copy["enchantments"] = []
		copy["effect_scale"] = 0.5
		copy["one_shot"] = true
		copy.erase("locked_until")
		copy.erase("stored_target")
		var data: CardData = formal.cards.get(str(card.card_id))
		copy["occupies_slot"] = data.occupies_slot if data != null else true
		battle.add_generated_card(str(card.card_id), "hand", "enchantment_half", copy)
	# 必须在 flow.sequence.finish 算下一索引之前移除，否则会跳过后面一张牌。
	if bool(card.get("one_shot", false)) and int(battle._repeat_remaining_by_card.get(str(card.instance_id), 0)) <= 0:
		battle.rules.publish("action.remove_card", {"instance_id": str(card.instance_id)})

func _publish_damage(event: BattleEvent) -> void:
	var card := formal._live_card(str(event.metadata.get("source_card", "")))
	var data := event.payload.duplicate(true)
	if str(data.side) == "enemy" and CardEnchantments.has(card, 6):
		var self_damage := data.duplicate(true)
		self_damage.merge({"side": "player", "target": "player", "block_double": false}, true)
		var self_event := battle.rules.publish("action.damage", self_damage,
			{"enchantment_self_damage": true, "self_source": true, "formal_damage": false})
		self_event.metadata["damage_program_id"] = self_event.id
	if str(data.side) == "enemy":
		for number in [17, 18]:
			if CardEnchantments.has(card, number):
				battle.rules.publish("action.buff_add", {"side": "enemy", "target": data.target,
					"buff_id": "vulnerable" if number == 17 else "poison", "layers": 1})
	var damage := battle.rules.publish("action.damage", data, {"enchantment_self_damage": false})
	damage.metadata["damage_program_id"] = damage.id

func _damage(event: BattleEvent) -> void:
	if event.id != int(event.metadata.get("damage_program_id", -1)) or not bool(event.payload.get("use_stats", false)): return
	var card := formal._live_card(str(event.metadata.get("source_card", "")))
	if str(event.payload.side) != "enemy" and not bool(event.metadata.get("enchantment_self_damage", false)): return
	var amount := int(event.payload.amount)
	if card.get("enchantments", []).has("damage_50"): amount = int(floor(amount * 1.5))
	if CardEnchantments.has(card, 3): amount = int(floor(amount * 1.3))
	if CardEnchantments.has(card, 20) and _boost_applies(event, card, "enchantment_damage_boost"): amount = int(floor(amount * 1.5))
	if str(event.payload.side) == "enemy" and CardEnchantments.has(card, 6): amount *= 2
	event.payload.amount = amount
	if CardEnchantments.has(card, 13): event.payload["block_double"] = true

func _block(event: BattleEvent) -> void:
	var card := formal._live_card(str(event.metadata.get("source_card", "")))
	if event.id == int(event.metadata.get("block_program_id", -1)) and CardEnchantments.has(card, 21) and _boost_applies(event, card, "enchantment_block_boost"):
		event.payload.amount = int(floor(int(event.payload.amount) * 1.5))

func _boost_applies(event: BattleEvent, card: Dictionary, flag: String) -> bool:
	return bool(event.metadata.get(flag, false)) and str(event.metadata.get("enchantment_boost_source", "")) == str(card.get("instance_id", ""))

func _damaged(event: BattleEvent) -> void:
	if str(event.payload.side) != "enemy" or event.parent_id != int(event.metadata.get("damage_program_id", -1)): return
	var card := formal._live_card(str(event.metadata.get("source_card", "")))
	var loss := int(event.payload.get("health_loss", 0))
	if CardEnchantments.has(card, 14): _block_action(int(floor(loss * 0.5)))
	if CardEnchantments.has(card, 15): battle.rules.publish("action.heal", {"amount": int(floor(loss * 0.25))})
	if CardEnchantments.has(card, 19):
		battle.rules.publish("action.buff_add", {"side": "enemy", "target": event.payload.entity_id, "buff_id": "weak", "layers": 1})
	if CardEnchantments.has(card, 22) and loss > 0 and int(event.payload.health_after) == 0:
		battle.rules.publish("action.heal", {"amount": 2})

func _block_action(amount: int) -> void:
	var block_event := battle.rules.publish("action.block", {"side": "player", "target": "player", "amount": amount})
	block_event.metadata["block_program_id"] = block_event.id

func _discarded(event: BattleEvent) -> void:
	# 结算完成转入弃牌堆不是“丢弃手牌”，不会再次触发弃牌附魔。
	if not bool(event.payload.get("from_hand", false)) or bool(event.payload.card.get("nullified", false)): return
	var card: Dictionary = event.payload.card
	var ancestry: Array = event.metadata.get("enchantment_ancestry", []).duplicate()
	var key := str(card.instance_id)
	if key in ancestry or int(state().get("discard_count", 0)) >= MAX_DISCARD_REACTIONS: return
	ancestry.append(key)
	state()["discard_count"] = int(state().get("discard_count", 0)) + 1
	var metadata := {"enchantment_ancestry": ancestry, "damage_program_id": -1, "block_program_id": -1,
		"formal_damage": false, "heal_ratio": 0.0, "block_ratio": 0.0, "restore_amount": 0}
	if CardEnchantments.has(card, 1):
		var index := battle._find_card_index(battle.discard_pile, key)
		if index >= 0:
			battle.discard_pile.remove_at(index)
			battle.play_zone.append(card)
			battle.card_committed.emit(card.duplicate(true), battle.play_zone.size() - 1)
	if CardEnchantments.has(card, 7):
		for id: String in formal._enemy_ids():
			battle.rules.publish("action.damage", {"side": "enemy", "target": id, "amount": 5, "ignore_block": false, "use_stats": false}, metadata)
	if CardEnchantments.has(card, 8): battle.rules.publish("action.draw", {"count": 3}, metadata)
	if CardEnchantments.has(card, 9):
		battle.rules.publish("action.block", {"side": "player", "target": "player", "amount": 5}, metadata)
	if CardEnchantments.has(card, 10): state()["pointer_repeat"] = int(state().get("pointer_repeat", 0)) + 1
	if CardEnchantments.has(card, 11):
		if battle.pointer_index == 0: battle.rules.publish("action.draw", {"count": 1}, metadata)
		else: state()["pointer_rewind"] = int(state().get("pointer_rewind", 0)) + 1
	if CardEnchantments.has(card, 12):
		battle.rules.publish("action.buff_add", {"side": "player", "target": "player", "buff_id": "strength", "layers": 1}, metadata)
		for id: String in formal._enemy_ids():
			battle.rules.publish("action.buff_add", {"side": "enemy", "target": id, "buff_id": "vulnerable", "layers": 1}, metadata)

func _pointer(event: BattleEvent) -> void:
	if not battle.active or int(event.payload.get("distance", 0)) <= 0: return
	if int(state().get("pointer_rewind", 0)) <= 0 and int(state().get("pointer_repeat", 0)) <= 0: return
	# 旧残片/测试可以只广播移动距离；没有真实目标索引时不消费指针附魔。
	if not event.payload.has("to"): return
	var target := int(event.payload.to)
	var rewind := int(state().get("pointer_rewind", 0))
	if rewind > 0:
		state()["pointer_rewind"] = 0
		target = maxi(0, target - rewind)
		event.payload.to = target
		event.payload.distance = absi(target - int(event.payload.get("from", battle.pointer_index)))
		if bool(event.payload.get("automatic", false)): battle.pointer_index = target
		else: battle._next_pointer_override = target
	var repeats := int(state().get("pointer_repeat", 0))
	if repeats > 0 and target >= 0 and target < battle.play_zone.size():
		state()["pointer_repeat"] = 0
		battle.repeat_card_at(target, repeats)

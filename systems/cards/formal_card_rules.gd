class_name FormalCardRules
extends RefCounted

## CSV 属性 + 显式指令。全部反应在现有事件队列中执行，不监听 UI 信号。
var battle: BattleStateMachine
var cards: Dictionary
var buffs: Dictionary


func _init(p_battle: BattleStateMachine, p_cards: Dictionary, p_buffs: Dictionary) -> void:
	battle = p_battle
	cards = p_cards
	buffs = p_buffs
	for type: String in ["action.card_program", "player.turn_started", "cards.sequence_committed",
			"combatant.damaged", "card.drawn", "card.discarded", "card.skipped", "pointer.moved"]:
		battle.rules.register_rule("formal." + type, type, _event)
	battle.rules.register_rule("formal.turn_end", "flow.enemy.begin", _turn_end, 0)
	battle.rules.register_rule("formal.enemy_end", "flow.enemy.buffs", _enemy_end, 0)
	battle.rules.register_rule("formal.finish_card", "flow.sequence.finish", _finish_card, 0)
	battle.rules.register_rule("formal.damage", "action.damage", _damage_adjust, 5)
	battle.rules.register_rule("formal.poison", "action.buff_add", _poison_adjust, 5)
	for zone: Array in [battle.draw_pile, battle.discard_pile, battle.hand, battle.play_zone]:
		for card: Dictionary in zone:
			var data: CardData = cards.get(str(card.card_id))
			if data != null:
				battle.update_card_properties(str(card.instance_id), {"occupies_slot": not FinalBossRules.is_saturn(card) and data.occupies_slot and not CardEnchantments.has(card, 4)})


func state() -> Dictionary:
	return battle.card_rule_state()


func is_disabled(id: String) -> bool:
	return bool(state().get("disabled", {}).get(id, false))


func before_card(event: BattleEvent) -> void:
	var card: Dictionary = event.payload.card
	var id := str(card.instance_id)
	var data: CardData = cards.get(str(card.card_id))
	var counts: Dictionary = state().get("trigger_counts", {})
	counts[id] = int(counts.get(id, 0)) + 1
	state()["trigger_counts"] = counts
	if data == null or data.effects.is_empty() or not data.effects[0] is CardEffectProgram:
		return
	state()["copy_source"] = state().get("previous", {}).duplicate(true)
	if str(card.card_id) != "64" and not (data.effects[0] as CardEffectProgram).instructions.is_empty():
		state()["previous"] = {"instructions": (data.effects[0] as CardEffectProgram).instructions.duplicate(true), "id": str(card.card_id)}


func _event(event: BattleEvent) -> void:
	if not battle.active:
		return
	match event.type:
		"action.card_program":
			_execute(event.payload.instruction, event.payload.card, _target(event.payload.get("target")))
		"player.turn_started":
			var next_slots := int(state().get("next_slots", 0))
			state().merge({"slots": next_slots, "next_slots": 0, "loss_count": 0, "life_lost": 0,
				"enemy_loss": 0, "auras": [], "disabled": {}, "trigger_counts": {}, "skips": {},
				"pointer_distance": 0, "next_damage": {}, "repeat_bonus": 0, "anchor": "",
				"refund": false, "previous": {}, "copy_source": {}, "pending_disable": {}}, true)
		"cards.sequence_committed":
			state()["layout"] = event.payload.hand.map(func(c: Dictionary): return str(c.instance_id))
			_right_curse()
		"card.drawn":
			_react("draw", event)
			_right_curse()
		"card.discarded":
			if bool(event.payload.get("from_hand", false)):
				_react("discard", event)
				if str(event.payload.card.card_id) == "69":
					_schedule({"op": "curse"}, event.payload.card, "")
			_right_curse()
		"combatant.damaged":
			_damaged(event)
		"pointer.moved":
			state()["pointer_distance"] = int(state().get("pointer_distance", 0)) + int(event.payload.distance)
		"card.skipped":
			var card: Dictionary = event.payload.card
			var skips: Dictionary = state().get("skips", {})
			skips[str(card.instance_id)] = int(skips.get(str(card.instance_id), 0)) + 1
			state()["skips"] = skips
			if str(card.card_id) == "46":
				_schedule({"op": "buff", "buff": "strength", "amount": 4, "scope": "player"}, card, "")
				_schedule({"op": "buff", "buff": "tenacity", "amount": 4, "scope": "player"}, card, "")
			elif str(card.card_id) == "47":
				_schedule({"op": "slots", "amount": 1, "next": true}, card, "")


func _target(raw: Variant) -> String:
	if raw != null and not str(raw).is_empty():
		return str(raw)
	for enemy: Dictionary in battle.enemies:
		if int(enemy.health) > 0:
			return str(enemy.enemy_id)
	return ""


func _schedule(instruction: Dictionary, card: Dictionary, target: String) -> void:
	if _nullified(card): return
	battle.rules.publish("action.card_program", {"instruction": instruction, "card": card, "target": target},
		{"source_card": str(card.instance_id), "heal_ratio": 0.0, "block_ratio": 0.0, "restore_amount": 0})


func _execute(op: Dictionary, card: Dictionary, target: String) -> void:
	if _nullified(card): return
	var id := str(card.instance_id)
	var scale_factor := float(card.get("effect_scale", 1.0))
	var n := int(floor(_value(op.get("amount", 0), card, target) * scale_factor))
	match str(op.op):
		"damage", "loss":
			var targets: Array = _enemy_ids() if bool(op.get("all", false)) else [target]
			if op.op == "loss":
				targets = ["player"]
			for destination: String in targets:
				var damage_event := battle.rules.publish("action.damage" if op.op == "loss" else "enchantment.damage", {"side": "player" if destination == "player" else "enemy",
					"target": destination, "amount": n, "ignore_block": op.op == "loss",
					"use_stats": op.op != "loss", "source_side": "player", "source_id": "player",
					"block_double": bool(op.get("block_double", false))},
					{"source_card": id, "formal_damage": op.op != "loss", "true_loss": op.op == "loss",
					"self_source": op.op == "loss", "heal_ratio": float(op.get("heal_ratio", 0)),
					"block_ratio": float(op.get("block_ratio", 0)),
					"restore_amount": int(state().get("consumed_block", 0)) if bool(op.get("restore_on_kill", false)) else 0})
				damage_event.metadata["damage_program_id"] = damage_event.id
		"block":
			var block_event := battle.rules.publish("action.block", {"side": "player", "target": "player", "amount": n})
			block_event.metadata["block_program_id"] = block_event.id
		"heal":
			battle.rules.publish("action.heal", {"amount": n})
		"buff":
			var scope := str(op.get("scope", "target"))
			var targets: Array = _enemy_ids() if scope == "all" else ["player" if scope == "player" else target]
			for destination: String in targets:
				battle.rules.publish("action.buff_add", {"side": "player" if destination == "player" else "enemy",
					"target": destination, "buff_id": op.buff, "layers": n})
		"draw":
			battle.rules.publish("action.draw", {"count": int(floor(int(op.count) * scale_factor))})
		"discard":
			var count := int(floor(int(op.count) * scale_factor))
			if count > 0: battle.rules.publish("action.discard_choice", {"count": count})
		"remove":
			battle.rules.publish("action.remove_card", {"instance_id": id})
		"aura":
			var auras: Array = state().get("auras", [])
			auras.append({"event": op.event, "effect": op.effect, "card": card.duplicate(true), "target": target})
			state()["auras"] = auras
		"slots":
			var key := "next_slots" if bool(op.get("next", false)) else "slots"
			state()[key] = int(state().get(key, 0)) + n
		"next_damage":
			var index := battle._find_card_index(battle.play_zone, id) + 1
			if index > 0 and index < battle.play_zone.size():
				var next: String = battle.play_zone[index].instance_id
				var bonuses: Dictionary = state().get("next_damage", {})
				bonuses[next] = int(bonuses.get(next, 0)) + n
				state()["next_damage"] = bonuses
		"lock_next":
			var index := battle._find_card_index(battle.play_zone, id) + 1
			if index > 0 and index < battle.play_zone.size():
				battle.update_card_properties(str(battle.play_zone[index].instance_id), {"locked_until": battle.turn_number + 1})
		"repeat_last":
			if not battle.play_zone.is_empty():
				var last := battle.play_zone.size() - 1
				if int(state().get("trigger_counts", {}).get(id, 0)) == 1:
					battle.repeat_card_at(last, 1)
		"repeat":
			var count := _value(op.count, card, target) + int(state().get("repeat_bonus", 0))
			for _index in maxi(0, count):
				for instruction: Dictionary in op.body:
					_schedule(instruction, card, target)
		"boost_repeat":
			state()["repeat_bonus"] = int(state().get("repeat_bonus", 0)) + 1
		"disable":
			_disable(id)
		"pointer":
			_pointer(op, card)
		"swap_neighbors":
			var index := battle._find_card_index(battle.play_zone, id)
			battle.swap_play_cards(index - 1, index + 1)
		"swap_next":
			var index := battle._find_card_index(battle.play_zone, id)
			battle.swap_play_cards(index, index + 1)
		"recover":
			battle.request_pile_choice(int(op.count), id)
		"poison_tick":
			var targets: Array = _enemy_ids() if bool(op.get("all", false)) else [target]
			for destination: String in targets:
				if bool(op.get("consume", true)):
					battle.rules.publish("buff.poison_tick", {"entity_id": destination})
				else:
					battle.rules.publish("action.damage", {"side": "enemy", "target": destination,
						"amount": _layers(destination, "poison"), "ignore_block": true, "use_stats": false},
						{"formal_damage": false, "heal_ratio": 0.0, "block_ratio": 0.0, "restore_amount": 0})
		"merge_poison":
			var sum := 0
			for enemy: Dictionary in battle.enemies:
				sum += _layers(str(enemy.enemy_id), "poison")
				battle.rules.publish("action.buff_set", {"side": "enemy", "target": enemy.enemy_id, "buff_id": "poison", "layers": 0})
			battle.rules.publish("action.buff_set", {"side": "enemy", "target": target, "buff_id": "poison", "layers": sum})
		"spread_poison":
			var amount := _layers(target, "poison") + (10 if _enemy_ids().size() == 1 else 0)
			for destination: String in _enemy_ids():
				battle.rules.publish("action.buff_add", {"side": "enemy", "target": destination, "buff_id": "poison", "layers": amount})
		"refund_life":
			state()["refund"] = true
		"consume_block":
			state()["consumed_block"] = int(battle.player.block)
			state()["block_restored"] = false
			battle.set_player_block(0)
		"copy_previous":
			for instruction: Dictionary in state().get("copy_source", {}).get("instructions", []):
				if str(instruction.op) != "copy_previous":
					_schedule(instruction, card, target)
		"curse":
			var cursed: Dictionary = state().get("cursed", {})
			if cursed.has(id):
				return
			cursed[id] = true
			state()["cursed"] = cursed
			battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": 6,
				"ignore_block": false, "use_stats": false}, {"self_source": true, "formal_damage": false})
			battle.rules.publish("action.remove_card", {"instance_id": id})
		_:
			battle.rules.last_error = ERR_INVALID_DATA
			push_error("Unknown formal card instruction: " + str(op.op))


func _value(raw: Variant, card: Dictionary, target: String) -> int:
	if not raw is String:
		return int(raw)
	match raw:
		"loss_count": return int(state().get("loss_count", 0))
		"poison_target": return _layers(target, "poison")
		"block": return int(battle.player.block)
		"received": return int(_live_card(str(card.instance_id)).get("received", 0))
		"recorded_block": return int(_live_card(str(card.instance_id)).get("recorded_block", 0))
		"pointer_damage": return 3 + 3 * int(state().get("pointer_distance", 0))
		"extra_slots": return 5 + 3 * maxi(0, int(state().get("slots", 0)))
		"empty_slots":
			var occupied := 0
			for c: Dictionary in battle.play_zone:
				if not bool(c.get("slot_empty", false)) and bool(c.get("occupies_slot", true)):
					occupied += 1
			return 5 + 5 * maxi(0, battle.effective_play_limit() - occupied)
		"coins":
			var run_silver := GlobalState.current_run.gold if GlobalState.current_run != null else 0
			return int(floor(float(battle.player.get("silver", run_silver)) / 100.0))
		"skip_damage": return 4 * int(pow(2, mini(20, int(state().get("skips", {}).get(str(card.instance_id), 0)))))
		"consumed_block": return int(floor(2.5 * int(state().get("consumed_block", 0))))
		"nonshift", "shift":
			var result := 0
			for c: Dictionary in battle.play_zone:
				var data: CardData = cards.get(str(c.card_id))
				if data != null and not bool(c.get("slot_empty", false)):
					if (data.kind == CardData.Kind.SHIFT) == (raw == "shift"):
						result += 1
			return result
	return 0


func _pointer(op: Dictionary, card: Dictionary) -> void:
	var id := str(card.instance_id)
	var count := int(state().get("trigger_counts", {}).get(id, 0))
	if op.has("budget"):
		var budget := _value(op.budget, card, "") + int(state().get("repeat_bonus", 0))
		if count > budget:
			_disable(id)
			return
		if count == budget:
			_disable(id)
	elif not bool(op.get("disable", false)) and count > 1:
		return
	var origin := battle.pointer_index if battle._next_pointer_override < 0 else battle._next_pointer_override
	var destination := 0 if bool(op.get("start", false)) else origin + int(op.steps)
	var anchor := str(state().get("anchor", ""))
	if not anchor.is_empty() and anchor != id:
		var index := battle._find_card_index(battle.play_zone, anchor)
		if index >= 0:
			destination = index
	battle.move_formal_pointer(destination)
	if bool(op.get("anchor", false)):
		state()["anchor"] = id
	if bool(op.get("disable", false)):
		_disable(id)


func _disable(id: String) -> void:
	var pending: Dictionary = state().get("pending_disable", {})
	pending[id] = true
	state()["pending_disable"] = pending


func _finish_card(event: BattleEvent) -> void:
	var id := str(event.payload.card.instance_id)
	if not bool(state().get("pending_disable", {}).get(id, false)):
		return
	if int(battle._repeat_remaining_by_card.get(id, 0)) > 0:
		return
	var disabled: Dictionary = state().get("disabled", {})
	disabled[id] = true
	state()["disabled"] = disabled
	state().get("pending_disable", {}).erase(id)


func _enemy_ids() -> Array[String]:
	var result: Array[String] = []
	for enemy: Dictionary in battle.enemies:
		if int(enemy.health) > 0:
			result.append(str(enemy.enemy_id))
	return result


func _layers(id: String, buff: String) -> int:
	var owner := battle.get_combatant(&"player" if id == "player" else &"enemy", id)
	for entry: Dictionary in owner.get("buffs", []):
		if str(entry.buff_id) == buff:
			return int(entry.layers)
	return 0


func _live_card(id: String) -> Dictionary:
	for zone: Array in [battle.hand, battle.play_zone, battle.discard_pile, battle.draw_pile]:
		for card: Dictionary in zone:
			if str(card.instance_id) == id:
				return card
	return {}


func _nullified(card: Dictionary) -> bool:
	return bool(card.get("nullified", false)) or bool(_live_card(str(card.instance_id)).get("nullified", false))


func _react(trigger: String, event: BattleEvent) -> void:
	var ancestry: Array = event.metadata.get("formal_ancestry", [])
	for aura: Dictionary in state().get("auras", []).duplicate(true):
		var key := str(aura.card.instance_id) + ":" + trigger
		if aura.event != trigger or ancestry.has(key) or _nullified(aura.card):
			continue
		var next := ancestry.duplicate()
		next.append(key)
		battle.rules.publish("action.card_program", {"instruction": aura.effect, "card": aura.card, "target": aura.target},
			{"source_card": str(aura.card.instance_id), "formal_ancestry": next, "heal_ratio": 0.0,
			"block_ratio": 0.0, "restore_amount": 0, "self_source": false})


func _damaged(event: BattleEvent) -> void:
	var loss := int(event.payload.get("health_loss", 0))
	if str(event.payload.side) == "player":
		if loss > 0:
			state()["loss_count"] = int(state().get("loss_count", 0)) + 1
			state()["life_lost"] = int(state().get("life_lost", 0)) + loss
			if battle.phase == BattleStateMachine.Phase.ENEMY_ACTION:
				state()["enemy_loss"] = int(state().get("enemy_loss", 0)) + loss
			for card: Dictionary in battle.hand:
				if str(card.card_id) == "54" and not _nullified(card):
					battle.update_card_properties(str(card.instance_id), {"received": int(card.get("received", 0)) + loss * (2 if bool(event.metadata.get("self_source", false)) else 1)})
	else:
		var direct := event.parent_id == int(event.metadata.get("damage_program_id", -1))
		if int(event.payload.damage) > 0:
			_react("damage_enemy", event)
			if direct:
				_move_seventy(event.metadata.get("seventy_move_ids", []))
		var heal := int(floor(loss * float(event.metadata.get("heal_ratio", 0)))) if direct else 0
		var block := int(floor(loss * float(event.metadata.get("block_ratio", 0)))) if direct else 0
		if heal > 0:
			battle.rules.publish("action.heal", {"amount": heal})
		if block > 0:
			var block_event := battle.rules.publish("action.block", {"side": "player", "target": "player", "amount": block})
			block_event.metadata["block_program_id"] = block_event.id
		if loss > 0 and int(event.payload.health_after) == 0:
			var restore := int(event.metadata.get("restore_amount", 0)) if direct else 0
			if restore > 0 and not bool(state().get("block_restored", false)):
				state()["block_restored"] = true
				battle.set_player_block(int(battle.player.block) + restore)
			if _enemy_ids().is_empty() and bool(state().get("refund", false)):
				battle.rules.publish("action.heal", {"amount": int(state().get("life_lost", 0))})


func _damage_adjust(event: BattleEvent) -> void:
	if event.id != int(event.metadata.get("damage_program_id", -1)) or str(event.payload.side) != "enemy":
		return
	var formal_damage := bool(event.metadata.get("formal_damage", false))
	var id := str(event.metadata.get("source_card", ""))
	if not formal_damage and (id.is_empty() or bool(event.metadata.get("dot", false)) or bool(event.metadata.get("relic_effect", false))): return
	var bonus := int(state().get("next_damage", {}).get(id, 0)) if formal_damage else 0
	var layout: Array = state().get("layout", [])
	var source_index := layout.find(id)
	var movers: Array[String] = []
	if source_index >= 0:
		for card: Dictionary in battle.hand:
			if str(card.card_id) != "70" or (not FinalBossRules.is_saturn(card) and _nullified(card)):
				continue
			var anchor := layout.find(str(card.instance_id))
			if anchor < 0:
				continue
			if FinalBossRules.is_saturn(card):
				bonus += -1 if source_index < anchor else 2
				continue
			if not formal_damage: continue
			bonus += 1 if source_index < anchor else -2
			if source_index < anchor:
				movers.append(str(card.instance_id))
	event.metadata["seventy_move_ids"] = movers
	event.payload["amount"] = maxi(0, int(event.payload.amount) + bonus)


func _move_seventy(ids: Array) -> void:
	var layout: Array = state().get("layout", [])
	for raw: Variant in ids:
		var id := str(raw)
		var hand_index := battle._find_card_index(battle.hand, id)
		if hand_index < 0:
			continue
		var anchor := layout.find(id)
		if anchor > 0:
			var previous: Variant = layout[anchor - 1]
			layout[anchor - 1] = id
			layout[anchor] = previous
		if hand_index > 0:
			battle.swap_hand_cards(hand_index, hand_index - 1)
	state()["layout"] = layout


func _poison_adjust(event: BattleEvent) -> void:
	if str(event.payload.buff_id) != "poison" or int(event.payload.layers) <= 0:
		return
	for aura: Dictionary in state().get("auras", []):
		if str(aura.event) == "poison_add" and not _nullified(aura.card):
			event.payload["layers"] = int(event.payload.layers) + int(aura.effect.amount)


func _turn_end(_event: BattleEvent) -> void:
	for card: Dictionary in battle.hand.duplicate(true):
		if str(card.card_id) == "68" and not _nullified(card):
			battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": 3,
				"ignore_block": false, "use_stats": false}, {"source_card": str(card.instance_id), "self_source": true, "formal_damage": false})
	_right_curse()


func _right_curse() -> void:
	if not battle.hand.is_empty() and str(battle.hand.back().card_id) == "69":
		_schedule({"op": "curse"}, battle.hand.back(), "")


func _enemy_end(_event: BattleEvent) -> void:
	if int(state().get("enemy_loss", 0)) > 0:
		return
	for card: Dictionary in battle.hand:
		if str(card.card_id) == "67" and not _nullified(card):
			battle.update_card_properties(str(card.instance_id), {"recorded_block": int(card.get("recorded_block", 0)) + int(battle.player.block)})

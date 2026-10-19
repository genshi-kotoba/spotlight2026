class_name RelicBattleSystem
extends Node

## 典籍是规则提供者，使用战斗统一队列；自身不再维护第二套结算循环。
signal fragment_activated(trigger_cell: int, effect_cell: int, description: String)
signal trigger_activated(cell: int, chained: bool)
signal chain_limited

const MAX_CHAIN_EFFECTS := 128

var catalog: Dictionary = {}
var board := RelicBoard.new()
var activation_count := 0
var _battle: BattleStateMachine
var _buff_catalog: Dictionary = {}
var _counts: Dictionary = {}
var _pending: Dictionary = {}
var _limited: Dictionary = {}
var _propagations: Dictionary = {}


func attach_to_battle(battle: BattleStateMachine, configured_board: RelicBoard,
		definitions: Dictionary, buff_definitions: Dictionary) -> Error:
	if _battle != null or battle == null or configured_board == null:
		return ERR_INVALID_PARAMETER
	if not BattleStateMachine._valid_relic_runtime(battle.player.get("relic_runtime", {})):
		return ERR_INVALID_DATA
	var error := board.restore(configured_board.to_dictionary(), definitions)
	if error != OK:
		return error
	catalog = definitions.duplicate()
	for id: String in board.cells:
		if not id.is_empty(): catalog[id] = RelicCatalog.resolve(id, catalog)
	_buff_catalog = buff_definitions
	_battle = battle
	_battle.rules.register_rule("relics.draw", "card.drawn", _on_card_gained)
	_battle.rules.register_rule("relics.damage", "combatant.damaged", _on_combatant_damaged)
	_battle.rules.register_rule("relics.turn", "player.turn_started", _on_player_turn_started)
	_battle.rules.register_rule("relics.custom", "relic.event", _on_custom_event)
	_battle.rules.register_rule("relics.activate", "relic.activate", _execute)
	_battle.rules.register_rule("relics.propagate", "relic.propagate", _spread)
	_battle.rules.register_rule("relics.completed", "relic.completed", _completed)
	for type: String in ["pointer.moved", "card.discarded", "enemy.died", "cards.sequence_committed", "card.effect_requested", "flow.enemy.begin"]:
		_battle.rules.register_rule("relics." + type, type, _event, 60)
	_battle.rules.register_rule("relics.damage_bonus", "action.damage", _damage_bonus, 7)
	_battle.rules.register_rule("relics.attack_count", "action.damage", _count_attack, 110)
	if not _battle.player.has("relic_runtime"): _battle.player["relic_runtime"] = {}
	# Relay credits belong to a battle and survive a safe-boundary battle save.
	# Only the fragment's own condition rearms one; a new root/turn does not.
	if not state().get("chain_charges") is Dictionary:
		state()["chain_charges"] = {}
	for index in RelicBoard.CELL_COUNT:
		if not state().chain_charges.has(str(index)): state().chain_charges[str(index)] = true
	_battle.player["hand_limit"] = maxi(1, 10 - _curse_count("hand_limit") * 2)
	return OK


func _exit_tree() -> void:
	if is_instance_valid(_battle):
		_battle.rules.remove_rules_for(self)


func _on_card_gained(event: BattleEvent) -> void:
	# 只过滤典籍的抽牌触发，不丢弃事实或关闭独立的回合开始存在类效果。
	if int(event.payload.get("draw_reason", BattleStateMachine.DrawReason.EFFECT)) != BattleStateMachine.DrawReason.EFFECT:
		return
	_trigger("card_gained", "", event)


func _on_player_turn_started(event: BattleEvent) -> void:
	# 清除旧回合根事件的预算，限制运行期追踪数据规模。
	_counts.clear()
	_pending.clear()
	_limited.clear()
	_propagations.clear()
	var runtime := state()
	runtime.merge({"distance": 0, "attacks": 0, "extra_used": 0, "extra_pointers": 0, "extra_pointer_active": false,
		"turn_damage": 0, "next_damage": 0, "next_bonus_card": "", "next_bonus": 0, "committed": 0,
		"next_slot_counts": {}, "carry_granted": false, "slots": int(runtime.get("next_slots", 0)), "next_slots": 0, "discard_chances": 0}, true)
	_trigger("player_turn_started", "", event)


func _enemy_was_damaged(event: BattleEvent) -> bool:
	return event.payload.side == "enemy" and int(event.payload.health_loss) > 0


func _on_combatant_damaged(event: BattleEvent) -> void:
	if event.payload.side == "enemy" and int(event.payload.health_loss) > 0:
		_trigger("enemy_damaged", String(event.payload.entity_id), event)
		if bool(event.metadata.get("dot", false)): _trigger("dot_damage", String(event.payload.entity_id), event)
	elif event.payload.side == "player":
		if int(event.payload.blocked) > 0: _trigger("blocked", "", event)
		if int(event.payload.health_loss) > 0: _trigger("player_damaged", "", event)


func state() -> Dictionary:
	return _battle.player.relic_runtime


func _count_attack(event: BattleEvent) -> void:
	if not _battle.active or event.payload.get("side") != "enemy" or not bool(event.payload.get("use_stats", false)) or event.payload.get("source_side") != "player" or bool(event.payload.get("skip", false)) or bool(event.metadata.get("relic_effect", false)) or str(event.metadata.get("source_card", "")).is_empty(): return
	state()["attacks"] = int(state().get("attacks", 0)) + 1
	if int(state().attacks) % 5 == 0: _trigger("attack_five", str(event.payload.target), event)


func _event(event: BattleEvent) -> void:
	if not _battle.active: return
	match event.type:
		"pointer.moved":
			var before := int(state().get("distance", 0))
			state()["distance"] = before + int(event.payload.distance)
			for index in int(state().distance) / 4 - before / 4: _trigger("pointer_four", "", event)
			if not bool(event.payload.get("automatic", false)): _trigger("pointer_moved", "", event)
		"card.discarded":
			if bool(event.payload.get("from_hand", false)): _trigger("card_discarded", "", event)
		"enemy.died": _trigger("enemy_died", str(event.payload.enemy_id), event)
		"cards.sequence_committed":
			state()["committed"] = _battle.play_zone.filter(func(c: Dictionary): return not bool(c.get("slot_empty", false)) and bool(c.get("occupies_slot", true))).size()
			for card: Dictionary in _battle.play_zone:
				if not bool(card.get("slot_empty", false)) and _curse_count("loss_on_play") > 0:
					_loss(2 * _curse_count("loss_on_play"))
		"flow.enemy.begin": _trigger("turn_end", "", event)


func _damage_bonus(event: BattleEvent) -> void:
	if event.payload.get("side") != "enemy" or not bool(event.payload.get("use_stats", false)) or str(event.payload.get("source_side", "")) != "player" or bool(event.metadata.get("relic_effect", false)): return
	var id := str(event.metadata.get("source_card", ""))
	if id.is_empty(): return
	var amount := int(state().get("turn_damage", 0))
	var alive := _battle.enemies.filter(func(enemy: Dictionary): return int(enemy.health) > 0).size()
	amount += _presence_count("few_enemies") * maxi(0, 3 - alive)
	if int(state().get("next_damage", 0)) > 0:
		if str(state().get("next_bonus_card", "")) != id: state()["next_bonus"] = 0
		state()["next_bonus_card"] = id
		state()["next_bonus"] = int(state().get("next_bonus", 0)) + int(state().next_damage)
		state().next_damage = 0
	if str(state().get("next_bonus_card", "")) == id: amount += int(state().get("next_bonus", 0))
	event.payload.amount = int(event.payload.amount) + amount


func _presence_count(action: String) -> int:
	var count := 0
	for id: String in board.cells:
		var data: RelicFragmentData = catalog.get(id)
		if data != null and ((data.kind == RelicFragmentData.Kind.PRESENCE and data.action_id == action) or data.presence_action == action): count += 1
	return count


func _curse_count(action: String) -> int:
	var count := 0
	for id: String in board.cells:
		var data: RelicFragmentData = catalog.get(id)
		if data != null and (data.negative_action == action or (data.kind == RelicFragmentData.Kind.NEGATIVE and data.action_id == action)): count += 1
	return count


func natural_draw_count(base: int) -> int:
	return maxi(0, base + _curse_count("less_discard_more_hand") - (_curse_count("less_draw") if _battle.turn_number >= 3 else 0))


func manual_discard_count() -> int:
	return maxi(0, int(state().get("discard_chances", 0)) - _curse_count("less_discard_more_hand"))


func request_manual_discard() -> Error:
	if not _battle.active or _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION or manual_discard_count() <= 0 or _battle.hand.is_empty(): return ERR_UNAVAILABLE
	state().discard_chances = int(state().get("discard_chances", 0)) - 1
	_battle.request_battle_choice("discard", _battle.hand.duplicate(true), 1)
	return OK


func _loss(amount: int) -> void:
	_battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": amount, "ignore_block": true}, {"true_loss": true, "relic_effect": true})


func notify_event(event_id: String, target_id: String = "") -> void:
	if is_instance_valid(_battle) and _battle.active:
		_battle.rules.submit("relic.event", {"event_id": event_id, "target_id": target_id})


func _on_custom_event(event: BattleEvent) -> void:
	_trigger(String(event.payload.event_id), String(event.payload.target_id), event)


func _trigger(event_id: String, target_id: String, event: BattleEvent) -> void:
	if not _battle.active:
		return
	for index in RelicBoard.CELL_COUNT:
		var data: RelicFragmentData = catalog.get(board.cells[index])
		if data == null: continue
		if not data.presence_action.is_empty() and data.presence_event == event_id:
			_enqueue(index, index, target_id, [], event.root_id, true)
		if data.event_id == event_id:
			if data.kind == RelicFragmentData.Kind.PRESENCE:
				_enqueue(index, index, target_id, [], event.root_id)
			elif data.kind == RelicFragmentData.Kind.TRIGGER:
				state().chain_charges[str(index)] = true
				_queue_spread(index, false, target_id, event.root_id)


func _limit(root_id: int) -> void:
	if not _limited.has(root_id):
		_limited[root_id] = true
		chain_limited.emit()


func _queue_spread(cell: int, chained: bool, target: String, root_id: int) -> void:
	if _limited.has(root_id): return
	if int(_propagations.get(root_id, 0)) >= MAX_CHAIN_EFFECTS * 4:
		_limit(root_id)
		return
	_propagations[root_id] = int(_propagations.get(root_id, 0)) + 1
	# Nonempty ancestry marks derived facts as the same root for the event engine.
	# It is provenance only; relay eligibility uses the persistent credit above.
	_battle.rules.publish("relic.propagate", {"cell":cell, "chained":chained, "target":target}, {"relic_ancestry":[cell]})


func _spread(event: BattleEvent) -> void:
	if not _battle.active or _limited.has(event.root_id): return
	var cell := int(event.payload.cell)
	var data: RelicFragmentData = catalog.get(board.cells[cell])
	if data == null or data.kind != RelicFragmentData.Kind.TRIGGER: return
	trigger_activated.emit(cell, bool(event.payload.chained))
	_curse_on_trigger(data.negative_action)
	for neighbor: int in board.neighbors(cell, data.reach):
		var nearby: RelicFragmentData = catalog.get(board.cells[neighbor])
		if nearby == null: continue
		if nearby.kind == RelicFragmentData.Kind.EFFECT:
			_enqueue(cell, neighbor, str(event.payload.target), [cell], event.root_id)
		elif nearby.kind == RelicFragmentData.Kind.TRIGGER and bool(state().chain_charges.get(str(neighbor), false)):
			# Reserve at enqueue time so multiple parents cannot spend the same credit.
			state().chain_charges[str(neighbor)] = false
			_queue_spread(neighbor, true, str(event.payload.target), event.root_id)


func _enqueue(trigger: int, effect: int, target: String, ancestry: Array, root_id: int, presence: bool = false) -> void:
	if _limited.has(root_id) or int(_pending.get(root_id, 0)) >= MAX_CHAIN_EFFECTS:
		return
	_pending[root_id] = int(_pending.get(root_id, 0)) + 1
	_battle.rules.publish("relic.activate", {"trigger": trigger, "effect": effect, "target": target, "presence":presence},
		{"relic_ancestry": ancestry.duplicate() if not ancestry.is_empty() else [effect]})


func _execute(event: BattleEvent) -> void:
	# 该观测位按本次实际执行重置，不能继承父残片的成功状态。
	# UI 在致死取消 completed 时仍可展示此动作，跳过的预算项则不闪光。
	event.metadata["relic_activation_started"] = false
	if not _battle.active:
		return
	var root_id := event.root_id
	_pending[root_id] = maxi(0, int(_pending.get(root_id, 0)) - 1)
	if _limited.has(root_id) or int(_counts.get(root_id, 0)) >= MAX_CHAIN_EFFECTS:
		_limit(root_id)
		return
	var job := event.payload
	var data: RelicFragmentData = catalog[board.cells[int(job.effect)]]
	if bool(job.get("presence", false)):
		data = data.duplicate(true)
		data.action_id = data.presence_action
		data.amount = data.presence_amount
		data.description = data.extra_description
		data.negative_action = ""
	var target := _living_target(String(job.target))
	var context := BattleEffectContext.new(_battle, target, _buff_catalog)
	event.metadata["relic_effect"] = true
	match data.action_id:
		"damage":
			if target.is_empty():
				return
			context.damage_enemy(target, data.amount)
		"block":
			context.add_block(&"player", "player", data.amount)
		"strength":
			context.add_buff(&"player", "player", &"strength", data.amount)
		"random_damage":
			var alive := _battle.enemies.filter(func(enemy: Dictionary): return int(enemy.health) > 0)
			if not alive.is_empty(): context.damage_enemy(str(_battle._logic_stream.pick(alive).enemy_id), data.amount)
		"draw": context.draw(data.amount)
		"poison":
			if not target.is_empty(): context.add_buff(&"enemy", target, &"poison", data.amount)
		"silver": _battle.player["silver"] = int(_battle.player.get("silver", 0)) + data.amount
		"turn_damage": state()["turn_damage"] = int(state().get("turn_damage", 0)) + data.amount
		"next_damage": state()["next_damage"] = int(state().get("next_damage", 0)) + data.amount
		"discard_chance": state()["discard_chances"] = int(state().get("discard_chances", 0)) + data.amount
		"carry_slot":
			if _battle.effective_play_limit() - int(state().get("committed", 0)) > 0 and not bool(state().get("carry_granted", false)):
				state()["carry_granted"] = true
				state()["next_slots"] = int(state().get("next_slots", 0)) + 1
		"next_slot":
			var counts: Dictionary = state().get("next_slot_counts", {})
			var key := str(job.effect)
			if int(counts.get(key, 0)) < 2:
				counts[key] = int(counts.get(key, 0)) + 1
				state()["next_slots"] = int(state().get("next_slots", 0)) + 1
				state()["next_slot_counts"] = counts
		"rewind":
			if _battle.phase == BattleStateMachine.Phase.PLAYER_EFFECTS and _battle.pointer_index > 0:
				context.rewind_pointer(data.amount)
		"extra_pointer":
			if not bool(event.metadata.get("extra_pointer", false)) and int(state().get("extra_used", 0)) < 2:
				state()["extra_used"] = int(state().get("extra_used", 0)) + 1
				state()["extra_pointers"] = int(state().get("extra_pointers", 0)) + 1
		"enchant":
			if int(_battle._logic_stream.int_range(0, 100)) < data.amount:
				var candidates: Array = []
				for zone: Array in [_battle.hand, _battle.play_zone, _battle.draw_pile, _battle.discard_pile]:
					for card: Dictionary in zone:
						if not RunRandomEvents.legal_enchants(card).is_empty() and not bool(card.get("slot_empty", false)): candidates.append(card)
				if not candidates.is_empty():
					var card: Dictionary = _battle._logic_stream.pick(candidates)
					var enchants: Array = card.get("enchantments", []).duplicate()
					enchants.append(str(_battle._logic_stream.pick(RunRandomEvents.legal_enchants(card))))
					_battle.update_card_properties(str(card.instance_id), {"enchantments": enchants})
					if not str(card.get("copy_id", "")).is_empty():
						var updates: Dictionary = _battle.player.get("enchantment_updates", {})
						updates[str(card.copy_id)] = enchants.duplicate()
						_battle.player["enchantment_updates"] = updates
		"debuff_duration":
			for enemy: Dictionary in _battle.enemies:
				if int(enemy.health) <= 0: continue
				for buff: Dictionary in enemy.buffs:
					if str(buff.buff_id) == "poison": buff["decay_delay"] = int(buff.get("decay_delay", 0)) + data.amount
					elif str(buff.buff_id) in ["weak", "vulnerable"]: buff.duration = int(buff.duration) + data.amount
		_:
			return
	event.metadata["relic_activation_started"] = true
	_curse_on_trigger(data.negative_action)
	_counts[root_id] = int(_counts.get(root_id, 0)) + 1
	_battle.rules.publish("relic.completed", {"trigger": job.trigger, "effect": job.effect, "description": data.description})


func _curse_on_trigger(action: String) -> void:
	match action:
		"trigger_loss": _loss(1)
		"trigger_discard":
			if not _battle.hand.is_empty():
				_battle.rules.publish("action.discard", {"instance_id": _battle.hand.back().instance_id, "reason": "relic_curse"})
		"trigger_heal_enemy":
			var target := _living_target("")
			if not target.is_empty(): _battle.rules.publish("monster.heal", {"target": target, "amount": 5})


func _completed(event: BattleEvent) -> void:
	activation_count += 1
	fragment_activated.emit(int(event.payload.trigger), int(event.payload.effect), String(event.payload.description))


func _living_target(preferred: String) -> String:
	for enemy: Dictionary in _battle.enemies:
		if enemy.enemy_id == preferred and int(enemy.health) > 0:
			return preferred
	for enemy: Dictionary in _battle.enemies:
		if int(enemy.health) > 0:
			return String(enemy.enemy_id)
	return ""

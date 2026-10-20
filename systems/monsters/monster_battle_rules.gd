class_name MonsterBattleRules
extends RefCounted
## 怪物只通过统一事件队列产生 action；UI 不决定攻击、召唤、反射或死亡。
const MAX_LIVING_ENEMIES := 3
var battle: BattleStateMachine
var cards: Dictionary
var buffs: Dictionary

func _init(p_battle: BattleStateMachine, p_cards: Dictionary, p_buffs: Dictionary) -> void:
	battle = p_battle; cards = p_cards; buffs = p_buffs
	for type: String in ["player.turn_started", "enemy.turn_started", "enemy.action_requested", "monster.summon",
		"combatant.damaged", "monster.choice", "monster.choice_result", "monster.heal", "card.resolved", "potion.use"]:
		battle.rules.register_rule("monsters." + type, type, _event, 30)
	battle.rules.register_rule("monsters.plan", "flow.enemy.plan", _plan, 0)
	battle.rules.register_rule("monsters.sequence", "cards.sequence_committed", _sequence, 20)
	battle.rules.register_rule("monsters.damage", "action.damage", _damage, 25)
	battle.rules.register_rule("monsters.block", "action.block", _block, 25)
	battle.rules.register_rule("monsters.card", "card.effect_requested", _before_card, 0)
	for type: String in ["damage", "block", "heal", "buff_add", "draw", "discard_choice", "pointer_move", "pointer_rewind", "repeat_next"]:
		battle.rules.register_rule("monsters.bleed." + type, "action." + type, _bleed, 150)

func _event(event: BattleEvent) -> void:
	if not battle.active: return
	match event.type:
		"player.turn_started": _player_turn()
		"enemy.turn_started": _enemy_turn()
		"enemy.action_requested": _act(event)
		"combatant.damaged": _damaged(event)
		"monster.summon": event.metadata["summoned"] = _summon(str(event.payload.id), str(event.payload.owner))
		"monster.heal":
			var enemy := battle._combatant(&"enemy", str(event.payload.target))
			if not enemy.is_empty() and int(enemy.health) > 0:
				var before := int(enemy.health)
				enemy.health = mini(int(enemy.max_health), before + int(event.payload.amount))
				battle.combatant_healed.emit(&"enemy", str(enemy.enemy_id), int(enemy.health) - before, int(enemy.health))
		"monster.choice":
			battle.request_battle_choice(str(event.payload.mode), event.payload.candidates, 1)
		"monster.choice_result":
			var mode := str(event.payload.mode)
			for id: String in event.payload.ids:
				if mode == "discard": battle.discard_from_hand(id, &"monster")
				elif mode == "copy": _copy_hand(id)
				else: battle.update_card_properties(id, {"nullified": true})
		"potion.use": _potion(str(event.payload.item_id))

func _bleed(event: BattleEvent) -> void:
	if battle.active and int(battle.player.get("bleed_until", 0)) >= battle.turn_number and not bool(event.metadata.get("bleed", false)) and not bool(event.metadata.get("relic_effect", false)) and not str(event.metadata.get("source_card", "")).is_empty():
		_loss(1, {"bleed": true})

func _potion(item_id: String) -> void:
	if battle.phase != BattleStateMachine.Phase.PLAYER_ACTION or battle.rules.queue.paused: return
	var used: Array = battle.player.get("used_potions", [])
	if item_id in used: return
	for item: Dictionary in battle.player.get("potions", []):
		if str(item.item_id) != item_id: continue
		var kind := int(item.get("potion", -1))
		if kind == 2 and battle.hand.is_empty(): return
		used.append(item_id); battle.player["used_potions"] = used
		battle.potion_consumed.emit(item_id)
		match kind:
			0: battle.rules.publish("action.draw", {"count": 2})
			1: battle.rules.publish("action.block", {"side": "player", "target": "player", "amount": 5})
			2: battle.rules.publish("monster.choice", {"mode": "copy", "candidates": battle.hand.duplicate(true)})
			3: battle.card_rule_state()["slots"] = int(battle.card_rule_state().get("slots", 0)) + 1
		return

func living(id: int) -> Array:
	return battle.enemies.filter(func(e: Dictionary): return int(e.health) > 0 and int(e.get("monster_id", 0)) == id)

func _buff(side: String, target: String, id: String, amount: int, duration := -1) -> void:
	battle.rules.publish("action.buff_add", {"side": side, "target": target, "buff_id": id, "layers": amount, "duration": duration})

func _loss(amount: int, metadata: Dictionary = {}) -> void:
	metadata["true_loss"] = true
	battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": amount, "ignore_block": true}, metadata)

func _player_turn() -> void:
	for enemy: Dictionary in battle.enemies.duplicate():
		if int(enemy.health) <= 0: continue
		enemy["piper_card"] = ""
		match int(enemy.get("monster_id", 0)):
			1:
				if battle.turn_number > 1:
					var distance := int(battle.player.get("monster_pointer_distance", 0))
					if battle.turn_number % 2 == 0:
						_buff("player" if distance > 4 else "enemy", "player" if distance > 4 else str(enemy.enemy_id), "strength", 1)
					else: _buff("enemy" if distance < 4 else "player", str(enemy.enemy_id) if distance < 4 else "player", "weak", 1)
			14: _buff("enemy", str(enemy.enemy_id), "strength", 3, 0)
			15:
				if not bool(enemy.get("stole", false)):
					enemy.stole = true
					enemy["stolen"] = int(floor(int(battle.player.get("silver", 0)) * 0.3))
					battle.player.silver = int(battle.player.get("silver", 0)) - int(enemy.stolen)
					_buff("enemy", str(enemy.enemy_id), "weak", int(enemy.stolen) / 20, 0)
			16:
				for index in 3: battle.add_generated_card("69", "hand", "choir")
			17: enemy["trinity"] = int(battle._logic_stream.int_range(0, 3))
			18:
				if battle.turn_number > 5:
					battle.player.health = 1
					battle._finish_battle("escaped")
					return
				battle.rules.publish("monster.heal", {"target": enemy.enemy_id, "amount": 10})
	battle.player["monster_pointer_distance"] = 0

func _enemy_turn() -> void:
	battle.player["monster_pointer_distance"] = int(battle.card_rule_state().get("pointer_distance", 0))
	for enemy: Dictionary in living(10):
		battle.rules.publish("monster.summon", {"id": "5", "owner": enemy.enemy_id})
	for enemy: Dictionary in living(15):
		for buff: Dictionary in enemy.buffs:
			if str(buff.buff_id) == "weak": buff.layers = maxi(0, int(buff.layers) - 1)

func _plan(event: BattleEvent) -> void:
	if not battle.active: return
	var planned: Array = []
	var formal := false
	for enemy: Dictionary in battle.enemies:
		if int(enemy.health) <= 0: continue
		if enemy.has("monster_id"):
			formal = true
			for action: Dictionary in MonsterCatalog.plan(enemy, battle.turn_number, battle._logic_stream):
				planned.append({"enemy_id": enemy.enemy_id, "action": action})
		else: planned.append({"enemy_id": enemy.enemy_id, "action": battle._logic_stream.pick(enemy.actions)})
	if formal: event.payload["planned"] = planned

func _act(event: BattleEvent) -> void:
	var enemy := battle._combatant(&"enemy", str(event.payload.enemy_id))
	if not enemy.has("monster_id"): return
	event.payload["handled"] = true
	var action: Dictionary = event.payload.action
	var id := str(enemy.enemy_id)
	if action.has("damage"):
		for hit in int(action.get("hits", 1)):
			battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": int(action.damage),
				"ignore_block": false, "use_stats": true, "source_side": "enemy", "source_id": id},
				{"monster_attack": id, "lifesteal_enemy": id if bool(action.get("lifesteal", false)) else ""})
	if action.has("block"): battle.rules.publish("action.block", {"side": "enemy", "target": id, "amount": int(action.block)})
	if action.has("dot"): _loss(int(action.dot), {"dot": true})
	if action.has("summon"): battle.rules.publish("monster.summon", {"id": action.summon, "owner": id})
	if action.has("bleed"): battle.player["bleed_until"] = battle.turn_number + 1
	if action.has("heal_player"): battle.rules.publish("action.heal", {"amount": int(action.heal_player)})
	if action.has("team_strength"):
		for other: Dictionary in battle.enemies:
			if int(other.health) > 0: _buff("enemy", str(other.enemy_id), "strength", int(action.team_strength), 0)
	if action.has("random_buff"):
		var buff := str(battle._logic_stream.pick(["strength", "tenacity", "weak", "poison"]))
		_buff("player" if buff in ["weak", "poison"] else "enemy", "player" if buff in ["weak", "poison"] else id, buff, 1)
	if action.has("discard_right") and not battle.hand.is_empty():
		battle.rules.publish("action.discard", {"instance_id": battle.hand.back().instance_id, "reason": "monster"})
	if action.has("forget"):
		var candidates := battle.hand.duplicate(true)
		battle._logic_stream.shuffle_in_place(candidates)
		battle.rules.publish("monster.choice", {"mode": "discard", "candidates": candidates.slice(0, 2)})
	if action.has("nullify"):
		for zone: Array in [battle.hand, battle.discard_pile]:
			var candidates := zone.filter(func(card: Dictionary): return not bool(card.get("nullified", false))).duplicate(true)
			battle.rules.publish("monster.choice", {"mode": "nullify", "candidates": candidates})

func _sequence(_event: BattleEvent) -> void:
	if not living(2).is_empty() and not battle.play_zone.is_empty() and battle.play_zone.size() < battle.effective_play_limit():
		battle.repeat_card_at(0, 1)

func _before_card(event: BattleEvent) -> void:
	if bool(event.metadata.get("extra_pointer", false)): return
	var card: Dictionary = event.payload.card
	if bool(card.get("slot_empty", false)) or bool(card.get("nullified", false)): return
	var data: CardData = cards.get(str(card.card_id))
	var attack := data != null and data.kind == CardData.Kind.DAMAGE
	for enemy: Dictionary in battle.enemies:
		if int(enemy.health) <= 0: continue
		if int(enemy.get("monster_id", 0)) == 13 and attack and str(enemy.get("piper_card", "")).is_empty(): enemy.piper_card = str(card.instance_id)
		if int(enemy.get("monster_id", 0)) == 17:
			match int(enemy.get("trinity", 0)):
				0: battle.rules.publish("action.block", {"side": "enemy", "target": enemy.enemy_id, "amount": 3})
				1: _loss(3)
				2: _buff("enemy", str(enemy.enemy_id), "strength", 1); _buff("enemy", str(enemy.enemy_id), "tenacity", 1)

func _damage(event: BattleEvent) -> void:
	var data := event.payload
	if data.get("side") != "enemy" or not bool(data.get("use_stats", false)) or str(data.get("source_side", "")) != "player": return
	var source := str(event.metadata.get("source_card", ""))
	for taunt: Dictionary in battle.enemies:
		if int(taunt.health) > 0 and bool(taunt.get("taunt", false)): data.target = str(taunt.enemy_id); break
	var target := battle._combatant(&"enemy", str(data.target))
	if target.is_empty() or int(target.get("health", 0)) <= 0:
		for enemy: Dictionary in battle.enemies:
			if int(enemy.health) > 0: data.target = str(enemy.enemy_id); target = enemy; break
	if int(target.get("monster_id", 0)) == 3 and str(target.get("first_attack", "")).is_empty() and not source.is_empty(): target.first_attack = source
	if int(target.get("monster_id", 0)) == 3 and str(target.get("first_attack", "")) == source:
		data.amount = int(floor(int(data.amount) * 0.5))
	if not living(12).is_empty() and not source.is_empty():
		battle.rules.publish("action.block", {"side": "player", "target": "player", "amount": int(data.amount)}, {"monster_converted": true})
		data["skip"] = true
		return
	for piper: Dictionary in living(13):
		if str(piper.get("piper_card", "")) == source and not source.is_empty():
			data.side = "player"; data.target = "player"; break

func _block(event: BattleEvent) -> void:
	if event.payload.get("side") != "player" or bool(event.metadata.get("monster_converted", false)) or str(event.metadata.get("source_card", "")).is_empty(): return
	for enemy: Dictionary in living(12):
		event.payload["skip"] = true
		battle.rules.publish("action.damage", {"side": "enemy", "target": enemy.enemy_id, "amount": int(event.payload.amount), "ignore_block": false}, {"monster_converted": true})
		break

func _damaged(event: BattleEvent) -> void:
	var data := event.payload
	if data.side == "player":
		var source := str(event.metadata.get("lifesteal_enemy", ""))
		if not source.is_empty() and int(data.health_loss) > 0: battle.rules.publish("monster.heal", {"target": source, "amount": int(data.health_loss)})
		return
	var enemy := battle._combatant(&"enemy", str(data.entity_id))
	var monster := int(enemy.get("monster_id", 0))
	if monster == 11 and int(enemy.health) <= 0 and int(enemy.phase) == 1:
		enemy.phase = 2; enemy.health = 96; enemy.max_health = 96; enemy.block = 0
		for id: String in ["14", "15"]: battle.rules.publish("monster.summon", {"id": id, "owner": enemy.enemy_id})
		return
	if int(data.health_loss) > 0:
		if monster == 9 and not bool(event.metadata.get("dot", false)):
			enemy["hits"] = int(enemy.get("hits", 0)) + 1
			if int(enemy.hits) % 3 == 0: _buff("player", "player", "poison", 3)
		elif monster == 19 and not bool(event.metadata.get("reflection", false)):
			_loss(int(data.health_loss), {"reflection": true})
		elif monster == 21: _buff("enemy", str(enemy.enemy_id), "strength", 1)
	if int(enemy.get("health", 0)) <= 0 and not bool(enemy.get("death_notified", false)):
		enemy["death_notified"] = true
		battle.rules.publish("enemy.died", {"enemy_id": enemy.enemy_id})
		if monster == 5:
			for owner: Dictionary in living(10): _buff("enemy", str(owner.enemy_id), "strength", 2, 0)
		if monster == 15:
			battle.player["stolen_refund"] = int(battle.player.get("stolen_refund", 0)) + maxi(0, int(enemy.get("stolen", 0)) - 50 * battle.turn_number)

func _summon(id: String, owner: String) -> bool:
	var living_count := 0
	for existing: Dictionary in battle.enemies:
		if int(existing.get("health", 0)) > 0:
			living_count += 1
	if living_count >= MAX_LIVING_ENEMIES:
		return false
	var formation_slot := next_formation_slot(battle.enemies)
	if formation_slot < 0:
		return false
	var serial := int(battle.player.get("summon_serial", 0)) + 1
	battle.player["summon_serial"] = serial
	var enemy := MonsterCatalog.create(id, int(battle.player.get("encounter_floor", 2)), "%s/summon/%d" % [owner, serial])
	if enemy.is_empty(): return false
	enemy["formation_slot"] = formation_slot
	enemy["summoned_by"] = owner
	enemy["spawn_turn"] = battle.turn_number
	battle.enemies.append(enemy)
	# 盗贼的入场行为也用于被召唤，不等待下一个回合重抽银币。
	if id == "15":
		enemy.stole = true; enemy.stolen = int(floor(int(battle.player.get("silver", 0)) * 0.3))
		battle.player.silver = int(battle.player.get("silver", 0)) - int(enemy.stolen)
		_buff("enemy", str(enemy.enemy_id), "weak", int(enemy.stolen) / 20, 0)

	return true

func _copy_hand(id: String) -> void:
	var index := battle._find_card_index(battle.hand, id)
	if index < 0: return
	var source: Dictionary = battle.hand[index]
	battle.add_generated_card(str(source.card_id), "hand", "potion-copy", source)


## 槽位属于敌人身份。召唤时保存槽号，读档后用同一解释重建站位。
## 旧记录没有槽号时保留完整历史，先用空位、再回收死亡位置。
static func formation_slots(enemies: Array) -> Dictionary:
	var result := {}
	var latest := {}
	for index in enemies.size():
		var enemy: Dictionary = enemies[index]
		var identity := str(enemy.get("enemy_id", ""))
		if identity.is_empty(): continue
		var role := -1
		var stored: Variant = enemy.get("formation_slot", -1)
		if index == 0:
			role = 0
		elif (stored is int or stored is float) and float(stored) == float(int(stored)) and int(stored) in [1, 2]:
			role = int(stored)
		if role >= 0 and latest.has(role) and int(latest[role].get("health", 0)) > 0:
			role = -1
		if role < 0:
			for candidate: int in [1, 2]:
				if not latest.has(candidate):
					role = candidate
					break
		if role < 0:
			for candidate: int in [1, 2]:
				if int(latest[candidate].get("health", 0)) <= 0:
					role = candidate
					break
		if role >= 0:
			result[identity] = role
			latest[role] = enemy
	return result


static func next_formation_slot(enemies: Array) -> int:
	var roles := formation_slots(enemies)
	var used := {0: true}
	for enemy: Dictionary in enemies:
		var identity := str(enemy.get("enemy_id", ""))
		if int(enemy.get("health", 0)) > 0 and roles.has(identity): used[int(roles[identity])] = true
	for role: int in [1, 2]:
		if not used.has(role): return role
	return -1

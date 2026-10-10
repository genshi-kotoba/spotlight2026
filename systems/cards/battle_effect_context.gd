class_name BattleEffectContext
extends EffectContext

## 效果资源的指令适配层：读取当前状态，写入事件队列；不直接修改战斗数值。
var battle: BattleStateMachine
var target: Variant
var buff_catalog: Dictionary


func _init(p_battle: BattleStateMachine, p_target: Variant, p_buff_catalog: Dictionary) -> void:
	battle = p_battle
	target = p_target
	buff_catalog = p_buff_catalog


func current_target() -> Variant:
	return target


func enemy_ids() -> Array[String]:
	var result: Array[String] = []
	for enemy: Dictionary in battle.enemies:
		if int(enemy["health"]) > 0:
			result.append(enemy["enemy_id"])
	return result


func player_health() -> int:
	return int(battle.player.get("health", 0))


func player_block() -> int:
	return int(battle.player.get("block", 0))


func buff_layers(entity: Variant, buff_id: StringName) -> int:
	var side: StringName = &"player" if String(entity) == "player" else &"enemy"
	var owner := battle.get_combatant(side, String(entity))
	for buff: Dictionary in owner.get("buffs", []):
		if buff.get("buff_id") == String(buff_id):
			return int(buff["layers"])
	return 0


func hand() -> Array[Dictionary]:
	return battle.hand.duplicate(true)


func play_zone() -> Array[Dictionary]:
	return battle.play_zone.duplicate(true)


func draw_pile_size() -> int:
	return battle.draw_pile.size()


func discard_pile() -> Array[Dictionary]:
	return battle.discard_pile.duplicate(true)


func pointer_index() -> int:
	return battle.pointer_index


func damage_enemy(enemy_id: String, amount: int, ignore_block: bool = false) -> void:
	_submit("damage", {"side": "enemy", "target": enemy_id, "amount": amount,
		"source_side": "player", "source_id": "player", "ignore_block": ignore_block, "use_stats": not ignore_block})


func damage_all_enemies(amount: int, ignore_block: bool = false) -> void:
	for enemy_id: String in enemy_ids():
		damage_enemy(enemy_id, amount, ignore_block)


func damage_player(amount: int, ignore_block: bool = false) -> void:
	_submit("damage", {"side": "player", "target": "player", "amount": amount,
		"ignore_block": ignore_block, "use_stats": false})


func damage_player_from(source_id: String, amount: int, ignore_block: bool = false) -> void:
	_submit("damage", {"side": "player", "target": "player", "amount": amount,
		"source_side": "enemy", "source_id": source_id, "ignore_block": ignore_block, "use_stats": not ignore_block})


func heal_player(amount: int) -> void:
	_submit("heal", {"amount": amount})


func add_block(side: StringName, entity_id: String, amount: int) -> void:
	_submit("block", {"side": String(side), "target": entity_id, "amount": amount})


func add_buff(side: StringName, entity_id: String, buff_id: StringName, layers: int) -> void:
	_submit("buff_add", {"side": String(side), "target": entity_id, "buff_id": String(buff_id), "layers": layers})


func set_buff_layers(side: StringName, entity_id: String, buff_id: StringName, layers: int) -> void:
	_submit("buff_set", {"side": String(side), "target": entity_id, "buff_id": String(buff_id), "layers": maxi(0, layers)})


func override_buff_duration(side: StringName, entity_id: String, buff_id: StringName,
		duration: int) -> void:
	_submit("buff_duration", {"side": String(side), "target": entity_id, "buff_id": String(buff_id), "duration": duration})


func tick_poison(entity: Variant) -> void:
	battle.rules.submit("buff.poison_tick", {"entity_id": String(entity)})


func draw(count: int) -> void:
	_submit("draw", {"count": count})


func discard_from_hand(instance_id: String, reason: StringName = &"effect") -> void:
	_submit("discard", {"instance_id": instance_id, "reason": String(reason)})


func discard_random(count: int) -> void:
	_submit("discard_random", {"count": count})


func request_discard_choice(count: int) -> void:
	_submit("discard_choice", {"count": count})


func is_waiting_for_input() -> bool:
	return battle.has_pending_discard_choice()


func remove_from_battle(card: Dictionary) -> void:
	_submit("remove_card", {"instance_id": String(card.get("instance_id", ""))})


func rewind_pointer(steps: int) -> void:
	_submit("pointer_rewind", {"steps": steps})


func move_pointer_to(index: int) -> void:
	_submit("pointer_move", {"index": index})


func repeat_next_card(extra_triggers: int) -> void:
	_submit("repeat_next", {"count": extra_triggers})


func _submit(type: String, data: Dictionary) -> void:
	battle.rules.submit("action." + type, data)

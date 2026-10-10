class_name BattleActionRules
extends RefCounted

## 唯一把效果指令落实到战斗状态的方法集合；效果资源只提交指令。
var battle: BattleStateMachine
var buff_catalog: Dictionary


func _init(p_battle: BattleStateMachine, p_buffs: Dictionary) -> void:
	battle = p_battle
	buff_catalog = p_buffs
	for type: String in ["damage", "block", "heal", "buff_add", "buff_set", "buff_duration",
		"buff_settle", "draw", "discard", "discard_random", "discard_choice", "remove_card",
		"pointer_rewind", "pointer_move", "repeat_next"]:
		battle.rules.register_rule("action." + type, "action." + type, _execute)


func _execute(event: BattleEvent) -> void:
	if not battle.active:
		return
	var data := event.payload
	match event.type:
		"action.damage":
			var side := String(data.side)
			var id := String(data.target)
			var owner := battle.get_combatant(StringName(side), id)
			if owner.is_empty() or int(owner.health) <= 0:
				return
			if side == "player":
				battle.apply_damage_to_player(int(data.amount), bool(data.ignore_block))
			else:
				battle.apply_damage_to_enemy(id, int(data.amount), bool(data.ignore_block))
		"action.block":
			battle.add_block(StringName(data.side), String(data.target), int(data.amount))
		"action.heal":
			battle.heal_player(int(data.amount))
		"action.buff_add", "action.buff_set":
			var definition: BuffData = buff_catalog.get(String(data.buff_id))
			if definition == null:
				battle.rules.last_error = ERR_DOES_NOT_EXIST
				return
			var layers := int(data.layers)
			if event.type == "action.buff_set":
				layers -= _layers(StringName(data.side), String(data.target), String(data.buff_id))
			battle.change_buff_layers(StringName(data.side), String(data.target),
				String(data.buff_id), layers, definition.duration)
		"action.buff_duration":
			var layers := _layers(StringName(data.side), String(data.target), String(data.buff_id))
			if layers > 0:
				battle.settle_buff_state(StringName(data.side), String(data.target),
					String(data.buff_id), layers, int(data.duration))
		"action.buff_settle":
			battle.settle_buff_state(StringName(data.side), String(data.target),
				String(data.buff_id), int(data.layers), int(data.duration))
		"action.draw":
			battle.draw_cards(int(data.count))
		"action.discard":
			battle.discard_from_hand(String(data.instance_id), StringName(data.reason))
		"action.discard_random":
			battle.discard_random_cards(int(data.count))
		"action.discard_choice":
			battle.request_discard_choice(int(data.count))
		"action.remove_card":
			battle.remove_card_from_battle(String(data.instance_id))
		"action.pointer_rewind":
			battle.request_pointer_rewind(int(data.steps))
		"action.pointer_move":
			battle.request_pointer_move_to(int(data.index))
		"action.repeat_next":
			battle.request_repeat_next_card(int(data.count))


func _layers(side: StringName, id: String, buff_id: String) -> int:
	for buff: Dictionary in battle.get_combatant(side, id).get("buffs", []):
		if String(buff.buff_id) == buff_id:
			return int(buff.layers)
	return 0

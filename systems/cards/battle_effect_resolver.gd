class_name BattleEffectResolver
extends Node

## 规则编译器：资源效果按顺序编译为队列事件，效果原语再产生 action 指令。
const CARD_DIR := "res://data/cards"
const BUFF_DIR := "res://data/buffs"

var battle: BattleStateMachine
var card_catalog: Dictionary = {}
var buff_catalog: Dictionary = {}
var _actions: BattleActionRules
var _stats: BattleStatRules


func attach_to_battle(p_battle: BattleStateMachine) -> Error:
	if battle != null or p_battle == null:
		return ERR_INVALID_PARAMETER
	var error := _load_catalogs()
	if error != OK:
		return error
	for zone: Array in [p_battle.draw_pile, p_battle.discard_pile,
			p_battle.hand, p_battle.play_zone]:
		for card: Dictionary in zone:
			if not card_catalog.has(String(card.get("card_id", ""))):
				push_error("BattleEffectResolver: card resource missing for %s" % card.get("card_id", ""))
				return ERR_DOES_NOT_EXIST
	battle = p_battle
	_actions = BattleActionRules.new(battle, buff_catalog)
	_stats = BattleStatRules.new(battle, buff_catalog)
	battle.rules.register_rule("cards.compile", "card.effect_requested", _on_card_effect_requested)
	battle.rules.register_rule("cards.effect", "effect.execute", _execute_effect)
	battle.rules.register_rule("buffs.compile", "buff.effect_requested", _on_buff_effect_requested)
	battle.rules.register_rule("buffs.step", "buff.effect_step", _step_buff_effect)
	battle.rules.register_rule("buffs.poison", "buff.poison_tick", _tick_poison)
	battle.rules.register_rule("enemies.action", "enemy.action_requested", _on_enemy_action_requested)
	return OK


func _exit_tree() -> void:
	if is_instance_valid(battle):
		battle.rules.remove_rules_for(self)
		battle.rules.remove_rules_for(_actions)
		battle.rules.remove_rules_for(_stats)


func _load_catalogs() -> Error:
	for path: String in _resource_paths(CARD_DIR):
		var resource: Resource = load(path)
		if not resource is CardData:
			return ERR_INVALID_DATA
		var card: CardData = resource
		var card_id := String(card.card_id)
		if card_id.is_empty():
			return ERR_INVALID_DATA
		# 原型数据有同名的两份；按排序取第一份作为该 card_id 的定义。
		if not card_catalog.has(card_id):
			card_catalog[card_id] = card
	for path: String in _resource_paths(BUFF_DIR):
		var resource: Resource = load(path)
		if not resource is BuffData:
			return ERR_INVALID_DATA
		var buff: BuffData = resource
		var buff_id := String(buff.buff_id)
		if buff_id.is_empty() or buff_catalog.has(buff_id):
			return ERR_INVALID_DATA
		buff_catalog[buff_id] = buff
	return OK


static func _resource_paths(directory: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	for file_name: String in dir.get_files():
		if file_name.ends_with(".tres"):
			result.append(directory + "/" + file_name)
	for child_directory: String in dir.get_directories():
		result.append_array(_resource_paths(directory + "/" + child_directory))
	result.sort()
	return result


func _on_card_effect_requested(event: BattleEvent) -> void:
	if not battle.active:
		return
	var card: Dictionary = event.payload.card
	var data: CardData = card_catalog.get(String(card.get("card_id", "")))
	if data == null:
		push_error("BattleEffectResolver: unknown card %s" % card.get("card_id", ""))
		battle.rules.last_error = ERR_DOES_NOT_EXIST
		return
	for effect: GameEffect in data.effects:
		battle.rules.publish("effect.execute", {"effect": effect, "card": card, "target": event.payload.target})


func _execute_effect(event: BattleEvent) -> void:
	if not battle.active:
		return
	var data := event.payload
	var effect: GameEffect = data.effect
	var context := BattleEffectContext.new(battle, data.target, buff_catalog)
	if effect is CardEffect:
		effect.execute(context, data.card)
	elif effect is BuffEffect:
		var modifier: BuffEffect = effect
		var entity_id := "player" if data.target == null else String(data.target)
		var side: StringName = &"player" if entity_id == "player" else &"enemy"
		var definition: BuffData = buff_catalog.get(String(modifier.buff_id))
		if definition != null:
			context.add_buff(side, entity_id, modifier.buff_id, definition.initial_layers)
			modifier.apply(context, entity_id, {"buff_id": String(modifier.buff_id),
				"layers": definition.initial_layers, "duration": definition.duration})
	else:
		battle.rules.last_error = ERR_INVALID_DATA


func _on_enemy_action_requested(event: BattleEvent) -> void:
	if not battle.active:
		return
	var action: Dictionary = event.payload.action
	var raw_damage: Variant = action.get("damage", 0)
	if (typeof(raw_damage) != TYPE_INT and typeof(raw_damage) != TYPE_FLOAT) \
			or int(raw_damage) <= 0:
		return
	var context := BattleEffectContext.new(battle, event.payload.enemy_id, buff_catalog)
	context.damage_player_from(String(event.payload.enemy_id), int(raw_damage))


func _on_buff_effect_requested(event: BattleEvent) -> void:
	if not battle.active:
		return
	var buff: Dictionary = event.payload.buff
	var data: BuffData = buff_catalog.get(String(buff.get("buff_id", "")))
	if data == null:
		push_error("BattleEffectResolver: unknown buff %s" % buff.get("buff_id", ""))
		return
	battle.rules.publish("buff.effect_step", {"side": event.payload.side, "entity_id": event.payload.entity_id,
		"buff": buff, "effects": data.effects, "index": 0, "limited": int(buff.duration) > 0})


func _step_buff_effect(event: BattleEvent) -> void:
	if not battle.active:
		return
	var data := event.payload
	var working: Dictionary = data.buff.duplicate(true)
	var context := BattleEffectContext.new(battle, data.entity_id, buff_catalog)
	var index := int(data.index)
	if index >= data.effects.size() or int(working.layers) <= 0:
		battle.rules.publish("action.buff_settle", {"side": data.side, "target": data.entity_id,
			"buff_id": working.buff_id, "layers": working.layers, "duration": working.duration})
		return
	var effect: GameEffect = data.effects[index]
	if effect is BuffEffect:
		var modifier: BuffEffect = effect
		working["layers"] = modifier.on_turn_update(context, data.entity_id, working)
		modifier.tick_duration(working)
		if modifier.is_expired(working) or (bool(data.limited) and int(working.duration) == 0):
			modifier.end(context, data.entity_id, working)
			working["layers"] = 0
	elif effect is CardEffect:
		effect.execute(context, {"instance_id": "", "card_id": ""})
	data["buff"] = working
	data["index"] = index + 1
	battle.rules.publish("buff.effect_step", data)


func _tick_poison(event: BattleEvent) -> void:
	if not battle.active:
		return
	var id := String(event.payload.entity_id)
	var side: StringName = &"player" if id == "player" else &"enemy"
	var data: BuffData = buff_catalog.get("poison")
	if data == null:
		return
	for buff: Dictionary in battle.get_combatant(side, id).get("buffs", []):
		if buff.buff_id != "poison":
			continue
		var context := BattleEffectContext.new(battle, id, buff_catalog)
		for effect: GameEffect in data.effects:
			if effect is BuffEffectPoison:
				var layers: int = effect.on_turn_update(context, id, buff)
				battle.rules.publish("action.buff_settle", {"side": String(side), "target": id,
					"buff_id": "poison", "layers": layers, "duration": buff.duration})
		return

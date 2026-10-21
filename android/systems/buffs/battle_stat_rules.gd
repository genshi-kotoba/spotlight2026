class_name BattleStatRules
extends RefCounted

## 数值规则在实际执行时读当前 Buff，并在 action 执行器之前修正指令。
var battle: BattleStateMachine
var catalog: Dictionary


func _init(p_battle: BattleStateMachine, p_catalog: Dictionary) -> void:
	battle = p_battle
	catalog = p_catalog
	battle.rules.register_rule("stats.damage", "action.damage", _damage, 10)
	battle.rules.register_rule("stats.block", "action.block", _block, 10)
	battle.rules.register_rule("stats.vulnerable", "action.damage", _vulnerable, 20)


func _damage(event: BattleEvent) -> void:
	var data := event.payload
	var bonus := 0
	if bool(data.get("use_stats", false)):
		bonus = _bonus(StringName(data.source_side), String(data.source_id), BuffEffectStat.Stat.ATTACK)
	data["base_amount"] = int(data.amount)
	data["amount"] = adjusted_amount(int(data.amount), bonus)


func _block(event: BattleEvent) -> void:
	var data := event.payload
	data["base_amount"] = int(data.amount)
	data["amount"] = adjusted_amount(int(data.amount), _bonus(StringName(data.side), String(data.target), BuffEffectStat.Stat.BLOCK))


func _vulnerable(event: BattleEvent) -> void:
	if int(event.payload.amount) <= 0 or bool(event.metadata.get("true_loss", false)):
		return
	var side := StringName(event.payload.side)
	var target := str(event.payload.target)
	for buff: Dictionary in battle.get_combatant(side, target).get("buffs", []):
		if str(buff.buff_id) == "vulnerable" and int(buff.layers) > 0:
			event.payload["amount"] = vulnerable_amount(int(event.payload.amount))
			battle.rules.publish("action.buff_set", {"side": String(side), "target": target,
				"buff_id": "vulnerable", "layers": int(buff.layers) - 1})
			return


func _bonus(side: StringName, id: String, stat: int) -> int:
	return stat_bonus(battle.get_combatant(side, id), catalog, stat)


## Shared pure arithmetic. Intent projection must never execute action rules.
static func adjusted_amount(base: int, bonus: int) -> int:
	return maxi(0, base + bonus)


static func vulnerable_amount(amount: int) -> int:
	return int(floor(amount * 1.5))


static func stat_bonus(combatant: Dictionary, definitions: Dictionary, stat: int) -> int:
	var result := 0
	for buff: Dictionary in combatant.get("buffs", []):
		var definition: BuffData = definitions.get(String(buff.buff_id))
		if definition == null:
			continue
		for effect: GameEffect in definition.effects:
			if effect is BuffEffectStat and effect.stat == stat:
				result += int(effect.get_effect_strength(buff))
	return result

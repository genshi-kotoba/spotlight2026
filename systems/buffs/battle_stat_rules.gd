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


func _damage(event: BattleEvent) -> void:
	var data := event.payload
	var bonus := 0
	if bool(data.get("use_stats", false)):
		bonus = _bonus(StringName(data.source_side), String(data.source_id), BuffEffectStat.Stat.ATTACK)
	data["base_amount"] = int(data.amount)
	data["amount"] = maxi(0, int(data.amount) + bonus)


func _block(event: BattleEvent) -> void:
	var data := event.payload
	data["base_amount"] = int(data.amount)
	data["amount"] = maxi(0, int(data.amount) + _bonus(StringName(data.side), String(data.target), BuffEffectStat.Stat.BLOCK))


func _bonus(side: StringName, id: String, stat: int) -> int:
	var result := 0
	for buff: Dictionary in battle.get_combatant(side, id).get("buffs", []):
		var definition: BuffData = catalog.get(String(buff.buff_id))
		if definition == null:
			continue
		for effect: GameEffect in definition.effects:
			if effect is BuffEffectStat and effect.stat == stat:
				result += int(effect.get_effect_strength(buff))
	return result

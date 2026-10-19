class_name BattleDirectPreview
extends RefCounted

## 只读的直接数值小计，不执行效果、不发布事件、不消费随机数。
## 指针、残片反应、条件数值及选牌交互不做预测，真实结算仍只走 main 队列。
static func calculate(battle: BattleStateMachine, cards: Array[Dictionary], catalog: Dictionary) -> Dictionary:
	var result := {"damage": 0, "block": 0}
	var attack_bonus := _layers(battle.player, "strength") - _layers(battle.player, "weak")
	var block_bonus := _layers(battle.player, "tenacity")
	for card: Dictionary in cards:
		if bool(card.get("slot_empty", false)):
			continue
		var data: CardData = catalog.get(str(card.get("card_id", "")))
		if data == null:
			continue
		var repeats := 2 if card.get("enchantments", []).has("repeat_2") else 1
		for effect: GameEffect in data.effects:
			var ops: Array = []
			if effect is CardEffectProgram:
				ops = effect.instructions
			elif effect is CardEffectAttack and effect.amount > 0:
				for index in effect.times:
					ops.append({"op": "damage", "amount": effect.amount})
			elif effect is CardEffectBlock and effect.receiver == CardEffectBlock.Receiver.SELF and effect.amount > 0:
				ops.append({"op": "block", "amount": effect.amount})
			_sum(ops, card, attack_bonus, block_bonus, repeats, result)
	return result


static func _sum(ops: Array, card: Dictionary, attack_bonus: int, block_bonus: int,
		repeats: int, result: Dictionary, depth: int = 0) -> void:
	if depth > 8:
		return
	for op: Dictionary in ops:
		if str(op.get("op", "")) == "repeat":
			var count: Variant = op.get("count", 0)
			if count is int or count is float:
				_sum(op.get("body", []), card, attack_bonus, block_bonus,
					repeats * clampi(int(count), 0, 100), result, depth + 1)
			continue
		var amount: Variant = op.get("amount", 0)
		if not (amount is int or amount is float):
			continue # 条件数值不能用零伪装成确定预测。
		match str(op.get("op", "")):
			"damage":
				var damage := maxi(0, int(amount) + attack_bonus)
				if card.get("enchantments", []).has("damage_50"):
					damage = int(floor(damage * 1.5))
				result.damage += damage * repeats
			"block":
				result.block += maxi(0, int(amount) + block_bonus) * repeats


static func _layers(owner: Dictionary, buff_id: String) -> int:
	for buff: Dictionary in owner.get("buffs", []):
		if str(buff.get("buff_id", "")) == buff_id:
			return int(buff.get("layers", 0))
	return 0

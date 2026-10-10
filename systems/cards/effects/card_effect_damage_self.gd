## 卡牌效果：对玩家自己造成伤害。
##
## 这是直接伤害，会被当前格挡抵消并消耗格挡；力量和虚弱只修正对外造成的伤害，
## 不会放大或降低自伤。

class_name CardEffectDamageSelf
extends CardEffect

@export_range(0, 999) var amount: int = 3


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectDamageSelf：缺少上下文")
		return
	if amount > 0:
		ctx.damage_player(amount)
	executed.emit(self, card)

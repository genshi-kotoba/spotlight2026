## 卡牌效果：恢复玩家生命值，不超过最大生命值。

class_name CardEffectHeal
extends CardEffect

@export_range(0, 999) var amount: int = 5


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectHeal：缺少上下文")
		return
	if amount > 0:
		ctx.heal_player(amount)
	executed.emit(self, card)

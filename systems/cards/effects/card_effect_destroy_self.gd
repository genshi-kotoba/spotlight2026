## 卡牌效果：使用后从战斗中移除
##
## 打出后这张牌从本场战斗消失（战斗结束回到牌组）。对应卡牌设计表里「使用后从本场
## 战斗中移除」那一类。
##
## 与「从本局移除」的分别见 CardZone.RemoveScope：那个用 CardEffectRemoveFromRun，
## 落点在 PRG-003 的牌组逻辑里，这里只留接口。

class_name CardEffectDestroySelf
extends CardEffect


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectDestroySelf：缺少上下文")
		return
	ctx.remove_from_battle(card)
	executed.emit(self, card)

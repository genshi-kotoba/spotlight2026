## 卡牌效果：让玩家从当前手牌中选择指定数量的牌弃置。
##
## 真实战斗会暂停在当前指针，直到界面调用 BattleStateMachine.submit_discard_choice。
## 事件队列保留剩余效果，因此可出现在 effects 数组任意位置，也可连续请求弃牌。

class_name CardEffectDiscardChoice
extends CardEffect

@export_range(0, 99) var count: int = 1


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectDiscardChoice：缺少上下文")
		return
	if count > 0:
		ctx.request_discard_choice(count)
	executed.emit(self, card)

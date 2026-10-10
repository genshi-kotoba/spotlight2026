## 卡牌效果：使出牌区中的后一张牌额外触发若干次。
##
## 默认 extra_triggers = 2，即后一张牌在正常触发一次后再额外触发两次，总计三次。
## 每次额外触发都计入 BattleStateMachine 的 256 次结算保护。

class_name CardEffectRepeatNext
extends CardEffect

@export_range(0, 99) var extra_triggers: int = 2


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectRepeatNext：缺少上下文")
		return
	if extra_triggers > 0:
		ctx.repeat_next_card(extra_triggers)
	executed.emit(self, card)

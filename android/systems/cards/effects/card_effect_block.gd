## 卡牌效果：获得格挡
##
## 默认给自己加格挡。格挡与 buff 不同，走 ctx.add_block 而不是加一条 buff。
## 它会优先抵消直接伤害并消耗，玩家剩余格挡在敌方回合结束时由状态机清零。

class_name CardEffectBlock
extends CardEffect

## 加给谁。玩家是默认，留出扩展位以便将来做「给队友加格挡」。
enum Receiver {
	SELF,
	CURRENT_TARGET,
}

@export_range(0, 999) var amount: int = 5

@export var receiver: Receiver = Receiver.SELF


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectBlock：缺少上下文")
		return
	if amount > 0:
		match receiver:
			Receiver.SELF:
				ctx.add_block(&"player", "player", amount)
			Receiver.CURRENT_TARGET:
				var target: Variant = ctx.current_target()
				if target == null:
					push_error("CardEffectBlock：指定了当前目标，但当前没有目标")
					return
				ctx.add_block(&"enemy", String(target), amount)
	executed.emit(self, card)

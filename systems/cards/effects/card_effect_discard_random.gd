## 卡牌效果：随机弃牌
##
## 从手牌里随机弃 count 张。抽哪几张由 ctx 的实现方决定——随机源必须走
## SeedService 的流，不能用全局 randi，否则一局不可复现。

class_name CardEffectDiscardRandom
extends CardEffect

@export_range(0, 99) var count: int = 1


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectDiscardRandom：缺少上下文")
		return
	if count > 0:
		ctx.discard_random(count)
	executed.emit(self, card)

## 卡牌效果：抽牌
##
## 抽多少张由 ctx 的实现方负责（含抽牌堆空时把弃牌堆洗回来）。效果层不管牌堆，
## 只发出「抽 N 张」这一个动作。

class_name CardEffectDraw
extends CardEffect

@export_range(0, 99) var 张数: int = 2


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectDraw：缺少上下文")
		return
	if 张数 > 0:
		ctx.draw(张数)
	executed.emit(self, card)

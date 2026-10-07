## 卡牌效果：获得格挡
##
## 默认给自己加格挡。格挡与 buff 不同，它不是层数也不会每回合衰减，所以走
## ctx.add_block 而不是加一条 buff。

class_name CardEffectBlock
extends CardEffect

## 加给谁。玩家是默认，留出扩展位以便将来做「给队友加格挡」。
enum 作用对象 {
	自己,
	当前目标,
}

@export_range(0, 999) var 数值: int = 5

@export var 施加给: 作用对象 = 作用对象.自己


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectBlock：缺少上下文")
		return
	if 数值 > 0:
		match 施加给:
			作用对象.自己:
				ctx.add_block(&"player", "player", 数值)
			作用对象.当前目标:
				var target: Variant = ctx.current_target()
				if target == null:
					push_error("CardEffectBlock：指定了当前目标，但当前没有目标")
					return
				ctx.add_block(&"enemy", String(target), 数值)
	executed.emit(self, card)

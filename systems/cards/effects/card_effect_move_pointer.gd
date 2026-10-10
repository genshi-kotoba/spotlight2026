## 卡牌效果：移动指针位置
##
## 指针移动会让已经结算过的牌再打一遍，这是本作的核心机制之一。
##
## 方向用枚举不用正负号：编辑器里是下拉加一个数字，不用猜 -2 是往左还是往右。
##
## LEFT 表示指针往回退（回到前面已结算的格子），RIGHT 表示往右跳。
## RIGHT 走绝对目标接口；每张移动牌在一段出牌序列中只允许成功改变一次指针，
## 即使指针回跳后再次遇到它也不会再次移动，从机制层避免无意义的永久回环。

class_name CardEffectMovePointer
extends CardEffect

@export var direction: CardZone.PointerDir = CardZone.PointerDir.LEFT

## 移动几格。非负。
@export_range(0, 99) var steps: int = 1


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectMovePointer：缺少上下文")
		return
	if steps > 0:
		match direction:
			CardZone.PointerDir.LEFT:
				ctx.rewind_pointer(steps)
			CardZone.PointerDir.RIGHT:
				ctx.move_pointer_to(ctx.pointer_index() + steps)
	executed.emit(self, card)


func _to_string() -> String:
	var arrow := "<-" if direction == CardZone.PointerDir.LEFT else "->"
	return "<%s %s%d>" % [get_class(), arrow, steps]

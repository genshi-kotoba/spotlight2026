## 卡牌效果：移动指针位置
##
## 指针移动会让已经结算过的牌再打一遍，这是本作的核心机制之一。
##
## 方向用枚举不用正负号：编辑器里是下拉加一个数字，不用猜 -2 是往左还是往右。
##
## 左 表示指针往回退（回到前面已结算的格子），右 表示往右跳。
## **右 目前做不到**：PRG-004 只有 request_pointer_rewind(格数)，只能往回。
## 本效果在 右 时走 ctx.move_pointer_to，这个方法在适配层里还是待实现状态。

class_name CardEffectMovePointer
extends CardEffect

@export var 方向: CardZone.方向 = CardZone.方向.左

## 移动几格。非负。
@export_range(0, 99) var 格数: int = 1


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectMovePointer：缺少上下文")
		return
	if 格数 > 0:
		match 方向:
			CardZone.方向.左:
				ctx.rewind_pointer(格数)
			CardZone.方向.右:
				ctx.move_pointer_to(ctx.pointer_index() + 格数)
	executed.emit(self, card)


func _to_string() -> String:
	var arrow := "<-" if 方向 == CardZone.方向.左 else "->"
	return "<%s %s%d>" % [get_class(), arrow, 格数]

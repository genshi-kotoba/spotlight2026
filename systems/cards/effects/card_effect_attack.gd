## 卡牌效果：造成伤害
##
## 对当前目标造成 times 次 amount 点伤害。没有目标时不做任何事并报错，不静默通过。

class_name CardEffectAttack
extends CardEffect

@export_range(0, 999) var amount: int = 5

## 重复次数。多次命中会分别结算，用于「造成 1 点伤害，重复四次」这类卡。
@export_range(1, 99) var times: int = 1


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectAttack：缺少上下文")
		return
	if amount <= 0 or times <= 0:
		# 参数为 0 或负数不动作，也不算错——策划可能把数值调到 0 做临时测试。
		executed.emit(self, card)
		return
	var target: Variant = ctx.current_target()
	if target == null:
		push_error("CardEffectAttack：当前没有目标，无法结算")
		return
	var enemy_id := String(target)
	for i in times:
		ctx.damage_enemy(enemy_id, amount)
	executed.emit(self, card)

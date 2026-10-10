## buff 效果：持续伤害（dot）
##
## 每回合按层数扣血。这是 dot 的通用形状，具体的层数变化规则留给子类——
## 「中毒」就是对本类的覆写，它的层数减半向上取整，1 层为特例归零。
##
## 扣血走 ctx.damage_*，ignore_block 由 damage_ignores_block 决定，默认绕过格挡：
## dot 与直接伤害区分开，是本模块自己定的默认值，见提示词文档 §3.8。策划确认后
## 改这个默认值即可，不用改结构。

class_name BuffEffectDot
extends BuffEffect

## 每层扣多少血。
@export_range(0, 999) var damage_per_layer: int = 1

## 是否绕过格挡。dot 默认绕过。
@export var damage_ignores_block: bool = true


## 每回合结算：先按层数造成伤害，再返回层数（默认不变）。
##
## 层数的变化规则由子类决定。本类保持层数不变，因为「dot 的层数怎么变」没有通用
## 答案——中毒是减半，别的 dot 可能是每回合减一或不变。
func on_turn_update(ctx: EffectContext, target: Variant, buff: Dictionary) -> int:
	if damage_per_layer > 0:
		_deal_damage(ctx, target, layers_of(buff) * damage_per_layer)
	return layers_of(buff)


## 把「对谁造成伤害」这件事收在一处，子类与将来的变体都走它。
func _deal_damage(ctx: EffectContext, target: Variant, amount: int) -> void:
	if amount <= 0:
		return
	if target == null:
		push_error("%s：目标为空，无法结算持续伤害" % get_class())
		return
	var entity_id := String(target)
	if entity_id == "player":
		ctx.damage_player(amount, damage_ignores_block)
	else:
		ctx.damage_enemy(entity_id, amount, damage_ignores_block)


func _to_string() -> String:
	return "<%s %s %d/层>" % [get_class(), buff_id, damage_per_layer]

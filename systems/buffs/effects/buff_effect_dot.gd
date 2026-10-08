## buff 效果：持续伤害（dot）
##
## 每回合按层数扣血。这是 dot 的通用形状，具体的层数变化规则留给子类——
## 「中毒」就是对本类的覆写，它的层数减半向上取整，1 层为特例归零。
##
## 扣血走 ctx.damage_*，ignore_block 由无视格挡决定，默认绕过格挡：这是把 dot 与直接
## 伤害区分开，属于本模块自己定的默认值。策划确认后改这个默认值即可，不用改结构。

class_name BuffEffectDot
extends BuffEffect

## 每层扣多少血。
@export_range(0, 999) var 每层伤害: int = 1

## 是否绕过格挡。dot 默认绕过。
@export var 无视格挡: bool = true


## 每回合结算：先按层数造成伤害，再返回层数（默认不变）。
##
## 层数的变化规则由子类决定。本类保持层数不变，因为「dot 的层数怎么变」没有通用
## 答案——中毒是减半，别的 dot 可能是每回合减一或不变。
func on_turn_update(ctx: EffectContext, target: Variant, buff: Dictionary) -> int:
	# 每层伤害为 0 时不必在这里挡：「0 就不动作」的规则由 _deal_damage 一处负责。
	_deal_damage(ctx, target, layers_of(buff) * 每层伤害)
	return layers_of(buff)


## 把「对谁造成伤害」这件事收在一处，子类与将来的变体都走它。
## 「伤害为 0 或负数就不动作」这条规则只写在这里，调用方不用重复判断。
func _deal_damage(ctx: EffectContext, target: Variant, 数值: int) -> void:
	if 数值 <= 0:
		return
	if target == null:
		push_error("%s：目标为空，无法结算持续伤害" % get_class())
		return
	var entity_id := String(target)
	if entity_id == "player":
		ctx.damage_player(数值, 无视格挡)
	else:
		ctx.damage_enemy(entity_id, 数值, 无视格挡)


func _to_string() -> String:
	return "<%s %s %d/层>" % [get_class(), buff标识, 每层伤害]

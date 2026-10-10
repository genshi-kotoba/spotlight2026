## buff 效果：数值增减
##
## 按层数影响伤害或格挡。策划案 2.5 定义的三条都落在这个类上：
##
##   力量   每层使伤害加 1     stat = ATTACK,  amount_per_layer = +1
##   虚弱   每层使伤害减 1     stat = ATTACK,  amount_per_layer = -1
##   坚韧   每层使格挡值加 1   stat = BLOCK,   amount_per_layer = +1
##
## 三条的**层数都不随回合变化**，这与策划案一致（2.5 只写了每层效果，没写衰减）。
## 限时与否靠 buff 字典的 duration，不靠层数。所以本类不覆写 on_turn_update。
##
## 换算结果是「相对基准的增减量」，不是最终伤害。谁去应用这个增减量由伤害结算那一侧
## 决定——本模块只负责把层数换算成一个数值。

class_name BuffEffectStat
extends BuffEffect

## 影响哪一项数值。新增一项加一个枚举值，已有 buff 不受影响。
enum Stat {
	ATTACK,
	BLOCK,
}

@export var stat: Stat = Stat.ATTACK

## 每层增减多少。正数为增益，负数为减益。
@export_range(-99, 99) var amount_per_layer: int = 1


func get_effect_strength(buff: Dictionary) -> float:
	return float(layers_of(buff) * amount_per_layer)


func _to_string() -> String:
	return "<%s %s %+d/层>" % [get_class(), buff_id, amount_per_layer]

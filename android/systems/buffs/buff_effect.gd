## buff 效果基类
##
## PRG-008 要求 buff 含三要素：层数、持续回合数、效果。三要素分别落在：
##
##   层数        存在 buff 字典的 "layers" 里，由 on_turn_update 决定怎么变
##   持续回合数   存在 buff 字典的 "duration" 里，由 tick_duration 决定怎么减
##   效果        子类的 @export 参数与上述钩子的覆写
##
## 为什么拆成几个独立钩子，而不是一条固定流程：不同 buff 的结算方式差别很大，
## 一套流程塞不下。三条已定的 buff 就能看出差别——
##
##   力量 / 坚韧 / 虚弱   层数不变，限时靠 duration
##   中毒               层数减半向上取整，1 层时归零
##
## 所以四个钩子各自独立，子类可以只覆写一个而不影响其他方面。基类只给默认实现，
## 不假设统一的结算流程。
##
## 字段约束来自 PRG-004 的 _valid_buff()，不是本类的设计选择：buff_id 非空字符串，
## layers 与 duration 都是大于等于 0 的整数，整体可 JSON 序列化。
##
## duration 的语义（本模块自己约定，因为状态机只要求非负、不定义含义）：
##
##   duration == 0   不限回合。tick_duration 对它不做任何事，永不因回合数被移除
##   duration > 0    剩余回合数。每回合由 tick_duration 减一，减到 0 即到期
##
## 所以 duration 是 0 只有两种来路：一开始就是不限回合，或者限时的走到了 0。
## 后者在减到 0 的那个回合就被移除了，因此 is_expired 看到 duration 为 0 时
## 不需要（也无法）区分来路——层数归零才是唯一可靠的到期信号。
##
## 调用方每回合的顺序应是：
##   1. on_turn_update(ctx, target, buff)   → 取回新层数并写回
##   2. tick_duration(buff)                 → 限时的减一
##   3. is_expired(buff)                    → 到期则 end 并移除
##
## 本类不自带 duration 字段。buff 实例是纯字典，活在状态机的 player["buffs"] 与
## enemies[i]["buffs"] 里；本类是挂在 BuffData 上的行为描述。

class_name BuffEffect
extends GameEffect

## 施加完成后释放。
signal applied(target: Variant, layers: int)

## 层数变化后释放。
signal stacks_changed(target: Variant, from_layers: int, to_layers: int)

## 结束（层数归零、回合数耗尽、或被主动清除）后释放。
signal ended(target: Variant)

## 本效果处理的 buff 标识。同 id 的 buff 在同一个目标身上只有一条。
@export var buff_id: StringName = &""

@export var display_name: String = ""


## 施加时的行为。默认只释放信号。
## 子类覆写时先做自己的事，最后调 super 释放信号。
func apply(_ctx: EffectContext, target: Variant, buff: Dictionary) -> void:
	applied.emit(target, layers_of(buff))


## 每回合结算，返回新的层数。
##
## 默认原样返回当前层数，即「层数不变」。三条已定的 buff（力量、坚韧、虚弱）都
## 走这个默认。要让层数衰减的子类覆写本方法。
##
## 本方法只负责算新层数，不负责写回；写回与移除由调用方做，因为调用方持有
## buffs 数组。
func on_turn_update(_ctx: EffectContext, _target: Variant, buff: Dictionary) -> int:
	return layers_of(buff)


## 持续回合数的递减。默认限时的减一，不限回合的原样不动。
## 不受回合限制的 buff 覆写成空实现即可。
func tick_duration(buff: Dictionary) -> void:
	var duration := duration_of(buff)
	if duration > 0:
		buff["duration"] = duration - 1


## 是否已到寿命尽头。默认只看层数：归零即到期。
##
## 回合数的处理见本文件开头的顺序说明——限时的由 tick_duration 减到 0，调用方在
## 同一回合就移除它了，不会留到 is_expired 来判。
##
## 注意本方法对多数 buff 成立；特殊 buff 若层数永不归零，就必须覆写本方法，
## 否则它永远不会自然结束。中毒已在 1 层时归零，因此可直接使用默认实现。
func is_expired(buff: Dictionary) -> bool:
	return layers_of(buff) <= 0


## 结束时的行为。默认只释放信号。
## 子类覆写时先清掉自己造成的影响，最后调 super。
func end(_ctx: EffectContext, target: Variant, _buff: Dictionary) -> void:
	ended.emit(target)


## 层数换算成强度。强度含义由子类定：伤害加成、格挡加成、每回合扣血数。
## 默认一层算一点。
func get_effect_strength(buff: Dictionary) -> float:
	return float(layers_of(buff))


# ---------------------------------------------------------------- 字典读写

## 读层数。缺字段或非法值按 0 处理，不抛错——非法数据由状态机那一侧拦。
static func layers_of(buff: Dictionary) -> int:
	var value: Variant = buff.get("layers")
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return 0
	return maxi(0, int(value))


## 读持续回合数。0 表示不限回合。
static func duration_of(buff: Dictionary) -> int:
	var value: Variant = buff.get("duration")
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return 0
	return maxi(0, int(value))


## 写层数。负数夹到 0。
static func set_layers(buff: Dictionary, layers: int) -> void:
	buff["layers"] = maxi(0, layers)


func _to_string() -> String:
	return "<%s %s %s>" % [get_class(), buff_id, _script_path()]

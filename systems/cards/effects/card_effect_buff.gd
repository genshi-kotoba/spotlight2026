## 卡牌效果：加 buff 层数
##
## 卡牌挂这个效果就是「给某人叠 N 层某种 buff」。buff 效果本身是另一套
## （BuffEffect 的子类），那套负责这个 buff 每回合怎么结算。
##
## 这里只负责「加」，且必须走 ctx.add_buff —— 由实现方按 buff标识合并同名，
## 不能直接往 buffs 数组里追加一条。PRG-004 的结算是「数组里有几条就发几次请求」，
## 不合并的话，分两次加的中毒会变成数组里两条，每回合扣两次血。
##
## 本效果没有「持续几回合」这个参数：buff 的初始时长取自 BuffData.持续回合。
## 如果以后要让某张卡自己指定时长，得先给 EffectContext.add_buff 加参数，
## 那是与 PRG-004 的接口变更，先说好再做。

class_name CardEffectBuff
extends CardEffect

## 施加给谁。
enum 作用对象 {
	自己,
	当前目标,
	所有敌人,
}

## 目标身上哪个 buff。与 systems/buffs/effects/ 下的 BuffEffect 子类的 buff标识对应。
@export var buff标识: StringName = &"strength"

## 叠几层。负数表示减层数。
@export_range(-99, 99) var 层数: int = 1

@export var 施加给: 作用对象 = 作用对象.自己


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectBuff：缺少上下文")
		return
	if 层数 != 0:
		match 施加给:
			作用对象.自己:
				ctx.add_buff(&"player", "player", buff标识, 层数)
			作用对象.当前目标:
				var target: Variant = ctx.current_target()
				if target == null:
					push_error("CardEffectBuff：指定了当前目标，但当前没有目标")
					return
				ctx.add_buff(&"enemy", String(target), buff标识, 层数)
			作用对象.所有敌人:
				for enemy_id in ctx.enemy_ids():
					ctx.add_buff(&"enemy", enemy_id, buff标识, 层数)
	executed.emit(self, card)


func _to_string() -> String:
	return "<%s %s %+d>" % [get_class(), buff标识, 层数]

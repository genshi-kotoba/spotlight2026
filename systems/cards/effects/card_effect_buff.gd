## 卡牌效果：加 buff 层数
##
## 卡牌挂这个效果就是「给某人叠 N 层某种 buff」。buff 效果本身是另一套
## （BuffEffect 的子类），那套负责这个 buff 每回合怎么结算。
##
## 这里只负责「加」，且必须走 ctx.add_buff —— 由实现方按 buff_id 合并同名，
## 不能直接往 buffs 数组里追加一条。不合并的后果见提示词文档 §3.4.6：
## 分两次加的中毒会变成数组里两条，每回合扣两次血。

class_name CardEffectBuff
extends CardEffect

## 施加给谁。
enum Receiver {
	SELF,
	CURRENT_TARGET,
	ALL_ENEMIES,
}

## 目标身上哪个 buff。与 systems/buffs/effects/ 下的 BuffEffect 子类的 buff_id 对应。
@export var buff_id: StringName = &"strength"

## 叠几层。负数表示减层数。
@export_range(-99, 99) var layers: int = 1

@export var receiver: Receiver = Receiver.SELF

## 持续回合数。0 表示不限回合。状态机要求非负。
@export_range(0, 999) var duration: int = 0


func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectBuff：缺少上下文")
		return
	if layers != 0:
		match receiver:
			Receiver.SELF:
				ctx.add_buff(&"player", "player", buff_id, layers)
				if duration > 0:
					ctx.override_buff_duration(&"player", "player", buff_id, duration)
			Receiver.CURRENT_TARGET:
				var target: Variant = ctx.current_target()
				if target == null:
					push_error("CardEffectBuff：指定了当前目标，但当前没有目标")
					return
				ctx.add_buff(&"enemy", String(target), buff_id, layers)
				if duration > 0:
					ctx.override_buff_duration(&"enemy", String(target), buff_id, duration)
			Receiver.ALL_ENEMIES:
				for enemy_id in ctx.enemy_ids():
					ctx.add_buff(&"enemy", enemy_id, buff_id, layers)
					if duration > 0:
						ctx.override_buff_duration(&"enemy", enemy_id, buff_id, duration)
	executed.emit(self, card)


func _to_string() -> String:
	return "<%s %s %+d>" % [get_class(), buff_id, layers]

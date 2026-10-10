## 效果与外界的唯一通道
##
## 卡牌效果要造成伤害、加格挡、抽牌，而这些状态归 PRG-004 战斗状态机。效果不直接
## 引用状态机（那样会把效果层与状态机绑死，状态机编译不过时效果层也编译不过），
## 而是认这个抽象接口。状态机那一侧写一个适配层来实现它。
##
## 默认实现全部 push_error 并返回安全默认值，是为了让「忘了实现某个方法」在自测里
## 立刻暴露，而不是静默什么都不做。
##
## 实现方有两类：
##   - 真实战斗适配层 systems/cards/battle_effect_context.gd
##   - 自测用的假上下文 tests/test_effects/fake_effect_context.gd
##
## 参数约定：
##   - target / enemy_id 用字符串的敌人 id；玩家用 &"player" 与 "player"
##   - side 用 &"player" 或 &"enemy"
##   - buff_id 用 &"strength" / &"weak" / &"poison" 这类稳定标识
##   - 位置索引从 0 起；index 为 -1 表示追加到末尾

class_name EffectContext
extends RefCounted


# ---------------------------------------------------------------- 读

## 当前攻击目标。没有目标时返回 null。
func current_target() -> Variant:
	return null


## 全部存活敌人的 id。
func enemy_ids() -> Array[String]:
	return []


func player_health() -> int:
	return 0


func player_block() -> int:
	return 0


## 目标身上某个 buff 的当前层数。没有该 buff 时返回 0。
func buff_layers(_target: Variant, _buff_id: StringName) -> int:
	return 0


func hand() -> Array[Dictionary]:
	return []


func play_zone() -> Array[Dictionary]:
	return []


func draw_pile_size() -> int:
	return 0


func discard_pile() -> Array[Dictionary]:
	return []


func pointer_index() -> int:
	return 0


# ---------------------------------------------------------------- 改：战斗数值

## 对单个敌人造成伤害。ignore_block 为 true 时绕过格挡直接扣血，用于 dot 这类
## 持续伤害——毒不该被格挡吃掉。
func damage_enemy(_enemy_id: String, _amount: int, _ignore_block: bool = false) -> void:
	_unimplemented("damage_enemy")


func damage_all_enemies(_amount: int, _ignore_block: bool = false) -> void:
	_unimplemented("damage_all_enemies")


## ignore_block 为 true 时绕过格挡直接扣血，用于 dot 这类持续伤害。
func damage_player(_amount: int, _ignore_block: bool = false) -> void:
	_unimplemented("damage_player")


## 敌人等明确来源对玩家造成伤害；来源身上的力量/虚弱会修正伤害。
func damage_player_from(_source_id: String, _amount: int,
		_ignore_block: bool = false) -> void:
	_unimplemented("damage_player_from")


func heal_player(_amount: int) -> void:
	_unimplemented("heal_player")


func add_block(_side: StringName, _entity_id: String, _amount: int) -> void:
	_unimplemented("add_block")


# ---------------------------------------------------------------- 改：buff 与状态

## 加 buff。实现方必须先按 buff_id 找同名合并层数，不能直接追加一条新的。
## 理由见提示词文档 §3.4.6：PRG-004 的结算是「数组里有几条就发几次请求」，
## 不合并会让分两次加的中毒扣两次血。
func add_buff(_side: StringName, _entity_id: String, _buff_id: StringName, _layers: int) -> void:
	_unimplemented("add_buff")


## 直接设定层数，不做累加。层数设为 0 表示移除该条。
func set_buff_layers(_side: StringName, _entity_id: String, _buff_id: StringName, _layers: int) -> void:
	_unimplemented("set_buff_layers")


## 覆写现有 buff 的剩余回合数；0 表示不限回合。
func override_buff_duration(_side: StringName, _entity_id: String, _buff_id: StringName,
		_duration: int) -> void:
	_unimplemented("override_buff_duration")


## 立即结算一次中毒（不是等回合钩子）。对应「立即结算一次中毒效果」这类卡。
func tick_poison(_target: Variant) -> void:
	_unimplemented("tick_poison")


# ---------------------------------------------------------------- 改：牌

func draw(_count: int) -> void:
	_unimplemented("draw")


func discard_from_hand(_instance_id: String, _reason: StringName = &"effect") -> void:
	_unimplemented("discard_from_hand")


## 随机弃若干张。随机源由实现方走 SeedService 的流，不用全局 randi。
func discard_random(_count: int) -> void:
	_unimplemented("discard_random")


## 请求界面让玩家选择指定数量手牌。真实上下文会暂停指针，直到界面提交选择。
func request_discard_choice(_count: int) -> void:
	_unimplemented("request_discard_choice")


func is_waiting_for_input() -> bool:
	return false


## 造一张牌放进指定区，返回新牌的 instance_id。index 为 -1 表示追加末尾。
## 实现方必须给每张牌分配不同的 instance_id，同名卡也不例外：PRG-004 的读档校验
## 会拒绝跨牌区重复的实例 id。
func add_card_to_zone(_card_id: String, _zone: StringName, _index: int = -1) -> String:
	_unimplemented("add_card_to_zone")
	return ""


func move_card_in_play_zone(_from_index: int, _to_index: int) -> void:
	_unimplemented("move_card_in_play_zone")


## 本场战斗内移除（战斗结束后回来）。
func remove_from_battle(_card: Dictionary) -> void:
	_unimplemented("remove_from_battle")


## 本局内移除（余下的战斗都不再出现）。落点属 PRG-003，先留接口。
func remove_from_run(_card: Dictionary) -> void:
	_unimplemented("remove_from_run")


func change_target(_instance_id: String, _target: Variant) -> void:
	_unimplemented("change_target")


## 给某张牌附加一个效果。
func attach_effect(_card: Dictionary, _effect: GameEffect) -> void:
	_unimplemented("attach_effect")


# ---------------------------------------------------------------- 指针

## 指针往回退 steps 格。steps 必须为正。这是 PRG-004 现有的唯一指针能力。
func rewind_pointer(_steps: int) -> void:
	_unimplemented("rewind_pointer")


## 指针跳到指定位置；等于出牌区长度表示结束本次序列。
func move_pointer_to(_index: int) -> void:
	_unimplemented("move_pointer_to")


## 令当前牌之后的一张牌额外触发指定次数。
func repeat_next_card(_extra_triggers: int) -> void:
	_unimplemented("repeat_next_card")


# ----------------------------------------------------------------

func _unimplemented(method: String) -> void:
	push_error("EffectContext.%s 未实现：%s" % [method, get_class()])

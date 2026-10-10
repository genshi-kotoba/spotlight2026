## buff 效果：中毒
##
## 规则（口述确认，2026-10-05 与 2026-10-06 两次，策划案中无文字）：
##
##   结算完牌之后，扣除对方等于当前中毒层数的生命，然后中毒层数减半、向上取整。
##   层数为 1 时是例外——下回合直接归零移除。
##
## 推演（「之后」指本次结算后的层数）：
##
##   结算前 1 层 → 扣 1，之后 0 层，该条移除
##   结算前 2 层 → 扣 2，之后 1 层
##   结算前 3 层 → 扣 3，之后 2 层
##   结算前 4 层 → 扣 4，之后 2 层
##   结算前 5 层 → 扣 5，之后 3 层
##
## 那个例外是必要的：ceil(1 / 2) 等于 1，不减这个特例的话 1 层中毒永远留着，
## 而它每回合还在扣血，于是变成一条永不结束的持续伤害。
##
## 因为层数会走到 0，本类**不需要**覆写 is_expired——基类默认的「层数归零即到期」
## 正好是想要的行为。
##
## 中毒不受回合数限制，所以 tick_duration 覆写成空实现。

class_name BuffEffectPoison
extends BuffEffectDot


## 中毒绕过格挡。基类的默认值可能被改，这里在构造时钉死，避免子类的行为随基类漂移。
func _init() -> void:
	damage_ignores_block = true


func on_turn_update(ctx: EffectContext, target: Variant, buff: Dictionary) -> int:
	var current := layers_of(buff)
	# 先扣血，再改层数。顺序不能反：扣的血量按结算前的层数算。
	if damage_per_layer > 0:
		_deal_damage(ctx, target, current * damage_per_layer)
	return next_layers(current)


## 持续回合数不减。中毒只看层数。
func tick_duration(_buff: Dictionary) -> void:
	pass


## 结算后的新层数。减半向上取整，1 层为特例直接归零。
##
## 静态方法，便于自测直接验算。
static func next_layers(layers: int) -> int:
	if layers <= 1:
		# 0 层本来就没了；1 层是那个例外，下回合归零。
		return 0
	return int(ceil(float(layers) / 2.0))


func _to_string() -> String:
	return "<%s %s %d/层>" % [get_class(), buff_id, damage_per_layer]

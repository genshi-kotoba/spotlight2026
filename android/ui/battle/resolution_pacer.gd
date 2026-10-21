class_name ResolutionPacer
extends RefCounted

## 结算节拍器：只做记账与给倍速，不碰任何业务状态，由战斗场景持有。
##
## 基准是一张牌约 1 秒。提速只由两件事推动：指针跳过的格数超过阈值，以及整串结算
## 花掉的名义时长逼近总预算。名义时长由调用方按「这张牌本该等多久」记账，不读真实
## 时钟，因此「10 张牌 ≈ 10 秒」可以直接断言，也不受顿帧压低 time_scale 的干扰。

## 名义时长的下限：提速提到底也要留一点，避免结算被压成瞬移看不清。
const MIN_WAIT := 0.02

var budget := 10.0
## 指针跳过这么多格之后才开始提速；一手 10 张正好是 10 格。
var speedup_after_hops := 10
var max_speed := 2.2
## 预算用尽后的应急倍速：连锁再长也在这附近收住，不让结算无限拖。
var emergency_speed := 6.0
## 预算超出这么多成，应急倍速就拉满。
var emergency_share := 0.5
## 典籍引发的续接额外让一档，反复结算的部分本来就只需要「看见」。
var relic_bias := 0.2

var _hops := 0
var _spent := 0.0


## 每串结算开始时清零，跨串不继承上一串的加速。
func begin() -> void:
	_hops = 0
	_spent = 0.0


## 指针移动一格记一次。结算里每张牌会让指针前进一格。
func note_pointer_hop() -> void:
	_hops += 1


func hops() -> int:
	return _hops


func spent() -> float:
	return _spent


func remaining() -> float:
	return maxf(budget - _spent, 0.0)


func spend(nominal: float) -> void:
	_spent += nominal


## 当前该用几倍速等下一次结算。from_relic 指这一段是典籍续接出来的。
func speed(from_relic := false) -> float:
	if budget > 0.0 and _spent >= budget:
		var overrun := clampf((_spent - budget) / maxf(budget * emergency_share, 0.1), 0.0, 1.0)
		return lerpf(max_speed, emergency_speed, overrun)
	var pressure := maxf(_hop_pressure(), _budget_pressure())
	if from_relic:
		pressure += relic_bias
	return lerpf(1.0, max_speed, clampf(pressure, 0.0, 1.0))


## 把名义时长换算成实际要等的秒数，倍速与下限都在这里收口。
func wait_for(nominal: float, from_relic := false) -> float:
	return maxf(nominal / speed(from_relic), MIN_WAIT)


func _hop_pressure() -> float:
	if speedup_after_hops <= 0:
		return 1.0
	return clampf(float(_hops - speedup_after_hops) / float(speedup_after_hops), 0.0, 1.0)


func _budget_pressure() -> float:
	if budget <= 0.0:
		return 1.0
	var ratio := _spent / budget
	# 平方：预算前段几乎不提速，越接近上限压得越紧，避免早早牺牲观感。
	return ratio * ratio

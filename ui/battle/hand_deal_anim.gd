extends Node
## 抽牌进手的飞入动画，纯表现。
## 参数取自《驳回！》web/src/main.js 的 dealIn()：牌从抽牌堆中心出发，
## 起始 45% 大小、偏 14 度、全透明，飞到自己手上；多张按固定间隔依次出发。
## 只动槽位自身的 position / rotation / scale / modulate，不碰布局与规则。

const DURATION := 0.40
## 相邻两张的出发间隔。手牌是五张一起抽的，所以最后一张比第一张晚 0.24 秒。
const STAGGER := 0.06
const START_SCALE := 0.45
## -14 度。
const START_ROTATION := -0.244


static func play(slot: Control, pile_center: Vector2, index: int) -> void:
	if slot == null or not slot.is_inside_tree():
		return
	var final_position := slot.position
	var final_rotation := slot.rotation
	# 落点就是布局已经摆好的位置，飞行只是把起始姿态搬到抽牌堆。
	# 手牌轴心在底边中点，缩放时视觉中心会跟着挪，起始位置按起始缩放反算，让中心对准堆。
	var start_position := pile_center - Vector2(slot.size.x * 0.5,
		slot.size.y * (1.0 - START_SCALE * 0.5))
	slot.position = start_position
	slot.rotation = START_ROTATION
	slot.scale = Vector2.ONE * START_SCALE
	slot.modulate.a = 0.0
	var delay := index * STAGGER
	var tween := slot.create_tween()
	tween.set_parallel(true)
	# Godot 没有 cubic-bezier，《驳回！》那条(.2,1.15,.4,1)的回弹很小：
	# 位移与旋转走平滑收尾，只有缩放带一点过冲，读起来是"牌落进手里"。
	tween.tween_property(slot, "position", final_position, DURATION) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(slot, "rotation", final_rotation, DURATION) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(slot, "scale", Vector2.ONE, DURATION) \
		.set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(slot, "modulate:a", 1.0, DURATION) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

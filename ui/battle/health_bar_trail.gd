class_name HealthBarTrail
# 类名与父类都走路径写：无头跑测试不经过编辑器扫描，用不了全局类缓存。
extends "res://ui/battle/health_fill.gd"

## 血条残影：掉血时留在正条背后的一条滞后白条。
##
## 正条先往新长度滑，它留在原地不动，等正条滑完再慢一拍追上去。这段时间里露在正条
## 之外的那截白色，就是「这一下降了多少」——数字和补间都一闪而过，只有这截滞后能把
## 掉的量留在眼睛里。
## 回血不滞后，直接跟上：残影是给损失看的，不是给恢复看的。

const SCRIPT_PATH := "res://ui/battle/health_bar_trail.gd"
const TRAIL_COLOR := Color(1.0, 1.0, 1.0, 0.72)
## 追上那一段比正条自己滑的那一段短一点，收尾更利落。
const CATCH_UP_TIME := 0.26

var _lag: Tween
## 上一次的目标长度。同目标重复刷新不能重启滞后，否则每次重绘都把追赶推后一拍。
var _target := -1.0


## 在正条背后挂一条残影；已经挂过就返回那一条。
static func ensure_on(bar: Control) -> Control:
	if bar == null or not bar.is_inside_tree():
		return null
	var existing: Variant = bar.get_meta("trail") if bar.has_meta("trail") else null
	if existing != null and is_instance_valid(existing):
		return existing
	var parent := bar.get_parent()
	if parent == null:
		return null
	var trail: Control = load(SCRIPT_PATH).new()
	trail.name = "Trail"
	trail.fill_color = TRAIL_COLOR
	trail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trail.slant = float(bar.get("slant")) if bar.get("slant") != null else 0.0
	parent.add_child(trail)
	# 插在正条前面：同一层里排在它之前才会画在它下面，掉血时那截白才露得出来。
	parent.move_child(trail, bar.get_index())
	bar.set_meta("trail", trail)
	return trail


## 跟住正条：尺寸照抄，长度按掉血 / 回血分开处理。
func sync_from(bar: Control, target: float, drain_time: float) -> void:
	offset_left = bar.offset_left
	offset_right = bar.offset_right
	offset_top = bar.offset_top
	offset_bottom = bar.offset_bottom
	if _target >= 0.0 and is_equal_approx(target, _target):
		return
	var previous := _target
	_target = target
	if previous < 0.0 or target > previous:
		# 首次定位和回血都直接跟上，不留痕。
		_clear_lag()
		ratio = target
		return
	_clear_lag()
	_lag = create_tween()
	_lag.tween_interval(drain_time)
	_lag.tween_property(self, "ratio", target, CATCH_UP_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _clear_lag() -> void:
	if _lag != null and _lag.is_valid():
		_lag.kill()
	_lag = null

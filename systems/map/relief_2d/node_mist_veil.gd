extends Node2D
## 节点底座雾圈：战斗沿用红色，事件、商店、宝箱、残堆共用同形状的金色方案。
## 底座坐标直接取渲染层 node_marker face 的显示空间 bounds，与节点交互提示同一套锚点口径。

const RING_COUNT := 4
const DRIFT_COUNT := 2
const BASE_COLOR := Color(0.78, 0.16, 0.13)
const DRIFT_COLOR := Color(0.66, 0.12, 0.11)
const GOLD_BASE_COLOR := Color(0.91, 0.69, 0.24)
const GOLD_DRIFT_COLOR := Color(0.82, 0.53, 0.15)

var _bases: Array = []
var _signature := ""
var _phase := 0.0

func _init() -> void:
	z_index = 6
	visible = false
	set_process(false)

## bases 每项含 center、width、phase、palette（默认 red），全在显示空间。
## 调用方可以每 tick 收集一次；这里按签名短路，没变化就不重建。
func set_bases(bases: Array) -> void:
	var signature := _build_signature(bases)
	if signature == _signature:
		return
	_signature = signature
	_bases = bases.duplicate()
	visible = not _bases.is_empty()
	set_process(visible)
	queue_redraw()

func _process(delta: float) -> void:
	_phase += delta
	queue_redraw()

func _build_signature(bases: Array) -> String:
	var parts := PackedStringArray()
	for base in bases:
		parts.append("%s@%.1f:%s" % [str(base["center"]), float(base["width"]), str(base.get("palette", "red"))])
	return "|".join(parts)

func _draw() -> void:
	for base in _bases:
		var width: float = float(base["width"])
		if width <= 0.0:
			continue
		var stage: float = float(base["phase"])
		var gold: bool = base.get("palette", "red") == "gold"
		var base_color: Color = GOLD_BASE_COLOR if gold else BASE_COLOR
		var drift_color: Color = GOLD_DRIFT_COLOR if gold else DRIFT_COLOR
		var breathe := 0.5 + 0.5 * sin(_phase * 0.9 + stage)
		draw_set_transform(base["center"], 0.0, Vector2(1.0, 0.6))
		for ring in RING_COUNT:
			var radius := width * 0.46 * (0.86 + 0.14 * breathe) * (1.0 - 0.19 * ring)
			var alpha := (0.13 + 0.07 * breathe) * (1.0 - 0.18 * ring)
			draw_circle(Vector2.ZERO, radius, Color(base_color.r, base_color.g, base_color.b, alpha))
		for drift in DRIFT_COUNT:
			var angle := _phase * 0.5 + TAU * float(drift) / float(DRIFT_COUNT) + stage
			draw_circle(Vector2.from_angle(angle) * width * 0.26, width * 0.19,
				Color(drift_color.r, drift_color.g, drift_color.b, 0.08 + 0.045 * breathe))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

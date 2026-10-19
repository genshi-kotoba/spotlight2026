extends Node2D
## 怪物节点底座红雾：未完成的战斗、精英、首领节点在底座叠一层缓慢流动的红雾。
## 底座坐标直接取渲染层 node_marker face 的显示空间 bounds，与节点交互提示同一套锚点口径。

const RING_COUNT := 4
const DRIFT_COUNT := 2
const BASE_COLOR := Color(0.78, 0.16, 0.13)
const DRIFT_COLOR := Color(0.66, 0.12, 0.11)

var _bases: Array = []
var _signature := ""
var _phase := 0.0

func _init() -> void:
	z_index = 6
	visible = false
	set_process(false)

## bases 每项是 {"center": Vector2, "width": float, "phase": float}，全在显示空间。
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
		parts.append("%s@%.1f" % [str(base["center"]), float(base["width"])])
	return "|".join(parts)

func _draw() -> void:
	for base in _bases:
		var width: float = float(base["width"])
		if width <= 0.0:
			continue
		var stage: float = float(base["phase"])
		var breathe := 0.5 + 0.5 * sin(_phase * 0.9 + stage)
		draw_set_transform(base["center"], 0.0, Vector2(1.0, 0.6))
		for ring in RING_COUNT:
			var radius := width * 0.46 * (0.86 + 0.14 * breathe) * (1.0 - 0.19 * ring)
			var alpha := (0.13 + 0.07 * breathe) * (1.0 - 0.18 * ring)
			draw_circle(Vector2.ZERO, radius, Color(BASE_COLOR.r, BASE_COLOR.g, BASE_COLOR.b, alpha))
		for drift in DRIFT_COUNT:
			var angle := _phase * 0.5 + TAU * float(drift) / float(DRIFT_COUNT) + stage
			draw_circle(Vector2.from_angle(angle) * width * 0.26, width * 0.19,
				Color(DRIFT_COLOR.r, DRIFT_COLOR.g, DRIFT_COLOR.b, 0.08 + 0.045 * breathe))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

extends Control
## 仅表现层的飞牌。目标每帧读取，支持抽牌落入扇形，以及出牌列重建、插牌和滚动。
signal completed

const SHRINK_TIME := 0.07
const FLIGHT_TIME := 0.18
const LAND_TIME := 0.09
const DURATION := SHRINK_TIME + FLIGHT_TIME + LAND_TIME
const TRAVEL_SCALE := 0.09

var destination: Callable
var disappearing := false
var _start_center := Vector2.ZERO
var _flight: Tween


func start(source_transform: Transform2D, target: Callable, discard: bool) -> void:
	destination = target
	disappearing = discard
	size = Vector2(480, 818)
	pivot_offset = size * 0.5
	_start_center = source_transform * pivot_offset
	position = _start_center - pivot_offset
	rotation = source_transform.get_rotation()
	scale = source_transform.get_scale()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 200
	_flight = create_tween()
	_flight.set_parallel(true)
	_flight.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_flight.tween_property(self, "scale", Vector2.ONE * TRAVEL_SCALE, SHRINK_TIME)
	_flight.tween_property(self, "rotation", 0.0, SHRINK_TIME)
	_flight.chain().tween_method(_move, 0.0, 1.0, FLIGHT_TIME) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_flight.chain().tween_method(_land, 0.0, 1.0, LAND_TIME)
	_flight.chain().tween_callback(func(): completed.emit(); queue_free())


func _move(weight: float) -> void:
	var target: Dictionary = destination.call()
	position = _start_center.lerp(target.center, weight) - pivot_offset


func _land(weight: float) -> void:
	var target: Dictionary = destination.call()
	position = Vector2(target.center) - pivot_offset
	var target_scale := 0.025 if disappearing else float(target.scale)
	scale = Vector2.ONE * lerpf(TRAVEL_SCALE, target_scale, weight)
	rotation = lerp_angle(0.0, float(target.get("rotation", 0.0)), weight)
	if disappearing:
		modulate.a = 1.0 - weight


func cancel() -> void:
	if _flight != null and _flight.is_valid():
		_flight.kill()
	queue_free()

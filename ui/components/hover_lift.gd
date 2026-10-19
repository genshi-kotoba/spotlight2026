extends RefCounted

## 悬停放大与提亮。挂在已有的鼠标进入/离开信号上，不改节点结构。
## 用法：HOVER_LIFT.attach(要动效的节点, 触发悬停的节点)；同一个触发节点可以同时连浮层。
## 复用格子时用 HOVER_LIFT.set_enabled() 开关，避免反复重连信号。

const DURATION := 0.10
const LIFT_SCALE := 1.06
const BRIGHTEN := Color(1.16, 1.16, 1.16)


## scale_to 是相对节点当前缩放的倍数，不是绝对缩放；brighten 关掉就只放大不改亮度。
static func attach(target: Control, trigger: Control = null, scale_to: float = LIFT_SCALE,
		brighten: bool = true) -> void:
	if not is_instance_valid(target):
		return
	var source: Control = trigger if is_instance_valid(trigger) else target
	var base_scale: Vector2 = target.scale
	var base_pivot: Vector2 = target.pivot_offset
	var base_modulate: Color = target.modulate
	source.mouse_entered.connect(_animate.bind(target, base_scale, base_pivot, base_modulate,
		base_scale * scale_to, true, brighten))
	source.mouse_exited.connect(_animate.bind(target, base_scale, base_pivot, base_modulate,
		base_scale, false, brighten))


static func set_enabled(target: Control, enabled: bool) -> void:
	if is_instance_valid(target):
		target.set_meta("hover_lift_enabled", enabled)


static func _animate(target: Control, base_scale: Vector2, base_pivot: Vector2,
		base_modulate: Color, to_scale: Vector2, lifting: bool, brighten: bool) -> void:
	if not _usable(target):
		return
	var tween := _tween(target)
	tween.set_parallel(true)
	tween.tween_property(target, "scale", to_scale, DURATION)
	# 枢轴与缩放同程补间：中途的偏差不到 0.1px，端点严格对齐。
	tween.tween_property(target, "pivot_offset",
		_pivot_for(target.size, base_scale, base_pivot, to_scale), DURATION)
	if brighten:
		tween.tween_property(target, "modulate",
			base_modulate * BRIGHTEN if lifting else base_modulate, DURATION)


## 枢轴按「视觉矩形中心不动」反解。Godot 的枢轴变换是 pivot + (p - pivot) * scale，
## 节点带非 1 倍基础缩放时（卡面 0.2917），直接取 size * 0.5 会把整块矩形推到别处。
static func _pivot_for(node_size: Vector2, base_scale: Vector2, base_pivot: Vector2,
		to_scale: Vector2) -> Vector2:
	var pivot := base_pivot
	for axis in 2:
		var denominator := 1.0 - to_scale[axis]
		if absf(denominator) < 0.0001:
			continue
		pivot[axis] = (base_pivot[axis] * (1.0 - base_scale[axis])
			+ node_size[axis] * (base_scale[axis] - to_scale[axis]) * 0.5) / denominator
	return pivot


static func _usable(target: Control) -> bool:
	return is_instance_valid(target) and bool(target.get_meta("hover_lift_enabled", true))


static func _tween(target: Control) -> Tween:
	var existing := target.get_meta("hover_lift_tween", null) as Tween
	if existing != null and existing.is_valid():
		existing.kill()
	var tween := target.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	target.set_meta("hover_lift_tween", tween)
	return tween

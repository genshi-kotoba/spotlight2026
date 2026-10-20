extends Node2D
## A discovered, interactable gate may be behind a tall wall or the fog rim.
## Draw only its icon above those effects; never authorize terrain pixels.
const Art = preload("res://systems/map/relief_2d/node_art.gd")
const Feel = preload("res://ui/components/feel_curve.gd")
## 图标一个呼吸周期，引线、锚点、E 徽标都跟着同一条脉动。
const PULSE_PERIOD := 1.6
const POP_SCALE := 0.82
const ICON_ALPHA_LOW := 0.86
const LINE_ALPHA_LOW := 0.40
var node_id := ""
var _texture: Texture2D
var _anchor := Vector2.ZERO
var _rect := Rect2()
var _scale := 1.0
var _phase := 0.0
var _tween: Tween
var _leaving := false

func _init() -> void:
	z_index = 201
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	hide()
	set_process(false)

## 消失带走过渡：node_id 保留到淡出结束，否则淡出这段时间 _draw 直接空转。
func clear() -> void:
	if _leaving or node_id.is_empty():
		return
	if not visible:
		node_id = ""
		return
	_leaving = true
	_play(modulate.a, scale.x, 0.0, POP_SCALE, Feel.PUSH_IN, _finish_hide)

func set_gate(node: Dictionary, anchor: Vector2, actor: Vector2, zoom: float) -> void:
	if not node.get("known", false) or not node.get("is_route_gate", false) or node.get("completed", false):
		clear()
		return
	var texture: Texture2D = Art.texture(str(Art.describe(node).texture))
	if texture == null:
		clear()
		return
	var unit := 1.0 / maxf(zoom, .05)
	var center := anchor + Vector2(0, -105) * unit
	# Keep the small callout clear of the actor's body, at every zoom level.
	if absf(center.x - actor.x) < 48 * unit and absf(center.y - actor.y) < 90 * unit:
		center.x += (68 if anchor.x >= actor.x else -68) * unit
	var rect := Rect2(center - Vector2(28, 28) * unit, Vector2(56, 56) * unit)
	var appeared: bool = bool(_leaving or not visible or node_id != node.id)
	if not appeared and _anchor == anchor and _rect == rect:
		return
	node_id = node.id
	_texture = texture
	_anchor = anchor
	_rect = rect
	_scale = unit
	# 原点挪到图标中心，出现时的弹入才是原地弹，而不是朝世界原点收。
	position = rect.get_center()
	if appeared:
		_appear()
	else:
		queue_redraw()

func _appear() -> void:
	_leaving = false
	_phase = 0.0
	_play(0.0, POP_SCALE, 1.0, 1.0, Feel.POPUP_IN, Callable())

func _finish_hide() -> void:
	hide()
	node_id = ""
	_leaving = false
	_phase = 0.0
	set_process(false)

func _play(from_alpha: float, from_scale: float, to_alpha: float, to_scale: float,
		duration: float, on_done: Callable) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	show()
	modulate.a = from_alpha
	scale = Vector2.ONE * from_scale
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(Feel.CURVE_CUBIC).set_ease(Feel.EASE_OUT)
	_tween.tween_property(self, "modulate:a", to_alpha, duration)
	_tween.tween_property(self, "scale", Vector2.ONE * to_scale, duration)
	if on_done.is_valid():
		_tween.chain().tween_callback(on_done)
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	_phase += delta
	queue_redraw()

func _draw() -> void:
	if _texture == null: return
	var center := position
	var anchor := _anchor - center
	var rect := Rect2(_rect.position - center, _rect.size)
	var pulse := 0.5 + 0.5 * sin(_phase * TAU / PULSE_PERIOD)
	var end := Vector2(rect.get_center().x, rect.end.y + 16 * _scale)
	draw_line(anchor, end, Color(.85, .70, .43, lerpf(LINE_ALPHA_LOW, .85, pulse)), lerpf(1.0, 1.7, pulse) * _scale, true)
	draw_circle(anchor, (2.6 + 0.9 * pulse) * _scale, Color(.96, .80, .49))
	var size := _texture.get_size()
	size *= minf(rect.size.x / size.x, rect.size.y / size.y) * (1.0 + 0.06 * pulse)
	draw_texture_rect(_texture, Rect2(rect.get_center() - size * .5, size), false, Color(1, .93, .82, lerpf(ICON_ALPHA_LOW, 1.0, pulse)))
	draw_circle(end - Vector2(0, 5 * _scale), 10 * _scale, Color(.10, .08, .06, .94))
	draw_string(Art.font(), end + Vector2(-4, 0) * _scale, "E", HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1, roundi(13 * _scale)), Color(1, .9, .68, lerpf(ICON_ALPHA_LOW, 1.0, pulse)))

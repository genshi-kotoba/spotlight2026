extends CanvasLayer
## Cosmetic only: no path traversal, fog mutation, random stream or scene load.
signal finished(success: bool)

const DEPART_SECONDS := 0.12
const ARRIVE_SECONDS := 0.20
const INK := Color(1.0, 0.79, 0.43)

class Strokes extends Control:
	var effect
	func _draw() -> void:
		effect._draw_strokes(self)

class Echoes extends Control:
	var effect
	func _draw() -> void:
		effect._draw_echoes(self)

var _canvas: Control
var _echoes: Control
var _tween: Tween
var _playing := false
var _generation := 0
var _arrival := false
var _progress := 0.0
var _success := false
var _portrait: Dictionary = {}
var _direction := Vector2.RIGHT

func _ready() -> void:
	layer = 1400
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Strokes.new()
	_canvas.name = "TravelStrokes"
	_canvas.effect = self
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)
	_echoes = Echoes.new()
	_echoes.effect = self
	_echoes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_echoes.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(_echoes)
	# Reuse the current frame's alpha, not its unlit RGB or a screenshot.
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; render_mode unshaded; varying vec4 ink; void vertex(){ ink = COLOR; } void fragment(){ COLOR = vec4(vec3(1.0, 0.79, 0.43), texture(TEXTURE, UV).a * ink.a); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	_echoes.material = material
	_canvas.hide()

func is_playing() -> bool:
	return _playing

func play(portrait: Dictionary, direction: Vector2, commit: Callable, arrival_portrait: Callable) -> bool:
	if _playing or not is_inside_tree(): return false
	_generation += 1
	_playing = true
	_arrival = false
	_progress = 0.0
	_success = false
	_portrait = portrait.duplicate()
	_direction = direction.normalized() if not direction.is_zero_approx() else Vector2.RIGHT
	_canvas.show()
	_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.tween_method(_depart, 0.0, 1.0, DEPART_SECONDS)
	_tween.tween_callback(_midpoint.bind(commit, arrival_portrait, _generation))
	_tween.tween_method(_arrive, 0.0, 1.0, ARRIVE_SECONDS)
	_tween.tween_callback(_finish)
	_redraw()
	return true

func cancel() -> void:
	_generation += 1
	if _tween != null and _tween.is_valid(): _tween.kill()
	_tween = null
	_playing = false
	_portrait.clear()
	if is_instance_valid(_canvas): _canvas.hide()

func _depart(value: float) -> void:
	_arrival = false
	_progress = value
	_redraw()

func _midpoint(commit: Callable, arrival_portrait: Callable, generation: int) -> void:
	_success = bool(commit.call())
	# A synchronous arrival listener may replace the floor and cancel us.
	if not _playing or generation != _generation: return
	if _success: _portrait = arrival_portrait.call()

func _arrive(value: float) -> void:
	_arrival = true
	_progress = value
	_redraw()

func _finish() -> void:
	var success := _success
	_playing = false
	_tween = null
	_portrait.clear()
	_canvas.hide()
	finished.emit(success)

func _redraw() -> void:
	_canvas.queue_redraw()
	_echoes.queue_redraw()

func _body() -> Rect2:
	return _portrait.get("body", Rect2(_canvas.size * 0.5 - Vector2(30, 80), Vector2(60, 80)))

func _draw_strokes(canvas: Control) -> void:
	if not _playing: return
	var p := clampf(_progress, 0.0, 1.0)
	var fade := pow(1.0 - p, 1.6) if _arrival else smoothstep(0.1, 1.0, p)
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color(0.025, 0.018, 0.012, fade * 0.94))
	if _arrival and not _success: return
	var body := _body()
	var center := body.get_center()
	var feet: Vector2 = _portrait.get("feet", body.end)
	var scale := clampf(body.size.y / 110.0, 0.55, 2.0)
	var amount := sin(p * PI) if _arrival else sin(p * PI * 0.85)
	var side := _direction.orthogonal()
	for i in range(14):
		var lane := (float(i % 7) / 6.0 - 0.5) * 110.0 * scale
		var offset := (25.0 + float(i % 5) * 17.0 + p * 60.0) * scale
		var tip := center + side * lane - _direction * offset
		var length := (20.0 + float(i % 4) * 10.0) * scale * (0.5 + amount)
		var color := Color(INK, (0.18 + float(i % 3) * 0.12) * amount)
		canvas.draw_line(tip - _direction * length, tip, Color(color, color.a * 0.22), 5.0 * scale, true)
		canvas.draw_line(tip - _direction * length, tip, color, 1.4 * scale, true)
	if _arrival:
		canvas.draw_set_transform(feet, 0.0, Vector2(1.0, 0.48))
		canvas.draw_arc(Vector2.ZERO, (18.0 + p * 70.0) * scale, 0.0, TAU, 64, Color(INK, (1.0 - p) * 0.65), 2.0 * scale, true)
		canvas.draw_set_transform(Vector2.ZERO)

func _draw_echoes(canvas: Control) -> void:
	if not _playing or (_arrival and not _success): return
	var texture: Texture2D = _portrait.get("texture")
	if texture == null: return
	var p := clampf(_progress, 0.0, 1.0)
	var visibility := pow(1.0 - p, 1.4) if _arrival else sin(p * PI)
	var rect: Rect2 = _portrait.rect
	var scale := clampf(_body().size.y / 110.0, 0.55, 2.0)
	for i in range(3, 0, -1):
		var echo := rect
		echo.position -= _direction * (float(i) * 15.0 + p * 45.0) * scale
		canvas.draw_texture_rect(texture, echo, false, Color(INK, visibility * (0.16 - float(i) * 0.03)))

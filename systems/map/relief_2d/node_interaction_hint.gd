extends Node2D
## 已知且靠近的可交互节点显示公共名称底框；关口保留原来的悬浮图标。
## 只将提示画在墙与雾上方，不授权新的地形、节点或远处事件身份。
const Art = preload("res://systems/map/relief_2d/node_art.gd")
const Feel = preload("res://ui/components/feel_curve.gd")
const UiSkin = preload("res://ui/components/common_ui_skin.gd")
## 图标一个呼吸周期，引线、锚点、E 徽标都跟着同一条脉动。
const PULSE_PERIOD := 1.6
const POP_SCALE := 0.82
const ICON_ALPHA_LOW := 0.86
const LINE_ALPHA_LOW := 0.40
const NAME_FONT_SIZE := 18
const NAME_HEIGHT := 38.0
const NAME_SCALE := 1.5
const NAME_GAP := 6.0
const SURFACE_OPACITY := 0.82
var node_id := ""
var _texture: Texture2D
var _show_gate := false
var _name := ""
var _name_rect := Rect2()
var _name_frame: StyleBox
var _anchor := Vector2.ZERO
var _rect := Rect2()
var _scale := 1.0
var _phase := 0.0
var _tween: Tween
var _leaving := false

func _init() -> void:
	z_index = 201
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_name_frame = UiSkin.panel("tooltip", Vector4(16, 8, 16, 8))
	_name_frame.set("surface_opacity", SURFACE_OPACITY)
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
	set_node(node, anchor, actor, zoom)

## 调用方必须先通过 nearby_nodes()；label 只属于这一条近处提示，不写回发布视图。
func set_node(node: Dictionary, anchor: Vector2, _actor: Vector2, zoom: float, label: String = "", marker_bounds: Rect2 = Rect2()) -> void:
	if not node.get("known", false) or str(node.get("id", "")).is_empty():
		clear()
		return
	var show_gate: bool = bool(node.get("is_route_gate", false)) and not bool(node.get("completed", false))
	var art_texture: Texture2D = Art.texture(str(Art.describe(node).texture))
	var texture: Texture2D = art_texture if show_gate else null
	var next_name := label if not label.is_empty() else str(node.get("display_name", "节点"))
	var unit := 1.0 / maxf(zoom, .05)
	# 使用渲染器已经发布的同一张贴图矩形，不随玩家经过中线左右避让。
	var art_rect := marker_bounds
	if art_texture != null and marker_bounds.has_area():
		art_rect = Art.target_rect(marker_bounds, art_texture.get_size())
	var top := Vector2(art_rect.get_center().x, art_rect.position.y) if art_rect.has_area() else anchor + Vector2(0, -105) * unit
	var name_center := top - Vector2(0, NAME_HEIGHT * NAME_SCALE * .5 + NAME_GAP) * unit
	# 关口的悬浮图标保留原位置；名称框独立固定在贴图顶部。
	var icon_center := anchor + Vector2(0, -105) * unit
	var rect := Rect2(icon_center - Vector2(28, 28) * unit, Vector2(56, 56) * unit)
	var appeared: bool = bool(_leaving or not visible or node_id != node.id)
	if not appeared and _anchor == anchor and _rect == rect and position == name_center and _name == next_name and _show_gate == show_gate and _texture == texture:
		return
	node_id = node.id
	_texture = texture
	_show_gate = show_gate
	_name = next_name
	var name_width := maxf(112.0, Art.font().get_string_size(_name, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE).x + 32.0)
	_name_rect = Rect2(-Vector2(name_width, NAME_HEIGHT) * .5, Vector2(name_width, NAME_HEIGHT))
	_anchor = anchor
	_rect = rect
	_scale = unit
	# 弹入围绕名称框自身中心，不改变贴图锚点。
	position = name_center
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
	if node_id.is_empty(): return
	if _show_gate and _texture != null:
		_draw_gate()
	# 按屏幕像素绘制公共 UI-002 底框，地图缩放不会改变字号、边角或留白。
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * _scale * NAME_SCALE)
	draw_style_box(_name_frame, _name_rect)
	var font := Art.font()
	var text_width := font.get_string_size(_name, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE).x
	var baseline := _name_rect.get_center() + Vector2(-text_width * .5, (font.get_ascent(NAME_FONT_SIZE) - font.get_descent(NAME_FONT_SIZE)) * .5)
	draw_string(font, baseline + Vector2(0, 1), _name, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE, Color(.08, .06, .04, .95))
	draw_string(font, baseline, _name, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE, UiSkin.TEXT)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func contains_screen_point(at: Vector2) -> bool:
	if not visible or _leaving or node_id.is_empty(): return false
	var local := get_global_transform_with_canvas().affine_inverse() * at
	return _name_rect.has_point(local / (_scale * NAME_SCALE))

func _draw_gate() -> void:
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

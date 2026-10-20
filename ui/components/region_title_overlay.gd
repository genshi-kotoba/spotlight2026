class_name RegionTitleOverlay
extends Control
## 地区标题的纯表现模板；存档与首次判断由 RegionTitles 负责。
signal finished
const REVEAL := preload("res://ui/components/region_title_reveal.gd")
const BLUR := preload("res://ui/components/region_title_blur.gdshader")
const INK := Color("f5ead8")
const GOLD := Color("b99a64")
var _word_viewport: SubViewport
var _word: RichTextLabel
var _texture: TextureRect
var _shadow: TextureRect
var _eyebrow: Label
var _subtitle: Label
var _effect: RichTextEffect
var _blur: ShaderMaterial
var _tween: Tween
var _playing := false
var _elapsed := 0.0
var _duration := 4.3
var _reduced := false
var _font: FontVariation
var _font_size := 68
var _heading := ""
var _center := Vector2.ZERO
var _ornament_spread := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var base := SystemFont.new()
	base.font_names = PackedStringArray(["Songti SC", "STSong", "Noto Serif CJK SC", "SimSun", "serif"])
	_font = FontVariation.new()
	_font.base_font = base
	_font.spacing_glyph = 10
	_word_viewport = SubViewport.new()
	_word_viewport.name = "TitleTexture"
	_word_viewport.disable_3d = true
	_word_viewport.transparent_bg = true
	_word_viewport.gui_disable_input = true
	_word_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_word_viewport)
	_word = RichTextLabel.new()
	_word.bbcode_enabled = true
	_word.scroll_active = false
	_word.autowrap_mode = TextServer.AUTOWRAP_OFF
	_word.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_word.add_theme_font_override("normal_font", _font)
	_word.add_theme_color_override("default_color", INK)
	_word_viewport.add_child(_word)
	_texture = TextureRect.new()
	_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_texture.texture = _word_viewport.get_texture()
	_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_texture.self_modulate = INK
	_blur = ShaderMaterial.new()
	_blur.shader = BLUR
	_texture.material = _blur
	# 同一张逐字显现纹理绘制柔和深色投影，不另建文字视口。
	_shadow = TextureRect.new()
	_shadow.name = "TitleShadow"
	_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shadow.texture = _texture.texture
	_shadow.expand_mode = _texture.expand_mode
	_shadow.stretch_mode = _texture.stretch_mode
	_shadow.self_modulate = Color(0.015, 0.012, 0.008, 0.98)
	var shadow_blur := ShaderMaterial.new()
	shadow_blur.shader = BLUR
	shadow_blur.set_shader_parameter("radius_px", 2.5)
	_shadow.material = shadow_blur
	add_child(_shadow)
	add_child(_texture)
	_eyebrow = _label(20, Color("c0b69e"))
	_subtitle = _label(24, Color("c2b49a"))
	resized.connect(_layout)
	hide()

func _label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 3)
	label.add_theme_constant_override("shadow_outline_size", 3)
	add_child(label)
	return label

func play(entry: Dictionary, style: Dictionary = {}) -> bool:
	if not is_node_ready() or not entry.get("title") is String or str(entry.title).strip_edges().is_empty():
		return false
	cancel()
	_heading = entry.title
	_duration = clampf(float(style.get("duration", 4.3)), 2.5, 8.0)
	_font_size = clampi(int(style.get("font_size", 68)), 32, 96)
	_reduced = bool(style.get("reduced_motion", false))
	_eyebrow.text = str(entry.get("eyebrow", ""))
	_subtitle.text = str(entry.get("subtitle", ""))
	_effect = REVEAL.new()
	_effect.character_count = _heading.length()
	_effect.reduced_motion = _reduced
	_word.install_effect(_effect)
	_word.text = "[center][region_reveal]" + _heading.replace("[", "[lb]") + "[/region_reveal][/center]"
	_playing = true
	_layout()
	_word_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	show()
	_render_at(0.0)
	_tween = create_tween()
	_tween.tween_method(_render_at, 0.0, _duration, _duration)
	_tween.tween_callback(_finish)
	return true

func is_playing() -> bool:
	return _playing

func cancel() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_playing = false
	if _word_viewport != null:
		_word_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_word.text = ""
		_word.custom_effects = []
	_effect = null
	hide()

func _exit_tree() -> void:
	cancel()

func _finish() -> void:
	cancel()
	finished.emit()

func _layout() -> void:
	if _word_viewport == null or _heading.is_empty():
		return
	var screen := get_viewport_rect().size
	var width := maxf(240.0, minf(1040.0, screen.x - 64.0))
	var measured := _font.get_string_size(_heading, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	var fitted := maxi(16, int(float(_font_size) * minf(1.0, (width - 48.0) / maxf(1.0, measured))))
	_word.add_theme_font_size_override("normal_font_size", fitted)
	var height := float(fitted * 2 + 32)
	_word_viewport.size = Vector2i(int(ceil(width)), int(ceil(height)))
	_word.position = Vector2(20, 16)
	_word.size = Vector2(width - 40.0, height - 16.0)
	_center = Vector2(screen.x * 0.5, screen.y * 0.38)
	_texture.position = _center - Vector2(width * 0.5, height * 0.5)
	_texture.size = Vector2(width, height)
	_shadow.position = _texture.position + Vector2(2.5, 4.0)
	_shadow.size = _texture.size
	_eyebrow.position = Vector2(_texture.position.x, _center.y - height * 0.5 - 56.0)
	_eyebrow.size = Vector2(width, 34)
	_subtitle.position = Vector2(_texture.position.x, _center.y + height * 0.5 - 14.0)
	_subtitle.size = Vector2(width, 40)
	queue_redraw()

func _render_at(seconds: float) -> void:
	_elapsed = seconds
	var phase := seconds / _duration
	var fade_in := smoothstep(0.0, 0.22 if not _reduced else 0.07, phase)
	var fade_out := 1.0 - smoothstep(0.77, 1.0, phase)
	modulate.a = fade_in * fade_out
	if _effect != null:
		_effect.elapsed = seconds * 4.3 / _duration
	var reveal_time := seconds * 4.3 / _duration
	_blur.set_shader_parameter("radius_px", 0.0 if _reduced else 6.0 * (1.0 - smoothstep(0.0, 1.25, reveal_time)))
	_subtitle.modulate.a = 1.0 if _reduced else smoothstep(0.65, 1.2, reveal_time)
	_ornament_spread = 1.0 if _reduced else smoothstep(0.0, 0.85, reveal_time)
	queue_redraw()

func _draw() -> void:
	if not _playing:
		return
	var color := GOLD
	color.a = 0.8
	var y := _texture.position.y - 12.0
	var span := minf(160.0, _texture.size.x * 0.22) * _ornament_spread
	draw_line(Vector2(_center.x - span, y), Vector2(_center.x - 16.0, y), color, 1.0, true)
	draw_line(Vector2(_center.x + 16.0, y), Vector2(_center.x + span, y), color, 1.0, true)
	var diamond := PackedVector2Array([Vector2(0, -4), Vector2(4, 0), Vector2(0, 4), Vector2(-4, 0), Vector2(0, -4)])
	for index in diamond.size():
		diamond[index] += Vector2(_center.x, y)
	draw_polyline(diamond, color, 1.0, true)
	draw_line(Vector2(_center.x - 45, _subtitle.position.y + 54), Vector2(_center.x + 45, _subtitle.position.y + 54), color * Color(1, 1, 1, 0.5), 1.0, true)

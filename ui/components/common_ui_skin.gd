class_name CommonUiSkin
extends RefCounted
## 显式绑定到通用控件；不会安装全局 Theme，也不递归改专用卡面/槽位。

const FRAME := preload("res://ui/components/common_frame_style.gd")
const BUTTON := preload("res://ui/components/common_button_style.gd")
const RELIC_MOTION := preload("res://ui/components/relic_text_motion.gd")
const TEXT := Color("fff5e8")
const DARK_TEXT := Color("211f1d")
static var _button_textures: Dictionary = {}
static var _relic_font: SystemFont
static var _relic_bold_font: SystemFont

static func relic_font() -> Font:
	if _relic_font == null:
		_relic_font = SystemFont.new()
		_relic_font.font_names = PackedStringArray([
			"Microsoft YaHei", "Noto Sans CJK SC", "Heiti SC", "PingFang SC", "sans-serif",
		])
		_relic_font.allow_system_fallback = true
	return _relic_font

static func relic_bold_font() -> Font:
	if _relic_bold_font == null:
		_relic_bold_font = SystemFont.new()
		_relic_bold_font.font_names = (relic_font() as SystemFont).font_names
		_relic_bold_font.font_weight = 700
		_relic_bold_font.allow_system_fallback = true
	return _relic_bold_font

static func setup_relic_text(label: RichTextLabel, font_size: int) -> void:
	label.add_theme_font_override("normal_font", relic_font())
	label.add_theme_font_override("bold_font", relic_bold_font())
	label.add_theme_font_size_override("normal_font_size", font_size)
	label.add_theme_font_size_override("bold_font_size", font_size)
	for effect: Variant in label.custom_effects:
		if effect is RichTextEffect and effect.get_script() == RELIC_MOTION:
			return
	label.install_effect(RELIC_MOTION.new())

static func panel(kind: String = "panel", margins: Vector4 = Vector4.ZERO) -> StyleBox:
	var style := FRAME.new()
	style.compact = kind in ["strip", "tooltip", "row", "tiny"]
	if style.compact:
		style.corner_size = Vector2(28, 10) if kind != "tiny" else Vector2(13, 5)
	elif kind == "small":
		style.corner_size = Vector2(24, 26)
	if kind == "event":
		style.surface_opacity = 0.52
	elif kind == "page_border":
		style.surface_opacity = 0.32
	style.content_margin_left = margins.x
	style.content_margin_top = margins.y
	style.content_margin_right = margins.z
	style.content_margin_bottom = margins.w
	return style

static func button_style(state: String = "normal", margins: Vector4 = Vector4(18, 8, 18, 8)) -> StyleBox:
	var file_state: String = {"normal": "初始", "hover": "悬停", "pressed": "按下", "disabled": "初始"}.get(state, "初始")
	if not _button_textures.has(file_state):
		_button_textures[file_state] = load("res://assets/ui/UI-003/大按钮-%s.png" % file_state)
	var style := BUTTON.new()
	style.texture = _button_textures[file_state]
	style.region = Rect2(40, 46, 841, 305) if file_state != "悬停" else Rect2(40, 45, 841, 307)
	style.content_margin_left = margins.x
	style.content_margin_top = margins.y
	style.content_margin_right = margins.z
	style.content_margin_bottom = margins.w
	if state == "disabled":
		style.modulate_color = Color(0.62, 0.62, 0.62, 0.78)
	return style

static func style_button(button: Button, margins: Vector4 = Vector4(18, 8, 18, 8)) -> void:
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		button.add_theme_stylebox_override(state, button_style(state, margins))
	# 焦点只画描边，不把另一张按钮图叠到正常状态上。
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	focus.border_color = Color("fff5e8")
	focus.set_border_width_all(2)
	focus.set_corner_radius_all(4)
	button.add_theme_stylebox_override("focus", focus)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", DARK_TEXT)
	button.add_theme_color_override("font_disabled_color", Color("aaa395"))

static func style_dialog(dialog: AcceptDialog) -> void:
	dialog.add_theme_stylebox_override("panel", panel("small", Vector4(24, 20, 24, 20)))
	dialog.get_label().add_theme_color_override("font_color", TEXT)
	style_button(dialog.get_ok_button())
	if dialog is ConfirmationDialog:
		style_button((dialog as ConfirmationDialog).get_cancel_button())

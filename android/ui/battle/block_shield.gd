class_name BlockShield
extends Control

## 血条右端的盾牌：盾面上写当前格挡层数，格挡为 0 时整块隐藏。
## 只画一个盾和数字，不管位置；位置由挂它的人摆。

const SHIELD_COLOR := Color(0.36, 0.46, 0.6, 1)
const SHIELD_EDGE := Color(0.83, 0.75, 0.52, 1)
const SHIELD_EDGE_DARK := Color(0.16, 0.13, 0.1, 0.9)
const SHIELD_SHINE := Color(0.62, 0.73, 0.86, 0.55)

var number_px := 15:
	set(new_px):
		number_px = new_px
		if _number != null:
			_number.add_theme_font_size_override("font_size", number_px)

var value := 0:
	set(new_value):
		value = maxi(0, new_value)
		visible = value > 0
		_number.text = str(value)
		queue_redraw()

var _number: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(40, 46)
	_number = Label.new()
	_number.name = "Value"
	_number.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_number.add_theme_font_size_override("font_size", number_px)
	_number.add_theme_color_override("font_color", Color(0.96, 0.97, 1, 1))
	_number.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_number.add_theme_constant_override("shadow_offset_x", 1)
	_number.add_theme_constant_override("shadow_offset_y", 1)
	_number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_number)
	visible = value > 0


func _draw() -> void:
	var w := size.x
	var h := size.y
	var outline := PackedVector2Array([
		Vector2(w * 0.50, h * 0.02),
		Vector2(w * 0.97, h * 0.16),
		Vector2(w * 0.92, h * 0.58),
		Vector2(w * 0.50, h * 0.98),
		Vector2(w * 0.08, h * 0.58),
		Vector2(w * 0.03, h * 0.16),
	])
	draw_colored_polygon(outline, SHIELD_EDGE_DARK)
	var inner := PackedVector2Array([])
	var center := Vector2(w * 0.5, h * 0.5)
	for point in outline:
		inner.append(center + (point - center) * 0.9)
	draw_colored_polygon(inner, SHIELD_COLOR)
	var rim := PackedVector2Array([])
	for point in inner:
		rim.append(point)
	rim.append(inner[0])
	draw_polyline(rim, SHIELD_EDGE, 1.5)
	# 左上到右下的一道高光，别让盾面看着像纯色块。
	draw_line(Vector2(w * 0.24, h * 0.22), Vector2(w * 0.62, h * 0.72), SHIELD_SHINE, 2.0)

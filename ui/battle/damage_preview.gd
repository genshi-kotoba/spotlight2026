class_name DamagePreview
extends Control

## 当前状态下的直接数值小计，不宣称是完整规则引擎的结果。

const PLATE_COLOR := Color(0.09, 0.07, 0.06, 0.86)
const EDGE_COLOR := Color(0.62, 0.5, 0.3, 0.75)
const TITLE_COLOR := Color(0.749, 0.682, 0.553, 1.0)
const DAMAGE_COLOR := Color(0.955, 0.78, 0.42, 1.0)
const BLOCK_COLOR := Color(0.62, 0.74, 0.86, 1.0)
const LETHAL_COLOR := Color(0.86, 0.36, 0.32, 1.0)

var _damage: Label
var _block: Label
var _lethal: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate := Panel.new()
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = PLATE_COLOR
	style.set_corner_radius_all(10)
	style.set_border_width_all(1)
	style.border_color = EDGE_COLOR
	plate.add_theme_stylebox_override("panel", style)
	add_child(plate)

	add_child(_make_title("基础伤害参考", Vector2(0, 6)))
	add_child(_make_title("基础格挡参考", Vector2(0, 56)))
	tooltip_text = "按当前力量、虚弱、坚韧及附魔计算固定数值。\n不包含易伤、条件数值、指针跳转、残片或后续状态联动；以实际结算为准。"
	mouse_filter = Control.MOUSE_FILTER_PASS
	_damage = _make_value(DAMAGE_COLOR)
	_damage.position = Vector2(0, 24)
	add_child(_damage)
	_block = _make_value(BLOCK_COLOR)
	_block.position = Vector2(0, 74)
	add_child(_block)

	_lethal = Label.new()
	_lethal.text = "击杀"
	_lethal.position = Vector2(112, 26)
	_lethal.size = Vector2(80, 28)
	_lethal.add_theme_font_size_override("font_size", 17)
	_lethal.add_theme_color_override("font_color", LETHAL_COLOR)
	_lethal.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_lethal.add_theme_constant_override("shadow_offset_x", 1)
	_lethal.add_theme_constant_override("shadow_offset_y", 1)
	_lethal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lethal)
	visible = false


func show_values(damage: int, block: int, lethal: bool) -> void:
	_damage.text = str(damage)
	_block.text = str(block)
	_lethal.visible = lethal
	visible = damage > 0 or block > 0


func _make_title(text: String, at: Vector2) -> Label:
	var title := Label.new()
	title.text = text
	title.position = at
	title.size = Vector2(170, 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return title


func _make_value(color: Color) -> Label:
	var value := Label.new()
	value.text = "0"
	value.size = Vector2(170, 34)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 28)
	value.add_theme_color_override("font_color", color)
	value.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	value.add_theme_constant_override("shadow_offset_x", 2)
	value.add_theme_constant_override("shadow_offset_y", 2)
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return value

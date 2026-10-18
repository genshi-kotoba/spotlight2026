class_name HoverTip
extends PanelContainer

## HUD 与背包共用的悬停浮层：深色底 + 细金边，文字自动换行。
## 系统 tooltip 在战斗里不稳定（会被全屏控件吞掉），统一用这个。

const FONT_SIZE := 15
const MIN_WIDTH := 250.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.05, 0.95)
	style.set_corner_radius_all(6)
	style.set_border_width_all(1)
	style.border_color = Color(0.62, 0.5, 0.3, 0.7)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.name = "TipLabel"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(MIN_WIDTH, 0)
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", Color(0.94, 0.9, 0.82))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


func show_for(anchor: Control, text: String) -> void:
	if not is_instance_valid(anchor):
		return
	show_at_rect(Rect2(anchor.global_position, anchor.size), text)


## 按一块全局矩形定位，浮层贴在它下沿；下方放不下就翻到上沿。
## 典籍格子是斜的四边形，没有对应的 Control 可当锚点，走这个。
func show_at_rect(rect: Rect2, text: String) -> void:
	var label := get_node_or_null("TipLabel") as Label
	if label == null:
		return
	label.text = text
	visible = true
	reset_size()
	var view := get_viewport_rect().size
	var x := clampf(rect.position.x, 8.0, maxf(8.0, view.x - 8.0 - size.x))
	var y := rect.position.y + rect.size.y + 6.0
	if y + size.y > view.y - 8.0:
		y = maxf(8.0, rect.position.y - size.y - 6.0)
	global_position = Vector2(x, y)


func hide_tip() -> void:
	visible = false

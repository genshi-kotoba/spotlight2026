class_name SettingsButton
extends Button

## 右上角的设置入口。资产表里没有齿轮图，这里用矢量绘制占位：
## 一圈八齿加中心孔，颜色与 UI-003 的金色描边一致。

const PLATE_COLOR := Color(0.08, 0.065, 0.05, 0.82)
const PLATE_HOVER_COLOR := Color(0.14, 0.11, 0.08, 0.92)
const EDGE_COLOR := Color(0.910, 0.706, 0.333, 0.55)
const GEAR_COLOR := Color(0.910, 0.706, 0.333)
const GEAR_HOVER_COLOR := Color(1.0, 0.824, 0.451)
const TOOTH_COUNT := 8


func _ready() -> void:
	flat = true
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "设置"
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)


func _draw() -> void:
	var draw_scale := minf(size.x, size.y) / 48.0
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * draw_scale)
	var center := Vector2(24, 24)
	var hovered := is_hovered()
	var plate := PLATE_HOVER_COLOR if hovered else PLATE_COLOR
	var gear := GEAR_HOVER_COLOR if hovered else GEAR_COLOR

	draw_circle(center, 23.0, plate, true, -1.0, true)
	draw_arc(center, 23.0, 0.0, TAU, 48, EDGE_COLOR, 1.2, true)

	for index in TOOTH_COUNT:
		var angle := TAU * float(index) / float(TOOTH_COUNT) + PI / 8.0
		var direction := Vector2.from_angle(angle)
		var normal := Vector2(-direction.y, direction.x)
		var inner := center + direction * 9.0
		var outer := center + direction * 18.0
		draw_colored_polygon(PackedVector2Array([
			inner - normal * 4.2, inner + normal * 4.2,
			outer + normal * 3.3, outer - normal * 3.3,
		]), gear)

	draw_circle(center, 12.5, gear, true, -1.0, true)
	draw_circle(center, 5.0, plate, true, -1.0, true)

class_name HealthFill
extends Control

## 血条填充段。
## 血条框的右端是斜切的，用矩形填充会在末端留一个三角缺口；这里按比例画平行四边形，
## 右端跟着框的斜边走：填满时正好贴住斜边，不满时斜度按比例收小，上沿永远是一条直线。

var ratio := 1.0:
	set(value):
		ratio = clampf(value, 0.0, 1.0)
		queue_redraw()

## 右端在整条长度上向下的偏移量，本地像素（等于框的斜切量）。
var slant := 0.0:
	set(value):
		slant = value
		queue_redraw()

var fill_color := Color(0.756863, 0.239216, 0.262745):
	set(value):
		fill_color = value
		queue_redraw()


func _draw() -> void:
	if ratio <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
		return
	var right := size.x * ratio
	var points := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(right, 0.0),
		Vector2(right + slant * ratio, size.y),
		Vector2(0.0, size.y),
	])
	draw_colored_polygon(points, fill_color)

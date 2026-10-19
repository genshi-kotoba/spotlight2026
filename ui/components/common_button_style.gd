class_name CommonButtonStyle
extends StyleBox
## UI-003 横向三片：两端按高度等比缩放，只延展没有斜边/装饰的中段。

@export var texture: Texture2D
@export var region := Rect2(40, 46, 841, 305)
@export var modulate_color := Color.WHITE
const END_WIDTH := 270.0

func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if texture == null or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	# 极窄控件也保留两端纵横比；整块视觉等比缩小并垂直居中，命中仍是原矩形。
	var scale := minf(rect.size.y / region.size.y, rect.size.x / (END_WIDTH * 2.0))
	var end_size := END_WIDTH * scale
	var height := region.size.y * scale
	var top := rect.position.y + (rect.size.y - height) * 0.5
	texture.draw_rect_region(to_canvas_item,
		Rect2(rect.position.x, top, end_size, height),
		Rect2(region.position.x, region.position.y, END_WIDTH, region.size.y), modulate_color)
	var middle_width := rect.size.x - end_size * 2.0
	if middle_width > 0.0:
		texture.draw_rect_region(to_canvas_item,
			Rect2(rect.position.x + end_size, top, middle_width, height),
			Rect2(region.position.x + END_WIDTH, region.position.y,
				region.size.x - END_WIDTH * 2.0, region.size.y), modulate_color)
	texture.draw_rect_region(to_canvas_item,
		Rect2(rect.end.x - end_size, top, end_size, height),
		Rect2(region.end.x - END_WIDTH, region.position.y, END_WIDTH, region.size.y), modulate_color)

func _test_mask(point: Vector2, rect: Rect2) -> bool:
	return rect.has_point(point)

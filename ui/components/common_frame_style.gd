class_name CommonFrameStyle
extends StyleBox
## UI-002 原图的两层 GPU 绘制。源裁角和显示裁角独立，不生成或缩放 Image。

const BASE := preload("res://assets/ui/UI-002/底图背景.png")
const SQUARE := preload("res://assets/ui/UI-002/金-物品描述底框1.png")
const WIDE := preload("res://assets/ui/UI-002/金-物品描述底框2.png")
const BASE_REGION := Rect2(55, 46, 1231, 1230)

@export var compact := false
@export var corner_size := Vector2(38, 42)
@export var surface_tint := Color(0.60, 0.56, 0.50, 1.0)
@export var surface_opacity := 1.0

func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	# 底纹只画在金框内侧，透明装饰外缘仍能看见场景背景。
	var inset := minf(4.0, minf(rect.size.x, rect.size.y) * 0.08)
	if surface_opacity > 0.0:
		var tint := surface_tint
		tint.a *= surface_opacity
		BASE.draw_rect_region(to_canvas_item, rect.grow(-inset), BASE_REGION, tint)
	var texture: Texture2D = WIDE if compact else SQUARE
	var source := Rect2(25, 13, 1295, 478 if compact else 1300)
	var cut := Vector2(420, 150 if compact else 460)
	var dest_corner := Vector2(minf(corner_size.x, rect.size.x * 0.5),
		minf(corner_size.y, rect.size.y * 0.5))
	var sx := [source.position.x, source.position.x + cut.x, source.end.x - cut.x, source.end.x]
	var sy := [source.position.y, source.position.y + cut.y, source.end.y - cut.y, source.end.y]
	var dx := [rect.position.x, rect.position.x + dest_corner.x, rect.end.x - dest_corner.x, rect.end.x]
	var dy := [rect.position.y, rect.position.y + dest_corner.y, rect.end.y - dest_corner.y, rect.end.y]
	for y in 3:
		for x in 3:
			if x == 1 and y == 1:
				continue # 边框中心透明；不在每个面板中重复画大块透明纹理。
			var target := Rect2(dx[x], dy[y], dx[x + 1] - dx[x], dy[y + 1] - dy[y])
			if target.size.x > 0.0 and target.size.y > 0.0:
				texture.draw_rect_region(to_canvas_item, target,
					Rect2(sx[x], sy[y], sx[x + 1] - sx[x], sy[y + 1] - sy[y]))

func _test_mask(point: Vector2, rect: Rect2) -> bool:
	# 保持原矩形命中，不让金框透明区意外把输入漏给地图。
	return rect.has_point(point)

class_name RelicPieceArt
extends RefCounted

## 背包只使用 UI-021 的单片模板；典籍按槽位使用 UI-020 的拼图片。
## UI-020 的 20 张图共用 773×951 画布，以下区域是各图实际 alpha 边界。
const TEMPLATE_PATH := "res://assets/ui/UI-021/UI-21.png"
const SLOT_DIRECTORY := "res://assets/ui/UI-020"
const SLOT_REGIONS: Array[Rect2] = [
	Rect2(23, 18, 199, 199), Rect2(201, 18, 201, 197), Rect2(388, 18, 193, 194),
	Rect2(560, 18, 195, 196), Rect2(23, 191, 199, 207), Rect2(201, 191, 199, 204),
	Rect2(381, 192, 201, 202), Rect2(565, 194, 190, 196), Rect2(23, 373, 196, 200),
	Rect2(194, 376, 209, 201), Rect2(384, 376, 192, 197), Rect2(560, 375, 195, 196),
	Rect2(23, 555, 193, 206), Rect2(199, 556, 202, 202), Rect2(381, 558, 202, 198),
	Rect2(565, 553, 190, 201), Rect2(23, 741, 185, 188), Rect2(192, 742, 202, 187),
	Rect2(378, 735, 206, 194), Rect2(572, 735, 183, 194),
]

static var _template: Texture2D
static var _slots: Dictionary = {}


static func template_texture() -> Texture2D:
	if _template == null:
		var source := load(TEMPLATE_PATH) as Texture2D
		if source == null:
			return null
		var atlas := AtlasTexture.new()
		atlas.atlas = source
		var source_image := source.get_image()
		atlas.region = Rect2(source_image.get_used_rect()) if source_image != null else Rect2(Vector2.ZERO, source.get_size())
		_template = atlas
	return _template


## index 使用棋盘的零起始槽位编号，与残片 ID、颜色、名称无关。
static func slot_texture(index: int) -> Texture2D:
	if index < 0 or index >= SLOT_REGIONS.size():
		return null
	if not _slots.has(index):
		var atlas := AtlasTexture.new()
		atlas.atlas = load("%s/%d.png" % [SLOT_DIRECTORY, index + 1]) as Texture2D
		atlas.region = SLOT_REGIONS[index]
		_slots[index] = atlas
	return _slots[index]

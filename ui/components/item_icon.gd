class_name ItemIcon
extends TextureRect

## 背包格里的物品图标。图标资源来自资产表，不做程序绘制：
## 药剂用 UI-022 的六种药剂图，货币用 UI-023，没有对应美术的物品先用已有图标占位。
## 具体用哪张由 data/text/items.csv 的「图标路径」列决定。

const FALLBACK_PATH := "res://assets/ui/UI-022/红药剂.png"


static func make(path: String, side: float) -> ItemIcon:
	var icon := ItemIcon.new()
	icon.texture = _load_texture(path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size = Vector2(side, side)
	return icon


static func _load_texture(path: String) -> Texture2D:
	var normalized := path.strip_edges()
	if normalized.is_empty():
		normalized = FALLBACK_PATH
	if not normalized.begins_with("res://") or ".." in normalized:
		normalized = FALLBACK_PATH
	if not ResourceLoader.exists(normalized):
		normalized = FALLBACK_PATH
	return load(normalized) as Texture2D

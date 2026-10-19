class_name ItemIcon
extends TextureRect

## 背包格里的物品图标。图标资源来自资产表，不做程序绘制：
## 药剂用 UI-022 的六种药剂图，货币用 UI-023，没有对应美术的物品先用已有图标占位。
## 普通物品由 data/text/items.csv 的「图标路径」列决定；残片与残片包统一用 UI-021。

const FALLBACK_PATH := "res://assets/ui/UI-022/红药剂.png"


static func make(path: String, side: float) -> ItemIcon:
	return _make_texture(_load_texture(path), side)


## 带业务身份的入口：残片不依赖物品表里有没有对应行，也不退到药瓶占位。
## 保留 make(path, side)，已有药剂和普通物品调用不会改变。
static func make_item(item: Variant, side: float, path: String = "") -> ItemIcon:
	if item is Dictionary:
		if str(item.get("kind", "")) in ["fragment", "fragment_pack"]:
			return _make_texture(RelicPieceArt.template_texture(), side)
	elif item is String and item in ["fragment", "fragment_pack", "典籍残片", "典籍残片包"]:
		return _make_texture(RelicPieceArt.template_texture(), side)
	return make(path, side)


static func _make_texture(source_texture: Texture2D, side: float) -> ItemIcon:
	var icon := ItemIcon.new()
	icon.texture = source_texture
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

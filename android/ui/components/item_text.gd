class_name ItemText
extends RefCounted

## 物品表查询与悬停文案。战斗 HUD、背包界面与跑图状态列共用同一份口径。

static func record(item_id: String, display: String = "") -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return {}
	var catalog := tree.root.get_node_or_null("TextCatalog")
	if catalog == null:
		return {}
	var entry: Dictionary = catalog.entry("items", item_id)
	if entry.is_empty() and not display.is_empty():
		# 物品表按名称兜底：run.items 里可能只带显示名。
		for candidate: Dictionary in catalog.entries("items"):
			if str(candidate.get("name", "")) == display:
				return candidate
	return entry


static func tooltip(item_id: String, entry: Dictionary) -> String:
	var display := str(entry.get("name", item_id))
	var effect := str(entry.get("effect", ""))
	return display if effect.is_empty() else "%s\n%s" % [display, effect]

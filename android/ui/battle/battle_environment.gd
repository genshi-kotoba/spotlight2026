extends RefCounted
## 战场外观只依赖开战楼层，不消耗种子随机流或改变战斗规则。
const PATHS := [
	"res://assets/env/ENV-001/ENV-001.PNG",
	"res://assets/env/ENV-002/ENV-002.png",
	"res://assets/env/ENV-003/ENV-003.JPG",
	"res://assets/env/ENV-004/ENV-004.JPG",
]
const CONFIG_PATH := "res://data/config/battle_backgrounds.json"
static var _config: Dictionary = {}

static func _floor_config(floor_index: int) -> Dictionary:
	if _config.is_empty() and FileAccess.file_exists(CONFIG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if parsed is Dictionary: _config = parsed
	return _config.get(str(floor_index), {})

static func variants_for_floor(floor_index: int) -> Array[String]:
	var index := floor_index if floor_index >= 1 and floor_index <= PATHS.size() else 1
	var result: Array[String] = []
	for path: Variant in _floor_config(index).get("variants", []):
		if path is String and path.begins_with("res://") and ResourceLoader.exists(path): result.append(path)
	if result.is_empty(): result.append(PATHS[index - 1])
	return result

static func path_for_floor(floor_index: int, variant_index: int = -1) -> String:
	var index := floor_index if floor_index >= 1 and floor_index <= PATHS.size() else 1
	var variants := variants_for_floor(index)
	var selected := variant_index if variant_index >= 0 else int(_floor_config(index).get("default", 0))
	return variants[selected if selected >= 0 and selected < variants.size() else 0]

static func texture_for_floor(floor_index: int, variant_index: int = -1) -> Texture2D:
	# 地图预加载器提前持有本层贴图；不要在解析战斗脚本时同步读完四层大图。
	return load(path_for_floor(floor_index, variant_index)) as Texture2D

static func floor_for_battle(player: Dictionary, map_id: String) -> int:
	var saved: Variant = player.get("encounter_floor")
	if (saved is int or saved is float) and saved >= 1 and saved <= PATHS.size() and saved == floor(saved):
		return int(saved)
	# 兼容没有 encounter_floor 的旧战斗。读取战斗自己的地图 ID，
	# 不能读取当前地图层数：Boss 结算时它可能已经推进到下一层。
	var parts := map_id.rsplit(":floor-", true, 1)
	if parts.size() == 2 and parts[1].is_valid_int():
		var index := int(parts[1])
		if index >= 1 and index <= PATHS.size():
			return index
	return 1

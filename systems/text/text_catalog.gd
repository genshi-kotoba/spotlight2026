class_name TextCatalogService
extends Node

## PRG-014：展示元数据不执行效果，不覆盖战斗 CardData 或残片规则 CSV。
signal catalog_changed

const CATEGORIES := ["cards", "fragments", "monsters", "items"]
const DEFAULT_PATHS := {
	"cards": "res://data/text/cards.csv", "fragments": "res://data/text/fragments.csv",
	"monsters": "res://data/text/monsters.csv",
	"items": "res://data/text/items.csv",
}
const FRAGMENT_HEADERS := ["编号", "卡图资源路径", "卡名", "效果文本", "类型", "文本"]
const CARD_HEADERS := ["编号", "卡图资源路径", "卡名", "效果文本", "类型", "文本", "稀有度"]
const LEGACY_MONSTER_HEADERS := ["编号", "怪物图资源路径", "怪物名", "能力文本", "类型与出现地", "文本"]
const MONSTER_HEADERS := ["编号", "怪物图资源路径", "怪物名", "能力文本", "类型与出现地", "文本", "战斗中文本资源路径"]
const MONSTER_KEYS := ["id", "art_path", "name", "effect", "type", "text", "battle_text_path"]
const ENTRY_KEYS := ["id", "art_path", "name", "effect", "type", "text"]
const CARD_KEYS := ["id", "art_path", "name", "effect", "type", "text", "rarity"]
const ITEM_HEADERS := ["编号", "物品名", "图标路径", "效果文本"]
const ITEM_KEYS := ["id", "name", "icon_path", "effect"]


var paths: Dictionary = DEFAULT_PATHS.duplicate()
var _tables: Dictionary = {}
var _errors: Dictionary = {}


func _ready() -> void:
	reload()


func reload() -> Error:
	var first_error: Error = OK
	for category: String in CATEGORIES:
		var headers: Array = MONSTER_HEADERS if category == "monsters" else (CARD_HEADERS if category == "cards" else FRAGMENT_HEADERS)
		var keys: Array = CARD_KEYS if category == "cards" else (MONSTER_KEYS if category == "monsters" else ENTRY_KEYS)
		if category == "items":
			headers = ITEM_HEADERS
			keys = ITEM_KEYS
		var result := CsvTextTable.read(str(paths.get(category, "")), headers, keys)
		if category == "monsters" and result.error == ERR_INVALID_DATA:
			# 兼容旧工具/旧测试的六列 CSV；旧数据不猜测 TXT 路径。
			result = CsvTextTable.read(str(paths.get(category, "")), LEGACY_MONSTER_HEADERS, ENTRY_KEYS)
		_tables[category] = result.records
		if category == "fragments":
			_tables[category] = result.records.filter(func(record: Dictionary) -> bool: return str(record.id) not in RelicCatalog.RETIRED_IDS)
		_errors[category] = result.message
		if result.error != OK and first_error == OK:
			first_error = result.error
	catalog_changed.emit()
	return first_error


func error_message(category: String) -> String:
	return str(_errors.get(category, "未知图鉴类别"))


func entries(category: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in _tables.get(category, []):
		result.append(entry.duplicate(true))
	return result


func entry(category: String, id: String) -> Dictionary:
	for record: Dictionary in _tables.get(category, []):
		if record.id == id:
			return record.duplicate(true)
	return {}


func display_name(category: String, id: String, fallback: String = "") -> String:
	var record := entry(category, id)
	return str(record.get("name", "")) if not record.is_empty() else fallback


func monster_battle_text_path(enemy: Dictionary) -> String:
	# 旧地图保存了旧编号；优先用稳定的图片路径对应，避免读到其他怪物台词。
	var art := str(enemy.get("art_path", ""))
	if not art.is_empty():
		for record: Dictionary in _tables.get("monsters", []):
			if record.art_path == art:
				return str(record.get("battle_text_path", ""))
	return str(entry("monsters", str(enemy.get("enemy_id", ""))).get("battle_text_path", ""))


## 对话/事件 TXT 只作为纯文本，支持 {参数名} 替换，不执行 GDScript/BBCode。
func read_text(path: String, parameters: Dictionary = {}) -> Dictionary:
	if not path.begins_with("res://") or path.get_extension().to_lower() != "txt" or ".." in path:
		return {"error": ERR_INVALID_PARAMETER, "text": ""}
	var cached: Variant = ScenePreloader.cached_text(path)
	if cached is String:
		return {"error": OK, "text": format_text(cached, parameters)}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": FileAccess.get_open_error(), "text": ""}
	return {"error": OK, "text": format_text(file.get_as_text().trim_prefix("\uFEFF"), parameters)}


static func format_text(source: String, parameters: Dictionary) -> String:
	# 一次扫描，参数中的花括号不会再次被替换。
	var result := ""
	var start := 0
	while start < source.length():
		var open := source.find("{", start)
		if open < 0:
			result += source.substr(start)
			break
		result += source.substr(start, open - start)
		var close := source.find("}", open + 1)
		if close < 0:
			result += source.substr(open)
			break
		var key := source.substr(open + 1, close - open - 1)
		result += str(parameters[key]) if parameters.has(key) else source.substr(open, close - open + 1)
		start = close + 1
	return result


static func art_texture(path: String) -> Texture2D:
	var normalized := path.strip_edges()
	if not normalized.begins_with("res://") or ".." in normalized \
			or normalized.get_extension().to_lower() not in ["png", "jpg", "jpeg", "webp", "svg"]:
		return null
	if not ResourceLoader.exists(normalized):
		return null
	return load(normalized) as Texture2D

class_name TextCatalogService
extends Node

## PRG-014：展示元数据不执行效果，不覆盖战斗 CardData 或残片规则 CSV。
signal catalog_changed
signal progress_changed

const CATEGORIES := ["cards", "fragments", "monsters", "achievements"]
const DEFAULT_PATHS := {
	"cards": "res://data/text/cards.csv", "fragments": "res://data/text/fragments.csv",
	"monsters": "res://data/text/monsters.csv", "achievements": "res://data/text/achievements.csv",
}
const CARD_HEADERS := ["编号", "卡图资源路径", "卡名", "效果文本", "类型", "文本"]
const MONSTER_HEADERS := ["编号", "怪物图资源路径", "怪物名", "能力文本", "类型与出现地", "文本"]
const ACHIEVEMENT_HEADERS := ["编号", "成就名", "要求文本", "奖励"]
const ENTRY_KEYS := ["id", "art_path", "name", "effect", "type", "text"]
const ACHIEVEMENT_KEYS := ["id", "name", "requirement", "reward"]

enum DisplayMode { ALL, UNLOCKED, LOCKED }

var paths: Dictionary = DEFAULT_PATHS.duplicate()
var _tables: Dictionary = {}
var _errors: Dictionary = {}


func _ready() -> void:
	GlobalState.save_loaded.connect(func(): progress_changed.emit())
	GlobalState.unlocked_cards_changed.connect(func(_ids: Array[String]): progress_changed.emit())
	GlobalState.collection_unlocked.connect(func(_category: String, _id: String): progress_changed.emit())
	GlobalState.achievement_unlocked.connect(func(_id: String): progress_changed.emit())
	reload()


func reload() -> Error:
	var first_error: Error = OK
	for category: String in CATEGORIES:
		var headers: Array = ACHIEVEMENT_HEADERS if category == "achievements" else (
			MONSTER_HEADERS if category == "monsters" else CARD_HEADERS)
		var keys: Array = ACHIEVEMENT_KEYS if category == "achievements" else ENTRY_KEYS
		var result := CsvTextTable.read(str(paths.get(category, "")), headers, keys)
		_tables[category] = result.records
		_errors[category] = result.message
		if result.error != OK and first_error == OK:
			first_error = result.error
	catalog_changed.emit()
	return first_error


func error_message(category: String) -> String:
	return str(_errors.get(category, "未知图鉴类别"))


func entries(category: String, mode: DisplayMode = DisplayMode.ALL) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in _tables.get(category, []):
		var unlocked := is_unlocked(category, entry.id)
		if mode == DisplayMode.UNLOCKED and not unlocked:
			continue
		if mode == DisplayMode.LOCKED and unlocked:
			continue
		result.append(entry.duplicate(true))
	return result


func entry(category: String, id: String) -> Dictionary:
	for record: Dictionary in _tables.get(category, []):
		if record.id == id:
			return record.duplicate(true)
	return {}


func is_unlocked(category: String, id: String) -> bool:
	match category:
		"cards": return GlobalState.unlocked_cards.has(id)
		"fragments": return GlobalState.unlocked_fragments.has(id)
		"monsters": return GlobalState.unlocked_monsters.has(id)
		"achievements":
			var state: Variant = GlobalState.achievements.get(id, {})
			return state is Dictionary and bool(state.get("completed", false))
	return false


func display_name(category: String, id: String, fallback: String = "") -> String:
	var record := entry(category, id)
	return str(record.get("name", "")) if not record.is_empty() else fallback


## 游戏规则显式调用；CSV 不携带状态，文本不是自动判定条件/奖励脚本。
func unlock_entry(category: String, id: String) -> Error:
	if category not in ["cards", "fragments", "monsters"] or entry(category, id).is_empty():
		return ERR_INVALID_PARAMETER
	var error: Error = GlobalState.unlock_card(id) if category == "cards" else GlobalState.unlock_collection(category, id)
	return SaveGateway.save_current() if error == OK else error


func complete_achievement(id: String, metadata: Dictionary = {}) -> Error:
	if entry("achievements", id).is_empty():
		return ERR_INVALID_PARAMETER
	var error := GlobalState.complete_achievement(id, metadata)
	return SaveGateway.save_current() if error == OK else error


## 对话/事件 TXT 只作为纯文本，支持 {参数名} 替换，不执行 GDScript/BBCode。
func read_text(path: String, parameters: Dictionary = {}) -> Dictionary:
	if not path.begins_with("res://") or path.get_extension().to_lower() != "txt" or ".." in path:
		return {"error": ERR_INVALID_PARAMETER, "text": ""}
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

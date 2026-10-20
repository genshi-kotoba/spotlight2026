class_name CardEnchantments
extends RefCounted
## 正式表是运行时数据源；附魔只属于具体副本，不修改共享 CardData。
const TABLE_PATH := "res://data/cards/enchantments.json"
const MAX_SLOTS := 2
static var DEFINITIONS: Dictionary = _load_table()
static var _card_info: Dictionary = {}
static var _programs: Dictionary = {}

static func _load_table() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(TABLE_PATH))
	var result: Dictionary = data if data is Dictionary else {}
	# 已存档的测试附魔继续生效，但不会再从新附魔书/商店中抽出。
	result["damage_50"] = {"number": 0, "name": "锋锐（旧版）", "text": "直接伤害 +50%（向下取整）", "type": "全部", "symbol": "♂", "price": 100, "legacy": true}
	return result

static func reward_ids() -> Array:
	return DEFINITIONS.keys().filter(func(id: String): return not bool(DEFINITIONS[id].get("legacy", false)))

static func id_for(number: int) -> String:
	return {2: "repeat_2", 3: "damage_30"}.get(number, "enchant_%03d" % number)

static func has(card: Dictionary, number: int) -> bool:
	return card.get("enchantments", []).has(id_for(number))

static func valid(value: Variant) -> bool:
	if not value is Array or value.size() > MAX_SLOTS:
		return false
	var seen := {}
	for id: Variant in value:
		if not id is String or not DEFINITIONS.has(id) or seen.has(id):
			return false
		seen[id] = true
	return true

static func can_apply(card: Dictionary, id: String) -> bool:
	var current: Variant = card.get("enchantments", [])
	if not valid(current) or current.size() >= MAX_SLOTS or current.has(id) or not DEFINITIONS.has(id):
		return false
	var category := str(DEFINITIONS[id].get("type", "全部"))
	if category == "全部": return true
	_load_card_info()
	var card_id := str(card.get("card_id", ""))
	var kind := str(_card_info.get(card_id, {}).get("type", ""))
	if category == "攻击": return kind in ["伤害", "攻击"]
	if category in ["格挡，和存在格挡的攻击", "格挡，和存在格挡的攻击牌"]:
		return _contains_block(_programs.get(card_id, {}).get("instructions", []))
	return category == kind

static func _load_card_info() -> void:
	if not _card_info.is_empty(): return
	var table := CsvTextTable.read("res://data/text/cards.csv", TextCatalogService.CARD_HEADERS, TextCatalogService.CARD_KEYS)
	for record: Dictionary in table.get("records", []): _card_info[str(record.id)] = record
	var programs: Variant = JSON.parse_string(FileAccess.get_file_as_string(FormalCardCatalog.PROGRAM_PATH))
	if programs is Dictionary: _programs = programs

static func _contains_block(instructions: Array) -> bool:
	for instruction: Dictionary in instructions:
		if str(instruction.get("op", "")) == "block": return true
		if float(instruction.get("block_ratio", 0)) > 0: return true
		if instruction.get("body") is Array and _contains_block(instruction.body): return true
	return false

static func symbols(card: Dictionary) -> String:
	var result := PackedStringArray()
	for id: String in card.get("enchantments", []):
		if DEFINITIONS.has(id): result.append(str(DEFINITIONS[id].get("symbol", "")))
	return " ".join(result)

static func describe(card: Dictionary) -> String:
	var lines := PackedStringArray()
	for id: String in card.get("enchantments", []):
		if DEFINITIONS.has(id):
			lines.append("%s %s：%s" % [DEFINITIONS[id].get("symbol", ""), DEFINITIONS[id].name, DEFINITIONS[id].text])
	var text := "附魔（%d/2）\n%s" % [lines.size(), "\n".join(lines)] if not lines.is_empty() else "附魔（0/2）：无"
	if bool(card.get("one_shot", false)):
		text = "一次性卡牌 · 数值效果 %d%% · 使用后移除\n" % int(float(card.get("effect_scale", 1.0)) * 100) + text
	return text

class_name RelicCatalog
extends RefCounted

const DATA_PATH := "res://data/relics/test_fragments.csv"
const FORMAL_PATH := "res://data/relics/fragments.csv"
static var _cache: Dictionary = {}


static func load_definitions() -> Dictionary:
	if not _cache.is_empty():
		return _cache.duplicate()
	var result := {}
	for path: String in [DATA_PATH, FORMAL_PATH]:
		if not _read(path, result):
			return {}
	# 负面附着使用稳定复合ID，棋盘仍只存字符串，冷恢复不会丢失附着效果。
	var base := result.duplicate()
	for id: String in reward_ids(base):
		for curse: String in negative_ids(base):
			var data: RelicFragmentData = base[id].duplicate(true)
			data.fragment_id = id + "~" + curse
			data.base_fragment_id = id
			data.negative_action = base[curse].action_id
			data.description += "\n负面：" + base[curse].description
			result[data.fragment_id] = data
	_cache = result
	return result.duplicate()


static func reward_ids(catalog: Dictionary = {}) -> Array[String]:
	var values := load_definitions() if catalog.is_empty() else catalog
	var result: Array[String] = []
	for id: String in values:
		if id.begins_with("FRG-") and not id.contains("~") and values[id].kind != RelicFragmentData.Kind.NEGATIVE:
			result.append(id)
	result.sort()
	return result


static func negative_ids(catalog: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for id: String in catalog:
		if catalog[id].kind == RelicFragmentData.Kind.NEGATIVE:
			result.append(id)
	result.sort()
	return result


static func choice_bonus(cells: Array) -> int:
	var result := 0
	for id: String in cells:
		if id.get_slice("~", 0) == "FRG-021": result += 1
	return result


static func _read(path: String, result: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RelicCatalog: cannot open " + DATA_PATH)
		return false
	file.get_csv_line()
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() == 1 and row[0].is_empty():
			continue
		if row.size() != 8:
			push_error("RelicCatalog: invalid CSV row")
			return false
		var kinds := {"trigger": RelicFragmentData.Kind.TRIGGER,
			"effect": RelicFragmentData.Kind.EFFECT, "presence": RelicFragmentData.Kind.PRESENCE,
			"negative": RelicFragmentData.Kind.NEGATIVE}
		var reaches := {"none": RelicFragmentData.Reach.NONE,
			"four": RelicFragmentData.Reach.FOUR, "eight": RelicFragmentData.Reach.EIGHT,
			"row": RelicFragmentData.Reach.ROW, "column": RelicFragmentData.Reach.COLUMN,
			"vertical": RelicFragmentData.Reach.VERTICAL, "all": RelicFragmentData.Reach.ALL}
		if row[0].is_empty() or result.has(row[0]) or not kinds.has(row[3]) \
				or not reaches.has(row[5]) or not row[7].is_valid_int():
			push_error("RelicCatalog: invalid fragment " + row[0])
			return false
		var data := RelicFragmentData.new()
		data.fragment_id = row[0]
		data.display_name = row[1]
		data.description = row[2]
		data.kind = kinds[row[3]]
		data.event_id = row[4]
		data.reach = reaches[row[5]]
		data.action_id = row[6]
		data.amount = int(row[7])
		result[data.fragment_id] = data
	return true

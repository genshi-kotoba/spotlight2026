class_name RelicCatalog
extends RefCounted

const DATA_PATH := "res://data/relics/test_fragments.csv"
const FORMAL_PATH := "res://data/relics/fragments.csv"
# 仅保留旧存档 ID 的解析；不再进入生成池或拥有任何效果。
const RETIRED_IDS := ["FRG-021"]
const RUNTIME_LOG := preload("res://systems/diagnostics/runtime_log.gd")
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
	var compatible_ids := reward_ids(base)
	compatible_ids.append_array(RETIRED_IDS)
	for id: String in compatible_ids:
		if not base.has(id): continue
		for curse: String in negative_ids(base):
			var data: RelicFragmentData = base[id].duplicate(true)
			data.fragment_id = id + "~" + curse
			data.base_fragment_id = id
			data.negative_action = base[curse].action_id
			data.auxiliary_id = curse
			data.primary_description = data.description
			data.extra_description = base[curse].description
			data.description += "\n负面：" + base[curse].description
			result[data.fragment_id] = data
	_cache = result
	return result.duplicate()


static func reward_ids(catalog: Dictionary = {}) -> Array[String]:
	var values := load_definitions() if catalog.is_empty() else catalog
	var result: Array[String] = []
	for id: String in values:
		if id.begins_with("FRG-") and not id.contains("~") and id not in RETIRED_IDS and values[id].kind != RelicFragmentData.Kind.NEGATIVE:
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


## Self-describing, allowlisted ID; neither a save nor a caller can supply executable actions.
## Old FRG/test/composite IDs stay valid and are never rerolled on load.
static func resolve(id: String, definitions: Dictionary = {}) -> RelicFragmentData:
	if definitions.has(id):
		return definitions[id]
	var values := load_definitions()
	if values.has(id):
		return values[id]
	var parts := id.split("/", true)
	if parts.size() != 5 or parts[0] != "RF1" or not parts[3].is_valid_int():
		return null
	var color := int(parts[3])
	if str(color) != parts[3] or color < 0 or color >= RelicFragmentData.PALETTE.size() \
			or not values.has(parts[1]) or not values.has(parts[2]) or not values.has(parts[4]):
		return null
	var primary: RelicFragmentData = values[parts[1]]
	var named: RelicFragmentData = values[parts[2]]
	var auxiliary: RelicFragmentData = values[parts[4]]
	if not parts[1].begins_with("FRG-") or parts[1].contains("~") \
			or primary.kind not in [RelicFragmentData.Kind.TRIGGER, RelicFragmentData.Kind.EFFECT] \
			or not parts[2].begins_with("FRG-") or parts[2].contains("~") \
			or named.display_name.is_empty() or named.display_name == "暂无" \
			or not parts[4].begins_with("FRG-") or parts[4].contains("~") \
			or auxiliary.kind not in [RelicFragmentData.Kind.NEGATIVE, RelicFragmentData.Kind.PRESENCE]:
		return null
	var data: RelicFragmentData = primary.duplicate(true)
	data.fragment_id = id
	data.base_fragment_id = parts[1]
	data.name_fragment_id = parts[2]
	data.display_name = named.display_name
	data.color_index = color
	data.auxiliary_id = parts[4]
	data.primary_description = primary.description
	data.extra_description = auxiliary.description
	if auxiliary.kind == RelicFragmentData.Kind.NEGATIVE:
		data.negative_action = auxiliary.action_id
		data.description += "\n负面：" + auxiliary.description
	else:
		data.presence_action = auxiliary.action_id
		data.presence_event = auxiliary.event_id
		data.presence_amount = auxiliary.amount
		data.description += "\n在场：" + auxiliary.description
	return data


static func compose(primary_id: String, name_id: String, color_index: int, auxiliary_id: String) -> String:
	var id := "RF1/%s/%s/%d/%s" % [primary_id, name_id, color_index, auxiliary_id]
	return id if resolve(id) != null else ""


static func generate(rng: RandomStream, primary_id: String = "", auxiliary_id: String = "") -> String:
	if rng == null:
		return ""
	var values := load_definitions()
	var names: Array[String] = []
	var triggers: Array[String] = []
	var effects: Array[String] = []
	var presence: Array[String] = []
	for id: String in reward_ids(values):
		var data: RelicFragmentData = values[id]
		if data.display_name != "暂无" and not data.display_name.is_empty(): names.append(id)
		match data.kind:
			RelicFragmentData.Kind.TRIGGER: triggers.append(id)
			RelicFragmentData.Kind.EFFECT: effects.append(id)
			RelicFragmentData.Kind.PRESENCE: presence.append(id)
	# Main ability comes from the trigger/effect pool; the other rolls are independent.
	triggers.append_array(effects)
	if primary_id.is_empty(): primary_id = str(rng.pick(triggers))
	if auxiliary_id.is_empty(): auxiliary_id = str(rng.pick(negative_ids(values) if int(rng.int_range(0, 100)) < 70 else presence))
	return compose(primary_id, str(rng.pick(names)), int(rng.int_range(0, RelicFragmentData.PALETTE.size())), auxiliary_id)


static func _read(path: String, result: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		RUNTIME_LOG.event("data.load_fail", {"category": "relics", "path": path,
			"error": FileAccess.get_open_error(), "message": "cannot open"})
		push_error("RelicCatalog: cannot open " + DATA_PATH)
		return false
	file.get_csv_line()
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() == 1 and row[0].is_empty():
			continue
		if row.size() != 8:
			RUNTIME_LOG.event("data.load_fail", {"category": "relics", "path": path,
				"error": ERR_INVALID_DATA, "message": "row has %d cells" % row.size()})
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
			var detail := "invalid fragment " + (row[0] if not row[0].is_empty() else "<empty>")
			RUNTIME_LOG.event("data.load_fail", {"category": "relics", "path": path,
				"error": ERR_INVALID_DATA, "message": detail})
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
		if data.fragment_id in RETIRED_IDS:
			data.description = "此残片效果已移除"
			data.event_id = ""
			data.action_id = ""
			data.amount = 0
		result[data.fragment_id] = data
	return true

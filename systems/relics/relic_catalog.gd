class_name RelicCatalog
extends RefCounted

const DATA_PATH := "res://data/relics/test_fragments.csv"


static func load_definitions() -> Dictionary:
	var result := {}
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		push_error("RelicCatalog: cannot open " + DATA_PATH)
		return result
	file.get_csv_line()
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() == 1 and row[0].is_empty():
			continue
		if row.size() != 8:
			push_error("RelicCatalog: invalid CSV row")
			return {}
		var kinds := {"trigger": RelicFragmentData.Kind.TRIGGER,
			"effect": RelicFragmentData.Kind.EFFECT, "presence": RelicFragmentData.Kind.PRESENCE}
		var reaches := {"none": RelicFragmentData.Reach.NONE,
			"four": RelicFragmentData.Reach.FOUR, "eight": RelicFragmentData.Reach.EIGHT}
		if row[0].is_empty() or result.has(row[0]) or not kinds.has(row[3]) \
				or not reaches.has(row[5]) or not row[7].is_valid_int() or int(row[7]) < 0:
			push_error("RelicCatalog: invalid fragment " + row[0])
			return {}
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
	return result

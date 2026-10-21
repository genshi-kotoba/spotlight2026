extends Node
## Runs against both editor resources and the actual exported resource pack.
var failures := 0
var checks := 0

func _ready() -> void:
	call_deferred("_run")

func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("EXPORT_CONTENT_FAIL " + label)

func _run() -> void:
	var header := "编号,卡图资源路径,卡名,效果文本,类型,文本,稀有度\n"
	for prefix: String in ["", String.chr(0xFEFF)]:
		var parsed := CsvTextTable.parse(prefix + header + "1,res://icon.svg,测试,暂无,伤害,暂无,普通\n", TextCatalog.CARD_HEADERS, TextCatalog.CARD_KEYS)
		_check("CSV first character and optional BOM", parsed.error == OK and parsed.records.size() == 1 and parsed.records[0].id == "1")
	_check("empty CSV rejected", CsvTextTable.parse("", TextCatalog.CARD_HEADERS, TextCatalog.CARD_KEYS).error != OK)
	_check("catalog reload", TextCatalog.reload() == OK)
	var resolver := BattleEffectResolver.new()
	_check("exported card and buff resource discovery", resolver._load_catalogs() == OK)
	for buff_id: String in ["strength", "weak", "poison"]:
		_check("buff definition " + buff_id, resolver.buff_catalog.has(buff_id))
	_check("test card definitions survive remapping", resolver.card_catalog.has("test_block"))
	resolver.free()
	var expected := {"cards": 70, "fragments": 32, "monsters": 23, "items": 7}
	for category: String in TextCatalog.CATEGORIES:
		var entries := TextCatalog.entries(category)
		_check(category + " count", entries.size() == int(expected[category]))
		for entry: Dictionary in entries:
			var art := str(entry.get("art_path", entry.get("icon_path", "")))
			if not art.is_empty() and art != "暂无":
				_check(category + " art " + art, TextCatalog.art_texture(art) != null)
			if category == "monsters":
				var path := str(entry.battle_text_path)
				var text := TextCatalog.read_text(path)
				_check("monster TXT " + path, text.error == OK and not str(text.text).strip_edges().is_empty())
	for path: String in ["res://data/config/main_menu_new_run.json", "res://data/config/encounter_test_rules.json", "res://data/text/items.csv", "res://wwise_soundbanks/Windows/Init.bnk", "res://wwise_soundbanks/Android/Init.bnk"]:
		_check("raw data " + path, FileAccess.file_exists(path))
	for floor_index: int in range(1, 5):
		_check("battle background " + str(floor_index), preload("res://ui/battle/battle_environment.gd").texture_for_floor(floor_index) != null)
		var theme := preload("res://systems/map/relief_2d/map_art_themes.gd").for_floor(floor_index)
		_check("map theme does not silently fall back " + str(floor_index), str(theme.fallback_reason).is_empty())
		var atlas := Image.new()
		_check("map CPU atlas bytes " + str(floor_index), atlas.load_png_from_buffer(FileAccess.get_file_as_bytes(str(theme.atlas))) == OK and not atlas.is_empty())
	for path: String in ["res://assets/environment/env005/atmosphere-cloud.png", "res://assets/map_nodes/alchemy/battle.png", "res://assets/map_nodes/alchemy/question.png"]:
		_check("raw map PNG " + path, FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path).size() > 0)
	print("EXPORT_CONTENT_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

extends RefCounted
## Floor appearance is presentation-only. Resolve CPU paths without loading
## textures or consuming any gameplay/random stream state.
const CONFIG_PATH := "res://data/config/relief_2d/art_themes.json"
const DEFAULT_ATLAS := "res://assets/environment/env005/env005-atlas.png"
const DEFAULT_MANIFEST := "res://assets/environment/env005/manifest.json"

static func fallback(reason: String = "") -> Dictionary:
	return {"id":"alchemy","asset_id":"ENV-005","atlas":DEFAULT_ATLAS,"manifest":DEFAULT_MANIFEST,"fallback_reason":reason}

static func for_floor(floor_index: int) -> Dictionary:
	if not FileAccess.file_exists(CONFIG_PATH): return fallback("Theme config missing")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not parsed is Dictionary: return fallback("Invalid theme config JSON")
	var floors: Variant = parsed.get("floors")
	var themes: Variant = parsed.get("themes")
	if not floors is Dictionary or not themes is Dictionary: return fallback("Invalid theme config tables")
	var id: Variant = floors.get(str(floor_index))
	if not id is String or id.is_empty(): return fallback("No theme for floor %d" % floor_index)
	var definition: Variant = themes.get(id)
	if not definition is Dictionary: return fallback("Missing theme: " + id)
	var asset_id: Variant = definition.get("asset_id")
	if not asset_id is String or asset_id.is_empty(): return fallback("Invalid asset id: " + id)
	for field: String in ["atlas","manifest"]:
		var path: Variant = definition.get(field)
		if not path is String or not path.begins_with("res://") or not FileAccess.file_exists(path):
			return fallback("Missing theme %s: %s" % [field,id])
	return {"id":id,"asset_id":asset_id,"atlas":definition.atlas,"manifest":definition.manifest,"fallback_reason":""}

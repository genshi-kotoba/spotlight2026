class_name FormalCardCatalog
extends RefCounted

const PROGRAM_PATH := "res://data/cards/formal/programs.json"
## These cards remain playable when granted by an event or enemy, but are not normal rewards.
const NEGATIVE_CARD_IDS := ["68", "69", "70"]

static func load_definitions() -> Dictionary:
	var table := CsvTextTable.read("res://data/text/cards.csv", TextCatalogService.CARD_HEADERS, TextCatalogService.CARD_KEYS)
	var programs: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROGRAM_PATH))
	if table.error != OK or not programs is Dictionary:
		return {"error": ERR_INVALID_DATA, "cards": {}}
	var catalog: Dictionary = {}
	for record: Dictionary in table.records:
		if not programs.has(record.id) or not programs[record.id] is Dictionary:
			return {"error": ERR_INVALID_DATA, "cards": {}}
		var definition: Dictionary = programs[record.id]
		var card := CardData.new()
		card.card_id = StringName(record.id)
		card.card_name = record.name
		card.description = record.effect
		card.art_path = record.art_path
		card.flavor_text = record.text
		card.rarity = CardData.Rarity.RARE if record.rarity == "稀有" else CardData.Rarity.COMMON
		card.kind = {"伤害": CardData.Kind.DAMAGE, "buff": CardData.Kind.BUFF,
			"移位": CardData.Kind.SHIFT, "特殊": CardData.Kind.SPECIAL}.get(record.type, CardData.Kind.SPECIAL)
		card.face_tint = CardData.face_tint_for_type(str(record.type))
		card.implementation_status = str(definition.get("status", "ready"))
		card.occupies_slot = bool(definition.get("occupies_slot", true))
		var effect := CardEffectProgram.new()
		effect.instructions.assign(definition.get("instructions", []))
		card.effects.append(effect)
		catalog[record.id] = card
	return {"error": OK, "cards": catalog}

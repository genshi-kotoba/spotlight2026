class_name RelicSlotButton
extends Button

signal dropped(destination: int, payload: Dictionary)

var cell_index := -1
var fragment_id := ""


func _get_drag_data(_position: Vector2) -> Variant:
	if fragment_id.is_empty():
		return null
	var preview := Label.new()
	preview.text = text
	preview.add_theme_font_size_override("font_size", 23)
	set_drag_preview(preview)
	return {"relic_drag": true, "source": cell_index, "fragment_id": fragment_id}


func _can_drop_data(_position: Vector2, payload: Variant) -> bool:
	return cell_index >= 0 and payload is Dictionary and payload.get("relic_drag") == true \
		and payload.get("fragment_id") is String


func _drop_data(_position: Vector2, payload: Variant) -> void:
	dropped.emit(cell_index, payload)

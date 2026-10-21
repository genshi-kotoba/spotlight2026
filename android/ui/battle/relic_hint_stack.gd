class_name RelicHintStack
extends VBoxContainer

## 典籍触发的提示条：挂在书页下方，触发一次往下堆一条。
##
## 每条各自计时，到时淡出后自己退场，后到的提示不顶掉先到的；
## 条数超过上限时最上面那条立即退休，免得长连锁把书页下面堆满。
## 只负责堆与退场，文案由战斗场景给。

const LIFETIME := 4.0
const FADE_OUT := 0.35
const MAX_ROWS := 5
const WIDTH := 240.0
## 高度按上限预留，行按最小高度从顶部往下排，超出部分不裁切。
const HEIGHT := 220.0
const FONT_SIZE := 16
const TEXT_COLOR := Color(0.749, 0.682, 0.553)


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_BEGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 3)
	size = Vector2(WIDTH, HEIGHT)


## 推一条提示。需要看久一点的提示（例如开局引导）传更长的 lifetime。
func push(text: String, lifetime := LIFETIME) -> void:
	if text.strip_edges().is_empty():
		return
	var row := _make_row(text)
	add_child(row)
	while get_child_count() > MAX_ROWS:
		var eldest := get_child(0)
		remove_child(eldest)
		eldest.queue_free()
	var tween := row.create_tween()
	tween.tween_interval(lifetime)
	tween.tween_property(row, "modulate:a", 0.0, FADE_OUT)
	tween.tween_callback(row.queue_free)


func _make_row(text: String) -> Label:
	var row := Label.new()
	row.text = text
	row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_font_size_override("font_size", FONT_SIZE)
	row.add_theme_color_override("font_color", TEXT_COLOR)
	row.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	row.add_theme_constant_override("shadow_offset_x", 1)
	row.add_theme_constant_override("shadow_offset_y", 1)
	return row

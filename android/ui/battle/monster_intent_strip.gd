class_name MonsterIntentStrip
extends Control
## 一个行动一个小图标。动数独立显示，伤害下标中的 × 只表示连击。

signal hint_requested(anchor: Control, text: String)
signal hint_hidden(source: MonsterIntentStrip)

const INK := Color("ffe0ca")
const GOLD := Color("e5be76")
var action_count_label: Label
var cells: Array[Control] = []
var _signature := ""
var _hovered: Control

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	action_count_label = _label("", 18, GOLD)
	action_count_label.name = "ActionCount"
	action_count_label.position = Vector2(0, 19)
	action_count_label.size = Vector2(44, 26)
	add_child(action_count_label)
	size = Vector2(104, 62)

func show_preview(preview: Dictionary) -> void:
	var signature := JSON.stringify(preview)
	if signature == _signature: return
	_signature = signature
	if _hovered != null: hint_hidden.emit(self)
	_hovered = null
	for cell: Control in cells:
		remove_child(cell)
		cell.queue_free()
	cells.clear()
	var ready := bool(preview.get("ready", false))
	action_count_label.text = "%d动" % int(preview.get("action_count", 0)) if ready else "…"
	action_count_label.set_meta("hint", _round_hint(preview))
	for action: Dictionary in preview.get("actions", []):
		_add_action(action)
	for trigger: String in preview.get("triggers", []):
		_add_cell(["special"], "!", "回合触发\n" + trigger, true)
	if cells.is_empty():
		_add_cell(["special"], "—" if ready else "?", "本回合不行动" if ready else "意图准备中")
	size = Vector2(48 + cells.size() * 62, 62)

func _add_action(action: Dictionary) -> void:
	var kinds: Array = action.get("kinds", ["special"])
	var metric := ""
	if int(action.get("damage", -1)) >= 0:
		metric = _range(int(action.damage), int(action.get("damage_max", action.damage)))
		if int(action.get("hits", 1)) > 1: metric += "×%d" % int(action.hits)
	elif int(action.get("block", -1)) >= 0:
		metric = _range(int(action.block), int(action.get("block_max", action.block)))
	elif str(action.get("summary", "")).contains("随机"):
		metric = "随机"
	var text := "第%d动：%s" % [int(action.get("index", cells.size() + 1)), str(action.get("summary", "特殊"))]
	if int(action.get("hits", 1)) > 1: text += "\n连击 %d 次（仍为 1 动）" % int(action.hits)
	if not str(action.get("detail", "")).is_empty(): text += "\n" + str(action.detail)
	_add_cell(kinds, metric, text)

func _add_cell(kinds: Array, metric: String, hint: String, trigger: bool = false) -> void:
	var cell := Control.new()
	cell.name = "Trigger" if trigger else "Action%d" % (cells.size() + 1)
	cell.position = Vector2(48 + cells.size() * 62, 0)
	cell.size = Vector2(62, 62)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.set_meta("hint", hint)
	cell.set_meta("kinds", kinds.duplicate())
	add_child(cell)
	cells.append(cell)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = MonsterIntentBoard.icon_for(str(kinds[0]) if not kinds.is_empty() else "special")
	icon.position = Vector2(11, 0)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size = Vector2(40, 40)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(icon)
	# 复合行动保留第二种效果的角标，仍只占一个行动位置。
	for index in range(1, kinds.size()):
		var secondary := TextureRect.new()
		secondary.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		secondary.texture = MonsterIntentBoard.icon_for(str(kinds[index]))
		secondary.position = Vector2(39, 20 - (index - 1) * 16)
		secondary.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		secondary.size = Vector2(22, 22)
		secondary.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(secondary)
	var value := _label(metric, 21 if metric.length() <= 5 else 18, INK)
	value.name = "Value"
	value.position = Vector2(0, 36)
	value.size = Vector2(62, 26)
	cell.add_child(value)

func _process(_delta: float) -> void:
	# 后排意图可以位于主怪透明或不透明区域，悬停检测与实体选中分离。
	var next: Control
	var hovered := get_viewport().gui_get_hovered_control()
	var battlefield := get_parent().get_parent().get_parent()
	var unobstructed := hovered == null or hovered is EnemySlot or hovered is EnemyRack or hovered == battlefield
	if is_visible_in_tree() and unobstructed:
		var point := get_local_mouse_position()
		if action_count_label.get_rect().has_point(point): next = action_count_label
		for cell: Control in cells:
			if cell.get_rect().has_point(point): next = cell
	if next == _hovered: return
	_hovered = next
	if next == null: hint_hidden.emit(self)
	else: hint_requested.emit(next, str(next.get_meta("hint", "")))

func _exit_tree() -> void:
	if _hovered != null: hint_hidden.emit(self)

static func _round_hint(preview: Dictionary) -> String:
	if not bool(preview.get("ready", false)): return "意图准备中"
	var lines: Array[String] = ["本回合 %d 动，图标从左到右依次执行" % int(preview.get("action_count", 0))]
	for action: Dictionary in preview.get("actions", []):
		lines.append("%d. %s" % [int(action.get("index", 1)), str(action.get("summary", ""))])
	for trigger: String in preview.get("triggers", []): lines.append(trigger)
	return "\n".join(lines)

static func _range(low: int, high: int) -> String:
	return str(low) if low == high else "%d–%d" % [low, high]

static func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color("171512"))
	label.add_theme_constant_override("outline_size", 7)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

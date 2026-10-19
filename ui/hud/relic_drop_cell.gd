class_name RelicDropCell
extends Control

## 背包页典籍区的一格。装上的残片还要能继续搬，所以这一格本身也能起拖：
## 只负责报「这里有一份残片，被按下了」，落点判定和存盘由宿主决定。
## 按住 Shift 点一下是「退回背包」，不走进拖拽。

signal drag_requested(source: Control, fragment_id: String)
signal remove_requested(index: int)

var index := 0
var fragment_id := ""
var editable := true
var unlocked := true

var _highlight: Panel
var _range_highlight: Panel
var _locked_cover: Panel
static var _locked_piece_material: ShaderMaterial


func _ready() -> void:
	_range_highlight = Panel.new()
	_range_highlight.name = "RangeHighlight"
	_range_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_range_highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_range_highlight.visible = false
	var range_style := StyleBoxFlat.new()
	range_style.bg_color = Color(0.40, 0.77, 1.0, 0.24)
	range_style.border_color = Color(0.53, 0.85, 1.0, 0.96)
	range_style.set_border_width_all(2)
	range_style.set_corner_radius_all(4)
	_range_highlight.add_theme_stylebox_override("panel", range_style)
	add_child(_range_highlight)

	_locked_cover = Panel.new()
	_locked_cover.name = "LockedCover"
	_locked_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_locked_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 灰显直接作用在拼片 alpha 轮廓上，不再用一块常驻矩形盖住拼片。
	_locked_cover.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var locked_label := Label.new()
	locked_label.text = "未解锁"
	locked_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	locked_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	locked_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	locked_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	locked_label.add_theme_font_size_override("font_size", 16)
	locked_label.add_theme_color_override("font_color", Color(0.63, 0.64, 0.66))
	_locked_cover.add_child(locked_label)
	add_child(_locked_cover)
	set_unlocked(unlocked)

	# 拖拽时把「松手会落在这里」的那一格点出来。
	_highlight = Panel.new()
	_highlight.name = "Highlight"
	_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_highlight.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.87, 0.55, 0.20)
	style.border_color = Color(1.0, 0.87, 0.55, 0.95)
	style.set_border_width_all(3)
	style.set_corner_radius_all(4)
	_highlight.add_theme_stylebox_override("panel", style)
	add_child(_highlight)


func set_highlight(on: bool) -> void:
	if _highlight != null:
		_highlight.visible = on and unlocked


func set_range_highlight(on: bool) -> void:
	if _range_highlight != null:
		_range_highlight.visible = on and unlocked


func set_unlocked(value: bool) -> void:
	unlocked = value
	if _locked_cover != null:
		_locked_cover.visible = not unlocked
	var piece := get_node_or_null("PieceArt") as TextureRect
	if piece != null:
		piece.material = null if unlocked else _locked_material()
	if not unlocked:
		set_highlight(false)
		set_range_highlight(false)


static func _locked_material() -> ShaderMaterial:
	if _locked_piece_material == null:
		var shader := Shader.new()
		shader.code = """shader_type canvas_item;
void fragment() {
	float gray = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	COLOR.rgb = vec3(gray * 0.48);
}
"""
		_locked_piece_material = ShaderMaterial.new()
		_locked_piece_material.shader = shader
	return _locked_piece_material


func _gui_input(event: InputEvent) -> void:
	if not editable or not unlocked:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and fragment_id.is_empty():
		drag_requested.emit(self, fragment_id)
		accept_event()
		return
	if fragment_id.is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		remove_requested.emit(index)
		accept_event()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.shift_pressed:
			remove_requested.emit(index)
		else:
			drag_requested.emit(self, fragment_id)
		accept_event()

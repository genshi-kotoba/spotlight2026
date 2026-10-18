class_name RelicDropCell
extends Control

## 背包页典籍区的一格。装上的残片还要能继续搬，所以这一格本身也能起拖：
## 只负责报「这里有一份残片，被按下了」，落点判定和存盘由宿主决定。
## 按住 Shift 点一下是「退回背包」，不走进拖拽。

signal drag_requested(source: Control, fragment_id: String)
signal remove_requested(index: int)

var index := 0
var fragment_id := ""

var _highlight: Panel


func _ready() -> void:
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
		_highlight.visible = on


func _gui_input(event: InputEvent) -> void:
	if fragment_id.is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.shift_pressed:
			remove_requested.emit(index)
		else:
			drag_requested.emit(self, fragment_id)
		accept_event()

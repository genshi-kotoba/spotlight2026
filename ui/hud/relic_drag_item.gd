class_name RelicDragItem
extends Control

## 背包栏位里的一份典籍残片。按下就把拖拽交给宿主：
## 跟随鼠标的残片块、落点判定、原位置空都由宿主做，组件只报意图。

signal drag_requested(source: Control, fragment_id: String)

var fragment_id := ""
var item_id := ""
var editable := true

var _name_label: Label


func set_name_label(label: Label) -> void:
	_name_label = label


## 抬起来的时候只把名字藏掉，格子的底和框留着 —— 那一格还在，不是凭空少一块。
func set_lifted(lifted: bool) -> void:
	if _name_label != null and is_instance_valid(_name_label):
		_name_label.visible = not lifted


func _gui_input(event: InputEvent) -> void:
	if fragment_id.is_empty() or not editable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		drag_requested.emit(self, fragment_id)
		accept_event()

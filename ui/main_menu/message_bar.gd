extends Panel

## 轻量提示条。存盘失败这类事情只在底部冒一条，不弹独立窗口。
## 几何与字号写在场景里，脚本只管显示哪句话、什么时候收起来。

## 一条提示停留多久，秒。
@export var stay_seconds: float = 4.0

@onready var _label: Label = $文本

var _token := 0


func show_message(text: String) -> void:
	_label.text = text
	visible = true
	_token += 1
	var token := _token
	await get_tree().create_timer(stay_seconds).timeout
	if token == _token:
		visible = false

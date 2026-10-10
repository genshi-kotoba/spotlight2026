extends Control

## 覆盖 / 删除确认弹窗。只做「问一句、把结果发出去」，文案与几何都在场景里。
## 用自绘面板而不是 AcceptDialog，是为了让按钮文案（覆盖 / 删除）能由调用方给。

signal accepted
signal dismissed

@onready var _title_label: Label = $面板/标题
@onready var _body_label: Label = $面板/正文
@onready var _ok_button: Button = $面板/按钮行/确定
@onready var _cancel_button: Button = $面板/按钮行/取消


func _ready() -> void:
	_ok_button.pressed.connect(_on_ok_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	visible = false


## ok_text 是确认按钮上的字：覆盖 / 删除。
func ask(title_text: String, body_text: String, ok_text: String) -> void:
	_title_label.text = title_text
	_body_label.text = body_text
	_ok_button.text = ok_text
	visible = true


func _on_ok_pressed() -> void:
	visible = false
	accepted.emit()


func _on_cancel_pressed() -> void:
	visible = false
	dismissed.emit()

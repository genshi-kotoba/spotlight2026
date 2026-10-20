extends Control

## 新游戏覆盖确认弹窗；只负责展示询问、发出确认或取消信号。

signal accepted
signal dismissed

@onready var _title_label: Label = $面板/标题
@onready var _body_label: Label = $面板/正文
@onready var _ok_button: Button = $面板/按钮行/确定
@onready var _cancel_button: Button = $面板/按钮行/取消


func _ready() -> void:
	$面板.add_theme_stylebox_override("panel", CommonUiSkin.panel("small"))
	CommonUiSkin.style_button(_ok_button)
	CommonUiSkin.style_button(_cancel_button)
	_title_label.add_theme_color_override("font_color", CommonUiSkin.TEXT)
	_body_label.add_theme_color_override("font_color", CommonUiSkin.TEXT)
	_ok_button.pressed.connect(_on_ok_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	visible = false


## ok_text 是确认按钮上的文案。
func ask(title_text: String, body_text: String, ok_text: String) -> void:
	_title_label.text = title_text
	_body_label.text = body_text
	_ok_button.text = ok_text
	visible = true
	_cancel_button.grab_focus()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		_on_cancel_pressed()
		get_viewport().set_input_as_handled()


func _on_ok_pressed() -> void:
	visible = false
	accepted.emit()


func _on_cancel_pressed() -> void:
	visible = false
	dismissed.emit()

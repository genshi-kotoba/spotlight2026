extends Control

## 设置界面。六项都存进 SaveGateway 自持的全局文件，与档案无关：删档不会清掉它们。
## 音频三项现在只存不用（PRG-015 在第三周）；分辨率改的是窗口大小，全屏时置灰。

@export var volume_max: float = 100.0
## 下拉里给的三档。界面不解释这些数，只把选中的字串存回去，改档位不用动代码。
@export var resolutions: PackedStringArray = ["1920x1080", "1600x900", "1280x720"]
@export var main_menu_scene: String = "res://ui/main_menu/main_menu.tscn"

@onready var _master_slider: HSlider = $面板/条目/主音量/滑条
@onready var _master_value: Label = $面板/条目/主音量/数值
@onready var _music_slider: HSlider = $面板/条目/音乐/滑条
@onready var _music_value: Label = $面板/条目/音乐/数值
@onready var _sfx_slider: HSlider = $面板/条目/音效/滑条
@onready var _sfx_value: Label = $面板/条目/音效/数值
@onready var _fullscreen_button: CheckButton = $面板/条目/全屏/开关
@onready var _resolution_button: OptionButton = $面板/条目/分辨率/下拉
@onready var _back_button: Button = $面板/条目/返回
@onready var _message_bar: Panel = $提示条

var _gateway: Node = null


func _ready() -> void:
	_gateway = get_node_or_null("/root/SaveGateway")
	for slider: HSlider in [_master_slider, _music_slider, _sfx_slider]:
		slider.min_value = 0.0
		slider.max_value = volume_max
		slider.step = 1.0
	_resolution_button.clear()
	for item: String in resolutions:
		_resolution_button.add_item(item)
	_load_from_gateway()

	# 先铺值再连信号：否则铺值本身会被当成一次改动写回去。
	_master_slider.value_changed.connect(_on_master_changed)
	_music_slider.value_changed.connect(_on_music_changed)
	_sfx_slider.value_changed.connect(_on_sfx_changed)
	_fullscreen_button.toggled.connect(_on_fullscreen_toggled)
	_resolution_button.item_selected.connect(_on_resolution_selected)
	_back_button.pressed.connect(_on_back_pressed)
	if _gateway != null:
		_gateway.save_failed.connect(_on_save_failed)


func _load_from_gateway() -> void:
	if _gateway == null:
		return
	_master_slider.value = float(_gateway.get_setting("master_volume", volume_max))
	_music_slider.value = float(_gateway.get_setting("music_volume", volume_max))
	_sfx_slider.value = float(_gateway.get_setting("sfx_volume", volume_max))
	_fullscreen_button.button_pressed = bool(_gateway.get_setting("fullscreen", true))
	_select_resolution(String(_gateway.get_setting("resolution", _first_resolution())))
	_update_volume_labels()
	_update_resolution_state()


func _first_resolution() -> String:
	if resolutions.is_empty():
		return ""
	return resolutions[0]


func _select_resolution(text: String) -> void:
	for index in _resolution_button.item_count:
		if _resolution_button.get_item_text(index) == text:
			_resolution_button.select(index)
			return


func _update_volume_labels() -> void:
	_master_value.text = "%d" % int(_master_slider.value)
	_music_value.text = "%d" % int(_music_slider.value)
	_sfx_value.text = "%d" % int(_sfx_slider.value)


## 全屏时窗口大小没有意义，分辨率下拉跟着置灰。
func _update_resolution_state() -> void:
	_resolution_button.disabled = _fullscreen_button.button_pressed


func _store(key: String, value: Variant) -> void:
	if _gateway == null:
		return
	# 写失败走 save_failed，由提示条显示，这里不重复弹窗。
	if _gateway.set_setting(key, value) != OK:
		return


func _on_master_changed(value: float) -> void:
	_master_value.text = "%d" % int(value)
	_store("master_volume", int(value))


func _on_music_changed(value: float) -> void:
	_music_value.text = "%d" % int(value)
	_store("music_volume", int(value))


func _on_sfx_changed(value: float) -> void:
	_sfx_value.text = "%d" % int(value)
	_store("sfx_volume", int(value))


func _on_fullscreen_toggled(pressed: bool) -> void:
	_update_resolution_state()
	_store("fullscreen", pressed)


func _on_resolution_selected(index: int) -> void:
	_store("resolution", _resolution_button.get_item_text(index))


func _on_save_failed(_error: int, message: String) -> void:
	_message_bar.show_message(message)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(main_menu_scene)

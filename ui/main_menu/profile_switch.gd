extends Control

## 切换档案屏。选中态与当前档是两个概念：选中是正要切过去的那一档，
## 当前是现在生效的那一档（卡片右下角标「当前档案」）。
## 卡片上的三态与数值全部来自 SaveGateway.list_slots()，界面自己不算。

@export var main_menu_scene: String = "res://ui/main_menu/main_menu.tscn"
@export var empty_slot_notice: String = "空档案没有可删的东西"

@onready var _cards: Array[SlotCard] = [$卡片行/档案卡1, $卡片行/档案卡2, $卡片行/档案卡3]
@onready var _switch_button: Button = $按钮行/切换档案
@onready var _delete_button: Button = $按钮行/删除存档
@onready var _message_bar: Panel = $提示条
@onready var _dialog: Control = $确认弹窗

var _gateway: Node = null
var _slots: Array = []
var _selected := 1
var _pending_delete := false


func _ready() -> void:
	_gateway = get_node_or_null("/root/SaveGateway")
	for index in _cards.size():
		var slot := index + 1
		_cards[index].pressed.connect(_on_card_pressed.bind(slot))
	_switch_button.pressed.connect(_on_switch_pressed)
	_delete_button.pressed.connect(_on_delete_pressed)
	$按钮行/返回.pressed.connect(_return_to_menu)
	_dialog.accepted.connect(_on_delete_confirmed)
	_dialog.dismissed.connect(func(): _pending_delete = false)
	if _gateway != null:
		_gateway.save_failed.connect(_on_save_failed)
		_gateway.slots_refreshed.connect(refresh)
		_selected = int(_gateway.get_active_slot())
	refresh()


func refresh() -> void:
	if _gateway == null:
		# 没有网关时把这张屏的动作全停掉，卡片保持场景里的空态。
		_switch_button.disabled = true
		_delete_button.disabled = true
		return
	_slots = _gateway.list_slots()
	var current := int(_gateway.get_active_slot())
	for index in _cards.size():
		var slot := index + 1
		_cards[index].setup(slot_info(slot), slot == current)
	select_slot(_selected)


## 选中某一档：只有它带选中态，其余取消。
func select_slot(slot: int) -> void:
	_selected = clampi(slot, 1, _cards.size())
	for index in _cards.size():
		_cards[index].button_pressed = (index + 1) == _selected
	_delete_button.disabled = not slot_exists(_selected)


func slot_info(slot: int) -> Dictionary:
	for item: Variant in _slots:
		if item is Dictionary and int((item as Dictionary).get("slot", 0)) == slot:
			return item as Dictionary
	return {"slot": slot, "exists": false, "state": "empty"}


func slot_exists(slot: int) -> bool:
	return bool(slot_info(slot).get("exists", false))


func _on_card_pressed(slot: int) -> void:
	select_slot(slot)


func _on_switch_pressed() -> void:
	var error: Error = _gateway.set_active_slot(_selected)
	if error != OK:
		return
	_return_to_menu()


func _return_to_menu() -> void:
	var error := get_tree().change_scene_to_file(main_menu_scene)
	if error != OK:
		_message_bar.show_message("返回开始界面失败：%d" % error)


func _on_delete_pressed() -> void:
	if not slot_exists(_selected):
		_message_bar.show_message(empty_slot_notice)
		return
	_pending_delete = true
	_dialog.ask("删除档案 %d？" % _selected, SlotCard.summary_text(slot_info(_selected)), "删除")


func _on_delete_confirmed() -> void:
	if not _pending_delete:
		return
	_pending_delete = false
	var error: Error = _gateway.delete_slot(_selected)
	if error != OK:
		return
	refresh()


func _on_save_failed(_error: int, message: String) -> void:
	_message_bar.show_message(message)

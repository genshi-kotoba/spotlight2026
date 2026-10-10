extends Control

## 开始界面。只做三件事：把按钮接到 SaveGateway、把网关读到的状态画到屏上、失败时报提示条。
## 它不判任何游戏状态：有没有可继续的局问网关，开局之后的事归状态机。

## 薄装配层复用 main 的地图视图、生成器和存档状态机，不导入占位玩法。
@export var game_scene: String = "res://ui/main_menu/menu_map_entry.tscn"
@export var settings_scene: String = ""
@export var new_run_config_path := "res://data/config/main_menu_new_run.json"
@export var profile_scene: String = "res://ui/main_menu/profile_switch.tscn"
@export var achievements_scene := "res://ui/catalog/achievements.tscn"
@export var encyclopedia_scene := "res://ui/catalog/encyclopedia.tscn"
@export var credits_notice: String = "感谢名单页还没做"

@onready var _continue_button: Button = $按钮列/继续游戏
@onready var _new_game_button: Button = $按钮列/新游戏
@onready var _settings_button: Button = $按钮列/设置
@onready var _achievements_button: Button = $按钮列/成就
@onready var _encyclopedia_button: Button = $按钮列/图鉴
@onready var _credits_button: Button = $按钮列/感谢名单
@onready var _quit_button: Button = $按钮列/退出游戏
@onready var _profile_button: Button = $档案
@onready var _message_bar: Panel = $提示条
@onready var _dialog: Control = $确认弹窗

var _gateway: Node = null
var _pending_new_run := false


func _ready() -> void:
	_gateway = get_node_or_null("/root/SaveGateway")
	_continue_button.pressed.connect(_on_continue_pressed)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_profile_button.pressed.connect(_on_profile_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_achievements_button.pressed.connect(func(): _change_scene(achievements_scene))
	_encyclopedia_button.pressed.connect(func(): _change_scene(encyclopedia_scene))
	_credits_button.pressed.connect(_show_credits_notice)
	_dialog.accepted.connect(_on_overwrite_accepted)
	_dialog.dismissed.connect(func(): _pending_new_run = false)
	if _gateway != null:
		_gateway.save_failed.connect(_on_save_failed)
		_gateway.active_slot_changed.connect(_on_gateway_changed)
		_gateway.slots_refreshed.connect(_on_gateway_changed)
	refresh()


## 把网关的状态铺到屏上。当前档与「继续游戏」的可用性都只问网关。
func refresh() -> void:
	if _gateway == null:
		# 没登记 autoload 时把靠它的入口全置灰，不留会崩的按钮。
		_continue_button.disabled = true
		_new_game_button.disabled = true
		_quit_button.disabled = true
		_profile_button.disabled = true
		_profile_button.text = "当前档案 — ▾"
		return
	_profile_button.text = "当前档案 %d ▾" % int(_gateway.get_active_slot())
	_continue_button.disabled = not bool(_gateway.has_continuable_run())
	var notice := str(_gateway.startup_notice())
	if not notice.is_empty():
		_message_bar.show_message(notice)


func _on_continue_pressed() -> void:
	var error: Error = _gateway.continue_saved_run()
	if error != OK:
		return
	_enter_game()


## 新游戏三种情况见文档 §四：空档直接开、有进行中的局先问覆盖、局中开局被状态机拒绝。
func _on_new_game_pressed() -> void:
	if bool(_gateway.has_continuable_run()):
		_pending_new_run = true
		_dialog.ask("覆盖档案 %d？" % int(_gateway.get_active_slot()), _active_slot_summary(), "覆盖")
		return
	_start_new_run()


func _on_overwrite_accepted() -> void:
	if not _pending_new_run:
		return
	_pending_new_run = false
	var error: Error = _gateway.abandon_run()
	if error != OK:
		return
	_start_new_run()


func _start_new_run() -> void:
	var error: Error = _gateway.start_new_run(_new_seed_text(), _new_run_config())
	if error == ERR_ALREADY_IN_USE:
		_pending_new_run = true
		_dialog.ask("本局还没结束", "这一档里有进行中的局。继续它，或者舍弃后重新开始。", "舍弃本局后新开")
		return
	if error != OK:
		return
	_enter_game()


func _on_settings_pressed() -> void:
	if settings_scene.is_empty():
		_message_bar.show_message("本次仅整合开始界面，设置页尚未接入。")
	else:
		_change_scene(settings_scene)


func _on_profile_pressed() -> void:
	_change_scene(profile_scene)


func _on_quit_pressed() -> void:
	_gateway.quit_game()


func _show_credits_notice() -> void:
	_message_bar.show_message(credits_notice)


func _on_save_failed(_error: int, message: String) -> void:
	_message_bar.show_message(message)


func _on_gateway_changed(_slot: int = 0) -> void:
	refresh()


func _enter_game() -> void:
	_change_scene(game_scene)


func _change_scene(path: String) -> void:
	var error := get_tree().change_scene_to_file(path)
	if error != OK:
		_message_bar.show_message("打开场景失败：%s（%d）" % [path, error])


## 种子文本由界面给：状态机只拿它派生随机流，不自己生成。
func _new_seed_text() -> String:
	return "%d-%d" % [int(Time.get_unix_time_from_system()), randi()]


## 完整新局配置交给 main 的 PRG-003 校验，不绕过卡牌解锁规则。
func _new_run_config() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(new_run_config_path))
	var config: Dictionary = parsed.duplicate(true) if parsed is Dictionary else {}
	config["run_id"] = "menu-%d-%d" % [Time.get_ticks_usec(), randi()]
	return config


func _active_slot_summary() -> String:
	var items: Array = _gateway.list_slots()
	var active := int(_gateway.get_active_slot())
	for item: Variant in items:
		if item is Dictionary and int((item as Dictionary).get("slot", 0)) == active:
			return SlotCard.summary_text(item as Dictionary)
	return ""

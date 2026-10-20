extends Control

## 开始界面。只做三件事：把按钮接到 SaveGateway、把网关读到的状态画到屏上、失败时报提示条。
## 它不判任何游戏状态：有没有可继续的局问网关，开局之后的事归状态机。

## 薄装配层复用 main 的地图视图、生成器和存档状态机，不导入占位玩法。
@export var game_scene: String = "res://ui/main_menu/menu_map_entry.tscn"
@export var settings_scene: String = ""
@export var new_run_config_path := "res://data/config/main_menu_new_run.json"
@export var achievements_scene := "res://ui/catalog/achievements.tscn"
@export var encyclopedia_scene := "res://ui/catalog/encyclopedia.tscn"
@export var records_scene := "res://ui/results/run_records.tscn"
@export var credits_notice: String = "感谢名单页还没做"

@onready var _continue_button: Button = $按钮列/继续游戏
@onready var _new_game_button: Button = $按钮列/新游戏
@onready var _settings_button: Button = $按钮列/设置
@onready var _achievements_button: Button = $按钮列/成就
@onready var _encyclopedia_button: Button = $按钮列/图鉴
@onready var _records_button: Button = $按钮列/记录
@onready var _credits_button: Button = $按钮列/感谢名单
@onready var _quit_button: Button = $按钮列/退出游戏
@onready var _message_bar: Panel = $提示条
@onready var _dialog: Control = $确认弹窗

var _gateway: Node = null
var _pending_new_run := false


func _ready() -> void:
	$按钮底板.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel"))
	for button: Button in [$按钮列/继续游戏, $按钮列/新游戏, $按钮列/设置, $按钮列/成就, $按钮列/图鉴, $按钮列/感谢名单, $按钮列/退出游戏]:
		CommonUiSkin.style_button(button, Vector4(24, 12, 24, 12))
	CommonUiSkin.style_button(_records_button, Vector4(24, 12, 24, 12))
	_gateway = get_node_or_null("/root/SaveGateway")
	_continue_button.pressed.connect(_on_continue_pressed)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_achievements_button.pressed.connect(func(): _change_scene(achievements_scene))
	_encyclopedia_button.pressed.connect(func(): _change_scene(encyclopedia_scene))
	_records_button.pressed.connect(func(): _change_scene(records_scene))
	_credits_button.pressed.connect(_show_credits_notice)
	_dialog.accepted.connect(_on_overwrite_accepted)
	_dialog.dismissed.connect(func(): _pending_new_run = false)
	if _gateway != null:
		_gateway.save_failed.connect(_on_save_failed)
		_gateway.save_changed.connect(refresh)
	refresh()
	ScenePreloader.warm_menu(game_scene)


## 「继续游戏」的可用性只问单存档网关。
func refresh() -> void:
	if _gateway == null:
		# 没登记 autoload 时把靠它的入口全置灰，不留会崩的按钮。
		_continue_button.disabled = true
		_new_game_button.disabled = true
		_quit_button.disabled = true
		return
	_continue_button.disabled = not bool(_gateway.has_continuable_run())
	var notice := str(_gateway.startup_notice())
	if not notice.is_empty():
		_message_bar.show_message(notice)


func _on_continue_pressed() -> void:
	var error: Error = _gateway.continue_saved_run()
	if error != OK:
		return
	_enter_game()


## 没有未完成游戏时直接开局，否则必须先确认覆盖。
func _on_new_game_pressed() -> void:
	if _pending_new_run:
		return
	if bool(_gateway.has_continuable_run()):
		_pending_new_run = true
		_dialog.ask("覆盖未完成的游戏？", "当前有一场未完成的游戏。确认后将覆盖本局进度并开始新游戏。\n成就和图鉴解锁将保留。", "确认覆盖")
		return
	_start_new_run()


func _on_overwrite_accepted() -> void:
	if not _pending_new_run:
		return
	_pending_new_run = false
	_start_new_run(true)


func _start_new_run(overwrite_confirmed := false) -> void:
	var error: Error = _gateway.start_new_run(_new_seed_text(), _new_run_config(), overwrite_confirmed)
	if error == ERR_ALREADY_IN_USE:
		_pending_new_run = true
		_dialog.ask("覆盖未完成的游戏？", "确认后将覆盖当前游戏进度，并开始新游戏。", "确认覆盖")
		return
	if error != OK:
		return
	_enter_game()


func _on_settings_pressed() -> void:
	if settings_scene.is_empty():
		_message_bar.show_message("本次仅整合开始界面，设置页尚未接入。")
	else:
		_change_scene(settings_scene)


func _on_quit_pressed() -> void:
	_gateway.quit_game()


func _show_credits_notice() -> void:
	_message_bar.show_message(credits_notice)


func _on_save_failed(_error: int, message: String) -> void:
	_message_bar.show_message(message)


func _enter_game() -> void:
	_change_scene(game_scene)


func _change_scene(path: String) -> void:
	var error := SceneTransition.change_scene_to_file(path)
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

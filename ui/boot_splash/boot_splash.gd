extends Control
## 启动屏：等 AudioService 加载完 bank 再进入主菜单。
##
## 把本场景设为 project.godot 的 run/main_scene，
## 这样玩家看到任何可交互 UI 之前，SFX / Music bank 已经 ready。

const MAIN_MENU_PATH := "res://ui/main_menu/main_menu.tscn"
const TIMEOUT_SEC := 5.0

var _audio: Node
var _timer: Timer
var _entered := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audio = get_node_or_null("/root/AudioService")
	if _audio == null or _audio.is_ready:
		_enter_main_menu()
		return

	_audio.banks_loaded.connect(_enter_main_menu)

	_timer = Timer.new()
	_timer.name = "TimeoutTimer"
	_timer.wait_time = TIMEOUT_SEC
	_timer.one_shot = true
	_timer.timeout.connect(_enter_main_menu)
	add_child(_timer)
	_timer.start()


func _enter_main_menu() -> void:
	if _entered:
		return
	_entered = true
	if _timer != null and is_instance_valid(_timer):
		_timer.stop()
		_timer.queue_free()
		_timer = null
	get_tree().change_scene_to_file(MAIN_MENU_PATH)

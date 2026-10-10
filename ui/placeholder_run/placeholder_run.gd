extends Node2D

## 占位跑图场景。真正的局内场景（战斗 PRG-017、地图 PRG-018）到位之前，用它验证
## 「开一局 → 退出 → 继续游戏」接的是同一局。场景里唯一有意义的东西是本局进度：
## 每 tick_seconds 秒 +1 并写进档案，回来继续时从存档值接着涨。
##
## 它不含玩法，也不读状态机的局内快照：进度存在 SaveGateway 的占位标记里。
## 接入状态机时这个目录连同 set_run_progress() 一起删掉。

@export var tick_seconds: float = 2.0
@export var main_menu_scene: String = "res://ui/main_menu/main_menu.tscn"

@onready var _progress_label: Label = $界面/进度
@onready var _status_label: Label = $界面/状态
@onready var _saved_at_label: Label = $界面/档案时间
@onready var _tick_timer: Timer = $计时
@onready var _keep_button: Button = $界面/按钮行/回主菜单
@onready var _abandon_button: Button = $界面/按钮行/放弃本局

var _gateway: Node = null
var _progress := 0
var _elapsed := 0.0


func _ready() -> void:
	_gateway = get_node_or_null("/root/SaveGateway")
	_tick_timer.wait_time = tick_seconds
	_tick_timer.timeout.connect(_on_tick)
	_keep_button.pressed.connect(_keep_run_and_back)
	_abandon_button.pressed.connect(_on_abandon_pressed)
	_progress = _active_slot_info().get("progress", 0)
	refresh()


func _process(delta: float) -> void:
	_elapsed += delta
	refresh_status()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_keep_run_and_back()


func refresh() -> void:
	_progress_label.text = "本局进度 %d" % _progress
	var stamp := String(_active_slot_info().get("updated_at", ""))
	_saved_at_label.text = "档案写入时间：%s" % (stamp if not stamp.is_empty() else "—")
	refresh_status()


func refresh_status() -> void:
	if _gateway == null:
		_status_label.text = "没有 SaveGateway，这局进不去也退不出来"
		return
	_status_label.text = "当前档案 %d · 已进行 %d 秒" % [int(_gateway.get_active_slot()), int(_elapsed)]


func _on_tick() -> void:
	if _gateway == null:
		return
	_progress += 1
	if _gateway.set_run_progress(_progress) != OK:
		return
	refresh()


func _on_abandon_pressed() -> void:
	if _gateway != null:
		_gateway.abandon_run()
	get_tree().change_scene_to_file(main_menu_scene)


func _keep_run_and_back() -> void:
	get_tree().change_scene_to_file(main_menu_scene)


## 当前档在档案里的那一项。进度与写入时间都从这里读，读的就是磁盘上那份档。
func _active_slot_info() -> Dictionary:
	if _gateway == null:
		return {}
	var active := int(_gateway.get_active_slot())
	var items: Array = _gateway.list_slots()
	for item: Variant in items:
		if item is Dictionary and int((item as Dictionary).get("slot", 0)) == active:
			return item as Dictionary
	return {}

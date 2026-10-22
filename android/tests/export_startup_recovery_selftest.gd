extends Node
## 从外部测试准备的旧引擎存档冷启动；所有后续保存仅在隔离 user://。
const MENU := "res://ui/main_menu/main_menu.tscn"
const WAIT := preload("res://tests/support/presentation_test_helper.gd")
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_tree().current_scene = null
	_check("旧 Steam 存档首次启动就能通过网关校验", SaveGateway._load_error == OK)
	_check("冷启动保留可继续对局", SaveGateway.has_continuable_run())
	if failures > 0:
		get_tree().quit(1)
		return
	var saved: Dictionary = SaveGateway._read_json(SaveGateway.save_path).data
	var original: Dictionary = saved.active_run.run_snapshot.duplicate(true)
	var menu: Control = load(MENU).instantiate()
	get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	await _frames()
	_check("旧存档主菜单继续和新游戏都可用", not menu.get_node("按钮列/继续游戏").disabled and not menu.get_node("按钮列/新游戏").disabled)
	await _click(menu.get_node("按钮列/继续游戏"))
	_check("真实点击继续进入玩法而不是卡在主菜单", get_tree().current_scene.scene_file_path in [EncounterFlow.MAP_SCENE, EncounterFlow.BATTLE_SCENE])
	var run := SaveGateway.current_run()
	_check("恢复保持原对局身份和种子", run != null and run.run_id == original.run_id and run.main_seed == original.main_seed)
	if run == null:
		get_tree().quit(1)
		return
	_check("恢复保留牌组与生命", JSON.stringify(run.deck) == JSON.stringify(original.deck) and run.health == original.health)
	_check("旧存档恢复后能保存", SaveGateway.save_current() == OK)
	var view := get_tree().current_scene
	if view.has_method("_return_to_menu"):
		view._return_to_menu()
	else:
		view._on_menu_return()
	await _frames()
	menu = get_tree().current_scene
	await _click(menu.get_node("按钮列/新游戏"))
	_check("旧存档新游戏显示覆盖确认", menu.get_node("确认弹窗").visible)
	await _click(menu.get_node("确认弹窗/面板/按钮行/取消"))
	_check("取消覆盖保留原对局", SaveGateway.current_run().run_id == original.run_id)
	await _click(menu.get_node("按钮列/新游戏"))
	await _click(menu.get_node("确认弹窗/面板/按钮行/确定"))
	_check("确认后新游戏真正进入地图", get_tree().current_scene.scene_file_path == EncounterFlow.MAP_SCENE and SaveGateway.current_run().run_id != original.run_id)
	_check("新局能正常保存", SaveGateway.save_current() == OK)
	print("EXPORT_STARTUP_RECOVERY failures=", failures)
	get_tree().quit(failures)

func _frames() -> void:
	for index: int in 4:
		await get_tree().process_frame
	_check("场景加载完成", await WAIT.map_ready(get_tree()))

func _click(button: Control) -> void:
	var event := InputEventMouseButton.new()
	event.position = button.get_global_rect().get_center()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)
	await _frames()

func _check(label: String, passed: bool) -> void:
	if not passed: failures += 1
	print("PASS " + label if passed else "FAIL " + label)

extends Node
const WAIT := preload("res://tests/support/presentation_test_helper.gd")
const MENU := "res://ui/main_menu/main_menu.tscn"
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_tree().current_scene = null
	var legacy := "user://save/game.json"
	var oldest := "user://spotlight_save.json"
	var legacy_hash := FileAccess.get_sha256(legacy)
	var oldest_hash := FileAccess.get_sha256(oldest)
	_check("发行模板实际运行", not OS.has_feature("editor"))
	_check("产品名已更新", ProjectSettings.get_setting("application/config/name") == "炼金术士的十日谈")
	_check("旧测试数据夹具存在", not legacy_hash.is_empty() and not oldest_hash.is_empty())
	_check("双网关使用同一独立发行存档", SaveGateway.save_path == GlobalStateMachine.RELEASE_SAVE_PATH and GlobalState.save_path == SaveGateway.save_path)
	_check("冷启动校验成功", SaveGateway._load_error == OK)
	var reload := OS.get_cmdline_user_args().has("--reload-profile")
	if reload:
		var marker: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("user://qa-profile-marker.json"))
		_check("重启可继续发行版新进度", SaveGateway.has_continuable_run() and GlobalState._saved_active_run.run_snapshot.run_id == marker.run_id)
		_check("重启没有带入旧测试记录", GlobalState.run_history.is_empty())
	else:
		_check("首次打开没有继续进度", not SaveGateway.has_continuable_run())
		_check("首次打开没有测试记录", GlobalState.run_history.is_empty())
		_check("不会自动复制旧存档", not FileAccess.file_exists(SaveGateway.save_path))
	if failures > 0:
		get_tree().quit(failures)
		return
	var menu: Control = load(MENU).instantiate()
	get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	await _frames()
	if not reload:
		_check("菜单没有继续入口", menu.get_node("按钮列/继续游戏").disabled)
		var records: Control = load("res://ui/results/run_records.tscn").instantiate()
		get_tree().root.add_child(records)
		await _frames()
		_check("记录页面确实为空", records.entries.is_empty())
		records.queue_free()
		await _frames()
		await _click(menu.get_node("按钮列/新游戏"))
	else:
		await _click(menu.get_node("按钮列/继续游戏"))
	_check("实际点击进入地图", get_tree().current_scene.scene_file_path == EncounterFlow.MAP_SCENE)
	if failures > 0:
		get_tree().quit(failures)
		return
	var run := SaveGateway.current_run()
	_check("新路径正常保存", SaveGateway.save_current() == OK and FileAccess.file_exists(GlobalStateMachine.RELEASE_SAVE_PATH))
	if not reload:
		var marker := FileAccess.open("user://qa-profile-marker.json", FileAccess.WRITE)
		marker.store_string(JSON.stringify({"run_id":run.run_id}))
		marker.close()
	get_tree().current_scene._return_to_menu()
	await _frames()
	menu = get_tree().current_scene
	await _click(menu.get_node("按钮列/新游戏"))
	var dialog: Control = menu.get_node("确认弹窗")
	_check("真实覆盖确认居中", dialog.visible and dialog.get_node("面板").get_global_rect().get_center().distance_to(get_viewport().get_visible_rect().get_center()) <= 1.0)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://overwrite-centered.png")
	await _click(dialog.get_node("面板/按钮行/取消"))
	_check("取消保留当前新进度", not dialog.visible and SaveGateway.current_run().run_id == run.run_id)
	_check("旧编辑器存档字节未变", FileAccess.get_sha256(legacy) == legacy_hash and FileAccess.get_sha256(oldest) == oldest_hash)
	print("RELEASE_PROFILE_RESULT reload=", reload, " failures=", failures)
	get_tree().quit(failures)

func _frames() -> void:
	for i in 4: await get_tree().process_frame
	_check("场景准备完成", await WAIT.map_ready(get_tree()))

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
	print("PASS " + label if passed else "FAIL " + label)
	if not passed: failures += 1

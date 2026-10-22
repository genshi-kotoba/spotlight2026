extends Node
## 退出测试由外部进程断言：必须自行退出0，超时则仍被锁在菜单。
func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := "user://quit-error-fixture/game.json"
	var valid_save := OS.get_cmdline_user_args().has("--valid-save")
	if valid_save:
		if SaveGateway._load_error != OK:
			get_tree().quit(1)
			return
	else:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("{invalid-save-fixture")
		file.close()
		SaveGateway.save_path = path
		if SaveGateway.load_current() == OK:
			get_tree().quit(1)
			return
	var before := FileAccess.get_sha256(path) if not valid_save else ""
	var menu: Control = load("res://ui/main_menu/main_menu.tscn").instantiate()
	get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	for index: int in 4: await get_tree().process_frame
	# 本用例断言稳定主菜单的退出行为。另留即时退出的进程日志；
	# 避免线程预加载尚未完成时关闭解析器产生无关的退出清理诊断。
	var deadline := Time.get_ticks_msec() + 15000
	while int(ScenePreloader.stats().queued) + int(ScenePreloader.stats().loading) > 0:
		if Time.get_ticks_msec() >= deadline:
			print("FAIL 菜单预加载未就绪")
			get_tree().quit(1)
			return
		await get_tree().process_frame
	if OS.get_cmdline_user_args().has("--window-close"):
		SaveGateway._notification(NOTIFICATION_WM_CLOSE_REQUEST)
	else:
		var event := InputEventMouseButton.new()
		event.position = menu.get_node("按钮列/退出游戏").get_global_rect().get_center()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = true
		get_viewport().push_input(event, true)
		event = event.duplicate()
		event.pressed = false
		get_viewport().push_input(event, true)
	if not valid_save and FileAccess.get_sha256(path) != before:
		print("FAIL 损坏存档被覆盖")
		get_tree().quit(1)
		return
	print("QUIT_VALID_SAVE_REQUESTED" if valid_save else "QUIT_LOAD_ERROR_REQUESTED_ORIGINAL_UNCHANGED")
	await get_tree().create_timer(1.0).timeout
	print("FAIL 读档失败后退出仍被阻止")
	get_tree().quit(1)

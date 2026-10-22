extends Node
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var menu: Control = load("res://ui/main_menu/main_menu.tscn").instantiate()
	add_child(menu)
	var dialog: Control = menu.get_node("确认弹窗")
	for dimensions: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(2560, 1080)]:
		get_window().size = dimensions
		for i in 4: await get_tree().process_frame
		dialog.ask("覆盖未完成的游戏？", "确认后将覆盖本局进度。", "确认覆盖")
		for i in 4: await get_tree().process_frame
		var rect: Rect2 = dialog.get_node("面板").get_global_rect()
		var viewport: Rect2 = get_viewport().get_visible_rect()
		_check("弹窗居中 %s" % dimensions, rect.get_center().distance_to(viewport.get_center()) <= 1.0)
		_check("遮罩铺满视口 %s" % dimensions, dialog.get_node("遮罩").get_global_rect().is_equal_approx(viewport))
		dialog._on_cancel_pressed()
		_check("取消后关闭", not dialog.visible)
	_check("编辑器与发行版默认路径正确", SaveGateway.save_path == GlobalStateMachine.default_save_path() and GlobalState.save_path == SaveGateway.save_path)
	var deadline := Time.get_ticks_msec() + 15000
	while int(ScenePreloader.stats().queued) + int(ScenePreloader.stats().loading) > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	print("CONFIRM_LAYOUT_RESULT failures=", failures)
	get_tree().quit(failures)

func _check(label: String, passed: bool) -> void:
	print("PASS " + label if passed else "FAIL " + label)
	if not passed: failures += 1

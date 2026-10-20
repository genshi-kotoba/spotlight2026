extends Node

const TARGET := "res://tests/support/scene_transition_target.tscn"
const REDIRECT := "res://tests/support/scene_transition_redirect.tscn"
const FAILURE := "res://tests/support/scene_transition_failure.tscn"
const MENU := "res://ui/main_menu/main_menu.tscn"
var failures := 0
var starts: Array[String] = []
var finishes: Array[String] = []
var errors: Array[String] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_run")

func _run() -> void:
	# 留在 root 中，让测试协程跨真实场景切换继续；写盘只用独立夹具。
	get_tree().current_scene = null
	get_window().size = Vector2i(1920, 1080)
	var fixture := "res://.godot/scene-transition-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture.path_join("game.json")
	_check("使用独立存档夹具", SaveGateway.load_current() == OK)
	SceneTransition.transition_started.connect(func(path: String): starts.append(path))
	SceneTransition.transition_finished.connect(func(path: String): finishes.append(path))
	SceneTransition.transition_failed.connect(func(path: String, _error: Error): errors.append(path))
	_check("无效路径立即拒绝，不锁定画面", SceneTransition.change_scene_to_file("res://missing-scene.tscn") == ERR_FILE_NOT_FOUND and not SceneTransition.is_loading() and not get_tree().paused)
	var old: Control = load(TARGET).instantiate()
	get_tree().root.add_child(old)
	get_tree().current_scene = old
	await get_tree().process_frame
	var old_ticks: int = old.process_count
	_check("切换请求立即显示全屏遮罩并暂停操作", SceneTransition.change_scene_to_file(TARGET) == OK and SceneTransition.is_loading() and SceneTransition._blocker.visible and get_tree().paused)
	_check("重复点击不会并行切换", SceneTransition.change_scene_to_file(TARGET) == ERR_BUSY)
	await _click(Vector2(120, 70))
	_check("旧场景加载时不处理鼠标、键盘或玩法帧", is_instance_valid(old) and old.clicks == 0 and old.input_count == 0 and old.process_count == old_ticks)
	await _wait()
	var current := get_tree().current_scene
	_check("新场景准备完成才撤掉遮罩", current.scene_file_path == TARGET and current.prepared and not SceneTransition._blocker.visible and not get_tree().paused)
	_check("完成信号仅发送一次", starts == [TARGET] and finishes == [TARGET] and errors.is_empty())
	_check("淡出淡入耗时独立统计且计入总时长", SceneTransition.last_metrics.fade_out_ms > 0.0 and SceneTransition.last_metrics.fade_in_ms > 0.0 and SceneTransition.last_metrics.total_ms >= SceneTransition.last_metrics.fade_out_ms + SceneTransition.last_metrics.fade_in_ms)
	await _click(Vector2(120, 70))
	_check("切换后恢复真实鼠标点击", current.clicks == 1)
	get_tree().paused = true
	_check("暂停状态下仍可发起切换", SceneTransition.change_scene_to_file(TARGET) == OK)
	await _wait()
	_check("切换完成恢复原先的暂停状态", get_tree().paused and not SceneTransition._blocker.visible)
	get_tree().paused = false
	var start_count := starts.size()
	var finish_count := finishes.size()
	_check("允许新场景准备中请求跳转", SceneTransition.change_scene_to_file(REDIRECT) == OK)
	await _wait()
	_check("连续跳转共用遮罩，最终场景才发送完成", get_tree().current_scene.scene_file_path == TARGET and starts.size() == start_count + 1 and finishes.size() == finish_count + 1 and finishes.back() == TARGET)
	_check("失败准备请求可受理", SceneTransition.change_scene_to_file(FAILURE) == OK)
	await _wait()
	_check("准备失败解除操作锁并显示可关闭提示", errors == [FAILURE] and not get_tree().paused and not SceneTransition._blocker.visible and SceneTransition._failure_dialog.visible)
	SceneTransition._failure_dialog.hide()
	_check("失败后可以再次加载", SceneTransition.change_scene_to_file(MENU) == OK)
	await _wait()
	var menu := get_tree().current_scene
	_check("真实主菜单可加载", menu.scene_file_path == MENU)
	menu.get_node("按钮列/图鉴").pressed.emit()
	_check("真实主菜单导航接入统一遮罩", SceneTransition.is_loading())
	await get_tree().process_frame
	_check("遮罩覆盖真实视口、提示正中且鼠标拦截", SceneTransition._blocker.get_global_rect().encloses(get_viewport().get_visible_rect()) and SceneTransition._blocker.mouse_filter == Control.MOUSE_FILTER_STOP and SceneTransition._label.get_global_rect().get_center().distance_to(get_viewport().get_visible_rect().get_center()) < 2.0)
	if DisplayServer.get_name() != "headless":
		# 截取真正显示加载文字的遮罩阶段，而不是淡出刚开始的透明帧。
		while SceneTransition.is_loading() and SceneTransition._blocker.modulate.a < 0.98:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/scene-transition-loading.png")
	await _wait()
	var catalog := get_tree().current_scene
	_check("图鉴加载后解除遮罩", catalog.scene_file_path == "res://ui/catalog/encyclopedia.tscn" and not get_tree().paused)
	catalog.get_node("Page").get_child(0).get_node("Heading/Back").pressed.emit()
	await _wait()
	_check("图鉴返回同样经过遮罩", get_tree().current_scene.scene_file_path == MENU)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/scene-transition-complete.png")
	print("场景加载提示：全部通过" if failures == 0 else "场景加载提示：失败 %d 项" % failures)
	get_tree().quit(failures)

func _wait() -> void:
	var deadline := Time.get_ticks_msec() + 15000
	var covered := true
	var fade_requests_rejected := true
	while SceneTransition.is_loading() and Time.get_ticks_msec() < deadline:
		covered = covered and SceneTransition._blocker.visible and get_tree().paused
		if not SceneTransition._installing and SceneTransition._blocker.modulate.a > 0.0 and SceneTransition._blocker.modulate.a < 1.0:
			fade_requests_rejected = fade_requests_rejected and SceneTransition.change_scene_to_file(MENU) == ERR_BUSY
		await get_tree().process_frame
	_check("加载和连续跳转期间始终保留遮罩与操作锁", covered)
	_check("淡入淡出期间不受理会丢失的重定向", fade_requests_rejected)
	_check("场景切换无永久等待", not SceneTransition.is_loading())
	await get_tree().process_frame

func _click(point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)
	var key := InputEventKey.new()
	key.keycode = KEY_TAB
	key.pressed = true
	get_viewport().push_input(key, true)
	key = key.duplicate()
	key.pressed = false
	get_viewport().push_input(key, true)

func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

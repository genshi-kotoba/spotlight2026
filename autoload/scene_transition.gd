extends CanvasLayer
## 所有运行时场景切换的唯一入口；遮罩不随旧场景释放。
signal transition_started(path: String)
signal transition_finished(path: String)
signal transition_failed(path: String, error: Error)

const READY_TIMEOUT_MS := 120000
const MAX_REDIRECTS := 8
var _busy := false
var _installing := false
var _target := ""
var _redirect := ""
var _was_paused := false
var _presentation_mode: Node.ProcessMode
var _previous_focus: WeakRef
var _blocker: ColorRect
var _label: Label
var _elapsed := 0.0
var _failure_dialog: AcceptDialog
## 调试用阶段耗时，资源等待与场景准备分开记录，避免把加载假快当成优化。
var last_metrics: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 2048 # 高于普通 CanvasLayer 和嵌入式弹窗。
	_blocker = ColorRect.new()
	_blocker.name = "LoadingOverlay"
	_blocker.color = Color(0.0, 0.0, 0.0, 0.72)
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_blocker.focus_mode = Control.FOCUS_ALL
	add_child(_blocker)
	_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blocker.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := CommonUiSkin.panel("strip", Vector4(48, 28, 48, 28))
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	_label = Label.new()
	_label.name = "LoadingLabel"
	_label.text = "正在加载…"
	_label.custom_minimum_size.x = 280
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "SimHei", "Noto Sans CJK SC"])
	_label.add_theme_font_override("font", font)
	_label.add_theme_font_size_override("font_size", 40)
	_label.add_theme_color_override("font_color", Color("e8bc58"))
	panel.add_child(_label)
	_blocker.hide()
	_failure_dialog = AcceptDialog.new()
	CommonUiSkin.style_dialog(_failure_dialog)
	_failure_dialog.name = "SceneLoadingError"
	_failure_dialog.title = "加载失败"
	_failure_dialog.ok_button_text = "确定"
	add_child(_failure_dialog)
	set_process(false)
	set_process_input(false)


func is_loading() -> bool:
	return _busy


## OK 表示请求已受理；异步失败通过信号和可关闭提示报告，恢复原来的操作状态。
func change_scene_to_file(path: String) -> Error:
	if not path.begins_with("res://") or not ResourceLoader.exists(path, "PackedScene"):
		return ERR_FILE_NOT_FOUND
	if _busy:
		# 新场景的 _ready/延迟恢复可能立刻转向战斗或主菜单，保持同一遮罩。
		if _installing and path != _target:
			_redirect = path
			return OK
		return ERR_BUSY
	_busy = true
	last_metrics = {"path": path, "started_usec": Time.get_ticks_usec(), "resource_ms": 0.0, "prepare_ms": 0.0}
	_target = path
	_redirect = ""
	_was_paused = get_tree().paused
	_presentation_mode = MapPresentation.process_mode
	var focus := get_viewport().gui_get_focus_owner()
	_previous_focus = weakref(focus) if focus != null else null
	get_tree().paused = true
	_elapsed = 0.0
	_label.text = "正在加载…"
	_blocker.show()
	_blocker.grab_focus()
	set_process(true)
	set_process_input(true)
	transition_started.emit(path)
	_perform.call_deferred(path)
	return OK


func _process(delta: float) -> void:
	_elapsed += delta
	_label.text = "正在加载" + ".".repeat(1 + int(_elapsed / 0.4) % 3)


func _input(_event: InputEvent) -> void:
	if _busy:
		get_viewport().set_input_as_handled()


func _draw_frame() -> void:
	await get_tree().process_frame
	# headless 不发送绘制信号，不能在这里永久等待。
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func _perform(path: String) -> void:
	# 必须先把遮罩真正绘制出来，再启动资源读取/实例化/同步 _ready。
	await _draw_frame()
	for redirect_index in MAX_REDIRECTS:
		_target = path
		_redirect = ""
		_installing = false
		var resource_started := Time.get_ticks_usec()
		var packed := await ScenePreloader.load_scene(path)
		last_metrics.resource_ms += (Time.get_ticks_usec() - resource_started) / 1000.0
		if packed == null:
			_fail(path, ERR_CANT_OPEN)
			return
		var prepare_started := Time.get_ticks_usec()
		_installing = true
		# 只允许纯表现缓存继续准备；场景玩法与输入仍处于暂停状态。
		MapPresentation.process_mode = Node.PROCESS_MODE_ALWAYS
		var error := get_tree().change_scene_to_packed(packed)
		if error != OK:
			_fail(path, error)
			return
		await get_tree().scene_changed
		# 包含 _ready 中 call_deferred 的恢复/跳转，以及首轮 UI 布局。
		await get_tree().process_frame
		var scene := get_tree().current_scene
		var started := Time.get_ticks_msec()
		while _redirect.is_empty() and is_instance_valid(scene):
			var message := _preparation_error(scene)
			if not message.is_empty():
				_fail(path, ERR_CANT_CREATE, message)
				return
			if _scene_prepared(scene):
				break
			if Time.get_ticks_msec() - started >= READY_TIMEOUT_MS:
				_fail(path, ERR_TIMEOUT, "场景准备超时，请返回开始界面后重试。")
				return
			await get_tree().process_frame
		if not is_instance_valid(scene) and _redirect.is_empty():
			_fail(path, ERR_DOES_NOT_EXIST, "场景在准备期间已退出，请重试。")
			return
		await _draw_frame()
		last_metrics.prepare_ms += (Time.get_ticks_usec() - prepare_started) / 1000.0
		if not _redirect.is_empty():
			path = _redirect
			continue
		_finish()
		transition_finished.emit(path)
		return
	_fail(path, ERR_CYCLIC_LINK, "场景连续跳转过多，已停止加载。")


func _scene_prepared(scene: Node) -> bool:
	if scene.has_method("is_scene_transition_ready"):
		return bool(scene.call("is_scene_transition_ready"))
	if scene.has_method("is_map_ready"):
		return bool(scene.call("is_map_ready"))
	return scene.is_node_ready()


func _preparation_error(scene: Node) -> String:
	if scene.has_method("scene_transition_error"):
		return str(scene.call("scene_transition_error"))
	return ""


func _finish() -> void:
	last_metrics["total_ms"] = (Time.get_ticks_usec() - int(last_metrics.get("started_usec", Time.get_ticks_usec()))) / 1000.0
	_busy = false
	_installing = false
	_redirect = ""
	_blocker.hide()
	set_process(false)
	set_process_input(false)
	MapPresentation.process_mode = _presentation_mode
	get_tree().paused = _was_paused
	var focus: Control = _previous_focus.get_ref() if _previous_focus != null else null
	if is_instance_valid(focus) and focus.is_inside_tree() and focus.is_visible_in_tree():
		focus.grab_focus()
	_previous_focus = null


func _fail(path: String, error: Error, message := "") -> void:
	_finish()
	_failure_dialog.dialog_text = "无法加载场景：%s\n%s（错误 %d）" % [path,
		message if not message.is_empty() else "请重试；当前操作锁定已解除。", error]
	_failure_dialog.popup_centered(Vector2i(680, 200))
	transition_failed.emit(path, error)

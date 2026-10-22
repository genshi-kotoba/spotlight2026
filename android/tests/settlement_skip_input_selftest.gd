extends Node
## Real viewport input: the skip gesture must never confirm the newly opened detail.
const VIEW := preload("res://ui/results/run_settlement_view.gd")
var checks := 0
var failures := 0
var confirmations := 0
var cases: Array[Dictionary] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_tree().current_scene = null
	if not str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")).begins_with("result-confirmation-qa-"):
		print("SETTLEMENT_SKIP_REFUSED non-QA user profile")
		get_tree().quit(2)
		return
	get_window().size = Vector2i(1920, 1080)
	# 当前项目只内置键盘确认；显式配置可用手柄，验证绑定后的完整手势。
	var controller_accept := InputEventJoypadButton.new()
	controller_accept.device = -1
	controller_accept.button_index = JOY_BUTTON_A
	InputMap.action_add_event("ui_accept", controller_accept)
	var controller_probe := InputEventJoypadButton.new()
	controller_probe.device = 2
	controller_probe.button_index = JOY_BUTTON_A
	controller_probe.pressed = true
	_check("configured controller confirmation binding is active", controller_probe.is_action_pressed("ui_accept"))
	for result: String in ["defeat", "victory"]:
		for input: String in ["mouse", "touch", "key", "joypad"]:
			await _skip_case(result, input)
	await _natural_case()
	await _history_case()
	await _cancel_cases()
	print("SETTLEMENT_SKIP_RESULT ", JSON.stringify({"checks": checks, "failures": failures, "cases": cases}))
	get_tree().quit(0 if failures == 0 else 1)

func _record(result: String) -> Dictionary:
	return {"run_id": "settlement-input-fixture", "main_seed": "read-only", "result": result,
		"location_name": "测试事件", "total_silver_earned": 400, "battles_fought": 3,
		"final_inventory": {"deck": ["1", "40"], "items": [], "health": 0, "max_health": 100, "gold": 100}}

func _panel(result: String, intro := true, outgoing := false) -> Control:
	var panel := VIEW.new()
	panel.fade_seconds = 0.2
	panel.line_seconds = 0.15
	panel.line_gap = 0.04
	panel.hold_seconds = 0.15
	panel.move_seconds = 0.15
	get_tree().root.add_child(panel)
	panel.confirmed.connect(func(): confirmations += 1)
	var frame: Texture2D
	if outgoing:
		var pixels := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		pixels.fill(Color.BLACK)
		frame = ImageTexture.create_from_image(pixels)
	panel.show_record(_record(result), intro, frame)
	return panel

func _skip_case(result: String, input: String) -> void:
	confirmations = 0
	var panel := _panel(result, true, input == "mouse")
	await _frames(2)
	var label := result + "-" + input
	_check(label + " explicit skip hint appears", panel.find_child("SettlementSkipHint", true, false) != null)
	var point: Vector2 = panel.confirm_button.get_global_rect().get_center()
	var before := Time.get_ticks_msec()
	_press(input, point, true)
	# Touch emulation may deliver a second mouse press while the finger is still held.
	if input == "touch": _mouse(point, true, -1)
	var deadline := Time.get_ticks_msec() + 650
	while not panel.detail_ready and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	var elapsed := Time.get_ticks_msec() - before
	_check(label + " skip reaches complete detail quickly", panel.detail_ready and elapsed < 650)
	_check(label + " full text and read-only bag are visible", _detail_complete(panel))
	_check(label + " live action names its destination", panel.confirm_button.text == "返回主菜单")
	if input == "key":
		panel.confirm_button.grab_focus()
		var repeat := InputEventKey.new()
		repeat.keycode = KEY_ENTER
		repeat.pressed = true
		repeat.echo = true
		get_viewport().push_input(repeat, true)
	else:
		_press(input, point, true)
	await _frames(2)
	if input == "joypad":
		var other_device := InputEventJoypadButton.new()
		other_device.device = 99
		other_device.button_index = JOY_BUTTON_A
		other_device.pressed = false
		get_viewport().push_input(other_device, true)
		await _click(panel.confirm_button)
		_check(label + " another controller cannot release the skip gesture", confirmations == 0)
	_press(input, point, false)
	if input == "touch": _mouse(point, false, -1)
	await _frames(3)
	_check(label + " skip/repeat/release never confirms", confirmations == 0)
	var opened: Tween = panel.bag._open_tween
	await get_tree().create_timer(1.6).timeout
	_check(label + " stale intro cannot reopen or hide detail", _detail_complete(panel) and panel.bag._open_tween == opened and confirmations == 0)
	_check(label + " final inventory stays read-only", panel.bag.settlement_mode and not panel.bag._can_edit_relics())
	if panel.detail_ready:
		if input == "joypad":
			_press(input, point, true)
			await _frames(1)
			_press(input, point, false)
			await _frames(2)
		else:
			await _click(panel.confirm_button)
		_check(label + " fresh explicit activation confirms once", confirmations == 1)
	cases.append({"case": label, "skip_ms": elapsed, "detail_ready": panel.detail_ready, "confirmations": confirmations})
	panel.queue_free()
	await _frames(2)

func _natural_case() -> void:
	confirmations = 0
	var panel := _panel("defeat", true, true)
	_check("natural intro starts with hidden detail", not panel.detail_ready and not panel.confirm_button.visible)
	var deadline := Time.get_ticks_msec() + 4000
	while not panel.detail_ready and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_check("natural intro still reaches complete detail", _detail_complete(panel) and confirmations == 0)
	panel.bag.close()
	panel.bag.set_page(2)
	_check("natural detail retains read-only final bag", panel.bag.visible and panel.bag.current_page() == 1)
	await _click(panel.confirm_button)
	_check("natural detail returns only on explicit confirmation", confirmations == 1)
	panel.queue_free()
	await _frames(2)

func _history_case() -> void:
	confirmations = 0
	var panel := _panel("victory", false)
	var deadline := Time.get_ticks_msec() + 2000
	while not panel.detail_ready and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_check("history detail opens without replaying intro", _detail_complete(panel) and panel.find_child("SettlementSkipHint", true, false) == null)
	_check("history action returns to the record list", panel.confirm_button.text == "返回记录列表")
	panel.confirm_button.grab_focus()
	panel.bag._peek_card("1")
	await _frames(2)
	_press("key", Vector2.ZERO, true)
	await _frames(1)
	_press("key", Vector2.ZERO, false)
	await _frames(2)
	_check("focused confirmation key cannot return through the card preview", confirmations == 0 and panel.bag._peek_layer.visible)
	panel.confirm_button.pressed.emit()
	_check("active card preview also guards direct button activation", confirmations == 0 and panel.bag._peek_layer.visible)
	await _click(panel.confirm_button)
	_check("card preview consumes its dismissal before detail confirmation", confirmations == 0 and not panel.bag._peek_layer.visible)
	await _click(panel.confirm_button)
	_check("history detail confirms only after preview closes", confirmations == 1)
	panel.queue_free()
	await _frames(2)

func _cancel_cases() -> void:
	confirmations = 0
	var panel := _panel("defeat", true, true)
	var reference: WeakRef = weakref(panel)
	panel.queue_free()
	await _frames(2)
	await get_tree().create_timer(1.6).timeout
	_check("free during intro cancels future animation work", reference.get_ref() == null and confirmations == 0)
	panel = _panel("defeat", true, true)
	var point: Vector2 = panel.confirm_button.get_global_rect().get_center()
	_press("mouse", point, true)
	reference = weakref(panel)
	panel.queue_free()
	await _frames(2)
	_press("mouse", point, false)
	await get_tree().create_timer(1.6).timeout
	_check("free after skip cancels the pending detail opening", reference.get_ref() == null and confirmations == 0)
	panel = _panel("victory")
	var cancel := InputEventKey.new()
	cancel.keycode = KEY_ESCAPE
	cancel.pressed = true
	get_viewport().push_input(cancel, true)
	await get_tree().create_timer(0.35).timeout
	_check("cancel key skips intro without returning", _detail_complete(panel) and confirmations == 0)
	# Losing focus must release any held skip gesture before a future activation.
	get_window().focus_exited.emit()
	await _frames(2)
	await _click(panel.confirm_button)
	_check("focus loss cannot leave skip input permanently blocked", confirmations == 1)
	panel.queue_free()
	await _frames(2)

func _detail_complete(panel: Control) -> bool:
	if not panel.detail_ready or not panel.bag.visible or not panel.confirm_button.visible: return false
	if not is_equal_approx(panel.bag.modulate.a, 1.0) or not is_equal_approx(panel.bag._pages[1].modulate.a, 1.0): return false
	if not panel.summary.position.is_equal_approx(Vector2(124, 300)) or not panel.summary.scale.is_equal_approx(Vector2.ONE * 0.6): return false
	for line: Control in panel.summary.get_children():
		if not is_equal_approx(line.modulate.a, 1.0): return false
	return not is_instance_valid(panel.outgoing)

func _press(kind: String, point: Vector2, pressed: bool) -> void:
	if kind == "mouse": _mouse(point, pressed); return
	if kind == "touch":
		var touch := InputEventScreenTouch.new()
		touch.index = 0
		touch.position = point
		touch.pressed = pressed
		get_viewport().push_input(touch, true)
	elif kind == "joypad":
		var joypad := InputEventJoypadButton.new()
		joypad.device = 2
		joypad.button_index = JOY_BUTTON_A
		joypad.pressed = pressed
		joypad.pressure = 1.0 if pressed else 0.0
		get_viewport().push_input(joypad, true)
	else:
		var key := InputEventKey.new()
		key.keycode = KEY_ENTER
		key.pressed = pressed
		get_viewport().push_input(key, true)

func _mouse(point: Vector2, pressed: bool, device := 0) -> void:
	var mouse := InputEventMouseButton.new()
	mouse.position = point
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = pressed
	mouse.device = device
	get_viewport().push_input(mouse, true)

func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	await _frames(2)
	_mouse(point, true)
	await _frames(1)
	_mouse(point, false)
	await _frames(2)

func _frames(count: int) -> void:
	for index in count: await get_tree().process_frame

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

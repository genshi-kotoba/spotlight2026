extends Node
class KeyReceiver extends Control:
	var received: Array[int] = []
	var navigation_received: Array[String] = []
	func _input(event: InputEvent) -> void:
		if event is InputEventKey:
			received.append(event.keycode)
			if event.pressed and event.keycode in [KEY_M, KEY_TAB]: hide()
		elif event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventAction:
			navigation_received.append(event.get_class())

var checks := 0
var failures := 0
var signals: Array[String] = []
var preference_changes := 0
var clicks := 0
var _had_settings := false
var _settings_bytes := PackedByteArray()

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	_had_settings = FileAccess.file_exists(ReadingSettings.PATH)
	if _had_settings: _settings_bytes = FileAccess.get_file_as_bytes(ReadingSettings.PATH)
	if _had_settings: DirAccess.remove_absolute(ProjectSettings.globalize_path(ReadingSettings.PATH))
	var expected_default := 32 if OS.has_feature("android") or ProjectSettings.has_setting("autoload/MobileInput") else 22
	_check("平台工程默认阅读字号", ReadingSettings.body_size() == expected_default)
	ReadingSettings.set_body_size(22)
	ReadingSettings.connect_changed(_preference_changed)
	ReadingSettings.connect_changed(_preference_changed)
	ReadingSettings.set_body_size(32)
	var saved := ConfigFile.new()
	_check("字号持久化且重复监听只通知一次", saved.load(ReadingSettings.PATH) == OK and saved.get_value("reading", "body_size") == 32 and preference_changes == 1)
	ReadingSettings.set_body_size(23)
	_check("非法字号不替换已选字号", ReadingSettings.body_size() == 32 and preference_changes == 1)
	ReadingSettings.disconnect_changed(_preference_changed)
	ReadingSettings.set_body_size(22)
	_check("监听移除后不再通知", preference_changes == 1)
	var bridge := get_node_or_null("/root/MobileInput")
	var test_bridge := bridge == null
	if test_bridge:
		bridge = load("res://android/autoload/mobile_input.gd").new()
		bridge.name = "MobileInput"
		get_tree().root.add_child(bridge)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	host.set_meta("reading_safe_rect", Rect2(80, 30, 1760, 1020))
	var behind := Button.new()
	behind.position = Vector2(10, 10)
	behind.size = Vector2(60, 60)
	behind.pressed.connect(func(): clicks += 1)
	host.add_child(behind)
	var data := CardData.new()
	data.card_id = "reading-selftest-card"
	data.card_name = "完整阅读测试"
	data.description = "这段完整文本必须保留到最后，".repeat(180) + "结尾标志"
	_check("直接战斗上下文拒绝新阅读层", ReadingDetailOverlay.open_card(host, data, {}, "battle") == null)
	bridge._begin(0, Vector2(500, 400))
	bridge._elapsed = 0.5
	bridge._process(0)
	var detail := ReadingDetailOverlay.open_card(host, data, {}, "shop", {"text": "确认测试", "token": "copy:1"})
	detail.action_requested.connect(func(token: String): signals.append("action:" + token))
	detail.closed.connect(func(): signals.append("closed"))
	await _frames()
	var reader: CardReadingPanel = detail.get("_reader")
	var action: Button = detail.get("_action_button")
	_check("详情保留全文并允许滚动到末尾", reader.body.text.replace("\n", "") == data.description.replace("\n", "") and reader.body.maximum_scroll() > 0)
	_check("详情与按钮完整留在安全区域", Rect2(80, 30, 1760, 1020).encloses(detail.get("_surface").get_global_rect()))
	_push_button(action.get_global_rect().get_center(), false)
	bridge._finish(Vector2(500, 400))
	await _frames()
	_check("打开详情的长按松手不触发动作", signals.is_empty() and ReadingDetailOverlay.is_open_for(host))
	ReadingSettings.set_body_size(40)
	await _frames()
	_check("已打开正文即时重排且不缩字", reader.body.get_theme_font_size("font_size") == 40 and Rect2(80, 30, 1760, 1020).encloses(detail.get("_surface").get_global_rect()))
	reader.body._scroll_to(reader.body.maximum_scroll())
	_check("大字号末段仍可到达", reader.body.lines_skipped > 0 and reader.body.text.replace("\n", "").ends_with("结尾标志"))
	await _click(action.get_global_rect().get_center())
	_check("新按下松开只发一次动作且不自动关闭", signals == ["action:copy:1"] and ReadingDetailOverlay.is_open_for(host))
	detail.close("host_before_transaction")
	_check("动作先于宿主关闭信号", signals == ["action:copy:1", "closed"] and not ReadingDetailOverlay.is_open_for(host))
	await _frames()
	detail = ReadingDetailOverlay.open_card(host, data)
	await _frames()
	await _click(Vector2(35, 35))
	_check("点击外部只关闭详情而不穿透按钮", not ReadingDetailOverlay.is_open_for(host) and clicks == 0)
	detail = ReadingDetailOverlay.open_card(host, data)
	await _frames()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	get_viewport().push_input(escape, true)
	await _frames()
	_check("Esc只收阅读层", not ReadingDetailOverlay.is_open_for(host) and host.is_visible_in_tree())
	detail = ReadingDetailOverlay.open_card(host, data)
	await _frames()
	host.hide()
	await _frames()
	_check("宿主隐藏强制清理详情", not ReadingDetailOverlay.is_open_for(host))
	host.show()
	ReadingSettings.set_body_size(32)
	var anchor := Control.new()
	anchor.position = Vector2(650, 450)
	anchor.size = Vector2(96, 96)
	host.add_child(anchor)
	var tip := HoverTip.new()
	host.add_child(tip)
	tip.pin_for(anchor, "[font_size=20]标题[/font_size]\n" + "完整说明".repeat(8), true, Vector2(698, 498))
	await _frames()
	tip.hide_tip()
	var label := tip.get_node("TipLabel") as RichTextLabel
	_check("固定提示抬手与mouse-exit后仍保留", tip.is_pinned())
	_check("提示正文32且标题跟随变大", label.get_theme_font_size("normal_font_size") == 32 and label.text.contains("font_size=38"))
	_check("固定提示避让接触点并留在安全区", not tip.get_global_rect().intersects(Rect2(602, 402, 192, 192)) and Rect2(80, 30, 1760, 1020).encloses(tip.get_global_rect()))
	_check("固定提示有64像素关闭按钮", tip.get_node("ClosePinnedTip").get_global_rect().size.y >= 64)
	bridge._begin(0, Vector2(35, 35))
	bridge._finish(Vector2(35, 35))
	await _frames()
	_check("新外部触摸关闭提示并消费整次点击", not tip.is_pinned() and clicks == 0)
	bridge._begin(0, anchor.get_global_rect().get_center())
	bridge._elapsed = 0.5
	bridge._process(0)
	tip.show_for(anchor, "长按固定")
	bridge._finish(anchor.get_global_rect().get_center())
	await _frames()
	_check("长按桥自动固定而非仅悬停", tip.is_pinned())
	anchor.hide()
	await _frames()
	_check("源控件隐藏强制收提示", not tip.visible)
	anchor.show()
	tip.pin_for(anchor, "旧上下文固定说明")
	detail = ReadingDetailOverlay.open_card(host, data)
	await _frames()
	_check("新阅读模态收掉旧固定提示", not tip.visible)
	detail.close()
	await _frames()
	var temporary_owner := Control.new()
	host.add_child(temporary_owner)
	var temporary_id := temporary_owner.get_instance_id()
	var owner_closed: Array = []
	detail = ReadingDetailOverlay.open_card(temporary_owner, data)
	detail.closed.connect(func(): owner_closed.append(true))
	temporary_owner.free()
	_check("宿主删除清理注册且关闭信号一次", not ReadingDetailOverlay._instances.has(temporary_id) and owner_closed.size() == 1)
	tip.free()
	anchor.free()
	await _body_drag_and_occlusion(host, bridge)
	await _keyboard_modal(host, data)
	await _controller_modal(host, data)
	await _pinned_close_on_menu(host)
	host.free()
	if test_bridge: bridge.free()
	if _had_settings:
		var original := FileAccess.open(ReadingSettings.PATH, FileAccess.WRITE)
		original.store_buffer(_settings_bytes)
		original.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ReadingSettings.PATH))
	print("SHARED_READING_COMPONENTS_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

func _body_drag_and_occlusion(host: Control, bridge: Node) -> void:
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(600, 300)
	scroll.size = Vector2(400, 200)
	host.add_child(scroll)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(350, 700)
	scroll.add_child(column)
	var body := CardDescriptionLabel.new()
	body.custom_minimum_size = Vector2(330, 100)
	body.size = Vector2(330, 100)
	body.add_theme_font_size_override("font_size", 32)
	column.add_child(body)
	body.set_content("第一行\n第二行\n第三行\n第四行\n第五行\n结尾", 2)
	await _frames()
	var at := body.get_global_rect().position + Vector2(80, 60)
	bridge._motion(at)
	await _frames()
	var hovered := get_viewport().gui_get_hovered_control()
	_check("正文拖动优先于祖先牌组滚动", CardDescriptionLabel.reading_surface(hovered) == body and bridge._scroll_target(hovered) == null and bridge._direct_drag(hovered))
	bridge._begin(0, at)
	bridge._move(at - Vector2(0, 45))
	bridge._finish(at - Vector2(0, 45))
	await _frames()
	_check("触屏正文拖动可滚动且不滚外层", body.lines_skipped > 0 and scroll.scroll_vertical == 0)
	var shield := Control.new()
	shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shield.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(shield)
	bridge._motion(at)
	await _frames()
	hovered = get_viewport().gui_get_hovered_control()
	_check("遮罩命中不穿透查找正文", hovered == shield and not bridge._direct_drag(hovered))
	bridge._begin(0, at)
	bridge.cancel_active_gesture()
	_check("取消活动手势不留下按下状态", int(bridge.get("_finger")) == -1 and not bool(bridge.get("_mouse_down")))
	shield.free()
	scroll.free()

func _preference_changed() -> void:
	preference_changes += 1

func _keyboard_modal(host: Control, data: CardData) -> void:
	var receiver := KeyReceiver.new()
	host.add_child(receiver)
	ReadingDetailOverlay.open_card(receiver, data)
	await _frames()
	for key: int in [KEY_M, KEY_TAB]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = true
		get_viewport().push_input(event, true)
		event = event.duplicate()
		event.pressed = false
		get_viewport().push_input(event, true)
		await _frames()
	_check("详情消费M和Tab按下松开而不影响底层宿主", receiver.received.is_empty() and receiver.is_visible_in_tree() and ReadingDetailOverlay.is_open_for(receiver))
	receiver.show()
	if not ReadingDetailOverlay.is_open_for(receiver): ReadingDetailOverlay.open_card(receiver, data)
	await _frames()
	var received_before := receiver.received.size()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	get_viewport().push_input(escape, true)
	await _frames()
	_check("Esc关闭详情且不传到底层按键接收器", not ReadingDetailOverlay.is_open_for(receiver) and receiver.is_visible_in_tree() and receiver.received.size() == received_before)
	receiver.free()

func _controller_modal(host: Control, data: CardData) -> void:
	var receiver := KeyReceiver.new()
	host.add_child(receiver)
	var buy := Button.new()
	buy.text = "底层购买"
	buy.focus_mode = Control.FOCUS_ALL
	var purchases: Array = []
	buy.pressed.connect(func(): purchases.append(true))
	receiver.add_child(buy)
	buy.grab_focus()
	ReadingDetailOverlay.open_card(receiver, data)
	await _frames()
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_A
	pad.pressed = true
	get_viewport().push_input(pad, true)
	pad = pad.duplicate()
	pad.pressed = false
	get_viewport().push_input(pad, true)
	var axis := InputEventJoypadMotion.new()
	axis.axis = JOY_AXIS_LEFT_X
	axis.axis_value = 1.0
	get_viewport().push_input(axis, true)
	axis = axis.duplicate()
	axis.axis_value = 0.0
	get_viewport().push_input(axis, true)
	for action: String in ["ui_accept", "ui_focus_next"]:
		var event := InputEventAction.new()
		event.action = action
		event.pressed = true
		get_viewport().push_input(event, true)
		event = event.duplicate()
		event.pressed = false
		get_viewport().push_input(event, true)
	await _frames()
	_check("详情隔离手柄按钮摇杆和合成导航动作", receiver.navigation_received.is_empty() and ReadingDetailOverlay.is_open_for(receiver))
	_check("底层已聚焦购买按钮不被手柄A或ui_accept激活", purchases.is_empty())
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	get_viewport().push_input(cancel, true)
	await _frames()
	_check("合成取消动作只关闭详情", not ReadingDetailOverlay.is_open_for(receiver) and receiver.navigation_received.is_empty() and purchases.is_empty())
	receiver.free()

func _pinned_close_on_menu(host: Control) -> void:
	var menu := RunMenuOverlay.new()
	host.add_child(menu)
	menu.show()
	var anchor: Control = menu.get("_relic_drop_cells")[0]
	var tip := HoverTip.new()
	tip.z_index = 140
	menu.add_child(tip)
	tip.pin_for(anchor, "菜单内固定提示\n关闭按钮应在说明上方", false, anchor.get_global_rect().get_center())
	await _frames()
	var close_button := tip.get_node("ClosePinnedTip") as Button
	_check("真实冒险菜单z500内关闭按钮绘制层级高于提示", menu.z_index == 500 and _canvas_z(close_button) > _canvas_z(tip))
	var at := close_button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion, true)
	await _frames()
	_check("菜单提示关闭按钮通过真实GUI命中", get_viewport().gui_get_hovered_control() == close_button)
	await _click(at)
	_check("菜单提示关闭按钮真实点击收起固定说明", not tip.is_pinned() and menu.is_visible_in_tree())
	menu.free()

func _canvas_z(item: CanvasItem) -> int:
	var result := item.z_index
	if item.is_set_as_top_level() or not item.z_as_relative: return result
	var parent := item.get_parent() as CanvasItem
	return result + _canvas_z(parent) if parent != null else result

func _frames() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

func _push_button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	get_viewport().push_input(event, true)

func _click(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	_push_button(at, true)
	await get_tree().process_frame
	_push_button(at, false)
	await _frames()

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print(("PASS " if passed else "FAIL ") + label)

extends Node
## 固定字号、全文可达及真实 GUI 路由；不访问玩家存档。
const CARD := preload("res://ui/components/card/card_view.tscn")
var checks := 0
var failures := 0
var selected := 0
var _source: CardView
var _surface: Button

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	var short: CardView = CARD.instantiate()
	short.set_texts("短描述", "造成5点伤害")
	short.apply_compact_layout(0.5)
	add_child(short)
	_source = CARD.instantiate()
	_source.set_texts("长描述", "第一段效果\n第二段效果\n第三段效果\n第四段效果\n最后一段效果")
	_source.apply_compact_layout(0.5)
	_source.scale = Vector2.ONE * 0.5
	_source.position = Vector2(500, 150)
	add_child(_source)
	var body: Label = _source.get_node("%效果文本")
	_check("长短描述使用相同大字号", body.get_theme_font_size("font_size") == short.get_node("%效果文本").get_theme_font_size("font_size") and body.get_theme_font_size("font_size") == CardView.LOCAL_BODY_PX)
	_check("长描述保留末段且不省略", body.text.contains("最后一段效果") and not body.text.ends_with("…"))
	var preview: Label = body.get_node("OverflowPreview")
	var body_size := body.size
	_check("长描述底部预告下一行且不撑大文字框", preview.visible and preview.text == body.text.split("\n")[body.max_lines_visible] and preview.position.y < body.size.y and preview.position.y + preview.size.y > body.size.y and preview.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	short.free()
	if not _source.has_method("bind_interaction_button"):
		_check("具有共用描述滚动入口", false)
		_finish()
		return
	_surface = Button.new()
	_surface.position = _source.position
	_surface.size = _source.size * 0.5
	_surface.flat = true
	_surface.pressed.connect(func(): selected += 1)
	add_child(_surface)
	_source.bind_interaction_button(_surface)
	await _frames()
	var point := _point(body, Vector2(0.5, 0.5))
	await _wheel(point, MOUSE_BUTTON_WHEEL_DOWN)
	_check("覆盖按钮上的滚轮移动正文", body.lines_skipped > 0 and selected == 0)
	_check("滚动同步下一行提示且正文框不跳动", preview.text == body.text.split("\n")[body.lines_skipped + body.max_lines_visible] and body.size == body_size)
	for index in 20: await _wheel(point, MOUSE_BUTTON_WHEEL_DOWN)
	_check("滚轮能够到达全文末尾", body.lines_skipped == maxi(0, body.text.split("\n").size() - body.max_lines_visible))
	_check("滚到底不再提示后面还有文字", not preview.visible)
	for index in 20: await _wheel(point, MOUSE_BUTTON_WHEEL_UP)
	_check("向上滚动回到开头", body.lines_skipped == 0)
	await _click(point)
	_check("描述短点保持原按钮行为且只触发一次", selected == 1)
	await _button(point, true)
	await _motion(point - Vector2(0, 100), MOUSE_BUTTON_MASK_LEFT)
	await _button(point - Vector2(0, 100), false)
	_check("拖动描述向后阅读且不触发按钮", body.lines_skipped > 0 and selected == 1)
	await _motion(point)
	await _click(_surface.position + Vector2(80, 80))
	_check("拖完后卡面仍可正常点击", selected == 2)
	await _button(point, true)
	await _motion(point - Vector2(0, 90), MOUSE_BUTTON_MASK_LEFT)
	await _motion(point, MOUSE_BUTTON_MASK_LEFT)
	await _button(point, false)
	_check("拖出又拖回仍不会误判点击", selected == 2)
	await _button(point, true)
	var during_modal := ColorRect.new()
	during_modal.position = _surface.position
	during_modal.size = _surface.size
	during_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(during_modal)
	await _button(point, false)
	_check("按下后出现新遮挡层也不误触底层按钮", selected == 2)
	during_modal.free()
	_surface.disabled = true
	await _wheel(point, MOUSE_BUTTON_WHEEL_UP)
	var disabled_before := body.lines_skipped
	await _click(point)
	_check("禁用按钮仍可读描述且不能触发选择", body.lines_skipped < maxi(0, body.text.split("\n").size() - body.max_lines_visible) and selected == 2)
	_surface.disabled = false
	var modal := ColorRect.new()
	modal.position = _surface.position
	modal.size = _surface.size
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(modal)
	await _wheel(point, MOUSE_BUTTON_WHEEL_DOWN)
	_check("遮挡层阻止滚动穿透", body.lines_skipped == disabled_before)
	modal.free()
	var before_enable := selected
	_surface.disabled = true
	await _button(point, true)
	_surface.disabled = false
	await _button(point, false)
	_check("按下时禁用的按钮不会因松开前启用而触发", selected == before_enable)
	_source.rotation = 0.16
	_source.scale = Vector2.ONE * 0.7
	_surface.hide()
	_source.bind_interaction_button(null)
	await _frames()
	point = _point(body, Vector2(0.5, 0.5))
	var before := body.lines_skipped
	await _wheel(point, MOUSE_BUTTON_WHEEL_UP)
	_check("独立放大及旋转卡面正确换算滚动区域", body.lines_skipped == maxi(0, before - 1))
	await _button(point, true)
	_source.hide()
	await _frames()
	await _button(point - Vector2(0, 80), false)
	_source.show()
	await _motion(point)
	_check("隐藏过程中取消描述拖动", not body.is_processing_input())
	_source.set_texts("新卡", "造成5点伤害")
	_check("换卡清除旧滚动位置", body.lines_skipped == 0)
	_check("短描述不显示截断提示", not preview.visible)
	_finish()

func _point(control: Control, factor: Vector2) -> Vector2:
	return control.get_global_transform_with_canvas() * (control.size * factor)

func _frames() -> void:
	for index in 3: await get_tree().process_frame

func _motion(point: Vector2, mask: int = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.button_mask = mask
	get_viewport().push_input(event, true)
	await _frames()

func _button(point: Vector2, pressed: bool, index: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = index
	event.pressed = pressed
	get_viewport().push_input(event, true)
	await _frames()

func _wheel(point: Vector2, index: MouseButton) -> void:
	await _motion(point)
	await _button(point, true, index)
	await _button(point, false, index)

func _click(point: Vector2) -> void:
	await _motion(point)
	await _button(point, true)
	await _button(point, false)

func _check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print(("PASS " if ok else "FAIL ") + label)

func _finish() -> void:
	print("CARD_DESCRIPTION_SCROLL_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

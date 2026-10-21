extends Button
## 富文本保留名称预览；鼠标交互传给原生按钮，统一处理悬停、按下和点击。
signal reference_entered(reference: Dictionary)
signal reference_exited
var _rich: RichTextLabel
var _references := {}

func configure(plain: String, decorated: Dictionary) -> void:
	text = plain
	_references = decorated.refs
	if is_instance_valid(_rich):
		_rich.text = "[center]" + str(decorated.text) + "[/center]"
		_layout_rich.call_deferred()
		return
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color", "font_focus_color", "font_hover_pressed_color"]:
		add_theme_color_override(state, Color.TRANSPARENT)
	add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	_rich = RichTextLabel.new()
	_rich.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rich.bbcode_enabled = true
	_rich.meta_underlined = false
	_rich.text = "[center]" + str(decorated.text) + "[/center]"
	_rich.scroll_active = false
	_rich.focus_mode = Control.FOCUS_NONE
	_rich.mouse_filter = Control.MOUSE_FILTER_PASS
	_rich.add_theme_font_size_override("normal_font_size", get_theme_font_size("font_size"))
	_rich.add_theme_color_override("default_color", CommonUiSkin.TEXT)
	_rich.add_theme_color_override("font_outline_color", Color(0.04, 0.025, 0.02, 0.95))
	_rich.add_theme_constant_override("outline_size", 2)
	add_child(_rich)
	_rich.meta_hover_started.connect(func(meta: Variant):
		if not disabled and _references.has(str(meta)): reference_entered.emit(_references[str(meta)]))
	_rich.meta_hover_ended.connect(func(_meta: Variant): reference_exited.emit())
	_rich.mouse_exited.connect(func(): reference_exited.emit())
	focus_entered.connect(_preview_focused_reference)
	focus_exited.connect(func(): reference_exited.emit())
	resized.connect(_layout_rich)
	_layout_rich.call_deferred()

func set_caption(plain: String) -> void:
	configure(plain, preload("res://ui/events/event_text_references.gd").decorate(plain, _references.values()))

func _layout_rich() -> void:
	if not is_instance_valid(_rich): return
	var margin := StyleBoxEmpty.new()
	margin.content_margin_left = 18
	margin.content_margin_right = 18
	margin.content_margin_top = maxf(8, (size.y - _rich.get_content_height()) * .5)
	_rich.add_theme_stylebox_override("normal", margin)

func _preview_focused_reference() -> void:
	if disabled or _references.is_empty(): return
	for reference: Dictionary in _references.values():
		if reference.get("kind") == "card": reference_entered.emit(reference); return
	reference_entered.emit(_references.values()[0])

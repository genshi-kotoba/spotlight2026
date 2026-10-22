extends PanelContainer
## Visible map feedback; errors stay until dismissed or replaced by another operation.
var _label: Label
var _generation := 0

func _ready() -> void:
	name = "MapFeedbackBar"
	z_index = 1500
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", CommonUiSkin.panel("strip", Vector4(24, 12, 12, 12)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	add_child(row)
	_label = Label.new()
	_label.name = "FeedbackText"
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.add_theme_font_size_override("font_size", 28)
	_label.add_theme_color_override("font_color", CommonUiSkin.TEXT)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_label)
	var close := Button.new()
	close.name = "DismissFeedback"
	close.text = "关闭"
	close.custom_minimum_size = Vector2(96, 64)
	close.add_theme_font_size_override("font_size", 26)
	CommonUiSkin.style_button(close)
	close.pressed.connect(dismiss)
	row.add_child(close)
	hide()
	get_viewport().size_changed.connect(_layout)
	ReadingSettings.connect_changed(_reading_changed)
	_reading_changed()

func _exit_tree() -> void:
	ReadingSettings.disconnect_changed(_reading_changed)

func _reading_changed() -> void:
	_label.add_theme_font_size_override("font_size", maxi(28, ReadingSettings.body_size()))
	_layout()

func show_message(message: String, sticky := false) -> void:
	_generation += 1
	_label.text = message
	show()
	_layout.call_deferred()
	if sticky: return
	var generation := _generation
	await get_tree().create_timer(5.0).timeout
	if generation == _generation: hide()

func dismiss() -> void:
	_generation += 1
	hide()

func _layout() -> void:
	var bounds := ReadingDetailOverlay.safe_rect_for(self)
	var viewport_size := bounds.size
	var width := minf(1040.0, viewport_size.x - 48.0)
	custom_minimum_size.x = width
	size.x = width
	size.y = get_combined_minimum_size().y
	position = bounds.position + Vector2((viewport_size.x - width) * 0.5, viewport_size.y - size.y - 24)

## 声音设置块：音乐 / 音效两行滑块。
##
## 跑图设置页与开始界面设置页共用这一份，字、色、滑块外观只有这一个来源。
## 内部坐标以 build() 给的 origin 为原点，宿主只管摆位置，不管里面的排版。
##
## 值的读写与落地统一走 AudioSettings，界面自己不碰存档字段：
## 拖动即时写设置并即时生效，不需要确认按钮。

const AUDIO_SETTINGS := preload("res://systems/audio/audio_settings.gd")

## 块占位：标题 28 + 两行 64 间距 + 读数高度。
const BLOCK_SIZE := Vector2(536, 150)
const ROW_NAMES: Array[String] = ["音乐", "音效"]
const TITLE_FONT_SIZE := 20
const ROW_FONT_SIZE := 18
const READOUT_FONT_SIZE := 16
const COL_TITLE := Color(0.910, 0.706, 0.333, 0.85)
const COL_TEXT := Color(0.749, 0.682, 0.553)
const SLIDER_SIZE := Vector2(320, 24)
const ROW_SPACING := 64.0

static var _grabber_texture_cache: Texture2D


## 在 parent 里按 origin 摆一块音量设置，返回块节点本身。
static func build(parent: Control, origin: Vector2 = Vector2.ZERO) -> Control:
	AUDIO_SETTINGS.install()
	var block := Control.new()
	block.name = "VolumeSettings"
	block.position = origin
	block.custom_minimum_size = BLOCK_SIZE
	block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(block)

	var title := _label("声音", TITLE_FONT_SIZE, COL_TITLE)
	title.position = Vector2(0, 0)
	title.size = Vector2(200, 28)
	block.add_child(title)

	for index in AUDIO_SETTINGS.ROW_KEYS.size():
		var key: String = AUDIO_SETTINGS.ROW_KEYS[index]
		var top := 52.0 + index * ROW_SPACING
		var name_label := _label(ROW_NAMES[index], ROW_FONT_SIZE, COL_TEXT)
		name_label.position = Vector2(0, top)
		name_label.size = Vector2(120, 28)
		block.add_child(name_label)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = AUDIO_SETTINGS.volume(key)
		slider.position = Vector2(120, top + 2.0)
		slider.size = SLIDER_SIZE
		slider.custom_minimum_size = SLIDER_SIZE
		slider.focus_mode = Control.FOCUS_NONE
		_skin_slider(slider)
		block.add_child(slider)

		var readout := _label("%d%%" % roundi(slider.value * 100.0), READOUT_FONT_SIZE, COL_TEXT)
		readout.position = Vector2(456, top + 2.0)
		readout.size = Vector2(80, 28)
		block.add_child(readout)
		slider.value_changed.connect(_on_slider_changed.bind(key, readout))

	return block


static func _on_slider_changed(value: float, key: String, readout: Label) -> void:
	readout.text = "%d%%" % roundi(value * 100.0)
	AUDIO_SETTINGS.set_volume(key, value)


static func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func _grabber_texture() -> Texture2D:
	# 默认滑块圆点是引擎灰白样式，和这套暗金面板不搭，这里画一颗金色圆点。
	if _grabber_texture_cache != null:
		return _grabber_texture_cache
	var side := 22
	var image := Image.create(side, side, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var center := Vector2(side, side) * 0.5
	for y in side:
		for x in side:
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(center)
			if distance > 10.0:
				continue
			image.set_pixel(x, y, Color(0.396, 0.290, 0.145) if distance > 8.0
				else Color(0.965, 0.784, 0.416))
	_grabber_texture_cache = ImageTexture.create_from_image(image)
	return _grabber_texture_cache


static func _skin_slider(slider: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.078, 0.063, 0.052, 0.95)
	track.border_color = Color(0.910, 0.706, 0.333, 0.30)
	track.set_border_width_all(1)
	track.set_corner_radius_all(4)
	track.content_margin_top = 6.0
	track.content_margin_bottom = 6.0
	slider.add_theme_stylebox_override("slider", track)
	var filled := track.duplicate() as StyleBoxFlat
	filled.bg_color = Color(0.639, 0.475, 0.196, 1.0)
	filled.border_color = Color(0.910, 0.706, 0.333, 0.55)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)
	slider.add_theme_icon_override("grabber", _grabber_texture())
	slider.add_theme_icon_override("grabber_highlight", _grabber_texture())

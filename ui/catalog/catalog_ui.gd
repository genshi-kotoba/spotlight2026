class_name CatalogUi
extends RefCounted

const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const BACKGROUND_TEXTURE := "res://assets/env/ENV-003/ENV-003.JPG"
const GOLD := Color(0.910, 0.706, 0.333)
const INK := Color("eae2d1")
const MUTED := Color("aaa395")


static func install_theme(root: Control) -> void:
	# 图鉴/成就与战斗、开始界面共用同一套暗金皮：深棕底 + 金边 + 奶油字。
	var skin := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei"])
	skin.default_font = font
	skin.default_font_size = 24
	skin.set_color("font_color", "Label", INK)
	for style_name: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		var normal := style_name == "normal"
		style.bg_color = Color(0.078, 0.065, 0.055, 0.92) if normal \
			else Color(0.165, 0.132, 0.098, 0.98)
		if style_name == "disabled":
			style.bg_color = Color(0.062, 0.052, 0.044, 0.85)
		style.border_color = Color(GOLD, 0.30 if style_name == "disabled" else (0.45 if normal else 0.95))
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		style.content_margin_left = 24
		style.content_margin_right = 24
		style.content_margin_top = 12
		style.content_margin_bottom = 12
		skin.set_stylebox(style_name, "Button", style)
		skin.set_color("font_color", "Button",
			Color(0.52, 0.49, 0.44) if style_name == "disabled" else INK)
		skin.set_color("font_hover_color", "Button", Color(1.0, 0.933, 0.749))
	root.theme = skin


static func panel_style(color: Color = Color("252b37")) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(12)
	return style


static func shell(root: Control, title_text: String, subtitle: String) -> VBoxContainer:
	install_theme(root)
	var art := TextureRect.new()
	art.texture = load(BACKGROUND_TEXTURE) as Texture2D
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(art)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color(0.035, 0.03, 0.028, 0.42)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sheet := Panel.new()
	sheet.name = "Sheet"
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sheet_style := StyleBoxFlat.new()
	sheet_style.bg_color = Color(0.035, 0.03, 0.026, 0.62)
	sheet_style.border_color = Color(GOLD, 0.14)
	sheet_style.set_border_width_all(1)
	sheet_style.set_corner_radius_all(12)
	sheet.add_theme_stylebox_override("panel", sheet_style)
	root.add_child(sheet)
	sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet.offset_left = 24.0
	sheet.offset_top = 24.0
	sheet.offset_right = -24.0
	sheet.offset_bottom = -24.0
	var margin := MarginContainer.new()
	margin.name = "Page"
	root.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 22)
	margin.add_child(body)
	var heading := HBoxContainer.new()
	heading.name = "Heading"
	body.add_child(heading)
	var title := label(title_text, 46)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(0.941, 0.902, 0.804))
	heading.add_child(title)
	var back := button("返回开始界面", "Back")
	heading.add_child(back)
	back.pressed.connect(func():
		var error := root.get_tree().change_scene_to_file("res://ui/main_menu/main_menu.tscn")
		if error != OK:
			push_error("返回开始界面失败：%d" % error))
	var hint := label(subtitle, 22)
	hint.modulate = MUTED
	body.add_child(hint)
	return body


static func label(text: String, font_size: int = 24) -> Label:
	var result := Label.new()
	result.text = text
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.add_theme_font_size_override("font_size", font_size)
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result


static func button(text: String, node_name: String = "") -> Button:
	var result := Button.new()
	result.text = text
	result.name = node_name if not node_name.is_empty() else text
	result.custom_minimum_size = Vector2(180, 60)
	result.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return result


static func clear(container: Node) -> void:
	for child: Node in container.get_children():
		container.remove_child(child)
		# 点击按钮/信号发射期间不能 free()。
		child.queue_free()


## 缩放只发生在外层，不改变卡面预制件的几何约定与战斗表现。
static func preview(parent: Control, entry: Dictionary, category: String, factor: float) -> Control:
	var holder := Control.new()
	holder.name = "Preview"
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.custom_minimum_size = Vector2(480, 818) * factor
	parent.add_child(holder)
	if category != "monsters":
		var card: CardView = CARD_SCENE.instantiate()
		holder.add_child(card)
		card.scale = Vector2.ONE * factor
		card.set_texts(str(entry.get("name", "")), str(entry.get("effect", "")), "")
		card.set_art_texture(TextCatalogService.art_texture(str(entry.get("art_path", ""))))
	else:
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_theme_stylebox_override("panel", panel_style())
		holder.add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(box)
		var art := TextureRect.new()
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.size_flags_vertical = Control.SIZE_EXPAND_FILL
		art.texture = TextCatalogService.art_texture(str(entry.get("art_path", "")))
		box.add_child(art)
		if art.texture == null:
			var placeholder := label("暂无怪物图片", 22)
			placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			placeholder.modulate = MUTED
			box.add_child(placeholder)
		box.add_child(label(str(entry.get("name", "")), 28))
		box.add_child(label(str(entry.get("effect", "")), 22))
	return holder

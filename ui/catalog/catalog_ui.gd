class_name CatalogUi
extends RefCounted

const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const INK := Color("eae2d1")
const MUTED := Color("aaa395")


static func install_theme(root: Control) -> void:
	var skin := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei"])
	skin.default_font = font
	skin.default_font_size = 24
	skin.set_color("font_color", "Label", INK)
	for style_name: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := panel_style(Color("2d3342") if style_name == "normal" else Color("414b60"))
		style.content_margin_left = 24
		style.content_margin_right = 24
		style.content_margin_top = 12
		style.content_margin_bottom = 12
		skin.set_stylebox(style_name, "Button", style)
		skin.set_color("font_color", "Button", INK)
	root.theme = skin


static func panel_style(color: Color = Color("252b37")) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(12)
	return style


static func shell(root: Control, title_text: String, subtitle: String) -> VBoxContainer:
	install_theme(root)
	var background := ColorRect.new()
	background.color = Color("151923")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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

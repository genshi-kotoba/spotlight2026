extends Node
## 卡面纯显示回归，不保存或修改玩家牌组/存档。
var failures := 0
var _samples: Array[CardData] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	var cards: Dictionary = FormalCardCatalog.load_definitions().cards
	for data: CardData in cards.values(): _samples.append(data)
	_samples.sort_custom(func(a: CardData, b: CardData) -> bool: return a.description.length() > b.description.length())
	var geometry_ok := true
	var fit_ok := true
	var preserved := true
	for factor: float in [0.285, 0.5, 0.675]:
		for data: CardData in _samples:
			var view: CardView = load("res://ui/components/card/card_view.tscn").instantiate()
			view.set_card(data)
			view.apply_compact_layout(factor)
			view.scale = Vector2.ONE * factor
			add_child(view)
			var effect: Label = view.get_node("%效果文本")
			var title: Label = view.get_node("%卡名")
			geometry_ok = geometry_ok and _inside(view, title) and _inside(view, effect)
			fit_ok = fit_ok and _fits(view, effect)
			preserved = preserved and effect.text.replace("\n", "") == CardView.strip_period(view._raw_effect).replace("\n", "").replace("\r", "")
			if not _fits(view, effect): print("BOUNDS_DIAG card=", data.card_id, " font=", effect.get_theme_font_size("font_size"), " box=", effect.size, " text=", effect.text)
			view.free()
	_check("所有正式卡在手牌/选牌/悬停比例下文字框位于卡内", geometry_ok)
	_check("所有正式卡在固定字号下显示窗口不越界", fit_ok)
	_check("换行不交换标点或丢失正文", preserved)
	var font := CardView._compact_body_typeface()
	var raw := "造成伤害，获得格挡；恢复生命！"
	_check("窄行中文标点保持顺序", CardText.wrap_to_width(raw, font, 49, 160).replace("\n", "") == raw)
	_check("保留显式换行", CardText.wrap_to_width("第一行\n第二行", font, 30, 330) == "第一行\n第二行")
	# 入树前 set_texts、长标题和极端长文案的兜底。
	var long_card: CardView = load("res://ui/components/card/card_view.tscn").instantiate()
	long_card.set_texts("这是一张名字特别长的卡牌用于测试", "长篇效果描述，".repeat(100))
	long_card.apply_compact_layout(0.5)
	add_child(long_card)
	_check("入树前的自定义文案及极端长描述全文保留", long_card._raw_title.begins_with("这是一张") and long_card.get_node("%效果文本").text.replace("\n", "") == "长篇效果描述，".repeat(100) and _fits(long_card, long_card.get_node("%效果文本")))
	long_card.free()
	var short_card: CardView = load("res://ui/components/card/card_view.tscn").instantiate()
	short_card.set_texts("紧凑测试卡", "造成5点伤害。")
	short_card.apply_compact_layout(0.285)
	add_child(short_card)
	_check("短文案保留原定字号", short_card.get_node("%卡名").get_theme_font_size("font_size") == CardView.LOCAL_TITLE_PX and short_card.get_node("%效果文本").get_theme_font_size("font_size") == CardView.LOCAL_BODY_PX)
	var before: String = short_card.get_node("%效果文本").text
	var before_size: int = short_card.get_node("%效果文本").get_theme_font_size("font_size")
	short_card.scale *= 1.5
	_check("悬停等比放大不重排正文或改变局部字号", short_card.get_node("%效果文本").text == before and short_card.get_node("%效果文本").get_theme_font_size("font_size") == before_size)
	short_card.free()
	for index in mini(6, _samples.size()):
		var view: CardView = load("res://ui/components/card/card_view.tscn").instantiate()
		view.set_card(_samples[index])
		view.apply_compact_layout(0.5)
		view.scale = Vector2.ONE * 0.5
		view.position = Vector2(110 + index % 3 * 560, 65 + index / 3 * 490)
		add_child(view)
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/card-text-bounds-preview.png")
	print("卡牌文字边界：全部通过" if failures == 0 else "卡牌文字边界：失败%d项" % failures)
	get_tree().quit(failures)

func _inside(view: CardView, label: Label) -> bool:
	return Rect2(Vector2.ZERO, view.size).encloses(label.get_rect())

func _fits(view: CardView, label: Label) -> bool:
	var font := label.get_theme_font("font")
	var px := label.get_theme_font_size("font_size")
	if px != CardView.LOCAL_BODY_PX: return false
	for line: String in label.text.split("\n"):
		if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px).x > label.size.x - view.TEXT_SAFETY_PADDING.x + 0.5: return false
	return view._text_height(label, px, mini(label.max_lines_visible, label.text.split("\n").size())) <= label.size.y - view.TEXT_SAFETY_PADDING.y + 0.5

func _check(label: String, result: bool) -> void:
	print(("PASS " if result else "FAIL ") + label)
	if not result: failures += 1

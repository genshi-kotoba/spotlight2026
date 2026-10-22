extends Node
var checks := 0
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var reader := CardReadingPanel.new()
	add_child(reader)
	var definitions: Dictionary = FormalCardCatalog.load_definitions().cards
	var preserved := true
	var all_visible := true
	var within_bounds := true
	var bounds := Rect2(0, 0, 1920, 1080)
	for data: CardData in definitions.values():
		var view: CardView = load("res://ui/components/card/card_view.tscn").instantiate()
		view.set_card(data)
		add_child(view)
		var reading := view.reading_text()
		reader.set_card_text(reading.title, reading.effect)
		reader.place_next_to(Rect2(1500, 850, 140, 230), bounds)
		await get_tree().process_frame
		reader.place_next_to(Rect2(1500, 850, 140, 230), bounds)
		preserved = preserved and reader.body.text.replace("\n", "") == str(reading.effect).replace("\n", "")
		all_visible = all_visible and reader.body.maximum_scroll() == 0
		within_bounds = within_bounds and bounds.encloses(reader.get_global_rect())
		view.free()
	_check("全部正式卡描述完整保留", preserved)
	_check("全部正式卡全文无需滚动即可展示", all_visible)
	_check("屏幕角落自动换边并完整留在视口", within_bounds)
	reader.set_card_text("极长描述", "长篇卡牌效果，".repeat(100))
	var small_bounds := Rect2(0, 0, 1280, 720)
	reader.place_next_to(Rect2(1100, 580, 140, 140), small_bounds)
	await get_tree().process_frame
	reader.place_next_to(Rect2(1100, 580, 140, 140), small_bounds)
	_check("极长描述受屏幕高度限制并可滚动", small_bounds.encloses(reader.get_global_rect()) and reader.body.maximum_scroll() > 0)
	reader.body._scroll_to(reader.body.maximum_scroll())
	_check("极长描述末段仍可到达", reader.body.lines_skipped > 0)
	var large_height := reader.size.y
	reader.set_card_text("短描述", "造成5点伤害")
	reader.place_next_to(Rect2(100, 100, 140, 240), bounds)
	await get_tree().process_frame
	await get_tree().process_frame
	reader.place_next_to(Rect2(100, 100, 140, 240), bounds)
	_check("切到短描述后面板缩短且滚动归零", reader.size.y < large_height and reader.body.lines_skipped == 0 and reader.body.maximum_scroll() == 0)
	_check("说明字号不随文案长度缩小", reader.body.get_theme_font_size("font_size") == CardReadingPanel.BODY_SIZE)
	print("CARD_READING_PANEL_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print(("PASS " if passed else "FAIL ") + label)

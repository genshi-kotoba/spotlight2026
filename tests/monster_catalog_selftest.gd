extends Node

var failures := 0
var fixture_root := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = "res://.godot/monster-catalog-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(fixture_root))
	var gateway := get_node("/root/SaveGateway")
	gateway.save_path = fixture_root.path_join("game.json")
	_check("独立测试档案，不修改玩家存档", gateway.load_current() == OK)
	_check("正式目录导入成功", TextCatalog.reload() == OK and TextCatalog.error_message("monsters").is_empty())
	var entries := TextCatalog.entries("monsters")
	_check("导入怪物表全部23条记录", entries.size() == 23)
	var names := ["炼金术士·贤者之石", "躯壳", "修格斯", "腐化学徒", "实验耗材", "强化恶犬", "解刨者", "遗言", "鼠王", "壹叁伍零，拾骨之年", "后巷公爵，无底坑之王", "腐化圣骑士", "彩衣笛手", "“后巷骑士”", "窃贼与骗子", "福音唱诗班", "三位一体", "哀悼圣母", "代为赎罪", "修女", "苦修士", "虔诚匍匐", "人造之神，方舟缔造者"]
	var elites := [2, 9, 12, 13, 18, 19]
	var bosses := [1, 10, 11, 16, 17, 23]
	for index in entries.size():
		var record: Dictionary = entries[index]
		var number := index + 1
		var floor_number := 1 if number <= 8 else (2 if number <= 15 else (3 if number <= 22 else 4))
		var rank := "BOSS" if number in bosses else ("精英" if number in elites else "普通")
		_check("%d号字段、原名、自然排序与类型出现层数" % number,
			record.size() == 7 and record.id == str(number) and record.name == names[index]
			and record.art_path == "res://assets/chr/CHR-%03d.png" % (number + 2)
			and record.type == "%s · 第%d层" % [rank, floor_number]
			and record.effect == "暂无" and record.text != "暂无"
			and record.battle_text_path == "res://assets/chr/CHR-%03d.txt" % (number + 2))
		var texture := TextCatalogService.art_texture(record.art_path)
		_check("%d号实际图片可加载" % number, texture != null and texture.get_width() > 0 and texture.get_height() > 0)
	_check("缺省状态全部未解锁，不自动授予进度", TextCatalog.entries("monsters", TextCatalogService.DisplayMode.LOCKED).size() == 23 and TextCatalog.entries("monsters", TextCatalogService.DisplayMode.UNLOCKED).is_empty())
	var page: Control = load("res://ui/catalog/encyclopedia.tscn").instantiate()
	add_child(page)
	await _frames(5)
	page._category_buttons["monsters"].pressed.emit()
	await _frames(5)
	_check("图鉴怪物按钮显示23条真实数据", page.category == "monsters" and page.visible_entries.size() == 23 and page._grid.get_child_count() == 23)
	await _capture("monsters-grid.png")
	await _click(page._grid.get_child(0).get_node("OpenDetail"))
	_check("真实鼠标点击怪物打开详情", page._detail.visible and page.detail_entry.id == "1")
	_check("详情左预览右类型/出现地/分隔线/叙述", page._detail_card.get_child_count() == 1 and page._detail_fields.get_child_count() == 4)
	_check("详情显示表格图鉴文本而非战斗台词", page._detail_fields.get_node("text").text == entries[0].text and page._detail_fields.get_node("type").text == "类型\nBOSS" and page._detail_fields.get_node("location").text == "出现地\n炼金工坊")
	_check("未解锁条目仍可查看且不显示状态字段", page._detail.visible and not page._detail_fields.has_node("unlock_state"))
	await _click(page._detail.get_node("Panel/Content/Heading/Close"))
	_check("真实鼠标关闭详情", not page._detail.visible)
	for record: Dictionary in entries:
		page.open_detail(record.id)
		var preview: Control = page._detail_card.get_child(0)
		var image := _first_texture(preview)
		_check("%s号详情展示对应图片和名称" % record.id, image != null and image.texture.resource_path == record.art_path and page._detail_card.find_child("MonsterName", true, false).text == record.name)
	page.open_detail("23")
	await _frames(4)
	await _capture("monster-23-detail.png")
	page.close_detail()
	page._mode_button.pressed.emit()
	_check("已解锁模式初始为空", page.display_mode == 1 and page.visible_entries.is_empty())
	page._mode_button.pressed.emit()
	_check("未解锁模式显示23项", page.display_mode == 2 and page.visible_entries.size() == 23)
	page._mode_button.pressed.emit()
	_check("模式循环回全部", page.display_mode == 0 and page.visible_entries.size() == 23)
	_check("怪物按图鉴编号解锁并保存", TextCatalog.unlock_entry("monsters", "23") == OK)
	_check("怪物编号不会串到同号卡牌解锁", not TextCatalog.is_unlocked("cards", "23"))
	_check("重载CSV不重置怪物解锁", TextCatalog.reload() == OK and TextCatalog.is_unlocked("monsters", "23"))
	page.set_display_mode(1)
	_check("已解锁筛选只显示23号", page.visible_entries.size() == 1 and page.visible_entries[0].id == "23")
	page.open_detail("23")
	_check("解锁筛选可看详情但不新增状态字段", page._detail.visible and not page._detail_fields.has_node("unlock_state"))
	page.close_detail()
	page.set_display_mode(2)
	_check("未解锁筛选排除23号", page.visible_entries.size() == 22 and not page.visible_entries.any(func(record: Dictionary): return record.id == "23"))
	_check("单存档冷载入保留怪物解锁", gateway.load_current() == OK and TextCatalog.is_unlocked("monsters", "23"))
	_check("图片资产编号不能冒充图鉴编号", TextCatalog.unlock_entry("monsters", "CHR-025") == ERR_INVALID_PARAMETER)
	_check("卡牌保留新版70条、残片33条且成就未变", TextCatalog.entries("cards").size() == 70 and TextCatalog.entries("fragments").size() == 33 and TextCatalog.entries("achievements").is_empty())
	page.queue_free()
	await _frames(3)
	print("怪物图鉴自测：全部通过" if failures == 0 else "怪物图鉴自测：%d 项失败" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _first_texture(node: Node) -> TextureRect:
	if node is TextureRect:
		return node
	for child: Node in node.get_children():
		var found := _first_texture(child)
		if found != null:
			return found
	return null


func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))


func _click(button: Button) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = button.get_global_rect().get_center()
	press.pressed = true
	get_viewport().push_input(press, true)
	await _frames(1)
	press = press.duplicate()
	press.pressed = false
	get_viewport().push_input(press, true)
	await _frames(4)


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1

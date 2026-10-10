extends Node

const ENCYCLOPEDIA := "res://ui/catalog/encyclopedia.tscn"
const ACHIEVEMENTS := "res://ui/catalog/achievements.tscn"
const MENU := "res://ui/main_menu/main_menu.tscn"
var failures := 0
var fixture_root := ""
var original_paths: Dictionary
var gateway: Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	# 测试协程保留为 root 子节点；切换被测场景不会销毁测试本身。
	get_tree().current_scene = null
	gateway = get_node("/root/SaveGateway")
	fixture_root = "res://.godot/text-catalog-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(fixture_root))
	gateway.profile_path = fixture_root.path_join("profile.json")
	gateway.slot_paths.assign([fixture_root.path_join("slot1.json"), fixture_root.path_join("slot2.json"), fixture_root.path_join("slot3.json")])
	gateway._active_slot = 1
	_check("使用隔离档案，不写玩家存档", gateway._load_slot(1) == OK)
	original_paths = TextCatalog.paths.duplicate()
	_check("四份正式空 CSV 都可导入", TextCatalog.reload() == OK)
	for category: String in TextCatalogService.CATEGORIES:
		_check(category + " 正式模板只有表头", TextCatalog.entries(category).is_empty())
	_parser_checks()
	_fixture_tables()
	_check("测试表导入", TextCatalog.reload() == OK)
	var runtime_card: CardView = CatalogUi.CARD_SCENE.instantiate()
	add_child(runtime_card)
	var runtime_data := CardData.new()
	runtime_data.card_id = &"10"
	runtime_data.card_name = "原测试资源名"
	runtime_data.description = "原测试资源文本"
	runtime_card.set_card(runtime_data)
	_check("战斗卡面复用 CSV 文本但不改动规则资源", runtime_card.get_node("卡名").text == "十号测试卡" and runtime_data.card_name == "原测试资源名")
	var manual_card: CardView = CatalogUi.CARD_SCENE.instantiate()
	add_child(manual_card)
	manual_card.set_texts("手写图鉴卡", "手写效果", "")
	TextCatalog.reload()
	_check("目录重载更新运行卡而不清空手写预览", runtime_card.get_node("卡名").text == "十号测试卡" and manual_card.get_node("卡名").text == "手写图鉴卡")
	manual_card.queue_free()
	runtime_card.queue_free()
	_check("按编号自然排序", TextCatalog.entries("cards").map(func(r: Dictionary): return r.id) == ["2", "10", "CARD-003"])
	_check("卡牌初始全部未解锁", TextCatalog.entries("cards", TextCatalogService.DisplayMode.LOCKED).size() == 3)
	_check("卡牌解锁接口保存", TextCatalog.unlock_entry("cards", "10") == OK)
	_check("残片解锁接口保存", TextCatalog.unlock_entry("fragments", "R-002") == OK)
	_check("怪物解锁接口保存", TextCatalog.unlock_entry("monsters", "M-002") == OK)
	_check("显式完成成就保存", TextCatalog.complete_achievement("A-002", {"test": true}) == OK)
	var stamp: Variant = GlobalState.achievements["A-002"].completed_at
	_check("成就完成幂等", TextCatalog.complete_achievement("A-002") == OK and GlobalState.achievements["A-002"].completed_at == stamp)
	_check("未知编号/类别不允许写进度", TextCatalog.unlock_entry("unknown", "10") == ERR_INVALID_PARAMETER and TextCatalog.complete_achievement("missing") == ERR_INVALID_PARAMETER)
	_check("CSV 重载不重置解锁", TextCatalog.reload() == OK and TextCatalog.is_unlocked("cards", "10"))
	_check("切空档不继承进度", gateway.set_active_slot(2) == OK and not TextCatalog.is_unlocked("cards", "10") and not TextCatalog.is_unlocked("fragments", "R-002") and not TextCatalog.is_unlocked("achievements", "A-002"))
	_check("恢复档案独立保存所有进度", gateway.set_active_slot(1) == OK and TextCatalog.is_unlocked("cards", "10") and TextCatalog.is_unlocked("fragments", "R-002") and TextCatalog.is_unlocked("monsters", "M-002") and TextCatalog.is_unlocked("achievements", "A-002"))
	_legacy_save_checks()
	var page: Control = await _scene(ENCYCLOPEDIA)
	_check("默认卡牌/所有模式", page.category == "cards" and page.display_mode == 0 and page.visible_entries.size() == 3)
	var preview: CardView = page._grid.get_child(1).get_node("OpenDetail/Preview/CardView")
	_check("卡面仅名称/效果，隐藏自由文本", preview.get_node("卡名").text == "十号测试卡" and preview.get_node("效果文本").text == "造成测试伤害" and not preview.get_node("介绍文本").visible)
	await _click(page._grid.get_child(0).get_node("OpenDetail").get_global_rect().get_center())
	_check("真实鼠标点击不会被卡面阻挡", page._detail.visible and page.detail_entry.id == "2")
	await _click(page._detail.get_node("Panel/Content/Heading/Close").get_global_rect().get_center())
	_check("真实鼠标关闭详情", not page._detail.visible)
	# 真实输入路径：pressed 信号中打开/关闭详情，避免 locked free 回归。
	page._grid.get_child(1).get_node("OpenDetail").pressed.emit()
	_check("详情左卡右全部七属性", page._detail.visible and page.detail_entry.id == "10" and page._detail_fields.get_child_count() == 7 and page._detail_card.get_child_count() == 1)
	_check("详情包含隐藏属性及真实状态", page._detail_fields.get_node("text").text.contains("只在详情显示") and page._detail_fields.get_node("unlock_state").text.contains("已解锁"))
	await _frames()
	await _capture("catalog-detail.png")
	page._detail.get_node("Panel/Content/Heading/Close").pressed.emit()
	_check("关闭详情", not page._detail.visible)
	page._mode_button.pressed.emit()
	_check("筛选已解锁", page.visible_entries.size() == 1 and page.visible_entries[0].id == "10")
	page._mode_button.pressed.emit()
	_check("筛选未解锁", page.visible_entries.size() == 2)
	page._mode_button.pressed.emit()
	_check("模式循环回所有", page.visible_entries.size() == 3 and page.display_mode == 0)
	page._category_buttons["fragments"].pressed.emit()
	_check("切换残片用独立表", page.category == "fragments" and page.visible_entries.size() == 2)
	page.set_display_mode(1)
	_check("残片已解锁筛选", page.visible_entries.size() == 1 and page.visible_entries[0].id == "R-002")
	page.open_detail("R-002")
	_check("残片同样显示七属性", page._detail_fields.get_child_count() == 7)
	page._category_buttons["monsters"].pressed.emit()
	_check("怪物切换与筛选", page.category == "monsters" and page.visible_entries.size() == 1)
	page.open_detail("M-002")
	_check("怪物能力/类型出现地字段", page._detail_fields.get_node("type").text.contains("类型与出现地") and page._detail_fields.get_node("effect").text.contains("能力文本"))
	await _frames()
	await _capture("catalog-monster.png")
	page.select_category("cards")
	page.set_display_mode(0)
	await _frames()
	await _capture("catalog-grid.png")
	page = await _scene(ACHIEVEMENTS)
	_check("成就按编号显示全部条目", page.visible_entries.size() == 2 and page.visible_entries[0].id == "A-002")
	var item: PanelContainer = page._list.get_child(0)
	_check("成就不使用按钮/不提供详情，只显示三属性", item.get_child(0).get_child_count() == 3 and _buttons(item) == 0 and not page.has_node("Detail"))
	await _capture("catalog-achievements.png")
	page.get_node("Page").get_child(0).get_node("Heading/Back").pressed.emit()
	await _frames()
	page = get_tree().current_scene
	_check("返回菜单", page.scene_file_path == MENU)
	page.get_node("按钮列/图鉴").pressed.emit()
	await _frames()
	_check("菜单图鉴按钮真实导航", get_tree().current_scene.scene_file_path == ENCYCLOPEDIA)
	page = await _scene(MENU)
	page.get_node("按钮列/成就").pressed.emit()
	await _frames()
	_check("菜单成就按钮真实导航", get_tree().current_scene.scene_file_path == ACHIEVEMENTS)
	TextCatalog.paths = original_paths
	TextCatalog.reload()
	page = await _scene(ENCYCLOPEDIA)
	_check("空模板明确空态", page.visible_entries.is_empty() and page._status.text.contains("暂无条目"))
	await _capture("catalog-empty.png")
	page = await _scene(MENU)
	await _capture("catalog-menu.png")
	print("文本与图鉴自测：全部通过" if failures == 0 else "文本与图鉴自测：%d 项失败" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _parser_checks() -> void:
	var headers := TextCatalogService.CARD_HEADERS
	var keys := TextCatalogService.ENTRY_KEYS
	var header := ",".join(headers) + "\r\n"
	var parsed := CsvTextTable.parse("\uFEFF" + header + "2,,测试,\"含逗号,和\"\"引号\"\"\n多行\",类型,文本\r\n", headers, keys)
	_check("BOM/CRLF/逗号/引号/跨行", parsed.error == OK and parsed.records.size() == 1 and parsed.records[0].effect == "含逗号,和\"引号\"\n多行")
	_check("空行忽略，只有表头合法", CsvTextTable.parse(header + "\r\n", headers, keys).error == OK)
	for malformed: String in ["错误表头\n", header + "2,,甲,效果,类型,文本\n2,,乙,效果,类型,文本", header + ",,无编号,效果,类型,文本", header + "2,列数不足", header + "2,,甲,\"未闭合", header + "2,,甲,\"效果\"尾部,类型,文本"]:
		var result := CsvTextTable.parse(malformed, headers, keys)
		_check("错误 CSV 整表拒绝", result.error != OK and result.records.is_empty())
	_check("参数替换不会递归/丢未知参数", TextCatalogService.format_text("{a} / {b}", {"a": "{b}"}) == "{b} / {b}")
	_check("不从任意资源路径加载脚本", TextCatalogService.art_texture("res://ui/main_menu/main_menu.gd") == null and TextCatalogService.art_texture("user://bad.png") == null)
	_check("项目内图片可加载", TextCatalogService.art_texture("res://assets/battle_test/CHR-025.png") != null)
	_check("TXT 禁止路径逃逸", TextCatalog.read_text("res://data/text/../secrets.txt").error == ERR_INVALID_PARAMETER)
	var text_path := fixture_root.path_join("event.txt")
	var text_file := FileAccess.open(text_path, FileAccess.WRITE)
	text_file.store_string("测试 {value}")
	text_file.close()
	var text_result := TextCatalog.read_text(text_path, {"value": 7})
	_check("TXT 读取与动态参数", text_result.error == OK and text_result.text == "测试 7")
	_check("TXT 缺失报告错误", TextCatalog.read_text(fixture_root.path_join("missing.txt")).error != OK)


func _legacy_save_checks() -> void:
	var data: Dictionary = gateway._read_json(gateway.slot_path(1)).data.duplicate(true)
	var legacy := data.duplicate(true)
	legacy.erase("unlocked_fragments")
	legacy.erase("unlocked_monsters")
	var candidate := GlobalStateMachine.new()
	_check("旧 v1 存档兼容可选解锁字段", candidate._install_save(legacy) == OK and candidate.unlocked_fragments.is_empty() and candidate.unlocked_cards.has("10"))
	var invalid := data.duplicate(true)
	invalid["unlocked_monsters"] = [42]
	_check("非法解锁状态拒绝，不修改旧数据", candidate._install_save(invalid) == ERR_INVALID_DATA and candidate.unlocked_monsters.is_empty() and candidate.unlocked_cards.has("10"))
	candidate.free()


func _fixture_tables() -> void:
	_write_table("cards", TextCatalogService.CARD_HEADERS, [
		["10", "", "十号测试卡", "造成测试伤害", "攻击", "只在详情显示的背景文本"],
		["2", "res://assets/battle_test/CHR-025.png", "二号测试卡", "测试多行效果\n含逗号,与引号\"", "技能", "详情长文本\n".repeat(18)],
		["CARD-003", "", "空插画测试", "无效果", "测试", "介绍"],
	])
	_write_table("fragments", TextCatalogService.CARD_HEADERS, [
		["R-010", "", "测试触发残片", "周围四格", "触发", "残片详情"],
		["R-002", "", "测试效果残片", "获得格挡", "效果", "残片说明"],
	])
	_write_table("monsters", TextCatalogService.MONSTER_HEADERS, [
		["M-010", "", "测试怪物十", "无能力", "普通 / 第一地区", "详情"],
		["M-002", "res://assets/battle_test/CHR-025.png", "测试怪物二", "测试能力", "精英 / 第二地区", "怪物背景文本"],
	])
	_write_table("achievements", TextCatalogService.ACHIEVEMENT_HEADERS, [
		["A-010", "测试成就十", "未定义机器条件的说明", "未定义奖励规则的说明"],
		["A-002", "测试成就二", "完成测试", "测试奖励（仅文本）"],
	])


func _write_table(category: String, headers: Array, rows: Array) -> void:
	var path := fixture_root.path_join(category + ".csv")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_csv_line(PackedStringArray(headers))
	for row: Array in rows:
		file.store_csv_line(PackedStringArray(row))
	file.close()
	TextCatalog.paths[category] = path


func _scene(path: String) -> Control:
	var error := get_tree().change_scene_to_file(path)
	_check("场景切换成功：" + path, error == OK)
	await _frames()
	return get_tree().current_scene as Control


func _frames() -> void:
	for i: int in 4:
		await get_tree().process_frame


func _click(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = point
	press.pressed = true
	get_viewport().push_input(press, true)
	await get_tree().process_frame
	press = press.duplicate()
	press.pressed = false
	get_viewport().push_input(press, true)
	await _frames()


func _capture(filename: String) -> void:
	# 图形模式额外检查实际渲染；headless 下不读取虚拟纹理。
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))


func _buttons(node: Node) -> int:
	var count := int(node is BaseButton)
	for child: Node in node.get_children():
		count += _buttons(child)
	return count


func _check(label: String, passed: bool) -> void:
	print("PASS " + label if passed else "FAIL " + label)
	if not passed:
		failures += 1

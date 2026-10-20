extends Node

var failures := 0
var fixture_root := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = "res://.godot/ui-optimization-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("独立档案加载", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "ui-optimization"
	_check("正式新局", SaveGateway.start_new_run("ui-optimization", config) == OK)
	var run := SaveGateway.current_run()
	_check("新局8张牌、12格空典籍、空背包", run.deck.size() == 8 and run.items.is_empty() and RunRewards.board_for_run(run).cells.count("") == 12)
	var geometry_ok := RelicBookGeometry.CELL_COUNT == 12
	for index in 12:
		geometry_ok = geometry_ok and RelicBookGeometry.cell_at(RelicBookGeometry.cell_center(index, RelicBookView.BOOK_SIZE), RelicBookView.BOOK_SIZE) == index
	_check("12格透视中心命中，不接受第13格", geometry_ok and RelicBookGeometry.cell_quad(12, RelicBookView.BOOK_SIZE).is_empty())
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	var menu := RunMenuOverlay.new()
	add_child(menu)
	menu.open(1)
	await _settle()
	_check("UI补齐21空槽不注入物品或限制背包容量", menu._item_grid.get_child_count() == 21 and run.items.is_empty())
	run.items.assign([
		{"item_id": "fragment-a", "kind": "fragment", "fragment_id": "deal_damage"},
		{"item_id": "fragment-b", "kind": "fragment", "fragment_id": "deal_damage"},
		{"item_id": "fragment-c", "kind": "fragment", "fragment_id": "gain_block"},
	])
	menu._refresh_data()
	await _settle()
	# 同名两份残片必须按 item_id 精确移动，不能消耗另一个副本。
	await _drag(menu._item_grid.get_child(1), menu._relic_drop_cells[0])
	_check("真实鼠标拖拽精确装入第二份同名残片", RunRewards.board_for_run(run).cells[0] == "deal_damage" and RunRewards.item(run, "fragment-b").is_empty() and not RunRewards.item(run, "fragment-a").is_empty())
	await _drag(menu._item_grid.get_child(1), menu._relic_drop_cells[1])
	_check("第二种残片可拖入", RunRewards.board_for_run(run).cells[1] == "gain_block" and run.items.size() == 1)
	await _drag(menu._relic_drop_cells[0], menu._relic_drop_cells[1])
	_check("已装残片互换，不复制到背包", RunRewards.board_for_run(run).cells[0] == "gain_block" and RunRewards.board_for_run(run).cells[1] == "deal_damage" and run.items.size() == 1)
	var snapshot := JSON.stringify(run.to_dictionary())
	var old_error := SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("换位保存失败", RunRewards.move_fragment(run, 0, 2) != OK)
	SaveGateway._load_error = old_error
	_check("失败完整回滚", JSON.stringify(run.to_dictionary()) == snapshot)
	_check("越界与空格被拒绝", RunRewards.move_fragment(run, 0, 12) == ERR_INVALID_PARAMETER and RunRewards.move_fragment(run, 11, 0) == ERR_DOES_NOT_EXIST)
	await _click(menu._relic_drop_cells[1], MOUSE_BUTTON_RIGHT)
	_check("右键卸下仅返回一份", RunRewards.board_for_run(run).cells[1].is_empty() and run.items.size() == 2)
	await _click(menu._item_grid.get_child(0))
	await _click(menu._relic_drop_cells[2])
	_check("保留原点击残片再点空格的装配方式", RunRewards.board_for_run(run).cells[2] == "deal_damage" and RunRewards.item(run, "fragment-a").is_empty())
	# 清除选中状态后从已装格拖回背包，走与右键相同的事务。
	await _drag(menu._relic_drop_cells[2], menu._item_grid.get_child(3))
	_check("拖回背包不丢失副本", RunRewards.board_for_run(run).cells[2].is_empty() and run.items.size() == 2)
	for index in 24:
		run.items.append({"item_id": "extra-%d" % index, "kind": "fragment", "fragment_id": "gain_block"})
	menu._refresh_data()
	await _settle()
	_check("超过21件仍完整显示并可滚动", menu._item_grid.get_child_count() == 26 and run.items.size() == 26)
	_check("背包操作不消耗种子随机流", JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _capture("backpack.png")
	menu.close()
	menu.queue_free()
	await _frames(2)
	var book := RelicBookView.new()
	add_child(book)
	var catalog := RelicCatalog.load_definitions()
	var board := RunRewards.board_for_run(run)
	book.set_board(catalog, board)
	book.flash_cell(0)
	await _frames(2)
	var energy := book._flash[0]
	book.set_board(catalog, board)
	_check("快照刷新不擦除残片触发光效", energy > 0 and is_equal_approx(book._flash[0], energy))
	book.attach_tip(self, 120)
	book._set_hovered(0)
	_check("透视格显示真实名称与效果浮层", book.hover_tip.visible and book.hover_tip.get_node("TipLabel").text.contains(catalog[board.cells[0]].display_name))
	book.queue_free()
	await _frames(2)
	var battle: BattleTestScene = load("res://ui/battle/formal_card_test_scene.tscn").instantiate()
	battle.relic_board_path = fixture_root.path_join("empty.json")
	add_child(battle)
	await _frames(5)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(battle)
	menu = battle._run_menu
	battle._open_run_menu(1)
	await _settle()
	snapshot = JSON.stringify(run.to_dictionary())
	await _drag(menu._relic_drop_cells[0], menu._relic_drop_cells[1])
	menu._on_item_pressed(str(run.items[0].item_id))
	menu._relic_cell_input(_button(Vector2.ZERO, MOUSE_BUTTON_RIGHT, true), 0)
	_check("战斗菜单不能拖拽、卸下、装配或开包", JSON.stringify(run.to_dictionary()) == snapshot and menu._drag_ghost == null)
	menu.close()
	var cards: Array[Dictionary] = [{"card_id": "1", "instance_id": "preview-only", "enchantments": ["damage_50", "repeat_2"]}, {"card_id": "50", "instance_id": "block-only"}]
	var battle_before := JSON.stringify(battle._battle.to_dictionary())
	seed_before = JSON.stringify(SeedService.capture_snapshot())
	var values := BattleDirectPreview.calculate(battle._battle, cards, battle._resolver.card_catalog)
	_check("正式指令及附魔只读数值预览", int(values.damage) == 14 and int(values.block) > 0 and JSON.stringify(battle._battle.to_dictionary()) == battle_before and JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	battle._on_hand_card_pressed(str(battle._battle.hand[0].instance_id))
	await _frames(3)
	var row: Control = battle.play_cards.get_child(0)
	battle._on_play_card_hover(row.get_child(0), true, str(battle._selected_ids[0]))
	_check("出牌列悬停显示同一正式卡大图", battle._resolve_preview.visible and str(battle._resolve_view.get_card_id()) == str(battle._selected_cards[0].card_id))
	battle._on_play_card_hover(row.get_child(0), false, str(battle._selected_ids[0]))
	_check("离开出牌列收起预览", not battle._resolve_preview.visible)
	await _capture("battle.png")
	var hand_slot: Control = battle.hand_cards.get_child(5)
	battle._on_hand_card_hover_changed(hand_slot, hand_slot.get_child(0), true)
	await get_tree().create_timer(0.6).timeout
	await _capture("hand-hover.png")
	battle._on_hand_card_hover_changed(hand_slot, hand_slot.get_child(0), false)
	battle.enemy_rack.slots[0].set_meta("portrait_home", battle.enemy_rack.slots[0].portrait.position)
	battle._feedback.on_damaged(&"enemy", 2, 0, str(battle._battle.enemies[0].enemy_id))
	await get_tree().create_timer(0.08).timeout
	battle._feedback.on_damaged(&"enemy", 2, 0, str(battle._battle.enemies[0].enemy_id))
	await get_tree().create_timer(0.35).timeout
	_check("连续受击震动后恢复原位", battle.enemy_rack.slots[0].portrait.position.is_equal_approx(battle.enemy_rack.slots[0].get_meta("portrait_home")))
	battle.queue_free()
	await _frames(2)
	print("新版UI优化整合：全部通过" if failures == 0 else "新版UI优化整合：失败%d项" % failures)
	get_tree().quit(failures)


func _settle() -> void:
	await get_tree().create_timer(0.26).timeout
	await _frames(2)


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _button(point: Vector2, index: MouseButton, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.position = point
	event.pressed = pressed
	return event


func _click(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var point := control.get_global_rect().get_center()
	get_viewport().push_input(_button(point, button, true), true)
	await _frames(1)
	get_viewport().push_input(_button(point, button, false), true)
	await _frames(3)


func _drag(source: Control, target: Control) -> void:
	var start := source.get_global_rect().get_center()
	var end := target.get_global_rect().get_center()
	get_viewport().push_input(_button(start, MOUSE_BUTTON_LEFT, true), true)
	await _frames(1)
	var motion := InputEventMouseMotion.new()
	motion.position = end
	motion.relative = end - start
	get_viewport().push_input(motion, true)
	await _frames(1)
	get_viewport().push_input(_button(end, MOUSE_BUTTON_LEFT, false), true)
	await _frames(3)


func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

extends "res://tests/map_entry_input_selftest.gd"
## 新版2.5D地图与UI的真实接线回归，全部数据写入隔离目录。
func _run() -> void:
	fixture_root = "res://.godot/map-ui-merge-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("隔离档案", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "map-ui-merge"
	_check("真实初始牌组开局", SaveGateway.start_new_run("map-ui-merge-v1", config) == OK)
	var run := SaveGateway.current_run()
	run.gold = 321
	run.inventory_state.elixir = 2
	var map: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(map)
	get_tree().current_scene = map
	await _frames(6)
	_check("正式入口使用新版2.5D渲染器并已就绪", map.is_map_ready() and map._view == MapPresentation.renderer and not map.height_layer.is_empty())
	_check("地图表现保留main八张初始牌和完整典籍", run.deck.size() == 8 and RunRewards.board_for_run(run).cells.size() == RelicBoard.CELL_COUNT)
	await _capture("map-relief.png")
	var renderer: Node2D = map._view
	var target := _approach(map)
	_check("找到可交互敌人", not target.is_empty())
	await _press_e()
	var battle := get_tree().current_scene as BattleTestScene
	_check("进入main真实战斗且完成开局", battle != null and battle._battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and not battle._busy)
	if battle == null:
		get_tree().quit(1)
		return
	_check("离开地图只隐藏缓存不重建或泄漏画面", MapPresentation.renderer == renderer and not renderer.visible)
	_check("新版战斗读取真实银币和万灵药", battle.get_node("Coin/Count").text == "321" and battle.get_node("Elixir/Count").text == "2")
	_check("新UI书页格数不变，出牌卡面仍是手牌一半", battle._relic_book._cells.size() == RelicBoard.CELL_COUNT and is_equal_approx(battle.PLAY_CARD_SCALE, battle.HAND_CARD_SCALE * 0.5))
	var first_id := str(battle._battle.hand[0].instance_id)
	var second_id := str(battle._battle.hand[1].instance_id)
	battle._on_hand_card_pressed(first_id)
	battle._on_hand_card_pressed(second_id)
	await _frames(5)
	# 从出牌列第一张拖到第二张后面；UI只改编排序列，未提前移动底层手牌。
	var row: Control = battle.play_cards.get_child(0)
	var begin := row.global_position + Vector2(battle.PLAY_POINTER_W + 15, 20)
	var end := battle.play_cards.global_position + Vector2(battle.PLAY_POINTER_W + 15, battle.PLAY_STEP * 2 + 5)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = begin
	press.pressed = true
	get_viewport().push_input(press, true)
	var motion := InputEventMouseMotion.new()
	motion.position = end
	motion.relative = end - begin
	get_viewport().push_input(motion, true)
	press = press.duplicate()
	press.position = end
	press.pressed = false
	get_viewport().push_input(press, true)
	await _frames(6)
	_check("真实鼠标拖动编排不污染main手牌", battle._selected_ids == [second_id, first_id] and battle._battle.hand.size() == 8)
	await _capture("battle-merged.png")
	battle._on_cancel_pressed()
	await _frames(3)
	battle._open_run_menu(1)
	await _frames(3)
	_check("背包读取真实八张牌、银币和万灵药", battle._run_menu._deck_grid.get_child_count() == 8 and battle._run_menu._resources.text.contains("321") and battle._run_menu._resources.text.contains("2"))
	await _capture("backpack-merged.png")
	battle._run_menu.close()
	# 动态出牌上限超过10时，新UI仍单列滚动，不在屏幕外开第二列。
	for i in 12:
		var card: Dictionary = battle._battle.hand[0].duplicate(true)
		card.instance_id = "display-only-%d" % i
		battle.play_cards.add_child(battle._make_play_row(card))
	battle._layout_play_rows()
	var one_column := true
	for child: Control in battle.play_cards.get_children():
		one_column = one_column and is_zero_approx(child.position.x)
	_check("十二张显示仍保持单列并扩展滚动高度", one_column and battle.play_cards.size.y > battle.play_scroll.size.y)
	print("地图UI新版整合：全部通过" if failures == 0 else "地图UI新版整合：失败%d项" % failures)
	get_tree().quit(failures)

func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))

extends Node

var failures := 0
var fixture_root := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = "res://.godot/prg017018-ui-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(fixture_root))
	# 所有档案与典籍夹具使用独立目录，不修改玩家存档或默认牌组。
	var gateway := get_node("/root/SaveGateway")
	gateway.save_path = fixture_root.path_join("game.json")
	_check("独立测试档案加载", gateway.load_current() == OK)
	SeedService.begin_run("prg017018-ui-integration")
	var battle: BattleTestScene = load("res://ui/battle/formal_card_test_scene.tscn").instantiate()
	battle.relic_board_path = fixture_root.path_join("empty-relic.json")
	add_child(battle)
	await _frames(6)
	_check("新排版保留 main 正式70张测试牌组", battle.deck_card_ids.size() == 70 and battle._battle.hand.size() == 12)
	_check("新血条读取 main 的500生命", battle.player_hp_num.text == "500/500")
	_check("典籍保持 main 的12格", battle._relic_cells.size() == 12)
	var snapshot := JSON.stringify(battle._battle.to_dictionary())
	battle._open_run_menu(1)
	await _frames(4)
	var menu := battle._run_menu
	_check("战斗背包显示全部真实卡牌而非旧测试牌组", menu._deck_grid.get_child_count() == 70 and menu._deck_title.text == "卡组 70")
	var seen := {}
	var valid := true
	for slot: Control in menu._deck_grid.get_children():
		var view: CardView = slot.get_child(0)
		var data := view.卡牌数据
		valid = valid and data != null
		if data == null:
			continue
		seen[str(data.card_id)] = true
		valid = valid and view.get_node("%卡框").texture == view.底图集.texture_for(data.rarity, data.face_tint)
	_check("背包70张正式卡均有名称、数据和正确底图", valid and seen.size() == 70 and seen.has("1") and seen.has("70"))
	_check("查看牌组不修改 main 战斗状态", JSON.stringify(battle._battle.to_dictionary()) == snapshot)
	_check("战斗菜单层级高于悬停卡牌和牌堆弹窗", menu.z_index > battle.pile_modal.z_index and menu.z_index > 100)
	await _capture("battle-bag.png")
	menu.close()
	var count_before := battle._battle.hand.size()
	battle._on_hand_card_pressed(str(battle._battle.hand[0].instance_id))
	await _frames(3)
	_check("新UI点击手牌后可取消且不改底层牌组", battle._selected_ids.size() == 1 and battle._battle.hand.size() == count_before)
	await _capture("battle.png")
	battle._on_cancel_pressed()
	await _frames(3)
	_check("取消恢复完整手牌", battle.hand_cards.get_child_count() == count_before and battle._selected_ids.is_empty())
	battle.queue_free()
	await _frames(3)

	# 地图只读查看器必须隔离世界，不影响外层视图、角色、随机或探索状态。
	var map: Node2D = load("res://ui/world_map/flat_2d/map_preview.tscn").instantiate()
	add_child(map)
	await _frames(5)
	map._set_paused(false)
	var state_before: String = JSON.stringify(map.capture_state())
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	await _key(KEY_TAB)
	_check("真实Tab打开背包并暂停外层地图", map._run_menu.is_open() and map._run_menu.current_page() == 1 and map.paused)
	await _key(KEY_M)
	_check("真实M从背包切换地图", map._run_menu.current_page() == 0 and map.paused)
	var viewer: MapViewer = map._menu_map
	_check("查看器独占2D世界", viewer._viewport.world_2d != map.get_world_2d())
	_check("地图初次打开即按边界适配缩放", viewer._camera.zoom.is_equal_approx(Vector2.ONE * viewer._camera_scale()))
	var outside_zoom: Vector2 = map._camera.zoom
	var zoom_before := viewer._camera.zoom
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = viewer.get_global_rect().get_center()
	get_viewport().push_input(wheel, true)
	await _frames(3)
	_check("真实滚轮只缩放查看器", not viewer._camera.zoom.is_equal_approx(zoom_before) and map._camera.zoom.is_equal_approx(outside_zoom))
	var camera_before := viewer._camera.position
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = viewer.size * 0.5
	viewer._gui_input(press)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(100, 40)
	viewer._gui_input(drag)
	press.pressed = false
	viewer._gui_input(press)
	_check("地图查看器拖动只移动镜头", not viewer._camera.position.is_equal_approx(camera_before) and JSON.stringify(map.capture_state()) == state_before)
	await _capture("map-menu.png")
	await _key(KEY_ESCAPE)
	_check("切页后关闭菜单恢复之前未暂停状态", not map._run_menu.is_open() and not map.paused)
	_check("地图菜单不改变位置、探索和随机状态", JSON.stringify(map.capture_state()) == state_before and JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	map._notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check("失焦暂停地图", map.paused)
	map._notification(NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_check("重新聚焦恢复操作，移除暂停按钮后不会卡死", not map.paused)
	map._set_paused(true)
	map._open_run_menu(0)
	map._open_run_menu(2)
	map._run_menu.close()
	_check("原本已暂停时关闭菜单仍保持暂停", map.paused)
	map._run_menu.open(2)
	var run_before := GlobalState.run_active
	map._run_menu._abandon_button.pressed.emit()
	_check("放弃本局只显示二次确认，不直接修改状态", map._run_menu._abandon_confirm_row.visible and GlobalState.run_active == run_before)
	map._run_menu._reset_abandon_confirm()
	map._run_menu.close()
	# 跑图背包也必须支持正式编号、重复卡与旧原型标识，不能重建或替换 run.deck。
	var run := RunStateMachine.new()
	add_child(run)
	run.deck.assign(["1", "1", "11", "40", "6", "bonk"])
	GlobalState.current_run = run
	GlobalState.run_active = true
	map._open_run_menu(1)
	var ids: Array[String] = []
	for slot: Control in map._run_menu._deck_grid.get_children():
		var view: CardView = slot.get_child(0)
		ids.append(str(view.get_card_id()))
	_check("跑图背包读取 main 牌组且保留顺序、重复卡和旧原型", ids == run.deck and ids.size() == 6 and map._run_menu._deck_title.text == "卡组 6")
	map._run_menu.close()
	GlobalState.current_run = null
	GlobalState.run_active = false
	run.queue_free()
	await _capture("map.png")
	map.queue_free()
	await _frames(3)
	print("PRG-017/018界面整合自测：全部通过" if failures == 0 else "PRG-017/018界面整合自测：%d 项失败" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _key(code: Key) -> void:
	var key := InputEventKey.new()
	key.keycode = code
	key.physical_keycode = code
	key.pressed = true
	get_viewport().push_input(key, true)
	await _frames(2)
	key = key.duplicate()
	key.pressed = false
	get_viewport().push_input(key, true)
	await _frames(2)


func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1

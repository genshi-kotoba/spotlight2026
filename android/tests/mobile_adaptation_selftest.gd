extends Node
var failures := 0
var clicks := 0
var hovers := 0

func _ready() -> void:
	SaveGateway.save_path = "res://.godot/mobile-fixture-%d/game.json" % Time.get_ticks_usec()
	SaveGateway.load_current()
	_check("移动版使用独立存档目录", OS.get_user_data_dir().ends_with("spotlight2026-android"))
	_check("关闭引擎默认触摸鼠标双重模拟", not Input.emulate_mouse_from_touch)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var button := Button.new()
	button.position = Vector2(50, 50)
	button.size = Vector2(180, 90)
	button.text = "触控测试"
	button.pressed.connect(func(): clicks += 1)
	button.mouse_entered.connect(func(): hovers += 1)
	root.add_child(button)
	await _frames(3)
	await _tap(Vector2(100, 90))
	_check("短按恰好点击一次", clicks == 1)
	var previous_hovers := hovers
	_touch(Vector2(100, 90), true)
	await get_tree().create_timer(0.55).timeout
	_check("长按产生悬停", hovers > previous_hovers)
	_touch(Vector2(100, 90), false)
	await _frames(3)
	_check("长按松手不触发点击", clicks == 1)
	_check("松手清理悬停", not button.is_hovered())
	_touch(Vector2(100, 90), true)
	_drag(Vector2(170, 90))
	_touch(Vector2(170, 90), false)
	await _frames(3)
	_check("普通按钮上的滑动不会误点击", clicks == 1)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(300, 50)
	scroll.size = Vector2(300, 300)
	root.add_child(scroll)
	var list := VBoxContainer.new()
	scroll.add_child(list)
	for i in 20:
		var item := Button.new()
		item.text = "列表%d" % i
		item.custom_minimum_size = Vector2(270, 70)
		item.pressed.connect(func(): clicks += 1)
		list.add_child(item)
	await _frames(3)
	_touch(Vector2(400, 250), true)
	_drag(Vector2(400, 200))
	_drag(Vector2(400, 110))
	_touch(Vector2(400, 110), false)
	await _frames(3)
	_check("列表手指拖动可滚动", scroll.scroll_vertical > 60)
	_check("滑动列表不会选择物品", clicks == 1)
	# 覆盖新游戏等标准确认弹窗，不能只验证自绘 Control 弹窗。
	get_viewport().gui_embed_subwindows = true
	var dialog := ConfirmationDialog.new()
	dialog.title = "触控确认"
	dialog.dialog_text = "测试确认按钮"
	dialog.confirmed.connect(func(): clicks += 1)
	add_child(dialog)
	dialog.popup_centered(Vector2i(600, 300))
	await _frames(3)
	await _tap(Vector2(dialog.position) + dialog.get_ok_button().get_global_rect().get_center())
	_check("标准确认弹窗可以触屏确认", clicks == 2 and not dialog.visible)
	dialog.queue_free()
	root.queue_free()
	await _frames(2)
	await _navigation()
	await _battle()
	await _inventory()
	print("MOBILE_TEST_RESULT failures=%d" % failures)
	get_tree().quit(failures)

func _navigation() -> void:
	var session = preload("res://systems/map/flat_2d/planar_map_session.gd").new()
	var cells: Array = []
	for x in range(6):
		for y in range(4): cells.append({"q": x, "r": y, "terrain": "ground"})
	var data := {"schema_version": 1, "map_id": "mobile-nav", "seed": "test", "floor_index": 1,
		"spawn": [0, 0], "cells": cells, "nodes": [{"id": "enemy", "type": "battle", "coord": [2, 1],
		"footprint": [[2, 1]], "is_route_gate": false, "revisitable": false, "body_radius": 0.4}]}
	_check("测试地图合法", session.load_map(data))
	for key in session.cells: session.known[key] = true
	session._rebuild_boundaries()
	session._rebuild_node_bodies()
	var nav = preload("res://systems/map/mobile_map_navigation.gd").new()
	var target := HexCoord.to_plane(Vector2i(4, 1), 1.0)
	var path: PackedVector2Array = nav.route(session, target)
	_check("目的地可寻路", path.size() > 1 and path[-1].distance_to(target) < 0.8)
	var clear := true
	for i in range(1, path.size()):
		for step in 20:
			if not session.can_stand(path[i-1].lerp(path[i], float(step)/20.0)): clear = false
	_check("路线不穿怪物或地图墙体", clear)
	var to_enemy: PackedVector2Array = nav.route(session, HexCoord.to_plane(Vector2i(2, 1), 1.0))
	_check("节点碰撞不阻止走到交互距离", not to_enemy.is_empty() and HexCoord.distance(HexCoord.from_plane(to_enemy[-1], 1.0), Vector2i(2,1)) <= 1)

func _battle() -> void:
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.relic_board_path = "res://.godot/mobile-empty-relics.json"
	add_child(scene)
	await _frames(4)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(scene)
	await get_tree().create_timer(1.0).timeout
	_check("手牌比桌面版放大", scene.HAND_CARD_SCALE > 0.285)
	_check("旧背包外框不遮挡血条和头像", not scene.backpack_board.visible)
	_check("背包格子和玩家血条仍可见", scene.backpack_slots.is_visible_in_tree() and scene.get_node("PlayerHPBar").is_visible_in_tree())
	_check("出牌区完整可见", scene.play_scroll.get_global_rect().end.x <= get_viewport().get_visible_rect().size.x)
	_check("出牌按钮触控高度", scene.play_button.size.y >= 70)
	var slot := scene.hand_cards.get_child(scene.hand_cards.get_child_count()/2) as Control
	var at := slot.get_global_transform() * (slot.size * Vector2(0.5, 0.3))
	var before: int = scene._selected_ids.size()
	_touch(at, true)
	await get_tree().create_timer(0.6).timeout
	_check("长按手牌放大但不出牌", scene._fan_target != null and scene._selected_ids.size() == before)
	_touch(at, false)
	await get_tree().create_timer(0.4).timeout
	_check("长按手牌抬手仍不出牌", scene._selected_ids.size() == before)
	at = slot.get_global_transform() * (slot.size * Vector2(0.5, 0.3))
	await _tap(at)
	await _frames(4)
	_check("真实触屏点击手牌进入出牌区", scene._selected_ids.size() == before + 1)
	await get_tree().create_timer(0.7).timeout
	slot = scene.hand_cards.get_child(scene.hand_cards.get_child_count()/2) as Control
	at = slot.get_global_transform() * (slot.size * Vector2(0.5, 0.3))
	_touch(at, true)
	_drag(at + Vector2(30, -30))
	var drop := scene.play_scroll.get_global_rect().get_center()
	_drag(drop)
	_touch(drop, false)
	await get_tree().create_timer(0.7).timeout
	_check("触屏拖牌进入出牌区沿用原排序逻辑", scene._selected_ids.size() == before + 2)
	await _tap(scene.cancel_button.get_global_rect().get_center())
	await get_tree().create_timer(0.7).timeout
	_check("触屏取消出牌回到手牌", scene._selected_ids.size() == before)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/mobile-hand-preview.png")
	scene.queue_free()
	await _frames(3)

func _inventory() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "mobile-inventory"
	_check("独立背包测试新局", SaveGateway.start_new_run("mobile-inventory", config) == OK)
	var run := SaveGateway.current_run()
	_check("建立背包奖励夹具", RunRewards.stage_victory(run, "mobile", "elite", "精英", 0) == OK)
	for entry: Dictionary in RunRewards.pending(run).entries: RunRewards.claim(run, str(entry.id))
	RunRewards.finish_rewards(run)
	var index := -1
	for i in run.items.size():
		if run.items[i].kind == "common_pack": index = i
	var bag := RunMenuOverlay.new()
	add_child(bag)
	bag.open(1)
	await get_tree().create_timer(0.4).timeout
	var item := bag._item_grid.get_child(index) as Control
	await _tap(item.get_global_rect().get_center())
	_check("触屏点击背包物品打开放大菜单", bag._item_menu != null and bag._item_menu.visible and bag._item_menu.ROW_HEIGHT >= 70)
	var rows: VBoxContainer = bag._item_menu._rows
	var cancel := rows.get_child(rows.get_child_count()-1) as Button
	_check("物品菜单提供取消按钮", cancel.text == "取消")
	await _tap(cancel.get_global_rect().get_center())
	_check("取消菜单不使用卡包", not bag._item_menu.visible and bag._pack_popup == null)
	await _tap(item.get_global_rect().get_center())
	await _tap(bag._item_menu._rows.get_child(0).get_global_rect().get_center())
	await get_tree().create_timer(0.7).timeout
	var popup := bag._pack_popup
	_check("触屏使用卡包进入原奖励模态", popup != null and popup.is_selection_locked())
	var fan := popup._choice_fan
	var before: int = run.deck.size()
	var at := fan._hits[1].get_global_rect().get_center()
	_touch(at, true)
	await get_tree().create_timer(0.7).timeout
	_check("长按奖励牌打开持久阅读但不领取", ReadingDetailOverlay.is_open_for(popup) and run.deck.size() == before)
	_touch(at, false)
	await get_tree().create_timer(0.4).timeout
	_check("长按抬手不领取且详情仍保持", run.deck.size() == before and ReadingDetailOverlay.is_open_for(popup))
	var close_reader := preload("res://tests/support/card_reader_test_helper.gd").action_button(popup, "关闭")
	_check("长按详情可明确关闭", close_reader != null)
	if close_reader != null: await _tap(close_reader.get_global_rect().get_center())
	await _tap(fan._hits[1].get_global_rect().get_center())
	await get_tree().create_timer(0.2).timeout
	_check("触屏短按先查看卡牌且不领取", run.deck.size() == before and ReadingDetailOverlay.is_open_for(popup))
	var confirm := preload("res://tests/support/card_reader_test_helper.gd").action_button(popup, "选择此牌")
	_check("触屏奖励有显式选择按钮", confirm != null)
	if confirm != null: await _tap(confirm.get_global_rect().get_center())
	await get_tree().create_timer(0.5).timeout
	_check("触屏选择奖励牌只领取一次", run.deck.size() == before + 1)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/mobile-bag-preview.png")
	bag.queue_free()
	await _frames(3)

func _touch(at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = at
	event.pressed = pressed
	get_viewport().push_input(event, true)

func _drag(at: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = at
	get_viewport().push_input(event, true)

func _tap(at: Vector2) -> void:
	_touch(at, true)
	await _frames(1)
	_touch(at, false)
	await _frames(3)

func _frames(count: int) -> void:
	for i in count: await get_tree().process_frame

func _check(label: String, passed: bool) -> void:
	print("%s %s" % ["PASS" if passed else "FAIL", label])
	if not passed: failures += 1

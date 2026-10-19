extends "res://tests/battle_animation_selftest.gd"
const VIEW := preload("res://ui/results/run_settlement_view.gd")
const BACKGROUNDS := preload("res://ui/battle/battle_environment.gd")
var _config: Dictionary

class FinalFloor extends RefCounted:
	var current_floor := 3

func _run() -> void:
	get_tree().current_scene = null # 保留测试宿主，允许实际场景切换。
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/run-settlement-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("结算测试使用独立存档", SaveGateway.load_current() == OK)
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	await _victory_and_currency()
	await _real_battle_death()
	await _records_and_legacy()
	print("终局结算与历史记录：全部通过" if failures == 0 else "终局结算与历史记录：失败%d项" % failures)
	get_tree().quit(failures)

func _victory_and_currency() -> void:
	_config.run_id = "settlement-victory"
	_check("建立统计新局", SaveGateway.start_new_run("settlement-victory", _config) == OK)
	var run := SaveGateway.current_run()
	run.gold += 400
	run.gold -= 150
	run.change_gold(20)
	_check("累计银币计算获得额，消费不回扣", run.gold == 270 and run.total_silver_earned == 420)
	var legacy_snapshot := run.to_dictionary()
	legacy_snapshot.erase("total_silver_earned")
	var legacy_run := RunStateMachine.new()
	add_child(legacy_run)
	_check("旧活动存档缺累计字段按当前余额迁移", legacy_run.restore_from_dictionary(legacy_snapshot) == OK and legacy_run.gold == 270 and legacy_run.total_silver_earned == 270)
	legacy_run.queue_free()
	_check("暂存普通奖励", RunRewards.stage_victory(run, run.current_map_id, "test-node", "普通", 0) == OK)
	var old_error := SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("领取保存失败同时回滚余额、累计数、领取标记", RunRewards.claim(run, "silver") != OK and run.gold == 270 and run.total_silver_earned == 420 and not RunRewards.pending(run).entries[0].claimed)
	SaveGateway._load_error = old_error
	for entry: Dictionary in RunRewards.pending(run).entries: _check("领取最终奖励" + str(entry.id), RunRewards.claim(run, str(entry.id)) == OK)
	_check("保存失败不重复累计，实际领奖累计一次", run.gold == 370 and run.total_silver_earned == 520)
	var before := RunRewards._capture(run)
	run.gold -= 100
	RunRandomEvents.restore(run, before.merged({"health":run.health}))
	_check("商店或事件退款回滚不当作新收入", run.total_silver_earned == 520 and run.gold == 370)
	run.deck_cards[0]["enchantments"] = ["damage_50"]
	run.inventory_state.settlement_context = {"location_name":"末层首领", "background_path":BACKGROUNDS.path_for_floor(3)}
	run.battles_fought = 7
	run.set_current_map(run.map_ids[2])
	EncounterFlow.run = run
	EncounterFlow.map_run = FinalFloor.new()
	_check("第三层Boss标记最终通关但等领奖完成", EncounterFlow._advance_after_boss() and run.active and bool(run.inventory_state.pending_run_victory) and not RunResults.complete_if_ready())
	_check("最终奖励完成后触发通关", RunRewards.finish_rewards(run) == OK and RunResults.complete_if_ready())
	var record: Dictionary = GlobalState.run_history.back()
	_check("通关记录带累计银币、战斗数、最终卡牌附魔和未开卡包", record.result == "victory" and int(record.total_silver_earned) == 520 and int(record.battles_fought) == 7 and record.final_inventory.deck_cards[0].enchantments == ["damage_50"] and record.final_inventory.items.size() == 2)
	_check("通关文本无死因", RunHistory.lines(record).size() == 3 and RunHistory.lines(record)[0] == "结束了")
	var saved := SaveGateway._read_json(SaveGateway.save_path)
	_check("终局立即原子保存且没有可继续的活动局", saved.error == OK and saved.data.active_run == null and saved.data.run_history.size() == 1 and not SaveGateway.has_continuable_run())
	await _frames(2)
	var panel := VIEW.new()
	add_child(panel)
	panel.show_record(record, false)
	await get_tree().create_timer(0.3).timeout
	_check("详情背包无角色立绘且禁止编辑", panel.bag.settlement_mode and not panel.bag._can_edit_relics() and panel.bag._pages[1].get_children().filter(func(c: Node): return c is TextureRect).is_empty())
	var frozen := JSON.stringify(record)
	var inventory_copy := RunHistory.inventory_run(record)
	inventory_copy.deck_cards[0].enchantments.append("repeat_2")
	_check("历史卡牌副本与附魔使用深拷贝，不修改记录", JSON.stringify(record) == frozen)
	inventory_copy.free()
	var live_before := JSON.stringify(GlobalState.capture_save_data())
	panel.bag._on_item_pressed(str(record.final_inventory.items[0].item_id))
	panel.bag.close()
	panel.bag.set_page(2)
	_check("只读模式不能开包、关闭背包或跳去设置", not is_instance_valid(panel.bag._pack_popup) and panel.bag.visible and panel.bag.current_page() == 1 and JSON.stringify(record) == frozen and JSON.stringify(GlobalState.capture_save_data()) == live_before)
	await get_tree().create_timer(0.25).timeout
	_check("详情背包和内容完成淡入且保留只读标题", panel.detail_ready and is_equal_approx(panel.bag.modulate.a, 1.0) and is_equal_approx(panel.bag._pages[1].modulate.a, 1.0) and panel.bag._page_title.text == "最终背包 · 仅供查看")
	await _capture("victory-detail.png")
	panel.queue_free()
	await _frames(2)
	EncounterFlow.run = null
	EncounterFlow.map_run = null
	_check("结算记录冷启动可恢复", SaveGateway.load_current() == OK and GlobalState.run_history.size() == 1 and GlobalState.run_history[0].total_silver_earned == 520)

func _real_battle_death() -> void:
	_config.run_id = "settlement-death"
	_check("建立实际死亡战斗", SaveGateway.start_new_run("settlement-death", _config) == OK)
	var run := SaveGateway.current_run()
	run.gold = 123
	_check("创建正式怪物战斗", run.start_battle("death-node", [MonsterCatalog.create("11", 2)], 0, false, 10, false) == OK)
	var battle := run.current_battle
	battle.player.encounter_floor = 2
	battle.player.encounter_relic_board = RunRewards.board_for_run(run).to_dictionary()
	var source: BattleTestScene = load("res://ui/battle/map_battle_scene.tscn").instantiate()
	get_tree().root.add_child(source)
	get_tree().current_scene = source
	await _wait_presentation(source)
	var context := BattleEffectContext.new(battle, "player", source._resolver.buff_catalog)
	context.damage_player(999, true)
	await _wait_presentation(source)
	var deadline := Time.get_ticks_msec() + 18000
	while (not is_instance_valid(RunResults.view) or not RunResults.view.detail_ready) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check("真实战斗死亡后留在战场并完成结算动画", is_instance_valid(RunResults.view) and RunResults.view.detail_ready and get_tree().current_scene == source)
	if not is_instance_valid(RunResults.view): return
	var result_view: Control = RunResults.view
	var record: Dictionary = result_view.record
	_check("死亡记录使用敌人名称与战斗所属楼层背景", record.result == "defeat" and record.location_name == str(battle.enemies[0].name) and result_view.background.texture.resource_path == BACKGROUNDS.path_for_floor(2))
	_check("死亡标题红色并复用典籍抖动，不再显示原UI", result_view.summary.get_child(0).text.contains("relic_motion") and result_view.summary.get_child(0).text.contains(RelicFragmentData.NEGATIVE_COLOR) and source.process_mode == Node.PROCESS_MODE_DISABLED)
	_check("文本全部显示后移到左边，背包可查看且确认按钮才出现", result_view.summary.position.x == 124 and result_view.summary.get_child_count() == 4 and result_view.bag.visible and result_view.confirm_button.visible and result_view.hold_seconds == 1.0)
	await _capture("death-detail.png")
	var history_count := GlobalState.run_history.size()
	var seed := JSON.stringify(SeedService.capture_snapshot())
	result_view.bag._peek_card("1", record.final_inventory.deck_cards[0])
	_check("最终牌组可放大查看且不改变随机数", result_view.bag._peek_layer.visible and JSON.stringify(SeedService.capture_snapshot()) == seed)
	result_view.bag._peek_layer.hide()
	var save_error := SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	await _mouse_click(result_view.confirm_button)
	await _frames(2)
	_check("保存失败保留结算并允许重试", is_instance_valid(RunResults.view) and not result_view.confirm_button.disabled and not result_view._error.text.is_empty() and get_tree().current_scene == source)
	SaveGateway._load_error = save_error
	await _mouse_click(result_view.confirm_button)
	await _frames(2)
	deadline = Time.get_ticks_msec() + 8000
	while (SceneTransition.is_loading() or get_tree().current_scene == null or get_tree().current_scene == source) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _frames(4)
	_check("点击确定返回主菜单，记录只保存一次", get_tree().current_scene.scene_file_path == "res://ui/main_menu/main_menu.tscn" and GlobalState.run_history.size() == history_count and not is_instance_valid(RunResults.view))

func _records_and_legacy() -> void:
	var menu := get_tree().current_scene
	_check("开始界面有记录按钮", menu.has_node("按钮列/记录"))
	menu.get_node("按钮列/记录").pressed.emit()
	var deadline := Time.get_ticks_msec() + 8000
	while (get_tree().current_scene == menu or SceneTransition.is_loading()) and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	var page := get_tree().current_scene
	_check("记录页面按时间展示死亡与胜利", page.scene_file_path == "res://ui/results/run_records.tscn" and page.entries.size() == 2 and page.entries[0].result == "defeat")
	page._open_detail(0)
	while not page._detail.detail_ready: await get_tree().process_frame
	_check("点击记录直接打开最终背包，不重播动画", page._detail.detail_ready and page._detail.summary.position.x == 124 and page._detail.record == page.entries[0])
	await _capture("record-detail.png")
	await _mouse_click(page._detail.confirm_button)
	await _frames(2)
	_check("真实鼠标点击确定关闭记录详情并返回列表", not is_instance_valid(page._detail) and not is_instance_valid(page._detail_layer) and get_tree().current_scene == page)
	if is_instance_valid(page._detail): page._close_detail()
	page._open_detail(1)
	while not page._detail.detail_ready: await get_tree().process_frame
	page._detail.bag._peek_card("1")
	await _frames(2)
	await _mouse_click(page._detail.confirm_button, page._detail.bag._peek_layer.get_child(0))
	_check("卡牌大图遮罩优先关闭大图，不穿透确定退出详情", is_instance_valid(page._detail) and not page._detail.bag._peek_layer.visible)
	await _mouse_click(page._detail.confirm_button)
	await _frames(2)
	_check("再次打开另一条记录也可真实点击返回", not is_instance_valid(page._detail))
	if is_instance_valid(page._detail): page._close_detail()
	await _capture("records.png")
	var legacy := {"run_id":"old", "result":"defeat", "death_location":"旧节点", "deck":["1"], "battles_fought":2}
	var old_run := RunHistory.inventory_run(legacy)
	_check("旧记录缺少背包及统计字段仍可查看，不伪造累计银币", old_run.deck.size() == 1 and old_run.items.is_empty() and RunHistory.silver_text(legacy) == "未记录")
	old_run.free()
	var event_record := legacy.duplicate(true)
	event_record.location_name = "素材合成"
	_check("随机事件死亡使用事件名称", RunHistory.lines(event_record)[1] == "你死于素材合成")
	var same_second := RunHistory.records([{"run_id":"first", "result":"defeat", "ended_at":"2026-10-20T00:00:00"}, {"run_id":"second", "result":"victory", "ended_at":"2026-10-20T00:00:00"}])
	_check("同秒记录仍按发生先后倒序，且不暴露排序辅助字段", same_second[0].run_id == "second" and not same_second[0].has("_history_order"))

func _mouse_click(button: Button, expected_hit: Control = null) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	await _frames(2)
	_check("确定按钮能接收真实鼠标而非被背包挡住" if expected_hit == null else "大图遮罩优先接收鼠标", get_viewport().gui_get_hovered_control() == (button if expected_hit == null else expected_hit))
	var click := InputEventMouseButton.new()
	click.position = point
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	get_viewport().push_input(click, true)
	await _frames(1)
	click = click.duplicate()
	click.pressed = false
	get_viewport().push_input(click, true)
	await _frames(2)

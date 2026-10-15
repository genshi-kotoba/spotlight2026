extends "res://tests/map_entry_input_selftest.gd"
## 真实 E 与鼠标输入，所有档案和典籍写入唯一隔离目录。
var _config: Dictionary

func _run() -> void:
	fixture_root = "res://.godot/battle-rewards-%d" % Time.get_ticks_usec()
	SaveGateway.profile_path = fixture_root.path_join("profile.json")
	SaveGateway.slot_paths.assign([fixture_root.path_join("slot1.json"), fixture_root.path_join("slot2.json"), fixture_root.path_join("slot3.json")])
	SaveGateway._active_slot = 1
	_check("隔离玩家档案", SaveGateway._load_slot(1) == OK)
	DirAccess.make_dir_recursive_absolute(fixture_root)
	EncounterFlow.relic_board_path = fixture_root.path_join("old-test-board.json")
	var legacy_board := RelicBoard.new()
	legacy_board.cells[0] = "turn_strength"
	legacy_board.save_to_file(EncounterFlow.relic_board_path)
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	_config.run_id = "rewards-test"
	_check("无需旧解锁也能建立指定初始构筑", SaveGateway.start_new_run("rewards-fixed-seed", _config) == OK)
	var run := SaveGateway.current_run()
	_check("新局八张牌准确且没有继承测试残片", run.deck == ["1", "1", "1", "50", "50", "50", "40", "40"] and RunRewards.board_for_run(run).cells.count("") == 12 and run.items.is_empty() and run.gold == 0 and int(run.inventory_state.elixir) == 0)
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	_approach(view)
	await _press_e()
	var battle_ui: Node = get_tree().current_scene
	_check("真实交互使用八张牌与空典籍", battle_ui.scene_file_path == EncounterFlow.BATTLE_SCENE and battle_ui._battle.hand.size() == 8 and battle_ui._relics.activation_count == 0)
	if battle_ui.scene_file_path != EncounterFlow.BATTLE_SCENE:
		get_tree().quit(1)
		return
	var context := BattleEffectContext.new(battle_ui._battle, str(battle_ui._battle.enemies[0].enemy_id), battle_ui._resolver.buff_catalog)
	context.damage_enemy(str(battle_ui._battle.enemies[0].enemy_id), 999)
	await _frames(10)
	var popup: LootPopup = battle_ui._reward_popup
	var first_battle_key := str(RunRewards.pending(run).battle_key)
	_check("胜利停留奖励弹窗且未自动领取", is_instance_valid(popup) and RunRewards.pending(run).entries.size() == 3 and run.gold == 0 and run.items.is_empty())
	await _capture("ordinary-rewards.png")
	await _click(popup._options.get_node("Reward_silver"))
	_check("点击领取100银币，重复领取被拒绝", run.gold == 100 and RunRewards.claim(run, "silver") == ERR_ALREADY_EXISTS)
	# 注入保存失败，保证领取标记与物资在内存中同时回滚。
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("保存失败时不发物品、不吞奖励", RunRewards.claim(run, "fragment_pack") != OK and run.items.is_empty() and not run.inventory_state.pending_rewards.entries[1].claimed)
	SaveGateway._load_error = old_error
	await _cold_continue()
	run = SaveGateway.current_run()
	view = get_tree().current_scene
	popup = view._reward_popup
	_check("冷恢复重新显示未领完奖励且银币不重复发放", is_instance_valid(popup) and run.gold == 100 and RunRewards.pending(run).entries[0].claimed)
	await _click(popup._options.get_node("Reward_fragment_pack"))
	await _click(popup._options.get_node("Reward_common_pack"))
	_check("领取后背包只有两个包，初始牌组未改变", run.items.size() == 2 and run.deck.size() == 8)
	await _click(popup._continue_button)
	_check("领完后继续探索，清除待领奖状态", RunRewards.pending(run).is_empty() and not view.paused)
	view._open_run_menu(1)
	await _frames(4)
	var bag: RunMenuOverlay = view._run_menu
	_check("背包显示银币万灵药与实际物品", bag._resources.text.contains("100") and bag._item_grid.get_child_count() == 2 and bag._relic_cells[0].text == "—")
	var fragment_pack_id := _pack_id(run, "fragment_pack")
	await _click(bag._item_grid.get_child(0))
	popup = bag._pack_popup
	var first: Array = RunRewards.item(run, fragment_pack_id).options
	_check("残片包恰为两个不同选项", first.size() == 2 and first[0] != first[1])
	await _capture("fragment-pack.png")
	await _click(popup._refresh_button)
	var refreshed: Array = RunRewards.item(run, fragment_pack_id).options
	_check("残片刷新整组选项替换且只限一次", refreshed.size() == 2 and refreshed[0] != refreshed[1] and refreshed[0] not in first and refreshed[1] not in first and RunRewards.refresh_pack(run, fragment_pack_id) == ERR_UNAVAILABLE)
	await _click(popup._continue_button)
	bag._on_item_pressed(fragment_pack_id)
	await _frames(3)
	popup = bag._pack_popup
	_check("关包重开不重抽且刷新次数保留", RunRewards.item(run, fragment_pack_id).options == refreshed and popup._refresh_button.disabled)
	await _click(popup._options.find_child("Choose_" + str(refreshed[0]), true, false))
	var fragment_item: Dictionary = RunRewards.item(run, fragment_pack_id + "/fragment")
	_check("选中残片收入背包，包不可二次选择", fragment_item.get("fragment_id") == refreshed[0] and RunRewards.choose(run, fragment_pack_id, str(refreshed[0])) == ERR_DOES_NOT_EXIST)
	bag._on_item_pressed(str(fragment_item.item_id))
	await _click(bag._relic_cells[0])
	_check("仅拥有的残片可装入本局典籍", RunRewards.board_for_run(run).cells[0] == refreshed[0] and RunRewards.item(run, str(fragment_item.item_id)).is_empty())
	_check("卸下返回背包，不丢失残片", RunRewards.unequip_fragment(run, 0) == OK and RunRewards.board_for_run(run).cells[0].is_empty())
	bag._refresh_data()
	var common_id := _pack_id(run, "common_pack")
	bag._on_item_pressed(common_id)
	await _frames(3)
	popup = bag._pack_popup
	var common_first: Array = RunRewards.item(run, common_id).options
	_check("普通包三个不同普通卡", _unique(common_first, 3) and _rarity(common_first, "普通"))
	await _capture("common-pack.png")
	await _click(popup._refresh_button)
	var common_new: Array = RunRewards.item(run, common_id).options
	_check("普通包刷新一次且全部换新", _unique(common_new, 3) and _disjoint(common_first, common_new) and RunRewards.refresh_pack(run, common_id) == ERR_UNAVAILABLE)
	await _click(popup._continue_button)
	await _cold_continue()
	run = SaveGateway.current_run()
	view = get_tree().current_scene
	_check("冷恢复保留卡包选项与刷新次数", RunRewards.item(run, common_id).options == common_new and RunRewards.item(run, common_id).rerolled)
	view._open_run_menu(1)
	await _frames(3)
	bag = view._run_menu
	bag._on_item_pressed(common_id)
	await _frames(3)
	popup = bag._pack_popup
	_check("伪造包外选项不能领奖", RunRewards.choose(run, common_id, "not-an-option") == ERR_INVALID_PARAMETER)
	await _click(popup._options.find_child("CardChoice_" + str(common_new[0]), true, false))
	_check("直接点击普通卡面仅加入一张到牌组", run.deck.size() == 9 and RunRewards.item(run, common_id).is_empty())
	bag.close()
	for grade: String in ["精英", "BOSS"]:
		_check(grade + "奖励生成", RunRewards.stage_victory(run, "fixture-map", "fixture-" + grade, grade, 0) == OK and SaveGateway.save_current() == OK)
		view._show_pending_rewards()
		await _frames(3)
		popup = view._reward_popup
		_check(grade + "奖励五项且有200银币与万灵药", RunRewards.pending(run).entries.size() == 5 and RunRewards.pending(run).entries[0].amount == 200)
		await _capture("elite-rewards.png" if grade == "精英" else "boss-rewards.png")
		for entry: Dictionary in RunRewards.pending(run).entries:
			await _click(popup._options.get_node("Reward_" + str(entry.id)))
		await _click(popup._continue_button)
		_check(grade + "重复战斗结果不再发奖励", RunRewards.stage_victory(run, "fixture-map", "fixture-" + grade, grade, 0) == OK and RunRewards.pending(run).is_empty())
	_check("资源合计正确", run.gold == 500 and int(run.inventory_state.elixir) == 2)
	var rare_id := _pack_id(run, "rare_pack")
	_check("稀有包可打开", RunRewards.open_pack(run, rare_id) == OK)
	var rare: Array = RunRewards.item(run, rare_id).options
	_check("稀有包三个不同稀有卡且不可刷新", _unique(rare, 3) and _rarity(rare, "稀有") and RunRewards.refresh_pack(run, rare_id) == ERR_UNAVAILABLE)
	view._open_run_menu(1)
	await _frames(3)
	bag = view._run_menu
	bag._on_item_pressed(rare_id)
	await _frames(3)
	popup = bag._pack_popup
	_check("稀有包不显示刷新按钮", not popup._refresh_button.visible)
	await _capture("rare-pack.png")
	await _click(popup._options.find_child("Choose_" + str(rare[0]), true, false))
	_check("稀有卡加入牌组", run.deck.size() == 10)
	var next_common := _pack_id(run, "common_pack")
	_check("每个包有独立刷新次数", RunRewards.open_pack(run, next_common) == OK and RunRewards.refresh_pack(run, next_common) == OK)
	# 老存档可继续，缺物资扩展时只迁移其旧典籍，新局不会继承。
	var legacy := run.to_dictionary()
	legacy.erase("inventory_state")
	var restored := RunStateMachine.new()
	add_child(restored)
	_check("旧版存档兼容加载", restored.restore_from_dictionary(legacy) == OK)
	RunRewards.ensure_state(restored, EncounterFlow.relic_board_path)
	_check("旧局保留旧典籍而非清空", RunRewards.board_for_run(restored).cells[0] == "turn_strength")
	restored.queue_free()
	bag.close()
	_approach(view)
	await _press_e()
	battle_ui = get_tree().current_scene
	_check("战斗中不能开包编辑构筑", RunRewards.open_pack(run, next_common) == ERR_BUSY)
	var defeat := BattleEffectContext.new(battle_ui._battle, "player", battle_ui._resolver.buff_catalog)
	defeat.damage_player(999, true)
	await _frames(10)
	_check("失败回主菜单不生成战利品", get_tree().current_scene.scene_file_path == MENU and not GlobalState.run_active)
	_config.run_id = "rewards-second-run"
	_check("下一次新局正常建立", SaveGateway.start_new_run("rewards-fixed-seed", _config) == OK)
	run = SaveGateway.current_run()
	_check("新局不继承上局银币万灵药卡包残片", run.gold == 0 and int(run.inventory_state.elixir) == 0 and run.items.is_empty() and RunRewards.board_for_run(run).cells.count("") == 12 and run.deck.size() == 8)
	var address := first_battle_key.split("/")
	RunRewards.stage_victory(run, address[0], address[1], "普通", int(address[2]))
	RunRewards.claim(run, "fragment_pack")
	RunRewards.open_pack(run, fragment_pack_id)
	_check("相同种子同一个包复现相同选项，不受开包顺序影响", RunRewards.item(run, fragment_pack_id).options == first)
	var corrupted := run.to_dictionary()
	corrupted.inventory_state.elixir = -1
	_check("拒绝损坏物资快照", not RunStateMachine._valid_inventory_state(corrupted.inventory_state))
	print("战斗奖励与背包：全部通过" if failures == 0 else "战斗奖励与背包：失败%d项" % failures)
	get_tree().quit(failures)

func _cold_continue() -> void:
	get_tree().change_scene_to_file(MENU)
	await _frames(4)
	_check("隔离档案冷载入", SaveGateway._load_slot(1) == OK)
	get_tree().current_scene._on_continue_pressed()
	await _frames(12)

func _click(button: Button) -> void:
	if button == null:
		_check("需要点击的控件存在", false)
		return
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	var click := InputEventMouseButton.new()
	click.position = point
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	get_viewport().push_input(click, true)
	await _frames(2)
	click = click.duplicate()
	click.pressed = false
	get_viewport().push_input(click, true)
	await _frames(5)

func _pack_id(run: RunStateMachine, kind: String) -> String:
	for value: Dictionary in run.items:
		if value.get("kind") == kind:
			return str(value.item_id)
	return ""

func _unique(values: Array, count: int) -> bool:
	var seen := {}
	for value: String in values:
		seen[value] = true
	return values.size() == count and seen.size() == count

func _rarity(values: Array, rarity: String) -> bool:
	for id: String in values:
		if TextCatalog.entry("cards", id).rarity != rarity:
			return false
	return true

func _disjoint(first: Array, second: Array) -> bool:
	for value: String in first:
		if value in second:
			return false
	return true

func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))

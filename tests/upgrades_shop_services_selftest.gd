extends "res://tests/shop_enchantments_selftest.gd"
## 隔离真实地图/存档，验证升级、服务、回滚和冷恢复。
func _run() -> void:
	fixture_root = "res://.godot/upgrades-services-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("隔离存档", SaveGateway.load_current() == OK)
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	_config.run_id = "upgrade-services"
	_check("建立测试局", SaveGateway.start_new_run(_seed_with_both_enchantments(), _config) == OK)
	var run := SaveGateway.current_run()
	run.inventory_state.elixir = 100
	for cost: int in RunUpgrades.PLAY_COSTS:
		var before := int(run.inventory_state.elixir)
		_check("牌位升级费用 %d" % cost, RunUpgrades.play_cost(run) == cost and RunUpgrades.buy_play_slot(run) == OK and int(run.inventory_state.elixir) == before - cost)
	_check("牌位最多升级五次", RunUpgrades.play_level(run) == 5 and RunUpgrades.buy_play_slot(run) == ERR_UNAVAILABLE)
	run.inventory_state["play_slot_upgrades"] = 0
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	var before_elixir := int(run.inventory_state.elixir)
	_check("升级保存失败回滚", RunUpgrades.buy_play_slot(run) != OK and RunUpgrades.play_level(run) == 0 and int(run.inventory_state.elixir) == before_elixir)
	SaveGateway._load_error = old_error
	_check("重新升级成功", RunUpgrades.buy_play_slot(run) == OK)
	for group: Dictionary in RunUpgrades.RELIC_GROUPS:
		before_elixir = int(run.inventory_state.elixir)
		_check("按图整组解锁", RunUpgrades.buy_relic_group(run, int(group.cells[0])) == OK and int(run.inventory_state.elixir) == before_elixir - int(group.cost))
		for cell: int in group.cells: _check("格子 %d 已解锁" % cell, RunRewards.board_for_run(run).is_unlocked(cell))
		_check("整组不能重复扣费", RunUpgrades.buy_relic_group(run, int(group.cells[0])) == ERR_ALREADY_EXISTS)
	var board := RelicBoard.new()
	run.inventory_state.relic_board = board.to_dictionary()
	run.inventory_state.elixir = 0
	_check("药不足不解锁", RunUpgrades.buy_relic_group(run, 3) == ERR_UNAVAILABLE and not RunRewards.board_for_run(run).is_unlocked(3))
	run.inventory_state.elixir = 30
	for grade: String in ["普通", "精英", "BOSS"]:
		_check("战斗奖励生成", RunRewards.stage_victory(run, "fixture", grade, grade, 0) == OK)
		var pending := RunRewards.pending(run)
		var medicine: Dictionary = {}
		for entry: Dictionary in pending.entries:
			if entry.kind == "elixir": medicine = entry
		_check(grade + "奖励两药且快照可恢复", medicine.get("amount") == 2 and RunStateMachine._valid_inventory_state(run.inventory_state))
		for entry: Dictionary in pending.entries: RunRewards.claim(run, str(entry.id))
		RunRewards.finish_rewards(run)
	run.items.clear()
	_check("同结点只赠药一次", RunUpgrades.award_node(run, "fixture", "shop") and not RunUpgrades.award_node(run, "fixture", "shop"))
	for kind: String in ["chest", "pile"]:
		var loot := RunNodeLoot.generate("fixed", "floor", kind, 1, kind)
		_check(kind + "包含两药且通过校验", loot.entries[1].amount == 2 and RunNodeLoot.valid_records({RunNodeLoot.key("floor", kind):loot}))
	_check("保存初始准备", SaveGateway.save_current() == OK)
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(12)
	_check("地图倍率固定1.5", view._walking_speed_multiplier() == 1.5)
	var visible_sliders := 0
	for slider: Node in view._hud_root.find_children("*", "HSlider", true, false):
		if slider.is_visible_in_tree(): visible_sliders += 1
	_check("地图不再显示底部提示框和移速滑块", not view._info_column.is_visible_in_tree() and visible_sliders == 0)
	view._open_run_menu(1)
	await get_tree().create_timer(0.35).timeout
	var bag: RunMenuOverlay = view._run_menu
	await _capture("bag-upgrades.png")
	await _click(bag._upgrade_relic)
	await _capture("relic-upgrade.png")
	_check("典籍升级蒙层打开且阻止关包", is_instance_valid(bag._upgrade_layer))
	bag.close()
	_check("解锁中不能穿透关包", bag.visible)
	var unlock := bag._upgrade_layer.find_child("UnlockRelic_3", true, false) as Button
	before_elixir = int(run.inventory_state.elixir)
	await _click(unlock)
	_check("真实点击整组解锁后恢复界面", not is_instance_valid(bag._upgrade_layer) and RunRewards.board_for_run(run).is_unlocked(3) and RunRewards.board_for_run(run).is_unlocked(7) and int(run.inventory_state.elixir) == before_elixir - 4)
	bag.close()
	run.gold = 3000
	var shop_id := _approach_shop(view)
	_check("找到商店", not shop_id.is_empty())
	await _press_e()
	var popup: ShopPopup = view._shop_popup
	_check("商店服务按钮存在", is_instance_valid(popup) and popup._options.find_child("RemoveCardService", true, false) != null and popup._options.find_child("ExorciseService", true, false) != null)
	var request := popup.request.duplicate(true)
	await _frames(3)
	await _capture("shop-services.png")
	var card: Dictionary = run.deck_cards[0].duplicate(true)
	var original_gold := run.gold
	var shelf_card := popup._options.get_child(0).get_child(0).get_child(0) as Control
	var hover := InputEventMouseMotion.new()
	hover.position = shelf_card.get_global_rect().get_center()
	get_viewport().push_input(hover, true)
	await _frames(3)
	await _capture("shop-preview.png")
	_check("商店悬停大图不拦输入", is_instance_valid(popup._preview) and popup._preview.size.x > 300 and popup._preview.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	popup._hide_preview()
	await _click(popup._options.find_child("RemoveCardService", true, false))
	_check("删牌展示整个牌组", popup._service_mode == "remove")
	popup._continue()
	SaveGateway._load_error = ERR_CANT_OPEN
	var before_count := run.deck.size()
	_check("免费删牌保存失败不吞牌不计次", RunShop.remove_card(run, request, str(run.deck_cards.back().copy_id)) != OK and run.deck.size() == before_count and RunShop.shelf(run, request).removals == 0)
	SaveGateway._load_error = old_error
	var whole_deck := run.deck.duplicate()
	var whole_copies := run.deck_cards.duplicate(true)
	run.deck.assign([run.deck[0]])
	run.deck_cards.assign([run.deck_cards[0]])
	_check("只剩一张牌时不能删除", RunShop.remove_card(run, request, str(run.deck_cards[0].copy_id)) == ERR_UNAVAILABLE and run.deck.size() == 1)
	run.deck.assign(whole_deck)
	run.deck_cards.assign(whole_copies)
	for price: int in [0, 50, 100]:
		var count := run.deck.size()
		var coins := run.gold
		_check("删牌价格 %d" % price, RunShop.removal_price(RunShop.shelf(run, request)) == price and RunShop.remove_card(run, request, str(run.deck_cards.back().copy_id)) == OK and run.deck.size() == count - 1 and run.gold == coins - price)
	_check("每店最多删三次", RunShop.remove_card(run, request, str(run.deck_cards.back().copy_id)) == ERR_UNAVAILABLE and run.gold == original_gold - 150)
	var other_request := request.duplicate(true)
	other_request.node_id = "another-shop"
	_check("其他商店计数独立", RunShop.generate("fixed", str(request.map_id), "other-shop", 1).removals == 0)
	var cursed := RelicCatalog.compose("FRG-001", "FRG-002", 2, "FRG-024")
	_check("测试负面残片合法", RelicCatalog.resolve(cursed) != null)
	run.inventory_state.relic_board.cells[0] = cursed
	_check("备份测试残片", SaveGateway.save_current() == OK)
	SaveGateway._load_error = ERR_CANT_OPEN
	var coins := run.gold
	_check("驱魔保存失败回滚", RunShop.exorcise(run, request, "cell:0") != OK and run.gold == coins and run.inventory_state.relic_board.cells[0] == cursed and not RunShop.shelf(run, request).exorcised)
	SaveGateway._load_error = old_error
	popup._render()
	await _click(popup._options.find_child("ExorciseService", true, false))
	_check("驱魔只列出负面残片", popup._service_mode == "exorcise")
	await _click(popup._options.find_child("ExorcismTarget_cell_0", true, false))
	_check("驱魔清除负面保留主效果", run.gold == coins - 300 and RelicCatalog.resolve(run.inventory_state.relic_board.cells[0]).negative_action.is_empty() and RelicCatalog.resolve(run.inventory_state.relic_board.cells[0]).action_id == RelicCatalog.resolve(cursed).action_id)
	_check("每店驱魔一次", RunShop.exorcise(run, request, "cell:0") == ERR_UNAVAILABLE)
	popup._render()
	before_elixir = int(run.inventory_state.elixir)
	await _click(popup._continue_button)
	_check("离店赠两药", int(run.inventory_state.elixir) == before_elixir + 2)
	await _cold_continue()
	run = SaveGateway.current_run()
	view = get_tree().current_scene
	_check("升级与驱魔冷恢复", RunUpgrades.play_level(run) == 1 and RunRewards.board_for_run(run).is_unlocked(3) and RelicCatalog.resolve(run.inventory_state.relic_board.cells[0]).negative_action.is_empty())
	_approach_shop(view)
	await _press_e()
	popup = view._shop_popup
	_check("商店冷恢复不重置次数", RunShop.shelf(run, popup.request).removals == 3 and RunShop.shelf(run, popup.request).exorcised)
	before_elixir = int(run.inventory_state.elixir)
	await _click(popup._continue_button)
	_check("重访商店不重复赠药", int(run.inventory_state.elixir) == before_elixir)
	_approach(view)
	await _press_e()
	var battle: Node = get_tree().current_scene
	_check("正式地图战斗继承牌位升级", battle.scene_file_path == EncounterFlow.BATTLE_SCENE and int(battle._battle.player.base_play_limit) == 4)
	print("UPGRADES_SERVICES_RESULT failures=%d" % failures)
	get_tree().quit(failures)

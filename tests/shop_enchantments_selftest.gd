extends "res://tests/battle_rewards_selftest.gd"
var captured: Dictionary = {}

func _run() -> void:
	fixture_root = "res://.godot/shop-enchant-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.profile_path = fixture_root.path_join("profile.json")
	SaveGateway.slot_paths.assign([fixture_root.path_join("1.json"), fixture_root.path_join("2.json"), fixture_root.path_join("3.json")])
	SaveGateway._active_slot = 1
	_check("隔离测试档案", SaveGateway._load_slot(1) == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	_config.run_id = "shop-fixture"
	_check("新局", SaveGateway.start_new_run(_seed_with_both_enchantments(), _config) == OK)
	var run := SaveGateway.current_run()
	_check("同名卡有不同永久身份", run.deck_cards.size() == 8 and run.deck_cards[0].copy_id != run.deck_cards[1].copy_id)
	_generation()
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	run.gold = 3000
	var shop_id := _approach_shop(view)
	_check("有可交互商店", not shop_id.is_empty())
	await _press_e()
	var popup: ShopPopup = view._shop_popup
	_check("真实E打开商店且无demo弹窗", is_instance_valid(popup) and not view._dialog.visible and view.paused)
	if not is_instance_valid(popup):
		get_tree().quit(1)
		return
	var request := popup.request.duplicate(true)
	var original := RunShop.shelf(run, request)
	if original.is_empty():
		print("SHOP DIAG request=", request, " session=", view.session.pending, " runmap=", run.current_map_id, " ui=", popup._description.text, " canedit=", RunRewards._can_edit(run))
		print("SHOP CHECKS flow_session=", EncounterFlow.session.pending, " equals=", EncounterFlow.session.pending == request, " floor=", run.map_ids.find(run.current_map_id) + 1, " rewards=", RunRewards.pending(run))
		print("SAVE DIAG ", SaveGateway._error_notice, " map_error ", view.map_run.last_error)
		get_tree().quit(1)
		return
	await _capture("shop.png")
	var price := int(original.cards[0].price)
	await _click(popup._options.find_child("BuyCard_0", true, false))
	_check("购买仅增加一张且扣正确银币", run.deck.size() == 9 and run.gold == 3000 - price and RunShop.shelf(run, request).cards[0].sold)
	_check("售罄不可重复购买", RunShop.buy_card(run, request, 0) == ERR_ALREADY_EXISTS)
	var before_gold := run.gold
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("买牌保存失败回滚副本银币和库存", RunShop.buy_card(run, request, 1) != OK and run.gold == before_gold and run.deck_cards.size() == 9 and not RunShop.shelf(run, request).cards[1].sold)
	SaveGateway._load_error = old_error
	await _click(popup._options.find_child("BuyEnchant_0", true, false))
	_check("获得附魔进入具体副本选牌页", popup._enchant_index == 0 and popup._options.find_child("EnchantTarget_0", true, false) != null)
	await _capture("enchant-targets.png")
	await _click(popup._continue_button)
	_check("取消选牌不扣费不占库存", run.gold == before_gold and not RunShop.shelf(run, request).enchantments[0].sold)
	await _click(popup._options.find_child("BuyEnchant_0", true, false))
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("附魔保存失败回滚", RunShop.buy_enchantment(run, request, 0, str(run.deck_cards[0].copy_id)) != OK and run.gold == before_gold and run.deck_cards[0].enchantments.is_empty())
	SaveGateway._load_error = old_error
	await _click(popup._options.find_child("EnchantTarget_0", true, false))
	var applied := str(original.enchantments[0].id)
	var expected_enchantments: Array = [applied]
	var copy_id := str(run.deck_cards[0].copy_id)
	_check("只附指定同名副本并扣100", run.deck_cards[0].enchantments == [applied] and run.deck_cards[1].enchantments.is_empty() and run.gold == before_gold - 100)
	_check("相同附魔拒绝，最多两个槽", not CardEnchantments.can_apply(run.deck_cards[0], applied) and not CardEnchantments.can_apply({"enchantments": ["damage_50", "repeat_2"]}, "repeat_2"))
	var other := -1
	for index in original.enchantments.size():
		if str(original.enchantments[index].id) != applied:
			other = index
	_check("测试货架含另一种附魔", other >= 0)
	if other >= 0:
		await _click(popup._options.find_child("BuyEnchant_%d" % other, true, false))
		await _click(popup._options.find_child("EnchantTarget_0", true, false))
		expected_enchantments.append(str(original.enchantments[other].id))
		_check("可给同一副本附第二种附魔且其他副本仍为空", run.deck_cards[0].enchantments == expected_enchantments and run.deck_cards[1].enchantments.is_empty() and run.gold == before_gold - 200)
	var affordable_gold := run.gold
	run.gold = 0
	_check("银币不足不能购买且不改变库存", RunShop.buy_card(run, request, 1) == ERR_UNAVAILABLE and not RunShop.shelf(run, request).cards[1].sold)
	run.gold = affordable_gold
	var stale := request.duplicate(true)
	stale.request_id = "fake"
	_check("拒绝伪造或跨节点交易", RunShop.buy_card(run, stale, 1) == ERR_UNAUTHORIZED)
	# 在仍然逛店时冷恢复：恢复待处理请求并重新打开原货架。
	await _cold_continue()
	run = SaveGateway.current_run()
	view = get_tree().current_scene
	popup = view._shop_popup
	_check("冷恢复自动重开同一家店并保留已购买状态", is_instance_valid(popup) and RunShop.shelf(run, popup.request).cards[0].sold and RunShop.shelf(run, popup.request).enchantments[0].sold and run.deck_cards[0].copy_id == copy_id and run.deck_cards[0].enchantments == expected_enchantments)
	var saved_shelf := RunShop.shelf(run, popup.request)
	SaveGateway._load_error = ERR_CANT_OPEN
	await _click(popup._continue_button)
	_check("离店保存失败保留弹窗与新令牌", is_instance_valid(popup) and not view.session.pending.is_empty() and popup.request == view.session.pending)
	SaveGateway._load_error = old_error
	await _click(popup._continue_button)
	_check("离店清除请求并恢复移动", view.session.pending.is_empty() and not view.paused)
	_approach_shop(view)
	await _press_e()
	popup = view._shop_popup
	_check("重访不会重抽货架或重置售罄", RunShop.shelf(run, popup.request) == saved_shelf)
	await _click(popup._continue_button)
	# 检查旧存档无副本字段时可迁移。
	var legacy := run.to_dictionary()
	legacy.erase("deck_cards")
	legacy.erase("next_card_serial")
	var migrated := RunStateMachine.new()
	add_child(migrated)
	_check("旧局按原顺序补副本不丢牌", migrated.restore_from_dictionary(legacy) == OK and migrated.deck_cards.size() == run.deck.size())
	migrated.queue_free()
	# 进入真实地图战斗验证永久副本传递与悬停文本。
	_approach(view)
	await _press_e()
	var battle_ui: Node = get_tree().current_scene
	_check("附魔进入真实地图战斗", battle_ui.scene_file_path == EncounterFlow.BATTLE_SCENE)
	if battle_ui.scene_file_path == EncounterFlow.BATTLE_SCENE:
		var found := false
		for card: Dictionary in battle_ui._battle.hand:
			if card.get("copy_id") == copy_id:
				found = card.enchantments == expected_enchantments
				var slot: Control = battle_ui._make_card_slot(card, 0.3, true)
				battle_ui.add_child(slot)
				battle_ui._on_hand_card_hover_changed(slot, slot.get_child(0), true)
				_check("手牌悬停显示该副本附魔", battle_ui._enchantment_hover.visible and battle_ui._enchantment_hover.get_child(0).text.contains(str(CardEnchantments.DEFINITIONS[applied].name)))
				battle_ui._on_hand_card_hover_changed(slot, slot.get_child(0), false)
				slot.queue_free()
		_check("永久附魔传给对应战斗副本", found)
		if DisplayServer.get_name() != "headless":
			await _frames(10)
			for hand_slot: Control in battle_ui.hand_cards.get_children():
				var instance_id := str(hand_slot.get_meta("instance_id", ""))
				var card := BattleTestScene._find_card(battle_ui._battle.hand, instance_id)
				if card.get("copy_id") == copy_id:
					var motion := InputEventMouseMotion.new()
					motion.position = hand_slot.get_global_rect().get_center()
					get_viewport().push_input(motion, true)
					await get_tree().create_timer(0.9).timeout
					await _capture("battle-enchantment-hover.png")
					break
		await _cold_continue()
		battle_ui = get_tree().current_scene
		var restored_copy := false
		for card: Dictionary in battle_ui._battle.hand:
			if card.get("copy_id") == copy_id:
				restored_copy = card.enchantments == expected_enchantments
		_check("活动战斗冷恢复仍保留副本附魔", restored_copy)
	_battle_rules()
	print("商店与附魔：全部通过" if failures == 0 else "商店与附魔：失败%d项" % failures)
	get_tree().quit(failures)

func _generation() -> void:
	var passed := true
	for seed_index in 30:
		for floor_index in range(1, 4):
			var map_id := "floor-%d" % floor_index
			var shop := RunShop.generate("fixture-%d" % seed_index, map_id, "shop-a", floor_index)
			passed = passed and shop == RunShop.generate("fixture-%d" % seed_index, map_id, "shop-a", floor_index)
			var ids: Array = []
			var rare := 0
			var discounts: Array = []
			for offer: Dictionary in shop.cards:
				ids.append(str(offer.id))
				var is_rare: bool = TextCatalog.entry("cards", str(offer.id)).rarity == "稀有"
				var extra := (floor_index - 1) * 50
				if is_rare:
					rare += 1
					passed = passed and int(offer.base_price) == 350 + extra and int(offer.discount) == 10
				else:
					passed = passed and int(offer.base_price) >= 100 + extra and int(offer.base_price) <= 150 + extra
				if int(offer.discount) < 10:
					discounts.append(int(offer.discount))
				passed = passed and int(offer.price) == int(floor(int(offer.base_price) * int(offer.discount) / 10.0))
			discounts.sort()
			passed = passed and _unique(ids, 6) and rare <= 1 and discounts.size() == 2 and discounts[0] in range(2, 6) and discounts[1] in range(5, 9) and shop.enchantments.size() == 3
	_check("90家店：种子复现、六张不重复、稀有限制、两种折扣与三层价格", passed)
	_check("节点不同独立货架", RunShop.generate("seed", "floor", "a", 1) != RunShop.generate("seed", "floor", "b", 1))

func _approach_shop(view: Node) -> String:
	# 测试夹具解开路线关口后，仍通过合法邻格和真实 E 交互。
	for id: String in view.session.nodes:
		if view.session.nodes[id].is_route_gate:
			view.session.completed[id] = true
			view.session.visits[id] = 1
	for cell: Dictionary in view._map_snapshot.cells:
		view.session.known[Session.key(Vector2i(cell.q, cell.r))] = true
	view._set_paused(false)
	for id: String in view.session.nodes:
		var node: Dictionary = view.session.nodes[id]
		if node.type != "shop":
			continue
		# 地图更新会改变节点编号；夹具选含两种附魔的真实商店，不假设第一家必有两种。
		var run := SaveGateway.current_run()
		var shelf := RunShop.generate(run.main_seed, view.session.map_id, id, view.session.floor_index)
		var enchant_ids: Array = shelf.enchantments.map(func(offer: Dictionary): return str(offer.id))
		if not enchant_ids.has("damage_50") or not enchant_ids.has("repeat_2"):
			continue
		for point: Array in node.footprint:
			for cell: Vector2i in Hex.neighbors(Session.coord(point)):
				var plane := Hex.to_plane(cell, 1.0)
				if view.session.can_stand(plane):
					view.session.actor_plane = plane
					view._sync_view()
					view._sync_actor(false)
					view._selected = id
					view._manual_selection = true
					view._selection_origin = plane
					return id
	return ""

func _seed_with_both_enchantments() -> String:
	# 双槽交易测试需要同店含两种测试附魔，选合法种子而不篡改真实货架或生产随机规则。
	var version := str(ProjectSettings.get_setting("application/config/seed_content_version", ""))
	var settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/relief_2d/exploration.json"))
	for attempt in 20:
		var candidate := "shop-fixed-%d" % attempt
		var source := SeedRegistry.new(version)
		var map_run = preload("res://state_machines/run/planar_map_run.gd").new(source, version)
		if not map_run.start_new_run(candidate, settings.floors):
			continue
		var entry: Dictionary = map_run.enter_floor(1)
		for node: Dictionary in entry.get("snapshot", {}).get("nodes", []):
			if node.type != "shop":
				continue
			var shelf := RunShop.generate(candidate, str(entry.snapshot.map_id), str(node.id), 1)
			var ids: Array = shelf.enchantments.map(func(offer: Dictionary): return str(offer.id))
			if ids.has("damage_50") and ids.has("repeat_2"):
				return candidate
	push_error("测试未找到含两种附魔的商店种子")
	return "shop-fixed"

func _fixture(ids: Array[String], enchantments: Array) -> BattleStateMachine:
	var b := BattleStateMachine.new()
	add_child(b)
	var deck: Array = []
	for index in ids.size():
		deck.append({"instance_id": "e-%d" % index, "card_id": ids[index], "enchantments": enchantments if index == 0 else []})
	_check("效果夹具初始化", b.initialize_battle({"map_id": "enchant-test", "node_id": "effects", "battle_index": 0,
		"draw_count": 0, "player": {"health": 100, "max_health": 200, "block": 0},
		"enemies": [{"enemy_id": "enemy", "health": 1000, "max_health": 1000, "block": 0, "actions": [{"damage": 0}]}], "deck_instances": deck}) == OK)
	var resolver := BattleEffectResolver.new()
	b.add_child(resolver)
	_check("统一规则引擎接入", resolver.attach_to_battle(b) == OK)
	b.start_battle()
	for card: Dictionary in deck:
		var index := b._find_card_index(b.draw_pile, str(card.instance_id))
		b.hand.append(b.draw_pile[index])
		b.draw_pile.remove_at(index)
	b.rules.register_rule("fixture.capture", "flow.enemy.begin", func(_e: BattleEvent): captured = b.to_dictionary(), -10)
	return b

func _battle_rules() -> void:
	var b := _fixture(["1", "1"], ["damage_50", "repeat_2"])
	var first := str(b.hand[0].instance_id)
	var second := str(b.hand[1].instance_id)
	_check("双附魔统一队列结算", b.commit_player_sequence([first, second], {first: "enemy", second: "enemy"}) == OK)
	# 001基础5点：7×2 + 5 = 19。
	_check("伤害向下取整且同名普通副本不受影响", int(captured.enemies[0].health) == 981 and int(captured.pointer_resolutions) == 3)
	if int(captured.enemies[0].health) != 981:
		print("DAMAGE DIAG health ", captured.enemies[0].health)
	_check("回响没有无限重复", b.rules.last_error == OK and b.rules.queue.pending_count() == 0 and not b.rules.queue.paused)
	b.queue_free()
	# 使用原有交互式弃牌原型，回响第二次需要第二次选择。
	b = _fixture(["32", "1", "1", "1", "1"], ["repeat_2"])
	first = str(b.hand[0].instance_id)
	var error := b.commit_player_sequence([first], {first: "enemy"})
	_check("回响弃牌首次进入等待", error == OK and b.has_pending_discard_choice())
	if error == OK and b.has_pending_discard_choice():
		var pauses := 0
		while b.has_pending_discard_choice() and pauses < 4:
			pauses += 1
			var choices: Array[String] = []
			for index in b.pending_discard_count():
				choices.append(str(b.hand[index].instance_id))
			b.submit_discard_choice(choices)
		_check("回响弃牌按次等待输入并恢复", pauses == 2 and not b.rules.queue.paused)
	b.queue_free()
	b = _fixture(["1"], ["damage_50"])
	b.change_buff_layers(&"player", "player", "strength", 2)
	b.change_buff_layers(&"enemy", "enemy", "vulnerable", 1)
	b.commit_player_sequence(["e-0"], {"e-0": "enemy"})
	_check("力量后附魔再易伤，百分比逐次向下取整", int(captured.enemies[0].health) == 985)
	b.queue_free()
	b = _fixture(["26"], ["damage_50"])
	b.commit_player_sequence(["e-0"], {"e-0": "enemy"})
	_check("伤害附魔不放大中毒", int(b.enemies[0].health) == 995)
	b.queue_free()
	b = _fixture(["17"], ["damage_50", "repeat_2"])
	b.commit_player_sequence(["e-0"], {"e-0": "enemy"})
	_check("重复自伤和格挡按次结算，伤害倍率不污染自伤", int(captured.player.health) == 94 and int(captured.player.block) == 16)
	b.queue_free()
	b = _fixture(["1"], ["damage_50"])
	var board := RelicBoard.new()
	for index in RelicBoard.CELL_COUNT:
		board.cells[index] = "on_enemy_damaged" if index < 6 else "deal_damage"
	var relics := RelicBattleSystem.new()
	b.add_child(relics)
	var resolver: BattleEffectResolver = b.get_child(0)
	relics.attach_to_battle(b, board, RelicCatalog.load_definitions(), resolver.buff_catalog)
	b.commit_player_sequence(["e-0"], {"e-0": "enemy"})
	_check("典籍连锁仍每次2伤，不继承卡牌倍率且保护仍生效", relics.activation_count == 128 and int(captured.enemies[0].health) == 737 and b.rules.last_error == OK)
	b.queue_free()

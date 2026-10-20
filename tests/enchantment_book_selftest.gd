extends "res://tests/shop_enchantments_selftest.gd"

func _run() -> void:
	fixture_root = "res://.godot/enchantment-books-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("隔离档案", SaveGateway.load_current() == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	_config.run_id = "enchantment-books"
	_check("新局", SaveGateway.start_new_run("enchantment-books-fixed", _config) == OK)
	_check("正式表22种且保留旧测试伤害附魔", CardEnchantments.reward_ids().size() == 22 and CardEnchantments.valid(["damage_50", "repeat_2"]))
	_check("攻击类型匹配", CardEnchantments.can_apply({"card_id": "1"}, "damage_30") and not CardEnchantments.can_apply({"card_id": "50"}, "damage_30"))
	_check("格挡按指令匹配包括伤害兼格挡", CardEnchantments.can_apply({"card_id": "50"}, CardEnchantments.id_for(21)) and CardEnchantments.can_apply({"card_id": "52"}, CardEnchantments.id_for(21)) and not CardEnchantments.can_apply({"card_id": "1"}, CardEnchantments.id_for(21)))
	await _books()
	await _symbols()
	_battle_rules() # 旧附魔、Buff、残片和交互式弃牌回归。
	_formal_enchantments()
	await _battle_ui()
	print("附魔书与正式附魔：全部通过" if failures == 0 else "附魔书与正式附魔：失败%d项" % failures)
	get_tree().quit(failures)

func _books() -> void:
	var run := SaveGateway.current_run()
	_check("普通战斗不发书", RunRewards.stage_victory(run, "fixture", "common", "普通", 0) == OK and RunRewards.pending(run).entries.size() == 3)
	for entry: Dictionary in RunRewards.pending(run).entries: RunRewards.claim(run, str(entry.id))
	RunRewards.finish_rewards(run)
	for grade: String in ["精英", "BOSS"]:
		_check(grade + "六项奖励末尾附魔书", RunRewards.stage_victory(run, "fixture", grade, grade, 0) == OK and RunRewards.pending(run).entries.size() == 6 and RunRewards.pending(run).entries[5].kind == "enchantment_book")
		var legacy := run.inventory_state.duplicate(true)
		legacy.pending_rewards.entries.pop_back()
		_check("旧版五项未领奖存档兼容", RunStateMachine._valid_inventory_state(legacy))
		for entry: Dictionary in RunRewards.pending(run).entries: _check("奖励可领取 " + str(entry.id), RunRewards.claim(run, str(entry.id)) == OK)
		_check("领奖后可继续", RunRewards.finish_rewards(run) == OK)
		_check("同战斗不重复发书", RunRewards.stage_victory(run, "fixture", grade, grade, 0) == OK and RunRewards.pending(run).is_empty())
	var book := _pack_id(run, "enchantment_book")
	_check("书严格三选一且不重复", RunRewards.open_pack(run, book) == OK and _unique(RunRewards.item(run, book).options, 3))
	var options: Array = RunRewards.item(run, book).options
	_check("不刷新不直接消耗", RunRewards.refresh_pack(run, book) == ERR_UNAVAILABLE and RunRewards.choose(run, book, str(options[0])) == ERR_INVALID_PARAMETER)
	_check("重复打开选项不变", RunRewards.open_pack(run, book) == OK and RunRewards.item(run, book).options == options)
	var popup := LootPopup.new()
	add_child(popup)
	popup.show_pack(book)
	await _frames(3)
	_check("三选一页面且不显示刷新", popup._mode == "pack" and not popup._refresh_button.visible)
	await _capture("enchantment-book-options.png")
	popup._choose(str(options[0]))
	await _frames(3)
	_check("选择附魔进入二级页面但书仍存在", popup._mode == "enchantment_targets" and not RunRewards.item(run, book).is_empty())
	await _capture("enchantment-book-targets.png")
	popup._continue()
	_check("可返回上一层且不重抽", popup._mode == "pack" and RunRewards.item(run, book).options == options)
	popup._finish()
	await _frames(2)
	# 满槽空态；不能消费附魔书，也不能改动同名其他副本。
	var before_deck := run.deck_cards.duplicate(true)
	for card: Dictionary in run.deck_cards: card.enchantments = ["damage_50", "repeat_2"]
	popup = LootPopup.new()
	add_child(popup)
	popup.show_pack(book)
	popup._choose(str(options[0]))
	await _frames(2)
	_check("没有可附魔卡牌时显示准确空态且保留书", popup._options.find_child("NoEnchantmentTargets", true, false) != null and not RunRewards.item(run, book).is_empty())
	await _capture("enchantment-book-empty.png")
	popup._finish()
	run.deck_cards.assign(before_deck)
	# 避免选项恰好只有格挡专属时选错牌，用业务层取真实合格副本。
	var enchantment := str(options[0])
	var targets := RunRewards.enchantment_targets(run, enchantment)
	_check("初始牌组至少一种合格类型", not targets.is_empty())
	var target: Dictionary = targets[0]
	var copy_id := str(target.copy_id)
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("保存失败不吞书不修改牌", RunRewards.apply_book(run, book, enchantment, copy_id) != OK and not RunRewards.item(run, book).is_empty() and run.deck_cards == before_deck)
	SaveGateway._load_error = old_error
	_check("拒绝伪造副本", RunRewards.apply_book(run, book, enchantment, "forged") == ERR_INVALID_PARAMETER)
	_check("选中副本附魔并消耗恰一本书", RunRewards.apply_book(run, book, enchantment, copy_id) == OK and RunRewards.item(run, book).is_empty())
	var changed := 0
	for card: Dictionary in run.deck_cards:
		if not card.enchantments.is_empty():
			changed += 1
			_check("仅目标副本带附魔", card.copy_id == copy_id and card.enchantments == [enchantment])
	_check("同名副本不串附魔", changed == 1)
	_check("书不可重复使用", RunRewards.apply_book(run, book, enchantment, copy_id) == ERR_DOES_NOT_EXIST)
	var second_book := _pack_id(run, "enchantment_book")
	RunRewards.open_pack(run, second_book)
	var second_options: Array = RunRewards.item(run, second_book).options
	_check("冷载入", SaveGateway.load_current() == OK and SaveGateway.continue_saved_run() == OK)
	run = SaveGateway.current_run()
	_check("读档保留具体副本附魔和书选项", run.deck_cards.any(func(card: Dictionary): return card.copy_id == copy_id and card.enchantments == [enchantment]) and RunRewards.item(run, second_book).options == second_options)
	_check("相同附魔及双槽限制", not CardEnchantments.can_apply({"enchantments": [enchantment]}, enchantment) and not CardEnchantments.can_apply({"enchantments": ["repeat_2", "damage_50"]}, CardEnchantments.id_for(1)))
	_check("拒绝损坏附魔书", not RunRewards.valid_items([{"item_id": "bad", "kind": "enchantment_book", "options": [enchantment, enchantment, enchantment], "rerolled": false}]))

func _symbols() -> void:
	var view: CardView = load("res://ui/components/card/card_view.tscn").instantiate()
	view.set_card(FormalCardCatalog.load_definitions().cards["1"])
	view.set_enchantments({"enchantments": ["repeat_2", CardEnchantments.id_for(11)]})
	view.scale = Vector2.ONE * 0.5
	add_child(view)
	await _frames(2)
	var label: Label = view.get_node("附魔符号")
	_check("预ready传入副本、卡面左上显示两个符号", label.visible and label.text == "☽ 🝒" and label.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	var font := label.get_theme_font("font")
	var missing := PackedStringArray()
	for id: String in CardEnchantments.reward_ids():
		var symbol := str(CardEnchantments.DEFINITIONS[id].symbol)
		if not font.has_char(symbol.unicode_at(0)): missing.append(symbol)
	_check("符号字体覆盖22种字符", missing.is_empty())
	if not missing.is_empty(): print("缺字：", missing)
	view.refresh()
	_check("重渲染不抹去副本符号", label.text == "☽ 🝒")
	await _capture("enchantment-card-symbols.png")
	view.set_enchantments({})
	_check("普通副本不显示附魔符号", not label.visible)
	view.queue_free()

func _ench_fixture(ids: Array[String], numbers: Array) -> BattleStateMachine:
	var enchantments: Array = []
	for number: int in numbers: enchantments.append(CardEnchantments.id_for(number))
	return _fixture(ids, enchantments)

func _play(battle: BattleStateMachine, ids: Array[String] = ["e-0"]) -> void:
	captured = {}
	_check("队列开始结算", battle.commit_player_sequence(ids, {"e-0": "enemy", "e-1": "enemy"}) == OK)

func _formal_enchantments() -> void:
	var b := _ench_fixture(["1"], [3])
	_play(b)
	_check("3伤害30%向下取整", int(captured.enemies[0].health) == 994)
	b.queue_free()
	b = _ench_fixture(["1"], [6])
	_play(b)
	_check("6先自伤5后敌方10", int(captured.player.health) == 95 and int(captured.enemies[0].health) == 990)
	b.queue_free()
	b = _ench_fixture(["1"], [13])
	b.enemies[0].block = 8
	_play(b)
	_check("13破格挡双倍且生命不双倍", int(captured.enemies[0].block) == 0 and int(captured.enemies[0].health) == 999)
	b.queue_free()
	b = _ench_fixture(["1"], [14, 15])
	_play(b)
	_check("14伤害50%格挡15伤害25%回复", int(captured.player.block) == 2 and int(captured.player.health) == 101)
	b.queue_free()
	b = _ench_fixture(["1"], [17, 18])
	_play(b)
	_check("17攻击前易伤生效并消耗18先上毒", int(captured.enemies[0].health) == 993 and _buff_layers(captured.enemies[0], "poison") == 1 and _buff_layers(captured.enemies[0], "vulnerable") == 0)
	b.queue_free()
	b = _ench_fixture(["1"], [19])
	_play(b)
	_check("19伤害后虚弱", _buff_layers(captured.enemies[0], "weak") == 1)
	b.queue_free()
	b = _ench_fixture(["1"], [22])
	b.enemies[0].health = 5
	_play(b)
	_check("22最后一击也能回血", int(b.player.health) == 102 and not b.active)
	b.queue_free()
	b = _ench_fixture(["1", "1"], [4])
	b.player.base_play_limit = 1
	_play(b, ["e-0", "e-1"])
	_check("4不占牌位", int(captured.enemies[0].health) == 990)
	b.queue_free()
	b = _ench_fixture(["1"], [5])
	_play(b)
	var generated: Dictionary = captured.hand[0] if not captured.get("hand", []).is_empty() else {}
	_check("5半效一次性牌不继承附魔", generated.get("effect_scale") == 0.5 and generated.get("one_shot") == true and generated.get("enchantments") == [] and not generated.has("copy_id"))
	if not generated.is_empty():
		var generated_id := str(generated.instance_id)
		b.add_generated_card("1", "hand", "fixture_plain")
		var plain_id := str(b.hand.back().instance_id)
		_play(b, [generated_id, plain_id])
		_check("半效5点变2且用后移除、不跳过后一张牌", int(captured.enemies[0].health) == 988 and not _any_zone_has(b, generated_id))
	b.queue_free()
	b = _ench_fixture(["1", "1"], [16])
	b.draw_pile.append(b.hand.pop_back())
	_play(b)
	_check("16触发抽一张牌", captured.hand.size() == 1 and str(captured.hand[0].instance_id) == "e-1")
	b.queue_free()
	_optional(20, "1", true, 993, 0)
	_optional(20, "1", false, 995, 0)
	_optional(21, "50", true, 1000, 6)
	_optional(21, "52", true, 996, 3)
	var repeated := _ench_fixture(["1", "1", "1"], [2, 20])
	_play(repeated)
	_check("重复附魔第一次等待付费", repeated.rules.queue.paused)
	_check("重复附魔第一次付费", repeated.submit_battle_choice(["e-1"]) == OK and repeated.rules.queue.paused)
	_check("重复附魔第二次独立付费", repeated.submit_battle_choice(["e-2"]) == OK and not repeated.rules.queue.paused and int(captured.enemies[0].health) == 986)
	repeated.queue_free()
	_discards()

func _optional(number: int, card_id: String, pay: bool, health: int, block: int) -> void:
	var b := _ench_fixture([card_id, "1"], [number])
	_play(b)
	_check("可选弃牌暂停%d" % number, b.rules.queue.paused and str(b.player.get("battle_choice", {}).get("mode", "")) == "enchantment_%d" % number)
	var ids: Array[String] = ["e-1" if pay else BattleEnchantmentRules.SKIP_ID]
	_check("提交可选弃牌%d" % number, b.submit_battle_choice(ids) == OK)
	_check("选择后倍率/跳过正确%d" % number, int(captured.enemies[0].health) == health and int(captured.player.block) == block and not b.rules.queue.paused)
	if not pay: _check("跳过保留手牌", b._find_card_index(b.hand, "e-1") >= 0)
	b.queue_free()

func _discards() -> void:
	for number in [1, 7, 8, 9, 10, 11, 12]:
		var b := _ench_fixture(["1", "1", "1", "1"], [number])
		# 移三张回抽牌堆，以覆盖弃置抽牌与指针在首格的补抽。
		for id: String in ["e-1", "e-2", "e-3"]:
			var index := b._find_card_index(b.hand, id)
			b.draw_pile.append(b.hand[index])
			b.hand.remove_at(index)
		b.discard_from_hand("e-0", &"chosen")
		match number:
			1: _check("1弃牌改入出牌队尾", b.play_zone.size() == 1 and b.discard_pile.is_empty())
			7: _check("7弃牌敌全体5伤", int(b.enemies[0].health) == 995)
			8: _check("8弃牌抽3张", b.hand.size() == 3)
			9: _check("9弃牌5格挡", int(b.player.block) == 5)
			10: _check("10下次移动重复已登记", int(b.player.enchantment_state.pointer_repeat) == 1)
			11: _check("11首格弃牌抽1", b.hand.size() == 1)
			12: _check("12力量与敌全体易伤", _buff_layers(b.player, "strength") == 1 and _buff_layers(b.enemies[0], "vulnerable") == 1)
		_check("弃牌反应无循环%d" % number, b.rules.last_error == OK and b.rules.queue.pending_count() == 0)
		b.queue_free()
	# 指针实际移动集成：先弃掉带10的牌，再打出两张普通伤害牌。
	var b := _ench_fixture(["1", "1", "1"], [10])
	b.discard_from_hand("e-0", &"chosen")
	_play(b, ["e-1", "e-2"])
	_check("10下次移动所在牌实际重复一次", int(captured.enemies[0].health) == 985 and int(captured.pointer_resolutions) == 3)
	b.queue_free()
	b = _ench_fixture(["1", "1"], [1])
	b.player.base_play_limit = 1
	var retained: Dictionary = b.hand.pop_back()
	b.play_zone.append(retained)
	b.discard_from_hand("e-0", &"chosen")
	_play(b, [])
	_check("强制入队超出牌位时仍可结算已有队列", int(captured.enemies[0].health) == 990 and b.rules.last_error == OK)
	b.queue_free()
	b = _ench_fixture(["1", "1", "1"], [11])
	var discarded := [false]
	b.rules.register_rule("fixture.discard_at_second", "flow.sequence.finish", func(event: BattleEvent):
		if int(event.payload.index) == 1 and not discarded[0]:
			discarded[0] = true
			b.discard_from_hand("e-0", &"chosen"), 1)
	_play(b, ["e-1", "e-2"])
	_check("11非首格弃牌在下次移动前移一位、无无限回跳", int(captured.enemies[0].health) == 985 and int(captured.pointer_resolutions) == 3 and b.rules.last_error == OK)
	b.queue_free()

func _buff_layers(owner: Dictionary, id: String) -> int:
	for buff: Dictionary in owner.get("buffs", []):
		if str(buff.buff_id) == id: return int(buff.layers)
	return 0

func _any_zone_has(b: BattleStateMachine, id: String) -> bool:
	for zone: Array in [b.hand, b.play_zone, b.draw_pile, b.discard_pile]:
		if b._find_card_index(zone, id) >= 0: return true
	return false

func _battle_ui() -> void:
	await _frames(2)
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	scene.deck_card_ids.assign(["1", "1", "50"])
	scene.initial_draw_count = 3
	scene.per_turn_draw_count = 0
	scene.resolution_delay = 0.05
	scene.enemy_turn_delay = 0.05
	scene.enemy_starting_health = 1000
	add_child(scene)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(scene)
	await _frames(3)
	var chosen: Dictionary = {}
	for card: Dictionary in scene._battle.hand:
		if str(card.card_id) == "1": chosen = card; break
	var id := str(chosen.instance_id)
	scene._battle.update_card_properties(id, {"enchantments": [CardEnchantments.id_for(3), CardEnchantments.id_for(20)]})
	scene._queue_refresh()
	await _frames(3)
	var slot: Control
	for child: Control in scene.hand_cards.get_children():
		if str(child.get_meta("instance_id", "")) == id: slot = child; break
	_check("真实手牌显示具体副本符号", slot != null and slot.get_child(0).get_node("附魔符号").text == CardEnchantments.symbols(chosen))
	await _capture("battle-enchantment-hand.png")
	await _click(slot.get_child(1))
	_check("附魔牌仍可点击加入出牌区", scene._selected_ids == [id])
	await get_tree().create_timer(0.4).timeout
	await _capture("battle-enchantment-play.png")
	await _click(scene.play_button)
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline and (not is_instance_valid(scene._battle_choice_layer) or scene._animating):
		await get_tree().create_timer(0.01).timeout
	_check("战斗表现后出现可选弃牌弹窗", is_instance_valid(scene._battle_choice_layer) and scene._battle.rules.queue.paused and not scene._animating)
	if is_instance_valid(scene._battle_choice_layer):
		# 无渲染器时截图不会等待绘制，仍须等待新弹窗完成容器布局。
		await _frames(3)
		await _capture("battle-enchantment-discard-choice.png")
		var root: Control = scene._battle_choice_layer.get_child(0)
		var list: VBoxContainer = root.get_child(1).get_child(0).get_child(1).get_child(0)
		await _click(list.get_child(0))
		await preload("res://tests/support/presentation_test_helper.gd").battle_settled(scene)
		_check("实际点击弃牌恢复动画并完成9伤害", not scene._battle.rules.queue.paused and scene._battle_choice_layer == null and int(scene._battle.enemies[0].health) == 991)
		await _capture("battle-enchantment-completed.png")
	scene.queue_free()
	await _frames(2)

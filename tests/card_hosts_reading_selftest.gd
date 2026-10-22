extends "res://tests/shop_enchantments_selftest.gd"
## 在真实宿主、真实卡面和真实确认按钮上核对阅读/事务边界。
const READER_HELPER := preload("res://tests/support/card_reader_test_helper.gd")
var _host_checks := 0

func _run() -> void:
	fixture_root = "res://.godot/card-host-reading-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	_check("隔离卡牌宿主测试存档", SaveGateway.load_current() == OK)
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	_config.run_id = "card-host-reading"
	_check("建立真实测试局", SaveGateway.start_new_run(_seed_with_both_enchantments(), _config) == OK)
	var run := SaveGateway.current_run()
	run.gold = 3000
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	_check("找到真实商店结点", not _approach_shop(view).is_empty())
	var tip_anchor := Control.new()
	add_child(tip_anchor)
	var pinned_tip := HoverTip.new()
	add_child(pinned_tip)
	pinned_tip.pin_for(tip_anchor, "打开商店时应关闭的固定说明")
	await _press_e()
	_check("打开商店强制关闭固定说明", not pinned_tip.is_pinned() and not pinned_tip.visible)
	pinned_tip.queue_free()
	tip_anchor.queue_free()
	var popup := view._shop_popup as ShopPopup
	_check("真实输入打开商店宿主", is_instance_valid(popup))
	if popup == null:
		get_tree().quit(1)
		return
	await _shop_reading(run, popup)
	popup._finish()
	await _frames(3)
	# 奖励由业务层真实生成；后续 UI 仍负责每次明确确认。
	_check("生成精英奖励", RunRewards.stage_victory(run, "reading-fixture", "elite", "精英", 0) == OK)
	for entry: Dictionary in RunRewards.pending(run).entries:
		_check("领取测试资源 " + str(entry.id), RunRewards.claim(run, str(entry.id)) == OK)
	_check("结束待领奖阶段", RunRewards.finish_rewards(run) == OK)
	await _book_reading(run)
	await _reward_reading(run)
	print("CARD_HOSTS_READING_RESULT checks=%d failures=%d" % [_host_checks, failures])
	get_tree().quit(failures)

func _shop_reading(run: RunStateMachine, popup: ShopPopup) -> void:
	var shelf := RunShop.shelf(run, popup.request)
	var before := run.to_dictionary().duplicate(true)
	var reader := await _inspect(popup, _shop_hit(popup, str(shelf.cards[0].id)), "商品卡面打开阅读")
	_check("商品阅读不扣钱、不购牌、不改库存", run.to_dictionary() == before)
	if reader == null: return
	reader.call("close", "test_cancel")
	await _frames(2)
	_check("取消商品阅读保留全部交易状态", not ReadingDetailOverlay.is_open_for(popup) and run.to_dictionary() == before)
	# 购买仍可走原本的明确购买按钮。
	var count := run.deck.size()
	var gold := run.gold
	await _click(popup._options.find_child("BuyCard_0", true, false))
	_check("原购买按钮恰好购入一张并扣原价", run.deck.size() == count + 1 and run.gold == gold - int(shelf.cards[0].price))
	reader = await _inspect(popup, _shop_hit(popup, str(shelf.cards[1].id)), "第二商品卡面可读")
	if reader == null: return
	var confirm := _reader_callback(reader)
	count = run.deck.size()
	gold = run.gold
	reader.emit_signal("action_requested", "1")
	reader.emit_signal("action_requested", "1")
	await _frames(2)
	_check("重复到达的确认仅交易一次", run.deck.size() == count + 1 and run.gold == gold - int(shelf.cards[1].price) and RunShop.shelf(run, popup.request).cards[1].sold)
	before = run.to_dictionary().duplicate(true)
	_replay_confirmation(confirm, "1")
	_check("已关闭阅读层的延迟确认失效", run.to_dictionary() == before)
	reader = await _inspect(popup, _shop_hit(popup, str(shelf.cards[2].id)), "余额变化前商品可读")
	if reader == null: return
	run.gold = 0
	count = run.deck.size()
	reader.emit_signal("action_requested", "2")
	await _frames(2)
	_check("确认时重验余额，钱不足不交易", run.gold == 0 and run.deck.size() == count and not RunShop.shelf(run, popup.request).cards[2].sold)
	run.gold = gold - int(shelf.cards[1].price)
	popup._render()
	reader = await _inspect(popup, _shop_hit(popup, str(shelf.cards[2].id)), "保存失败前商品可读")
	if reader == null: return
	before = run.to_dictionary().duplicate(true)
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	await _click(READER_HELPER.action_button(popup, "购买"))
	SaveGateway._load_error = old_error
	_check("阅读层购买保存失败保留原事务回滚", run.to_dictionary() == before and not popup._error.text.is_empty())
	await _click(popup._options.find_child("BuyEnchant_0", true, false))
	var target: Dictionary = run.deck_cards[0]
	before = run.to_dictionary().duplicate(true)
	reader = await _inspect(popup, _shop_hit(popup, str(target.copy_id)), "商店附魔卡面打开阅读")
	_check("附魔卡面不消耗钱和附魔库存", run.to_dictionary() == before)
	if reader == null: return
	confirm = _reader_callback(reader)
	popup._continue()
	_replay_confirmation(confirm, str(target.copy_id))
	_check("取消附魔页面使旧阅读确认失效", run.to_dictionary() == before and popup._enchant_index == -1)
	await _frames(3)
	await _click(popup._options.find_child("BuyEnchant_0", true, false))
	reader = await _inspect(popup, _shop_hit(popup, str(target.copy_id)), "商店附魔再次可读")
	if reader == null: return
	count = target.enchantments.size()
	gold = run.gold
	await _click(READER_HELPER.action_button(popup, "附魔"))
	_check("阅读层附魔确认只修改目标副本且扣一次款", run.deck_cards[0].enchantments.size() == count + 1 and run.deck_cards[1].enchantments.is_empty() and run.gold == gold - int(shelf.enchantments[0].price))
	await _click(popup._options.find_child("RemoveCardService", true, false))
	target = run.deck_cards.back().duplicate(true)
	before = run.to_dictionary().duplicate(true)
	reader = await _inspect(popup, _shop_hit(popup, str(target.copy_id)), "删除目标卡面打开阅读")
	_check("删除卡面不删除、不计次、不扣钱", run.to_dictionary() == before)
	if reader == null: return
	reader.call("close", "test_cancel")
	await _frames(2)
	_check("取消删除阅读保持牌组", run.to_dictionary() == before)
	reader = await _inspect(popup, _shop_hit(popup, str(target.copy_id)), "删除目标可再次阅读")
	if reader == null: return
	count = run.deck.size()
	await _click(READER_HELPER.action_button(popup, "删除此牌"))
	_check("明确删除只移除一个副本并计一次服务", run.deck.size() == count - 1 and RunShop.shelf(run, popup.request).removals == 1 and not run.deck_cards.any(func(card: Dictionary): return card.copy_id == target.copy_id))
	reader = await _inspect(popup, _shop_hit(popup, str(shelf.cards[3].id)), "隐藏前商品可读")
	if reader == null: return
	confirm = _reader_callback(reader)
	before = run.to_dictionary().duplicate(true)
	popup.hide()
	_check("隐藏商店同步关闭读取层", not ReadingDetailOverlay.is_open_for(popup))
	_replay_confirmation(confirm, "3")
	_check("隐藏宿主拒绝延迟购买", run.to_dictionary() == before)
	popup.show()
	popup._render()

func _book_reading(run: RunStateMachine) -> void:
	var book_id := _pack_id(run, "enchantment_book")
	var popup := LootPopup.new()
	add_child(popup)
	popup.show_pack(book_id)
	var book := RunRewards.item(run, book_id)
	var enchantment_id := str(book.options[0])
	popup._choose(enchantment_id)
	await _frames(3)
	var targets := RunRewards.enchantment_targets(run, enchantment_id)
	_check("附魔书存在有效副本目标", not targets.is_empty())
	if targets.is_empty():
		popup._finish()
		return
	var copy_id := str(targets[0].copy_id)
	var before := run.to_dictionary().duplicate(true)
	var hit := popup._options.find_child("InspectEnchantCopy_" + copy_id.validate_node_name(), true, false) as Button
	var reader := await _inspect(popup, hit, "附魔书目标卡面打开阅读")
	_check("附魔书卡面不吞书不修改卡", run.to_dictionary() == before)
	if reader == null:
		popup._finish()
		return
	var confirm := _reader_callback(reader)
	popup._continue()
	_replay_confirmation(confirm, copy_id)
	_check("返回书的上级页面拒绝旧确认", run.to_dictionary() == before and not ReadingDetailOverlay.is_open_for(popup))
	popup._choose(enchantment_id)
	await _frames(3)
	hit = popup._options.find_child("InspectEnchantCopy_" + copy_id.validate_node_name(), true, false) as Button
	reader = await _inspect(popup, hit, "附魔书返回后目标仍可读")
	if reader == null:
		popup._finish()
		return
	await _click(READER_HELPER.action_button(popup, "附魔"))
	_check("明确附魔才消耗一本书并只修改指定副本", RunRewards.item(run, book_id).is_empty() and run.deck_cards.any(func(card: Dictionary): return card.copy_id == copy_id and enchantment_id in card.enchantments))

func _reward_reading(run: RunStateMachine) -> void:
	var pack_id := _pack_id(run, "common_pack")
	var popup := LootPopup.new()
	add_child(popup)
	popup.show_pack(pack_id)
	await _settle_pack(popup)
	var before := run.to_dictionary().duplicate(true)
	var reader := await _inspect(popup, popup._choice_fan._hits[0], "奖励卡面打开阅读")
	_check("奖励卡面不消费卡包不发牌", run.to_dictionary() == before)
	if reader == null:
		popup._finish()
		return
	var option := str(RunRewards.item(run, pack_id).options[0])
	var confirm := _reader_callback(reader)
	popup._toggle_suspension()
	_replay_confirmation(confirm, option)
	_check("悬置关闭阅读且拒绝旧确认", popup.is_suspended() and not ReadingDetailOverlay.is_open_for(popup) and run.to_dictionary() == before)
	popup._toggle_suspension()
	await _settle_pack(popup)
	reader = await _inspect(popup, popup._choice_fan._hits[0], "恢复奖励后可继续阅读")
	if reader == null:
		popup._finish()
		return
	confirm = _reader_callback(reader)
	popup._refresh_offer()
	await _settle_pack(popup)
	before = run.to_dictionary().duplicate(true)
	_replay_confirmation(confirm, option)
	_check("刷新选项关闭旧阅读且拒绝旧选择", not ReadingDetailOverlay.is_open_for(popup) and run.to_dictionary() == before)
	reader = await _inspect(popup, popup._choice_fan._hits[0], "刷新后新卡面可读")
	if reader == null:
		popup._finish()
		return
	reader.call("close", "test_cancel")
	await _frames(2)
	_check("取消奖励阅读保留完整卡包状态", run.to_dictionary() == before)
	reader = await _inspect(popup, popup._choice_fan._hits[0], "取消后可重新阅读")
	if reader == null:
		popup._finish()
		return
	confirm = _reader_callback(reader)
	option = str(RunRewards.item(run, pack_id).options[0])
	var count := run.deck.size()
	await _click(READER_HELPER.action_button(popup, "选择此牌"))
	_replay_confirmation(confirm, option)
	_check("选择此牌明确确认恰好发一张并消费一次卡包", run.deck.size() == count + 1 and RunRewards.item(run, pack_id).is_empty())
	var rare_id := _pack_id(run, "rare_pack")
	popup = LootPopup.new()
	add_child(popup)
	popup.show_pack(rare_id)
	await _settle_pack(popup)
	reader = await _inspect(popup, popup._choice_fan._hits[0], "待销毁奖励宿主可读")
	if reader == null:
		popup._finish()
		return
	confirm = _reader_callback(reader)
	option = str(RunRewards.item(run, rare_id).options[0])
	before = run.to_dictionary().duplicate(true)
	var owner_panel := Control.new()
	add_child(owner_panel)
	popup.reparent(owner_panel)
	owner_panel.hide()
	_replay_confirmation(confirm, option)
	_check("祖先隐藏后立即拒绝读取层迟到确认", run.to_dictionary() == before)
	owner_panel.show()
	var reader_reference: WeakRef = weakref(reader)
	var owner_reference: WeakRef = weakref(popup)
	popup.queue_free()
	_replay_confirmation(confirm, option)
	_check("宿主等待销毁期间拒绝读取层迟到确认", run.to_dictionary() == before)
	await _frames(3)
	_check("销毁宿主关闭读取层且不发奖", run.to_dictionary() == before and not is_instance_valid(owner_reference.get_ref()) and not is_instance_valid(reader_reference.get_ref()))
	owner_panel.queue_free()

func _replay_confirmation(callback: Callable, token: String) -> void:
	if callback.is_valid(): callback.call(token)

func _shop_hit(popup: ShopPopup, id: String) -> Button:
	return popup._options.find_child("InspectCard_" + id.validate_node_name(), true, false) as Button

func _inspect(owner: LootPopup, hit: Button, label: String) -> CanvasLayer:
	await _frames(3)
	await _click(hit)
	var reader := READER_HELPER.active_reader(owner)
	_check(label, reader != null and ReadingDetailOverlay.is_open_for(owner))
	return reader

func _reader_callback(reader: CanvasLayer) -> Callable:
	return reader.get_signal_connection_list("action_requested")[0].callable

func _check(label: String, passed: bool) -> void:
	_host_checks += 1
	super._check(label, passed)

extends "res://tests/battle_rewards_selftest.gd"
## 真实点击测试：动画只改表现，悬置保留待选状态、只读查看与事务边界。

func _run() -> void:
	fixture_root = "res://.godot/reward-choice-animation-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("独立测试存档", SaveGateway.load_current() == OK)
	_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	_config.run_id = "reward-choice-animation"
	_check("测试新局", SaveGateway.start_new_run("reward-choice-animation", _config) == OK)
	var run := SaveGateway.current_run()
	RunRewards.stage_victory(run, "fixture", "elite", "精英", 0)
	for entry: Dictionary in RunRewards.pending(run).entries: RunRewards.claim(run, str(entry.id))
	RunRewards.finish_rewards(run)
	for index in 18: run.add_card("1")
	run.items.append({"item_id": "fixture-fragment", "kind": "fragment", "fragment_id": "FRG-001"})
	RunRewards.equip_fragment(run, "fixture-fragment", 0)
	run.items.append({"item_id": "fixture-second-fragment", "kind": "fragment", "fragment_id": "FRG-002"})
	var background := ColorRect.new()
	background.color = Color("505762")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var bag := RunMenuOverlay.new()
	add_child(bag)
	bag.open(1)
	await get_tree().create_timer(0.3).timeout
	var common := _pack_id(run, "common_pack")
	bag._on_item_pressed(common)
	var popup := bag._pack_popup
	var fan := popup._choice_fan
	_check("三张卡从中央缩略状态展开", fan._items.size() == 3 and fan._opening and fan._states.all(func(state: Dictionary): return float(state.zoom) == RewardChoiceFan.THUMBNAIL_SCALE))
	await get_tree().create_timer(0.09).timeout
	_check("先飞散再放大", float(fan._states[0].zoom) == RewardChoiceFan.THUMBNAIL_SCALE and Vector2(fan._states[0].center).distance_to(fan.size * 0.5) > 40.0)
	await _settle_pack(popup)
	await get_tree().create_timer(0.2).timeout
	_check("展开后变暗且锁定背包编辑", popup._shade.modulate.a > 0.99 and popup._shade.mouse_filter == Control.MOUSE_FILTER_STOP and not bag._can_edit_relics())
	_check("新金色关闭按钮保留选择锁", bag._close_button.icon != null and bag._close_button.disabled)
	await _capture("01-cards-open.png")
	var before: Dictionary = run.to_dictionary().duplicate(true)
	var original_options: Array = RunRewards.item(run, common).options.duplicate()
	var centers: Array[Vector2] = []
	for state: Dictionary in fan._states: centers.append(state.center)
	_move_mouse(fan._hits[1].get_global_rect().get_center())
	await get_tree().create_timer(0.5).timeout
	_check("悬停卡放大到1.35倍且两边让位", float(fan._states[1].zoom) > 1.3 and fan._states[0].center.x < centers[0].x - 25.0 and fan._states[2].center.x > centers[2].x + 25.0)
	_check("悬停让位没有重叠", fan._hits[0].get_global_rect().end.x < fan._hits[1].get_global_rect().position.x and fan._hits[1].get_global_rect().end.x < fan._hits[2].get_global_rect().position.x)
	await _capture("02-card-hover.png")
	await _click(popup._continue_button)
	await get_tree().create_timer(0.25).timeout
	_check("悬置收牌去暗，但依然等待选择", popup.is_suspended() and not fan.visible and popup._shade.modulate.a < 0.01 and popup._shade.mouse_filter == Control.MOUSE_FILTER_IGNORE and popup._continue_button.text == "恢复选择")
	bag.close()
	bag.set_page(2)
	bag._on_item_pressed("fixture-second-fragment")
	bag._unmount_relic(0)
	bag._apply_relic_drop(0, 1, "FRG-001")
	popup._choose(str(original_options[0]))
	_check("悬置不能关闭背包、换页、使用物品、改典籍或暗选", bag.visible and bag.current_page() == 1 and run.to_dictionary() == before and bag._selected_fragment_id.is_empty())
	await _click(bag._deck_grid.get_child(0).get_child(1))
	_check("悬置时仍可点击查看牌组大图", bag._peek_layer.visible)
	await _capture("03-suspended-card-peek.png")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	get_viewport().push_input(escape, true)
	await _frames(2)
	_check("Esc只关闭大图，不退出悬置选择", not bag._peek_layer.visible and popup.is_suspended())
	_move_mouse(bag._relic_drop_cells[0].get_global_rect().get_center())
	await _frames(3)
	_check("悬置仍可查看残片说明且格子不可编辑", bag._item_tip != null and bag._item_tip.visible and not bag._relic_drop_cells[0].editable)
	await _capture("04-suspended-relic-tip.png")
	bag._deck_scroll.scroll_vertical = 100
	await _frames(3)
	_check("悬置允许滚动牌组", bag._deck_scroll.scroll_vertical > 0)
	await _click(popup._continue_button)
	await _settle_pack(popup)
	_check("恢复重新弹出同一组选项且仍锁编辑", not popup.is_suspended() and fan.visible and RunRewards.item(run, common).options == original_options and not bag._can_edit_relics())
	for index in 4:
		popup._toggle_suspension()
		await get_tree().create_timer(0.035).timeout
	await _settle_pack(popup)
	_check("连续悬置恢复不重抽不叠加选项", not popup.is_suspended() and fan._items.size() == 3 and RunRewards.item(run, common).options == original_options)
	await _click(popup._refresh_button)
	await _settle_pack(popup)
	var refreshed: Array = RunRewards.item(run, common).options.duplicate()
	_check("保留一次刷新且重新播放展开", _unique(refreshed, 3) and _disjoint(original_options, refreshed) and popup._refresh_button.disabled)
	var old_deck_size := run.deck.size()
	await _click(popup._choice_fan._hits[0])
	_check("卡面仅打开持久阅读，卡包和牌组未变", not RunRewards.item(run, common).is_empty() and run.deck.size() == old_deck_size and ReadingDetailOverlay.is_open_for(popup))
	await _confirm_card_reader(popup)
	await _frames(3)
	_check("详情明确选择恰好领取一次并恢复背包操作", RunRewards.item(run, common).is_empty() and run.deck.size() == old_deck_size + 1 and not is_instance_valid(bag._pack_popup) and bag._can_edit_relics() and bag._relic_drop_cells[0].editable)
	var fragment_pack := _pack_id(run, "fragment_pack")
	bag._on_item_pressed(fragment_pack)
	popup = bag._pack_popup
	await _settle_pack(popup)
	fan = popup._choice_fan
	_check("残片包用同一弹簧展开两份可点击残片", fan._items.size() == 2 and fan._item_size == Vector2(330, 470))
	_move_mouse(fan._hits[0].get_global_rect().get_center())
	await get_tree().create_timer(0.5).timeout
	_check("残片悬停同样放大让位", fan._hovered == 0 and float(fan._states[0].zoom) > 1.3 and fan._hits[0].get_global_rect().end.x < fan._hits[1].get_global_rect().position.x)
	await _capture("05-fragments-hover.png")
	var fragment_id := str(RunRewards.item(run, fragment_pack).options[0])
	await _click(fan._hits[0])
	_check("直接点残片收入背包，不自动装配", RunRewards.item(run, fragment_pack).is_empty() and RunRewards.item(run, fragment_pack + "/fragment").fragment_id == fragment_id and run.inventory_state.relic_board.cells[0] == "FRG-001")
	bag._on_item_pressed(_pack_id(run, "rare_pack"))
	popup = bag._pack_popup
	await _settle_pack(popup)
	_check("稀有包同样展开但无刷新", popup._choice_fan._items.size() == 3 and not popup._refresh_button.visible)
	await _click(popup._choice_fan._hits[0])
	await _confirm_card_reader(popup)
	bag._on_item_pressed(_pack_id(run, "enchantment_book"))
	popup = bag._pack_popup
	_check("附魔书保持既有二级选牌流程", not popup.is_selection_locked() and popup._choice_fan == null and popup._options.get_child_count() == 1)
	popup._finish()
	await _frames(3)
	bag.queue_free()
	print("奖励弹簧动画与悬置：全部通过" if failures == 0 else "奖励弹簧动画与悬置：失败%d项" % failures)
	get_tree().quit(failures)

func _move_mouse(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)

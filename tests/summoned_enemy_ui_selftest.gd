extends "res://tests/battle_animation_selftest.gd"


func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/summon-lineup-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("召唤测试使用独立存档", SaveGateway.load_current() == OK)
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.relic_board_path = fixture_root.path_join("empty.json")
	scene.deck_card_ids.assign(["test_damage_enemy", "test_damage_enemy"])
	scene.initial_draw_count = 2
	add_child(scene)
	await _wait_presentation(scene)
	scene._battle.enemies.assign([MonsterCatalog.create("11", 2)])
	var primary: Dictionary = scene._battle.enemies[0]
	var owner := str(primary.enemy_id)
	scene._refresh_combat_status()
	await get_tree().create_timer(0.35).timeout
	var context := BattleEffectContext.new(scene._battle, owner, scene._resolver.buff_catalog)
	context.damage_enemy(owner, int(primary.health), true)
	var spawn_events := scene._resolution_events.filter(func(e: Dictionary): return e.kind == "enemy_spawned")
	_check("真实阶段转换经过队列召唤两只独立怪物", scene._battle.enemies.size() == 3 and int(primary.phase) == 2 and spawn_events.size() == 2)
	if scene._battle.enemies.size() != 3 or spawn_events.size() != 2:
		get_tree().quit(1)
		return
	_check("召唤快照逐个增长且不提前显示最终阵容", spawn_events[0].enemies.size() == 2 and spawn_events[1].enemies.size() == 3 and scene.enemy_rack.slots.size() == 1)
	await _wait_presentation(scene)
	await get_tree().create_timer(0.35).timeout
	var knight: Dictionary = scene._battle.enemies[1]
	var thief: Dictionary = scene._battle.enemies[2]
	var knight_id := str(knight.enemy_id)
	var thief_id := str(thief.enemy_id)
	var knight_view: EnemySlot = scene.enemy_rack.slot_for(knight_id)
	var thief_view: EnemySlot = scene.enemy_rack.slot_for(thief_id)
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	_check("本体阶段转换后恢复正常亮度", is_equal_approx(main.portrait.modulate.a, 1.0))
	_check("本体与随从通过独立槽位同屏且不共享血条", scene.enemy_rack.slots.size() == 3 and main.visible and knight_view.visible and thief_view.visible and main.fill != knight_view.fill and knight_view.fill != thief_view.fill)
	_check("槽位横向排布不重叠，点击区域不遮挡手牌", main.get_rect().end.x <= knight_view.position.x and knight_view.get_rect().end.x <= thief_view.position.x and scene.enemy_rack.position.y + main.position.y + main.click_height() <= scene.hand_scroll.position.y)
	var intent_data := knight.duplicate(true)
	intent_data.actions = [{"block": 9}]
	knight_view.show_snapshot_status(intent_data, false, true)
	_check("防御意图显示防御资源和格挡值", knight_view._intent_badge.texture.atlas.resource_path.ends_with("/防御.png") and knight_view.intent_value.text == "9")
	intent_data.actions = [{"summon": "4"}]
	knight_view.show_snapshot_status(intent_data, false, true)
	_check("特殊意图不显示错误的0点攻击", knight_view._intent_badge.texture.atlas.resource_path.ends_with("/特殊.png") and knight_view.intent_value.text == "—")
	scene._refresh_combat_status()
	await _click_enemy(knight_view)
	_check("直接点击随从选择目标，其他槽仍显示自己的身份", scene._chosen_enemy_id() == knight_id and main.name_label.text == str(primary.name) and main.portrait.texture == TextCatalogService.art_texture(str(primary.art_path)))
	await _capture("summoned-enemies.png")
	var main_ratio := float(main.fill.get("ratio"))
	var old_health := int(knight.health)
	context.damage_enemy(knight_id, 7, true)
	_check("受伤事件保留具体怪物ID", scene._resolution_events.any(func(e: Dictionary): return e.kind == "damage" and e.entity_id == knight_id))
	await _wait_presentation(scene)
	await get_tree().create_timer(0.35).timeout
	_check("随从伤害不影响本体血条", int(knight.health) == old_health - 7 and is_equal_approx(float(knight_view.fill.get("ratio")), float(knight.health) / float(knight.max_health)) and is_equal_approx(float(main.fill.get("ratio")), main_ratio))
	_check("受击反馈解析到随从自己的立绘", scene._feedback._enemy_view(knight_id).portrait == knight_view.portrait and scene._feedback._enemy_view(thief_id).portrait == thief_view.portrait and scene._feedback._flash_tweens.has("enemy/" + knight_id))
	scene._battle.rules.submit("action.block", {"side": "enemy", "target": knight_id, "amount": 3})
	scene._battle.rules.submit("monster.heal", {"target": knight_id, "amount": 4})
	await _wait_presentation(scene)
	await get_tree().create_timer(0.35).timeout
	_check("治疗与格挡不串到本体或其他随从", int(knight.health) == old_health - 3 and int(knight_view.shield.get("value")) == 3 and int(thief_view.shield.get("value")) == 0 and int(main.shield.get("value")) == 0)
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	for index in 3: scene._refresh_combat_status()
	_check("阵容刷新不消耗种子随机流", JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _click_enemy(thief_view)
	var thief_health := int(thief.health)
	await _click_target(scene.hand_cards.get_child(0).get_child(1))
	_check("有召唤物时仍能通过真实鼠标选择手牌", scene._selected_ids.size() == 1)
	await get_tree().create_timer(0.45).timeout
	scene._on_play_pressed()
	await _wait_presentation(scene)
	_check("真实出牌伤害点选随从，不误伤本体", int(thief.health) == thief_health - 8 and int(primary.health) == int(primary.max_health))
	for index in 4: scene._battle.rules.submit("monster.summon", {"id": "4", "owner": owner})
	await _wait_presentation(scene)
	var fits := true
	for slot: EnemySlot in scene.enemy_rack.slots:
		fits = fits and scene.enemy_rack.zone.grow(0.1).encloses(slot.get_rect())
	_check("多次召唤使用唯一槽位并缩排在敌人区域", scene.enemy_rack.slots.size() == 7 and fits)
	await _capture("many-summoned-enemies.png")
	scene._battle.rules.submit("monster.summon", {"id": "5", "owner": owner})
	await _wait_presentation(scene)
	var guard: Dictionary = scene._battle.enemies.back()
	knight_view = scene.enemy_rack.slot_for(knight_id)
	thief_view = scene.enemy_rack.slot_for(thief_id)
	main = scene.enemy_rack.slot_for(owner)
	var guard_view: EnemySlot = scene.enemy_rack.slot_for(str(guard.enemy_id))
	_check("嘲讽强制目标并禁用其他随从点击", scene._chosen_enemy_id() == str(guard.enemy_id) and not knight_view.selectable)
	scene._on_enemy_slot_selected(thief_id)
	_check("不能绕过嘲讽选择其他目标", scene._chosen_enemy_id() == str(guard.enemy_id))
	context.damage_enemy(str(guard.enemy_id), int(guard.health), true)
	await _wait_presentation(scene)
	await get_tree().create_timer(0.5).timeout
	_check("召唤物死亡后退场且意图隐藏", not guard_view.visible and not guard_view.selectable and not guard_view.intent_value.visible)
	await _click_enemy(thief_view)
	_check("嘲讽死亡后可选择其他单位", scene._chosen_enemy_id() == thief_id)
	context.damage_enemy(owner, int(primary.health), true)
	await _wait_presentation(scene)
	await get_tree().create_timer(0.5).timeout
	_check("本体死亡不替换身份，存活随从仍可攻击", scene._battle.active and main.name_label.text == str(primary.name) and main.portrait.modulate.a < 0.5 and thief_view.visible and thief_view.selectable)
	await _capture("primary-defeated.png")
	scene.queue_free()
	await _frames(4)
	print("召唤同屏与独立血条：全部通过" if failures == 0 else "召唤同屏与独立血条：失败%d项" % failures)
	get_tree().quit(failures)


func _click_enemy(slot: EnemySlot) -> void:
	var at := slot.get_global_rect().position + Vector2(slot.size.x * 0.5, minf(slot.click_height() * 0.5, 120.0))
	slot.get_viewport().warp_mouse(at)
	await _frames(2)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.pressed = pressed
		Input.parse_input_event(event)
		await _frames(2)
	await _frames(3)


func _click_target(button: Button) -> void:
	button.get_viewport().warp_mouse(button.get_global_rect().get_center())
	await _frames(2)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = button.get_global_rect().get_center()
		event.pressed = pressed
		Input.parse_input_event(event)
		await _frames(2)
	await _frames(3)

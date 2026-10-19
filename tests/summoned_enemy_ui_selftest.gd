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
	var original_rect: Rect2 = scene.get_node("EnemyPortrait").get_rect()
	scene._battle.enemies.assign([MonsterCatalog.create("11", 2)])
	var primary: Dictionary = scene._battle.enemies[0]
	var owner := str(primary.enemy_id)
	scene._refresh_combat_status()
	await get_tree().create_timer(0.35).timeout
	# 正式怪物规则：第一阶段致死后变为第二阶段，并依序召唤骑士和盗贼。
	var context := BattleEffectContext.new(scene._battle, owner, scene._resolver.buff_catalog)
	context.damage_enemy(owner, int(primary.health), true)
	var spawn_events := scene._resolution_events.filter(func(e: Dictionary): return e.kind == "enemy_spawned")
	_check("真实阶段转换经过队列召唤两只独立怪物", scene._battle.enemies.size() == 3 and int(primary.phase) == 2 and spawn_events.size() == 2)
	if scene._battle.enemies.size() != 3:
		get_tree().quit(1)
		return
	_check("召唤快照逐个增长且不提前显示最终阵容", spawn_events[0].enemies.size() == 2 and spawn_events[1].enemies.size() == 3 and scene._companion_views.is_empty())
	await _wait_presentation(scene)
	await get_tree().create_timer(0.35).timeout
	var knight: Dictionary = scene._battle.enemies[1]
	var thief: Dictionary = scene._battle.enemies[2]
	var knight_id := str(knight.enemy_id)
	var thief_id := str(thief.enemy_id)
	var knight_view: Control = scene._companion_views[knight_id]
	var thief_view: Control = scene._companion_views[thief_id]
	var main: Control = scene.get_node("EnemyPortrait")
	_check("本体阶段转换后恢复正常亮度，不残留死亡透明度", is_equal_approx(main.modulate.a, 1.0))
	_check("有召唤物时本体仍保持原始位置和尺寸", main.get_rect().is_equal_approx(original_rect) and main.scale == Vector2.ONE)
	_check("本体点击区域不能遮挡手牌", scene._primary_enemy_hit.get_rect().end.y <= scene.hand_scroll.position.y)
	_check("本体和召唤物同屏，仅缩放两侧随从", main.visible and knight_view.visible and thief_view.visible and knight_view.size.x < main.size.x and knight_view.size.y < main.size.y)
	_check("两只随从排列在本体两侧且不遮挡手牌", knight_view.position.x < main.position.x and thief_view.position.x > main.position.x and knight_view.get_rect().end.y <= 650.1)
	_check("短血条右侧显示缩小的独立行动意图", knight_view.intent.visible and thief_view.intent.visible and knight_view.intent.scale.x < 1.0 and knight_view.intent.position.x > knight_view.health_bar.position.x and knight_view.intent_value.text == str(knight.actions[0].damage) and thief_view.intent_value.text == str(thief.actions[0].damage))
	var intent_data := knight.duplicate(true)
	intent_data.actions = [{"block": 9}]
	knight_view.show_snapshot(intent_data, false, true)
	_check("防御意图显示防御资源和格挡值", knight_view.intent_badge.texture.atlas.resource_path.ends_with("/防御.png") and knight_view.intent_value.text == "9")
	intent_data.actions = [{"summon": "4"}]
	knight_view.show_snapshot(intent_data, false, true)
	_check("非攻击动作显示特殊意图而不是错误的0点攻击", knight_view.intent_badge.texture.atlas.resource_path.ends_with("/特殊.png") and knight_view.intent_value.text == "—")
	scene._refresh_combat_status()
	_check("各有独立短血条且移除旧切换列表", knight_view.health_bar != thief_view.health_bar and knight_view.health_bar.size.x * knight_view.health_bar.scale.x < scene.get_node("EnemyHPBar").size.x and not scene.has_node("EnemyTargetSelector"))
	await _click_target(knight_view.hit)
	_check("直接点击随从作为目标，不替换本体名称和立绘", scene._chosen_enemy_id() == knight_id and scene.get_node("EnemyName").text == str(primary.name) and main.texture == TextCatalogService.art_texture(str(primary.art_path)))
	await _capture("summoned-enemies.png")
	var main_ratio := float(scene.enemy_hp_fill.get("ratio"))
	var old_health := int(knight.health)
	context.damage_enemy(knight_id, 7, true)
	_check("受伤事件保留具体怪物ID", scene._resolution_events.any(func(e: Dictionary): return e.kind == "damage" and e.entity_id == knight_id))
	await _wait_presentation(scene)
	var fill: Control = knight_view.health_bar.get_node("Fill")
	var tween: Tween = fill.get_meta("tween")
	tween.pause()
	var start := float(fill.get("ratio"))
	scene._refresh_combat_status()
	_check("随从血条刷新不重置动画，也不影响本体", fill.get_meta("tween") == tween and is_equal_approx(float(fill.get("ratio")), start) and is_equal_approx(float(scene.enemy_hp_fill.get("ratio")), main_ratio))
	tween.custom_step(0.31)
	_check("短血条在0.3秒后到达正确比例", int(knight.health) == old_health - 7 and is_equal_approx(float(fill.get("ratio")), float(knight.health) / float(knight.max_health)))
	_check("受击反馈定位到随从本身", scene._feedback._portrait(&"enemy", knight_id) == knight_view.portrait and scene._feedback._portrait(&"enemy", thief_id) == thief_view.portrait and scene._feedback._flash_tweens.has("enemy:" + knight_id))
	scene._battle.rules.submit("action.block", {"side": "enemy", "target": knight_id, "amount": 3})
	scene._battle.rules.submit("monster.heal", {"target": knight_id, "amount": 4})
	await _wait_presentation(scene)
	await get_tree().create_timer(0.35).timeout
	_check("各自治疗与格挡不串到本体或其他随从", int(knight.health) == old_health - 3 and int(knight_view.block_shield.get("value")) == 3 and int(thief_view.block_shield.get("value")) == 0 and int(scene.enemy_block_shield.get("value")) == 0)
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	for index in 3: scene._refresh_combat_status()
	_check("阵容刷新不消耗种子随机流", JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	await _click_target(thief_view.hit)
	var thief_health := int(thief.health)
	await _click_target(scene.hand_cards.get_child(0).get_child(1))
	_check("有召唤物时仍能通过真实鼠标点击选择手牌", scene._selected_ids.size() == 1)
	await get_tree().create_timer(0.45).timeout
	scene._on_play_pressed()
	await _wait_presentation(scene)
	_check("真实出牌通过队列伤害点选的随从，不误伤本体", int(thief.health) == thief_health - 8 and int(primary.health) == int(primary.max_health))
	# 同种怪物可被多次召唤，但仍有各自的立绘、血条与唯一 ID。
	for index in 4: scene._battle.rules.submit("monster.summon", {"id": "4", "owner": owner})
	await _wait_presentation(scene)
	var fits := true
	for enemy: Dictionary in scene._battle.enemies.slice(1):
		var rect: Rect2 = scene._companion_views[str(enemy.enemy_id)].get_rect()
		fits = fits and scene.ENEMY_LINEUP_AREA.grow(0.1).encloses(rect)
	_check("多次召唤不重用视图且自动缩排避开UI", scene._companion_views.size() == 6 and fits)
	_check("召唤数量增多也不能缩小或挪动本体", main.get_rect().is_equal_approx(original_rect) and main.scale == Vector2.ONE)
	await _capture("many-summoned-enemies.png")
	scene._battle.rules.submit("monster.summon", {"id": "5", "owner": owner})
	await _wait_presentation(scene)
	var guard: Dictionary = scene._battle.enemies.back()
	_check("嘲讽仍强制目标并禁用其他随从点击", scene._chosen_enemy_id() == str(guard.enemy_id) and knight_view.hit.disabled)
	scene._select_enemy_target(thief_id)
	_check("不能绕过嘲讽选择其他目标", scene._chosen_enemy_id() == str(guard.enemy_id))
	context.damage_enemy(str(guard.enemy_id), int(guard.health), true)
	await _wait_presentation(scene)
	await get_tree().create_timer(0.5).timeout
	_check("召唤物死亡后短条与立绘退场，意图隐藏", not scene._companion_views[str(guard.enemy_id)].visible and scene._companion_views[str(guard.enemy_id)].hit.disabled and not scene._companion_views[str(guard.enemy_id)].intent.visible)
	await _click_target(thief_view.hit)
	_check("嘲讽死亡后可直接选其他单位", scene._chosen_enemy_id() == thief_id)
	context.damage_enemy(owner, int(primary.health), true)
	await _wait_presentation(scene)
	await get_tree().create_timer(0.5).timeout
	_check("本体死亡不切换成其他怪物，存活随从仍可攻击", scene._battle.active and scene.get_node("EnemyName").text == str(primary.name) and main.modulate.a < 0.5 and thief_view.visible and not thief_view.hit.disabled)
	await _capture("primary-defeated.png")
	scene.queue_free()
	await _frames(4)
	print("召唤同屏与独立血条：全部通过" if failures == 0 else "召唤同屏与独立血条：失败%d项" % failures)
	get_tree().quit(failures)


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

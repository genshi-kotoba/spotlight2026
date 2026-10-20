extends "res://tests/battle_animation_selftest.gd"

var _acceptance_alpha_images: Dictionary = {}


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
	_check_road_lineup(scene, main, knight_view, thief_view)
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
	var serial_before := int(scene._battle.player.get("summon_serial", 0))
	var main_size := main.portrait.size
	var main_at := main.portrait.get_global_rect().position
	for index in 4: scene._battle.rules.submit("monster.summon", {"id": "4", "owner": owner})
	await _wait_presentation(scene)
	_check("满员跳过额外召唤且主怪尺寸位置不变", scene.enemy_rack.slots.size() == 3 and scene._battle.enemies.size() == 3 and int(scene._battle.player.get("summon_serial", 0)) == serial_before and main.portrait.size == main_size and main.portrait.get_global_rect().position == main_at)
	await _capture("three-summoned-enemies.png")
	context.damage_enemy(knight_id, int(knight.health), true)
	await _wait_presentation(scene)
	await get_tree().create_timer(0.5).timeout
	_check("次怪死亡后留下空位，不自动重试已跳过召唤", not knight_view.visible and scene._battle.enemies.size() == 3)

	scene._battle.rules.submit("monster.summon", {"id": "5", "owner": owner})
	await _wait_presentation(scene)
	var guard: Dictionary = scene._battle.enemies.back()
	thief_view = scene.enemy_rack.slot_for(thief_id)
	main = scene.enemy_rack.slot_for(owner)
	var guard_view: EnemySlot = scene.enemy_rack.slot_for(str(guard.enemy_id))
	_check("嘲讽强制目标并禁用其他随从点击", scene._chosen_enemy_id() == str(guard.enemy_id) and not main.selectable and not thief_view.selectable)
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


func _check_road_lineup(scene: BattleTestScene, main: EnemySlot, left: EnemySlot, right: EnemySlot) -> void:
	# Independent authored and medium references; do not copy production rack constants.
	var authored := EnemySlot.new()
	scene.add_child(authored)
	authored.layout_for(959.5, 880.0)
	authored.position = Vector2(530.0, 78.0)
	authored.hide()
	authored.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_check("主怪精确保留959.5×880原始单体尺寸位置", main.size.is_equal_approx(Vector2(959.5, 880.0)) and main.global_position.is_equal_approx(authored.global_position) and main.portrait.size.is_equal_approx(authored.portrait.size) and main.portrait.get_global_rect().is_equal_approx(authored.portrait.get_global_rect()))
	var medium := EnemySlot.new()
	scene.add_child(medium)
	medium.layout_for(480.0, 610.0)
	medium.hide()
	medium.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sides: Array[EnemySlot] = [left, right]
	for index: int in sides.size():
		var side: EnemySlot = sides[index]
		var rect: Rect2 = side.portrait.get_global_rect()
		medium.position = Vector2([544.75, 994.75][index], 780.0 - medium.portrait.position.y - medium.portrait.size.y)
		_check("侧怪%d使用480中型尺寸并固定在道路前景" % index, is_equal_approx(side.size.x, 480.0) and side.global_position.is_equal_approx(medium.global_position) and side.portrait.size.is_equal_approx(medium.portrait.size) and rect.is_equal_approx(medium.portrait.get_global_rect()))
		_check("侧怪%d脚底中点在可见道路保守范围且主侧立绘矩形交叠" % index, Rect2(600.0, 740.0, 800.0, 80.0).has_point(Vector2(rect.get_center().x, rect.end.y)) and is_equal_approx(rect.end.y, 780.0) and rect.intersection(main.portrait.get_global_rect()).has_area())
	_check("两侧仍分列主怪左右", left.portrait.get_global_rect().get_center().x < main.portrait.get_global_rect().get_center().x and main.portrait.get_global_rect().get_center().x < right.portrait.get_global_rect().get_center().x)
	for slot: EnemySlot in [main, left, right]:
		_check("中型阵容点击区不遮挡手牌/" + slot.enemy_id, not Rect2(slot.global_position, Vector2(slot.size.x, slot.click_height())).intersects(scene.hand_scroll.get_global_rect()))
	authored.free()
	medium.free()


func _click_enemy(slot: EnemySlot) -> void:
	var at := _visible_rear_point(slot)
	_check("真实点击使用模型可见区域/" + slot.enemy_id, at != Vector2.INF)
	if at == Vector2.INF: return
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


func _portrait_alpha(slot: EnemySlot, point: Vector2) -> float:
	if slot.portrait.texture == null: return 0.0
	var texture: Texture2D = slot.portrait.texture
	var key: int = texture.get_instance_id()
	if not _acceptance_alpha_images.has(key):
		var read_image: Image = texture.get_image()
		if read_image == null: return -1.0
		if read_image.is_compressed() and read_image.decompress() != OK: return -1.0
		_acceptance_alpha_images[key] = read_image
	var texture_image: Image = _acceptance_alpha_images[key]
	var rect: Rect2 = slot.portrait.get_global_rect()
	var native: Vector2 = Vector2(texture_image.get_size())
	var fit: float = minf(rect.size.x / native.x, rect.size.y / native.y)
	var drawn := Rect2(rect.get_center() - native * fit * 0.5, native * fit)
	if not drawn.has_point(point): return 0.0
	var texel: Vector2i = Vector2i((point - drawn.position) / fit)
	if texel.x < 2 or texel.y < 2 or texel.x >= texture_image.get_width() - 2 or texel.y >= texture_image.get_height() - 2: return 0.5
	var lowest: float = 1.0
	var highest: float = 0.0
	for offset_y: int in range(-2, 3):
		for offset_x: int in range(-2, 3):
			var value: float = texture_image.get_pixel(texel.x + offset_x, texel.y + offset_y).a
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
	if lowest > 0.98: return 1.0
	if highest < 0.02: return 0.0
	return 0.5


func _visible_rear_point(slot: EnemySlot) -> Vector2:
	var rack: EnemyRack = slot.get_parent() as EnemyRack
	var main: EnemySlot
	for other: EnemySlot in rack.slots:
		if other.size.x > slot.size.x: main = other
	var area: Rect2 = Rect2(slot.global_position, Vector2(slot.size.x, slot.click_height())).intersection(slot.portrait.get_global_rect())
	for y: int in range(int(area.position.y) + 6, int(area.end.y) - 6, 8):
		for x: int in range(int(area.position.x) + 6, int(area.end.x) - 6, 8):
			var point := Vector2(x, y)
			if _portrait_alpha(slot, point) < 0.98: continue
			if main != null and not main._snapshot_dead and _portrait_alpha(main, point) >= 0.02: continue
			var covered: bool = false
			for other: EnemySlot in rack.slots:
				if other != slot and other != main and other.visible and other.selectable and Rect2(other.global_position, Vector2(other.size.x, other.click_height())).has_point(point): covered = true
			if not covered: return point
	return Vector2.INF

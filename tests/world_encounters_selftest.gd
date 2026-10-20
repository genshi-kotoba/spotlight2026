extends Node
const Policy = preload("res://systems/map/flat_2d/monster_encounters.gd")
const PlanarRun = preload("res://state_machines/run/planar_map_run.gd")
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const Hex = preload("res://systems/map/hex_coord.gd")
const MAP := "res://ui/main_menu/menu_map_entry.tscn"
var failures := 0
var fixture_root := ""

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	fixture_root = "res://.godot/world-encounters-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("独立测试存档", SaveGateway.load_current() == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-relic.json")
	_test_policy()
	await _test_world_flow()
	print("地图怪物与战斗整合：全部通过" if failures == 0 else "地图怪物与战斗整合：失败%d项" % failures)
	get_tree().quit(failures)

func _test_policy() -> void:
	var roster := Policy.roster_from_catalog(TextCatalog.entries("monsters"))
	_check("23怪物包含四层及三级别", roster.size() == 23 and Policy.candidates(roster, 4, "boss") == ["23"])
	var source := SeedRegistry.new("encounter-test")
	var world := PlanarRun.new(source, "encounter-test")
	_check("三层地图开局", world.start_new_run("encounter-world-v1", [{}, {"normal": 4}, {"normal": 4, "elite": 2}]))
	_check("启用正式怪物分配", world.enable_encounters(roster))
	var signatures := {}
	for floor_index in [3, 1, 2]:
		var entry: Dictionary = world.get_floor(floor_index)
		_check("第%d层可生成" % floor_index, not entry.is_empty())
		if entry.is_empty():
			continue
		var snapshot: Dictionary = entry.snapshot
		signatures[floor_index] = _json(snapshot)
		_check("第%d层每节点符合楼层级别" % floor_index, Policy.valid_assignments(snapshot, roster))
		var balanced := true
		for kind: String in ["battle", "elite", "boss"]:
			var counts := {}
			for id: String in Policy.candidates(roster, floor_index, kind):
				counts[id] = 0
			for node: Dictionary in snapshot.nodes:
				if node.type == kind:
					counts[node.content_id] += 1
			balanced = balanced and counts.values().max() - counts.values().min() <= 1
		_check("第%d层重复次数最小且均衡" % floor_index, balanced)
		var session = Session.new()
		session.load_map(snapshot)
		var private_view := true
		for node: Dictionary in session.get_view().nodes:
			private_view = private_view and not node.has("content_id") and not node.has("enemy_id") and not node.has("name")
		_check("第%d层地图视图不泄露敌人身份" % floor_index, private_view)
	var other_source := SeedRegistry.new("encounter-test")
	other_source.begin_run("encounter-world-v1")
	other_source.get_stream(RandomDomains.SHOP, ["unrelated"]).pick([1, 2, 3])
	var other := PlanarRun.new(other_source, "encounter-test")
	other.attach_existing_run([{}, {"normal": 4}, {"normal": 4, "elite": 2}])
	other.enable_encounters(roster)
	for index in [1, 2, 3]:
		_check("第%d层同种子不受生成顺序及商店随机影响" % index, _json(other.get_floor(index).snapshot) == signatures[index])
	var saved: Dictionary = world.capture_snapshot()
	var restored := PlanarRun.new(SeedRegistry.new("encounter-test"), "encounter-test")
	_check("整局保存恢复保留敌人", restored.restore_snapshot(JSON.parse_string(_json(saved))) and _json(restored.get_floor(2).snapshot) == signatures[2])
	var corrupted := saved.duplicate(true)
	for node: Dictionary in corrupted.floors[0].snapshot.nodes:
		if node.type == "battle":
			node.content_id = "23"
			break
	_check("拒绝把第四层BOSS放到第一层普通节点", not restored.restore_snapshot(corrupted))
	var policy := Policy.new()
	var sample: Dictionary = world.get_floor(2).snapshot
	var assignment: Dictionary = policy.assign(sample, roster)
	sample.seed = "another-encounter-world"
	var changed: Dictionary = policy.assign(sample, roster)
	var variation := false
	for index in assignment.nodes.size():
		variation = variation or assignment.nodes[index].content_id != changed.nodes[index].content_id
	_check("不同种子可改变同一地图的敌人分配", variation)
	var legacy_source := SeedRegistry.new("encounter-test")
	var legacy := PlanarRun.new(legacy_source, "encounter-test")
	legacy.start_new_run("legacy-encounters", [{}, {}, {}])
	var old_entry: Dictionary = legacy.enter_floor(1)
	var legacy_session = Session.new()
	legacy_session.load_map(old_entry.snapshot)
	var old_request := _available_request(legacy_session)
	_check("旧版节点可模拟已完成的历史", not old_request.is_empty() and legacy_session.resolve_request({"request_id": old_request.request_id, "status": "completed"}))
	var pending_request := _available_request(legacy_session)
	_check("旧版地图存在另一个待结算节点", not pending_request.is_empty())
	legacy.store_current(legacy_session.capture_state())
	var old_state: Dictionary = legacy_session.capture_state()
	var source_before := _json(legacy_source.capture_snapshot())
	_check("旧地图补怪物不重生成地形", legacy.enable_encounters(roster) and _json(old_entry.snapshot.cells) == _json(legacy.get_floor(1).snapshot.cells))
	var migrated: Dictionary = legacy.get_floor(1).state
	_check("旧存档位置、完成节点与探索不丢失", _json(migrated.actor_plane) == _json(old_state.actor_plane) and _json(migrated.completed) == _json(old_state.completed) and _json(migrated.known) == _json(old_state.known))
	_check("旧待结算节点补入对应怪物并换新回调令牌", migrated.pending.node_id == pending_request.node_id and migrated.pending.content_id in Policy.candidates(roster, 1, pending_request.type) and migrated.pending.request_id != pending_request.request_id)
	_check("补入旧地图不改共享随机流", _json(legacy_source.capture_snapshot()) == source_before)

func _test_world_flow() -> void:
	GlobalState.unlock_card("1")
	GlobalState.unlock_card("8")
	var config := {"run_id": "world-encounter-flow", "max_health": 200, "initial_health": 200,
		"card_catalog": ["1", "8"], "initial_deck": ["1", "1", "1", "1", "1", "8", "8", "8", "8", "8"],
		"map_ids": ["world:floor-001", "world:floor-002", "world:floor-003"]}
	_check("沿用真实局内牌组开局", SaveGateway.start_new_run("world-encounter-flow-v1", config) == OK)
	var view: Node = load(MAP).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(5)
	_check("正式地图自动分配怪物且不显示手动换层", view.map_run.current_floor == 1 and not view._next.visible and not view._previous.visible)
	_check("正式地图全部节点已登记预加载", int(ScenePreloader.stats().nodes) == view.session.nodes.size() and ScenePreloader.stats().map_id == view.session.map_id)
	var first := _approach(view, ["battle", "elite"])
	_check("找到可交互的真实战斗节点", not first.is_empty())
	if first.is_empty():
		return
	var expected_id: String = view.session.nodes[first].content_id
	var old_snapshot := _json(view.map_run.get_floor(1).snapshot)
	view._interact()
	_check("战斗节点不弹模拟完成窗口", not view._dialog.visible)
	await _frames(8)
	var ui: Node = get_tree().current_scene
	_check("节点交互进入已有战斗UI", ui.scene_file_path == EncounterFlow.BATTLE_SCENE)
	print("PERF first node transition ", SceneTransition.last_metrics)
	if ui.scene_file_path != EncounterFlow.BATTLE_SCENE:
		return
	ui.resolution_delay = 0.05
	ui.enemy_turn_delay = 0.05
	var battle: BattleStateMachine = ui._battle
	_check("第一层战斗使用场景一并保存开战楼层", int(battle.player.encounter_floor) == 1 and ui.get_node("Background").texture.resource_path == "res://assets/env/ENV-001/ENV-001.PNG")
	_check("敌人匹配种子分配且图片名称正确", battle.enemies[0].enemy_id == expected_id and ui.enemy_rack.slots[0].name_label.text == TextCatalog.entry("monsters", expected_id).name and ui.enemy_rack.slots[0].portrait.texture != null)
	_check("地图战斗加载对应怪物TXT", ui._monster_text.source_path == TextCatalog.entry("monsters", expected_id).battle_text_path and not ui._monster_text.sentences.is_empty())
	_check("真实牌组生命进入战斗，不使用临时测试牌", battle.hand.size() == 10 and int(battle.player.health) == 200 and not bool(battle.player.temporary_deck))
	_check("生产战斗不显示重开测试按钮且典籍保持只读", not ui._restart_button.visible and not ui._run_menu.allow_edit_in_battle)
	await _ready_to_act(ui)
	for card: Dictionary in battle.hand:
		if card.card_id == "1":
			ui._on_hand_card_pressed(str(card.instance_id))
			break
	ui._on_play_pressed()
	_finish_monster_choices(ui)
	await get_tree().create_timer(0.3).timeout
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(ui)
	var damage_taken := 0
	for event: Dictionary in battle.rules.queue.history:
		if event.type == "combatant.damaged" and event.payload.side == "player": damage_taken += int(event.payload.health_loss)
	var expected_health := int(battle.player.health)
	_check("出牌目标不是固定CHR025且正式怪物经队列攻击", int(battle.enemies[0].health) < int(battle.enemies[0].max_health) and damage_taken > 0 and expected_health == 200 - damage_taken and not ui._busy)
	var battle_snapshot := _json(battle.to_dictionary())
	var seed_snapshot := _json(SeedService.capture_snapshot())
	ui._on_menu_return()
	await _frames(5)
	_check("保存返回菜单保留进行中的战斗", get_tree().current_scene.scene_file_path == "res://ui/main_menu/main_menu.tscn" and SaveGateway.current_run().current_battle == battle)
	_check("冷启动模拟读取档案", SaveGateway.load_current() == OK)
	get_tree().current_scene._on_continue_pressed()
	await _frames(12)
	ui = get_tree().current_scene
	_check("冷恢复自动回到同一场战斗", ui.scene_file_path == EncounterFlow.BATTLE_SCENE)
	if ui.scene_file_path != EncounterFlow.BATTLE_SCENE:
		return
	battle = ui._battle
	_check("恢复不重抽牌、不重选敌人、不重复回合开始", _json(battle.to_dictionary()) == battle_snapshot and _json(SeedService.capture_snapshot()) == seed_snapshot)
	_check("冷恢复重新绑定对应怪物台词且不改玩法随机流", ui._monster_text.source_path == TextCatalog.entry("monsters", expected_id).battle_text_path)
	_check("冷恢复保留本场楼层背景", int(battle.player.encounter_floor) == 1 and ui.get_node("Background").texture.resource_path == "res://assets/env/ENV-001/ENV-001.PNG")
	_check("战斗地图仍不包含怪物身份字段", not _json(ui._map_snapshot_data()).contains("content_id"))
	var context := BattleEffectContext.new(battle, expected_id, ui._resolver.buff_catalog)
	context.damage_enemy(expected_id, int(battle.enemies[0].health) - 5)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(ui)
	ui.resolution_delay = 0.05
	ui.enemy_turn_delay = 0.05
	for card: Dictionary in battle.hand:
		if card.card_id == "1":
			ui._on_hand_card_pressed(str(card.instance_id))
			break
	ui._on_play_pressed()
	_check("致死卡进入表现队列而不立即销毁战斗", not battle.active and is_instance_valid(battle) and ui._busy)
	await get_tree().create_timer(0.3).timeout
	await _frames(5)
	await preload("res://tests/support/reward_test_helper.gd").collect(get_tree())
	view = get_tree().current_scene
	_check("胜利自动回地图并完成节点", view.scene_file_path == MAP and view.session.completed.has(first) and view.session.pending.is_empty())
	if view.scene_file_path != MAP:
		return
	_check("返回地图保持血量并保留原敌人分配", SaveGateway.current_run().health == expected_health and _json(view.map_run.get_floor(1).snapshot) == old_snapshot)
	_check("相同结果不能二次完成节点", not EncounterFlow.begin_encounter({"request_id": "stale", "type": "battle"}))
	# 战斗数值通过事件队列清场夹具；地图位置只移到合法可达的交互格。
	for floor_number in [1, 2, 3]:
		var safety := 0
		while GlobalState.run_active and view.scene_file_path == MAP and view.map_run.current_floor == floor_number and safety < 10:
			safety += 1
			var target := _approach(view, ["boss", "battle", "elite"])
			if target.is_empty():
				break
			await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())
			view._interact()
			await _frames(8)
			ui = get_tree().current_scene
			if ui.scene_file_path != EncounterFlow.BATTLE_SCENE:
				break
			await _ready_to_act(ui)
			var expected_background := preload("res://ui/battle/battle_environment.gd").texture_for_floor(floor_number)
			_check("第%d层战斗复用公共场景缓存" % floor_number, ScenePreloader.cached_resource(EncounterFlow.BATTLE_SCENE) is PackedScene)
			_check("第%d层正式节点绑定对应战场" % floor_number, int(ui._battle.player.encounter_floor) == floor_number and ui.get_node("Background").texture == expected_background)
			var target_context := BattleEffectContext.new(ui._battle, ui._battle.enemies[0].enemy_id, ui._resolver.buff_catalog)
			_clear_monsters(ui)
			_check("节点或Boss结算后旧战场不变", ui.get_node("Background").texture == expected_background and ui._battle_environment_floor() == floor_number)
			_check("Boss奖励阶段已预热目标楼层全部节点", ScenePreloader.stats().map_id == EncounterFlow.session.map_id and int(ScenePreloader.stats().nodes) == EncounterFlow.session.nodes.size())
			await _frames(10)
			if floor_number == 3 and bool(SaveGateway.current_run().inventory_state.get("pending_run_victory", false)):
				await preload("res://tests/support/presentation_test_helper.gd").battle_settled(ui)
				_check("第三层Boss领奖前仍可保存并继续", SaveGateway.save_current() == OK and SaveGateway.load_current() == OK and SaveGateway.continue_saved_run() == OK)
				get_tree().change_scene_to_file(MAP)
				await _frames(12)
				_check("冷恢复保留最终奖励，尚未提前结束游戏", GlobalState.run_active and not RunRewards.pending(SaveGateway.current_run()).is_empty() and bool(SaveGateway.current_run().inventory_state.get("pending_run_victory", false)))
			await preload("res://tests/support/reward_test_helper.gd").collect(get_tree())
			view = get_tree().current_scene
			if view.scene_file_path != MAP:
				break
		_check("第%d层BOSS后自动推进或第三层通关" % floor_number, (view.scene_file_path == MAP and view.map_run.current_floor > floor_number) if floor_number < 3 else (not GlobalState.run_active and GlobalState.run_history.back().result == "victory"))
	_check("第三层BOSS领奖后记录通关和三层完成", not GlobalState.run_active and GlobalState.run_history.back().stages_completed == 3 and GlobalState.run_history.back().result == "victory")
	_check("未生成第四层地图", EncounterFlow.map_run.floor_count() == 3)
	await _wait_settlement()
	await _capture("floor3-cleared.png")
	await _confirm_settlement()
	# 空牌组兼容与败北：临时牌只存在于战斗快照，不授予解锁或污染正式牌组。
	await _frames(3)
	config.run_id = "empty-deck-encounter"
	config.initial_deck = []
	_check("空牌组仍可正常开新测试局", SaveGateway.start_new_run("world-encounter-empty", config) == OK)
	get_tree().change_scene_to_file(MAP)
	await _frames(8)
	view = get_tree().current_scene
	_approach(view, ["battle", "elite"])
	view._interact()
	await _frames(8)
	ui = get_tree().current_scene
	_check("空牌组临时使用20张牌，首抽受10张上限限制且不更改正式牌组", bool(ui._battle.player.temporary_deck) and GlobalState.current_run.deck.is_empty() and ui._battle.hand.size() == 10)
	await _ready_to_act(ui)
	await _capture("node-battle.png")
	var defeat_context := BattleEffectContext.new(ui._battle, "player", ui._resolver.buff_catalog)
	defeat_context.damage_player(999, true)
	await _wait_settlement()
	_check("败北展示结算并记录失败，不完成BOSS", not GlobalState.run_active and GlobalState.run_history.back().result == "defeat")
	await _confirm_settlement()
	_check("确认败北结算后回主菜单", get_tree().current_scene.scene_file_path == "res://ui/main_menu/main_menu.tscn")

func _wait_settlement() -> void:
	var deadline := Time.get_ticks_msec() + 18000
	while (not is_instance_valid(RunResults.view) or not RunResults.view.detail_ready) and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_check("终局结算动画完成并显示只读背包", is_instance_valid(RunResults.view) and RunResults.view.detail_ready)

func _confirm_settlement() -> void:
	if is_instance_valid(RunResults.view): RunResults.view.confirm_button.pressed.emit()
	var deadline := Time.get_ticks_msec() + 8000
	while (is_instance_valid(RunResults.view) or SceneTransition.is_loading()) and Time.get_ticks_msec() < deadline: await get_tree().process_frame

func _ready_to_act(ui: Node) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while ui._opening or ui._presentation_pending():
		if Time.get_ticks_msec() >= deadline:
			_check("战斗开局与抽牌表现按时完成", false)
			return
		await get_tree().create_timer(0.01).timeout

func _approach(view: Node, types: Array) -> String:
	view._set_paused(false)
	var reachable: Dictionary = view.session.reachable()
	for kind: String in types:
		for id: String in view.session.nodes:
			var node: Dictionary = view.session.nodes[id]
			if node.type != kind or view.session.completed.has(id):
				continue
			for point: Array in node.footprint:
				for cell: Vector2i in Hex.neighbors(Session.coord(point)):
					var plane: Vector2 = Hex.to_plane(cell, 1.0)
					if reachable.has(Session.key(cell)) and view.session.can_stand(plane):
						view.session.actor_plane = plane
						if id not in view.session.nearby_nodes():
							continue
						view._sync_actor(false)
						view._selected = id
						view._manual_selection = true
						view._selection_origin = plane
						return id
	return ""

func _finish_monster_choices(ui: Node) -> void:
	for index in 10:
		var choice: Dictionary = ui._battle.player.get("battle_choice", {})
		if choice.is_empty(): break
		ui._submit_battle_choice(str(choice.candidates[0].instance_id))

func _clear_monsters(ui: Node) -> void:
	for index in 20:
		if not ui._battle.active: break
		var context := BattleEffectContext.new(ui._battle, null, ui._resolver.buff_catalog)
		for enemy: Dictionary in ui._battle.enemies:
			if int(enemy.health) > 0:
				context.damage_enemy(str(enemy.enemy_id), 999)
				break

func _available_request(session: RefCounted) -> Dictionary:
	var reachable: Dictionary = session.reachable()
	for id: String in session.nodes:
		var node: Dictionary = session.nodes[id]
		if node.type not in ["battle", "elite"] or session.completed.has(id):
			continue
		for point: Array in node.footprint:
			for cell: Vector2i in Hex.neighbors(Session.coord(point)):
				var plane: Vector2 = Hex.to_plane(cell, 1.0)
				if reachable.has(Session.key(cell)) and session.can_stand(plane):
					session.actor_plane = plane
					if id in session.nearby_nodes():
						return session.request_node(id)
	return {}

func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))

func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame
	await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())

func _json(value: Variant) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(value)))

func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

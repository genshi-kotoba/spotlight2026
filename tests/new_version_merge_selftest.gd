extends "res://tests/world_encounters_selftest.gd"
## Merge acceptance: real menu-map/encounter/reward/save wiring, isolated fixtures.
const Summit = preload("res://systems/map/flat_2d/summit_map_template.gd")
const PRESENT = preload("res://tests/support/presentation_test_helper.gd")
const REWARDS = preload("res://tests/support/reward_test_helper.gd")
var contracts_finished := false
var flow_finished := false

func _run() -> void:
	fixture_root = "res://.godot/new-version-merge-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-relic.json")
	_check("isolated merge save", SaveGateway.load_current() == OK)
	_test_new_contracts()
	await _test_final_floor_flow()
	_check("all contracts and full fourth-floor flow completed", contracts_finished and flow_finished)
	print("NEW_VERSION_MERGE_RESULT failures=%d" % failures)
	get_tree().quit(failures)

func _test_new_contracts() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	var defaults: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/encounter_test_rules.json"))
	_check("four-map new game and original eight-card deck", config.map_ids.size() == 4 and config.initial_deck == ["1", "1", "1", "50", "50", "50", "40", "40"])
	_check("main keeps 6/3/3 battle settings", int(defaults.initial_draw_count) == 6 and int(defaults.per_turn_draw_count) == 3 and int(defaults.play_limit) == 3)
	_check("anatomist remains damage2 and three actions", int(MonsterCatalog.create("7").actions[0].damage) == 2 and MonsterCatalog.action_count(MonsterCatalog.create("7")) == 3)
	_check("no removed achievements or unlocks restored", not GlobalState.has_method("unlock_card") and not GlobalState.has_method("complete_achievement") and not ResourceLoader.exists("res://ui/catalog/achievements.tscn"))
	var template := Summit.build("merge-contract", "world:floor-004")
	_check("summit fixed spawn/shop/boss coordinates", template.spawn == [0, 0] and template.nodes[0].coord == [12, 0] and template.nodes[1].coord == [6, 0])
	_check("summit only shop and boss23", template.nodes.size() == 2 and template.nodes[0].content_id == "23" and template.nodes[0].type == "boss" and template.nodes[1].type == "shop")
	_check("summit geometry seed independent", _json(template.cells) == _json(Summit.build("other-seed", "world:floor-004").cells))
	var source := SeedRegistry.new("merge-contract")
	var world := PlanarRun.new(source, "merge-contract")
	_check("four-floor coordinator initializes", world.start_new_run("merge-contract", [{}, {}, {}, {"template": "summit-v1"}]))
	_check("four-floor encounter roster accepted", world.enable_encounters(Policy.roster_from_catalog(TextCatalog.entries("monsters"))))
	var entry: Dictionary = world.enter_floor(4)
	_check("fourth-floor real snapshot accepted", not entry.is_empty() and entry.snapshot.generation_quality.template == Summit.VERSION)
	var rng := _json(source.capture_snapshot())
	_check("revisiting summit does not consume RNG or regenerate", _json(world.get_floor(4)) == _json(entry) and _json(source.capture_snapshot()) == rng)
	var restored := PlanarRun.new(SeedRegistry.new("merge-contract"), "merge-contract")
	_check("four-floor JSON checkpoint restores", restored.restore_snapshot(JSON.parse_string(_json(world.capture_snapshot()))) and restored.current_floor == 4 and restored.floor_count() == 4)
	var legacy := PlanarRun.new(SeedRegistry.new("merge-contract"), "merge-contract")
	_check("legacy three-floor coordinator still accepted", legacy.start_new_run("merge-legacy", [{}, {}, {}]) and not legacy.enter_floor(3).is_empty())
	var legacy_restored := PlanarRun.new(SeedRegistry.new("merge-contract"), "merge-contract")
	_check("legacy three-floor JSON keeps three-floor end", legacy_restored.restore_snapshot(JSON.parse_string(_json(legacy.capture_snapshot()))) and legacy_restored.floor_count() == 3)
	var shelf := RunShop.generate("merge-contract", "world:floor-004", "shop-1", 4)
	_check("summit shop valid and deterministic", RunShop.valid_shops({"world:floor-004/shop-1": shelf}) and _json(shelf) == _json(RunShop.generate("merge-contract", "world:floor-004", "shop-1", 4)))
	var third := RunShop.generate("merge-contract", "world:floor-004", "shop-1", 3)
	_check("summit shop retains third-floor price bracket", _json(shelf.cards) == _json(third.cards))
	contracts_finished = true

func _test_final_floor_flow() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "new-version-merge-flow"
	config.max_health = 2000
	config.initial_health = 2000
	_check("new four-floor save starts", SaveGateway.start_new_run("merge-summit-flow", config) == OK)
	var run := SaveGateway.current_run()
	# Only advance prior progress through run APIs; no player save is used.
	run.complete_current_map()
	run.set_current_map(str(run.map_ids[1]))
	run.complete_current_map()
	run.set_current_map(str(run.map_ids[2]))
	var view: Node = load(MAP).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	_check("real map opens floor3 with four-floor ending", view.map_run.current_floor == 3 and EncounterFlow.final_floor_count() == 4)
	var boss := await _reach_boss(view)
	if boss.is_empty():
		_check("reachable floor3 boss", false)
		return
	await PRESENT.route_ready(get_tree())
	view._interact()
	await _frames(8)
	var ui := get_tree().current_scene as BattleTestScene
	if ui == null:
		_check("third-floor interaction enters real battle", false)
		return
	await _ready_to_act(ui)
	_clear_monsters(ui)
	await PRESENT.battle_settled(ui)
	_check("third boss advances to fourth, not victory", EncounterFlow.map_run.current_floor == 4 and not bool(run.inventory_state.get("pending_run_victory", false)) and GlobalState.run_active)
	await REWARDS.collect(get_tree())
	view = get_tree().current_scene
	if view.scene_file_path != MAP:
		_check("third-floor reward returns to summit map", false)
		return
	_check("fourth floor template and hidden assigned boss", view.session.nodes.size() == 2 and view.session.nodes["boss-1"].content_id == "23" and not _json(view.session.get_view()).contains("content_id"))
	_check("summit has no route gates and can be traversed", not view.session.reachable().is_empty())
	await _capture("summit-map.png")
	# Open the real shop request and retain its exact shelf across a cold save.
	_check("summit shop reachable", _approach(view, ["shop"]) == "shop-1")
	await PRESENT.route_ready(get_tree())
	view._interact()
	await _frames(4)
	var request: Dictionary = view.session.pending.duplicate(true)
	var shelf := _json(RunShop.shelf(run, request))
	_check("real fourth-floor shop popup opens", request.get("type") == "shop" and is_instance_valid(view._shop_popup) and not RunShop.shelf(run, request).is_empty())
	_check("fourth-floor shop checkpoint saves", SaveGateway.save_current() == OK)
	view._shop_popup._continue()
	await _frames(4)
	view._return_to_menu()
	await _frames(4)
	_check("four-floor cold save loads", SaveGateway.load_current() == OK and SaveGateway.continue_saved_run() == OK)
	get_tree().change_scene_to_file(MAP)
	await _frames(10)
	view = get_tree().current_scene
	run = SaveGateway.current_run()
	_check("fourth-floor cold restore preserves map and shelf", view.map_run.current_floor == 4 and _json(RunShop.shelf(run, request)) == shelf and EncounterFlow.final_floor_count() == 4)
	_check("summit boss reachable", _approach(view, ["boss"]) == "boss-1")
	await PRESENT.route_ready(get_tree())
	view._interact()
	await _frames(8)
	ui = get_tree().current_scene as BattleTestScene
	if ui == null:
		_check("summit interaction enters real battle", false)
		return
	await _ready_to_act(ui)
	ui.resolution_delay = 0.01
	ui.enemy_turn_delay = 0.01
	ui.enemy_action_delay = 0.01
	ui.enemy_hit_delay = 0.01
	var final_enemy: Dictionary = ui._battle.enemies[0]
	_check("summit uses final boss305hp and three intentions", int(final_enemy.monster_id) == 23 and int(final_enemy.max_health) == 305 and final_enemy.intent_plan.size() == 3)
	_check("fourth-floor battle uses fourth environment", int(ui._battle.player.encounter_floor) == 4 and ui.get_node("Background").texture == preload("res://ui/battle/battle_environment.gd").texture_for_floor(4))
	var ctx := BattleEffectContext.new(ui._battle, str(final_enemy.enemy_id), ui._resolver.buff_catalog)
	ctx.damage_enemy(str(final_enemy.enemy_id), 999, true)
	await PRESENT.battle_settled(ui)
	_check("final boss half-health lock remains alive", ui._battle.active and int(final_enemy.health) == 153)
	ui._on_play_pressed()
	_finish_monster_choices(ui)
	await PRESENT.battle_settled(ui)
	_check("final boss transitions on following player turn", int(final_enemy.phase) == 2 and not bool(final_enemy.get("boss_health_locked", false)))
	ctx.damage_enemy(str(final_enemy.enemy_id), 999, true)
	await PRESENT.battle_settled(ui)
	_check("final victory waits for reward collection", GlobalState.run_active and bool(run.inventory_state.get("pending_run_victory", false)) and not RunRewards.pending(run).is_empty())
	await REWARDS.collect(get_tree())
	await _wait_settlement()
	_check("fourth boss rewards finish four-stage victory record", not GlobalState.run_active and GlobalState.run_history.back().result == "victory" and int(GlobalState.run_history.back().stages_completed) == 4)
	await _capture("summit-victory.png")
	await _confirm_settlement()
	flow_finished = true

func _reach_boss(view: Node) -> String:
	for step in 40:
		var id := _approach(view, ["boss", "battle", "elite", "event", "shop", "chest", "pile"])
		if id.is_empty(): return ""
		if view.session.nodes[id].type == "boss": return id
		# Prior encounters are fixture history; the boss itself uses all real wiring.
		var request: Dictionary = view.session.request_node(id)
		if request.is_empty() or not view.session.resolve_request({"request_id": request.request_id, "status": "completed"}): return ""
		view.map_run.store_current(view.session.capture_state())
		view._sync_view()
		view._emit_state()
		await _frames(2)
	return ""


extends "res://tests/map_entry_input_selftest.gd"
## Production map entry, real input, save/menu and cold restore; no fixture battle subclass.
var checks := 0
var results: Array[Dictionary] = []
var output_root := "res://../verification/map"

func _run() -> void:
	fixture_root = "res://.godot/intent-map-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	DirAccess.make_dir_recursive_absolute(output_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("independent production save", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "intent-native-map"
	config.initial_health = 2000
	config.max_health = 2000
	_check("new real run", SaveGateway.start_new_run("intent-map-player-phase", config) == OK)
	var view: Node = load(MAP_ENTRIES[2]).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await _frames(8)
	var target := _approach(view)
	_check("real assigned encounter reachable", not target.is_empty())
	await _press_e()
	var scene: BattleTestScene = get_tree().current_scene as BattleTestScene
	if not _check_ok("E enters production MapBattleScene", scene != null and scene.scene_file_path == EncounterFlow.BATTLE_SCENE):
		_finish()
		return
	await _frames(5)
	var before := _plans(scene)
	_check("first player phase shows all real planned actions", _complete(scene))
	await _capture("production-first-player")
	var hand := scene._battle.hand.duplicate(true)
	var turn := scene._battle.turn_number
	scene._on_menu_return()
	await _frames(5)
	_check("menu keeps the saved active battle", SaveGateway.current_run().current_battle != null)
	_check("cold-load save", SaveGateway.load_current() == OK and SaveGateway.current_run() == null)
	get_tree().change_scene_to_file(MAP_ENTRIES[2])
	await _frames(10)
	scene = get_tree().current_scene as BattleTestScene
	if not _check_ok("cold restore enters same production battle", scene != null and scene.scene_file_path == EncounterFlow.BATTLE_SCENE):
		_finish()
		return
	_check("restore keeps the same turn", scene._battle.turn_number == turn)
	_check("restore keeps the same hand instances", _equivalent(scene._battle.hand, hand))
	_check("restore keeps the exact chosen plans", _equivalent(_plans(scene), before))
	_check("restore draws the same complete intentions", _complete(scene))
	await _capture("production-restored-player")
	var actual: Array[Dictionary] = []
	scene._battle.enemy_action_requested.connect(func(id: String, action: Dictionary): actual.append({"enemy_id": id, "action": action.duplicate(true)}))
	var selected := ""
	for card: Dictionary in scene._battle.hand:
		if str(card.card_id) in ["69", "70"]: continue
		selected = str(card.instance_id)
		break
	var button: Button
	for slot: Node in scene.hand_cards.get_children():
		if str(slot.get_meta("instance_id", "")) == selected and slot.get_child_count() > 1: button = slot.get_child(1) as Button
	if _check_ok("restored real hand card can be clicked", button != null):
		await _click_control(button)
		_check("real mouse chooses one restored card", scene._selected_ids.size() == 1)
		await _click_control(scene.play_button)
		await _frames(8)
		_check("restored cached plans execute exactly", _equivalent(before, actual))
		_check("next player phase has complete new intents", scene._battle.turn_number == turn + 1 and _complete(scene))
		await _capture("production-next-player")
		results.append({"preview_before_save": before, "actual_after_restore": actual, "next_plans": _plans(scene)})
	_finish()

func _equivalent(left: Variant, right: Variant) -> bool:
	# JSON persistence normalizes integer-valued numbers to floats. Compare the
	# same serialized representation on both sides, retaining fields and order.
	return JSON.stringify(JSON.parse_string(JSON.stringify(left))) == JSON.stringify(JSON.parse_string(JSON.stringify(right)))

func _plans(scene: BattleTestScene) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for enemy: Dictionary in scene._battle.enemies:
		if int(enemy.health) <= 0: continue
		for action: Dictionary in enemy.get("intent_plan", []):
			result.append({"enemy_id": str(enemy.enemy_id), "action": action.duplicate(true)})
	return result

func _complete(scene: BattleTestScene) -> bool:
	if scene._battle.phase != BattleStateMachine.Phase.PLAYER_ACTION or scene._busy or scene.intent_board == null: return false
	for enemy: Dictionary in scene._battle.enemies:
		if int(enemy.health) <= 0: continue
		var shown: Dictionary = scene.intent_board.preview_for(str(enemy.enemy_id))
		if not bool(shown.get("ready", false)) or int(shown.get("turn", -1)) != scene._battle.turn_number or shown.get("actions", []).size() != enemy.get("intent_plan", []).size(): return false
	return true

func _click_control(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	get_viewport().warp_mouse(point)
	var move := InputEventMouseMotion.new()
	move.position = point
	get_viewport().push_input(move, true)
	await get_tree().create_timer(0.6).timeout
	point = control.get_global_rect().get_center()
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		get_viewport().push_input(event, true)
		await get_tree().process_frame
	await _frames(3)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	_check(tag + " native image", get_viewport().get_texture().get_image().save_png(output_root.path_join(tag + ".png")) == OK)

func _check_ok(label: String, passed: bool) -> bool:
	_check(label, passed)
	return passed

func _check(label: String, passed: bool) -> void:
	checks += 1
	super._check(label, passed)

func _finish() -> void:
	var file := FileAccess.open(output_root.path_join("results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "results": results}, "\t"))
	print("INTENT PRODUCTION NATIVE: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)

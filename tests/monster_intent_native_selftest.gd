extends Node
## Native acceptance uses real catalog enemies, rule queues, rendered controls and mouse input.
const CASES := [
	{"tag": "mixed", "ids": ["16", "4", "2"], "rounds": 3},
	{"tag": "multi-block", "ids": ["7", "3", "18"], "rounds": 2},
	{"tag": "action-summon", "ids": ["1"], "rounds": 4},
	{"tag": "start-summon", "ids": ["10"], "rounds": 2},
	{"tag": "phase", "ids": ["11"], "rounds": 1},
	{"tag": "final-boss", "ids": ["23"], "rounds": 3},
]
var fixture_root := "res://.godot/intent-native"
var output_root := "res://.godot/verification/native"
var failures := 0
var checks := 0
var rounds := 0
var seen_combo := false
var seen_hits := false
var records: Array[Dictionary] = []
var images: Array[String] = []
var scene: FixtureBattle
var actual: Array[Dictionary] = []
var additions: Array[Dictionary] = []
var _finished := false

class FixtureBattle extends "res://ui/battle/battle_test_scene.gd":
	var fixture_ids: Array[String] = []
	var shown: Array[Dictionary] = []
	func _test_enemy_payload() -> Array:
		var result: Array = []
		for id: String in fixture_ids: result.append(MonsterCatalog.create(id, 2))
		return result
	func _render_combat_snapshot(player_data: Dictionary, enemies: Array) -> void:
		super._render_combat_snapshot(player_data, enemies)
		if intent_board != null:
			shown.append({"turn": _presentation_turn, "records": intent_board.records.duplicate(true), "enemies": enemies.duplicate(true)})

func _ready() -> void:
	call_deferred("_run")
	get_tree().create_timer(240.0).timeout.connect(func():
		if not _finished:
			_check("native acceptance finishes within 240 seconds", false)
			_finish())

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(fixture_root)
	DirAccess.make_dir_recursive_absolute(output_root)
	SaveGateway.save_path = fixture_root.path_join("game-%d.json" % Time.get_ticks_usec())
	_check("isolated save", SaveGateway.load_current() == OK)
	var board := RelicBoard.new()
	_check("empty relic board", board.save_to_file(fixture_root.path_join("empty-board.json")) == OK)
	for resolution: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		get_window().size = resolution
		for spec: Dictionary in CASES:
			if not await _new_battle(spec, resolution):
				_finish()
				return
			if str(spec.tag) == "phase":
				var original_plan: Array = scene._battle.enemies[0].intent_plan.duplicate(true)
				var context := BattleEffectContext.new(scene._battle, str(scene._battle.enemies[0].enemy_id), scene._resolver.buff_catalog)
				context.damage_enemy(str(scene._battle.enemies[0].enemy_id), 1000, true)
				if not await _settled("phase transition"): return
				_check("phase transition changes the shown plan and adds two actors", int(scene._battle.enemies[0].phase) == 2 and scene._battle.enemies.size() == 3 and scene._battle.enemies[0].intent_plan != original_plan and scene.intent_board.records.size() == 3)
			for index: int in int(spec.rounds):
				if str(spec.tag) == "final-boss":
					if index == 1:
						var context := BattleEffectContext.new(scene._battle, str(scene._battle.enemies[0].enemy_id), scene._resolver.buff_catalog)
						context.damage_enemy(str(scene._battle.enemies[0].enemy_id), 1000, true)
						if not await _settled("final boss half health"): return
					var view := scene.intent_board.preview_for(str(scene._battle.enemies[0].enemy_id))
					_check("final boss complete three-action numeric preview", int(view.action_count) == 3 and int(view.actions[0].damage) == 8 + index and int(view.actions[2].block) == 8 and view.triggers.size() == 1)
					_check("final boss zero-draw turn retains correct Saturn count and phase", scene._battle.hand.filter(FinalBossRules.is_saturn).size() == (2 if index == 2 else 1) and int(scene._battle.enemies[0].intent_phase) == (2 if index == 2 else 1))
				var tag := "%s-%d-turn%d" % [str(spec.tag), resolution.x, scene._battle.turn_number]
				if not await _verify_turn(tag):
					_finish()
					return
			_release_scene()
			await _frames(3)
	_check("native coverage includes independent multi-action plans", seen_combo)
	_check("native coverage includes five-hit single actions", seen_hits)
	_finish()

func _new_battle(spec: Dictionary, resolution: Vector2i) -> bool:
	_release_scene()
	SeedService.begin_run("intent-native/%s/%d" % [str(spec.tag), resolution.x])
	var packed := load("res://ui/battle/battle_test_scene.tscn") as PackedScene
	var supplied := packed.instantiate() as BattleTestScene
	supplied.set_script(FixtureBattle)
	scene = supplied as FixtureBattle
	scene.fixture_ids.assign(spec.ids)
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	if str(spec.tag) == "final-boss": scene.per_turn_draw_count = 0
	scene.test_player_health = 10000
	scene.test_player_max_health = 10000
	scene.resolution_delay = 0.02
	scene.enemy_turn_delay = 0.02
	var deck: Array[String] = []
	for index in 24: deck.append("test_block")
	scene.deck_card_ids.assign(deck)
	var prior := EncounterFlow.test_rules
	EncounterFlow.test_rules = prior.duplicate(true)
	EncounterFlow.test_rules.initial_draw_count = 4
	EncounterFlow.test_rules.per_turn_draw_count = 1
	add_child(scene)
	EncounterFlow.test_rules = prior
	if not await _settled("new " + str(spec.tag)): return false
	scene._battle.enemy_action_requested.connect(func(id: String, action: Dictionary): actual.append({"enemy_id": id, "action": action.duplicate(true)}))
	scene._battle.rules.queue.event_processed.connect(func(event: BattleEvent):
		if event.type == &"enemy.intents_changed":
			for enemy: Dictionary in scene._battle.enemies:
				if not enemy.get("intent_plan", []).is_empty() and int(enemy.get("spawn_turn", -1)) == scene._battle.turn_number and int(enemy.get("monster_id", 0)) == 5:
					for action: Dictionary in enemy.intent_plan:
						var item := {"enemy_id": str(enemy.enemy_id), "action": action.duplicate(true)}
						if item not in additions: additions.append(item))
	return _check("real catalog scene ready " + str(spec.tag), scene._battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and not scene._busy)

func _verify_turn(tag: String) -> bool:
	var turn := scene._battle.turn_number
	var expected: Array[Dictionary] = []
	var baseline := JSON.stringify(SeedService.capture_snapshot())
	for index in 8: scene._refresh_combat_status()
	_check(tag + " repeated drawing consumes no gameplay RNG", baseline == JSON.stringify(SeedService.capture_snapshot()))
	for enemy: Dictionary in scene._battle.enemies:
		if int(enemy.health) <= 0: continue
		var plan: Array = enemy.get("intent_plan", [])
		var preview := scene.intent_board.preview_for(str(enemy.enemy_id))
		if not _check(tag + "/" + str(enemy.enemy_id) + " complete plan visible before input", int(enemy.get("intent_turn", -1)) == turn and bool(preview.get("ready", false)) and int(preview.get("action_count", -1)) == plan.size() and preview.get("actions", []).size() == plan.size()): return false
		var slot := scene.enemy_rack.slot_for(str(enemy.enemy_id))
		_check(tag + " badge is action count", slot != null and slot.intent_value.text == "%d动" % plan.size())
		if plan.size() > 1: seen_combo = true
		for i: int in plan.size():
			var action: Dictionary = plan[i]
			var displayed: Dictionary = preview.actions[i]
			expected.append({"enemy_id": str(enemy.enemy_id), "action": action.duplicate(true)})
			if int(action.get("hits", 1)) > 1:
				seen_hits = true
				_check(tag + " hits remain separate from action count", int(displayed.hits) == int(action.hits) and plan.size() == 1)
			if action.has("random_buff"):
				_check(tag + " random buff is explicitly random", str(displayed.summary).contains("随机") and str(displayed.detail).contains("执行时随机"))
	_check(tag + " no text sidebar is created", scene.intent_board.get_class() == "Node")
	for slot: EnemySlot in scene.enemy_rack.slots:
		if not slot.visible: continue
		var rect := slot.intent_strip.get_global_rect()
		_check(tag + " compact icons remain inside battlefield", rect.position.x >= 500 and rect.end.x <= 1490 and rect.position.y >= 0 and rect.end.y < 700)
		for cell: Control in slot.intent_strip.cells:
			_check(tag + " icon texture stays compact", cell.get_node("Icon").size.is_equal_approx(Vector2(40, 40)))
		var shown := scene.intent_board.preview_for(slot.enemy_id)
		_check(tag + " every action has its own icon", slot.intent_strip.cells.size() == maxi(1, shown.get("actions", []).size() + shown.get("triggers", []).size()))

	var plan_copy := expected.duplicate(true)
	await _capture(tag)
	if tag.begins_with("mixed") and not "--skip-native-hover" in OS.get_cmdline_user_args():
		for slot: EnemySlot in scene.enemy_rack.slots:
			for cell: Control in slot.intent_strip.cells:
				if not str(cell.get_meta("hint", "")).contains("随机"): continue
				var main_slot: EnemySlot = scene.enemy_rack.slots[0]
				await _hover(main_slot.intent_strip.cells[0])
				await _hover(cell)
				_check(tag + " moving from main to rear preserves the new tooltip", scene._intent_tip.visible and scene._intent_tip_source == slot.intent_strip)
				scene._refresh_combat_status()
				await _frames(3)
				_check(tag + " status refresh preserves a stationary intent tooltip", scene._intent_tip.visible)
				_check(tag + " native hover explains random buff", scene._intent_tip.visible and str(scene._intent_tip.get_node("TipLabel").text).contains("执行时随机"))
				await _capture(tag + "-random-hover")
				await _hover(scene.play_button)
	actual.clear()
	additions.clear()
	var button: Button
	for card: Dictionary in scene._battle.hand:
		if str(card.card_id) != "test_block": continue
		for slot: Node in scene.hand_cards.get_children():
			if str(slot.get_meta("instance_id", "")) == str(card.instance_id) and slot.get_child_count() > 1: button = slot.get_child(1) as Button
		if button != null: break
	if button == null and tag.begins_with("final-boss"):
		_check(tag + " zero-draw turn can use the real empty-pass button", not scene.play_button.disabled)
	else:
		if not _check(tag + " real hand card is available", button != null): return false
		await _click(button)
		if not _check(tag + " mouse selected a real card", scene._selected_ids.size() == 1): return false
	await _click(scene.play_button)
	if not await _settled(tag + " actual turn"): return false
	expected.append_array(additions)
	# A turn-start newborn is last in roster order, matching production execution.
	_check(tag + " actual ordered execution equals the shown cached plan", JSON.stringify(expected) == JSON.stringify(actual))
	_check(tag + " one mouse click advances exactly one turn", scene._battle.turn_number == turn + 1)
	records.append({"tag": tag, "turn": turn, "preview": plan_copy, "turn_start_additions": additions.duplicate(true), "actual": actual.duplicate(true), "shown": scene.shown.duplicate(true)})
	var snapshots_match := true
	for shown: Dictionary in scene.shown:
		for record: Dictionary in shown.records:
			snapshots_match = snapshots_match and (int(record.get("turn", shown.turn)) == int(shown.turn) if bool(record.get("ready", false)) else record.get("actions", []).is_empty())
	_check(tag + " presentation uses the plan belonging to its own snapshot", snapshots_match)
	scene.shown.clear()
	rounds += 1
	return failures == 0

func _settled(label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 18000
	while is_instance_valid(scene) and (scene._presentation_pending() or scene._refresh_queued or not _hand_deals_finished()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _frames(3)
	return _check(label + " settles with controls unlocked", is_instance_valid(scene) and not scene._presentation_pending() and not scene._refresh_queued)

func _hand_deals_finished() -> bool:
	for slot: Control in scene.hand_cards.get_children():
		if slot.modulate.a < 0.99 or not slot.scale.is_equal_approx(Vector2.ONE): return false
	return true

func _click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	get_viewport().warp_mouse(point)
	var move := InputEventMouseMotion.new()
	move.position = point
	get_viewport().push_input(move, true)
	await get_tree().create_timer(0.6).timeout
	point = control.get_global_rect().get_center()
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	get_viewport().push_input(event, true)
	await _frames(1)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)
	await _frames(2)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var path := output_root.path_join(tag + ".png")
	_check(tag + " native image saved", get_viewport().get_texture().get_image().save_png(path) == OK)
	images.append(ProjectSettings.globalize_path(path))

func _frames(count: int) -> void:
	for index in count: await get_tree().process_frame

func _release_scene() -> void:
	if is_instance_valid(scene):
		remove_child(scene)
		scene.queue_free()
	scene = null

func _check(label: String, passed: bool) -> bool:
	checks += 1
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])
	return passed

func _finish() -> void:
	if _finished: return
	_finished = true
	_check("all 30 native turns completed", rounds == 30)
	_release_scene()
	var file := FileAccess.open(output_root.path_join("results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "rounds": rounds, "renderer": RenderingServer.get_video_adapter_name(), "images": images, "records": records}, "\t"))
	print("INTENT NATIVE: %d checks, %d failures, %d turns" % [checks, failures, rounds])
	get_tree().quit(1 if failures else 0)

func _hover(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	get_viewport().warp_mouse(point)
	var move := InputEventMouseMotion.new()
	move.position = point
	get_viewport().push_input(move, true)
	await get_tree().create_timer(0.15).timeout

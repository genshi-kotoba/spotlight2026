extends Node
## Same-process regression: real menu -> map -> lethal rule -> settlement -> menu.
const MENU := "res://ui/main_menu/main_menu.tscn"
const MAP := "res://ui/main_menu/menu_map_entry.tscn"
const BATTLE := "res://ui/battle/map_battle_scene.tscn"
const Hex = preload("res://systems/map/hex_coord.gd")
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
var failures := 0
var checks := 0
var run_ids: Array[String] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_run")

func _run() -> void:
	get_tree().current_scene = null
	get_window().size = Vector2i(1920, 1080)
	SaveGateway.save_path = "user://death-restart-%d/game.json" % Time.get_ticks_usec()
	EncounterFlow.relic_board_path = SaveGateway.save_path.get_base_dir().path_join("empty-board.json")
	_check("isolated fixture loaded", SaveGateway.load_current() == OK)
	_check("menu transition accepted", SceneTransition.change_scene_to_file(MENU) == OK)
	if not await _wait_scene(MENU): return _finish()
	var self_damage_cards: Array[String] = []
	if OS.get_cmdline_user_args().has("--self-damage-cards"):
		self_damage_cards.assign(["14", "15", "16", "17", "18", "69"])
	var final_cycle := self_damage_cards.size() if not self_damage_cards.is_empty() else 2
	for cycle in final_cycle + 1:
		print("DEATH_RESTART cycle=", cycle, " before_new ", _state())
		var menu := get_tree().current_scene
		_check("menu permits fresh run %d" % cycle, not menu.get_node("按钮列/新游戏").disabled and not SaveGateway.has_continuable_run())
		await _click(menu.get_node("按钮列/新游戏"))
		if not await _wait_scene(MAP): return _finish()
		var map := get_tree().current_scene
		var run := SaveGateway.current_run()
		_check("new distinct active run %d" % cycle, is_instance_valid(run) and run.active and run.run_id not in run_ids and run.current_battle == null and EncounterFlow.run == run)
		if not is_instance_valid(run): return _finish()
		run_ids.append(run.run_id)
		_check("map saves after new run %d" % cycle, SaveGateway.save_current() == OK)
		var event_battle := cycle == 1
		var node_id := _approach(map, "event" if event_battle else "battle")
		_check("reachable encounter %d" % cycle, not node_id.is_empty())
		if node_id.is_empty(): return _finish()
		if event_battle:
			# The fixture fixes only the event kind; UI, battle, effects and saves stay real.
			# Event identities vary per seed, so keep the second loop deterministic.
			var event_key := "%s/%s" % [map.session.map_id, node_id]
			if not run.inventory_state.has("events"): run.inventory_state["events"] = {}
			run.inventory_state.events[event_key] = {"index": 5, "stage": "choice", "plays": 0,
				"inputs": [], "offers": [], "result": "", "finished": false}
		if not await preload("res://tests/support/presentation_test_helper.gd").route_ready(get_tree(), 60.0):
			_check("route presentation ready", false)
			return _finish()
		if not await _wait_scene(MAP): return _finish()
		print("DEATH_RESTART interact before ", {"selected": map._selected, "nearby": map.session.nearby_nodes(), "ready": map.is_map_ready(), "pending": map.session.pending})
		map._interact()
		print("DEATH_RESTART interact after ", {"selected": map._selected, "ready": map.is_map_ready(), "pending": map.session.pending, "error": EncounterFlow.last_error})
		if event_battle:
			if not await _wait_scene(RandomEventCatalog.SCENE): return _finish()
			var event_ui := get_tree().current_scene
			_check("real event choice opens beast battle", RunRandomEvents.state(run, event_ui.request).index == 5)
			await _click(event_ui._content.get_child(0))
		if not await _wait_scene(BATTLE): return _finish()
		var ui := get_tree().current_scene
		if event_battle:
			var original_run_id: String = run.run_id
			var original_battle_id: String = ui._battle.node_id
			# Save through the battle menu, reload the isolated file and continue through UI.
			ui._on_menu_return()
			if not await _wait_scene(MENU): return _finish()
			_check("battle checkpoint cold reload", SaveGateway.load_current() == OK)
			await _click(get_tree().current_scene.get_node("按钮列/继续游戏"))
			if not await _wait_scene(BATTLE): return _finish()
			ui = get_tree().current_scene
			run = SaveGateway.current_run()
			_check("cold continuation restores same event battle", run.run_id == original_run_id and ui._battle.node_id == original_battle_id and ui._battle.player.get("event_combat", {}).get("kind") == "beast")
		ui.resolution_delay = 0.01
		ui.enemy_turn_delay = 0.01
		var deadline := Time.get_ticks_msec() + 20000
		while ui._opening or ui._presentation_pending():
			if Time.get_ticks_msec() > deadline:
				_check("battle opening ready", false)
				return _finish()
			await get_tree().process_frame
		while not _hand_ready(ui) and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		_check("opening hand visible %d" % cycle, _hand_ready(ui) and ui._battle.hand.size() == 6)
		_check("battle playable and saves %d" % cycle, ui._battle.active and ui._battle.phase == BattleStateMachine.Phase.PLAYER_ACTION and SaveGateway.save_current() == OK)
		await _capture("cycle-%d-battle" % cycle)
		if cycle == final_cycle:
			var initial_turn: int = ui._battle.turn_number
			await _click(ui.play_button)
			deadline = Time.get_ticks_msec() + 15000
			while (ui._battle.turn_number == initial_turn or ui._presentation_pending()) and Time.get_ticks_msec() < deadline:
				await get_tree().process_frame
			_check("final new run real turn advances and saves", ui._battle.active and ui._battle.turn_number > initial_turn and SaveGateway.save_current() == OK)
			break
		var ended_run: WeakRef = weakref(run)
		if not self_damage_cards.is_empty():
			var card_id: String = self_damage_cards[cycle]
			_check("self-damage health fixture " + card_id, run.set_health(1) == OK)
			ui._battle.player.health = 1
			ui._battle.player.block = 0
			# Generated cards use the normal formal-card resolver and real card.drawn.
			# 69 resolves its rightmost-hand curse immediately; other cards are clicked.
			ui._battle.add_generated_card(card_id, "hand", "death-restart-" + card_id)
			if ui._battle.active:
				var instance_id: String = ui._battle.hand.back().instance_id
				ui._queue_refresh()
				while not _hand_ready(ui) and Time.get_ticks_msec() < deadline:
					await get_tree().process_frame
				var card_button: Button
				for slot: Control in ui.hand_cards.get_children():
					if slot.get_meta("instance_id", "") == instance_id:
						for child: Node in slot.get_children():
							if child is Button: card_button = child
				_check("self-damage card has real input button " + card_id, is_instance_valid(card_button))
				if not is_instance_valid(card_button): return _finish()
				await _click(card_button)
				_check("real card click selects self-damage " + card_id, ui._selected_ids.has(instance_id))
				await _click(ui.play_button)
			_check("formal self-damage causes defeat " + card_id, not ui._battle.active and ui._battle.player.health == 0)
		elif OS.get_cmdline_user_args().has("--natural-death"):
			# Fixture health only; the lethal damage comes from real enemy turns via UI.
			_check("one-health fixture", run.set_health(1) == OK)
			ui._battle.player.health = 1
			ui._battle.player.block = 0
			var lethal_deadline := Time.get_ticks_msec() + 25000
			for turn in 8:
				if not ui._battle.active: break
				await _click(ui.play_button)
				while ui._presentation_pending() and ui._battle.active and Time.get_ticks_msec() < lethal_deadline:
					await get_tree().process_frame
			_check("real enemy turn kills player", not ui._battle.active and ui._battle.player.health == 0 and ui._battle.rules.queue.history.any(func(e: Dictionary): return e.type == "combatant.damaged" and e.payload.get("side") == "player" and int(e.payload.get("health_loss", 0)) > 0))
		else:
			var context := BattleEffectContext.new(ui._battle, "player", ui._resolver.buff_catalog)
			context.damage_player(99999, true)
		print("DEATH_RESTART cycle=", cycle, " after_damage ", _state())
		deadline = Time.get_ticks_msec() + 20000
		while not is_instance_valid(RunResults.view) or not RunResults.view.detail_ready:
			if Time.get_ticks_msec() > deadline:
				_check("settlement ready", false)
				return _finish()
			await get_tree().process_frame
		_check("death ends run once %d" % cycle, not GlobalState.run_active and SaveGateway.current_run() == null and GlobalState.run_history.size() == cycle + 1 and GlobalState.run_history.back().result == "defeat")
		await _capture("cycle-%d-settlement" % cycle)
		if cycle == 0:
			var original_path: String = SaveGateway.save_path
			SaveGateway.save_path = original_path.path_join("blocked.json")
			await _click(RunResults.view.confirm_button)
			await get_tree().process_frame
			await get_tree().process_frame
			_check("failed settlement save remains retryable", is_instance_valid(RunResults.view) and not RunResults.view.confirm_button.disabled and not RunResults.view._error.text.is_empty() and get_tree().current_scene == ui)
			SaveGateway.save_path = original_path
		await _click(RunResults.view.confirm_button)
		if not await _wait_scene(MENU): return _finish()
		_check("death menu releases old run %d" % cycle, ended_run.get_ref() == null and not get_tree().paused and not SceneTransition.is_loading() and not is_instance_valid(RunResults.view))
	_finish()

func _hand_ready(ui: Node) -> bool:
	if ui._refresh_queued or ui.hand_cards.get_child_count() != ui._battle.hand.size() or ui._battle.hand.is_empty(): return false
	for slot: Control in ui.hand_cards.get_children():
		if slot.modulate.a < 0.99 or slot.scale.distance_to(Vector2.ONE) > 0.01: return false
	return true

func _state() -> Dictionary:
	return {"global_active": GlobalState.run_active, "current_run": is_instance_valid(SaveGateway.current_run()), "paused": get_tree().paused, "transition_busy": SceneTransition.is_loading(), "pending_record": not RunResults.pending_record.is_empty(), "checkpoint": not SaveGateway.map_checkpoint().is_empty()}

func _wait_scene(path: String) -> bool:
	var deadline := Time.get_ticks_msec() + 65000
	while true:
		var scene := get_tree().current_scene
		if is_instance_valid(scene) and scene.scene_file_path == path and not SceneTransition.is_loading():
			if not scene.has_method("is_map_ready") or scene.is_map_ready():
				_check("scene ready " + path, true)
				return true
		if Time.get_ticks_msec() >= deadline:
			_check("scene ready " + path + " actual=" + (scene.scene_file_path if is_instance_valid(scene) else "null") + " state=" + str(_state()), false)
			return false
		await get_tree().process_frame
	return false

func _approach(view: Node, kind: String) -> String:
	view._set_paused(false)
	if kind == "event":
		# Reach a non-gate event in the isolated map fixture without fighting route guards.
		for id: String in view.session.nodes:
			var guard: Dictionary = view.session.nodes[id]
			if guard.is_route_gate and guard.type != "boss":
				view.session.completed[id] = true
				view.session.visits[id] = 1
		for cell: Dictionary in view._map_snapshot.cells:
			view.session.known[Session.key(Vector2i(cell.q, cell.r))] = true
	var reachable: Dictionary = view.session.reachable()
	for id: String in view.session.nodes:
		var node: Dictionary = view.session.nodes[id]
		if (node.type not in ["battle", "elite"] if kind == "battle" else node.type != kind) or view.session.completed.has(id): continue
		for point: Array in node.footprint:
			for cell: Vector2i in Hex.neighbors(Session.coord(point)):
				var plane: Vector2 = Hex.to_plane(cell, 1.0)
				if reachable.has(Session.key(cell)) and view.session.can_stand(plane):
					view.session.actor_plane = plane
					if id not in view.session.nearby_nodes(): continue
					view._sync_actor(false)
					view._sync_view()
					view._selected = id
					view._manual_selection = true
					view._selection_origin = plane
					return id
	return ""

func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SaveGateway.save_path.get_base_dir().path_join(label + ".png"))

func _click(button: Button) -> void:
	var event := InputEventMouseButton.new()
	event.position = button.get_global_rect().get_center()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)
	await get_tree().process_frame

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

func _finish() -> void:
	print("DEATH_RESTART_RESULT checks=%d failures=%d run_ids=%s" % [checks, failures, str(run_ids)])
	get_tree().quit(failures)

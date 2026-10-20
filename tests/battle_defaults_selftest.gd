extends Node
## Real battle-scene regression; isolated saves and an empty relic board.
const Presentation = preload("res://tests/support/presentation_test_helper.gd")
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := "res://.godot/battle-defaults-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture.path_join("game.json")
	_check("isolated save", SaveGateway.load_current() == OK)
	_check("shared encounter defaults are 6/3/3",
		int(EncounterFlow.test_rules.initial_draw_count) == 6
		and int(EncounterFlow.test_rules.per_turn_draw_count) == 3
		and int(EncounterFlow.test_rules.play_limit) == 3)
	var scene := load("res://ui/battle/battle_test_scene.tscn").instantiate() as BattleTestScene
	_check("scene exported defaults are 6/3/3",
		scene.initial_draw_count == 6 and scene.per_turn_draw_count == 3 and scene.play_limit == 3)
	scene.relic_board_path = fixture.path_join("empty-relic-board.json")
	scene.test_enemy_count = 1
	for index in 20:
		scene.deck_card_ids.append("test_block")
	add_child(scene)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("opening draws exactly six cards", scene._battle.hand.size() == 6
		and scene._battle.draw_pile.size() == 14 and scene._battle.turn_number == 1)
	_check("battle state machine receives three slots", scene._battle.effective_play_limit() == 3)
	_check("opening presentation settles", await Presentation.battle_settled(scene))
	var ids: Array[String] = []
	for card: Dictionary in scene._battle.hand:
		ids.append(str(card.instance_id))
	for index in 3:
		scene._on_hand_card_pressed(ids[index])
	_check("three normal cards fill all slots", scene._selected_ids.size() == 3 and scene._used_slots() == 3)
	scene._on_hand_card_pressed(ids[3])
	_check("fourth normal card is rejected", scene._selected_ids.size() == 3
		and not scene._selected_ids.has(ids[3]))
	scene._on_cancel_pressed()
	_check("cancel releases all three slots", scene._selected_ids.is_empty())
	for index in 3:
		scene._on_hand_card_pressed(ids[index])
	scene._on_play_pressed()
	_check("next turn presentation settles", await Presentation.battle_settled(scene))
	_check("next player turn draws three without repeating opening draw",
		scene._battle.turn_number == 2 and scene._battle.hand.size() == 6
		and scene._battle.draw_pile.size() == 11 and scene._battle.discard_pile.size() == 3)
	_check("next turn retains three slots", scene._battle.effective_play_limit() == 3)
	scene.queue_free()
	await get_tree().process_frame
	print("BATTLE_DEFAULTS_RESULT failures=%d" % failures)
	get_tree().quit(failures)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		push_error("FAIL " + label)

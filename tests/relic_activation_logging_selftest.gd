extends Node

const LOG := preload("res://systems/diagnostics/runtime_log.gd")
const GENERATED_TRIGGER := "RF1/FRG-003/FRG-012/5/FRG-027"
const GENERATED_EFFECT := "RF1/FRG-013/FRG-002/0/FRG-029"

var checks := 0
var failures := 0
var catalog: Dictionary


func _ready() -> void:
	SeedService.begin_run("relic-activation-logging-selftest")
	catalog = RelicCatalog.load_definitions()
	_test_prototype_trigger()
	_test_generated_turn_end()
	_test_presence()
	print("RELIC_ACTIVATION_LOGGING_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _test_prototype_trigger() -> void:
	var setup := _setup("prototype", {0:"on_card_gained", 1:"gain_block"})
	if setup.is_empty(): return
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	var marker := _sequence_number()
	battle.draw_cards(1)
	_check("prototype effect still applies", int(battle.player.block) == 1)
	_check_activation("prototype", marker, "on_card_gained", "gain_block", false)
	_cleanup(setup)


func _test_generated_turn_end() -> void:
	# The two generated fragments and adjacent cells are the reported live configuration.
	var setup := _setup("generated", {4:GENERATED_TRIGGER, 5:GENERATED_EFFECT})
	if setup.is_empty(): return
	var battle: BattleStateMachine = setup.battle
	battle.start_battle()
	var marker := _sequence_number()
	var sequence: Array[String] = [str(battle.hand[0].instance_id)]
	var error := battle.commit_player_sequence(sequence, {sequence[0]:"enemy"})
	_check("generated turn-end resolution returns", error == OK and battle.turn_number == 2)
	_check("generated turn-end queue is idle", not battle.rules.queue.processing and not battle.rules.queue.paused and battle.rules.queue.pending_count() == 0)
	_check("generated effect activates once", setup.relics.activation_count == 1)
	_check_activation("generated", marker, GENERATED_TRIGGER, GENERATED_EFFECT, false)
	_cleanup(setup)


func _test_presence() -> void:
	var setup := _setup("presence", {5:"turn_strength"})
	if setup.is_empty(): return
	var marker := _sequence_number()
	setup.battle.start_battle()
	_check("presence effect still activates", setup.relics.activation_count == 1)
	_check_activation("presence", marker, "turn_strength", "turn_strength", false)
	_cleanup(setup)


func _setup(label: String, placements: Dictionary) -> Dictionary:
	var board := RelicBoard.new()
	for cell: int in placements:
		var placed := board.place(cell, str(placements[cell]), catalog)
		_check(label + " places fragment " + str(cell), placed == OK)
		if placed != OK: return {}
	var battle := BattleStateMachine.new()
	add_child(battle)
	var deck: Array[Dictionary] = []
	for index in 6:
		deck.append({"instance_id":label + "/" + str(index), "card_id":"1"})
	var error := battle.initialize_battle({
		"map_id":"logging-test", "node_id":label, "battle_index":0, "draw_count":1,
		"player":{"health":100, "max_health":100, "block":0, "buffs":[]},
		"enemies":[{"enemy_id":"enemy", "health":100, "max_health":100,
			"block":0, "buffs":[], "actions":[{"damage":1}]}],
		"deck_instances":deck,
	})
	_check(label + " initializes battle", error == OK)
	if error != OK: battle.free(); return {}
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	error = resolver.attach_to_battle(battle)
	_check(label + " attaches resolver", error == OK)
	if error != OK: resolver.free(); battle.free(); return {}
	var relics := RelicBattleSystem.new()
	add_child(relics)
	error = relics.attach_to_battle(battle, board, catalog, resolver.buff_catalog)
	_check(label + " attaches relics", error == OK)
	if error != OK: relics.free(); resolver.free(); battle.free(); return {}
	return {"battle":battle, "resolver":resolver, "relics":relics}


func _sequence_number() -> int:
	var recent := LOG.recent(1)
	return 0 if recent.is_empty() else int(recent[0].n)


func _check_activation(label: String, marker: int, trigger_id: String, effect_id: String, presence: bool) -> void:
	var records := LOG.recent().filter(func(record: Dictionary): return int(record.n) > marker and record.tag == "relic.activate")
	# _enqueue publishes the gameplay event before evaluating its logging payload.
	# Gameplay assertions alone can pass after a script error; require the actual log too.
	_check(label + " records one activation", records.size() == 1)
	if records.size() != 1: return
	var data: Dictionary = records[0].data
	_check(label + " logs trigger fragment identity", data.get("trigger_id") == trigger_id)
	_check(label + " logs effect fragment identity", data.get("effect_id") == effect_id)
	_check(label + " preserves activation metadata", data.get("presence") == presence and int(data.get("root", 0)) > 0)


func _cleanup(setup: Dictionary) -> void:
	setup.relics.free()
	setup.resolver.free()
	setup.battle.free()


func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print(("PASS " if passed else "FAIL ") + label)

extends Node
## Pure battle-rule probe. No battle scene, Control, input, save/load gateway or disk fixture.
## Root must launch from an isolated test project/user-data configuration.

var failures := 0
var checks := 0
var fixture_serial := 0
var events: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SeedService.begin_run("three-enemy-summon-cap-selftest")
	_check("monster catalog ready", TextCatalog.reload() == OK)
	_test_formation_metadata()
	_test_full_and_vacancy()
	_test_initial_two_and_elite()
	_test_boss11(["11"], 2)
	_test_boss11(["11", "3"], 1)
	_test_boss11(["11", "3", "3"], 0)
	_test_natural_repeat_and_restore()
	_test_legacy_over_capacity()
	print("SUMMON_CAP checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _make(ids: Array[String]) -> BattleStateMachine:
	fixture_serial += 1
	var battle := BattleStateMachine.new()
	get_tree().root.add_child(battle)
	var enemies: Array[Dictionary] = []
	for index in ids.size():
		var enemy := MonsterCatalog.create(ids[index], 2, "fixture-%d/initial/%d" % [fixture_serial, index])
		if not _check("create real catalog entity " + ids[index], not enemy.is_empty()):
			battle.free()
			return null
		enemies.append(enemy)
	var error := battle.initialize_battle({
		"map_id": "summon-cap", "node_id": "fixture-%d" % fixture_serial,
		"battle_index": fixture_serial, "draw_count": 0, "discard_hand_at_turn_end": false,
		"player": {"health": 10000, "max_health": 10000, "block": 0, "buffs": [],
			"silver": 1000, "base_play_limit": 10},
		"enemies": enemies,
		"deck_instances": [{"card_id": "test_block", "instance_id": "fixture-card-%d" % fixture_serial}],
	})
	if not _check("initialize real battle", error == OK):
		battle.free()
		return null
	battle.player["encounter_floor"] = 2
	if not _attach(battle):
		battle.free()
		return null
	if not _check("start real battle", battle.start_battle() == OK):
		battle.free()
		return null
	return battle


func _attach(battle: BattleStateMachine) -> bool:
	var resolver := BattleEffectResolver.new()
	battle.add_child(resolver)
	if not _check("attach production rule handlers", resolver.attach_to_battle(battle) == OK):
		return false
	battle.rules.queue.event_processed.connect(_record_event)
	return true


func _record_event(event: BattleEvent) -> void:
	events.append(str(event.type))


func _living(battle: BattleStateMachine) -> int:
	var count := 0
	for enemy: Dictionary in battle.enemies:
		if int(enemy.health) > 0:
			count += 1
	return count


func _unique_ids(battle: BattleStateMachine) -> bool:
	var ids := {}
	for enemy: Dictionary in battle.enemies:
		if ids.has(str(enemy.enemy_id)):
			return false
		ids[str(enemy.enemy_id)] = true
	return true


func _summon(battle: BattleStateMachine, id: String = "15") -> void:
	var owner := str(battle.enemies[0].enemy_id)
	_check("submit real monster.summon", battle.rules.submit("monster.summon", {"id": id, "owner": owner}) == OK)


func _reject_unchanged(battle: BattleStateMachine, label: String) -> void:
	var before := JSON.stringify(battle.to_dictionary())
	var seed_before := JSON.stringify(SeedService.capture_snapshot())
	var serial_before: Variant = battle.player.get("summon_serial")
	var silver_before := int(battle.player.silver)
	events.clear()
	_summon(battle, "15")
	_check(label + " preserves entire battle snapshot", JSON.stringify(battle.to_dictionary()) == before)
	_check(label + " preserves summon serial including absent key", battle.player.get("summon_serial") == serial_before)
	_check(label + " does not advance random streams", JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	_check(label + " thief cannot steal silver", int(battle.player.silver) == silver_before)
	_check(label + " publishes no child/entry/buff facts", events.size() == 1 and events[0] == "monster.summon")


func _test_full_and_vacancy() -> void:
	var battle := _make(["10", "3", "3"])
	if battle == null:
		return
	_reject_unchanged(battle, "three living rejects")
	var dead_id := str(battle.enemies[1].enemy_id)
	_check("kill actual secondary by production damage", battle.apply_damage_to_enemy(dead_id, int(battle.enemies[1].health), true) == OK)
	var corpse: Dictionary = battle.enemies[1].duplicate(true)
	_check("death alone never retries rejected summon", _living(battle) == 2 and battle.enemies.size() == 3 and not battle.player.has("summon_serial"))
	_summon(battle, "3")
	var first_id := str(battle.enemies.back().enemy_id)
	_check("later summon fills one vacancy", _living(battle) == 3 and battle.enemies.size() == 4 and int(battle.player.summon_serial) == 1)
	_check("first accepted identity has no gap from rejection", first_id == str(battle.enemies[0].enemy_id) + "/summon/1")
	_check("dead archive is unchanged and duplicate prototype has distinct ID", battle.enemies[1] == corpse and _unique_ids(battle))
	_reject_unchanged(battle, "three live plus corpse rejects")
	_check("kill accepted summon through real damage", battle.apply_damage_to_enemy(first_id, int(battle.enemies.back().health), true) == OK)
	_check("death does not auto-fill second vacancy", _living(battle) == 2 and int(battle.player.summon_serial) == 1)
	_summon(battle, "3")
	_check("next accepted summon uses serial two and keeps both corpses", _living(battle) == 3 and battle.enemies.size() == 5 and int(battle.player.summon_serial) == 2 and str(battle.enemies.back().enemy_id).ends_with("/summon/2") and _unique_ids(battle))
	battle.free()


func _test_initial_two_and_elite() -> void:
	var battle := _make(["3", "3"])
	if battle != null:
		_summon(battle, "3")
		_check("initial two can grow to three", _living(battle) == 3 and int(battle.player.summon_serial) == 1)
		_reject_unchanged(battle, "ordinary formation cap")
		battle.free()
	battle = _make(["12", "3", "3"])
	if battle != null:
		_reject_unchanged(battle, "elite plus two ordinary cap")
		battle.free()


func _test_boss11(initial_ids: Array[String], expected_summons: int) -> void:
	var battle := _make(initial_ids)
	if battle == null:
		return
	var duke_id := str(battle.enemies[0].enemy_id)
	var initial_size := battle.enemies.size()
	events.clear()
	_check("Boss11 receives lethal production damage", battle.apply_damage_to_enemy(duke_id, int(battle.enemies[0].health) + 1, true) == OK)
	_check("Boss11 survives phase two", battle.active and int(battle.enemies[0].phase) == 2 and int(battle.enemies[0].health) == 96)
	_check("Boss11 double request respects available capacity", battle.enemies.size() == initial_size + expected_summons and _living(battle) == 3 and int(battle.player.get("summon_serial", 0)) == expected_summons)
	_check("Boss11 rejected thief has no entry theft", int(battle.player.silver) == (700 if expected_summons == 2 else 1000))
	var expected_entries := expected_summons if battle.has_method("add_enemy") else 0
	_check("entry facts match this version's accepted-summon contract", events.count("enemy.entered") == expected_entries)
	_check("Boss11 identities remain unique", _unique_ids(battle))
	if expected_summons > 0:
		_check("Boss11 first summon keeps requested order", str(battle.enemies[initial_size].monster_id) == "14")
	if expected_summons == 2:
		_check("Boss11 second summon is thief", str(battle.enemies.back().monster_id) == "15")
	battle.free()


func _roundtrip(battle: BattleStateMachine) -> BattleStateMachine:
	var saved: Dictionary = JSON.parse_string(JSON.stringify(battle.to_dictionary()))
	var saved_enemies: Array = saved.enemies.duplicate(true)
	var saved_serial := int(saved.player.get("summon_serial", 0))
	var saved_roles := MonsterBattleRules.formation_slots(battle.enemies)
	battle.free()
	var restored := BattleStateMachine.new()
	get_tree().root.add_child(restored)
	if not _check("JSON restore accepts historical roster", restored.restore_from_dictionary(saved) == OK):
		restored.free()
		return null
	_check("JSON restore keeps all identities and corpses", JSON.parse_string(JSON.stringify(restored.enemies)) == saved_enemies and int(restored.player.get("summon_serial", 0)) == saved_serial)
	_check("JSON restore keeps stable formation slots including replaced corpses", MonsterBattleRules.formation_slots(restored.enemies) == saved_roles)
	if not _attach(restored):
		restored.free()
		return null
	return restored


func _test_natural_repeat_and_restore() -> void:
	var battle := _make(["10"])
	if battle == null:
		return
	for index in 3:
		_check("Boss10 natural enemy turn %d" % (index + 1), battle.end_player_action() == OK)
		_check("natural repeat never exceeds three", _living(battle) <= 3)
	_check("third natural summon was skipped without serial advance", _living(battle) == 3 and battle.enemies.size() == 3 and int(battle.player.summon_serial) == 2)
	var dead_id := str(battle.enemies.back().enemy_id)
	_check("kill natural summon", battle.apply_damage_to_enemy(dead_id, int(battle.enemies.back().health), true) == OK)
	_check("death waits for future natural request", _living(battle) == 2 and battle.enemies.size() == 3)
	_check("later real turn runs", battle.end_player_action() == OK)
	_check("later natural summon refills and preserves dead archive", _living(battle) == 3 and battle.enemies.size() == 4 and int(battle.player.summon_serial) == 3 and _unique_ids(battle))
	battle = _roundtrip(battle)
	if battle == null:
		return
	_reject_unchanged(battle, "restored full roster rejects")
	var previous_size := battle.enemies.size()
	var previous_serial := int(battle.player.summon_serial)
	dead_id = str(battle.enemies.back().enemy_id)
	_check("kill after JSON restore", battle.apply_damage_to_enemy(dead_id, int(battle.enemies.back().health), true) == OK)
	_summon(battle, "3")
	_check("restore continues identity serial without reusing corpse ID", _living(battle) == 3 and battle.enemies.size() == previous_size + 1 and int(battle.player.summon_serial) == previous_serial + 1 and _unique_ids(battle))
	battle.free()


func _test_legacy_over_capacity() -> void:
	var battle := _make(["10", "3", "3", "3"])
	if battle == null:
		return
	_reject_unchanged(battle, "synthetic legacy four living rejects")
	_check("legacy four living are not deleted or clipped by rule", _living(battle) == 4 and battle.enemies.size() == 4)
	battle = _roundtrip(battle)
	if battle != null:
		_reject_unchanged(battle, "restored legacy four living rejects")
		_check("legacy over-cap restore remains nondestructive", _living(battle) == 4 and battle.enemies.size() == 4)
		battle.free()


func _test_formation_metadata() -> void:
	var history: Array[Dictionary] = [
		{"enemy_id":"boss", "health":10},
		{"enemy_id":"old-left", "health":0, "formation_slot":1},
		{"enemy_id":"old-right", "health":0, "formation_slot":2},
		{"enemy_id":"middle-left", "health":0, "formation_slot":1},
		{"enemy_id":"new-right", "health":10, "formation_slot":2},
		{"enemy_id":"new-left", "health":10, "formation_slot":1},
	]
	var before := JSON.stringify(history)
	var roles := MonsterBattleRules.formation_slots(history)
	_check("multi-generation recorded slots preserve both surviving sides", roles["new-right"] == 2 and roles["new-left"] == 1 and roles["boss"] == 0)
	_check("formation lookup is pure and JSON reconstructs identical roles", JSON.stringify(history) == before and MonsterBattleRules.formation_slots(JSON.parse_string(before)) == roles)
	var invalid: Array[Dictionary] = [
		{"enemy_id":"boss", "health":10, "formation_slot":2},
		{"enemy_id":"left", "health":10, "formation_slot":0},
		{"enemy_id":"right", "health":10, "formation_slot":1},
	]
	roles = MonsterBattleRules.formation_slots(invalid)
	_check("main role cannot be stolen and duplicate live roles fall back", roles["boss"] == 0 and roles["left"] == 1 and roles["right"] == 2)
	invalid[1].formation_slot = 1.5
	invalid[2].formation_slot = 99
	roles = MonsterBattleRules.formation_slots(invalid)
	_check("fractional and out-of-range roles fall back deterministically", roles["boss"] == 0 and roles["left"] == 1 and roles["right"] == 2)
	_check("full formation has no free secondary slot", MonsterBattleRules.next_formation_slot(history) == -1)

func _check(label: String, passed: bool) -> bool:
	checks += 1
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1
	return passed

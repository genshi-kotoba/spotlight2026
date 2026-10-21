extends Node
## Exercise the production resolver/queue, including safe JSON snapshot restore.
## No debug victory or direct _finish_battle calls are used.
const BOSS_FLOORS := {"1": 1, "10": 2, "11": 2, "16": 3, "17": 3, "23": 4}
var checks := 0
var failures := 0
var serial := 0

func _ready() -> void:
	SeedService.begin_run("boss-completion-selftest")
	_test_catalog_coverage()
	for id: String in BOSS_FLOORS: _test_boss(id)
	_test_natural_summons()
	_test_regular_completion("2")
	_test_regular_completion("9")
	_test_summoned_boss()
	_test_multiple_bosses()
	_test_death_reaction_priority()
	_test_reflection_priority()
	_test_cold_run_rewards()
	print("BOSS_COMPLETION: %d checks, %d failures" % [checks, failures])
	get_tree().quit(failures)

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print(("PASS " if passed else "FAIL ") + label)

func _test_catalog_coverage() -> void:
	var found: Array[String] = []
	for number in range(1, 24):
		var enemy := MonsterCatalog.create(str(number))
		if str(enemy.get("grade", "")) == "BOSS": found.append(str(number))
	_check("all six CSV bosses across four floors are covered", found == BOSS_FLOORS.keys())

func _make(enemies: Array) -> Dictionary:
	serial += 1
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.initialize_battle({"map_id": "boss-test", "node_id": "case-%d" % serial,
		"battle_index": serial, "draw_count": 0,
		"player": {"health": 5000, "max_health": 5000, "buffs": [], "silver": 0},
		"enemies": enemies, "deck_instances": []})
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	if error == OK: error = resolver.attach_to_battle(battle)
	var ended: Array[Dictionary] = []
	battle.battle_ended.connect(func(result: Dictionary): ended.append(result.duplicate(true)))
	if error == OK: error = battle.start_battle()
	_check("production battle initialized %d" % serial, error == OK)
	return {"battle": battle, "resolver": resolver, "ended": ended}

func _free(setup: Dictionary) -> void:
	setup.resolver.queue_free()
	setup.battle.queue_free()

func _damage(battle: BattleStateMachine, target: String, amount := 10000) -> void:
	_check("queued damage " + target, battle.rules.submit("action.damage",
		{"side": "enemy", "target": target, "amount": amount, "ignore_block": true}) == OK)

func _summon(battle: BattleStateMachine, owner: String, id := "4") -> String:
	var before := battle.enemies.size()
	var error := battle.rules.submit("monster.summon", {"id": id, "owner": owner})
	_check("production summon " + id, error == OK and battle.enemies.size() == before + 1)
	return str(battle.enemies.back().enemy_id)

func _test_boss(id: String) -> void:
	var setup := _make([MonsterCatalog.create(id, BOSS_FLOORS[id])])
	var battle: BattleStateMachine = setup.battle
	var minion := _summon(battle, id)
	_damage(battle, minion)
	_check(id + " killing only the minion cannot win", battle.active and setup.ended.is_empty())
	_summon(battle, id)
	if id == "11":
		_damage(battle, id)
		_check("11 first death restores same body before outcome", battle.active and battle.enemies[0].phase == 2 and battle.enemies[0].health == 96 and setup.ended.is_empty())
	if id == "23":
		_damage(battle, id)
		_check("23 lethal phase-one hit locks at half HP", battle.active and battle.enemies[0].health == FinalBossRules.HALF_HEALTH and battle.enemies[0].boss_transition_pending and setup.ended.is_empty())
		_damage(battle, id)
		_check("23 repeat hit cannot bypass phase lock", battle.active and battle.enemies[0].health == FinalBossRules.HALF_HEALTH)
		var restored := _restore_battle(battle.to_dictionary())
		_check("23 pending phase transition survives cold JSON restore", restored.error == OK and restored.battle.enemies[0].boss_transition_pending and restored.battle.enemies[0].boss_health_locked)
		_free(setup)
		setup = restored
		battle = setup.battle
		_check("23 real turn unlocks phase two", battle.commit_player_sequence([]) == OK and battle.active and battle.enemies[0].phase == 2 and not battle.enemies[0].boss_health_locked)
	_damage(battle, id)
	_check(id + " body death wins with living summons", not battle.active and battle.phase == BattleStateMachine.Phase.VICTORY and setup.ended.size() == 1 and battle.enemies.any(func(e: Dictionary): return int(e.health) > 0 and e.has("summoned_by")))
	if not setup.ended.is_empty():
		_check(id + " result records defeated body only", id in setup.ended[0].defeated_enemy_ids and battle.enemies.filter(func(e: Dictionary): return int(e.health) > 0).all(func(e: Dictionary): return str(e.enemy_id) not in setup.ended[0].defeated_enemy_ids))
	battle.rules.submit("flow.outcome")
	battle.rules.submit("flow.outcome")
	_check(id + " repeated outcomes emit one result", setup.ended.size() == 1)
	var terminal := _restore_battle(battle.to_dictionary())
	_check(id + " terminal cold restore cannot replay result", terminal.error == OK and not terminal.battle.active and terminal.battle.phase == BattleStateMachine.Phase.VICTORY and terminal.ended.is_empty())
	terminal.battle.rules.submit("flow.outcome")
	_check(id + " restored terminal outcome stays silent", terminal.ended.is_empty())
	_free(terminal)
	_free(setup)

func _restore_battle(saved: Dictionary) -> Dictionary:
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.restore_from_dictionary(JSON.parse_string(JSON.stringify(saved)))
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	if error == OK: error = resolver.attach_to_battle(battle)
	var ended: Array[Dictionary] = []
	battle.battle_ended.connect(func(result: Dictionary): ended.append(result.duplicate(true)))
	return {"battle": battle, "resolver": resolver, "ended": ended, "error": error}

func _test_natural_summons() -> void:
	for id: String in ["1", "10", "11"]:
		var setup := _make([MonsterCatalog.create(id, BOSS_FLOORS[id])])
		var battle: BattleStateMachine = setup.battle
		if id == "1":
			battle.commit_player_sequence([])
			battle.commit_player_sequence([])
		elif id == "10": battle.commit_player_sequence([])
		else: _damage(battle, id)
		_check(id + " actual mechanic creates living summons", battle.enemies.any(func(e: Dictionary): return e.get("summoned_by") == id and int(e.health) > 0))
		_damage(battle, id)
		_check(id + " actual summon mechanic cannot block victory", not battle.active and battle.phase == BattleStateMachine.Phase.VICTORY)
		_free(setup)

func _test_regular_completion(id: String) -> void:
	var setup := _make([MonsterCatalog.create(id)])
	var battle: BattleStateMachine = setup.battle
	var minion := _summon(battle, id)
	_damage(battle, id)
	_check(id + " ordinary or elite still requires minion clear", battle.active and setup.ended.is_empty())
	_damage(battle, minion)
	_check(id + " ordinary or elite wins only after all die", not battle.active and setup.ended.size() == 1)
	_free(setup)

func _test_summoned_boss() -> void:
	var setup := _make([MonsterCatalog.create("2")])
	var battle: BattleStateMachine = setup.battle
	var summoned := _summon(battle, "2", "1")
	_damage(battle, summoned)
	_check("summoned Boss does not replace ordinary battle goal", battle.active and setup.ended.is_empty())
	_damage(battle, "2")
	_check("summoned Boss ordinary battle completes after full clear", not battle.active and setup.ended.size() == 1)
	_free(setup)

func _test_multiple_bosses() -> void:
	var setup := _make([MonsterCatalog.create("1"), MonsterCatalog.create("17")])
	var battle: BattleStateMachine = setup.battle
	_summon(battle, "1")
	_damage(battle, "1")
	_check("multiple original Boss bodies all remain objectives", battle.active and setup.ended.is_empty())
	var restored := _restore_battle(battle.to_dictionary())
	_check("multiple Boss objectives rebuild from legacy v1 fields", restored.error == OK)
	_free(setup)
	setup = restored
	battle = setup.battle
	_damage(battle, "17")
	_check("last original Boss death wins after cold restore", not battle.active and setup.ended.size() == 1 and int(battle.enemies.back().health) > 0)
	_free(setup)

func _test_death_reaction_priority() -> void:
	var setup := _make([MonsterCatalog.create("1")])
	var battle: BattleStateMachine = setup.battle
	_summon(battle, "1")
	battle.rules.register_rule("test.death.reaction", "enemy.died", func(event: BattleEvent):
		if event.payload.enemy_id == "1":
			battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": 10000, "ignore_block": true}))
	_damage(battle, "1")
	_check("lethal death reaction settles before Boss victory and defeat wins ties", battle.phase == BattleStateMachine.Phase.DEFEAT and setup.ended.size() == 1 and setup.ended[0].status == "defeat")
	_free(setup)

func _test_reflection_priority() -> void:
	var setup := _make([MonsterCatalog.create("1"), MonsterCatalog.create("19")])
	var battle: BattleStateMachine = setup.battle
	battle.player.health = 1
	# Existing batch deferral must still drain the real reflection reaction first.
	battle.rules.register_rule("test.batch", "test.batch", func(_event: BattleEvent):
		battle.begin_deferred_outcome()
		battle.rules.publish("action.damage", {"side": "enemy", "target": "1", "amount": 10000, "ignore_block": true})
		battle.rules.publish("action.damage", {"side": "enemy", "target": "19", "amount": 1, "ignore_block": true})
		battle.rules.publish("test.batch.end"))
	battle.rules.register_rule("test.batch.end", "test.batch.end", func(_event: BattleEvent): battle.end_deferred_outcome())
	battle.rules.submit("test.batch")
	_check("real reflection and deferred simultaneous Boss death retain defeat priority", battle.phase == BattleStateMachine.Phase.DEFEAT and battle.player.health == 0 and setup.ended.size() == 1)
	_free(setup)

func _run_config() -> Dictionary:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "boss-completion-run"
	config.max_health = 5000
	config.initial_health = 5000
	config.initial_deck = []
	return config

func _connect_rewards(run: RunStateMachine, ended: Array[Dictionary]) -> void:
	run.battle_finished.connect(func(result: Dictionary):
		ended.append(result.duplicate(true))
		_check("real Run battle_finished stages Boss rewards", RunRewards.stage_victory(run, result.map_id, result.node_id, "BOSS", int(result.battle_index)) == OK))

func _test_cold_run_rewards() -> void:
	var run := RunStateMachine.new()
	add_child(run)
	_check("reward test run initializes", run.initialize_new("boss-reward-seed", _run_config()) == OK)
	_check("Run creates production Boss battle", run.start_battle("boss-reward", [MonsterCatalog.create("1")], 0) == OK)
	_summon(run.current_battle, "1")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(run.to_dictionary()))
	var rng := SeedService.capture_snapshot()
	run.queue_free()
	_check("cold restore reacquires seeded state", SeedService.restore_snapshot(rng) == OK)
	run = RunStateMachine.new()
	add_child(run)
	_check("cold Run restore keeps active Boss and summons", run.restore_from_dictionary(saved) == OK and run.current_battle != null and run.current_battle.enemies.size() == 2)
	var ended: Array[Dictionary] = []
	_connect_rewards(run, ended)
	var battle := run.current_battle
	battle.set_meta("presentation_owner", self)
	_damage(battle, "1")
	battle.rules.submit("flow.outcome")
	battle.rules.submit("flow.outcome")
	_check("cold restored kill settles Run and rewards once", run.current_battle == null and ended.size() == 1 and run.inventory_state.rewarded_battles.size() == 1 and not RunRewards.pending(run).is_empty())
	if run.current_battle != null:
		run.queue_free()
		return
	var rewards: Dictionary = JSON.parse_string(JSON.stringify(RunRewards.pending(run)))
	battle.queue_free()
	saved = JSON.parse_string(JSON.stringify(run.to_dictionary()))
	rng = SeedService.capture_snapshot()
	run.queue_free()
	SeedService.restore_snapshot(rng)
	run = RunStateMachine.new()
	add_child(run)
	var restore_error := run.restore_from_dictionary(saved)
	_check("terminal Run restore has rewards and no replayable battle", restore_error == OK and run.current_battle == null and RunRewards.pending(run) == rewards)
	_check("duplicate real reward staging is idempotent after cold restore", RunRewards.stage_victory(run, str(rewards.battle_key).get_slice("/", 0), "boss-reward", "BOSS", 0) == OK and RunRewards.pending(run) == rewards and run.inventory_state.rewarded_battles.size() == 1)
	run.queue_free()

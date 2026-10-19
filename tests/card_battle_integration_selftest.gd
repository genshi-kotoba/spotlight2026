extends Node

## PRG-002/003/004 与 PRG-007/008 的实际战斗连接测试。
## godot --headless --path . res://tests/card_battle_integration_selftest.tscn

var failures := 0


func _ready() -> void:
	_test_card_and_buff_resolution()
	print("全部通过" if failures == 0 else "失败 %d 项" % failures)
	get_tree().quit(failures)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		failures += 1
		print("  失败  %s" % label)


func _test_card_and_buff_resolution() -> void:
	var run := RunStateMachine.new()
	add_child(run)
	var config := {
		"run_id": "integrated-effects-001",
		"max_health": 40,
		"initial_health": 40,
		"initial_gold": 0,
		"card_catalog": ["bonk", "spit", "one_shot"],
		"initial_deck": ["bonk", "spit", "one_shot"],
		"map_ids": ["map-001", "map-002", "map-003"],
	}
	var error := run.initialize_new("integrated-effects-seed", config,
		["bonk", "spit", "one_shot"])
	_check("局内状态可使用新卡牌资源", error == OK)
	if error != OK:
		return
	var enemy := {
		"enemy_id": "enemy-001", "health": 30, "max_health": 30,
		"block": 0, "buffs": [], "actions": [{"action_id": "wait"}],
	}
	error = run.start_battle("hex:1,2", [enemy], 3)
	_check("战斗能挂载效果适配层", error == OK and run.current_battle != null)
	if error != OK:
		return
	var battle := run.current_battle
	var instance_by_card := {}
	for card: Dictionary in battle.hand:
		instance_by_card[card["card_id"]] = card["instance_id"]
	var ordered: Array[String] = [
		instance_by_card["bonk"], instance_by_card["spit"], instance_by_card["one_shot"],
	]
	var targets := {}
	targets[instance_by_card["bonk"]] = "enemy-001"
	targets[instance_by_card["spit"]] = "enemy-001"
	error = battle.commit_player_sequence(ordered, targets)
	_check("资源效果按牌序完成结算", error == OK)
	if error == OK:
		_check("攻击与中毒已改变敌人生命", int(battle.enemies[0]["health"]) == 23)
		_check("中毒同名合并且结算后只剩一条", battle.enemies[0]["buffs"].size() == 1 \
			and int(battle.enemies[0]["buffs"][0]["layers"]) == 1)
		var removed := true
		for zone: Array in [battle.draw_pile, battle.discard_pile, battle.hand, battle.play_zone]:
			for card: Dictionary in zone:
				if card["instance_id"] == instance_by_card["one_shot"]:
					removed = false
		_check("一次性卡仅从本场战斗牌区移除", removed)
		_check("下一回合仍在玩家行动阶段", battle.phase == BattleStateMachine.Phase.PLAYER_ACTION)
		var run_snapshot := run.to_dictionary()
		var seed_snapshot := SeedService.capture_snapshot()
		var restored := RunStateMachine.new()
		add_child(restored)
		var restore_error := SeedService.restore_snapshot(seed_snapshot)
		if restore_error == OK:
			restore_error = restored.restore_from_dictionary(run_snapshot)
		_check("战斗与随机流可联合恢复", restore_error == OK \
			and restored.current_battle != null)
		if restore_error == OK:
			var resumed := restored.current_battle
			var resumed_ids := {}
			for card: Dictionary in resumed.hand:
				resumed_ids[card["card_id"]] = card["instance_id"]
			var resumed_order: Array[String] = [resumed_ids["bonk"], resumed_ids["spit"]]
			var resumed_targets := {}
			resumed_targets[resumed_ids["bonk"]] = "enemy-001"
			resumed_targets[resumed_ids["spit"]] = "enemy-001"
			var resumed_error := resumed.commit_player_sequence(resumed_order, resumed_targets)
			_check("恢复后资源效果继续结算", resumed_error == OK \
				and int(resumed.enemies[0]["health"]) == 15)
		restored.queue_free()
	run.queue_free()

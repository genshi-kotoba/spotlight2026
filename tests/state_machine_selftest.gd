extends SceneTree

## PRG-002 / 003 / 004 无渲染自测：
## godot --headless --path . --script res://tests/state_machine_selftest.gd

var _failures := 0
var _effect_battle: BattleStateMachine
var _resolved_order: Array[int] = []
var _rewound_once := false
var _buff_requests := 0
var _reshuffles := 0


func _initialize() -> void:
	_test_run_state_and_seed_restore()
	_test_battle_order_and_pointer()
	_test_discard_reshuffle()
	_test_battle_snapshot_validation()
	_test_initial_battle_outcome()
	_test_global_save_round_trip()
	print("全部通过" if _failures == 0 else "失败 %d 项" % _failures)
	quit(_failures)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		_failures += 1
		print("  失败  %s  %s" % [label, detail])


func _base_run_config(run_id: String) -> Dictionary:
	return {
		"run_id": run_id,
		"max_health": 80,
		"initial_health": 72,
		"initial_gold": 20,
		"card_catalog": ["card-a", "card-b", "card-locked"],
		"initial_deck": ["card-a", "card-b"],
		"initial_items": [{"item_id": "potion-a"}],
		"map_ids": ["map-001", "map-002", "map-003"],
		"reward_pool": ["reward-a", "reward-b", "reward-c"],
		"shop_pool": ["shop-a", "shop-b", "shop-c"],
		"event_pool": ["event-a", "event-b", "event-c"],
	}


func _test_run_state_and_seed_restore() -> void:
	print("[PRG-003 局内状态与随机池]")
	var run := RunStateMachine.new()
	get_root().add_child(run)
	var stats: Array[StringName] = []
	run.stat_updated.connect(func(metric: StringName, _value: Variant): stats.append(metric))
	var error := run.initialize_new(
		"state-machine-seed", _base_run_config("run-test-001"), ["card-a", "card-b"]
	)
	_check("新局初始化成功", error == OK)
	_check("锁定卡未进入局内卡池", run.card_pool == ["card-a", "card-b"])
	_check("三张地图已初始化", run.map_ids.size() == 3 and run.map_states.size() == 3)
	_check("奖励/商店/事件池已初始化",
		run.reward_pool.size() == 3 and run.shop_pool.size() == 3 and run.event_pool.size() == 3)

	run.change_gold(5)
	run.change_health(-2)
	run.update_map_node("map-001", "hex:1,2", {"visited": true, "kind": "event"})
	_check("可触发成就的数值均发出更新信号",
		stats.has(&"gold") and stats.has(&"health") and stats.has(&"map_node_updates"))

	var run_snapshot := run.to_dictionary()
	var seed_snapshot := SeedService.capture_snapshot()
	var expected_rewards := run.reward_pool.duplicate()
	run.queue_free()
	_check("随机快照捕获成功", not seed_snapshot.is_empty())

	error = SeedService.restore_snapshot(seed_snapshot)
	var restored := RunStateMachine.new()
	get_root().add_child(restored)
	error = restored.restore_from_dictionary(run_snapshot) if error == OK else error
	_check("局内与随机快照可共同恢复", error == OK)
	_check("恢复后资源一致", restored.health == 70 and restored.gold == 25)
	_check("恢复后池顺序一致", restored.reward_pool == expected_rewards)
	_check("恢复后地图节点状态一致",
		restored.map_states["map-001"]["nodes"].has("hex:1,2"))
	restored.queue_free()


func _battle_config(enemy_health: int = 20, draw_cards: int = 3) -> Dictionary:
	return {
		"map_id": "map-001",
		"node_id": "hex:4,0",
		"battle_index": 0,
		"draw_count": draw_cards,
		"discard_hand_at_turn_end": false,
		"player": {"health": 40, "max_health": 40, "block": 0, "buffs": []},
		"enemies": [{
			"enemy_id": "enemy-001",
			"health": enemy_health,
			"max_health": maxi(1, enemy_health),
			"block": 0,
			"buffs": [{"buff_id": "weak", "layers": 1, "duration": 2}],
			"actions": [{"action_id": "wait"}],
		}],
		"deck_instances": [
			{"instance_id": "card-1", "card_id": "card-a"},
			{"instance_id": "card-2", "card_id": "card-a"},
			{"instance_id": "card-3", "card_id": "card-b"},
		],
	}


func _test_battle_order_and_pointer() -> void:
	print("[PRG-004 阶段与指针结算]")
	SeedService.begin_run("battle-pointer-seed")
	var battle := BattleStateMachine.new()
	get_root().add_child(battle)
	var phases: Array[int] = []
	_buff_requests = 0
	battle.phase_changed.connect(func(_old: int, next: int): phases.append(next))
	battle.buff_effect_requested.connect(
		func(_side: StringName, _id: String, _buff: Dictionary): _buff_requests += 1
	)
	var error := battle.initialize_battle(_battle_config())
	error = battle.start_battle() if error == OK else error
	_check("战斗进入玩家行动阶段", error == OK and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION)
	_check("玩家阶段严格经过抽牌和 Buff",
		phases.has(BattleStateMachine.Phase.PLAYER_DRAW) \
		and phases.has(BattleStateMachine.Phase.PLAYER_BUFF))
	_check("初始抽牌逐张完成", battle.hand.size() == 3)

	_effect_battle = battle
	_resolved_order.clear()
	_rewound_once = false
	battle.card_effect_requested.connect(_on_pointer_card_effect)
	var order: Array[String] = []
	for card: Dictionary in battle.hand:
		order.append(card["instance_id"])
	error = battle.commit_player_sequence(order)
	_check("三张牌按指针结算并允许一次回跳", error == OK and _rewound_once)
	_check("回跳导致前一张牌再次触发", _resolved_order.size() == 5,
		"实际触发 %d 次" % _resolved_order.size())
	_check("敌方 Buff 逐个发出结算请求", _buff_requests == 1)
	battle.queue_free()
	_effect_battle = null


func _on_pointer_card_effect(_card: Dictionary, _target: Variant, index: int) -> void:
	_resolved_order.append(index)
	if index == 1 and not _rewound_once:
		_rewound_once = true
		_effect_battle.request_pointer_rewind(1)


func _test_discard_reshuffle() -> void:
	print("[PRG-004 弃牌堆重洗]")
	SeedService.begin_run("battle-reshuffle-seed")
	var battle := BattleStateMachine.new()
	get_root().add_child(battle)
	_reshuffles = 0
	battle.discard_pile_shuffled.connect(func(_size: int): _reshuffles += 1)
	var config := _battle_config(20, 3)
	config["discard_hand_at_turn_end"] = true
	var error := battle.initialize_battle(config)
	error = battle.start_battle() if error == OK else error
	error = battle.end_player_action() if error == OK else error
	_check("敌方回合后进入第二个玩家回合",
		error == OK and battle.turn_number == 2 and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION)
	_check("弃牌堆使用 battle.draw 原流重洗", _reshuffles == 1)
	_check("重洗后再次抽出全部三张", battle.hand.size() == 3)
	battle.queue_free()


func _test_battle_snapshot_validation() -> void:
	print("[PRG-004 战斗快照一致性]")
	SeedService.begin_run("battle-snapshot-validation-seed")
	var battle := BattleStateMachine.new()
	get_root().add_child(battle)
	var error := battle.initialize_battle(_battle_config())
	error = battle.start_battle() if error == OK else error
	var snapshot := battle.to_dictionary()
	var duplicate_card: Dictionary = snapshot["hand"][0].duplicate(true)
	snapshot["discard_pile"].append(duplicate_card)
	var restored := BattleStateMachine.new()
	get_root().add_child(restored)
	error = restored.restore_from_dictionary(snapshot)
	_check("同一卡牌实例不能同时存在于多个牌区", error == ERR_INVALID_DATA)
	battle.queue_free()
	restored.queue_free()


func _test_initial_battle_outcome() -> void:
	print("[PRG-004 初始终局判定]")
	SeedService.begin_run("battle-initial-outcome-seed")
	var battle := BattleStateMachine.new()
	get_root().add_child(battle)
	var ended := {"status": ""}
	battle.battle_ended.connect(
		func(result: Dictionary): ended["status"] = result.get("status", "")
	)
	var error := battle.initialize_battle(_battle_config(0, 3))
	error = battle.start_battle() if error == OK else error
	_check("初始敌人全灭时直接胜利", error == OK \
		and ended["status"] == "victory" and battle.turn_number == 0 \
		and battle.phase == BattleStateMachine.Phase.VICTORY)
	battle.queue_free()


func _test_global_save_round_trip() -> void:
	print("[PRG-002 JSON 存档]")
	var path := "user://state_machine_selftest.json"
	var absolute := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(absolute)
	DirAccess.remove_absolute(absolute + ".tmp")
	DirAccess.remove_absolute(absolute + ".bak")

	var global_state := GlobalStateMachine.new()
	global_state.save_path = path
	global_state.unlock_card("card-a")
	global_state.unlock_card("card-b")
	global_state.set_setting("master_volume", 0.75)
	_check("非有限浮点数不能写入 JSON 设置",
		global_state.set_setting("invalid_number", INF) == ERR_INVALID_PARAMETER)
	var error := global_state.start_new_run(
		"global-save-seed", _base_run_config("run-save-001")
	)
	_check("全局状态可建立并保存活动局", error == OK and FileAccess.file_exists(path))

	var loaded := GlobalStateMachine.new()
	loaded.save_path = path
	error = loaded.load_save()
	_check("JSON 存档可读取", error == OK)
	_check("局外设置与解锁恢复",
		loaded.settings.get("master_volume") == 0.75 and loaded.unlocked_cards == ["card-a", "card-b"])
	_check("活动局可继续", loaded.has_continuable_run())
	error = loaded.continue_saved_run()
	_check("继续游戏同时恢复随机和局内状态", error == OK and loaded.current_run != null)

	DirAccess.remove_absolute(absolute)
	DirAccess.remove_absolute(absolute + ".tmp")
	DirAccess.remove_absolute(absolute + ".bak")

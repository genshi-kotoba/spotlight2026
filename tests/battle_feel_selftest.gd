extends Node

## 战斗打击感 P0 断言：顿帧、伤害飘字分级、击杀收尾节拍。
## 跑法：godot --headless --path . res://tests/battle_feel_selftest.tscn

const DECK: Array[String] = [
	"test_damage_enemy", "test_damage_enemy", "test_damage_enemy",
	"test_block", "test_heal",
]

var failures := 0
var fixture_root := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/battle-feel-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.profile_path = fixture_root.path_join("profile.json")
	SaveGateway.slot_paths.assign([fixture_root.path_join("1.json"), fixture_root.path_join("2.json"), fixture_root.path_join("3.json")])
	SaveGateway._active_slot = 1
	Engine.time_scale = 1.0
	_check("独立测试存档", SaveGateway._load_slot(1) == OK)
	var scene := _make_scene()
	add_child(scene)
	await _frames(5)
	await _check_hitstop(scene)
	_check_float_tiers(scene)
	await _check_kill_beat(scene)
	await _check_lethal_finish(scene)
	Engine.time_scale = 1.0
	scene.queue_free()
	await _frames(3)
	print("战斗打击感：全部通过" if failures == 0 else "战斗打击感：失败%d项" % failures)
	get_tree().quit(failures)


func _make_scene() -> BattleTestScene:
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	scene.deck_card_ids.assign(DECK)
	scene.initial_draw_count = 5
	scene.resolution_delay = 0.35
	# 20 血配三张 8 伤测试卡，一次出牌就能致死。
	scene.enemy_starting_health = 20
	# 本测试断言「一次致死出牌即结束战斗」，用单敌人；多敌人排布由 content_ui_selftest 覆盖。
	scene.test_enemy_count = 1
	return scene


func _check_hitstop(scene: BattleTestScene) -> void:
	var stop := scene._hit_stop
	Engine.time_scale = 1.0
	stop.hit_stop(0.2)
	_check("顿帧期间 time_scale 被压低", Engine.time_scale < 1.0)
	await _real(0.32)
	_check("顿帧按真实时长恢复到触发前的 1.0", is_equal_approx(Engine.time_scale, 1.0))

	Engine.time_scale = 0.2
	stop.hit_stop(0.1)
	_check("慢放（0.2）上再触发顿帧会继续压低", Engine.time_scale < 0.2)
	await _real(0.2)
	_check("慢放下恢复到触发前的 0.2 而不是 1.0", is_equal_approx(Engine.time_scale, 0.2))
	Engine.time_scale = 1.0

	stop.hit_stop(0.18)
	await _real(0.1)
	stop.hit_stop(0.18)
	await _real(0.12)
	_check("重叠调用只延长，第一次到期后仍在顿", Engine.time_scale < 1.0)
	await _real(0.2)
	_check("重叠延长到期后恢复，且只恢复一次", is_equal_approx(Engine.time_scale, 1.0))


func _check_float_tiers(scene: BattleTestScene) -> void:
	scene._feedback.on_damaged(&"enemy", 3, 0)
	scene._feedback.on_damaged(&"enemy", 27, 0)
	scene._feedback.on_damaged(&"enemy", 200, 0)
	var small := _float_font(scene, "-3")
	var medium := _float_font(scene, "-27")
	var heavy := _float_font(scene, "-200")
	_check("伤害飘字分级 3/27/200 对应字号 30/42/58",
		small == 30 and medium == 42 and heavy == 58)


func _check_kill_beat(scene: BattleTestScene) -> void:
	var probe := {"stopped": false}
	_sample_during_beat(scene, probe)
	var beat := scene.kill_beat_time
	var started := Time.get_ticks_msec()
	await scene._play_damage_feedback({"side": &"enemy", "damage": 200, "blocked": 0, "lethal": true})
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	_check("击杀节拍不短于 kill_beat_time", elapsed >= beat - 0.01)
	_check("击杀节拍期间已触发顿帧", bool(probe["stopped"]))


func _check_lethal_finish(scene: BattleTestScene) -> void:
	for card: Dictionary in scene._battle.hand:
		if str(card.card_id) == "test_damage_enemy":
			scene._on_hand_card_pressed(str(card.instance_id))
	await _real(0.5)
	scene._on_play_pressed()
	_check("致死出牌后逻辑已结束战斗", not scene._battle.active)
	var deadline := Time.get_ticks_msec() + 10000
	while scene._busy and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _real(0.5)
	_check("击杀节拍走完真实结算，收尾无残留",
		not scene._busy and scene._card_transfers.is_empty() and scene._resolved_discards.is_empty())


## 取样只读，跑够 2.5 秒真实时长；调用方在节拍结束时读结果，取样协程自行结束。
func _sample_during_beat(scene: BattleTestScene, probe: Dictionary) -> void:
	var deadline := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		probe["stopped"] = bool(probe["stopped"]) or Engine.time_scale < 1.0


func _float_font(scene: BattleTestScene, text: String) -> int:
	for child: Node in scene.get_children():
		if child is Label and (child as Label).text == text:
			return (child as Label).get_theme_font_size("font_size")
	return -1


func _real(seconds: float) -> void:
	# 顿帧会把 time_scale 压到 0.05，等待必须走真实时长，否则测试自己被拖慢。
	await get_tree().create_timer(seconds, true, false, true).timeout


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1

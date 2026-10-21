extends Node

const AUDIO_SETTINGS := preload("res://systems/audio/audio_settings.gd")
var failures := 0
var fixture_root := ""

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/main-new-merge-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("隔离存档", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "main-new-merge-test"
	_check("保留main初始牌组", SaveGateway.start_new_run("main-new-merge-test", config) == OK and SaveGateway.current_run().deck == ["1", "1", "1", "50", "50", "50", "40", "40"])
	_check("没有恢复成就或局外解锁", not GlobalState.has_method("unlock_card") and not GlobalState.has_method("complete_achievement") and not ResourceLoader.exists("res://ui/catalog/achievements.tscn"))
	var menu: Control = load("res://ui/main_menu/main_menu.tscn").instantiate()
	add_child(menu)
	_check("主菜单七个入口并接入设置页", menu.get_node("按钮列").get_child_count() == 7 and menu.settings_scene == "res://ui/main_menu/main_menu_settings.tscn")
	menu.queue_free()
	await get_tree().process_frame
	var settings: Control = load("res://ui/main_menu/main_menu_settings.tscn").instantiate()
	add_child(settings)
	await get_tree().process_frame
	var sliders := settings.find_children("*", "HSlider", true, false)
	_check("音乐与音效两条公共滑块", sliders.size() == 2)
	if sliders.size() == 2:
		sliders[0].value = 0.35
		sliders[1].value = 0.55
		_check("音量即时更新同一设置对象", is_equal_approx(AUDIO_SETTINGS.volume("music_volume"), 0.35) and is_equal_approx(AUDIO_SETTINGS.volume("sfx_volume"), 0.55))
	var deadline := Time.get_ticks_msec() + 7000
	while not AudioService.is_ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if Engine.has_singleton("Wwise"):
		_check("Wwise音效与音乐Bank加载", AudioService.bank_ok("SFX") and AudioService.bank_ok("Music"))
		AUDIO_SETTINGS.apply_all()
		_check("Wwise音量写入接口返回成功", AudioService.set_rtpc("Volume_Music", 35.0) and AudioService.set_rtpc("Volume_SFX", 55.0))
		await get_tree().create_timer(0.1).timeout
		# 原生模块的读回值与写入值不一致，保留诊断，不把“接受调用”误当成听感验证。
		print("INFO Wwise RTPC readback music=", AudioService.get_rtpc("Volume_Music"), " sfx=", AudioService.get_rtpc("Volume_SFX"))
	await _capture("volume-settings.png")
	settings.queue_free()
	await get_tree().process_frame
	var run := SaveGateway.current_run()
	run.items.append({"item_id": "discard-test", "kind": "potion", "potion": 0})
	SaveGateway.save_current()
	var snapshot := JSON.stringify(run.to_dictionary())
	var previous_error := SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("丢弃保存失败回滚", RunRewards.discard_item(run, "discard-test") != OK and JSON.stringify(run.to_dictionary()) == snapshot)
	SaveGateway._load_error = previous_error
	_check("丢弃成功后持久保存", RunRewards.discard_item(run, "discard-test") == OK and RunRewards.item(run, "discard-test").is_empty())
	var saved_hash := FileAccess.get_sha256(SaveGateway.save_path)
	var battle: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	battle.relic_board_path = fixture_root.path_join("empty-board.json")
	battle.deck_card_ids.assign(["test_damage_enemy", "test_block", "test_heal"])
	add_child(battle)
	await preload("res://tests/support/presentation_test_helper.gd").battle_settled(battle)
	await get_tree().create_timer(0.8).timeout
	var sandbox := battle._test_run
	sandbox.items.append({"item_id": "sandbox-fragment", "kind": "fragment", "fragment_id": "gain_block"})
	_check("测试装配只更新沙盒", RunRewards.equip_fragment(sandbox, "sandbox-fragment", 0) == OK and RunRewards.board_for_run(sandbox).cells[0] == "gain_block" and FileAccess.get_sha256(SaveGateway.save_path) == saved_hash)
	var detached := RunStateMachine.new()
	detached.active = true
	add_child(detached)
	_check("沙盒不放宽其他局的权限", not RunRewards._can_edit(detached))
	detached.queue_free()
	var id := str(battle._battle.hand[0].instance_id)
	battle._on_hand_card_pressed(id)
	await get_tree().process_frame
	_check("出牌保留缩略飞行动画", battle._card_transfers.has(id))
	await get_tree().create_timer(0.4).timeout
	battle._on_cancel_pressed()
	await get_tree().process_frame
	_check("取消编排不误当成抽新牌", battle._hand_ids_previous.has(id) and battle._selected_ids.is_empty())
	await get_tree().create_timer(0.4).timeout
	await _capture("merged-battle.png")
	battle.queue_free()
	await get_tree().process_frame
	print("main(new)补充合并：全部通过" if failures == 0 else "main(new)补充合并：失败%d项" % failures)
	get_tree().quit(failures)

func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))

func _check(label: String, passed: bool) -> void:
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

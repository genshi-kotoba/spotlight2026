extends "res://tests/battle_rewards_selftest.gd"
## 只对指定存档的隔离副本操作；不对正式玩家文件执行保存或覆盖。

func _run() -> void:
	get_tree().current_scene = null
	var source := ""
	var operation := "resume"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--source="): source = argument.trim_prefix("--source=")
		if argument.begins_with("--operation="): operation = argument.trim_prefix("--operation=")
	if source.is_empty() or not FileAccess.file_exists(source):
		print("RECOVERY_PROBE missing --source; no player files written")
		get_tree().quit(2)
		return
	var original_hash := FileAccess.get_sha256(source)
	fixture_root = "res://.godot/save-recovery-probe-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	var copy := fixture_root.path_join("game.json")
	_check("创建存档诊断副本", DirAccess.copy_absolute(source, copy) == OK)
	print("RECOVERY_PROBE fixture=", fixture_root, " operation=", operation)
	print("RECOVERY_PROBE startup_load_error=", SaveGateway._load_error, " notice=", SaveGateway.startup_notice())
	if SaveGateway._validate_save(GlobalStateMachine.DEFAULT_SAVE_PATH) == OK:
		_check("有效玩家存档在首次启动时即通过校验", SaveGateway._load_error == OK)
	var autoloads := ProjectSettings.get_property_list().filter(func(property: Dictionary) -> bool: return str(property.name).begins_with("autoload/"))
	var names: Array = autoloads.map(func(property: Dictionary) -> String: return str(property.name))
	_check("冷启动顺序先载入卡牌资料再校验存档", names.find("autoload/TextCatalog") >= 0 and names.find("autoload/TextCatalog") < names.find("autoload/SaveGateway"))
	SaveGateway.save_path = copy
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	print("RECOVERY_PROBE before load_current")
	var error := SaveGateway.load_current()
	print("RECOVERY_PROBE load_current=", error, " notice=", SaveGateway.startup_notice())
	_check("副本完整验证并载入", error == OK)
	# 真实玩家问题：商店记录在资料表尚未就绪时被误判为坏档。
	var saved: Dictionary = SaveGateway._read_json(copy).data
	var shops: Dictionary = saved.get("active_run", {}).get("run_snapshot", {}).get("inventory_state", {}).get("shops", {})
	if not shops.is_empty():
		var tables := TextCatalog._tables
		TextCatalog._tables = {}
		_check("复现旧启动顺序误判含商店的有效存档", not RunShop.valid_shops(shops) and SaveGateway._validate_save(copy) == ERR_INVALID_DATA)
		TextCatalog._tables = tables
		_check("资料就绪后相同商店及完整存档可通过校验", RunShop.valid_shops(shops) and SaveGateway._validate_save(copy) == OK)
	if error == OK and operation != "validate":
		var menu: Control = load(MENU).instantiate()
		get_tree().root.add_child(menu)
		get_tree().current_scene = menu
		await _frames(3)
		print("RECOVERY_PROBE menu ready; continuable=", SaveGateway.has_continuable_run())
		if operation == "new":
			menu._on_new_game_pressed()
			if menu._pending_new_run: menu._on_overwrite_accepted()
		else:
			menu._on_continue_pressed()
		print("RECOVERY_PROBE requested ", operation, " transition=", SceneTransition.is_loading())
		await _frames(5)
		print("RECOVERY_PROBE scene=", get_tree().current_scene.scene_file_path, " active=", GlobalState.run_active)
		_check("读取或新建后进入正常玩法场景", GlobalState.run_active and get_tree().current_scene.scene_file_path in [EncounterFlow.MAP_SCENE, EncounterFlow.BATTLE_SCENE])
		if operation == "resume":
			var before: Dictionary = saved.active_run.run_snapshot
			var restored := SaveGateway.current_run().to_dictionary()
			for key: String in ["run_id", "main_seed", "health", "gold", "deck", "deck_cards", "items", "inventory_state", "current_map_id"]:
				_check("恢复保留原进度：" + key, _normalized(before.get(key)) == _normalized(restored.get(key)))
			if before.get("current_battle") is Dictionary:
				for key: String in ["turn_number", "player", "enemies", "hand", "play_zone", "draw_pile", "discard_pile"]:
					_check("恢复保留原战斗：" + key, _normalized(before.current_battle.get(key)) == _normalized(restored.current_battle.get(key)))
		var identity := SaveGateway.current_run().run_id
		_check("恢复或新建后可再次安全保存", SaveGateway.save_current() == OK)
		if get_tree().current_scene.has_method("_return_to_menu"):
			get_tree().current_scene._return_to_menu()
		else:
			get_tree().current_scene._on_menu_return()
		await _frames(5)
		_check("保存返回菜单后仍可继续", get_tree().current_scene.scene_file_path == MENU and SaveGateway.has_continuable_run())
		_check("模拟重启重新读取刚保存的完整状态", SaveGateway.load_current() == OK and SaveGateway.current_run() == null)
		get_tree().current_scene._on_continue_pressed()
		await _frames(8)
		_check("二次继续保持同一对局", SaveGateway.current_run() != null and SaveGateway.current_run().run_id == identity and get_tree().current_scene.scene_file_path in [EncounterFlow.MAP_SCENE, EncounterFlow.BATTLE_SCENE])
	_check("源存档字节保持不变", FileAccess.get_sha256(source) == original_hash)
	print("存档崩溃诊断：全部通过" if failures == 0 else "存档崩溃诊断：失败%d项" % failures)
	get_tree().quit(failures)


func _normalized(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value))

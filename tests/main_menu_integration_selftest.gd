extends Node

const MENU := "res://ui/main_menu/main_menu.tscn"
const ENTRY := "res://ui/main_menu/menu_map_entry.tscn"
var failures := 0
var fixture_root := ""
var gateway: Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	gateway = get_node("/root/SaveGateway")
	var autoloads := ProjectSettings.get_property_list().filter(func(property: Dictionary) -> bool: return str(property.name).begins_with("autoload/"))
	var names: Array = autoloads.map(func(property: Dictionary) -> String: return str(property.name))
	_check("冷启动资料表必须先于存档校验就绪", names.find("autoload/TextCatalog") >= 0 and names.find("autoload/TextCatalog") < names.find("autoload/SaveGateway"))
	# 所有写盘和删除只落在本轮唯一的 .godot 夹具目录，不碰用户档案/典籍。
	fixture_root = "res://.godot/menu-integration-%d" % Time.get_ticks_usec()
	gateway.save_path = fixture_root.path_join("game.json")
	_check("隔离存档可载入", gateway.load_current() == OK)
	var menu: Control = load(MENU).instantiate()
	get_tree().root.add_child(menu)
	# 测试节点保持 root 兄弟节点，真实换场景时不销毁测试协程。
	get_tree().current_scene = menu
	await _frames()
	_check("空档案不能继续但能开新局", menu.get_node("按钮列/继续游戏").disabled and not menu.get_node("按钮列/新游戏").disabled)
	_check("主菜单保留原入口并加入记录且不再有存档选择入口", menu.get_node("按钮列").get_child_count() == 8 and menu.has_node("按钮列/记录") and not menu.has_node("档案"))
	_check("旧三槽位接口及场景已移除", not gateway.has_method("set_active_slot") and not gateway.has_method("list_slots") and not ResourceLoader.exists("res://ui/main_menu/profile_switch.tscn") and not ResourceLoader.exists("res://ui/main_menu/slot_card.tscn"))
	menu.get_node("按钮列/设置").pressed.emit()
	_check("未导入设置页时给明确提示", menu.get_node("提示条/文本").text.contains("设置页尚未接入"))
	menu.get_node("按钮列/新游戏").pressed.emit()
	await _frames()
	var view: Node = get_tree().current_scene
	_check("新游戏进入 main 地图装配层", view.scene_file_path == ENTRY)
	if view.scene_file_path != ENTRY or view.map_run.current_floor <= 0:
		_finish()
		return
	_check("真实状态机开局且三张地图配置合法", GlobalState.run_active and GlobalState.current_run.map_ids.size() == 3)
	_check("新局固定八张初始牌且不伪造局外解锁", GlobalState.current_run.deck == ["1", "1", "1", "50", "50", "50", "40", "40"] and GlobalState.unlocked_cards.is_empty())
	var run_id: String = GlobalState.current_run.run_id
	var map_before: String = _json(view._map_snapshot)
	var movement: Vector2 = view.session.actor_plane
	for displacement: Vector2 in [Vector2(0.2, 0), Vector2(-0.2, 0), Vector2(0, 0.2)]:
		view.session.move_actor(displacement)
		if not view.session.actor_plane.is_equal_approx(movement):
			break
	_check("移动夹具确实改变位置", not view.session.actor_plane.is_equal_approx(movement))
	var state_before: String = _json(view.capture_state())
	var stream := SeedService.get_stream(RandomDomains.SHOP, ["menu-test"])
	stream.pick(["a", "b", "c"])
	var seed_before: String = JSON.stringify(SeedService.capture_snapshot())
	view._return_to_menu()
	await _frames()
	menu = get_tree().current_scene
	_check("保存返回后可继续同一局", menu.scene_file_path == MENU and not menu.get_node("按钮列/继续游戏").disabled)
	var saved: Dictionary = gateway._read_json(gateway.save_path).data
	_check("沿用 main 存档字段并保存可选地图检查点", saved.save_version == GlobalStateMachine.SAVE_VERSION and saved.has("menu_map_checkpoint") and not saved.has("placeholder_run"))
	menu.get_node("按钮列/继续游戏").pressed.emit()
	await _frames()
	view = get_tree().current_scene
	_check("继续没有重置地图或位置/探索", _json(view._map_snapshot) == map_before and _json(view.capture_state()) == state_before)
	_check("继续没有重装随机上下文导致旧流失效", stream == SeedService.get_stream(RandomDomains.SHOP, ["menu-test"]) and JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	_check("继续保持原局身份", GlobalState.current_run.run_id == run_id)
	view._return_to_menu()
	await _frames()
	# 模拟冷启动：销毁运行中对象，只从 JSON/随机快照恢复。
	_check("冷启动式重新载入当前档", gateway.load_current() == OK and GlobalState.current_run == null)
	_check("未点击继续时保存仍保留地图", gateway.save_current() == OK and gateway._read_json(gateway.save_path).data.has("menu_map_checkpoint"))
	menu = get_tree().current_scene
	menu.refresh()
	menu.get_node("按钮列/继续游戏").pressed.emit()
	await _frames()
	view = get_tree().current_scene
	_check("冷恢复保留真实局与地图进度", GlobalState.current_run.run_id == run_id and _json(view.capture_state()) == state_before and _json(view._map_snapshot) == map_before)
	_check("冷恢复随机状态完全一致", JSON.stringify(SeedService.capture_snapshot()) == seed_before)
	view._return_to_menu()
	await _frames()
	menu = get_tree().current_scene
	menu.get_node("按钮列/新游戏").pressed.emit()
	_check("有局新开必须先确认覆盖", menu.get_node("确认弹窗").visible and GlobalState.current_run.run_id == run_id)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join("overwrite-confirm.png"))
	menu.get_node("确认弹窗/面板/按钮行/取消").pressed.emit()
	_check("取消覆盖不改动本局", not menu.get_node("确认弹窗").visible and GlobalState.current_run.run_id == run_id)
	menu.get_node("按钮列/新游戏").pressed.emit()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	get_viewport().push_input(escape, true)
	await _frames()
	_check("Esc取消覆盖且不改变本局", not menu.get_node("确认弹窗").visible and not menu._pending_new_run and GlobalState.current_run.run_id == run_id)
	var file_before := FileAccess.get_file_as_string(gateway.save_path)
	var random_before := JSON.stringify(SeedService.capture_snapshot())
	var original_run: RunStateMachine = GlobalState.current_run
	var config: Dictionary = menu._new_run_config()
	_check("未明确确认时网关拒绝直接覆盖", gateway.start_new_run("unconfirmed", config) == ERR_ALREADY_IN_USE and GlobalState.current_run == original_run)
	config.max_health = 0
	_check("无效新局配置不破坏原局", gateway.start_new_run("invalid-config", config, true) != OK and GlobalState.current_run == original_run and FileAccess.get_file_as_string(gateway.save_path) == file_before and JSON.stringify(SeedService.capture_snapshot()) == random_before)
	var old_stream := SeedService.get_stream(RandomDomains.SHOP, ["overwrite-rollback"])
	old_stream.pick([1, 2, 3])
	random_before = JSON.stringify(SeedService.capture_snapshot())
	var blocker: String = gateway.save_path + ".tmp"
	_check("创建隔离的写盘失败夹具", DirAccess.make_dir_recursive_absolute(blocker) == OK)
	menu.get_node("按钮列/新游戏").pressed.emit()
	menu.get_node("确认弹窗/面板/按钮行/确定").pressed.emit()
	_check("确认覆盖但写盘失败时留在菜单并保留原文件/对象/随机流", get_tree().current_scene == menu and GlobalState.current_run == original_run and gateway.has_continuable_run() and FileAccess.get_file_as_string(gateway.save_path) == file_before and JSON.stringify(SeedService.capture_snapshot()) == random_before and SeedService.get_stream(RandomDomains.SHOP, ["overwrite-rollback"]) == old_stream)
	_check("失败时给出提示", menu.get_node("提示条/文本").text.contains("原存档与进度保持不变"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(blocker))
	var damaged: Dictionary = gateway._read_json(gateway.save_path).data.duplicate(true)
	damaged.menu_map_checkpoint.snapshot["generator_version"] = "invalid-test-version"
	var damaged_path := fixture_root.path_join("damaged.json")
	_check("损坏地图检查点拒绝载入", gateway._write_json(damaged_path, damaged) == OK and gateway._validate_save(damaged_path) == ERR_INVALID_DATA and GlobalState.current_run == original_run)
	GlobalState.unlock_card("1")
	GlobalState.unlock_collection("fragments", "relic-progress")
	GlobalState.complete_achievement("menu-achievement")
	GlobalState.set_setting("music", 0.4)
	GlobalState.current_run.gold = 17
	GlobalState.current_run.items.append({"item_id":"old-run-only", "kind":"potion", "potion":0})
	var starter_items: Array = menu._new_run_config().get("initial_items", [])
	menu.get_node("按钮列/新游戏").pressed.emit()
	menu.get_node("确认弹窗/面板/按钮行/确定").pressed.emit()
	await _frames()
	view = get_tree().current_scene
	_check("确认覆盖后新局身份改变且旧局记入历史", GlobalState.current_run.run_id != run_id and GlobalState.run_history.size() == 1 and GlobalState.run_history[0].result == "abandoned")
	_check("覆盖保留成就/解锁/设置，清空旧节点和旧物资并重建配置初始物品", GlobalState.unlocked_cards.has("1") and GlobalState.unlocked_fragments.has("relic-progress") and GlobalState.achievements.has("menu-achievement") and GlobalState.settings.music == 0.4 and GlobalState.current_run.gold == 0 and _json(GlobalState.current_run.items) == _json(starter_items) and view.session.completed.is_empty())
	var replacement_id := GlobalState.current_run.run_id
	view._return_to_menu()
	await _frames()
	menu = get_tree().current_scene
	_check("冷启动尚未继续时也能发现未完成游戏", gateway.load_current() == OK and gateway.current_run() == null and gateway.has_continuable_run())
	menu.get_node("按钮列/新游戏").pressed.emit()
	_check("冷启动新游戏仍须确认且未改写存档", menu.get_node("确认弹窗").visible and gateway._read_json(gateway.save_path).data.active_run.run_snapshot.run_id == replacement_id)
	menu.get_node("确认弹窗/面板/按钮行/确定").pressed.emit()
	await _frames()
	view = get_tree().current_scene
	_check("冷启动确认覆盖同样成功并保留两局历史", view.scene_file_path == ENTRY and gateway.current_run().run_id != replacement_id and GlobalState.run_history.size() == 2)
	view._return_to_menu()
	await _frames()
	_check_legacy_migration(gateway._read_json(gateway.save_path).data)
	menu = get_tree().current_scene
	_check("正常弃局后没有未完成游戏", gateway.abandon_run() == OK and not gateway.has_continuable_run())
	menu.get_node("按钮列/新游戏").pressed.emit()
	await _frames()
	view = get_tree().current_scene
	_check("已结束游戏后新开无需覆盖确认", view.scene_file_path == ENTRY and gateway.current_run() != null and gateway.current_run().active)
	view._return_to_menu()
	await _frames()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/main_menu_preview.png")
	_finish()


func _check_legacy_migration(data: Dictionary) -> void:
	var migration: Node = load("res://autoload/save_gateway.gd").new()
	for selected: int in [1, 2, 3]:
		var root := fixture_root.path_join("legacy-%d" % selected)
		var source := root.path_join("spotlight_save.json" if selected == 1 else "save/slot%d.json" % selected)
		var legacy := data.duplicate(true)
		legacy.settings["migration_marker"] = selected
		gateway._write_json(source, legacy)
		gateway._write_json(root.path_join("save/menu_profile.json"), {"active_slot": selected})
		migration.save_path = root.path_join("save/game.json")
		var migration_error: Error = migration._migrate_legacy_save(root)
		var migrated: Dictionary = gateway._read_json(migration.save_path).data
		_check("旧布局%d可一次性迁移为单存档且原文件保留" % selected, migration_error == OK and migrated.get("settings", {}).get("migration_marker") == selected and FileAccess.file_exists(source))
		legacy.settings["migration_marker"] = 99
		gateway._write_json(source, legacy)
		_check("已有新存档后不再重读旧布局%d" % selected, migration._migrate_legacy_save(root) == OK and gateway._read_json(migration.save_path).data.get("settings", {}).get("migration_marker") == selected)
	var bad_root := fixture_root.path_join("legacy-invalid")
	gateway._write_json(bad_root.path_join("spotlight_save.json"), {"invalid": true})
	migration.save_path = bad_root.path_join("save/game.json")
	_check("损坏旧存档不静默迁移或覆盖", migration._migrate_legacy_save(bad_root) == ERR_INVALID_DATA and not FileAccess.file_exists(migration.save_path))
	migration.free()


func _frames() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await preload("res://tests/support/presentation_test_helper.gd").map_ready(get_tree())


func _json(value: Variant) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(value)))


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["通过" if passed else "失败", label])


func _finish() -> void:
	print("开始界面整合全部通过" if failures == 0 else "开始界面整合失败 %d 项" % failures)
	get_tree().quit(failures)

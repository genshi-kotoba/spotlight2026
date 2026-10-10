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
	# 所有写盘和删除只落在本轮唯一的 .godot 夹具目录，不碰用户档案/典籍。
	fixture_root = "res://.godot/menu-integration-%d" % Time.get_ticks_usec()
	gateway.profile_path = fixture_root.path_join("profile.json")
	gateway.slot_paths.assign([fixture_root.path_join("slot1.json"), fixture_root.path_join("slot2.json"), fixture_root.path_join("slot3.json")])
	gateway._active_slot = 1
	_check("隔离存档可载入", gateway._load_slot(1) == OK)
	var menu: Control = load(MENU).instantiate()
	get_tree().root.add_child(menu)
	# 测试节点保持 root 兄弟节点，真实换场景时不销毁测试协程。
	get_tree().current_scene = menu
	await _frames()
	_check("空档案不能继续但能开新局", menu.get_node("按钮列/继续游戏").disabled and not menu.get_node("按钮列/新游戏").disabled)
	_check("七个主菜单按钮包含图鉴", menu.get_node("按钮列").get_child_count() == 7 and menu.get_node("档案").text.contains("1"))
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
	_check("不绕过 main 的解锁/初始牌组规则", GlobalState.current_run.deck.is_empty() and GlobalState.unlocked_cards.is_empty())
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
	var saved: Dictionary = gateway._read_json(gateway.slot_path(1)).data
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
	_check("冷启动式重新载入当前档", gateway._load_slot(1) == OK and GlobalState.current_run == null)
	_check("未点击继续时保存/切档仍保留地图", gateway.save_current() == OK and gateway._read_json(gateway.slot_path(1)).data.has("menu_map_checkpoint"))
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
	menu.get_node("确认弹窗/面板/按钮行/取消").pressed.emit()
	_check("取消覆盖不改动本局", not menu.get_node("确认弹窗").visible and GlobalState.current_run.run_id == run_id)
	menu.get_node("档案").pressed.emit()
	await _frames()
	var profile: Control = get_tree().current_scene
	_check("档案页面读取空/进行中三档", profile.slot_info(1).state == "active" and profile.slot_info(2).state == "empty" and profile.get_node("卡片行").get_child_count() == 3)
	profile.select_slot(2)
	profile.get_node("按钮行/切换档案").pressed.emit()
	await _frames()
	menu = get_tree().current_scene
	_check("切换空档不继承上一局且索引持久化", gateway.get_active_slot() == 2 and not gateway.has_continuable_run() and gateway._read_json(gateway.profile_path).data.active_slot == 2)
	_check("第一档继续数据未丢失", gateway.read_slot(1).state == "active")
	var damaged: Dictionary = gateway._read_json(gateway.slot_path(1)).data.duplicate(true)
	damaged.menu_map_checkpoint.snapshot["generator_version"] = "invalid-test-version"
	_check("损坏夹具写在隔离目录", gateway._write_json(gateway.slot_path(3), damaged) == OK)
	_check("损坏地图检查点拒绝切换，当前档不变", gateway.set_active_slot(3) == ERR_INVALID_DATA and gateway.get_active_slot() == 2)
	# 回到第一档，确认覆盖通过 main 的弃局逻辑保留历史。
	_check("切回原档", gateway.set_active_slot(1) == OK)
	menu.get_node("按钮列/新游戏").pressed.emit()
	menu.get_node("确认弹窗/面板/按钮行/确定").pressed.emit()
	await _frames()
	view = get_tree().current_scene
	_check("确认覆盖后新局身份改变且旧局记入历史", GlobalState.current_run.run_id != run_id and GlobalState.run_history.size() == 1 and GlobalState.run_history[0].result == "abandoned")
	view._return_to_menu()
	await _frames()
	# 写盘失败不换场景，不覆盖已保存数据。
	menu = get_tree().current_scene
	var original_profile_path: String = gateway.profile_path
	gateway.profile_path = "res://project.godot/menu-index.json"
	_check("索引写盘失败不切换档案", gateway.set_active_slot(3) != OK and gateway.get_active_slot() == 1)
	gateway.profile_path = original_profile_path
	menu.get_node("档案").pressed.emit()
	await _frames()
	profile = get_tree().current_scene
	profile.select_slot(1)
	profile.get_node("按钮行/删除存档").pressed.emit()
	_check("删除前需要确认，文件仍存在", profile.get_node("确认弹窗").visible and FileAccess.file_exists(gateway.slot_path(1)))
	profile.get_node("确认弹窗/面板/按钮行/取消").pressed.emit()
	_check("取消删除保留进行中的局", gateway.has_continuable_run())
	profile.get_node("按钮行/删除存档").pressed.emit()
	profile.get_node("确认弹窗/面板/按钮行/确定").pressed.emit()
	_check("确认删除清除内存与继续入口", not gateway.has_continuable_run() and GlobalState.current_run == null and not FileAccess.file_exists(gateway.slot_path(1)))
	var archives := DirAccess.open(fixture_root.path_join("deleted"))
	_check("删除档案保留可恢复备份", archives != null and archives.get_files().size() > 0)
	profile.get_node("按钮行/返回").pressed.emit()
	await _frames()
	menu = get_tree().current_scene
	_check("档案页面可不切换直接返回", menu.scene_file_path == MENU and menu.get_node("按钮列/继续游戏").disabled)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/main_menu_preview.png")
	_finish()


func _frames() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _json(value: Variant) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(value)))


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["通过" if passed else "失败", label])


func _finish() -> void:
	print("开始界面整合全部通过" if failures == 0 else "开始界面整合失败 %d 项" % failures)
	get_tree().quit(failures)

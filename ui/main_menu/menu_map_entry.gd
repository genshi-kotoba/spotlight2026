extends "res://ui/world_map/relief_2d/map_exploration.gd"

## 正式业务入口；2.5D 只负责显示，战斗、奖励、商店和存档保持同一接线。
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"
var _gateway: Node
var _saved_entry_state: Dictionary = {}
var _reward_popup: LootPopup
var _shop_popup: ShopPopup

# PRG-002 已经安装了真实随机快照；地图恢复仅验证同一个快照，不能再次安装
# SeedService，否则会使 main 的战斗/奖励等已经持有的 RandomStream 失效。
class ExistingSeedSource extends RefCounted:
	func get_main_seed() -> String:
		return SeedService.get_main_seed()
	func get_stream(domain: StringName, ids: Array, occurrence: int = 0) -> RandomStream:
		return SeedService.get_stream(domain, ids, occurrence)
	func begin_run(_seed: String = "") -> String:
		return ""
	func capture_snapshot() -> Dictionary:
		return SeedService.capture_snapshot()
	func restore_snapshot(snapshot: Dictionary) -> Error:
		# JSON 读盘把整数变成浮点；比较前双方都做相同的 JSON 规范化。
		var saved: Variant = JSON.parse_string(JSON.stringify(snapshot))
		var current: Variant = JSON.parse_string(JSON.stringify(SeedService.capture_snapshot()))
		return OK if JSON.stringify(saved) == JSON.stringify(current) else ERR_INVALID_DATA


func _ready() -> void:
	_gateway = get_node("/root/SaveGateway")
	# F6 直接运行任一地图入口时也经过真实局内状态，不再落到无接线的 demo。
	# 已有进行中的档案只能继续，绝不能用默认种子覆盖它。
	if not _ensure_active_run():
		set_process(false)
		set_physics_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)
		SceneTransition.call_deferred("change_scene_to_file", MENU_SCENE)
		return
	MapEvents.node_interaction_requested.connect(_on_world_node_requested)
	super._ready()
	if not _saved_entry_state.is_empty():
		load_map(_map_snapshot, _saved_entry_state)
		if not session.pending.is_empty() and demo_interactions_enabled and _uses_demo_dialog(session.pending):
			_dialog_request_id = str(session.pending.request_id)
			_configure_node_dialog(session.pending)
	if not EncounterFlow.bind_map(self):
		_show_toast(EncounterFlow.last_error)
		return
	# 兼容旧版已完成 Boss 的地图：正式进度自动转入下一层。
	if EncounterFlow.session.map_id != session.map_id:
		var entry: Dictionary = map_run.get_floor(map_run.current_floor)
		load_map(entry.snapshot, entry.state)
		EncounterFlow.session = session
	if not RunRewards.pending(_gateway.current_run()).is_empty() and _gateway.current_run().current_battle == null:
		call_deferred("_show_pending_rewards")
	elif session.pending.get("type") == "shop":
		call_deferred("_show_shop", session.pending.duplicate(true))
	elif session.pending.get("type") == "event":
		call_deferred("_show_random_event")
	elif EncounterFlow.waiting_for_fourth_floor():
		_show_fourth_floor_notice()
	# 放弃本局的二次确认在设置面板里完成，这里只负责落地。
	# 冒险菜单设置页里的三个动作：存档、回主菜单、退出都走存档网关。
	_run_menu.abandon_requested.connect(_on_menu_abandon)
	_run_menu.return_to_menu_requested.connect(_return_to_menu)
	_run_menu.quit_requested.connect(_on_menu_quit)
	# 第一张地图生成后即留下完整检查点；原 F6 地图 Demo 仍不受此装配层影响。
	if map_run != null and map_run.current_floor > 0:
		_save_run()

func _ensure_active_run() -> bool:
	if _gateway.current_run() != null:
		return true
	if _gateway.has_continuable_run():
		return _gateway.continue_saved_run() == OK
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(_run_settings_path()))
	if not parsed is Dictionary or not settings is Dictionary:
		push_error("地图入口的新局配置无法读取")
		return false
	var config: Dictionary = parsed.duplicate(true)
	config["run_id"] = "map-entry-%d-%d" % [Time.get_ticks_usec(), randi()]
	return _gateway.start_new_run(str(settings.get("seed", "")), config) == OK


func _initial_snapshot() -> Dictionary:
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(_run_settings_path()))
	if not settings is Dictionary or not settings.get("floors") is Array:
		return {}
	_floor_configs = settings.floors.duplicate(true)
	map_run = Run.new(ExistingSeedSource.new(), str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	var saved: Dictionary = _gateway.map_checkpoint()
	var run: RunStateMachine = _gateway.current_run()
	if run == null:
		return {}
	if not saved.is_empty():
		if not map_run.restore_snapshot(saved):
			session.last_error = "地图存档无法恢复：" + map_run.last_error
			return {}
		if not _enable_monster_assignments():
			return {}
		var entry: Dictionary = map_run.get_floor(map_run.current_floor)
		_saved_entry_state = entry.get("state", {}).duplicate(true)
		return entry.get("snapshot", {})
	if not map_run.attach_existing_run(_floor_configs):
		return {}
	if not _enable_monster_assignments():
		return {}
	var floor_index := run.map_ids.find(run.current_map_id) + 1
	var entry: Dictionary = map_run.enter_floor(maxi(1, floor_index))
	return entry.get("snapshot", {})

func _enable_monster_assignments() -> bool:
	var policy = preload("res://systems/map/flat_2d/monster_encounters.gd")
	var roster: Array = policy.roster_from_catalog(TextCatalog.entries("monsters"))
	if not map_run.enable_encounters(roster):
		session.last_error = map_run.last_error
		return false
	return true

func _uses_demo_dialog(request: Dictionary) -> bool:
	return request.get("type") not in ["battle", "elite", "boss", "shop", "event"]

func _on_world_node_requested(request: Dictionary) -> void:
	if request.get("map_id") != session.map_id or _uses_demo_dialog(request):
		return
	# 不在地图提示或确认框中展示 content_id、名称、头像。
	EncounterFlow.session = session
	ScenePreloader.prioritize_node(session.map_id, str(request.node_id))
	if request.get("type") == "event":
		_show_random_event()
		return
	if request.get("type") == "shop":
		_show_shop(request)
		return
	if not EncounterFlow.begin_encounter(request):
		_show_toast(EncounterFlow.last_error)

func _interact() -> void:
	if not RunRewards.pending(_gateway.current_run()).is_empty():
		_show_pending_rewards()
		return
	if EncounterFlow.waiting_for_fourth_floor():
		_show_toast("前三层已完成，第四层暂未开放")
		return
	if not session.pending.is_empty() and _gateway.current_run().current_battle != null:
		if _gateway.save_current() == OK:
			EncounterFlow.open_battle()
		return
	super._interact()

func _update_selection() -> void:
	super._update_selection()
	if not _selected.is_empty():
		ScenePreloader.prioritize_node(session.map_id, _selected)

func _show_shop(request: Dictionary) -> void:
	if is_instance_valid(_shop_popup):
		return
	_set_paused(true)
	_shop_popup = ShopPopup.new()
	add_child(_shop_popup)
	_shop_popup.close_handler = _close_shop
	_shop_popup.show_shop(request)

func _show_random_event() -> void:
	if _gateway.save_current() != OK:
		_show_toast("事件进入前保存失败，请重试")
		return
	var error := SceneTransition.change_scene_to_file(RandomEventCatalog.SCENE)
	if error != OK: _show_toast("打开随机事件失败：%d" % error)

func _close_shop() -> Error:
	var old_state: Dictionary = session.capture_state()
	var pending: Dictionary = session.pending.duplicate(true)
	if pending.get("type") != "shop" or not session.resolve_request({"request_id": pending.request_id, "status": "completed"}):
		return ERR_INVALID_DATA
	var error: Error = _gateway.save_current()
	if error != OK:
		session.restore_state(old_state)
		# restore_state 会更新回调令牌，弹窗必须同步。
		_shop_popup.request = session.pending.duplicate(true)
		return error
	_sync_view()
	_sync_actor()
	MapEvents.map_state_changed.emit(session.map_id, session.capture_state())
	MapEvents.node_interaction_resolved.emit(str(pending.request_id), str(pending.node_id), "completed")
	_set_paused(false)
	return OK

func _handle_menu_hotkeys(event: InputEvent) -> bool:
	if is_instance_valid(_shop_popup) or is_instance_valid(_reward_popup):
		return false
	return super._handle_menu_hotkeys(event)

func _show_pending_rewards() -> void:
	if is_instance_valid(_reward_popup):
		return
	_set_paused(true)
	_reward_popup = LootPopup.new()
	add_child(_reward_popup)
	_reward_popup.finished.connect(_on_rewards_closed, CONNECT_DEFERRED)
	_reward_popup.show_rewards()

func _on_rewards_closed() -> void:
	_set_paused(false)
	if EncounterFlow.waiting_for_fourth_floor():
		_show_fourth_floor_notice()

func _reset_map() -> void:
	_show_toast("正式冒险不重置节点；同一种子的敌人和已完成进度均保留")

func _refresh_run_controls() -> void:
	super._refresh_run_controls()
	_previous.hide()
	_next.hide()
	if map_run != null and map_run.current_floor > 0:
		_floor_label.text = "第 %d / 4 层 · 击败 BOSS 自动前往下一层" % map_run.current_floor

func _show_fourth_floor_notice() -> void:
	_set_paused(true)
	var notice := AcceptDialog.new()
	notice.title = "前三层已完成"
	notice.dialog_text = "已击败第三层 BOSS。\n第四层暂未制作，本局进度已保留；这还不是全游戏通关。"
	notice.ok_button_text = "留在地图"
	CommonUiSkin.style_dialog(notice)
	add_child(notice)
	notice.popup_centered(Vector2i(660, 220))


func capture_menu_checkpoint() -> Dictionary:
	if map_run == null or map_run.current_floor <= 0:
		return {}
	return map_run.capture_snapshot(capture_state())


func _save_run() -> void:
	var error: Error = _gateway.save_current()
	_show_toast("本局已保存到当前档案" if error == OK else "保存失败：%d" % error)


func _build_run_controls() -> void:
	# 换层控件并入右下信息面板；档案存盘由存档网关负责。
	super._build_run_controls()


func _on_menu_abandon() -> void:
	var error: Error = _gateway.abandon_run()
	if error != OK:
		_show_toast("放弃本局失败：%d" % error)
		return
	_return_to_menu()


func _on_menu_quit() -> void:
	_gateway.save_current()
	_gateway.quit_game()


func _return_to_menu() -> void:
	if not session.pending.is_empty():
		_show_toast("请先完成或取消当前节点")
		return
	if _gateway.save_current() != OK:
		_show_toast("保存失败，仍留在当前地图")
		return
	var error := SceneTransition.change_scene_to_file(MENU_SCENE)
	if error != OK:
		_show_toast("返回开始界面失败：%d" % error)


func _change_floor(index: int) -> void:
	_show_toast("正式冒险在击败本层 BOSS 后自动换层（请求：%d）" % index)

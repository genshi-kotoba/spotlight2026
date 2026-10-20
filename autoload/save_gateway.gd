extends Node

## 开始界面的适配层。局内状态/随机/解锁仍以 main 的 GlobalState 为准。
## 地图检查点是存档顶层可选扩展，不修改状态机或伪造 active_run。
signal save_changed
signal save_reloaded
signal run_started
signal run_continued
signal save_failed(error: int, message: String)

const MAP_KEY := "menu_map_checkpoint"
const PlanarRun := preload("res://state_machines/run/planar_map_run.gd")

var save_path := GlobalStateMachine.DEFAULT_SAVE_PATH
var _state: GlobalStateMachine
var _map_checkpoint: Dictionary = {}
var _map_view: WeakRef
var _load_error: Error = OK
var _closing := false
var _error_notice := ""


func _ready() -> void:
	_state = get_node("/root/GlobalState") as GlobalStateMachine
	_state.save_on_window_close = false
	_state.save_failed.connect(_forward_error)
	get_tree().auto_accept_quit = false
	_load_error = _migrate_legacy_save()
	if _load_error == OK:
		_load_error = load_current()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _closing:
		# 窗口关闭只安装一次含地图的完整存档，失败则留在游戏内。
		_closing = true
		call_deferred("quit_game")


func startup_notice() -> String:
	return _error_notice if _load_error != OK else ""


func has_continuable_run() -> bool:
	return _load_error == OK and _state.has_continuable_run()


func start_new_run(seed_text: String, config: Dictionary, overwrite_confirmed := false) -> Error:
	if _load_error != OK:
		return _fail(_load_error, "存档读取失败，原文件已保留，请修复存档后重试。")
	if has_continuable_run() and not overwrite_confirmed:
		return _fail(ERR_ALREADY_IN_USE, "已有未完成的游戏，请先确认覆盖。")
	var error := _ensure_parent(save_path)
	if error != OK:
		return _fail(error, "无法创建存档目录。")
	# 先在独立随机上下文中准备并验证新局，避免配置错误或写盘失败损毁原局。
	var version := str(ProjectSettings.get_setting("application/config/seed_content_version", ""))
	var random := SeedRegistry.new(version)
	var prepared := RunStateMachine.new()
	error = prepared.initialize_new(seed_text, config, _state.unlocked_cards, random)
	if error != OK:
		prepared.free()
		return _fail(error, "新游戏初始化失败，原存档与进度保持不变。")
	var data := _state.capture_save_data()
	if data.is_empty():
		prepared.free()
		return _fail(_state.last_error, "无法读取原游戏状态，未覆盖存档。")
	var previous: Variant = data.get("active_run")
	if previous is Dictionary and previous.get("run_snapshot") is Dictionary:
		data.run_history.append(RunStateMachine.history_record_from_snapshot(previous.run_snapshot, {"status": "abandoned"}))
	data["active_run"] = {"run_snapshot": prepared.to_dictionary(), "seed_snapshot": random.capture_snapshot()}
	var validator := GlobalStateMachine.new()
	error = validator._install_save(data)
	validator.free()
	if error == OK:
		error = _write_json(save_path, data)
	if error != OK:
		prepared.free()
		return _fail(error, "新游戏保存失败，原存档与进度保持不变。")
	_state.save_path = save_path
	error = _state.install_prepared_run(data, prepared)
	if error != OK:
		prepared.free()
		return _fail(error, "新游戏已保存，但内存载入失败，请重新启动游戏。")
	_map_checkpoint.clear()
	_map_view = null
	run_started.emit()
	save_changed.emit()
	return OK


func continue_saved_run() -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "没有可继续的游戏。")
	# 保存并返回菜单后，本局仍在内存中；不能再次恢复/重置随机流。
	if _state.run_active and _state.current_run != null:
		run_continued.emit()
		return OK
	var error := _state.continue_saved_run()
	if error == OK:
		run_continued.emit()
	return error


func abandon_run() -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "没有进行中的游戏。")
	if _state.current_run == null:
		var error := continue_saved_run()
		if error != OK:
			return error
	_map_view = null
	_map_checkpoint.clear()
	var error := _state.abandon_current_run()
	if error == OK:
		error = _state.last_error
	if error == OK:
		save_changed.emit()
	return error


func bind_map_view(view: Node) -> void:
	_map_view = weakref(view)


func map_checkpoint() -> Dictionary:
	return _map_checkpoint.duplicate(true)


func current_run() -> RunStateMachine:
	return _state.current_run


func save_current() -> Error:
	if _load_error != OK:
		return _fail(_load_error, "存档有读取错误，拒绝覆盖。")
	var run := _state.current_run
	if run != null and run.current_battle != null and not bool(run.current_battle.to_dictionary().queue_idle):
		return _fail(ERR_BUSY, "战斗结算中暂不能保存，请先完成操作。")
	var view: Node = _map_view.get_ref() if _map_view != null else null
	var checkpoint := _map_checkpoint.duplicate(true)
	if is_instance_valid(view) and run != null:
		checkpoint = view.capture_menu_checkpoint()
		if checkpoint.is_empty():
			return _fail(ERR_INVALID_DATA, "地图检查点捕获失败，未覆盖存档。")
	if not checkpoint.is_empty() and run != null:
		checkpoint["seed_snapshot"] = SeedService.capture_snapshot()
	var path := save_path
	var error := _ensure_parent(path)
	if error != OK:
		return _fail(error, "无法创建存档目录。")
	# 状态机序列化原有字段，网关附上地图后只原子写入一次完整存档。
	var prepared := _state.build_save_payload()
	if prepared.error != OK:
		return _fail(prepared.error, "存档状态捕获失败，原文件已保留。")
	var data: Dictionary = prepared.payload
	# 尚未点击继续时 current_run 为 null，但磁盘仍有进行中的局；不能丢掉它的地图。
	var saved_active: Variant = data.get("active_run")
	if not checkpoint.is_empty() and saved_active is Dictionary and saved_active.get("run_snapshot") is Dictionary:
		data[MAP_KEY] = {"run_id": saved_active.run_snapshot.run_id, "snapshot": checkpoint}
	error = _write_json(path, data)
	if error != OK:
		return _fail(error, "保存失败，原存档已保留。")
	_map_checkpoint = checkpoint
	_state.last_error = OK
	save_changed.emit()
	return OK


func quit_game() -> void:
	var error := save_current()
	if error != OK:
		_closing = false
		return
	get_tree().quit()


func _validate_save(path: String) -> Error:
	var candidate := GlobalStateMachine.new()
	candidate.save_path = path
	var error := candidate.load_save()
	candidate.free()
	if error != OK:
		return error
	var loaded := _read_json(path)
	if loaded.error == ERR_FILE_NOT_FOUND:
		return OK
	if loaded.error != OK:
		return loaded.error
	var extension: Variant = loaded.data.get(MAP_KEY)
	var node_loot: Variant = {}
	var active_data: Variant = loaded.data.get("active_run")
	if active_data is Dictionary and active_data.get("run_snapshot") is Dictionary:
		if not RunRewards.valid_items(active_data.run_snapshot.get("items")): return ERR_INVALID_DATA
		var inventory: Variant = active_data.run_snapshot.get("inventory_state", {})
		if not inventory is Dictionary or not RunStateMachine._valid_inventory_state(inventory): return ERR_INVALID_DATA
		var saved_battle: Variant = active_data.run_snapshot.get("current_battle")
		if saved_battle != null:
			if not saved_battle is Dictionary or not saved_battle.get("player") is Dictionary \
					or not BattleStateMachine._valid_player(saved_battle.player): return ERR_INVALID_DATA
		node_loot = inventory.get("node_loot", {})
		if not RunNodeLoot.valid_records(node_loot): return ERR_INVALID_DATA
	if extension != null:
		var active: Variant = loaded.data.get("active_run")
		if not extension is Dictionary or not extension.get("snapshot") is Dictionary \
				or not active is Dictionary or not active.get("run_snapshot") is Dictionary \
				or extension.get("run_id") != active.run_snapshot.get("run_id"):
			return ERR_INVALID_DATA
		var version := str(ProjectSettings.get_setting("application/config/seed_content_version", ""))
		var candidate_map := PlanarRun.new(SeedRegistry.new(version), version)
		if not candidate_map.restore_snapshot(extension.snapshot) or candidate_map.current_floor <= 0:
			return ERR_INVALID_DATA
		if JSON.stringify(extension.snapshot.get("seed_snapshot")) != JSON.stringify(active.get("seed_snapshot")):
			return ERR_INVALID_DATA
		if not RunNodeLoot.valid_map_records(node_loot, extension.snapshot.floors):
			return ERR_INVALID_DATA
	elif not node_loot.is_empty():
		return ERR_INVALID_DATA
	return OK


func load_current() -> Error:
	var error := _validate_save(save_path)
	if error != OK:
		_load_error = error
		return _fail(error, "存档读取失败，原文件不会被覆盖。")
	var old_run := _state.current_run
	var previous_path := _state.save_path
	_state.save_path = save_path
	error = _state.load_save()
	if error != OK:
		_state.save_path = previous_path
		return error
	if is_instance_valid(old_run):
		old_run.queue_free()
	_map_view = null
	_map_checkpoint.clear()
	var loaded := _read_json(save_path)
	if loaded.error == OK:
		var extension: Dictionary = loaded.data.get(MAP_KEY, {})
		_map_checkpoint = extension.get("snapshot", {}).duplicate(true)
	_load_error = OK
	_error_notice = ""
	save_reloaded.emit()
	save_changed.emit()
	return OK


## 仅首次升级读取旧布局；不保留多槽位接口，也不删除玩家的旧存档。
func _migrate_legacy_save(legacy_root := "user://") -> Error:
	if FileAccess.file_exists(save_path):
		return OK
	var source := legacy_root.path_join("spotlight_save.json")
	var profile := _read_json(legacy_root.path_join("save/menu_profile.json"))
	if profile.error == OK:
		var selected: Variant = profile.data.get("active_slot", 1)
		if (selected is int or selected is float) and float(selected) == floorf(float(selected)) and int(selected) in [2, 3]:
			source = legacy_root.path_join("save/slot%d.json" % int(selected))
	if not FileAccess.file_exists(source):
		return OK
	var error := _validate_save(source)
	if error != OK:
		return _fail(error, "旧存档无法迁移，原文件已保留，未创建新存档。")
	var loaded := _read_json(source)
	error = _write_json(save_path, loaded.data)
	if error != OK:
		return _fail(error, "旧存档迁移保存失败，原文件已保留。")
	return OK


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": ERR_FILE_NOT_FOUND, "data": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": FileAccess.get_open_error(), "data": {}}
	var data: Variant = JSON.parse_string(file.get_as_text())
	return {"error": OK, "data": data} if data is Dictionary else {"error": ERR_PARSE_ERROR, "data": {}}


func _ensure_parent(path: String) -> Error:
	return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))


func _write_json(path: String, data: Dictionary) -> Error:
	var error := _ensure_parent(path)
	if error != OK:
		return error
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	error = file.get_error()
	file = null
	if error != OK:
		return error
	var backup := path + ".bak"
	if FileAccess.file_exists(backup):
		error = DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
		if error != OK:
			return error
	if FileAccess.file_exists(path):
		error = DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(backup))
		if error != OK:
			return error
	error = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))
	if error != OK and FileAccess.file_exists(backup):
		DirAccess.rename_absolute(ProjectSettings.globalize_path(backup), ProjectSettings.globalize_path(path))
	return error


func _forward_error(error: int, message: String) -> void:
	_error_notice = message
	save_failed.emit(error, message)


func _fail(error: Error, message: String) -> Error:
	_error_notice = message
	save_failed.emit(error, message)
	return error

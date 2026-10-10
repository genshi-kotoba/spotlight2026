extends Node

## 开始界面的适配层。局内状态/随机/解锁仍以 main 的 GlobalState 为准。
## 地图检查点是存档顶层可选扩展，不修改状态机或伪造 active_run。
signal slots_refreshed
signal active_slot_changed(slot: int)
signal run_started(slot: int)
signal run_continued(slot: int)
signal save_failed(error: int, message: String)

const SLOT_COUNT := 3
const PROFILE_PATH := "user://save/menu_profile.json"
const MAP_KEY := "menu_map_checkpoint"
const PlanarRun := preload("res://state_machines/run/planar_map_run.gd")

var profile_path := PROFILE_PATH
var slot_paths: Array[String] = [GlobalStateMachine.DEFAULT_SAVE_PATH,
	"user://save/slot2.json", "user://save/slot3.json"]
var _state: GlobalStateMachine
var _active_slot := 1
var _map_checkpoint: Dictionary = {}
var _map_view: WeakRef
var _load_error: Error = OK
var _closing := false
var _error_notice := ""


func _ready() -> void:
	_state = get_node("/root/GlobalState") as GlobalStateMachine
	_state.save_failed.connect(_forward_error)
	get_tree().auto_accept_quit = false
	var profile := _read_json(profile_path)
	if profile.error == OK:
		var slot: Variant = profile.data.get("active_slot", 1)
		if (slot is int or slot is float) and float(slot) == floorf(float(slot)):
			_active_slot = clampi(int(slot), 1, SLOT_COUNT)
	_load_error = _load_slot(_active_slot)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _closing:
		# GlobalState 的原退出通知先完成；随后保存含地图的完整检查点再退出。
		_closing = true
		call_deferred("quit_game")


func slot_path(slot: int) -> String:
	return slot_paths[slot - 1] if slot >= 1 and slot <= SLOT_COUNT else ""


func get_active_slot() -> int:
	return _active_slot


func startup_notice() -> String:
	return _error_notice if _load_error != OK else ""


func list_slots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot in range(1, SLOT_COUNT + 1):
		result.append(read_slot(slot))
	return result


func read_slot(slot: int) -> Dictionary:
	var info := {"slot": slot, "exists": false, "state": "empty", "region": "",
		"health": 0, "max_health": 0, "gold": 0, "progress": 0,
		"run_count": 0, "updated_at": ""}
	var path := slot_path(slot)
	if path.is_empty() or not FileAccess.file_exists(path):
		return info
	info.exists = true
	var loaded := _read_json(path)
	if loaded.error != OK:
		info.state = "ended"
		info.region = "存档读取失败"
		return info
	var data: Dictionary = loaded.data
	var history: Variant = data.get("run_history", [])
	info.run_count = history.size() if history is Array else 0
	var active: Variant = data.get("active_run")
	var run: Variant = active.get("run_snapshot") if active is Dictionary else null
	if run is Dictionary and bool(run.get("active", false)):
		info.state = "active"
		info.region = str(run.get("current_map_id", ""))
		info.health = int(run.get("health", 0))
		info.max_health = int(run.get("max_health", 0))
		info.gold = int(run.get("gold", 0))
	else:
		info.state = "ended"
	info.updated_at = Time.get_datetime_string_from_unix_time(FileAccess.get_modified_time(path))
	return info


func has_continuable_run() -> bool:
	return _load_error == OK and _state.has_continuable_run()


func start_new_run(seed_text: String, config: Dictionary) -> Error:
	if _load_error != OK:
		return _fail(_load_error, "当前档案读取失败，请切换其他档案或确认删除后再开局。")
	if has_continuable_run():
		return _fail(ERR_ALREADY_IN_USE, "当前档案已有进行中的局，请先确认覆盖。")
	var error := _ensure_parent(slot_path(_active_slot))
	if error != OK:
		return _fail(error, "无法创建存档目录。")
	_map_checkpoint.clear()
	_map_view = null
	error = _state.start_new_run(seed_text, config)
	if error == OK:
		run_started.emit(_active_slot)
		slots_refreshed.emit()
	return error


func continue_saved_run() -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "当前档案没有可继续的局。")
	# 保存并返回菜单后，本局仍在内存中；不能再次恢复/重置随机流。
	if _state.run_active and _state.current_run != null:
		run_continued.emit(_active_slot)
		return OK
	var error := _state.continue_saved_run()
	if error == OK:
		run_continued.emit(_active_slot)
	return error


func abandon_run() -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "当前档案没有进行中的局。")
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
		slots_refreshed.emit()
	return error


func set_active_slot(slot: int) -> Error:
	if slot < 1 or slot > SLOT_COUNT:
		return _fail(ERR_INVALID_PARAMETER, "档号必须在 1 到 3 之间。")
	if slot == _active_slot:
		return OK
	if _load_error == OK:
		var error := save_current()
		if error != OK:
			return error
	# 先验证目标，不因错误存档破坏当前内存状态。
	var error := _validate_slot(slot)
	if error != OK:
		return _fail(error, "目标档案无法读取，当前档案保持不变。")
	error = _write_json(profile_path, {"active_slot": slot})
	if error != OK:
		return _fail(error, "当前档案索引保存失败。")
	error = _load_slot(slot)
	if error != OK:
		_write_json(profile_path, {"active_slot": _active_slot})
		return error
	_active_slot = slot
	active_slot_changed.emit(slot)
	slots_refreshed.emit()
	return OK


func delete_slot(slot: int) -> Error:
	var path := slot_path(slot)
	if path.is_empty():
		return _fail(ERR_INVALID_PARAMETER, "无效的档号。")
	# 用户确认删除后移至可恢复目录，不丢弃原 JSON 与备份。
	var archive := path.get_base_dir().path_join("deleted")
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(archive))
	if error != OK:
		return _fail(error, "无法创建已删除档案备份目录。")
	var moved: Array[Dictionary] = []
	var suffix := ".%d-%d.deleted" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	for candidate: String in [path, path + ".bak", path + ".tmp"]:
		if not FileAccess.file_exists(candidate):
			continue
		var destination := archive.path_join(candidate.get_file() + suffix)
		error = DirAccess.rename_absolute(ProjectSettings.globalize_path(candidate), ProjectSettings.globalize_path(destination))
		if error != OK:
			for item: Dictionary in moved:
				DirAccess.rename_absolute(item.to, item.from)
			return _fail(error, "删除档案失败，已尝试恢复原文件。")
		moved.append({"from": ProjectSettings.globalize_path(candidate), "to": ProjectSettings.globalize_path(destination)})
	if slot == _active_slot:
		_load_error = _load_slot(slot)
	slots_refreshed.emit()
	return _load_error if slot == _active_slot else OK


func bind_map_view(view: Node) -> void:
	_map_view = weakref(view)


func map_checkpoint() -> Dictionary:
	return _map_checkpoint.duplicate(true)


func current_run() -> RunStateMachine:
	return _state.current_run


func save_current() -> Error:
	if _load_error != OK:
		return _fail(_load_error, "当前档案有读取错误，拒绝覆盖。")
	var run := _state.current_run
	if run != null and run.current_battle != null and not bool(run.current_battle.to_dictionary().queue_idle):
		return _fail(ERR_BUSY, "战斗结算中暂不能保存，请先完成操作。")
	var view: Node = _map_view.get_ref() if _map_view != null else null
	var checkpoint := _map_checkpoint.duplicate(true)
	if is_instance_valid(view):
		checkpoint = view.capture_menu_checkpoint()
		if checkpoint.is_empty():
			return _fail(ERR_INVALID_DATA, "地图检查点捕获失败，未覆盖存档。")
	if not checkpoint.is_empty() and run != null:
		checkpoint["seed_snapshot"] = SeedService.capture_snapshot()
	var path := slot_path(_active_slot)
	var error := _ensure_parent(path)
	if error != OK:
		return _fail(error, "无法创建存档目录。")
	# main 的状态机负责序列化原有字段；先写独立中间件，最后一次原子安装完整文件。
	var staging := path + ".menu-staging"
	var previous_path := _state.save_path
	_state.save_path = staging
	error = _state.save_game()
	_state.save_path = previous_path
	if error != OK:
		return error
	var prepared := _read_json(staging)
	if prepared.error != OK:
		return _fail(prepared.error, "存档中间件读取失败。")
	var data: Dictionary = prepared.data
	# 尚未点击继续时 current_run 为 null，但磁盘仍有进行中的局；不能丢掉它的地图。
	var saved_active: Variant = data.get("active_run")
	if not checkpoint.is_empty() and saved_active is Dictionary and saved_active.get("run_snapshot") is Dictionary:
		data[MAP_KEY] = {"run_id": saved_active.run_snapshot.run_id, "snapshot": checkpoint}
	error = _write_json(path, data)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(staging))
	if error != OK:
		return _fail(error, "保存失败，原存档已保留。")
	_map_checkpoint = checkpoint
	slots_refreshed.emit()
	return OK


func quit_game() -> void:
	var error := save_current()
	if error != OK:
		_closing = false
		return
	get_tree().quit()


func _validate_slot(slot: int) -> Error:
	var candidate := GlobalStateMachine.new()
	candidate.save_path = slot_path(slot)
	var error := candidate.load_save()
	candidate.free()
	if error != OK:
		return error
	var loaded := _read_json(slot_path(slot))
	if loaded.error == ERR_FILE_NOT_FOUND:
		return OK
	if loaded.error != OK:
		return loaded.error
	var extension: Variant = loaded.data.get(MAP_KEY)
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
	return OK


func _load_slot(slot: int) -> Error:
	var error := _validate_slot(slot)
	if error != OK:
		return _fail(error, "档案读取失败，原文件不会被覆盖。")
	var old_run := _state.current_run
	var previous_path := _state.save_path
	_state.save_path = slot_path(slot)
	error = _state.load_save()
	if error != OK:
		_state.save_path = previous_path
		return error
	if is_instance_valid(old_run):
		old_run.queue_free()
	_map_view = null
	_map_checkpoint.clear()
	var loaded := _read_json(slot_path(slot))
	if loaded.error == OK:
		var extension: Dictionary = loaded.data.get(MAP_KEY, {})
		_map_checkpoint = extension.get("snapshot", {}).duplicate(true)
	_load_error = OK
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

class_name GlobalStateMachine
extends Node

## PRG-002：局外设置、JSON 存档与对局历史。
## Autoload 名称为 GlobalState；业务代码不应再实例化第二个常驻全局状态机。

signal save_loaded
signal save_failed(error: Error, message: String)
signal run_started(run: RunStateMachine)
signal run_continued(run: RunStateMachine)
signal run_finished(result: Dictionary)
signal settings_changed(key: String, value: Variant)

const SAVE_VERSION := 1
const DEFAULT_SAVE_PATH := "user://save/game.json"

var save_path := DEFAULT_SAVE_PATH
var settings: Dictionary = {}
var run_history: Array[Dictionary] = []
## 跨局保留的地区首次入场记录；旧版 v1 缺省为空。
var seen_region_titles: Array[String] = []

var current_run: RunStateMachine
var run_active := false
var last_error: Error = OK
## 独立状态机保留自动保存；装配完整地图网关时由网关独占窗口关闭。
var save_on_window_close := true

## 启动时读入、但要等玩家点击“继续游戏”才安装的快照。
var _saved_active_run: Dictionary = {}


func _ready() -> void:
	if preload("res://systems/testing/sandbox_launch.gd").requested():
		save_path = preload("res://systems/testing/sandbox_launch.gd").SAVE_PATH
	load_save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and save_on_window_close:
		save_game()


func has_continuable_run() -> bool:
	return not _saved_active_run.is_empty() or (run_active and current_run != null)


func start_new_run(seed_text: String, config: Dictionary) -> Error:
	if run_active or current_run != null:
		return _fail(ERR_ALREADY_IN_USE, "A run is already active")

	var run := RunStateMachine.new()
	add_child(run)
	_connect_run(run)
	var error := run.initialize_new(seed_text, config)
	if error != OK:
		run.queue_free()
		return _fail(error, "Could not initialize the new run")

	current_run = run
	run_active = true
	_saved_active_run.clear()
	last_error = OK
	run_started.emit(run)
	# 新局一经创建就留下可继续的检查点；不是只等到退出时才第一次写盘。
	return save_game()


func continue_saved_run() -> Error:
	if run_active or current_run != null:
		return _fail(ERR_ALREADY_IN_USE, "A run is already active")
	if _saved_active_run.is_empty():
		return _fail(ERR_DOES_NOT_EXIST, "No saved run is available")

	var seed_snapshot: Variant = _saved_active_run.get("seed_snapshot")
	var run_snapshot: Variant = _saved_active_run.get("run_snapshot")
	if not seed_snapshot is Dictionary or not run_snapshot is Dictionary:
		return _fail(ERR_INVALID_DATA, "Saved run has no valid seed/run snapshots")

	var previous_seed: Dictionary = {}
	if not SeedService.get_main_seed().is_empty():
		previous_seed = SeedService.capture_snapshot()
	var error := SeedService.restore_snapshot(seed_snapshot)
	if error != OK:
		return _fail(error, "Could not restore the random context")

	var run := RunStateMachine.new()
	add_child(run)
	_connect_run(run)
	error = run.restore_from_dictionary(run_snapshot)
	if error != OK:
		run.queue_free()
		if not previous_seed.is_empty():
			SeedService.restore_snapshot(previous_seed)
		return _fail(error, "Could not restore the run state")

	current_run = run
	run_active = true
	last_error = OK
	run_continued.emit(run)
	return OK


## 主动保存检查点；UI 的“保存并返回”与平台退出都调用同一入口。
func save_game() -> Error:
	var prepared := build_save_payload()
	if prepared.error != OK:
		return _fail(prepared.error, "Could not capture save state")
	var error := _write_atomic(JSON.stringify(prepared.payload, "\t"))
	if error != OK:
		return _fail(error, "Could not write save file")
	last_error = OK
	return OK


## 只捕获原有全局字段，网关在一次原子写入中附上地图检查点。
func capture_save_data() -> Dictionary:
	var prepared := build_save_payload()
	if prepared.error != OK:
		_fail(prepared.error, "Could not capture save state")
		return {}
	return prepared.payload


## 只构建完整载荷，不写文件、不切换保存路径、不发送保存失败信号。
func build_save_payload() -> Dictionary:
	var active_payload: Variant = null
	if run_active and current_run != null:
		var seed_snapshot := SeedService.capture_snapshot()
		if seed_snapshot.is_empty():
			return {"error": SeedService.last_error, "payload": {}}
		active_payload = {
			"run_snapshot": current_run.to_dictionary(),
			"seed_snapshot": seed_snapshot,
		}
	elif not _saved_active_run.is_empty():
		active_payload = _saved_active_run.duplicate(true)

	var payload := {
		"save_version": SAVE_VERSION,
		"settings": settings.duplicate(true),
		"run_history": run_history.duplicate(true),
		"active_run": active_payload,
	}
	# 没有历史记录时保留旧版存档载荷形状。
	if not seen_region_titles.is_empty():
		payload["seen_region_titles"] = seen_region_titles.duplicate()
	# 点语法可在运行时字典中产生 StringName；存盘前只归一化这种字符串表示。
	# 先检查再复制，禁止 JSON.stringify 将对象或非有限数字悄悄转换成合法数据。
	if not _is_json_safe(payload, true):
		return {"error": ERR_INVALID_DATA, "payload": {}}
	return {"error": OK, "payload": _copy_json_value(payload)}


## 网关已验证并保存预备新局后才调用；旧局只在提交成功后销毁。
func install_prepared_run(data: Dictionary, run: RunStateMachine) -> Error:
	var validator := GlobalStateMachine.new()
	var error := validator._install_save(data)
	validator.free()
	if error != OK:
		return _fail(error, "Prepared save validation failed")
	error = SeedService.restore_snapshot(data.active_run.seed_snapshot)
	if error != OK:
		return _fail(error, "Could not install prepared random context")
	var old_run := current_run
	_install_save(data)
	add_child(run)
	_connect_run(run)
	current_run = run
	run_active = true
	_saved_active_run.clear()
	if is_instance_valid(old_run):
		old_run.queue_free()
	last_error = OK
	save_loaded.emit()
	run_started.emit(run)
	return OK


func load_save() -> Error:
	if not FileAccess.file_exists(save_path):
		_reset_loaded_data()
		last_error = OK
		save_loaded.emit()
		return OK

	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		return _fail(FileAccess.get_open_error(), "Could not open save file")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return _fail(ERR_PARSE_ERROR, "Save root must be a JSON object")
	var error := _install_save(parsed)
	if error != OK:
		return _fail(error, "Save validation failed")
	last_error = OK
	save_loaded.emit()
	return OK


func set_setting(key: String, value: Variant) -> Error:
	if key.strip_edges().is_empty() or not _is_json_safe(value):
		return _fail(ERR_INVALID_PARAMETER, "Setting key/value is invalid")
	settings[key] = _copy_json_value(value)
	settings_changed.emit(key, value)
	return OK


func abandon_current_run() -> Error:
	if not run_active or current_run == null:
		return _fail(ERR_UNCONFIGURED, "No active run")
	return current_run.finish_abandoned()


func _connect_run(run: RunStateMachine) -> void:
	run.run_ended.connect(_on_run_ended)


func _on_run_ended(result: Dictionary) -> void:
	if current_run == null:
		return
	var ended_run := current_run
	run_history.append(ended_run.build_history_record(result))
	run_active = false
	current_run = null
	_saved_active_run.clear()
	run_finished.emit(result.duplicate(true))
	# 正式游戏由网关原子落盘，结束记录不能绕过单存档保护及备份逻辑。
	var gateway := get_node_or_null("/root/SaveGateway") if is_inside_tree() else null
	var error: Error = gateway.save_current() if gateway != null and self == get_node_or_null("/root/GlobalState") else save_game()
	if error != OK:
		push_error("GlobalStateMachine: autosave after run end failed")
	ended_run.queue_free()


## 语义地区 ID 不包含随机种子；同地区换层/新局不重置历史。
static func valid_region_title_id(value: Variant) -> bool:
	if not value is String:
		return false
	return RegEx.create_from_string("^[a-z][a-z0-9_.:-]{0,127}$").search(value) != null

func has_seen_region_title(region_id: String) -> bool:
	return region_id in seen_region_titles

## 首次记录与现有完整存档共用原子写入；失败撤销本次追加。
func remember_region_title(region_id: String) -> Error:
	if not valid_region_title_id(region_id):
		return ERR_INVALID_PARAMETER
	if has_seen_region_title(region_id):
		return OK
	if seen_region_titles.size() >= 4096:
		return ERR_OUT_OF_MEMORY
	seen_region_titles.append(region_id)
	var gateway := get_node_or_null("/root/SaveGateway") if is_inside_tree() else null
	var error: Error = gateway.save_current() if gateway != null and self == get_node_or_null("/root/GlobalState") else save_game()
	if error != OK:
		seen_region_titles.erase(region_id)
	return error


func _install_save(data: Dictionary) -> Error:
	if not _integer_equals(data.get("save_version"), SAVE_VERSION):
		return ERR_INVALID_DATA
	var loaded_settings: Variant = data.get("settings")
	# 旧 v1 的成就和局外解锁字段已退役：读取时忽略，之后保存时不再写入。
	var loaded_history: Variant = data.get("run_history")
	var loaded_regions: Variant = data.get("seen_region_titles", [])
	var loaded_active: Variant = data.get("active_run")
	if not loaded_settings is Dictionary or not loaded_history is Array \
			or (loaded_active != null and not loaded_active is Dictionary):
		return ERR_INVALID_DATA
	if not _is_json_safe(loaded_settings) or not _is_json_safe(loaded_history) \
			or (loaded_active != null and not _is_json_safe(loaded_active)):
		return ERR_INVALID_DATA

	if not loaded_regions is Array or loaded_regions.size() > 4096:
		return ERR_INVALID_DATA
	var unique_regions: Dictionary = {}
	for region: Variant in loaded_regions:
		if not valid_region_title_id(region) or unique_regions.has(region):
			return ERR_INVALID_DATA
		unique_regions[region] = true
	for record: Variant in loaded_history:
		if not record is Dictionary:
			return ERR_INVALID_DATA
	seen_region_titles.assign(loaded_regions)
	settings = loaded_settings.duplicate(true)
	run_history.clear()
	for record: Variant in loaded_history:
		run_history.append(record.duplicate(true))
	_saved_active_run = {} if loaded_active == null else loaded_active.duplicate(true)
	run_active = false
	current_run = null
	return OK


func _reset_loaded_data() -> void:
	seen_region_titles.clear()
	settings.clear()
	run_history.clear()
	_saved_active_run.clear()
	run_active = false
	current_run = null


func _write_atomic(text: String) -> Error:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_path.get_base_dir()))
	if directory_error != OK:
		return directory_error
	var temporary := save_path + ".tmp"
	var backup := save_path + ".bak"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.flush()
	file = null

	var absolute_save := ProjectSettings.globalize_path(save_path)
	var absolute_temp := ProjectSettings.globalize_path(temporary)
	var absolute_backup := ProjectSettings.globalize_path(backup)
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(absolute_backup)
	if FileAccess.file_exists(save_path):
		var backup_error := DirAccess.rename_absolute(absolute_save, absolute_backup)
		if backup_error != OK:
			return backup_error
	var install_error := DirAccess.rename_absolute(absolute_temp, absolute_save)
	if install_error != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(absolute_backup, absolute_save)
		return install_error
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(absolute_backup)
	return OK


static func _is_json_safe(value: Variant, allow_string_names := false) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_STRING_NAME:
			return allow_string_names
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for item: Variant in value:
				if not _is_json_safe(item, allow_string_names):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not (key is String or (allow_string_names and key is StringName)) \
						or not _is_json_safe(value[key], allow_string_names):
					return false
			return true
		_:
			return false


static func _copy_json_value(value: Variant) -> Variant:
	if value is StringName:
		return String(value)
	if value is Array:
		var copied: Array = []
		for item: Variant in value:
			copied.append(_copy_json_value(item))
		return copied
	if value is Dictionary:
		var copied: Dictionary = {}
		for key: Variant in value:
			copied[String(key)] = _copy_json_value(value[key])
		return copied
	return value


static func _integer_equals(value: Variant, expected: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == expected


func _fail(error: Error, message: String) -> Error:
	last_error = error
	push_error("GlobalStateMachine: " + message)
	save_failed.emit(error, message)
	return error

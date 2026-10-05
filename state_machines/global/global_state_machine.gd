class_name GlobalStateMachine
extends Node

## PRG-002：局外状态、JSON 存档、卡牌解锁、成就状态与对局历史。
## Autoload 名称为 GlobalState；业务代码不应再实例化第二个常驻全局状态机。

signal save_loaded
signal save_failed(error: Error, message: String)
signal run_started(run: RunStateMachine)
signal run_continued(run: RunStateMachine)
signal run_finished(result: Dictionary)
signal achievement_check_requested(metric: StringName, value: Variant, run_snapshot: Dictionary)
signal achievement_unlocked(achievement_id: String)
signal settings_changed(key: String, value: Variant)
signal unlocked_cards_changed(card_ids: Array[String])

const SAVE_VERSION := 1
const DEFAULT_SAVE_PATH := "user://spotlight_save.json"

var save_path := DEFAULT_SAVE_PATH
var settings: Dictionary = {}
var achievements: Dictionary = {}
var unlocked_cards: Array[String] = []
var run_history: Array[Dictionary] = []

var current_run: RunStateMachine
var run_active := false
var last_error: Error = OK

## 启动时读入、但要等玩家点击“继续游戏”才安装的快照。
var _saved_active_run: Dictionary = {}


func _ready() -> void:
	load_save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()


func has_continuable_run() -> bool:
	return not _saved_active_run.is_empty() or (run_active and current_run != null)


func start_new_run(seed_text: String, config: Dictionary) -> Error:
	if run_active or current_run != null:
		return _fail(ERR_ALREADY_IN_USE, "A run is already active")

	var run := RunStateMachine.new()
	add_child(run)
	_connect_run(run)
	var error := run.initialize_new(seed_text, config, unlocked_cards)
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
	var active_payload: Variant = null
	if run_active and current_run != null:
		var seed_snapshot := SeedService.capture_snapshot()
		if seed_snapshot.is_empty():
			return _fail(SeedService.last_error, "Could not capture random state")
		active_payload = {
			"run_snapshot": current_run.to_dictionary(),
			"seed_snapshot": seed_snapshot,
		}
	elif not _saved_active_run.is_empty():
		active_payload = _saved_active_run.duplicate(true)

	var payload := {
		"save_version": SAVE_VERSION,
		"settings": settings.duplicate(true),
		"achievements": achievements.duplicate(true),
		"unlocked_cards": unlocked_cards.duplicate(),
		"run_history": run_history.duplicate(true),
		"active_run": active_payload,
	}
	var json := JSON.stringify(payload, "\t")
	var error := _write_atomic(json)
	if error != OK:
		return _fail(error, "Could not write save file")
	last_error = OK
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


func unlock_card(card_id: String) -> Error:
	var normalized := card_id.strip_edges()
	if normalized.is_empty():
		return _fail(ERR_INVALID_PARAMETER, "Card id is empty")
	if not unlocked_cards.has(normalized):
		unlocked_cards.append(normalized)
		unlocked_cards.sort()
		unlocked_cards_changed.emit(unlocked_cards.duplicate())
	return OK


## 具体成就条件不在本任务内；外部规则监听检查请求，满足后调用本方法。
func complete_achievement(achievement_id: String, metadata: Dictionary = {}) -> Error:
	var normalized := achievement_id.strip_edges()
	if normalized.is_empty() or not _is_json_safe(metadata):
		return _fail(ERR_INVALID_PARAMETER, "Achievement id or metadata is invalid")
	var existing: Variant = achievements.get(normalized)
	if existing is Dictionary and bool(existing.get("completed", false)):
		return OK
	achievements[normalized] = {
		"completed": true,
		"completed_at": Time.get_datetime_string_from_system(true),
		"metadata": metadata.duplicate(true),
	}
	achievement_unlocked.emit(normalized)
	return OK


func abandon_current_run() -> Error:
	if not run_active or current_run == null:
		return _fail(ERR_UNCONFIGURED, "No active run")
	return current_run.finish_abandoned()


func _connect_run(run: RunStateMachine) -> void:
	run.stat_updated.connect(_on_run_stat_updated)
	run.run_ended.connect(_on_run_ended)


func _on_run_stat_updated(metric: StringName, value: Variant) -> void:
	if current_run == null:
		return
	achievement_check_requested.emit(metric, value, current_run.to_dictionary())


func _on_run_ended(result: Dictionary) -> void:
	if current_run == null:
		return
	var ended_run := current_run
	run_history.append(ended_run.build_history_record(result))
	run_active = false
	current_run = null
	_saved_active_run.clear()
	run_finished.emit(result.duplicate(true))
	var error := save_game()
	if error != OK:
		push_error("GlobalStateMachine: autosave after run end failed")
	ended_run.queue_free()


func _install_save(data: Dictionary) -> Error:
	if not _integer_equals(data.get("save_version"), SAVE_VERSION):
		return ERR_INVALID_DATA
	var loaded_settings: Variant = data.get("settings")
	var loaded_achievements: Variant = data.get("achievements")
	var loaded_cards: Variant = data.get("unlocked_cards")
	var loaded_history: Variant = data.get("run_history")
	var loaded_active: Variant = data.get("active_run")
	if not loaded_settings is Dictionary or not loaded_achievements is Dictionary \
			or not loaded_cards is Array or not loaded_history is Array \
			or (loaded_active != null and not loaded_active is Dictionary):
		return ERR_INVALID_DATA
	if not _string_array_valid(loaded_cards) or not _is_json_safe(loaded_settings) \
			or not _is_json_safe(loaded_achievements) or not _is_json_safe(loaded_history) \
			or (loaded_active != null and not _is_json_safe(loaded_active)):
		return ERR_INVALID_DATA

	settings = loaded_settings.duplicate(true)
	achievements = loaded_achievements.duplicate(true)
	unlocked_cards.assign(loaded_cards)
	unlocked_cards.sort()
	run_history.clear()
	for record: Variant in loaded_history:
		if not record is Dictionary:
			return ERR_INVALID_DATA
		run_history.append(record.duplicate(true))
	_saved_active_run = {} if loaded_active == null else loaded_active.duplicate(true)
	run_active = false
	current_run = null
	return OK


func _reset_loaded_data() -> void:
	settings.clear()
	achievements.clear()
	unlocked_cards.clear()
	run_history.clear()
	_saved_active_run.clear()
	run_active = false
	current_run = null


func _write_atomic(text: String) -> Error:
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


static func _string_array_valid(values: Array) -> bool:
	for value: Variant in values:
		if not value is String or value.strip_edges().is_empty():
			return false
	return true


static func _is_json_safe(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for item: Variant in value:
				if not _is_json_safe(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not key is String or not _is_json_safe(value[key]):
					return false
			return true
		_:
			return false


static func _copy_json_value(value: Variant) -> Variant:
	return value.duplicate(true) if value is Array or value is Dictionary else value


static func _integer_equals(value: Variant, expected: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == expected


func _fail(error: Error, message: String) -> Error:
	last_error = error
	push_error("GlobalStateMachine: " + message)
	save_failed.emit(error, message)
	return error

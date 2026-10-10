extends Node

## 界面侧的存档适配层。唯一认识存档文件的文件：开始界面与设置界面只调它、只听它的信号，
## 谁都不直接摸存档文件或状态机。见 docs/prompts/PRG-016-021-开始界面与设置.md §七。
##
## 与方法名一样冻结的还有信号名、`list_slots()` 的字段名，`ui/` 只认这一套。
##
## 占位期（PRG-002 的 GlobalState 还没合进 main）：读的一侧真读档案 JSON；写的一侧只写
## 设置、当前档索引、删除，以及自己那个 `placeholder_run` 标记——**状态机的 `active_run` 一个字都不写**。
## 新游戏、继续、死亡这条链的唯一真相来源是 GlobalState，接入只换本文件内部实现。

signal slots_refreshed
signal active_slot_changed(slot: int)
signal run_started(slot: int)
signal run_continued(slot: int)
signal save_failed(error: int, message: String)
signal settings_changed(key: String, value: Variant)

const SLOT_COUNT := 3
const SAVE_DIR := "user://save"
const SLOT_PATH_TEMPLATE := "user://save/slot%d.json"
const DEFAULT_SETTINGS_PATH := "user://save/settings.json"
const FILE_VERSION := 1
## 占位期的「本局进行中」标记。状态机合进 main 之后，这里连同它的读写一起删掉。
const PLACEHOLDER_RUN_KEY := "placeholder_run"

## PRG-021 定义的六项，前三项是音量、后两项是全屏与分辨率，默认值见文档 §六。
const DEFAULT_SETTINGS := {
	"master_volume": 100,
	"music_volume": 100,
	"sfx_volume": 100,
	"fullscreen": true,
	"resolution": "1920x1080",
}

## 全局文件的路径。留成变量是为了自测能把它指到写不进去的位置，验证 save_failed。
var settings_path := DEFAULT_SETTINGS_PATH

var _settings: Dictionary = {}
var _active_slot: int = 1
var _achievements: Array[Dictionary] = []


func _ready() -> void:
	_load_settings()


# ------------------------------------------------------------------ 档案槽位

## 三档信息，字段见文档 §七。空档也要返回，供界面画三张卡片。
func list_slots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot in range(1, SLOT_COUNT + 1):
		result.append(read_slot(slot))
	return result


## 单档信息。只读，不改任何状态。
func read_slot(slot: int) -> Dictionary:
	var info := _empty_slot_info(slot)
	if slot < 1 or slot > SLOT_COUNT:
		return info
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return info

	var data := _read_json(path)
	# 文件在就算这档有东西：解析失败或内容为空都按「只有记录」处理，不当成空档。
	info["exists"] = true
	info["run_count"] = _array_size(data.get("run_history"))

	var active: Variant = data.get("active_run")
	var placeholder: Variant = data.get(PLACEHOLDER_RUN_KEY)
	var placeholder_run := placeholder is Dictionary and not (placeholder as Dictionary).is_empty()
	if (active is Dictionary and not (active as Dictionary).is_empty()) or placeholder_run:
		info["state"] = "active"
		var snapshot: Variant = (active as Dictionary).get("run_snapshot") if active is Dictionary else null
		if snapshot is Dictionary:
			var run: Dictionary = snapshot
			info["health"] = _int_value(run.get("health"), 0)
			info["max_health"] = _int_value(run.get("max_health"), 0)
			info["gold"] = _int_value(run.get("gold"), 0)
			info["region"] = String(run.get("current_map_id", ""))
		elif placeholder_run:
			# 占位局没有真实快照，报场景名与进度，生命与金币留 0 不编。
			info["region"] = String((placeholder as Dictionary).get("region", ""))
			info["progress"] = _int_value((placeholder as Dictionary).get("progress"), 0)
	else:
		# 只有记录、没有进行中的局：死亡或舍弃之后的墓碑态，不是空档。
		info["state"] = "ended"
	info["updated_at"] = _modified_at(path)
	return info


func get_active_slot() -> int:
	return _active_slot


## 切当前档。先落盘再切是接入后的要求（load_save() 会清掉内存里的 current_run），
## 占位期没有局内状态可丢，只改索引与文件。
func set_active_slot(slot: int) -> Error:
	if slot < 1 or slot > SLOT_COUNT:
		return _fail(ERR_INVALID_PARAMETER, "档号必须在 1 到 %d 之间" % SLOT_COUNT)
	if slot != _active_slot:
		_active_slot = slot
		var error := _save_settings()
		if error != OK:
			return error
	active_slot_changed.emit(_active_slot)
	return OK


## 删档：档案 JSON 加它的临时件与备份一起删。占位期删当前档没有额外动作——内存里
## 没有局内状态，界面重读 list_slots() 就是空档；接入后按文档 §七 还要再让状态机读一次
## （把 save_path 指开再 load_save()），免得它手里还攥着一份已经删掉的档。
func delete_slot(slot: int) -> Error:
	if slot < 1 or slot > SLOT_COUNT:
		return _fail(ERR_INVALID_PARAMETER, "档号必须在 1 到 %d 之间" % SLOT_COUNT)
	var path := slot_path(slot)
	for candidate: String in [path, path + ".tmp", path + ".bak"]:
		if not FileAccess.file_exists(candidate):
			continue
		var error := DirAccess.remove_absolute(candidate)
		if error != OK:
			return _fail(error, "删不掉 %s" % candidate)
	slots_refreshed.emit()
	return OK


func slot_path(slot: int) -> String:
	return SLOT_PATH_TEMPLATE % slot


# ------------------------------------------------ 转发给 GlobalState 的方法

## 当前档有没有进行中的局。
## 占位：档案 JSON 里有状态机写的 `active_run`、或网关自己写的 `placeholder_run`，都算有；
## 接入后换成 GlobalState.has_continuable_run()。
func has_continuable_run() -> bool:
	return String(read_slot(_active_slot).get("state", "empty")) == "active"


## 开新局。
## 占位：往当前档写一个 placeholder_run 标记，界面据此进占位跑图场景，**不碰 active_run**。
## 接入后：删掉这处标记的读写，改成 return GlobalState.start_new_run(seed_text, config)，
## 局中它会回 ERR_ALREADY_IN_USE。
func start_new_run(seed_text: String, config: Dictionary) -> Error:
	var data := _read_json(slot_path(_active_slot))
	data[PLACEHOLDER_RUN_KEY] = {
		"started_at": int(Time.get_unix_time_from_system()),
		"seed_text": seed_text,
		"region": "占位跑图",
		"progress": 0,
	}
	# config（三张地图的配置）是状态机要的，占位期用不上，接入时交给 GlobalState。
	var error := _write_slot(_active_slot, data)
	if error != OK:
		return error
	run_started.emit(_active_slot)
	return OK


## 继续存档里的局。占位：当前档有进行中的标记就回 OK，界面据此进占位场景。
## 接入后：return GlobalState.continue_saved_run()——读档只准走这一条，不自行恢复随机快照。
func continue_saved_run() -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "当前档没有进行中的局")
	run_continued.emit(_active_slot)
	return OK


## 舍弃本局。占位：把标记从当前档里删掉，档案文件留着（对局记录归状态机写）。
## 接入后：return GlobalState.abandon_current_run()。
func abandon_run() -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "当前档没有进行中的局")
	var data := _read_json(slot_path(_active_slot))
	data.erase(PLACEHOLDER_RUN_KEY)
	return _write_slot(_active_slot, data)


## 占位专用：把本局的进度写进占位标记。占位跑图场景用它证明「继续游戏」接的是同一局。
## 接入后连同 placeholder_run 与这个方法一起删掉——进度那时归状态机的 run_snapshot。
func set_run_progress(progress: int) -> Error:
	if not has_continuable_run():
		return _fail(ERR_DOES_NOT_EXIST, "当前档没有进行中的局")
	var data := _read_json(slot_path(_active_slot))
	var marker: Variant = data.get(PLACEHOLDER_RUN_KEY)
	if not (marker is Dictionary):
		return _fail(ERR_DOES_NOT_EXIST, "当前档的占位标记不见了")
	var updated: Dictionary = (marker as Dictionary).duplicate(true)
	updated["progress"] = progress
	data[PLACEHOLDER_RUN_KEY] = updated
	return _write_slot(_active_slot, data)


# ------------------------------------------------------------------ 设置

func get_setting(key: String, default: Variant = null) -> Variant:
	if _settings.has(key):
		return _settings[key]
	return default


## 设置不与档案绑定，删档不会连音量和全屏一起清掉。不转 GlobalState.set_setting()，
## 理由见文档 §2.4：状态机那份 settings 留空，由本文件自持。
func set_setting(key: String, value: Variant) -> Error:
	if key.is_empty():
		return _fail(ERR_INVALID_PARAMETER, "设置键不能为空")
	_settings[key] = value
	var error := _save_settings()
	if error != OK:
		return error
	settings_changed.emit(key, value)
	return OK


func list_achievements() -> Array[Dictionary]:
	return _achievements.duplicate()


## 当前档的解锁卡牌。占位：读档案 JSON 的 unlocked_cards；接入后转发 GlobalState.unlocked_cards。
func list_unlocked_cards() -> Array[String]:
	var data := _read_json(slot_path(_active_slot))
	return _string_array(data.get("unlocked_cards"))


## 当前档的对局记录。占位：读档案 JSON 的 run_history；接入后转发 GlobalState.run_history。
func list_run_history() -> Array[Dictionary]:
	var data := _read_json(slot_path(_active_slot))
	return _dictionary_array(data.get("run_history"))


## 退出前先落盘。get_tree().quit() 不触发 NOTIFICATION_WM_CLOSE_REQUEST，状态机挂在那条
## 通知上的自动存不会跑，所以这里显式存一次。
func quit_game() -> void:
	_save_settings()
	var global_state: Node = get_node_or_null("/root/GlobalState")
	if global_state != null and global_state.has_method("save_game"):
		global_state.call("save_game")
	get_tree().quit()


# ------------------------------------------------------------------ 内部

func _empty_slot_info(slot: int) -> Dictionary:
	return {
		"slot": slot,
		"exists": false,
		"state": "empty",
		"region": "",
		"health": 0,
		"max_health": 0,
		"gold": 0,
		"progress": 0,
		"run_count": 0,
		"updated_at": "",
	}


func _load_settings() -> void:
	_settings = DEFAULT_SETTINGS.duplicate(true)
	_active_slot = 1
	_achievements = []
	var data := _read_json(settings_path)
	if data.is_empty():
		return
	_active_slot = clampi(_int_value(data.get("active_slot"), 1), 1, SLOT_COUNT)
	var stored: Variant = data.get("settings")
	if stored is Dictionary:
		for key: Variant in (stored as Dictionary):
			_settings[String(key)] = _restore_setting_value((stored as Dictionary)[key])
	_achievements = _dictionary_array(data.get("achievements"))


func _save_settings() -> Error:
	var payload := {
		"version": FILE_VERSION,
		"active_slot": _active_slot,
		"settings": _settings,
		"achievements": _achievements,
	}
	return _atomic_write(settings_path, JSON.stringify(payload, "\t"))


## 先写 .tmp 再换名，原名先转成 .bak。写之前建目录：状态机的 _write_atomic() 不建目录，
## 这里不建的话第一次写盘就是 save_failed。
func _atomic_write(path: String, text: String) -> Error:
	var error := _ensure_dir()
	if error != OK:
		return _fail(error, "建不了目录 %s" % SAVE_DIR)

	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _fail(FileAccess.get_open_error(), "写不了 %s" % temporary)
	file.store_string(text)
	file.close()

	if FileAccess.file_exists(path):
		var backup := path + ".bak"
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(backup)
		error = DirAccess.rename_absolute(path, backup)
		if error != OK:
			return _fail(error, "换不了备份 %s" % backup)
	error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		return _fail(error, "换不了正式文件 %s" % path)
	return OK


func _ensure_dir() -> Error:
	if DirAccess.dir_exists_absolute(SAVE_DIR):
		return OK
	return DirAccess.make_dir_recursive_absolute(SAVE_DIR)


func _write_slot(slot: int, data: Dictionary) -> Error:
	return _atomic_write(slot_path(slot), JSON.stringify(data, "\t"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	_fail(ERR_PARSE_ERROR, "存档解析失败：%s" % path)
	return {}


func _modified_at(path: String) -> String:
	var stamp := FileAccess.get_modified_time(path)
	if stamp <= 0:
		return ""
	return Time.get_datetime_string_from_unix_time(stamp)


func _int_value(value: Variant, fallback: int) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return int(value)
	return fallback


## JSON 里没有整数类型，读写一趟整数会变成浮点，界面拿到 42.0 再去显示或比较就会出怪。
## 整数形态的浮点还原成 int；真的小数照原样留着。
func _restore_setting_value(value: Variant) -> Variant:
	if typeof(value) == TYPE_FLOAT and value == floor(value):
		return int(value)
	return value


func _array_size(value: Variant) -> int:
	if value is Array:
		return (value as Array).size()
	return 0


func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item: Variant in (value as Array):
			if item is String:
				result.append(item)
	return result


func _dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if value is Array:
		for item: Variant in (value as Array):
			if item is Dictionary:
				result.append((item as Dictionary).duplicate(true))
	return result


## 失败只走 save_failed 信号（界面用提示条显示），不 push_error：
## 自测会故意触发失败，stderr 里不该出现 ERROR。
func _fail(error: Error, message: String) -> Error:
	save_failed.emit(error, message)
	return error

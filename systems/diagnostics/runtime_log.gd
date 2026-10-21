## 运行日志：把失败与关键流程写成能回传的文本。
##
## 只写 user://logs/，不碰存档、不改存档版本，也不新增 autoload：全是静态方法。
## 一行一个 JSON，字段 t（毫秒时间戳）、n（会话内序号）、tag、data，方便直接写脚本统计。
##
## install() 幂等，首次调用写会话头（版本、平台、主场景、autoload 顺序）。
## event() 记一条普通事件；failure() 记一条失败，并附带调用栈的文件与行号。

const LOG_DIR := "user://logs"
const RING_LIMIT := 200
const CHUNK_BYTES := 2 * 1024 * 1024
const KEEP_SESSIONS := 3
const STACK_DEPTH := 5
const GODOT_LOG_PATH := "user://logs/godot.log"
## 攒到这么多字符就先落盘，避免长时间不刷新时缓冲区无限增长。
const FLUSH_BYTES := 64 * 1024

static var _dir := LOG_DIR
static var _installed := false
static var _path := ""
static var _chunk := 0
static var _seq := 0
static var _ring: Array = []
static var _pending := ""
static var _flush_hooked := false


## 测试用：在 install() 之前换目录，生产路径不需要调用。
static func set_dir(path: String) -> void:
	if _installed:
		return
	_dir = path


static func install(context: Dictionary = {}) -> void:
	if _installed:
		return
	_installed = true
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir)) != OK:
		return
	_trim_sessions()
	_rotate()
	var body := _runtime_context()
	for key: String in context:
		body[key] = context[key]
	_write("session", body, true)


static func event(tag: String, data: Dictionary = {}) -> void:
	if not _installed:
		install()
	if _path.is_empty():
		return
	_write(tag, data)


## 失败事件。error 用引擎错误码，message 用给玩家看的同一句文案；
## 调用栈取 failure 的调用方，直接落到 save_gateway.gd 之类的具体行。
static func failure(tag: String, error: Error, message: String) -> void:
	event(tag, {
		"error": error,
		"error_name": error_string(error),
		"message": message,
		"stack": caller_stack(),
	})


static func caller_stack(depth: int = STACK_DEPTH) -> Array[String]:
	var result: Array[String] = []
	# 跳过本文件自身的帧（caller_stack / failure），从真正的调用点开始取。
	for frame: Dictionary in get_stack():
		var source := str(frame.get("source", ""))
		if source.ends_with("runtime_log.gd"):
			continue
		result.append("%s:%d %s" % [source, int(frame.get("line", 0)),
			str(frame.get("function", ""))])
		if result.size() >= depth:
			break
	return result


static func recent(limit: int = RING_LIMIT) -> Array:
	if _ring.is_empty():
		return []
	var take := mini(limit, _ring.size())
	return _ring.slice(_ring.size() - take).duplicate(true)


static func current_path() -> String:
	return _path


## 生成诊断目录：本次会话的 jsonl、summary.txt，以及存在的引擎日志。
## 返回绝对路径，交给界面打开；失败返回空串。
static func export_bundle() -> String:
	if not _installed:
		install()
	# 导出的是磁盘文件，缓冲区里的最新事件必须先落盘。
	flush()
	var dir := _dir.path_join("export-" + _stamp())
	var global_dir := ProjectSettings.globalize_path(dir)
	if DirAccess.make_dir_recursive_absolute(global_dir) != OK:
		return ""
	_copy_runtime_files(global_dir)
	var godot_log := ProjectSettings.globalize_path(GODOT_LOG_PATH)
	if FileAccess.file_exists(godot_log):
		DirAccess.copy_absolute(godot_log, global_dir.path_join("godot.log"))
	var file := FileAccess.open(dir.path_join("summary.txt"), FileAccess.WRITE)
	if file != null:
		file.store_string(summary())
		file = null
	return global_dir


static func summary() -> String:
	var lines: Array[String] = []
	lines.append("导出时间：" + Time.get_datetime_string_from_system())
	lines.append("会话日志：" + ProjectSettings.globalize_path(_path))
	var tree := Engine.get_main_loop() as SceneTree
	var scene_path := ""
	var save_path := ""
	if tree != null:
		if tree.current_scene != null:
			scene_path = tree.current_scene.scene_file_path
		var gateway := tree.root.get_node_or_null("SaveGateway")
		if gateway != null:
			save_path = str(gateway.get("save_path"))
	lines.append("当前场景：" + scene_path)
	lines.append("存档路径：" + save_path)
	lines.append("最近 %d 条：" % _ring.size())
	for record: Dictionary in _ring:
		lines.append("%d %-16s %s" % [int(record.get("t", 0)), str(record.get("tag", "")),
			JSON.stringify(record.get("data", {}))])
	return "\n".join(lines)


static func _write(tag: String, data: Dictionary, immediate: bool = false) -> void:
	_seq += 1
	var record := {"t": _now_ms(), "n": _seq, "tag": tag, "data": data}
	_ring.append(record)
	if _ring.size() > RING_LIMIT:
		_ring = _ring.slice(_ring.size() - RING_LIMIT)
	# 一行一次 open/flush/close 会把结算这类一秒几十条事件的流程拖成肉眼可见的卡顿，
	# 先攒在内存里，每帧末落盘一次；会话头与导出前强制立即写。
	_pending += JSON.stringify(record) + "\n"
	if immediate or _pending.length() >= FLUSH_BYTES:
		flush()
		return
	_hook_frame_flush()


## 每帧末统一落盘。没有可用的 SceneTree（如 --script 自测）时退回逐条写。
static func _hook_frame_flush() -> void:
	if _flush_hooked:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		flush()
		return
	tree.process_frame.connect(flush)
	_flush_hooked = true


static func flush() -> void:
	if _pending.is_empty():
		return
	var payload := _pending
	_pending = ""
	_rotate_if_full(payload.length())
	# READ_WRITE 不建文件，首条事件用 WRITE 建，之后追加。
	var file: FileAccess = null
	if FileAccess.file_exists(_path):
		file = FileAccess.open(_path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(payload)
	file.flush()
	file = null


static func _rotate_if_full(incoming_bytes: int) -> void:
	if not FileAccess.file_exists(_path):
		return
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		return
	var size := file.get_length()
	file = null
	if size + incoming_bytes > CHUNK_BYTES:
		_rotate()


static func _rotate() -> void:
	_chunk += 1
	_path = _dir.path_join("runtime-%s-%d.jsonl" % [_stamp(), _chunk])


static func _trim_sessions() -> void:
	var dir := DirAccess.open(_dir)
	if dir == null:
		return
	var names: Array[String] = []
	for name in dir.get_files():
		if name.begins_with("runtime-") and name.ends_with(".jsonl"):
			names.append(name)
	names.sort()
	while names.size() > KEEP_SESSIONS - 1:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_dir.path_join(names[0])))
		names.remove_at(0)


static func _copy_runtime_files(target_dir: String) -> void:
	var dir := DirAccess.open(_dir)
	if dir == null:
		return
	for name in dir.get_files():
		if name.begins_with("runtime-") and name.ends_with(".jsonl"):
			DirAccess.copy_absolute(ProjectSettings.globalize_path(_dir.path_join(name)),
				target_dir.path_join(name))


static func _runtime_context() -> Dictionary:
	return {
		"version": str(ProjectSettings.get_setting("application/config/version", "")),
		"content_version": str(ProjectSettings.get_setting("application/config/seed_content_version", "")),
		"app": str(ProjectSettings.get_setting("application/config/name", "")),
		"platform": OS.get_name(),
		"main_scene": str(ProjectSettings.get_setting("application/run/main_scene", "")),
		"autoloads": _autoload_order(),
		"debug": OS.is_debug_build(),
	}


## 按 project.godot 的声明顺序取 autoload，用来复现启动期依赖顺序问题。
static func _autoload_order() -> Array[String]:
	var result: Array[String] = []
	for property: Dictionary in ProjectSettings.get_property_list():
		var name := str(property.get("name", ""))
		if name.begins_with("autoload/"):
			result.append(name.trim_prefix("autoload/"))
	return result


static func _now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


static func _stamp() -> String:
	var now := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d" % [int(now.year), int(now.month), int(now.day),
		int(now.hour), int(now.minute), int(now.second)]

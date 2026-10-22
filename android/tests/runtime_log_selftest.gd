extends SceneTree

## 运行日志自测。用 --script 跑，不依赖渲染，也不写正式日志目录。
##
##   godot --headless --script res://tests/runtime_log_selftest.gd
##
## 覆盖：
##   - install 幂等，首行是 session，且带 autoload 顺序
##   - 事件按 JSONL 追加，环形缓冲截到 200 条
##   - failure 带出调用栈，并落到本文件的行
##   - export_bundle 生成 jsonl 副本与 summary.txt

const RUNTIME_LOG := preload("res://systems/diagnostics/runtime_log.gd")
const TEST_DIR := "user://logs-selftest"

var _failures := 0


func _initialize() -> void:
	_clean()
	RUNTIME_LOG.set_dir(TEST_DIR)
	RUNTIME_LOG.install({"case": "selftest"})
	RUNTIME_LOG.install({"case": "again"})

	var path := RUNTIME_LOG.current_path()
	_check(not path.is_empty() and FileAccess.file_exists(path), "install 后应生成会话文件")
	_check(_first_tag(path) == "session", "首行应为 session")
	var autoloads: Array = _first_data(path).get("autoloads", [])
	_check("SaveGateway" in autoloads, "session 头应带 autoload 顺序")

	for index in 250:
		RUNTIME_LOG.event("test.tick", {"i": index})
	_check(RUNTIME_LOG.recent(1000).size() == RUNTIME_LOG.RING_LIMIT, "环形缓冲应截到上限")
	_check(RUNTIME_LOG.recent(10).size() == 10, "recent 应按需截取")

	var marker := "boom-%d" % Time.get_ticks_usec()
	RUNTIME_LOG.failure("test.fail", ERR_INVALID_DATA, marker)
	var last: Dictionary = RUNTIME_LOG.recent(1)[0]
	var stack: Array = last.get("data", {}).get("stack", [])
	_check(str(last.get("tag", "")) == "test.fail", "failure 应写入失败事件")
	_check(int(last.get("data", {}).get("error", 0)) == ERR_INVALID_DATA, "failure 应带错误码")
	_check(not stack.is_empty(), "failure 应带调用栈")
	_check("runtime_log_selftest.gd" in str(stack), "调用栈应落到调用方文件")

	var exported := RUNTIME_LOG.export_bundle()
	_check(not exported.is_empty() and DirAccess.dir_exists_absolute(exported), "导出目录应生成")
	_check(FileAccess.file_exists(exported.path_join("summary.txt")), "summary.txt 应生成")
	var summary := FileAccess.get_file_as_string(exported.path_join("summary.txt"))
	_check(summary.find(marker) >= 0, "summary 应包含最近事件")

	_clean()
	if _failures == 0:
		print("runtime_log_selftest: OK")
		quit(0)
	else:
		print("runtime_log_selftest: %d failed" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("runtime_log_selftest: " + message)


func _first_line(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var line := file.get_line()
	file = null
	return line


func _first_tag(path: String) -> String:
	var record = JSON.parse_string(_first_line(path))
	return str(record.get("tag", "")) if record is Dictionary else ""


func _first_data(path: String) -> Dictionary:
	var record = JSON.parse_string(_first_line(path))
	return record.get("data", {}) if record is Dictionary else {}


func _clean() -> void:
	var dir := DirAccess.open(TEST_DIR)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR.path_join(name)))
	for name in dir.get_directories():
		var sub := TEST_DIR.path_join(name)
		var sub_dir := DirAccess.open(sub)
		if sub_dir != null:
			for file_name in sub_dir.get_files():
				DirAccess.remove_absolute(ProjectSettings.globalize_path(sub.path_join(file_name)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sub))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR))

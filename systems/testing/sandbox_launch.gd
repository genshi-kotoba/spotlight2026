extends RefCounted
## Explicit process-level opt-in; it never redirects an ordinary game profile.
const SAVE_PATH := "user://fixed-test-map/game.json"
const MENU := "res://ui/testing/fixed_test_menu.tscn"
const MAP := "res://ui/testing/fixed_test_map.tscn"
const MAP_IDS := ["sandbox:floor-001", "sandbox:floor-002", "sandbox:floor-003", "sandbox:floor-004"]

static func requested() -> bool:
	return OS.get_cmdline_user_args().has("--fixed-test-map")

static func scene_path(path: String) -> String:
	if not requested(): return path
	if path == "res://ui/main_menu/main_menu.tscn": return MENU
	if path == "res://ui/main_menu/menu_map_entry.tscn": return MAP
	return path

static func valid_map_count(ids: Array, run_id: String, sandbox: bool) -> bool:
	# 正式局兼容旧三层与当前四层；固定测试档只接受自己的四区身份。
	if sandbox and run_id.begins_with("sandbox-"): return ids == MAP_IDS
	return ids.size() in [3, 4]

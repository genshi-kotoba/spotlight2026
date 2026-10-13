extends "res://ui/world_map/flat_2d/map_run_demo.gd"

## 主菜单落点：只覆盖装配/持久化入口，地图算法、交互和视图全部继承 main。
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"
var _gateway: Node
var _saved_entry_state: Dictionary = {}

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
	super._ready()
	if not _saved_entry_state.is_empty():
		load_map(_map_snapshot, _saved_entry_state)
		if not session.pending.is_empty() and demo_interactions_enabled:
			_dialog_request_id = str(session.pending.request_id)
			_dialog.title = "已恢复待结算节点"
			_dialog.dialog_text = "节点 %s 的请求已恢复，请完成或取消以继续探索。" % session.pending.node_id
			_dialog.popup_centered(Vector2i(570, 255))
	_gateway.bind_map_view(self)
	# 放弃本局的二次确认在设置面板里完成，这里只负责落地。
	# 冒险菜单设置页里的三个动作：存档、回主菜单、退出都走存档网关。
	_run_menu.abandon_requested.connect(_on_menu_abandon)
	_run_menu.return_to_menu_requested.connect(_return_to_menu)
	_run_menu.quit_requested.connect(_on_menu_quit)
	# 第一张地图生成后即留下完整检查点；原 F6 地图 Demo 仍不受此装配层影响。
	if map_run != null and map_run.current_floor > 0:
		_save_run()


func _initial_snapshot() -> Dictionary:
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUN_CONFIG_PATH))
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
		var entry: Dictionary = map_run.get_floor(map_run.current_floor)
		_saved_entry_state = entry.get("state", {}).duplicate(true)
		return entry.get("snapshot", {})
	if not map_run.attach_existing_run(_floor_configs):
		return {}
	var floor_index := run.map_ids.find(run.current_map_id) + 1
	var entry: Dictionary = map_run.enter_floor(maxi(1, floor_index))
	return entry.get("snapshot", {})


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
	var error := get_tree().change_scene_to_file(MENU_SCENE)
	if error != OK:
		_show_toast("返回开始界面失败：%d" % error)


func _change_floor(index: int) -> void:
	super._change_floor(index)
	var run: RunStateMachine = _gateway.current_run()
	if run != null and map_run.current_floor == index:
		run.set_current_map(run.map_ids[index - 1])
		_save_run()

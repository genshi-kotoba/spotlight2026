extends "res://ui/world_map/flat_2d/map_demo.gd"
## Standalone integration sample. Production run state retains PlanarMapRun;
## the shared map_demo view can then be replaced by a 2.5D view unchanged.
const Run = preload("res://state_machines/run/planar_map_run.gd")
const RUN_CONFIG_PATH := "res://data/config/flat_2d/demo_run.json"
var map_run: RefCounted
var _floor_configs: Array = []
var _seed_field: LineEdit
var _floor_label: Label
var _previous: Button
var _next: Button
var _saved_run: Dictionary = {}
var _restore_button: Button

func _ready() -> void:
	super._ready()
	_build_run_controls()
	_refresh_run_controls()

func _initial_snapshot() -> Dictionary:
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(RUN_CONFIG_PATH))
	if not settings is Dictionary or not settings.get("floors") is Array or not settings.get("seed") is String:
		push_error("Invalid demo_run.json")
		return {}
	_floor_configs = settings.floors.duplicate(true)
	var source := get_node("/root/SeedService")
	map_run = Run.new(source, str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	# A host which already began the run must not be reset by a map scene.
	var attached: bool = map_run.attach_existing_run(_floor_configs) if not source.get_main_seed().is_empty() else map_run.start_new_run(settings.seed, _floor_configs)
	if not attached:
		push_error(map_run.last_error)
		return {}
	var entry: Dictionary = map_run.enter_floor(1)
	if entry.is_empty():
		push_error(map_run.last_error)
		return {}
	return entry.snapshot

func _build_run_controls() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 175)
	panel.custom_minimum_size = Vector2(520, 0)
	_hud_root.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var seed_row := HBoxContainer.new()
	column.add_child(seed_row)
	_seed_field = LineEdit.new()
	_seed_field.placeholder_text = "输入 Seed；空白生成新 Seed"
	_seed_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_field.text = map_run.get_main_seed() if map_run else ""
	seed_row.add_child(_seed_field)
	seed_row.add_child(_button("开始新局", _new_run))
	_seed_field.text_submitted.connect(func(_text): _new_run())
	var floor_row := HBoxContainer.new()
	column.add_child(floor_row)
	_previous = _button("上一层", func(): _change_floor(map_run.current_floor - 1))
	floor_row.add_child(_previous)
	_next = _button("下一层", func(): _change_floor(map_run.current_floor + 1))
	floor_row.add_child(_next)
	_floor_label = Label.new()
	floor_row.add_child(_floor_label)
	var save_row := HBoxContainer.new()
	column.add_child(save_row)
	save_row.add_child(_button("暂存本局", _save_run))
	_restore_button = _button("恢复暂存", _restore_run)
	save_row.add_child(_restore_button)
	var note := Label.new()
	note.text = "完成本层 Boss 可换层；其余节点可保留"
	note.add_theme_font_size_override("font_size", 16)
	save_row.add_child(note)

func _process(delta: float) -> void:
	super._process(delta)
	if is_instance_valid(_floor_label):
		_refresh_run_controls()

func _physics_process(delta: float) -> void:
	if map_run == null or map_run.current_floor == 0:
		_advance_motion(Vector2.ZERO, delta)
		return
	super._physics_process(delta)

func _interact() -> void:
	if map_run == null or map_run.current_floor == 0:
		_show_toast("当前新局没有有效地图，请重新开始")
		return
	super._interact()

func _reset_map() -> void:
	if map_run != null and map_run.current_floor > 0:
		super._reset_map()

func _refresh_run_controls() -> void:
	var available: bool = map_run != null and map_run.current_floor > 0
	var blocked: bool = not available or not session.pending.is_empty()
	_previous.disabled = blocked or map_run.current_floor <= 1
	_next.disabled = blocked or map_run.current_floor >= map_run.floor_count() or not _boss_completed()
	_restore_button.disabled = _saved_run.is_empty() or not session.pending.is_empty()
	_floor_label.text = "第 %d / %d 层" % [map_run.current_floor, map_run.floor_count()] if available else "生成失败"

func _boss_completed() -> bool:
	for id in session.nodes:
		if session.nodes[id].type == "boss":
			return session.completed.has(id)
	return false

func _new_run() -> void:
	_seed_field.release_focus()
	if not session.pending.is_empty():
		_show_toast("请先完成或取消当前节点")
		return
	if not map_run.start_new_run(_seed_field.text, _floor_configs):
		_show_toast(map_run.last_error)
		return
	_seed_field.text = map_run.get_main_seed()
	var entry: Dictionary = map_run.enter_floor(1)
	if entry.is_empty():
		_show_toast(map_run.last_error)
		# New run has no valid floor; do not keep moving in the old seed map.
		_set_paused(true)
		return
	load_map(entry.snapshot, entry.state)
	_show_toast("新局已生成 · Seed 可复制复现")

func _change_floor(index: int) -> void:
	if index > map_run.current_floor and not _boss_completed():
		_show_toast("先完成本层 Boss，或继续探索")
		return
	var entry: Dictionary = map_run.enter_floor(index, capture_state())
	if entry.is_empty():
		_show_toast(map_run.last_error)
		return
	load_map(entry.snapshot, entry.state)
	_show_toast("第 %d 层 · 回访保留探索和节点状态" % index)

func _save_run() -> void:
	var saved: Dictionary = map_run.capture_snapshot(capture_state())
	if saved.is_empty():
		_show_toast(map_run.last_error)
		return
	_saved_run = saved
	_show_toast("本局已暂存内存；关闭程序后不保留")

func _restore_run() -> void:
	if not session.pending.is_empty():
		_show_toast("请先完成或取消当前节点")
		return
	if not map_run.restore_snapshot(_saved_run):
		_show_toast(map_run.last_error)
		return
	var entry: Dictionary = map_run.get_floor(map_run.current_floor)
	if not entry.is_empty():
		load_map(entry.snapshot, entry.state)
	_seed_field.text = map_run.get_main_seed()
	_show_toast("已恢复楼层、角色位置、探索与随机状态")

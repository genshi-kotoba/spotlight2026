extends "res://ui/main_menu/menu_map_entry.gd"
const SandboxLaunch = preload("res://systems/testing/sandbox_launch.gd")
const SandboxResources = preload("res://systems/testing/sandbox_resources.gd")
const Layout = preload("res://systems/testing/fixed_test_map_layout.gd")
const Policy = preload("res://systems/map/flat_2d/monster_encounters.gd")
const MapEventsCatalog = preload("res://systems/map/flat_2d/alchemy_event_catalog.gd")
var _region_buttons: Array[Button] = []
var _target_picker: OptionButton
var _target_map_id := ""

func _ready() -> void:
	super._ready()
	for control in find_children("*", "Button", true, false):
		if control.text == "重开本图": control.text = "测试菜单"

func _ensure_active_run() -> bool:
	if not SandboxLaunch.requested(): return false
	if _gateway.current_run() == null and _gateway.has_continuable_run():
		if _gateway.continue_saved_run() != OK: return false
	return SandboxResources.active(_gateway.current_run())

func _initial_snapshot() -> Dictionary:
	map_run = Run.new(ExistingSeedSource.new(), str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	var saved: Dictionary = _gateway.map_checkpoint()
	if saved.is_empty():
		saved = Layout.checkpoint(SeedService.capture_snapshot(), Policy.roster_from_catalog(TextCatalog.entries("monsters")))
	if saved.is_empty() or not map_run.restore_snapshot(saved):
		session.last_error = "固定测试地图无法载入：" + map_run.last_error
		return {}
	var entry: Dictionary = map_run.get_floor(map_run.current_floor)
	_saved_entry_state = entry.state.duplicate(true)
	return entry.snapshot

func _enable_monster_assignments() -> bool:
	# The fixed checkpoint already owns all identities; never run random allocation.
	return true

func _build_run_controls() -> void:
	var regions := HBoxContainer.new()
	_info_column.add_child(regions)
	for index in range(1, 5):
		var button: Button = _button(str(Layout.REGION_NAMES[index]), _change_floor.bind(index))
		regions.add_child(button)
		_region_buttons.append(button)
	_floor_label = Label.new()
	_info_column.add_child(_floor_label)
	var targets := HBoxContainer.new()
	_info_column.add_child(targets)
	_target_picker = OptionButton.new()
	_target_picker.custom_minimum_size.x = 360
	_target_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	CommonUiSkin.style_button(_target_picker, Vector4.ZERO)
	targets.add_child(_target_picker)
	targets.add_child(_button("传送到节点", _travel_to_selected))

func _refresh_run_controls() -> void:
	if _floor_label == null or map_run == null or map_run.current_floor <= 0: return
	var blocked: bool = not session.pending.is_empty() or _fast_travel_busy or not RunRewards.pending(_gateway.current_run()).is_empty()
	for index in _region_buttons.size():
		_region_buttons[index].disabled = blocked or index + 1 == map_run.current_floor
	_floor_label.text = "固定测试 · %s · 金币 / 万灵药 ∞ · 余额效果按1000计算" % Layout.REGION_NAMES[map_run.current_floor]
	_header.text = "固定测试地图 · " + str(Layout.REGION_NAMES[map_run.current_floor])
	if _target_map_id != session.map_id:
		_target_map_id = session.map_id
		_target_picker.clear()
		for node: Dictionary in session.get_snapshot().nodes:
			_target_picker.add_item(_node_title(node))
			_target_picker.set_item_metadata(_target_picker.item_count - 1, str(node.id))

func _node_title(node: Dictionary) -> String:
	if node.type in ["battle", "elite", "boss"]:
		return "%s · %s" % [{"battle": "普通", "elite": "精英", "boss": "Boss"}[node.type], TextCatalog.entry("monsters", str(node.content_id)).get("name", node.content_id)]
	if node.type == "event": return "事件 · " + MapEventsCatalog.display_name(str(node.event_kind))
	return str({"shop": "商店", "chest": "宝箱", "pile": "残堆"}.get(node.type, node.type))

func _travel_to_selected() -> void:
	if _target_picker.selected < 0: return
	_open_run_menu(0)
	_on_map_fast_travel(str(_target_picker.get_item_metadata(_target_picker.selected)), session.map_id, session.fingerprint)

func _change_floor(index: int) -> void:
	if map_run == null or index == map_run.current_floor or _fast_travel_busy or SceneTransition.is_loading(): return
	if not session.pending.is_empty() or not RunRewards.pending(_gateway.current_run()).is_empty():
		_show_toast("请先完成当前节点并领取奖励，再切换区域")
		return
	var entry: Dictionary = map_run.enter_floor(index, capture_state())
	if entry.is_empty():
		_show_toast(map_run.last_error)
		return
	_gateway.current_run().set_current_map(str(entry.snapshot.map_id))
	if not load_map(entry.snapshot, entry.state) or not EncounterFlow.bind_map(self):
		_show_toast("切换测试区域失败：" + EncounterFlow.last_error)
		return
	_gateway.save_current()
	_refresh_run_controls()

func _reset_map() -> void:
	# Restart through the test menu so reward and event ledgers stay coherent.
	_return_to_menu()

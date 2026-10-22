extends "res://tests/map_entry_input_selftest.gd"
## Exercise the real map feedback route, using a separate save and production HUD.
func _run() -> void:
	get_tree().current_scene = null
	fixture_root = "res://.godot/map-feedback-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("isolated save", SaveGateway.load_current() == OK)
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "map-feedback"
	_check("new run", SaveGateway.start_new_run("map-feedback", config) == OK)
	var map: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(map)
	get_tree().current_scene = map
	await _frames(12)
	map._show_toast("反馈路径：保存未完成，请重试")
	await get_tree().create_timer(0.35).timeout
	var visible_feedback := 0
	for label: Node in map._hud_root.find_children("*", "Label", true, false):
		if label.is_visible_in_tree() and label.text.contains("反馈路径：保存未完成，请重试"):
			visible_feedback += 1
	_check("map operation failure is actually visible", visible_feedback == 1)
	_check("debug panel stays hidden", not map._info_column.is_visible_in_tree())
	map._show_toast("保存失败，仍留在当前地图", true)
	await get_tree().create_timer(5.2).timeout
	_check("save error remains for reading", map._feedback_bar.visible and map._feedback_bar._label.text.contains("保存失败"))
	map._open_run_menu(2)
	await get_tree().create_timer(0.35).timeout
	var close: Button = map._feedback_bar.find_child("DismissFeedback", true, false)
	var point := close.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	_check("feedback close stays reachable after reopening menu", get_viewport().gui_get_hovered_control() == close)
	for pressed: bool in [true, false]:
		var click := InputEventMouseButton.new()
		click.position = point
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		get_viewport().push_input(click, true)
		await get_tree().process_frame
	_check("real GUI click dismisses feedback above menu", not map._feedback_bar.visible)
	var hint := preload("res://systems/map/relief_2d/node_interaction_hint.gd").new()
	get_tree().root.add_child(hint)
	hint.node_id = "visible-label"
	hint._name_rect = Rect2(-56, -19, 112, 38)
	hint._scale = 2.0
	hint.position = Vector2(500, 400)
	hint.scale = Vector2.ONE * 0.82
	hint.show()
	var edge: Vector2 = hint.get_global_transform_with_canvas() * Vector2(55 * 3, 18 * 3)
	_check("visible label edge is clickable under transforms", hint.contains_screen_point(edge))
	_check("outside label is not clickable", not hint.contains_screen_point(hint.get_global_transform_with_canvas() * Vector2(57 * 3, 20 * 3)))
	hint.queue_free()
	map.queue_free()
	await get_tree().process_frame
	print("MAP_FEEDBACK_RESULT failures=%d" % failures)
	get_tree().quit(failures)

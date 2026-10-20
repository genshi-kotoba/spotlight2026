extends "res://tests/monster_intent_native_selftest.gd"
## Real native hover, menu input, and shared Buff UI lifecycle regression.

func _run() -> void:
	output_root = "res://../verification/hover"
	DirAccess.make_dir_recursive_absolute(fixture_root)
	DirAccess.make_dir_recursive_absolute(output_root)
	SaveGateway.save_path = fixture_root.path_join("hover-%d.json" % Time.get_ticks_usec())
	_check("isolated hover save", SaveGateway.load_current() == OK)
	var board := RelicBoard.new()
	_check("empty hover relic board", board.save_to_file(fixture_root.path_join("empty-board.json")) == OK)
	for resolution: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		get_window().size = resolution
		if not await _new_battle({"tag": "hover", "ids": ["16", "4", "2"]}, resolution):
			_finish()
			return
		var random_slot := scene.enemy_rack.slots[1]
		var cell := random_slot.intent_strip.cells[0]
		await _hover(scene.enemy_rack.slots[0].intent_strip.cells[0])
		await _hover(cell)
		_check("main to rear keeps random detail", scene._intent_tip.visible and str(scene._intent_tip.get_node("TipLabel").text).contains("执行时随机"))
		await _click(scene._settings_button)
		_check("real settings click opens menu", scene._run_menu.is_open())
		await _hover(cell)
		_check("menu blocks intent hovering", not scene._intent_tip.visible)
		await _capture("menu-%d" % resolution.x)
		await _click(scene._run_menu._close_button)
		await _hover(cell)
		_check("menu close restores native hover", not scene._run_menu.is_open() and scene._intent_tip.visible)
		var context := BattleEffectContext.new(scene._battle, "", scene._resolver.buff_catalog)
		context.add_buff(&"player", "player", &"poison", 1)
		await _settled("player buff UI")
		await _hover(cell)
		if not _check("real buff rule creates a hover chip", scene.player_buff_row.get_child_count() > 0):
			_finish()
			return
		var buff := scene.player_buff_row.get_child(0) as Control
		await _hover(buff)
		_check("intent to buff preserves buff description", scene._buff_tip.visible and not scene._intent_tip.visible)
		await _hover(cell)
		_check("buff to intent preserves intent description", scene._intent_tip.visible and not scene._buff_tip.visible)
		await _capture("random-detail-%d" % resolution.x)
		_release_scene()
		await _frames(3)
	_finish()

func _finish() -> void:
	if _finished: return
	_finished = true
	_release_scene()
	var file := FileAccess.open(output_root.path_join("results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "images": images}, "\t"))
	print("INTENT HOVER: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)

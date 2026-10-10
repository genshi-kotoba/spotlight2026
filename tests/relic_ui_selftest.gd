extends Node

## 使用独立的缓存配置，避免覆盖玩家保存的典籍编排。
const FIXTURE_PATH := "res://.godot/relic_ui_fixture.json"
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://ui/relics/relic_test_scene.tscn") as PackedScene
	var page := packed.instantiate()
	add_child(page)
	await get_tree().process_frame
	page._load_example()
	_check("页面创建 12 个格子与五种残片", page._slots.size() == 12 and page._palette.size() == 5)
	page._palette[3].pressed.emit()
	page._slots[7].pressed.emit()
	_check("选择残片后点击格子可放置", page._board.cells[7] == "gain_block")
	page._slots[10].dropped.emit(10, {"relic_drag": true, "source": 7, "fragment_id": "gain_block"})
	_check("拖动换位沿 UI 信号链执行", page._board.cells[7].is_empty() and page._board.cells[10] == "gain_block")
	page._slots[10].gui_input.emit(_right_click())
	_check("右键移除残片", page._board.cells[10].is_empty())
	page._show_range(1)
	_check("触发范围提示展示连接数", page._detail.text.contains("2 个效果残片"))
	await _capture("res://.godot/relic_page_preview.png")
	_check("测试编排可保存", page._board.save_to_file(FIXTURE_PATH) == OK)
	page.free()

	var battle_packed := load("res://ui/battle/battle_test_scene.tscn") as PackedScene
	var battle_ui := battle_packed.instantiate() as BattleTestScene
	battle_ui.relic_board_path = FIXTURE_PATH
	add_child(battle_ui)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("战斗从保存配置读取 12 格构筑", battle_ui._relic_board.cells[0] == "turn_strength" and battle_ui._relic_board.cells[6] == "on_enemy_damaged")
	_check("首回合力量及首抽触发链完整生效", int(battle_ui._battle.enemies[0].health) == battle_ui.enemy_starting_health - 72 and int(battle_ui._battle.player.block) == 24)
	_check("HUD 显示 49 次残片生效", battle_ui._relic_title.text.contains("49") and not battle_ui._relic_events.is_empty())
	await _capture("res://.godot/relic_battle_preview.png")
	battle_ui.free()
	DirAccess.remove_absolute(FIXTURE_PATH)
	print("典籍界面联调全部通过" if failures == 0 else "典籍界面联调失败 %d 项" % failures)
	get_tree().quit(failures)


func _capture(path: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)


func _right_click() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.pressed = true
	event.button_index = MOUSE_BUTTON_RIGHT
	return event


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("  %s  %s" % ["通过" if passed else "失败", label])

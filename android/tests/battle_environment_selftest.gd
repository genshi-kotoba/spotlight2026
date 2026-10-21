extends Node
const Backgrounds = preload("res://ui/battle/battle_environment.gd")
const BATTLE = preload("res://ui/battle/battle_test_scene.tscn")
const PATHS := [
	"res://assets/env/ENV-001/ENV-001.PNG",
	"res://assets/env/ENV-002/ENV-002-2.png",
	"res://assets/env/ENV-003/ENV_003_01.PNG",
	"res://assets/env/ENV-004/ENV-004.JPG",
]
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	SaveGateway.save_path = "res://.godot/battle-environment-%d/game.json" % Time.get_ticks_usec()
	_check("使用隔离存档", SaveGateway.load_current() == OK)
	SeedService.begin_run("battle-environment-test")
	var before := JSON.stringify(SeedService.capture_snapshot())
	for index in range(1, 5):
		var texture := Backgrounds.texture_for_floor(index)
		_check("第%d层资源正确且已导入" % index, texture.resource_path == PATHS[index - 1] and texture.get_width() > 0)
		var saved: Dictionary = JSON.parse_string(JSON.stringify({"encounter_floor": index}))
		_check("第%d层保存字段兼容JSON数值" % index, Backgrounds.floor_for_battle(saved, "world:floor-001") == index)
		_check("第%d层旧战斗从原地图恢复" % index, Backgrounds.floor_for_battle({}, "world:floor-%03d" % index) == index)
	_check("外观选择不消耗种子随机流", before == JSON.stringify(SeedService.capture_snapshot()))
	_check("第二层保留原版并默认蓝调差分", Backgrounds.variants_for_floor(2).size() == 2 and Backgrounds.path_for_floor(2, 0) == Backgrounds.PATHS[1] and Backgrounds.path_for_floor(2) == PATHS[1])
	_check("第三层保留三种背景供检查器预览", Backgrounds.variants_for_floor(3).size() == 3 and Backgrounds.path_for_floor(3, 2).ends_with("ENV_003_02.JPG"))
	_check("越界差分索引安全回退", Backgrounds.path_for_floor(3, 99) == Backgrounds.PATHS[2])
	_check("异常楼层安全回退第一层", Backgrounds.texture_for_floor(0) == Backgrounds.texture_for_floor(1) and Backgrounds.texture_for_floor(5) == Backgrounds.texture_for_floor(1))
	_check("异常存档字段回退本场地图", Backgrounds.floor_for_battle({"encounter_floor": "2"}, "world:floor-003") == 3 and Backgrounds.floor_for_battle({"encounter_floor": 2.5}, "world:floor-003") == 3)
	_check("未知地图默认第一层", Backgrounds.floor_for_battle({}, "battle-effects-ui-test") == 1)
	for index in range(1, 5):
		var ui := BATTLE.instantiate() as BattleTestScene
		ui.test_floor_index = index
		ui.relic_board_path = "res://.godot/battle-environment-empty-relic.json"
		add_child(ui)
		await get_tree().process_frame
		_check("第%d层战斗实际显示对应背景" % index, ui.get_node("Background").texture.resource_path == PATHS[index - 1])
		_check("背景不遮挡交互与漂浮文本", ui.get_node("Background").mouse_filter == Control.MOUSE_FILTER_IGNORE and ui.get_node("Background").z_index == -4)
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://.godot/battle-environment-floor-%d.png" % index)
		ui.queue_free()
		await get_tree().process_frame
	print("战斗分层背景：全部通过" if failures == 0 else "战斗分层背景：失败%d项" % failures)
	get_tree().quit(failures)

func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])

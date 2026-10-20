extends "res://ui/main_menu/main_menu.gd"
const SandboxLaunch = preload("res://systems/testing/sandbox_launch.gd")
const Resources = preload("res://systems/testing/sandbox_resources.gd")

func _ready() -> void:
	if not SandboxLaunch.requested():
		SceneTransition.call_deferred("change_scene_to_file", "res://ui/main_menu/main_menu.tscn")
		return
	game_scene = SandboxLaunch.MAP
	super._ready()
	_new_game_button.text = "新建固定测试"
	_continue_button.text = "继续固定测试"
	credits_notice = "固定四区域、44节点；金币与万灵药无限。\nM 地图传送，E 进入节点，Tab 背包。\n金币相关效果按1000计算。测试存档独立保存。"
	_credits_button.text = "测试说明"
	if not _gateway.has_continuable_run():
		call_deferred("_start_new_run")

func _new_seed_text() -> String:
	return "fixed-test-map-v1"

func _new_run_config() -> Dictionary:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "sandbox-%d-%d" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
	config.initial_gold = Resources.RESERVE
	config.map_ids = SandboxLaunch.MAP_IDS.duplicate()
	config.fixed_test_sandbox = 1
	# Only the starting inventory is random. It has its own disposable seed context.
	var source := SeedRegistry.new(str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	source.begin_run()
	var rng: RandomStream = source.get_stream(&"rewards.pool", ["sandbox-starting-items"])
	var initial: Array = []
	for index in 10:
		initial.append({"item_id": "sandbox-fragment-%02d" % index, "kind": "fragment", "fragment_id": RelicCatalog.generate(rng)})
	for index in 5:
		initial.append({"item_id": "sandbox-potion-%02d" % index, "kind": "potion", "potion": index if index < 4 else int(rng.int_range(0, 4))})
	for index in 2:
		initial.append({"item_id": "sandbox-common-%d" % index, "kind": "common_pack", "options": [], "rerolled": false})
	initial.append({"item_id": "sandbox-rare-0", "kind": "rare_pack", "options": [], "rerolled": false})
	config.initial_items = initial
	return config

func _enter_game() -> void:
	var run: RunStateMachine = _gateway.current_run()
	if run == null or not run.run_id.begins_with("sandbox-"): return
	run.inventory_state["fixed_test_sandbox"] = 1
	Resources.refill(run)
	if _gateway.save_current() != OK: return
	super._enter_game()

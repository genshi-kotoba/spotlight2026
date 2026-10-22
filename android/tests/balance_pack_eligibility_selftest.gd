extends Node
## Regression: the requested boss tuning and reward provenance, with isolated saves.
var failures := 0
var checks := 0

func _ready() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks += 1
	if passed: print("PASS ", label)
	else:
		failures += 1
		push_error("FAIL " + label)

func _run() -> void:
	var stone := MonsterCatalog.create("1", 1)
	_check("贤者之石96生命", stone.health == 96 and stone.max_health == 96)
	_check("贤者之石基础攻击4伤", stone.actions[0].damage == 4)
	var source := SeedRegistry.new("balance-pack-regression")
	source.begin_run("stone-plan")
	var plan1 := MonsterCatalog.plan(stone, 1, source.get_stream(RandomDomains.BATTLE_LOGIC, ["stone"]))
	var plan2 := MonsterCatalog.plan(stone, 2, source.get_stream(RandomDomains.BATTLE_LOGIC, ["stone-2"]))
	_check("贤者之石双行动仍各4伤", plan1.size() == 2 and plan1[0].damage == 4 and plan1[1].damage == 4)
	_check("偶数回合召唤不变", plan2.size() == 2 and plan2[0].damage == 4 and plan2[1].get("summon") == "4")
	var common := RunRewards._card_pool("common_pack")
	var rare := RunRewards._card_pool("rare_pack")
	_check("正常卡池不混入三张负面牌", not common.has("68") and not common.has("69") and not common.has("70") and not rare.has("68") and not rare.has("69") and not rare.has("70"))
	_check("自伤代价的正常卡保留", ["14", "15", "16", "17", "18"].all(func(id): return common.has(id)))
	var catalog := FormalCardCatalog.load_definitions()
	_check("负面牌底层定义与事件用途保留", ["68", "69", "70"].all(func(id): return catalog.cards.has(id)))
	SaveGateway.save_path = "res://.godot/balance-pack-regression/game.json"
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "balance-pack-regression"
	config.initial_items = []
	_check("隔离新局", SaveGateway.start_new_run("pack-eligibility", config) == OK)
	var run := SaveGateway.current_run()
	for index in 32:
		var id := "eligibility-%d" % index
		run.items.append({"item_id": id, "kind": "common_pack", "options": [], "rerolled": false})
		_check("新包打开%d" % index, RunRewards.open_pack(run, id) == OK)
		var options: Array = RunRewards.item(run, id).options
		_check("新包三选一均为正常卡%d" % index, options.size() == 3 and options.all(func(choice): return choice in common and choice not in ["68", "69", "70"]))
		var before := JSON.stringify(options)
		_check("同包重开不重抽%d" % index, RunRewards.open_pack(run, id) == OK and JSON.stringify(RunRewards.item(run, id).options) == before)
	run.items.append({"item_id":"legacy-negative", "kind":"common_pack", "options":["1", "68", "50"], "rerolled":true})
	run.items.append({"item_id":"legacy-reject", "kind":"common_pack", "options":["1", "68", "50"], "rerolled":false})
	_check("旧包负面选项不能直接领取", RunRewards.choose(run, "legacy-reject", "68") == ERR_INVALID_DATA)
	var old_error: Error = SaveGateway._load_error
	SaveGateway._load_error = ERR_CANT_OPEN
	_check("旧候选修复保存失败回滚", RunRewards.open_pack(run, "legacy-negative") != OK and RunRewards.item(run, "legacy-negative").options == ["1", "68", "50"])
	SaveGateway._load_error = old_error
	_check("旧候选打开时修复", RunRewards.open_pack(run, "legacy-negative") == OK)
	var repaired := RunRewards.item(run, "legacy-negative")
	_check("仅替换非法候选且不恢复刷新次数", repaired.options.size() == 3 and repaired.options.has("1") and repaired.options.has("50") and repaired.options.all(func(choice): return choice in common and choice not in ["68", "69", "70"]) and repaired.rerolled)
	var repaired_json := JSON.stringify(repaired.options)
	var restore_error: Error = SaveGateway.load_current()
	if restore_error == OK: restore_error = SaveGateway.continue_saved_run()
	_check("修复后冷恢复不重抽", restore_error == OK and JSON.stringify(RunRewards.item(SaveGateway.current_run(), "legacy-negative").get("options", [])) == repaired_json)
	run = SaveGateway.current_run()
	if not is_instance_valid(run):
		get_tree().quit(failures + 1)
		return
	var deck_count := run.deck.size()
	_check("合法候选只入牌组一次", RunRewards.choose(run, "legacy-negative", "1") == OK and run.deck.size() == deck_count + 1 and RunRewards.choose(run, "legacy-negative", "1") == ERR_DOES_NOT_EXIST)
	for index in 12:
		var shelf := RunShop.generate("eligibility-%d" % index, "world:floor-001", "shop", 1)
		_check("共享正常卡池的商店不生成负面牌%d" % index, shelf.cards.all(func(card): return str(card.id) not in ["68", "69", "70"]))
	print("BALANCE_PACK_ELIGIBILITY_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

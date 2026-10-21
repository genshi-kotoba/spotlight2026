extends Node
var failures := 0

func _ready() -> void:
	var source := SeedRegistry.new("build-compat-v1")
	source.begin_run("same-source-same-rng")
	var stream := source.get_stream(&"test.compatibility", ["shop", 1])
	for index: int in 17: stream.int_range(0, 1000000)
	var snapshot := source.capture_snapshot()
	var expected: Array = []
	for index: int in 64: expected.append(stream.int_range(0, 1000000))
	var build := String(snapshot.engine_build).split("|", true)
	var version := SeedRegistry._engine_version_without_distribution(build[0])
	for channel: String in ["steam", "official"]:
		var legacy := snapshot.duplicate(true)
		legacy.engine_build = "%s (%s)|%s" % [version, channel, build[1]]
		var restored := SeedRegistry.new("build-compat-v1")
		_check(channel + " 同源码提交可恢复", restored.restore_snapshot(legacy) == OK)
		var actual: Array = []
		var next := restored.get_stream(&"test.compatibility", ["shop", 1])
		if next != null:
			for index: int in 64: actual.append(next.int_range(0, 1000000))
		_check(channel + " 恢复不改变后续64次随机结果", actual == expected)
	var cases: Array[Dictionary] = [
		{"engine_build": version + " (official)|" + "0".repeat(40)},
		{"engine_build": "0.0.0-stable (official)|" + build[1]},
		{"engine_build": version + " (custom)|" + build[1]},
		{"rng_protocol_version": 999},
		{"snapshot_version": 999},
		{"content_version": "different-content"},
		{"engine_build": null},
	]
	for fields: Dictionary in cases:
		var bad := snapshot.duplicate(true)
		bad.merge(fields, true)
		var target := SeedRegistry.new("build-compat-v1")
		target.begin_run("untouched")
		var before := JSON.stringify(target.capture_snapshot())
		_check("不同构建或协议仍拒绝：" + str(fields), target.restore_snapshot(bad) == ERR_INVALID_DATA and JSON.stringify(target.capture_snapshot()) == before)
	SeedService.begin_run("existing-map-context")
	var held := SeedService.get_stream(&"test.compatibility", ["already-held"])
	held.int_range(0, 100)
	var context := SeedService.capture_snapshot()
	var context_build := String(context.engine_build).split("|", true)
	context.engine_build = "%s (official)|%s" % [version, context_build[1]]
	var adapter := preload("res://ui/main_menu/menu_map_entry.gd").ExistingSeedSource.new()
	_check("地图适配层接受同提交不同渠道快照", adapter.restore_snapshot(context) == OK)
	_check("地图校验不重装全局上下文或作废旧流", held == SeedService.get_stream(&"test.compatibility", ["already-held"]))
	var changed := context.duplicate(true)
	changed.main_seed = "different-run"
	_check("地图适配层仍拒绝不同随机上下文", adapter.restore_snapshot(changed) == ERR_INVALID_DATA)
	print("SEED_BUILD_COMPATIBILITY failures=", failures)
	get_tree().quit(failures)

func _check(label: String, passed: bool) -> void:
	if not passed: failures += 1
	print("PASS " + label if passed else "FAIL " + label)

extends Node
## 使用独立 user:// 和显式存档夹具，不访问玩家文件。
var checks := 0
var failures := 0
var starts: Array[String] = []
var skips: Array[String] = []

class MapHost extends Node:
	var ready_for_title := false
	var map_id := "world:floor-001"
	var seed := "region-title-fixture"
	func region_title_context() -> Dictionary:
		return {"map_id": map_id, "seed": seed}
	func is_region_title_ready() -> bool:
		return ready_for_title

func _ready() -> void:
	call_deferred("_run")

func _check(label: String, condition: bool) -> void:
	checks += 1
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		push_error("FAIL " + label)

func _frames(count := 3) -> void:
	for index in count:
		await get_tree().process_frame

func _fixture() -> Dictionary:
	return {"version": 1, "enabled": true,
		"map_regions": {"world:floor-001": "qa.monastery", "world:floor-002": "qa.crypt"},
		"regions": {"qa.monastery": {"title": "灰烬修道院", "eyebrow": "第一层", "subtitle": "外庭"},
			"qa.crypt": {"title": "静默墓室"}},
		"style": {"duration": 2.5, "font_size": 68, "reduced_motion": false}}

func _run() -> void:
	SaveGateway.save_path = "user://region-title-fixture-%d/game.json" % Time.get_ticks_usec()
	_check("独立存档载入", SaveGateway.load_current() == OK)
	_check("正式四层地区配置已启用", RegionTitles.is_enabled())
	var production: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/region_titles.json"))
	var run_config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	var expected := [
		["world:floor-001", "alchemy_workshop", "炼金工坊", "地底"],
		["world:floor-002", "elbak_slums", "贫民窟", "埃尔巴克"],
		["world:floor-003", "nock_cathedral", "诺克大教堂", "祷告厅"],
		["world:floor-004", "cathedral_summit", "教堂顶端", "神临"]]
	_check("四层映射覆盖正式新局", production.map_regions.size() == 4 and run_config.map_ids.size() == 4)
	for row: Array in expected:
		var region: Dictionary = production.regions.get(row[1], {})
		_check("正式文案与楼层对应 " + row[0], run_config.map_ids.has(row[0]) and production.map_regions.get(row[0]) == row[1] and region.get("title") == row[2] and region.get("subtitle") == row[3])
	RegionTitles.configure({"version": 1, "enabled": false, "map_regions": {}, "regions": {}})
	var host := MapHost.new()
	get_tree().root.add_child(host)
	var original := get_tree().current_scene
	get_tree().current_scene = host
	var before := GlobalState.capture_save_data()
	RegionTitles.track_map(host)
	await _frames()
	_check("关闭时不处理、不创建标题节点", not RegionTitles.is_processing() and RegionTitles.get_child_count() == 0)
	_check("关闭时不写首次记录或存档", GlobalState.capture_save_data() == before and not FileAccess.file_exists(SaveGateway.save_path))
	_check("空记录不增加旧存档字段", not before.has("seen_region_titles"))
	var invalid := _fixture()
	invalid.map_regions["world:floor-001"] = "missing.region"
	_check("无效映射安全关闭", RegionTitles.configure(invalid) == ERR_INVALID_DATA and not RegionTitles.is_enabled())
	invalid = _fixture()
	invalid.style.duration = "fast"
	_check("动效非法参数拒绝", RegionTitles.configure(invalid) == ERR_INVALID_DATA)
	invalid = _fixture()
	invalid.regions["qa.monastery"].title = ""
	_check("空地区标题拒绝", RegionTitles.configure(invalid) == ERR_INVALID_DATA)
	_check("夹具可显式启用", RegionTitles.configure(_fixture()) == OK)
	RegionTitles.title_started.connect(func(id: String): starts.append(id))
	RegionTitles.title_skipped.connect(func(id: String, _reason: String): skips.append(id))
	RegionTitles.track_map(host)
	await _frames()
	_check("地图未就绪不消费首次记录", starts.is_empty() and not GlobalState.has_seen_region_title("qa.monastery"))
	host.ready_for_title = true
	await _frames()
	_check("就绪后仅播放一次", starts == ["qa.monastery"] and RegionTitles._overlay != null)
	var overlay := RegionTitles._overlay
	_check("纯表现节点不拦鼠标", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE and overlay._texture.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	var disk := SaveGateway._read_json(SaveGateway.save_path)
	_check("首次记录已随完整存档落盘", disk.error == OK and disk.data.get("seen_region_titles") == ["qa.monastery"])
	RegionTitles.track_map(host)
	await _frames()
	_check("重复事件不叠加标题", starts.size() == 1 and RegionTitles._overlay == overlay)
	await get_tree().create_timer(2.8).timeout
	await _frames()
	_check("淡出后释放纹理与节点并停止处理", RegionTitles.get_child_count() == 0 and not RegionTitles.is_processing())
	host.seed = "another-run-seed"
	RegionTitles.track_map(host)
	await _frames()
	_check("同地区换种子不重播", starts.size() == 1 and RegionTitles._overlay == null)
	var candidate := GlobalStateMachine.new()
	candidate.save_path = SaveGateway.save_path
	_check("冷恢复保留首次记录", candidate.load_save() == OK and candidate.has_seen_region_title("qa.monastery"))
	var modern := candidate.capture_save_data()
	var corrupt := modern.duplicate(true)
	corrupt.seen_region_titles = ["qa.monastery", "qa.monastery"]
	_check("重复地区记录拒绝且不部分安装", candidate._install_save(corrupt) == ERR_INVALID_DATA and candidate.capture_save_data() == modern)
	corrupt.seen_region_titles = ["Bad ID"]
	_check("非法语义 ID 拒绝", candidate._install_save(corrupt) == ERR_INVALID_DATA and candidate.capture_save_data() == modern)
	corrupt.seen_region_titles = "invalid"
	_check("错误记录类型拒绝", candidate._install_save(corrupt) == ERR_INVALID_DATA)
	var legacy := modern.duplicate(true)
	legacy.erase("seen_region_titles")
	_check("旧 v1 存档缺省兼容", candidate._install_save(legacy) == OK and candidate.seen_region_titles.is_empty())
	candidate.free()
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "region-title-new-run-fixture"
	_check("新开一局仍保留全局首次记录", SaveGateway.start_new_run("region-title-new-run-fixture", config, true) == OK and GlobalState.has_seen_region_title("qa.monastery"))
	_check("放弃本局仍保留首次记录", SaveGateway.abandon_run() == OK and GlobalState.has_seen_region_title("qa.monastery"))
	host.map_id = "world:floor-002"
	RegionTitles.track_map(host)
	await _frames()
	_check("不同地区可分别首次播放", starts == ["qa.monastery", "qa.crypt"])
	host.queue_free()
	await _frames()
	_check("退出地图立即清理表现与处理", RegionTitles.get_child_count() == 0 and not RegionTitles.is_processing())
	get_tree().current_scene = original
	_check("再次读档不丢地区历史", SaveGateway.load_current() == OK and GlobalState.has_seen_region_title("qa.crypt"))
	var failure_state := GlobalStateMachine.new()
	var blocker := "user://region-title-blocker"
	var file := FileAccess.open(blocker, FileAccess.WRITE)
	file.store_string("preserve-blocker")
	file = null
	failure_state.save_path = blocker.path_join("game.json")
	_check("保存失败撤销首次记录", failure_state.remember_region_title("qa.failure") != OK and not failure_state.has_seen_region_title("qa.failure"))
	_check("保存失败不损毁已有文件", FileAccess.get_file_as_string(blocker) == "preserve-blocker")
	failure_state.free()
	_check("非法记录 API 无副作用", GlobalState.remember_region_title("bad id") == ERR_INVALID_PARAMETER and not GlobalState.has_seen_region_title("bad id"))
	# 过期候选、真实网关写入失败都不能误消费标题。
	var failed_config := _fixture()
	failed_config.map_regions["world:floor-003"] = "qa.failure"
	failed_config.regions["qa.failure"] = {"title": "失败夹具"}
	_check("失败夹具配置可载入", RegionTitles.configure(failed_config) == OK)
	host = MapHost.new()
	host.map_id = "world:floor-003"
	get_tree().root.add_child(host)
	get_tree().current_scene = host
	RegionTitles.track_map(host)
	host.map_id = "world:floor-unmapped"
	await _frames()
	_check("等待中换图取消过期候选", not RegionTitles.is_processing() and not GlobalState.has_seen_region_title("qa.failure"))
	host.map_id = "world:floor-003"
	host.ready_for_title = true
	var good_save := SaveGateway.save_path
	SaveGateway.save_path = blocker.path_join("game.json")
	var start_count := starts.size()
	RegionTitles.track_map(host)
	await _frames()
	_check("网关保存失败不播放也不记录", starts.size() == start_count and skips.has("qa.failure") and not GlobalState.has_seen_region_title("qa.failure") and RegionTitles._overlay == null)
	SaveGateway.save_path = good_save
	host.queue_free()
	await _frames()
	get_tree().current_scene = original

	RegionTitles.configure({"version": 1, "enabled": false, "map_regions": {}, "regions": {}})
	_check("关闭不擦除已有首次记录", not RegionTitles.is_enabled() and GlobalState.has_seen_region_title("qa.monastery"))
	print("REGION_TITLE_RESULT checks=", checks, " failures=", failures)
	get_tree().quit(1 if failures else 0)

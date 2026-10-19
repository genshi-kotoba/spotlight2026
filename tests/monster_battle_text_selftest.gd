extends Node

var failures := 0
var fixture_root := ""
const SOURCE := "res://assets/chr/CHR-025.txt"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	get_window().size = Vector2i(1920, 1080)
	fixture_root = "res://.godot/monster-text-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(fixture_root)
	SaveGateway.save_path = fixture_root.path_join("game.json")
	_check("独立测试存档", SaveGateway.load_current() == OK)
	EncounterFlow.relic_board_path = fixture_root.path_join("empty-board.json")
	_check("句号换行、分号换行、BOM、CRLF与尾句", MonsterBattleText.parse_sentences("\uFEFF甲；\r\n乙。\r\n丙。行内句号不拆。\n尾句") == ["甲；\n乙。", "丙。行内句号不拆。", "尾句"])
	_check("问号感叹号加换行结束一句", MonsterBattleText.parse_sentences("谁？\n我！\n结束。\n") == ["谁？", "我！", "结束。"])
	for ending: String in ["。", "｡", ".", "．", "！", "!", "？", "?"]:
		_check("全半角结束标点%s支持BOM、CRLF与行尾空格" % ending, MonsterBattleText.parse_sentences("\uFEFF甲%s  \r\n乙%s\n尾句" % [ending, ending]) == ["甲" + ending, "乙" + ending, "尾句"])
	_check("没有换行的问号感叹号句号不拆句", MonsterBattleText.parse_sentences("谁？我!为何？看！甲.乙．丙｡丁。\n尾句") == ["谁？我!为何？看！甲.乙．丙｡丁。", "尾句"])
	_check("分号换行仍保留在同一句", MonsterBattleText.parse_sentences("谁？；\n我!;\n回答！\n下句?\n") == ["谁？；\n我!;\n回答！", "下句?"])
	_check("没有结束标点的普通换行仍合并", MonsterBattleText.parse_sentences("甲\n乙!\n丙\n丁?\n") == ["甲乙!", "丙丁?"])
	_check("空白不产生候选句", MonsterBattleText.parse_sentences("\n \r\n").is_empty())
	_check("半角标点和末尾没有换行", MonsterBattleText.parse_sentences("A;\nB.\nC") == ["A;\nB.", "C"])
	_check("旧档编号变动以图片绑定TXT", TextCatalog.monster_battle_text_path({"enemy_id": "1", "art_path": "res://assets/chr/CHR-016.png"}) == "res://assets/chr/CHR-016.txt")
	var scene: BattleTestScene = load("res://ui/battle/battle_test_scene.tscn").instantiate()
	scene.relic_board_path = EncounterFlow.relic_board_path
	add_child(scene)
	await _frames(5)
	var overlay: MonsterBattleText = scene._monster_text
	overlay.set_process(false)
	_check("逐字放慢至0.16秒、句间3秒，保留0.1秒抖动和1秒淡出", is_equal_approx(overlay.character_interval, 0.16) and is_equal_approx(overlay.perturb_interval, 0.1) and MonsterBattleText.NEXT_DELAY == 3.0 and MonsterBattleText.FADE_DURATION == 1.0)
	_check("测试场景加载CHR025真实TXT", overlay.source_path == SOURCE and not overlay.sentences.is_empty())
	_check("鼠标穿透，背景和敌人之上、所有UI之下", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE and scene.get_node("Background").z_index < scene.get_node("EnemyPortrait").z_index and scene.get_node("EnemyPortrait").z_index < overlay.z_index and overlay.z_index < scene.hand_scroll.z_index)
	var before := JSON.stringify(SeedService.capture_snapshot())
	var context := scene._monster_text_context()
	var viewport_area: Rect2 = scene.get_global_transform_with_canvas().affine_inverse() * scene.get_viewport_rect()
	var original_size := scene.size
	scene.size = Vector2(1920, 1920)
	_check("场景高于窗口时，文字区域仍限制在真实视口内", viewport_area.encloses(scene._monster_text_context().area))
	scene.size = original_size
	context = scene._monster_text_context()
	_check("手牌放大区域和出牌区始终保留", not MonsterBattleText.is_safe(Rect2(500, 620, 40, 40), context.area, context.blockers) and not MonsterBattleText.is_safe(Rect2(1780, 240, 40, 40), context.area, context.blockers))
	var equal := _new_overlay(scene._monster_text_context)
	overlay.configure(SOURCE, "reproducible", ["map", "node", 0])
	equal.configure(SOURCE, "reproducible", ["map", "node", 0])
	var deterministic := true
	var safe := true
	var animated := true
	var counts := {}
	var positions := {}
	var font_sizes := {}
	var angles := {}
	var geometry_safe := true
	var atlas_safe := true
	var off_center := true
	var side_counts := [0, 0]
	var no_recent_repeat := true
	var recent: Array[String] = []
	var readable := true
	for i in 500:
		overlay.advance(0.001)
		equal.advance(0.001)
		if overlay.active_sentences.is_empty():
			safe = false
			break
		var sentence: Dictionary = overlay.active_sentences.back()
		deterministic = deterministic and _presentation_snapshot(sentence) == _presentation_snapshot(equal.active_sentences.back())
		safe = safe and MonsterBattleText.is_safe(sentence.bounds, context.area, context.blockers)
		off_center = off_center and not MonsterBattleText.center_exclusion(context.area).has_point(Rect2(sentence.bounds).get_center())
		side_counts[int(sentence.side)] += 1
		readable = readable and float(sentence.font_size) * float(sentence.render_scale) >= 18.0
		no_recent_repeat = no_recent_repeat and not recent.has(str(sentence.text))
		recent.append(str(sentence.text))
		if recent.size() > 4:
			recent.pop_front()
		counts[sentence.text] = int(counts.get(sentence.text, 0)) + 1
		positions[str(sentence.bounds.position)] = true
		font_sizes[sentence.font_size] = true
		angles[sentence.angle] = true
		animated = animated and sentence.font_size >= MonsterBattleText.FONT_MIN and sentence.font_size <= MonsterBattleText.FONT_MAX and sentence.angle >= deg_to_rad(-15) and sentence.angle <= deg_to_rad(14)
		for index in sentence.glyphs.size():
			var glyph: Dictionary = sentence.glyphs[index]
			if Vector2(glyph.quad_half).x > 0.0 and Vector2(glyph.quad_half).y > 0.0:
				atlas_safe = atlas_safe and RID(glyph.texture_rid).is_valid() and glyph.texture_uvs.size() == 4
				for uv: Vector2 in glyph.texture_uvs:
					atlas_safe = atlas_safe and uv.x >= 0.0 and uv.y >= 0.0 and uv.x <= 1.0 and uv.y <= 1.0
			var pose := overlay.glyph_pose(sentence, index, float(sentence.started) + 0.125)
			animated = animated and absf(pose.angle) <= deg_to_rad(5.0) and absf(pose.offset.x) <= 1.0 and absf(pose.offset.y) <= 1.0 and pose.scale >= 1.0 and pose.scale <= 1.2
		for sample: float in [0.0, 0.15, float(sentence.complete) - float(sentence.started), float(sentence.display_done) - float(sentence.started)]:
			geometry_safe = geometry_safe and _glyph_geometry_safe(overlay, sentence, float(sentence.started) + sample)
		var step := float(sentence.display_done) + 0.0001 - overlay._time
		overlay.advance(step)
		equal.advance(step)
	_check("500句布局完整留在屏内且避开所有UI", safe)
	_check("同种子、身份、时间线逐字参数完全可复现", deterministic)
	_check("500句随机字号200至240、整句倾角和单字扰动范围正确", animated and font_sizes.size() >= 35 and angles.size() >= 25)
	_check("500句左右都持续出现，狭窄侧可为可读字号回退", side_counts[0] > 100 and side_counts[1] > 100)
	_check("真实1920x1080战场，500句实际字号不再缩到几像素", readable)
	_check("500句均不重复最近4句", no_recent_repeat)
	_check("500句文字中心均左右偏置，不挤进中央窄缝", off_center)
	var ink := MonsterBattleText.glyph_ink_colors(1.0)
	var fading_ink := MonsterBattleText.glyph_ink_colors(0.5)
	_check("字形从上到下金至红渐变，保留60%基础透明度", ink.size() == 4 and ink[0] == ink[1] and ink[2] == ink[3] and ink[0].is_equal_approx(Color(Color("e8bc58"), 0.6)) and ink[2].is_equal_approx(Color(Color("c4313b"), 0.6)))
	_check("渐变两端同步淡出，不改变色相", is_equal_approx(fading_ink[0].a, 0.3) and is_equal_approx(fading_ink[2].a, 0.3) and fading_ink[0].r == ink[0].r and fading_ink[2].r == ink[2].r and MonsterBattleText.glyph_ink_colors(0.0)[0].a == 0.0)
	_check("逐字重排、字形中心旋转及尺寸脉冲始终在安全包围盒内", geometry_safe)
	_check("渐变字形使用有效字体图集且四角UV不越界", atlas_safe)
	_check("随机位置持续变化而非小池循环", positions.size() > 450)
	var distribution := counts.size() == overlay.sentences.size()
	var expected := 500.0 / overlay.sentences.size()
	for count: int in counts.values():
		distribution = distribution and absf(count - expected) < expected * 0.65
	_check("防重复随机抽样覆盖全部句子且无明显偏斜", distribution)
	_check("动画不改变玩法随机快照", JSON.stringify(SeedService.capture_snapshot()) == before)
	_check("私有随机流数量固定，不随500句播放增长", overlay._random.capture_snapshot().streams.size() == 2)
	overlay.configure(SOURCE, "reproducible", ["map", "node", 0])
	overlay.advance(0.001)
	equal.configure(SOURCE, "another-seed", ["map", "node", 0])
	equal.advance(0.001)
	_check("不同种子改变字形和位置", _presentation_snapshot(equal.active_sentences.back()) != _presentation_snapshot(overlay.active_sentences.back()))
	equal.configure(SOURCE, "reproducible", ["map", "different-node", 0])
	equal.advance(0.001)
	_check("不同战斗节点使用独立表现种子", _presentation_snapshot(equal.active_sentences.back()) != _presentation_snapshot(overlay.active_sentences.back()))
	var motion_sentence: Dictionary = overlay.active_sentences.back()
	var motion_start := float(motion_sentence.started)
	_check("离散更新：同一0.1秒片内姿态固定，跨片重新采样", overlay.glyph_pose(motion_sentence, 0, motion_start + 0.11) == overlay.glyph_pose(motion_sentence, 0, motion_start + 0.19) and overlay.glyph_pose(motion_sentence, 0, motion_start + 0.21) != overlay.glyph_pose(motion_sentence, 0, motion_start + 0.19))
	_check("姿态查询与绘制不推进任何随机流", JSON.stringify(SeedService.capture_snapshot()) == before)
	var layout := overlay._layout("甲 乙；\n丙。", 40)
	_check("首字立即出现、普通空格零等待、显式换行参与时序", layout.glyphs[0].reveal_at == 0.0 and is_equal_approx(layout.typing_duration, 0.96))
	_check_small_pools(scene._monster_text_context)
	_check_short_sentence_sizing()
	_check_side_scale_balance(scene._monster_text_context)
	_check_layout_fallbacks()
	var joined := MonsterBattleText.free_regions(Rect2(0, 0, 1000, 600), [Rect2(100, 0, 100, 100), Rect2(700, 0, 100, 200)])
	_check("安全区域分片重新扩展，恢复底部整片连续空白", joined.any(func(region: Rect2): return region.encloses(Rect2(12, 200, 976, 388))))
	equal.configure(SOURCE, "long-line", ["fit"])
	equal.sentences.assign(["没有分号换行的长句".repeat(40) + "。"])
	equal.advance(0.001)
	var long_sentence: Dictionary = equal.active_sentences.back()
	_check("超长句完整单行自适应，不折行不截断", _source_lines_only(long_sentence) and long_sentence.glyphs.size() == long_sentence.text.length() and long_sentence.render_scale < 1.0 and MonsterBattleText.is_safe(long_sentence.bounds, context.area, context.blockers))
	equal.configure(SOURCE, "explicit-lines", ["fit"])
	equal.sentences.assign(MonsterBattleText.parse_sentences("第一行很长；\n第二行仍是同一句；\n第三行结束。"))
	equal.advance(0.001)
	_check("只有分号加换行产生显式显示换行", _source_lines_only(equal.active_sentences.back()) and str(equal.active_sentences.back().text).count("\n") == 2)
	equal.free()
	# 所有正式怪物文本都能读取、解析，并在实际战场安全区完整排版。
	var all_loaded := true
	var source_lines_only := true
	var captured_long_line := false
	for record: Dictionary in TextCatalog.entries("monsters"):
		overlay.configure(record.battle_text_path, "all-monsters", [record.id])
		for sentence: String in overlay.sentences.duplicate():
			overlay.configure(record.battle_text_path, "all-monsters", [record.id, sentence])
			overlay.sentences.assign([sentence])
			overlay.advance(0.001)
			all_loaded = all_loaded and overlay.last_error == OK and not overlay.active_sentences.is_empty()
			if not overlay.active_sentences.is_empty():
				var current: Dictionary = overlay.active_sentences.back()
				all_loaded = all_loaded and current.text == sentence and MonsterBattleText.is_safe(current.bounds, context.area, context.blockers) and not MonsterBattleText.center_exclusion(context.area).has_point(Rect2(current.bounds).get_center())
				source_lines_only = source_lines_only and _source_lines_only(current)
				if not captured_long_line and sentence.length() >= 38 and not sentence.contains("\n"):
					overlay.advance(float(current.complete) - overlay._time)
					await _capture("battle-text-long-single-line.png")
					captured_long_line = true
	_check("23个TXT中的每句都能完整排入真实安全区域", all_loaded)
	_check("23份正式TXT均无额外折行，仅保留分号换行", source_lines_only)
	# 放慢后的地图调度：首字立即 -> 逐字 -> 等待3秒 -> 新句/旧句同时淡出。
	overlay.configure(SOURCE, "timeline", ["ui"])
	overlay.advance(0.001)
	var first: Dictionary = overlay.active_sentences[0].duplicate(true)
	_check("首字立即显示而非整句瞬间出现", first.glyphs[0].reveal_at == 0.0 and first.complete > overlay._time)
	overlay.advance(0.45)
	await _capture("battle-text-typing.png")
	overlay.advance(float(first.complete) - overlay._time)
	await _capture("battle-text-complete.png")
	overlay.advance(0.2)
	await _capture("battle-text-drift.png")
	_check("单句兜底：显示协程结束后3+3秒启动淡出，再1秒销毁", is_equal_approx(first.fade_at - first.display_done, 3.0) and is_equal_approx(first.expires - first.fade_at, 1.0))
	overlay.advance(float(first.display_done) - overlay._time - 0.001)
	_check("DisplayDone之前不启动下一句，旧句不透明", overlay._serial == 1 and MonsterBattleText.sentence_alpha(overlay.active_sentences[0], overlay._time) == 1.0)
	overlay.advance(0.002)
	_check("DisplayDone后启动新句且旧句并存淡出", overlay._serial == 2 and overlay.active_sentences.size() == 2 and is_equal_approx(overlay.active_sentences[0].fade_at, overlay._time))
	overlay.advance(0.5)
	_check("淡出中点透明度为一半", is_equal_approx(MonsterBattleText.sentence_alpha(overlay.active_sentences[0], overlay._time), 0.5))
	await _capture("battle-text-crossfade.png")
	overlay.advance(0.501)
	_check("约1秒淡出后仅销毁旧句", overlay.active_sentences.size() == 1 and overlay.active_sentences[0].started != first.started)
	var time_before := overlay._time
	scene.pile_modal.show()
	overlay.advance(2.0)
	_check("牌堆弹窗隐藏并暂停文本", not overlay.visible and overlay._time == time_before)
	scene.pile_modal.hide()
	scene._run_menu.open()
	overlay.advance(2.0)
	_check("背包地图设置弹窗也暂停文本", not overlay.visible and overlay._time == time_before)
	scene._run_menu.close()
	overlay.advance(0.01)
	_check("关闭菜单继续原时间线", overlay.visible and overlay._time > time_before)
	await _check_live_playback(scene)
	overlay.context_provider = func(): return {"area": Rect2(0, 0, 80, 60), "blockers": []}
	overlay.advance(0.001)
	_check("缩小窗口后不越界绘制旧句", overlay.active_sentences.is_empty())
	scene._on_battle_ended({"status": "victory"})
	_check("终局停止且清除文本", not overlay._running and overlay.active_sentences.is_empty())
	scene.queue_free()
	await _frames(3)
	print("战斗怪物文本：全部通过" if failures == 0 else "战斗怪物文本：%d项失败" % failures)
	print("截图目录：", ProjectSettings.globalize_path(fixture_root))
	get_tree().quit(failures)


func _new_overlay(provider: Callable) -> MonsterBattleText:
	var result := MonsterBattleText.new()
	add_child(result)
	result.set_process(false)
	result.context_provider = provider
	return result


func _check_small_pools(provider: Callable) -> void:
	var probe := _new_overlay(provider)
	var valid := true
	for pool_size in range(1, 7):
		probe.configure(SOURCE, "small-pool", [pool_size])
		probe.sentences.clear()
		for index in pool_size:
			probe.sentences.append("候选%d。" % index)
		# 相同文本重复写入，不得绕过防重复，也不应该增加其抽取权重。
		probe.sentences.append(probe.sentences[0])
		var recent: Array[String] = []
		for index in 60:
			probe.advance(0.001)
			var current: Dictionary = probe.active_sentences.back()
			var window := mini(4, pool_size - 1)
			if window > 0:
				valid = valid and not recent.slice(maxi(0, recent.size() - window)).has(str(current.text))
			recent.append(str(current.text))
			if recent.size() > 4:
				recent.pop_front()
			valid = valid and probe._recent_sentences.size() <= 4
			probe.advance(float(current.display_done) - probe._time + 0.001)
	_check("1至6句小候选池及重复条目：优先避开最近句，数量不足有限回退", valid)
	probe.free()


func _check_short_sentence_sizing() -> void:
	var area := Rect2(0, 0, 1000, 600)
	var probe := _new_overlay(func(): return {"area": area, "blockers": []})
	probe.configure(SOURCE, "minimum-fifteen-characters", ["short-fit"])
	probe.sentences.assign(["国".repeat(15)])
	probe.advance(0.001)
	var reference: Dictionary = probe.active_sentences.back().duplicate(true)
	var sizing_ok := true
	var content_ok := true
	var safe := true
	for count in range(1, 15):
		probe.configure(SOURCE, "minimum-fifteen-characters", ["short-fit"])
		probe.sentences.assign(["国".repeat(count)])
		probe.advance(0.001)
		var sentence: Dictionary = probe.active_sentences.back()
		sizing_ok = sizing_ok and sentence.font_size == reference.font_size and is_equal_approx(sentence.render_scale, reference.render_scale)
		content_ok = content_ok and sentence.text == "国".repeat(count) and sentence.glyphs.size() == count and is_equal_approx(sentence.display_done - sentence.started, count * probe.character_interval + MonsterBattleText.NEXT_DELAY)
		safe = safe and MonsterBattleText.is_safe(sentence.bounds, area, []) and _glyph_geometry_safe(probe, sentence, float(sentence.complete))
	_check("1至14字短句与同种子15字句使用相同字号和缩放", sizing_ok)
	_check("短句不补字、不增加逐字时间，绘制仍在真实安全范围", content_ok and safe)
	for text: String in ["国".repeat(15), "国".repeat(16), "长句保持原来的排版尺寸和缩放适配方式。"]:
		var layout := probe._layout(text, 220)
		_check("至少15字保持原适配尺寸：" + text, probe._sizing_reference(text, layout).is_equal_approx(layout.size))
	var short_lines := "甲；\n乙。"
	probe.configure(SOURCE, "minimum-fifteen-characters", ["short-fit"])
	probe.sentences.assign([short_lines])
	probe.advance(0.001)
	var multiline: Dictionary = probe.active_sentences.back()
	var multiline_layout := probe._layout(short_lines, int(multiline.font_size))
	var minimum := probe._layout("国".repeat(15), int(multiline.font_size))
	_check("短句分号换行仍保留，参考宽度不少于15字", multiline.text == short_lines and _source_lines_only(multiline) and probe._sizing_reference(short_lines, multiline_layout).x >= Vector2(minimum.size).x)
	probe.free()


func _check_side_scale_balance(provider: Callable) -> void:
	var context := {"area": Rect2(0, 0, 1600, 900), "blockers": [Rect2(0, 250, 400, 650)]}
	var probe := _new_overlay(func(): return context)
	var equal_sizing := true
	var both_sides := true
	var safe := true
	# 先在不对称空白中对照，再用真实战斗的立绘、背包、手牌和出牌区遮挡对照。
	for use_real_context in [false, true]:
		if use_real_context:
			context = provider.call()
			probe.context_provider = provider
		for text: String in ["短句。", "国".repeat(15), "这是一句需要在左右两侧保持同样显示大小的测试台词。"]:
			var samples: Array[Dictionary] = []
			for side in 2:
				probe.configure(SOURCE, "balanced-sides", [text])
				probe.sentences.assign([text])
				probe._next_side = side
				probe.advance(0.001)
				var sentence: Dictionary = probe.active_sentences.back()
				samples.append(sentence.duplicate(true))
				safe = safe and MonsterBattleText.is_safe(sentence.bounds, context.area, context.blockers) and _glyph_geometry_safe(probe, sentence, float(sentence.complete))
			equal_sizing = equal_sizing and samples[0].font_size == samples[1].font_size and is_equal_approx(samples[0].render_scale, samples[1].render_scale)
			# 很长的句子允许因可读性回退同一侧；短句与15字参考句应可正常左右轮换。
			if text.length() <= 15:
				both_sides = both_sides and samples[0].side == 0 and samples[1].side == 1
	_check("左右空白不对称及真实战场中，同一句的两侧字号和缩放一致", equal_sizing)
	_check("统一大小后短句仍左右轮换", both_sides)
	_check("左右对照的字形不越界或遮挡UI", safe)
	probe.free()


func _check_layout_fallbacks() -> void:
	var area := Rect2(100, 50, 1200, 700)
	var context := {"area": area, "blockers": [Rect2(area.position, Vector2(area.size.x * 0.4, area.size.y))]}
	var probe := _new_overlay(func(): return context)
	probe.configure(SOURCE, "side-fallback", ["ui"])
	probe.advance(0.001)
	_check("左侧完全遮挡时可回退右侧，不停播", probe.active_sentences.size() == 1 and probe.active_sentences[0].side == 1)
	context.blockers = []
	probe.advance(probe._next_at - probe._time + 0.001)
	_check("左侧恢复后下一句回到左侧", probe.active_sentences.back().side == 0)
	probe.configure(SOURCE, "pending-retry", ["ui"])
	context.blockers = [area]
	probe.advance(0.001)
	var pending := probe._pending_text
	var random_before := JSON.stringify(probe._random.capture_snapshot())
	probe.advance(0.3)
	probe.advance(0.3)
	_check("完全遮挡重试不重抽、不记入近期历史、不推进左右轮换", not pending.is_empty() and probe._pending_text == pending and probe._recent_sentences.is_empty() and probe._next_side == 0 and probe._serial == 0 and JSON.stringify(probe._random.capture_snapshot()) == random_before)
	context.blockers = []
	probe.advance(0.3)
	_check("解除遮挡才记录实际显示的句子并轮换", probe.active_sentences.back().text == pending and probe._recent_sentences == [pending] and probe._next_side == 1)
	probe.stop()
	_check("停止/重新配置清空防重复历史和左右轮换状态", probe._recent_sentences.is_empty() and probe._next_side == 0)
	context.blockers = []
	probe.configure(SOURCE, "layout-invalidation", ["ui"])
	probe.advance(0.001)
	var hidden: Rect2 = probe.active_sentences[0].bounds
	var old_next_at := probe._next_at
	context.blockers = [hidden.grow(1.0)]
	probe.advance(0.001)
	_check("UI遮挡旧句后立即重新排句，不空等原长句播完", probe._serial == 2 and probe._time < old_next_at and not probe.active_sentences.is_empty() and not Rect2(probe.active_sentences.back().bounds).intersects(hidden))
	probe.free()


func _check_live_playback(scene: BattleTestScene) -> void:
	var overlay := scene._monster_text
	overlay.configure(SOURCE, "live-frame-regression", ["ui"])
	var seen: Array[String] = []
	var started := func(text: String, _bounds: Rect2): seen.append(text)
	overlay.sentence_started.connect(started)
	var previous_time_scale := Engine.time_scale
	Engine.time_scale = 8.0
	overlay.set_process(true)
	var safe := true
	for sample in 10:
		# 不调用 advance、不直接跳到 display_done，真正通过 _process 持续播放40秒。
		await get_tree().create_timer(4.0).timeout
		var context := scene._monster_text_context()
		for sentence: Dictionary in overlay.active_sentences:
			safe = safe and MonsterBattleText.is_safe(sentence.bounds, context.area, context.blockers)
		if sample in [0, 4, 9]:
			await _capture("battle-text-live-%d.png" % sample)
	overlay.set_process(false)
	Engine.time_scale = previous_time_scale
	overlay.sentence_started.disconnect(started)
	_check("真实逐帧40秒持续换句，至少显示4句不同文本", overlay._time >= 39.0 and seen.size() >= 4 and _unique_count(seen) >= 4)
	_check("真实逐帧播放的新旧句始终在视口内且避开UI", safe)


static func _unique_count(values: Array[String]) -> int:
	var unique := {}
	for value: String in values:
		unique[value] = true
	return unique.size()


func _presentation_snapshot(sentence: Dictionary) -> Dictionary:
	var result := sentence.duplicate(true)
	# 不同SystemFont实例的RID与图集打包位置可能不同，不属于表现随机参数。
	for glyph: Dictionary in result.glyphs:
		glyph.erase("font_rid")
		glyph.erase("texture_rid")
		glyph.erase("texture_uvs")
	return result


func _glyph_geometry_safe(overlay: MonsterBattleText, sentence: Dictionary, at_time: float) -> bool:
	var widths := overlay._visible_widths(sentence, at_time)
	for index in sentence.glyphs.size():
		var glyph: Dictionary = sentence.glyphs[index]
		if float(glyph.reveal_at) > at_time - float(sentence.started) + 0.000001:
			continue
		var transform := overlay._glyph_transform(sentence, index, at_time, widths)
		var half: Vector2 = glyph.quad_half
		for corner: Vector2 in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
			if not Rect2(sentence.bounds).grow(0.01).has_point(transform * corner):
				return false
	return true


func _source_lines_only(sentence: Dictionary) -> bool:
	var line_breaks := 0
	var previous_x := -1.0
	for glyph: Dictionary in sentence.glyphs:
		if glyph.position.x <= previous_x:
			line_breaks += 1
		previous_x = glyph.position.x
	return line_breaks == str(sentence.text).count("\n")


func _capture(filename: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fixture_root.path_join(filename))


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1

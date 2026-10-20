extends "res://tests/three_enemy_fixed_layout_selftest.gd"

var layer_samples: Array[Dictionary] = []
var feedback_samples: Array[Dictionary] = []
var pixel_samples: Array[Dictionary] = []
var tooltip_samples: Array[Dictionary] = []

func _run() -> void:
	deadline = Time.get_ticks_msec() + 180000
	fixture_root = "res://.godot/primary-occlusion-%d" % Time.get_ticks_usec()
	if not _expect("遮挡验收必须使用原生渲染器", DisplayServer.get_name() != "headless"):
		_finish()
		return
	if not _expect("遮挡验收隔离目录可创建", DirAccess.make_dir_recursive_absolute(fixture_root) == OK):
		_finish()
		return
	SaveGateway.save_path = fixture_root.path_join("game.json")
	if not _expect("遮挡验收独立存档可加载", SaveGateway.load_current() == OK):
		_finish()
		return
	var board := RelicBoard.new()
	if not _expect("遮挡验收空残片板可保存", board.save_to_file(fixture_root.path_join("empty-board.json")) == OK):
		_finish()
		return
	for resolution: Vector2i in RESOLUTIONS:
		get_window().size = resolution
		await get_tree().process_frame
		for primary_id: String in ["1", "12", "4"]:
			if not await _real_fixture(primary_id, resolution):
				_finish()
				return
		if not await _sentinel_fixture(resolution):
			_finish()
			return
	_finish()

func _real_fixture(primary_id: String, resolution: Vector2i) -> bool:
	var tag := "real-%s-%d" % [primary_id, resolution.x]
	if not await _new_battle([primary_id, "4", "4"], "test_block", tag): return false
	var owner: String = str(scene._battle.enemies[0]["enemy_id"])
	_notice("REAL CATALOG: primary %s + two apprentices; %d x %d" % [primary_id, resolution.x, resolution.y])
	for id: String in _living():
		if id == owner: continue
		_context().add_buff(&"enemy", id, &"poison", 1)
		if not _expect(tag + " 正式格挡指令接受后排ID", scene._battle.rules.submit("action.block", {"side": "enemy", "target": id, "amount": 3}) == OK): return false
	if not await _settled(tag + " 真实buff盾牌"): return false
	if not _layout(owner, 3, tag): return false
	if primary_id == "1" and not await _rear_tooltip(owner, tag): return false
	if not _layers(owner, tag + " 初始"): return false
	if not await _overlap_input(owner, tag): return false
	if not await _arrow_layers(owner, tag): return false
	if not await _live_feedback(owner, tag): return false
	if not await _capture(tag + "-catalog"): return false
	var original: Dictionary = _pose(owner)
	var removed: String = str(scene._battle.enemies[1]["enemy_id"])
	var old_slot: EnemySlot = scene.enemy_rack.slot_for(removed)
	_context().damage_enemy(removed, int(_enemy(removed)["health"]), true)
	if not await _settled(tag + " 真实后排死亡"): return false
	if not _expect(tag + " 后排死亡退出交互", not is_instance_valid(old_slot) or not old_slot.visible or not old_slot.selectable): return false
	if not _expect(tag + " 死亡空位允许真实补位", scene._battle.rules.submit("monster.summon", {"id": "4", "owner": owner}) == OK): return false
	if not await _settled(tag + " 真实补位"): return false
	if not _stable(owner, original, tag + " 后排死亡补位主怪不变"): return false
	if not _layout(owner, 3, tag + " 补位道路"): return false
	if not _layers(owner, tag + " 补位"): return false
	if not await _cold_rebuild_formation(tag + " 冷重建"): return false
	if not _layers(owner, tag + " 冷重建"): return false
	if not await _overlap_input(owner, tag + " 冷重建"): return false
	# A real visible main-body point which is also in a rear rectangular hit region.
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	var rear: EnemySlot
	var covered_point := Vector2.INF
	for id: String in _living():
		if id == owner: continue
		var candidate: EnemySlot = scene.enemy_rack.slot_for(id)
		var area: Rect2 = _click_rect(candidate).intersection(_click_rect(main))
		var point: Vector2 = _unambiguous_covered_point(main, candidate, area)
		if point != Vector2.INF and (rear == null or candidate.position.x > rear.position.x):
			rear = candidate
			covered_point = point
	if not _expect(tag + " 主怪死亡前有遮住后排点击区的可见身体", rear != null and covered_point != Vector2.INF): return false
	_context().damage_enemy(owner, int(_enemy(owner)["health"]), true)
	if not await _settled(tag + " 主怪真实死亡"): return false
	if not _expect(tag + " 主怪死亡不结束存活后排战斗", scene._battle.active and not main.selectable and main._snapshot_dead): return false
	if not await _pointer_select(rear, covered_point, tag + " 主怪死亡后原覆盖点穿透后排"): return false
	if not _layers(owner, tag + " 主怪死亡"): return false
	if not await _play_first_card(tag + " 遮挡分层后真实手牌", true): return false
	if not await _capture(tag + "-main-dead-card"): return false
	_record(tag)
	return true

func _unambiguous_covered_point(main: EnemySlot, rear: EnemySlot, area: Rect2) -> Vector2:
	for y: int in range(int(area.position.y) + 6, int(area.end.y) - 6, 8):
		for x: int in range(int(area.position.x) + 6, int(area.end.x) - 6, 8):
			var point := Vector2(x, y)
			if _portrait_alpha(main, point) < 0.98: continue
			var another_rear: bool = false
			for other: EnemySlot in scene.enemy_rack.slots:
				if other != main and other != rear and other.visible and not other._snapshot_dead and _click_rect(other).has_point(point): another_rear = true
			if not another_rear: return point
	return Vector2.INF

func _rear_tooltip(owner: String, label: String) -> bool:
	# Give each source a real chip. Rendering rebuilds rows, so resolve chip nodes afterwards.
	_context().add_buff(&"enemy", owner, &"poison", 1)
	_context().add_buff(&"player", "player", &"poison", 1)
	# A real block event captures the complete current enemy/player snapshot after both buffs.
	if not _expect(label + " 真实格挡事件刷新三种提示来源快照", scene._battle.rules.submit("action.block", {"side": "enemy", "target": owner, "amount": 1}) == OK): return false
	if not await _settled(label + " 提示来源真实buff装配"): return false
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	var rear: EnemySlot
	for slot: EnemySlot in scene.enemy_rack.slots:
		if slot != main and (rear == null or slot.position.x > rear.position.x): rear = slot
	if not _expect(label + " 三个提示来源都有真实buff chip", rear != null and rear.buff_row.get_child_count() > 0 and main.buff_row.get_child_count() > 0 and scene.player_buff_row.get_child_count() > 0): return false
	var chip: Control = rear.buff_row.get_child(0) as Control
	var point: Vector2 = _alpha_point(main, chip.get_global_rect(), false)
	if not _expect(label + " 真实后排chip内有主怪完全透明内核可悬停点", point != Vector2.INF and chip.get_global_rect().has_point(point) and main.portrait.get_global_rect().has_point(point) and _portrait_alpha(main, point) < 0.02): return false
	scene._hide_buff_tip()
	await _move_pointer(Vector2(1800, 50))
	await RenderingServer.frame_post_draw
	var baseline: Image = get_viewport().get_texture().get_image()
	if not await _hover_real_tip(chip, point, label + " 后排真实悬停"): return false
	if not _tip_layer(main, "rear", label + " 后排真实悬停"): return false
	var overlap: Rect2 = scene._buff_tip.get_global_rect().intersection(main.portrait.get_global_rect())
	var protected: Array[Vector2] = []
	for sample: Vector2 in _protected_points(main):
		if overlap.has_point(sample): protected.append(sample)
	if not _expect(label + " 后排真实提示矩形与主怪不透明内核实际交叠", protected.size() >= 4): return false
	await RenderingServer.frame_post_draw
	if not _pixels_unchanged(baseline, get_viewport().get_texture().get_image(), protected, label + " 后排真实提示不可覆盖主怪像素"): return false
	if not await _capture(label + "-real-rear-buff-tooltip"): return false
	tooltip_samples.append({"case": label, "source": "rear_real_hover", "chip_rect": _rectangle(chip.get_global_rect()), "hover_point": _vector(point), "primary_alpha_core": _portrait_alpha(main, point), "tooltip_rect": _rectangle(scene._buff_tip.get_global_rect()), "opaque_overlap_samples": protected.size(), "effective_z": _effective_z(scene._buff_tip)})
	# The shared popup must reset its layer when its source changes; these two are direct API supplements.
	scene._show_buff_tip(main.buff_row.get_child(0) as Control, "PRIMARY SOURCE: layer must recover")
	await get_tree().process_frame
	await get_tree().process_frame
	if not _tip_layer(main, "primary", label + " 后排切主怪来源"): return false
	scene._show_buff_tip(scene.player_buff_row.get_child(0) as Control, "PLAYER SOURCE: layer must recover")
	await get_tree().process_frame
	await get_tree().process_frame
	if not _tip_layer(main, "player", label + " 主怪切玩家来源"): return false
	scene._hide_buff_tip()
	await _move_pointer(Vector2(1800, 50))
	if not await _hover_real_tip(chip, point, label + " 玩家切回后排真实悬停"): return false
	if not _tip_layer(main, "rear", label + " 玩家切回后排来源"): return false
	scene._hide_buff_tip()
	await _move_pointer(Vector2(1800, 50))
	return true

func _move_pointer(point: Vector2) -> void:
	get_viewport().warp_mouse(point)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	await get_tree().process_frame

func _hover_real_tip(chip: Control, point: Vector2, label: String) -> bool:
	await _move_pointer(point)
	var until: int = mini(Time.get_ticks_msec() + 2000, deadline)
	while Time.get_ticks_msec() < until and (not scene._buff_tip.visible or not _same_rect(scene._buff_tip.get("_anchor_rect"), chip.get_global_rect())):
		await get_tree().process_frame
	return _expect(label + " 原生mouse_entered生成对应chip提示", scene._buff_tip.is_visible_in_tree() and _same_rect(scene._buff_tip.get("_anchor_rect"), chip.get_global_rect()) and not (scene._buff_tip.get_node("TipLabel") as RichTextLabel).text.is_empty())

func _tip_layer(main: EnemySlot, source: String, label: String) -> bool:
	var items: Array[CanvasItem] = []
	_collect_canvas(scene._buff_tip, items)
	if not _expect(label + " 提示树实际可见且含文字", scene._buff_tip.is_visible_in_tree() and items.size() >= 2): return false
	for item: CanvasItem in items:
		var z: int = _effective_z(item)
		if source == "rear":
			if not _expect(label + "/" + str(item.name) + " 后排提示全部低于主怪模型", z < _effective_z(main.portrait)): return false
		elif source == "primary":
			if not _expect(label + "/" + str(item.name) + " 主怪提示恢复自身前景且低于手牌", z > _effective_z(main.portrait) and z < _effective_z(scene.hand_scroll)): return false
		else:
			if not _expect(label + "/" + str(item.name) + " 玩家提示恢复普通UI上方", z > _effective_z(scene.hand_scroll)): return false
	tooltip_samples.append({"label": label, "source": source, "effective_z": _effective_z(scene._buff_tip)})
	return true

func _layers(owner: String, label: String) -> bool:
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	if not _expect(label + " 主怪视图存在", main != null): return false
	var main_z: int = _effective_z(main.portrait)
	var names: Array[String] = []
	for slot: EnemySlot in scene.enemy_rack.slots:
		if slot == main: continue
		var descendants: Array[CanvasItem] = []
		_collect_canvas(slot, descendants)
		if not _expect(label + "/" + slot.enemy_id + " 后排Canvas树含模型光晕HUD盾牌文字", descendants.has(slot.portrait) and descendants.has(slot._glow) and descendants.has(slot.fill) and descendants.has(slot.name_label) and descendants.has(slot.intent_value) and descendants.has(slot.buff_row) and descendants.has(slot.shield) and slot.shield.get_child_count() > 0): return false
		for item: CanvasItem in descendants:
			var z: int = _effective_z(item)
			if not _expect(label + "/" + slot.enemy_id + "/" + str(item.name) + " 实际有效Z低于主怪模型", z < main_z): return false
			names.append(str(item.get_path()))
	if not _expect(label + " 主怪HUD高于主怪模型且低于普通UI", _effective_z(main.name_label) > main_z and _effective_z(main.shield) > main_z and _effective_z(main.buff_row) > main_z and _effective_z(main.shield) < _effective_z(scene.hand_scroll)): return false
	layer_samples.append({"label": label, "main_portrait_z": main_z, "rear_canvas_paths": names})
	return true

func _collect_canvas(node: Node, result: Array[CanvasItem]) -> void:
	if node is CanvasItem: result.append(node as CanvasItem)
	for child: Node in node.get_children(): _collect_canvas(child, result)

func _effective_z(item: CanvasItem) -> int:
	var result: int = item.z_index
	if item.z_as_relative and not item.is_set_as_top_level():
		var ancestor: Node = item.get_parent()
		while ancestor != null and not (ancestor is CanvasLayer):
			if ancestor is CanvasItem:
				result += _effective_z(ancestor as CanvasItem)
				break
			ancestor = ancestor.get_parent()
	return clampi(result, -4096, 4096)

func _arrow_layers(owner: String, label: String) -> bool:
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	for id: String in _living():
		var slot: EnemySlot = scene.enemy_rack.slot_for(id)
		var point: Vector2 = _visible_click_point(slot)
		if not _expect(label + " 箭头命中样本存在/" + id, point != Vector2.INF): return false
		if not await _pointer_select(slot, point, label + " 箭头分层/" + id): return false
		var arrow_z: int = _effective_z(scene.enemy_rack._arrow)
		if id == owner:
			if not _expect(label + " 主怪箭头高于主怪模型且低于手牌", arrow_z > _effective_z(main.portrait) and arrow_z < _effective_z(scene.hand_scroll)): return false
		else:
			if not _expect(label + " 后排箭头低于主怪模型", arrow_z < _effective_z(main.portrait)): return false
	return true

func _live_feedback(owner: String, label: String) -> bool:
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	var subjects: Array[String] = _living()
	subjects.append("player")
	for id: String in subjects:
		for kind: String in ["attack", "heal", "block"]:
			await get_tree().create_timer(0.15).timeout
			var nodes: Array[CanvasItem] = _trigger_feedback(id, kind)
			if not _expect(label + "/" + id + "/" + kind + " 真实反馈API新建飘字和VFX", nodes.size() == 2): return false
			var floats: int = 0
			var effects: int = 0
			for item: CanvasItem in nodes:
				if item is Label: floats += 1
				if item is VfxPlayback: effects += 1
				var z: int = _effective_z(item)
				if id == "player":
					if not _expect(label + "/" + kind + " 玩家反馈保持普通UI上方", z > _effective_z(scene.hand_scroll)): return false
				elif id == owner:
					if not _expect(label + "/" + kind + " 主怪反馈在自身模型上方且在手牌下方", z > _effective_z(main.portrait) and z < _effective_z(scene.hand_scroll)): return false
				else:
					if not _expect(label + "/" + id + "/" + kind + " 后排实时飘字特效低于主怪模型", z < _effective_z(main.portrait)): return false
				feedback_samples.append({"case": label, "entity": id, "kind": kind, "node_class": item.get_class(), "effective_z": z})
			if not _expect(label + "/" + id + "/" + kind + " 实际捕获一个文字与一个特效", floats == 1 and effects == 1): return false
			await get_tree().create_timer(0.04).timeout
			if not _expect(label + "/" + id + "/" + kind + " 反馈节点在真实存活帧可见", nodes.all(func(item: CanvasItem): return is_instance_valid(item) and item.is_visible_in_tree())): return false
	# Let transient flashes finish before catalog captures and the pixel fixture.
	await get_tree().create_timer(1.1).timeout
	return true

func _trigger_feedback(id: String, kind: String) -> Array[CanvasItem]:
	var before: Array[Node] = scene.get_children()
	var side: StringName = &"player" if id == "player" else &"enemy"
	var identity: String = "" if id == "player" else id
	match kind:
		"attack": scene._feedback.on_damaged(side, 7, 0, identity)
		"heal": scene._feedback.on_healed(side, 5, identity)
		"block": scene._feedback.on_block_changed(side, 999, identity)
	var created: Array[CanvasItem] = []
	for child: Node in scene.get_children():
		if not before.has(child) and child is CanvasItem: created.append(child as CanvasItem)
	return created

func _sentinel_fixture(resolution: Vector2i) -> bool:
	var tag := "sentinel-%d" % resolution.x
	if not await _new_battle(["1", "4", "4"], "test_block", tag): return false
	_notice("DETERMINISTIC SENTINEL: cyan primary / magenta rear; real production nodes and feedback")
	var owner: String = str(scene._battle.enemies[0]["enemy_id"])
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	var sample := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	sample.fill(Color.TRANSPARENT)
	sample.fill_rect(Rect2i(16, 16, 64, 64), Color(0.12, 0.80, 0.95, 1.0))
	main.portrait.texture = ImageTexture.create_from_image(sample)
	main.show_snapshot_status(_enemy(owner), true, true)
	var rear_image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	rear_image.fill(Color(0.95, 0.08, 0.70, 1.0))
	var rear_texture := ImageTexture.create_from_image(rear_image)
	get_viewport().warp_mouse(Vector2(1800, 50))
	scene.enemy_rack.set_process(false)
	scene.enemy_rack._arrow.hide()
	main._glow.hide()
	var rears: Array[EnemySlot] = []
	for slot: EnemySlot in scene.enemy_rack.slots:
		if slot == main: continue
		rears.append(slot)
		slot.portrait.texture = rear_texture
		slot.portrait.global_position = Vector2(850, 390)
		slot.portrait.size = Vector2(240, 240)
		slot._glow.global_position = Vector2(830, 370)
		slot._glow.size = Vector2(280, 280)
		var hud: Array[Control] = [slot._bar, slot._frame, slot.name_label, slot.number_label, slot._intent_badge, slot._intent_ring, slot.intent_value, slot.buff_row, slot.shield]
		for index: int in hud.size():
			hud[index].global_position = Vector2(870 + (index % 3) * 35, 410 + floori(float(index) / 3.0) * 45)
			hud[index].show()
		slot.name_label.text = "REAR NAME"
		slot.number_label.text = "999/999"
		slot.intent_value.text = "999"
		slot.name_label.add_theme_font_size_override("font_size", 48)
		slot.shield.set("value", 999)
		# Existing actual buff-row children are audited in real fixtures; this sentinel adds an explicit label at that inherited layer.
		var buff_text := Label.new()
		buff_text.name = "SentinelBuffText"
		buff_text.text = "BUFF 999"
		buff_text.add_theme_font_size_override("font_size", 48)
		buff_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.buff_row.add_child(buff_text)
		slot.hide()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var baseline: Image = get_viewport().get_texture().get_image()
	var points: Array[Vector2] = _protected_points(main)
	if not _expect(tag + " 主怪确定性不透明内核包含足够像素", points.size() >= 200): return false
	if not await _capture(tag + "-baseline-rears-hidden"): return false
	for slot: EnemySlot in rears:
		slot.show()
		slot._glow.show()
	if not _layers(owner, tag + " sentinel全后排Canvas"): return false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	if not _pixels_unchanged(baseline, get_viewport().get_texture().get_image(), points, tag + " 模型HUD文字光晕盾牌均不能盖主怪"): return false
	if not await _capture(tag + "-all-rear-nodes-behind"): return false
	for kind: String in ["attack", "heal", "block"]:
		await get_tree().create_timer(0.16).timeout
		var live: Array[CanvasItem] = _trigger_feedback(rears[0].enemy_id, kind)
		if not _expect(tag + "/" + kind + " sentinel用真实反馈API创建两个节点", live.size() == 2): return false
		await get_tree().create_timer(0.06).timeout
		await RenderingServer.frame_post_draw
		if not _pixels_unchanged(baseline, get_viewport().get_texture().get_image(), points, tag + "/" + kind + " 存活反馈不能盖主怪内核"): return false
		if not await _capture(tag + "-live-" + kind): return false
	main.portrait.hide()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var counterfactual: Image = get_viewport().get_texture().get_image()
	var exposed: int = _changed_pixels(baseline, counterfactual, points)
	if not _expect(tag + " 隐藏主怪对照必须暴露真实后排绘制威胁", exposed >= 100): return false
	pixel_samples.append({"case": tag, "sentinel": true, "protected_core_samples": points.size(), "main_hidden_changed_samples": exposed, "excluded": "2 texture pixels around alpha transitions; scene UI may remain in front"})
	if not await _capture(tag + "-counterfactual-primary-hidden"): return false
	return true

func _protected_points(main: EnemySlot) -> Array[Vector2]:
	var points: Array[Vector2] = []
	var rect: Rect2 = main.portrait.get_global_rect()
	for y: int in range(int(rect.position.y) + 12, int(rect.end.y) - 12, 12):
		for x: int in range(int(rect.position.x) + 12, int(rect.end.x) - 12, 12):
			var point := Vector2(x, y)
			if _portrait_alpha(main, point) > 0.98: points.append(point)
	return points

func _pixels_unchanged(before: Image, after: Image, points: Array[Vector2], label: String) -> bool:
	var changed: int = _changed_pixels(before, after, points)
	pixel_samples.append({"label": label, "samples": points.size(), "changed_over_2_rgb_levels": changed})
	return _expect(label, changed == 0)

func _changed_pixels(before: Image, after: Image, points: Array[Vector2]) -> int:
	var count: int = 0
	for point: Vector2 in points:
		# Both configured windows are 16:9; the authored scene canvas is 1920x1080.
		var pixel := Vector2i(point * Vector2(float(after.get_width()) / 1920.0, float(after.get_height()) / 1080.0))
		var a: Color = before.get_pixelv(pixel)
		var b: Color = after.get_pixelv(pixel)
		if maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))) > 2.0 / 255.0: count += 1
	return count

func _notice(text: String) -> void:
	var label := Label.new()
	label.name = "EvidenceFixtureNotice"
	label.text = text
	label.position = Vector2(350, 20)
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 350
	scene.add_child(label)

func _finish() -> void:
	if finishing: return
	records.append({"effective_layer_samples": layer_samples, "live_feedback_samples": feedback_samples, "sentinel_pixel_samples": pixel_samples, "tooltip_samples": tooltip_samples, "alpha_policy": "Only alpha >=0.98 and <=0.02 cores with a 2-texel guard; blended edges excluded.", "pixel_coordinate_basis": [1920, 1080]})
	print("PRIMARY_OCCLUSION live_feedback_samples=%d pixel_samples=%d" % [feedback_samples.size(), pixel_samples.size()])
	super._finish()

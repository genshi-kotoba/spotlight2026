extends Node
const Session := preload("res://systems/map/flat_2d/planar_map_session.gd")
const Helper := preload("res://tests/support/presentation_test_helper.gd")
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var test_scene := get_tree().current_scene
	get_tree().current_scene = null
	var fixture := "res://.godot/mobile-map-%d" % Time.get_ticks_usec()
	SaveGateway.save_path = fixture.path_join("game.json")
	SaveGateway.load_current()
	EncounterFlow.relic_board_path = fixture.path_join("relics.json")
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/main_menu_new_run.json"))
	config.run_id = "mobile-map-test"
	_check("建立隔离真实局", SaveGateway.start_new_run("mobile-map-test", config) == OK)
	var view: Node = load(EncounterFlow.MAP_SCENE).instantiate()
	get_tree().root.add_child(view)
	get_tree().current_scene = view
	await Helper.map_ready(get_tree())
	await _frames(3)
	view._set_paused(false)
	var settings := view._hud_root.get_node("MapSettingsButton") as Control
	_check("地图设置按钮位于小地图左侧", settings.get_global_rect().end.x < view._mini.get_global_rect().position.x)
	await _tap(settings.get_global_rect().get_center())
	_check("点击设置打开同一局内设置页并暂停移动", view._run_menu.is_open() and view._run_menu.current_page() == 2 and view.paused)
	await _tap(view._run_menu._close_button.get_global_rect().get_center())
	_check("设置关闭恢复地图", not view._run_menu.is_open() and not view.paused)
	var origin: Vector2 = view.session.actor_plane
	var target := Vector2.ZERO
	var found := false
	for key: String in view.session.reachable():
		var cell: Dictionary = view.session.cells[key]
		var plane := HexCoord.to_plane(Vector2i(cell.q, cell.r), 1.0)
		var at: Vector2 = view.get_canvas_transform() * view._plane_to_display(plane)
		if plane.distance_to(origin) < 1.4 or plane.distance_to(origin) > 4.0 or not view.session.can_stand(plane): continue
		if at.x < 700 or at.x > get_viewport().get_visible_rect().size.x - 450 or at.y < 300 or at.y > 800: continue
		if view._mobile_pick_cell(at) != key: continue
		target = plane
		found = true
		var started := Time.get_ticks_msec()
		await _tap(at)
		print("NAVIGATION_BUILD_MS=", Time.get_ticks_msec() - started)
		break
	_check("实际高程投影可点选地块", found)
	if found:
		_check("点选后有路线且没有瞬移", not view._mobile_path.is_empty() and view.session.actor_plane.distance_to(origin) < 1.0)
		for i in 600:
			if view._mobile_path.is_empty(): break
			view._advance_motion(view._movement_direction(), 1.0 / 60.0)
		_check("按原移动碰撞走到目的地", view.session.actor_plane.distance_to(target) < 0.35)
	var id := _approach(view)
	_check("存在可交互敌人测试结点", not id.is_empty())
	await _frames(4)
	await Helper.map_ready(get_tree())
	if not id.is_empty():
		await Helper.route_ready(get_tree())
		var node: Dictionary = view.session.nodes[id]
		var plane := HexCoord.to_plane(Session.coord(node.coord), 1.0)
		var at: Vector2 = view.get_canvas_transform() * view._plane_to_display(plane)
		_check("怪物结点投影可拾取", view._mobile_pick_cell(at) in node.footprint.map(func(c): return Session.key(Session.coord(c))))
		_check("中心可选结点", view._mobile_node_at(at, Session.coord(node.coord)) == id)
		_check("中心外不再把整个占地当作结点", view._mobile_node_at(at + Vector2(40, 0), Session.coord(node.coord)).is_empty())
		var hint = view._node_hint
		if hint.visible and not hint._leaving:
			var hint_center: Vector2 = hint.get_global_transform_with_canvas() * Vector2.ZERO
			_check("名称框中心仍可交互", view._mobile_hint_hit(hint_center))
			_check("名称框外不扩大命中", not view._mobile_hint_hit(hint_center + Vector2(40, 0)))
		var tested_edge := false
		for offset: Vector2 in [Vector2(40, 0), Vector2(-40, 0), Vector2(0, 40), Vector2(60, 0), Vector2(-60, 0)]:
			var edge := at + offset
			var key: String = view._mobile_pick_cell(edge)
			if not view.session.known.has(key) or not view.session.cells.has(key): continue
			var cell: Dictionary = view.session.cells[key]
			var coord := Vector2i(cell.q, cell.r)
			if cell.terrain != "ground" or [coord.x, coord.y] not in node.footprint or not view._mobile_node_at(edge, coord).is_empty(): continue
			view._mobile_target_node = ""
			await _tap(edge)
			_check("真实触屏点击占地边缘只移动不选结点", view._mobile_target_node.is_empty() and view.session.pending.is_empty())
			tested_edge = true
			view._mobile_path.clear()
			_approach(view)
			await _frames(4)
			break
		_check("覆盖结点原占地边缘的真实点击", tested_edge)
		at = view.get_canvas_transform() * view._plane_to_display(plane)
		await _tap(at)
		_check("第一次点结点只选目标不立即交互", view.session.pending.is_empty())
		at = view.get_canvas_transform() * view._plane_to_display(plane)
		await _tap(at)
		for i in 180:
			await _frames(1)
			if get_tree().current_scene != view and not SceneTransition.is_loading(): break
		var battle := get_tree().current_scene as BattleTestScene
		_check("第二次点击经过EncounterFlow进入真实战斗", battle != null and battle.scene_file_path == EncounterFlow.BATTLE_SCENE)
	if DisplayServer.get_name() != "headless":
		var battle := get_tree().current_scene as BattleTestScene
		if battle != null:
			await Helper.battle_settled(battle)
			await get_tree().create_timer(1.5).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/mobile-battle-preview.png")
	get_tree().current_scene = test_scene
	var current := get_tree().root.get_children()
	for child in current:
		if child == view or child is BattleTestScene: child.queue_free()
	await _frames(3)
	print("MOBILE_MAP_RESULT failures=%d" % failures)
	get_tree().quit(failures)

func _approach(view: Node) -> String:
	for id: String in view.session.nodes:
		var node: Dictionary = view.session.nodes[id]
		if node.type not in ["battle", "elite"]: continue
		for coord: Array in node.footprint:
			for cell in HexCoord.neighbors(Session.coord(coord)):
				var point := HexCoord.to_plane(cell, 1.0)
				if view.session.can_stand(point):
					view.session.actor_plane = point
					if id not in view.session.nearby_nodes(): continue
					view._sync_actor(false)
					return id
	return ""

func _tap(at: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventScreenTouch.new()
		event.index = 0
		event.position = at
		event.pressed = pressed
		get_viewport().push_input(event, true)
		await _frames(1)
	await _frames(3)

func _frames(count: int) -> void:
	for i in count: await get_tree().process_frame

func _check(label: String, passed: bool) -> void:
	print("%s %s" % ["PASS" if passed else "FAIL", label])
	if not passed: failures += 1

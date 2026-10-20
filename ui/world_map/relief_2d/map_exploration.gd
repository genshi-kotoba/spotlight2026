extends "res://ui/world_map/flat_2d/map_run_demo.gd"
## Production presentation adapter. The parent and menu entry retain gameplay,
## run ownership, encounters, menu input and persistence. No demo settlement.
const ReliefView = preload("res://systems/map/relief_2d/renderer_2d.gd")
const Heights = preload("res://systems/map/relief_2d/height_generator.gd")
const Support = preload("res://systems/map/relief_2d/support_sampler.gd")
const Envelope = preload("res://systems/map/relief_2d/scene_envelope.gd")
const FogVeil = preload("res://systems/map/relief_2d/fog_veil_2d.gd")
const Discovery = preload("res://systems/map/relief_2d/discovery_presentations.gd")
const NodeHint = preload("res://systems/map/relief_2d/node_interaction_hint.gd")
const MistVeil = preload("res://systems/map/relief_2d/node_mist_veil.gd")
const SETTINGS := "res://data/config/relief_2d/exploration.json"
const SUN := "res://data/config/relief_2d/sunlight.json"
const ATMOSPHERE := "res://data/config/relief_2d/atmosphere.json"
const FOLLOW_ZOOM_AT_100 := 0.25
var height_layer: Dictionary = {}
var support = Support.new()
var _height_settings: Dictionary = {}
var _sun_settings: Dictionary = {}
var _atmosphere_settings: Dictionary = {}
var _envelope: Dictionary = {}
var _fog_veil: Node2D
var _node_hint: Node2D
var _node_mist: Node2D
var _animated_plane := Vector2.ZERO
var _actor_facing_intent := Vector2.ZERO
var _discovery_prepare_queued := false
var _prepare_error := ""
var _entry_started_usec := 0
var entry_ready_ms := -1.0
var _binding_presentation := false
## 已经放过焦点渐亮的层标识，同一层重刷不重放。
var _focus_identity := ""

func _ready() -> void:
	_entry_started_usec = Time.get_ticks_usec()
	_height_settings = _read_settings(SETTINGS)
	_sun_settings = _read_settings(SUN)
	_atmosphere_settings = _read_settings(ATMOSPHERE)
	get_viewport().gui_embed_subwindows = true
	super._ready()
	_update_camera()

func _read_settings(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

func _run_settings_path() -> String:
	return SETTINGS

func _create_map_view() -> Node2D:
	map_scale = clampf(float(_height_settings.get("map_scale", 7.0)), 0.5, 16.0)
	speed_multiplier = 2.0
	var run := SaveGateway.current_run()
	var identity := run.run_id if run != null else SeedService.get_main_seed()
	var view: Node2D = MapPresentation.acquire(self, identity)
	view.set_wall_cutaway_enabled(true)
	view.show_node_regions = false
	view.set_art_enabled(true, false)
	view.set_exploration_fog_visual_mode("veil")
	view.set_exploration_fog_enabled(true)
	view.set_actor_emission_strength(0.6)
	_fog_veil = view.get_node_or_null("ExplorationVeil")
	if _fog_veil == null:
		_fog_veil = FogVeil.new()
		_fog_veil.name = "ExplorationVeil"
		view.add_child(_fog_veil)
	_node_hint = view.get_node_or_null("NodeInteractionHint")
	if _node_hint == null:
		_node_hint = NodeHint.new()
		_node_hint.name = "NodeInteractionHint"
		view.add_child(_node_hint)
	_node_hint.clear()
	_node_mist = view.get_node_or_null("NodeMistVeil")
	if _node_mist == null:
		_node_mist = MistVeil.new()
		_node_mist.name = "NodeMistVeil"
		view.add_child(_node_mist)
	view.presentation_committed.connect(_presentation_committed)
	return view

func _create_actor() -> Node2D:
	# Camera anchor; the renderer owns the animated, occlusion-aware body.
	return Node2D.new()

func load_map(snapshot: Dictionary, saved_state: Dictionary = {}) -> bool:
	_binding_presentation = true
	var accepted: bool = super.load_map(snapshot, saved_state)
	_binding_presentation = false
	return accepted

func _derived_seed(map_id: String, domain: StringName, version: String) -> Variant:
	var ids := [map_id, version]
	if SeedService.get_stream(domain, ids, 0) == null:
		return null
	# Register a zero-draw address. Never reinitialize the shared RNG context.
	for entry in SeedService.capture_snapshot().get("streams", []):
		if entry.domain == domain and str(entry.occurrence) == "0" and entry.ids == [{"type": "string", "value": map_id}, {"type": "string", "value": version}]:
			return posmod(int(entry.seed), 2147483647)
	return null

func _height_config(floor_index: int) -> Dictionary:
	var config: Dictionary = _height_settings.get("height_common", {}).duplicate(true)
	config.merge(_height_settings.get("height_floors", {}).get(str(floor_index), {}), true)
	return config

func _prepare_presentation(candidate: RefCounted) -> bool:
	if SeedService.get_main_seed() != candidate.seed:
		_show_toast("高度显示拒绝：地图与当前局种子不一致")
		return false
	var noise: Variant = _derived_seed(candidate.map_id, &"map.height", "relief-height-v1")
	var scenery: Variant = _derived_seed(candidate.map_id, &"map.scenery", "context-envelope-v3")
	if noise == null or scenery == null:
		_show_toast("无法取得地图显示的随机地址")
		return false
	var snapshot: Dictionary = candidate.get_snapshot()
	var config := _height_config(candidate.floor_index)
	# 顶端是固定地图：地形与外围也固定，货架随机仍由独立商店流负责。
	if candidate.floor_index == 4:
		noise = 4042026
		scenery = 4042027
	var identity: String = candidate.fingerprint + "|" + JSON.stringify(config) + "|" + JSON.stringify(snapshot.get("height_recipe", {}))
	var layer: Dictionary = MapPresentation.height_layer if identity == MapPresentation.height_identity else {}
	var surroundings: Dictionary = MapPresentation.envelope if not layer.is_empty() else {}
	if layer.is_empty():
		var generator = Heights.new()
		layer = generator.generate(snapshot, int(noise), config)
		if layer.is_empty():
			_show_toast("高度生成拒绝：" + generator.last_error)
			return false
		surroundings = Envelope.generate(layer, int(scenery))
	var sampler = Support.new()
	if not sampler.load_layer(layer):
		_show_toast("高度采样拒绝：" + sampler.last_error)
		return false
	if MapPresentation.height_identity != identity:
		MapPresentation.veil_revision = ""
		MapPresentation.discovery_revision = 0
	MapPresentation.height_identity = identity
	MapPresentation.height_layer = layer
	MapPresentation.envelope = surroundings
	height_layer = layer
	_envelope = surroundings
	support = sampler
	_animated_plane = candidate.actor_plane
	_prepare_error = ""
	entry_ready_ms = -1.0
	return true

func _plane_to_display(point: Vector2) -> Vector2:
	return _view.project_plane(point, support.height_at(point))

func _place_actor(point: Vector2) -> void:
	_player.position = _plane_to_display(point)
	# Publish position and animation together once at the end of advance_actor.
	_view.update_actor(point, support.height_at(point), true)

func _direction_to_plane(direction: Vector2) -> Vector2:
	return _view.unproject_plane(direction).normalized()

func _advance_motion(direction: Vector2, delta: float) -> void:
	_actor_facing_intent = _view.project_plane(direction) if is_instance_valid(_view) else Vector2.ZERO
	super._advance_motion(direction, delta)

func _presentation_layer() -> Dictionary:
	var layer := height_layer.duplicate()
	var reservations: Array = []
	for node: Dictionary in height_layer.get("nodes", []):
		reservations.append({"coord": node.coord, "is_gate": bool(node.get("is_route_gate", false)), "protected": node.get("height_flat_footprint", [])})
	layer["rock_reservations"] = reservations
	layer["scene_envelope"] = _envelope
	return layer

func _sync_view() -> void:
	_fade_focus_for_entry()
	var data: Dictionary = session.get_view()
	var layer := _presentation_layer().duplicate()
	var visible_ids: Dictionary = {}
	for node in data.nodes:
		if bool(node.get("known", false)): visible_ids[node.id] = true
	layer.nodes = []
	for node in height_layer.nodes:
		if visible_ids.has(node.id): layer.nodes.append(node)
	var sun: Dictionary = ReliefView.SUN_DEFAULTS.duplicate()
	sun.merge(_sun_settings.get("common", {}), true)
	sun.merge(_sun_settings.get("floors", {}).get(str(session.floor_index), {}), true)
	_view.set_sun_config(sun, false)
	var atmosphere: Dictionary = _atmosphere_settings.get("common", {}).duplicate(true)
	atmosphere.merge(_atmosphere_settings.get("floors", {}).get(str(session.floor_index), {}), true)
	_view.set_atmosphere_config(atmosphere, false)
	_view.set_wall_cutaway_context(session.map_id, session.seed, session.floor_index, session.reachable(), true, session.collision_boundaries())
	_view.set_layer(layer, session.known, session.completed, _binding_presentation)
	_view.set_node_presentations(data.nodes)
	_sync_node_mist(data.nodes)
	if not _view.is_rebuilding():
		support.set_visibility(session.known, true)
		_sync_veil()
	_mini.set_view(data, cell_radius_px)
	RenderingServer.set_default_clear_color(_view.get_atmosphere_background())
	_view.flush_dynamic()
	_queue_discovery()

func _update_selection() -> void:
	super._update_selection()
	_target_marker.hide() # Ground marker cannot draw over a high wall.
	if not is_instance_valid(_node_hint): return
	if not MapPresentation.owns(self) or not is_map_ready() or paused or not session.pending.is_empty() or _selected not in session.nearby_nodes():
		_node_hint.clear()
		return
	# 圈和图标仍只读取发布过的已知节点；名字仅在 Session 已确认靠近时读取。
	var node: Dictionary = _view._node_presentations.get(_selected, {})
	if node.is_empty():
		_node_hint.clear()
		return
	var marker_bounds := Rect2()
	# 只取当前目标自己的已发布贴图，避免借用同批次内其他节点的位置。
	for batch in _view._node_batches.get(_selected, []):
		for face: Dictionary in batch.faces:
			if face.get("node_marker", false) and str(face.get("node_id", "")) == _selected:
				marker_bounds = face.bounds
				break
		if marker_bounds.has_area(): break
	if not marker_bounds.has_area():
		_node_hint.clear()
		return
	var anchor := Vector2(marker_bounds.get_center().x, marker_bounds.end.y)
	_node_hint.set_node(node, anchor, _player.position, _camera.zoom.x, _node_label(session.nodes[_selected]), marker_bounds)

func _sync_actor(emit_notifications: bool = true) -> void:
	_actor_facing_intent = Vector2.ZERO
	super._sync_actor(emit_notifications)
	if not MapPresentation.owns(self): return
	_update_render_cache()
	_view.flush_dynamic()
	_sync_node_mist(session.get_view().nodes)
	if is_instance_valid(_fog_veil):
		_fog_veil.set_view(_view._cache_view)
		_fog_veil.set_focus(_view.project_plane(_view._actor_plane, _view._actor_height + _view.ACTOR_HEIGHT * 0.32), 0.6)
	MapPresentation.present(self)


func _after_fast_travel() -> void:
	# A discontinuous move is not walking: reset animation displacement along
	# with the flat host's render path, while normal support supplies elevation.
	_animated_plane = session.actor_plane
	_actor_facing_intent = Vector2.ZERO
	_view.advance_actor(Vector2.ZERO, 0.0, Vector2.ZERO)


func _fast_travel_ready() -> bool:
	return is_map_ready()

func _fast_travel_portrait() -> Dictionary:
	var animation = _view.actor_animation
	var feet: Vector2 = _view.project_plane(session.actor_plane, support.height_at(session.actor_plane))
	var transform := _view.get_global_transform_with_canvas()
	var rect: Rect2 = animation.draw_rect(feet)
	var body: Rect2 = animation.body_rect(feet)
	return {"feet": transform * feet,
		"rect": Rect2(transform * rect.position, rect.size * transform.get_scale().abs()),
		"body": Rect2(transform * body.position, body.size * transform.get_scale().abs()),
		"texture": animation.textures.get(str(animation.frame().get("path", "")))}

func _queue_discovery() -> void:
	if _discovery_prepare_queued: return
	_discovery_prepare_queued = true
	call_deferred("_prepare_discovery")

func _prepare_discovery() -> void:
	_discovery_prepare_queued = false
	if not MapPresentation.owns(self) or not is_instance_valid(_view) or _view.is_rebuilding(): return
	var layer := _presentation_layer()
	var revision := hash(layer)
	var progress: Dictionary = _view.get_presentation_cache_progress()
	if revision == MapPresentation.discovery_revision and int(progress.total_states) > 0: return
	var plan := Discovery.build(session.get_snapshot(), layer)
	if plan.has("error"):
		_prepare_error = plan.error
	elif _view.prepare_presentation_cache(plan.states):
		MapPresentation.discovery_revision = revision
	else:
		_prepare_error = "本层显示准备失败，请返回菜单后重试"
	if not _prepare_error.is_empty(): push_error(_prepare_error)

## 新层第一次出图时把角色光从全暗拉起；同一层重刷不重放。
func _fade_focus_for_entry() -> void:
	if not is_instance_valid(_fog_veil): return
	var identity := "%s:%d" % [session.seed, session.floor_index]
	if identity == _focus_identity: return
	_focus_identity = identity
	_fog_veil.fade_focus_in()

func _sync_veil() -> void:
	if not is_instance_valid(_fog_veil) or not _fog_veil.is_inside_tree(): return
	var revision := "%s:%s:%s" % [session.seed, session.floor_index, hash([_view._known, _view._source_snapshot])]
	if revision != MapPresentation.veil_revision:
		_fog_veil.sync(_view, not MapPresentation.veil_revision.is_empty())
		MapPresentation.veil_revision = revision

func _presentation_committed() -> void:
	if not MapPresentation.owns(self): return
	_view.set_node_presentations(session.get_view().nodes)
	_sync_node_mist(session.get_view().nodes)
	support.set_visibility(session.known, true)
	_sync_actor(false)
	_sync_veil()
	_update_camera()
	_queue_discovery()

## 可交互的已知节点共用底座雾圈；只有已存在的模型才提供锚点与尺寸。
func _sync_node_mist(nodes: Array) -> void:
	if not is_instance_valid(_node_mist): return
	var bases: Array = []
	for node: Dictionary in nodes:
		if not bool(node.get("known", false)): continue
		var kind := str(node.get("type", ""))
		if kind not in ["battle", "elite", "boss", "event", "shop", "chest", "pile"]: continue
		if bool(node.get("completed", false)):
			var revisitable: bool = bool(session.nodes.get(node.id, {}).get("revisitable", false))
			if kind not in ["event", "shop"] or not revisitable: continue
		var center := Vector2.ZERO
		var width := 0.0
		for batch in _view._node_batches.get(node.id, []):
			for face: Dictionary in batch.faces:
				if face.get("node_marker", false):
					center = Vector2(face.bounds.get_center().x, face.bounds.end.y)
					width = face.bounds.size.x
		if width <= 0.0: continue
		bases.append({"center": center, "width": width, "phase": float(abs(hash(node.id)) % 628) / 100.0,
			"palette": "gold" if kind in ["event", "shop", "chest", "pile"] else "red"})
	_node_mist.set_bases(bases)

## Current support/geometry is usable independently of future discovery variants.
func is_current_map_ready() -> bool:
	return not height_layer.is_empty() and _prepare_error.is_empty() and not _discovery_prepare_queued and is_instance_valid(_view) and not _view.is_rebuilding()

func is_map_ready() -> bool:
	return is_current_map_ready() and not _view.is_presentation_cache_preparing()

func scene_transition_error() -> String:
	if not _prepare_error.is_empty():
		return _prepare_error
	return session.last_error if height_layer.is_empty() else ""

func _physics_process(delta: float) -> void:
	if not is_map_ready():
		_advance_motion(Vector2.ZERO, delta)
		return
	super._physics_process(delta)

func _interact() -> void:
	if not is_map_ready():
		_show_toast(_prepare_error if not _prepare_error.is_empty() else "正在准备本层显示，请稍候")
		return
	super._interact()

func _update_camera() -> void:
	if not is_inside_tree() or not is_instance_valid(_camera) or not is_instance_valid(_view): return
	_camera.zoom = Vector2.ONE * FOLLOW_ZOOM_AT_100 * map_scale
	_camera.position = Vector2.ZERO
	_camera.force_update_scroll()
	_update_render_cache()
	_update_minimap()

func _update_render_cache() -> void:
	if not is_instance_valid(_view) or not is_instance_valid(_camera): return
	var half := get_viewport_rect().size / (_camera.zoom * 2.0)
	var stretch := get_viewport().get_stretch_transform().get_scale().abs()
	_view.set_cache_view(Rect2(_camera.global_position - half, half * 2), _camera.zoom.x * maxf(stretch.x, stretch.y))

func _update_minimap() -> void:
	if not is_inside_tree() or not is_instance_valid(_mini) or not is_instance_valid(_camera): return
	var half := get_viewport_rect().size / (_camera.zoom * 2)
	var center := _camera.global_position
	var corners := [center - half, center + Vector2(half.x, -half.y), center + half, center + Vector2(-half.x, half.y)]
	var rectangle := Rect2(_view.unproject_plane(corners[0]), Vector2.ZERO)
	for point in corners: rectangle = rectangle.expand(_view.unproject_plane(point))
	_mini.set_player(_render_actor_plane, rectangle)
	if is_instance_valid(_menu_map): _menu_map.set_actor(_render_actor_plane)

func _process(delta: float) -> void:
	super._process(delta)
	if not is_instance_valid(_view): return
	_update_render_cache()
	_view.advance_actor(_render_actor_plane - _animated_plane, delta, _actor_facing_intent)
	_animated_plane = _render_actor_plane
	if is_instance_valid(_fog_veil):
		_fog_veil.set_view(_view._cache_view)
		_fog_veil.set_focus(_view.project_plane(_view._actor_plane, _view._actor_height + _view.ACTOR_HEIGHT * 0.32), 0.6)
	if not is_map_ready():
		var progress: Dictionary = _view.get_presentation_cache_progress()
		_prompt.text = _prepare_error if not _prepare_error.is_empty() else "正在进入第 %d 层 · 显示准备 %d / %d" % [session.floor_index, progress.prepared_states, progress.total_states]
	elif entry_ready_ms < 0:
		entry_ready_ms = (Time.get_ticks_usec() - _entry_started_usec) / 1000.0

func _exit_tree() -> void:
	if is_instance_valid(_view) and _view.presentation_committed.is_connected(_presentation_committed):
		_view.presentation_committed.disconnect(_presentation_committed)
	if MapPresentation.owns(self):
		MapPresentation.release(self)
		RenderingServer.set_default_clear_color(Color("101923"))

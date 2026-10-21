extends Node2D

const NodeArt = preload("res://systems/map/relief_2d/node_art.gd")
var _node_presentations: Dictionary = {}
const RockScatter = preload("res://systems/map/relief_2d/rock_scatter.gd")
var _rock_layout: Dictionary = {}
## Fixed-camera, planar Node2D prototype. Basis/Vector3 are projection math only.
## Static convex faces use overlap ordering. Actor occlusion is a separate
## per-face affine ray-depth comparison, independent of sprite/image-center Y.
## No navigation, collision, connectivity or discovery is inferred from height.

signal presentation_committed

const PITCH_DEGREES := 35.2643897
const YAW_DEGREES := 35.0
const PIXELS_PER_WORLD := 60.0
const FloorRenderData = preload("res://systems/map/relief_2d/floor_render_data.gd")
const VectorBatch = preload("res://systems/map/relief_2d/vector_batch.gd")
const VECTOR_BATCH_FACES := 128
const SURFACE_OCCLUDER_CACHE_RECEIVERS := 64
const SURFACE_OCCLUDER_CACHE_PAIRS := 1024
const SURFACE_OCCLUDER_CACHE_POLYGONS := 4096
const SURFACE_OCCLUDER_CACHE_VERTICES := 16384
const Profile = preload("res://systems/map/relief_2d/actor_profile.gd")
const ActorAnimation = preload("res://systems/map/relief_2d/actor_animation.gd")
const SolarLighting = preload("res://systems/map/relief_2d/solar_lighting.gd")
const Env005Material = preload("res://systems/map/relief_2d/env005_material.gd")
const ExplorationFog = preload("res://systems/map/relief_2d/exploration_fog.gd")
const ActorSurfaceLight = preload("res://systems/map/relief_2d/actor_surface_light.gd")
const ActorEmission = preload("res://systems/map/relief_2d/actor_emission_2d.gd")
const WallCutaway = preload("res://systems/map/relief_2d/wall_cutaway.gd")
const ActorCutawayRestore = preload("res://systems/map/relief_2d/actor_cutaway_restore.gd")
const ActorOcclusionHint = preload("res://systems/map/relief_2d/actor_occlusion_hint.gd")
const AtmosphereLighting = preload("res://systems/map/relief_2d/atmosphere_lighting.gd")
const SceneVolume = preload("res://systems/map/relief_2d/scene_volume.gd")
const SurfaceClipper = preload("res://systems/map/relief_2d/surface_clipper.gd")
const ACTOR_HEIGHT := Profile.HEIGHT
const DEPTH_EPSILON := 0.0003
const DIRS := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
const INK := Color("39413d")
const GROUND := Color("c6cdbf")
const FOG := Color("5e6864")
const OCHRE := Color("bd9753")
const FACE_BIN_SIZE := 128.0
const SUN_DEFAULTS := {"enabled": true, "azimuth_degrees": 135.0, "elevation_degrees": 45.0, "ambient": 0.30, "direct": 0.70}

@export var show_grid: bool = true:
	set(value):
		show_grid = value
		if not _cells.is_empty():
			if is_rebuilding(): _request_geometry(_pending_layer,_pending_known,_pending_completed,true)
			else:
				_refresh_meshes()
				_refresh_actor()
		queue_redraw()
@export var show_debug: bool = false:
	set(value):
		show_debug = value
		queue_redraw()
@export var show_node_regions: bool = true:
	set(value):
		if show_node_regions == value: return
		show_node_regions = value
		if not _cells.is_empty():
			if is_rebuilding(): _request_geometry(_pending_layer,_pending_known,_pending_completed,true)
			else: _rebuild()

var _basis := Basis.from_euler(Vector3(-deg_to_rad(PITCH_DEGREES), deg_to_rad(YAW_DEGREES), 0.0))
var _cells: Dictionary = {}
var _nodes: Array = []
var _known: Dictionary = {}
var _completed: Dictionary = {}
var _faces: Array[Dictionary] = []
var _sorted_faces: Array[Dictionary] = []
var _front_faces: Array[Dictionary] = []
var _pick_tops: Array[Dictionary] = []
var _actor_plane := Vector2.ZERO
var _actor_height := 0.0
var _actor_valid := false
var _actor_shape := PackedVector2Array()
var _actor_aperture := Rect2()
var _quantum := 0.20
var _radius := 1.0
var _bounds := Rect2()
var _report: Dictionary = {}
var _ordering_cycles := 0
var _static_overlap_pairs := 0
var _ambiguous_overlap_pairs := 0
var _duplicate_cells: Array[String] = []
var _wall_readability_cache: Dictionary = {}
var _skipped_nodes: Array[String] = []
var _static_rebuild_count := 0
var actor_animation = ActorAnimation.new()
var _vector_batches: Array = []
var _node_batches: Dictionary = {}
var _mesh_refresh_count := 0
var _mesh_refresh_usec := 0
var _cache_view := Rect2()
var _cache_display_scale := 1.0
var _face_bins: Dictionary = {}
# Lazy static fog surfaces/depth clips, current presentation only. Dynamic
# query polygons and their subtraction remainders stay uncached.
var _surface_occluder_cache_enabled := true
var _surface_occluder_cache_rows: Array[Dictionary] = []
var _surface_occluder_cache_bins: Dictionary = {}
var _surface_occluder_cache_clock := 0
var _surface_occluder_cache_pairs := 0
var _surface_occluder_cache_polygons := 0
var _surface_occluder_cache_vertices := 0
var _surface_occluder_cache_hits := 0
var _surface_occluder_cache_misses := 0
var _surface_occluder_cache_fog_hits := 0
var _surface_occluder_cache_fog_misses := 0
var _surface_occluder_cache_evictions := 0
var _surface_occluder_cache_skips := 0
var _source_snapshot: Dictionary = {}
var _floor_data: RefCounted
var _pending_floor_data: RefCounted
var _prepared_face_groups: Array = []
# Presentation-only solids never enter the authoritative support-cell table.
var _scenery_cells: Dictionary = {}
var _scenery_volumes: Array[Dictionary] = []
var _scenery_stats: Dictionary = {}
var _scenery_bounds := Rect2()
var _sun_dirty := false
var _display_sun_config: Dictionary = SUN_DEFAULTS.duplicate()
var _publish_timings := {}
var _material_update_count := 0
var _order_candidate_pairs := 0
var _order_coplanar_skips := 0
var _rebuild_timings := {}
var _input_load_ms := 0.0
var _geometry_thread: Thread
var _geometry_builder: Node2D
var _geometry_generation := 0
var _job_generation := -1
var _pending_layer: Dictionary = {}
var _pending_known: Dictionary = {}
var _pending_sun_config: Dictionary = {}
var _pending_grid := true
var _pending_node_regions := true
var _pending_completed: Dictionary = {}
var _pending_batches: Array = []
var _retired_batches: Array = []
var _pending_arrays: Array = []
var _pending_cursor := 0
var _async_rebuild_count := 0
var _async_elapsed_usec := 0
var _async_start_usec := 0
var _visible_actor_regions: Array[PackedVector2Array] = []
var _hidden_actor_regions: Array[PackedVector2Array] = []
var _actor_occlusion_hint_enabled := true
var _actor_occlusion_hint: Node2D
var _surface_light = ActorSurfaceLight.new()
var _wall_cutaway: RefCounted
var _actor_cutaway_restore: Node2D
var _cutaway_warmup_drawn := false
var _wall_restore_regions: Array[PackedVector2Array] = []
var _dynamic_dirty := false
var _dynamic_draw_count := 0
var _solar = SolarLighting.new()
var _solar_snapshot: Dictionary = {}
var _sun_config: Dictionary = SUN_DEFAULTS.duplicate()
var _sun_report: Dictionary = {}
var _actor_light := 1.0
var _actor_atmosphere_tint := Color.WHITE
var _art = Env005Material.new()
var _art_enabled := false
var _display_art_enabled := false
var _pending_art_enabled := false
var _art_dirty := false
var _art_actor_shadow_batch: Node2D
var _atmosphere = AtmosphereLighting.new()
var _atmosphere_config: Dictionary = AtmosphereLighting.DEFAULTS.duplicate()
var _display_atmosphere_config: Dictionary = AtmosphereLighting.DEFAULTS.duplicate()
var _pending_atmosphere_config: Dictionary = {}
var _atmosphere_dirty := false
var _atmosphere_material_updates := 0
var _actor_solar_shadows: Array[Dictionary] = []
# Current presentation only; original cached batch commands are never replaced.
var _wall_shadow_batches: Dictionary = {}
var _wall_shadow_active: Array = []
var _wall_shadow_applied: Dictionary = {}
var _wall_shadow_stats := {"faces":0,"pieces":0,"batches":0,"triangles":0,"unbound_pieces":0,"build_ms":0.0,"updates":0}
var _incremental_presentation_enabled := true # Per-face material reuse only.
var _material_face_cache: Dictionary = {}
var _material_context_id := 0
# At most one lookahead alongside the current CPU job. Neither owns GPU nodes.
var _warm_lookahead: Dictionary = {}
var _retired_warm_jobs: Array[Dictionary] = []
var _parallel_warm_enabled := true
var _warm_lookahead_hits := 0
var _reuse_report: Dictionary = {}
var _exploration_fog_visual_mode := "legacy_vertex"
var _display_exploration_fog_visual_mode := "legacy_vertex"
const CACHE_FIELDS := ["_rock_layout","_floor_data","_cells","_nodes","_source_snapshot","_solar_snapshot","_scenery_cells","_scenery_volumes","_scenery_stats","_scenery_bounds","_known","_completed","_faces","_sorted_faces","_pick_tops","_bounds","_face_bins","_solar","_sun_report","_display_sun_config","_art","_display_art_enabled","_exploration_fog","_display_exploration_fog_enabled","_atmosphere","_display_atmosphere_config","_skipped_nodes","_duplicate_cells","_ordering_cycles","_static_overlap_pairs","_ambiguous_overlap_pairs","_order_candidate_pairs","_order_coplanar_skips","_rebuild_timings","_material_face_cache","_material_context_id","_reuse_report","_display_exploration_fog_visual_mode","_quantum","_radius","_wall_readability_cache"]
var _presentation_cache_plan: Array[Dictionary] = []
var _presentation_cache_entries: Dictionary = {}
var _presentation_cache_plan_keys: Array[String] = []
var _presentation_cache_current := ""
var _presentation_cache_warming := false
var _presentation_cache_warming_key := ""
var _presentation_cache_dirty := false
var _presentation_cache_start_usec := 0
var _presentation_cache_prepare_ms := 0.0
var _presentation_cache_memory_before := 0
var _presentation_cache_memory_delta := 0
var _presentation_cache_hits := 0
var _presentation_cache_misses := 0
var _presentation_cache_commit_ms := 0.0
var _presentation_cache_signature: Array = []

var _exploration_fog = ExplorationFog.new()
var _exploration_fog_enabled := false
var _display_exploration_fog_enabled := false
var _pending_exploration_fog_enabled := false
var _exploration_fog_dirty := false
var _actor_emission_strength := 0.0
var _actor_emission_batch: Node2D



func _ready() -> void:
	# Geometry is rasterized at the current window scale; no magnified map cache.
	get_viewport().msaa_2d = Viewport.MSAA_4X
	_prime_cutaway_pipeline()

func _prime_cutaway_pipeline() -> void:
	# Canvas shaders compile on their first actual draw, not on preload.
	# Use this viewport (including its MSAA), before traversable geometry is ready.
	var frame: Dictionary = actor_animation.frame()
	if frame.is_empty() or DisplayServer.get_name() == "headless": return
	var layer := CanvasLayer.new()
	layer.layer = -128
	var primer := ActorCutawayRestore.new()
	primer.prepare_invisible_draw(actor_animation.textures[frame.path])
	layer.add_child(primer)
	add_child(layer)
	RenderingServer.frame_post_draw.connect(func():
		_cutaway_warmup_drawn = true
		if is_instance_valid(layer): layer.queue_free()
	, CONNECT_ONE_SHOT)

func _init(load_actor: bool = true) -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if load_actor: actor_animation.load_config("res://data/config/relief_2d/actor.json", ACTOR_HEIGHT * _basis.y.y * PIXELS_PER_WORLD)
	if actor_animation.config.get("texture_filter", "nearest") == "linear_mipmap":
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_configure_sun()


func _configure_sun() -> void:
	_display_sun_config = _sun_config.duplicate(true)
	var azimuth := deg_to_rad(float(_sun_config.get("azimuth_degrees", 135.0)))
	var elevation := deg_to_rad(clampf(float(_sun_config.get("elevation_degrees", 45.0)), 10.0, 85.0))
	var config := _sun_config.duplicate()
	config["sun_direction"] = Vector3(cos(azimuth) * cos(elevation), sin(elevation), sin(azimuth) * cos(elevation))
	_solar.configure(config)


func set_sun_config(config: Dictionary, rebuild: bool = true) -> bool:
	var next := _sun_config.duplicate()
	for field in ["azimuth_degrees", "elevation_degrees", "ambient", "direct"]:
		var value: Variant = config.get(field, next[field])
		if (not value is int and not value is float) or not is_finite(float(value)): return false
		next[field] = float(value)
	if config.has("enabled"):
		if not config.enabled is bool: return false
		next.enabled = config.enabled
	next.azimuth_degrees = fposmod(next.azimuth_degrees, 360.0)
	next.elevation_degrees = clampf(next.elevation_degrees, 10.0, 85.0)
	next.ambient = clampf(next.ambient, 0.0, 1.0)
	next.direct = clampf(next.direct, 0.0, 1.0 - next.ambient)
	if next == _sun_config: return true
	_sun_config = next
	_actor_shadow_dirty = true
	_invalidate_presentation_cache()
	_sun_dirty = true
	if is_rebuilding(): _request_geometry(_pending_layer,_pending_known,_pending_completed,true)
	elif rebuild and not _cells.is_empty(): _rebuild()
	return true


func set_atmosphere_config(config: Dictionary, rebuild: bool = true) -> bool:
	var next: Dictionary = AtmosphereLighting.merged(_atmosphere_config,config)
	if next.is_empty(): return false
	if next == _atmosphere_config: return true
	_atmosphere_config = next
	_invalidate_presentation_cache()
	_atmosphere_dirty = true
	if is_rebuilding(): _pending_atmosphere_config = next.duplicate(true)
	if _cells.is_empty() and not is_rebuilding():
		_refresh_atmosphere_cache()
	elif rebuild:
		# Palette changes never re-run solar projection, geometry, or ordering.
		_refresh_atmosphere_cache()
		_refresh_meshes()
		_refresh_actor()
	return true


func set_art_enabled(enabled: bool, rebuild: bool = true) -> void:
	if enabled == _art_enabled: return
	_art_enabled = enabled;_art_dirty=true
	_invalidate_presentation_cache()
	if is_rebuilding(): _pending_art_enabled=enabled
	if _cells.is_empty() and not is_rebuilding(): _refresh_art_cache()
	elif rebuild:
		_refresh_art_cache();_refresh_meshes();_refresh_actor()


func is_art_enabled() -> bool:
	return _display_art_enabled


func _refresh_art_cache() -> void:
	_display_art_enabled=_art_enabled
	_art.configure(_display_art_enabled,_source_snapshot,_known)
	_art_dirty=false


func set_exploration_fog_enabled(value: bool) -> void:
	if value == _exploration_fog_enabled: return
	_exploration_fog_enabled=value;_exploration_fog_dirty=true
	_invalidate_presentation_cache()
	if is_rebuilding(): _pending_exploration_fog_enabled=value
	_refresh_exploration_fog_cache()
	if not _cells.is_empty(): _refresh_meshes();_refresh_actor()


func is_exploration_fog_enabled() -> bool:
	return _display_exploration_fog_enabled


func _refresh_exploration_fog_cache() -> void:
	_clear_surface_occluder_cache()
	_display_exploration_fog_enabled=_exploration_fog_enabled
	_exploration_fog.configure(self,_display_exploration_fog_enabled)
	_exploration_fog_dirty=false


func _fog_alpha(face: Dictionary, point: Vector2) -> float:
	if not is_exploration_fog_enabled(): return 1.0
	if not face.get("known",false): return 0.0
	if _display_exploration_fog_visual_mode=="veil": return 1.0
	var world := _face_world_at(face,point)
	if face.get("scenery",false):
		# These solids have already passed their complete reveal-key contract.
		# The whole-site backdrop alone is clipped to a known-derived halo.
		return _exploration_fog.site_visibility(self,Vector2(world.x,world.z)) if face.get("scene_role","")=="site" else 1.0
	return _exploration_fog.visibility(Vector2(world.x,world.z))


func set_exploration_fog_visual_mode(mode: String) -> bool:
	if mode not in ["legacy_vertex","veil"]: return false
	if mode==_exploration_fog_visual_mode: return true
	_exploration_fog_visual_mode=mode
	_invalidate_presentation_cache()
	_display_exploration_fog_visual_mode=mode
	if not _cells.is_empty(): _refresh_meshes();_refresh_actor()
	return true


func get_exploration_visibility_polygons() -> Array[PackedVector2Array]:
	var polygons: Array[PackedVector2Array] = []
	for face: Dictionary in _sorted_faces:
		if face.has("rock") or face.get("node_marker", false): continue
		if not face.known: continue
		polygons.append_array(_fog_surface_regions(face,face.polygon))
	return polygons


func _fog_surface_regions(face: Dictionary, polygon: PackedVector2Array) -> Array[PackedVector2Array]:
	if is_exploration_fog_enabled(): return _exploration_fog.surface_regions(self,face,polygon)
	var result: Array[PackedVector2Array] = [polygon]
	return result


func set_actor_emission_strength(value: float) -> bool:
	if not is_finite(value) or value<0.0 or value>1.0: return false
	if is_equal_approx(value,_actor_emission_strength): return true
	_actor_emission_strength=value
	_surface_light.refresh(self)
	_refresh_actor_emission()
	queue_redraw()
	return true


func get_actor_emission_strength() -> float:
	return _actor_emission_strength


func _cache_key(snapshot: Dictionary, known: Dictionary) -> String:
	var keys: Array = []
	for key in known:
		if known[key]: keys.append(key)
	keys.sort()
	var ids: Array = []
	for node: Dictionary in snapshot.get("nodes",[]): ids.append(node.id)
	ids.sort()
	return JSON.stringify([keys,ids])


func _cache_config_signature() -> Array:
	return [_sun_config,_atmosphere_config,_art_enabled,_exploration_fog_enabled,_exploration_fog_visual_mode,show_grid,show_node_regions,_art.cache_identity()]


func prepare_presentation_cache(states: Array[Dictionary]) -> bool:
	if states.is_empty() or states.size()>4 or _source_snapshot.is_empty(): return false
	if states==_presentation_cache_plan and not _presentation_cache_dirty and _cache_config_signature()==_presentation_cache_signature: return true
	var plan: Array[Dictionary] = []
	var includes_current := false
	var seen_snapshots: Dictionary = {}
	var current_key := _cache_key(_source_snapshot,_known)
	for state in states:
		if not state.get("snapshot") is Dictionary or not state.get("known") is Dictionary or not state.get("completed",{}) is Dictionary: return false
		var snapshot: Dictionary = state.snapshot
		for field in ["map_id","seed","floor_index","cells","height_quantum","outer_radius","scene_envelope"]:
			if snapshot.get(field)!=_source_snapshot.get(field): return false
		for key in state.known:
			if not state.known[key] is bool or not _cells.has(key): return false
		var key := _cache_key(snapshot,state.known)
		if seen_snapshots.has(key) and seen_snapshots[key]!=snapshot: return false
		seen_snapshots[key]=snapshot
		if key==current_key: includes_current=true
		plan.append({"snapshot":_floor_data.snapshot_for(snapshot),"known":state.known.duplicate(true),"completed":state.get("completed",{}).duplicate(true)})
	if not includes_current: return false
	_clear_presentation_cache()
	_presentation_cache_plan=plan
	for state in plan:
		var key := _cache_key(state.snapshot,state.known)
		if key not in _presentation_cache_plan_keys: _presentation_cache_plan_keys.append(key)
	_presentation_cache_signature=_cache_config_signature().duplicate(true)
	_presentation_cache_start_usec=Time.get_ticks_usec()
	_presentation_cache_memory_before=int(Performance.get_monitor(Performance.MEMORY_STATIC))
	_store_current_presentation()
	_warm_next_presentation()
	return true


func is_presentation_cache_ready() -> bool:
	if not _warm_lookahead.is_empty() or not _retired_warm_jobs.is_empty(): return false
	if _presentation_cache_plan.is_empty(): return true
	if _presentation_cache_dirty or _presentation_cache_warming: return false
	for key in _presentation_cache_plan_keys:
		if not _presentation_cache_entries.has(key): return false
	return true


func is_presentation_cache_preparing() -> bool:
	if not _warm_lookahead.is_empty() or not _retired_warm_jobs.is_empty(): return true
	return not _presentation_cache_plan.is_empty() and not is_presentation_cache_ready()


func get_presentation_cache_progress() -> Dictionary:
	var total := _presentation_cache_plan_keys.size()
	var prepared := 0
	for key in _presentation_cache_plan_keys:
		if _presentation_cache_entries.has(key): prepared+=1
	var fraction := float(prepared)/maxi(1,total)
	return {"ready":is_presentation_cache_ready(),"preparing":is_presentation_cache_preparing(),"prepared_states":prepared,"total_states":total,"progress":fraction,"stage":"cpu" if _geometry_thread!=null else ("mesh" if _presentation_cache_warming else ("ready" if is_presentation_cache_ready() else "pending"))}


func _capture_presentation():
	var state=get_script().new(false)
	for field in CACHE_FIELDS: state.set(field,get(field))
	return state


func _store_current_presentation() -> void:
	if _source_snapshot.is_empty(): return
	var key := _cache_key(_source_snapshot,_known)
	if _presentation_cache_entries.has(key):
		var state=_presentation_cache_entries[key].state
		for field in CACHE_FIELDS: state.set(field,get(field))
		_presentation_cache_entries[key].batches=_vector_batches.duplicate()
		_presentation_cache_entries[key].wall_shadow_batches=_wall_shadow_batches.duplicate()
	else:
		_presentation_cache_entries[key]={"state":_capture_presentation(),"batches":_vector_batches.duplicate(),"wall_shadow_batches":_wall_shadow_batches.duplicate()}
	_presentation_cache_current=key


func _clear_presentation_cache() -> void:
	_discard_warm_lookahead()
	if _presentation_cache_warming:
		_presentation_cache_warming=false
		_cancel_geometry()
	for entry: Dictionary in _presentation_cache_entries.values():
		for batch in entry.batches:
			if is_instance_valid(batch) and batch not in _vector_batches: batch.queue_free()
		if is_instance_valid(entry.state): entry.state.free()
	_presentation_cache_entries.clear()
	_presentation_cache_current="";_presentation_cache_warming_key=""
	_presentation_cache_plan.clear();_presentation_cache_plan_keys.clear();_presentation_cache_dirty=false


func _invalidate_presentation_cache() -> void:
	if _floor_data!=null: _floor_data.clear_packets()
	if _presentation_cache_plan.is_empty(): return
	var plan := _presentation_cache_plan.duplicate()
	var keys := _presentation_cache_plan_keys.duplicate()
	_clear_presentation_cache()
	_presentation_cache_plan=plan
	_presentation_cache_plan_keys=keys
	_material_face_cache={}
	_presentation_cache_dirty=true
	set_process(true)


func _warm_next_presentation() -> void:
	if _presentation_cache_plan.is_empty() or _geometry_thread!=null or _geometry_builder!=null: return
	if _presentation_cache_dirty:
		if _atmosphere_dirty or _art_dirty or _sun_dirty: return
		_presentation_cache_dirty=false
		_presentation_cache_signature=_cache_config_signature().duplicate(true)
		_presentation_cache_start_usec=Time.get_ticks_usec()
		_store_current_presentation()
	for state in _presentation_cache_plan:
		var key := _cache_key(state.snapshot,state.known)
		if _presentation_cache_entries.has(key): continue
		_presentation_cache_warming=true;_presentation_cache_warming_key=key
		_request_geometry(state.snapshot,state.known,state.get("completed",{}))
		_start_warm_lookahead()
		return
	_floor_data.clear_packets()
	_presentation_cache_prepare_ms=(Time.get_ticks_usec()-_presentation_cache_start_usec)/1000.0
	_presentation_cache_memory_delta=int(Performance.get_monitor(Performance.MEMORY_STATIC))-_presentation_cache_memory_before
	set_process(not _retired_warm_jobs.is_empty() or not _warm_lookahead.is_empty() or not _retired_batches.is_empty() or not _presentation_cache_plan.is_empty())


func _publish_warm_presentation() -> void:
	for batch in _pending_batches: batch.hide()
	# The worker has finished and all matching batches exist. Retain this
	# presentation's index once, rather than scanning its faces on each bind.
	var wall_batches := _build_wall_shadow_batch_index(_geometry_builder,_pending_batches)
	_presentation_cache_entries[_presentation_cache_warming_key]={"state":_geometry_builder,"batches":_pending_batches,"wall_shadow_batches":wall_batches}
	_geometry_builder=null;_pending_batches=[]
	_pending_floor_data=null
	_pending_layer={};_pending_known={};_pending_completed={};_pending_atmosphere_config={};_pending_arrays=[];_pending_cursor=0
	_presentation_cache_warming=false;_presentation_cache_warming_key=""
	_warm_next_presentation()


func _try_cached_presentation(snapshot: Dictionary, known: Dictionary, completed: Dictionary) -> bool:
	if _presentation_cache_plan.is_empty() or _presentation_cache_dirty: return false
	if _cache_config_signature()!=_presentation_cache_signature:
		_invalidate_presentation_cache();return false
	var key := _cache_key(snapshot,known)
	if key==_presentation_cache_current and _source_snapshot==snapshot and _known==known:
		_update_completed(completed);return true
	if not _presentation_cache_entries.has(key) or _presentation_cache_entries[key].state._source_snapshot!=snapshot:
		_presentation_cache_misses+=1;return false
	var started := Time.get_ticks_usec()
	_store_current_presentation()
	_clear_surface_occluder_cache()
	_clear_wall_shadow_overrides()
	for batch in _vector_batches: batch.hide()
	var entry: Dictionary=_presentation_cache_entries[key]
	for field in CACHE_FIELDS: set(field,entry.state.get(field))
	_vector_batches=entry.batches.duplicate()
	_node_batches.clear()
	for batch in _vector_batches:
		batch.clear_dynamic_prepared()
		batch.visibility_layer=visibility_layer
		move_child(batch,get_child_count()-1)
		batch.show();_index_node_batch(batch)
	if entry.has("wall_shadow_batches"):
		_wall_shadow_batches=entry.wall_shadow_batches.duplicate()
	else:
		_index_wall_shadow_batches()
	_presentation_cache_current=key
	_atmosphere_dirty=false;_art_dirty=false;_exploration_fog_dirty=false;_sun_dirty=false
	_update_completed(completed,false)
	_refresh_actor();_dynamic_dirty=false
	_presentation_cache_hits+=1
	_presentation_cache_commit_ms=(Time.get_ticks_usec()-started)/1000.0
	presentation_committed.emit()
	return true


func _art_color(face: Dictionary, point: Vector2, shadowed: bool = false) -> Color:
	return _art_color_at_world(face,point,_face_world_at(face,point),shadowed)

func _art_color_at_world(face: Dictionary, point: Vector2, world: Vector3, shadowed: bool = false) -> Color:
	# Painted art is the albedo. Do not multiply it by whitebox grey again.
	var factor: float = face.get("solar_factor",1.0)
	var lighting := Color.WHITE
	if is_atmosphere_enabled():
		lighting=_atmosphere.tint(Color.WHITE,world,face.normal,str(face.key),factor,_display_sun_config,shadowed)
	else:
		if shadowed: factor=float(_display_sun_config.get("ambient",.3))
		lighting=Color(factor,factor,factor,1)
	# The supplied faces already contain painted directional values. Keep their
	# contrast without applying the full whitebox shadow a second time.
	return Color(.25+.75*lighting.r,.25+.75*lighting.g,.25+.75*lighting.b,_fog_alpha(face,point))*_art.tint(face)


func is_atmosphere_enabled() -> bool:
	return _atmosphere.active()


func get_atmosphere_background() -> Color:
	if is_atmosphere_enabled() and _display_atmosphere_config.preset in ["alchemical_daylight","alchemical_gloom"]: return _atmosphere.background()
	return ExplorationFog.DARK if is_exploration_fog_enabled() else _atmosphere.background()


func _refresh_atmosphere_cache() -> void:
	_display_atmosphere_config = _atmosphere_config.duplicate(true)
	_atmosphere.configure(_display_atmosphere_config,_source_snapshot,_known)
	_atmosphere_dirty = false
	_atmosphere_material_updates += 1


func _face_world_at(face: Dictionary, point: Vector2) -> Vector3:
	return _basis.x*(point.x/PIXELS_PER_WORLD) - _basis.y*(point.y/PIXELS_PER_WORLD) + _basis.z*_depth_at(face.coefficient,point)


func _atmosphere_color(face: Dictionary, point: Vector2, shadowed: bool = false) -> Color:
	if not bool(face.get("known",false)): return _atmosphere.unknown_color(face.color)
	var color: Color = _atmosphere.tint(face.color,_face_world_at(face,point),face.normal,str(face.key),float(face.get("solar_factor",1.0)),_display_sun_config,shadowed)
	color.a *= _fog_alpha(face,point)
	return color


func _atmosphere_markers(face: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for lamp: Dictionary in _atmosphere.markers(face):
		var p: Vector3 = lamp.position
		var center := project_plane(Vector2(p.x,p.z),p.y)
		for band in [0,1,2]:
			var size := [7.0,3.4,1.5][band] as float
			var polygon := PackedVector2Array([center+Vector2(-size,0),center+Vector2(0,-size*.48),center+Vector2(size,0),center+Vector2(0,size*.48)])
			polygon = _intersect_convex(polygon,face.polygon)
			if polygon.size() < 3: continue
			var color := [Color(1,.58,.20,.15),Color(1,.72,.32,.72),Color(1,.91,.69,.98)][band] as Color
			color.a *= float(_display_atmosphere_config.strength)*_fog_alpha(face,center)
			result.append({"polygon":polygon,"color":color})
	return result


func is_sun_enabled() -> bool:
	return bool(_display_sun_config.get("enabled", true))


func advance_actor(displacement: Vector2, delta: float, facing_intent: Vector2 = Vector2(INF, INF)) -> void:
	if _wall_cutaway != null and _wall_cutaway.advance(delta):
		_wall_cutaway.refresh(self)
		if _actor_cutaway_restore != null:
			_wall_cutaway.apply_to(_actor_cutaway_restore.material)
	if actor_animation.advance(displacement, project_plane(displacement), delta, facing_intent):
		# Stationary breathing/blinking changes the silhouette and its sunlight shadow.
		_dynamic_dirty = true
	# Position can change between two sprite frames; publish that movement too.
	flush_dynamic()


func set_layer(snapshot: Dictionary, known: Dictionary, completed: Dictionary, synchronous_binding: bool = false) -> void:
	_actor_shadow_dirty = true
	if not _presentation_cache_plan.is_empty():
		if _cache_config_signature()!=_presentation_cache_signature: _invalidate_presentation_cache()
		var layout_changed := false
		for field in ["map_id","seed","floor_index","cells","height_quantum","outer_radius","scene_envelope"]:
			if _source_snapshot.get(field)!=snapshot.get(field): layout_changed=true;break
		if layout_changed:
			_clear_presentation_cache();_material_face_cache.clear()
		elif _try_cached_presentation(snapshot,known,completed): return
		elif _presentation_cache_warming and _source_snapshot==snapshot and _known==known:
			_update_completed(completed);return
		elif _presentation_cache_warming:
			_presentation_cache_warming=false;_cancel_geometry()
		if not _presentation_cache_plan.is_empty() and (_source_snapshot!=snapshot or _known!=known):
			# A debug/unplanned state must not retire meshes still referenced by
			# an old cache entry. The caller can prepare a new bounded plan later.
			_clear_presentation_cache()
	if synchronous_binding:
		_known=known.duplicate(true);_completed=completed.duplicate(true)
		set_map(snapshot)
		presentation_committed.emit()
		return
	if not _source_snapshot.is_empty() and _source_snapshot.get("cells") == snapshot.get("cells") and _source_snapshot.get("height_quantum") == snapshot.get("height_quantum") and _source_snapshot.get("outer_radius") == snapshot.get("outer_radius") and (_known != known or _source_snapshot != snapshot or is_rebuilding() or _sun_dirty):
		_request_geometry(snapshot,known,completed)
		return
	if _source_snapshot == snapshot and _known == known and not _sun_dirty:
		if _atmosphere_dirty or _art_dirty or _exploration_fog_dirty:
			if _atmosphere_dirty: _refresh_atmosphere_cache()
			if _art_dirty: _refresh_art_cache()
			if _exploration_fog_dirty: _refresh_exploration_fog_cache()
			_refresh_meshes()
			_refresh_actor()
		_update_completed(completed)
		return
	_known = known.duplicate(true)
	_completed = completed.duplicate(true)
	set_map(snapshot)
	presentation_committed.emit()


func _update_completed(completed: Dictionary, refresh_actor: bool = true) -> void:
	if _completed == completed: return
	var changed: Dictionary = {}
	for id in _completed:
		if not completed.has(id): changed[id] = true
	for id in completed:
		if not _completed.has(id): changed[id] = true
	_completed = completed.duplicate(true)
	var batches: Dictionary = {}
	for face in _faces:
		if face.has("node_id") and changed.has(face.node_id):
			_style_node_face(face)
			for batch in _node_batches.get(face.node_id, []): batches[batch] = true
	for batch in batches: batch.build(self, batch.faces)
	_material_update_count += 1
	# Completion changes floor stamps, not terrain/casters/depth clipping.
	if refresh_actor: _refresh_actor()


func set_node_presentations(nodes: Array) -> void:
	# Live event state never changes height geometry or discovery cache identity.
	_node_presentations.clear()
	for node: Dictionary in nodes:
		if node.get("known", false): _node_presentations[node.id] = node
	var dirty: Dictionary = {}
	for face: Dictionary in _faces:
		if not face.get("node_marker", false): continue
		var before: Dictionary = face.get("node_display", {})
		_style_node_face(face)
		if before != face.node_display:
			for batch in _node_batches.get(face.node_id, []): dirty[batch] = true
	for batch in dirty: batch.build(self, batch.faces)
	# A presentation change can add/remove an opaque PNG without moving the
	# actor. Refresh its clipping at the normal dynamic flush, not terrain warmup.
	if not dirty.is_empty(): _dynamic_dirty = true


func _style_node_face(face: Dictionary) -> void:
	if face.get("node_marker", false):
		var node: Dictionary = _node_presentations.get(face.node_id, {"type":face.node_type})
		face.node_display = NodeArt.describe(node)
		face.node_display["gate_closed"] = bool(face.get("node_gate", false)) and not _completed.has(face.node_id)
		return
	var color: Color = face.node_color
	if _completed.has(face.node_id): color = color.lerp(GROUND, .7)
	face.color = GROUND.lerp(color, .66)
	if face.has("label_base"):
		face.label = face.label_base + ("*" if face.node_gate and not _completed.has(face.node_id) else "")


func get_map_bounds() -> Rect2:
	return get_bounds()


func set_map(snapshot: Dictionary) -> void:
	_cancel_geometry()
	_load_map_data(snapshot)
	_rebuild()

func _load_map_data(snapshot: Dictionary) -> void:
	var input_started := Time.get_ticks_usec()
	if not _source_snapshot.is_empty():
		for field in ["map_id","seed","floor_index","cells","height_quantum","outer_radius","scene_envelope"]:
			if _source_snapshot.get(field)!=snapshot.get(field): _material_face_cache={};break
	if _floor_data==null or not _floor_data.matches(snapshot): _floor_data=FloorRenderData.new(snapshot)
	_source_snapshot = _floor_data.snapshot_for(snapshot)
	# CPU catalog selection precedes rock outlines and all material UV packets.
	# Texture allocation remains in VectorBatch's main-thread publish path.
	_art.select_floor(int(_source_snapshot.get("floor_index",1)))
	_solar_snapshot = _source_snapshot
	_cells = _floor_data.cells
	_wall_readability_cache={}
	_duplicate_cells = _floor_data.duplicate_cells
	_quantum = maxf(0.001, float(snapshot.get("height_quantum", 0.20)))
	_radius = maxf(0.01, float(snapshot.get("outer_radius", 1.0)))
	_nodes = _source_snapshot.nodes
	var volumes := SceneVolume.normalize(snapshot, _known)
	_scenery_volumes = volumes.volumes
	if volumes.stats.enabled:
		_scenery_cells = {}
		_scenery_stats = volumes.stats
	else:
		var envelope := SolarLighting.scene_envelope_cells(snapshot, _known)
		_scenery_cells = envelope.cells
		_scenery_stats = envelope.stats
	if not _actor_valid and snapshot.has("spawn"):
		var spawn := _pair(snapshot.spawn)
		_actor_plane = hex_plane(spawn)
		_actor_height = _cell_height(_key(spawn))
		_actor_valid = true
	_input_load_ms = (Time.get_ticks_usec()-input_started)/1000.0


func project_plane(p: Vector2, height: float = 0.0) -> Vector2:
	var world := Vector3(p.x, height, p.y)
	return Vector2(world.dot(_basis.x), -world.dot(_basis.y)) * PIXELS_PER_WORLD


func unproject_plane(screen: Vector2, height: float = 0.0) -> Vector2:
	# Solve the exact two projected plane axes at a caller-selected world height.
	var target := screen / PIXELS_PER_WORLD
	target.y += height * _basis.y.y
	var a := _basis.x.x
	var b := _basis.x.z
	var c := -_basis.y.x
	var d := -_basis.y.z
	var determinant := a * d - b * c
	return Vector2((target.x * d - b * target.y) / determinant, (a * target.y - target.x * c) / determinant)


func hex_plane(coord: Vector2i) -> Vector2:
	return Vector2(1.5 * float(coord.x), sqrt(3.0) * (float(coord.y) + float(coord.x) * 0.5)) * _radius


func pick_cell(local_screen: Vector2) -> String:
	# The frontmost visible face selects its owned support hex. Wall/prop bodies
	# cannot be clicked through to a floor behind them; fog consumes the hit.
	var result := ""
	var front_depth := -INF
	for item: Dictionary in _sorted_faces:
		if Geometry2D.is_point_in_polygon(local_screen, item.polygon):
			var depth := _depth_at(item.coefficient, local_screen)
			if depth > front_depth:
				front_depth = depth
				result = String(item.key) if bool(item.known) and not bool(item.get("scenery", false)) else ""
	return result


func get_bounds() -> Rect2:
	return _exploration_fog.bounds if is_exploration_fog_enabled() else _bounds


func get_report() -> Dictionary:
	if _dynamic_dirty: flush_dynamic()
	var result := _report.duplicate(true)
	result["static_render_backend"] = "vector_mesh"
	result["uses_raster_fallback"] = false
	result["static_mesh_batches"] = _vector_batches.size()
	var node_body_count := 0
	for node: Dictionary in _node_presentations.values():
		if float(node.get("body_radius", 0.0)) > 0.0 or not node.get("body_capsule", {}).is_empty(): node_body_count += 1
	result["node_body_count"] = node_body_count
	result["static_mesh_refresh_count"] = _mesh_refresh_count
	result["static_mesh_refresh_ms"] = _mesh_refresh_usec / 1000.0
	result["material_update_count"] = _material_update_count
	result["order_candidate_pairs"] = _order_candidate_pairs
	result["order_coplanar_skips"] = _order_coplanar_skips
	result["rebuild_timings_ms"] = _rebuild_timings.duplicate()
	result["publish_timings_ms"] = _publish_timings.duplicate()
	result["geometry_job_active"] = is_rebuilding()
	result["async_rebuild_count"] = _async_rebuild_count
	result["async_rebuild_ms"] = _async_elapsed_usec / 1000.0
	result["sunlight"] = _sun_report.duplicate(true)
	result["dynamic_actor_shadow"]=_solar.get_actor_shadow_report()
	result["dynamic_wall_shadow"]=_wall_shadow_stats.duplicate()
	result["art"] = _art.report()
	result["wall_readability"] = _wall_readability_report()
	result.art["material_refresh_ms"] = _mesh_refresh_usec/1000.0
	result.art["pending"] = _art_dirty or (is_rebuilding() and _geometry_builder != null and _geometry_builder._art_enabled != _art_enabled)
	result["atmosphere"] = _atmosphere.report()
	result.atmosphere["material_updates"] = _atmosphere_material_updates
	result.atmosphere["actor_tint"] = _actor_atmosphere_tint.to_html(false)
	result.atmosphere["pending"] = _atmosphere_dirty or (is_rebuilding() and _geometry_builder != null and _geometry_builder._atmosphere_config != _atmosphere_config)
	result["exploration_fog"] = _exploration_fog.report()
	result.exploration_fog["pending"] = _exploration_fog_dirty or (is_rebuilding() and _geometry_builder != null and _geometry_builder._exploration_fog_enabled != _exploration_fog_enabled)
	result["actor_surface_light"] = _surface_light.report()
	result["actor_emission"] = {"strength":_actor_emission_strength,"body_restore":.72*_actor_emission_strength,"body_energy":1.0+.30*_actor_emission_strength,"receiver_radius_world":.68*_radius,"clip_pieces":_actor_emission_batch.piece_count if _actor_emission_batch!=null else 0,"update_count":_actor_emission_batch.update_count if _actor_emission_batch!=null else 0,"build_ms":_actor_emission_batch.build_ms if _actor_emission_batch!=null else 0.0,"method":"original sprite tint restoration plus clipped additive support light"}
	var cache_triangles := 0
	for entry: Dictionary in _presentation_cache_entries.values():
		for batch in entry.batches: cache_triangles+=batch.triangles
	result["presentation_cache"]={"ready":is_presentation_cache_ready(),"preparing":is_presentation_cache_preparing(),"progress":get_presentation_cache_progress(),"entries":_presentation_cache_entries.size(),"plan_states":_presentation_cache_plan.size(),"warming":_presentation_cache_warming,"prepare_ms":_presentation_cache_prepare_ms,"memory_static_delta_bytes":_presentation_cache_memory_delta,"vertex_payload_upper_bytes":cache_triangles*3*52,"hits":_presentation_cache_hits,"misses":_presentation_cache_misses,"last_commit_ms":_presentation_cache_commit_ms,"bounded_states":4,"quality":"complete old geometry/CSG/solar/material; no progressive shadow"}
	result["presentation_reuse"]=_reuse_report.duplicate(true)
	result["floor_storage"]=_floor_data.report() if _floor_data!=null else {}
	result["scene_envelope"] = _scenery_stats.duplicate(true)
	result["scenery_bounds"] = {"x": _scenery_bounds.position.x, "y": _scenery_bounds.position.y, "width": _scenery_bounds.size.x, "height": _scenery_bounds.size.y}
	result["actor_animation"] = actor_animation.report()
	result["actor_occlusion_hint"] = {"enabled": _actor_occlusion_hint_enabled, "hidden_regions": _hidden_actor_regions.size(), "pieces": _actor_occlusion_hint.piece_count if _actor_occlusion_hint != null else 0, "visible": _actor_occlusion_hint.visible if _actor_occlusion_hint != null else false, "build_ms": _actor_occlusion_hint.build_ms if _actor_occlusion_hint != null else 0.0, "method": "current-frame inner contour inside disjoint known foreground masks; opaque wall and actor depth unchanged"}
	result["wall_cutaway"] = _wall_cutaway.report() if _wall_cutaway != null else {"enabled": false, "target_keys": []}
	result.wall_cutaway["restore_regions"] = _wall_restore_regions.size()
	result.wall_cutaway["pipeline_primed"] = _cutaway_warmup_drawn
	return result


func set_wall_cutaway_context(map_id: String, seed: String, floor_index: int, reachable: Dictionary, defer_refresh: bool = false, collision_edges: Dictionary = {}) -> void:
	if _wall_cutaway == null: _wall_cutaway = WallCutaway.new()
	_wall_cutaway.set_context(map_id, seed, floor_index, reachable, collision_edges)
	_dynamic_dirty = true
	if not defer_refresh: flush_dynamic()

func set_wall_cutaway_enabled(value: bool) -> void:
	if _wall_cutaway == null: _wall_cutaway = WallCutaway.new()
	_wall_cutaway.enabled = value
	_refresh_actor()

func is_wall_cutaway_enabled() -> bool:
	return _wall_cutaway != null and _wall_cutaway.enabled

func set_wall_cutaway_opacity(value: float) -> void:
	if not is_finite(value): return
	if _wall_cutaway == null: _wall_cutaway = WallCutaway.new()
	_wall_cutaway.opacity = clampf(value, 0.0, 1.0)
	_refresh_actor()

func _is_cutaway_wall(face: Dictionary) -> bool:
	return bool(face.get("known", false)) and not face.has("node_id") and _cells.has(face.key) and _cells[face.key].terrain == "wall" and str(face.category) in ["wall", "ground", "terrain_side"]

func _refresh_wall_cutaway() -> void:
	if _wall_cutaway == null: return
	_wall_cutaway.refresh(self)
	# Current presentation only. Cached/warming presentations are rebound when published.
	for batch in _vector_batches:
		# Sprite/contact drawing has no terrain CUSTOM0/CUSTOM1 vertex channels.
		# Its tint is already prepared, and it must not inherit wall cutaway.
		if batch.node_marker_only:
			batch.material = null
			continue
		if batch.material != _wall_cutaway.material: batch.material = _wall_cutaway.material

func _refresh_actor_cutaway_restore() -> void:
	if _wall_cutaway == null or _wall_cutaway.target_keys.is_empty() or _wall_restore_regions.is_empty():
		if _actor_cutaway_restore != null: _actor_cutaway_restore.clear()
		return
	if _actor_cutaway_restore == null:
		_actor_cutaway_restore = ActorCutawayRestore.new()
		add_child(_actor_cutaway_restore)
	move_child(_actor_cutaway_restore, get_child_count() - 1)
	_actor_cutaway_restore.rebuild(self, _wall_restore_regions)

func set_actor_occlusion_hint_enabled(enabled: bool) -> void:
	_actor_occlusion_hint_enabled = enabled
	_refresh_actor_occlusion_hint()


func is_actor_occlusion_hint_enabled() -> bool:
	return _actor_occlusion_hint_enabled


func update_actor(plane: Vector2, height: float, defer_refresh: bool = false) -> void:
	if _actor_valid and _actor_plane.is_equal_approx(plane) and is_equal_approx(_actor_height, height):
		return
	if not _actor_valid: _actor_shadow_dirty = true
	_actor_plane = plane
	_actor_height = height
	_actor_valid = true
	_dynamic_dirty = true
	if not defer_refresh: flush_dynamic()


func flush_dynamic() -> void:
	if _dynamic_dirty or _wall_shadow_pending:
		_dynamic_dirty = false
		_refresh_actor()


func set_visibility(known: Dictionary, completed: Dictionary) -> void:
	set_layer(_pending_layer if is_rebuilding() else _source_snapshot,known,completed)


func _rebuild() -> void:
	if is_rebuilding():
		_known = _pending_known.duplicate(true)
		_completed = _pending_completed.duplicate(true)
		_load_map_data(_pending_layer)
	_cancel_geometry()
	_configure_sun()
	_build_geometry()
	_refresh_meshes()
	_refresh_actor()
	_dynamic_dirty = false

func _build_geometry() -> void:
	_clear_surface_occluder_cache()
	var start := Time.get_ticks_usec()
	_static_rebuild_count += 1
	_faces.clear()
	_pick_tops.clear()
	_skipped_nodes.clear()
	var base_height := 0.0
	for key: String in _cells:
		if bool(_known.get(key, false)): base_height = minf(base_height, _cell_height(key))
	base_height -= 0.24
	# New seeded profiles keep the unknown shell below visible support. Its
	# height depends only on KNOWN cells, so negative valleys remain readable
	# without exposing unknown elevations or disabling opaque depth clipping.
	var unknown_height := base_height if _source_snapshot.get("metadata", {}).get("height", {}).get("unknown_shell", "") == "below-known-ground" else 0.0
	for key: String in _cells:
		var cell: Dictionary = _cells[key]
		var center := hex_plane(cell.coord)
		var known := bool(_known.get(key, false))
		# Fog has a neutral flat shell. It never exposes a hidden wall, node or
		# elevation, and is not eligible for cutaway or picking.
		var height := float(cell.level) * _quantum if known else unknown_height
		var footprint := _hex_polygon(center, _radius)
		var tint := GROUND.lerp(Color("d9d7c7"), 0.10 * posmod(int(cell.level), 4)) if known else FOG
		var top := _add_face(footprint, _repeat_height(6, height), tint, "ground" if known else "fog", "cell:" + key, key, known, center, height, true)
		if known:
			_pick_tops.append(top)
			for index in 6:
				var a := footprint[index]
				var b := footprint[(index + 1) % 6]
				var outward := ((a + b) * 0.5 - center).normalized()
				if _planar_depth(outward) <= 0.0:
					continue
				var neighbor := _neighbor(cell.coord, index)
				var neighbor_key := _key(neighbor)
				var bottom := base_height
				if _cells.has(neighbor_key) and bool(_known.get(neighbor_key, false)):
					bottom = _cell_height(neighbor_key)
					if bottom >= height - 0.0001:
						continue
				# Unknown neighbors cannot contribute hidden elevation data.
				var color := tint if is_sun_enabled() else tint.darkened(0.18 if outward.dot(Vector2(_basis.x.x, _basis.x.z)) > 0.0 else 0.29)
				_add_face(PackedVector2Array([a, b, b, a]), PackedFloat32Array([bottom, bottom, height, height]), color, "terrain_side", "cell:" + key, key, true, center, height, false)
			if String(cell.get("terrain", "ground")) == "wall":
				_make_prism(footprint, height, height + maxf(0.1, float(cell.get("wall_height", 1.3))), Color("adb3a4") if is_sun_enabled() else Color("858d80"), Color("6e7a80"), "wall", "wall:" + key, key, center, true)
	for node: Dictionary in _nodes:
		_make_node(node)
	_make_rocks()
	var support_bounds := Rect2()
	var v2: bool = _scenery_stats.get("version", "") == SceneVolume.VERSION
	if v2:
		_calculate_bounds()
		support_bounds = _bounds
	_make_scene_envelope(base_height)
	if v2: _clip_scene_surfaces()
	var geometry_done := Time.get_ticks_usec()
	_solar.set_receiver_cache(_floor_data if _incremental_presentation_enabled else null)
	_sun_report = _solar.bake(_solar_snapshot, _known, _faces, _basis, PIXELS_PER_WORLD)
	var solar_done := Time.get_ticks_usec()
	_order_faces()
	var order_done := Time.get_ticks_usec()
	_index_faces()
	_calculate_bounds()
	if v2: _bounds = support_bounds
	_rebuild_timings = {"geometry":(geometry_done-start)/1000.0,"sun":(solar_done-geometry_done)/1000.0,"order":(order_done-solar_done)/1000.0,"mesh_and_index":(Time.get_ticks_usec()-order_done)/1000.0,"total":(Time.get_ticks_usec()-start)/1000.0}
	_sun_dirty = false
	var cache_started := Time.get_ticks_usec()
	_refresh_atmosphere_cache()
	_rebuild_timings["atmosphere"]=(Time.get_ticks_usec()-cache_started)/1000.0
	cache_started=Time.get_ticks_usec()
	_refresh_art_cache()
	_rebuild_timings["art"]=(Time.get_ticks_usec()-cache_started)/1000.0
	cache_started=Time.get_ticks_usec()
	_refresh_exploration_fog_cache()
	_rebuild_timings["fog"]=(Time.get_ticks_usec()-cache_started)/1000.0
	_rebuild_timings["input_load"]=_input_load_ms


func _wall_readability_report() -> Dictionary:
	if not _wall_readability_cache.is_empty(): return _wall_readability_cache
	var count:=0
	var measured:=0
	var minimum_clearance:=INF
	var maximum_clearance:=-INF
	var conflicts:Array=[]
	var missing_metadata:Array=[]
	var high_mismatches:Array=[]
	for key:String in _cells:
		var cell:Dictionary=_cells[key]
		if not bool(_known.get(key,false)) or str(cell.get("terrain","ground"))!="wall": continue
		count+=1
		var top:float=float(cell.level)*_quantum+maxf(.1,float(cell.get("wall_height",1.3)))
		var actual_high:float=-INF
		for direction:Vector2i in DIRS:
			var neighbor:Dictionary=_cells.get(_key(cell.coord+direction),{})
			if not neighbor.is_empty() and str(neighbor.get("terrain","ground"))=="ground": actual_high=maxf(actual_high,float(neighbor.level)*_quantum)
		if is_finite(actual_high):
			measured+=1
			minimum_clearance=minf(minimum_clearance,top-actual_high)
			maximum_clearance=maxf(maximum_clearance,top-actual_high)
			if cell.has("wall_high_level") and not is_equal_approx(float(cell.wall_high_level)*_quantum,actual_high): high_mismatches.append(key)
		if not cell.has("wall_high_level") or not cell.has("wall_cap"): missing_metadata.append(key)
		var cap:Variant=cell.get("wall_cap")
		if cap!=null and top>float(cap)+.000001: conflicts.append({"cell":key,"top":top,"cap":cap,"excess":top-float(cap)})
	_wall_readability_cache={"known_walls":count,"measured_adjacent_walls":measured,"minimum_clearance":minimum_clearance if measured>0 else null,"maximum_clearance":maximum_clearance if measured>0 else null,"cap_conflicts":conflicts,"profile_metadata_missing":missing_metadata,"adjacent_high_mismatches":high_mismatches,"policy":"highest-adjacent-ground-plus-finite-crown; terrain-and-visibility-solver-unchanged"}
	return _wall_readability_cache


func is_rebuilding() -> bool:
	return not _pending_layer.is_empty() and not _presentation_cache_warming

func _request_geometry(snapshot: Dictionary, known: Dictionary, completed: Dictionary, force: bool = false) -> void:
	if not force and _pending_layer == snapshot and _pending_known == known and _pending_sun_config == _sun_config and _pending_grid == show_grid and _pending_node_regions == show_node_regions:
		_pending_completed = completed.duplicate(true)
		_pending_atmosphere_config = _atmosphere_config.duplicate(true)
		_pending_art_enabled = _art_enabled
		_pending_exploration_fog_enabled = _exploration_fog_enabled
		return
	var next_floor: RefCounted=_floor_data if _floor_data!=null and _floor_data.matches(snapshot) else FloorRenderData.new(snapshot)
	var next_layer: Dictionary=next_floor.snapshot_for(snapshot)
	var next_known := known.duplicate(true)
	var next_completed := completed.duplicate(true)
	var preserve: bool=_presentation_cache_warming and not _warm_lookahead.is_empty() and _warm_lookahead.key==_cache_key(next_layer,next_known) and _warm_lookahead.signature==_cache_config_signature()
	_cancel_geometry(preserve)
	_pending_layer = next_layer
	_pending_floor_data=next_floor
	_pending_known = next_known
	_pending_completed = next_completed
	_pending_sun_config = _sun_config.duplicate(true)
	_pending_atmosphere_config = _atmosphere_config.duplicate(true)
	_pending_art_enabled = _art_enabled
	_pending_exploration_fog_enabled = _exploration_fog_enabled
	_pending_grid = show_grid
	_pending_node_regions = show_node_regions
	_async_start_usec = Time.get_ticks_usec()
	set_process(true)
	if _geometry_thread == null: _start_geometry()

func _cancel_geometry(preserve_warm_lookahead: bool=false) -> void:
	if not preserve_warm_lookahead: _discard_warm_lookahead()
	_geometry_generation += 1
	_pending_floor_data=null
	_pending_layer={};_pending_known={};_pending_completed={};_pending_sun_config={};_pending_atmosphere_config={}
	_retired_batches.append_array(_pending_batches)
	_pending_batches.clear();_pending_arrays.clear();_pending_cursor=0
	# The private CPU job can finish safely; only this revision may publish.
	if _geometry_thread == null:
		if _geometry_builder != null: _geometry_builder.free(); _geometry_builder=null
		set_process(not _retired_warm_jobs.is_empty() or not _warm_lookahead.is_empty() or not _retired_batches.is_empty() or not _presentation_cache_plan.is_empty())

func _start_geometry() -> void:
	if not _warm_lookahead.is_empty():
		var job: Dictionary=_warm_lookahead
		if _presentation_cache_warming and job.key==_presentation_cache_warming_key and job.signature==_cache_config_signature() and job.builder._source_snapshot==_pending_layer and job.builder._known==_pending_known:
			_geometry_builder=job.builder;_geometry_thread=job.thread
			_warm_lookahead={};_job_generation=_geometry_generation;_warm_lookahead_hits+=1
			return
		_discard_warm_lookahead()
	_geometry_builder = get_script().new(false)
	_geometry_builder.show_grid = show_grid
	_geometry_builder.show_node_regions = show_node_regions
	_geometry_builder._known = _pending_known.duplicate(true)
	_geometry_builder._completed = _pending_completed.duplicate(true)
	_geometry_builder._sun_config = _sun_config.duplicate(true)
	_geometry_builder._atmosphere_config = _pending_atmosphere_config.duplicate(true)
	_geometry_builder._art_enabled = _pending_art_enabled
	_geometry_builder._exploration_fog_enabled = _pending_exploration_fog_enabled
	_geometry_builder._configure_sun()
	_geometry_builder._floor_data=_pending_floor_data
	_geometry_builder._load_map_data(_pending_layer)
	_geometry_builder._exploration_fog_visual_mode=_exploration_fog_visual_mode
	_geometry_builder._display_exploration_fog_visual_mode=_exploration_fog_visual_mode
	_geometry_builder._material_face_cache={}
	_job_generation = _geometry_generation
	_geometry_thread = Thread.new()
	var status := _geometry_thread.start(_geometry_builder._prepare_geometry_arrays, Thread.PRIORITY_LOW if _presentation_cache_warming else Thread.PRIORITY_NORMAL)
	if status != OK:
		_geometry_thread = null
		_pending_arrays = _geometry_builder._prepare_geometry_arrays()
		push_warning("Terrain worker unavailable; prepared on main thread")

func _prepare_geometry_arrays() -> Array:
	# Called on a private off-tree builder. No textures, meshes, scene-tree or
	# RenderingServer operations; each job owns all mutable arrays and solar data.
	var worker_started := Time.get_ticks_usec()
	_build_geometry()
	var started := Time.get_ticks_usec()
	var arrays := _prepare_material_arrays()
	_rebuild_timings["materials"]=(Time.get_ticks_usec()-started)/1000.0
	_rebuild_timings["worker_total"]=(Time.get_ticks_usec()-worker_started)/1000.0
	return arrays

func _material_face_key(face: Dictionary) -> Array:
	var lamps: Array = []
	if is_atmosphere_enabled():
		for index: int in _atmosphere._cell_lamps.get(face.key,[]):
			var lamp: Dictionary = _atmosphere.lamps[index]
			lamps.append([lamp.position,lamp.cells.get(face.key),lamp.node_id,lamp.key])
	var fog_domain: Array = []
	if is_exploration_fog_enabled():
		if face.get("scene_role","")=="site":
			fog_domain=[_fog_surface_regions(face,face.polygon)]
			if _display_exploration_fog_visual_mode=="legacy_vertex": fog_domain.append(_known)
		elif _display_exploration_fog_visual_mode=="legacy_vertex" and not face.get("scenery",false):
			var coord := _plane_coord(face.support)
			fog_domain.append(_known.get(_key(coord),false))
			for direction: Vector2i in DIRS:
				fog_domain.append(_known.get(_key(coord+direction),false))
				for second: Vector2i in DIRS: fog_domain.append(_known.get(_key(coord+direction+second),false))
	if _material_context_id==0:
		_material_context_id=_floor_data.material_context_id(["surface-point-light-v1",show_grid,_display_sun_config,_display_art_enabled,_art.cache_identity(),_art._address,_display_atmosphere_config,_atmosphere._anchor,_display_exploration_fog_enabled,_display_exploration_fog_visual_mode])
	return [_material_context_id,_is_cutaway_wall(face),face.polygon,face.coefficient,face.normal,face.color,face.category,face.id,face.key,face.known,face.get("solar_factor",1.0),face.get("solar_shadows",[]),face.get("label"),face.get("label_point"),face.get("node_id"),face.top,face.get("draw_edges",true),_art._blocked.has(face.key),lamps,fog_domain,face.get("rock",{})]


func _group_material_faces() -> Array:
	var groups: Array=[]
	var group: Array=[]
	var owner: String=""
	for face: Dictionary in _sorted_faces:
		var next_owner: String=str(face.get("node_id",""))
		if not group.is_empty() and (next_owner!=owner or group.size()>=VECTOR_BATCH_FACES):
			groups.append(group);group=[]
		owner=next_owner;group.append(face)
	if not group.is_empty():groups.append(group)
	return groups

func _prepare_material_arrays() -> Array:
	_material_context_id=0
	var arrays: Array=[]
	_prepared_face_groups=_group_material_faces()
	for group: Array in _prepared_face_groups: arrays.append(VectorBatch.prepare(self,group))
	return arrays

func _process(_delta: float) -> void:
	_drain_retired_warm_jobs()
	if not _presentation_cache_plan.is_empty() and not _presentation_cache_dirty and _cache_config_signature()!=_presentation_cache_signature: _invalidate_presentation_cache()
	if _geometry_thread==null and _geometry_builder==null and not _presentation_cache_plan.is_empty() and not is_presentation_cache_ready(): _warm_next_presentation()
	for i in mini(3, _retired_batches.size()):
		var retired = _retired_batches.pop_back()
		retired.queue_free()
	if _geometry_thread != null:
		if _geometry_thread.is_alive(): return
		var arrays: Array = _geometry_thread.wait_to_finish()
		_geometry_thread = null
		if _job_generation != _geometry_generation or _pending_layer.is_empty():
			_geometry_builder.free();_geometry_builder=null
			if is_rebuilding(): _start_geometry()
			else: set_process(not _retired_warm_jobs.is_empty() or not _warm_lookahead.is_empty() or not _retired_batches.is_empty() or _presentation_cache_dirty or not _presentation_cache_plan.is_empty())
			return
		_pending_arrays = arrays
	if _geometry_builder == null or _pending_arrays.is_empty():
		if _geometry_thread == null and _retired_batches.is_empty(): set_process(not _retired_warm_jobs.is_empty() or not _warm_lookahead.is_empty() or _presentation_cache_dirty or not _presentation_cache_plan.is_empty())
		return
	if _geometry_builder._atmosphere_config != _atmosphere_config or _geometry_builder._art_enabled != _art_enabled or _geometry_builder._exploration_fog_enabled != _exploration_fog_enabled or _geometry_builder._exploration_fog_visual_mode != _exploration_fog_visual_mode:
		# A T toggle during a private geometry job changes material revision only.
		# Never mutate the worker while its thread is alive or publish old colors.
		_retired_batches.append_array(_pending_batches)
		_pending_batches=[];_pending_cursor=0
		_geometry_builder._atmosphere_config = _atmosphere_config.duplicate(true)
		_geometry_builder._refresh_atmosphere_cache()
		_geometry_builder._art_enabled=_art_enabled
		_geometry_builder._refresh_art_cache()
		_geometry_builder._exploration_fog_enabled=_exploration_fog_enabled
		_geometry_builder._refresh_exploration_fog_cache()
		_geometry_builder._exploration_fog_visual_mode=_exploration_fog_visual_mode
		_geometry_builder._display_exploration_fog_visual_mode=_exploration_fog_visual_mode
		_pending_arrays = _geometry_builder._prepare_material_arrays()
		_pending_atmosphere_config = _atmosphere_config.duplicate(true)
	var start := Time.get_ticks_usec()
	var upload_budget := 2000 if _presentation_cache_warming else 6000
	while _pending_cursor < _pending_arrays.size() and Time.get_ticks_usec()-start < upload_budget:
		var batch = VectorBatch.new()
		batch.show_behind_parent = true
		batch.visibility_layer = 0
		add_child(batch)
		batch.apply_prepared(_geometry_builder._prepared_face_groups[_pending_cursor],_pending_arrays[_pending_cursor],_geometry_builder._art.atlas_path)
		# Mesh + retained wall packets now own their data; release upload scratch.
		_pending_arrays[_pending_cursor]=[]
		_pending_batches.append(batch);_pending_cursor+=1
	if _pending_cursor == _pending_arrays.size(): _publish_geometry()

func _publish_geometry() -> void:
	if _presentation_cache_warming:
		_publish_warm_presentation();return
	_clear_surface_occluder_cache()
	var clock := Time.get_ticks_usec()
	_publish_timings = {}
	var builder = _geometry_builder
	_clear_wall_shadow_overrides()
	for batch in _vector_batches: batch.hide()
	_retired_batches.append_array(_vector_batches)
	_vector_batches = _pending_batches
	_pending_batches = []
	_publish_timings["retire_gpu"] = (Time.get_ticks_usec()-clock)/1000.0;clock=Time.get_ticks_usec()
	_material_face_cache=builder._material_face_cache
	_material_context_id=builder._material_context_id
	_reuse_report=builder._reuse_report
	_display_exploration_fog_visual_mode=builder._display_exploration_fog_visual_mode
	_cells=builder._cells;_nodes=builder._nodes
	_source_snapshot=builder._source_snapshot;_solar_snapshot=builder._solar_snapshot
	_floor_data=builder._floor_data
	_scenery_cells=builder._scenery_cells;_scenery_volumes=builder._scenery_volumes;_scenery_stats=builder._scenery_stats;_scenery_bounds=builder._scenery_bounds
	_known=builder._known;_completed=builder._completed
	_publish_timings["cells"] = (Time.get_ticks_usec()-clock)/1000.0;clock=Time.get_ticks_usec()
	_faces=builder._faces;_sorted_faces=builder._sorted_faces;_pick_tops=builder._pick_tops
	_bounds=builder._bounds;_face_bins=builder._face_bins
	_publish_timings["faces"] = (Time.get_ticks_usec()-clock)/1000.0;clock=Time.get_ticks_usec()
	_solar=builder._solar;_sun_report=builder._sun_report
	_display_sun_config = builder._display_sun_config
	_rock_layout=builder._rock_layout
	_art=builder._art
	_display_art_enabled=builder._display_art_enabled
	_art_dirty=_display_art_enabled != _art_enabled
	_exploration_fog=builder._exploration_fog
	_display_exploration_fog_enabled=builder._display_exploration_fog_enabled
	_exploration_fog_dirty=_display_exploration_fog_enabled != _exploration_fog_enabled
	_atmosphere = builder._atmosphere
	_display_atmosphere_config = builder._display_atmosphere_config
	_atmosphere_dirty = _display_atmosphere_config != _atmosphere_config
	_atmosphere_material_updates += 1
	_publish_timings["solar"] = (Time.get_ticks_usec()-clock)/1000.0;clock=Time.get_ticks_usec()
	_skipped_nodes=builder._skipped_nodes;_duplicate_cells=builder._duplicate_cells
	_ordering_cycles=builder._ordering_cycles;_static_overlap_pairs=builder._static_overlap_pairs
	_ambiguous_overlap_pairs=builder._ambiguous_overlap_pairs;_order_candidate_pairs=builder._order_candidate_pairs;_order_coplanar_skips=builder._order_coplanar_skips
	_rebuild_timings=builder._rebuild_timings;_static_rebuild_count+=1
	_node_batches.clear()
	for batch in _vector_batches:
		batch.visibility_layer = visibility_layer
		batch.show()
		_index_node_batch(batch)
	_index_wall_shadow_batches()
	_publish_timings["node_index"] = (Time.get_ticks_usec()-clock)/1000.0;clock=Time.get_ticks_usec()
	var completed := _pending_completed.duplicate(true)
	_pending_floor_data=null
	_pending_layer={};_pending_known={};_pending_completed={};_pending_atmosphere_config={};_pending_arrays=[];_pending_cursor=0
	builder.free();_geometry_builder=null
	_publish_timings["builder_free"] = (Time.get_ticks_usec()-clock)/1000.0;clock=Time.get_ticks_usec()
	_sun_dirty=false;_async_rebuild_count+=1
	_async_elapsed_usec=Time.get_ticks_usec()-_async_start_usec
	set_process(not _retired_warm_jobs.is_empty() or not _warm_lookahead.is_empty() or not _retired_batches.is_empty() or not _presentation_cache_plan.is_empty())
	_update_completed(completed,false)
	_refresh_actor()
	presentation_committed.emit()
	_publish_timings["actor_and_commit"] = (Time.get_ticks_usec()-clock)/1000.0

func _index_node_batch(batch) -> void:
	for face in batch.faces:
		if face.has("node_id"):
			if not _node_batches.has(face.node_id): _node_batches[face.node_id]=[]
			if batch not in _node_batches[face.node_id]: _node_batches[face.node_id].append(batch)

func _exit_tree() -> void:
	_discard_warm_lookahead()
	_drain_retired_warm_jobs(true)
	_clear_surface_occluder_cache()
	_clear_wall_shadow_overrides()
	_wall_shadow_batches.clear()
	_clear_presentation_cache()
	_cancel_geometry()
	if _geometry_thread != null:
		_geometry_thread.wait_to_finish();_geometry_thread=null
	if _geometry_builder != null:
		_geometry_builder.free();_geometry_builder=null


func _refresh_meshes() -> void:
	_material_context_id=0
	_clear_surface_occluder_cache()
	var start := Time.get_ticks_usec()
	_clear_wall_shadow_overrides()
	_node_batches.clear()
	var groups:=_group_material_faces()
	var count:=groups.size()
	while _vector_batches.size() < count:
		var batch = VectorBatch.new()
		batch.show_behind_parent = true
		add_child(batch)
		_vector_batches.append(batch)
	for index in _vector_batches.size():
		var batch = _vector_batches[index]
		if index >= count:
			batch.hide()
			batch.clear()
			continue
		batch.show()
		batch.faces = groups[index]
		batch.build(self, batch.faces)
		_index_node_batch(batch)
	_index_wall_shadow_batches()
	# apply_prepared resets each material, including while the actor is idle.
	_refresh_wall_cutaway()
	_mesh_refresh_count += 1
	_mesh_refresh_usec = Time.get_ticks_usec()-start


func set_cache_view(rectangle: Rect2, display_scale: float) -> void:
	# Adapter compatibility: used for diagnostics, never changes retained meshes.
	if not is_finite(display_scale) or display_scale <= 0 or not rectangle.has_area(): return
	_cache_view = rectangle
	_cache_display_scale = display_scale


func _build_face_bins(faces: Array) -> Dictionary:
	var bins: Dictionary = {}
	for index in faces.size():
		var rect: Rect2 = faces[index].bounds
		for x in range(floori(rect.position.x / FACE_BIN_SIZE), floori(rect.end.x / FACE_BIN_SIZE) + 1):
			for y in range(floori(rect.position.y / FACE_BIN_SIZE), floori(rect.end.y / FACE_BIN_SIZE) + 1):
				var bin := Vector2i(x,y)
				if not bins.has(bin): bins[bin] = []
				bins[bin].append(index)
	return bins


func _index_faces() -> void:
	_face_bins = _build_face_bins(_sorted_faces)


func _indices_in_bins(rect: Rect2, bins: Dictionary) -> Array:
	var found: Dictionary = {}
	for x in range(floori(rect.position.x / FACE_BIN_SIZE), floori(rect.end.x / FACE_BIN_SIZE) + 1):
		for y in range(floori(rect.position.y / FACE_BIN_SIZE), floori(rect.end.y / FACE_BIN_SIZE) + 1):
			for index in bins.get(Vector2i(x,y), []): found[index] = true
	var indices := found.keys()
	indices.sort()
	return indices


func _face_indices(rect: Rect2) -> Array:
	return _indices_in_bins(rect, _face_bins)


func _make_node(node: Dictionary) -> void:
	# 第四层复用已交付的 Boss/商店节点立绘及其透明、落地和遮挡处理。
	if int(_source_snapshot.get("floor_index", 0)) in [1, 4]:
		_make_node_marker(node)
		return
	# These are traversable node floor stamps, not physical props. A future art
	# adapter must declare physical footprints in the shared planar model.
	var id := str(node.id)
	# Logical ownership is unchanged. Only the declared visual foundation must
	# be flat; released event cells carry stamps at their own ground height.
	var protected: Array = node.get("height_flat_footprint", node.footprint)
	var base := INF
	for point in protected:
		var key := _key(_pair(point))
		if not _cells.has(key) or not bool(_known.get(key, false)):
			continue
		var height := _cell_height(key)
		if is_inf(base): base = height
		elif not is_equal_approx(height, base):
			_skipped_nodes.append(id)
			return
	var supports: Array = []
	for point in (node.footprint if show_node_regions else protected):
		var key := _key(_pair(point))
		if _cells.has(key) and bool(_known.get(key, false)):
			supports.append({"plane": hex_plane(_pair(point)), "height": _cell_height(key), "key": key})
	if supports.is_empty(): return
	var label_support := hex_plane(_pair(node.coord))
	if not supports.any(func(value): return value.plane == label_support): label_support = supports[0].plane
	var kind := str(node.type)
	var color: Color = {"battle": Color("cba275"), "elite": Color("af8bbb"), "shop": Color("79bfae"), "boss": Color("b96f6f"), "event": Color("8daec0")}.get(kind, OCHRE)
	for support in supports:
		var plane: Vector2 = support.plane
		var height: float = support.height
		var face := _add_face(_hex_polygon(plane, _radius * 0.74), _repeat_height(6, height + 0.006), GROUND.lerp(color, 0.66), "ground", "node:" + id, support.key, true, plane, height, true)
		face["node_id"] = id
		face["node_color"] = color
		face["node_gate"] = bool(node.get("is_route_gate", false))
		if plane.is_equal_approx(label_support):
			face.label_base = {"shop": "$", "event": "?", "battle": "B", "elite": "E", "boss": "BOSS"}.get(kind, "?")
			face.label_point = project_plane(plane, height + 0.006)
		_style_node_face(face)


func _make_node_marker(node: Dictionary) -> void:
	var anchor := _pair(node.coord)
	var key := _key(anchor)
	# A closed gate can be discovered at its entrance before its center.
	# Match Session._node_visible without revealing the remaining footprint.
	if not bool(_known.get(key, false)) and bool(node.get("is_route_gate", false)):
		var nearest := INF
		for point in node.footprint:
			var candidate := _pair(point)
			var candidate_key := _key(candidate)
			if not _cells.has(candidate_key) or not bool(_known.get(candidate_key, false)): continue
			var distance := hex_plane(candidate).distance_squared_to(hex_plane(_pair(node.coord)))
			if distance < nearest:
				nearest = distance
				anchor = candidate
				key = candidate_key
	if not _cells.has(key) or not bool(_known.get(key, false)): return
	var plane := hex_plane(anchor)
	var height := _cell_height(key) + 0.006
	var width := _radius * (1.85 if node.type == "boss" else 1.45)
	var capsule: Dictionary = node.get("body_capsule", {})
	var body_radius := float(node.get("body_radius", 0.0))
	if not capsule.is_empty():
		width = 2.0 * (float(capsule.half_length) + float(capsule.radius))
	# A sprite's lowest painted pixel represents its front ground contact,
	# not the centre of its footprint. Keep physics at the declared centre.
	var front := Vector2(_basis.z.x, _basis.z.z).normalized()
	var front_extent := float(capsule.get("radius", body_radius))
	var art_plane := plane + front * front_extent
	var rise := (maxf(width, 1.20) if node.type == "event" else width) / _basis.y.y
	# Upright pre-painted sprite: retain the authored perspective. This quad
	# participates in terrain painter order, but adds no collision or FOV area.
	var right := Vector2(_basis.x.x, _basis.x.z).normalized() * width * .5
	var face := _add_face(PackedVector2Array([art_plane-right,art_plane+right,art_plane+right,art_plane-right]), PackedFloat32Array([height,height,height+rise,height+rise]), Color.WHITE, "node_marker", "node:"+str(node.id), key, true, art_plane, height, false)
	face.node_id = str(node.id)
	face.node_type = str(node.type)
	face.node_gate = bool(node.get("is_route_gate", false))
	face.node_marker = true
	face.node_base = project_plane(art_plane, height)
	var contact := PackedVector2Array()
	if node.type != "event":
		for i in 24:
			contact.append(project_plane(plane + Vector2.from_angle(TAU * i / 24.0) * body_radius, height))
	face.node_contact = contact
	face.draw_edges = false
	_style_node_face(face)


func _make_scene_envelope(base_height: float) -> void:
	if _scenery_stats.get("version", "") == SceneVolume.VERSION:
		_make_scene_volumes()
		return
	var first := _faces.size()
	var removed := 0
	var sides := 0
	var roofs := 0
	for coordinate: String in _scenery_cells:
		var cell: Dictionary = _scenery_cells[coordinate]
		var center := hex_plane(cell.coord)
		var hull := _hex_polygon(center, _radius)
		var tint: Color = {"foundation": Color("9faaa0"), "core": Color("aeb3a1"), "basin": Color("899b91")}[cell.role]
		var roof := _add_face(hull, _repeat_height(6, cell.top), tint, "scenery", cell.key, cell.key, true, center, cell.bottom, true)
		_mark_scenery_face(roof, cell)
		roofs += 1
		for edge in 6:
			var a := hull[edge]
			var b := hull[(edge + 1) % 6]
			var outward := ((a + b) * 0.5 - center).normalized()
			if _planar_depth(outward) <= 0.0001: continue
			var neighbor := _key(_neighbor(cell.coord, edge))
			var exposed: Array[Vector2] = [Vector2(cell.bottom, cell.top)]
			if _scenery_cells.has(neighbor):
				var other: Dictionary = _scenery_cells[neighbor]
				exposed = _uncovered_height(cell.bottom, cell.top, other.bottom, other.top)
			elif _cells.has(neighbor) and bool(_known.get(neighbor, false)):
				var other: Dictionary = _cells[neighbor]
				var high := _cell_height(neighbor)
				if String(other.get("terrain", "ground")) == "wall": high += maxf(0.1, float(other.get("wall_height", 1.3)))
				exposed = _uncovered_height(cell.bottom, cell.top, base_height, high)
			if exposed.is_empty(): removed += 1
			for span in exposed:
				var color := tint if is_sun_enabled() else tint.darkened(0.12 if outward.dot(Vector2(_basis.x.x, _basis.x.z)) > 0.0 else 0.24)
				# One true coplanar quad per exposed interval; no height bands and
				# no internal equal-height faces. Affine depth remains exact.
				var face := _add_face(PackedVector2Array([a,b,b,a]), PackedFloat32Array([span.x,span.x,span.y,span.y]), color, "scenery", cell.key, cell.key, true, center, cell.bottom, false)
				_mark_scenery_face(face, cell)
				sides += 1
	var skirt_count := 0
	for skirt: Dictionary in SolarLighting.scene_support_skirts(_source_snapshot, _known, _scenery_cells):
		var a: Vector2 = skirt.a
		var b: Vector2 = skirt.b
		var center: Vector2 = skirt.center
		var outward := ((a+b)*0.5-center).normalized()
		if _planar_depth(outward) <= 0.0001: continue
		var tint := GROUND.lerp(Color("d9d7c7"), 0.10 * posmod(int(skirt.level), 4))
		var color := tint if is_sun_enabled() else tint.darkened(0.18 if outward.dot(Vector2(_basis.x.x, _basis.x.z)) > 0.0 else 0.29)
		var face := _add_face(PackedVector2Array([a,b,b,a]), PackedFloat32Array([skirt.bottom,skirt.bottom,skirt.top,skirt.top]), color, "scenery", skirt.key, skirt.key, true, center, skirt.bottom, false)
		_mark_scenery_face(face, skirt)
		skirt_count += 1
	_scenery_stats["support_skirt_faces"] = skirt_count
	_scenery_stats["rendered_faces"] = _faces.size() - first
	_scenery_stats["roof_faces"] = roofs
	_scenery_stats["side_faces"] = sides
	_scenery_stats["culled_camera_facing_internal_sides"] = removed
	_scenery_stats["full_hex_radius"] = _radius
	_scenery_stats["opaque"] = true
	_scenery_stats["changes_support_cells"] = false


func _make_scene_volumes() -> void:
	var first := _faces.size()
	var roofs := 0
	var sides := 0
	var back_roofs := 0
	var colors := {"site":Color("7a8581"),"foundation":Color("9ea394"),"core":Color("aea391"),"basin":Color("a3a18f"),"buttress":Color("939b8e")}
	for volume: Dictionary in _scenery_volumes:
		var hull: PackedVector2Array = volume.footprint
		var heights: PackedFloat32Array = volume.top_heights
		var center: Vector2 = volume.center
		var color: Color = colors[volume.role]
		# A sloped roof is one real world plane, including its normal. Back
		# faces are culled geometrically, never made transparent or reordered.
		if (volume.top_normal as Vector3).dot(_basis.z) > 0.0001:
			var before := _faces.size()
			var roof := _add_face(hull,heights,color,"scenery",volume.key,volume.key,true,center,volume.bottom,true)
			roof.normal = volume.top_normal
			_mark_scenery_face(roof,volume)
			roofs += _faces.size()-before
		else: back_roofs += 1
		for edge in hull.size():
			var normal := SceneVolume.edge_normal(hull,edge)
			if normal.dot(_basis.z) <= 0.0001: continue
			var next := (edge+1)%hull.size()
			var tint := color if is_sun_enabled() else color.darkened(0.12 if normal.dot(_basis.x)>0 else 0.24)
			var before := _faces.size()
			var face := _add_face(PackedVector2Array([hull[edge],hull[next],hull[next],hull[edge]]),PackedFloat32Array([volume.bottom,volume.bottom,heights[next],heights[edge]]),tint,"scenery",volume.key,volume.key,true,center,volume.bottom,false)
			face.normal = normal
			face["scene_edge"] = edge
			_mark_scenery_face(face,volume)
			sides += _faces.size()-before
	_scenery_stats["rendered_faces"] = _faces.size()-first
	_scenery_stats["roof_faces"] = roofs
	_scenery_stats["side_faces"] = sides
	_scenery_stats["back_roofs_culled"] = back_roofs
	_scenery_stats["support_skirt_faces"] = 0
	_scenery_stats["opaque"] = true
	_scenery_stats["changes_support_cells"] = false


func _clip_scene_surfaces() -> void:
	var started := Time.get_ticks_usec()
	var solids := SceneVolume.original_solids(_source_snapshot,_known)
	for volume in _scenery_volumes:
		var solid := SceneVolume.solid(volume);solid["scenery"]=true;solids.append(solid)
	var clipper := SurfaceClipper.new()
	clipper.prepare(solids,_scenery_volumes)
	var exposed: Array[Dictionary] = []
	var roofs := 0
	var sides := 0
	for source in _faces:
		for world: PackedVector3Array in clipper.clip(source):
			var polygon := PackedVector2Array()
			var depths := PackedFloat32Array()
			var mean := 0.0
			for point in world:
				polygon.append(Vector2(point.dot(_basis.x),-point.dot(_basis.y))*PIXELS_PER_WORLD)
				var depth := point.dot(_basis.z);depths.append(depth);mean+=depth
			if polygon.size()<3 or absf(_signed_area(polygon))<=.05:continue
			var face := source.duplicate(false)
			face.world=world;face.polygon=polygon;face.depths=depths
			face.coefficient=_plane_depth_coefficient(source.normal,source.world[0])
			face.mean_depth=mean/world.size();face.bounds=_polygon_bounds(polygon)
			exposed.append(face)
			if bool(face.get("scenery",false)):
				if face.top:roofs+=1
				else:sides+=1
	_faces=exposed
	_scenery_stats["raw_rendered_faces"]=_scenery_stats.get("rendered_faces",0)
	_scenery_stats["rendered_faces"]=roofs+sides
	_scenery_stats["roof_faces"]=roofs;_scenery_stats["side_faces"]=sides
	_scenery_stats["surface_clipping"]=clipper.stats.duplicate(true)
	_scenery_stats["surface_clipping"]["elapsed_ms"]=(Time.get_ticks_usec()-started)/1000.0


func _plane_depth_coefficient(normal: Vector3, point: Vector3) -> Vector3:
	# Clipped polygons may begin with almost-collinear intersection points.
	# Solve the original world plane directly instead of fitting those points.
	var denominator := normal.dot(_basis.z)
	return Vector3(-normal.dot(_basis.x)/(PIXELS_PER_WORLD*denominator),normal.dot(_basis.y)/(PIXELS_PER_WORLD*denominator),normal.dot(point)/denominator)


func _mark_scenery_face(face: Dictionary, cell: Dictionary) -> void:
	face["scenery"] = true
	face["scene_role"] = cell.role
	face["scene_group"] = cell.group_id
	face["draw_edges"] = false


func _uncovered_height(bottom: float, top: float, covered_bottom: float, covered_top: float) -> Array[Vector2]:
	var spans: Array[Vector2] = []
	if covered_top <= bottom + 0.0001 or covered_bottom >= top - 0.0001:
		spans.append(Vector2(bottom, top))
		return spans
	if covered_bottom > bottom + 0.0001: spans.append(Vector2(bottom, minf(top, covered_bottom)))
	if covered_top < top - 0.0001: spans.append(Vector2(maxf(bottom, covered_top), top))
	return spans


func _make_prism(hull: PackedVector2Array, bottom: float, top: float, side: Color, roof: Color, category: String, id: String, key: String, center: Vector2, known: bool, draw_top: bool = true) -> void:
	if draw_top:
		_add_face(hull, _repeat_height(hull.size(), top), roof, category, id, key, known, center, bottom, true)
	for i in hull.size():
		var a := hull[i]
		var b := hull[(i + 1) % hull.size()]
		var outward := ((a + b) * 0.5 - center).normalized()
		if _planar_depth(outward) <= 0.0001:
			continue
		var shade := side if is_sun_enabled() else side.darkened(0.07 if outward.dot(Vector2(_basis.x.x, _basis.x.z)) > 0.0 else 0.20)
		# Horizontal wall bands are real 2D faces with their own affine depth.
		# Subdivision does not move the support origin when height changes.
		var band_count := maxi(1, ceili((top - bottom) / 0.55))
		for band in band_count:
			var lo := lerpf(bottom, top, float(band) / band_count)
			var hi := lerpf(bottom, top, float(band + 1) / band_count)
			var color := shade if is_sun_enabled() else shade.lightened(0.012 * float(band % 2))
			_add_face(PackedVector2Array([a, b, b, a]), PackedFloat32Array([lo, lo, hi, hi]), color, category, id, key, known, center, bottom, false)


func _add_face(planar: PackedVector2Array, heights: PackedFloat32Array, color: Color, category: String, id: String, key: String, known: bool, support: Vector2, support_height: float, top: bool) -> Dictionary:
	var polygon := PackedVector2Array()
	var world := PackedVector3Array()
	var depths := PackedFloat32Array()
	var average_depth := 0.0
	for i in planar.size():
		world.append(Vector3(planar[i].x, heights[i], planar[i].y))
		polygon.append(project_plane(planar[i], heights[i]))
		var depth := _world_depth(planar[i], heights[i])
		depths.append(depth)
		average_depth += depth
	var coefficient := _depth_coefficient(polygon, depths)
	var normal := Vector3.UP
	if not top and world.size() >= 3:
		normal = (world[1] - world[0]).cross(world[2] - world[0]).normalized()
		var outward := Vector3((planar[0].x + planar[1].x) * 0.5 - support.x, 0.0, (planar[0].y + planar[1].y) * 0.5 - support.y)
		if normal.dot(outward) < 0: normal = -normal
	var item := {"polygon": polygon, "world": world, "normal": normal, "coefficient": coefficient, "depths": depths, "color": color, "category": category, "id": id, "key": key, "known": known, "support": support, "support_height": support_height, "support_y": project_plane(support).y, "top": top, "mean_depth": average_depth / maxf(1.0, float(planar.size())), "bounds": _polygon_bounds(polygon)}
	if polygon.size() >= 3 and absf(_signed_area(polygon)) > 0.05:
		_faces.append(item)
	return item


func _order_faces() -> void:
	# Overlap constraints, not a single object-center depth, determine static
	# painter order. For disjoint nonintersecting convex columns, a projected
	# overlap has one consistent front surface. Mixed/cyclic cases are reported.
	var outgoing: Array[Array] = []
	var indegree: Array[int] = []
	for _i in _faces.size():
		outgoing.append([])
		indegree.append(0)
	_static_overlap_pairs = 0
	_ambiguous_overlap_pairs = 0
	var bins := _build_face_bins(_faces)
	_order_candidate_pairs = 0
	_order_coplanar_skips = 0
	for a_index in _faces.size():
		var a: Dictionary = _faces[a_index]
		for b_index: int in _indices_in_bins(a.bounds, bins):
			if b_index <= a_index: continue
			_order_candidate_pairs += 1
			var b: Dictionary = _faces[b_index]
			if not a.bounds.intersects(b.bounds):
				continue
			# Identical depth equations subtract to zero at every sample. Such
			# faces add no ordering edge or ambiguity, whatever their overlap.
			# Exact equality only: near-coplanar faces still take the full path.
			if a.coefficient == b.coefficient:
				_order_coplanar_skips += 1
				continue
			var overlaps := Geometry2D.intersect_polygons(a.polygon, b.polygon)
			if overlaps.is_empty():
				continue
			var minimum := INF
			var maximum := -INF
			var area := 0.0
			for overlap: PackedVector2Array in overlaps:
				area += absf(_signed_area(overlap))
				for sample in overlap:
					var difference := _depth_at(a.coefficient, sample) - _depth_at(b.coefficient, sample)
					minimum = minf(minimum, difference)
					maximum = maxf(maximum, difference)
			if area < 0.12:
				continue
			var behind := -1
			var ahead := -1
			if maximum < DEPTH_EPSILON and minimum < -DEPTH_EPSILON:
				behind = a_index
				ahead = b_index
			elif minimum > -DEPTH_EPSILON and maximum > DEPTH_EPSILON:
				behind = b_index
				ahead = a_index
			if behind >= 0:
				outgoing[behind].append(ahead)
				indegree[ahead] += 1
				_static_overlap_pairs += 1
			elif minimum < -DEPTH_EPSILON and maximum > DEPTH_EPSILON:
				_ambiguous_overlap_pairs += 1
	var remaining: Dictionary = {}
	var ready: Array[int] = []
	var fallback: Array[int] = []
	for i in _faces.size():
		remaining[i] = true
		_heap_push(fallback, i)
		if indegree[i] == 0: _heap_push(ready, i)
	_sorted_faces.clear()
	_ordering_cycles = 0
	while not remaining.is_empty():
		var candidate := -1
		while not ready.is_empty() and candidate < 0:
			var i := _heap_pop(ready)
			if remaining.has(i): candidate = i
		if candidate < 0:
			_ordering_cycles += 1
			while candidate < 0:
				var i := _heap_pop(fallback)
				if remaining.has(i): candidate = i
		remaining.erase(candidate)
		_sorted_faces.append(_faces[candidate])
		for next in outgoing[candidate]:
			indegree[next] -= 1
			if indegree[next] == 0 and remaining.has(next): _heap_push(ready, next)


func _heap_less(a: int, b: int) -> bool:
	var x := float(_faces[a].mean_depth)
	var y := float(_faces[b].mean_depth)
	return a < b if x == y else x < y


func _heap_push(heap: Array[int], value: int) -> void:
	heap.append(value)
	var i := heap.size()-1
	while i > 0:
		var parent := (i-1)/2
		if not _heap_less(heap[i],heap[parent]): break
		var swap := heap[parent]; heap[parent] = heap[i]; heap[i] = swap
		i = parent


func _heap_pop(heap: Array[int]) -> int:
	var result := heap[0]
	var tail: int = heap.pop_back()
	if heap.is_empty(): return result
	heap[0] = tail
	var i := 0
	while i*2+1 < heap.size():
		var child := i*2+1
		if child+1 < heap.size() and _heap_less(heap[child+1],heap[child]): child += 1
		if not _heap_less(heap[child],heap[i]): break
		var swap := heap[i]; heap[i] = heap[child]; heap[child] = swap
		i = child
	return result


## 角色太阳投影与墙体遮蔽批次逐帧重建会把地图从 320 帧压到 34 帧。
## 阴影是低对比度的软投影，按屏幕位移和最长间隔触发即可。
var actor_shadow_min_pixels := 6.0
var actor_shadow_refresh_hz := 10.0
var _actor_shadow_dirty := true
var _last_actor_shadow_usec := 0
var _last_shadow_feet := Vector2(INF, INF)
## 墙体批次重建推迟到下一帧，避免同一帧里投影、可见性裁剪与重构批次叠在一起。
var _wall_shadow_pending := false

func _refresh_actor() -> void:
	_dynamic_dirty = false
	_refresh_wall_cutaway()
	_surface_light.refresh(self)
	_wall_restore_regions.clear()
	_front_faces.clear()
	_visible_actor_regions.clear()
	_hidden_actor_regions.clear()
	var feet_for_gate := project_plane(_actor_plane, _actor_height)
	var shadows_due := _actor_shadow_dirty
	if not shadows_due and _actor_valid:
		shadows_due = _last_shadow_feet.distance_to(feet_for_gate) >= actor_shadow_min_pixels
	if not shadows_due and actor_shadow_refresh_hz > 0.0:
		shadows_due = Time.get_ticks_usec() - _last_actor_shadow_usec >= int(1000000.0 / actor_shadow_refresh_hz)
	if not _actor_valid:
		_actor_solar_shadows.clear()
		_clear_wall_shadow_overrides()
		_wall_shadow_pending = false
		_refresh_actor_cutaway_restore()
		_refresh_actor_occlusion_hint()
		_refresh_actor_emission()
		queue_redraw()
		return
	if shadows_due:
		_actor_shadow_dirty = false
		_last_actor_shadow_usec = Time.get_ticks_usec()
		_last_shadow_feet = feet_for_gate
		_actor_solar_shadows.clear()
	var actor_world := Vector3(_actor_plane.x,_actor_height+ACTOR_HEIGHT*.55,_actor_plane.y)
	_actor_light = _solar.lighting_at(actor_world)
	_actor_atmosphere_tint = _atmosphere.tint(Color.WHITE,actor_world,Vector3.UP,_key(_plane_coord(_actor_plane)),_actor_light,_display_sun_config,false,true)
	if shadows_due and is_sun_enabled():
		var projected_shadows: Array = _solar.project_actor_shadow(_actor_plane, _actor_height, ACTOR_HEIGHT, Profile.FOOT_RADIUS, _faces, actor_animation.shadow_contour(PIXELS_PER_WORLD, _basis.y.y))
		for shadow: Dictionary in projected_shadows:
			var receiver: Dictionary = _faces[int(shadow.face_index)]
			if receiver.get("node_marker", false) or (receiver.has("rock") and not is_art_enabled()): continue
			for visible in _visible_surface_regions(shadow.polygon, receiver):
				_actor_solar_shadows.append({"polygon": visible, "factor": float(receiver.get("solar_factor", 1.0)), "receiver":receiver, "face_index":int(shadow.face_index)})
	# Cover the union of every original animation frame AND the foot shadow.
	# A silhouette fitted to one idle pose leaks walking legs around foreground.
	var feet := feet_for_gate
	var silhouette := actor_animation.body_rect(feet)
	var shadow := Rect2(feet + Vector2(-16, -6) * Profile.VISUAL_SCALE, Vector2(36, 14) * Profile.VISUAL_SCALE)
	_actor_aperture = silhouette.merge(shadow).grow(1.0)
	_actor_shape = _rect_polygon(_actor_aperture)
	var actor_coefficient := _upright_depth_coefficient(_actor_plane, _actor_height)
	var node_masks: Array[Dictionary] = []
	var blockers: Dictionary = {}
	var body_samples: Array[Dictionary] = []
	for fraction in [0.08, 0.50, 0.98]:
		var relative_height: float = fraction * ACTOR_HEIGHT
		for original_lateral in [-0.12, 0.0, 0.12]:
			var lateral: float = original_lateral * Profile.VISUAL_SCALE
			var sample := project_plane(_actor_plane, _actor_height + relative_height) + Vector2(lateral * PIXELS_PER_WORLD, 0.0)
			body_samples.append({"height": relative_height, "lateral": lateral, "screen": [sample.x, sample.y], "blockers": []})
	for index in _face_indices(_actor_aperture):
		var face: Dictionary = _sorted_faces[index]
		if is_exploration_fog_enabled() and not face.known: continue
		if face.has("rock"): continue
		if not face.bounds.intersects(_actor_aperture):
			continue
		var coefficient: Vector3 = face.coefficient
		var surfaces: Array[PackedVector2Array] = []
		var node_marker: bool = face.get("node_marker", false)
		if node_marker:
			# Markers use their actual foot plane, with only cached opaque image
			# pixels as blockers. Text, the contact circle and PNG corners stay open.
			coefficient = _upright_depth_coefficient(face.support, face.support_height)
			# Both upright planes share XY coefficients, so their depth difference
			# is constant across the PNG. Classify the whole node once.
			if coefficient.z - actor_coefficient.z < DEPTH_EPSILON: continue
			surfaces = _node_actor_surfaces(face)
			if not surfaces.is_empty(): node_masks.append(face)
		else:
			surfaces = _fog_surface_regions(face,face.polygon)
		for surface in surfaces:
			# Node rectangles are already clipped to the aperture and classified
			# as a whole upright plane; avoid clipping every strip a second time.
			var foreground := surface if node_marker else _clip_depth(surface, coefficient, actor_coefficient)
			if foreground.size() < 3 or absf(_signed_area(foreground)) < 0.1:
				continue
			# Convex rectangular clipping is enough; avoid polygon-with-hole output.
			if not node_marker: foreground = _clip_to_rect(foreground, _actor_aperture)
			var area := absf(_signed_area(foreground))
			if area < 0.20:
				continue
			var item := face.duplicate(false)
			item["foreground"] = foreground
			item["foreground_bounds"] = _polygon_bounds(foreground)
			item["cutaway"] = false
			_front_faces.append(item)
			var id := String(face.id)
			if not blockers.has(id):
				blockers[id] = {"id": id, "category": face.category, "cell": face.key, "known": face.known, "support_plane": [face.support.x, face.support.y], "support_planar_y": face.support_y, "support_height": face.support_height, "face_count": 0, "overlap_pixels": 0.0, "cutaway": item.cutaway}
			blockers[id].face_count += 1
			blockers[id].overlap_pixels += area
			for sample in body_samples:
				var screen := Vector2(float(sample.screen[0]), float(sample.screen[1]))
				if Geometry2D.is_point_in_polygon(screen, foreground) and not sample.blockers.has(id):
					sample.blockers.append(id)
	_visible_actor_regions.append(_actor_shape)
	for face in _front_faces:
		if face.get("node_marker", false): continue
		var remaining: Array[PackedVector2Array] = []
		for region in _visible_actor_regions:
			if not _polygon_bounds(region).intersects(face.foreground_bounds):
				remaining.append(region)
				continue
			var hidden := _intersect_convex(region, face.foreground)
			if hidden.size() >= 3 and absf(_signed_area(hidden)) >= 0.0001:
				_hidden_actor_regions.append(hidden)
			remaining.append_array(_subtract_convex(region, face.foreground))
		_visible_actor_regions = remaining
		if remaining.is_empty(): break
	# Only walls can be opened. Higher traversable ground, nodes and scenery
	# retain their true occlusion even inside the local display aperture.
	_wall_restore_regions.assign(_hidden_actor_regions)
	for face in _front_faces:
		if face.get("node_marker", false): continue
		if _is_cutaway_wall(face): continue
		var remaining: Array[PackedVector2Array] = []
		for region in _wall_restore_regions:
			if _polygon_bounds(region).intersects(face.foreground_bounds): remaining.append_array(_subtract_convex(region, face.foreground))
			else: remaining.append(region)
		_wall_restore_regions = remaining
		if remaining.is_empty(): break
	# Terrain is settled before PNG masks. Intersect with the cached disjoint
	# alpha partition once per node instead of repeatedly subtracting opaque
	# strips from an ever-growing set of actor and restore fragments.
	var node_clip_start := Time.get_ticks_usec()
	for face in node_masks:
		_visible_actor_regions = _node_transparent_regions(_visible_actor_regions, face, true)
		_wall_restore_regions = _node_transparent_regions(_wall_restore_regions, face, false)
	var node_clip_ms := (Time.get_ticks_usec() - node_clip_start) / 1000.0
	_report = {
		"renderer": "pure Node2D convex-face painter with affine foreground clipping",
		"projection": "orthographic", "pitch_degrees": PITCH_DEGREES, "yaw_degrees": YAW_DEGREES,
		"pixels_per_world": PIXELS_PER_WORLD, "outer_radius": _radius, "height_quantum": _quantum,
		"actor_physical_height": ACTOR_HEIGHT, "actor_height": _actor_height,
		"actor_scale": Profile.VISUAL_SCALE, "foot_radius": Profile.FOOT_RADIUS, "move_speed": Profile.MOVE_SPEED,
		"actor_plane": [_actor_plane.x, _actor_plane.y], "actor_feet_screen": [feet.x, feet.y],
		"actor_planar_y": project_plane(_actor_plane, 0.0).y,
		"actor_support_depth": _planar_depth(_actor_plane), "actor_world_feet_depth": _world_depth(_actor_plane, _actor_height),
		"sort_origin_independent_of_visual_height": true, "height_implies_connectivity": false,
		"cell_count": _cells.size(), "known_cell_count": _known_count(), "unknown_content_hidden": true,
		"static_face_count": _faces.size(), "static_overlap_constraints": _static_overlap_pairs,
		"static_rebuild_count": _static_rebuild_count,
		"actor_candidate_faces": _face_indices(_actor_aperture).size(), "actor_visible_regions": _visible_actor_regions.size(),
		"static_ordering_fallbacks": _ordering_cycles, "front_face_count": _front_faces.size(),
		"static_ambiguous_overlap_pairs": _ambiguous_overlap_pairs,
		"front_occluders": blockers.values(), "body_samples": body_samples,
		"node_actor_clip": {"nodes": node_masks.size(), "build_ms": node_clip_ms, "method": "cached 64px opaque/transparent partition; one target split per input region"},
		"cutaway_enabled": is_wall_cutaway_enabled(),
		"cutaway_method": "local wall alpha with known reachable ground targets; geometry clipping unchanged",
		"duplicate_cell_keys": _duplicate_cells.duplicate(), "skipped_nodes": _skipped_nodes.duplicate(),
		"limits": ["Scoped convex extruded hex/footprint geometry, not general intersecting art", "Static painter cycles use a reported deterministic fallback", "No general pixel-perfect sprite alpha/depth reconstruction", "Movement/collision/fog discovery are controller responsibilities"]
	}
	var shadow_batches_due := _wall_shadow_pending
	_wall_shadow_pending = false
	if shadows_due:
		# 本帧只做投影与可见性裁剪，批次重构留到下一帧，避免单帧把两件事叠在一起。
		_wall_shadow_pending = true
	if shadow_batches_due:
		_refresh_wall_shadow_overrides()
		_refresh_art_actor_shadow()
	_refresh_actor_emission()
	_refresh_actor_occlusion_hint()
	_refresh_actor_cutaway_restore()
	queue_redraw()


func _node_actor_surfaces(face: Dictionary) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	# Only published, known, sanitized presentations can block the actor. This
	# does not add marker rectangles to any fog or surface-visibility authority.
	if not face.get("known", false) or not _node_presentations.has(face.node_id): return result
	var visual: Dictionary = face.get("node_display", {})
	if not NodeArt.is_actor_occluder(visual): return result
	var path: String = str(visual.get("texture", ""))
	var bounds: Rect2 = face.bounds
	if face.get("actor_alpha_path", "") != path or face.get("actor_alpha_bounds", Rect2()) != bounds or not face.has("actor_alpha_transparent"):
		var rectangles: Array[Rect2] = []
		var transparent: Array[Rect2] = []
		var texture: Texture2D = NodeArt.texture(path)
		var target := Rect2()
		if texture != null:
			target = NodeArt.target_rect(bounds, texture.get_size())
			for rect: Rect2 in NodeArt.opaque_rects(path):
				rectangles.append(Rect2(target.position + rect.position * target.size, rect.size * target.size))
			for rect: Rect2 in NodeArt.transparent_rects(path):
				transparent.append(Rect2(target.position + rect.position * target.size, rect.size * target.size))
		face.actor_alpha_path = path
		face.actor_alpha_bounds = bounds
		face.actor_alpha_rects = rectangles
		face.actor_alpha_transparent = transparent
		face.actor_alpha_target = target
	# World-space rectangles are cached with the static marker; per frame only
	# rectangles intersecting the actor become convex clipping pieces.
	for rect: Rect2 in face.get("actor_alpha_rects", []):
		if rect.intersects(_actor_aperture): result.append(_rect_polygon(rect.intersection(_actor_aperture)))
	return result


func _node_transparent_regions(regions: Array[PackedVector2Array], face: Dictionary, collect_hidden: bool) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var target: Rect2 = face.actor_alpha_target
	var target_polygon := _rect_polygon(target)
	for region in regions:
		var bounds := _polygon_bounds(region)
		if not bounds.intersects(target):
			result.append(region)
			continue
		# The aspect-fitted image can leave open space inside marker.bounds.
		# Split only its actual draw target, retaining all four outside sides.
		result.append_array(_subtract_convex(region, target_polygon))
		for rect: Rect2 in face.actor_alpha_transparent:
			if not bounds.intersects(rect): continue
			var visible := _clip_to_rect(region, rect)
			if visible.size() >= 3 and absf(_signed_area(visible)) > 0.0001: result.append(visible)
		if not collect_hidden: continue
		for rect: Rect2 in face.actor_alpha_rects:
			if not bounds.intersects(rect): continue
			var hidden := _clip_to_rect(region, rect)
			if hidden.size() >= 3 and absf(_signed_area(hidden)) > 0.0001: _hidden_actor_regions.append(hidden)
	return result


func _refresh_actor_occlusion_hint() -> void:
	var key := _key(_plane_coord(_actor_plane))
	var valid_ground: bool = _cells.has(key) and _cells[key].terrain == "ground"
	var known_ground := not is_exploration_fog_enabled() or _known.has(key)
	if not _actor_occlusion_hint_enabled or not _actor_valid or not valid_ground or not known_ground or _hidden_actor_regions.is_empty():
		if _actor_occlusion_hint != null: _actor_occlusion_hint.clear()
		return
	if _actor_occlusion_hint == null:
		_actor_occlusion_hint = ActorOcclusionHint.new()
		add_child(_actor_occlusion_hint)
	# FogVeil uses its own foreground ordering; this cue cannot reveal map art.
	_actor_occlusion_hint.rebuild(self, _hidden_actor_regions)


func _refresh_actor_emission() -> void:
	if _actor_emission_strength<=0.0 or not _actor_valid or _visible_actor_regions.is_empty():
		if _actor_emission_batch!=null: _actor_emission_batch.rebuild(self,{},[],0.0)
		return
	var key := _key(_plane_coord(_actor_plane))
	if not _known.get(key,false) or not _cells.has(key) or _cells[key].get("terrain","ground") != "ground":
		if _actor_emission_batch!=null: _actor_emission_batch.rebuild(self,{},[],0.0)
		return
	var footprint := PackedVector2Array()
	for i in 24:
		var angle := TAU*float(i)/24.0
		footprint.append(project_plane(_actor_plane+Vector2(cos(angle),sin(angle))*.68*_radius,_actor_height))
	var receiver: Dictionary = {}
	for index in _face_indices(_polygon_bounds(footprint)):
		var face: Dictionary = _sorted_faces[index]
		if face.key==key and face.known and face.top and face.category=="ground" and not face.has("node_id") and not face.get("scenery",false):
			receiver=face;break
	var pieces: Array[PackedVector2Array] = []
	if not receiver.is_empty():
		var clipped := _intersect_convex(footprint,receiver.polygon)
		if clipped.size()>=3: pieces=_visible_surface_regions(clipped,receiver)
	if _actor_emission_batch==null:
		_actor_emission_batch=ActorEmission.new();add_child(_actor_emission_batch)
	move_child(_actor_emission_batch,get_child_count()-1)
	_actor_emission_batch.rebuild(self,receiver,pieces,_actor_emission_strength*.35)


func _clear_wall_shadow_overrides() -> void:
	for batch in _wall_shadow_active:
		if is_instance_valid(batch): batch.clear_dynamic_prepared()
	_wall_shadow_active.clear();_wall_shadow_applied.clear()
	for field in ["faces","pieces","batches","triangles","unbound_pieces"]: _wall_shadow_stats[field]=0
	_wall_shadow_stats.build_ms=0.0

func _index_wall_shadow_batches() -> void:
	_clear_wall_shadow_overrides()
	for batch in _vector_batches: batch.clear_dynamic_prepared()
	_wall_shadow_batches=_build_wall_shadow_batch_index(self,_vector_batches)

func _is_actor_shadow_receiver(face: Dictionary) -> bool:
	# A PNG billboard is not an opaque surface. Ground and scenery receive
	# moving shadows in their own painter slot, just as walls already do.
	return bool(face.get("known", false)) and not face.get("node_marker", false)

func _build_wall_shadow_batch_index(source, batches: Array) -> Dictionary:
	var bindings: Dictionary = {}
	# Face ids repeat across wall height bands. Solar's original face index is
	# unique only within this presentation and its matching batch collection.
	for index in source._faces.size():
		if source._is_actor_shadow_receiver(source._faces[index]): source._faces[index]["_wall_shadow_index"]=index
	for batch in batches:
		for face: Dictionary in batch.faces:
			if source._is_actor_shadow_receiver(face): bindings[int(face._wall_shadow_index)]=batch
	return bindings

func _refresh_wall_shadow_overrides() -> void:
	var start := Time.get_ticks_usec()
	_clear_wall_shadow_overrides()
	_wall_shadow_stats.updates+=1
	var by_batch: Dictionary = {}
	for shadow: Dictionary in _actor_solar_shadows:
		if not _is_actor_shadow_receiver(shadow.receiver): continue
		var index := int(shadow.face_index)
		var batch = _wall_shadow_batches.get(index)
		# A missing binding keeps the existing overlay path, rather than dropping
		# the shadow. Normal publication always indexes before refreshing actor.
		if not is_instance_valid(batch):
			_wall_shadow_stats.unbound_pieces+=1
			continue
		if not by_batch.has(batch): by_batch[batch]={}
		if not by_batch[batch].has(index): by_batch[batch][index]=[]
		by_batch[batch][index].append(shadow.polygon)
		_wall_shadow_stats.pieces+=1
	for batch in by_batch:
		var prepared: Array = VectorBatch.prepare_wall_shadow_override(self,batch.faces,by_batch[batch],batch.static_face_packets)
		batch.set_dynamic_prepared(prepared)
		_wall_shadow_active.append(batch)
		_wall_shadow_stats.triangles+=batch.dynamic_triangles
		for index in by_batch[batch]: _wall_shadow_applied[index]=true
	_wall_shadow_stats.faces=_wall_shadow_applied.size()
	_wall_shadow_stats.batches=_wall_shadow_active.size()
	_wall_shadow_stats.build_ms=(Time.get_ticks_usec()-start)/1000.0

func _refresh_art_actor_shadow() -> void:
	if _art_actor_shadow_batch == null:
		_art_actor_shadow_batch=VectorBatch.new()
		_art_actor_shadow_batch.show_behind_parent=true
		add_child(_art_actor_shadow_batch)
	move_child(_art_actor_shadow_batch,get_child_count()-1)
	var buffer=VectorBatch.Buffer.new()
	buffer.atlas=is_art_enabled()
	for shadow: Dictionary in _actor_solar_shadows:
		# All published terrain shadows belong to their original painter slot.
		# This fallback is only for a temporarily unbound receiver, never a PNG.
		if shadow.receiver.get("node_marker", false) or _wall_shadow_applied.has(int(shadow.face_index)): continue
		buffer.begin_face(self,shadow.receiver)
		var map: Dictionary = _art.mapping(shadow.receiver) if is_art_enabled() else {}
		if not map.is_empty():
			buffer.art_fill(self,shadow.receiver,shadow.polygon,map,true)

		elif is_atmosphere_enabled() or is_exploration_fog_enabled():
			buffer.atmosphere_fill(self,shadow.receiver,shadow.polygon,true)
		else:
			buffer.light_receiver=0.0
			buffer.polygon_fill(shadow.polygon,Color(0,0,0,_shadow_opacity(shadow.factor)))
		if is_art_enabled():
			# The receiver includes its painted decal. Redraw only the part under
			# this actor-shadow fragment, preserving the original decal UV frame.
			var decal: Dictionary = _art.decoration(self,shadow.receiver)
			if not decal.is_empty():
				var overlap := _intersect_convex(decal.polygon,shadow.polygon)
				if overlap.size() >= 3:
					decal.polygon=overlap
					buffer.art_decoration(self,shadow.receiver,decal,true)
	buffer.flush_mesh()
	_art_actor_shadow_batch.apply_prepared([],buffer.commands,_art.atlas_path)
	if _wall_cutaway != null: _art_actor_shadow_batch.material=_wall_cutaway.material
	_art_actor_shadow_batch.show()


func _clear_surface_occluder_cache() -> void:
	_surface_occluder_cache_rows.clear()
	_surface_occluder_cache_bins.clear()
	_surface_occluder_cache_clock = 0
	_surface_occluder_cache_pairs = 0
	_surface_occluder_cache_polygons = 0
	_surface_occluder_cache_vertices = 0


func _evict_surface_occluder_receiver(protected: Dictionary = {}) -> bool:
	var oldest := -1
	var oldest_touch := 0
	for i in _surface_occluder_cache_rows.size():
		var candidate: Dictionary = _surface_occluder_cache_rows[i]
		if is_same(candidate, protected): continue
		if oldest < 0 or int(candidate.touch) < oldest_touch:
			oldest = i
			oldest_touch = int(candidate.touch)
	if oldest < 0: return false
	var row: Dictionary = _surface_occluder_cache_rows[oldest]
	_surface_occluder_cache_rows.remove_at(oldest)
	var bucket: Array = _surface_occluder_cache_bins[row.bucket]
	for i in bucket.size():
		if is_same(bucket[i], row):
			bucket.remove_at(i)
			break
	if bucket.is_empty(): _surface_occluder_cache_bins.erase(row.bucket)
	_surface_occluder_cache_pairs -= row.occluders.size()
	_surface_occluder_cache_polygons -= int(row.polygons)
	_surface_occluder_cache_vertices -= int(row.vertices)
	_surface_occluder_cache_evictions += 1
	return true


func _surface_occluder_receiver(receiver: Dictionary) -> Dictionary:
	_surface_occluder_cache_clock += 1
	# Hashes only select a bucket. Dictionary identity disambiguates repeated
	# wall ids, equal polygons and hash collisions without mutating face data.
	var identity: int = hash(receiver.polygon)
	for candidate: Dictionary in _surface_occluder_cache_bins.get(identity, []):
		if is_same(candidate.receiver, receiver):
			candidate.touch = _surface_occluder_cache_clock
			return candidate
	while _surface_occluder_cache_rows.size() >= SURFACE_OCCLUDER_CACHE_RECEIVERS:
		_evict_surface_occluder_receiver()
	var row := {"receiver":receiver, "bucket":identity, "occluders":{}, "polygons":0, "vertices":0, "touch":_surface_occluder_cache_clock}
	if not _surface_occluder_cache_bins.has(identity): _surface_occluder_cache_bins[identity] = []
	_surface_occluder_cache_bins[identity].append(row)
	_surface_occluder_cache_rows.append(row)
	return row


func _surface_occluder_record(row: Dictionary, index: int, face: Dictionary) -> Dictionary:
	if row.occluders.has(index):
		_surface_occluder_cache_fog_hits += 1
		return row.occluders[index]
	_surface_occluder_cache_fog_misses += 1
	var surfaces := _fog_surface_regions(face,face.polygon)
	var record := {"surfaces":surfaces, "covers":[], "retained":false}
	if surfaces.size() > SURFACE_OCCLUDER_CACHE_POLYGONS:
		_surface_occluder_cache_skips += 1
		return record
	while _surface_occluder_cache_pairs >= SURFACE_OCCLUDER_CACHE_PAIRS or _surface_occluder_cache_polygons + surfaces.size() > SURFACE_OCCLUDER_CACHE_POLYGONS:
		if not _evict_surface_occluder_receiver(row):
			_surface_occluder_cache_skips += 1
			return record
	# Null slots distinguish unvisited clips from legitimately empty covers.
	# This keeps the original early exit even for a site face with many pieces.
	record.covers.resize(surfaces.size())
	record.retained = true
	row.occluders[index] = record
	row.polygons += surfaces.size()
	_surface_occluder_cache_pairs += 1
	_surface_occluder_cache_polygons += surfaces.size()
	return record


func _store_surface_occluder_cover(row: Dictionary, record: Dictionary, index: int, cover: PackedVector2Array) -> void:
	if not record.retained: return
	var count := cover.size()
	if count > SURFACE_OCCLUDER_CACHE_VERTICES:
		_surface_occluder_cache_skips += 1
		return
	while _surface_occluder_cache_vertices + count > SURFACE_OCCLUDER_CACHE_VERTICES:
		if not _evict_surface_occluder_receiver(row):
			_surface_occluder_cache_skips += 1
			return
	record.covers[index] = cover
	row.vertices += count
	_surface_occluder_cache_vertices += count


func _visible_surface_regions(polygon: PackedVector2Array, receiver: Dictionary) -> Array[PackedVector2Array]:
	var regions: Array[PackedVector2Array] = _fog_surface_regions(receiver,polygon)
	var bounds := _polygon_bounds(polygon)
	var cached_receiver: Dictionary = {}
	for index in _face_indices(bounds):
		var face: Dictionary = _sorted_faces[index]
		if is_exploration_fog_enabled() and not face.known: continue
		if face.get("node_marker", false) or (face.has("rock") and not is_art_enabled()): continue
		if is_same(face, receiver) or not face.bounds.intersects(bounds, true): continue
		var record: Dictionary = {}
		var surfaces: Array[PackedVector2Array]
		if _surface_occluder_cache_enabled:
			if cached_receiver.is_empty(): cached_receiver = _surface_occluder_receiver(receiver)
			record = _surface_occluder_record(cached_receiver,index,face)
			surfaces = record.surfaces
		else:
			surfaces = _fog_surface_regions(face,face.polygon)
		for surface_index in surfaces.size():
			var cover: PackedVector2Array
			if _surface_occluder_cache_enabled and record.retained and record.covers[surface_index] != null:
				cover = record.covers[surface_index]
				_surface_occluder_cache_hits += 1
			else:
				cover = _clip_depth(surfaces[surface_index], face.coefficient, receiver.coefficient)
				if _surface_occluder_cache_enabled:
					_surface_occluder_cache_misses += 1
					_store_surface_occluder_cover(cached_receiver,record,surface_index,cover)
			if cover.size() < 3: continue
			var remaining: Array[PackedVector2Array] = []
			for region in regions: remaining.append_array(_subtract_convex(region, cover))
			regions = remaining
			if regions.is_empty(): break
		if regions.is_empty(): break
	return regions


func _draw() -> void:
	_dynamic_draw_count += 1
	# All shadow receivers use the same cutaway attributes as their wall/floor.
	if _actor_valid:
		_draw_actor()
	if show_debug:
		_draw_debug()


func _shadow_opacity(lit_factor: float) -> float:
	return clampf(1.0 - float(_display_sun_config.get("ambient", 0.30)) / maxf(0.001, lit_factor), 0.0, 1.0)


func _draw_actor() -> void:
	var feet := project_plane(_actor_plane, _actor_height)
	var shadow := _ellipse(feet + Vector2(2.0, 0.8) * Profile.VISUAL_SCALE, Vector2(17.0, 6.0) * Profile.VISUAL_SCALE, 20)
	if not is_sun_enabled():
		for region in _visible_actor_regions:
			var visible := _intersect_convex(shadow, region)
			if _has_drawable_actor_area(visible):
				_draw_actor_piece(visible, Color(0.15, 0.20, 0.17, 0.28))
	var frame: Dictionary = actor_animation.frame()
	if frame.is_empty(): return
	var region: Array = frame.region
	var texture: Texture2D = actor_animation.textures[frame.path]
	var box: Rect2 = actor_animation.draw_rect(feet)
	for part in _visible_actor_regions:
		var visible := _clip_to_rect(part, box)
		if not _has_drawable_actor_area(visible): continue
		var uvs := PackedVector2Array()
		for point in visible:
			uvs.append((Vector2(float(region[0]),float(region[1])) + (point - box.position) / box.size * Vector2(float(region[2]),float(region[3]))) / texture.get_size())
		_draw_actor_piece(visible,_actor_draw_tint(),uvs,texture)


func _actor_draw_tint() -> Color:
	var tint := _actor_atmosphere_tint if is_atmosphere_enabled() else Color(_actor_light, _actor_light, _actor_light, 1.0)
	if _actor_emission_strength > 0.0:
		tint = tint.lerp(Color.WHITE, .72 * _actor_emission_strength)
		var energy := 1.0 + .30 * _actor_emission_strength
		tint = Color(tint.r * energy, tint.g * energy, tint.b * energy, 1.0)
	return tint


func _draw_actor_piece(polygon: PackedVector2Array, color: Color, uvs: PackedVector2Array = PackedVector2Array(), texture: Texture2D = null) -> void:
	_draw_local_polygon(self, polygon, color, uvs, texture)


func _has_drawable_actor_area(polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3 or absf(_signed_area(polygon)) < 0.0001:
		return false
	# Coincident depth clips can produce a long, almost collinear float32
	# sliver with nonzero area and alternating turns. Area alone admits it,
	# but Godot cannot triangulate it. Reject only subpixel-width actor pieces;
	# leave the terrain, texture coordinates and visible cutaway unchanged.
	var edge_start := Vector2.ZERO
	var edge := Vector2.ZERO
	var longest_squared := 0.0
	for i in polygon.size():
		var candidate := polygon[(i + 1) % polygon.size()] - polygon[i]
		var length_squared := candidate.length_squared()
		if length_squared > longest_squared:
			longest_squared = length_squared
			edge_start = polygon[i]
			edge = candidate
	if longest_squared <= 0.0:
		return false
	# Projected-pixel tolerance, independent of the absolute map coordinate.
	var threshold := 0.001 * sqrt(longest_squared)
	for point in polygon:
		if absf(edge.cross(point - edge_start)) > threshold:
			return true
	return false


func _draw_local_polygon(painter: CanvasItem, polygon: PackedVector2Array, color: Color, uvs: PackedVector2Array = PackedVector2Array(), texture: Texture2D = null) -> void:
	# Godot's triangulator also uses float32 area products. Tiny valid triangles
	# fail at distant absolute coordinates, so submit first-vertex-relative
	# points for BOTH cached sunlight and moving sprites/shadows. Geometry and
	# UVs stay unchanged; the local command transform restores their position.
	if polygon.size() < 3: return
	var origin := polygon[0]
	var local := PackedVector2Array()
	for point in polygon: local.append(point-origin)
	painter.draw_set_transform(origin)
	painter.draw_colored_polygon(local, color, uvs, texture)
	painter.draw_set_transform(Vector2.ZERO)







func _draw_debug() -> void:
	if not _actor_valid:
		return
	var origin := project_plane(_actor_plane)
	var feet := project_plane(_actor_plane, _actor_height)
	draw_line(origin, feet, Color("bd9753"), 1.0, true)
	draw_circle(origin, 3.0, Color("53694f"), false, 1.2, true)
	draw_rect(_actor_aperture, Color(0.77, 0.57, 0.25, 0.65), false, 1.0)
	for face in _front_faces:
		var line: PackedVector2Array = face.foreground.duplicate()
		line.append(line[0])
		draw_polyline(line, Color(0.76, 0.45, 0.26, 0.6), 1.0, true)
	for sample in _report.get("body_samples", []):
		var point := Vector2(float(sample.screen[0]), float(sample.screen[1]))
		draw_circle(point, 1.8, Color("b45438") if not sample.blockers.is_empty() else Color("d6e0c0"))


func _clip_depth(polygon: PackedVector2Array, face: Vector3, target: Vector3) -> PackedVector2Array:
	var difference := face - target
	difference.z -= DEPTH_EPSILON
	return _clip_halfplane(polygon, difference)


func _clip_halfplane(polygon: PackedVector2Array, coefficient: Vector3) -> PackedVector2Array:
	var output := PackedVector2Array()
	if polygon.size() < 3:
		return output
	var previous := polygon[-1]
	var previous_value := _depth_at(coefficient, previous)
	for current in polygon:
		var value := _depth_at(coefficient, current)
		if (value >= 0.0) != (previous_value >= 0.0):
			var proportion := previous_value / (previous_value - value)
			output.append(previous.lerp(current, proportion))
		if value >= 0.0:
			output.append(current)
		previous = current
		previous_value = value
	return _clean_polygon(output)


func _clean_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	# Clipping coincident edges can leave a float32-wide sliver (7e-6 px in
	# the native wall test). Remove duplicate endpoints before triangulation.
	# The tolerance is in local pixels, independent of viewport zoom.
	var clean := PackedVector2Array()
	for point in polygon:
		if clean.is_empty() or clean[-1].distance_squared_to(point) > 0.00000001:
			clean.append(point)
	if clean.size() > 1 and clean[0].distance_squared_to(clean[-1]) <= 0.00000001:
		clean.remove_at(clean.size()-1)
	if clean.size() < 3 or absf(_signed_area(clean)) < 0.000001:
		return PackedVector2Array()
	return clean



func _clip_to_rect(polygon: PackedVector2Array, rectangle: Rect2) -> PackedVector2Array:
	var inside := polygon
	for coefficient in [Vector3(1,0,-rectangle.position.x),Vector3(-1,0,rectangle.end.x),Vector3(0,1,-rectangle.position.y),Vector3(0,-1,rectangle.end.y)]:
		inside = _clip_halfplane(inside, coefficient)
		if inside.size() < 3: break
	return inside


func _convex_planes(polygon: PackedVector2Array) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var direction := 1.0 if _signed_area(polygon) >= 0.0 else -1.0
	for i in polygon.size():
		var p := polygon[i]
		var d := polygon[(i+1) % polygon.size()] - p
		result.append(Vector3(-d.y,d.x,d.y*p.x-d.x*p.y) * direction)
	return result


func _intersect_convex(polygon: PackedVector2Array, cutter: PackedVector2Array) -> PackedVector2Array:
	var inside := polygon
	for coefficient in _convex_planes(cutter):
		inside = _clip_halfplane(inside,coefficient)
		if inside.size() < 3: break
	return inside


func _subtract_convex(polygon: PackedVector2Array, cutter: PackedVector2Array) -> Array[PackedVector2Array]:
	var outside: Array[PackedVector2Array] = []
	var inside := polygon
	for coefficient in _convex_planes(cutter):
		var piece := _clip_halfplane(inside,-coefficient)
		if piece.size() >= 3 and absf(_signed_area(piece)) > 0.0001: outside.append(piece)
		inside = _clip_halfplane(inside,coefficient)
		if inside.size() < 3: break
	return outside


func _depth_coefficient(polygon: PackedVector2Array, depths: PackedFloat32Array) -> Vector3:
	# All generated faces are planar, so camera depth is affine in screen XY.
	for i in range(1, polygon.size() - 1):
		var u := polygon[i] - polygon[0]
		var v := polygon[i + 1] - polygon[0]
		var determinant := u.cross(v)
		if absf(determinant) < 0.0001:
			continue
		var du := float(depths[i] - depths[0])
		var dv := float(depths[i + 1] - depths[0])
		var x := (du * v.y - dv * u.y) / determinant
		var y := (u.x * dv - v.x * du) / determinant
		return Vector3(x, y, float(depths[0]) - x * polygon[0].x - y * polygon[0].y)
	return Vector3(0, 0, depths[0] if not depths.is_empty() else 0.0)


func _upright_depth_coefficient(plane: Vector2, height: float) -> Vector3:
	var feet := project_plane(plane, height)
	var y := -tan(deg_to_rad(PITCH_DEGREES)) / PIXELS_PER_WORLD
	return Vector3(0.0, y, _world_depth(plane, height) - y * feet.y)


func _horizontal_depth_coefficient(height: float) -> Vector3:
	var origin := project_plane(Vector2.ZERO, height)
	var y := 1.0 / (tan(deg_to_rad(PITCH_DEGREES)) * PIXELS_PER_WORLD)
	return Vector3(0.0, y, _world_depth(Vector2.ZERO, height) - y * origin.y)


func _depth_at(coefficient: Vector3, screen: Vector2) -> float:
	return coefficient.x * screen.x + coefficient.y * screen.y + coefficient.z


func _world_depth(plane: Vector2, height: float) -> float:
	return Vector3(plane.x, height, plane.y).dot(_basis.z)


func _planar_depth(plane: Vector2) -> float:
	return _world_depth(plane, 0.0)


func _calculate_bounds() -> void:
	# Fit the same support-map rectangle in both comparison modes. Scenery
	# bounds are diagnostic only, so adding an outer ring cannot shrink the map.
	var has_map := false
	var has_scenery := false
	_scenery_bounds = Rect2()
	for face in _faces:
		if bool(face.get("scenery", false)):
			_scenery_bounds = _scenery_bounds.merge(face.bounds) if has_scenery else face.bounds
			has_scenery = true
		else:
			_bounds = _bounds.merge(face.bounds) if has_map else face.bounds
			has_map = true
	if not has_map:
		_bounds = Rect2(-60, -60, 120, 120)
		return
	# Reserve actor headroom without coupling the camera fit to actor movement.
	_bounds = _bounds.grow(24.0)
	_bounds.position.y -= ACTOR_HEIGHT * PIXELS_PER_WORLD
	_bounds.size.y += ACTOR_HEIGHT * PIXELS_PER_WORLD


func _hex_polygon(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in 6:
		var angle := deg_to_rad(float(index) * 60.0)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


func _repeat_height(count: int, height: float) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for _i in count:
		values.append(height)
	return values


func _neighbor(coord: Vector2i, edge: int) -> Vector2i:
	var corners := _hex_polygon(Vector2.ZERO, 1.0)
	var outward := (corners[edge] + corners[(edge + 1) % 6]).normalized()
	var best := -INF
	var result := coord
	for direction: Vector2i in DIRS:
		var score := outward.dot(hex_plane(direction).normalized())
		if score > best:
			best = score
			result = coord + direction
	return result


func _cell_height(key: String) -> float:
	return float(_cells.get(key, {}).get("level", 0)) * _quantum


func _key(coord: Vector2i) -> String:
	return "%d,%d" % [coord.x, coord.y]


func _pair(value) -> Vector2i:
	if value is Vector2i:
		return value
	return Vector2i(int(value[0]), int(value[1]))


func _plane_coord(plane: Vector2) -> Vector2i:
	var q := plane.x / (1.5 * _radius)
	var r := plane.y / (sqrt(3.0) * _radius) - q * 0.5
	var x := roundi(q)
	var z := roundi(r)
	var y := roundi(-q - r)
	var dx := absf(float(x) - q)
	var dz := absf(float(z) - r)
	var dy := absf(float(y) + q + r)
	if dx > dy and dx > dz:
		x = -y - z
	elif dz > dy:
		z = -x - y
	return Vector2i(x, z)




func _known_count() -> int:
	var count := 0
	for key in _cells:
		if bool(_known.get(key, false)):
			count += 1
	return count


func _polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	if polygon.is_empty():
		return Rect2()
	var rect := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		rect = rect.expand(point)
	return rect


func _signed_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3: return 0.0
	# Translate first: absolute float32 cross products cancel for thin clipped
	# pieces and can reverse their winding despite a nonzero visible area.
	var origin := polygon[0]
	var sum := 0.0
	for i in range(1, polygon.size()-1):
		sum += (polygon[i]-origin).cross(polygon[i+1]-origin)
	return sum * 0.5


func _ellipse(center: Vector2, radius: Vector2, count: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in count:
		var angle := TAU * float(i) / count
		points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	return points


func _rect_polygon(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])


func _start_warm_lookahead() -> void:
	if not _parallel_warm_enabled or not _warm_lookahead.is_empty() or not _retired_warm_jobs.is_empty(): return
	for state: Dictionary in _presentation_cache_plan:
		var key:=_cache_key(state.snapshot,state.known)
		if key==_presentation_cache_warming_key or _presentation_cache_entries.has(key): continue
		var builder=get_script().new(false)
		builder.show_grid=show_grid;builder.show_node_regions=show_node_regions
		builder._sun_config=_sun_config.duplicate(true)
		builder._atmosphere_config=_atmosphere_config.duplicate(true)
		builder._art_enabled=_art_enabled;builder._exploration_fog_enabled=_exploration_fog_enabled
		builder._known=state.known.duplicate(true);builder._completed=state.get("completed",{}).duplicate(true)
		builder._configure_sun();builder._floor_data=_floor_data;builder._load_map_data(state.snapshot)
		builder._exploration_fog_visual_mode=_exploration_fog_visual_mode
		builder._display_exploration_fog_visual_mode=_exploration_fog_visual_mode
		var thread:=Thread.new()
		if thread.start(builder._prepare_geometry_arrays, Thread.PRIORITY_LOW)!=OK:
			builder.free();return # Existing serial worker is the complete fallback.
		_warm_lookahead={"key":key,"builder":builder,"thread":thread,"signature":_cache_config_signature().duplicate(true)}
		return


func _discard_warm_lookahead() -> void:
	if _warm_lookahead.is_empty(): return
	_retired_warm_jobs.append(_warm_lookahead);_warm_lookahead={}
	set_process(true)
	_drain_retired_warm_jobs()


func _drain_retired_warm_jobs(wait_for_all: bool=false) -> void:
	for index in range(_retired_warm_jobs.size()-1,-1,-1):
		var job: Dictionary=_retired_warm_jobs[index]
		if job.thread.is_alive() and not wait_for_all: continue
		job.thread.wait_to_finish();job.builder.free();_retired_warm_jobs.remove_at(index)


func _make_rocks() -> void:
	# Full-floor deterministic positions; discovery only controls drawing.
	_rock_layout=RockScatter.generate(_source_snapshot,_art.catalog)
	for entry: Dictionary in _rock_layout.get("entries",[]):
		if not bool(_known.get(str(entry.key),false)): continue
		if entry.kind=="rubble" and not bool(_known.get(str(entry.wall_key),false)): continue
		var region: Dictionary=_art.catalog.regions.get(str(entry.region),{})
		if region.is_empty(): continue
		var plane: Vector2=entry.plane
		var height: float=float(entry.height)+.012
		var dimensions: Vector2=region.dimensions
		var width: float=float(entry.width)*PIXELS_PER_WORLD
		var size:=Vector2(width,width*dimensions.y/dimensions.x)
		var feet:=project_plane(plane,height)
		var rect:=Rect2(feet-Vector2(size.x*.5,size.y if entry.kind=="rubble" else size.y*.5),size)
		var planar:=PackedVector2Array()
		var heights:=PackedFloat32Array()
		var outline: Array=region.get("outline",[[0,0],[1,0],[1,1],[0,1]])
		var prop: Dictionary={"rect":rect,"region":str(entry.region),"kind":str(entry.kind)}
		if entry.kind=="rubble":
			# Preserve the artist's fixed-view projection. Give the lower edge a
			# supported footing and lean the upper silhouette over that footprint,
			# instead of shearing the entire painting onto whichever wall is near.
			var tangent: Vector2=entry.sprite_right
			var away: Vector2=entry.sprite_depth
			var backset: float=entry.backset
			var front: Vector2=plane+away*backset*.5
			var actual_width: float=entry.width
			var rise: float=(actual_width*dimensions.y/dimensions.x-backset*sin(deg_to_rad(PITCH_DEGREES)))/cos(deg_to_rad(PITCH_DEGREES))
			prop.merge({"plane":front,"tangent":tangent,"width":actual_width,"base":height,"rise":rise})
			_make_rubble_contact(entry,height-.008)
			for pair in outline:
				var up: float=1.0-float(pair[1])
				planar.append(front+tangent*(float(pair[0])-.5)*actual_width-away*backset*up)
				heights.append(height+up*rise)

		else:
			var coefficient:=_horizontal_depth_coefficient(height)
			for pair in outline:
				var point:=rect.position+Vector2(pair[0],pair[1])*rect.size
				var depth: float=coefficient.x*point.x+coefficient.y*point.y+coefficient.z
				var world: Vector3=_basis.x*(point.x/PIXELS_PER_WORLD)-_basis.y*(point.y/PIXELS_PER_WORLD)+_basis.z*depth
				planar.append(Vector2(world.x,world.z));heights.append(world.y)
		var face:=_add_face(planar,heights,Color.WHITE,"rock",str(entry.id),str(entry.key),true,plane,height,entry.kind=="pebble")
		face["rock"]=prop
		face["draw_edges"]=false
		if entry.kind=="rubble":
			face["normal"]=Vector3(entry.sprite_depth.x*prop.rise,entry.backset,entry.sprite_depth.y*prop.rise).normalized()


func _make_rubble_contact(entry: Dictionary,height: float) -> void:
	# A shallow ground shadow joins the painted base to the actual floor.
	# It stays within the same verified footprint, never a rectangular decal.
	var polygon:=PackedVector2Array()
	for i in 16:
		var angle: float=TAU*float(i)/16.0
		polygon.append(entry.plane+entry.sprite_right*cos(angle)*entry.foot_half_width*.94+entry.sprite_depth*sin(angle)*entry.foot_half_depth*.86)
	var face:=_add_face(polygon,_repeat_height(16,height),Color(.055,.039,.025,.20),"rock_contact",str(entry.id)+":contact",str(entry.key),true,entry.plane,height,true)
	face["rock"]={"kind":"contact","region":""};face["draw_edges"]=false


func get_rock_report() -> Dictionary:
	var report: Dictionary=_rock_layout.get("stats",{}).duplicate(true)
	var visible:=0
	for face: Dictionary in _faces:
		if face.has("rock") and face.rock.kind!="contact": visible+=1
	report["visible_instances"]=visible
	return report

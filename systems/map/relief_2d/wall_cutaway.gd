extends RefCounted
## Dynamic display context; never stored in static geometry/presentation caches.
const SHADER = preload("res://systems/map/relief_2d/env005_canvas.gdshader")
const TARGET_CAPACITY := 20 # Actor plus the guarded two-ring candidate set.
const FULL_RADIUS := 1.75 # Preserve full strength at the six adjacent centers (sqrt(3) R).
const OUTER_RADIUS := 2.6
const REVEAL_SECONDS := 0.18 # Match the short fog reveal; never delays Session passage.
var material := ShaderMaterial.new()
var enabled := true
var opacity := 0.14
var reachable: Dictionary = {}
var collision_edges: Dictionary = {}
var wall_edges := PackedInt32Array()
var context: Array = []
var targets := PackedVector4Array()
var depths := PackedVector3Array()
var edges_a := PackedVector3Array()
var edges_b := PackedVector3Array()
# Only newly authorized cells animate. Repeated unlocks keep existing progress.
var _opening: Dictionary = {}
var target_keys: Array[String] = []
var _inverse := Vector4.ZERO
var _feet := Vector2.ZERO
var _radius := 60.0
var build_ms := 0.0
var update_count := 0
var _body_mask_path := ""
var _body_mask: Texture2D
var _body_mask_enabled := false
var _body_rect := Vector4.ZERO

func _configure_body_mask(source) -> void:
	# Optional actor-profile asset. Missing/invalid profiles retain the original
	# ellipse. Load once per path; movement only updates the projected rectangle.
	var profile: Dictionary = source.actor_animation.config.get("cutaway_mask", {})
	var path := str(profile.get("path", ""))
	if path != _body_mask_path:
		_body_mask_path = path
		_body_mask = null
		if not path.is_empty() and FileAccess.file_exists(path):
			var image := Image.new()
			if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) == OK:
				_body_mask = ImageTexture.create_from_image(image)
		elif not path.is_empty() and ResourceLoader.exists(path):
			var texture = load(path)
			if texture is Texture2D: _body_mask = texture
	_body_mask_enabled = _body_mask != null and profile.get("frame_size", []) == source.actor_animation.config.get("frame_size", [])
	if not _body_mask_enabled: return
	var padding: float = maxf(0.0, float(profile.get("padding", 0))) * source.actor_animation.pixel_scale
	var rect: Rect2 = source.actor_animation.draw_rect(_feet).grow(padding)
	_body_rect = Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y)

func _init() -> void:
	material.shader = SHADER
	targets.resize(TARGET_CAPACITY); depths.resize(TARGET_CAPACITY)
	wall_edges.resize(TARGET_CAPACITY)
	edges_a.resize(TARGET_CAPACITY); edges_b.resize(TARGET_CAPACITY)

func set_context(map_id: String, seed: String, floor_index: int, allowed: Dictionary, boundaries: Dictionary = {}) -> void:
	var next_context := [map_id, seed, floor_index]
	var reset := context != next_context or not enabled
	for key in reachable:
		if bool(reachable[key]) and not bool(allowed.get(key, false)):
			reset = true # Revocation is immediate, never animated or retained.
			break
	if reset:
		_opening.clear()
	else:
		for key in allowed:
			if bool(allowed[key]) and not bool(reachable.get(key, false)):
				_opening[key] = -1.0 # Wait for the corresponding known presentation.
	context = next_context
	reachable = allowed.duplicate()
	collision_edges = boundaries.duplicate(true)

func advance(delta: float) -> bool:
	if _opening.is_empty(): return false
	if not enabled:
		_opening.clear()
		return true
	var changed := false
	for key in _opening.keys():
		if float(_opening[key]) < 0.0: continue
		changed = true
		var elapsed: float = float(_opening[key]) + maxf(0.0, delta)
		if elapsed >= REVEAL_SECONDS: _opening.erase(key)
		else: _opening[key] = elapsed
	return changed

func _activate_openings(source) -> void:
	# During an asynchronous bind, Session may already know more than the
	# displayed renderer. Do not spend the animation while those faces are absent.
	# This also handles same-known completion, which need not emit a commit signal.
	for key in _opening:
		if float(_opening[key]) < 0.0 and not _authorized(source, key): return
	for key in _opening:
		if float(_opening[key]) < 0.0: _opening[key] = 0.0

func _openness(key: String) -> float:
	return smoothstep(0.0, REVEAL_SECONDS, float(_opening[key])) if _opening.has(key) else 1.0

func refresh(source) -> void:
	var start := Time.get_ticks_usec()
	update_count += 1
	target_keys.clear()
	targets.fill(Vector4.ZERO); depths.fill(Vector3.ZERO)
	wall_edges.fill(0)
	edges_a.fill(Vector3.ZERO); edges_b.fill(Vector3.ZERO)
	var key: String = source._key(source._plane_coord(source._actor_plane))
	var current: Array = [source._source_snapshot.get("map_id", ""), source._source_snapshot.get("seed", ""), source._source_snapshot.get("floor_index", 0)]
	if enabled and source._actor_valid and current == context and _authorized(source, key):
		_activate_openings(source)
		var feet: Vector2 = source.project_plane(source._actor_plane, source._actor_height)
		_feet = feet
		_configure_body_mask(source)
		var box: Rect2 = source.actor_animation.body_rect(feet).grow(10.0)
		var half := box.size * 0.72
		targets[0] = Vector4(box.get_center().x, box.get_center().y, half.x, half.y)
		depths[0] = source._upright_depth_coefficient(source._actor_plane, source._actor_height)
		var coord: Vector2i = source._plane_coord(source._actor_plane)
		# The two-ring set is a guard, not the visible aperture. Every omitted
		# center is at least (sqrt(21)-1) radii from the actor, beyond OUTER_RADIUS.
		# Membership can therefore change only where its weight is already zero.
		var candidates: Array[Vector2i] = []
		for q in range(-2, 3):
			for r in range(-2, 3):
				if absi(q + r) <= 2: candidates.append(coord + Vector2i(q, r))
		for cell_coord in candidates:
			var candidate: String = source._key(cell_coord)
			if not _authorized(source, candidate): continue
			var distance: float = source.hex_plane(cell_coord).distance_to(source._actor_plane) / source._radius
			if distance >= OUTER_RADIUS: continue
			var openness := _openness(candidate)
			var weight := (1.0 - smoothstep(FULL_RADIUS, OUTER_RADIUS, distance)) * openness
			var height: float = source._cell_height(candidate)
			var center: Vector2 = source.project_plane(source.hex_plane(cell_coord), height)
			var index := target_keys.size() + 1
			# Only a shared, authorized ground edge can join the apertures. The
			# outer boundary (walls, unknown cells and locked gates) stays closed.
			var links := 0
			var joined_a := Vector3.ZERO
			var joined_b := Vector3.ZERO
			for direction in source.DIRS.size():
				var neighbor: String = source._key(cell_coord + source.DIRS[direction])
				if _authorized(source, neighbor):
					links |= 1 << direction
					var joined := minf(openness, _openness(neighbor))
					if direction < 3: joined_a[direction] = joined
					else: joined_b[direction - 3] = joined
			# Only Session-blocking edges against KNOWN wall cells get a root.
			# Unknown, void and locked ground edges remain unmarked.
			for boundary: Dictionary in collision_edges.get(candidate, []):
				var wall_key := str(boundary.get("neighbor_key", ""))
				var side := int(boundary.get("direction", -1))
				if side < 0 or side >= 6 or not bool(source._known.get(wall_key, false)): continue
				if source._cells.get(wall_key, {}).get("terrain", "") == "wall":
					wall_edges[index] |= 1 << side
			edges_a[index] = joined_a
			edges_b[index] = joined_b
			targets[index] = Vector4(center.x, center.y, weight, links)
			depths[index] = source._horizontal_depth_coefficient(height)
			target_keys.append(candidate)
		var a: Vector2 = source.unproject_plane(Vector2(1, 0)) / source._radius
		var b: Vector2 = source.unproject_plane(Vector2(0, 1)) / source._radius
		_inverse = Vector4(a.x, b.x, a.y, b.y)
		_radius = source.PIXELS_PER_WORLD * source._radius
	else:
		_opening.clear() # No fading history survives invalid actor/map authority.
		_body_mask_enabled = false
	apply_to(material)
	build_ms = (Time.get_ticks_usec() - start) / 1000.0

func _authorized(source, key: String) -> bool:
	# Known fringe around a locked gate is intentionally insufficient.
	return bool(reachable.get(key, false)) and bool(source._known.get(key, false)) and source._cells.has(key) and source._cells[key].terrain == "ground"

func apply_to(effect: ShaderMaterial) -> void:
	effect.set_shader_parameter("cut_count", target_keys.size() + 1 if not target_keys.is_empty() else 0)
	effect.set_shader_parameter("cut_targets", targets)
	effect.set_shader_parameter("cut_depths", depths)
	effect.set_shader_parameter("cut_edges_a", edges_a)
	effect.set_shader_parameter("cut_edges_b", edges_b)
	effect.set_shader_parameter("cut_wall_edges", wall_edges)
	effect.set_shader_parameter("cut_inverse", _inverse)
	effect.set_shader_parameter("cut_actor_feet", _feet)
	effect.set_shader_parameter("cut_radius", _radius)
	effect.set_shader_parameter("cut_opacity", opacity)
	effect.set_shader_parameter("cut_body_mask_enabled", _body_mask_enabled)
	effect.set_shader_parameter("cut_body_mask", _body_mask)
	effect.set_shader_parameter("cut_body_rect", _body_rect)

func report() -> Dictionary:
	return {"enabled": enabled, "body_requires_path": true, "wall_edges": Array(wall_edges), "contact_band_width_world": 0.035, "opacity": opacity, "target_keys": target_keys.duplicate(), "context": context.duplicate(), "build_ms": build_ms, "updates": update_count, "full_radius": FULL_RADIUS, "support_radius": OUTER_RADIUS, "shared_edge_aperture": true, "reveal_seconds": REVEAL_SECONDS, "opening_cells": _opening.size(), "path_inner": 0.65, "path_outer": 2.25, "body_mask": _body_mask_enabled, "foot_guard_inner": 0.78, "foot_guard_outer": 1.25, "body_inner": 0.57, "body_outer": 1.0, "blend": "body_path_screen_union", "method": "body cannot independently open walls; original authorized continuous path field is required; sprite restore retains body visibility"}

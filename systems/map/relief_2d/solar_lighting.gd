extends RefCounted
## Directional whitebox lighting for the existing Node2D projection.
## Vector3/Basis describe world geometry only; no 3D scene or engine lights.
## The sun_direction points toward the source. Shadows travel along -sun.
## Each receiver gets disjoint convex shadow polygons, suitable for one
## ambient-light overlay per polygon without cumulative overlap darkening.

const ACTOR_SHADOW_SCREEN_BIN := 128.0
const ACTOR_SHADOW_MAX_PIECE_BINS := 256
const ACTOR_SHADOW_MAX_INDEX_REFERENCES := 200000
const EPSILON := 0.00001
const AREA_EPSILON := 0.0001
const PIXEL_EPSILON := 0.001
const DEFAULT_SUN := Vector3(-0.6, 1.0, -0.8)
const SceneVolume = preload("res://systems/map/relief_2d/scene_volume.gd")

var _sun := DEFAULT_SUN.normalized()
var _ambient := 0.30
var _direct := 0.70
var _enabled := true
var _basis := Basis.IDENTITY
var _pixels := 60.0
var _radius := 1.0
var _bin_size := 2.0
var _light_u := Vector3.RIGHT
var _light_v := Vector3.FORWARD
var _casters: Array[Dictionary] = []
var _caster_bins: Dictionary = {}
var _receiver_bins: Dictionary = {}
var _cached_faces: Array = []
var _projection_cache: Dictionary = {}
var _receiver_cache: RefCounted
var _actor_shadow_piece_bounds: Dictionary = {}
var _actor_shadow_piece_bins: Dictionary = {}
var _actor_shadow_wide_pieces: Dictionary = {}
var _actor_shadow_index_references := 0
var _actor_shadow_wide_count := 0
var _actor_shadow_bounds_filter_enabled := true # Legacy-reference switch for tests.
var _actor_shadow_use_spatial_index := true
var _last_actor_shadow_report: Dictionary = {}
var _last_report: Dictionary = {}
var _scenery_caster_count := 0
var _support_skirt_caster_count := 0
var _volume_caster_count := 0


func _init() -> void:
	configure()


func configure(config: Dictionary = {}) -> Dictionary:
	var direction: Variant = config.get("sun_direction", DEFAULT_SUN)
	if not direction is Vector3 or not _finite3(direction) or direction.length_squared() < EPSILON * EPSILON or direction.y <= EPSILON:
		direction = DEFAULT_SUN
	_sun = (direction as Vector3).normalized()
	_ambient = clampf(_number(config.get("ambient", 0.30), 0.30), 0.0, 1.0)
	_direct = clampf(_number(config.get("direct", 0.70), 0.70), 0.0, 1.0 - _ambient)
	_enabled = bool(config.get("enabled", true))
	# A stable orthonormal frame indexes the set of parallel sunlight rays.
	var reference := Vector3.UP if absf(_sun.y) < 0.98 else Vector3.RIGHT
	_light_u = _sun.cross(reference).normalized()
	_light_v = _sun.cross(_light_u).normalized()
	_projection_cache.clear()
	_casters.clear()
	_caster_bins.clear()
	_receiver_bins.clear()
	_cached_faces = []
	_actor_shadow_piece_bounds.clear();_actor_shadow_piece_bins.clear();_actor_shadow_wide_pieces.clear()
	_actor_shadow_index_references=0;_actor_shadow_wide_count=0
	return _config_report()


func bake(snapshot: Dictionary, known: Dictionary, faces: Array, basis: Basis, pixels_per_world: float) -> Dictionary:
	var started := Time.get_ticks_usec()
	_basis = basis
	_pixels = maxf(EPSILON, _number(pixels_per_world, 60.0))
	_radius = maxf(0.01, _number(snapshot.get("outer_radius", 1.0), 1.0))
	_bin_size = maxf(0.1, 2.0 * _radius)
	_projection_cache.clear()
	_receiver_bins.clear()
	_cached_faces = faces
	_build_casters(snapshot, known)
	# A caster entirely behind the receiving plane cannot cast onto it. Cache
	# support boxes once, including generated perimeter solids and skirts.
	for caster: Dictionary in _casters:
		var low: Vector3 = caster.vertices[0]
		var high: Vector3 = low
		for vertex: Vector3 in caster.vertices:
			low = low.min(vertex); high = high.max(vertex)
		caster["support_low"] = low; caster["support_high"] = high
	var caster_geometry: Array=[]
	if _receiver_cache!=null:
		for caster: Dictionary in _casters:caster_geometry.append(_receiver_cache.caster_geometry_id([caster.key,caster.vertices,caster.edges]))
	var receiver_cache_hits:=0
	var receiver_count := 0
	var candidate_pairs := 0
	var clip_count := 0
	var projection_count := 0
	var shadow_regions := 0
	var invalid_faces := 0
	for face_index in faces.size():
		var face: Dictionary = faces[face_index]
		face["solar_factor"] = 1.0
		face["solar_shadows"] = []
		if not _enabled or not bool(face.get("known", false)):
			continue
		var world: Variant = face.get("world")
		var polygon: Variant = face.get("polygon")
		var normal: Variant = face.get("normal")
		if not world is PackedVector3Array or world.size() < 3 or not polygon is PackedVector2Array or polygon.size() < 3 or not normal is Vector3 or not _finite3(normal) or normal.length_squared() < EPSILON:
			invalid_faces += 1
			continue
		var valid := true
		for vertex: Vector3 in world:
			if not _finite3(vertex): valid = false
		for vertex: Vector2 in polygon:
			if not _finite2(vertex): valid = false
		if not valid:
			invalid_faces += 1
			continue
		var n: Vector3 = normal.normalized()
		var incidence := n.dot(_sun)
		face["solar_factor"] = _ambient + _direct * maxf(0.0, incidence)
		receiver_count += 1
		if incidence <= EPSILON:
			continue
		var receiver_polygon := _clean_polygon(polygon)
		if receiver_polygon.size() < 3:
			continue
		var light_bounds := _light_bounds(world)
		_index_bounds(_receiver_bins, light_bounds, face_index)
		var offset: float = n.dot(world[0])
		var plane_key := _plane_key(n, offset)
		if not _projection_cache.has(plane_key): _projection_cache[plane_key] = {}
		var cache: Dictionary = _projection_cache[plane_key]
		var candidate_indices: Array=[]
		for index in _query_bounds(_caster_bins,light_bounds):
			var caster: Dictionary=_casters[index]
			if String(caster.key)==String(face.get("key","")) or not light_bounds.intersects(caster.light_bounds,true):continue
			var low: Vector3=caster.support_low; var high: Vector3=caster.support_high
			var support:=Vector3(high.x if n.x>=0 else low.x,high.y if n.y>=0 else low.y,high.z if n.z>=0 else low.z)
			# Conservative margin retains borderline floating point contacts.
			if n.dot(support)<offset-EPSILON*4.0:continue
			candidate_indices.append(index)
		var signature: Array=[]
		if _receiver_cache!=null:
			var actual: Array=[]
			for index in candidate_indices:
				actual.append(caster_geometry[index])
			# This is the receiver's actual known-only ordered caster geometry,
			# not the map's future/all-known set or a face-id approximation.
			signature=[world,polygon,n,_sun,_ambient,_direct,_basis,_pixels,actual]
			var previous: Variant=_receiver_cache.find_shadows(signature)
			if previous!=null:
				face["solar_shadows"]=previous
				shadow_regions+=previous.size();receiver_cache_hits+=1
				continue
		var shadows: Array[PackedVector2Array] = []
		var shadow_bounds: Array[Rect2] = []
		var shadow_area:=0.0
		var face_bounds := _bounds(receiver_polygon)
		for caster_index in candidate_indices:
			var caster: Dictionary = _casters[caster_index]
			candidate_pairs += 1
			if not cache.has(caster_index):
				cache[caster_index] = _project_solid(caster, n, offset)
				projection_count += 1
			var projected: PackedVector2Array = cache[caster_index]
			if projected.size() < 3 or not face_bounds.intersects(_bounds(projected), true):
				continue
			clip_count += 1
			var overlap := _convex_intersection(projected, receiver_polygon)
			if overlap.size() < 3:
				continue
			var previous_count:=shadows.size()
			_append_disjoint(shadows, shadow_bounds, overlap)
			for index in range(previous_count,shadows.size()):shadow_area+=absf(_area(shadows[index]))
			# Once the full receiver is covered, further casters cannot change it.
			if shadow_area >= absf(_area(receiver_polygon)) - AREA_EPSILON:
				break
		face["solar_shadows"] = shadows
		if _receiver_cache!=null:_receiver_cache.store_shadows(signature,shadows)
		shadow_regions += shadows.size()
	# No dynamic query uses bake's caster-plane projection scratch.
	_projection_cache.clear()
	_index_actor_shadow_pieces(faces)
	_last_report = _config_report()
	_last_report.merge({"caster_count": _casters.size(), "scene_envelope_caster_count": _scenery_caster_count, "scene_support_skirt_caster_count": _support_skirt_caster_count, "scene_volume_caster_count": _volume_caster_count, "receiver_count": receiver_count, "receiver_cache_hits":receiver_cache_hits, "shadow_regions": shadow_regions, "candidate_pairs": candidate_pairs, "clip_count": clip_count, "projection_count": projection_count, "invalid_faces": invalid_faces, "bake_ms": float(Time.get_ticks_usec() - started) / 1000.0})
	return _last_report.duplicate(true)


func set_receiver_cache(cache: RefCounted) -> void:
	_receiver_cache=cache


func get_report() -> Dictionary:
	return _last_report.duplicate(true)


func is_shadowed(point: Vector3) -> bool:
	if not _enabled or not _finite3(point): return false
	var uv := _light_point(point)
	var bin := Vector2i(floori(uv.x / _bin_size), floori(uv.y / _bin_size))
	# The small sunward bias rejects t=0 contact with the support surface.
	var origin := point + _sun * EPSILON * 4.0
	for caster_index in _caster_bins.get(bin, []):
		var caster: Dictionary = _casters[caster_index]
		if caster.light_bounds.grow(EPSILON).has_point(uv) and _ray_hits_solid(origin, caster):
			return true
	return false


func lighting_at(point: Vector3, normal: Vector3 = Vector3.UP) -> float:
	if not _enabled: return 1.0
	if not _finite3(normal) or normal.length_squared() < EPSILON: return _ambient
	var incidence := maxf(0.0, normal.normalized().dot(_sun))
	return _ambient if incidence <= EPSILON or is_shadowed(point) else _ambient + _direct * incidence


func project_actor_shadow(center: Vector2, feet_height: float, actor_height: float, radius: float, faces: Array) -> Array[Dictionary]:
	var started := Time.get_ticks_usec()
	var all_pieces := 0
	var tested_pieces := 0
	var results: Array[Dictionary] = []
	if not _enabled or not _finite2(center) or not is_finite(feet_height) or not is_finite(actor_height) or not is_finite(radius) or actor_height <= EPSILON or radius <= EPSILON:
		return results
	var actor := _solid(center, feet_height, feet_height + actor_height, radius, "actor", 8)
	var light_bounds: Rect2 = actor.light_bounds
	var same_faces := is_same(_cached_faces, faces)
	var candidates: Array = _query_bounds(_receiver_bins, light_bounds) if same_faces else []
	# The normal runtime path uses bake's sunlight-space receiver index. A caller
	# supplying a different face array gets a safe uncached compatibility path.
	if not same_faces:
		for i in faces.size(): candidates.append(i)
	for face_index in candidates:
		var face: Dictionary = faces[face_index]
		if not bool(face.get("known", false)): continue
		var world: Variant = face.get("world")
		var normal: Variant = face.get("normal")
		var polygon: Variant = face.get("polygon")
		if not world is PackedVector3Array or world.size() < 3 or not normal is Vector3 or not _finite3(normal) or normal.length_squared() < EPSILON or not polygon is PackedVector2Array or polygon.size() < 3:
			continue
		var n: Vector3 = normal.normalized()
		if n.dot(_sun) <= EPSILON or not light_bounds.intersects(_light_bounds(world), true): continue
		var projected := _project_solid(actor, n, n.dot(world[0]))
		if projected.size() < 3: continue
		var overlap := _convex_intersection(projected, _clean_polygon(polygon))
		if overlap.size() < 3: continue
		# Terrain's ambient mask already removes this direct light. Remove that
		# covered area so dynamic actor shadows cannot darken it a second time.
		var pieces: Array[PackedVector2Array] = [overlap]
		var static_shadows: Array = face.get("solar_shadows", [])
		all_pieces+=static_shadows.size()
		var overlap_bounds := _bounds(overlap).grow(PIXEL_EPSILON)
		for shadow_index: int in _actor_shadow_candidates(face_index,overlap_bounds,static_shadows,same_faces):
			var existing: PackedVector2Array = static_shadows[shadow_index]
			tested_pieces+=1
			var next: Array[PackedVector2Array] = []
			for piece in pieces: next.append_array(_subtract_convex(piece, existing))
			pieces = next
			if pieces.is_empty(): break
		for piece in pieces:
			results.append({"polygon": piece, "key": String(face.get("key", "")), "face_index": face_index})
	_last_actor_shadow_report={"ms":(Time.get_ticks_usec()-started)/1000.0,"receiver_candidates":candidates.size(),"static_pieces":all_pieces,"static_candidates":tested_pieces,"output_pieces":results.size(),"same_faces":same_faces,"spatial_index":_actor_shadow_use_spatial_index and _actor_shadow_bounds_filter_enabled}
	return results


func get_actor_shadow_report() -> Dictionary:
	var report := _last_actor_shadow_report.duplicate()
	report.merge({"screen_bin_pixels":ACTOR_SHADOW_SCREEN_BIN,"index_references":_actor_shadow_index_references,"wide_pieces":_actor_shadow_wide_count,"index_reference_limit":ACTOR_SHADOW_MAX_INDEX_REFERENCES,"piece_bin_limit":ACTOR_SHADOW_MAX_PIECE_BINS})
	return report


func _index_actor_shadow_pieces(faces: Array) -> void:
	_actor_shadow_piece_bounds.clear();_actor_shadow_piece_bins.clear();_actor_shadow_wide_pieces.clear()
	_actor_shadow_index_references=0;_actor_shadow_wide_count=0
	for face_index in faces.size():
		var shadows: Array = faces[face_index].get("solar_shadows",[])
		if shadows.is_empty(): continue
		var bounds: Array[Rect2] = []
		var bins: Dictionary = {}
		var wide: Array[int] = []
		for index in shadows.size():
			var rect := _bounds(shadows[index]).grow(PIXEL_EPSILON)
			bounds.append(rect)
			var x0 := floori(rect.position.x/ACTOR_SHADOW_SCREEN_BIN)
			var x1 := floori(rect.end.x/ACTOR_SHADOW_SCREEN_BIN)
			var y0 := floori(rect.position.y/ACTOR_SHADOW_SCREEN_BIN)
			var y1 := floori(rect.end.y/ACTOR_SHADOW_SCREEN_BIN)
			var references := (x1-x0+1)*(y1-y0+1)
			if references>ACTOR_SHADOW_MAX_PIECE_BINS or _actor_shadow_index_references+references>ACTOR_SHADOW_MAX_INDEX_REFERENCES:
				wide.append(index);_actor_shadow_wide_count+=1;continue
			_actor_shadow_index_references+=references
			for x in range(x0,x1+1):
				for y in range(floori(rect.position.y/ACTOR_SHADOW_SCREEN_BIN),floori(rect.end.y/ACTOR_SHADOW_SCREEN_BIN)+1):
					var bin := Vector2i(x,y)
					if not bins.has(bin): bins[bin]=[]
					bins[bin].append(index)
		_actor_shadow_wide_pieces[face_index]=wide
		_actor_shadow_piece_bounds[face_index]=bounds
		_actor_shadow_piece_bins[face_index]=bins


func _actor_shadow_candidates(face_index: int, rectangle: Rect2, shadows: Array, same_faces: bool) -> Array:
	var indices: Array = []
	if _actor_shadow_bounds_filter_enabled and _actor_shadow_use_spatial_index and same_faces and _actor_shadow_piece_bins.has(face_index):
		var found: Dictionary = {}
		var bins: Dictionary = _actor_shadow_piece_bins[face_index]
		for index in _actor_shadow_wide_pieces.get(face_index,[]): found[index]=true
		for x in range(floori(rectangle.position.x/ACTOR_SHADOW_SCREEN_BIN),floori(rectangle.end.x/ACTOR_SHADOW_SCREEN_BIN)+1):
			for y in range(floori(rectangle.position.y/ACTOR_SHADOW_SCREEN_BIN),floori(rectangle.end.y/ACTOR_SHADOW_SCREEN_BIN)+1):
				for index in bins.get(Vector2i(x,y),[]): found[index]=true
		indices=found.keys();indices.sort()
	else:
		for index in shadows.size(): indices.append(index)
	if not _actor_shadow_bounds_filter_enabled: return indices
	var result: Array = []
	for index: int in indices:
		var bounds: Rect2 = _actor_shadow_piece_bounds[face_index][index] if same_faces and _actor_shadow_piece_bounds.has(face_index) else _bounds(shadows[index])
		if bounds.intersects(rectangle,true): result.append(index)
	return result


func _build_casters(snapshot: Dictionary, known: Dictionary) -> void:
	_casters.clear()
	_caster_bins.clear()
	_scenery_caster_count = 0
	_support_skirt_caster_count = 0
	_volume_caster_count = 0
	if not _enabled: return
	var quantum := maxf(0.001, _number(snapshot.get("height_quantum", 0.20), 0.20))
	var visible: Array[Dictionary] = []
	var base := 0.0
	var seen: Dictionary = {}
	for value in snapshot.get("cells", []):
		if not value is Dictionary: continue
		var cell: Dictionary = value
		var q := int(cell.get("q", 0))
		var r := int(cell.get("r", 0))
		var key := "%d,%d" % [q, r]
		# Match Session/renderer ownership exactly. Never read hidden elevation
		# or wall height into either a caster or the common terrain base.
		if not bool(known.get(key, false)) or seen.has(key): continue
		seen[key] = true
		var height := _number(cell.get("level", 0), 0.0) * quantum
		base = minf(base, height)
		visible.append({"key": key, "center": Vector2(1.5 * q, sqrt(3.0) * (r + q * 0.5)) * _radius, "height": height, "wall": String(cell.get("terrain", "ground")) == "wall", "wall_height": maxf(0.1, _number(cell.get("wall_height", 1.3), 1.3))})
	base -= 0.24
	for cell in visible:
		var top: float = cell.height + (cell.wall_height if cell.wall else 0.0)
		var solid := _solid(cell.center, base, top, _radius, cell.key, 6)
		var index := _casters.size()
		_casters.append(solid)
		_index_bounds(_caster_bins, solid.light_bounds, index)

	var volumes := SceneVolume.normalize(snapshot, known)
	if volumes.stats.enabled:
		for volume: Dictionary in volumes.volumes:
			var solid := SceneVolume.solid(volume)
			solid["light_bounds"] = _light_bounds(solid.vertices)
			var index := _casters.size()
			_casters.append(solid)
			_index_bounds(_caster_bins,solid.light_bounds,index)
			_volume_caster_count += 1
			_scenery_caster_count += 1
		return

	# Presentation-only prisms share renderer validation, ownership and reveal
	# rules. Their explicit world bottoms must never inherit terrain's base.
	var envelope := scene_envelope_cells(snapshot, known)
	for coordinate: String in envelope.cells:
		var cell: Dictionary = envelope.cells[coordinate]
		var center := Vector2(1.5 * cell.coord.x, sqrt(3.0) * (cell.coord.y + cell.coord.x * 0.5)) * _radius
		var solid := _solid(center, cell.bottom, cell.top, _radius, cell.key, 6)
		var index := _casters.size()
		_casters.append(solid)
		_index_bounds(_caster_bins, solid.light_bounds, index)
		_scenery_caster_count += 1
	for skirt: Dictionary in scene_support_skirts(snapshot, known, envelope.cells):
		var solid := _skirt_solid(skirt)
		var index := _casters.size()
		_casters.append(solid)
		_index_bounds(_caster_bins, solid.light_bounds, index)
		_support_skirt_caster_count += 1


static func scene_envelope_cells(snapshot: Dictionary, known: Dictionary) -> Dictionary:
	# Pure per-call normalization is safe on private geometry worker threads.
	# Neither caller mutates source data or uses extras as walkable support.
	var cells: Dictionary = {}
	var stats := {"enabled": false, "version": "", "input_cells": 0, "valid_cells": 0, "visible_cells": 0, "hidden_cells": 0, "invalid_cells": 0, "visible_roles": {"foundation": 0, "core": 0, "basin": 0}}
	var raw: Variant = snapshot.get("scene_envelope", {})
	if not raw is Dictionary or raw.get("version", "") != "scene-envelope-v1" or not raw.get("cells", []) is Array:
		return {"cells": cells, "stats": stats}
	stats.enabled = true
	stats.version = "scene-envelope-v1"
	stats.generator_stats = raw.get("stats", {}).duplicate(true) if raw.get("stats", {}) is Dictionary else {}
	var original: Dictionary = {}
	for value in snapshot.get("cells", []):
		if value is Dictionary: original["%d,%d" % [int(value.get("q", 0)), int(value.get("r", 0))]] = true
	var ids: Dictionary = {}
	var coordinates: Dictionary = {}
	stats.input_cells = raw.cells.size()
	for value in raw.cells:
		var valid := value is Dictionary
		if valid:
			for field in ["q", "r", "bottom", "top"]:
				var number: Variant = value.get(field)
				if (not number is int and not number is float) or not is_finite(float(number)):
					valid = false
			if not value.get("id") is String or String(value.get("id", "")).is_empty() or not value.get("group_id") is String or not value.get("role") is String or value.role not in ["foundation", "core", "basin"] or not value.get("reveal_keys") is Array:
				valid = false
		if not valid:
			stats.invalid_cells += 1
			continue
		var q := int(value.q)
		var r := int(value.r)
		var coordinate := "%d,%d" % [q, r]
		if float(q) != float(value.q) or float(r) != float(value.r) or float(value.top) <= float(value.bottom) + EPSILON or original.has(coordinate) or ids.has(value.id) or coordinates.has(coordinate):
			stats.invalid_cells += 1
			continue
		var visible: bool = not value.reveal_keys.is_empty()
		for key in value.reveal_keys:
			if not key is String or String(key).is_empty():
				valid = false
				break
			if not bool(known.get(key, false)): visible = false
		if not valid:
			stats.invalid_cells += 1
			continue
		ids[value.id] = true
		coordinates[coordinate] = true
		stats.valid_cells += 1
		if not visible:
			stats.hidden_cells += 1
			continue
		var cell: Dictionary = value.duplicate(true)
		cell.coord = Vector2i(q,r)
		cell.bottom = float(value.bottom)
		cell.top = float(value.top)
		cell.key = "scenery:" + String(value.id)
		cells[coordinate] = cell
		stats.visible_cells += 1
		stats.visible_roles[cell.role] += 1
	return {"cells": cells, "stats": stats}


static func scene_support_skirts(snapshot: Dictionary, known: Dictionary, scenery: Dictionary) -> Array[Dictionary]:
	# The old support slab stops at min(known elevation)-.24. Close only a
	# shared edge exposed by an explicitly visible, lower scenery top. This
	# adds vertical presentation faces, never floors or new support cells.
	var skirts: Array[Dictionary] = []
	if scenery.is_empty(): return skirts
	var quantum := maxf(0.001, float(snapshot.get("height_quantum", 0.20)))
	var radius := maxf(0.01, float(snapshot.get("outer_radius", 1.0)))
	var original: Dictionary = {}
	var base := 0.0
	for value in snapshot.get("cells", []):
		if not value is Dictionary: continue
		var coord := Vector2i(int(value.get("q", 0)), int(value.get("r", 0)))
		var key := "%d,%d" % [coord.x,coord.y]
		if not bool(known.get(key, false)) or original.has(key): continue
		original[key] = {"coord": coord, "level": float(value.get("level", 0))}
		base = minf(base, float(value.get("level", 0)) * quantum)
	base -= 0.24
	var neighbors := [Vector2i(1,0),Vector2i(0,1),Vector2i(-1,1),Vector2i(-1,0),Vector2i(0,-1),Vector2i(1,-1)]
	for key: String in original:
		var cell: Dictionary = original[key]
		var center := Vector2(1.5 * cell.coord.x, sqrt(3.0) * (cell.coord.y + cell.coord.x * 0.5)) * radius
		for edge in 6:
			var adjacent: Vector2i = cell.coord + neighbors[edge]
			var adjacent_key := "%d,%d" % [adjacent.x,adjacent.y]
			if not scenery.has(adjacent_key): continue
			var extra: Dictionary = scenery[adjacent_key]
			if float(extra.top) >= base - EPSILON: continue
			var a := center + Vector2(cos(TAU * edge / 6.0), sin(TAU * edge / 6.0)) * radius
			var b := center + Vector2(cos(TAU * (edge+1) / 6.0), sin(TAU * (edge+1) / 6.0)) * radius
			skirts.append({"a":a,"b":b,"bottom":float(extra.top),"top":base,"center":center,"key":"scenery:skirt:"+key+":"+str(edge),"role":"support_skirt","group_id":String(extra.group_id),"level":float(cell.level),"support_key":key,"adjacent_key":adjacent_key})
	return skirts


func _skirt_solid(skirt: Dictionary) -> Dictionary:
	# A finite, zero-thickness vertical rectangle is both the rendered surface
	# and caster. Opposed coincident planes retain exact ray hits without
	# inventing an unseen full-hex extension below the original terrain base.
	var a: Vector2 = skirt.a
	var b: Vector2 = skirt.b
	var vertices := PackedVector3Array([Vector3(a.x,skirt.bottom,a.y),Vector3(b.x,skirt.bottom,b.y),Vector3(b.x,skirt.top,b.y),Vector3(a.x,skirt.top,a.y)])
	var tangent := Vector3(b.x-a.x,0,b.y-a.y).normalized()
	var normal := Vector3(tangent.z,0,-tangent.x)
	var offset := normal.dot(vertices[0])
	var start := tangent.dot(vertices[0])
	var end := tangent.dot(vertices[1])
	var planes: Array[Plane] = [Plane(normal,offset),Plane(-normal,-offset),Plane(tangent,end),Plane(-tangent,-start),Plane(Vector3.UP,skirt.top),Plane(Vector3.DOWN,-skirt.bottom)]
	var edges: Array[Vector2i] = [Vector2i(0,1),Vector2i(1,2),Vector2i(2,3),Vector2i(3,0)]
	return {"key":skirt.key,"vertices":vertices,"edges":edges,"planes":planes,"light_bounds":_light_bounds(vertices)}


func _solid(center: Vector2, bottom: float, top: float, radius: float, key: String, sides: int) -> Dictionary:
	var vertices := PackedVector3Array()
	var edges: Array[Vector2i] = []
	var planes: Array[Plane] = [Plane(Vector3.UP, top), Plane(Vector3.DOWN, -bottom)]
	for height in [bottom, top]:
		for i in sides:
			var angle := TAU * float(i) / sides
			vertices.append(Vector3(center.x + cos(angle) * radius, height, center.y + sin(angle) * radius))
	for i in sides:
		edges.append(Vector2i(i, (i + 1) % sides))
		edges.append(Vector2i(i + sides, (i + 1) % sides + sides))
		edges.append(Vector2i(i, i + sides))
		var angle := TAU * (float(i) + 0.5) / sides
		var n := Vector3(cos(angle), 0, sin(angle))
		planes.append(Plane(n, n.dot(Vector3(center.x, 0, center.y)) + radius * cos(PI / sides)))
	return {"key": key, "vertices": vertices, "edges": edges, "planes": planes, "light_bounds": _light_bounds(vertices)}


func _project_solid(solid: Dictionary, normal: Vector3, offset: float) -> PackedVector2Array:
	var denominator := normal.dot(_sun)
	if denominator <= EPSILON: return PackedVector2Array()
	var vertices: PackedVector3Array = solid.vertices
	var clipped := PackedVector3Array()
	var distances := PackedFloat64Array()
	for vertex in vertices:
		var distance := normal.dot(vertex) - offset - EPSILON
		distances.append(distance)
		if distance >= 0.0: clipped.append(vertex)
	# Intersections of all original prism edges with the positive-depth plane
	# complete the vertices of the clipped convex solid, including back sides.
	for edge: Vector2i in solid.edges:
		var a := distances[edge.x]
		var b := distances[edge.y]
		if (a < 0.0 and b > 0.0) or (a > 0.0 and b < 0.0):
			clipped.append(vertices[edge.x].lerp(vertices[edge.y], a / (a - b)))
	var projected := PackedVector2Array()
	for vertex in clipped:
		var point := vertex - _sun * ((normal.dot(vertex) - offset) / denominator)
		var screen := Vector2(point.dot(_basis.x), -point.dot(_basis.y)) * _pixels
		if _finite2(screen): projected.append(screen)
	if projected.size() < 3: return PackedVector2Array()
	return _clean_polygon(Geometry2D.convex_hull(projected))


func _ray_hits_solid(origin: Vector3, solid: Dictionary) -> bool:
	var enter := 0.0
	var leave := INF
	for plane: Plane in solid.planes:
		var denominator := plane.normal.dot(_sun)
		var numerator := plane.d - plane.normal.dot(origin)
		if absf(denominator) <= EPSILON:
			if numerator < -EPSILON: return false
			continue
		var distance := numerator / denominator
		if denominator > 0.0: leave = minf(leave, distance)
		else: enter = maxf(enter, distance)
		if leave < enter: return false
	return leave > EPSILON and leave >= enter


func _append_disjoint(regions: Array[PackedVector2Array], bounds: Array[Rect2], polygon: PackedVector2Array) -> void:
	var pieces: Array[PackedVector2Array] = [polygon]
	var piece_bounds: Array[Rect2]=[_bounds(polygon)]
	# Every fragment remains inside the incoming polygon. Rejecting a region
	# against its conservative outer bounds avoids repeated pass-through arrays.
	var incoming_bounds: Rect2=piece_bounds[0].grow(PIXEL_EPSILON)
	for i in regions.size():
		if not incoming_bounds.intersects(bounds[i].grow(PIXEL_EPSILON),true):continue
		var next: Array[PackedVector2Array] = []
		var next_bounds: Array[Rect2]=[]
		for index in pieces.size():
			if not piece_bounds[index].intersects(bounds[i],true):
				next.append(pieces[index]);next_bounds.append(piece_bounds[index])
			else:
				for part: PackedVector2Array in _subtract_convex(pieces[index],regions[i]):
					next.append(part);next_bounds.append(_bounds(part))
		pieces = next;piece_bounds=next_bounds
		if pieces.is_empty(): return
	for index in pieces.size():
		regions.append(pieces[index]);bounds.append(piece_bounds[index])


func _subtract_convex(subject: PackedVector2Array, cutter: PackedVector2Array) -> Array[PackedVector2Array]:
	# Each outside slice is emitted once; the inside remainder advances through
	# the cutter's halfspaces. This avoids boolean polygons with hole rings.
	var result: Array[PackedVector2Array] = []
	var remainder := subject
	var orientation := 1.0 if _area(cutter) >= 0.0 else -1.0
	for i in cutter.size():
		var a := cutter[i]
		var b := cutter[(i + 1) % cutter.size()]
		var split := _split_halfspace(remainder, a, b, orientation)
		if split[0].size() >= 3: result.append(split[0])
		remainder = split[1]
		if remainder.size() < 3: break
	return result


func _convex_intersection(subject: PackedVector2Array, clip: PackedVector2Array) -> PackedVector2Array:
	var result := subject
	var orientation := 1.0 if _area(clip) >= 0.0 else -1.0
	for i in clip.size():
		result = _clip_halfspace(result, clip[i], clip[(i + 1) % clip.size()], orientation, true)
		if result.size() < 3: return PackedVector2Array()
	return result


func _split_halfspace(polygon: PackedVector2Array, a: Vector2, b: Vector2, orientation: float) -> Array[PackedVector2Array]:
	# Subtraction needs both halves of the same edge. Classify each vertex
	# once, preserving each half's inclusive zero boundary, intersection math
	# and cleanup order from the two independent reference clipping calls.
	var outside := PackedVector2Array()
	var inside := PackedVector2Array()
	if polygon.size() < 3: return [outside,inside]
	var edge := b-a
	var previous := polygon[polygon.size()-1]
	var previous_distance := edge.cross(previous-a)*orientation
	for current in polygon:
		var distance := edge.cross(current-a)*orientation
		if (previous_distance <= 0.0) != (distance <= 0.0):
			outside.append(previous.lerp(current, -previous_distance / (-previous_distance + distance)))
		if distance <= 0.0: outside.append(current)
		if (previous_distance >= 0.0) != (distance >= 0.0):
			inside.append(previous.lerp(current, previous_distance / (previous_distance-distance)))
		if distance >= 0.0: inside.append(current)
		previous=current;previous_distance=distance
	return [_clean_polygon(outside),_clean_polygon(inside)]


func _clip_halfspace(polygon: PackedVector2Array, a: Vector2, b: Vector2, orientation: float, inside: bool) -> PackedVector2Array:
	if polygon.size() < 3: return PackedVector2Array()
	var result := PackedVector2Array()
	var multiplier := orientation if inside else -orientation
	var edge := b-a
	var previous := polygon[polygon.size() - 1]
	var previous_distance := edge.cross(previous - a) * multiplier
	for current in polygon:
		var distance := edge.cross(current - a) * multiplier
		var previous_in := previous_distance >= 0.0
		var current_in := distance >= 0.0
		if previous_in != current_in:
			result.append(previous.lerp(current, previous_distance / (previous_distance - distance)))
		if current_in: result.append(current)
		previous = current
		previous_distance = distance
	return _clean_polygon(result)


func _clean_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	if polygon.size() < 3: return PackedVector2Array()
	var result := PackedVector2Array()
	for point in polygon:
		if result.is_empty() or result[result.size() - 1].distance_squared_to(point) > PIXEL_EPSILON * PIXEL_EPSILON:
			result.append(point)
	if result.size() > 1 and result[0].distance_squared_to(result[result.size() - 1]) <= PIXEL_EPSILON * PIXEL_EPSILON:
		result.resize(result.size() - 1)
	# Vector2 stores 32-bit components in the standard engine build. Repeated
	# intersections can leave coincident or almost collinear vertices that the
	# Canvas triangulator cannot consume. Remove subpixel middle vertices.
	var changed := true
	while changed and result.size() >= 3:
		changed = false
		for i in result.size():
			var previous := result[(i + result.size() - 1) % result.size()]
			var next := result[(i + 1) % result.size()]
			var span := next - previous
			if span.length_squared() <= PIXEL_EPSILON * PIXEL_EPSILON or absf(span.cross(result[i] - previous)) <= PIXEL_EPSILON * span.length():
				result.remove_at(i)
				changed = true
				break
	return result if result.size() >= 3 and absf(_area(result)) > AREA_EPSILON else PackedVector2Array()


func _light_point(point: Vector3) -> Vector2:
	return Vector2(point.dot(_light_u), point.dot(_light_v))


func _light_bounds(vertices: PackedVector3Array) -> Rect2:
	var points := PackedVector2Array()
	for vertex in vertices: points.append(_light_point(vertex))
	return _bounds(points).grow(EPSILON)


func _index_bounds(index: Dictionary, bounds: Rect2, value: int) -> void:
	for x in range(floori(bounds.position.x / _bin_size), floori(bounds.end.x / _bin_size) + 1):
		for y in range(floori(bounds.position.y / _bin_size), floori(bounds.end.y / _bin_size) + 1):
			var bin := Vector2i(x, y)
			if not index.has(bin): index[bin] = []
			index[bin].append(value)


func _query_bounds(index: Dictionary, bounds: Rect2) -> Array:
	var found: Dictionary = {}
	for x in range(floori(bounds.position.x / _bin_size), floori(bounds.end.x / _bin_size) + 1):
		for y in range(floori(bounds.position.y / _bin_size), floori(bounds.end.y / _bin_size) + 1):
			for value in index.get(Vector2i(x, y), []): found[value] = true
	var values := found.keys()
	values.sort()
	return values


func _bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty(): return Rect2()
	var result := Rect2(points[0], Vector2.ZERO)
	for point in points: result = result.expand(point)
	return result


func _area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3: return 0.0
	var result := 0.0
	# Translate before crossing so large screen origins cannot manufacture area
	# through float cancellation in an otherwise degenerate sliver.
	var origin := polygon[0]
	for i in range(1, polygon.size() - 1): result += (polygon[i] - origin).cross(polygon[i + 1] - origin)
	return result * 0.5


func _regions_area(regions: Array[PackedVector2Array]) -> float:
	var result := 0.0
	for polygon in regions: result += absf(_area(polygon))
	return result


func _plane_key(normal: Vector3, offset: float) -> PackedByteArray:
	# Rounded decimal planes alias distinct float32 normals. The first face
	# then changes later shadows, making shared caches depend on worker order.
	# Exact plane identity keeps bake outputs a function of their full inputs.
	return var_to_bytes([normal,offset])


func _config_report() -> Dictionary:
	return {"enabled": _enabled, "sun_direction": [_sun.x, _sun.y, _sun.z], "ambient": _ambient, "direct": _direct}


func _number(value: Variant, fallback: float) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else fallback


func _finite2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func _finite3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

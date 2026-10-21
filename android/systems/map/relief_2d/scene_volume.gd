extends RefCounted
## Pure CPU normalization for presentation-only convex volumes. Renderer and
## sunlight use the same world vertices and planes; no support/gameplay writes.
const VERSION := "scene-envelope-v2"
const EPSILON := 0.00001
const ROLES := ["site", "foundation", "core", "basin", "buttress"]


static func normalize(snapshot: Dictionary, known: Dictionary) -> Dictionary:
	var volumes: Array[Dictionary] = []
	var stats := {"enabled": false, "version": "", "input_volumes": 0, "valid_volumes": 0, "visible_volumes": 0, "hidden_volumes": 0, "invalid_volumes": 0, "visible_roles": {"site": 0, "foundation": 0, "core": 0, "basin": 0, "buttress": 0}, "sloped_volumes": 0, "footprint_vertices": 0}
	var raw: Variant = snapshot.get("scene_envelope")
	if not raw is Dictionary or raw.get("version") != VERSION:
		return {"volumes": volumes, "stats": stats}
	stats.enabled = true
	stats.version = VERSION
	stats.generator_stats = raw.get("stats", {}).duplicate(true) if raw.get("stats", {}) is Dictionary else {}
	if not raw.get("volumes") is Array:
		stats["invalid_envelope"] = true
		return {"volumes": volumes, "stats": stats}
	var original: Dictionary = {}
	var known_min := 0.0
	var quantum := maxf(.001,float(snapshot.get("height_quantum",.2)))
	for value in snapshot.get("cells", []):
		if not value is Dictionary: continue
		var key := "%d,%d" % [int(value.get("q",0)),int(value.get("r",0))]
		if original.has(key): continue
		original[key] = true
		# Match the original slab: hidden elevations never enter its base.
		if bool(known.get(key,false)): known_min=minf(known_min,float(value.get("level",0))*quantum)
	stats["known_min_height"] = known_min
	var ids: Dictionary = {}
	stats.input_volumes = raw.volumes.size()
	for value in raw.volumes:
		var volume := _normalize_volume(value, original, known_min)
		if volume.is_empty() or ids.has(volume.id):
			stats.invalid_volumes += 1
			continue
		ids[volume.id] = true
		stats.valid_volumes += 1
		var visible := true
		for key in volume.reveal_keys:
			if not bool(known.get(key, false)): visible = false
		if not visible:
			stats.hidden_volumes += 1
			continue
		volumes.append(volume)
		stats.visible_volumes += 1
		stats.visible_roles[volume.role] += 1
		stats.footprint_vertices += volume.footprint.size()
		if absf(volume.top_plane.x) > EPSILON or absf(volume.top_plane.y) > EPSILON: stats.sloped_volumes += 1
	return {"volumes": volumes, "stats": stats}


static func _normalize_volume(value: Variant, original: Dictionary, known_min: float = 0.0) -> Dictionary:
	if not value is Dictionary: return {}
	for field in ["id", "group_id", "role"]:
		if not value.get(field) is String or String(value[field]).is_empty(): return {}
	if value.role not in ROLES or not _number(value.get("bottom")) or not _number(value.get("top")): return {}
	if not value.get("reveal_keys") is Array or value.reveal_keys.is_empty(): return {}
	for key in value.reveal_keys:
		if not key is String or not original.has(key): return {}
	var raw: Variant = value.get("footprint")
	if not raw is Array or raw.size() < 3 or raw.size() > 12: return {}
	var hull := PackedVector2Array()
	for pair in raw:
		if not pair is Array or pair.size() != 2 or not _number(pair[0]) or not _number(pair[1]): return {}
		var point := Vector2(float(pair[0]), float(pair[1]))
		if not is_finite(point.x) or not is_finite(point.y): return {}
		for previous in hull:
			if previous.distance_squared_to(point) <= EPSILON * EPSILON: return {}
		hull.append(point)
	# Every vertex must lie in every CCW edge's left halfspace. Unlike a
	# signed-turn-only test, this also rejects self-crossing star polygons.
	var area := 0.0
	for i in hull.size():
		var edge := hull[(i+1)%hull.size()] - hull[i]
		if edge.length_squared() <= EPSILON * EPSILON: return {}
		for j in hull.size():
			if edge.cross(hull[j]-hull[i]) < -EPSILON: return {}
		if i > 0 and i < hull.size()-1: area += (hull[i]-hull[0]).cross(hull[i+1]-hull[0])
	if not is_finite(area) or area <= EPSILON: return {}
	# Remove redundant collinear vertices once, before faces/casters are built.
	var clean := PackedVector2Array()
	for i in hull.size():
		if absf((hull[i]-hull[(i-1+hull.size())%hull.size()]).cross(hull[(i+1)%hull.size()]-hull[i])) > EPSILON: clean.append(hull[i])
	if clean.size() < 3: return {}
	var plane := Vector3(0,0,float(value.top))
	if value.has("top_plane"):
		var raw_plane: Variant = value.top_plane
		if not raw_plane is Array or raw_plane.size() != 3: return {}
		for number in raw_plane:
			if not _number(number): return {}
		plane = Vector3(float(raw_plane[0]),float(raw_plane[1]),float(raw_plane[2]))
	var top := float(value.top)
	if value.has("top_from_known_min"):
		if not _number(value.top_from_known_min): return {}
		top = known_min + float(value.top_from_known_min)
		plane.z = top
	var bottom := float(value.bottom)
	if value.has("bottom_from_known_min"):
		if not _number(value.bottom_from_known_min): return {}
		bottom = known_min + float(value.bottom_from_known_min)
	if not is_finite(Vector2(bottom,0).x): return {}
	var heights := PackedFloat32Array()
	var center := Vector2.ZERO
	var minimum := INF
	var maximum := -INF
	for point in clean:
		var height := plane.x*point.x+plane.y*point.y+plane.z
		if not is_finite(height) or height <= bottom + EPSILON: return {}
		heights.append(height)
		minimum = minf(minimum,height);maximum = maxf(maximum,height)
		center += point
	var normal := Vector3(-plane.x,1,-plane.y).normalized()
	return {"id":String(value.id), "group_id":String(value.group_id), "role":String(value.role), "key":"scenery:volume:"+String(value.id), "footprint":clean, "bottom":bottom, "top":top, "top_plane":plane, "top_heights":heights, "top_normal":normal, "top_min":minimum, "top_max":maximum, "center":center/clean.size(), "reveal_keys":value.reveal_keys.duplicate(true)}


static func solid(volume: Dictionary) -> Dictionary:
	var hull: PackedVector2Array = volume.footprint
	var heights: PackedFloat32Array = volume.top_heights
	var count := hull.size()
	var vertices := PackedVector3Array()
	var edges: Array[Vector2i] = []
	var normal: Vector3 = volume.top_normal
	var planes: Array[Plane] = [Plane(normal, normal.dot(Vector3(hull[0].x,heights[0],hull[0].y))), Plane(Vector3.DOWN,-float(volume.bottom))]
	for point in hull: vertices.append(Vector3(point.x,volume.bottom,point.y))
	for i in count: vertices.append(Vector3(hull[i].x,heights[i],hull[i].y))
	for i in count:
		var next := (i+1)%count
		edges.append(Vector2i(i,next));edges.append(Vector2i(i+count,next+count));edges.append(Vector2i(i,i+count))
		var outward := edge_normal(hull,i)
		planes.append(Plane(outward,outward.dot(vertices[i])))
	return {"key":volume.key,"vertices":vertices,"edges":edges,"planes":planes}


static func edge_normal(hull: PackedVector2Array, index: int) -> Vector3:
	var edge := hull[(index+1)%hull.size()] - hull[index]
	return Vector3(edge.y,0,-edge.x).normalized()


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func original_solids(snapshot: Dictionary, known: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var quantum := maxf(.001,float(snapshot.get("height_quantum",.2)))
	var radius := maxf(.01,float(snapshot.get("outer_radius",1.0)))
	var cells: Dictionary = {}
	var base := 0.0
	for cell in snapshot.get("cells",[]):
		if not cell is Dictionary:continue
		var key := "%d,%d" % [int(cell.get("q",0)),int(cell.get("r",0))]
		if cells.has(key) or not bool(known.get(key,false)):continue
		cells[key]=cell
		base=minf(base,float(cell.get("level",0))*quantum)
	base-=.24
	for key: String in cells:
		var cell: Dictionary = cells[key]
		var center := Vector2(1.5*int(cell.get("q",0)),sqrt(3.0)*(int(cell.get("r",0))+int(cell.get("q",0))*.5))*radius
		var hull := PackedVector2Array()
		for i in 6:hull.append(center+Vector2(cos(TAU*i/6.0),sin(TAU*i/6.0))*radius)
		var top := float(cell.get("level",0))*quantum
		if String(cell.get("terrain","ground"))=="wall":top+=maxf(.1,float(cell.get("wall_height",1.3)))
		var heights := PackedFloat32Array()
		for i in 6:heights.append(top)
		var volume := {"footprint":hull,"bottom":base,"top_heights":heights,"top_normal":Vector3.UP,"key":key}
		var row := solid(volume);row["scenery"]=false;output.append(row)
	return output

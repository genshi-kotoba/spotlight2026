extends RefCounted
## Exact convex-surface subtraction in world coordinates. This is CPU-only
## geometry preparation; it neither changes support data nor draws anything.
const EPSILON := 0.00001
const BIN := 5.0
var solids: Array[Dictionary] = []
var bins: Dictionary = {}
var shared_site_sides: Dictionary = {}
var stats := {"candidate_solids":0,"plane_splits":0,"buried_faces":0,"shared_site_sides":0,"input_faces":0,"output_faces":0}


func prepare(next_solids: Array[Dictionary], volumes: Array[Dictionary]) -> void:
	solids = next_solids
	bins.clear();shared_site_sides.clear()
	for i in solids.size():
		var solid: Dictionary = solids[i]
		var vertices: PackedVector3Array = solid.vertices
		var low := vertices[0]
		var high := vertices[0]
		for point in vertices:
			low=low.min(point);high=high.max(point)
		solid["low"] = low;solid["high"] = high
		for x in range(floori(low.x/BIN),floori(high.x/BIN)+1):
			for z in range(floori(low.z/BIN),floori(high.z/BIN)+1):
				var key := Vector2i(x,z)
				if not bins.has(key): bins[key]=[]
				bins[key].append(i)
	var edges: Dictionary = {}
	for volume in volumes:
		if volume.role != "site": continue
		var hull: PackedVector2Array = volume.footprint
		for edge in hull.size():
			var next := (edge+1)%hull.size()
			var a := hull[edge];var b := hull[next]
			var a_key := "%.5f:%.5f" % [a.x,a.y]
			var b_key := "%.5f:%.5f" % [b.x,b.y]
			var key := (a_key+"/"+b_key if a_key<b_key else b_key+"/"+a_key)
			var row := {"a":a,"b":b,"lo":float(volume.bottom),"ha":float(volume.top_heights[edge]),"hb":float(volume.top_heights[next]),"key":String(volume.key)+"/"+str(edge)}
			for other: Dictionary in edges.get(key,[]):
				if a.distance_to(other.b)<=EPSILON and b.distance_to(other.a)<=EPSILON and absf(row.lo-other.lo)<=EPSILON and absf(row.ha-other.hb)<=EPSILON and absf(row.hb-other.ha)<=EPSILON:
					shared_site_sides[row.key]=true;shared_site_sides[other.key]=true
			if not edges.has(key): edges[key]=[]
			edges[key].append(row)


func clip(face: Dictionary) -> Array[PackedVector3Array]:
	stats.input_faces += 1
	var world: PackedVector3Array = face.world
	if bool(face.get("scenery",false)) and not bool(face.top) and shared_site_sides.has(String(face.key)+"/"+str(face.get("scene_edge",-1))):
		stats.shared_site_sides += 1;stats.buried_faces += 1
		return []
	var low := world[0];var high := world[0]
	for point in world: low=low.min(point);high=high.max(point)
	var found: Dictionary = {}
	for x in range(floori(low.x/BIN),floori(high.x/BIN)+1):
		for z in range(floori(low.z/BIN),floori(high.z/BIN)+1):
			for index in bins.get(Vector2i(x,z),[]):found[index]=true
	var candidates := found.keys();candidates.sort()
	var pieces: Array[PackedVector3Array] = [world]
	for index in candidates:
		var solid: Dictionary = solids[index]
		if String(solid.key)==String(face.key):continue
		if not bool(face.get("scenery",false)) and not bool(solid.get("scenery",false)):continue
		if not _overlap(low,high,solid.low,solid.high):continue
		# Same-facing coplanar overlap belongs to one stable owner. Preserve
		# original surfaces first; new volumes use their unique lexical keys.
		var same_plane := false
		for plane: Plane in solid.planes:
			if (face.normal as Vector3).dot(plane.normal) < 0.99999:continue
			var coplanar := true
			for point in world:
				if absf(plane.distance_to(point)) > EPSILON:coplanar=false;break
			if coplanar:same_plane=true;break
		if same_plane and _owns_coplanar(face,solid):continue
		stats.candidate_solids += 1
		var remaining: Array[PackedVector3Array] = []
		for piece in pieces:remaining.append_array(_subtract(piece,solid.planes))
		pieces=remaining
		if pieces.is_empty():break
	if pieces.is_empty():stats.buried_faces += 1
	stats.output_faces += pieces.size()
	return pieces


func _owns_coplanar(face: Dictionary, solid: Dictionary) -> bool:
	var a := bool(face.get("scenery",false))
	var b := bool(solid.get("scenery",false))
	if a != b:return not a
	return String(face.key)<String(solid.key)


func _subtract(polygon: PackedVector3Array, planes: Array) -> Array[PackedVector3Array]:
	# Reject disjoint halfspaces before creating fragments. Faces in contact
	# with an opposite-facing boundary are deliberately considered internal.
	for plane: Plane in planes:
		var outside := true
		for point in polygon:
			if plane.distance_to(point)<=EPSILON:outside=false;break
		if outside:return [polygon]
	var output: Array[PackedVector3Array] = []
	var inside := polygon
	for plane: Plane in planes:
		var outside := _halfspace(inside,plane,false)
		if outside.size()>=3:output.append(outside)
		inside=_halfspace(inside,plane,true)
		# Empty final intersection means subtraction changed no area. Keep
		# the original convex face instead of needless exterior fragments.
		if inside.is_empty():return [polygon]
	return output


func _halfspace(polygon: PackedVector3Array, plane: Plane, inside: bool) -> PackedVector3Array:
	if polygon.size()<3:return PackedVector3Array()
	if not inside:
		var has_outside := false
		for point in polygon:
			if plane.distance_to(point)>EPSILON:has_outside=true;break
		if not has_outside:return PackedVector3Array()
	var output := PackedVector3Array()
	var previous := polygon[-1]
	var before := plane.distance_to(previous)*(-1.0 if inside else 1.0)
	if absf(before)<=EPSILON:before=0.0
	for point in polygon:
		var value := plane.distance_to(point)*(-1.0 if inside else 1.0)
		if absf(value)<=EPSILON:value=0.0
		if (value>=0.0)!=(before>=0.0):
			output.append(previous.lerp(point,before/(before-value)))
			stats.plane_splits += 1
		if value>=0.0:output.append(point)
		previous=point;before=value
	return _clean(output)


static func _clean(polygon: PackedVector3Array) -> PackedVector3Array:
	var clean := PackedVector3Array()
	for point in polygon:
		if clean.is_empty() or clean[-1].distance_squared_to(point)>EPSILON*EPSILON:clean.append(point)
	if clean.size()>1 and clean[0].distance_squared_to(clean[-1])<=EPSILON*EPSILON:clean.remove_at(clean.size()-1)
	if clean.size()<3:return PackedVector3Array()
	var area := Vector3.ZERO
	for i in range(1,clean.size()-1):area+=(clean[i]-clean[0]).cross(clean[i+1]-clean[0])
	return clean if area.length_squared()>EPSILON*EPSILON else PackedVector3Array()


static func _overlap(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> bool:
	return a.x<=d.x+EPSILON and c.x<=b.x+EPSILON and a.y<=d.y+EPSILON and c.y<=b.y+EPSILON and a.z<=d.z+EPSILON and c.z<=b.z+EPSILON

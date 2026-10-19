extends RefCounted
## CPU-only visibility cache. The unknown world is never rendered beneath it.
## Feathering extends inward from the union of known support footprints.
const DARK := Color("0c141e")
var enabled := false
var bounds := Rect2(-60,-60,120,120)
var width := 0.75
var cache_ms := 0.0
var build_count := 0
var _known: Dictionary = {}
var _segments: Array = []
var _bins: Dictionary = {}
var _site_tiles: Dictionary = {}
var _site_regions: Dictionary = {}
var _site_region_bounds: Dictionary = {}
var _radius := 1.0
var _bin_size := 2.0

func configure(source, value: bool) -> void:
	var start := Time.get_ticks_usec()
	enabled=value;_known.clear();_segments.clear();_bins.clear();_site_tiles.clear();_site_regions.clear();_site_region_bounds.clear()
	_radius=source._radius;width=.75*_radius;_bin_size=2.0*_radius
	for key in source._known:
		if source._known[key] and source._cells.has(key): _known[key]=true
	if enabled:
		var neighbors: Array[Vector2i] = []
		for edge in 6: neighbors.append(source._neighbor(Vector2i.ZERO,edge))
		for key in _known:
			var coord: Vector2i = source._cells[key].coord
			_site_tiles[coord]=true
			for direction: Vector2i in source.DIRS:
				_site_tiles[coord+direction]=true
				for second: Vector2i in source.DIRS: _site_tiles[coord+direction+second]=true
			var corners: PackedVector2Array = source._hex_polygon(source.hex_plane(coord),_radius)
			for edge in 6:
				if _known.has(source._key(coord+neighbors[edge])): continue
				var a := corners[edge]
				var b := corners[(edge+1)%6]
				var index := _segments.size()
				_segments.append([a,b])
				var rect := Rect2(a,Vector2.ZERO).expand(b).grow(2.0*_radius)
				for x in range(floori(rect.position.x/_bin_size),floori(rect.end.x/_bin_size)+1):
					for y in range(floori(rect.position.y/_bin_size),floori(rect.end.y/_bin_size)+1):
						var bin := Vector2i(x,y)
						if not _bins.has(bin): _bins[bin]=[]
						_bins[bin].append(index)
	if enabled:
		for face: Dictionary in source._faces:
			if face.get("scene_role","")!="site": continue
			var pieces: Array[PackedVector2Array] = []
			var world_bounds := Rect2()
			for i in face.world.size():
				var world: Vector3 = face.world[i]
				var point := Vector2(world.x,world.z)
				world_bounds=Rect2(point,Vector2.ZERO) if i==0 else world_bounds.expand(point)
			var q_low := floori(world_bounds.position.x/(1.5*_radius))-1
			var q_high := ceili(world_bounds.end.x/(1.5*_radius))+1
			var r_low := floori(world_bounds.position.y/(sqrt(3.0)*_radius)-q_high*.5)-1
			var r_high := ceili(world_bounds.end.y/(sqrt(3.0)*_radius)-q_low*.5)+1
			var candidates: Array[Vector2i] = []
			for q in range(q_low,q_high+1):
				for r in range(r_low,r_high+1):
					var coord := Vector2i(q,r)
					if _site_tiles.has(coord): candidates.append(coord)
			for coord: Vector2i in candidates:
				var center: Vector2 = source.hex_plane(coord)
				if not world_bounds.grow(.001).intersects(Rect2(center-Vector2.ONE*_radius,Vector2.ONE*2.0*_radius),true): continue
				var clipped := _clip_planar(source,face,face.polygon,source._hex_polygon(center,_radius))
				if clipped.size()>=3 and absf(source._signed_area(clipped))>.001: pieces.append(clipped)
			_site_regions[face.polygon]=pieces
			var piece_bounds: Array[Rect2]=[]
			for piece: PackedVector2Array in pieces: piece_bounds.append(source._polygon_bounds(piece).grow(.001))
			_site_region_bounds[face.polygon]=piece_bounds
	var has_bounds := false
	for face: Dictionary in source._faces:
		if not face.known or face.get("scenery",false): continue
		bounds=bounds.merge(face.bounds) if has_bounds else face.bounds
		has_bounds=true
	if has_bounds:
		bounds=bounds.grow(24.0)
		bounds.position.y-=source.ACTOR_HEIGHT*source.PIXELS_PER_WORLD
		bounds.size.y+=source.ACTOR_HEIGHT*source.PIXELS_PER_WORLD
	else: bounds=Rect2(-60,-60,120,120)
	build_count+=1;cache_ms=(Time.get_ticks_usec()-start)/1000.0

func visibility(point: Vector2) -> float:
	if not enabled: return 1.0
	# Evaluate the planar cell without inspecting any hidden cell data.
	var q := point.x/(1.5*_radius)
	var r := point.y/(sqrt(3.0)*_radius)-q*.5
	var x := roundi(q);var z := roundi(r);var y := roundi(-q-r)
	var dx := absf(x-q);var dz := absf(z-r);var dy := absf(y+q+r)
	if dx>dy and dx>dz: x=-y-z
	elif dz>dy: z=-x-y
	# At a shared polygon vertex, rounding may choose the unknown neighbor.
	# Distance to a boundary is zero there in either case, so this is stable.
	if not _known.has("%d,%d"%[x,z]): return 0.0
	return smoothstep(0.0,width,_boundary_distance(point,width))

func site_visibility(source, point: Vector2) -> float:
	if _known.has(source._key(source._plane_coord(point))): return 1.0
	return 1.0-smoothstep(0.0,2.0*_radius,_boundary_distance(point,2.0*_radius))

func _boundary_distance(point: Vector2, maximum: float) -> float:
	var distance := maximum
	for index in _bins.get(Vector2i(floori(point.x/_bin_size),floori(point.y/_bin_size)),[]):
		var segment: Array = _segments[index]
		var a: Vector2 = segment[0];var b: Vector2 = segment[1]
		var closest := a+(b-a)*clampf((point-a).dot(b-a)/(b-a).length_squared(),0.0,1.0)
		distance=minf(distance,point.distance_to(closest))
	return distance

func surface_regions(source, face: Dictionary, polygon: PackedVector2Array) -> Array[PackedVector2Array]:
	if not enabled or face.get("scene_role","")!="site":
		var original: Array[PackedVector2Array] = [polygon]
		return original
	if polygon==face.polygon and _site_regions.has(face.polygon): return _site_regions[face.polygon]
	var result: Array[PackedVector2Array] = []
	var query: Rect2=source._polygon_bounds(polygon).grow(.001)
	var pieces: Array=_site_regions.get(face.polygon,[])
	var piece_bounds: Array=_site_region_bounds.get(face.polygon,[])
	for index in pieces.size():
		if index<piece_bounds.size() and not query.intersects(piece_bounds[index],true):continue
		var clipped: PackedVector2Array = source._intersect_convex(polygon,pieces[index])
		if clipped.size()>=3 and absf(source._signed_area(clipped))>.001: result.append(clipped)
	return result

func _clip_planar(source, face: Dictionary, polygon: PackedVector2Array, hull: PackedVector2Array) -> PackedVector2Array:
	var result := polygon
	for edge in hull.size():
		var output := PackedVector2Array()
		if result.is_empty(): break
		var a := hull[edge];var b := hull[(edge+1)%hull.size()]
		var previous := result[result.size()-1]
		var world: Vector3 = source._face_world_at(face,previous)
		var previous_distance := (b-a).cross(Vector2(world.x,world.z)-a)
		for point in result:
			world=source._face_world_at(face,point)
			var distance := (b-a).cross(Vector2(world.x,world.z)-a)
			if (distance>=0.0)!=(previous_distance>=0.0): output.append(previous.lerp(point,previous_distance/(previous_distance-distance)))
			if distance>=0.0: output.append(point)
			previous=point;previous_distance=distance
		result=output
	return result

func report() -> Dictionary:
	return {"enabled":enabled,"known_cells":_known.size(),"boundary_edges":_segments.size(),"feather_world":width,"site_clip_faces":_site_regions.size(),"site_clip_tiles":_site_tiles.size(),"cache_ms":cache_ms,"cache_build_count":build_count,"unknown_geometry_drawn":false if enabled else null,"background_hex":DARK.to_html(false),"method":"known-union inward feather; unknown faces omitted"}

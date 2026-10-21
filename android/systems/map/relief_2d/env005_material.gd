extends RefCounted
## CPU-only registration of six already-projected art layers. Texture creation
## is exclusively requested by the main-thread mesh publish/dynamic draw path.
const ATLAS_PATH := "res://assets/environment/env005/env005-atlas.png"
const VariantCatalog = preload("res://systems/map/relief_2d/art_variant_catalog.gd")
const ArtThemes = preload("res://systems/map/relief_2d/map_art_themes.gd")
# Reuse the supplied top and its painted black perimeter. A darker neutral
# stone albedo separates non-walkable crowns from the walkable floor without
# extra geometry, outlines, seam strips, or an additional texture.
const WALL_CROWN_TINT := Color(.78,.775,.76,1.0)
const CORNERS := [Vector2(2862,2855),Vector2(1938,3103),Vector2(1104,2767),Vector2(1185,2180),Vector2(2125,1933),Vector2(2955,2268)]
# Main-thread texture sharing does not own the GPU resources. Published and
# cached batches hold strong references; retiring a floor can release its atlas.
static var _atlas_refs: Dictionary = {}
static var _texture_metrics: Dictionary = {}
var enabled := false
var theme_id := "alchemy"
var asset_id := "ENV-005"
var atlas_path := ATLAS_PATH
var manifest_path := VariantCatalog.MANIFEST
var theme_fallback_reason := ""
var _blocked: Dictionary = {}
var _address := ""
var cache_ms := 0.0
var catalog: VariantCatalog = VariantCatalog.new()
var _choices: Dictionary = {}
var _uv_center := Vector2.ZERO
var _uv_edge_a: Array[Vector2] = []
var _uv_edge_b: Array[Vector2] = []
var _uv_edge_cross: Array[float] = []

func _init() -> void:
	# Use the same expressions and accumulation order as the old per-vertex
	# path. In particular, edge five's end is evaluated at 2*PI, not wrapped.
	for corner: Vector2 in CORNERS: _uv_center+=corner
	_uv_center/=6.0
	for edge in 6:
		var a := Vector2(cos(edge*PI/3.0),sin(edge*PI/3.0))
		var b := Vector2(cos((edge+1)*PI/3.0),sin((edge+1)*PI/3.0))
		_uv_edge_a.append(a);_uv_edge_b.append(b);_uv_edge_cross.append(a.cross(b))

static func atlas_texture(path: String = ATLAS_PATH) -> Texture2D:
	# Called only by the main-thread mesh publish/dynamic draw path.
	for key: String in _atlas_refs.keys():
		if _atlas_refs[key].get_ref() == null: _atlas_refs.erase(key)
	var reference: WeakRef = _atlas_refs.get(path)
	if reference != null:
		var existing: Texture2D = reference.get_ref() as Texture2D
		if existing != null: return existing
	var start := Time.get_ticks_usec()
	var image := Image.new()
	var error := image.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
	if error != OK or image.is_empty(): push_error("Map art atlas missing: " + path);return null
	image.fix_alpha_edges()
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	_atlas_refs[path] = weakref(texture)
	_texture_metrics[path] = {"rgba_mipmap_bytes":image.get_data_size(),"texture_load_ms":(Time.get_ticks_usec()-start)/1000.0}
	# Metrics are small CPU records, but keep even user-supplied path changes bounded.
	while _texture_metrics.size() > 16: _texture_metrics.erase(_texture_metrics.keys()[0])
	return texture

func select_floor(floor_index: int) -> void:
	var theme: Dictionary = ArtThemes.for_floor(floor_index)
	theme_fallback_reason = str(theme.fallback_reason)
	if atlas_path != str(theme.atlas) or manifest_path != str(theme.manifest):
		var candidate: VariantCatalog = VariantCatalog.new({},str(theme.manifest))
		if not candidate.errors.is_empty() or candidate.pools.get("ground",[]).is_empty() or candidate.pools.get("wall",[]).is_empty():
			theme = ArtThemes.fallback("Invalid theme catalog: " + str(theme.id))
			theme_fallback_reason = str(theme.fallback_reason)
			candidate = VariantCatalog.new()
		catalog = candidate
		_choices.clear()
	theme_id = str(theme.id)
	asset_id = str(theme.asset_id)
	atlas_path = str(theme.atlas)
	manifest_path = str(theme.manifest)

func cache_identity() -> Array:
	return [theme_id,atlas_path,manifest_path,catalog.signature]

func configure(value: bool, snapshot: Dictionary, known: Dictionary) -> void:
	var start := Time.get_ticks_usec()
	select_floor(int(snapshot.get("floor_index",1)))
	enabled = value;_blocked.clear();_choices.clear()
	_address = JSON.stringify([str(snapshot.get("seed","")),str(snapshot.get("map_id","")),int(snapshot.get("floor_index",0))])
	for node: Dictionary in snapshot.get("nodes",[]):
		var visible := true
		for pair in node.get("footprint",[]):
			if not bool(known.get("%d,%d" % [int(pair[0]),int(pair[1])],false)): visible=false;break
		if not visible: continue
		for pair in node.get("footprint",[]):
			var key := "%d,%d" % [int(pair[0]),int(pair[1])]
			if bool(known.get(key,false)): _blocked[key] = true
	cache_ms = (Time.get_ticks_usec()-start)/1000.0

func mapping(face: Dictionary) -> Dictionary:
	if not enabled or not bool(face.get("known",false)) or bool(face.get("scenery",false)) or face.has("node_id"): return {}
	if face.has("rock"):
		var id: String=face.rock.region
		return {"role":"prop","variant_id":id,"region":catalog.regions[id]} if catalog.regions.has(id) else {}
	if bool(face.top): return _mapping_for("ground",str(face.key),"top")
	if str(face.category) not in ["terrain_side","wall"]: return {}
	var normal: Vector3 = face.normal
	var direction := Vector2(normal.x,normal.z).normalized()
	var best := -INF
	var edge := 0
	for index in [0,1,5]:
		var angle := deg_to_rad(index*60.0+30.0)
		var score := direction.dot(Vector2(cos(angle),sin(angle)))
		if score > best: best=score;edge=index
	var result := _mapping_for("wall",str(face.key),{0:"wall2",1:"wall1",5:"wall3"}[edge])
	if not result.is_empty(): result["edge"]=edge
	return result

func _choice(pool: String, key: String) -> Dictionary:
	var identity := pool+":"+key
	if not _choices.has(identity): _choices[identity]=catalog.choose(pool,_address,key)
	return _choices[identity]

func _mapping_for(pool: String, key: String, role: String) -> Dictionary:
	var variant := _choice(pool,key)
	if variant.is_empty(): return {}
	return {"role":role,"variant_id":variant.id,"region":catalog.regions[variant.regions[role]]}

func tint(face: Dictionary) -> Color:
	if enabled and bool(face.get("known",false)) and bool(face.get("top",false)) and str(face.get("category",""))=="wall": return WALL_CROWN_TINT
	return Color.WHITE

func pieces(source, face: Dictionary, polygon: PackedVector2Array, map: Dictionary) -> Array[Dictionary]:
	if map.is_empty() or map.get("role","")=="prop": return [{"polygon":polygon,"tile_top":0.0}]
	if map.role == "top":
		if not source._is_cutaway_wall(face): return [{"polygon":polygon,"tile_top":0.0}]
		# The painted top uses six affine UV sectors. A shadow cut can cross
		# sectors; split there first so new triangulation cannot bend the art.
		var sectors: Array[Dictionary] = []
		var top: float = face.world[0].y
		var center: Vector2 = source.project_plane(face.support,top)
		for index in 6:
			var a: Vector2 = face.support+Vector2(cos(index*PI/3.0),sin(index*PI/3.0))*source._radius
			var b: Vector2 = face.support+Vector2(cos((index+1)*PI/3.0),sin((index+1)*PI/3.0))*source._radius
			var sector := PackedVector2Array([center,source.project_plane(a,top),source.project_plane(b,top)])
			var part: PackedVector2Array = source._intersect_convex(polygon,sector)
			if part.size()>=3 and absf(source._signed_area(part))>.0001: sectors.append({"polygon":part,"tile_top":0.0})
		return sectors
	var lo := INF
	var hi := -INF
	for point in polygon:
		var height: float = source._face_world_at(face,point).y
		lo=minf(lo,height);hi=maxf(hi,height)
	# Global world phase, never restart at the renderer's 0.55-high wall bands.
	var output: Array[Dictionary] = []
	var normal: Vector3 = face.normal
	var coefficient: Vector3 = face.coefficient
	var basis: Basis = source._basis
	var height_plane := Vector3(basis.x.y/source.PIXELS_PER_WORLD+basis.z.y*coefficient.x,-basis.y.y/source.PIXELS_PER_WORLD+basis.z.y*coefficient.y,basis.z.y*coefficient.z)
	for row in range(floori((lo+.00001)/catalog.repeat_height),ceili((hi-.00001)/catalog.repeat_height)):
		var bottom := row*catalog.repeat_height
		var top := bottom+catalog.repeat_height
		var part: PackedVector2Array = source._clip_halfplane(polygon,height_plane-Vector3(0,0,bottom))
		part = source._clip_halfplane(part,-height_plane+Vector3(0,0,top))
		if part.size() >= 3: output.append({"polygon":part,"tile_top":top})
	return output

func uv(source, face: Dictionary, point: Vector2, map: Dictionary, tile_top: float) -> Vector2:
	if map.is_empty(): return Vector2(-1,-1)
	var world: Vector3 = source._face_world_at(face,point)
	return uv_at_world(source,face,world,map,tile_top)

func uv_at_world(source, face: Dictionary, world: Vector3, map: Dictionary, tile_top: float) -> Vector2:
	if map.is_empty(): return Vector2(-1,-1)
	if map.role=="prop":
		if face.rock.kind=="rubble":
			var prop: Dictionary=face.rock
			var local:=Vector2((Vector2(world.x,world.z)-Vector2(prop.plane)).dot(Vector2(prop.tangent))/float(prop.width)+.5,1.0-(world.y-float(prop.base))/float(prop.rise))
			return (Vector2(map.region.origin)+local*Vector2(map.region.dimensions))/catalog.size
		var point: Vector2=source.project_plane(Vector2(world.x,world.z),world.y)
		var rect: Rect2=face.rock.rect
		return (Vector2(map.region.origin)+(point-rect.position)/rect.size*Vector2(map.region.dimensions))/catalog.size
	var p := (Vector2(world.x,world.z)-Vector2(face.support))/float(source._radius)
	var pixel := Vector2.ZERO
	if map.role == "top":
		var angle := fposmod(atan2(p.y,p.x),TAU)
		var edge := mini(5,floori(angle/(PI/3.0)))
		var a: Vector2 = _uv_edge_a[edge]
		var b: Vector2 = _uv_edge_b[edge]
		var center: Vector2 = _uv_center
		pixel=center+(CORNERS[edge]-center)*(p.cross(b)/_uv_edge_cross[edge])+(CORNERS[(edge+1)%6]-center)*(a.cross(p)/_uv_edge_cross[edge])
	else:
		var edge: int = map.edge
		var a: Vector2 = _uv_edge_a[edge]
		var b: Vector2 = _uv_edge_b[edge]
		var u := clampf((p-a).dot(b-a)/(b-a).length_squared(),0,1)
		pixel=CORNERS[edge].lerp(CORNERS[(edge+1)%6],u)+Vector2(0,209.0*clampf((tile_top-world.y)/catalog.repeat_height,0,1))
	var region: Dictionary = map.region
	return (Vector2(region.origin)+(pixel-Vector2(region.crop))*catalog.scale)/catalog.size

func decoration(source, face: Dictionary) -> Dictionary:
	if not enabled or not bool(face.get("known",false)) or bool(face.get("scenery",false)) or str(face.category) != "ground" or not bool(face.top) or face.has("node_id") or _blocked.has(str(face.key)): return {}
	if not catalog.places_decoration(_address,str(face.key)): return {}
	var variant := _choice("decoration",str(face.key))
	if variant.is_empty(): return {}
	var region: Dictionary = catalog.regions[variant.region]
	var origin: Vector2 = region.origin
	var dimensions: Vector2 = region.dimensions
	var center: Vector2 = source.project_plane(face.support,float(face.support_height)+.01)
	# The overlay is already projected: a screen-aligned small cutout, not a
	# second projected plane. Clip to its existing floor and painter ownership.
	var width := float(source.PIXELS_PER_WORLD)*float(source._radius)*float(variant.width)
	var rect := Rect2(center-Vector2(width,width*dimensions.y/dimensions.x)*.5,Vector2(width,width*dimensions.y/dimensions.x))
	var polygon: PackedVector2Array = source._intersect_convex(source._rect_polygon(rect),face.polygon)
	return {"polygon":polygon,"rect":rect,"origin":origin,"dimensions":dimensions,"atlas_size":catalog.size,"variant_id":variant.id}

func report() -> Dictionary:
	var counts := {}
	for pool: String in catalog.pools: counts[pool]=catalog.pools[pool].size()
	var metrics: Dictionary = _texture_metrics.get(atlas_path,{})
	return {"enabled":enabled,"theme":theme_id,"asset_id":asset_id,"atlas":atlas_path.get_file(),"atlas_path":atlas_path,"manifest_path":manifest_path,"theme_fallback_reason":theme_fallback_reason,"size":[catalog.size.x,catalog.size.y],"rgba_mipmap_bytes":int(metrics.get("rgba_mipmap_bytes",0)),"texture_load_ms":float(metrics.get("texture_load_ms",0.0)),"cache_ms":cache_ms,"wall_repeat_world":catalog.repeat_height,"wall_crown_tint":WALL_CROWN_TINT.to_html(false),"filter":"linear-mipmap","variant_pools":counts,"catalog_signature":catalog.signature,"catalog_errors":catalog.errors,"decoration_probability":catalog.decoration_probability,"selection":"seed-map-floor-cell-pool-stateless-v1"}

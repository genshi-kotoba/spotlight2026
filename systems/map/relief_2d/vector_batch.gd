extends Node2D
## Retained 2D triangles preserve face/shadow/label painter order. Preparation
## uses private CPU arrays; meshes and CanvasItem commands are main-thread only.
const NodeArt = preload("res://systems/map/relief_2d/node_art.gd")
const Env005Material = preload("res://systems/map/relief_2d/env005_material.gd")
const ArtShader = preload("res://systems/map/relief_2d/env005_canvas.gdshader")
# Default-only material for hidden/prepared batches. Runtime cutaway replaces
# the whole material with its presentation-owned instance; never mutate this
# fallback's uniforms. Created by main-thread apply_prepared, not CPU workers.
static var _default_art_material: ShaderMaterial
var _atlas_texture: Texture2D
var commands: Array = []
var faces: Array = []
var build_usec := 0
var triangles := 0
# Presentation-local replacement. The original commands remain immutable and
# can be shown again without rebuilding or polluting FloorRenderData packets.
var _dynamic_commands: Array = []
var _dynamic_override := false
var dynamic_triangles := 0
var static_face_packets: Array = []
var node_marker_only := false

class Buffer extends RefCounted:
	var atlas := false
	var uvs := PackedVector2Array()
	var commands: Array = []
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var custom := PackedFloat32Array()
	var normals := PackedFloat32Array()
	var surface_normal := Vector3.UP
	var light_receiver := 0.0
	var face_depth := Vector3.ZERO
	var wall_column := 0.0
	var ground_receiver := 0.0
	func begin_face(source, face: Dictionary) -> void:
		surface_normal = face.normal
		light_receiver = 1.0 if face.known and not face.has("node_id") and not face.get("scenery",false) and face.category in ["ground","wall","terrain_side","rock"] else 0.0
		face_depth = face.coefficient
		wall_column = 1.0 if source._is_cutaway_wall(face) else 0.0
		ground_receiver = 1.0 if face.known and face.top and face.category == "ground" and not face.get("scenery", false) and source._cells.get(face.key, {}).get("terrain", "") == "ground" else 0.0
	func _meta(point: Vector2) -> void:
		var offset := custom.size()
		custom.resize(offset+4);normals.resize(offset+4)
		_write_meta(offset,point)
	func _write_meta(offset: int, point: Vector2) -> void:
		custom[offset]=wall_column
		custom[offset+1]=face_depth.x * point.x + face_depth.y * point.y + face_depth.z
		custom[offset+2]=ground_receiver;custom[offset+3]=0.0
		normals[offset]=surface_normal.x;normals[offset+1]=surface_normal.y
		normals[offset+2]=surface_normal.z;normals[offset+3]=light_receiver
	func _reserve_vertices(count: int, with_uvs: bool = false) -> int:
		var first := vertices.size()
		var total := first+count
		vertices.resize(total);colors.resize(total)
		custom.resize(total*4);normals.resize(total*4)
		if atlas or with_uvs: uvs.resize(total)
		return first
	func _append_triangles(first: int, tris: PackedInt32Array) -> void:
		var offset := indices.size()
		indices.resize(offset+tris.size())
		for i in tris.size(): indices[offset+i]=first+tris[i]
	func _append_fan(first: int, count: int) -> void:
		var offset := indices.size()
		indices.resize(offset+count*3)
		for index in count:
			indices[offset+index*3]=first
			indices[offset+index*3+1]=first+index+1
			indices[offset+index*3+2]=first+(index+1)%count+1
	func polygon_fill(polygon: PackedVector2Array, color: Color) -> void:
		if polygon.size()<3: return
		var local := PackedVector2Array()
		for point in polygon: local.append(point-polygon[0])
		var tris := Geometry2D.triangulate_polygon(local)
		if tris.is_empty(): return
		var first := _reserve_vertices(polygon.size())
		for i in polygon.size():
			var point: Vector2 = polygon[i]
			vertices[first+i]=point;_write_meta((first+i)*4,point)
			colors[first+i]=color
			if atlas: uvs[first+i]=Vector2(-1,-1)
		_append_triangles(first,tris)
	func atmosphere_fill(source, face: Dictionary, polygon: PackedVector2Array, shadowed: bool = false) -> void:
		for piece in source._fog_surface_regions(face,polygon): _atmosphere_piece(source,face,piece,shadowed)
	func _atmosphere_piece(source, face: Dictionary, polygon: PackedVector2Array, shadowed: bool = false) -> void:
		if polygon.size()<3: return
		var center := Vector2.ZERO
		for point in polygon: center += point
		center /= polygon.size()
		var first := _reserve_vertices(polygon.size()+1)
		vertices[first]=center;_write_meta(first*4,center);colors[first]=source._atmosphere_color(face,center,shadowed)
		if atlas: uvs[first]=Vector2(-1,-1)
		for i in polygon.size():
			var point: Vector2 = polygon[i]
			vertices[first+i+1]=point;_write_meta((first+i+1)*4,point);colors[first+i+1]=source._atmosphere_color(face,point,shadowed)
			if atlas: uvs[first+i+1]=Vector2(-1,-1)
		_append_fan(first,polygon.size())
	func art_fill(source, face: Dictionary, polygon: PackedVector2Array, map: Dictionary, shadowed: bool = false) -> void:
		var shared_world: bool = source.has_method("_art_color_at_world") and source._art.has_method("uv_at_world")
		for piece: Dictionary in source._art.pieces(source,face,polygon,map):
			var points: PackedVector2Array = piece.polygon
			if points.size()<3: continue
			var center := Vector2.ZERO
			for point in points: center+=point
			center/=points.size()
			var first := _reserve_vertices(points.size()+1,true)
			_art_vertex(source,face,first,center,map,piece.tile_top,shadowed,shared_world)
			for i in points.size():
				_art_vertex(source,face,first+i+1,points[i],map,piece.tile_top,shadowed,shared_world)
			_append_fan(first,points.size())
	func _art_vertex(source, face: Dictionary, index: int, point: Vector2, map: Dictionary, tile_top: float, shadowed: bool, shared_world: bool) -> void:
		vertices[index]=point;_write_meta(index*4,point)
		if shared_world:
			var world: Vector3 = source._face_world_at(face,point)
			colors[index]=source._art_color_at_world(face,point,world,shadowed)
			uvs[index]=source._art.uv_at_world(source,face,world,map,tile_top)
		else:
			# Retain the original Buffer source protocol for older adapters.
			colors[index]=source._art_color(face,point,shadowed)
			uvs[index]=source._art.uv(source,face,point,map,tile_top)
	func art_decoration(source, face: Dictionary, decal: Dictionary, force_shadowed: bool = false) -> void:
		var points: PackedVector2Array = decal.polygon
		if points.size()<3: return
		var local := PackedVector2Array()
		for point in points: local.append(point-points[0])
		var tris := Geometry2D.triangulate_polygon(local)
		if tris.is_empty(): return
		var first := _reserve_vertices(points.size(),true)
		var center: Vector2 = decal.rect.get_center()
		var shadowed: bool = force_shadowed or source._solar.is_shadowed(source._face_world_at(face,center))
		for i in points.size():
			var point: Vector2 = points[i]
			vertices[first+i]=point;_write_meta((first+i)*4,point);colors[first+i]=source._art_color(face,point,shadowed);uvs[first+i]=(Vector2(decal.origin)+(point-decal.rect.position)/decal.rect.size*Vector2(decal.dimensions))/Vector2(decal.atlas_size)
		_append_triangles(first,tris)
	func line(a:Vector2,b:Vector2,color:Color,width:float) -> void:
		var normal := (b-a).orthogonal().normalized()*width*.5
		polygon_fill(PackedVector2Array([a+normal,b+normal,b-normal,a-normal]),color)
	func append_commands(prepared: Array) -> void:
		for command: Dictionary in prepared:
			if not command.has("vertices"):
				flush_mesh();commands.append(command);continue
			var first := vertices.size()
			vertices.append_array(command.vertices);colors.append_array(command.colors)
			custom.append_array(command.custom)
			normals.append_array(command.normals)
			if atlas: uvs.append_array(command.uvs)
			_append_triangles(first,command.indices)

	func flush_mesh() -> void:
		if indices.is_empty(): return
		var command := {"vertices":vertices,"colors":colors,"indices":indices,"custom":custom,"normals":normals}
		if atlas: command["uvs"]=uvs;command["atlas"]=true
		commands.append(command)
		uvs=PackedVector2Array()
		vertices=PackedVector2Array();colors=PackedColorArray();indices=PackedInt32Array();custom=PackedFloat32Array();normals=PackedFloat32Array()

static func prepare(source, next_faces: Array) -> Array:
	var buffer := Buffer.new()
	buffer.atlas=source.is_art_enabled()
	var packets: Array = []
	var has_receiver := false
	for face: Dictionary in next_faces:
		if source.is_exploration_fog_enabled() and not face.known:
			packets.append([]);continue
		var packet: Array = _static_face_packet(source,face)
		packets.append(packet)
		has_receiver = has_receiver or source._is_actor_shadow_receiver(face)
		buffer.append_commands(packet)
	buffer.flush_mesh()
	# Keep immutable packet references, without the cache signatures. Otherwise
	# a first actor shadow after FloorRenderData trims its temporary cache would
	# regenerate all unchanged faces in this group on the movement frame.
	if has_receiver and not buffer.commands.is_empty(): buffer.commands[0]["face_packets"]=packets
	return buffer.commands

static func _static_face_packet(source, face: Dictionary) -> Array:
	# This exact existing omission produces no vertices, labels or edges. Avoid
	# hashing/caching its solar/material signature as an empty packet.
	if _is_buried_wall_cap(source,face):return []
	# Node groups are mutable; dynamic wall variants never call this cache path.
	if not source._incremental_presentation_enabled or source._floor_data==null or face.has("node_id"):
		return _prepare_uncached(source,[face])
	var signature: Array=source._material_face_key(face)
	var prepared: Variant=source._floor_data.find_packet(signature)
	if prepared==null:
		source._reuse_report["material_misses"]=source._reuse_report.get("material_misses",0)+1
		prepared=_prepare_uncached(source,[face])
		source._floor_data.store_packet(signature,prepared)
	else: source._reuse_report["material_hits"]=source._reuse_report.get("material_hits",0)+1
	return prepared

static func _is_buried_wall_cap(source, face: Dictionary) -> bool:
	return face.get("known",false) and face.category=="ground" and face.top \
			and not face.has("node_id") and not face.get("scenery",false) \
			and source._cells.get(face.key,{}).get("terrain","")=="wall"

static func prepare_wall_shadow_override(source, next_faces: Array, dynamic: Dictionary, retained: Array = []) -> Array:
	var buffer := Buffer.new()
	buffer.atlas=source.is_art_enabled()
	for position in next_faces.size():
		var face: Dictionary = next_faces[position]
		if source.is_exploration_fog_enabled() and not face.known: continue
		var receiver := int(face.get("_wall_shadow_index",-1))
		if not dynamic.has(receiver):
			buffer.append_commands(retained[position] if retained.size()==next_faces.size() else _static_face_packet(source,face));continue
		var variant := face.duplicate(false)
		var shadows: Array = face.get("solar_shadows",[]).duplicate()
		var added: Array[PackedVector2Array] = []
		# Solar already removes static coverage. Repeat the cheap bounded-area
		# subtraction against static AND earlier dynamic pieces to keep the final
		# surface disjoint even at clipping tolerances; never truncate fragments.
		for polygon: PackedVector2Array in dynamic[receiver]:
			var pieces: Array[PackedVector2Array] = [source._intersect_convex(polygon,face.polygon)]
			for covered: PackedVector2Array in shadows:
				var remaining: Array[PackedVector2Array] = []
				var bounds: Rect2 = source._polygon_bounds(covered)
				for piece in pieces:
					if source._polygon_bounds(piece).intersects(bounds,true): remaining.append_array(source._subtract_convex(piece,covered))
					else: remaining.append(piece)
				pieces=remaining
				if pieces.is_empty(): break
			for piece in pieces:
				if piece.size()<3 or absf(source._signed_area(piece))<0.0001: continue
				shadows.append(piece);added.append(piece)
		variant["solar_shadows"]=shadows
		variant["_dynamic_solar_shadows"]=added
		# Do not find/store a packet under the moving actor's shadow geometry.
		buffer.append_commands(_prepare_uncached(source,[variant]))
	buffer.flush_mesh()
	return buffer.commands

static func _prepare_uncached(source, next_faces: Array) -> Array:
	var buffer := Buffer.new()
	var art: bool = source.has_method("is_art_enabled") and source.is_art_enabled()
	buffer.atlas = art
	var atmosphere: bool = source.has_method("is_atmosphere_enabled") and source.is_atmosphere_enabled()
	var fog: bool = source.has_method("is_exploration_fog_enabled") and source.is_exploration_fog_enabled()
	for face: Dictionary in next_faces:
		if fog and not face.get("known",false): continue
		if face.has("rock") and not art: continue
		# Every wall column also has a ground cap at its base. It is buried
		# inside the solid, not a walkable surface; cutaway must not expose it
		# as an unshadowed floor. Keep geometry/picking/casters intact and omit
		# its packet here, shared by static and moving-shadow preparation.
		if _is_buried_wall_cap(source,face):
			continue
		if face.get("node_marker", false):
			buffer.flush_mesh()
			var visual: Dictionary = face.get("node_display", {"label":"?", "texture":"", "completed":false})
			var tint := Color(.93, .85, .73)
			if visual.get("completed", false) and face.node_type in ["battle", "elite", "boss", "chest"]: tint.a = .42
			buffer.commands.append({"node_marker":true, "rect":face.bounds, "visual":visual, "tint":tint, "contact":face.get("node_contact", PackedVector2Array())})
			continue
		buffer.begin_face(source, face)
		var polygon: PackedVector2Array = face.polygon
		var factor := float(face.get("solar_factor",1.0))
		var map: Dictionary = source._art.mapping(face) if art else {}
		var shadows: Array = face.get("solar_shadows",[])
		var single_surface: bool = (source._is_cutaway_wall(face) or face.has("rock")) and not shadows.is_empty()
		var lit_regions: Array[PackedVector2Array] = [polygon]
		if single_surface:
			# An opaque shadow redraw hides the lit base, but two faded redraws
			# expose that base again. Partition once, before applying transparency.
			for shadow: PackedVector2Array in shadows:
				var remaining: Array[PackedVector2Array] = []
				for region in lit_regions: remaining.append_array(source._subtract_convex(region,shadow))
				lit_regions=remaining
		for region in lit_regions:
			if not map.is_empty(): buffer.art_fill(source,face,region,map)
			elif atmosphere or fog: buffer.atmosphere_fill(source,face,region)
			else: buffer.polygon_fill(region,face.color*Color(factor,factor,factor,1))
		for shadow: PackedVector2Array in shadows:
			if not map.is_empty(): buffer.art_fill(source,face,shadow,map,true)
			elif atmosphere or fog: buffer.atmosphere_fill(source,face,shadow,true)
			elif single_surface:
				var ambient := float(source._display_sun_config.get("ambient",.3))
				buffer.polygon_fill(shadow,face.color*Color(ambient,ambient,ambient,1))
			else: buffer.polygon_fill(shadow,Color(0,0,0,source._shadow_opacity(factor)))
		if art:
			var decal: Dictionary = source._art.decoration(source,face)
			if not decal.is_empty():
				var decal_lit: Array[PackedVector2Array] = [decal.polygon]
				for shadow: PackedVector2Array in face.get("_dynamic_solar_shadows",[]):
					var remaining: Array[PackedVector2Array] = []
					for region in decal_lit: remaining.append_array(source._subtract_convex(region,shadow))
					decal_lit=remaining
					var overlap: PackedVector2Array = source._intersect_convex(decal.polygon,shadow)
					if overlap.size()>=3:
						var shade := decal.duplicate(false);shade.polygon=overlap
						buffer.art_decoration(source,face,shade,true)
				for region in decal_lit:
					var lit := decal.duplicate(false);lit.polygon=region
					buffer.art_decoration(source,face,lit)
		if atmosphere:
			for marker: Dictionary in source._atmosphere_markers(face): buffer.polygon_fill(marker.polygon,marker.color)
		if face.has("label") and Geometry2D.is_point_in_polygon(face.label_point,polygon):
			buffer.flush_mesh()
			var label := {"label":face.label,"point":face.label_point,"alpha":face.color.a}
			if atmosphere: label["color"] = Color(.2235,.2549,.2392,face.color.a).lerp(Color(.82,.80,.71,face.color.a*.92),float(source._display_atmosphere_config.strength))
			if fog:
				label.alpha *= source._fog_alpha(face,face.label_point)
				if label.has("color"): label.color.a=label.alpha
			buffer.commands.append(label)
		if map.is_empty() and bool(face.get("draw_edges", true)) and (String(face.category) not in ["ground","fog"] or source.show_grid):
			var edge: Color = source.INK
			edge.a=.26 if String(face.category) in ["ground","fog"] else .48
			if atmosphere:
				edge = edge.lerp(Color(.10,.17,.23,.19 if String(face.category) in ["ground","fog"] else .34),float(source._display_atmosphere_config.strength))
			if fog: edge.a*=source._fog_alpha(face,face.bounds.get_center())
			if source.is_sun_enabled() and String(face.category)=="wall" and not bool(face.top):
				buffer.line(polygon[0],polygon[3],edge,.65);buffer.line(polygon[1],polygon[2],edge,.65)
			else:
				for i in polygon.size(): buffer.line(polygon[i],polygon[(i+1)%polygon.size()],edge,.8 if bool(face.top) else .65)
	buffer.flush_mesh()
	return buffer.commands

func apply_prepared(next_faces: Array, prepared: Array) -> void:
	var start := Time.get_ticks_usec()
	clear_dynamic_prepared()
	faces = next_faces
	node_marker_only = not faces.is_empty() and faces.all(func(face): return face.get("node_marker", false))
	static_face_packets=prepared[0].get("face_packets",[]) if not prepared.is_empty() else []
	commands.clear();triangles=0
	_atlas_texture=null;material=null
	texture_filter=CanvasItem.TEXTURE_FILTER_PARENT_NODE
	var built := _mesh_commands(prepared)
	commands=built.commands;triangles=built.triangles
	if built.atlas and not node_marker_only:
		_atlas_texture=Env005Material.atlas_texture()
		if _default_art_material==null:
			_default_art_material=ShaderMaterial.new()
			_default_art_material.shader=ArtShader
		material=_default_art_material
		texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if next_faces.any(func(face): return face.get("node_marker", false)):
		texture_filter=CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	build_usec=Time.get_ticks_usec()-start
	queue_redraw()

func _mesh_commands(prepared: Array) -> Dictionary:
	var output: Array = []
	var triangle_count := 0
	var uses_atlas := false
	for command in prepared:
		if command.has("vertices"):
			var mesh := ArrayMesh.new()
			var arrays := [];arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX]=command.vertices
			arrays[Mesh.ARRAY_COLOR]=command.colors
			arrays[Mesh.ARRAY_INDEX]=command.indices
			arrays[Mesh.ARRAY_CUSTOM0]=command.custom
			arrays[Mesh.ARRAY_CUSTOM1]=command.normals
			if not command.get("atlas",false):
				var empty_uv := PackedVector2Array(); empty_uv.resize(command.vertices.size()); empty_uv.fill(Vector2(-1,-1))
				arrays[Mesh.ARRAY_TEX_UV]=empty_uv
			if command.get("atlas",false):
				arrays[Mesh.ARRAY_TEX_UV]=command.uvs
				uses_atlas=true
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{},(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
			output.append({"mesh":mesh});triangle_count+=command.indices.size()/3
		else: output.append(command)
	return {"commands":output,"triangles":triangle_count,"atlas":uses_atlas}

func set_dynamic_prepared(prepared: Array) -> void:
	var built := _mesh_commands(prepared)
	_dynamic_commands=built.commands;dynamic_triangles=built.triangles
	_dynamic_override=true
	# A surface override has the current group's same art mode/material. Keep
	# shared cutaway uniforms, texture filtering and original draw order intact.
	if built.atlas and _atlas_texture==null: _atlas_texture=Env005Material.atlas_texture()
	queue_redraw()

func clear_dynamic_prepared() -> void:
	if not _dynamic_override: return
	_dynamic_commands.clear();dynamic_triangles=0;_dynamic_override=false
	queue_redraw()

func build(source, next_faces: Array) -> void:
	var start := Time.get_ticks_usec()
	apply_prepared(next_faces,prepare(source,next_faces))
	build_usec=Time.get_ticks_usec()-start

func clear() -> void:
	clear_dynamic_prepared()
	static_face_packets=[]
	faces.clear();commands.clear();queue_redraw()

func _draw() -> void:
	var active: Array = _dynamic_commands if _dynamic_override else commands
	for command in active:
		if command.has("mesh"): draw_mesh(command.mesh,_atlas_texture)
		elif command.has("node_marker"): _draw_node_marker(command)
		else:
			var font := ThemeDB.fallback_font
			var size := font.get_string_size(command.label,HORIZONTAL_ALIGNMENT_LEFT,-1,13)
			draw_string(font,command.point+Vector2(-size.x*.5,4),command.label,HORIZONTAL_ALIGNMENT_LEFT,-1,13,command.get("color",Color(.2235,.2549,.2392,command.alpha)))


func _draw_node_marker(command: Dictionary) -> void:
	var rect: Rect2 = command.rect
	var visual: Dictionary = command.visual
	var tex: Texture2D = NodeArt.texture(str(visual.get("texture", "")))
	var tint: Color = command.tint
	var contact: PackedVector2Array = command.get("contact", PackedVector2Array())
	if visual.get("type", "") != "event" and float(visual.get("body_radius", 0.0)) > 0 and contact.size() >= 3:
		# The contact patch uses the same planar radius as Session collision.
		# It grounds the drawing without turning transparent PNG corners solid.
		draw_colored_polygon(contact, Color(.10, .08, .055, .32))
		var rim := contact.duplicate(); rim.append(contact[0])
		draw_polyline(rim, Color(.53, .43, .28, .42), .8, true)
	if tex != null:
		var target: Rect2 = NodeArt.target_rect(rect, tex.get_size())
		draw_texture_rect(tex, target, false, tint)
	else:
		var font: Font = NodeArt.font()
		var layout := NodeArt.label_layout(str(visual.get("label", "?")), rect)
		for line: Dictionary in layout:
			draw_string_outline(font,line.point,line.text,HORIZONTAL_ALIGNMENT_LEFT,-1,line.size,2,Color(.10,.075,.055,.92))
			draw_string(font,line.point,line.text,HORIZONTAL_ALIGNMENT_LEFT,-1,line.size,Color(1.0,.88,.62))
		# A thin contact edge belongs to the upright paper marker. It is not
		# a cast shadow or a circular floor stamp, and matches its solid width.
		if not visual.get("body_capsule", {}).is_empty():
			draw_line(Vector2(rect.position.x,rect.end.y),rect.end,Color(.61,.47,.28,.8),1.0,true)
	if visual.get("gate_closed", false):
		var foot := Vector2(rect.get_center().x, rect.end.y-2.0)
		draw_line(foot+Vector2(-14,0),foot+Vector2(14,0),Color(.96,.61,.27,.95),2.0,true)
		for x in [-8.0,0.0,8.0]: draw_line(foot+Vector2(x,-3),foot+Vector2(x,3),Color(.96,.61,.27,.95),1.6,true)

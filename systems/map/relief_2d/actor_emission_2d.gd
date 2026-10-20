extends Node2D
## Small additive receiver light. Resources are created only on the main thread.
var _mesh: ArrayMesh
var piece_count := 0
var build_ms := 0.0
var update_count := 0

func _init() -> void:
	var blend := CanvasItemMaterial.new()
	blend.blend_mode=CanvasItemMaterial.BLEND_MODE_ADD
	blend.light_mode=CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material=blend
	show_behind_parent=true

func rebuild(source, receiver: Dictionary, pieces: Array, strength: float) -> void:
	var start := Time.get_ticks_usec()
	piece_count=pieces.size();update_count+=1;_mesh=null
	if strength<=0.0 or receiver.is_empty() or pieces.is_empty():
		hide();queue_redraw();return
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var radius: float = .68*source._radius
	for polygon: PackedVector2Array in pieces:
		if polygon.size()<3: continue
		var center := Vector2.ZERO
		for point in polygon: center+=point
		center/=polygon.size()
		var first := vertices.size()
		var points := PackedVector2Array([center]);points.append_array(polygon)
		for point in points:
			var world: Vector3 = source._face_world_at(receiver,point)
			var distance := Vector2(world.x,world.z).distance_to(source._actor_plane)/radius
			var alpha: float = .34*strength*pow(maxf(0.0,1.0-distance*distance),2.0)*source._fog_alpha(receiver,point)
			vertices.append(point);colors.append(Color(.92,.86,.74,alpha))
		for index in polygon.size(): indices.append_array(PackedInt32Array([first,first+index+1,first+(index+1)%polygon.size()+1]))
	if not indices.is_empty():
		var arrays := [];arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX]=vertices;arrays[Mesh.ARRAY_COLOR]=colors;arrays[Mesh.ARRAY_INDEX]=indices
		_mesh=ArrayMesh.new();_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	show();build_ms=(Time.get_ticks_usec()-start)/1000.0;queue_redraw()

func _draw() -> void:
	if _mesh!=null: draw_mesh(_mesh,null)

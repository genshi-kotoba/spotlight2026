extends Node2D
## A local readability cue, not a second opaque actor or a terrain cutaway.
## Disjoint masks come from the renderer's actual foreground depth clipping.
const SHADER = preload("res://systems/map/relief_2d/actor_occlusion_hint.gdshader")
var _parts: Array[Dictionary] = []
var _texture: Texture2D
var piece_count := 0
var update_count := 0
var build_ms := 0.0

func _init() -> void:
	var effect := ShaderMaterial.new()
	effect.shader = SHADER
	material = effect
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func clear() -> void:
	_parts.clear()
	_texture = null
	piece_count = 0
	hide()
	queue_redraw()

func rebuild(source, hidden: Array[PackedVector2Array]) -> void:
	var started := Time.get_ticks_usec()
	update_count += 1
	_parts.clear()
	var frame: Dictionary = source.actor_animation.frame()
	if frame.is_empty() or hidden.is_empty():
		clear()
		return
	_texture = source.actor_animation.textures[frame.path]
	material.set_shader_parameter("actor_texture", _texture)
	var feet: Vector2 = source.project_plane(source._actor_plane, source._actor_height)
	var box: Rect2 = source.actor_animation.draw_rect(feet)
	var region: Array = frame.region
	var start := Vector2(float(region[0]), float(region[1]))
	var size := Vector2(float(region[2]), float(region[3]))
	var atlas := _texture.get_size()
	material.set_shader_parameter("frame_uv", Vector4(start.x / atlas.x, start.y / atlas.y, size.x / atlas.x, size.y / atlas.y))
	# Local coordinates avoid distant-map float32 triangulation cancellation.
	position = feet
	for polygon in hidden:
		var clipped: PackedVector2Array = source._clip_to_rect(polygon, box)
		if not source._has_drawable_actor_area(clipped): continue
		var vertices := PackedVector2Array()
		var uvs := PackedVector2Array()
		for point in clipped:
			vertices.append(point - feet)
			uvs.append((start + (point - box.position) / box.size * size) / atlas)
		_parts.append({"vertices": vertices, "uvs": uvs})
	piece_count = _parts.size()
	visible = piece_count > 0
	build_ms = (Time.get_ticks_usec() - started) / 1000.0
	queue_redraw()

func _draw() -> void:
	if _texture == null: return
	for part in _parts:
		draw_colored_polygon(part.vertices, Color.WHITE, part.uvs, _texture)

extends "res://systems/map/relief_2d/actor_occlusion_hint.gd"
## Visibility assist inside the local wall aperture; ordinary sprite clipping
## remains authoritative everywhere else. Not a general translucent scene sorter.
const RESTORE_SHADER = preload("res://systems/map/relief_2d/actor_cutaway_restore.gdshader")

func _init() -> void:
	super()
	material.shader = RESTORE_SHADER

func rebuild(source, hidden: Array[PackedVector2Array]) -> void:
	super.rebuild(source, hidden)
	if source._wall_cutaway != null: source._wall_cutaway.apply_to(material)
	material.set_shader_parameter("foot_origin", position)
	material.set_shader_parameter("actor_tint", source._actor_draw_tint())

func prepare_invisible_draw(texture: Texture2D) -> void:
	# Exercise the same textured polygon pipeline while the map is loading.
	# Shader alpha is zero because cut_count is zero; CanvasItem opacity must
	# stay nonzero or Godot would cull the draw before compiling its pipeline.
	_texture = texture
	material.set_shader_parameter("actor_texture", texture)
	material.set_shader_parameter("cut_count", 0)
	_parts = [{"vertices": PackedVector2Array([Vector2.ZERO, Vector2(4, 0), Vector2(0, 4)]),
		"uvs": PackedVector2Array([Vector2.ZERO, Vector2(1, 0), Vector2(0, 1)])}]
	queue_redraw()

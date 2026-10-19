extends Node2D
## A discovered, interactable gate may be behind a tall wall or the fog rim.
## Draw only its icon above those effects; never authorize terrain pixels.
const Art = preload("res://systems/map/relief_2d/node_art.gd")
var node_id := ""
var _texture: Texture2D
var _anchor := Vector2.ZERO
var _rect := Rect2()
var _scale := 1.0

func _init() -> void:
	z_index = 201
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	hide()

func clear() -> void:
	node_id = ""
	hide()

func set_gate(node: Dictionary, anchor: Vector2, actor: Vector2, zoom: float) -> void:
	if not node.get("known", false) or not node.get("is_route_gate", false) or node.get("completed", false):
		clear()
		return
	var texture: Texture2D = Art.texture(str(Art.describe(node).texture))
	if texture == null:
		clear()
		return
	var unit := 1.0 / maxf(zoom, .05)
	var center := anchor + Vector2(0, -105) * unit
	# Keep the small callout clear of the actor's body, at every zoom level.
	if absf(center.x - actor.x) < 48 * unit and absf(center.y - actor.y) < 90 * unit:
		center.x += (68 if anchor.x >= actor.x else -68) * unit
	var rect := Rect2(center - Vector2(28, 28) * unit, Vector2(56, 56) * unit)
	if node_id == node.id and _anchor == anchor and _rect == rect and visible: return
	node_id = node.id
	_texture = texture
	_anchor = anchor
	_rect = rect
	_scale = unit
	show()
	queue_redraw()

func _draw() -> void:
	if node_id.is_empty() or _texture == null: return
	var end := Vector2(_rect.get_center().x, _rect.end.y + 16 * _scale)
	draw_line(_anchor, end, Color(.85, .70, .43, .65), 1.2 * _scale, true)
	draw_circle(_anchor, 3 * _scale, Color(.96, .80, .49))
	var size := _texture.get_size()
	size *= minf(_rect.size.x / size.x, _rect.size.y / size.y)
	draw_texture_rect(_texture, Rect2(_rect.get_center() - size * .5, size), false, Color(1, .93, .82))
	draw_circle(end - Vector2(0, 5 * _scale), 10 * _scale, Color(.10, .08, .06, .94))
	draw_string(Art.font(), end + Vector2(-4, 0) * _scale, "E", HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1, roundi(13 * _scale)), Color(1, .9, .68))

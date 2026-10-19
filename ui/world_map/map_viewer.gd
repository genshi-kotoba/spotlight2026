class_name MapViewer
extends Control

## 冒险菜单里的地图查看器：真实地图渲染 + 滚轮缩放 + 拖动平移，只动镜头不动角色。
## 用 SubViewport 装一份 MapView 与独立相机，和大地图共用同一套渲染与坐标。

const MAP_VIEW := preload("res://ui/world_map/flat_2d/map_view.gd")

const ZOOM_RATE := 1.12
const ZOOM_MIN := 0.55
const ZOOM_MAX := 2.6
const MARGIN_RATIO := 0.18


class ActorMarker:
	extends Node2D

	var actor := Vector2.ZERO
	var active := false

	func _draw() -> void:
		if not active:
			return
		draw_circle(actor, 18.0, Color(0.06, 0.09, 0.10, 0.86))
		draw_circle(actor, 12.0, Color(0.64, 1.0, 0.89))
		draw_circle(actor, 18.0, Color(0.83, 1.0, 0.96, 0.9), false, 3.0)


var _viewport: SubViewport
var _map: Node2D
var _camera: Camera2D
var _marker: ActorMarker
var _texture: TextureRect
var _radius := 60.0
var _actor := Vector2.ZERO
var _has_actor := false
var _dragging := false
var _fit_zoom := 1.0
var _zoom_scale := 1.0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	_viewport = SubViewport.new()
	# 只读查看器独占 2D 世界，不能把第二份地图画进外层跑图场景。
	_viewport.world_2d = World2D.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = true
	add_child(_viewport)

	_texture = TextureRect.new()
	_texture.texture = _viewport.get_texture()
	_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_texture)

	_map = MAP_VIEW.new()
	_viewport.add_child(_map)

	_marker = ActorMarker.new()
	_viewport.add_child(_marker)

	_camera = Camera2D.new()
	_camera.enabled = true
	_viewport.add_child(_camera)

	resized.connect(_sync_viewport_size)
	_sync_viewport_size()


func set_map(data: Dictionary, cell_radius_px: float = 60.0) -> void:
	_radius = maxf(cell_radius_px, 1.0)
	_map.set_view(data, _radius)
	_fit_zoom = _compute_fit()
	_zoom_scale = 1.0
	_camera.zoom = Vector2.ONE * _camera_scale()
	_recenter()


func set_actor(plane: Vector2) -> void:
	_actor = plane
	_has_actor = true
	_marker.actor = plane * _radius
	_marker.active = true
	_marker.queue_redraw()


func clear_actor() -> void:
	_has_actor = false
	_marker.active = false
	_marker.queue_redraw()


func _sync_viewport_size() -> void:
	_viewport.size = Vector2i(maxi(int(size.x), 1), maxi(int(size.y), 1))
	_fit_zoom = _compute_fit()
	_camera.zoom = Vector2.ONE * _camera_scale()
	_clamp_camera()


func _compute_fit() -> float:
	var bounds: Rect2 = _map.get_map_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return 1.0
	var viewport := Vector2(_viewport.size)
	if viewport.x <= 1.0 or viewport.y <= 1.0:
		return 1.0
	return minf(viewport.x / (bounds.size.x + _radius * 2.0),
		viewport.y / (bounds.size.y + _radius * 2.0))


func _camera_scale() -> float:
	return maxf(_fit_zoom * _zoom_scale, 0.01)


func _recenter() -> void:
	if _has_actor:
		_camera.position = _actor * _radius
	else:
		var bounds: Rect2 = _map.get_map_bounds()
		_camera.position = bounds.position + bounds.size * 0.5
	_clamp_camera()


func _clamp_camera() -> void:
	var bounds: Rect2 = _map.get_map_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var margin := Vector2(_radius, _radius) * (1.0 + MARGIN_RATIO)
	var half := Vector2(_viewport.size) * 0.5 / Vector2(_camera.zoom)
	var low := bounds.position - margin + half
	var high := bounds.end + margin - half
	_camera.position = Vector2(
		clampf(_camera.position.x, minf(low.x, high.x), maxf(low.x, high.x)),
		clampf(_camera.position.y, minf(low.y, high.y), maxf(low.y, high.y)))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, ZOOM_RATE)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / ZOOM_RATE)
	elif event is InputEventMouseMotion and _dragging:
		# 镜头反向移动：按住往哪拖，地图就往哪走。
		_camera.position -= event.relative / Vector2(_camera.zoom)
		_clamp_camera()


func _zoom_at(local_point: Vector2, factor: float) -> void:
	var next := clampf(_zoom_scale * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(next, _zoom_scale):
		return
	var offset := local_point - Vector2(_viewport.size) * 0.5
	var before := _camera.position + offset / Vector2(_camera.zoom)
	_zoom_scale = next
	_camera.zoom = Vector2.ONE * _camera_scale()
	var after := _camera.position + offset / Vector2(_camera.zoom)
	_camera.position += before - after
	_clamp_camera()

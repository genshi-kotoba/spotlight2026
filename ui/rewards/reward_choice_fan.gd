class_name RewardChoiceFan
extends Control
## 开包的纯表现层：飞散、缩放和悬停共用连续弹簧状态，不执行奖励事务。
signal chosen(id: String)

const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const RUNTIME_LOG := preload("res://systems/diagnostics/runtime_log.gd")
const FLIGHT_TIME := 0.16
const FOLD_TIME := 0.20
const THUMBNAIL_SCALE := 0.16
const HOVER_SCALE := 1.35
const SPRING_STIFFNESS := 440.0
const SPRING_DAMPING := 31.0
const GAP := 58.0

var _items: Array[Control] = []
var _hits: Array[Button] = []
var _states: Array[Dictionary] = []
var _item_size := Vector2(240, 409)
var _hovered := -1
var _elapsed := 0.0
var _folding := false
var _opening := true
var _ready_to_choose := false
var _pointer_position := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = false

func configure(options: Array, fragments: bool) -> void:
	RUNTIME_LOG.event("reward.offer", {"kind": "fragment" if fragments else "card", "options": options})
	_item_size = Vector2(330, 470) if fragments else Vector2(240, 409)
	var cards: Dictionary = {} if fragments else FormalCardCatalog.load_definitions().cards
	for value: String in options:
		var item := Control.new()
		item.name = "Option_" + value.validate_node_name()
		item.size = _item_size
		item.pivot_offset = _item_size * 0.5
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(item)
		var card: CardView
		if fragments:
			_build_fragment(item, value)
		else:
			card = CARD_SCENE.instantiate()
			card.set_card(cards[value])
			card.apply_compact_layout(0.5)
			card.scale = Vector2.ONE * 0.5
			card.mouse_filter = Control.MOUSE_FILTER_IGNORE
			item.add_child(card)
		var hit := Button.new()
		hit.name = "Choose_" + value.validate_node_name()
		hit.flat = true
		hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hit.focus_mode = Control.FOCUS_NONE
		hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		for state: String in ["normal", "hover", "pressed", "focus"]:
			hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		hit.pressed.connect(func():
			if _ready_to_choose and not _folding: chosen.emit(value))
		item.add_child(hit)
		if card != null: card.bind_interaction_button(hit)
		_items.append(item)
		_hits.append(hit)
		_states.append({"center": Vector2.ZERO, "velocity": Vector2.ZERO,
			"zoom": THUMBNAIL_SCALE, "zoom_velocity": 0.0, "fold_from": Vector2.ZERO})
	open()

func _build_fragment(item: Control, id: String) -> void:
	var fragment := RelicCatalog.resolve(id)
	var panel := Panel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel", Vector4(16, 16, 16, 16)))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(panel)
	var art := TextureRect.new()
	art.texture = RelicPieceArt.template_texture()
	art.position = Vector2(75, 18)
	art.size = Vector2(180, 180)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.modulate = fragment.tint().lightened(0.25)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(art)
	var detail := RichTextLabel.new()
	CommonUiSkin.setup_relic_text(detail, 21)
	detail.position = Vector2(20, 215)
	detail.size = Vector2(290, 235)
	detail.bbcode_enabled = true
	detail.text = fragment.rich_text(21)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.scroll_active = false
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(detail)

func open() -> void:
	visible = true
	_folding = false
	_opening = true
	_ready_to_choose = false
	_elapsed = 0.0
	_hovered = -1
	_pointer_position = get_viewport().get_mouse_position()
	for index in _states.size():
		_states[index].merge({"center": _origin(), "velocity": Vector2.ZERO,
			"zoom": THUMBNAIL_SCALE, "zoom_velocity": 0.0}, true)
		_items[index].modulate.a = 1.0
		_apply(index)
	_set_hits(false)
	set_process(true)

func fold() -> void:
	if _folding: return
	_folding = true
	_ready_to_choose = false
	_elapsed = 0.0
	_hovered = -1
	for state: Dictionary in _states:
		state.fold_from = state.center
		state.fold_zoom = state.zoom
	_set_hits(false)

func is_settled() -> bool:
	return (not visible and _folding) or (_ready_to_choose and not _opening)

func _set_hits(enabled: bool) -> void:
	for hit: Button in _hits:
		hit.disabled = not enabled
		hit.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	_elapsed += delta
	if _folding:
		var weight := smoothstep(0.0, 1.0, minf(1.0, _elapsed / FOLD_TIME))
		for index in _states.size():
			_states[index].center = Vector2(_states[index].fold_from).lerp(_origin(), weight)
			_states[index].zoom = lerpf(float(_states[index].fold_zoom), THUMBNAIL_SCALE, weight)
			_items[index].modulate.a = 1.0 - weight
			_apply(index)
		if _elapsed >= FOLD_TIME:
			hide()
			set_process(false)
		return
	if _ready_to_choose: _update_hover()
	var targets := _targets()
	for index in _states.size():
		var state: Dictionary = _states[index]
		if _opening and _elapsed < FLIGHT_TIME:
			var progress := 1.0 - pow(1.0 - clampf(_elapsed / FLIGHT_TIME, 0.0, 1.0), 3.0)
			state.center = _origin().lerp(targets[index], progress)
		else:
			var steps := maxi(1, ceili(minf(delta, 0.05) * 120.0))
			var step := minf(delta, 0.05) / steps
			var target_zoom := _fit_scale() * (HOVER_SCALE if index == _hovered else 1.0)
			for tick in steps:
				state.velocity += ((targets[index] - state.center) * SPRING_STIFFNESS - state.velocity * SPRING_DAMPING) * step
				state.center += state.velocity * step
				state.zoom_velocity += ((target_zoom - float(state.zoom)) * SPRING_STIFFNESS - float(state.zoom_velocity) * SPRING_DAMPING) * step
				state.zoom += state.zoom_velocity * step
		_apply(index)
	if _opening and _elapsed >= 0.42:
		_opening = false
		_ready_to_choose = true
		_set_hits(true)

func _fit_scale() -> float:
	var maximum_width := _item_size.x * (_items.size() + HOVER_SCALE - 1.0) + GAP * maxi(0, _items.size() - 1)
	return minf(1.0, minf(maxf(1.0, size.x - 100.0) / maximum_width, maxf(1.0, size.y - 30.0) / (_item_size.y * HOVER_SCALE)))

func _origin() -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * (get_viewport_rect().size * 0.5)

func _targets() -> Array[Vector2]:
	var centers: Array[Vector2] = []
	var fit := _fit_scale()
	var total := GAP * maxi(0, _items.size() - 1) * fit
	for index in _items.size(): total += _item_size.x * fit * (HOVER_SCALE if index == _hovered else 1.0)
	var left := (size.x - total) * 0.5
	for index in _items.size():
		var width := _item_size.x * fit * (HOVER_SCALE if index == _hovered else 1.0)
		centers.append(Vector2(left + width * 0.5, size.y * 0.5))
		left += width + GAP * fit
	return centers

func _update_hover() -> void:
	# 与命中检测使用同一套 Viewport 坐标；不要将 CanvasLayer 全局坐标再次变换。
	var mouse := _pointer_position
	if _hovered >= 0 and _contains(_items[_hovered], mouse): return
	_hovered = -1
	for index in _items.size():
		if _contains(_items[index], mouse):
			_hovered = index
			break

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion: _pointer_position = event.position

func _contains(item: Control, point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, item.size).has_point(item.get_global_transform_with_canvas().affine_inverse() * point)

func _apply(index: int) -> void:
	var item := _items[index]
	item.position = Vector2(_states[index].center) - item.pivot_offset
	item.scale = Vector2.ONE * float(_states[index].zoom)
	item.z_index = 2 if index == _hovered else 1

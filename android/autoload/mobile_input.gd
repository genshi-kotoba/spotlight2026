extends Node
## 单指手势只转换表现层输入，规则、卡牌和存档仍由原系统执行。
## 禁用 Godot 的自动鼠标模拟，短按在抬手时点击，长按只悬停。
const HOLD_SECONDS := 0.42
const DRAG_PIXELS := 18.0
var _finger := -1
var _origin := Vector2.ZERO
var _at := Vector2.ZERO
var _elapsed := 0.0
var _held := false
var _dragging := false
var _mouse_down := false
var _scroll: ScrollContainer
var _scene_id := 0
var _hover_revision := 0
var _wheel_distance := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.emulate_mouse_from_touch = false
	Input.emulate_touch_from_mouse = false
	# 确认对话框也留在游戏视口中，桌面预览和 Android 使用同一套触屏路由。
	get_tree().root.gui_embed_subwindows = true

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			_begin(event.index, event.position)
		elif not event.pressed and event.index == _finger:
			_finish(event.position, event.canceled)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if event.index == _finger: _move(event.position)
		get_viewport().set_input_as_handled()

func _scene_identity() -> int:
	var scene := get_tree().current_scene
	return scene.get_instance_id() if is_instance_valid(scene) else 0

func _begin(index: int, at: Vector2) -> void:
	_hover_revision += 1
	_finger = index
	_origin = at
	_at = at
	_elapsed = 0.0
	_held = false
	_dragging = false
	_mouse_down = false
	_scroll = null
	_wheel_distance = 0.0
	_scene_id = _scene_identity()

func _process(delta: float) -> void:
	if _finger < 0: return
	if _scene_identity() != _scene_id:
		_finish(_at, true)
		return
	_elapsed += delta
	if not _dragging and not _held and _elapsed >= HOLD_SECONDS:
		_held = true
		_motion(_at)

func _move(at: Vector2) -> void:
	if _scene_identity() != _scene_id:
		_finish(_at, true)
		return
	var relative := at - _at
	_at = at
	if not _dragging and at.distance_to(_origin) >= DRAG_PIXELS:
		_dragging = true
		# 命中测试只用原有 UI 的遮挡规则；不枚举/点击遮罩下面的控件。
		_motion(_origin)
		var hovered := get_viewport().gui_get_hovered_control()
		_scroll = _scroll_target(hovered)
		if not is_instance_valid(_scroll) and _direct_drag(hovered):
			_button(_origin, true)
			_mouse_down = true
	if not _dragging: return
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical -= roundi(relative.y)
		_scroll.scroll_horizontal -= roundi(relative.x)
	elif _mouse_down:
		_motion(at, relative, true)
	else:
		_wheel_distance += relative.y
		if absf(_wheel_distance) >= 36.0:
			var wheel := InputEventMouseButton.new()
			wheel.position = _origin
			wheel.global_position = _origin
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if _wheel_distance < 0 else MOUSE_BUTTON_WHEEL_UP
			wheel.pressed = true
			get_viewport().push_input(wheel, true)
			wheel = wheel.duplicate()
			wheel.pressed = false
			get_viewport().push_input(wheel, true)
			_wheel_distance = 0.0

func _scroll_target(control: Control) -> ScrollContainer:
	# 战斗中的卡牌排序、典籍拖放、滑块、地图查看器优先使用原来的拖动逻辑。
	var parent: Node = control
	while is_instance_valid(parent):
		if parent is RelicDropCell or parent is Range or parent is MapViewer:
			return null
		if parent is ScrollContainer:
			if _direct_drag(control):
				# 竖向快速滑动用于滚动出牌列/背包；长按后拖动仍是排序/装配。
				var offset := _at - _origin
				var bar: VScrollBar = parent.get_v_scroll_bar()
				if not _held and absf(offset.y) > absf(offset.x) * 1.25 and bar.max_value > bar.page + 1.0:
					return parent
				return null
			return parent
		parent = parent.get_parent()
	return null

func _direct_drag(control: Control) -> bool:
	var parent: Node = control
	while is_instance_valid(parent):
		if parent is RelicDragItem or parent is RelicDropCell or parent is Range or parent is MapViewer:
			return true
		# 只允许命中卡牌本身时拖动，不能越过上层弹窗命中下方手牌。
		if parent.name in [&"HandScroll", &"PlayScroll"]:
			var scene := parent.get_parent()
			if scene.has_method("_hand_card_at"):
				return not scene._hand_card_at(_origin).is_empty() or not scene._play_card_at(_origin).is_empty()
		parent = parent.get_parent()
	return false

func _finish(at: Vector2, canceled := false) -> void:
	var valid_scene := _scene_identity() == _scene_id
	_finger = -1
	if _mouse_down:
		# 取消手势时在屏外释放，不能把拖动变成购买或出牌。
		_button(at if not canceled and valid_scene else Vector2(-10000, -10000), false)
	elif not canceled and valid_scene and not _held and not _dragging:
		_motion(at)
		_button(at, true)
		_button(at, false)
	_mouse_down = false
	_scroll = null
	_dragging = false
	# 清掉虚拟鼠标，避免触屏抬手后卡牌一直保持悬停。
	_clear_hover_later(_hover_revision)

func _clear_hover_later(revision: int) -> void:
	await get_tree().process_frame
	if revision == _hover_revision and _finger < 0:
		_motion(Vector2(-10000, -10000))

func _motion(at: Vector2, relative := Vector2.ZERO, pressed := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_viewport().push_input(event, true)

func _button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_viewport().push_input(event, true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _finger >= 0:
		_finish(_at, true)

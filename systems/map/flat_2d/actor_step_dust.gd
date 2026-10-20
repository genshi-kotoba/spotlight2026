extends Node2D
## 脚步尘：按显示空间的跨步距离触发，程序绘制，不引入贴图资源。
## 由 map_demo 每帧喂入演员的显示空间位置与当帧位移；载入、换层造成的瞬移由调用方过滤。

## 每走这么长的显示空间距离落一个尘点，左右脚交替。
const STEP_DISTANCE := 12.0
const FOOT_OFFSET := 6.0
const GROUND_OFFSET := 7.0
const LIFE := 0.55
const RADIUS := 9.0
const DRIFT := 11.0
## 浮雕地层是深色纹理，尘点太淡就完全看不出来，峰值浓度给到肉眼能分辨的量级。
const COLOR := Color(0.72, 0.69, 0.60)
const MAX_ALPHA := 0.45
const MAX_PUFFS := 24

var _puffs: Array = []
var _travelled := 0.0
var _foot := 1.0

func _init() -> void:
	z_index = 6

## actor_position 与 motion 都在显示空间，与 _player.position 同一坐标。
func update(actor_position: Vector2, motion: Vector2, delta: float) -> void:
	_advance(delta)
	var distance := motion.length()
	if distance > 0.0001:
		_travelled += distance
		var direction := motion / distance
		var side := Vector2(-direction.y, direction.x)
		while _travelled >= STEP_DISTANCE:
			_travelled -= STEP_DISTANCE
			_foot = -_foot
			# 尘点落在跨过步长阈值的位置，也就是当前落点再往回退剩余量。
			_spawn(actor_position - direction * _travelled
				+ side * (FOOT_OFFSET * _foot) + Vector2(0, GROUND_OFFSET), direction)
	else:
		_travelled = 0.0
	queue_redraw()

func _advance(delta: float) -> void:
	var alive: Array = []
	for puff in _puffs:
		puff["age"] += delta
		if puff["age"] < LIFE:
			alive.append(puff)
	_puffs = alive
	visible = not _puffs.is_empty()

func _spawn(at: Vector2, direction: Vector2) -> void:
	if _puffs.size() >= MAX_PUFFS:
		_puffs.remove_at(0)
	_puffs.append({"position": at, "age": 0.0, "drift": direction * DRIFT})

func _draw() -> void:
	for puff in _puffs:
		var progress: float = puff["age"] / LIFE
		var radius := RADIUS * (0.8 + 0.5 * progress)
		var alpha := (1.0 - progress) * MAX_ALPHA
		var at: Vector2 = puff["position"] + puff["drift"] * progress
		draw_set_transform(at, 0.0, Vector2(1.0, 0.6))
		draw_circle(Vector2.ZERO, radius, Color(COLOR.r, COLOR.g, COLOR.b, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

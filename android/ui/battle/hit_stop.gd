class_name HitStop
extends Node

## 顿帧：把 Engine.time_scale 压到 slow，保持 duration 的真实秒数后恢复到触发前的倍率。
##
## 只做这一件事，不持有游戏状态，由场景挂载，因此不新增 autoload。
## 恢复目标取触发前的倍率而不是写死 1.0，慢放与顿帧才能叠加；
## 重叠触发只延长本次顿感，不产生第二次恢复动作。

const DEFAULT_SLOW := 0.05

var _restore_target := 1.0
var _until_ms := 0
var _pending := false


## duration 是真实秒数，不受当前 time_scale 影响；slow 是顿帧期间的目标倍率。
func hit_stop(duration: float, slow: float = DEFAULT_SLOW) -> void:
	if duration <= 0.0:
		return
	if not _pending:
		_restore_target = Engine.time_scale
	_until_ms = maxi(_until_ms, Time.get_ticks_msec() + int(round(duration * 1000.0)))
	Engine.time_scale = minf(Engine.time_scale, slow)
	if _pending:
		return
	_pending = true
	_run()


func _run() -> void:
	# 按真实帧推进。受 time_scale 影响的计时器在倍率被压低后不再前进，不能用。
	while _pending and is_inside_tree() and Time.get_ticks_msec() < _until_ms:
		await get_tree().process_frame
	_pending = false
	_until_ms = 0
	Engine.time_scale = _restore_target


func _exit_tree() -> void:
	# 顿帧中途场景被释放时必须还原，否则整个游戏永久停在低倍率。
	if _pending:
		_pending = false
		_until_ms = 0
		Engine.time_scale = _restore_target

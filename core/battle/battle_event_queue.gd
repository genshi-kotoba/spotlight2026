class_name BattleEventQueue
extends RefCounted

## 普通指令 FIFO；当前事件的反应按发出顺序，在原续接点之前完成。
## 队列推进不递归。暂停时保留全部续接事件，提交输入后原位恢复。
signal event_processed(event: BattleEvent)
signal limit_reached

const MAX_EVENTS_PER_DRAIN := 50000
const HISTORY_LIMIT := 2048

var current: BattleEvent
var processing := false
var paused := false
var max_events_per_drain := MAX_EVENTS_PER_DRAIN
var history: Array[Dictionary] = []
var _pending: Array[BattleEvent] = []
var _children: Array[BattleEvent] = []
var _resume_events: Array[BattleEvent] = []


func enqueue(event: BattleEvent) -> void:
	if processing:
		_children.append(event)
	elif paused:
		_resume_events.append(event)
	else:
		_pending.append(event)


func drain(dispatch: Callable) -> Error:
	if processing or paused:
		return OK
	processing = true
	var processed := 0
	while not _pending.is_empty() and not paused:
		if processed >= maxi(1, max_events_per_drain):
			clear()
			processing = false
			current = null
			limit_reached.emit()
			return ERR_CYCLIC_LINK
		current = _pending.pop_front()
		_children.clear()
		dispatch.call(current)
		history.append(current.snapshot())
		if history.size() > HISTORY_LIMIT:
			history.pop_front()
		event_processed.emit(current)
		# 先处理本事件派生的反应，再执行下一效果/下一张牌/下一阶段。
		# 观察信号中提交的事件也属于当前反应，不能在下一次循环中丢失。
		if not _children.is_empty():
			_children.append_array(_pending)
			_pending = _children
			_children = []
		processed += 1
	current = null
	processing = false
	return OK


func pause() -> void:
	paused = true


func resume() -> void:
	paused = false
	if not _resume_events.is_empty():
		_resume_events.append_array(_pending)
		_pending = _resume_events
		_resume_events = []


func pending_count() -> int:
	return _pending.size() + _children.size() + _resume_events.size()


func clear() -> void:
	_pending.clear()
	_children.clear()
	_resume_events.clear()
	paused = false

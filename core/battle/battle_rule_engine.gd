class_name BattleRuleEngine
extends RefCounted

## 事件类型 -> 有序规则（条件、优先级、处理器）。规则可修改指令或产生新事件。
var queue := BattleEventQueue.new()
var last_error: Error = OK
var _rules: Dictionary = {}
var _ids: Dictionary = {}
var _serial := 0
var _rule_order := 0


func register_rule(id: String, event_type: String, handler: Callable,
		priority: int = 100, condition: Callable = Callable()) -> Error:
	if id.is_empty() or _ids.has(id) or not handler.is_valid():
		return ERR_INVALID_PARAMETER
	_rule_order += 1
	var rules: Array = _rules.get(event_type, [])
	rules.append({"id": id, "handler": handler, "priority": priority,
		"condition": condition, "order": _rule_order})
	rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.priority < b.priority if a.priority != b.priority else a.order < b.order)
	_rules[event_type] = rules
	_ids[id] = event_type
	return OK


func remove_rules_for(owner: Object) -> void:
	for type: String in _rules.keys():
		var remaining: Array = []
		for rule: Dictionary in _rules[type]:
			if rule.handler.get_object() == owner:
				_ids.erase(rule.id)
			else:
				remaining.append(rule)
		_rules[type] = remaining


func publish(type: String, payload: Dictionary = {}, metadata: Dictionary = {},
		new_chain: bool = false) -> BattleEvent:
	_serial += 1
	var event := BattleEvent.new()
	event.id = _serial
	event.type = type
	event.payload = payload.duplicate(true)
	var parent := queue.current
	event.parent_id = parent.id if parent != null else 0
	event.root_id = parent.root_id if parent != null and not new_chain else event.id
	event.metadata = parent.metadata.duplicate(true) if parent != null else {}
	event.metadata.merge(metadata, true)
	queue.enqueue(event)
	return event


func submit(type: String, payload: Dictionary = {}, metadata: Dictionary = {}) -> Error:
	publish(type, payload, metadata)
	return flush()


func flush() -> Error:
	if queue.processing or queue.paused:
		return OK
	last_error = OK
	var error := queue.drain(_dispatch)
	if error != OK:
		last_error = error
	return last_error


func _dispatch(event: BattleEvent) -> void:
	# 快照使规则在回调中增删时，不改变当前事件剩余处理顺序。
	var matching: Array = _rules.get(event.type, []).duplicate()
	for rule: Dictionary in matching:
		if not rule.handler.is_valid():
			continue
		var condition: Callable = rule.condition
		if condition.is_valid() and not bool(condition.call(event)):
			continue
		rule.handler.call(event)

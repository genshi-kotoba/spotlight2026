class_name BattleEvent
extends RefCounted

## 一次指令或已发生事实；同一根事件共享 root_id，便于追踪连锁来源。
var id := 0
var type := ""
var payload: Dictionary = {}
var metadata: Dictionary = {}
var parent_id := 0
var root_id := 0


func snapshot() -> Dictionary:
	return {"id": id, "type": type, "parent_id": parent_id, "root_id": root_id,
		"payload": _log_value(payload), "metadata": metadata.duplicate(true)}


static func _log_value(value: Variant) -> Variant:
	if value is Resource:
		return {"resource": value.resource_path, "class": value.get_class()}
	if value is Dictionary:
		var result := {}
		for key: Variant in value:
			result[String(key)] = _log_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_log_value(item))
		return result
	return value

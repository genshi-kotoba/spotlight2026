class_name MapNodePlan
extends RefCounted

## 一张地图已经生成并应随局内存档保存的节点分布。
## key 是稳定的六边形逻辑坐标，value 是 MapNodeKind.Type。
const SNAPSHOT_VERSION := 1

var map_id: String
var assignments: Dictionary = {}


func _init(p_map_id: String = "") -> void:
	map_id = p_map_id


func assign(coord: Vector2i, kind: int) -> void:
	assignments[coord] = kind


func kind_at(coord: Vector2i) -> int:
	return assignments.get(coord, MapNodeKind.Type.NONE)


func has_node(coord: Vector2i) -> bool:
	return assignments.has(coord)


func node_id(coord: Vector2i) -> String:
	return "hex:%d,%d" % [coord.x, coord.y]


func count(kind: int) -> int:
	var total := 0
	for assigned: int in assignments.values():
		if assigned == kind:
			total += 1
	return total


## 测试、日志与存档校验使用的稳定摘要；不依赖 Dictionary 遍历顺序。
func signature() -> String:
	var entries := PackedStringArray()
	for coord: Vector2i in assignments:
		entries.append("%+06d,%+06d=%02d" % [coord.x, coord.y, assignments[coord]])
	entries.sort()
	return "|".join(entries)


## JSON 友好的业务快照。随机服务快照不能替代这份已经生成的结果。
func to_dictionary() -> Dictionary:
	var nodes: Array = []
	var coords: Array[Vector2i] = []
	for coord: Vector2i in assignments:
		coords.append(coord)
	coords.sort_custom(_coord_before)
	for coord in coords:
		nodes.append({
			"id": node_id(coord),
			"q": coord.x,
			"r": coord.y,
			"kind": assignments[coord],
		})
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"map_id": map_id,
		"nodes": nodes,
	}


## 从业务存档恢复。失败返回 null，不留下半份计划。
static func from_dictionary(data: Dictionary) -> MapNodePlan:
	if not _integer_equals(data.get("snapshot_version"), SNAPSHOT_VERSION):
		push_error("MapNodePlan: incompatible snapshot version")
		return null
	var saved_map_id: Variant = data.get("map_id")
	var nodes: Variant = data.get("nodes")
	if not saved_map_id is String or saved_map_id.strip_edges().is_empty() or not nodes is Array:
		push_error("MapNodePlan: invalid map id or node list")
		return null

	var restored := MapNodePlan.new(saved_map_id)
	for entry: Variant in nodes:
		if not entry is Dictionary:
			push_error("MapNodePlan: invalid node record")
			return null
		var raw_q: Variant = entry.get("q")
		var raw_r: Variant = entry.get("r")
		var raw_kind: Variant = entry.get("kind")
		if not _is_integer(raw_q) or not _is_integer(raw_r) or not _is_integer(raw_kind):
			push_error("MapNodePlan: node q/r/kind must be integers")
			return null
		var coord := Vector2i(int(raw_q), int(raw_r))
		var kind := int(raw_kind)
		if restored.assignments.has(coord) or kind < MapNodeKind.Type.START \
				or kind > MapNodeKind.Type.SHOP or entry.get("id") != restored.node_id(coord):
			push_error("MapNodePlan: duplicate, unsupported kind, or mismatched node id")
			return null
		restored.assign(coord, kind)
	return restored


static func _coord_before(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y if a.x == b.x else a.x < b.x


static func _is_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == floorf(float(value))


static func _integer_equals(value: Variant, expected: int) -> bool:
	return _is_integer(value) and int(value) == expected

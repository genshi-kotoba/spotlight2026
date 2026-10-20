extends RefCounted
## 纯分配策略：不读存档、不执行怪物文本，也不消费地图/战斗已有随机流。
const GRADES := {"battle": "普通", "elite": "精英", "boss": "BOSS"}
const PROTOCOL := "monster-encounters-v1"
var last_error := ""

static func roster_from_catalog(records: Array) -> Array:
	var roster: Array = []
	var pattern := RegEx.new()
	pattern.compile("^(普通|精英|BOSS) · 第([1-4])层$")
	for record: Dictionary in records:
		var found := pattern.search(str(record.get("type", "")))
		if found == null:
			return []
		roster.append({"id": record.id, "name": record.name, "art_path": record.art_path,
			"grade": found.get_string(1), "floor_index": int(found.get_string(2))})
	return roster if valid_roster(roster) else []

static func valid_roster(roster: Array) -> bool:
	var ids := {}
	for raw: Variant in roster:
		if not raw is Dictionary or not raw.get("id") is String or raw.id.is_empty() \
				or ids.has(raw.id) or raw.get("grade") not in GRADES.values() \
				or not raw.get("name") is String or not raw.get("art_path") is String \
				or not raw.get("floor_index") is int and not raw.get("floor_index") is float:
			return false
		if float(raw.floor_index) != floorf(float(raw.floor_index)) or int(raw.floor_index) not in [1, 2, 3, 4]:
			return false
		ids[raw.id] = true
	return not roster.is_empty()

static func candidates(roster: Array, floor_index: int, node_type: String) -> Array:
	var found: Array = []
	for record: Dictionary in roster:
		if int(record.floor_index) == floor_index and record.grade == GRADES.get(node_type, ""):
			found.append(record.id)
	found.sort_custom(func(a: String, b: String): return a.naturalnocasecmp_to(b) < 0)
	return found

func assign(snapshot: Dictionary, roster: Array) -> Dictionary:
	last_error = ""
	if not valid_roster(roster):
		last_error = "怪物候选表无效"
		return {}
	var result := snapshot.duplicate(true)
	# 独立、可重新推导的地址空间；迁移旧地图也不会重置共享 SeedService。
	var source := SeedRegistry.new(PROTOCOL)
	source.begin_run(str(snapshot.seed))
	var counts := {}
	var nodes: Array = result.nodes.duplicate()
	nodes.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.id) < str(b.id))
	for node: Dictionary in nodes:
		if not GRADES.has(node.type):
			continue
		var pool := candidates(roster, int(result.floor_index), str(node.type))
		if pool.is_empty():
			last_error = "第%d层的%s节点没有可选怪物" % [int(result.floor_index), GRADES[node.type]]
			return {}
		if _is_summit(snapshot) and node.type == "boss":
			if "23" not in pool:
				last_error = "顶端固定 Boss 23 不在第四层 BOSS 候选表"
				return {}
			node.content_id = "23"
			continue
		var least := 2147483647
		for id: String in pool:
			least = mini(least, int(counts.get(id, 0)))
		var choices: Array = []
		for id: String in pool:
			if int(counts.get(id, 0)) == least:
				choices.append(id)
		var stream := source.get_stream(&"map.encounters", [str(result.map_id), str(node.id)])
		node.content_id = str(stream.pick(choices))
		counts[node.content_id] = int(counts.get(node.content_id, 0)) + 1
	return result

static func _is_summit(snapshot: Dictionary) -> bool:
	return int(snapshot.get("floor_index", 0)) == 4 and snapshot.get("generation_config", {}).get("template", "") == "summit-v1"

static func valid_assignments(snapshot: Dictionary, roster: Array) -> bool:
	for node: Dictionary in snapshot.get("nodes", []):
		if _is_summit(snapshot) and node.get("type") == "boss" and node.get("content_id") != "23":
			return false
		if GRADES.has(node.get("type", "")) and node.get("content_id") not in candidates(roster, int(snapshot.floor_index), node.type):
			return false
	return true

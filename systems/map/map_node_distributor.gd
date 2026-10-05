class_name MapNodeDistributor
extends RefCounted

## 第一张地图的策划配比。
const BATTLE_COUNT := 3
const ELITE_COUNT := 1
const BOSS_COUNT := 1
const EVENT_COUNT_MIN := 7
const EVENT_COUNT_MAX := 9


## 在可达且可通行的格子上确定性分配节点。
## RandomStream 由调用方通过 map.nodes + [map_id] 取得，便于独立测试和复用。
static func generate_first_map(layout: MapLayout, stream: RandomStream,
		map_id: String) -> MapNodePlan:
	if layout == null or stream == null or map_id.strip_edges().is_empty():
		push_error("MapNodeDistributor: layout, stream and map_id are required")
		return null
	if not layout.has_start:
		push_error("MapNodeDistributor: layout needs a start tile")
		return null

	var event_roll: Variant = stream.int_range(EVENT_COUNT_MIN, EVENT_COUNT_MAX + 1)
	if event_roll == null:
		return null
	var event_count := int(event_roll)

	var reachable := MapPathfinder.reachable_from(layout.start_coord, layout.can_move)
	var candidates: Array[Vector2i] = []
	for coord: Vector2i in reachable:
		if coord == layout.start_coord:
			continue
		var tile := layout.tile_at(coord)
		if tile != null and tile.is_passable():
			candidates.append(coord)
	candidates.sort_custom(_coord_before)

	var required := BATTLE_COUNT + ELITE_COUNT + BOSS_COUNT + event_count
	if candidates.size() < required:
		push_error("MapNodeDistributor: need %d candidate tiles, got %d" % [required, candidates.size()])
		return null

	# Boss 只在离起点最远的两圈中抽取，既保留种子差异，也避免刷在门口。
	var farthest := 0
	for coord in candidates:
		farthest = maxi(farthest, HexCoord.distance(layout.start_coord, coord))
	var boss_pool: Array[Vector2i] = []
	for coord in candidates:
		if HexCoord.distance(layout.start_coord, coord) >= farthest - 1:
			boss_pool.append(coord)
	var boss_value: Variant = stream.pick(boss_pool)
	if boss_value == null:
		return null
	var boss_coord: Vector2i = boss_value
	candidates.erase(boss_coord)

	if stream.shuffle_in_place(candidates) != OK:
		return null

	var plan := MapNodePlan.new(map_id)
	plan.assign(layout.start_coord, MapNodeKind.Type.START)
	plan.assign(boss_coord, MapNodeKind.Type.BOSS)

	var cursor := 0
	for _index in ELITE_COUNT:
		plan.assign(candidates[cursor], MapNodeKind.Type.ELITE)
		cursor += 1
	for _index in BATTLE_COUNT:
		plan.assign(candidates[cursor], MapNodeKind.Type.BATTLE)
		cursor += 1
	for _index in event_count:
		plan.assign(candidates[cursor], MapNodeKind.Type.EVENT)
		cursor += 1
	return plan


static func _coord_before(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y if a.x == b.x else a.x < b.x

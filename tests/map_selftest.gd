extends SceneTree

## 地图系统的自测。用 --script 跑，不依赖渲染。
##
##   godot --headless --path . --script res://tests/map_selftest.gd
##
## 所有断言都从布局里现查特征格，不写死坐标。换演示地图时这份测试不用跟着改。

var _failures := 0


func _initialize() -> void:
	var layout := MapLayout.from_text(MapBuilder.DEFAULT_LAYOUT)

	_test_map_built(layout)
	_test_start_exists(layout)
	_test_step_passable(layout)
	_test_climb_blocked(layout)
	_test_climb_limit_uses_world_height()
	_test_wall_blocks_same_height(layout)
	_test_symmetric(layout)
	_test_pathfinding(layout)
	_test_reachable(layout)
	_test_seeded_node_distribution(layout)
	_test_geometry_normals(layout)

	if _failures == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _failures)
	quit(_failures)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		_failures += 1
		print("  失败  %s  %s" % [label, detail])


func _height_of(layout: MapLayout, coord: Vector2i) -> int:
	var tile := layout.tile_at(coord)
	return tile.height if tile != null else -1


func _test_map_built(layout: MapLayout) -> void:
	print("[地图构建]")
	_check("地图非空", layout.size() > 0, "格子数 %d" % layout.size())

	var heights := {}
	for coord in layout.tiles:
		heights[layout.tiles[coord].height] = true
	_check("至少三种高度", heights.size() >= 3, "实际 %d 种" % heights.size())


func _test_start_exists(layout: MapLayout) -> void:
	print("[起点]")
	_check("布局里有起点标记 @", layout.has_start)
	if layout.has_start:
		_check("起点格存在", layout.tile_at(layout.start_coord) != null)
		_check("起点格可通行", layout.tile_at(layout.start_coord).is_passable())


func _test_step_passable(layout: MapLayout) -> void:
	print("[限值以内：可走]")
	var pair := _find_delta_pair(layout, 1)
	_check("存在高差 1 级的相邻格", pair.size() == 2)
	if pair.size() == 2:
		_check("高差 1 级可通行", layout.can_move(pair[0], pair[1]),
			"高度 %d 与 %d" % [_height_of(layout, pair[0]), _height_of(layout, pair[1])])


func _test_climb_blocked(layout: MapLayout) -> void:
	print("[超过限值：不可走]")
	var pair := _find_cliff_pair(layout)
	_check("存在超过限值的相邻格", pair.size() == 2)
	if pair.size() == 2:
		_check("超过限值不可通行", not layout.can_move(pair[0], pair[1]),
			"高度 %d 与 %d" % [_height_of(layout, pair[0]), _height_of(layout, pair[1])])
		_check("反向同样不可通行", not layout.can_move(pair[1], pair[0]))


## 爬升限值说的是世界高度，不是层数。
## 用一条两格的合成地图直接探边界，不依赖演示地图里恰好有合适的高差。
func _test_climb_limit_uses_world_height() -> void:
	print("[爬升限值按世界高度判]")
	var a := HexCoord.offset_to_axial(0, 0)
	var b := HexCoord.offset_to_axial(1, 0)

	# 两格文本，高度分别是 0 与 2，即高差 2 级
	var two_levels := MapLayout.from_text("02", 0.25)
	_check("台阶 0.25、高差 2 级 = 0.5，恰好等于限值，可上",
		two_levels.can_move(a, b),
		"实际 %.2f，限值 %.2f" % [2 * 0.25, MapLayout.CLIMB_LIMIT_WORLD])

	var three_levels := MapLayout.from_text("03", 0.25)
	_check("台阶 0.25、高差 3 级 = 0.75，超过限值，不可上",
		not three_levels.can_move(a, b),
		"实际 %.2f" % (3 * 0.25))

	var one_level := MapLayout.from_text("01", 0.25)
	_check("台阶 0.25、高差 1 级 = 0.25，可上", one_level.can_move(a, b))

	# 同样 2 级，把台阶调粗一倍，世界高差变成 1.0，判定必须跟着变
	var coarse := MapLayout.from_text("02", 0.5)
	_check("台阶调到 0.5 后，同样 2 级变成 1.0，不可上",
		not coarse.can_move(a, b),
		"实际 %.2f" % (2 * 0.5))


func _test_wall_blocks_same_height(layout: MapLayout) -> void:
	print("[地形阻挡：同高度的墙]")
	var pair := _find_wall_pair(layout)
	_check("存在墙格与同高度的可通行邻格", pair.size() == 2)
	if pair.size() == 2:
		var plain: Vector2i = pair[0]
		var wall: Vector2i = pair[1]
		_check("墙格地形不可通行", not layout.tile_at(wall).is_passable())
		_check("两者高度相同", _height_of(layout, wall) == _height_of(layout, plain))
		_check("同高度下墙仍然阻挡", not layout.can_move(plain, wall))
		_check("墙这一侧也走不出去", not layout.can_move(wall, plain))


func _test_symmetric(layout: MapLayout) -> void:
	print("[上下对称]")
	var mismatched := 0
	for coord in layout.tiles:
		for neighbor in HexCoord.neighbors(coord):
			if not layout.has_tile(neighbor):
				continue
			if layout.can_move(coord, neighbor) != layout.can_move(neighbor, coord):
				mismatched += 1
	_check("任意相邻两格的可通行性双向一致", mismatched == 0, "不一致 %d 对" % mismatched)


func _test_pathfinding(layout: MapLayout) -> void:
	print("[寻路]")
	var from := layout.start_coord
	var to := _find_highest(layout)
	var path := layout.find_path(from, to)

	_check("能规划出多步路径", path.size() >= 2, "路径长度 %d" % path.size())
	_check("路径起点正确", path.size() > 0 and path[0] == from)
	_check("路径终点正确", path.size() > 0 and path[path.size() - 1] == to)

	var illegal := 0
	for i in range(path.size() - 1):
		if not layout.can_move(path[i], path[i + 1]):
			illegal += 1
	_check("路径每一段都合法", illegal == 0, "非法段 %d" % illegal)

	var steep := 0
	for i in range(path.size() - 1):
		var rise := absi(_height_of(layout, path[i]) - _height_of(layout, path[i + 1])) * layout.step_height
		if rise > MapLayout.CLIMB_LIMIT_WORLD:
			steep += 1
	_check("路径每一段高差不超过限值", steep == 0, "超限 %d 段" % steep)

	var self_path := layout.find_path(from, from)
	_check("起点等于终点时返回单格路径", self_path.size() == 1)


func _test_reachable(layout: MapLayout) -> void:
	print("[可达集合]")
	var reachable := MapPathfinder.reachable_from(layout.start_coord, layout.can_move)
	_check("可达集合包含起点", reachable.has(layout.start_coord))
	_check("可达格数少于总格数", reachable.size() < layout.size(),
		"可达 %d / 总 %d" % [reachable.size(), layout.size()])

	var wall_reachable := 0
	for coord in layout.tiles:
		if layout.tiles[coord].is_passable():
			continue
		if reachable.has(coord):
			wall_reachable += 1
	_check("墙体不在可达集合内", wall_reachable == 0, "混入 %d 格" % wall_reachable)

	# 最高处必须走得到，这一条验证「一级一级爬台阶」确实能爬到顶
	var highest := _find_highest(layout)
	_check("最高格可达", reachable.has(highest),
		"高度 %d" % _height_of(layout, highest))


func _test_seeded_node_distribution(layout: MapLayout) -> void:
	print("[地图 × 种子集成]")
	var first := _generate_plan(layout, "integration-seed", "map-001")
	var repeated := _generate_plan(layout, "integration-seed", "map-001")
	var changed := _generate_plan(layout, "another-seed", "map-001")
	var isolated := _generate_plan(layout, "integration-seed", "map-001", true)

	_check("同主种子与地图身份产生相同节点", first != null and repeated != null \
		and first.signature() == repeated.signature())
	_check("其他随机域的消费不改变地图节点", first != null and isolated != null \
		and first.signature() == isolated.signature())
	_check("不同主种子产生不同节点", first != null and changed != null \
		and first.signature() != changed.signature())
	if first == null:
		return

	_check("分配 3 个普通战斗", first.count(MapNodeKind.Type.BATTLE) == 3)
	_check("分配 1 个精英", first.count(MapNodeKind.Type.ELITE) == 1)
	_check("分配 1 个 Boss", first.count(MapNodeKind.Type.BOSS) == 1)
	_check("分配 7 至 9 个事件", first.count(MapNodeKind.Type.EVENT) >= 7 \
		and first.count(MapNodeKind.Type.EVENT) <= 9)
	_check("起点被标记且不被其他节点覆盖",
		first.kind_at(layout.start_coord) == MapNodeKind.Type.START)
	var restored := MapNodePlan.from_dictionary(first.to_dictionary())
	_check("节点计划可无损写入并恢复业务存档", restored != null \
		and restored.signature() == first.signature() and restored.map_id == first.map_id)

	var reachable := MapPathfinder.reachable_from(layout.start_coord, layout.can_move)
	var invalid := 0
	var boss_distance := -1
	var farthest := 0
	for coord: Vector2i in reachable:
		if coord != layout.start_coord:
			farthest = maxi(farthest, HexCoord.distance(layout.start_coord, coord))
	for coord: Vector2i in first.assignments:
		var tile := layout.tile_at(coord)
		if tile == null or not tile.is_passable() or not reachable.has(coord):
			invalid += 1
		if first.kind_at(coord) == MapNodeKind.Type.BOSS:
			boss_distance = HexCoord.distance(layout.start_coord, coord)
	_check("全部节点位于可达可通行格", invalid == 0, "非法节点 %d" % invalid)
	_check("Boss 位于距起点最远两圈", boss_distance >= farthest - 1,
		"Boss 距离 %d，最远 %d" % [boss_distance, farthest])


func _generate_plan(layout: MapLayout, seed_text: String, map_id: String,
		consume_other_domain := false) -> MapNodePlan:
	var registry := SeedRegistry.new("map-integration-test-v1")
	if registry.begin_run(seed_text).is_empty():
		return null
	if consume_other_domain:
		var shop := registry.get_stream(RandomDomains.SHOP, [map_id, "hex:0,0"])
		if shop == null or shop.pick(["a", "b", "c"]) == null:
			return null
	var stream := registry.get_stream(RandomDomains.MAP_NODES, [map_id])
	return MapNodeDistributor.generate_first_map(layout, stream, map_id)


func _test_geometry_normals(layout: MapLayout) -> void:
	print("[几何法线]")
	var mesh := MapMeshBuilder.build(layout)
	var arrays := mesh.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	var up := 0
	var down := 0
	for n in normals:
		if n.y > 0.5:
			up += 1
		elif n.y < -0.5:
			down += 1

	# 顶面和描边朝上，侧壁接近水平。法线若算反，朝下的会反超朝上的，
	# 表现为整张地图被当成背面受光，又暗又平。
	_check("朝上的法线远多于朝下的", up > down * 4, "上 %d 下 %d" % [up, down])

	var flat := MapMeshBuilder.build_flat_hex(1.0, 0.02, Color.WHITE)
	var flat_normals: PackedVector3Array = flat.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var flat_up := 0
	for n in flat_normals:
		if n.y > 0.5:
			flat_up += 1
	_check("高亮面片法线朝上", flat_up == flat_normals.size(),
		"%d / %d" % [flat_up, flat_normals.size()])


## 找一对高差恰好等于 delta 的相邻格，返回 [a, b]。找不到返回空数组。
func _find_delta_pair(layout: MapLayout, delta: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for coord in layout.tiles:
		var a: MapTile = layout.tiles[coord]
		if not a.is_passable():
			continue
		for neighbor in HexCoord.neighbors(coord):
			var b: MapTile = layout.tiles.get(neighbor)
			if b == null or not b.is_passable():
				continue
			if absi(a.height - b.height) == delta:
				result.append(coord)
				result.append(neighbor)
				return result
	return result


## 找一对高差大于等于 2 的相邻格，返回 [低, 高]。找不到返回空数组。
func _find_cliff_pair(layout: MapLayout) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for coord in layout.tiles:
		var a: MapTile = layout.tiles[coord]
		if not a.is_passable():
			continue
		for neighbor in HexCoord.neighbors(coord):
			var b: MapTile = layout.tiles.get(neighbor)
			if b == null or not b.is_passable():
				continue
			if absi(a.height - b.height) * layout.step_height > MapLayout.CLIMB_LIMIT_WORLD:
				if a.height < b.height:
					result.append(coord)
					result.append(neighbor)
				else:
					result.append(neighbor)
					result.append(coord)
				return result
	return result


## 找一格墙，以及它旁边高度相同且可通行的邻格，返回 [可通行格, 墙格]。
func _find_wall_pair(layout: MapLayout) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for coord in layout.tiles:
		var wall: MapTile = layout.tiles[coord]
		if wall.is_passable():
			continue
		for neighbor in HexCoord.neighbors(coord):
			var plain: MapTile = layout.tiles.get(neighbor)
			if plain == null or not plain.is_passable():
				continue
			if plain.height == wall.height:
				result.append(neighbor)
				result.append(coord)
				return result
	return result


func _find_highest(layout: MapLayout) -> Vector2i:
	var best := Vector2i.ZERO
	var best_height := -1
	for coord in layout.tiles:
		var tile: MapTile = layout.tiles[coord]
		if tile.height > best_height:
			best_height = tile.height
			best = coord
	return best

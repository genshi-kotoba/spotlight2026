class_name MapPathfinder
extends RefCounted

## 六边形网格上的 BFS 寻路。
##
## 本项目没有行动点，所有可通行边的代价相同，图是无权的。
## 无权图下 BFS 就是最优解，A* 的启发式会退化为 0，多写的都是死代码。
##
## 本类不持有地图数据，通行判定通过 Callable 传入，方便单独测试。

## 返回含起点与终点的路径。不可达返回空数组。
## can_move 是接收两个 Vector2i 的可调用对象。
static func find_path(from: Vector2i, to: Vector2i, can_move: Callable) -> Array[Vector2i]:
	var path: Array[Vector2i] = []

	if from == to:
		path.append(from)
		return path

	# 这里不要加「can_move(from, to) 为假就返回空」的提前判断。
	# 那只在目标与起点相邻时成立，会让多步寻路直接返回空路径。
	# 可达性交给下面的 BFS 判定。

	var frontier: Array[Vector2i] = [from]
	var came_from := {from: from}

	while not frontier.is_empty():
		var next_frontier: Array[Vector2i] = []

		for current in frontier:
			for neighbor in HexCoord.neighbors(current):
				if came_from.has(neighbor):
					continue
				if not can_move.call(current, neighbor):
					continue

				came_from[neighbor] = current

				if neighbor == to:
					return _retrace(came_from, from, to)

				next_frontier.append(neighbor)

		frontier = next_frontier

	return path


## 从起点出发能无阻到达的全部格子，含起点。
## 迷雾要的「当前能无阻通达区域」就是它，与寻路共用同一次遍历逻辑。
static func reachable_from(from: Vector2i, can_move: Callable) -> Dictionary:
	var visited := {from: true}
	var frontier: Array[Vector2i] = [from]

	while not frontier.is_empty():
		var next_frontier: Array[Vector2i] = []
		for current in frontier:
			for neighbor in HexCoord.neighbors(current):
				if visited.has(neighbor):
					continue
				if not can_move.call(current, neighbor):
					continue
				visited[neighbor] = true
				next_frontier.append(neighbor)
		frontier = next_frontier

	return visited


static func _retrace(came_from: Dictionary, from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var current := to
	while current != from:
		path.append(current)
		current = came_from[current]
	path.append(from)
	path.reverse()
	return path

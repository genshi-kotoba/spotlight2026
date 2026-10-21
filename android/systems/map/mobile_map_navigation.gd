extends RefCounted
## 在已探索地块上寻路；碰撞、关口和探索全部服从原 Session。
const Hex := preload("res://systems/map/hex_coord.gd")
const RING_RADIUS := 0.68
const LINK_DISTANCE := 1.05
var _astar := AStar2D.new()
var _signature := ""
var _bins: Dictionary = {}

func route(session: RefCounted, target: Vector2) -> PackedVector2Array:
	prepare(session)
	if _astar.get_point_count() == 0: return PackedVector2Array()
	var start := _astar.get_available_point_id()
	_astar.add_point(start, session.actor_plane)
	_connect_near(session, start, session.actor_plane)
	var candidates: Array = []
	for id in _astar.get_point_ids():
		if id == start: continue
		var distance: float = _astar.get_point_position(id).distance_squared_to(target)
		if distance <= 2.2 * 2.2: candidates.append([distance, id])
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	var result := PackedVector2Array()
	for candidate in candidates.slice(0, 16):
		result = _astar.get_point_path(start, int(candidate[1]))
		if not result.is_empty(): break
	_astar.remove_point(start)
	return result

func prepare(session: RefCounted) -> void:
	var signature: String = session.fingerprint + ":%d:%d" % [session.known.size(), session.completed.size()]
	if signature != _signature:
		_build(session)
		_signature = signature

func _build(session: RefCounted) -> void:
	_astar.clear()
	_bins.clear()
	for key: String in session.known:
		if not session.cells.has(key) or session.cells[key].terrain != "ground": continue
		var cell: Dictionary = session.cells[key]
		var center := Hex.to_plane(Vector2i(cell.q, cell.r), 1.0)
		_add(session, center)
		for i in 6:
			_add(session, center + Vector2.from_angle(TAU * i / 6.0) * RING_RADIUS)
	for id in _astar.get_point_ids():
		_connect_near(session, id, _astar.get_point_position(id), true)

func _add(session: RefCounted, point: Vector2) -> void:
	if not session.can_stand(point): return
	var id := _astar.get_available_point_id()
	_astar.add_point(id, point)
	var bin := Vector2i(floori(point.x), floori(point.y))
	if not _bins.has(bin): _bins[bin] = []
	_bins[bin].append(id)

func _connect_near(session: RefCounted, id: int, point: Vector2, only_new := false) -> void:
	var bin := Vector2i(floori(point.x), floori(point.y))
	for x in range(-2, 3):
		for y in range(-2, 3):
			for other: int in _bins.get(bin + Vector2i(x, y), []):
				if other == id or (only_new and other < id): continue
				var to := _astar.get_point_position(other)
				if point.distance_squared_to(to) > LINK_DISTANCE * LINK_DISTANCE: continue
				if _clear(session, point, to): _astar.connect_points(id, other)

func _clear(session: RefCounted, from: Vector2, to: Vector2) -> bool:
	var steps := ceili(from.distance_to(to) / 0.09)
	for i in range(1, steps + 1):
		if not session.can_stand(from.lerp(to, float(i) / steps)): return false
	return true

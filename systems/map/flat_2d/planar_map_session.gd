extends RefCounted
## Pure planar map state. Unit radius = 1; rendering pixels and height are absent.
const Hex = preload("res://systems/map/hex_coord.gd")
const TYPES := ["battle", "elite", "shop", "boss", "event"]
const FOOT_RADIUS := 0.18
var map_id := ""
var seed := ""
var floor_index := 1
var fingerprint := ""
var actor_plane := Vector2.ZERO
var cells: Dictionary = {}
var nodes: Dictionary = {}
var known: Dictionary = {}
var completed: Dictionary = {}
var visits: Dictionary = {}
var pending: Dictionary = {}
var last_error := ""
var _snapshot: Dictionary = {}
var _gate_cells: Dictionary = {}
var _serial := 0
var _boundaries: Dictionary = {}
var motion_path: Array[Vector2] = []

static func key(c: Vector2i) -> String:
	return "%d,%d" % [c.x, c.y]

static func coord(value: Array) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1]))

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and absf(float(value)) <= 100000.0

static func _coord_valid(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _integer(value[0]) and _integer(value[1])

func _fail(message: String) -> bool:
	last_error = message
	return false

func load_map(data: Dictionary) -> bool:
	var candidate = get_script().new()
	if not candidate._parse(data):
		return _fail(candidate.last_error)
	_adopt(candidate)
	return true

func _parse(data: Dictionary) -> bool:
	if data.get("schema_version") != 1 or not data.get("map_id") is String or str(data.map_id).is_empty():
		return _fail("Expected schema_version=1 and a nonempty map_id")
	if not data.get("seed", "") is String or not _integer(data.get("floor_index", 1)) or int(data.get("floor_index", 1)) < 1:
		return _fail("Invalid seed or floor_index")
	if not _coord_valid(data.get("spawn")) or not data.get("cells") is Array or data.cells.is_empty() or data.cells.size() > 10000 or not data.get("nodes", []) is Array:
		return _fail("Invalid spawn/cells/nodes")
	map_id = data.map_id
	seed = data.get("seed", "")
	floor_index = int(data.get("floor_index", 1))
	var clean_cells: Array = []
	for item in data.cells:
		if not item is Dictionary or not _integer(item.get("q")) or not _integer(item.get("r")) or item.get("terrain") not in ["ground", "wall"]:
			return _fail("Invalid cell")
		var c := Vector2i(int(item.q), int(item.r))
		if cells.has(key(c)):
			return _fail("Duplicate cell: " + key(c))
		var clean := {"q": c.x, "r": c.y, "terrain": item.terrain}
		cells[key(c)] = clean
		clean_cells.append(clean)
	var owners: Dictionary = {}
	var clean_nodes: Array = []
	for item in data.get("nodes", []):
		if not item is Dictionary or not item.get("id") is String or str(item.id).is_empty() or nodes.has(item.id) or item.get("type") not in TYPES or not _coord_valid(item.get("coord")):
			return _fail("Invalid or duplicate node")
		if not item.get("footprint") is Array or item.footprint.is_empty() or not item.get("is_route_gate", false) is bool or not item.get("revisitable", false) is bool or not item.get("unlock_gates", []) is Array:
			return _fail("Invalid node footprint or flags")
		if item.get("is_route_gate", false) and item.type not in ["battle", "elite"]:
			return _fail("Only battle/elite nodes may be local route gates")
		var footprint: Array = []
		for point in item.footprint:
			if not _coord_valid(point):
				return _fail("Invalid node footprint coordinate")
			var c := coord(point)
			var k := key(c)
			if not cells.has(k) or cells[k].terrain != "ground" or owners.has(k):
				return _fail("Footprint must contain unique, unowned ground cells")
			owners[k] = item.id
			footprint.append([c.x, c.y])
			if item.get("is_route_gate", false):
				_gate_cells[k] = item.id
		if [int(item.coord[0]), int(item.coord[1])] not in footprint:
			return _fail("Node center is outside footprint")
		var gates: Array = []
		for id in item.get("unlock_gates", []):
			if not id is String or id == item.id or id in gates:
				return _fail("Invalid unlock_gates")
			gates.append(id)
		for field in ["event_kind", "content_id"]:
			if not item.get(field, "") is String:
				return _fail("Invalid node " + field)
		var clean := {"id": item.id, "type": item.type, "coord": [int(item.coord[0]), int(item.coord[1])], "footprint": footprint, "is_route_gate": item.get("is_route_gate", false), "revisitable": item.get("revisitable", false), "unlock_gates": gates, "event_kind": item.get("event_kind", ""), "content_id": item.get("content_id", "")}
		nodes[item.id] = clean
		clean_nodes.append(clean)
	for item in clean_nodes:
		for id in item.unlock_gates:
			if not nodes.has(id) or not nodes[id].is_route_gate:
				return _fail("unlock_gates must reference a route gate")
	var spawn := coord(data.spawn)
	if not _passable(spawn):
		return _fail("Spawn must be open ground")
	clean_cells.sort_custom(func(a, b): return a.q < b.q or (a.q == b.q and a.r < b.r))
	clean_nodes.sort_custom(func(a, b): return a.id < b.id)
	_snapshot = {"schema_version": 1, "map_id": map_id, "seed": seed, "floor_index": floor_index, "spawn": [spawn.x, spawn.y], "cells": clean_cells, "nodes": clean_nodes}
	fingerprint = JSON.stringify(_snapshot).sha256_text()
	actor_plane = Hex.to_plane(spawn, 1.0)
	_discover()
	return true

func _adopt(other) -> void:
	map_id = other.map_id
	seed = other.seed
	floor_index = other.floor_index
	fingerprint = other.fingerprint
	actor_plane = other.actor_plane
	cells = other.cells
	nodes = other.nodes
	known = other.known
	completed = other.completed
	visits = other.visits
	pending = other.pending
	_snapshot = other._snapshot
	_gate_cells = other._gate_cells
	_boundaries = other._boundaries
	motion_path = [actor_plane]
	_serial += 1
	last_error = ""

func _passable(c: Vector2i) -> bool:
	var k := key(c)
	return cells.has(k) and cells[k].terrain == "ground" and (not _gate_cells.has(k) or completed.has(_gate_cells[k]))

func reachable() -> Dictionary:
	var start := Hex.from_plane(actor_plane, 1.0)
	var result: Dictionary = {}
	if not _passable(start):
		return result
	var queue: Array[Vector2i] = [start]
	result[key(start)] = true
	var index := 0
	while index < queue.size():
		for c in Hex.neighbors(queue[index]):
			var k := key(c)
			if _passable(c) and not result.has(k):
				result[k] = true
				queue.append(c)
		index += 1
	return result

func _discover() -> void:
	for k in reachable():
		known[k] = true
		var cell: Dictionary = cells[k]
		for c in Hex.neighbors(Vector2i(cell.q, cell.r)):
			if cells.has(key(c)):
				known[key(c)] = true

	_rebuild_boundaries()

func _rebuild_boundaries() -> void:
	_boundaries.clear()
	for k in cells:
		var cell: Dictionary = cells[k]
		var c := Vector2i(cell.q, cell.r)
		if not _passable(c) or not known.has(k):
			continue
		var center := Hex.to_plane(c, 1.0)
		var edges: Array = []
		var neighbors: Array = Hex.neighbors(c)
		for i in 6:
			var neighbor: Vector2i = neighbors[i]
			if _passable(neighbor) and known.has(key(neighbor)):
				continue
			var vertex := (6 - i) % 6
			var a := center + Vector2.from_angle(TAU * vertex / 6.0)
			var b := center + Vector2.from_angle(TAU * (vertex + 1) / 6.0)
			var inward := (center - Hex.to_plane(neighbor, 1.0)).normalized()
			edges.append({"a": a, "b": b, "normal": inward})
		_boundaries[k] = edges

func _node_visible(node: Dictionary) -> bool:
	var visible := known.has(key(coord(node.coord)))
	if node.is_route_gate and not visible:
		for point in node.footprint:
			visible = visible or known.has(key(coord(point)))
	if not visible:
		return false
	for id in node.unlock_gates:
		if not completed.has(id):
			return false
	return true

func can_stand(point: Vector2) -> bool:
	if not point.is_finite():
		return false
	var center := Hex.from_plane(point, 1.0)
	if not _passable(center) or not known.has(key(center)):
		return false
	# The circle radius is below the hex inradius. Only six neighbor hexes
	# can intersect it; distance to their edges gives exact corner clearance.
	for neighbor in Hex.neighbors(center):
		if _passable(neighbor) and known.has(key(neighbor)):
			continue
		var local := point - Hex.to_plane(neighbor, 1.0)
		for i in 6:
			var a := Vector2.from_angle(TAU * i / 6.0)
			var b := Vector2.from_angle(TAU * (i + 1) / 6.0)
			var nearest := Geometry2D.get_closest_point_to_segment(local, a, b)
			if local.distance_squared_to(nearest) < FOOT_RADIUS * FOOT_RADIUS - 0.000001:
				return false
	return true

func move_actor(displacement: Vector2) -> Vector2:
	motion_path = [actor_plane]
	if not pending.is_empty() or not displacement.is_finite():
		return actor_plane
	if displacement.length() > 12.0:
		displacement = displacement.normalized() * 12.0
	# Local continuous circle sweeps prevent tunneling; short pieces also
	# give render interpolation the actual path around rounded corners.
	var count := maxi(1, ceili(displacement.length() / 0.04))
	var step := displacement / count
	for i in count:
		_slide_piece(step)
	return actor_plane

func _slide_piece(displacement: Vector2) -> void:
	var remaining := displacement
	for iteration in 5:
		if remaining.length_squared() < 0.0000000001:
			break
		var hit := _sweep_circle(actor_plane, remaining)
		if hit.is_empty():
			var next := actor_plane + remaining
			if can_stand(next):
				actor_plane = next
				motion_path.append(actor_plane)
			break
		var t: float = hit.time
		# Stop just before contact. Remove only the component pointing into
		# the wall; the tangent remains, including on diagonal hex edges.
		var safe_t := maxf(0.0, t - 0.00001 / maxf(remaining.length(), 0.00001))
		var next := actor_plane + remaining * safe_t
		if not can_stand(next):
			break
		actor_plane = next
		motion_path.append(actor_plane)
		remaining *= 1.0 - t
		for normal in hit.normals:
			remaining -= normal * minf(remaining.dot(normal), 0.0)

func _sweep_circle(point: Vector2, motion: Vector2) -> Dictionary:
	var center := Hex.from_plane(point, 1.0)
	var local_cells: Array = [center]
	local_cells.append_array(Hex.neighbors(center))
	var hits: Array = []
	for c in local_cells:
		for edge in _boundaries.get(key(c), []):
			var a: Vector2 = edge.a
			var b: Vector2 = edge.b
			var normal: Vector2 = edge.normal
			var velocity := motion.dot(normal)
			if velocity < -0.0000001:
				var t := (FOOT_RADIUS - (point - a).dot(normal)) / velocity
				if t >= -0.00001 and t <= 1.0:
					t = maxf(t, 0.0)
					var contact := point + motion * t - normal * FOOT_RADIUS
					var along := (contact - a).dot(b - a) / a.distance_squared_to(b)
					if along >= 0.0 and along <= 1.0:
						hits.append({"time": t, "normal": normal})
			for vertex in [a, b]:
				var offset: Vector2 = point - vertex
				var aa := motion.length_squared()
				var bb := 2.0 * offset.dot(motion)
				var cc := offset.length_squared() - FOOT_RADIUS * FOOT_RADIUS
				var discriminant := bb * bb - 4.0 * aa * cc
				if bb >= 0.0 or discriminant < 0.0:
					continue
				var t := (-bb - sqrt(discriminant)) / (2.0 * aa)
				if t >= -0.00001 and t <= 1.0:
					t = maxf(t, 0.0)
					var corner_normal: Vector2 = (point + motion * t - vertex).normalized()
					if motion.dot(corner_normal) < -0.0000001:
						hits.append({"time": t, "normal": corner_normal})
	if hits.is_empty():
		return {}
	var earliest := 1.0
	for hit in hits:
		earliest = minf(earliest, hit.time)
	var normals: Array[Vector2] = []
	for hit in hits:
		if absf(hit.time - earliest) <= 0.00001 and hit.normal not in normals:
			normals.append(hit.normal)
	return {"time": earliest, "normals": normals}

func nearby_nodes() -> Array[String]:
	var found: Array[String] = []
	var c := Hex.from_plane(actor_plane, 1.0)
	for id in nodes:
		var node: Dictionary = nodes[id]
		if not _node_visible(node) or (completed.has(id) and not node.revisitable):
			continue
		# Interaction within footprint or one adjacent cell, but only near
		# an actual open neighbor of that footprint (not through a wall).
		for point in node.footprint:
			if Hex.distance(c, coord(point)) <= 1:
				found.append(id)
				break
	found.sort_custom(func(a, b):
		var da := actor_plane.distance_squared_to(Hex.to_plane(coord(nodes[a].coord), 1.0))
		var db := actor_plane.distance_squared_to(Hex.to_plane(coord(nodes[b].coord), 1.0))
		return a < b if is_equal_approx(da, db) else da < db)
	return found

func request_node(id: String) -> Dictionary:
	if not pending.is_empty() or id not in nearby_nodes():
		last_error = "Node unavailable, too far away, or another request is pending"
		return {}
	_serial += 1
	var node: Dictionary = nodes[id]
	pending = {"request_id": "%d:%d" % [get_instance_id(), _serial], "map_id": map_id, "seed": seed, "floor_index": floor_index, "node_id": id, "type": node.type, "event_kind": node.event_kind, "content_id": node.content_id, "is_route_gate": node.is_route_gate, "visit_index": int(visits.get(id, 0))}
	last_error = ""
	return pending.duplicate(true)

func resolve_request(result: Dictionary) -> bool:
	if pending.is_empty() or result.get("request_id") != pending.request_id or result.get("status") not in ["completed", "cancelled", "failed"]:
		return _fail("Stale, duplicate or invalid node result")
	if result.status == "completed":
		var id: String = pending.node_id
		completed[id] = true
		visits[id] = int(visits.get(id, 0)) + 1
		_discover()
	pending = {}
	last_error = ""
	return true

func get_view() -> Dictionary:
	var view_cells: Array = []
	for cell in _snapshot.get("cells", []):
		var copy: Dictionary = cell.duplicate()
		var k := key(Vector2i(cell.q, cell.r))
		copy.known = known.has(k)
		copy.gate_closed = _gate_cells.has(k) and not completed.has(_gate_cells[k])
		view_cells.append(copy)
	var view_nodes: Array = []
	for node in _snapshot.get("nodes", []):
		view_nodes.append({"id": node.id, "type": node.type, "coord": node.coord.duplicate(), "known": _node_visible(node), "completed": completed.has(node.id), "is_route_gate": node.is_route_gate})
	return {"cells": view_cells, "nodes": view_nodes, "spawn": _snapshot.get("spawn", []).duplicate()}

func get_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)

func capture_state() -> Dictionary:
	return {"state_version": 1, "map_id": map_id, "fingerprint": fingerprint, "actor_plane": [actor_plane.x, actor_plane.y], "known": known.keys(), "completed": completed.keys(), "visits": visits.duplicate(), "pending": pending.duplicate(true)}

func restore_state(saved: Dictionary) -> bool:
	# Validate in a candidate. Any rejection leaves the active session intact.
	var candidate = get_script().new()
	if not candidate._parse(_snapshot) or not candidate._restore_checked(saved):
		return _fail(candidate.last_error)
	_adopt(candidate)
	return true

func _restore_checked(saved: Dictionary) -> bool:
	if saved.get("state_version") != 1 or saved.get("map_id") != map_id or saved.get("fingerprint") != fingerprint:
		return _fail("State version or map identity does not match")
	if not saved.get("known") is Array or not saved.get("completed") is Array or not saved.get("visits") is Dictionary or not saved.get("pending") is Dictionary:
		return _fail("Invalid state collections")
	var p: Variant = saved.get("actor_plane")
	if not p is Array or p.size() != 2 or not (p[0] is float or p[0] is int) or not (p[1] is float or p[1] is int) or not is_finite(float(p[0])) or not is_finite(float(p[1])):
		return _fail("Invalid actor_plane")
	completed = {}
	for id in saved.completed:
		if not id is String or not nodes.has(id) or completed.has(id):
			return _fail("Invalid completed node")
		completed[id] = true
	for id in completed:
		for gate in nodes[id].unlock_gates:
			if not completed.has(gate):
				return _fail("Completed node has an unfinished prerequisite gate")
	# No arbitrary reveal API: rebuild fog from spawn and completed gates.
	known = {}
	_discover()
	var expected_known: Dictionary = known.duplicate()
	known = {}
	for k in saved.known:
		if not k is String or not cells.has(k) or known.has(k):
			return _fail("Invalid known cell")
		known[k] = true
	if known != expected_known:
		return _fail("Saved fog does not match completed local gates")
	visits = {}
	for id in saved.visits:
		if not nodes.has(id) or not _integer(saved.visits[id]) or int(saved.visits[id]) < 1 or not completed.has(id):
			return _fail("Invalid visit count")
		visits[id] = int(saved.visits[id])
	for id in completed:
		if not visits.has(id) or (not nodes[id].revisitable and visits[id] != 1):
			return _fail("Completed node needs a valid visit count")
	actor_plane = Vector2(float(p[0]), float(p[1]))
	if not can_stand(actor_plane):
		return _fail("Saved actor is inside blocked or unknown terrain")
	for k in reachable():
		if not known.has(k):
			return _fail("Known cells omit reachable terrain")
	pending = {}
	if not saved.pending.is_empty():
		var old: Dictionary = saved.pending
		if not old.get("node_id") is String or old.node_id not in nearby_nodes() or not old.get("request_id") is String or str(old.request_id).is_empty():
			return _fail("Invalid pending request")
		var expected := request_node(old.node_id)
		for field in expected:
			if field != "request_id" and old.get(field) != expected[field]:
				return _fail("Pending request metadata does not match")
		# Keep the fresh callback token created by request_node in this
		# candidate. An old asynchronous result cannot settle restored state.
	return true

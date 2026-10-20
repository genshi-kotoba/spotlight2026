extends RefCounted
## Read-only destination policy; travel changes only the actor and render path.
## Fog, local gates, node requests and random streams remain session-owned.
const Hex = preload("res://systems/map/hex_coord.gd")


static func options(session) -> Dictionary:
	var context: Dictionary = _context(session)
	var result: Dictionary = {}
	for node_id: String in context.get("visible_ids", []):
		result[node_id] = _select(session, node_id, context)
	return result


static func preview(session, node_id: String, expected_map_id: String = "", expected_fingerprint: String = "") -> Dictionary:
	var identity_error := _identity_error(session, expected_map_id, expected_fingerprint)
	if not identity_error.is_empty():
		return _failure(session, node_id, identity_error)
	return _select(session, node_id, _context(session))


static func travel(session, node_id: String, expected_map_id: String = "", expected_fingerprint: String = "") -> Dictionary:
	# Recompute against current fog, prerequisites, route gates and collisions.
	var destination: Dictionary = preview(session, node_id, expected_map_id, expected_fingerprint)
	if not destination.ok:
		return destination
	var point: Array = destination.actor_plane
	var landing := Vector2(float(point[0]), float(point[1]))
	session.actor_plane = landing
	var path: Array[Vector2] = [landing]
	session.motion_path = path
	return destination


static func _valid_session(session) -> bool:
	return session is Object and is_instance_valid(session) and session.has_method("get_view") and session.has_method("reachable") and session.has_method("can_stand")


static func _identity_error(session, expected_map_id: String, expected_fingerprint: String) -> String:
	if not _valid_session(session):
		return "invalid_session"
	if not expected_map_id.is_empty() and expected_map_id != str(session.map_id):
		return "map_changed"
	if not expected_fingerprint.is_empty() and expected_fingerprint != str(session.fingerprint):
		return "fingerprint_changed"
	return ""


static func _failure(session, node_id: String, reason: String) -> Dictionary:
	var valid := _valid_session(session)
	# No coordinates or node metadata are disclosed for unavailable targets.
	return {"ok": false, "reason": reason, "node_id": node_id,
		"map_id": str(session.map_id) if valid else "",
		"fingerprint": str(session.fingerprint) if valid else ""}


static func _context(session) -> Dictionary:
	var context: Dictionary = {"visible_ids": [], "visible": {}, "markers": {}, "distances": {}, "error": ""}
	if not _valid_session(session):
		context.error = "invalid_session"
		return context
	var view: Dictionary = session.get_view()
	var visible: Dictionary = {}
	for node: Dictionary in view.get("nodes", []):
		if bool(node.get("known", false)):
			visible[str(node.id)] = true
	var ids: Array = visible.keys()
	ids.sort()
	context.visible_ids = ids
	context.visible = visible
	var known_cells: Dictionary = {}
	var known_open: Dictionary = {}
	for cell: Dictionary in view.get("cells", []):
		if not bool(cell.get("known", false)):
			continue
		var cell_key := _key(Vector2i(int(cell.q), int(cell.r)))
		known_cells[cell_key] = true
		if cell.get("terrain", "") == "ground" and not bool(cell.get("gate_closed", false)):
			known_open[cell_key] = true
	for node_id: String in ids:
		var node: Dictionary = session.nodes.get(node_id, {})
		var marker: Array = _marker(node, known_cells)
		if not marker.is_empty():
			context.markers[node_id] = marker
	if not session.pending.is_empty():
		context.error = "pending_request"
		return context
	# reachable() is the public authority for the current open route. Intersect
	# it with fog before measuring distances; geometric proximity grants nothing.
	var reachable: Dictionary = session.reachable()
	var start := Hex.from_plane(session.actor_plane, 1.0)
	var start_key := _key(start)
	if not known_open.has(start_key) or not reachable.has(start_key):
		return context
	var distances: Dictionary = {}
	distances[start_key] = 0
	var queue: Array[Vector2i] = [start]
	var index := 0
	while index < queue.size():
		var current: Vector2i = queue[index]
		var distance: int = int(distances[_key(current)]) + 1
		for neighbor: Vector2i in Hex.neighbors(current):
			var neighbor_key := _key(neighbor)
			if known_open.has(neighbor_key) and reachable.has(neighbor_key) and not distances.has(neighbor_key):
				distances[neighbor_key] = distance
				queue.append(neighbor)
		index += 1
	context.distances = distances
	return context


static func _select(session, node_id: String, context: Dictionary) -> Dictionary:
	if not context.visible.has(node_id):
		return _failure(session, node_id, "node_unavailable")
	if not str(context.error).is_empty():
		return _visible_failure(session, node_id, str(context.error), context)
	var node: Dictionary = session.nodes.get(node_id, {})
	if node.is_empty():
		return _visible_failure(session, node_id, "node_unavailable", context)
	for gate_id: String in node.get("unlock_gates", []):
		if not session.completed.has(gate_id):
			return _visible_failure(session, node_id, "node_unavailable", context)
	var center := _coord(node.coord)
	var landing: Dictionary = _best_candidate(session, Hex.neighbors(center), node, context.distances)
	if landing.is_empty() and bool(node.get("is_route_gate", false)) and not session.completed.has(node_id) and node.footprint.size() > 1:
		# A broad closed footprint may surround the center. Its outside ring is
		# still within the session's one-cell interaction reach, on the open side.
		var footprint: Dictionary = {}
		for point: Array in node.footprint:
			footprint[_key(_coord(point))] = true
		var outside: Dictionary = {}
		for point: Array in node.footprint:
			for neighbor: Vector2i in Hex.neighbors(_coord(point)):
				if not footprint.has(_key(neighbor)):
					outside[_key(neighbor)] = neighbor
		landing = _best_candidate(session, outside.values(), node, context.distances)
	if landing.is_empty():
		return _visible_failure(session, node_id, "no_safe_landing", context)
	return {"ok": true, "reason": "ok", "node_id": node_id,
		"map_id": str(session.map_id), "fingerprint": str(session.fingerprint),
		"coord": landing.coord, "actor_plane": landing.actor_plane,
		"marker_coord": context.markers.get(node_id, [])}


static func _visible_failure(session, node_id: String, reason: String, context: Dictionary) -> Dictionary:
	var result: Dictionary = _failure(session, node_id, reason)
	if context.markers.has(node_id):
		result.marker_coord = context.markers[node_id].duplicate()
	return result


static func _marker(node: Dictionary, known_cells: Dictionary) -> Array:
	if node.is_empty():
		return []
	var center := _coord(node.coord)
	if known_cells.has(_key(center)):
		return [center.x, center.y]
	var found := false
	var best := Vector2i.ZERO
	for point: Array in node.footprint:
		var candidate := _coord(point)
		if known_cells.has(_key(candidate)) and (not found or candidate.x < best.x or (candidate.x == best.x and candidate.y < best.y)):
			found = true
			best = candidate
	return [best.x, best.y] if found else []


static func _best_candidate(session, candidates: Array, node: Dictionary, distances: Dictionary) -> Dictionary:
	var center := _coord(node.coord)
	var found := false
	var best := Vector2i.ZERO
	var best_distance := 0
	for candidate: Vector2i in candidates:
		var candidate_key := _key(candidate)
		if candidate == center or not distances.has(candidate_key) or not _within_interaction(candidate, node.footprint):
			continue
		var plane := Hex.to_plane(candidate, 1.0)
		if not session.can_stand(plane):
			continue
		var distance := int(distances[candidate_key])
		if not found or distance < best_distance or (distance == best_distance and (candidate.x < best.x or (candidate.x == best.x and candidate.y < best.y))):
			found = true
			best = candidate
			best_distance = distance
	if not found:
		return {}
	var plane := Hex.to_plane(best, 1.0)
	return {"coord": [best.x, best.y], "actor_plane": [plane.x, plane.y]}


static func _within_interaction(candidate: Vector2i, footprint: Array) -> bool:
	for point: Array in footprint:
		if Hex.distance(candidate, _coord(point)) <= 1:
			return true
	return false


static func _coord(point: Array) -> Vector2i:
	return Vector2i(int(point[0]), int(point[1]))


static func _key(point: Vector2i) -> String:
	return "%d,%d" % [point.x, point.y]

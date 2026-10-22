extends RefCounted
## Enumerate the generator's bounded (two-gate) discovery states using disposable
## Sessions and their real request/result rules. Never touches the active run/RNG.
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const Hex = preload("res://systems/map/hex_coord.gd")

static func build(map_snapshot: Dictionary, layer: Dictionary) -> Dictionary:
	var first = Session.new()
	if not first.load_map(map_snapshot): return {"error": first.last_error}
	var gates: Array[String] = []
	for id in first.nodes:
		if first.nodes[id].is_route_gate: gates.append(id)
	gates.sort()
	if gates.size() > 2: return {"error": "Presentation preparation supports at most two route gates"}
	var queue: Array = [first]
	var visited := {"": true}
	var states: Array[Dictionary] = []
	while not queue.is_empty():
		var current = queue.pop_front()
		var visible_ids := {}
		for node in current.get_view().nodes:
			if node.known: visible_ids[node.id] = true
		var visible_layer := layer.duplicate()
		visible_layer.nodes = []
		for node in layer.get("nodes", []):
			if visible_ids.has(node.id): visible_layer.nodes.append(node)
		states.append({"snapshot": visible_layer, "known": current.known.duplicate(), "completed": current.completed.duplicate()})
		var reachable: Dictionary = current.reachable()
		for id in gates:
			if current.completed.has(id): continue
			var next = Session.new()
			if not next.load_map(map_snapshot) or not next.restore_state(current.capture_state()):
				return {"error": "Could not restore preparation Session: " + next.last_error}
			var requested := false
			for point in next.nodes[id].footprint:
				for neighbor in Hex.neighbors(Session.coord(point)):
					if not reachable.has(Session.key(neighbor)): continue
					next.actor_plane = Hex.to_plane(neighbor, 1.0)
					var request: Dictionary = next.request_node(id)
					if request.is_empty(): continue
					if not next.resolve_request({"request_id": request.request_id, "status": "completed"}):
						return {"error": next.last_error}
					requested = true
					break
				if requested: break
			if not requested: continue
			var completed_ids: Array = next.completed.keys()
			completed_ids.sort()
			var identity := ",".join(completed_ids)
			if visited.has(identity): continue
			visited[identity] = true
			queue.append(next)
	return {"states": states, "gate_count": gates.size()}

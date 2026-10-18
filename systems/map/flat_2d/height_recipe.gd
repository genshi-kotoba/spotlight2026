extends RefCounted
## Optional presentation recipe. Never grants a traversal edge or changes gates.
const Hex = preload("res://systems/map/hex_coord.gd")
static func parse(value: Variant, cells: Dictionary, nodes: Dictionary, spawn: Vector2i) -> Dictionary:
	if not value is Dictionary or value.size() != 2 or value.get("version") != "switchback-v1" or not value.get("climbs") is Array or value.climbs.size() > 2:
		return {"error": "Invalid height_recipe version/climbs"}
	var climbs: Array = []
	var pairs := {}
	for climb in value.climbs:
		if not climb is Dictionary or climb.size() != 3 or not climb.get("from_id") is String or not climb.get("to_id") is String or not climb.get("path") is Array or climb.path.size() < 2 or climb.path.size() > mini(512, cells.size()):
			return {"error": "Invalid height_recipe climb"}
		var endpoints: Array = []
		for id in [climb.from_id, climb.to_id]:
			if id == "spawn": endpoints.append(spawn)
			elif nodes.has(id): endpoints.append(Vector2i(int(nodes[id].coord[0]), int(nodes[id].coord[1])))
			else: return {"error": "Unknown height_recipe endpoint"}
		var pair: Array = [climb.from_id, climb.to_id]; pair.sort()
		var pair_key := JSON.stringify(pair)
		if endpoints[0] == endpoints[1] or pairs.has(pair_key): return {"error": "Duplicate height_recipe endpoint pair"}
		pairs[pair_key] = true
		var path: Array = []
		var seen := {}
		for point in climb.path:
			if not point is Array or point.size() != 2: return {"error": "Invalid height_recipe coordinate"}
			for component in point:
				if not (component is int or component is float) or not is_finite(float(component)) or absf(float(component)) > 100000 or float(component) != floor(float(component)):
					return {"error": "Invalid height_recipe coordinate"}
			var coord := Vector2i(int(point[0]), int(point[1]))
			var key := "%d,%d" % [coord.x, coord.y]
			if not cells.has(key) or cells[key].terrain != "ground" or seen.has(key): return {"error": "Height recipe must follow unique existing ground"}
			if not path.is_empty() and Hex.distance(Vector2i(path.back()[0], path.back()[1]), coord) != 1: return {"error": "Height recipe path must be adjacent"}
			seen[key] = true
			path.append([coord.x, coord.y])
		if Vector2i(path.front()[0], path.front()[1]) != endpoints[0] or Vector2i(path.back()[0], path.back()[1]) != endpoints[1]: return {"error": "Height recipe endpoints do not match path"}
		climbs.append({"from_id": climb.from_id, "to_id": climb.to_id, "path": path})
	return {"recipe": {"version": "switchback-v1", "climbs": climbs}}

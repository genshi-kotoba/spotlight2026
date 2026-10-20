extends RefCounted
## Fixed sandbox content. Geometry and encounters never consume random streams.
const Generator = preload("res://systems/map/flat_2d/planar_map_generator.gd")
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const Hex = preload("res://systems/map/hex_coord.gd")
const NodeGeometry = preload("res://systems/map/flat_2d/node_geometry.gd")

const REGION_NAMES := {1: "炼金工坊", 2: "贫民窟", 3: "教堂", 4: "方舟"}
const REGION_SIZES := {1: [23, 23], 2: [19, 15], 3: [19, 15], 4: [9, 9]}
const SPAWN := [1, 1]
# Already normalized legal metadata; the random generator is never invoked.
const FLOOR_CONFIG := {
	"size": "small", "normal": 3, "elite": 1, "events": 8,
	"min_boss_content_nodes": 4, "transition_count": 0,
	"transition_steps": 1, "obstacle_rate": 0.0,
	"cell_space": 1, "space_jitter": false, "layout_candidates": 1,
}
# All coordinates are planar axial [q, r]. No cell has multiple floor levels.
const MONSTER_LAYOUT := [
	{"id": "1", "floor": 1, "type": "boss", "coord": [3, 2]},
	{"id": "2", "floor": 1, "type": "elite", "coord": [7, 0]},
	{"id": "3", "floor": 1, "type": "battle", "coord": [11, -2]},
	{"id": "4", "floor": 1, "type": "battle", "coord": [15, -4]},
	{"id": "5", "floor": 1, "type": "battle", "coord": [19, -6]},
	{"id": "6", "floor": 1, "type": "battle", "coord": [3, 6]},
	{"id": "7", "floor": 1, "type": "battle", "coord": [7, 4]},
	{"id": "8", "floor": 1, "type": "battle", "coord": [11, 2]},
	{"id": "9", "floor": 2, "type": "elite", "coord": [3, 2]},
	{"id": "10", "floor": 2, "type": "boss", "coord": [7, 0]},
	{"id": "11", "floor": 2, "type": "boss", "coord": [11, -2]},
	{"id": "12", "floor": 2, "type": "elite", "coord": [15, -4]},
	{"id": "13", "floor": 2, "type": "elite", "coord": [3, 6]},
	{"id": "14", "floor": 2, "type": "battle", "coord": [7, 4]},
	{"id": "15", "floor": 2, "type": "battle", "coord": [11, 2]},
	{"id": "16", "floor": 3, "type": "boss", "coord": [3, 2]},
	{"id": "17", "floor": 3, "type": "boss", "coord": [7, 0]},
	{"id": "18", "floor": 3, "type": "elite", "coord": [11, -2]},
	{"id": "19", "floor": 3, "type": "elite", "coord": [15, -4]},
	{"id": "20", "floor": 3, "type": "battle", "coord": [3, 6]},
	{"id": "21", "floor": 3, "type": "battle", "coord": [7, 4]},
	{"id": "22", "floor": 3, "type": "battle", "coord": [11, 2]},
	{"id": "23", "floor": 4, "type": "boss", "coord": [4, 2]},
]
const EVENT_LAYOUT := [
	{"id": "great_work", "coord": [7, 8]},
	{"id": "medical", "coord": [11, 6]},
	{"id": "empty_gambling_table", "coord": [15, 4]},
	{"id": "death_and_taxes", "coord": [19, 2]},
	{"id": "wishing_well", "coord": [3, 14]},
	{"id": "beast_fight", "coord": [7, 12]},
	{"id": "damage_stele", "coord": [11, 10]},
	{"id": "object_confession", "coord": [15, 8]},
	{"id": "codex_exchange", "coord": [19, 6]},
	{"id": "material_synthesis", "coord": [3, 18]},
	{"id": "material_upgrade", "coord": [7, 16]},
	{"id": "listening_conch", "coord": [11, 14]},
]
const SERVICE_LAYOUT := {
	1: [{"type": "shop", "coord": [15, 0]}, {"type": "chest", "coord": [19, -2]}, {"type": "pile", "coord": [3, 10]}],
	2: [{"type": "shop", "coord": [15, 0]}, {"type": "chest", "coord": [3, 10]}, {"type": "pile", "coord": [7, 8]}],
	3: [{"type": "shop", "coord": [15, 0]}, {"type": "chest", "coord": [3, 10]}, {"type": "pile", "coord": [7, 8]}],
}
const ENCOUNTER_IDS := {
	"1": ["1"], "2": ["2", "3", "4"],
	"3": ["3", "4"], "4": ["4", "5", "6"],
	"5": ["5", "7"], "6": ["6", "5", "8"],
	"7": ["7", "3"], "8": ["8", "4", "6"],
	"9": ["9", "14", "15"], "10": ["10"], "11": ["11"],
	"12": ["12", "14"], "13": ["13", "15", "14"],
	"14": ["14", "15"], "15": ["15", "14"],
	"16": ["16"], "17": ["17"],
	"18": ["18", "20", "21"], "19": ["19", "22"],
	"20": ["20", "21"], "21": ["21", "22", "20"],
	"22": ["22", "20", "21"], "23": ["23"],
}
const GRADES := {"battle": "普通", "elite": "精英", "boss": "BOSS"}

static func checkpoint(seed_snapshot: Dictionary, roster: Array) -> Dictionary:
	var seed_value: Variant = seed_snapshot.get("main_seed", "")
	if not seed_value is String or seed_value.is_empty() or not _roster_matches(roster):
		push_error("Fixed test map requires an initialized seed and all 23 catalog monsters")
		return {}
	var floors: Array = []
	var configs: Array = []
	for floor_index in range(1, 5):
		var snapshot := _snapshot(seed_value, floor_index)
		var session := Session.new()
		if not session.load_map(snapshot):
			push_error("Fixed test map initialization failed: " + session.last_error)
			return {}
		# With no gates, native discovery reveals every connected floor tile.
		# Opened event names remain visible, while every node is still unfinished.
		var state: Dictionary = session.capture_state()
		for node: Dictionary in snapshot.nodes:
			if node.type == "event":
				state.opened.append(node.id)
		if not session.restore_state(state):
			push_error("Fixed test map initialization failed: " + session.last_error)
			return {}
		floors.append({"floor_index": floor_index, "snapshot": snapshot, "state": session.capture_state()})
		configs.append(FLOOR_CONFIG.duplicate(true))
	return {
		"run_version": 1, "generator_version": Generator.VERSION,
		"map_set_id": "sandbox", "current_floor": 1,
		"floor_configs": configs, "seed_snapshot": seed_snapshot.duplicate(true),
		"encounter_roster": roster.duplicate(true), "floors": floors,
		"generation_failures": [],
	}

static func encounter_ids(primary_id: String) -> Array:
	var ids: Array = ENCOUNTER_IDS.get(primary_id, [])
	return ids.duplicate()

static func _roster_matches(roster: Array) -> bool:
	if roster.size() != MONSTER_LAYOUT.size():
		return false
	var by_id := {}
	for raw: Variant in roster:
		if not raw is Dictionary or not raw.get("id") is String or by_id.has(raw.id):
			return false
		if not raw.get("name") is String or not raw.get("art_path") is String or not Session._integer(raw.get("floor_index")):
			return false
		by_id[raw.id] = raw
	for entry: Dictionary in MONSTER_LAYOUT:
		if not by_id.has(entry.id):
			return false
		var record: Dictionary = by_id[entry.id]
		if int(record.floor_index) != int(entry.floor) or record.get("grade") != GRADES[entry.type]:
			return false
	return true

static func _snapshot(seed_text: String, floor_index: int) -> Dictionary:
	var nodes: Array = []
	for entry: Dictionary in MONSTER_LAYOUT:
		if int(entry.floor) != floor_index:
			continue
		var node := _node("monster-%02d" % int(entry.id), str(entry.type), entry.coord)
		node.content_id = str(entry.id)
		nodes.append(node)
	for entry: Dictionary in SERVICE_LAYOUT.get(floor_index, []):
		nodes.append(_node(str(entry.type) + "-1", str(entry.type), entry.coord))
	if floor_index == 1:
		for entry: Dictionary in EVENT_LAYOUT:
			var node := _node("event-" + str(entry.id), "event", entry.coord)
			node.event_kind = str(entry.id)
			node.content_id = "alchemy/events/" + str(entry.id)
			nodes.append(node)
	nodes.sort_custom(func(a: Dictionary, b: Dictionary): return a.id < b.id)
	return {
		"schema_version": 1, "generator_version": Generator.VERSION,
		"generation_config": FLOOR_CONFIG.duplicate(true),
		"map_id": "sandbox:floor-%03d" % floor_index, "seed": seed_text,
		"floor_index": floor_index, "spawn": SPAWN.duplicate(),
		"cells": _cells(floor_index), "nodes": nodes,
	}

static func _node(id: String, type: String, point: Array) -> Dictionary:
	var center := Vector2i(int(point[0]), int(point[1]))
	var footprint: Array = [[center.x, center.y]]
	for neighbor: Vector2i in Hex.neighbors(center):
		footprint.append([neighbor.x, neighbor.y])
	var node := {
		"id": id, "type": type, "coord": point.duplicate(), "footprint": footprint,
		"is_route_gate": false, "unlock_gates": [],
		"revisitable": type in ["event", "shop"],
		"event_kind": "shop" if type == "shop" else "", "content_id": "flat_2d/" + type,
	}
	if type == "event":
		node.body_capsule = NodeGeometry.event_capsule()
	else:
		node.body_radius = NodeGeometry.alchemy_radius("battle" if type == "elite" else type)
	return node

static func _cells(floor_index: int) -> Array:
	var dimensions: Array = REGION_SIZES[floor_index]
	var terrain := {}
	for col in range(int(dimensions[0])):
		for row in range(int(dimensions[1])):
			terrain[Hex.offset_to_axial(col, row)] = "ground"
	var ground: Array = terrain.keys()
	for center: Vector2i in ground:
		for neighbor: Vector2i in Hex.neighbors(center):
			if not terrain.has(neighbor):
				terrain[neighbor] = "wall"
	var points: Array = terrain.keys()
	points.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var cells: Array = []
	for point: Vector2i in points:
		cells.append({"q": point.x, "r": point.y, "terrain": terrain[point]})
	return cells

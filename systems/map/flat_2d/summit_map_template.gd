extends RefCounted
## Final-floor planar template. Height remains presentation-only; no RNG, fog,
## gates, progression, or encounter lifecycle is owned here.
const VERSION := "summit-v1"
const Hex = preload("res://systems/map/hex_coord.gd")
const NodeGeometry = preload("res://systems/map/flat_2d/node_geometry.gd")
const SPAWN := Vector2i(0, 0)
const SHOP := Vector2i(6, 0)
const BOSS := Vector2i(12, 0)


static func build(seed_text: String, map_id: String) -> Dictionary:
	var ground: Dictionary = {}
	# Three-cell-wide axial corridor with fixed, slightly wider platforms.
	# The shop body and even its footprint have a route around either side.
	for q in range(SPAWN.x, BOSS.x + 1):
		for r in range(-1, 2):
			ground[Vector2i(q, r)] = true
	for center: Vector2i in [SPAWN, SHOP, BOSS]:
		for coord: Vector2i in _platform(center, 2):
			ground[coord] = true
	var terrain: Dictionary = {}
	for coord: Vector2i in ground:
		terrain[coord] = "ground"
		for neighbor: Vector2i in Hex.neighbors(coord):
			if not ground.has(neighbor):
				terrain[neighbor] = "wall"
	var ordered: Array = terrain.keys()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	var cells: Array = []
	for coord: Vector2i in ordered:
		cells.append({"q": coord.x, "r": coord.y, "terrain": terrain[coord]})
	# Spawn is snapshot.spawn, never an unsupported interactive node type.
	var nodes: Array = [
		_node("boss-1", "boss", BOSS, 2, false, "23"),
		_node("shop-1", "shop", SHOP, 1, true),
	]
	return {
		"schema_version": 1, "map_id": map_id, "seed": seed_text,
		"floor_index": 4, "spawn": _point(SPAWN), "cells": cells, "nodes": nodes,
		# Reuse the existing persisted path contract. The presentation adapter
		# chooses a fixed shallow profile; a recipe never changes traversal.
		"height_recipe": {"version": "switchback-v1", "climbs": [
			{"from_id": "spawn", "to_id": "shop-1", "path": _path(SPAWN.x, SHOP.x)},
			{"from_id": "shop-1", "to_id": "boss-1", "path": _path(SHOP.x, BOSS.x)},
		]},
		"generation_attempt": 0,
		"generation_quality": {
			"ok": true, "template": VERSION, "ground_cells": ground.size(),
			"counts": {"battle": 0, "elite": 0, "event": 0, "shop": 1, "boss": 1, "chest": 0, "pile": 0},
			"route_gates": 0,
			"transitions": {"requested_count": 0, "applied_count": 0, "skipped_count": 0, "operations": []},
		},
	}


static func _node(id: String, type: String, center: Vector2i, radius: int, revisitable: bool, content_id: String = "") -> Dictionary:
	var footprint: Array = []
	for coord: Vector2i in _platform(center, radius):
		footprint.append(_point(coord))
	return {
		"id": id, "type": type, "coord": _point(center), "footprint": footprint,
		"is_route_gate": false, "revisitable": revisitable, "unlock_gates": [],
		"event_kind": "", "content_id": content_id,
		"body_radius": NodeGeometry.alchemy_radius(type),
	}


static func _platform(center: Vector2i, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for q in range(center.x - radius, center.x + radius + 1):
		for r in range(center.y - radius, center.y + radius + 1):
			var coord := Vector2i(q, r)
			if Hex.distance(center, coord) <= radius:
				cells.append(coord)
	return cells


static func _path(from_q: int, to_q: int) -> Array:
	var path: Array = []
	for q in range(from_q, to_q + 1):
		path.append([q, 0])
	return path


static func _point(coord: Vector2i) -> Array:
	return [coord.x, coord.y]

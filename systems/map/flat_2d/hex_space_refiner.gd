extends RefCounted
## Optional spatial refinement AFTER the validated coarse map. No second RNG.
## Index-seven axial lattice: disks tile without overlaps or extra macro edges.
const Hex = preload("res://systems/map/hex_coord.gd")
const VERSION := "hex-space-seven-v1"

static func center(p: Vector2i, cells_per_position: int = 7) -> Vector2i:
	if cells_per_position == 3:
		return Vector2i(p.x-p.y,p.x+2*p.y)
	if cells_per_position == 4:
		return p*2
	return Vector2i(2 * p.x - p.y, p.x + 3 * p.y)

static func _coord(p: Array) -> Vector2i:
	return Vector2i(int(p[0]), int(p[1]))

static func _point(p: Vector2i) -> Array:
	return [p.x, p.y]

static func _sorted(items: Dictionary) -> Array:
	var keys: Array = items.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	return keys

static func _edge(a: Vector2i, b: Vector2i) -> String:
	var first := a.x < b.x or (a.x == b.x and a.y < b.y)
	return str(a if first else b) + ":" + str(b if first else a)

static func _connected(part: Dictionary, start: Vector2i) -> bool:
	if not part.has(start): return false
	var seen := {start: true}
	var queue: Array = [start]
	var i := 0
	while i < queue.size():
		for n in Hex.neighbors(queue[i]):
			if part.has(n) and not seen.has(n):
				seen[n] = true
				queue.append(n)
		i += 1
	return seen.size() == part.size()

static func _contacts(parent: Dictionary, terrain: Dictionary) -> Dictionary:
	var edges := {}
	for p in parent:
		var a: Vector2i = parent[p]
		if terrain[a] != "ground": continue
		for n in Hex.neighbors(p):
			if parent.has(n):
				var b: Vector2i = parent[n]
				if a != b and terrain[b] == "ground":
					var key := _edge(a, b)
					edges[key] = int(edges.get(key, 0)) + 1
	return edges

static func _try_transfer(p: Vector2i, receiver: Vector2i, parents: Dictionary, parts: Dictionary, terrain: Dictionary, expected: Dictionary) -> bool:
	var donor: Vector2i = parents[p]
	if donor == receiver or Hex.distance(donor, receiver) != 1 or p == center(donor): return false
	if parts[donor].size() <= 6 or parts[receiver].size() >= 8: return false
	var a: Dictionary = parts[donor].duplicate()
	var b: Dictionary = parts[receiver].duplicate()
	a.erase(p)
	b[p] = true
	if not _connected(a, center(donor)) or not _connected(b, center(receiver)): return false
	# Changed incident edges may disappear, but never add a coarse connection.
	for n in Hex.neighbors(p):
		if not parents.has(n): continue
		var owner: Vector2i = parents[n]
		if terrain[receiver] == "ground" and terrain[owner] == "ground" and receiver != owner and not expected.has(_edge(receiver, owner)):
			return false
	parents[p] = receiver
	var contacts := _contacts(parents, terrain)
	for edge in expected:
		if not contacts.has(edge):
			parents[p] = donor
			return false
	parts[donor] = a
	parts[receiver] = b
	return true

func apply(snapshot: Dictionary, rng, irregular: bool = true, cells_per_position: int = 7) -> Dictionary:
	if cells_per_position in [3,4]:
		return _apply_small(snapshot,rng,irregular,cells_per_position)
	if cells_per_position != 7:
		push_error("Spatial refinement supports exactly 3, 4, or 7 cells per position")
		return {}
	var terrain := {}
	var parts := {}
	var parents := {}
	for cell in snapshot.cells:
		var coarse := Vector2i(int(cell.q), int(cell.r))
		terrain[coarse] = cell.terrain
		var part := {center(coarse): true}
		for p in Hex.neighbors(center(coarse)):
			part[p] = true
		parts[coarse] = part
		for p in part: parents[p] = coarse
	var expected := _contacts(parents, terrain)
	# Gate clusters and their immediate surroundings keep their three-edge neck.
	var protected := {}
	for node in snapshot.nodes:
		if node.is_route_gate:
			for point in node.footprint:
				var p := _coord(point)
				protected[p] = true
				for n in Hex.neighbors(p): protected[n] = true
	var changes := 0
	if irregular:
		var candidates := _sorted(parents)
		rng.shuffle_in_place(candidates)
		for p in candidates:
			var donor: Vector2i = parents[p]
			if protected.has(donor) or p == center(donor): continue
			var receivers := {}
			for n in Hex.neighbors(p):
				if parents.has(n) and parents[n] != donor and not protected.has(parents[n]): receivers[parents[n]] = true
			var choices := _sorted(receivers)
			rng.shuffle_in_place(choices)
			for receiver in choices:
				# Prefer contour and ownership variety; keep alterations local.
				if rng.int_range(0, 99) >= 35: continue
				if _try_transfer(p, receiver, parents, parts, terrain, expected):
					changes += 1
					break
			if changes >= terrain.size() / 2: break
	var ground := {}
	var output_cells := {}
	var histogram := {"6": 0, "7": 0, "8": 0}
	for coarse in _sorted(parts):
		if terrain[coarse] != "ground": continue
		histogram[str(parts[coarse].size())] += 1
		for p in parts[coarse]: ground[p] = coarse
	for p in ground:
		output_cells[p] = "ground"
		for n in Hex.neighbors(p):
			if not ground.has(n): output_cells[n] = "wall"
	var result: Dictionary = snapshot.duplicate(true)
	result.cells = []
	for p in _sorted(output_cells):
		var cell := {"q": p.x, "r": p.y, "terrain": output_cells[p]}
		if ground.has(p): cell.coarse_coord = _point(ground[p])
		result.cells.append(cell)
	result.spawn = _point(center(_coord(snapshot.spawn)))
	for node in result.nodes:
		node.coord = _point(center(_coord(node.coord)))
		var footprint := {}
		for point in node.footprint:
			footprint.merge(parts[_coord(point)])
		node.footprint = []
		for p in _sorted(footprint): node.footprint.append(_point(p))
	result.spatial_refinement = {"version": VERSION, "cells_per_position": 7, "irregular": irregular, "boundary_changes": changes, "cluster_sizes": histogram, "coarse_ground_cells": histogram["6"] + histogram["7"] + histogram["8"], "fine_ground_cells": ground.size(), "coarse_spawn": snapshot.spawn.duplicate(), "coarse_cells": snapshot.cells.duplicate(true)}
	return result


static func _try_swap(p: Vector2i, q: Vector2i, parents: Dictionary, parts: Dictionary, terrain: Dictionary, expected: Dictionary, cells_per_position: int) -> bool:
	var donor: Vector2i = parents[p]
	var receiver: Vector2i = parents[q]
	if donor == receiver or Hex.distance(donor,receiver) != 1 or p == center(donor,cells_per_position) or q == center(receiver,cells_per_position): return false
	var a: Dictionary = parts[donor].duplicate()
	var b: Dictionary = parts[receiver].duplicate()
	a.erase(p)
	a[q] = true
	b.erase(q)
	b[p] = true
	if not _connected(a,center(donor,cells_per_position)) or not _connected(b,center(receiver,cells_per_position)): return false
	parents[p] = receiver
	parents[q] = donor
	# Counts remain exact; a swap may never add or remove any traversable
	# coarse contact, including at a third part next to the swapped cells.
	var contacts: Dictionary = _contacts(parents,terrain)
	var valid: bool = contacts.size() == expected.size()
	if valid:
		for edge: String in expected:
			if not contacts.has(edge):
				valid = false
				break
	if not valid:
		parents[p] = donor
		parents[q] = receiver
		return false
	parts[donor] = a
	parts[receiver] = b
	return true


func _apply_small(snapshot: Dictionary, rng, irregular: bool, cells_per_position: int) -> Dictionary:
	# Each offset represents a distinct lattice coset. The triomino (index 3)
	# and rhombus (index 4) tile the fine hex grid; neither reuses seven-cell
	# centres or removes cells from a larger platform.
	var offsets: Array = [Vector2i.ZERO,Vector2i(1,0),Vector2i(0,1)]
	if cells_per_position == 4: offsets.append(Vector2i(1,1))
	var terrain: Dictionary = {}
	var parts: Dictionary = {}
	var parents: Dictionary = {}
	for cell: Dictionary in snapshot.cells:
		var coarse := Vector2i(cell.q,cell.r)
		terrain[coarse] = cell.terrain
		var part: Dictionary = {}
		for offset: Vector2i in offsets:
			var p: Vector2i = center(coarse,cells_per_position)+offset
			part[p] = true
			parents[p] = coarse
		parts[coarse] = part
	var expected: Dictionary = _contacts(parents,terrain)
	var protected: Dictionary = {}
	for node: Dictionary in snapshot.nodes:
		if node.is_route_gate:
			for point: Array in node.footprint:
				var p: Vector2i = _coord(point)
				protected[p] = true
				for n: Vector2i in Hex.neighbors(p): protected[n] = true
	var swaps := 0
	if irregular:
		var candidates: Array = _sorted(parents)
		rng.shuffle_in_place(candidates)
		for p: Vector2i in candidates:
			var donor: Vector2i = parents[p]
			if protected.has(donor) or p == center(donor,cells_per_position): continue
			var choices: Dictionary = {}
			for q: Vector2i in Hex.neighbors(p):
				if parents.has(q) and parents[q] != donor and not protected.has(parents[q]): choices[q] = true
			var shuffled: Array = _sorted(choices)
			rng.shuffle_in_place(shuffled)
			for q: Vector2i in shuffled:
				if rng.int_range(0,99) >= 35: continue
				if _try_swap(p,q,parents,parts,terrain,expected,cells_per_position):
					swaps += 1
					break
			if swaps >= terrain.size()/2: break
	var ground: Dictionary = {}
	for coarse: Vector2i in _sorted(parts):
		if terrain[coarse] != "ground": continue
		for p: Vector2i in parts[coarse]: ground[p] = coarse
	var output_cells: Dictionary = {}
	for p: Vector2i in ground:
		output_cells[p] = "ground"
		for n: Vector2i in Hex.neighbors(p):
			if not ground.has(n): output_cells[n] = "wall"
	var result: Dictionary = snapshot.duplicate(true)
	result.cells = []
	for p: Vector2i in _sorted(output_cells):
		var cell := {"q":p.x,"r":p.y,"terrain":output_cells[p]}
		if ground.has(p): cell.coarse_coord = _point(ground[p])
		result.cells.append(cell)
	result.spawn = _point(center(_coord(snapshot.spawn),cells_per_position))
	for node: Dictionary in result.nodes:
		node.coord = _point(center(_coord(node.coord),cells_per_position))
		var footprint: Dictionary = {}
		for point: Array in node.footprint: footprint.merge(parts[_coord(point)])
		node.footprint = []
		for p: Vector2i in _sorted(footprint): node.footprint.append(_point(p))
	var coarse_ground_count: int = ground.size()/cells_per_position
	result.spatial_refinement = {"version":"hex-space-three-v1" if cells_per_position == 3 else "hex-space-four-v1","cells_per_position":cells_per_position,"irregular":irregular,"boundary_changes":swaps*2,"boundary_swaps":swaps,"cluster_sizes":{str(cells_per_position):coarse_ground_count},"coarse_ground_cells":coarse_ground_count,"fine_ground_cells":ground.size(),"coarse_spawn":snapshot.spawn.duplicate(),"coarse_cells":snapshot.cells.duplicate(true),"policy":"exact part counts; connected centre foundations; traversable coarse contact graph unchanged"}
	return result

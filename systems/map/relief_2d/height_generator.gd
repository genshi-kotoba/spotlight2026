extends RefCounted
## Presentation only. Never edits terrain, connectivity, gates, or the input.
## Node footprints are contracted before fitting a unit-Lipschitz integer field.
const VERSION := "relief-2d-fnl-v1"
const Hex = preload("res://systems/map/hex_coord.gd")
const Castle = preload("res://systems/map/relief_2d/castle_height.gd")
const Citadel = preload("res://systems/map/relief_2d/citadel_height.gd")
const Contour = preload("res://systems/map/relief_2d/contour_height.gd")
const Regions = preload("res://systems/map/relief_2d/region_walls_height.gd")
const Articulation = preload("res://systems/map/relief_2d/local_articulation_height.gd")
const Network = preload("res://systems/map/relief_2d/regional_network_height.gd")
const Features = preload("res://systems/map/relief_2d/regional_features_height.gd")
const RegionWall = preload("res://systems/map/relief_2d/region_wall_profile.gd")
const Eccentric = preload("res://systems/map/relief_2d/eccentric_keep_height.gd")
const DEFAULT_CONFIG := {
	"amplitude_levels": 3.0, "wavelength": 7.0, "detail": 0.25,
	"quantum": 0.20, "wall_height": 1.3, "baseline_level": 0,
	"boss_mode": "free", "boss_level": null, "strategy": "basic",
	"event_flat_mode": "full", "foundation_mode": "legacy",
}
const STRATEGY_VERSION := "bounded-graph-relief-v1"
const RUGGED_VERSION := "warped-multiscale-relief-v1"
const EVENT_FLAT_VERSION := "event-foundation-v1"
const FOUNDATION_VERSION := "node-foundation-v2"
const INTEGER_LIMIT := 100000
const CELL_LIMIT := 4096
var last_error: String = ""


func normalize_config(input: Dictionary) -> Dictionary:
	last_error = ""
	for field in input:
		if field not in DEFAULT_CONFIG:
			return _fail("Unsupported height config key: " + str(field))
	var c: Dictionary = DEFAULT_CONFIG.duplicate()
	c.merge(input, true)
	if not c.strategy is String or c.strategy not in ["basic", "aggressive", "rugged", "castle", "citadel", "contour", "contour_warp", "contour_structure", "eccentric_keep", "region_walls", "regional_features", "regional_network", "regional_articulated"]:
		return _fail("strategy must be basic/aggressive/rugged/castle/citadel/contour/contour_warp/contour_structure/eccentric_keep/region_walls/regional_features/regional_network/regional_articulated")
	if not c.event_flat_mode is String or c.event_flat_mode not in ["full", "partial", "center"]:
		return _fail("event_flat_mode must be full/partial/center")
	if not c.foundation_mode is String or c.foundation_mode not in ["legacy", "full", "partial", "center"]:
		return _fail("foundation_mode must be legacy/full/partial/center")
	for field in ["amplitude_levels", "wavelength", "detail", "quantum", "wall_height"]:
		if not _number(c[field]):
			return _fail(field + " must be a finite number")
		c[field] = float(c[field])
	if c.amplitude_levels < 0.0 or c.amplitude_levels > 16.0:
		return _fail("amplitude_levels must be 0..16 (raw noise amplitude, not a final height bound)")
	if c.wavelength < 1.0 or c.wavelength > 128.0 or c.detail < 0.0 or c.detail > 1.0:
		return _fail("wavelength must be 1..128 and detail must be 0..1")
	if c.quantum < 0.001 or c.quantum > 1.0 or c.wall_height < 0.0 or c.wall_height > 8.0:
		return _fail("quantum must be 0.001..1 and wall_height must be 0..8")
	if not _integer(c.baseline_level) or absi(int(c.baseline_level)) > 64:
		return _fail("baseline_level must be an integer in -64..64")
	c.baseline_level = int(c.baseline_level)
	if not c.boss_mode is String or c.boss_mode not in ["free", "highest", "lowest", "below", "above", "fixed"]:
		return _fail("boss_mode must be free/highest/lowest/below/above/fixed")
	if c.boss_level != null:
		if not _integer(c.boss_level) or absi(int(c.boss_level)) > 128:
			return _fail("boss_level must be an integer in -128..128")
		c.boss_level = int(c.boss_level)
	if c.boss_mode == "fixed" and c.boss_level == null:
		return _fail("boss_level is required for boss_mode=fixed")
	if c.boss_mode == "free" and c.boss_level != null:
		return _fail("boss_level requires a constrained boss_mode")
	if c.boss_level != null and ((c.boss_mode == "above" and c.boss_level <= c.baseline_level) or (c.boss_mode == "below" and c.boss_level >= c.baseline_level)):
		return _fail("above/below boss_level must be strictly above/below baseline_level")
	return c


func generate(planar: Dictionary, noise_seed: int, config: Dictionary = {}) -> Dictionary:
	var c: Dictionary = normalize_config(config)
	if c.is_empty():
		return {}
	if noise_seed < -2147483648 or noise_seed > 2147483647:
		return _fail("noise_seed must fit FastNoiseLite's signed 32-bit seed")
	var data: Dictionary = _prepare(planar, c.event_flat_mode, c.foundation_mode)
	if data.is_empty():
		return {}
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 1.0 / (c.wavelength * sqrt(3.0))
	noise.fractal_octaves = 3
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = c.detail
	noise.domain_warp_enabled = false
	var raw: Array = []
	for group in data.groups:
		var total := 0.0
		for coord in group:
			var p: Vector2 = Hex.to_plane(coord, 1.0)
			total += noise.get_noise_2d(p.x, p.y)
		raw.append(c.baseline_level + total / group.size() * c.amplitude_levels)
	if c.strategy == "castle" and c.amplitude_levels > 0.0:
		raw = Castle.targets(data, c, noise_seed, 0)
	var citadel_choice: Dictionary = {}
	if c.strategy == "citadel" and c.amplitude_levels > 0.0:
		citadel_choice = Citadel.select(planar, data, c, noise_seed, _measure_citadel.bind(data, _free_graph(data)))
		if citadel_choice.has("error"): return _fail(citadel_choice.error)
		raw = citadel_choice.levels
	var contour_choice: Dictionary = {}
	if c.strategy in ["contour", "contour_warp", "contour_structure"] and c.amplitude_levels > 0.0:
		contour_choice = Contour.select(planar, data, c, noise_seed, _measure_citadel.bind(data, _free_graph(data)))
		if contour_choice.has("error"): return _fail(contour_choice.error)
		raw = contour_choice.levels
	var eccentric_choice: Dictionary = {}
	if c.strategy == "eccentric_keep" and c.amplitude_levels > 0.0:
		eccentric_choice = Eccentric.select(planar, data, c, noise_seed, _measure_citadel.bind(data, _free_graph(data)))
		if eccentric_choice.has("error"): return _fail(eccentric_choice.error)
		raw = eccentric_choice.levels
	var region_choice: Dictionary = {}
	if c.strategy == "region_walls" and c.amplitude_levels > 0.0:
		region_choice = Regions.select(planar, data, c, noise_seed, _measure_citadel.bind(data, _free_graph(data)))
		if region_choice.has("error"): return _fail(region_choice.error)
		raw = region_choice.levels
	var feature_choice: Dictionary = {}
	if c.strategy == "regional_features" and c.amplitude_levels > 0.0:
		feature_choice = Features.select(planar, data, c, noise_seed, _measure_citadel.bind(data, _free_graph(data)))
		if feature_choice.has("error"): return _fail(feature_choice.error)
		raw = feature_choice.levels
	var network_choice: Dictionary = {}
	if c.strategy in ["regional_network", "regional_articulated"] and c.amplitude_levels > 0.0:
		network_choice = Network.select(planar, data, c, noise_seed, _measure_level_span)
		if network_choice.has("error"): return _fail(network_choice.error)
		if c.strategy == "regional_articulated":
			network_choice = Articulation.refine(planar, data, c, noise_seed, network_choice, _measure_level_span)
			if network_choice.has("error"): return _fail(network_choice.error)
		raw = network_choice.levels
	var targets: Array = []
	for value in raw:
		targets.append(_round_level(value))
	var count: int = data.groups.size()
	var lower: Array = []
	var upper: Array = []
	lower.resize(count)
	upper.resize(count)
	lower.fill(-INF)
	upper.fill(INF)
	var spawn_group: int = data.owner[data.spawn]
	lower[spawn_group] = c.baseline_level
	upper[spawn_group] = c.baseline_level
	var boss_group: int = data.boss_group
	var boss_level: Variant = null
	if c.boss_mode != "free":
		if boss_group < 0:
			return _fail("Constrained boss_mode requires exactly one boss node")
		var distance: int = _distance(spawn_group, boss_group, data.edges)
		if c.strategy in ["regional_network", "regional_articulated"] and network_choice.get("network", {}).get("boss_level") != null:
			boss_level = int(network_choice.network.boss_level)
		elif c.strategy == "regional_features" and feature_choice.get("features", {}).get("boss_level") != null:
			boss_level = int(feature_choice.features.boss_level)
		elif c.boss_level != null:
			boss_level = c.boss_level
		elif c.boss_mode == "above":
			boss_level = c.baseline_level + 1
		elif c.boss_mode == "below":
			boss_level = c.baseline_level - 1
		else:
			var extreme: int = int(targets.max() if c.boss_mode == "highest" else targets.min())
			if c.amplitude_levels > 0.0:
				extreme = maxi(extreme, c.baseline_level + 1) if c.boss_mode == "highest" else mini(extreme, c.baseline_level - 1)
			boss_level = clampi(extreme, c.baseline_level - distance, c.baseline_level + distance) if distance >= 0 else extreme
		if (c.boss_mode == "highest" and boss_level < c.baseline_level) or (c.boss_mode == "lowest" and boss_level > c.baseline_level):
			return _fail("Boss extremum conflicts with the spawn baseline anchor")
		if c.amplitude_levels == 0.0 and boss_level != c.baseline_level:
			return _fail("Zero amplitude requires a flat baseline; boss anchor requests a different level")
		if distance >= 0 and absi(boss_level - c.baseline_level) > distance:
			return _fail("Boss/spawn hard anchors exceed the contracted ground path's one-level-per-edge budget")
		if c.boss_mode == "highest":
			upper.fill(boss_level)
		elif c.boss_mode == "lowest":
			lower.fill(boss_level)
		lower[spawn_group] = c.baseline_level
		upper[spawn_group] = c.baseline_level
		if boss_group == spawn_group and boss_level != c.baseline_level:
			return _fail("Boss and spawn hard anchors conflict on one platform")
		lower[boss_group] = boss_level
		upper[boss_group] = boss_level
	lower = _max_envelope(lower, data.edges)
	upper = _min_envelope(upper, data.edges)
	for i in count:
		if lower[i] > upper[i]:
			return _fail("Hard height anchors are infeasible at ground group %d" % i)
		targets[i] = clampf(targets[i], lower[i], upper[i])
	var levels: Array = _fit(targets, data.edges)
	var variation_anchor := false
	if c.amplitude_levels > 0.0 and levels.min() == levels.max():
		# A small sampled noise range can round to one level. Add the smallest
		# feasible contrast at a noise-selected group rather than flattening all.
		var choice := -1
		var chosen_level := 0
		var score := -INF
		var flat: int = levels[0]
		for i in count:
			for candidate in [flat - 1, flat + 1]:
				if candidate < lower[i] or candidate > upper[i]:
					continue
				var candidate_score: float = (raw[i] - flat) * (candidate - flat)
				if choice < 0 or candidate_score > score:
					choice = i
					chosen_level = candidate
					score = candidate_score
		if choice < 0:
			return _fail("Nonzero amplitude cannot create relief under the supplied flat-platform/anchor constraints")
		lower[choice] = chosen_level
		upper[choice] = chosen_level
		lower = _max_envelope(lower, data.edges)
		upper = _min_envelope(upper, data.edges)
		for i in count:
			targets[i] = clampf(targets[i], lower[i], upper[i])
		levels = _fit(targets, data.edges)
		variation_anchor = true
	var before: Dictionary = _measure_levels(levels, data)
	var selected_profile := "basic"
	if not citadel_choice.is_empty(): selected_profile = citadel_choice.profile
	if not contour_choice.is_empty(): selected_profile = contour_choice.profile
	if not eccentric_choice.is_empty(): selected_profile = eccentric_choice.profile
	if not region_choice.is_empty(): selected_profile = region_choice.profile
	if not feature_choice.is_empty(): selected_profile = feature_choice.profile
	if not network_choice.is_empty(): selected_profile = network_choice.profile
	if c.strategy == "aggressive" and c.amplitude_levels > 0.0:
		var choice := _select_aggressive(levels, raw, lower, upper, data, c)
		levels = choice.levels
		selected_profile = choice.profile
	var free_graph := _free_graph(data)
	free_graph.hard_pins = {}
	for coord in free_graph.free:
		var group: int = data.owner[coord]
		if lower[group] == upper[group]: free_graph.hard_pins[coord] = true
	var rugged_score: Variant = null
	if c.strategy == "rugged" and c.amplitude_levels > 0.0:
		var choice := _select_rugged(levels, lower, upper, data, free_graph, c, noise_seed)
		levels = choice.levels
		selected_profile = choice.profile
		rugged_score = choice.score
	var castle_choice: Dictionary = {}
	if c.strategy == "castle" and c.amplitude_levels > 0.0:
		castle_choice = _select_castle(levels, lower, upper, data, free_graph, c, noise_seed)
		levels = castle_choice.levels
		selected_profile = castle_choice.profile
	if c.strategy == "regional_features" and not feature_choice.is_empty():
		var final_error := Features.validate_final(planar, data, levels, c, feature_choice)
		if not final_error.is_empty(): return _fail(final_error)
	if c.strategy in ["regional_network", "regional_articulated"] and not network_choice.is_empty():
		var final_error := Articulation.validate_final(planar, data, levels, c, network_choice) if c.strategy == "regional_articulated" else Network.validate_final(planar, data, levels, c, network_choice)
		if not final_error.is_empty(): return _fail(final_error)
	var measured: Dictionary = _measure_levels(levels, data)
	measured.merge(_measure_free(levels, data, free_graph), true)
	measured.merge(_measure_ground(levels, data, free_graph), true)
	if c.strategy in ["castle", "citadel", "contour", "contour_warp", "contour_structure", "eccentric_keep", "region_walls", "regional_features", "regional_network", "regional_articulated"]: measured.merge(_measure_castle_regions(levels, data, free_graph, c), true)
	var result: Dictionary = planar.duplicate(true)
	var wall_levels: Dictionary = _rugged_wall_levels(planar.cells, levels, data) if c.strategy in ["rugged", "castle"] else {}
	var citadel_walls: Dictionary = Citadel.wall_profile(planar, data, levels, c) if c.strategy == "citadel" else {}
	var contour_walls: Dictionary = Contour.wall_profile(planar, data, levels, c) if c.strategy in ["contour", "contour_warp", "contour_structure", "eccentric_keep"] else {}
	var regional_walls: Dictionary = RegionWall.final_profile(planar, data, levels, c, noise_seed, {}, (network_choice if c.strategy in ["regional_network", "regional_articulated"] else (feature_choice if c.strategy == "regional_features" else region_choice)).get("selected_walls", {})) if c.strategy in ["region_walls", "regional_features", "regional_network", "regional_articulated"] else {}
	for cell in result.cells:
		var coord := Vector2i(int(cell.q), int(cell.r))
		if cell.terrain == "ground":
			cell.level = int(levels[data.owner[coord]])
			cell.erase("wall_height")
		else:
			var p: Vector2 = Hex.to_plane(coord, 1.0)
			cell.level = wall_levels[coord] if c.strategy in ["rugged", "castle"] else _round_level(c.baseline_level + noise.get_noise_2d(p.x, p.y) * c.amplitude_levels)
			cell.wall_height = c.wall_height
			if c.strategy == "citadel":
				cell.level = citadel_walls[coord].level
				cell.wall_height = citadel_walls[coord].wall_height
			if c.strategy in ["contour", "contour_warp", "contour_structure", "eccentric_keep"]:
				cell.level = contour_walls[coord].level
				cell.wall_height = contour_walls[coord].wall_height
			if c.strategy in ["region_walls", "regional_features", "regional_network", "regional_articulated"]:
				var record: Dictionary = regional_walls.cells[coord]
				cell.level = record.level; cell.wall_height = record.wall_height
				for field in ["wall_role", "wall_high_level", "wall_low_level", "wall_cap", "wall_top"]: cell[field] = record[field]
				for field in ["wall_crown_height", "wall_crown_patch"]:
					if record.has(field): cell[field] = record[field]
	for node in result.nodes:
		var reduced: bool = (node.type == "event" and c.event_flat_mode != "full") if c.foundation_mode == "legacy" else c.foundation_mode in ["partial", "center"]
		if reduced:
			node.height_flat_footprint = []
			for coord in data.protected_footprints[node.id]:
				node.height_flat_footprint.append([coord.x, coord.y])
	result.height_quantum = c.quantum
	result.outer_radius = 1.0
	var metadata: Dictionary = result.get("metadata", {}).duplicate(true)
	var stats := {"ground_cells": data.owner.size(), "ground_groups": count, "node_platforms": result.nodes.size(), "min_level": int(levels.min()), "max_level": int(levels.max()), "distinct_levels": 0, "variation_anchor": variation_anchor, "boss_level": boss_level}
	var distinct: Dictionary = {}
	for level in levels:
		distinct[int(level)] = true
	stats.distinct_levels = distinct.size()
	stats.merge(measured, true)
	stats.strategy = c.strategy
	stats.selected_profile = selected_profile
	stats.aggressive_improved = c.strategy == "aggressive" and _better_metrics(measured, before)
	stats.basic_comparison = before
	stats.foundation_mode = c.foundation_mode
	stats.node_original_cells = data.node_original_cells
	stats.protected_node_cells = data.protected_node_cells
	stats.released_node_cells = data.node_original_cells - data.protected_node_cells
	stats.event_flat_mode = c.event_flat_mode
	stats.event_original_cells = data.event_original_cells
	stats.protected_event_cells = data.protected_event_cells
	stats.released_event_cells = data.event_original_cells - data.protected_event_cells
	if c.strategy == "rugged":
		stats.rugged_candidate_count = 12 if c.amplitude_levels > 0.0 else 0
		stats.rugged_score = rugged_score
	if c.strategy == "castle":
		stats.castle_candidate_count = Castle.CANDIDATE_COUNT if c.amplitude_levels > 0.0 else 0
		stats.castle_score = castle_choice.get("score", null)
		stats.castle_relief_status = _castle_status(measured, c)
	if c.strategy == "citadel":
		stats.merge(citadel_choice.get("local", {}), true)
		stats.citadel_candidate_count = citadel_choice.get("candidate_count", 0)
		stats.citadel_refinement_count = citadel_choice.get("refinement_count", 0)
		stats.citadel_score = citadel_choice.get("score", null)
		stats.citadel_anchors = citadel_choice.get("anchors", [])
		stats.citadel_visibility_tests = citadel_choice.get("visibility_arcs", 0)
		stats.citadel_wall_witness_tests = citadel_choice.get("wall_witness_arcs", 0)
		var limits: Array = []
		if stats.level_span < 8: limits.append("short_height_span")
		if stats.get("citadel_local_contrast_p90", 0) < 6: limits.append("limited_nearby_cliff_contrast")
		if stats.get("citadel_upper_components", 0) < 2: limits.append("single_upper_region")
		if stats.ground_flat_ratio > 0.25: limits.append("large_flat_interior")
		stats.citadel_status = {"status":"flat_requested" if c.amplitude_levels == 0 else ("quality_candidate" if limits.is_empty() else "limited_candidate"), "limitations":limits}
	if c.strategy in ["contour", "contour_warp", "contour_structure"]:
		stats.merge(contour_choice.get("local", {}), true)
		stats.contour_candidate_count = contour_choice.get("candidate_count", 0)
		stats.contour_score = contour_choice.get("score", null)
		stats.contour_anchors = contour_choice.get("anchors", [])
		stats.contour_candidates = contour_choice.get("candidates", [])
		stats.contour_visibility_tests = contour_choice.get("visibility_arcs", 0)
		stats.contour_wall_policy = "original-citadel-wall-profile"
	if c.strategy == "contour_structure": stats.contour_structure = contour_choice.get("structure", {"status":"flat_requested","climbs":[]})
	if c.strategy == "eccentric_keep":
		stats.merge(eccentric_choice.get("local", {}), true)
		stats.eccentric_keep = eccentric_choice.get("massing", {"status":"flat_requested"})
		stats.eccentric_candidates = eccentric_choice.get("candidates", [])
		stats.eccentric_visibility_tests = eccentric_choice.get("visibility_arcs", 0)
		stats.eccentric_wall_policy = "original-citadel-wall-profile"
		stats.eccentric_real_cell_tips = Eccentric._tip_sites(levels, data).map(func(i): return [data.groups[i][0].x, data.groups[i][0].y])
	if c.strategy == "region_walls":
		stats.merge(region_choice.get("local", {}), true)
		stats.region_candidate_count = region_choice.get("candidate_count", 0)
		stats.region_candidates = region_choice.get("candidates", [])
		stats.region_wall_roles = regional_walls.counts
		stats.region_limited_walls = regional_walls.limited
	if c.strategy == "regional_features":
		stats.merge(feature_choice.get("local", {}), true)
		stats.regional_features = feature_choice.get("features", {"status":"flat_requested"})
		stats.regional_feature_candidates = feature_choice.get("candidates", [])
		stats.region_wall_roles = regional_walls.get("counts", {})
		stats.region_limited_walls = regional_walls.get("limited", 0)
	if c.strategy in ["regional_network", "regional_articulated"]:
		stats.merge(network_choice.get("local", {}), true)
		stats.regional_network = network_choice.get("network", {"status":"flat_requested"})
		stats.regional_network_candidates = network_choice.get("candidates", [])
		stats.region_wall_roles = regional_walls.get("counts", {})
		stats.region_limited_walls = regional_walls.get("limited", 0)
	if c.strategy == "regional_articulated": stats.regional_articulation = network_choice.get("articulation", {"status":"flat_requested"})
	var engine: Dictionary = Engine.get_version_info()
	metadata.height = {"version": VERSION, "strategy_version": STRATEGY_VERSION, "event_flat_version": EVENT_FLAT_VERSION, "foundation_version": FOUNDATION_VERSION, "config": c, "noise_seed": noise_seed, "engine_build": "%s|%s" % [engine.string, engine.hash], "stats": stats}
	if c.strategy == "rugged": metadata.height.rugged_version = RUGGED_VERSION
	if c.strategy == "castle": metadata.height.castle_version = Castle.VERSION
	if c.strategy == "citadel":
		metadata.height.citadel_version = Citadel.VERSION
		metadata.height.support_boundary = "local-real-barycentric-v1"
		metadata.height.unknown_shell = "below-known-ground"
	if c.strategy in ["contour", "contour_warp", "contour_structure", "eccentric_keep"]:
		metadata.height.contour_version = Contour.VERSION
		metadata.height.support_boundary = "local-real-barycentric-v1"
		metadata.height.unknown_shell = "below-known-ground"
		metadata.height.visibility_scope = "conservative-terrain-guard-and-original-wall-profile; sampled-visibility-not-universal"
		if c.strategy != "eccentric_keep":
			metadata.height.contour_target_shape = contour_choice.get("target_shape", {})
			metadata.height.contour_target_field = Contour.target_rows(data, contour_choice.targets, levels) if contour_choice.has("targets") else []
	if c.strategy == "contour_warp": metadata.height.contour_warp_version = Contour.WARP_VERSION
	if c.strategy == "contour_structure": metadata.height.contour_structure_version = Contour.STRUCTURE_VERSION
	if c.strategy == "eccentric_keep":
		metadata.height.eccentric_keep_version = Eccentric.VERSION
		metadata.height.eccentric_keep = eccentric_choice.get("massing", {})
		metadata.height.eccentric_mass_shape = eccentric_choice.get("target_shape", {})
		metadata.height.eccentric_target_field = Contour.target_rows(data, eccentric_choice.targets, levels) if eccentric_choice.has("targets") else []
	if c.strategy == "region_walls":
		metadata.height.region_walls_version = Regions.VERSION
		metadata.height.region_wall_profile_version = RegionWall.VERSION
		metadata.height.region_walls = region_choice.get("region", {"status":"flat_requested","routes":[],"limitations":[]})
		metadata.height.region_target_field = Contour.target_rows(data, region_choice.targets, levels) if region_choice.has("targets") else []
		metadata.height.support_boundary = "local-real-barycentric-v1"
		metadata.height.unknown_shell = "below-known-ground"
		metadata.height.visibility_scope = "original-terrain-guard-plus-selected-retaining-wall-constraints; ordinary-original-capped-profile; native-open-gate-sampling-required"
	if c.strategy == "regional_features":
		metadata.height.regional_features_version = Features.VERSION
		metadata.height.region_wall_profile_version = RegionWall.VERSION
		metadata.height.regional_features = feature_choice.get("features", {"status":"flat_requested","limitations":[]})
		metadata.height.region_target_field = Contour.target_rows(data, feature_choice.targets, levels) if feature_choice.has("targets") else []
		metadata.height.support_boundary = "local-real-barycentric-v1"
		metadata.height.unknown_shell = "below-known-ground"
		metadata.height.visibility_scope = "original-terrain-guard-plus-multiple-selected-wall-constraints; native-body-validation-required"
	if c.strategy in ["regional_network", "regional_articulated"]:
		metadata.height.regional_network_version = Network.VERSION
		metadata.height.region_wall_profile_version = RegionWall.VERSION
		metadata.height.regional_network = network_choice.get("network", {"status":"flat_requested","limitations":[]})
		metadata.height.region_target_field = Contour.target_rows(data, network_choice.targets, levels) if network_choice.has("targets") else []
		metadata.height.support_boundary = "local-real-barycentric-v1"
		metadata.height.unknown_shell = "below-known-ground"
		metadata.height.visibility_scope = "original-terrain-guard-plus-joint-selected-wall-network; native-body-validation-required"
	if c.strategy == "regional_articulated":
		metadata.height.regional_articulation_version = Articulation.VERSION
		metadata.height.regional_articulation = network_choice.get("articulation", {"status":"flat_requested"})
	if not regional_walls.is_empty(): metadata.height["masonry_crowns"]=regional_walls.get("masonry_crowns",{})
	result.metadata = metadata
	last_error = ""
	return result


func _measure_citadel(levels: Array, data: Dictionary, graph: Dictionary) -> Dictionary:
	var metrics := _measure_levels(levels, data, graph.neighbors)
	metrics.merge(_measure_ground(levels, data, graph), true)
	return metrics


func _select_castle(basic: Array, lower: Array, upper: Array, data: Dictionary, graph: Dictionary, c: Dictionary, noise_seed: int) -> Dictionary:
	# Three related architectural layouts, two feasible envelope blends each.
	# Score every ground tile, including all foundations, with no valley reward.
	var best: Array = basic
	var best_score := -INF
	var profile := "castle_base"
	for variant in Castle.LAYOUT_COUNT:
		var raw: Array = Castle.targets(data, c, noise_seed, variant)
		var shift := 0.0
		if c.boss_mode == "highest": shift = minf(0.0, upper[data.boss_group] - float(raw.max()))
		elif c.boss_mode == "lowest": shift = maxf(0.0, lower[data.boss_group] - float(raw.min()))
		var targets: Array = []
		for i in raw.size(): targets.append(clampf(raw[i] + shift, lower[i], upper[i]))
		var low := _max_envelope(targets, data.edges)
		var high := _min_envelope(targets, data.edges)
		for blend in [0.35, 0.65]:
			var candidate: Array = []
			for i in targets.size(): candidate.append(_round_level(lerpf(low[i], high[i], blend)))
			candidate = _smooth_rugged_extrema(candidate, lower, upper, data, graph)
			var metrics := _measure_levels(candidate, data, graph.neighbors)
			metrics.merge(_measure_ground(candidate, data, graph), true)
			metrics.merge(_measure_castle_regions(candidate, data, graph, c), true)
			var score := _castle_score(metrics)
			if score > best_score + 0.000000001:
				best = candidate
				best_score = score
				profile = "castle_regions_%d_blend_%02d" % [variant, int(blend * 100)]
	if best.min() == best.max() and basic.min() != basic.max():
		best = basic
		var metrics := _measure_levels(best, data, graph.neighbors)
		metrics.merge(_measure_ground(best, data, graph), true)
		metrics.merge(_measure_castle_regions(best, data, graph, c), true)
		best_score = _castle_score(metrics)
		profile = "castle_contrast_fallback"
	return {"levels": best, "profile": profile, "score": best_score}


func _measure_ground(levels: Array, data: Dictionary, graph: Dictionary) -> Dictionary:
	# Reuse the same adjacency tests with ALL original cells in the domain.
	var all_graph := {"free": data.owner, "protected": {}, "neighbors": graph.neighbors, "hard_pins": graph.get("hard_pins", {})}
	var m := _measure_free(levels, data, all_graph)
	return {"largest_ground_plateau": m.largest_free_plateau, "largest_ground_plateau_ratio": float(m.largest_free_plateau) / maxi(1, data.owner.size()), "ground_flat_cells": m.free_flat_cells, "ground_flat_ratio": m.free_flat_ratio, "ground_continuous_slope_cells": m.free_continuous_slope_cells, "ground_continuous_slope_ratio": m.free_continuous_slope_coverage, "ground_isolated_extrema": m.free_isolated_extrema, "ground_isolated_extrema_ratio": m.free_isolated_extrema_ratio, "ground_plateau_area_fraction": m.free_plateau_area_fraction}


func _measure_castle_regions(levels: Array, data: Dictionary, graph: Dictionary, c: Dictionary) -> Dictionary:
	var low: int = levels.min()
	var high: int = levels.max()
	var span: int = high - low
	var bounds := _ground_bounds(data.owner.keys())
	var bbox_span: float = maxf(bounds.size.x, bounds.size.y)
	var samples: Array = []
	for coord in data.owner: samples.append(levels[data.owner[coord]])
	samples.sort()
	var p10: int = samples[floori((samples.size() - 1) * 0.10)]
	var p90: int = samples[floori((samples.size() - 1) * 0.90)]
	var upper: Dictionary = _height_band(levels, data, graph, samples[floori((samples.size() - 1) * 0.70)], true)
	var lower: Dictionary = _height_band(levels, data, graph, samples[floori((samples.size() - 1) * 0.25)], false)
	var denominator: float = maxf(1.0, data.owner.size())
	var physical_relief: float = span * c.quantum
	return {"ground_bbox_width": bounds.size.x, "ground_bbox_height": bounds.size.y, "physical_relief_units": physical_relief, "castle_p10_level": p10, "castle_p90_level": p90, "physical_regional_relief_units": (p90 - p10) * c.quantum, "physical_regional_relief_to_bbox_span": (p90 - p10) * c.quantum / bbox_span, "physical_relief_to_bbox_span": physical_relief / bbox_span, "physical_step_units": c.quantum, "physical_step_run_ratio": c.quantum / sqrt(3.0), "physical_step_angle_degrees": rad_to_deg(atan(c.quantum / sqrt(3.0))) if span > 0 else 0.0, "castle_high_region_cells": upper.cells, "castle_high_region_coverage": upper.cells / denominator, "castle_high_region_largest_cells": upper.largest, "castle_high_region_largest_ratio": upper.largest / denominator, "castle_high_region_coherence": float(upper.largest) / maxi(1, upper.cells), "castle_high_region_span_ratio": upper.span / bbox_span, "castle_low_region_cells": lower.cells, "castle_low_region_coverage": lower.cells / denominator, "castle_low_region_largest_cells": lower.largest, "castle_low_region_largest_ratio": lower.largest / denominator, "castle_low_region_coherence": float(lower.largest) / maxi(1, lower.cells), "castle_low_region_span_ratio": lower.span / bbox_span}


func _height_band(levels: Array, data: Dictionary, graph: Dictionary, threshold: float, upper: bool) -> Dictionary:
	var selected := {}
	for coord in data.owner:
		var level: int = levels[data.owner[coord]]
		if (level >= threshold if upper else level <= threshold): selected[coord] = true
	var seen := {}
	var largest := 0
	var span := 0.0
	for start in selected:
		if seen.has(start): continue
		var queue: Array = [start]
		seen[start] = true
		var index := 0
		while index < queue.size():
			for other in graph.neighbors[queue[index]]:
				if selected.has(other) and not seen.has(other):
					seen[other] = true
					queue.append(other)
			index += 1
		if queue.size() > largest:
			largest = queue.size()
			var bounds := _ground_bounds(queue)
			span = maxf(bounds.size.x, bounds.size.y)
	return {"cells": selected.size(), "largest": largest, "span": span}


func _ground_bounds(coordinates: Array) -> Rect2:
	var minimum: Vector2 = Hex.to_plane(coordinates[0], 1.0)
	var maximum := minimum
	for coord in coordinates:
		var p: Vector2 = Hex.to_plane(coord, 1.0)
		minimum = minimum.min(p)
		maximum = maximum.max(p)
	return Rect2(minimum - Vector2(1.0, sqrt(3.0) * 0.5), maximum - minimum + Vector2(2.0, sqrt(3.0)))


func _castle_score(m: Dictionary) -> float:
	# Macro district coherence outranks micro roughness. Low-region area checks
	# broad basins; no count/balance of tiny peaks and valleys is rewarded.
	var macro: float = 1.3 * m.castle_high_region_coherence + 1.3 * minf(0.30, m.castle_high_region_largest_ratio) / 0.30 - 1.1 * absf(m.castle_high_region_span_ratio - 0.50) + 0.4 * minf(0.20, m.castle_low_region_largest_ratio) / 0.20 + 0.5 * minf(0.20, m.physical_regional_relief_to_bbox_span) / 0.20
	return macro + 0.7 * m.slope_edge_ratio + 0.8 * m.ground_continuous_slope_ratio - 1.5 * m.largest_ground_plateau_ratio - 0.7 * m.ground_flat_ratio - 0.8 * m.ground_plateau_area_fraction - 5.0 * m.ground_isolated_extrema_ratio + 0.03 * mini(16, m.level_span) + 0.03 * mini(12, m.longest_ascent_edges)


func _castle_status(m: Dictionary, c: Dictionary) -> Dictionary:
	var reasons: Array = []
	if c.amplitude_levels == 0.0: return {"status": "flat_requested", "limitations": reasons}
	if m.level_span < 6: reasons.append("fewer_than_seven_height_tiers")
	if m.largest_ground_plateau_ratio > 0.12: reasons.append("large_connected_plateau")
	if m.ground_flat_ratio > 0.20: reasons.append("large_flat_interior")
	if m.ground_continuous_slope_ratio < 0.12: reasons.append("few_continuous_slopes")
	if m.longest_ascent_edges < 6: reasons.append("short_consecutive_ascents")
	if m.ground_isolated_extrema_ratio > 0.04: reasons.append("isolated_extrema")
	if m.castle_high_region_largest_ratio < 0.10: reasons.append("small_upper_district")
	if m.castle_high_region_span_ratio < 0.30: reasons.append("short_upper_district")
	if m.castle_high_region_coherence < 0.60: reasons.append("fragmented_upper_district")
	if m.castle_low_region_largest_ratio < 0.04: reasons.append("small_lower_district")
	if m.physical_regional_relief_to_bbox_span < 0.06: reasons.append("shallow_regional_physical_relief")
	return {"status": "candidate_meets_relief_thresholds" if reasons.is_empty() else "limited_relief", "limitations": reasons}


func _select_rugged(basic: Array, lower: Array, upper: Array, data: Dictionary, free_graph: Dictionary, c: Dictionary, noise_seed: int) -> Dictionary:
	# Six correlated fields, two envelope blends each. No route-distance field,
	# amplitude clipping, random draws, or retries. Anchors still bound every fit.
	var broad := _rugged_noise(noise_seed, 15485863, c.wavelength * 1.5, 0.35, false)
	var fine := _rugged_noise(noise_seed, 32452843, maxf(2.5, c.wavelength * 0.32), 0.18, true)
	var best: Array = _smooth_rugged_extrema(basic, lower, upper, data, free_graph)
	var best_score := _rugged_score(_measure_free(best, data, free_graph))
	var profile := "basic" if best == basic else "basic_smoothed"
	var scales: Array = [0.55, 0.75, 1.05]
	for band in scales.size():
		var wavelength: float = maxf(2.5, c.wavelength * scales[band])
		var medium := _rugged_noise(noise_seed, 104729 + band * 7919, wavelength, 0.15 + c.detail * 0.3, true)
		var ridge := _rugged_noise(noise_seed, 49979687 + band * 7907, wavelength * 1.2, 0.2, true)
		ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
		for ridge_sign in [-1.0, 1.0]:
			var raw: Array = []
			for group in data.groups:
				var value := 0.0
				for coord in group:
					var p: Vector2 = Hex.to_plane(coord, 1.0)
					value += 0.45 * broad.get_noise_2d(p.x, p.y) + 1.9 * medium.get_noise_2d(p.x, p.y) + ridge_sign * 0.55 * ridge.get_noise_2d(p.x, p.y) + c.detail * 0.35 * fine.get_noise_2d(p.x, p.y)
				raw.append(value / group.size() * c.amplitude_levels)
			var origin: float = raw[data.owner[data.spawn]]
			for i in raw.size(): raw[i] += c.baseline_level - origin
			# Move the field under/over an extremum before local anchor clamping.
			# Clamping half a signed field to a highest Boss creates a large mesa.
			var shift := 0.0
			if c.boss_mode == "highest": shift = minf(0.0, upper[data.boss_group] - float(raw.max()))
			elif c.boss_mode == "lowest": shift = maxf(0.0, lower[data.boss_group] - float(raw.min()))
			var targets: Array = []
			for i in raw.size(): targets.append(clampf(raw[i] + shift, lower[i], upper[i]))
			var low := _max_envelope(targets, data.edges)
			var high := _min_envelope(targets, data.edges)
			for blend in [0.35, 0.65]:
				var candidate: Array = []
				for i in targets.size(): candidate.append(_round_level(lerpf(low[i], high[i], blend)))
				candidate = _smooth_rugged_extrema(candidate, lower, upper, data, free_graph)
				var score := _rugged_score(_measure_free(candidate, data, free_graph))
				if score > best_score + 0.000000001:
					best = candidate
					best_score = score
					profile = "warped_band_%d_%s_blend_%02d" % [band, "ridge" if ridge_sign > 0 else "valley", int(blend * 100)]
	if best.min() == best.max():
		# On very small inputs, removing every optional tip can erase the only
		# feasible sampled contrast. Preserve the valid baseline rather than
		# silently returning a flat map for a positive amplitude.
		best = basic
		best_score = _rugged_score(_measure_free(best, data, free_graph))
		profile = "basic_contrast_fallback"
	return {"levels": best, "profile": profile, "score": best_score}


func _smooth_rugged_extrema(levels: Array, lower: Array, upper: Array, data: Dictionary, graph: Dictionary) -> Array:
	# Two coordinate-ordered passes remove free one-cell tips. Strict neighbors
	# of a unit-step extremum all share one level, so each update stays Lipschitz.
	# Sequential updates break binary corridor oscillation. Hard pins never move.
	var result: Array = levels.duplicate()
	for pass_index in 2:
		for coord in graph.free:
			var adjacent: Array = graph.neighbors[coord]
			if adjacent.size() < 2: continue
			var group: int = data.owner[coord]
			var replacement: int = result[data.owner[adjacent[0]]]
			if replacement == result[group] or replacement < lower[group] or replacement > upper[group]: continue
			var strict := true
			for other in adjacent:
				if result[data.owner[other]] != replacement:
					strict = false
					break
			if strict: result[group] = replacement
	return result


func _rugged_noise(noise_seed: int, offset: int, wavelength: float, gain: float, warp: bool) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = posmod(noise_seed + offset, 4294967296) - 2147483648
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 1.0 / (wavelength * sqrt(3.0))
	noise.fractal_octaves = 3
	noise.fractal_gain = gain
	noise.fractal_lacunarity = 2.0
	noise.domain_warp_enabled = warp
	noise.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX_REDUCED
	noise.domain_warp_amplitude = wavelength * sqrt(3.0) * 0.22
	noise.domain_warp_frequency = noise.frequency * 0.6
	noise.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_PROGRESSIVE
	noise.domain_warp_fractal_octaves = 2
	return noise


func _free_graph(data: Dictionary) -> Dictionary:
	var protected: Dictionary = {data.spawn: true}
	for footprint in data.protected_footprints.values():
		for coord in footprint: protected[coord] = true
	var coordinates: Array = data.owner.keys()
	coordinates.sort_custom(_coord_less)
	var neighbors: Dictionary = {}
	var free: Dictionary = {}
	for coord in coordinates:
		var adjacent: Array = []
		for other in Hex.neighbors(coord):
			if data.owner.has(other): adjacent.append(other)
		neighbors[coord] = adjacent
		if not protected.has(coord): free[coord] = true
	return {"protected": protected, "free": free, "neighbors": neighbors}


func _measure_free(levels: Array, data: Dictionary, graph: Dictionary) -> Dictionary:
	# All denominators and components count original ground hexes, never groups.
	# Flat/slope/extremum tests include protected ground neighbors as well.
	var flat := 0
	var slope := 0
	var continuous := 0
	var isolated := 0
	var hard_isolated := 0
	for coord in graph.free:
		var level: int = levels[data.owner[coord]]
		var above := 0
		var below := 0
		var degree: int = graph.neighbors[coord].size()
		for other in graph.neighbors[coord]:
			var delta: int = levels[data.owner[other]] - level
			if delta > 0: above += 1
			elif delta < 0: below += 1
		if above + below == 0: flat += 1
		else: slope += 1
		if above > 0 and below > 0: continuous += 1
		# Degree-one corridor ends are not single-cell spikes. Equal neighbors
		# exclude a cell from strict extrema, including a multi-cell summit.
		if degree >= 2 and (above == degree or below == degree):
			isolated += 1
			if graph.get("hard_pins", {}).has(coord): hard_isolated += 1
	var seen: Dictionary = {}
	var largest := 0
	var plateau_area := 0
	var peaks := 0
	var valleys := 0
	for start in graph.free:
		if seen.has(start): continue
		var level: int = levels[data.owner[start]]
		var queue: Array = [start]
		seen[start] = true
		var index := 0
		var boundary_above := 0
		var boundary_below := 0
		var boundary_equal := 0
		while index < queue.size():
			var coord: Vector2i = queue[index]
			index += 1
			for other in graph.neighbors[coord]:
				var other_level: int = levels[data.owner[other]]
				if other_level == level and graph.free.has(other):
					if not seen.has(other):
						seen[other] = true
						queue.append(other)
				elif other_level > level: boundary_above += 1
				elif other_level < level: boundary_below += 1
				else: boundary_equal += 1
		largest = maxi(largest, queue.size())
		plateau_area += queue.size() * queue.size()
		if queue.size() >= 2 and boundary_equal == 0:
			if boundary_above == 0 and boundary_below > 0: peaks += 1
			if boundary_below == 0 and boundary_above > 0: valleys += 1
	var count: int = graph.free.size()
	var denominator := maxi(1, count)
	return {"protected_cells": graph.protected.size(), "free_cells": count, "free_flat_cells": flat, "free_flat_ratio": float(flat) / denominator, "free_slope_cells": slope, "free_slope_coverage": float(slope) / denominator, "free_continuous_slope_cells": continuous, "free_continuous_slope_coverage": float(continuous) / denominator, "largest_free_plateau": largest, "free_plateau_area_fraction": float(plateau_area) / (denominator * denominator), "free_isolated_extrema": isolated, "free_hard_anchor_extrema": hard_isolated, "free_isolated_extrema_ratio": float(isolated) / denominator, "free_multicell_peaks": peaks, "free_multicell_valleys": valleys}


func _rugged_score(metrics: Dictionary) -> float:
	# Penalties supplement the explicit tip smoothing; they are not by themselves
	# a checkerboard prohibition. Through-slopes need uphill and downhill exits.
	var largest_fraction: float = float(metrics.largest_free_plateau) / maxi(1, metrics.free_cells)
	var diversity := mini(4, mini(metrics.free_multicell_peaks, metrics.free_multicell_valleys))
	return 3.0 * metrics.free_slope_coverage + 1.5 * metrics.free_continuous_slope_coverage - 1.5 * largest_fraction - 1.5 * metrics.free_plateau_area_fraction - 6.0 * metrics.free_isolated_extrema_ratio + 0.12 * diversity


func _rugged_wall_levels(cells: Array, levels: Array, data: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var ground: Array = data.owner.keys()
	ground.sort_custom(_coord_less)
	for cell in cells:
		if cell.terrain != "wall": continue
		var coord := Vector2i(int(cell.q), int(cell.r))
		var sum := 0.0
		var count := 0
		for other in Hex.neighbors(coord):
			if data.owner.has(other):
				sum += levels[data.owner[other]]
				count += 1
		if count > 0:
			result[coord] = _round_level(sum / count)
		else:
			# Detached manual wall inputs have no touching terrain; use the nearest
			# final ground (coordinate-order ties), bounded by the 4096-cell cap.
			var nearest: Vector2i = ground[0]
			var distance := Hex.distance(coord, nearest)
			for other in ground:
				var candidate := Hex.distance(coord, other)
				if candidate < distance:
					nearest = other
					distance = candidate
			result[coord] = levels[data.owner[nearest]]
	return result


func _select_aggressive(basic: Array, raw: Array, lower: Array, upper: Array, data: Dictionary, c: Dictionary) -> Dictionary:
	# No random draws or layout changes. Baseline hard anchors also constrain
	# every candidate, including implicit Boss anchors and the variation guard.
	var budget := maxf(1.0, c.amplitude_levels)
	var route := _route_field(data, raw)
	var best: Array = basic
	var basic_metrics := _measure_levels(basic, data)
	var best_metrics: Dictionary = basic_metrics
	var profile := "basic"
	for name in ["noise_gain", "graph_blend", "graph_dominant"]:
		var targets: Array = []
		for i in raw.size():
			var delta: float = float(raw[i]) - c.baseline_level
			if name == "noise_gain":
				delta *= 3.0
			elif name == "graph_blend":
				delta = delta * 1.8 + float(route[i]) * 0.75
			else:
				delta = delta * 0.45 + float(route[i]) * 0.95
			var target: float = float(c.baseline_level) + clampf(delta, -budget, budget)
			targets.append(clampf(target, lower[i], upper[i]))
		var candidate := _fit(targets, data.edges)
		var metrics := _measure_levels(candidate, data)
		# More relief must not shorten an existing strict uphill cell chain.
		# Dense platform graphs may honestly retain the baseline candidate.
		if metrics.level_span < basic_metrics.level_span or metrics.longest_ascent_edges < basic_metrics.longest_ascent_edges:
			continue
		if _better_metrics(metrics, best_metrics):
			best = candidate
			best_metrics = metrics
			profile = name
	return {"levels": best, "profile": profile}


func _route_field(data: Dictionary, raw: Array) -> Array:
	# Difference of graph distances gives a gradual peak/valley field. Work on
	# contracted platforms, not room centers or screen/camera directions.
	var field: Array = []
	field.resize(data.groups.size())
	field.fill(0.0)
	var seen: Dictionary = {}
	var spawn_group: int = data.owner[data.spawn]
	for start in data.groups.size():
		if seen.has(start): continue
		var component_dist := _distances(start, data.edges)
		var component: Array = component_dist.keys()
		component.sort()
		var seed_group: int = component[0]
		for i in component:
			seen[i] = true
			if raw[i] < raw[seed_group]: seed_group = i
		var seed_dist := _distances(seed_group, data.edges)
		var peak: int = seed_group
		for i in component:
			if seed_dist[i] > seed_dist[peak] or (seed_dist[i] == seed_dist[peak] and raw[i] > raw[peak]): peak = i
		var peak_dist := _distances(peak, data.edges)
		var valley: int = peak
		for i in component:
			if peak_dist[i] > peak_dist[valley] or (peak_dist[i] == peak_dist[valley] and raw[i] < raw[valley]): valley = i
		var valley_dist := _distances(valley, data.edges)
		var origin := 0.0
		if peak_dist.has(spawn_group):
			origin = (float(valley_dist[spawn_group]) - float(peak_dist[spawn_group])) * 0.5
		for i in component:
			field[i] = (float(valley_dist[i]) - float(peak_dist[i])) * 0.5 - origin
	return field


func _distances(start: int, edges: Array) -> Dictionary:
	var queue: Array = [start]
	var distances: Dictionary = {start: 0}
	var index := 0
	while index < queue.size():
		var a: int = queue[index]
		index += 1
		for b in edges[a]:
			if not distances.has(b):
				distances[b] = distances[a] + 1
				queue.append(b)
	return distances


func _measure_levels(levels: Array, data: Dictionary, neighbors: Dictionary = {}) -> Dictionary:
	var coordinates: Array = data.owner.keys()
	coordinates.sort_custom(func(a, b):
		var la: int = levels[data.owner[a]]
		var lb: int = levels[data.owner[b]]
		return la < lb if la != lb else _coord_less(a, b))
	var ascent: Dictionary = {}
	var longest := 0
	var ramp_cells := 0
	var slope_edges := 0
	var all_edges := 0
	for coord in coordinates:
		var level: int = levels[data.owner[coord]]
		var length := 0
		var adjacent: Array = neighbors[coord] if neighbors.has(coord) else Hex.neighbors(coord)
		for neighbor in adjacent:
			if not data.owner.has(neighbor): continue
			var other: int = levels[data.owner[neighbor]]
			if _coord_less(coord, neighbor): all_edges += 1
			if other == level - 1:
				slope_edges += 1
				length = maxi(length, int(ascent.get(neighbor, 0)) + 1)
		ascent[coord] = length
		longest = maxi(longest, length)
		if length >= 2: ramp_cells += 1
	return {"level_span": int(levels.max()) - int(levels.min()), "longest_ascent_edges": longest, "two_step_ramp_cells": ramp_cells, "slope_edges": slope_edges, "ground_edges": all_edges, "slope_edge_ratio": float(slope_edges) / maxi(1, all_edges)}


func _better_metrics(a: Dictionary, b: Dictionary) -> bool:
	for key in ["longest_ascent_edges", "level_span", "two_step_ramp_cells", "slope_edges"]:
		if a[key] != b[key]: return a[key] > b[key]
	return false


func _prepare(planar: Dictionary, event_flat_mode: String = "full", foundation_mode: String = "legacy") -> Dictionary:
	if event_flat_mode not in ["full", "partial", "center"]:
		return _fail("event_flat_mode must be full/partial/center")
	if foundation_mode not in ["legacy", "full", "partial", "center"]:
		return _fail("foundation_mode must be legacy/full/partial/center")
	if not planar.get("cells") is Array or not planar.get("nodes") is Array or not _coordinate(planar.get("spawn")):
		return _fail("Height input requires cells/nodes arrays and an axial spawn pair")
	if planar.cells.is_empty() or planar.cells.size() > CELL_LIMIT or (planar.has("metadata") and not planar.metadata is Dictionary):
		return _fail("Height input has an invalid cell count or metadata")
	var ground: Dictionary = {}
	var cells: Dictionary = {}
	for cell in planar.cells:
		if not cell is Dictionary or not _integer(cell.get("q")) or not _integer(cell.get("r")) or cell.get("terrain") not in ["ground", "wall"]:
			return _fail("Malformed height input cell")
		var coord := Vector2i(int(cell.q), int(cell.r))
		if cells.has(coord):
			return _fail("Duplicate height input cell coordinate")
		cells[coord] = true
		if cell.terrain == "ground":
			ground[coord] = true
	var spawn := _coord(planar.spawn)
	if not ground.has(spawn):
		return _fail("Height input spawn must be on ground")
	var groups: Array = []
	var owner: Dictionary = {}
	var physical_owner: Dictionary = {}
	var protected_footprints: Dictionary = {}
	var node_original_cells := 0
	var protected_node_cells := 0
	var event_original_cells := 0
	var protected_event_cells := 0
	var ids: Dictionary = {}
	var boss_group := -1
	var nodes: Array = planar.nodes.duplicate()
	for node in nodes:
		if not node is Dictionary or not node.get("id") is String or node.id.is_empty() or not node.get("type") is String or not _coordinate(node.get("coord")) or not node.get("footprint") is Array or node.footprint.is_empty():
			return _fail("Malformed height input node")
		if ids.has(node.id):
			return _fail("Duplicate height input node ID")
		ids[node.id] = true
	nodes.sort_custom(func(a, b): return a.id < b.id)
	for node in nodes:
		var group: Array = []
		var seen: Dictionary = {}
		for point in node.footprint:
			if not _coordinate(point):
				return _fail("Malformed node footprint coordinate: " + node.id)
			var coord := _coord(point)
			if not ground.has(coord) or seen.has(coord) or physical_owner.has(coord):
				return _fail("Node footprint must be unique, nonoverlapping ground: " + node.id)
			group.append(coord)
			seen[coord] = true
			physical_owner[coord] = node.id
		if not seen.has(_coord(node.coord)) or not _connected(group, seen):
			return _fail("Node footprint must be connected and contain its center: " + node.id)
		group.sort_custom(_coord_less)
		node_original_cells += group.size()
		if node.type == "event": event_original_cells += group.size()
		var mode: String = event_flat_mode if foundation_mode == "legacy" and node.type == "event" else ("full" if foundation_mode == "legacy" else foundation_mode)
		group = _event_foundation(_coord(node.coord), group, ground, mode)
		protected_node_cells += group.size()
		if node.type == "event": protected_event_cells += group.size()
		if not _validate_flat_annotation(node, group, mode):
			return {}
		protected_footprints[node.id] = group
		for coord in group:
			owner[coord] = groups.size()
		if node.type == "boss":
			if boss_group >= 0:
				return _fail("Height input supports at most one boss node")
			boss_group = groups.size()
		groups.append(group)
	var coordinates: Array = ground.keys()
	coordinates.sort_custom(_coord_less)
	for coord in coordinates:
		if not owner.has(coord):
			owner[coord] = groups.size()
			groups.append([coord])
	var edges: Array = []
	for i in groups.size():
		edges.append([])
	for coord in coordinates:
		var a: int = owner[coord]
		for neighbor in Hex.neighbors(coord):
			if ground.has(neighbor):
				var b: int = owner[neighbor]
				if a != b and b not in edges[a]:
					edges[a].append(b)
	for edge in edges:
		edge.sort()
	return {"groups": groups, "owner": owner, "edges": edges, "spawn": spawn, "boss_group": boss_group, "protected_footprints": protected_footprints, "node_original_cells": node_original_cells, "protected_node_cells": protected_node_cells, "event_original_cells": event_original_cells, "protected_event_cells": protected_event_cells}


func _layer_event_flat_mode(layer: Dictionary) -> String:
	# Existing layers without the new field retain full-footprint protection.
	if not layer.has("metadata"):
		return "full"
	if not layer.metadata is Dictionary:
		_fail("Height layer metadata must be a Dictionary")
		return ""
	if not layer.metadata.has("height"):
		return "full"
	var height: Variant = layer.metadata.height
	if not height is Dictionary:
		_fail("Height layer metadata.height must be a Dictionary")
		return ""
	if not height.has("config"):
		return "full"
	if not height.config is Dictionary:
		_fail("Height layer metadata.height.config must be a Dictionary")
		return ""
	var config: Dictionary = normalize_config(height.config)
	return "" if config.is_empty() else str(config.event_flat_mode)


func _layer_foundation_mode(layer: Dictionary) -> String:
	# Absent metadata/config retains the exact historical event-only behavior.
	if not layer.has("metadata"): return "legacy"
	if not layer.metadata is Dictionary:
		_fail("Height layer metadata must be a Dictionary")
		return ""
	var height: Variant = layer.metadata.get("height", {})
	if not height is Dictionary:
		_fail("Height layer metadata.height must be a Dictionary")
		return ""
	var config: Variant = height.get("config", {})
	if not config is Dictionary:
		_fail("Height layer metadata.height.config must be a Dictionary")
		return ""
	var normalized: Dictionary = normalize_config(config)
	return "" if normalized.is_empty() else str(normalized.foundation_mode)


func _validate_flat_annotation(node: Dictionary, expected: Array, mode: String) -> bool:
	if not node.has("height_flat_footprint"):
		return true
	if mode == "full":
		last_error = "height_flat_footprint is allowed only on reduced foundations: " + node.id
		return false
	var annotation: Variant = node.height_flat_footprint
	if not annotation is Array or annotation.is_empty() or annotation.size() > 3:
		last_error = "height_flat_footprint must contain 1..3 axial pairs: " + node.id
		return false
	var seen: Dictionary = {}
	var points: Array = []
	for point in annotation:
		if not _coordinate(point):
			last_error = "Malformed height_flat_footprint coordinate: " + node.id
			return false
		var coord := _coord(point)
		if seen.has(coord) or coord not in expected:
			last_error = "height_flat_footprint conflicts with the selected foundation: " + node.id
			return false
		seen[coord] = true
		points.append(coord)
	if seen.size() != expected.size() or not seen.has(_coord(node.coord)) or not _connected(points, seen):
		last_error = "height_flat_footprint must match the connected selected foundation and include its center: " + node.id
		return false
	return true


func _event_foundation(center: Vector2i, physical: Array, ground: Dictionary, mode: String) -> Array:
	if mode == "full":
		return physical
	if mode == "center":
		return [center]
	var footprint: Dictionary = {}
	for coord in physical:
		footprint[coord] = true
	var candidates: Dictionary = {}
	for adjacent in Hex.neighbors(center):
		if not footprint.has(adjacent): continue
		candidates[adjacent] = true
		for coord in Hex.neighbors(adjacent):
			if coord != center and footprint.has(coord):
				candidates[coord] = true
	var access: Dictionary = {}
	var distances: Dictionary = {}
	var queue: Array = []
	for coord in physical:
		var count := 0
		for neighbor in Hex.neighbors(coord):
			if ground.has(neighbor) and not footprint.has(neighbor): count += 1
		access[coord] = count
		if count > 0:
			distances[coord] = 0
			queue.append(coord)
	var index := 0
	while index < queue.size():
		var coord: Vector2i = queue[index]
		index += 1
		for neighbor in Hex.neighbors(coord):
			if footprint.has(neighbor) and not distances.has(neighbor):
				distances[neighbor] = distances[coord] + 1
				queue.append(neighbor)
	var choices: Array = [[center]]
	var available: Array = candidates.keys()
	available.sort_custom(_coord_less)
	for i in available.size():
		var a: Vector2i = available[i]
		if Hex.distance(center, a) == 1:
			choices.append([center, a])
		for j in range(i + 1, available.size()):
			var b: Vector2i = available[j]
			var points: Array = [center, a, b]
			var mask: Dictionary = {center: true, a: true, b: true}
			if _connected(points, mask): choices.append(points)
	var best: Array = [center]
	var best_score: Array = _foundation_score(best, center, access, distances)
	for choice in choices:
		choice.sort_custom(_coord_less)
		var score: Array = _foundation_score(choice, center, access, distances)
		var comparison := 0
		for i in score.size():
			if score[i] != best_score[i]:
				comparison = 1 if score[i] > best_score[i] else -1
				break
		if comparison > 0 or (comparison == 0 and _footprint_less(choice, best)):
			best = choice
			best_score = score
	return best


func _foundation_score(points: Array, center: Vector2i, access: Dictionary, distances: Dictionary) -> Array:
	var center_neighbors := 0
	var internal_edges := 0
	var access_edges := 0
	var distance_sum := 0
	for i in points.size():
		var coord: Vector2i = points[i]
		if Hex.distance(coord, center) == 1: center_neighbors += 1
		access_edges += int(access[coord])
		distance_sum += int(distances.get(coord, 0))
		for j in range(i + 1, points.size()):
			if Hex.distance(coord, points[j]) == 1: internal_edges += 1
	# Compact center + adjacent pair first, then actual ground access. No camera
	# direction, terrain edits, or random draws enter this deterministic choice.
	return [points.size(), center_neighbors, internal_edges, access_edges, -distance_sum]


func _footprint_less(a: Array, b: Array) -> bool:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]: return _coord_less(a[i], b[i])
	return a.size() < b.size()


func _fit(targets: Array, edges: Array) -> Array:
	var upper: Array = _min_envelope(targets, edges)
	var lower: Array = _max_envelope(targets, edges)
	var result: Array = []
	for i in targets.size():
		# floor(x+.5) commutes with integer shifts; roundi() does not at zero.
		result.append(_round_level((upper[i] + lower[i]) * 0.5))
	return result


func _min_envelope(initial: Array, edges: Array) -> Array:
	var out: Array = initial.duplicate()
	var queue: Array = []
	var queued: Dictionary = {}
	for i in out.size():
		if is_finite(float(out[i])):
			queue.append(i)
			queued[i] = true
	var index := 0
	while index < queue.size():
		var a: int = queue[index]
		queued.erase(a)
		index += 1
		for b in edges[a]:
			if out[b] > out[a] + 1:
				out[b] = out[a] + 1
				if not queued.has(b):
					queue.append(b)
					queued[b] = true
	return out


func _max_envelope(initial: Array, edges: Array) -> Array:
	var negative: Array = []
	for value in initial:
		negative.append(-value)
	var result: Array = _min_envelope(negative, edges)
	for i in result.size():
		result[i] = -result[i]
	return result


func _distance(start: int, goal: int, edges: Array) -> int:
	var queue: Array = [start]
	var distances: Dictionary = {start: 0}
	var index := 0
	while index < queue.size():
		var a: int = queue[index]
		index += 1
		if a == goal:
			return distances[a]
		for b in edges[a]:
			if not distances.has(b):
				distances[b] = distances[a] + 1
				queue.append(b)
	return -1


func _connected(group: Array, cells: Dictionary) -> bool:
	var queue: Array = [group[0]]
	var seen: Dictionary = {group[0]: true}
	var index := 0
	while index < queue.size():
		for neighbor in Hex.neighbors(queue[index]):
			if cells.has(neighbor) and not seen.has(neighbor):
				seen[neighbor] = true
				queue.append(neighbor)
		index += 1
	return seen.size() == group.size()


func _round_level(value: float) -> int:
	return floori(value + 0.5)


func _coord_less(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x or (a.x == b.x and a.y < b.y)


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value)) and absf(float(value)) <= INTEGER_LIMIT


func _coordinate(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _integer(value[0]) and _integer(value[1])


func _coord(value: Array) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1]))


func _fail(message: String) -> Dictionary:
	last_error = message
	return {}


static func _measure_level_span(levels: Array) -> Dictionary:
	# Network selection consumes only span; full final diagnostics stay intact.
	return {"level_span": int(levels.max()) - int(levels.min())}

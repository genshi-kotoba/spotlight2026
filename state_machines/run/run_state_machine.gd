class_name RunStateMachine
extends Node

## PRG-003：一局游戏内的地图、玩家资源、牌组、道具、池与战斗进度。

signal run_started(snapshot: Dictionary)
signal run_ended(result: Dictionary)
signal stat_updated(metric: StringName, value: Variant)
signal map_node_updated(map_id: String, node_id: String, state: Dictionary)
signal battle_started(battle: BattleStateMachine)
signal battle_finished(result: Dictionary)
signal state_changed

const SNAPSHOT_VERSION := 1

var run_id := ""
var main_seed := ""
var active := false
var result: Dictionary = {}

var max_health := 0
var health := 0
var gold := 0
var deck: Array[String] = []
var card_pool: Array[String] = []
var items: Array = []

var map_ids: Array[String] = []
var current_map_id := ""
var map_states: Dictionary = {}
var reward_pool: Array[String] = []
var shop_pool: Array[String] = []
var event_pool: Array[String] = []

var battles_fought := 0
var stages_completed := 0
var defeated_enemy_ids: Array[String] = []
var battle_index_by_node: Dictionary = {}

var current_battle: BattleStateMachine
var last_error: Error = OK


func initialize_new(seed_text: String, config: Dictionary,
		unlocked_cards: Array) -> Error:
	if active or current_battle != null:
		return _fail(ERR_ALREADY_IN_USE, "Run is already initialized")

	var prepared := _prepare_new_config(config, unlocked_cards)
	if prepared.is_empty():
		return last_error
	var chosen_seed := SeedService.begin_run(seed_text)
	if chosen_seed.is_empty():
		return _fail(SeedService.last_error, "Could not begin the seeded run")

	run_id = prepared["run_id"]
	main_seed = chosen_seed
	max_health = prepared["max_health"]
	health = prepared["health"]
	gold = prepared["gold"]
	deck.assign(prepared["deck"])
	card_pool.assign(prepared["card_pool"])
	items = prepared["items"].duplicate(true)
	map_ids.assign(prepared["map_ids"])
	current_map_id = map_ids[0]

	map_states.clear()
	for map_id: String in map_ids:
		map_states[map_id] = {"completed": false, "nodes": {}}

	var seeded_rewards: Variant = _seeded_pool(RandomDomains.REWARD, prepared["reward_pool"])
	if seeded_rewards == null:
		return last_error
	reward_pool.assign(seeded_rewards)
	var seeded_shops: Variant = _seeded_pool(RandomDomains.SHOP, prepared["shop_pool"])
	if seeded_shops == null:
		return last_error
	shop_pool.assign(seeded_shops)
	var seeded_events: Variant = _seeded_pool(RandomDomains.EVENT_POOL, prepared["event_pool"])
	if seeded_events == null:
		return last_error
	event_pool.assign(seeded_events)

	battles_fought = 0
	stages_completed = 0
	defeated_enemy_ids.clear()
	battle_index_by_node.clear()
	result.clear()
	active = true
	last_error = OK
	run_started.emit(to_dictionary())
	state_changed.emit()
	return OK


func restore_from_dictionary(data: Dictionary) -> Error:
	if active or current_battle != null:
		return _fail(ERR_ALREADY_IN_USE, "Run is already initialized")
	if not _integer_equals(data.get("snapshot_version"), SNAPSHOT_VERSION):
		return _fail(ERR_INVALID_DATA, "Run snapshot version is invalid")

	var saved_run_id: Variant = data.get("run_id")
	var saved_seed: Variant = data.get("main_seed")
	var saved_active: Variant = data.get("active")
	var saved_result: Variant = data.get("result")
	var saved_deck: Variant = data.get("deck")
	var saved_cards: Variant = data.get("card_pool")
	var saved_items: Variant = data.get("items")
	var saved_maps: Variant = data.get("map_ids")
	var saved_current_map: Variant = data.get("current_map_id")
	var saved_map_states: Variant = data.get("map_states")
	var saved_rewards: Variant = data.get("reward_pool")
	var saved_shops: Variant = data.get("shop_pool")
	var saved_events: Variant = data.get("event_pool")
	var saved_defeated: Variant = data.get("defeated_enemy_ids")
	var saved_indices: Variant = data.get("battle_index_by_node")
	var saved_battle: Variant = data.get("current_battle")

	if not saved_run_id is String or saved_run_id.strip_edges().is_empty() \
			or not saved_seed is String or saved_seed.is_empty() \
			or saved_seed != SeedService.get_main_seed() or not saved_active is bool \
			or not saved_result is Dictionary or not _string_array_valid(saved_deck) \
			or not _string_array_valid(saved_cards) or not saved_items is Array \
			or not _string_array_valid(saved_maps) or not saved_current_map is String \
			or not saved_map_states is Dictionary or not _string_array_valid(saved_rewards) \
			or not _string_array_valid(saved_shops) or not _string_array_valid(saved_events) \
			or not _string_array_valid(saved_defeated) or not saved_indices is Dictionary \
			or (saved_battle != null and not saved_battle is Dictionary):
		return _fail(ERR_INVALID_DATA, "Run snapshot fields are invalid")

	var saved_max := _integer_value(data.get("max_health"))
	var saved_health := _integer_value(data.get("health"))
	var saved_gold := _integer_value(data.get("gold"))
	var saved_battles := _integer_value(data.get("battles_fought"))
	var saved_stages := _integer_value(data.get("stages_completed"))
	if saved_max == null or saved_health == null or saved_gold == null \
			or saved_battles == null or saved_stages == null or saved_max <= 0 \
			or saved_health < 0 or saved_health > saved_max or saved_gold < 0 \
			or saved_battles < 0 or saved_stages < 0 or not saved_maps.has(saved_current_map) \
			or not _json_safe(saved_result) or not _json_safe(saved_items) \
			or not _unique_string_array_valid(saved_maps) or saved_maps.size() != 3 \
			or not _valid_map_states(saved_map_states, saved_maps) \
			or not _valid_nonnegative_int_dictionary(saved_indices) \
			or (saved_active and not saved_result.is_empty()) \
			or (not saved_active and saved_result.is_empty()) \
			or (not saved_active and saved_battle != null) \
			or (saved_battle != null and saved_battle.get("map_id") != saved_current_map):
		return _fail(ERR_INVALID_DATA, "Run snapshot values are invalid")

	run_id = saved_run_id
	main_seed = saved_seed
	active = saved_active
	result = saved_result.duplicate(true)
	max_health = saved_max
	health = saved_health
	gold = saved_gold
	deck.assign(saved_deck)
	card_pool.assign(saved_cards)
	items = saved_items.duplicate(true)
	map_ids.assign(saved_maps)
	current_map_id = saved_current_map
	map_states = saved_map_states.duplicate(true)
	reward_pool.assign(saved_rewards)
	shop_pool.assign(saved_shops)
	event_pool.assign(saved_events)
	battles_fought = saved_battles
	stages_completed = saved_stages
	defeated_enemy_ids.assign(saved_defeated)
	battle_index_by_node = _normalized_integer_dictionary(saved_indices)

	if saved_battle != null:
		var battle := BattleStateMachine.new()
		add_child(battle)
		var error := battle.restore_from_dictionary(saved_battle)
		if error != OK:
			battle.queue_free()
			return _fail(error, "Could not restore current battle")
		current_battle = battle
		_connect_battle(battle)
	last_error = OK
	return OK


func to_dictionary() -> Dictionary:
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"run_id": run_id,
		"main_seed": main_seed,
		"active": active,
		"result": result.duplicate(true),
		"max_health": max_health,
		"health": health,
		"gold": gold,
		"deck": deck.duplicate(),
		"card_pool": card_pool.duplicate(),
		"items": items.duplicate(true),
		"map_ids": map_ids.duplicate(),
		"current_map_id": current_map_id,
		"map_states": map_states.duplicate(true),
		"reward_pool": reward_pool.duplicate(),
		"shop_pool": shop_pool.duplicate(),
		"event_pool": event_pool.duplicate(),
		"battles_fought": battles_fought,
		"stages_completed": stages_completed,
		"defeated_enemy_ids": defeated_enemy_ids.duplicate(),
		"battle_index_by_node": battle_index_by_node.duplicate(true),
		"current_battle": null if current_battle == null else current_battle.to_dictionary(),
	}


func set_health(value: int) -> Error:
	if not active or value < 0 or value > max_health:
		return _fail(ERR_INVALID_PARAMETER, "Health is outside [0, max_health]")
	health = value
	_emit_stat(&"health", health)
	if health == 0:
		return finish_defeat(current_map_id)
	return OK


func change_health(delta: int) -> Error:
	return set_health(clampi(health + delta, 0, max_health))


func change_gold(delta: int) -> Error:
	if not active or gold + delta < 0:
		return _fail(ERR_INVALID_PARAMETER, "Gold cannot become negative")
	gold += delta
	_emit_stat(&"gold", gold)
	return OK


func add_card(card_id: String) -> Error:
	if not active or not card_pool.has(card_id):
		return _fail(ERR_INVALID_PARAMETER, "Card is not in this run's unlocked pool")
	deck.append(card_id)
	_emit_stat(&"deck_size", deck.size())
	return OK


func remove_card_at(index: int) -> Error:
	if not active or index < 0 or index >= deck.size():
		return _fail(ERR_INVALID_PARAMETER, "Deck index is invalid")
	deck.remove_at(index)
	_emit_stat(&"deck_size", deck.size())
	return OK


func add_item(item: Dictionary) -> Error:
	if not active or not _json_safe(item) or not item.get("item_id") is String \
			or item["item_id"].strip_edges().is_empty():
		return _fail(ERR_INVALID_PARAMETER, "Item needs a stable item_id and JSON-safe data")
	items.append(item.duplicate(true))
	_emit_stat(&"item_count", items.size())
	return OK


func set_current_map(map_id: String) -> Error:
	if not active or not map_ids.has(map_id):
		return _fail(ERR_INVALID_PARAMETER, "Unknown map id")
	current_map_id = map_id
	_emit_stat(&"current_map", current_map_id)
	return OK


## 接收已由地图 × 种子系统生成的业务结果；重进场景时从这里恢复而不是重抽。
func set_map_node_plan(plan: MapNodePlan) -> Error:
	if not active or plan == null or not map_states.has(plan.map_id):
		return _fail(ERR_INVALID_PARAMETER, "Map node plan is invalid for this run")
	var state: Dictionary = map_states[plan.map_id]
	state["node_plan"] = plan.to_dictionary()
	map_states[plan.map_id] = state
	_emit_stat(&"map_plan_count", _count_map_plans())
	return OK


func get_map_node_plan(map_id: String) -> MapNodePlan:
	if not map_states.has(map_id):
		return null
	var saved: Variant = map_states[map_id].get("node_plan")
	if not saved is Dictionary:
		return null
	return MapNodePlan.from_dictionary(saved)


func update_map_node(map_id: String, node_id: String, node_state: Dictionary) -> Error:
	if not active or not map_states.has(map_id) or node_id.strip_edges().is_empty() \
			or not _json_safe(node_state):
		return _fail(ERR_INVALID_PARAMETER, "Map node update is invalid")
	var state: Dictionary = map_states[map_id]
	var nodes: Dictionary = state["nodes"]
	nodes[node_id] = node_state.duplicate(true)
	state["nodes"] = nodes
	map_states[map_id] = state
	map_node_updated.emit(map_id, node_id, node_state.duplicate(true))
	_emit_stat(&"map_node_updates", _count_map_nodes())
	return OK


func complete_current_map() -> Error:
	if not active or not map_states.has(current_map_id):
		return _fail(ERR_UNCONFIGURED, "Current map is invalid")
	var state: Dictionary = map_states[current_map_id]
	if not state.get("completed", false):
		state["completed"] = true
		map_states[current_map_id] = state
		stages_completed += 1
		_emit_stat(&"stages_completed", stages_completed)
	return OK


func record_enemy_defeated(enemy_id: String) -> Error:
	if not active or enemy_id.strip_edges().is_empty():
		return _fail(ERR_INVALID_PARAMETER, "Enemy id is empty")
	defeated_enemy_ids.append(enemy_id)
	_emit_stat(&"enemies_defeated", defeated_enemy_ids.size())
	return OK


func start_battle(node_id: String, enemies: Array, draw_count: int = 5,
		discard_hand_at_turn_end: bool = false) -> Error:
	if not active or current_battle != null or node_id.strip_edges().is_empty() \
			or enemies.is_empty() or draw_count < 0:
		return _fail(ERR_INVALID_PARAMETER, "Battle start parameters are invalid")
	var key := "%s/%s" % [current_map_id, node_id]
	var battle_index: int = battle_index_by_node.get(key, 0)
	var deck_instances: Array = []
	for index in deck.size():
		deck_instances.append({
			"instance_id": "%s:%s:%d:%d" % [run_id, node_id, battle_index, index],
			"card_id": deck[index],
		})
	var battle := BattleStateMachine.new()
	add_child(battle)
	var error := battle.initialize_battle({
		"map_id": current_map_id,
		"node_id": node_id,
		"battle_index": battle_index,
		"draw_count": draw_count,
		"discard_hand_at_turn_end": discard_hand_at_turn_end,
		"player": {"health": health, "max_health": max_health, "block": 0},
		"enemies": enemies,
		"deck_instances": deck_instances,
	})
	if error != OK:
		battle.queue_free()
		return _fail(error, "Battle initialization failed")
	battle_index_by_node[key] = battle_index + 1
	battles_fought += 1
	current_battle = battle
	_connect_battle(battle)
	_emit_stat(&"battles_fought", battles_fought)
	battle_started.emit(battle)
	return battle.start_battle()


func finish_victory() -> Error:
	return _finish_run("victory", "")


func finish_defeat(death_location: String) -> Error:
	return _finish_run("defeat", death_location)


func finish_abandoned() -> Error:
	return _finish_run("abandoned", current_map_id)


func build_history_record(end_result: Dictionary) -> Dictionary:
	return {
		"run_id": run_id,
		"main_seed": main_seed,
		"result": end_result.get("status", "unknown"),
		"victory": end_result.get("status") == "victory",
		"death_location": end_result.get("death_location", ""),
		"deck": deck.duplicate(),
		"stages_completed": stages_completed,
		"battles_fought": battles_fought,
		"enemies_defeated": defeated_enemy_ids.size(),
		"ended_at": Time.get_datetime_string_from_system(true),
	}


func _prepare_new_config(config: Dictionary, unlocked_cards: Array) -> Dictionary:
	var configured_run_id: Variant = config.get("run_id")
	var configured_max := _integer_value(config.get("max_health"))
	var configured_health := _integer_value(config.get("initial_health"))
	var configured_gold := _integer_value(config.get("initial_gold", 0))
	var catalog: Variant = config.get("card_catalog", [])
	var initial_deck: Variant = config.get("initial_deck", [])
	var configured_items: Variant = config.get("initial_items", [])
	var configured_maps: Variant = config.get("map_ids", [])
	var rewards: Variant = config.get("reward_pool", [])
	var shops: Variant = config.get("shop_pool", [])
	var events: Variant = config.get("event_pool", [])
	if not configured_run_id is String or configured_run_id.strip_edges().is_empty() \
			or configured_max == null or configured_health == null or configured_gold == null \
			or configured_max <= 0 or configured_health <= 0 or configured_health > configured_max \
			or configured_gold < 0 or not _string_array_valid(catalog) \
			or not _string_array_valid(initial_deck) or not configured_items is Array \
			or not _json_safe(configured_items) or not _unique_string_array_valid(configured_maps) \
			or configured_maps.size() != 3 or not _string_array_valid(rewards) \
			or not _string_array_valid(shops) or not _string_array_valid(events) \
			or not _string_array_valid(unlocked_cards):
		_fail(ERR_INVALID_PARAMETER, "New run config is invalid")
		return {}

	var unlocked := {}
	for card_id: String in unlocked_cards:
		unlocked[card_id] = true
	var eligible: Array[String] = []
	for card_id: String in catalog:
		if unlocked.has(card_id):
			eligible.append(card_id)
	for card_id: String in initial_deck:
		if not eligible.has(card_id):
			_fail(ERR_INVALID_PARAMETER, "Initial deck contains a locked/unknown card: " + card_id)
			return {}
	return {
		"run_id": configured_run_id,
		"max_health": configured_max,
		"health": configured_health,
		"gold": configured_gold,
		"deck": initial_deck.duplicate(),
		"card_pool": eligible,
		"items": configured_items.duplicate(true),
		"map_ids": configured_maps.duplicate(),
		"reward_pool": rewards.duplicate(),
		"shop_pool": shops.duplicate(),
		"event_pool": events.duplicate(),
	}


func _seeded_pool(domain: StringName, source: Array) -> Variant:
	var result: Array[String] = []
	result.assign(source)
	if result.size() <= 1:
		return result
	var stream := SeedService.get_stream(domain, [run_id, "pool"])
	if stream == null:
		_fail(SeedService.last_error, "Could not get pool stream: " + String(domain))
		return null
	if stream.shuffle_in_place(result) != OK:
		_fail(stream.last_error, "Could not shuffle pool: " + String(domain))
		return null
	return result


func _connect_battle(battle: BattleStateMachine) -> void:
	battle.battle_ended.connect(_on_battle_ended)


func _on_battle_ended(battle_result: Dictionary) -> void:
	if current_battle == null:
		return
	var ended := current_battle
	var player_state := ended.player
	health = int(player_state.get("health", health))
	for enemy_id: String in battle_result.get("defeated_enemy_ids", []):
		record_enemy_defeated(enemy_id)
	current_battle = null
	_emit_stat(&"health", health)
	battle_finished.emit(battle_result.duplicate(true))
	ended.queue_free()
	if battle_result.get("status") == "defeat" and active:
		finish_defeat(str(battle_result.get("node_id", current_map_id)))


func _finish_run(status: String, death_location: String) -> Error:
	if not active:
		return _fail(ERR_UNCONFIGURED, "Run is not active")
	active = false
	result = {
		"status": status,
		"death_location": death_location,
	}
	state_changed.emit()
	run_ended.emit(result.duplicate(true))
	return OK


func _emit_stat(metric: StringName, value: Variant) -> void:
	stat_updated.emit(metric, value)
	state_changed.emit()


func _count_map_nodes() -> int:
	var total := 0
	for map_id: String in map_states:
		total += map_states[map_id].get("nodes", {}).size()
	return total


func _count_map_plans() -> int:
	var total := 0
	for map_id: String in map_states:
		if map_states[map_id].get("node_plan") is Dictionary:
			total += 1
	return total


static func _integer_value(value: Variant) -> Variant:
	if (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT) \
			or not is_finite(float(value)) or float(value) != floorf(float(value)):
		return null
	return int(value)


static func _integer_equals(value: Variant, expected: int) -> bool:
	var integer := _integer_value(value)
	return integer != null and integer == expected


static func _string_array_valid(values: Variant) -> bool:
	if not values is Array:
		return false
	for value: Variant in values:
		if not value is String or value.strip_edges().is_empty():
			return false
	return true


static func _unique_string_array_valid(values: Variant) -> bool:
	if not _string_array_valid(values):
		return false
	var seen := {}
	for value: String in values:
		if seen.has(value):
			return false
		seen[value] = true
	return true


static func _valid_map_states(values: Dictionary, expected_map_ids: Array) -> bool:
	if values.size() != expected_map_ids.size():
		return false
	for map_id: String in expected_map_ids:
		var raw_state: Variant = values.get(map_id)
		if not raw_state is Dictionary or not raw_state.get("completed") is bool:
			return false
		var raw_nodes: Variant = raw_state.get("nodes")
		if not raw_nodes is Dictionary:
			return false
		for node_id: Variant in raw_nodes:
			if not node_id is String or node_id.strip_edges().is_empty() \
					or not raw_nodes[node_id] is Dictionary or not _json_safe(raw_nodes[node_id]):
				return false
		var raw_plan: Variant = raw_state.get("node_plan")
		if raw_plan != null:
			if not raw_plan is Dictionary:
				return false
			var plan := MapNodePlan.from_dictionary(raw_plan)
			if plan == null or plan.map_id != map_id:
				return false
	return true


static func _valid_nonnegative_int_dictionary(values: Dictionary) -> bool:
	for key: Variant in values:
		if not key is String:
			return false
		var number := _integer_value(values[key])
		if number == null or number < 0:
			return false
	return true


static func _normalized_integer_dictionary(values: Dictionary) -> Dictionary:
	var result := {}
	for key: String in values:
		result[key] = int(values[key])
	return result


static func _json_safe(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for item: Variant in value:
				if not _json_safe(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not key is String or not _json_safe(value[key]):
					return false
			return true
		_:
			return false


func _fail(error: Error, message: String) -> Error:
	last_error = error
	push_error("RunStateMachine: " + message)
	return error

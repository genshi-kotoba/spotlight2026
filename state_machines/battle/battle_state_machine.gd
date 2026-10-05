class_name BattleStateMachine
extends Node

## PRG-004：回合阶段、玩家/怪物状态、牌堆和逐项结算顺序。
## 具体牌效与 Buff 效果由 PRG-007/008 监听请求信号同步执行。

signal battle_started(snapshot: Dictionary)
signal battle_ended(result: Dictionary)
signal phase_changed(previous: int, current: int)
signal turn_started(turn_number: int)
signal card_drawn(card: Dictionary, hand_size: int)
signal card_discarded(card: Dictionary, reason: StringName)
signal discard_pile_shuffled(draw_pile_size: int)
signal card_committed(card: Dictionary, play_index: int)
signal card_effect_requested(card: Dictionary, target: Variant, pointer_index: int)
signal card_resolved(card: Dictionary, pointer_index: int)
signal buff_effect_requested(side: StringName, entity_id: String, buff: Dictionary)
signal buff_resolved(side: StringName, entity_id: String, buff: Dictionary)
signal enemy_action_decided(enemy_id: String, action: Dictionary)
signal enemy_action_requested(enemy_id: String, action: Dictionary)
signal enemy_action_resolved(enemy_id: String, action: Dictionary)
signal combatant_damaged(side: StringName, entity_id: String, damage: int,
		blocked: int, health_after: int)
signal combatant_healed(side: StringName, entity_id: String, amount: int, health_after: int)
signal block_changed(side: StringName, entity_id: String, block: int)
signal buff_added(side: StringName, entity_id: String, buff: Dictionary)
signal resolution_limit_reached(limit: int)

enum Phase {
	IDLE,
	PLAYER_DRAW,
	PLAYER_BUFF,
	PLAYER_ACTION,
	PLAYER_EFFECTS,
	ENEMY_DECIDE,
	ENEMY_BUFF,
	ENEMY_ACTION,
	VICTORY,
	DEFEAT,
}

const SNAPSHOT_VERSION := 1
const MAX_POINTER_RESOLUTIONS := 256

var map_id := ""
var node_id := ""
var battle_index := 0
var draw_count := 0
var discard_hand_at_turn_end := false

var active := false
var phase: int = Phase.IDLE
var turn_number := 0
var player: Dictionary = {}
var enemies: Array[Dictionary] = []
var draw_pile: Array[Dictionary] = []
var discard_pile: Array[Dictionary] = []
var hand: Array[Dictionary] = []
var play_zone: Array[Dictionary] = []

var pointer_index := 0
var pointer_resolutions := 0
var last_error: Error = OK

var _draw_stream: RandomStream
var _logic_stream: RandomStream
var _resolving_card := false
var _next_pointer_override := -1


func initialize_battle(config: Dictionary) -> Error:
	if active:
		return _fail(ERR_ALREADY_IN_USE, "Battle is already initialized")
	var prepared := _prepare_config(config)
	if prepared.is_empty():
		return last_error

	map_id = prepared["map_id"]
	node_id = prepared["node_id"]
	battle_index = prepared["battle_index"]
	draw_count = prepared["draw_count"]
	discard_hand_at_turn_end = prepared["discard_hand_at_turn_end"]
	player = prepared["player"].duplicate(true)
	enemies.clear()
	for enemy: Dictionary in prepared["enemies"]:
		enemies.append(enemy.duplicate(true))
	draw_pile.clear()
	for card: Dictionary in prepared["deck_instances"]:
		draw_pile.append(card.duplicate(true))
	discard_pile.clear()
	hand.clear()
	play_zone.clear()

	_draw_stream = SeedService.get_stream(
		RandomDomains.BATTLE_DRAW, [map_id, node_id, battle_index]
	)
	_logic_stream = SeedService.get_stream(
		RandomDomains.BATTLE_LOGIC, [map_id, node_id, battle_index]
	)
	if _draw_stream == null or _logic_stream == null:
		return _fail(SeedService.last_error, "Could not acquire battle random streams")
	if _draw_stream.shuffle_in_place(draw_pile) != OK:
		return _fail(_draw_stream.last_error, "Could not shuffle the initial draw pile")

	phase = Phase.IDLE
	turn_number = 0
	pointer_index = 0
	pointer_resolutions = 0
	active = true
	last_error = OK
	return OK


func restore_from_dictionary(data: Dictionary) -> Error:
	if active:
		return _fail(ERR_ALREADY_IN_USE, "Battle is already initialized")
	if not _integer_equals(data.get("snapshot_version"), SNAPSHOT_VERSION):
		return _fail(ERR_INVALID_DATA, "Battle snapshot version is invalid")
	var saved_map: Variant = data.get("map_id")
	var saved_node: Variant = data.get("node_id")
	var saved_active: Variant = data.get("active")
	var saved_player: Variant = data.get("player")
	var saved_enemies: Variant = data.get("enemies")
	var saved_draw: Variant = data.get("draw_pile")
	var saved_discard: Variant = data.get("discard_pile")
	var saved_hand: Variant = data.get("hand")
	var saved_play: Variant = data.get("play_zone")
	var saved_discard_rule: Variant = data.get("discard_hand_at_turn_end")
	var saved_index := _integer_value(data.get("battle_index"))
	var saved_draw_count := _integer_value(data.get("draw_count"))
	var saved_phase := _integer_value(data.get("phase"))
	var saved_turn := _integer_value(data.get("turn_number"))
	var saved_pointer := _integer_value(data.get("pointer_index"))
	var saved_resolutions := _integer_value(data.get("pointer_resolutions"))
	if not saved_map is String or saved_map.strip_edges().is_empty() \
			or not saved_node is String or saved_node.strip_edges().is_empty() \
			or not saved_active is bool or not saved_player is Dictionary \
			or not saved_enemies is Array or not saved_draw is Array \
			or not saved_discard is Array or not saved_hand is Array or not saved_play is Array \
			or not saved_discard_rule is bool or saved_index == null or saved_index < 0 \
			or saved_draw_count == null or saved_draw_count < 0 or saved_phase == null \
			or saved_phase < Phase.IDLE or saved_phase > Phase.DEFEAT \
			or saved_turn == null or saved_turn < 0 or saved_pointer == null \
			or saved_pointer < 0 or saved_resolutions == null or saved_resolutions < 0 \
			or not _valid_player(saved_player) or not _valid_enemy_array(saved_enemies) \
			or not _valid_card_array(saved_draw) or not _valid_card_array(saved_discard) \
			or not _valid_card_array(saved_hand) or not _valid_card_array(saved_play) \
			or not _card_zones_are_disjoint([saved_draw, saved_discard, saved_hand, saved_play]):
		return _fail(ERR_INVALID_DATA, "Battle snapshot fields are invalid")
	# 同步结算阶段不会成为合法存档边界；否则恢复后无法知道信号执行到哪一步。
	if not [Phase.IDLE, Phase.PLAYER_ACTION, Phase.VICTORY, Phase.DEFEAT].has(saved_phase):
		return _fail(ERR_INVALID_DATA, "Battle snapshot was captured mid-resolution")
	if saved_active != [Phase.IDLE, Phase.PLAYER_ACTION].has(saved_phase) \
			or saved_pointer > saved_play.size() \
			or saved_resolutions > MAX_POINTER_RESOLUTIONS:
		return _fail(ERR_INVALID_DATA, "Battle snapshot lifecycle/pointer state is inconsistent")

	map_id = saved_map
	node_id = saved_node
	battle_index = saved_index
	draw_count = saved_draw_count
	discard_hand_at_turn_end = saved_discard_rule
	active = saved_active
	phase = saved_phase
	turn_number = saved_turn
	pointer_index = saved_pointer
	pointer_resolutions = saved_resolutions
	player = saved_player.duplicate(true)
	enemies = _copy_dictionary_array(saved_enemies)
	draw_pile = _copy_dictionary_array(saved_draw)
	discard_pile = _copy_dictionary_array(saved_discard)
	hand = _copy_dictionary_array(saved_hand)
	play_zone = _copy_dictionary_array(saved_play)
	_draw_stream = SeedService.get_stream(
		RandomDomains.BATTLE_DRAW, [map_id, node_id, battle_index]
	)
	_logic_stream = SeedService.get_stream(
		RandomDomains.BATTLE_LOGIC, [map_id, node_id, battle_index]
	)
	if _draw_stream == null or _logic_stream == null:
		return _fail(SeedService.last_error, "Could not reacquire restored battle streams")
	last_error = OK
	return OK


func to_dictionary() -> Dictionary:
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"map_id": map_id,
		"node_id": node_id,
		"battle_index": battle_index,
		"draw_count": draw_count,
		"discard_hand_at_turn_end": discard_hand_at_turn_end,
		"active": active,
		"phase": phase,
		"turn_number": turn_number,
		"player": player.duplicate(true),
		"enemies": enemies.duplicate(true),
		"draw_pile": draw_pile.duplicate(true),
		"discard_pile": discard_pile.duplicate(true),
		"hand": hand.duplicate(true),
		"play_zone": play_zone.duplicate(true),
		"pointer_index": pointer_index,
		"pointer_resolutions": pointer_resolutions,
	}


func start_battle() -> Error:
	if not active or phase != Phase.IDLE:
		return _fail(ERR_UNCONFIGURED, "Battle cannot start from the current phase")
	battle_started.emit(to_dictionary())
	# 配置或恢复数据允许生命为 0；先判定终局，不能让已死亡的一方进入首回合。
	if _finish_if_needed():
		return OK
	return _start_player_turn()


## 玩家确认排列后，从左到右逐张同步结算。targets 以 card instance_id 为 key。
func commit_player_sequence(instance_ids: Array[String], targets: Dictionary = {}) -> Error:
	if not active or phase != Phase.PLAYER_ACTION or instance_ids.is_empty():
		return _fail(ERR_INVALID_PARAMETER, "A nonempty sequence is required in PLAYER_ACTION")
	var seen := {}
	for instance_id: String in instance_ids:
		if instance_id.strip_edges().is_empty() or seen.has(instance_id) \
				or _find_card_index(hand, instance_id) < 0:
			return _fail(ERR_INVALID_PARAMETER, "Sequence contains a duplicate/unknown card")
		seen[instance_id] = true

	play_zone.clear()
	for instance_id: String in instance_ids:
		var hand_index := _find_card_index(hand, instance_id)
		var card: Dictionary = hand[hand_index]
		hand.remove_at(hand_index)
		play_zone.append(card)
		card_committed.emit(card.duplicate(true), play_zone.size() - 1)

	_set_phase(Phase.PLAYER_EFFECTS)
	pointer_index = 0
	pointer_resolutions = 0
	while active and pointer_index < play_zone.size():
		if pointer_resolutions >= MAX_POINTER_RESOLUTIONS:
			resolution_limit_reached.emit(MAX_POINTER_RESOLUTIONS)
			return _fail(ERR_CYCLIC_LINK, "Card pointer resolution limit reached")
		var card: Dictionary = play_zone[pointer_index]
		var resolved_at := pointer_index
		var target: Variant = targets.get(card["instance_id"])
		_next_pointer_override = -1
		_resolving_card = true
		card_effect_requested.emit(card.duplicate(true), _copy_json_value(target), resolved_at)
		_resolving_card = false
		pointer_resolutions += 1
		card_resolved.emit(card.duplicate(true), resolved_at)
		if _finish_if_needed():
			return OK
		pointer_index = _next_pointer_override if _next_pointer_override >= 0 else resolved_at + 1

	while not play_zone.is_empty():
		_discard_play_card(0, &"resolved")
	return _begin_enemy_turn()


## 没有编排卡牌时结束玩家行动，不虚构“必须出牌”的规则。
func end_player_action() -> Error:
	if not active or phase != Phase.PLAYER_ACTION:
		return _fail(ERR_INVALID_PARAMETER, "Player action can only end in PLAYER_ACTION")
	return _begin_enemy_turn()


## 由正在同步执行的卡牌效果请求下一次回到前方第 N 格。
func request_pointer_rewind(steps: int) -> Error:
	if not _resolving_card or phase != Phase.PLAYER_EFFECTS or steps <= 0:
		return _fail(ERR_INVALID_PARAMETER, "Pointer rewind is only valid during a card effect")
	_next_pointer_override = maxi(0, pointer_index - steps)
	return OK


func apply_damage_to_player(amount: int) -> Error:
	if not active or amount < 0:
		return _fail(ERR_INVALID_PARAMETER, "Damage must be nonnegative")
	var blocked := mini(int(player["block"]), amount)
	player["block"] = int(player["block"]) - blocked
	player["health"] = maxi(0, int(player["health"]) - (amount - blocked))
	block_changed.emit(&"player", "player", player["block"])
	combatant_damaged.emit(&"player", "player", amount, blocked, player["health"])
	return OK


func apply_damage_to_enemy(enemy_id: String, amount: int) -> Error:
	var index := _find_enemy_index(enemy_id)
	if not active or amount < 0 or index < 0:
		return _fail(ERR_INVALID_PARAMETER, "Enemy damage target/amount is invalid")
	var enemy: Dictionary = enemies[index]
	var blocked := mini(int(enemy["block"]), amount)
	enemy["block"] = int(enemy["block"]) - blocked
	enemy["health"] = maxi(0, int(enemy["health"]) - (amount - blocked))
	enemies[index] = enemy
	block_changed.emit(&"enemy", enemy_id, enemy["block"])
	combatant_damaged.emit(&"enemy", enemy_id, amount, blocked, enemy["health"])
	return OK


func heal_player(amount: int) -> Error:
	if not active or amount < 0:
		return _fail(ERR_INVALID_PARAMETER, "Heal must be nonnegative")
	var before := int(player["health"])
	player["health"] = mini(int(player["max_health"]), before + amount)
	combatant_healed.emit(&"player", "player", int(player["health"]) - before, player["health"])
	return OK


func add_block(side: StringName, entity_id: String, amount: int) -> Error:
	if not active or amount < 0:
		return _fail(ERR_INVALID_PARAMETER, "Block must be nonnegative")
	if side == &"player" and entity_id == "player":
		player["block"] = int(player["block"]) + amount
		block_changed.emit(side, entity_id, player["block"])
		return OK
	if side == &"enemy":
		var index := _find_enemy_index(entity_id)
		if index >= 0:
			var enemy: Dictionary = enemies[index]
			enemy["block"] = int(enemy["block"]) + amount
			enemies[index] = enemy
			block_changed.emit(side, entity_id, enemy["block"])
			return OK
	return _fail(ERR_INVALID_PARAMETER, "Block target is invalid")


func add_buff(side: StringName, entity_id: String, buff: Dictionary) -> Error:
	if not active or not _valid_buff(buff):
		return _fail(ERR_INVALID_PARAMETER, "Buff data is invalid")
	if side == &"player" and entity_id == "player":
		var buffs: Array = player["buffs"]
		buffs.append(buff.duplicate(true))
		player["buffs"] = buffs
		buff_added.emit(side, entity_id, buff.duplicate(true))
		return OK
	if side == &"enemy":
		var index := _find_enemy_index(entity_id)
		if index >= 0:
			var enemy: Dictionary = enemies[index]
			var buffs: Array = enemy["buffs"]
			buffs.append(buff.duplicate(true))
			enemy["buffs"] = buffs
			enemies[index] = enemy
			buff_added.emit(side, entity_id, buff.duplicate(true))
			return OK
	return _fail(ERR_INVALID_PARAMETER, "Buff target is invalid")


func discard_from_hand(instance_id: String, reason: StringName = &"effect") -> Error:
	if not active:
		return _fail(ERR_UNCONFIGURED, "Battle is not active")
	var index := _find_card_index(hand, instance_id)
	if index < 0:
		return _fail(ERR_INVALID_PARAMETER, "Card is not in hand")
	var card: Dictionary = hand[index]
	hand.remove_at(index)
	discard_pile.append(card)
	card_discarded.emit(card.duplicate(true), reason)
	return OK


func _start_player_turn() -> Error:
	if not active:
		return ERR_UNCONFIGURED
	turn_number += 1
	_set_phase(Phase.PLAYER_DRAW)
	for _index in draw_count:
		var error := _draw_one()
		if error == ERR_DOES_NOT_EXIST:
			break
		if error != OK:
			return error
	_set_phase(Phase.PLAYER_BUFF)
	_settle_buffs(&"player", "player", player["buffs"])
	if _finish_if_needed():
		return OK
	_set_phase(Phase.PLAYER_ACTION)
	turn_started.emit(turn_number)
	return OK


func _begin_enemy_turn() -> Error:
	if not active:
		return ERR_UNCONFIGURED
	_set_phase(Phase.ENEMY_DECIDE)
	var planned: Array[Dictionary] = []
	for enemy: Dictionary in enemies:
		if int(enemy["health"]) <= 0:
			continue
		var picked: Variant = _logic_stream.pick(enemy["actions"])
		if picked == null or not picked is Dictionary:
			return _fail(_logic_stream.last_error, "Could not choose an enemy action")
		var action: Dictionary = picked.duplicate(true)
		planned.append({"enemy_id": enemy["enemy_id"], "action": action})
		enemy_action_decided.emit(enemy["enemy_id"], action.duplicate(true))

	_set_phase(Phase.ENEMY_BUFF)
	for enemy: Dictionary in enemies:
		if int(enemy["health"]) > 0:
			_settle_buffs(&"enemy", enemy["enemy_id"], enemy["buffs"])
	if _finish_if_needed():
		return OK

	_set_phase(Phase.ENEMY_ACTION)
	for planned_action: Dictionary in planned:
		if _enemy_is_alive(planned_action["enemy_id"]):
			enemy_action_requested.emit(
				planned_action["enemy_id"], planned_action["action"].duplicate(true)
			)
			enemy_action_resolved.emit(
				planned_action["enemy_id"], planned_action["action"].duplicate(true)
			)
			if _finish_if_needed():
				return OK

	if discard_hand_at_turn_end:
		while not hand.is_empty():
			var card: Dictionary = hand.pop_back()
			discard_pile.append(card)
			card_discarded.emit(card.duplicate(true), &"turn_end")
	return _start_player_turn()


func _draw_one() -> Error:
	if draw_pile.is_empty():
		if discard_pile.is_empty():
			return ERR_DOES_NOT_EXIST
		draw_pile = discard_pile
		discard_pile = []
		if _draw_stream.shuffle_in_place(draw_pile) != OK:
			return _fail(_draw_stream.last_error, "Could not reshuffle discard pile")
		discard_pile_shuffled.emit(draw_pile.size())
	var card: Dictionary = draw_pile.pop_back()
	hand.append(card)
	card_drawn.emit(card.duplicate(true), hand.size())
	return OK


func _discard_play_card(index: int, reason: StringName) -> void:
	var card: Dictionary = play_zone[index]
	play_zone.remove_at(index)
	discard_pile.append(card)
	card_discarded.emit(card.duplicate(true), reason)


func _settle_buffs(side: StringName, entity_id: String, buffs: Array) -> void:
	# 使用快照遍历：效果可以同步增删原容器，但不会插队进本轮结算。
	for raw: Variant in buffs.duplicate(true):
		if not raw is Dictionary:
			continue
		var buff: Dictionary = raw
		buff_effect_requested.emit(side, entity_id, buff.duplicate(true))
		buff_resolved.emit(side, entity_id, buff.duplicate(true))


func _finish_if_needed() -> bool:
	if not active:
		return true
	if int(player["health"]) <= 0:
		_finish_battle("defeat")
		return true
	var living := 0
	for enemy: Dictionary in enemies:
		if int(enemy["health"]) > 0:
			living += 1
	if living == 0:
		_finish_battle("victory")
		return true
	return false


func _finish_battle(status: String) -> void:
	active = false
	_set_phase(Phase.VICTORY if status == "victory" else Phase.DEFEAT)
	var defeated: Array[String] = []
	for enemy: Dictionary in enemies:
		if int(enemy["health"]) <= 0:
			defeated.append(enemy["enemy_id"])
	battle_ended.emit({
		"status": status,
		"map_id": map_id,
		"node_id": node_id,
		"battle_index": battle_index,
		"turns": turn_number,
		"defeated_enemy_ids": defeated,
	})


func _set_phase(next: int) -> void:
	var previous := phase
	phase = next
	phase_changed.emit(previous, phase)


func _prepare_config(config: Dictionary) -> Dictionary:
	var configured_map: Variant = config.get("map_id")
	var configured_node: Variant = config.get("node_id")
	var configured_index := _integer_value(config.get("battle_index"))
	var configured_draw := _integer_value(config.get("draw_count"))
	var configured_discard: Variant = config.get("discard_hand_at_turn_end", false)
	var configured_player: Variant = config.get("player")
	var configured_enemies: Variant = config.get("enemies")
	var configured_deck: Variant = config.get("deck_instances")
	if not configured_map is String or configured_map.strip_edges().is_empty() \
			or not configured_node is String or configured_node.strip_edges().is_empty() \
			or configured_index == null or configured_index < 0 \
			or configured_draw == null or configured_draw < 0 \
			or not configured_discard is bool or not configured_player is Dictionary \
			or not configured_enemies is Array or configured_enemies.is_empty() \
			or not configured_deck is Array or not _valid_player(configured_player) \
			or not _valid_enemy_array(configured_enemies) \
			or not _valid_card_array(configured_deck):
		_fail(ERR_INVALID_PARAMETER, "Battle config is invalid")
		return {}
	return {
		"map_id": configured_map,
		"node_id": configured_node,
		"battle_index": configured_index,
		"draw_count": configured_draw,
		"discard_hand_at_turn_end": configured_discard,
		"player": _normalize_player(configured_player),
		"enemies": _normalize_enemies(configured_enemies),
		"deck_instances": _copy_dictionary_array(configured_deck),
	}


static func _valid_player(value: Dictionary) -> bool:
	var health := _integer_value(value.get("health"))
	var maximum := _integer_value(value.get("max_health"))
	var block := _integer_value(value.get("block", 0))
	var buffs: Variant = value.get("buffs", [])
	return health != null and maximum != null and block != null and maximum > 0 \
		and health >= 0 and health <= maximum and block >= 0 and buffs is Array \
		and _valid_buff_array(buffs)


static func _valid_enemy_array(values: Array) -> bool:
	var ids := {}
	for value: Variant in values:
		if not value is Dictionary or not value.get("enemy_id") is String \
				or value["enemy_id"].strip_edges().is_empty() or ids.has(value["enemy_id"]) \
				or not _valid_player(value) or not value.get("actions") is Array \
				or value["actions"].is_empty() or not _json_safe(value["actions"]):
			return false
		for action: Variant in value["actions"]:
			if not action is Dictionary:
				return false
		ids[value["enemy_id"]] = true
	return true


static func _valid_card_array(values: Array) -> bool:
	var ids := {}
	for value: Variant in values:
		if not value is Dictionary or not value.get("instance_id") is String \
				or value["instance_id"].strip_edges().is_empty() \
				or not value.get("card_id") is String or value["card_id"].strip_edges().is_empty() \
				or ids.has(value["instance_id"]) or not _json_safe(value):
			return false
		ids[value["instance_id"]] = true
	return true


static func _card_zones_are_disjoint(zones: Array) -> bool:
	var ids := {}
	for zone: Variant in zones:
		if not zone is Array:
			return false
		for card: Variant in zone:
			if not card is Dictionary:
				return false
			var instance_id: Variant = card.get("instance_id")
			if not instance_id is String or ids.has(instance_id):
				return false
			ids[instance_id] = true
	return true


static func _valid_buff_array(values: Array) -> bool:
	for value: Variant in values:
		if not value is Dictionary or not _valid_buff(value):
			return false
	return true


static func _valid_buff(buff: Dictionary) -> bool:
	var layers := _integer_value(buff.get("layers"))
	var duration := _integer_value(buff.get("duration"))
	return buff.get("buff_id") is String and not buff["buff_id"].strip_edges().is_empty() \
		and layers != null and layers >= 0 and duration != null and duration >= 0 \
		and _json_safe(buff)


static func _normalize_player(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result["health"] = int(value["health"])
	result["max_health"] = int(value["max_health"])
	result["block"] = int(value.get("block", 0))
	result["buffs"] = value.get("buffs", []).duplicate(true)
	return result


static func _normalize_enemies(values: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Dictionary in values:
		var enemy := _normalize_player(value)
		enemy["enemy_id"] = value["enemy_id"]
		enemy["actions"] = value["actions"].duplicate(true)
		result.append(enemy)
	return result


static func _copy_dictionary_array(values: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Dictionary in values:
		result.append(value.duplicate(true))
	return result


func _find_card_index(cards: Array[Dictionary], instance_id: String) -> int:
	for index in cards.size():
		if cards[index].get("instance_id") == instance_id:
			return index
	return -1


func _find_enemy_index(enemy_id: String) -> int:
	for index in enemies.size():
		if enemies[index].get("enemy_id") == enemy_id:
			return index
	return -1


func _enemy_is_alive(enemy_id: String) -> bool:
	var index := _find_enemy_index(enemy_id)
	return index >= 0 and int(enemies[index]["health"]) > 0


static func _integer_value(value: Variant) -> Variant:
	if (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT) \
			or not is_finite(float(value)) or float(value) != floorf(float(value)):
		return null
	return int(value)


static func _integer_equals(value: Variant, expected: int) -> bool:
	var integer := _integer_value(value)
	return integer != null and integer == expected


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


static func _copy_json_value(value: Variant) -> Variant:
	return value.duplicate(true) if value is Array or value is Dictionary else value


func _fail(error: Error, message: String) -> Error:
	last_error = error
	push_error("BattleStateMachine: " + message)
	return error

class_name BattleStateMachine
extends Node

## PRG-004：回合阶段、玩家/怪物状态、牌堆和逐项结算顺序。
## 流程通过事件队列推进；系统层注册效果、Buff、典籍规则，信号只供 UI/兼容接口观察。

signal battle_started(snapshot: Dictionary)
signal battle_ended(result: Dictionary)
signal phase_changed(previous: int, current: int)
signal turn_started(turn_number: int)
## 存在类残片在抽牌之前生效，保证首回合与后续回合采用同一顺序。
signal player_turn_started(turn_number: int)
signal card_drawn(card: Dictionary, hand_size: int)
signal card_discarded(card: Dictionary, reason: StringName)
signal discard_pile_shuffled(draw_pile_size: int)
signal card_committed(card: Dictionary, play_index: int)
signal card_effect_requested(card: Dictionary, target: Variant, pointer_index: int)
signal card_resolved(card: Dictionary, pointer_index: int)
signal discard_choice_requested(card: Dictionary, count: int, candidates: Array[Dictionary])
signal discard_choice_completed(discarded_instance_ids: Array[String])
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
var rules := BattleRuleEngine.new()

var _draw_stream: RandomStream
var _discard_stream: RandomStream
var _logic_stream: RandomStream
var _resolving_card := false
var _next_pointer_override := -1
var _resolution_targets: Dictionary = {}
var _repeat_remaining_by_card: Dictionary = {}
var _pointer_move_sources: Dictionary = {}
var _repeat_request_sources: Dictionary = {}
var _pending_discard_count := 0
var _pending_card: Dictionary = {}
var _pending_resolved_at := -1


func _init() -> void:
	var flows := {
		"flow.sequence.next": _step_sequence,
		"flow.sequence.finish": _step_sequence_finish,
		"flow.turn.start": _step_turn_start,
		"flow.turn.draw": _step_turn_draw,
		"flow.turn.action": _step_turn_action,
		"flow.draw.one": _step_draw,
		"flow.enemy.begin": _step_enemy_begin,
		"flow.enemy.plan": _step_enemy_plan,
		"flow.enemy.act": _step_enemy_action,
		"flow.enemy.buffs": _step_enemy_buffs,
		"flow.enemy.end": _step_enemy_end,
		"flow.buff.resolved": _step_buff_resolved,
		"flow.enemy.resolved": _step_enemy_resolved,
		"flow.outcome": _step_outcome,
	}
	for type: String in flows:
		rules.register_rule(type, type, flows[type], 100, _can_process_flow)


func _can_process_flow(_event: BattleEvent) -> bool:
	return active


func _publish_fact(type: String, data: Dictionary) -> void:
	var current := rules.queue.current
	var is_root: bool = current == null or current.metadata.get("relic_ancestry", []).is_empty()
	rules.publish(type, data, {}, is_root)
	rules.flush()


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
	_discard_stream = SeedService.get_stream(
		RandomDomains.BATTLE_DISCARD, [map_id, node_id, battle_index]
	)
	_logic_stream = SeedService.get_stream(
		RandomDomains.BATTLE_LOGIC, [map_id, node_id, battle_index]
	)
	if _draw_stream == null or _discard_stream == null or _logic_stream == null:
		return _fail(SeedService.last_error, "Could not acquire battle random streams")
	if _draw_stream.shuffle_in_place(draw_pile) != OK:
		return _fail(_draw_stream.last_error, "Could not shuffle the initial draw pile")

	phase = Phase.IDLE
	turn_number = 0
	pointer_index = 0
	pointer_resolutions = 0
	_clear_resolution_runtime()
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
	var saved_index: Variant = _integer_value(data.get("battle_index"))
	var saved_draw_count: Variant = _integer_value(data.get("draw_count"))
	var saved_phase: Variant = _integer_value(data.get("phase"))
	var saved_turn: Variant = _integer_value(data.get("turn_number"))
	var saved_pointer: Variant = _integer_value(data.get("pointer_index"))
	var saved_resolutions: Variant = _integer_value(data.get("pointer_resolutions"))
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
	# 队列结算中途不是合法存档边界；当前未序列化待执行事件和交互续接点。
	if not [Phase.IDLE, Phase.PLAYER_ACTION, Phase.VICTORY, Phase.DEFEAT].has(saved_phase):
		return _fail(ERR_INVALID_DATA, "Battle snapshot was captured mid-resolution")
	if not bool(data.get("queue_idle", true)):
		return _fail(ERR_INVALID_DATA, "Battle snapshot contains pending queue events")
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
	_discard_stream = SeedService.get_stream(
		RandomDomains.BATTLE_DISCARD, [map_id, node_id, battle_index]
	)
	_logic_stream = SeedService.get_stream(
		RandomDomains.BATTLE_LOGIC, [map_id, node_id, battle_index]
	)
	if _draw_stream == null or _discard_stream == null or _logic_stream == null:
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
		"queue_idle": not rules.queue.paused and rules.queue.pending_count() == 0 \
			and (not rules.queue.processing or not active),
	}


func start_battle() -> Error:
	if not active or phase != Phase.IDLE:
		return _fail(ERR_UNCONFIGURED, "Battle cannot start from the current phase")
	battle_started.emit(to_dictionary())
	# 配置或恢复数据允许生命为 0；先判定终局，不能让已死亡的一方进入首回合。
	if _finish_if_needed():
		return OK
	return _start_player_turn()


## 玩家确认排列后，从左到右逐张结算。targets 以 card instance_id 为 key。
##
## 队列在本调用内推进到空闲或输入暂停。选择弃牌会停在
## PLAYER_EFFECTS，界面调用 submit_discard_choice() 后从同一指针继续。
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
	_clear_resolution_runtime()
	_resolution_targets = targets.duplicate(true)
	return _continue_player_resolution()


func _continue_player_resolution() -> Error:
	return rules.submit("flow.sequence.next")


func _step_sequence(_event: BattleEvent) -> void:
	if pointer_index >= play_zone.size():
		while not play_zone.is_empty():
			_discard_play_card(0, &"resolved")
		_resolution_targets.clear()
		_begin_enemy_turn()
		return
	if pointer_resolutions >= MAX_POINTER_RESOLUTIONS:
		resolution_limit_reached.emit(MAX_POINTER_RESOLUTIONS)
		rules.queue.clear()
		rules.last_error = _fail(ERR_CYCLIC_LINK, "Card pointer resolution limit reached")
		return
	var card: Dictionary = play_zone[pointer_index].duplicate(true)
	var target: Variant = _resolution_targets.get(card.instance_id)
	_next_pointer_override = -1
	_resolving_card = true
	_pending_card = card
	_pending_resolved_at = pointer_index
	card_effect_requested.emit(card.duplicate(true), _copy_json_value(target), pointer_index)
	rules.publish("card.effect_requested", {"card": card, "target": target}, {"source_card": card.instance_id})
	rules.publish("flow.sequence.finish", {"card": card, "index": pointer_index})


func _step_sequence_finish(event: BattleEvent) -> void:
	_resolving_card = false
	_pending_card.clear()
	_pending_resolved_at = -1
	var card: Dictionary = event.payload.card
	var error := _finish_resolved_card(card, int(event.payload.index), String(card.instance_id), _next_pointer_override)
	if error != OK:
		rules.last_error = error
	elif active:
		rules.publish("flow.sequence.next")


func _finish_resolved_card(card: Dictionary, resolved_at: int,
		card_instance_id: String, pointer_override: int) -> Error:
	pointer_resolutions += 1
	card_resolved.emit(card.duplicate(true), resolved_at)
	if _finish_if_needed():
		return OK

	var repeat_count := int(_repeat_remaining_by_card.get(card_instance_id, 0))
	if repeat_count > 0 and _find_card_index(play_zone, card_instance_id) >= 0:
		if repeat_count == 1:
			_repeat_remaining_by_card.erase(card_instance_id)
		else:
			_repeat_remaining_by_card[card_instance_id] = repeat_count - 1
		pointer_index = _find_card_index(play_zone, card_instance_id)
		return OK
	_repeat_remaining_by_card.erase(card_instance_id)

	if pointer_override >= 0:
		pointer_index = pointer_override
	else:
		# “使用后移除”会让右侧卡牌左移，下一张仍在原索引。
		pointer_index = resolved_at + 1 \
			if _find_card_index(play_zone, card_instance_id) >= 0 else resolved_at
	return OK


## 交互式弃牌的唯一继续入口。必须一次提交界面请求的准确数量。
func submit_discard_choice(instance_ids: Array[String]) -> Error:
	if not active or phase != Phase.PLAYER_EFFECTS or _pending_discard_count <= 0:
		return _fail(ERR_INVALID_PARAMETER, "No discard choice is pending")
	if instance_ids.size() != _pending_discard_count:
		return _fail(ERR_INVALID_PARAMETER, "Discard choice count does not match request")
	var seen := {}
	for instance_id: String in instance_ids:
		if instance_id.strip_edges().is_empty() or seen.has(instance_id) \
				or _find_card_index(hand, instance_id) < 0:
			return _fail(ERR_INVALID_PARAMETER, "Discard choice contains duplicate/unknown card")
		seen[instance_id] = true

	for instance_id: String in instance_ids:
		var error := discard_from_hand(instance_id, &"chosen")
		if error != OK:
			return error
	var submitted: Array[String] = instance_ids.duplicate()
	_pending_discard_count = 0
	discard_choice_completed.emit(submitted)

	rules.queue.resume()
	return rules.flush()


func has_pending_discard_choice() -> bool:
	return _pending_discard_count > 0


func pending_discard_count() -> int:
	return _pending_discard_count
## 没有编排卡牌时结束玩家行动，不虚构“必须出牌”的规则。
func end_player_action() -> Error:
	if not active or phase != Phase.PLAYER_ACTION:
		return _fail(ERR_INVALID_PARAMETER, "Player action can only end in PLAYER_ACTION")
	return _begin_enemy_turn()


## 由当前卡牌的队列动作请求下一次回到前方第 N 格。
func request_pointer_rewind(steps: int) -> Error:
	if not _resolving_card or phase != Phase.PLAYER_EFFECTS or steps <= 0:
		return _fail(ERR_INVALID_PARAMETER, "Pointer rewind is only valid during a card effect")
	var target_index := maxi(0, pointer_index - steps)
	if target_index == pointer_index:
		return ERR_INVALID_PARAMETER
	var source_id := String(play_zone[pointer_index].get("instance_id", ""))
	if _pointer_move_sources.has(source_id):
		return ERR_ALREADY_IN_USE
	_pointer_move_sources[source_id] = true
	_next_pointer_override = target_index
	return OK


## 指针跳到指定索引；等于 play_zone.size() 表示直接结束本轮牌区结算。
func request_pointer_move_to(index: int) -> Error:
	if not _resolving_card or phase != Phase.PLAYER_EFFECTS \
			or index < 0 or index > play_zone.size() or index == pointer_index:
		return _fail(ERR_INVALID_PARAMETER, "Pointer target is invalid")
	var source_id := String(play_zone[pointer_index].get("instance_id", ""))
	if _pointer_move_sources.has(source_id):
		return ERR_ALREADY_IN_USE
	_pointer_move_sources[source_id] = true
	_next_pointer_override = index
	return OK


## 令当前牌之后的一张牌额外触发 extra_triggers 次。
func request_repeat_next_card(extra_triggers: int) -> Error:
	if not _resolving_card or phase != Phase.PLAYER_EFFECTS or extra_triggers <= 0:
		return _fail(ERR_INVALID_PARAMETER, "Repeat-next request is invalid")
	var next_index := pointer_index + 1
	if next_index >= play_zone.size():
		return ERR_DOES_NOT_EXIST
	var source_id := String(play_zone[pointer_index].get("instance_id", ""))
	if _repeat_request_sources.has(source_id):
		return ERR_ALREADY_IN_USE
	_repeat_request_sources[source_id] = true
	var next_id := String(play_zone[next_index].get("instance_id", ""))
	_repeat_remaining_by_card[next_id] = \
		int(_repeat_remaining_by_card.get(next_id, 0)) + extra_triggers
	return OK


## 效果层请求玩家从当前手牌中选择 count 张弃置。
func request_discard_choice(count: int) -> Error:
	if not _resolving_card or phase != Phase.PLAYER_EFFECTS or count <= 0 \
			or _pending_discard_count > 0:
		return _fail(ERR_INVALID_PARAMETER, "Discard choice request is invalid")
	_pending_discard_count = mini(count, hand.size())
	if _pending_discard_count > 0:
		rules.queue.pause()
		discard_choice_requested.emit(_pending_card.duplicate(true), _pending_discard_count, hand.duplicate(true))
	return OK


func apply_damage_to_player(amount: int, ignore_block: bool = false) -> Error:
	if not active or amount < 0:
		return _fail(ERR_INVALID_PARAMETER, "Damage must be nonnegative")
	var blocked := 0 if ignore_block else mini(int(player["block"]), amount)
	var before := int(player["health"])
	player["block"] = int(player["block"]) - blocked
	player["health"] = maxi(0, int(player["health"]) - (amount - blocked))
	block_changed.emit(&"player", "player", player["block"])
	combatant_damaged.emit(&"player", "player", amount, blocked, player["health"])
	_publish_fact("combatant.damaged", {"side": "player", "entity_id": "player", "damage": amount,
		"blocked": blocked, "health_after": player["health"], "health_loss": before - int(player["health"])})
	rules.submit("flow.outcome")
	return OK


func apply_damage_to_enemy(enemy_id: String, amount: int, ignore_block: bool = false) -> Error:
	var index := _find_enemy_index(enemy_id)
	if not active or amount < 0 or index < 0:
		return _fail(ERR_INVALID_PARAMETER, "Enemy damage target/amount is invalid")
	var enemy: Dictionary = enemies[index]
	var before := int(enemy["health"])
	var blocked := 0 if ignore_block else mini(int(enemy["block"]), amount)
	enemy["block"] = int(enemy["block"]) - blocked
	enemy["health"] = maxi(0, int(enemy["health"]) - (amount - blocked))
	enemies[index] = enemy
	block_changed.emit(&"enemy", enemy_id, enemy["block"])
	combatant_damaged.emit(&"enemy", enemy_id, amount, blocked, enemy["health"])
	_publish_fact("combatant.damaged", {"side": "enemy", "entity_id": enemy_id, "damage": amount,
		"blocked": blocked, "health_after": enemy["health"], "health_loss": before - int(enemy["health"])})
	rules.submit("flow.outcome")
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


## 效果层可在玩家行动或逐张结算期间抽牌；沿用 battle.draw 流。
func draw_cards(count: int) -> Error:
	if not active or not [Phase.PLAYER_ACTION, Phase.PLAYER_EFFECTS].has(phase) or count < 0:
		return _fail(ERR_INVALID_PARAMETER, "Cards cannot be drawn in this phase")
	return rules.submit("flow.draw.one", {"remaining": count})


func _step_draw(event: BattleEvent) -> void:
	var remaining := int(event.payload.remaining)
	if remaining <= 0:
		return
	var error := _draw_one()
	if error == ERR_DOES_NOT_EXIST:
		return
	if error != OK:
		rules.last_error = error
		return
	rules.publish("flow.outcome")
	if remaining > 1:
		rules.publish("flow.draw.one", {"remaining": remaining - 1})


## 随机弃牌使用独立流，避免改变抽牌堆的既有随机序列。
func discard_random_cards(count: int) -> Error:
	if not active or not [Phase.PLAYER_ACTION, Phase.PLAYER_EFFECTS].has(phase) or count < 0:
		return _fail(ERR_INVALID_PARAMETER, "Cards cannot be discarded in this phase")
	for _index in mini(count, hand.size()):
		var chosen: Variant = _discard_stream.int_range(0, hand.size())
		if chosen == null:
			return _fail(_discard_stream.last_error, "Could not choose a card to discard")
		var card: Dictionary = hand[int(chosen)]
		var error := discard_from_hand(card["instance_id"], &"random")
		if error != OK:
			return error
	return OK


func remove_card_from_battle(instance_id: String) -> Error:
	if not active or instance_id.strip_edges().is_empty():
		return _fail(ERR_INVALID_PARAMETER, "Card instance id is invalid")
	for zone: Array in [draw_pile, discard_pile, hand, play_zone]:
		var index := _find_card_index(zone, instance_id)
		if index >= 0:
			zone.remove_at(index)
			return OK
	return _fail(ERR_DOES_NOT_EXIST, "Card instance is not in this battle")


## Buff 按稳定 ID 合并；0 层不保留在结算队列里。
func change_buff_layers(side: StringName, entity_id: String, buff_id: String,
		delta: int, duration: int = 0) -> Error:
	var owner: Dictionary = _combatant(side, entity_id)
	if not active or owner.is_empty() or buff_id.strip_edges().is_empty() or duration < 0:
		return _fail(ERR_INVALID_PARAMETER, "Buff target or data is invalid")
	var buffs: Array = owner["buffs"]
	for index in buffs.size():
		var existing: Dictionary = buffs[index]
		if existing.get("buff_id") == buff_id:
			var layers := maxi(0, int(existing["layers"]) + delta)
			if layers == 0:
				buffs.remove_at(index)
			else:
				existing["layers"] = layers
				existing["duration"] = maxi(int(existing["duration"]), duration)
				buffs[index] = existing
			owner["buffs"] = buffs
			return OK
	if delta > 0:
		return add_buff(side, entity_id, {
			"buff_id": buff_id, "layers": delta, "duration": duration,
		})
	return OK


func settle_buff_state(side: StringName, entity_id: String, buff_id: String,
		layers: int, duration: int) -> Error:
	var owner: Dictionary = _combatant(side, entity_id)
	if not active or owner.is_empty() or layers < 0 or duration < 0:
		return _fail(ERR_INVALID_PARAMETER, "Buff settlement is invalid")
	var buffs: Array = owner["buffs"]
	for index in buffs.size():
		var existing: Dictionary = buffs[index]
		if existing.get("buff_id") == buff_id:
			if layers == 0:
				buffs.remove_at(index)
			else:
				existing["layers"] = layers
				existing["duration"] = duration
				buffs[index] = existing
			owner["buffs"] = buffs
			return OK
	return _fail(ERR_DOES_NOT_EXIST, "Buff to settle does not exist")


func get_combatant(side: StringName, entity_id: String) -> Dictionary:
	return _combatant(side, entity_id).duplicate(true)


func _combatant(side: StringName, entity_id: String) -> Dictionary:
	if side == &"player" and entity_id == "player":
		return player
	if side == &"enemy":
		var index := _find_enemy_index(entity_id)
		if index >= 0:
			return enemies[index]
	return {}


func _start_player_turn() -> Error:
	if not active:
		return ERR_UNCONFIGURED
	return rules.submit("flow.turn.start")


func _step_turn_start(_event: BattleEvent) -> void:
	pointer_index = 0
	pointer_resolutions = 0
	turn_number += 1
	player_turn_started.emit(turn_number)
	_publish_fact("player.turn_started", {"turn": turn_number})
	rules.publish("flow.turn.draw")


func _step_turn_draw(_event: BattleEvent) -> void:
	_set_phase(Phase.PLAYER_DRAW)
	rules.publish("flow.draw.one", {"remaining": draw_count})
	rules.publish("flow.turn.action")


func _step_turn_action(_event: BattleEvent) -> void:
	_set_phase(Phase.PLAYER_BUFF)
	_set_phase(Phase.PLAYER_ACTION)
	turn_started.emit(turn_number)
	rules.publish("flow.outcome")


func _begin_enemy_turn() -> Error:
	if not active:
		return ERR_UNCONFIGURED
	return rules.submit("flow.enemy.begin")


func _step_enemy_begin(_event: BattleEvent) -> void:
	# 玩家身上的回合性 Buff 在玩家回合结束时结算。这样本回合获得的力量/虚弱
	# 能影响后续卡牌，并在整段出牌结束后清除；玩家中毒也在此时扣血和衰减。
	_set_phase(Phase.PLAYER_BUFF)
	_settle_buffs(&"player", "player", player["buffs"])
	rules.publish("flow.enemy.plan")


func _step_enemy_plan(_event: BattleEvent) -> void:
	if _finish_if_needed():
		return

	_set_phase(Phase.ENEMY_DECIDE)
	var planned: Array[Dictionary] = []
	for enemy: Dictionary in enemies:
		if int(enemy["health"]) <= 0:
			continue
		var picked: Variant = _logic_stream.pick(enemy["actions"])
		if picked == null or not picked is Dictionary:
			rules.last_error = _fail(_logic_stream.last_error, "Could not choose an enemy action")
			return
		var action: Dictionary = picked.duplicate(true)
		planned.append({"enemy_id": enemy["enemy_id"], "action": action})
		enemy_action_decided.emit(enemy["enemy_id"], action.duplicate(true))

	_set_phase(Phase.ENEMY_ACTION)
	for planned_action: Dictionary in planned:
		rules.publish("flow.enemy.act", planned_action)
	rules.publish("flow.enemy.buffs")


func _step_enemy_action(event: BattleEvent) -> void:
	var data := event.payload
	if not _enemy_is_alive(String(data.enemy_id)):
		return
	enemy_action_requested.emit(String(data.enemy_id), data.action.duplicate(true))
	_publish_fact("enemy.action_requested", data)
	rules.publish("flow.enemy.resolved", data)


func _step_enemy_resolved(event: BattleEvent) -> void:
	enemy_action_resolved.emit(String(event.payload.enemy_id), event.payload.action.duplicate(true))
	_finish_if_needed()


func _step_enemy_buffs(_event: BattleEvent) -> void:
	# 敌人身上的中毒、力量、虚弱在敌方回合结束时结算。
	_set_phase(Phase.ENEMY_BUFF)
	for enemy: Dictionary in enemies:
		if int(enemy["health"]) > 0:
			_settle_buffs(&"enemy", enemy["enemy_id"], enemy["buffs"])
	rules.publish("flow.enemy.end")


func _step_enemy_end(_event: BattleEvent) -> void:
	if _finish_if_needed():
		return

	# 玩家格挡完整覆盖敌方行动，敌方回合结束后统一清零。
	if int(player.get("block", 0)) != 0:
		player["block"] = 0
		block_changed.emit(&"player", "player", 0)

	if discard_hand_at_turn_end:
		while not hand.is_empty():
			var card: Dictionary = hand.pop_back()
			discard_pile.append(card)
			card_discarded.emit(card.duplicate(true), &"turn_end")
	_start_player_turn()


func _step_outcome(_event: BattleEvent) -> void:
	_finish_if_needed()


func _clear_resolution_runtime() -> void:
	_resolution_targets.clear()
	_repeat_remaining_by_card.clear()
	_pointer_move_sources.clear()
	_repeat_request_sources.clear()
	_pending_discard_count = 0
	_pending_card.clear()
	_pending_resolved_at = -1
	_next_pointer_override = -1
	_resolving_card = false


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
	_publish_fact("card.drawn", {"card": card, "hand_size": hand.size()})
	return OK


func _discard_play_card(index: int, reason: StringName) -> void:
	var card: Dictionary = play_zone[index]
	play_zone.remove_at(index)
	discard_pile.append(card)
	card_discarded.emit(card.duplicate(true), reason)


func _settle_buffs(side: StringName, entity_id: String, buffs: Array) -> void:
	# 使用快照安排本轮 Buff；派生效果可以增删原容器，不改变已安排的遍历顺序。
	for raw: Variant in buffs.duplicate(true):
		if not raw is Dictionary:
			continue
		var buff: Dictionary = raw
		buff_effect_requested.emit(side, entity_id, buff.duplicate(true))
		_publish_fact("buff.effect_requested", {"side": String(side), "entity_id": entity_id, "buff": buff})
		rules.publish("flow.buff.resolved", {"side": String(side), "entity_id": entity_id, "buff": buff})


func _step_buff_resolved(event: BattleEvent) -> void:
	var data := event.payload
	buff_resolved.emit(StringName(data.side), String(data.entity_id), data.buff.duplicate(true))
	_finish_if_needed()


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
	rules.queue.clear()
	if _resolving_card and not _pending_card.is_empty():
		card_resolved.emit(_pending_card.duplicate(true), _pending_resolved_at)
	_resolving_card = false
	_pending_discard_count = 0
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
	var configured_index: Variant = _integer_value(config.get("battle_index"))
	var configured_draw: Variant = _integer_value(config.get("draw_count"))
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
	var health: Variant = _integer_value(value.get("health"))
	var maximum: Variant = _integer_value(value.get("max_health"))
	var block: Variant = _integer_value(value.get("block", 0))
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
	var layers: Variant = _integer_value(buff.get("layers"))
	var duration: Variant = _integer_value(buff.get("duration"))
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
	var integer: Variant = _integer_value(value)
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

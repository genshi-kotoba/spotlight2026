class_name RelicBattleSystem
extends Node

## 典籍是规则提供者，使用战斗统一队列；自身不再维护第二套结算循环。
signal fragment_activated(trigger_cell: int, effect_cell: int, description: String)
signal chain_limited

const MAX_CHAIN_EFFECTS := 128

var catalog: Dictionary = {}
var board := RelicBoard.new()
var activation_count := 0
var _battle: BattleStateMachine
var _buff_catalog: Dictionary = {}
var _counts: Dictionary = {}
var _pending: Dictionary = {}
var _limited: Dictionary = {}


func attach_to_battle(battle: BattleStateMachine, configured_board: RelicBoard,
		definitions: Dictionary, buff_definitions: Dictionary) -> Error:
	if _battle != null or battle == null or configured_board == null:
		return ERR_INVALID_PARAMETER
	var error := board.restore(configured_board.to_dictionary(), definitions)
	if error != OK:
		return error
	catalog = definitions.duplicate()
	_buff_catalog = buff_definitions
	_battle = battle
	_battle.rules.register_rule("relics.draw", "card.drawn", _on_card_gained)
	_battle.rules.register_rule("relics.damage", "combatant.damaged", _on_combatant_damaged, 100, _enemy_was_damaged)
	_battle.rules.register_rule("relics.turn", "player.turn_started", _on_player_turn_started)
	_battle.rules.register_rule("relics.custom", "relic.event", _on_custom_event)
	_battle.rules.register_rule("relics.activate", "relic.activate", _execute)
	_battle.rules.register_rule("relics.completed", "relic.completed", _completed)
	return OK


func _exit_tree() -> void:
	if is_instance_valid(_battle):
		_battle.rules.remove_rules_for(self)


func _on_card_gained(event: BattleEvent) -> void:
	_trigger("card_gained", "", event)


func _on_player_turn_started(event: BattleEvent) -> void:
	# 清除旧回合根事件的预算，限制运行期追踪数据规模。
	_counts.clear()
	_pending.clear()
	_limited.clear()
	_trigger("player_turn_started", "", event)


func _enemy_was_damaged(event: BattleEvent) -> bool:
	return event.payload.side == "enemy" and int(event.payload.health_loss) > 0


func _on_combatant_damaged(event: BattleEvent) -> void:
	_trigger("enemy_damaged", String(event.payload.entity_id), event)


func notify_event(event_id: String, target_id: String = "") -> void:
	if is_instance_valid(_battle) and _battle.active:
		_battle.rules.submit("relic.event", {"event_id": event_id, "target_id": target_id})


func _on_custom_event(event: BattleEvent) -> void:
	_trigger(String(event.payload.event_id), String(event.payload.target_id), event)


func _trigger(event_id: String, target_id: String, event: BattleEvent) -> void:
	if not _battle.active:
		return
	var ancestry: Array = event.metadata.get("relic_ancestry", [])
	for index in RelicBoard.CELL_COUNT:
		var data: RelicFragmentData = catalog.get(board.cells[index])
		if data == null or data.event_id != event_id:
			continue
		if data.kind == RelicFragmentData.Kind.PRESENCE:
			_enqueue(index, index, target_id, ancestry, event.root_id)
		elif data.kind == RelicFragmentData.Kind.TRIGGER and not ancestry.has(index):
			var descendants := ancestry.duplicate()
			descendants.append(index)
			for neighbor: int in board.neighbors(index, data.reach):
				var effect: RelicFragmentData = catalog.get(board.cells[neighbor])
				if effect != null and effect.kind == RelicFragmentData.Kind.EFFECT:
					_enqueue(index, neighbor, target_id, descendants, event.root_id)


func _enqueue(trigger: int, effect: int, target: String, ancestry: Array, root_id: int) -> void:
	if int(_pending.get(root_id, 0)) >= MAX_CHAIN_EFFECTS:
		return
	_pending[root_id] = int(_pending.get(root_id, 0)) + 1
	_battle.rules.publish("relic.activate", {"trigger": trigger, "effect": effect, "target": target},
		{"relic_ancestry": ancestry.duplicate()})


func _execute(event: BattleEvent) -> void:
	if not _battle.active:
		return
	var root_id := event.root_id
	_pending[root_id] = maxi(0, int(_pending.get(root_id, 0)) - 1)
	if int(_counts.get(root_id, 0)) >= MAX_CHAIN_EFFECTS:
		if not _limited.has(root_id):
			_limited[root_id] = true
			chain_limited.emit()
		return
	var job := event.payload
	var data: RelicFragmentData = catalog[board.cells[int(job.effect)]]
	var target := _living_target(String(job.target))
	var context := BattleEffectContext.new(_battle, target, _buff_catalog)
	match data.action_id:
		"damage":
			if target.is_empty():
				return
			context.damage_enemy(target, data.amount)
		"block":
			context.add_block(&"player", "player", data.amount)
		"strength":
			context.add_buff(&"player", "player", &"strength", data.amount)
		_:
			return
	_counts[root_id] = int(_counts.get(root_id, 0)) + 1
	_battle.rules.publish("relic.completed", {"trigger": job.trigger, "effect": job.effect, "description": data.description})


func _completed(event: BattleEvent) -> void:
	activation_count += 1
	fragment_activated.emit(int(event.payload.trigger), int(event.payload.effect), String(event.payload.description))


func _living_target(preferred: String) -> String:
	for enemy: Dictionary in _battle.enemies:
		if enemy.enemy_id == preferred and int(enemy.health) > 0:
			return preferred
	for enemy: Dictionary in _battle.enemies:
		if int(enemy.health) > 0:
			return String(enemy.enemy_id)
	return ""

extends Node
## 伤害石碑只记录真实最终伤害；所有进度均在 player.event_combat 内随战斗保存。
const SCRIPT_PATH := "res://systems/events/damage_trial_rules.gd"
const NODE_NAME := "DamageTrialRules"
const TURN_LIMIT := 3
const REWARD_NAMES := ["银币 ×100", "普通卡包 ×1", "随机药水 ×1", "稀有卡包 ×1"]
const STONE_ART := "res://assets/map_nodes/alchemy/damage_stele.png"

var _battle: BattleStateMachine
var _finish_queued := false


static func enemies(floor_index: int, event_key: String) -> Array:
	return [{"enemy_id": "damage-trial:" + event_key, "monster_id": 0,
		"damage_trial_target": true, "name": "伤害石碑", "grade": "试炼",
		"art_path": STONE_ART, "floor": clampi(floor_index, 1, 3),
		"health": 1, "max_health": 1, "block": 0, "buffs": [], "actions": []}]


static func thresholds(floor_index: int) -> Array[int]:
	var scale := 1 << clampi(floor_index - 1, 0, 2)
	return [20 * scale, 35 * scale, 50 * scale, 70 * scale]


static func tier_for(total_damage: int, floor_index: int) -> int:
	var tier := -1
	var limits := thresholds(floor_index)
	for index in limits.size():
		if total_damage >= limits[index]: tier = index
	return tier


static func reward_entries(total_damage: int, floor_index: int, rng: RandomStream) -> Array:
	match tier_for(total_damage, floor_index):
		0: return [{"kind": "silver", "amount": 100}]
		1: return [{"kind": "common_pack", "amount": 1}]
		2:
			if rng == null: return []
			var potion: Variant = rng.int_range(0, 4)
			if potion == null: return []
			return [{"kind": "potion", "amount": 1, "potion": int(potion)}]
		3: return [{"kind": "rare_pack", "amount": 1}]
	return []


## 新建与冷恢复均可调用；每场战斗只挂一个节点，不重复注册规则或观察队列。
static func attach_to(battle: BattleStateMachine) -> Error:
	if battle == null or not battle.is_damage_trial(): return ERR_UNAUTHORIZED
	var existing := battle.get_node_or_null(NODE_NAME)
	if existing != null:
		if existing.get_script() == null or existing.get_script().resource_path != SCRIPT_PATH:
			return ERR_ALREADY_IN_USE
		return int(existing.call("attach", battle))
	var handler: Node = (load(SCRIPT_PATH) as GDScript).new()
	handler.name = NODE_NAME
	battle.add_child(handler)
	var error: Error = int(handler.call("attach", battle))
	if error != OK:
		battle.remove_child(handler)
		handler.free()
	return error


func attach(battle: BattleStateMachine) -> Error:
	if _battle == battle and battle != null: return OK
	if _battle != null or battle == null or not battle.is_damage_trial(): return ERR_UNAUTHORIZED
	var context: Dictionary = battle.player.event_combat
	var total: Variant = BattleStateMachine._integer_value(context.get("total_damage"))
	var completed: Variant = BattleStateMachine._integer_value(context.get("completed_turns", maxi(0, battle.turn_number - 1)))
	if total == null or int(total) < 0 or completed == null or int(completed) < 0 or int(completed) > TURN_LIMIT \
			or not context.get("finished") is bool or not context.get("finish_pending", false) is bool \
			or battle.turn_number > TURN_LIMIT or (bool(context.finished) and battle.active):
		return ERR_INVALID_DATA
	# 只补旧快照缺失的字段，不重置累计伤害或已完成的回合。
	if not context.has("completed_turns"): context["completed_turns"] = int(completed)
	if not context.has("finish_pending"): context["finish_pending"] = false
	_battle = battle
	var error := battle.rules.register_rule("event.stone.damage", "combatant.damaged", _record_damage, 200)
	if error != OK:
		_battle = null
		return error
	if not battle.rules.queue.event_processed.is_connected(_on_event_processed):
		battle.rules.queue.event_processed.connect(_on_event_processed)
	_request_finish()
	return OK


func _exit_tree() -> void:
	if not is_instance_valid(_battle): return
	_battle.rules.remove_rules_for(self)
	if _battle.rules.queue.event_processed.is_connected(_on_event_processed):
		_battle.rules.queue.event_processed.disconnect(_on_event_processed)


func _record_damage(event: BattleEvent) -> void:
	if not is_instance_valid(_battle) or not _battle.active or not _battle.is_damage_trial(): return
	var context: Dictionary = _battle.player.event_combat
	if bool(context.get("finished", false)) or event.payload.get("side") != "enemy" \
			or event.payload.get("entity_id") != "damage-trial:" + str(context.event_key):
		return
	# BSM 提供扣除实际格挡吸收后的伤害，石碑无限承伤不裁掉溢出伤害。
	context["total_damage"] = int(context.total_damage) + maxi(0, int(event.payload.get("health_loss", 0)))


func _on_event_processed(_event: BattleEvent) -> void:
	_request_finish()


func _request_finish() -> void:
	if _finish_queued or not is_instance_valid(_battle) or not _battle.active or not _battle.is_damage_trial(): return
	if not bool(_battle.player.event_combat.get("finish_pending", false)): return
	_finish_queued = true
	call_deferred("_finish_when_idle")


func _finish_when_idle() -> void:
	_finish_queued = false
	if not is_instance_valid(_battle) or not _battle.active: return
	# deferred 运行在当前 drain 返回后；若反应暂停等待选择，下一次队列推进会再请求。
	if _battle.rules.queue.processing or _battle.rules.queue.paused or _battle.rules.queue.pending_count() != 0: return
	_battle.finish_damage_trial()

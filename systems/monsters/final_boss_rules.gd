class_name FinalBossRules
extends RefCounted

## 人造之神的手牌机制与一次性半血过渡。卡牌属性随 battle snapshot 保存，
## 只使用战斗已有逻辑随机流；不建立正式卡池条目或永久牌组身份。
const MONSTER_ID := 23
const HALF_HEALTH := 153
const SATURN_CARD_ID := "70"

var battle: BattleStateMachine

func _init(p_battle: BattleStateMachine) -> void:
	battle = p_battle

static func is_saturn(card: Dictionary) -> bool:
	return bool(card.get("boss_saturn", false))

static func card_name() -> String:
	return "逆行土星"

static func card_description() -> String:
	return "机制牌 · 不可出牌／丢弃。留在手牌时，右侧卡牌伤害+2，左侧卡牌伤害-1，可叠加。玩家回合结束时，销毁自身及左侧所有手牌（仅本场战斗）；每销毁一张牌，依次失去5、10、15……生命。每次回合末重新计数。"

## 唯一扣血入口调用，涵盖攻击、典籍、DOT及直接扣血接口。
## 旧 snapshot 没有这些新增字段时仍能继续；不会把旧低血状态向上治疗。
static func clamp_health_after_damage(enemy: Dictionary, proposed: int, turn: int) -> int:
	if int(enemy.get("monster_id", 0)) != MONSTER_ID or int(enemy.get("phase", 1)) >= 2:
		return proposed
	var floor_health := mini(int(enemy.health), HALF_HEALTH)
	if bool(enemy.get("boss_health_locked", false)):
		return maxi(floor_health, proposed)
	if proposed <= HALF_HEALTH:
		enemy["boss_transition_pending"] = true
		enemy["boss_health_locked"] = true
		enemy["boss_transition_turn"] = turn
		return maxi(floor_health, proposed)
	return proposed

static func valid_enemy_state(enemy: Dictionary) -> bool:
	if int(enemy.get("monster_id", 0)) != MONSTER_ID: return true
	for key: String in ["boss_transition_pending", "boss_health_locked"]:
		if enemy.has(key) and not enemy[key] is bool: return false
	for key: String in ["phase", "boss_transition_turn", "boss_saturn_turn"]:
		if not enemy.has(key): continue
		var value: Variant = enemy[key]
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or int(value) < 0: return false
	var phase := int(enemy.get("phase", 1))
	var pending := bool(enemy.get("boss_transition_pending", false))
	return phase in [1, 2] and pending == bool(enemy.get("boss_health_locked", false)) and (phase == 1 or not pending)

static func valid_card_state(card: Dictionary) -> bool:
	if card.has("boss_saturn") and not card.boss_saturn is bool: return false
	if not is_saturn(card): return true
	return str(card.get("card_id", "")) == SATURN_CARD_ID and card.get("temporary") is bool and bool(card.temporary) and card.get("boss_owner") is String and not str(card.boss_owner).is_empty() and not card.has("copy_id")

func handle_event(event: BattleEvent) -> void:
	if not battle.active: return
	match event.type:
		"player.turn_started": _unlock_phase()
		"flow.turn.action":
			if not bool(battle.player.get("external_natural_draw", false)): _after_normal_draw()
		"cards.natural_draw_completed": _after_normal_draw()
		"flow.enemy.begin":
			if battle.hand.any(is_saturn): battle.rules.publish("boss.saturn.cleanup")
		"boss.saturn.cleanup": _begin_cleanup()
		"boss.saturn.destroy": _destroy_one(event)
		"boss.saturn.cleanup_finished": battle.end_deferred_outcome()

func _unlock_phase() -> void:
	for enemy: Dictionary in battle.enemies:
		if int(enemy.get("monster_id", 0)) != MONSTER_ID or int(enemy.health) <= 0: continue
		if bool(enemy.get("boss_transition_pending", false)) and battle.turn_number > int(enemy.get("boss_transition_turn", 0)):
			enemy["phase"] = 2
			enemy["boss_transition_pending"] = false
			enemy["boss_health_locked"] = false

func _after_normal_draw() -> void:
	for enemy: Dictionary in battle.enemies:
		if int(enemy.get("monster_id", 0)) != MONSTER_ID or int(enemy.health) <= 0: continue
		if int(enemy.get("boss_saturn_turn", 0)) >= battle.turn_number: continue
		# 在任何生成及其派生反应之前置位；冷恢复或重复事实不会二次发牌。
		enemy["boss_saturn_turn"] = battle.turn_number
		for index in (2 if int(enemy.get("phase", 1)) >= 2 else 1):
			battle.add_generated_card(SATURN_CARD_ID, "hand", "boss-saturn", {
				"boss_saturn": true, "temporary": true, "boss_owner": str(enemy.enemy_id),
				"occupies_slot": false,
			})

func _begin_cleanup() -> void:
	var rightmost := -1
	for index in battle.hand.size():
		if is_saturn(battle.hand[index]): rightmost = index
	if rightmost < 0: return
	# 两个左侧前缀的并集就是最右侧土星的前缀，按当前从左到右顺序各销毁一次。
	var doomed := battle.hand.slice(0, rightmost + 1).duplicate(true)
	battle.begin_deferred_outcome()
	for card: Dictionary in doomed:
		battle.rules.publish("boss.saturn.destroy", {"instance_id": str(card.instance_id)},
			{"boss_saturn_cleanup": true, "source_card": ""})
	battle.rules.publish("boss.saturn.cleanup_finished")
	battle.player["boss_saturn_destroyed"] = 0

func _destroy_one(event: BattleEvent) -> void:
	if battle.destroy_card_from_battle(str(event.payload.instance_id), &"boss_saturn") != OK: return
	var count := int(battle.player.get("boss_saturn_destroyed", 0)) + 1
	battle.player["boss_saturn_destroyed"] = count
	battle.rules.publish("action.damage", {"side": "player", "target": "player", "amount": count * 5,
		"ignore_block": true, "use_stats": false}, {"boss_saturn_cleanup": true, "true_loss": true,
		"source_card": "", "self_source": false, "formal_damage": false, "heal_ratio": 0.0,
		"block_ratio": 0.0, "restore_amount": 0, "lifesteal_enemy": ""})

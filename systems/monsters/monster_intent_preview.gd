class_name MonsterIntentPreview
extends RefCounted

## Read-only projection over saved actions. No events, RNG, or combatant writes.
## Damage is attack damage before block, not promised final health loss.
static func describe(enemy: Dictionary, player: Dictionary, enemies: Array, buff_catalog: Dictionary) -> Dictionary:
	var result := {"ready": false, "turn": int(enemy.get("intent_turn", 0)),
		"action_count": 0, "actions": [], "triggers": [], "summary": "意图尚未确定"}
	if int(enemy.get("health", 0)) <= 0:
		result.summary = "已阵亡"
		return result
	if not enemy.get("intent_plan") is Array or int(enemy.get("intent_turn", 0)) <= 0 \
			or int(enemy.get("intent_phase", -1)) != int(enemy.get("phase", 1)) \
			or str(enemy.get("intent_actor", enemy.get("enemy_id", ""))) != str(enemy.get("enemy_id", "")):
		return result
	# During execution, live buffs already include effects from earlier actions.
	# Queue snapshots carry the projection frozen before those actions, so do not
	# replay a complete plan over a partially executed state.
	if enemy.get("intent_preview") is Dictionary \
			and int(enemy.get("intent_preview_turn", -1)) == int(enemy.intent_turn) \
			and int(enemy.get("intent_preview_phase", -1)) == int(enemy.intent_phase):
		return enemy.intent_preview.duplicate(true)
	result.ready = true
	var identity := str(enemy.get("enemy_id", ""))
	var states := {}
	for actor: Dictionary in enemies:
		var projected: Dictionary = actor.duplicate(true)
		if int(actor.get("monster_id", 0)) == 15 and int(actor.get("intent_start_applied_turn", 0)) < int(actor.get("intent_turn", 0)):
			for buff: Dictionary in projected.get("buffs", []):
				if str(buff.buff_id) == "weak": buff.layers = maxi(0, int(buff.layers) - 1)
		var attack := BattleStatRules.stat_bonus(projected, buff_catalog, BuffEffectStat.Stat.ATTACK)
		var block := BattleStatRules.stat_bonus(projected, buff_catalog, BuffEffectStat.Stat.BLOCK)
		states[str(actor.get("enemy_id", ""))] = {"attack": attack, "attack_max": attack,
			"block": block, "block_max": block}
	var vulnerable := 0
	for buff: Dictionary in player.get("buffs", []):
		if str(buff.buff_id) == "vulnerable": vulnerable += int(buff.layers)
	var vulnerable_min := vulnerable
	var vulnerable_max := vulnerable
	# Existing roster order is also the execution order. Earlier team strength
	# and random self buffs affect subsequent actions, on temporary ranges only.
	for actor: Dictionary in enemies:
		if int(actor.get("health", 0)) <= 0: continue
		var actor_id := str(actor.get("enemy_id", ""))
		var state: Dictionary = states[actor_id]
		var action_index := 0
		for action: Dictionary in actor.get("intent_plan", []):
			action_index += 1
			var view := {"index": action_index, "kinds": [], "summary": "", "detail": "",
				"hits": int(action.get("hits", 1)), "hit_ranges": [], "damage": -1, "damage_max": -1, "block": -1, "block_max": -1}
			var parts: Array[String] = []
			var details: Array[String] = []
			if action.has("damage"):
				view.kinds.append("attack")
				var low := BattleStatRules.adjusted_amount(int(action.damage), int(state.attack))
				var high := BattleStatRules.adjusted_amount(int(action.damage), int(state.attack_max))
				var minimum := 2147483647
				var maximum := 0
				var hit_descriptions: Array[String] = []
				for hit in int(view.hits):
					var hit_low := low
					var hit_high := high
					if vulnerable_min > 0 and low > 0:
						hit_low = BattleStatRules.vulnerable_amount(low)
					if vulnerable_max > 0 and high > 0:
						hit_high = BattleStatRules.vulnerable_amount(high)
					# A possibly positive hit may consume a layer; a guaranteed
					# positive hit always does. Keep both possible remainders.
					if high > 0: vulnerable_min = maxi(0, vulnerable_min - 1)
					if low > 0: vulnerable_max = maxi(0, vulnerable_max - 1)
					minimum = mini(minimum, hit_low)
					maximum = maxi(maximum, hit_high)
					hit_descriptions.append(_range(hit_low, hit_high))
					view.hit_ranges.append([hit_low, hit_high])
				view.damage = minimum
				view.damage_max = maximum
				parts.append("攻击" + _range(minimum, maximum) + ("×%d" % int(view.hits) if int(view.hits) > 1 else ""))
				details.append("攻击伤害（扣格挡前）；逐击：" + "、".join(hit_descriptions))
				if bool(action.get("lifesteal", false)):
					_add_kind(view, "special")
					parts.append("吸血")
					details.append("吸血：回复实际造成的生命损失")
			if action.has("strength"):
				_add_kind(view, "buff")
				parts.append("力量+%d" % int(action.strength))
				_shift(state, "attack", _bonus_delta(buff_catalog, "strength", int(action.strength), BuffEffectStat.Stat.ATTACK))
			if action.has("block"):
				_add_kind(view, "block")
				view.block = BattleStatRules.adjusted_amount(int(action.block), int(state.block))
				view.block_max = BattleStatRules.adjusted_amount(int(action.block), int(state.block_max))
				parts.append("格挡" + _range(int(view.block), int(view.block_max)))
			if action.has("dot"):
				_add_kind(view, "special")
				parts.append("失去%d生命" % int(action.dot))
				details.append("无视格挡的生命损失")
			if action.has("summon"):
				_add_kind(view, "special")
				parts.append("召唤" + _monster_name(str(action.summon)))
				details.append("需要空位；行动中召唤者本轮不行动")
			if action.has("bleed"):
				_add_kind(view, "special")
				parts.append("施加流血")
			if action.has("heal_player"):
				_add_kind(view, "special")
				parts.append("治疗玩家%d" % int(action.heal_player))
			if action.has("team_strength"):
				_add_kind(view, "buff")
				parts.append("全体敌人力量+%d" % int(action.team_strength))
				for target: String in states:
					_shift(states[target], "attack", _bonus_delta(buff_catalog, "strength", int(action.team_strength), BuffEffectStat.Stat.ATTACK))
			if action.has("random_buff"):
				_add_kind(view, "buff")
				_add_kind(view, "special")
				parts.append("随机Buff")
				details.append("自身力量+1／坚韧+1，或玩家虚弱+1／中毒+1；执行时随机")
				state.attack_max = int(state.attack_max) + _bonus_delta(buff_catalog, "strength", 1, BuffEffectStat.Stat.ATTACK)
				state.block_max = int(state.block_max) + _bonus_delta(buff_catalog, "tenacity", 1, BuffEffectStat.Stat.BLOCK)
			if action.has("discard_right"):
				_add_kind(view, "special")
				parts.append("弃置最右手牌")
			if action.has("forget"):
				_add_kind(view, "special")
				parts.append("遗忘")
				details.append("从执行时随机挑选的至多2张手牌中选1张弃置")
			if action.has("nullify"):
				_add_kind(view, "special")
				parts.append("使卡牌失效")
				details.append("从执行时的手牌、弃牌候选中选择失效卡")
			if parts.is_empty():
				_add_kind(view, "special")
				parts.append("等待")
				details.append("本次不产生战斗效果")
			view.summary = "＋".join(parts)
			view.detail = "；".join(details)
			if actor_id == identity: result.actions.append(view)
	result.action_count = result.actions.size()
	if int(enemy.get("monster_id", 0)) == 23:
		result.triggers.append("玩家回合结束：若手牌中有逆行土星，销毁最右土星及其左侧所有手牌；每成功销毁一张依次失去5、10、15…生命（无视格挡）")
	if int(enemy.get("monster_id", 0)) == 10:
		result.triggers.append("敌方回合开始尝试召唤实验耗材；有空位时新生者本轮行动：失去4生命（无视格挡）")
	if int(enemy.get("intent_first_action_turn", 0)) > int(enemy.intent_turn):
		result.triggers.append("行动阶段出生，本轮不行动，下回合开始行动")
	var lines: Array[String] = []
	for view: Dictionary in result.actions: lines.append("%d. %s" % [int(view.index), str(view.summary)])
	result.summary = "\n".join(lines) if not lines.is_empty() else "本轮不行动"
	return result


static func _add_kind(view: Dictionary, kind: String) -> void:
	if kind not in view.kinds: view.kinds.append(kind)


static func _range(low: int, high: int) -> String:
	return str(low) if low == high else "%d–%d" % [low, high]


static func _shift(state: Dictionary, key: String, amount: int) -> void:
	state[key] = int(state[key]) + amount
	state[key + "_max"] = int(state[key + "_max"]) + amount


static func _bonus_delta(catalog: Dictionary, id: String, layers: int, stat: int) -> int:
	return BattleStatRules.stat_bonus({"buffs": [{"buff_id": id, "layers": layers, "duration": 0}]}, catalog, stat)


static func _monster_name(id: String) -> String:
	var entry := TextCatalog.entry("monsters", id)
	return str(entry.get("name", id + "号怪物"))

extends Node

## 新战斗效果规则的集成自测。
## godot --headless --path . --scene res://tests/battle_effect_rules_selftest.tscn

var failures := 0
var _resolved_events := 0


func _ready() -> void:
	if SeedService.get_main_seed().is_empty():
		SeedService.begin_run("battle-effect-rules-selftest")
	_test_damage_buffs_block_and_heal()
	_test_interactive_discard()
	_test_repeat_next()
	_test_pointer_rewind_once()
	print("全部通过" if failures == 0 else "失败 %d 项" % failures)
	get_tree().quit(failures)


func _test_damage_buffs_block_and_heal() -> void:
	var setup := _make_battle([
		"test_strength", "test_damage_enemy", "test_block", "test_damage_self",
		"test_heal", "test_poison", "test_weak",
	], 101)
	_check("综合规则战斗可创建", setup["error"] == OK)
	if setup["error"] != OK:
		return
	var battle: BattleStateMachine = setup["battle"]
	var ids := _ids_by_card(battle.hand)
	var sequence: Array[String] = [
		ids["test_strength"], ids["test_damage_enemy"], ids["test_block"],
		ids["test_damage_self"], ids["test_heal"], ids["test_poison"],
		ids["test_weak"],
	]
	var targets := _enemy_targets(sequence)
	var error := battle.commit_player_sequence(sequence, targets)
	_check("综合效果序列可完成", error == OK)
	_check("力量使 8 点攻击变为 11 点，中毒回合末再造成 4 点",
		int(battle.enemies[0]["health"]) == 285)
	_check("格挡抵消 4 点自伤和 3 点虚弱后的敌方攻击，玩家治疗后为 56",
		int(battle.player["health"]) == 56)
	_check("敌方回合结束时玩家格挡清零", int(battle.player["block"]) == 0)
	_check("力量在本回合结束后清除", _buff_layers(battle.player, "strength") == 0)
	_check("敌人的虚弱在敌方回合结束后清除", _buff_layers(battle.enemies[0], "weak") == 0)
	_check("4 层中毒结算后减半为 2", _buff_layers(battle.enemies[0], "poison") == 2)
	_free_setup(setup)


func _test_interactive_discard() -> void:
	var setup := _make_battle([
		"test_discard_choice", "test_damage_enemy", "test_block", "test_heal",
	], 102)
	_check("交互弃牌战斗可创建", setup["error"] == OK)
	if setup["error"] != OK:
		return
	var battle: BattleStateMachine = setup["battle"]
	var ids := _ids_by_card(battle.hand)
	var sequence: Array[String] = [ids["test_discard_choice"]]
	var error := battle.commit_player_sequence(sequence, _enemy_targets(sequence))
	_check("弃牌效果暂停但提交本身成功", error == OK \
		and battle.phase == BattleStateMachine.Phase.PLAYER_EFFECTS)
	_check("状态机明确等待选择 2 张", battle.has_pending_discard_choice() \
		and battle.pending_discard_count() == 2)
	var choices: Array[String] = [ids["test_damage_enemy"], ids["test_block"]]
	error = battle.submit_discard_choice(choices)
	_check("提交准确数量后继续并进入下一玩家回合", error == OK \
		and battle.phase == BattleStateMachine.Phase.PLAYER_ACTION)
	_check("选择的两张牌和效果牌都进入弃牌堆", battle.discard_pile.size() == 3)
	_free_setup(setup)


func _test_repeat_next() -> void:
	var setup := _make_battle(["test_repeat_next", "test_damage_enemy"], 103)
	_check("重复后一张战斗可创建", setup["error"] == OK)
	if setup["error"] != OK:
		return
	var battle: BattleStateMachine = setup["battle"]
	var ids := _ids_by_card(battle.hand)
	var sequence: Array[String] = [ids["test_repeat_next"], ids["test_damage_enemy"]]
	_resolved_events = 0
	battle.card_resolved.connect(_count_resolved)
	var error := battle.commit_player_sequence(sequence, _enemy_targets(sequence))
	_check("重复效果序列可完成", error == OK)
	_check("8 点伤害正常一次加额外两次，共造成 24 点",
		int(battle.enemies[0]["health"]) == 276)
	_check("指针事件为重复牌 1 次加伤害牌 3 次", _resolved_events == 4)
	_free_setup(setup)


func _test_pointer_rewind_once() -> void:
	var setup := _make_battle(["test_damage_enemy", "test_move_pointer"], 104)
	_check("指针移动战斗可创建", setup["error"] == OK)
	if setup["error"] != OK:
		return
	var battle: BattleStateMachine = setup["battle"]
	var move_id := ""
	var attack_id := ""
	for card: Dictionary in battle.hand:
		if card["card_id"] == "test_move_pointer":
			move_id = card["instance_id"]
		else:
			attack_id = card["instance_id"]
	var sequence: Array[String] = [attack_id, move_id]
	_resolved_events = 0
	battle.card_resolved.connect(_count_resolved)
	var error := battle.commit_player_sequence(sequence, _enemy_targets(sequence))
	_check("指针向左回退可完成", error == OK)
	_check("回退后前一张 8 点伤害牌再次触发，共造成 16 点",
		int(battle.enemies[0]["health"]) == 284)
	_check("移动牌第二次被遇到时不再回跳，序列正常结束", _resolved_events == 4)
	_free_setup(setup)


func _make_battle(card_ids: Array[String], battle_index: int) -> Dictionary:
	var battle := BattleStateMachine.new()
	add_child(battle)
	var deck: Array[Dictionary] = []
	for index in card_ids.size():
		deck.append({
			"instance_id": "rule-%d-%d" % [battle_index, index],
			"card_id": card_ids[index],
		})
	var error := battle.initialize_battle({
		"map_id": "rule-test", "node_id": "node-%d" % battle_index,
		"battle_index": battle_index, "draw_count": 0,
		"discard_hand_at_turn_end": false,
		"player": {"health": 50, "max_health": 100, "block": 0, "buffs": []},
		"enemies": [{
			"enemy_id": "enemy", "health": 300, "max_health": 300,
			"block": 0, "buffs": [],
			"actions": [{"action_id": "attack", "damage": 6}],
		}],
		"deck_instances": deck,
	})
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	if error == OK:
		error = resolver.attach_to_battle(battle)
	if error == OK:
		error = battle.start_battle()
	if error == OK:
		error = battle.draw_cards(card_ids.size())
	return {"battle": battle, "resolver": resolver, "error": error}


func _ids_by_card(cards: Array[Dictionary]) -> Dictionary:
	var result := {}
	for card: Dictionary in cards:
		result[String(card["card_id"])] = String(card["instance_id"])
	return result


func _enemy_targets(instance_ids: Array[String]) -> Dictionary:
	var result := {}
	for instance_id: String in instance_ids:
		result[instance_id] = "enemy"
	return result


func _count_resolved(_card: Dictionary, _pointer: int) -> void:
	_resolved_events += 1


static func _buff_layers(owner: Dictionary, buff_id: String) -> int:
	for buff: Dictionary in owner.get("buffs", []):
		if String(buff.get("buff_id", "")) == buff_id:
			return int(buff.get("layers", 0))
	return 0


func _free_setup(setup: Dictionary) -> void:
	(setup["resolver"] as Node).queue_free()
	(setup["battle"] as Node).queue_free()


func _check(label: String, condition: bool) -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		failures += 1
		print("  失败  %s" % label)

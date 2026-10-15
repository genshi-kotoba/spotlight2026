extends Node

var failures := 0
var serial := 10000
var round_snapshot: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SeedService.begin_run("formal-card-regression")
	var loaded := FormalCardCatalog.load_definitions()
	_check("81 条定义与 CSV 一一对应", loaded.error == OK and loaded.cards.size() == 81)
	_check("61 明确部分实现，71–81 为占位，62 不占牌位", loaded.cards["61"].implementation_status == "partial" and loaded.cards["81"].implementation_status == "placeholder" and not loaded.cards["62"].occupies_slot)
	for number in range(1, 71):
		_test_one(number)
	_combinations()
	_more_interactions()
	print("正式卡牌自测：全部通过" if failures == 0 else "正式卡牌自测：%d 项失败" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _make(ids: Array[String], enemy_health: int = 1000, enemy_damage: int = 0, multiple: bool = false) -> Dictionary:
	serial += 1
	var battle := BattleStateMachine.new()
	add_child(battle)
	var deck: Array[Dictionary] = []
	for index in ids.size():
		deck.append({"instance_id": "f-%d-%d" % [serial, index], "card_id": ids[index]})
	var enemies: Array[Dictionary] = [{"enemy_id": "enemy", "health": enemy_health, "max_health": enemy_health,
		"block": 0, "buffs": [], "actions": [{"damage": enemy_damage}]}]
	if multiple:
		enemies.append({"enemy_id": "enemy2", "health": enemy_health, "max_health": enemy_health,
			"block": 0, "buffs": [], "actions": [{"damage": enemy_damage}]})
	_check("创建战斗", battle.initialize_battle({"map_id": "formal-test", "node_id": "room",
		"battle_index": serial, "draw_count": 0, "discard_hand_at_turn_end": false,
		"player": {"health": 200, "max_health": 300, "block": 0, "buffs": [], "silver": 1234, "base_play_limit": 10},
		"enemies": enemies, "deck_instances": deck}) == OK)
	var resolver := BattleEffectResolver.new()
	add_child(resolver)
	_check("接入既有规则引擎", resolver.attach_to_battle(battle) == OK)
	_check("开始战斗", battle.start_battle() == OK)
	# 显式布置每条用例的手牌顺序，抽牌事实另有专门覆盖，避免 RNG 掩盖左右语义。
	for fixture: Dictionary in deck:
		var index := battle._find_card_index(battle.draw_pile, fixture.instance_id)
		var card: Dictionary = battle.draw_pile[index]
		battle.draw_pile.remove_at(index)
		battle.hand.append(card)
	battle.rules.register_rule("test.capture", "flow.enemy.begin", _capture.bind(battle), -10)
	return {"battle": battle, "resolver": resolver}


func _capture(_event: BattleEvent, battle: BattleStateMachine) -> void:
	round_snapshot = battle.to_dictionary()


func _play(setup: Dictionary, positions: Array[int]) -> void:
	var battle: BattleStateMachine = setup.battle
	var sequence: Array[String] = []
	var targets := {}
	for position: int in positions:
		var id := str(battle.hand[position].instance_id)
		sequence.append(id)
		targets[id] = "enemy"
	round_snapshot = {}
	_check("提交序列", battle.commit_player_sequence(sequence, targets) == OK)
	var loops := 0
	while battle.active and battle.rules.queue.paused and loops < 10:
		loops += 1
		var choices: Array[String] = []
		if battle.has_pending_discard_choice():
			for i in battle.pending_discard_count():
				choices.append(str(battle.hand[i].instance_id))
			_check("准确弃牌后队列原位恢复", battle.submit_discard_choice(choices) == OK)
		elif battle.pending_pile_count() > 0:
			for i in battle.pending_pile_count():
				choices.append(str(battle.discard_pile[i].instance_id))
			_check("弃牌堆选择后队列原位恢复", battle.submit_pile_choice(choices) == OK)
		else:
			break
	_check("队列空闲且无错误", battle.rules.last_error == OK and not battle.rules.queue.paused and battle.rules.queue.pending_count() == 0)


func _test_one(number: int) -> void:
	var setup := _make([str(number), "1", "1", "71", "72"])
	var b: BattleStateMachine = setup.battle
	var subject := str(b.hand[0].instance_id)
	if number in [23, 27, 29, 58, 59]:
		b.change_buff_layers(&"enemy", "enemy", "poison", 5)
	if number in [49, 66]:
		b.set_player_block(8)
	if number == 54:
		b.hand[0]["received"] = 7
	if number == 67:
		b.hand[0]["recorded_block"] = 7
	if number in [37, 62]:
		b.discard_from_hand(str(b.hand[4].instance_id))
		b.discard_from_hand(str(b.hand[3].instance_id))
	if number in [16, 38]:
		b.draw_pile.append({"instance_id": "extra1-%d" % serial, "card_id": "71"})
		b.draw_pile.append({"instance_id": "extra2-%d" % serial, "card_id": "72"})
		b.draw_pile.append({"instance_id": "extra3-%d" % serial, "card_id": "73"})
	if number == 13:
		b.apply_damage_to_player(2, true)
		b.apply_damage_to_player(2, true)
	var positions: Array[int] = [0]
	if number in [12, 20, 22, 45, 48, 63, 64]:
		positions = [1, 0, 2]
	if number in [18, 36, 40, 41, 43, 44]:
		positions = [1, 0]
	if number == 68 or number == 70:
		positions = [1]
	_play(setup, positions)
	var direct_damage := _damage(b, "enemy", true)
	var expected: Dictionary = {1:5, 2:4, 3:3, 4:4, 5:4, 6:0, 7:6, 8:0, 9:0, 10:4,
		12:13, 14:10, 19:3, 21:5, 22:16, 24:4, 28:3, 32:8, 40:10, 41:10,
		42:3, 43:10, 44:10, 48:10, 49:8, 51:4, 52:4, 54:7, 56:5, 57:50, 60:12, 61:5, 64:15, 65:4, 66:20, 67:7}
	if expected.has(number):
		_check("%02d 直接伤害=%d（实际%d）" % [number, expected[number], direct_damage], direct_damage == int(expected[number]))
	match number:
		5: _check("25% 回血向下取整", int(b.player.health) == 201)
		6: _check("回复2", int(b.player.health) == 202)
		8, 9: _check("总共重复2/4次格挡", _block_total(b) == 4)
		13: _check("失血次数转力量", _buff_added(b, "strength") == 2)
		14, 15, 16, 17, 18: _check("失去生命不受格挡影响", _damage(b, "player", false) == {14:2,15:4,16:5,17:3,18:10}[number])
		19, 21, 47: _check("下回合牌位更新", b.effective_play_limit() == (10 if number == 47 else 11))
		20: _check("保留原索引下一牌", b.play_zone.size() == 3 and str(b.play_zone[2].card_id) == "1")
		23: _check("毒层数转格挡", _block_total(b) == 5)
		25: _check("全敌2毒回合末减半", _layers(b.enemies[0], "poison") == 1)
		26: _check("5毒回合末变3", _layers(b.enemies[0], "poison") == 3)
		27: _check("主动毒结算再经过敌回合结算", 1000 - int(b.enemies[0].health) == 8 and _layers(b.enemies[0], "poison") == 2)
		33: _check("弃牌后获得7格挡", _block_total(b) == 7)
		37, 59, 62, 69: _check("本场移除不进入任何牌堆", not _exists(b, subject))
		38: _check("先弃2后抽3", b.hand.size() == 5)
		40, 41, 43, 44, 53: _check("失效不再产生效果且有限终止", b.pointer_resolutions < 30)
		51: _check("无格挡不增生命伤害", int(b.enemies[0].health) == 996)
		52: _check("50%格挡", _block_total(b) == 2)
		58: _check("单目标原5毒再获得15毒", _layers(b.enemies[0], "poison") == 10)
		59: _check("不减层毒结算", 1000 - int(b.enemies[0].health) == 10 and _layers(b.enemies[0], "poison") == 3)
		68: _check("手牌回合末自伤3", int(b.player.health) == 197)
		69: _check("打出自伤6仅一次", int(b.player.health) == 194)
		70: _check("右侧牌减2伤害", direct_damage == 3)
	_check("%02d 可运行且有真实效果事件" % number, b.rules.queue.history.any(func(e: Dictionary): return e.type == "action.card_program") or number in [46, 47, 68, 70])
	_free(setup)


func _combinations() -> void:
	var s := _make(["4", "7"])
	_play(s, [0, 1])
	_check("易伤只加50%，消耗一层后第二击正常", _damage(s.battle, "enemy", true) == 11 and _layers(s.battle.enemies[0], "vulnerable") == 0)
	_free(s)
	s = _make(["15", "7"])
	_play(s, [0, 1])
	_check("力量作用于每次重复攻击", _damage(s.battle, "enemy", true) == 10)
	_free(s)
	s = _make(["11", "7", "30", "26"])
	_play(s, [0, 1, 2, 3])
	_check("伤害事实触发格挡，中毒追加1", _block_total(s.battle) == 3 and _layers(s.battle.enemies[0], "poison") == 3)
	_free(s)
	s = _make(["34", "35", "32", "71", "72"])
	_play(s, [0, 1, 2])
	_check("选择弃牌触发格挡和伤害，而出牌入弃不触发", _block_total(s.battle) == 2 and _damage(s.battle, "enemy", true) == 10)
	_free(s)
	s = _make(["31", "39", "16"])
	for i in 3:
		s.battle.draw_pile.append({"instance_id": "draw-%d-%d" % [serial, i], "card_id": "71"})
	_play(s, [0, 1, 2])
	_check("逐张抽牌触发伤害和毒", _damage(s.battle, "enemy", true) == 6 and _layers(s.battle.enemies[0], "poison") == 2)
	_free(s)
	s = _make(["48", "46", "1", "48", "47", "1"])
	_play(s, [0, 1, 2, 3, 4, 5])
	_check("跳过卡不打出普通效果但获得力量坚韧与次回合牌位", _damage(s.battle, "enemy", true) == 32 and s.battle.effective_play_limit() == 11 and _buff_added(s.battle, "tenacity") == 4)
	_free(s)
	s = _make(["48", "65", "40"])
	_play(s, [0, 1, 2])
	_check("65被跳过一次后重访伤害翻倍，移位有限终止", _damage(s.battle, "enemy", true) == 18 and s.battle.pointer_resolutions < 10)
	_free(s)
	s = _make(["53", "7", "9"])
	_play(s, [0, 1, 2])
	_check("重复次数+1为总共3次/5次", _damage(s.battle, "enemy", true) == 9 and _block_total(s.battle) == 5)
	_free(s)
	s = _make(["1", "1", "1", "1", "22", "40"])
	_play(s, [0, 1, 2, 3, 4, 5])
	_check("40先完成外部重复，两次前移累计4格后失效", _damage(s.battle, "enemy", true) == 37 and s.battle.pointer_resolutions < 20)
	_free(s)
	s = _make(["20", "1"])
	_play(s, [0, 1])
	var b: BattleStateMachine = s.battle
	_check("锁牌存档边界合法", bool(b.to_dictionary().queue_idle) and b.play_zone.size() == 2)
	var restored := BattleStateMachine.new()
	add_child(restored)
	_check("锁牌和规则状态可以恢复", restored.restore_from_dictionary(b.to_dictionary()) == OK)
	var restored_resolver := BattleEffectResolver.new()
	add_child(restored_resolver)
	_check("恢复后重新接规则", restored_resolver.attach_to_battle(restored) == OK)
	_check("锁牌无需手牌自动再次参与且本回合后入弃", restored.end_player_action() == OK and int(restored.enemies[0].health) == 990 and restored.play_zone.is_empty())
	restored_resolver.queue_free()
	restored.queue_free()
	_free(s)
	s = _make(["55", "14"], 10)
	_play(s, [0, 1])
	_check("终局清队列之前返还本回合失血", s.battle.phase == BattleStateMachine.Phase.VICTORY and int(s.battle.player.health) == 200)
	_free(s)
	s = _make(["66"], 10, 0, true)
	s.battle.set_player_block(8)
	_play(s, [0])
	_check("全体伤害击杀后格挡只恢复一次", s.battle.phase == BattleStateMachine.Phase.VICTORY and int(s.battle.player.block) == 8)
	_free(s)
	s = _make(["14", "54"])
	_play(s, [0])
	_check("54在手牌记录自身失血双倍", int(s.battle.hand[0].get("received", 0)) == 4)
	_play(s, [0])
	_check("54打出使用记录值", int(s.battle.enemies[0].health) == 986)
	_free(s)
	s = _make(["50", "67"])
	_play(s, [0])
	_check("67记录敌方未扣生命时残余格挡", int(s.battle.hand[0].get("recorded_block", 0)) == 4)
	_free(s)
	s = _make(["1", "70", "1"])
	_play(s, [0, 2])
	_check("70左右修正及自身左移", _damage(s.battle, "enemy", true) == 9 and str(s.battle.hand[0].card_id) == "70")
	_free(s)
	s = _make(["51"])
	s.battle.enemies[0]["block"] = 4
	_play(s, [0])
	_check("51对格挡双倍，剩余2伤害扣生命", int(s.battle.enemies[0].health) == 998 and int(s.battle.enemies[0].block) == 0)
	_free(s)
	s = _make(["62", "71"])
	s.battle.player["base_play_limit"] = 1
	s.battle.hand[1]["card_id"] = "1"
	_play(s, [0, 1])
	_check("62不占牌位，数量超限时仍可搭配1张牌", int(s.battle.enemies[0].health) == 995)
	_free(s)


func _more_interactions() -> void:
	var s := _make(["2", "25", "28", "29", "58", "59"], 1000, 0, true)
	s.battle.change_buff_layers(&"enemy", "enemy", "poison", 2)
	s.battle.change_buff_layers(&"enemy", "enemy2", "poison", 3)
	_play(s, [0, 1, 2, 3, 4, 5])
	_check("多敌伤害、毒合并/扩散/不减层结算保持顺序", int(s.battle.enemies[0].health) == 949 and int(s.battle.enemies[1].health) == 971 and _layers(s.battle.enemies[0], "poison") == 11 and _layers(s.battle.enemies[1], "poison") == 6)
	_free(s)
	s = _make(["1", "42"])
	_play(s, [0, 1])
	_check("42包括正常指针推进一格的加伤", _damage(s.battle, "enemy", true) == 11)
	_free(s)
	s = _make(["19", "56", "57"])
	_play(s, [0])
	_play(s, [0, 1])
	_check("次回合多1牌位使56增伤3，57计9空位", int(s.battle.enemies[0].health) == 939)
	_free(s)
	s = _make(["1", "63", "1", "1", "1", "40", "1"])
	_play(s, [0, 1, 2, 3, 4, 5, 6])
	_check("63主动位移固定到移动后的自身位置而非原目标", s.battle.rules.queue.history.any(func(e: Dictionary): return e.type == "pointer.moved" and int(e.payload.from) == 5 and int(e.payload.to) == 2) and s.battle.pointer_resolutions < 30)
	_free(s)
	s = _make(["1", "44", "40", "1"])
	_play(s, [0, 1, 2, 3])
	_check("44按两张移位牌允许两次触发后失效", s.battle.pointer_resolutions < 15 and _damage(s.battle, "enemy", true) == 25)
	_free(s)
	s = _make(["5", "52"])
	s.battle.change_buff_layers(&"player", "player", "weak", 1, 1)
	_play(s, [0, 1])
	_check("3伤害的25%回血为0，50%格挡为1", int(s.battle.player.health) == 200 and _block_total(s.battle) == 1)
	_free(s)
	s = _make(["66"])
	s.battle.set_player_block(3)
	_play(s, [0])
	_check("250%格挡伤害向下取整，不击杀不返还", _damage(s.battle, "enemy", true) == 7 and int(round_snapshot.player.block) == 0)
	_free(s)
	s = _make(["1", "69", "71"])
	s.battle.discard_from_hand(str(s.battle.hand[1].instance_id))
	_check("弃置69立即自伤6并从弃牌堆移除", int(s.battle.player.health) == 194 and not _exists(s.battle, "f-%d-1" % serial))
	_free(s)
	s = _make(["69", "71"])
	s.battle.discard_from_hand(str(s.battle.hand[1].instance_id))
	_check("移走右侧手牌令69成为最右侧时立即触发", int(s.battle.player.health) == 194 and s.battle.hand.is_empty())
	_free(s)
	s = _make(["50", "67"], 1000, 6)
	_play(s, [0])
	_check("67敌方实际扣血则不记录", int(s.battle.hand[0].get("recorded_block", 0)) == 0)
	_free(s)
	s = _make(["1", "62", "71"])
	s.battle.discard_from_hand(str(s.battle.hand[2].instance_id))
	var sequence: Array[String] = [str(s.battle.hand[1].instance_id)]
	_check("62候选不足时选择现有数量", s.battle.commit_player_sequence(sequence) == OK and s.battle.pending_pile_count() == 1)
	var wrong: Array[String] = [str(s.battle.hand[0].instance_id)]
	_check("错误弃牌堆输入拒绝且保持暂停", s.battle.submit_pile_choice(wrong) == ERR_INVALID_PARAMETER and s.battle.rules.queue.paused)
	var correct: Array[String] = [str(s.battle.discard_pile[0].instance_id)]
	_check("正确输入继续原队列", s.battle.submit_pile_choice(correct) == OK and not s.battle.rules.queue.paused)
	_free(s)
	# 典籍与正式卡沿用同一战斗规则引擎：此事实观察器模拟外围规则，验证比例
	# 元数据不会泄漏到后续派生伤害，造成意外递归回血。
	s = _make(["5"])
	s.battle.rules.register_rule("test.followup", "combatant.damaged", func(e: BattleEvent):
		if str(e.payload.side) == "enemy" and not bool(e.metadata.get("test_followup", false)):
			s.battle.rules.publish("action.damage", {"side": "enemy", "target": "enemy", "amount": 8,
				"ignore_block": false, "use_stats": false}, {"test_followup": true}))
	_play(s, [0])
	_check("派生伤害不继承5号回血比例", int(s.battle.player.health) == 201 and int(s.battle.enemies[0].health) == 988)
	_free(s)
	s = _make(["10", "71", "70"])
	s.battle.change_buff_layers(&"player", "player", "weak", 10, 1)
	_play(s, [0])
	_check("零伤害不会令70左移", _damage(s.battle, "enemy", true) == 0 and str(s.battle.hand[1].card_id) == "70")
	_free(s)


func _damage(b: BattleStateMachine, side: String, formal_only: bool) -> int:
	var result := 0
	for event: Dictionary in b.rules.queue.history:
		if event.type == "combatant.damaged" and str(event.payload.side) == side:
			if not formal_only or (bool(event.metadata.get("formal_damage", false)) and int(event.parent_id) == int(event.metadata.get("damage_program_id", -1))):
				result += int(event.payload.health_loss)
	return result


func _block_total(b: BattleStateMachine) -> int:
	var result := 0
	for event: Dictionary in b.rules.queue.history:
		if event.type == "action.block":
			result += int(event.payload.amount)
	return result


func _buff_added(b: BattleStateMachine, id: String) -> int:
	var result := 0
	for event: Dictionary in b.rules.queue.history:
		if event.type == "action.buff_add" and str(event.payload.buff_id) == id:
			result += int(event.payload.layers)
	return result


func _layers(owner: Dictionary, id: String) -> int:
	for buff: Dictionary in owner.buffs:
		if str(buff.buff_id) == id:
			return int(buff.layers)
	return 0


func _exists(b: BattleStateMachine, id: String) -> bool:
	for zone: Array in [b.hand, b.draw_pile, b.discard_pile, b.play_zone]:
		if zone.any(func(c: Dictionary): return str(c.instance_id) == id):
			return true
	return false


func _free(setup: Dictionary) -> void:
	setup.resolver.queue_free()
	setup.battle.queue_free()


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1

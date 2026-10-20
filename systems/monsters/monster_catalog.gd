class_name MonsterCatalog
extends RefCounted
## 正式怪物数值来自策划案；17 按当前测试要求暂定100血、10攻击。
const HEALTH := [128, 64, 18, 32, 28, 24, 26, 24, 164, 135, 70, 118, 89, 46, 38, 205, 100, 101, 99, 80, 89, 50, 305]
const DAMAGE := [10, 2, 4, 5, 0, 4, 1, 4, 3, 6, 4, 10, 6, 6, 10, 2, 10, 0, 0, 10, 3, 6, 8]

static func create(id: String, floor_index := 1, identity := "") -> Dictionary:
	var entry := TextCatalog.entry("monsters", id)
	var index := int(id) - 1
	if entry.is_empty() or index < 0 or index >= HEALTH.size(): return {}
	var enemy := {"enemy_id": id if identity.is_empty() else identity, "monster_id": id,
		"name": str(entry.name), "art_path": str(entry.art_path),
		"grade": "BOSS" if "BOSS" in str(entry.get("type", "")) else ("精英" if "精英" in str(entry.get("type", "")) else "普通"),
		"health": int(HEALTH[index]), "max_health": int(HEALTH[index]), "block": 0, "buffs": [],
		"floor": floor_index, "taunt": id == "5" and floor_index >= 2, "phase": 1,
		"actions": [{"action_id": "monster-attack", "damage": int(DAMAGE[index])}]}
	if id == "23":
		enemy.merge({"boss_transition_pending": false, "boss_health_locked": false,
			"boss_transition_turn": 0, "boss_saturn_turn": 0,
			"actions": [{"action_id": "monster-23", "damage": 8},
				{"action_id": "monster-23", "strength": 1}, {"action_id": "monster-23", "block": 8}]}, true)
	return enemy

static func plan(enemy: Dictionary, turn: int, rng: RandomStream) -> Array:
	var id := int(enemy.get("monster_id", 0))
	var result: Array = []
	match id:
		1:
			result = [{"damage": 10}, {"summon": "4"} if turn >= 2 and turn % 2 == 0 else {"damage": 10}]
		2:
			var block_at := int(rng.int_range(0, 5)) # 4代表本轮不格挡；最多一次。
			for index in 4: result.append({"block": 1} if index == block_at else {"damage": 2})
		3: result = [{"damage": 4} if int(rng.int_range(0, 2)) == 0 else {"block": 3}]
		4: result = [{"random_buff": true}, {"damage": int(floor(5.0 * pow(1.2, max(0, turn - int(enemy.get("spawn_turn", 1))))))}]
		5: result = [{"dot": 4}]
		6: result = [{"damage": 4, "bleed": true}]
		7: result = [{"damage": 1, "lifesteal": true}, {"damage": 1, "lifesteal": true}, {"damage": 1, "lifesteal": true}]
		8: result = [{"damage": 4, "forget": true}]
		9: result = [{"damage": 3}, {"damage": 3}]
		10: result = [{"damage": 6}]
		11:
			result = [{"damage": 4}, {"damage": 4}] if int(enemy.get("phase", 1)) == 1 else ([{"damage": 4}] if turn % 2 == 1 else [{"team_strength": 1}])
		13: result = [{"damage": 6}] if int(rng.int_range(0, 2)) == 0 else [{"block": 10}]
		15: result = [{"damage": 10}, {"damage": 10}]
		16: result = [{"damage": 2, "hits": 5}] if int(rng.int_range(0, 2)) == 0 else [{"damage": 4, "discard_right": true}]
		18: result = [{"block": 10}]
		19: result = [{"heal_player": 10, "nullify": true}]
		21: result = [{"damage": 3}, {"damage": 3}]
		23: result = [{"damage": 8}, {"strength": 1}, {"block": 8}]
		_: result = enemy.actions.duplicate(true)
	for action: Dictionary in result: action["action_id"] = "monster-%d" % id
	return result

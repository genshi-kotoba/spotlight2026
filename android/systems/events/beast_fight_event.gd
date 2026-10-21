extends RefCounted


static func enemies(floor_index: int, event_key: String) -> Array:
	var effective_floor := clampi(floor_index, 1, 3)
	var health_multiplier := effective_floor * 2
	var result: Array = []
	for index in range(3):
		var identity := "%s/hound-%d" % [event_key, index]
		var enemy := MonsterCatalog.create("6", effective_floor, identity)
		if enemy.is_empty():
			return []
		enemy["name"] = "强化恶犬"
		enemy["grade"] = "普通"
		enemy["health"] = int(enemy.get("health", 0)) * health_multiplier
		enemy["max_health"] = int(enemy.get("max_health", 0)) * health_multiplier
		enemy["formation_slot"] = index
		result.append(enemy)
	return result


static func reward_entries(rng: RandomStream) -> Array:
	var fragment_id := RelicCatalog.generate(rng)
	if fragment_id.is_empty():
		return []
	return [
		{"kind": "silver", "amount": 100},
		{"kind": "fragment", "fragment_id": fragment_id, "amount": 1},
	]

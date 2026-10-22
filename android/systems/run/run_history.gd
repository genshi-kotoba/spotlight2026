class_name RunHistory
extends RefCounted
## 记录只展示保存的最终背包；不恢复随机流，不安装活动对局。

static func records(history: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(history.size() - 1, -1, -1):
		var entry: Dictionary = history[index]
		if entry.get("result") in ["defeat", "victory"]:
			var copy := entry.duplicate(true)
			copy["_history_order"] = index
			result.append(copy)
	result.sort_custom(func(a: Dictionary, b: Dictionary):
		var a_time := float(a.get("ended_at_unix", Time.get_unix_time_from_datetime_string(str(a.get("ended_at", "1970-01-01T00:00:00")))))
		var b_time := float(b.get("ended_at_unix", Time.get_unix_time_from_datetime_string(str(b.get("ended_at", "1970-01-01T00:00:00")))))
		return int(a._history_order) > int(b._history_order) if a_time == b_time else a_time > b_time)
	for entry in result: entry.erase("_history_order")
	return result

static func inventory_run(record: Dictionary) -> RunStateMachine:
	var run := RunStateMachine.new()
	var data: Dictionary = record.get("final_inventory", {})
	run.run_id = str(record.get("run_id", "history"))
	run.main_seed = str(record.get("main_seed", ""))
	run.active = false
	run.max_health = int(data.get("max_health", 100))
	run.health = int(data.get("health", 0))
	run.gold = int(data.get("gold", 0))
	run.total_silver_earned = int(record.get("total_silver_earned", run.gold))
	run.deck.assign(data.get("deck", record.get("deck", [])))
	run.deck_cards.assign(data.get("deck_cards", []).duplicate(true))
	run.next_card_serial = int(data.get("next_card_serial", 0))
	run.ensure_deck_cards()
	run.items = data.get("items", []).duplicate(true)
	var empty_inventory := {"version": 1, "elixir": 0, "next_item": 0,
		"relic_board": RelicBoard.new().to_dictionary(), "pending_rewards": {}, "rewarded_battles": {}}
	run.inventory_state = data.get("inventory_state", empty_inventory).duplicate(true)
	if run.inventory_state.is_empty(): run.inventory_state = empty_inventory
	return run

static func silver_text(record: Dictionary) -> String:
	return str(int(record.total_silver_earned)) if record.has("total_silver_earned") else "未记录"

static func lines(record: Dictionary) -> Array[String]:
	var result: Array[String] = ["结束了" if record.get("result") == "victory" else "你死了"]
	if record.get("result") != "victory":
		result.append("你死于%s" % str(record.get("location_name", record.get("death_location", "未知地点"))))
	result.append("你共获得过%s银币" % silver_text(record) if record.has("total_silver_earned") else "累计获得银币：未记录")
	result.append("你经历了%d场战斗" % int(record.get("battles_fought", 0)))
	return result

extends RefCounted
## 事件战斗沿用正式战斗；事件节点保留到专属结果被确认后再完成。
const Beast = preload("res://systems/events/beast_fight_event.gd")
const Stone = preload("res://systems/events/damage_trial_rules.gd")
const Sandbox = preload("res://systems/testing/sandbox_resources.gd")

static func event_key(request: Dictionary) -> String:
	return "%s/%s" % [request.get("map_id", ""), request.get("node_id", "")]

static func _record(run: Node, request: Dictionary) -> Dictionary:
	return run.inventory_state.get("events", {}).get(event_key(request), {}).duplicate(true)

static func matches(battle: BattleStateMachine, session: RefCounted, run: Node) -> bool:
	if not is_instance_valid(battle) or session == null or not is_instance_valid(run): return false
	var context: Variant = battle.player.get("event_combat")
	var pending: Dictionary = session.pending
	if not context is Dictionary or pending.get("type") != "event" \
			or battle.map_id != session.map_id or battle.node_id != pending.get("node_id") \
			or context.get("event_key") != event_key(pending): return false
	var current := _record(run, pending)
	return current.get("stage") == "battle" \
		and current.get("event_battle_index") == battle.battle_index \
		and ((current.get("index") == 5 and context.get("kind") == "beast") \
		or (current.get("index") == 6 and context.get("kind") == "stone"))

static func start(run: Node, request: Dictionary) -> Error:
	var session: RefCounted = EncounterFlow.session
	if not is_instance_valid(run) or run != SaveGateway.current_run() or not run.active \
			or session == null or session.pending != request or request.get("type") != "event" \
			or request.get("map_id") != run.current_map_id or not RunRewards.pending(run).is_empty():
		return ERR_UNAUTHORIZED
	var current := _record(run, request)
	if current.get("stage") == "battle": return resume(run, request)
	if run.current_battle != null or current.get("stage") != "choice" or int(current.get("index", -1)) not in [5, 6]: return ERR_BUSY
	var floor_index := clampi(int(EncounterFlow.map_run.current_floor), 1, 3)
	var board := RelicBoard.new()
	var error := board.restore(run.inventory_state.relic_board, RelicCatalog.load_definitions())
	if error != OK: return error
	var context := {"kind": "beast" if int(current.index) == 5 else "stone",
		"event_key": event_key(request), "floor": floor_index, "request": request.duplicate(true),
		"total_damage": 0, "turn_limit": 3, "finished": false}
	var enemies: Array = Beast.enemies(floor_index, str(context.event_key)) if context.kind == "beast" else Stone.enemies(floor_index, str(context.event_key))
	if enemies.is_empty(): return ERR_INVALID_DATA
	var rules: Dictionary = EncounterFlow.test_rules.duplicate(true)
	# 与已确认的正式抽牌规则一致。
	rules["initial_draw_count"] = 6
	var temporary: Array = rules.empty_deck_fallback if run.deck.is_empty() else []
	error = run.start_battle(str(request.node_id), enemies, 0, false, int(rules.play_limit), false, temporary, {"event_combat": context})
	if error != OK: return error
	var battle: BattleStateMachine = run.current_battle
	battle.player["encounter_floor"] = floor_index
	battle.player["encounter_rules"] = rules
	battle.player["temporary_deck"] = run.deck.is_empty()
	battle.player["conch_bound"] = int(run.inventory_state.get("conch_bound", 0)) if context.kind == "beast" else 0
	battle.player["potions"] = run.items.filter(func(value: Variant): return value is Dictionary and value.get("kind") == "potion").duplicate(true)
	battle.player["encounter_relic_board"] = board.to_dictionary()
	if Sandbox.active(run):
		battle.player["sandbox_reference_silver"] = Sandbox.RESERVE
		Sandbox.refill(run)
	current["stage"] = "battle"
	current["event_battle_index"] = battle.battle_index
	run.inventory_state.events[event_key(request)] = current
	# 保存失败保留同一场已准备战斗，重试不能重新造怪或消费战斗编号。
	return resume(run, request)

static func resume(run: Node, request: Dictionary) -> Error:
	if run != SaveGateway.current_run() or EncounterFlow.session == null \
			or request != EncounterFlow.session.pending or not matches(run.current_battle, EncounterFlow.session, run): return ERR_UNAUTHORIZED
	var error := SaveGateway.save_current()
	if error != OK: return error
	EncounterFlow.last_error = ""
	EncounterFlow.call_deferred("open_battle")
	return OK

static func is_result(result: Dictionary) -> bool:
	var context: Variant = result.get("event_combat")
	return context is Dictionary and context.get("kind") in ["beast", "stone"]

static func settle(run: Node, result: Dictionary) -> Error:
	var session: RefCounted = EncounterFlow.session
	if not is_result(result) or not is_instance_valid(run) or run != SaveGateway.current_run() \
			or session == null or session.pending.get("type") != "event" \
			or result.get("map_id") != session.map_id or result.get("node_id") != session.pending.get("node_id"):
		return ERR_UNAUTHORIZED
	var request: Dictionary = session.pending
	var context: Dictionary = result.event_combat
	var current := _record(run, request)
	if current.get("settled_battle_index") == result.get("battle_index") and current.get("stage") in ["result", "done"]: return OK
	if context.get("event_key") != event_key(request) or current.get("stage") != "battle" \
			or current.get("event_battle_index") != result.get("battle_index") \
			or not ((current.get("index") == 5 and context.kind == "beast") or (current.get("index") == 6 and context.kind == "stone")):
		return ERR_INVALID_DATA
	# 奖励提交失败时保留待结算结果，可在当前界面重试，也可保存后恢复。
	current["pending_outcome"] = result.duplicate(true)
	run.inventory_state.events[event_key(request)] = current
	var before := RunRewards._capture(run)
	var victory: bool = result.get("status") == "victory"
	var entries: Array = []
	var lines: Array[String] = []
	var fragments: Array[String] = []
	if victory:
		var rng := RandomEventCatalog.stream(str(run.main_seed), session.map_id, str(request.node_id), "event-combat-reward-%d" % int(result.battle_index))
		if context.kind == "beast":
			entries = Beast.reward_entries(rng)
			if entries.size() != 2: return ERR_INVALID_DATA
			lines.append("三只强化恶犬已被击败")
			for _bonus in maxi(0, int(result.get("conch_bound", 0))):
				entries.append({"kind": "rare_pack", "amount": 1})
		else:
			if not bool(context.get("finished", false)): return ERR_INVALID_DATA
			entries = Stone.reward_entries(int(context.total_damage), int(context.floor), rng)
			lines.append("三回合试炼结束 · 累计伤害 %d" % int(context.total_damage))
			if entries.is_empty(): lines.append("未达到最低档，无奖励")
		if rng.last_error != OK: return rng.last_error
		for entry: Dictionary in entries:
			if not _grant(run, entry, lines, fragments):
				_restore(run, before)
				return ERR_INVALID_DATA
	elif result.get("status") == "escaped":
		lines.append("已退出挑战，无奖励")
	else:
		lines.append("挑战失败，无奖励")
	current.erase("pending_outcome")
	current["stage"] = "result"
	current["result"] = "\n".join(lines)
	current["result_fragments"] = fragments
	current["settled_battle_index"] = int(result.battle_index)
	run.inventory_state.events[event_key(request)] = current
	return RunRewards._commit(run, before)

static func retry_settlement(run: Node, request: Dictionary) -> Error:
	if not is_instance_valid(run) or run.current_battle != null: return ERR_BUSY
	var current := _record(run, request)
	if not current.get("pending_outcome") is Dictionary: return ERR_DOES_NOT_EXIST
	return settle(run, current.pending_outcome)

static func _grant(run: Node, entry: Dictionary, lines: Array[String], fragments: Array[String]) -> bool:
	if entry.get("kind") == "silver":
		run.gold += int(entry.amount)
		lines.append("获得%d银币" % int(entry.amount))
		return true
	var kind := str(entry.get("kind", ""))
	if kind not in ["fragment", "potion", "common_pack", "rare_pack"]: return false
	if kind == "fragment" and RelicCatalog.resolve(str(entry.get("fragment_id", ""))) == null: return false
	if kind == "potion" and int(entry.get("potion", -1)) not in range(4): return false
	run.inventory_state.next_item = int(run.inventory_state.next_item) + 1
	var item := {"item_id": "event-combat-%d" % int(run.inventory_state.next_item), "kind": kind}
	if kind == "fragment":
		item["fragment_id"] = str(entry.fragment_id)
		fragments.append(str(entry.fragment_id))
		lines.append("获得典籍残片：" + RelicCatalog.resolve(str(entry.fragment_id)).display_name)
	elif kind == "potion":
		item["potion"] = int(entry.potion)
		lines.append("获得随机药水")
	else:
		item["options"] = []
		item["rerolled"] = false
		lines.append("获得：" + str(RunRewards.NAMES.get(kind, kind)))
	run.items.append(item)
	return true

static func _restore(run: Node, before: Dictionary) -> void:
	run.inventory_state = before.inventory
	run.items = before.items
	run.gold = int(before.gold)
	run.total_silver_earned = int(before.total_silver_earned)

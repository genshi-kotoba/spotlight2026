class_name RunNodeLoot
extends RefCounted
## 宝箱/残堆独立事务。封存奖励不重抽；物资与地图完成经同一存档安装。
const CONFIG_PATH := "res://data/config/node_loot_rewards.json"
const VERSION := 1

static func key(map_id: String, node_id: String) -> String:
	return JSON.stringify([map_id, node_id])

static func record(run: Node, request: Dictionary) -> Dictionary:
	var loot: Dictionary = run.inventory_state.get("node_loot", {}).get(key(str(request.get("map_id", "")), str(request.get("node_id", ""))), {}).duplicate(true)
	# 旧版本已封存但尚未领取的宝箱/残堆也采用新规则；保留原随机主奖励。
	if not loot.is_empty():
		loot.entries = loot.entries.filter(func(entry: Dictionary): return entry.get("kind") != "elixir")
	return loot

static func generate(seed_text: String, map_id: String, node_id: String, floor_index: int, source_kind: String = "chest") -> Dictionary:
	if source_kind not in ["chest", "pile"]: return {}
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not settings is Dictionary or not RunStateMachine._integer_equals(settings.get("version"), VERSION) or not settings.get(source_kind) is Dictionary:
		return {}
	var config: Dictionary = settings[source_kind]
	var alternative := "potion" if source_kind == "chest" else "fragment"
	var weight_key := alternative + "_weight"
	for field: String in ["silver_weight", weight_key, "silver_min", "silver_max"]:
		if RunStateMachine._integer_value(config.get(field)) == null:
			return {}
	if config.silver_weight < 0 or config[weight_key] < 0 or config.silver_weight + config[weight_key] <= 0 \
			or config.silver_min < 1 or config.silver_max < config.silver_min or config.silver_max > 1000000:
		return {}
	var source := SeedRegistry.new(str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	if source.begin_run(seed_text).is_empty(): return {}
	var rng := source.get_stream(RandomDomains.REWARD, [source_kind + "-loot-v1", map_id, node_id])
	if rng == null: return {}
	var kind: Variant = rng.weighted_pick([{"value":"silver", "weight":config.silver_weight}, {"value":alternative, "weight":config[weight_key]}])
	if kind == null: return {}
	var entry := {"id":"node-loot/" + key(map_id, node_id) + "/0", "kind":str(kind), "amount":1}
	if kind == "silver": entry.amount = int(rng.int_range(int(config.silver_min), int(config.silver_max) + 1))
	elif kind == "potion": entry["potion"] = int(rng.int_range(0, RunRandomEvents.POTIONS.size()))
	else:
		entry["fragment_id"] = RelicCatalog.generate(rng)
		if str(entry.fragment_id).is_empty(): return {}
	return {"version":VERSION, "map_id":map_id, "node_id":node_id, "floor_index":floor_index,
		"source":source_kind, "entries":[entry], "claimed":false}

static func open(run: Node, request: Dictionary) -> Error:
	if not _authorized(run, request): return ERR_UNAUTHORIZED
	var existing := record(run, request)
	if not existing.is_empty():
		if not _matches_record(existing, request): return ERR_INVALID_DATA
		return ERR_ALREADY_EXISTS if existing.claimed else OK
	var generated := generate(str(run.main_seed), str(request.map_id), str(request.node_id), int(request.floor_index), str(request.type))
	var address := key(str(request.map_id), str(request.node_id))
	if generated.is_empty() or not valid_records({address:generated}): return ERR_INVALID_DATA
	var before: Dictionary = run.inventory_state.duplicate(true)
	if not run.inventory_state.has("node_loot"): run.inventory_state.node_loot = {}
	run.inventory_state.node_loot[address] = generated
	var error := SaveGateway.save_current()
	if error != OK: run.inventory_state = before
	return error

## 宝箱交互立即领取：生成、发放、账本与地图完成只落盘一次。
## 失败时连首次生成也一同回滚；重试仍由节点种子生成同一份奖励。
static func collect_chest(run: Node, request: Dictionary) -> Error:
	if request.get("type") != "chest" or not _authorized(run, request): return ERR_UNAUTHORIZED
	var before: Dictionary = run.inventory_state.duplicate(true)
	if record(run, request).is_empty():
		var generated := generate(str(run.main_seed), str(request.map_id), str(request.node_id), int(request.floor_index), "chest")
		var address := key(str(request.map_id), str(request.node_id))
		if generated.is_empty() or not valid_records({address:generated}): return ERR_INVALID_DATA
		if not run.inventory_state.has("node_loot"): run.inventory_state.node_loot = {}
		run.inventory_state.node_loot[address] = generated
	var error := claim(run, request)
	if error != OK: run.inventory_state = before
	return error

static func claim(run: Node, request: Dictionary) -> Error:
	if not _authorized(run, request): return ERR_UNAUTHORIZED
	var loot := record(run, request)
	if loot.is_empty(): return ERR_DOES_NOT_EXIST
	if not _matches_record(loot, request): return ERR_INVALID_DATA
	if loot.claimed: return ERR_ALREADY_EXISTS
	var session: RefCounted = EncounterFlow.session
	var before := {"inventory":run.inventory_state.duplicate(true), "items":run.items.duplicate(true),
		"gold":run.gold, "total_silver_earned":run.total_silver_earned, "session":session.capture_state()}
	# Preflight every item before changing anything. A consumed item still has a
	# claimed ledger, so absence from the backpack never permits another award.
	for entry: Dictionary in loot.entries:
		if not RunRewards.item(run, str(entry.id)).is_empty(): return ERR_ALREADY_EXISTS
	for entry: Dictionary in loot.entries:
		if entry.kind == "silver": run.gold += int(entry.amount)
		elif entry.kind == "potion": run.items.append({"item_id":str(entry.id), "kind":"potion", "potion":int(entry.potion)})
		else: run.items.append({"item_id":str(entry.id), "kind":"fragment", "fragment_id":str(entry.fragment_id)})
	loot.claimed = true
	run.inventory_state.node_loot[key(str(request.map_id), str(request.node_id))] = loot
	if not session.resolve_request({"request_id":request.request_id, "status":"completed"}):
		run.inventory_state = before.inventory; run.items = before.items; run.gold = int(before.gold)
		run.total_silver_earned = int(before.total_silver_earned)
		return ERR_INVALID_DATA
	var error := SaveGateway.save_current()
	if error != OK:
		run.inventory_state = before.inventory; run.items = before.items; run.gold = int(before.gold)
		run.total_silver_earned = int(before.total_silver_earned)
		if not _restore_session(before.session): return ERR_INVALID_DATA
	run.state_changed.emit()
	return error

static func cancel(run: Node, request: Dictionary) -> Error:
	if not _authorized(run, request): return ERR_UNAUTHORIZED
	var before: Dictionary = EncounterFlow.session.capture_state()
	if not EncounterFlow.session.resolve_request({"request_id":request.request_id, "status":"cancelled"}): return ERR_INVALID_DATA
	var error := SaveGateway.save_current()
	if error != OK and not _restore_session(before): return ERR_INVALID_DATA
	return error

static func _restore_session(before: Dictionary) -> bool:
	# restore_state deliberately rotates the request token. UI must reread it.
	return EncounterFlow.session.restore_state(before) and EncounterFlow.map_run.store_current(EncounterFlow.session.capture_state())

static func _authorized(run: Node, request: Dictionary) -> bool:
	if not RunRewards._can_edit(run) or not RunRewards.pending(run).is_empty(): return false
	var session: RefCounted = EncounterFlow.session
	var map_run: RefCounted = EncounterFlow.map_run
	if session == null or map_run == null or request.is_empty() or request != session.pending \
			or request.get("type") not in ["chest", "pile"] or request.get("map_id") != session.map_id \
			or session.map_id != run.current_map_id or request.get("seed") != run.main_seed \
			or request.get("floor_index") != map_run.current_floor:
		return false
	var id := str(request.get("node_id", ""))
	return session.nodes.has(id) and session.nodes[id].type == request.type and not session.completed.has(id)

static func _matches_record(loot: Dictionary, request: Dictionary) -> bool:
	return valid_records({key(str(request.map_id), str(request.node_id)):loot}) \
		and loot.source == request.type and loot.floor_index == request.floor_index

static func valid_records(value: Variant) -> bool:
	if not value is Dictionary: return false
	for address: Variant in value:
		var loot: Variant = value[address]
		if not address is String or not loot is Dictionary or not RunStateMachine._integer_equals(loot.get("version"), VERSION) \
				or not loot.get("map_id") is String or str(loot.map_id).is_empty() \
				or not loot.get("node_id") is String or str(loot.node_id).is_empty() \
				or address != key(loot.map_id, loot.node_id) or loot.get("source") not in ["chest", "pile"] \
				or not loot.get("claimed") is bool or not loot.get("entries") is Array or loot.entries.size() not in [1, 2]:
			return false
		if loot.entries.size() == 2:
			var extra: Variant = loot.entries[1]
			if not extra is Dictionary or extra.get("id") != "node-loot/" + str(address) + "/elixir" or extra.get("kind") != "elixir" or not RunStateMachine._integer_equals(extra.get("amount"), 2): return false
		var floor_index: Variant = RunStateMachine._integer_value(loot.get("floor_index"))
		if floor_index == null or floor_index < 1 or floor_index > 20: return false
		var entry: Variant = loot.entries[0]
		if not entry is Dictionary or entry.get("id") != "node-loot/" + str(address) + "/0" \
				or entry.get("kind") not in (["silver", "potion"] if loot.source == "chest" else ["silver", "fragment"]):
			return false
		var amount: Variant = RunStateMachine._integer_value(entry.get("amount"))
		if amount == null or amount < 1 or amount > 1000000: return false
		if entry.kind == "potion":
			var potion: Variant = RunStateMachine._integer_value(entry.get("potion"))
			if amount != 1 or potion == null or potion < 0 or potion >= RunRandomEvents.POTIONS.size(): return false
		elif entry.kind == "fragment":
			if amount != 1 or not entry.get("fragment_id") is String or RelicCatalog.resolve(entry.fragment_id) == null: return false
	return true

static func valid_map_records(value: Dictionary, floors: Array) -> bool:
	if not valid_records(value): return false
	for loot: Dictionary in value.values():
		var matched := false
		for floor_record: Dictionary in floors:
			var snapshot: Dictionary = floor_record.snapshot
			if snapshot.map_id != loot.map_id: continue
			if floor_record.floor_index != loot.floor_index: return false
			for node: Dictionary in snapshot.nodes:
				if node.id != loot.node_id: continue
				if node.type != loot.source or bool(loot.claimed) != floor_record.state.completed.has(loot.node_id): return false
				matched = true
			break
		if not matched: return false
	return true

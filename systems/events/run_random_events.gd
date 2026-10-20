class_name RunRandomEvents
extends RefCounted
## 节点事务：选择、选牌、奖励展示均持久化，重进不重抽、不重复发奖。
const Sandbox = preload("res://systems/testing/sandbox_resources.gd")
const Upgrade = preload("res://systems/events/material_upgrade_event.gd")
const EventCombat = preload("res://systems/events/event_combat_flow.gd")
const POTIONS := ["抽两张牌", "获得5点格挡", "复制一张手牌", "本回合增加一个牌位"]

static func key(request: Dictionary) -> String:
	return str(request.get("map_id", "")) + "/" + str(request.get("node_id", ""))

static func valid_events(value: Variant) -> bool:
	if not value is Dictionary: return false
	for id: Variant in value:
		var current: Variant = value[id]
		if not id is String or not current is Dictionary: return false
		var index: Variant = RunStateMachine._integer_value(current.get("index"))
		var plays: Variant = RunStateMachine._integer_value(current.get("plays"))
		if index == null or index < 0 or index >= 12 or plays == null or plays < 0 or plays > 3: return false
		if current.get("stage") not in ["choice", "inputs", "reward", "battle", "result", "done"] or not current.get("result") is String or not current.get("finished") is bool: return false
		if bool(current.finished) != (current.stage == "done"): return false
		if not RunStateMachine._string_array_valid(current.get("inputs")) or not RunStateMachine._unique_string_array_valid(current.get("offers")): return false
		if current.stage == "battle":
			var battle_index: Variant = RunStateMachine._integer_value(current.get("event_battle_index"))
			if int(index) not in [5, 6] or battle_index == null or battle_index < 0: return false
			if current.has("pending_outcome"):
				var outcome: Variant = current.pending_outcome
				if not outcome is Dictionary or not EventCombat.is_result(outcome) or outcome.get("battle_index") != battle_index: return false
		if int(index) == 10:
			if current.has("upgrade_offers"):
				if not current.get("upgrade_input_id") is String or current.get("upgrade_source_kind") not in ["common_pack", "potion", "fragment"]: return false
				if not Upgrade.valid_offers(current.upgrade_offers, str(current.upgrade_source_kind), str(current.upgrade_input_id)): return false
				if current.offers != current.upgrade_offers.map(func(offer: Dictionary): return str(offer.id)): return false
			elif current.stage == "reward": return false
		if int(index) == 8:
			for offer: String in current.offers:
				if RelicCatalog.resolve(offer) == null: return false
		if current.has("result_fragments"):
			if not current.result_fragments is Array: return false
			for fragment: Variant in current.result_fragments:
				if not fragment is String or RelicCatalog.resolve(fragment) == null: return false
	return true

static func state(run: Node, request: Dictionary) -> Dictionary:
	return run.inventory_state.get("events", {}).get(key(request), {}).duplicate(true)

static func open(run: Node, request: Dictionary) -> Error:
	if not authorized(run, request): return ERR_UNAUTHORIZED
	var event_index := RandomEventCatalog.index_for_map_node(str(run.main_seed), str(request.map_id), request)
	run.inventory_state["settlement_context"] = {
		"location_name": RandomEventCatalog.NAMES[event_index],
		"background_path": preload("res://ui/battle/battle_environment.gd").path_for_floor(preload("res://ui/battle/battle_environment.gd").floor_for_battle({}, str(request.get("map_id", "")))),
	}
	var existing := state(run, request)
	if not existing.is_empty():
		if not _retryable_sandbox_exit(run, existing): return OK
		event_index = int(existing.index)
	var before := capture(run)
	if not run.inventory_state.has("events"): run.inventory_state.events = {}
	run.inventory_state.events[key(request)] = {"index": event_index,
		"stage": "choice", "plays": 0, "inputs": [], "offers": [], "result": "", "finished": false}
	return commit(run, before)

## 测试地图允许重新打开直接离开、未执行的事件；有抽取、奖励或战斗记录的不重置。
static func _retryable_sandbox_exit(run: Node, current: Dictionary) -> bool:
	var index := int(current.get("index", -1))
	return Sandbox.active(run) and index >= 0 and index < RandomEventCatalog.NAMES.size() \
		and int(current.get("plays", 0)) == 0 \
		and current.get("stage") == "done" and current.get("result") == "已离开，无奖励" \
		and current.get("inputs", []).is_empty() and current.get("offers", []).is_empty() \
		and current.get("result_fragments", []).is_empty() \
		and not current.has("event_battle_index") and not current.has("settled_battle_index") \
		and not current.has("pending_outcome")

static func authorized(run: Node, request: Dictionary) -> bool:
	var session: RefCounted = EncounterFlow.session
	return RunRewards._can_edit(run) and RunRewards.pending(run).is_empty() and session != null \
		and request.get("type") == "event" and request == session.pending and str(request.get("map_id")) == session.map_id

static func selectables(run: Node, request: Dictionary) -> Array:
	var current := state(run, request)
	var result: Array = []
	if current.is_empty(): return result
	if int(current.index) == 10:
		if current.stage == "reward":
			for offer: Dictionary in current.get("upgrade_offers", []):
				result.append({"id": str(offer.id), "label": Upgrade.label(offer)})
		else:
			result.assign(Upgrade.candidates(run))
		return result
	if current.stage == "reward":
		for id: String in current.offers:
			var label := id
			if int(current.index) == 8:
				var data: RelicFragmentData = RelicCatalog.resolve(id)
				if data != null: label = data.display_name + "\n" + data.description
			else:
				var card := TextCatalog.entry("cards", id)
				label = str(card.get("name", id)) + "\n" + str(card.get("effect", ""))
			var entry := {"id": id, "label": label}
			if int(current.index) == 8 and RelicCatalog.resolve(id) != null: entry["rich_label"] = RelicCatalog.resolve(id).rich_text()
			result.append(entry)
	elif int(current.index) == 8:
		var catalog := RelicCatalog.load_definitions()
		for cell in RelicBoard.CELL_COUNT:
			var id := str(run.inventory_state.relic_board.cells[cell])
			if not id.is_empty():
				var data := RelicCatalog.resolve(id, catalog)
				if data != null: result.append({"id": "cell:%d" % cell, "label": "已装备：" + data.display_name + "\n" + data.description, "rich_label":"已装备：" + data.rich_text()})
		for item: Variant in run.items:
			if item is Dictionary and item.get("kind") == "fragment":
				var data := RelicCatalog.resolve(str(item.fragment_id), catalog)
				if data != null: result.append({"id": "item:" + str(item.item_id), "label": data.display_name + "\n" + data.description, "rich_label":data.rich_text()})
	else:
		run.ensure_deck_cards()
		for card: Dictionary in run.deck_cards:
			if int(current.index) == 4 and legal_enchants(card).is_empty(): continue
			var data := TextCatalog.entry("cards", str(card.card_id))
			result.append({"id": str(card.copy_id), "label": "#%s %s\n%s" % [card.card_id, data.get("name", "暂无"), CardEnchantments.describe(card)]})
	return result

static func legal_enchants(card: Dictionary) -> Array:
	return CardEnchantments.reward_ids().filter(func(id: Variant): return CardEnchantments.can_apply(card, str(id)))

static func choose(run: Node, request: Dictionary, option: int) -> Error:
	if not authorized(run, request): return ERR_UNAUTHORIZED
	var current := state(run, request)
	if current.is_empty() or current.stage != "choice": return ERR_BUSY
	var index := int(current.index)
	var choices := RandomEventCatalog.choices(index)
	if option < 0 or option >= choices.size(): return ERR_INVALID_PARAMETER
	if index in [5, 6] and option == 0:
		return EventCombat.start(run, request)
	var before := capture(run)
	var rng := RandomEventCatalog.stream(str(run.main_seed), str(request.map_id), str(request.node_id), "choice-%d-%d" % [option, int(current.plays)])
	var result: Array[String] = []
	var error := OK
	if option == choices.size() - 1:
		result.append("已离开，无奖励")
	else:
		match index:
			0:
				error = pay(run, 0, 10 if option == 0 else 20)
				if error == OK:
					give_potion(run, int(rng.int_range(0, 4)), result)
					if option == 1: give(run, "common_pack", result)
			1:
				if option < 2:
					var amount := mini(40 if option == 0 else 20, run.max_health - run.health)
					run.health += amount
					result.append("恢复%d生命" % amount)
					if option == 1: run.gold += 100; result.append("获得100银币")
				else:
					error = pay(run, 0, 20)
					if error == OK: run.gold += 500; result.append("获得500银币")
			2:
				if int(current.plays) >= 3: return ERR_UNAVAILABLE
				error = pay(run, 400, 0)
				if error == OK:
					current.plays = int(current.plays) + 1
					match int(rng.int_range(0, 6)):
						0: give_fragment(run, RelicCatalog.generate(rng), result)
						1: give(run, "common_pack", result)
						2: give(run, "rare_pack", result)
						3: give_potion(run, int(rng.int_range(0, 4)), result)
						4: run.gold += 300; result.append("获得300银币")
						5: run.gold += 500; result.append("获得500银币")
			3:
				error = pay(run, 0, 10 if option == 0 else 20)
				if error == OK:
					if option == 0: give(run, "common_pack", result)
					else: give_fragment(run, RelicCatalog.generate(rng), result)
			4:
				if option == 0: run.gold += 300; result.append("获得300银币")
				else:
					current.stage = "inputs"
					current.option = option
					var eligible := selectables_for_enchant(run)
					if eligible.size() < 2 or run.gold < (200 if option == 1 else 500): return ERR_UNAVAILABLE
					if option == 1:
						rng.shuffle_in_place(eligible)
						current.inputs = eligible.slice(0, 2)
						run.inventory_state.events[key(request)] = current
						return select(run, request, current.inputs, before)
			10:
				if Upgrade.candidates(run).is_empty(): return ERR_UNAVAILABLE
				current.stage = "inputs"
			7:
				if option == 0: add_card(run, "69"); result.append("获得圣杯幻象"); give(run, "rare_pack", result)
				else: run.gold += 100; result.append("获得100银币")
			8, 9:
				current.stage = "inputs"
				if selectables(run_for_state(run, request, current), request).size() < (1 if index == 8 else 2):
					restore(run, before)
					return ERR_UNAVAILABLE
			11:
				if option == 0:
					run.inventory_state["conch_bound"] = int(run.inventory_state.get("conch_bound", 0)) + 1
					result.append("下场战斗：牌位-1；胜利额外获得稀有卡包")
				elif option == 1: give(run, "common_pack", result)
				else:
					var id := RelicCatalog.generate(rng, "", str(rng.pick(RelicCatalog.negative_ids(RelicCatalog.load_definitions()))))
					give_fragment(run, id, result)
	if error != OK: restore(run, before); return error
	if not result.is_empty():
		current.stage = "result"; current.result = "\n".join(result)
		current["result_fragments"] = _new_fragments(run, before)
	run.inventory_state.events[key(request)] = current
	return commit(run, before)

static func run_for_state(run: Node, request: Dictionary, current: Dictionary) -> Node:
	run.inventory_state.events[key(request)] = current
	return run

static func selectables_for_enchant(run: Node) -> Array:
	run.ensure_deck_cards()
	return run.deck_cards.filter(func(c: Dictionary): return not legal_enchants(c).is_empty()).map(func(c: Dictionary): return str(c.copy_id))

static func select(run: Node, request: Dictionary, ids: Array, rollback: Dictionary = {}) -> Error:
	if not authorized(run, request): return ERR_UNAUTHORIZED
	var current := state(run, request)
	if current.stage not in ["inputs", "reward"]: return ERR_BUSY
	if int(current.index) == 10: return _select_upgrade(run, request, current, ids)
	var before := capture(run) if rollback.is_empty() else rollback
	var allowed := selectables(run, request).map(func(e: Dictionary): return str(e.id))
	var unique := {}
	for id: String in ids:
		if not allowed.has(id) or unique.has(id): return ERR_INVALID_PARAMETER
		unique[id] = true
	var index := int(current.index)
	var count := 1 if current.stage == "reward" or index == 8 else 2
	if ids.size() != count: return ERR_INVALID_PARAMETER
	var rng := RandomEventCatalog.stream(str(run.main_seed), str(request.map_id), str(request.node_id), "selection")
	var result: Array[String] = []
	if current.stage == "inputs":
		current.inputs = ids.duplicate()
		if index == 4:
			var error := pay(run, 200 if int(current.option) == 1 else 500, 0)
			if error != OK: restore(run, before); return error
			for card: Dictionary in run.deck_cards:
				if ids.has(str(card.copy_id)):
					var enchant := str(rng.pick(legal_enchants(card)))
					card.enchantments.append(enchant)
					result.append("#%s 获得附魔：%s" % [card.card_id, CardEnchantments.DEFINITIONS[enchant].name])
		else:
			var pool: Array = RelicCatalog.reward_ids() if index == 8 else RunRewards._card_pool("rare_pack" if int(rng.int_range(0, 100)) < 20 else "common_pack")
			if index == 8:
				var consumed := fragment_at(run, str(ids[0]))
				var data := RelicCatalog.resolve(consumed)
				pool = pool.filter(func(id: String) -> bool: return RelicCatalog.resolve(id).kind in [RelicFragmentData.Kind.TRIGGER, RelicFragmentData.Kind.EFFECT])
				if data != null: pool.erase(data.base_fragment_id if not data.base_fragment_id.is_empty() else consumed.get_slice("~", 0))
			rng.shuffle_in_place(pool)
			current.offers = pool.slice(0, mini(pool.size(), 3))
			if index == 8:
				for position in current.offers.size():
					current.offers[position] = RelicCatalog.generate(rng, str(current.offers[position]))
			current.stage = "reward"
	else:
		if index == 8:
			if RelicCatalog.resolve(str(ids[0])) == null: return ERR_INVALID_DATA
			var token := str(current.inputs[0])
			if fragment_at(run, token).is_empty(): return ERR_INVALID_DATA
			if token.begins_with("cell:"): run.inventory_state.relic_board.cells[int(token.trim_prefix("cell:"))] = ""
			else: run.items.remove_at(RunRewards._item_index(run, token.trim_prefix("item:")))
			give_fragment(run, str(ids[0]), result)
		else:
			var removed := 0
			for position in range(run.deck_cards.size() - 1, -1, -1):
				if current.inputs.has(str(run.deck_cards[position].copy_id)): run.remove_card_at(position); removed += 1
			if removed != 2: restore(run, before); return ERR_INVALID_DATA
			add_card(run, str(ids[0])); result.append("合成获得：" + str(TextCatalog.entry("cards", str(ids[0])).get("name", ids[0])))
	if not result.is_empty():
		current.stage = "result"; current.result = "\n".join(result)
		current["result_fragments"] = _new_fragments(run, before)
	run.inventory_state.events[key(request)] = current
	return commit(run, before)


static func _select_upgrade(run: Node, request: Dictionary, current: Dictionary, ids: Array) -> Error:
	if ids.size() != 1 or not ids[0] is String: return ERR_INVALID_PARAMETER
	var before := capture(run)
	var chosen: Dictionary = {}
	if current.stage == "inputs":
		var sources := Upgrade.candidates(run)
		var source: Dictionary = {}
		for entry: Dictionary in sources:
			if entry.id == ids[0]: source = entry
		if source.is_empty(): return ERR_INVALID_PARAMETER
		var rng := RandomEventCatalog.stream(str(run.main_seed), str(request.map_id), str(request.node_id), "upgrade-" + str(ids[0]))
		var offers := Upgrade.offers(run, str(ids[0]), rng)
		if rng.last_error != OK: return rng.last_error
		if not Upgrade.valid_offers(offers, str(source.kind), str(ids[0])): return ERR_INVALID_DATA
		current["inputs"] = ids.duplicate()
		current["upgrade_input_id"] = str(ids[0])
		current["upgrade_source_kind"] = str(source.kind)
		current["upgrade_source_label"] = str(source.label)
		current["upgrade_offers"] = offers
		current["offers"] = offers.map(func(offer: Dictionary): return str(offer.id))
		if offers.size() == 3:
			current.stage = "reward"
			run.inventory_state.events[key(request)] = current
			return commit(run, before)
		chosen = offers[0]
	else:
		if not Upgrade.valid_offers(current.get("upgrade_offers"), str(current.get("upgrade_source_kind", "")), str(current.get("upgrade_input_id", ""))): return ERR_INVALID_DATA
		for offer: Dictionary in current.upgrade_offers:
			if offer.id == ids[0]: chosen = offer
		if chosen.is_empty(): return ERR_INVALID_PARAMETER
	var outcome := Upgrade.apply_choice(run, str(current.upgrade_input_id), chosen)
	if int(outcome.error) != OK: restore(run, before); return int(outcome.error)
	current["stage"] = "result"
	current["result"] = str(outcome.result)
	current["result_fragments"] = outcome.result_fragments
	run.inventory_state.events[key(request)] = current
	return commit(run, before)

static func fragment_at(run: Node, token: String) -> String:
	if token.begins_with("cell:"):
		var cell := int(token.trim_prefix("cell:"))
		var board := RunRewards.board_for_run(run)
		return str(board.cells[cell]) if board.is_unlocked(cell) else ""
	var item := RunRewards.item(run, token.trim_prefix("item:"))
	return str(item.get("fragment_id", ""))

static func acknowledge(run: Node, request: Dictionary, continue_gamble := false) -> Error:
	if not authorized(run, request): return ERR_UNAUTHORIZED
	var current := state(run, request)
	if current.stage != "result": return ERR_BUSY
	var before := capture(run)
	if continue_gamble and int(current.index) == 2 and int(current.plays) < 3:
		current.stage = "choice"
	else:
		current.stage = "done"
		current.finished = true
		RunUpgrades.award_node(run, str(request.map_id), str(request.node_id))
	run.inventory_state.events[key(request)] = current
	return commit(run, before)

static func pay(run: Node, silver: int, life: int) -> Error:
	if run.gold < silver or run.health <= life: return ERR_UNAVAILABLE
	run.gold -= silver
	run.health -= life
	return OK

static func add_card(run: Node, id: String) -> void:
	if not run.card_pool.has(id): run.card_pool.append(id)
	run.add_card(id, false)

static func give(run: Node, kind: String, result: Array[String]) -> void:
	run.inventory_state.next_item = int(run.inventory_state.next_item) + 1
	run.items.append({"item_id": "event-%d" % int(run.inventory_state.next_item), "kind": kind, "options": [], "rerolled": false})
	result.append("获得：" + str(RunRewards.NAMES.get(kind, kind)))

static func give_fragment(run: Node, id: String, result: Array[String]) -> void:
	var data: RelicFragmentData = RelicCatalog.resolve(id)
	if data == null: return
	run.inventory_state.next_item = int(run.inventory_state.next_item) + 1
	run.items.append({"item_id": "event-fragment-%d" % int(run.inventory_state.next_item), "kind": "fragment", "fragment_id": id})
	result.append("获得典籍残片：%s\n%s" % [data.display_name, data.description])

static func _new_fragments(run: Node, before: Dictionary) -> Array[String]:
	var previous := {}
	for item: Variant in before.items:
		if item is Dictionary: previous[str(item.get("item_id", ""))] = true
	var result: Array[String] = []
	for item: Variant in run.items:
		if item is Dictionary and item.get("kind") == "fragment" and not previous.has(str(item.get("item_id", ""))):
			result.append(str(item.fragment_id))
	return result

static func give_potion(run: Node, index: int, result: Array[String]) -> void:
	run.inventory_state.next_item = int(run.inventory_state.next_item) + 1
	run.items.append({"item_id": "event-potion-%d" % int(run.inventory_state.next_item), "kind": "potion", "potion": index})
	result.append("获得药水：" + str(POTIONS[index]))

static func capture(run: Node) -> Dictionary:
	var before := RunRewards._capture(run)
	before["health"] = run.health
	return before

static func restore(run: Node, before: Dictionary) -> void:
	run.inventory_state = before.inventory
	run.items = before.items
	run.gold = int(before.gold)
	run.total_silver_earned = int(before.total_silver_earned)
	run.health = int(before.health)
	run.deck.assign(before.deck)
	run.deck_cards.assign(before.deck_cards)
	run.next_card_serial = int(before.next_card_serial)
	run.card_pool.assign(before.pool)

static func commit(run: Node, before: Dictionary) -> Error:
	var error := SaveGateway.save_current()
	if error != OK: restore(run, before)
	run.state_changed.emit()
	return error

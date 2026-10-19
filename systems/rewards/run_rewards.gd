class_name RunRewards
extends RefCounted
## 战斗奖励与背包唯一业务入口。UI 不直接修改物资；每步原子保存，失败回滚。
const PACKS := ["fragment_pack", "common_pack", "rare_pack", "enchantment_book"]
const NAMES := {"silver": "银币", "elixir": "万灵药", "fragment_pack": "典籍残片包",
	"common_pack": "普通卡牌包", "rare_pack": "稀有卡牌包", "fragment": "典籍残片", "enchantment_book": "附魔书"}

static func ensure_state(run: Node, legacy_path: String = RelicBoard.SAVE_PATH) -> void:
	if not run.inventory_state.is_empty():
		# v1 twelve-slot saves keep all former slots open; only the eight new slots lock.
		var current := RelicBoard.new()
		if run.inventory_state.get("relic_board") is Dictionary and current.restore(run.inventory_state.relic_board, RelicCatalog.load_definitions()) == OK:
			run.inventory_state.relic_board = current.to_dictionary()
		return
	# 仅老存档迁移原典籍。新局已由状态机创建空棋盘，绝不读取测试配置。
	var board := RelicBoard.new()
	board.load_from_file(RelicCatalog.load_definitions(), legacy_path)
	run.inventory_state = {"version": 1, "elixir": 0, "relic_board": board.to_dictionary(),
		"pending_rewards": {}, "rewarded_battles": {}, "next_item": 0}

static func board_for_run(run: Node, legacy_path: String = RelicBoard.SAVE_PATH) -> RelicBoard:
	ensure_state(run, legacy_path)
	var board := RelicBoard.new()
	board.restore(run.inventory_state.relic_board, RelicCatalog.load_definitions())
	return board

static func pending(run: Node) -> Dictionary:
	ensure_state(run)
	return run.inventory_state.pending_rewards.duplicate(true)

static func stage_victory(run: Node, map_id: String, node_id: String, grade: String, battle_index: int) -> Error:
	ensure_state(run)
	if not run.active or grade not in ["普通", "精英", "BOSS"]:
		return ERR_INVALID_PARAMETER
	var key := "%s/%s/%d" % [map_id, node_id, battle_index]
	if run.inventory_state.rewarded_battles.has(key):
		return OK
	if not run.inventory_state.pending_rewards.is_empty():
		return ERR_BUSY
	var entries: Array = [{"id": "silver", "kind": "silver", "amount": 100 if grade == "普通" else 200, "claimed": false}]
	if grade != "普通":
		entries.append({"id": "elixir", "kind": "elixir", "amount": 1, "claimed": false})
	for kind: String in ["fragment_pack", "common_pack"]:
		entries.append({"id": kind, "kind": kind, "amount": 1, "claimed": false})
	if grade != "普通":
		entries.append({"id": "rare_pack", "kind": "rare_pack", "amount": 1, "claimed": false})
		entries.append({"id": "enchantment_book", "kind": "enchantment_book", "amount": 1, "claimed": false})
	run.inventory_state.pending_rewards = {"battle_key": key, "grade": grade, "entries": entries}
	run.inventory_state.rewarded_battles[key] = true
	return OK

static func claim(run: Node, reward_id: String) -> Error:
	if not _can_edit(run):
		return ERR_BUSY
	var rewards := pending(run)
	if rewards.is_empty():
		return ERR_DOES_NOT_EXIST
	var entries: Array = run.inventory_state.pending_rewards.entries.duplicate()
	entries.append_array(run.inventory_state.pending_rewards.get("bonus_entries", []))
	for entry: Dictionary in entries:
		if entry.id != reward_id:
			continue
		if entry.claimed:
			return ERR_ALREADY_EXISTS
		var before := _capture(run)
		match str(entry.kind):
			"silver": run.gold += int(entry.amount)
			"elixir": run.inventory_state.elixir = int(run.inventory_state.elixir) + int(entry.amount)
			_:
				if str(entry.kind) not in PACKS:
					return ERR_INVALID_DATA
				for copy in int(entry.amount):
					run.items.append({"item_id": str(rewards.battle_key) + "/" + str(entry.id) + "/%d" % copy,
						"kind": str(entry.kind), "options": [], "rerolled": false})
		entry.claimed = true
		return _commit(run, before)
	return ERR_DOES_NOT_EXIST

static func finish_rewards(run: Node) -> Error:
	if not _can_edit(run):
		return ERR_BUSY
	var rewards := pending(run)
	if rewards.is_empty():
		return ERR_DOES_NOT_EXIST
	var entries: Array = rewards.entries.duplicate()
	entries.append_array(rewards.get("bonus_entries", []))
	for entry: Dictionary in entries:
		if not entry.claimed:
			return ERR_BUSY
	var before := _capture(run)
	run.inventory_state.pending_rewards = {}
	return _commit(run, before)

static func item(run: Node, item_id: String) -> Dictionary:
	for value: Variant in run.items:
		if value is Dictionary and value.get("item_id") == item_id:
			return value.duplicate(true)
	return {}

static func open_pack(run: Node, item_id: String) -> Error:
	if not _can_edit(run):
		return ERR_BUSY
	var index := _item_index(run, item_id)
	if index < 0 or str(run.items[index].get("kind", "")) not in PACKS:
		return ERR_DOES_NOT_EXIST
	if not run.items[index].options.is_empty():
		return OK
	return _generate_offer(run, index, false)

static func refresh_pack(run: Node, item_id: String) -> Error:
	if not _can_edit(run):
		return ERR_BUSY
	var index := _item_index(run, item_id)
	if index < 0:
		return ERR_DOES_NOT_EXIST
	var pack: Dictionary = run.items[index]
	if str(pack.get("kind", "")) not in ["fragment_pack", "common_pack"] or bool(pack.get("rerolled", false)) or pack.get("options", []).is_empty():
		return ERR_UNAVAILABLE
	return _generate_offer(run, index, true)

static func choose(run: Node, item_id: String, choice: String) -> Error:
	if not _can_edit(run):
		return ERR_BUSY
	var index := _item_index(run, item_id)
	if index < 0:
		return ERR_DOES_NOT_EXIST
	var pack: Dictionary = run.items[index]
	if str(pack.get("kind", "")) not in PACKS or choice not in pack.get("options", []):
		return ERR_INVALID_PARAMETER
	if pack.kind == "enchantment_book":
		return ERR_INVALID_PARAMETER # 书只能在二级页面选中具体副本后消耗。
	var before := _capture(run)
	if pack.kind == "fragment_pack":
		if RelicCatalog.resolve(choice) == null:
			return ERR_DOES_NOT_EXIST
		run.items[index] = {"item_id": item_id + "/fragment", "kind": "fragment", "fragment_id": choice}
	else:
		if not _card_pool(str(pack.kind)).has(choice):
			return ERR_INVALID_DATA
		# 奖励明确赠予本局卡牌；不修改局外解锁表。
		if not run.card_pool.has(choice):
			run.card_pool.append(choice)
		run.add_card(choice, false)
		run.items.remove_at(index)
	return _commit(run, before)

static func enchantment_targets(run: Node, enchantment_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_instance_valid(run): return result
	run.ensure_deck_cards()
	for card: Dictionary in run.deck_cards:
		if CardEnchantments.can_apply(card, enchantment_id): result.append(card.duplicate(true))
	return result

static func apply_book(run: Node, item_id: String, enchantment_id: String, copy_id: String) -> Error:
	if not _can_edit(run): return ERR_BUSY
	var index := _item_index(run, item_id)
	if index < 0: return ERR_DOES_NOT_EXIST
	var book: Dictionary = run.items[index]
	if book.get("kind") != "enchantment_book" or enchantment_id not in book.get("options", []):
		return ERR_INVALID_PARAMETER
	run.ensure_deck_cards()
	for position in run.deck_cards.size():
		var card: Dictionary = run.deck_cards[position]
		if str(card.copy_id) == copy_id and CardEnchantments.can_apply(card, enchantment_id):
			var before := _capture(run)
			# _capture 的旧档同步会重建字典，不能继续修改捕获前的引用。
			run.deck_cards[position].enchantments.append(enchantment_id)
			run.items.remove_at(index)
			return _commit(run, before)
	return ERR_INVALID_PARAMETER

static func equip_fragment(run: Node, item_id: String, cell: int) -> Error:
	if not _can_edit(run) or cell < 0 or cell >= RelicBoard.CELL_COUNT:
		return ERR_INVALID_PARAMETER
	if not board_for_run(run).is_unlocked(cell): return ERR_UNAUTHORIZED
	var index := _item_index(run, item_id)
	if index < 0 or run.items[index].get("kind") != "fragment":
		return ERR_DOES_NOT_EXIST
	if RelicCatalog.resolve(str(run.items[index].get("fragment_id", ""))) == null:
		return ERR_INVALID_DATA
	var before := _capture(run)
	var cells: Array = run.inventory_state.relic_board.cells
	var previous := str(cells[cell])
	cells[cell] = str(run.items[index].fragment_id)
	if previous.is_empty():
		run.items.remove_at(index)
	else:
		run.items[index].fragment_id = previous
	return _commit(run, before)

## 界面换位也使用主线事务，不能把被交换的残片再复制进背包。
static func move_fragment(run: Node, source: int, destination: int) -> Error:
	if not _can_edit(run):
		return ERR_BUSY
	if source < 0 or source >= RelicBoard.CELL_COUNT or destination < 0 or destination >= RelicBoard.CELL_COUNT:
		return ERR_INVALID_PARAMETER
	var board := board_for_run(run)
	if not board.is_unlocked(source) or not board.is_unlocked(destination): return ERR_UNAUTHORIZED
	var cells: Array = run.inventory_state.relic_board.cells
	if str(cells[source]).is_empty():
		return ERR_DOES_NOT_EXIST
	if source == destination:
		return OK
	var before := _capture(run)
	var previous: String = cells[destination]
	cells[destination] = cells[source]
	cells[source] = previous
	return _commit(run, before)


static func unequip_fragment(run: Node, cell: int) -> Error:
	if not _can_edit(run) or cell < 0 or cell >= RelicBoard.CELL_COUNT:
		return ERR_INVALID_PARAMETER
	if not board_for_run(run).is_unlocked(cell): return ERR_UNAUTHORIZED
	var cells: Array = run.inventory_state.relic_board.cells
	if str(cells[cell]).is_empty():
		return ERR_DOES_NOT_EXIST
	var before := _capture(run)
	run.inventory_state.next_item = int(run.inventory_state.next_item) + 1
	run.items.append({"item_id": "unequip-%d" % int(run.inventory_state.next_item), "kind": "fragment", "fragment_id": str(cells[cell])})
	cells[cell] = ""
	return _commit(run, before)

static func _generate_offer(run: Node, index: int, refresh: bool) -> Error:
	var pack: Dictionary = run.items[index]
	var fragment_pack: bool = pack.kind == "fragment_pack"
	var book: bool = pack.kind == "enchantment_book"
	var pool: Array = CardEnchantments.reward_ids() if book else (RelicCatalog.reward_ids() if fragment_pack else _card_pool(str(pack.kind)))
	if fragment_pack:
		pool = pool.filter(func(id: String) -> bool: return RelicCatalog.resolve(id).kind in [RelicFragmentData.Kind.TRIGGER, RelicFragmentData.Kind.EFFECT])
	pool.sort()
	if refresh:
		var previous: Array = []
		for option: String in pack.options:
			var data := RelicCatalog.resolve(option) if fragment_pack else null
			previous.append((data.base_fragment_id if not data.base_fragment_id.is_empty() else data.fragment_id.get_slice("~", 0)) if data != null else option)
		pool = pool.filter(func(id: Variant) -> bool: return id not in previous)
	var count := 2 if pack.kind == "fragment_pack" else 3
	if pool.size() < count:
		return ERR_UNAVAILABLE
	# 按主种子与包身份派生一次性子上下文，开包顺序、失败重试不消费其他随机流。
	var source := SeedRegistry.new(str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	source.begin_run(str(run.main_seed))
	var stream := source.get_stream(RandomDomains.REWARD, ["pack", str(pack.item_id), 1 if refresh else 0])
	if stream == null or stream.shuffle_in_place(pool) != OK:
		return ERR_UNCONFIGURED
	var before := _capture(run)
	var options: Array = pool.slice(0, count)
	if fragment_pack:
		for option in options.size():
			options[option] = RelicCatalog.generate(stream, str(options[option]))
			if str(options[option]).is_empty(): return ERR_INVALID_DATA
	pack.options = options
	pack.rerolled = refresh
	return _commit(run, before)


static func valid_items(values: Variant) -> bool:
	if not values is Array: return false
	var seen_ids := {}
	for item: Variant in values:
		if not item is Dictionary: continue # Historical non-fragment inventory remains compatible.
		if item.get("kind") in ["fragment", "fragment_pack", "enchantment_book"]:
			if not item.get("item_id") is String or item.item_id.is_empty() or seen_ids.has(item.item_id): return false
			seen_ids[item.item_id] = true
		if item.get("kind") == "fragment":
			if not item.get("fragment_id") is String or RelicCatalog.resolve(item.fragment_id) == null: return false
		elif item.get("kind") == "fragment_pack":
			if not item.get("options") is Array or not item.get("rerolled") is bool: return false
			var seen := {}
			for option: Variant in item.options:
				if not option is String or RelicCatalog.resolve(option) == null or seen.has(option): return false
				seen[option] = true
		elif item.get("kind") == "enchantment_book":
			if not item.get("options") is Array or item.get("rerolled") != false or item.options.size() not in [0, 3]: return false
			var seen := {}
			for option: Variant in item.options:
				if not option is String or option not in CardEnchantments.reward_ids() or seen.has(option): return false
				seen[option] = true
	return true

static func _card_pool(kind: String) -> Array[String]:
	var result: Array[String] = []
	for entry: Dictionary in TextCatalog.entries("cards"):
		if str(entry.rarity) == ("稀有" if kind == "rare_pack" else "普通"):
			result.append(str(entry.id))
	return result

static func _item_index(run: Node, item_id: String) -> int:
	for index in run.items.size():
		if run.items[index] is Dictionary and run.items[index].get("item_id") == item_id:
			return index
	return -1

static func _can_edit(run: Node) -> bool:
	if not is_instance_valid(run) or not run.active or run.current_battle != null or run != SaveGateway.current_run():
		return false
	ensure_state(run)
	return true

static func _capture(run: Node) -> Dictionary:
	run.ensure_deck_cards()
	return {"inventory": run.inventory_state.duplicate(true), "items": run.items.duplicate(true),
		"gold": run.gold, "total_silver_earned": run.total_silver_earned, "deck": run.deck.duplicate(), "pool": run.card_pool.duplicate(),
		"deck_cards": run.deck_cards.duplicate(true), "next_card_serial": run.next_card_serial}

static func _commit(run: Node, before: Dictionary) -> Error:
	var error := SaveGateway.save_current()
	if error != OK:
		run.inventory_state = before.inventory
		run.items = before.items
		run.gold = int(before.gold)
		run.total_silver_earned = int(before.total_silver_earned)
		run.deck.assign(before.deck)
		run.deck_cards.assign(before.deck_cards)
		run.next_card_serial = int(before.next_card_serial)
		run.card_pool.assign(before.pool)
	run.state_changed.emit()
	return error

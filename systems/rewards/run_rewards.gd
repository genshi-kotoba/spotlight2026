class_name RunRewards
extends RefCounted
## 战斗奖励与背包唯一业务入口。UI 不直接修改物资；每步原子保存，失败回滚。
const PACKS := ["fragment_pack", "common_pack", "rare_pack"]
const NAMES := {"silver": "银币", "elixir": "万灵药", "fragment_pack": "典籍残片包",
	"common_pack": "普通卡牌包", "rare_pack": "稀有卡牌包", "fragment": "典籍残片"}

static func ensure_state(run: Node, legacy_path: String = RelicBoard.SAVE_PATH) -> void:
	if not run.inventory_state.is_empty():
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
	var before := _capture(run)
	if pack.kind == "fragment_pack":
		if not RelicCatalog.load_definitions().has(choice):
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

static func equip_fragment(run: Node, item_id: String, cell: int) -> Error:
	if not _can_edit(run) or cell < 0 or cell >= RelicBoard.CELL_COUNT:
		return ERR_INVALID_PARAMETER
	var index := _item_index(run, item_id)
	if index < 0 or run.items[index].get("kind") != "fragment":
		return ERR_DOES_NOT_EXIST
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
	var pool: Array = RelicCatalog.reward_ids() if pack.kind == "fragment_pack" else _card_pool(str(pack.kind))
	pool.sort()
	if refresh:
		pool = pool.filter(func(id: Variant) -> bool: return id not in pack.options)
	var count := 2 if pack.kind == "fragment_pack" else 3
	count += RelicCatalog.choice_bonus(run.inventory_state.relic_board.cells)
	if pool.size() < count:
		return ERR_UNAVAILABLE
	# 按主种子与包身份派生一次性子上下文，开包顺序、失败重试不消费其他随机流。
	var source := SeedRegistry.new(str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	source.begin_run(str(run.main_seed))
	var stream := source.get_stream(RandomDomains.REWARD, ["pack", str(pack.item_id), 1 if refresh else 0])
	if stream == null or stream.shuffle_in_place(pool) != OK:
		return ERR_UNCONFIGURED
	var before := _capture(run)
	pack.options = pool.slice(0, count)
	pack.rerolled = refresh
	return _commit(run, before)

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
		"gold": run.gold, "deck": run.deck.duplicate(), "pool": run.card_pool.duplicate(),
		"deck_cards": run.deck_cards.duplicate(true), "next_card_serial": run.next_card_serial}

static func _commit(run: Node, before: Dictionary) -> Error:
	var error := SaveGateway.save_current()
	if error != OK:
		run.inventory_state = before.inventory
		run.items = before.items
		run.gold = int(before.gold)
		run.deck.assign(before.deck)
		run.deck_cards.assign(before.deck_cards)
		run.next_card_serial = int(before.next_card_serial)
		run.card_pool.assign(before.pool)
	run.state_changed.emit()
	return error

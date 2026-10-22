class_name RunUpgrades
extends RefCounted
## 局内升级使用原子保存，不影响其他局的存档。
const PLAY_COSTS := [2, 5, 6, 9, 11]
const RELIC_GROUPS := [
	{"cells": [3, 7], "cost": 4},
	{"cells": [11, 14, 15], "cost": 8},
	{"cells": [12, 13, 16], "cost": 8},
	{"cells": [17, 18, 19], "cost": 4},
]

static func play_level(run: Node) -> int:
	return int(run.inventory_state.get("play_slot_upgrades", 0))

static func play_cost(run: Node) -> int:
	var level := play_level(run)
	return int(PLAY_COSTS[level]) if level < PLAY_COSTS.size() else -1

static func can_upgrade(run: Node) -> bool:
	if not RunRewards._can_edit(run) or not RunRewards.pending(run).is_empty(): return false
	# 已展开的选包不能被另一条修改构筑的事务绕过。
	for item: Variant in run.items:
		if item is Dictionary and item.get("kind") in RunRewards.PACKS and not item.get("options", []).is_empty(): return false
	return true

static func buy_play_slot(run: Node) -> Error:
	if not can_upgrade(run): return ERR_BUSY
	var cost := play_cost(run)
	if cost < 0 or int(run.inventory_state.elixir) < cost: return ERR_UNAVAILABLE
	var before := RunRewards._capture(run)
	run.inventory_state.elixir = int(run.inventory_state.elixir) - cost
	run.inventory_state["play_slot_upgrades"] = play_level(run) + 1
	return RunRewards._commit(run, before)

static func relic_group(index: int) -> Dictionary:
	for group: Dictionary in RELIC_GROUPS:
		if index in group.cells: return group.duplicate(true)
	return {}

static func buy_relic_group(run: Node, index: int) -> Error:
	if not can_upgrade(run): return ERR_BUSY
	var group := relic_group(index)
	if group.is_empty(): return ERR_INVALID_PARAMETER
	var board := RunRewards.board_for_run(run)
	if board.is_unlocked(index): return ERR_ALREADY_EXISTS
	if int(run.inventory_state.elixir) < int(group.cost): return ERR_UNAVAILABLE
	var before := RunRewards._capture(run)
	run.inventory_state.elixir = int(run.inventory_state.elixir) - int(group.cost)
	for cell: int in group.cells: board.unlock_cell(cell)
	run.inventory_state.relic_board = board.to_dictionary()
	return RunRewards._commit(run, before)

static func valid_state(data: Dictionary) -> bool:
	var level: Variant = RunStateMachine._integer_value(data.get("play_slot_upgrades", 0))
	if level == null or level < 0 or level > PLAY_COSTS.size(): return false
	# 只兼容读取旧赠药账本，当前版本不再生成或发放非战斗结点万灵药。
	var ledger: Variant = data.get("node_elixir_rewards", {})
	if not ledger is Dictionary: return false
	for key: Variant in ledger:
		if not key is String or ledger[key] != true: return false
	return true


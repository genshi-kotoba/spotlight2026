extends RefCounted

## 固定测试地图专用货币。以 1000 银币参与余额相关效果，支付不会扣减。
const RESERVE := 1000


static func active(run: Node) -> bool:
	if run == null:
		return false
	var inventory: Variant = run.get("inventory_state")
	var run_id: Variant = run.get("run_id")
	return inventory is Dictionary and inventory.get("fixed_test_sandbox", 0) == 1 \
		and run_id is String and run_id.begins_with("sandbox-")


static func refill(run: Node) -> void:
	if not active(run):
		return
	run.gold = RESERVE
	run.inventory_state["elixir"] = RESERVE
	var battle: Node = run.get("current_battle")
	if is_instance_valid(battle):
		var player: Variant = battle.get("player")
		if player is Dictionary:
			player["silver"] = RESERVE


static func text(value: int, run: Node = null) -> String:
	return "∞" if active(run) else str(value)

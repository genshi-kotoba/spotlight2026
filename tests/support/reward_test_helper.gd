extends RefCounted
## 集成回归在验证完奖励后领取再离场；不绕过正式领奖业务。
static func collect(tree: SceneTree) -> void:
	var active_scene := tree.current_scene as BattleTestScene
	if active_scene != null:
		await preload("res://tests/support/presentation_test_helper.gd").battle_settled(active_scene)
	for index in 12:
		await tree.process_frame
	var scene: Node = tree.current_scene
	var popup: LootPopup = scene.get("_reward_popup")
	if not is_instance_valid(popup):
		return
	for entry: Dictionary in RunRewards.pending(SaveGateway.current_run()).get("entries", []):
		if not entry.claimed:
			popup._claim(str(entry.id))
	popup._continue()
	for index in 8:
		await tree.process_frame
	await preload("res://tests/support/presentation_test_helper.gd").map_ready(tree)

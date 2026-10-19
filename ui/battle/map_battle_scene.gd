extends BattleTestScene
## 正式节点入口复用已有卡牌、动画、事件队列；不创建第二场测试战斗。
var _leaving := false
var _opening := false
var _opening_resolved := false
var _opening_result: AcceptDialog
var _reward_popup: LootPopup

func _battle_environment_floor() -> int:
	return BATTLE_ENVIRONMENT.floor_for_battle(_battle.player, _battle.map_id)

func _ready() -> void:
	var run := SaveGateway.current_run()
	if run == null or run.current_battle == null:
		# 此场景必须从地图进入；单独 F6 时回菜单，不留下可点击的空战斗。
		SceneTransition.call_deferred("change_scene_to_file", MENU_SCENE)
		return
	super._ready()

func _start_test_battle() -> void:
	var run := SaveGateway.current_run()
	if run == null or run.current_battle == null:
		hint_label.text = "没有待恢复的节点战斗，请返回主菜单继续冒险。"
		return
	_battle = run.current_battle
	_battle.set_meta("presentation_owner", self)
	var rules: Dictionary = _battle.player.get("encounter_rules", EncounterFlow.test_rules)
	initial_draw_count = int(rules.initial_draw_count)
	per_turn_draw_count = int(rules.per_turn_draw_count)
	play_limit = int(rules.play_limit)
	for child: Node in _battle.get_children():
		if child is BattleEffectResolver:
			_resolver = child
		elif child is RelicBattleSystem:
			_relics = child
	_battle.turn_started.connect(_on_turn_started)
	_battle.card_resolved.connect(_on_card_resolved)
	_connect_combat_feedback()
	_battle.discard_choice_requested.connect(_on_discard_choice_requested)
	_battle.pile_choice_requested.connect(_on_pile_choice_requested)
	_battle.battle_ended.connect(_on_battle_ended)
	_relic_catalog = RelicCatalog.load_definitions()
	var error := _relic_board.restore(_battle.player.encounter_relic_board, _relic_catalog)
	if error == OK and _relics == null:
		_relics = RelicBattleSystem.new()
		_battle.add_child(_relics)
		error = _relics.attach_to_battle(_battle, _relic_board, _relic_catalog, _resolver.buff_catalog)
	if error == OK:
		_relics.fragment_activated.connect(_on_relic_activated)
		_relics.chain_limited.connect(_on_relic_chain_limited)
		_refresh_relic_hud()
		if _relic_board.cells.count("") == RelicBoard.CELL_COUNT:
			_relic_log.text = "尚未安装残片。战斗胜利后可领取残片包，在背包中打开并安装。"
	_relic_edit_button.hide()
	_restart_button.hide()
	var enemy: Dictionary = _battle.enemies[0]
	$EnemyPortrait.texture = TextCatalogService.art_texture(str(enemy.art_path))
	$EnemyName.text = str(enemy.name)
	var frame_name: String = {"普通": "小怪", "精英": "精英", "BOSS": "boss"}.get(str(enemy.get("grade", "")), "boss")
	$EnemyHPBar/Frame.texture = load("res://assets/ui/UI-015/超长-%s血条框.png" % frame_name)
	$IntentValue.text = str(enemy.actions[0].get("damage", 0))
	if error != OK:
		hint_label.text = "节点战斗初始化失败：%d" % error
		_busy = true
		return
	if _battle.phase == BattleStateMachine.Phase.IDLE:
		# 先把敌人、典籍与牌堆呈现出来，再经原有队列开始首回合。
		# 开局效果若导致终局，也不能在首帧绘制前退图而像“交互无反应”。
		_opening = true
		_busy = true
		call_deferred("_begin_opening")
	_queue_refresh()

func is_scene_transition_ready() -> bool:
	return not _opening and not _refresh_queued

func _begin_opening() -> void:
	await get_tree().process_frame
	# 无窗口回归不产生绘制信号；图形模式则确保开局效果前已显示战场。
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	if not is_inside_tree():
		return
	var error := _battle.start_battle()
	if error == OK and _battle.active:
		error = _battle.draw_cards(_relics.natural_draw_count(initial_draw_count), BattleStateMachine.DrawReason.BATTLE_START)
	_opening = false
	_busy = false
	if error != OK:
		_busy = true
		hint_label.text = "节点战斗开局失败：%d" % error
		return
	if _battle.active:
		hint_label.text = "玩家回合开始：请选择手牌编排到右侧"
	_queue_refresh()
	if _opening_resolved:
		call_deferred("_show_opening_result")
	elif SaveGateway.save_current() != OK:
		hint_label.text = "战斗已开始，但自动保存失败，请退出前重试保存。"

func _on_battle_ended(result: Dictionary) -> void:
	super._on_battle_ended(result)
	if _opening:
		_opening_resolved = true
		return
	call_deferred("_leave_after_resolution")

func _show_opening_result() -> void:
	if _opening_result != null:
		return
	_opening_result = AcceptDialog.new()
	_opening_result.name = "OpeningBattleResult"
	var victory := _battle_result == "victory"
	_opening_result.title = "战斗胜利 · 开局结算" if victory else "战斗结束 · 开局结算"
	_opening_result.dialog_text = "开局回合与抽牌效果已通过事件队列结算。\n典籍生效 %d 次；%s 生命 %d / %d。\n%s\n%s" % [
		_relics.activation_count, str(_battle.enemies[0].name),
		int(_battle.enemies[0].health), int(_battle.enemies[0].max_health),
		"敌人在手动出牌前已被击败，无需再出牌。" if victory else "玩家在开局效果结算中被击败。",
		"节点进度已保存，确认后返回地图。" if EncounterFlow.last_error.is_empty() else EncounterFlow.last_error,
	]
	_opening_result.ok_button_text = "返回地图" if victory else "返回开始界面"
	_opening_result.dialog_close_on_escape = false
	_opening_result.confirmed.connect(_leave_after_resolution, CONNECT_DEFERRED)
	_opening_result.canceled.connect(_leave_after_resolution, CONNECT_DEFERRED)
	add_child(_opening_result)
	_opening_result.popup_centered(Vector2i(640, 240))

func _leave_after_resolution() -> void:
	if _leaving:
		return
	_leaving = true
	# 逻辑已同步结算，等待既有UI播放完最后一张牌，避免销毁正在发信号的对象。
	while _busy or _animating:
		await get_tree().process_frame
	if not EncounterFlow.last_error.is_empty():
		hint_label.text = EncounterFlow.last_error
		_leaving = false
		return
	var run := SaveGateway.current_run()
	if _battle_result == "victory" and run != null and not RunRewards.pending(run).is_empty():
		_reward_popup = LootPopup.new()
		add_child(_reward_popup)
		_reward_popup.finished.connect(_return_after_rewards, CONNECT_DEFERRED)
		_reward_popup.show_rewards()
		hint_label.text = "战斗胜利，请领取奖励后继续探索。"
		return
	_return_after_rewards()

func _return_after_rewards() -> void:
	var path := EncounterFlow.MAP_SCENE if _battle_result in ["victory", "escaped"] else MENU_SCENE
	var error := SceneTransition.change_scene_to_file(path)
	if error != OK:
		_leaving = false
		hint_label.text = "返回场景失败：%d" % error

func _map_snapshot_data() -> Dictionary:
	# 战斗地图仍使用同一份探索视图，不泄露未探索区域或其他节点敌人。
	return EncounterFlow.map_view_data()

func _refresh_header() -> void:
	super._refresh_header()
	_relic_edit_button.hide()
	_restart_button.hide()
	if is_instance_valid(_reward_popup):
		hint_label.text = "战斗胜利，请领取奖励后继续探索。"
	elif _opening:
		phase_label.text = "进入战斗 · 开局结算"
		hint_label.text = "正在准备首回合与抽牌……"
	elif is_instance_valid(_battle) and not _battle.active:
		if _opening_resolved and not _leaving:
			hint_label.text = "开局效果已结束战斗，请确认结算结果后返回。"
		else:
			hint_label.text = "战斗胜利，正在返回地图……" if _battle_result == "victory" else "战斗结束，正在返回开始界面……"

func _exit_tree() -> void:
	# 未结束的战斗由 RunStateMachine 持有；保存返回菜单不会重开或重新抽牌。
	if is_instance_valid(_battle):
		_battle.remove_meta("presentation_owner")

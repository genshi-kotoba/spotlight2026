extends Node
## 地图→战斗→节点结算的装配层。地形、战斗效果和持久化仍由原系统负责。
const Session = preload("res://systems/map/flat_2d/planar_map_session.gd")
const RulesPath := "res://data/config/encounter_test_rules.json"
const BATTLE_SCENE := "res://ui/battle/map_battle_scene.tscn"
const MAP_SCENE := "res://ui/main_menu/menu_map_entry.tscn"
const TOTAL_FLOORS := 4
const IMPLEMENTED_FLOORS := 3
var map_run: RefCounted
var session: RefCounted
var run: RunStateMachine
var last_error := ""
var test_rules: Dictionary = {}
var relic_board_path := RelicBoard.SAVE_PATH

func _ready() -> void:
	test_rules = JSON.parse_string(FileAccess.get_file_as_string(RulesPath))

func bind_map(view: Node) -> bool:
	last_error = ""
	var current := SaveGateway.current_run()
	if current == null or view.map_run == null or view.map_run.current_floor <= 0:
		return _fail("没有可用的局内地图")
	if is_instance_valid(run) and run != current and run.battle_finished.is_connected(_on_battle_finished):
		run.battle_finished.disconnect(_on_battle_finished)
	run = current
	RunRewards.ensure_state(run, relic_board_path)
	map_run = view.map_run
	session = view.session
	if not run.battle_finished.is_connected(_on_battle_finished):
		run.battle_finished.connect(_on_battle_finished)
	SaveGateway.bind_map_view(self)
	if run.current_battle != null:
		if not _matches_battle(run.current_battle):
			return _fail("战斗存档与待结算地图节点不一致")
		call_deferred("open_battle")
	elif not session.pending.is_empty() and session.pending.type in ["battle", "elite", "boss"]:
		# 崩溃发生在地图请求已落盘、战斗尚未创建之间时，继续同一个节点。
		call_deferred("begin_encounter", session.pending.duplicate(true))
	elif _boss_completed():
		# 兼容旧版已用 demo 完成本层 Boss 的检查点。
		if not _advance_after_boss():
			return false
	_preload_floor(session.get_snapshot())
	return true

func _preload_floor(snapshot: Dictionary) -> void:
	var monsters := {}
	for node: Dictionary in snapshot.get("nodes", []):
		if node.type in ["battle", "elite", "boss"]:
			monsters[str(node.content_id)] = map_run.monster_definition(str(node.content_id))
	ScenePreloader.prepare_map(snapshot, run.run_id, monsters)

func begin_encounter(request: Dictionary) -> bool:
	last_error = ""
	if not is_instance_valid(run) or not run.active or run.current_battle != null \
			or session == null or session.pending.is_empty() \
			or request.get("request_id") != session.pending.request_id \
			or request.get("type") not in ["battle", "elite", "boss"]:
		return _fail("战斗节点请求已失效或有战斗进行中")
	if not RunRewards.pending(run).is_empty():
		return _fail("请先领取上一场战斗的奖励")
	var monster: Dictionary = map_run.monster_definition(str(session.pending.content_id))
	if monster.is_empty():
		return _fail("节点没有有效的已分配怪物")
	# 先预检典籍，失败时不留下缺少配置的半初始化战斗。
	var board := RelicBoard.new()
	var catalog := RelicCatalog.load_definitions()
	var board_error := board.restore(run.inventory_state.relic_board, catalog)
	if board_error != OK:
		return _fail("读取典籍配置失败：%d" % board_error)
	var enemy := MonsterCatalog.create(str(monster.id), map_run.current_floor)
	if enemy.is_empty(): return _fail("未找到怪物正式战斗配置：" + str(monster.id))
	enemy.grade = monster.grade
	# 只在原牌组为空时使用临时联调牌，不改变正式牌组或任何解锁状态。
	var temporary: Array = test_rules.empty_deck_fallback if run.deck.is_empty() else []
	var error := run.start_battle(str(session.pending.node_id), [enemy], 0, false,
		int(test_rules.play_limit), false, temporary)
	if error != OK:
		return _fail("创建节点战斗失败：%d" % error)
	var battle := run.current_battle
	# 固定本场战场外观，随战斗快照保存；Boss 推进楼层不影响旧战场。
	battle.player["encounter_floor"] = map_run.current_floor
	battle.player["encounter_rules"] = test_rules.duplicate(true)
	battle.player["temporary_deck"] = run.deck.is_empty()
	battle.player["conch_bound"] = int(run.inventory_state.get("conch_bound", 0))
	battle.player["potions"] = run.items.filter(func(value: Variant): return value is Dictionary and value.get("kind") == "potion").duplicate(true)
	# 棋盘跟随本场战斗保存；回菜单或冷恢复时不会重复施加首回合效果。
	battle.player["encounter_relic_board"] = board.to_dictionary()
	if SaveGateway.save_current() != OK:
		return _fail("进入战斗前保存失败，请重试")
	call_deferred("open_battle")
	return true

func open_battle() -> void:
	if is_instance_valid(run) and run == SaveGateway.current_run() and run.current_battle != null:
		var error := SceneTransition.change_scene_to_file(BATTLE_SCENE)
		if error != OK:
			_fail("打开战斗界面失败：%d" % error)

func _matches_battle(battle: BattleStateMachine) -> bool:
	return session != null and not session.pending.is_empty() \
		and battle.enemies.size() >= 1 and session.pending.type in ["battle", "elite", "boss"] \
		and session.pending.node_id == battle.node_id and session.map_id == battle.map_id \
		and session.pending.content_id == battle.enemies[0].enemy_id

func _on_battle_finished(result: Dictionary) -> void:
	if session == null or session.pending.is_empty() or result.get("map_id") != session.map_id \
			or result.get("node_id") != session.pending.node_id:
		_fail("拒绝不属于当前地图节点的战斗结果")
		return
	var pending: Dictionary = session.pending.duplicate(true)
	var victory: bool = result.get("status") == "victory"
	var completed: bool = victory or result.get("status") == "escaped"
	if not session.resolve_request({"request_id": pending.request_id, "status": "completed" if completed else "failed"}):
		_fail(session.last_error)
		return
	if not map_run.store_current(session.capture_state()):
		_fail(map_run.last_error)
		return
	var completed_state: Dictionary = session.capture_state()
	if victory:
		var monster: Dictionary = map_run.monster_definition(str(pending.content_id))
		var reward_error := RunRewards.stage_victory(run, str(pending.map_id), str(pending.node_id), str(monster.grade), int(result.battle_index))
		if reward_error != OK:
			_fail("创建战斗奖励失败：%d" % reward_error)
			return
		run.inventory_state.pending_rewards["stolen_refund"] = int(result.get("stolen_refund", 0))
		run.inventory_state.pending_rewards["conch_bonus"] = int(result.get("conch_bound", 0))
		var bonus: Array = []
		if int(result.get("stolen_refund", 0)) > 0:
			bonus.append({"id": "stolen_silver", "kind": "silver", "amount": int(result.stolen_refund), "claimed": false})
		if int(result.get("conch_bound", 0)) > 0:
			bonus.append({"id": "conch_rare", "kind": "rare_pack", "amount": int(result.conch_bound), "claimed": false})
		run.inventory_state.pending_rewards["bonus_entries"] = bonus
		run.update_map_node(session.map_id, str(pending.node_id), {"completed": true, "enemy_id": pending.content_id})
		if pending.type == "boss" and not _advance_after_boss():
			return
	# 战斗结果已落地，UI 只负责播放结算动画；不能重进节点重新抽敌人。
	if SaveGateway.save_current() != OK:
		_fail("战斗结果保存失败，请在退出前重试保存")
	MapEvents.map_state_changed.emit(str(pending.map_id), completed_state)
	MapEvents.node_interaction_resolved.emit(str(pending.request_id), str(pending.node_id), "completed" if completed else "failed")
	if victory and pending.type == "boss":
		MapEvents.boss_cleared.emit(str(pending.map_id), str(pending.node_id))

func _boss_completed() -> bool:
	for id: String in session.nodes:
		if session.nodes[id].type == "boss" and session.completed.has(id):
			return true
	return false

func _advance_after_boss() -> bool:
	run.complete_current_map()
	if map_run.current_floor >= IMPLEMENTED_FLOORS:
		# 不能把第三层当全游戏胜利；保留本局，等待后续第四层。
		run.map_states[run.current_map_id]["awaiting_fourth_floor"] = true
		return true
	var entry: Dictionary = map_run.enter_floor(map_run.current_floor + 1, session.capture_state())
	if entry.is_empty():
		return _fail(map_run.last_error)
	var next_session = Session.new()
	if not next_session.load_map(entry.snapshot) or not next_session.restore_state(entry.state):
		return _fail(next_session.last_error)
	session = next_session
	run.set_current_map(str(entry.snapshot.map_id))
	# 领取 Boss 奖励期间就预热下一层全部节点，不等玩家回到地图才读贴图。
	_preload_floor(entry.snapshot)
	return true

func capture_menu_checkpoint() -> Dictionary:
	if map_run == null or session == null or not is_instance_valid(run) or run != SaveGateway.current_run():
		return {}
	return map_run.capture_snapshot(session.capture_state())

func map_view_data() -> Dictionary:
	return session.get_view() if session != null else {}

func waiting_for_fourth_floor() -> bool:
	return is_instance_valid(run) and bool(run.map_states.get(run.current_map_id, {}).get("awaiting_fourth_floor", false))

func _fail(message: String) -> bool:
	last_error = message
	push_warning("EncounterFlow: " + message)
	return false

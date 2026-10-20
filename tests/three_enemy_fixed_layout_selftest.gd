extends Node

const RESOLUTIONS: Array[Vector2i] = [Vector2i(1920, 1080), Vector2i(1280, 720)]
const WAIT_MS: int = 15000
# Independent acceptance contract, authored for this road background; never read rack constants.
const ROAD_CONTACT_RECT := Rect2(600.0, 740.0, 800.0, 80.0)
const SIDE_LEFT_X: float = 544.75
const SIDE_RIGHT_X: float = 994.75
const SIDE_GROUND_Y: float = 780.0
var failures: int = 0
var checks: int = 0
var failure_labels: Array[String] = []
var fixture_root: String = ""
var scene: FixtureBattle
var original_reference: EnemySlot
var ordinary_reference: EnemySlot
var side_reference: EnemySlot
var records: Array[Dictionary] = []
var images: Array[String] = []
var skipped_images: Array[String] = []
var skipped_native_checks: Array[String] = []
var deadline: int = 0
var finishing: bool = false
var _acceptance_alpha_images: Dictionary = {}

# Only supply real catalog enemies before initialization and observe production snapshots.
# All battle initialization, rules, resolver, rendering and animation methods still run.
class FixtureBattle extends "res://ui/battle/battle_test_scene.gd":
	var fixture_ids: Array[String] = []
	var fixture_prefix: String = ""
	var spawn_records: Array[Dictionary] = []
	var rendered_records: Array[Dictionary] = []
	var pose_records: Array[Dictionary] = []
	var validated_sample_count: int = 0
	func _test_enemy_payload() -> Array:
		var enemies: Array = []
		for index: int in fixture_ids.size():
			enemies.append(MonsterCatalog.create(fixture_ids[index], 2, "%s/%d" % [fixture_prefix, index]))
		return enemies

	func _queue_presentation(kind: String, fields: Dictionary = {}) -> void:
		super._queue_presentation(kind, fields)
		if kind == "enemy_spawned":
			var event: Dictionary = _resolution_events.back()
			spawn_records.append({"living_ids": living_ids(event["enemies"]), "ui_ids_at_queue": visible_ids(), "turn": int(event["turn"])})

	func _render_combat_snapshot(player_data: Dictionary, enemies: Array) -> void:
		super._render_combat_snapshot(player_data, enemies)
		var poses: Dictionary = {}
		for slot: EnemySlot in enemy_rack.slots:
			var rect: Rect2 = slot.portrait.get_global_rect()
			poses[slot.enemy_id] = {"portrait_size": [slot.portrait.size.x, slot.portrait.size.y], "portrait_rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]}
		rendered_records.append({"living_ids": living_ids(enemies), "visible_ids": visible_ids(), "target": _chosen_enemy_id(), "portraits": poses})

	func visible_ids() -> Array[String]:
		var ids: Array[String] = []
		if enemy_rack != null:
			for slot: EnemySlot in enemy_rack.slots:
				if is_instance_valid(slot) and slot.visible and not slot._snapshot_dead: ids.append(slot.enemy_id)
		return ids

	func living_ids(enemies: Array) -> Array[String]:
		var ids: Array[String] = []
		for enemy: Dictionary in enemies:
			if int(enemy.get("health", 0)) > 0: ids.append(str(enemy["enemy_id"]))
		return ids

func _ready() -> void:
	call_deferred("_run")

func _process(_delta: float) -> void:
	if deadline > 0 and not finishing and Time.get_ticks_msec() >= deadline:
		_expect("全套在180秒硬上限内完成", false)
		_finish()

func _run() -> void:
	deadline = Time.get_ticks_msec() + 180000
	fixture_root = "res://.godot/original-size-%d" % Time.get_ticks_usec()
	if not _expect("隔离目录可创建", DirAccess.make_dir_recursive_absolute(fixture_root) == OK):
		_finish()
		return
	SaveGateway.save_path = fixture_root.path_join("game.json")
	if not _expect("独立档案可载入", SaveGateway.load_current() == OK):
		_finish()
		return
	var board: RelicBoard = RelicBoard.new()
	if not _expect("合法空20格残片板可保存", board.cells.size() == 20 and board.save_to_file(fixture_root.path_join("empty-board.json")) == OK):
		_finish()
		return
	for resolution: Vector2i in RESOLUTIONS:
		get_window().size = resolution
		await get_tree().process_frame
		if not await _boss_one(resolution):
			_finish()
			return
		if not await _boss_eleven(resolution):
			_finish()
			return
		if not await _elite_twelve(resolution):
			_finish()
			return
		if not await _ordinary_three(resolution):
			_finish()
			return
	_finish()

func _new_battle(ids: Array[String], card_id: String, tag: String) -> bool:
	_release_scene()
	SeedService.begin_run("three-fixed/" + tag)
	var packed: PackedScene = load("res://ui/battle/battle_test_scene.tscn") as PackedScene
	if not _expect(tag + " 场景资源存在", packed != null): return false
	var base: BattleTestScene = packed.instantiate() as BattleTestScene
	if not _expect(tag + " 场景可实例化", base != null): return false
	base.set_script(FixtureBattle)
	scene = base as FixtureBattle
	if not _expect(tag + " 观察子类装配成功", scene != null):
		base.free()
		return false
	scene.fixture_ids.assign(ids)
	scene.fixture_prefix = tag
	scene.relic_board_path = fixture_root.path_join("empty-board.json")
	scene.test_player_health = 10000
	scene.test_player_max_health = 10000
	scene.resolution_delay = 0.05
	scene.enemy_turn_delay = 0.05
	var deck: Array[String] = []
	for index: int in 24: deck.append(card_id)
	scene.deck_card_ids.assign(deck)
	# The scene reads formal rules during ready. Isolate precise fixture draws, then restore.
	var rules_before: Dictionary = EncounterFlow.test_rules
	EncounterFlow.test_rules = rules_before.duplicate(true)
	EncounterFlow.test_rules["initial_draw_count"] = 6
	EncounterFlow.test_rules["per_turn_draw_count"] = 1
	add_child(scene)
	EncounterFlow.test_rules = rules_before
	if not _expect(tag + " 正式规则引用已恢复", EncounterFlow.test_rules == rules_before): return false
	if not await _settled(tag + " 初始化"): return false
	# Independent authored-size oracle: do not read EnemyRack's selected width or zone.
	original_reference = _reference_slot(959.5, 880.0, Vector2(530.0, 78.0))
	ordinary_reference = _reference_slot(650.0, 610.0, Vector2.ZERO)
	ordinary_reference.position = Vector2(725.0, 660.0 - ordinary_reference.portrait.position.y - ordinary_reference.portrait.size.y)
	side_reference = _reference_slot(480.0, 610.0, Vector2.ZERO)
	return _expect(tag + " 真实怪物与固定牌组进入战斗", scene._battle.enemies.size() == ids.size() and scene._battle.hand.size() == 6 and scene._battle.enemies.all(func(enemy: Dictionary): return enemy.has("monster_id")))

func _boss_one(resolution: Vector2i) -> bool:
	var tag: String = "boss1-%d" % resolution.x
	if not await _new_battle(["1"], "test_block", tag): return false
	var owner: String = str(scene._battle.enemies[0]["enemy_id"])
	var original: Dictionary = _pose(owner)
	if not _expect(tag + " 初始主怪槽存在", not original.is_empty()): return false
	if not _layout(owner, 1, tag + "/one"): return false
	if not await _capture(tag + "-one"): return false
	# Boss1's real plan summons only on even enemy turns starting at turn 2.
	for round_index: int in 6:
		if not await _play_first_card(tag + "/turn%d" % (round_index + 1)): return false
		var expected: int = [1, 2, 2, 3, 3, 3][round_index]
		if not _expect(tag + " 自然回合人数/%d" % (round_index + 1), _living().size() == expected): return false
		if not _stable(owner, original, tag + " 主怪1→2→3保持原槽和立绘"): return false
		if not _layout(owner, expected, tag + "/turn%d" % (round_index + 1)): return false
		if round_index == 1 and not await _capture(tag + "-two"): return false
		if round_index == 3 and not await _capture(tag + "-three"): return false
	if not _expect(tag + " 满三怪继续真实回合跳过召唤且无多余入场", scene.spawn_records.size() == 2 and _living().size() == 3): return false
	if not _expect(tag + " 入场快照真实逐次增长", scene.spawn_records[0]["living_ids"].size() == 2 and scene.spawn_records[1]["living_ids"].size() == 3 and scene.spawn_records[0]["ui_ids_at_queue"].size() == 1 and scene.spawn_records[1]["ui_ids_at_queue"].size() == 2): return false
	var sides: Array[String] = _living()
	sides.erase(owner)
	var removed_id: String = sides[0]
	var survivor_id: String = sides[1]
	var removed_pose: Dictionary = _pose(removed_id)
	var survivor_pose: Dictionary = _pose(survivor_id)
	if not await _click_enemy(survivor_id): return false
	if not _expect(tag + " 点副怪只切目标", scene._chosen_enemy_id() == survivor_id): return false
	if not _stable(owner, original, tag + " 点选不把副怪提升为主怪") or not _stable(survivor_id, survivor_pose, tag + " 点选不交换站位") or not _stable(removed_id, removed_pose, tag + " 点选不挪另一副怪"): return false
	var dead_view: EnemySlot = scene.enemy_rack.slot_for(removed_id)
	_context().damage_enemy(removed_id, int(_enemy(removed_id)["health"]), true)
	if not await _settled(tag + " 侧怪死亡"): return false
	if not _expect(tag + " 死侧怪腾位且不再可点击", _living().size() == 2 and (not is_instance_valid(dead_view) or (not dead_view.visible and not dead_view.selectable))): return false
	if not _stable(owner, original, tag + " 死亡不改变主怪") or not _stable(survivor_id, survivor_pose, tag + " 死亡不挪存活侧怪"): return false
	for index: int in 2:
		if not await _play_first_card(tag + "/refill%d" % index): return false
	if not _expect(tag + " 下一次真实召唤重新补足三怪", _living().size() == 3 and scene.spawn_records.size() == 3): return false
	var replacement: Array[String] = _living()
	replacement.erase(owner)
	replacement.erase(survivor_id)
	if not _expect(tag + " 新召唤具有独立身份", replacement.size() == 1 and replacement[0] != removed_id): return false
	var replacement_view: EnemySlot = scene.enemy_rack.slot_for(replacement[0])
	if not _expect(tag + " 新怪具有真实视图", replacement_view != null): return false
	if not _expect(tag + " 新怪继承空侧位", _same_rect(replacement_view.portrait.get_global_rect(), _rect(removed_pose["portrait_rect"]))): return false
	if not _stable(owner, original, tag + " 补位不改变主怪") or not _stable(survivor_id, survivor_pose, tag + " 补位不改变另一侧instance及位置"): return false
	if not _layout(owner, 3, tag + "/refilled"): return false
	if not await _capture(tag + "-refilled"): return false
	if not await _cold_rebuild_formation(tag + " 补位冷重建"): return false
	_record(tag)
	return true

func _cold_rebuild_formation(label: String) -> bool:
	var before := {}
	for identity: String in _living(): before[identity] = _pose(identity)
	var battle_before := JSON.stringify(scene._battle.to_dictionary())
	var rng_before := JSON.stringify(SeedService.capture_snapshot())
	var saved: Dictionary = JSON.parse_string(battle_before)
	var previous: EnemyRack = scene.enemy_rack
	scene.remove_child(previous)
	previous.free()
	var rebuilt: EnemyRack = load("res://ui/battle/enemy_rack.gd").new()
	rebuilt.name = "EnemyRack"
	scene.add_child(rebuilt)
	scene.enemy_rack = rebuilt
	rebuilt.slot_selected.connect(Callable(scene, "_on_enemy_slot_selected"))
	scene._render_combat_snapshot(saved.player, saved.enemies)
	if not await _settled(label): return false
	for identity: String in before:
		var current := _pose(identity)
		if not _expect(label + "/" + identity + " JSON快照重建后仍在原位且尺寸相等", not current.is_empty() and current.portrait_size == before[identity].portrait_size and _same_rect(_rect(current.portrait_rect), _rect(before[identity].portrait_rect))): return false
	if _large_primary() and not _authored_size(str(scene._battle.enemies[0]["enemy_id"]), label + " 原版尺寸"): return false
	return _expect(label + " 仅重建视图不改业务或随机状态", JSON.stringify(scene._battle.to_dictionary()) == battle_before and JSON.stringify(SeedService.capture_snapshot()) == rng_before)

func _boss_eleven(resolution: Vector2i) -> bool:
	var tag: String = "boss11-%d" % resolution.x
	if not await _new_battle(["11"], "test_damage_enemy", tag): return false
	var main: Dictionary = scene._battle.enemies[0]
	var owner: String = str(main["enemy_id"])
	var original: Dictionary = _pose(owner)
	if not _expect(tag + " 初始主怪槽存在", not original.is_empty()): return false
	if not _layout(owner, 1, tag + "/one"): return false
	if not await _capture(tag + "-one"): return false
	_context().damage_enemy(owner, int(main["health"]), true)
	if not _expect(tag + " 真实二阶段同步产生两次召唤", int(main["phase"]) == 2 and int(main["health"]) == 96 and scene.spawn_records.size() == 2 and _living().size() == 3): return false
	if not await _settled(tag + " 二阶段入场"): return false
	if not _expect(tag + " 二阶段快照逐个增长且界面真实经过二怪和三怪", scene.spawn_records[0]["living_ids"].size() == 2 and scene.spawn_records[1]["living_ids"].size() == 3 and scene.spawn_records[0]["ui_ids_at_queue"].size() == 1 and scene.spawn_records[1]["ui_ids_at_queue"].size() == 1 and scene.rendered_records.any(func(sample: Dictionary): return sample["visible_ids"].size() == 2) and scene.rendered_records.any(func(sample: Dictionary): return sample["visible_ids"].size() == 3)): return false
	if not _stable(owner, original, tag + " 二阶段本体位置大小instance稳定") or not _layout(owner, 3, tag): return false
	var side_ids: Array[String] = _living()
	side_ids.erase(owner)
	var knight_id: String = side_ids[0]
	var thief_id: String = side_ids[1]
	if not _expect(tag + " 二阶段成员来自真实骑士与盗贼", str(_enemy(knight_id)["monster_id"]) == "14" and str(_enemy(thief_id)["monster_id"]) == "15"): return false
	var knight: EnemySlot = scene.enemy_rack.slot_for(knight_id)
	var thief: EnemySlot = scene.enemy_rack.slot_for(thief_id)
	var main_slot: EnemySlot = scene.enemy_rack.slot_for(owner)
	if not _expect(tag + " 三者独立血条且本体正常亮度", main_slot.fill != knight.fill and knight.fill != thief.fill and is_equal_approx(main_slot.portrait.modulate.a, 1.0)): return false
	var health_before: int = int(_enemy(knight_id)["health"])
	_context().damage_enemy(knight_id, 7, true)
	if not _expect(tag + " 伤害快照记录具体随从ID", scene._resolution_events.any(func(event: Dictionary): return event["kind"] == "damage" and str(event.get("entity_id", "")) == knight_id)): return false
	if not await _settled(tag + " 随从独立受伤"): return false
	if not _expect(tag + " 伤害HP及反馈只定位到随从", int(_enemy(knight_id)["health"]) == health_before - 7 and is_equal_approx(float(knight.fill.get("ratio")), float(health_before - 7) / float(_enemy(knight_id)["max_health"])) and is_equal_approx(float(main_slot.fill.get("ratio")), 1.0) and scene._feedback._enemy_view(knight_id).portrait == knight.portrait): return false
	if not _expect(tag + " 真实格挡与治疗规则接受指令", scene._battle.rules.submit("action.block", {"side": "enemy", "target": knight_id, "amount": 3}) == OK and scene._battle.rules.submit("monster.heal", {"target": knight_id, "amount": 4}) == OK): return false
	_context().add_buff(&"enemy", knight_id, &"poison", 2)
	if not await _settled(tag + " 格挡治疗buff表现"): return false
	if not _expect(tag + " 血量格挡buff不串实体", int(_enemy(knight_id)["health"]) == health_before - 3 and int(knight.shield.get("value")) == 3 and int(main_slot.shield.get("value")) == 0 and int(thief.shield.get("value")) == 0 and knight.buff_row.get_child_count() > 0 and knight.buff_row.get_child_count() == _enemy(knight_id)["buffs"].size() and main_slot.buff_row.get_child_count() == main["buffs"].size() and thief.buff_row.get_child_count() == _enemy(thief_id)["buffs"].size() and knight.buff_row != main_slot.buff_row and knight.buff_row != thief.buff_row): return false
	var intent: Dictionary = _enemy(knight_id).duplicate(true)
	intent["intent_plan"] = [{"block": 9}]
	knight.show_snapshot_status(intent, false, true, {"ready": true, "action_count": 1, "actions": [{"kinds": ["block"], "block": 9, "block_max": 9, "summary": "测试"}]})
	if not _expect(tag + " 防御意图为真实防御图标和独立动数", knight.intent_strip.cells[0].get_node("Icon").texture.atlas.resource_path.ends_with("/防御.png") and knight.intent_value.text == "1动"): return false
	intent["intent_plan"] = [{"summon": "4"}]
	knight.show_snapshot_status(intent, false, true, {"ready": true, "action_count": 1, "actions": [{"kinds": ["special"], "block": -1, "block_max": -1, "summary": "测试"}]})
	if not _expect(tag + " 特殊意图不会伪装成0攻击", knight.intent_strip.cells[0].get_node("Icon").texture.atlas.resource_path.ends_with("/特殊.png") and knight.intent_value.text == "1动"): return false
	var random_before: String = JSON.stringify(SeedService.capture_snapshot())
	for index: int in 3: scene._refresh_combat_status()
	if not _expect(tag + " UI重复刷新不消耗随机", JSON.stringify(SeedService.capture_snapshot()) == random_before): return false
	if not await _click_enemy(thief_id): return false
	if not _expect(tag + " 鼠标可选盗贼且主怪身份不替换", scene._chosen_enemy_id() == thief_id and main_slot.name_label.text == str(main["name"]) and main_slot.portrait.texture == TextCatalogService.art_texture(str(main["art_path"]))): return false
	var thief_health: int = int(_enemy(thief_id)["health"])
	if not await _play_first_card(tag + " 真鼠标出牌", true): return false
	if not _expect(tag + " 真卡牌伤害只打点选副怪", int(_enemy(thief_id)["health"]) == thief_health - 8 and int(main["health"]) == 96): return false
	if not _stable(owner, original, tag + " 所有反馈后主怪仍保持原位"): return false
	if not await _capture(tag + "-phase2"): return false
	_record(tag)
	return true

func _elite_twelve(resolution: Vector2i) -> bool:
	var tag: String = "elite12-%d" % resolution.x
	if not await _new_battle(["12"], "test_block", tag): return false
	var owner: String = str(scene._battle.enemies[0]["enemy_id"])
	var original: Dictionary = _pose(owner)
	if not _expect(tag + " 真实精英12进入主怪位", str(_enemy(owner)["grade"]) == "精英" and not original.is_empty()): return false
	if not _layout(owner, 1, tag + "/one"): return false
	if not await _capture(tag + "-one"): return false
	for member_count: int in [2, 3]:
		if not _expect(tag + " 正式召唤指令成功", scene._battle.rules.submit("monster.summon", {"id": "4", "owner": owner}) == OK): return false
		if not await _settled(tag + "/summon%d" % member_count): return false
		if not _stable(owner, original, tag + " 精英召唤前后instance位置尺寸不变"): return false
		if not _layout(owner, member_count, tag + "/count%d" % member_count): return false
		if member_count == 3 and not await _overlap_input(owner, tag): return false
		if not await _capture(tag + "-count%d" % member_count): return false
	if not _expect(tag + " 真实召唤仅产生两次成员入场", scene.spawn_records.size() == 2): return false
	if not await _cold_rebuild_formation(tag + " 精英三怪JSON重建"): return false
	_record(tag)
	return true

func _ordinary_three(resolution: Vector2i) -> bool:
	var tag: String = "ordinary-%d" % resolution.x
	if not await _new_battle(["6", "5", "3"], "test_block", tag): return false
	var ids: Array[String] = _living()
	var main_id: String = ids[0]
	var guard_id: String = ids[1]
	var other_id: String = ids[2]
	var main_pose: Dictionary = _pose(main_id)
	var other_pose: Dictionary = _pose(other_id)
	if not _expect(tag + " 普通主副怪槽存在", not main_pose.is_empty() and not other_pose.is_empty()): return false
	if not _layout(main_id, 3, tag + " 普通三怪完整显示"): return false
	if not _expect(tag + " 真护卫嘲讽强制目标并禁用其他点击", bool(_enemy(guard_id)["taunt"]) and scene._chosen_enemy_id() == guard_id and not scene.enemy_rack.slot_for(other_id).selectable): return false
	if not await _click_enemy(other_id): return false
	if not _expect(tag + " 真实鼠标不能绕过嘲讽", scene._chosen_enemy_id() == guard_id): return false
	if not _stable(main_id, main_pose, tag + " 嘲讽目标不变成主怪"): return false
	if not await _capture(tag + "-three-taunt"): return false
	_context().damage_enemy(guard_id, int(_enemy(guard_id)["health"]), true)
	if not await _settled(tag + " 护卫死亡"): return false
	if not await _click_enemy(other_id): return false
	if not _expect(tag + " 嘲讽死亡后可点击其他怪物", scene._chosen_enemy_id() == other_id): return false
	if not _stable(main_id, main_pose, tag + " 嘲讽死亡主怪不变") or not _stable(other_id, other_pose, tag + " 嘲讽死亡另一侧不跳"): return false
	_context().damage_enemy(main_id, int(_enemy(main_id)["health"]), true)
	if not await _settled(tag + " 主怪死亡"): return false
	if not _expect(tag + " 主怪死亡后侧怪仍活着并可点击", scene._battle.active and scene.enemy_rack.slot_for(other_id).visible and scene.enemy_rack.slot_for(other_id).selectable): return false
	if not _stable(other_id, other_pose, tag + " 主怪死亡不把侧怪升为主怪"): return false
	if not await _capture(tag + "-main-defeated"): return false
	_record(tag)
	return true

func _play_first_card(label: String, real_mouse: bool = false) -> bool:
	if not _expect(label + " 有合法手牌", not scene._battle.hand.is_empty()): return false
	var id: String = str(scene._battle.hand[0]["instance_id"])
	if real_mouse:
		var button: Button
		for slot: Node in scene.hand_cards.get_children():
			if str(slot.get_meta("instance_id", "")) == id and slot.get_child_count() > 1: button = slot.get_child(1) as Button
		if not _expect(label + " 真手牌按钮存在", button != null): return false
		await _click(button.get_global_rect().get_center())
	else:
		scene._on_hand_card_pressed(id)
	if not await _settled(label + " 编排飞牌"): return false
	if not _expect(label + " 实际已编排一张", scene._selected_ids == [id]): return false
	var turn_before: int = scene._battle.turn_number
	scene._on_play_pressed()
	if not await _settled(label + " 真实敌方回合"): return false
	return _expect(label + " 规则恰好推进一回合", scene._battle.turn_number == turn_before + 1)

func _layout(owner: String, expected: int, label: String) -> bool:
	var ids: Array[String] = _living()
	if not _expect(label + " 所有存活实体可见且最多三只", ids.size() == expected and scene.visible_ids().size() == expected and expected <= 3): return false
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	if not _expect(label + " 永久主怪槽存在", main != null): return false
	var main_rect: Rect2 = main.portrait.get_global_rect()
	var large: bool = _large_primary()
	if large:
		if not _authored_size(owner, label + " 原版单体参照"): return false
	else:
		if not _expect(label + " 普通主怪保持650原几何和660脚底", is_equal_approx(main.size.x, 650.0) and main.global_position.is_equal_approx(ordinary_reference.global_position) and main.portrait.size.is_equal_approx(ordinary_reference.portrait.size) and _same_rect(main_rect, ordinary_reference.portrait.get_global_rect()) and is_equal_approx(main_rect.end.y, 660.0)): return false
	var sides: Array[Rect2] = []
	var poses: Array[Dictionary] = []
	for id: String in ids:
		var slot: EnemySlot = scene.enemy_rack.slot_for(id)
		if not _expect(label + "/" + id + " 各自槽位可见有身份", slot != null and slot.visible and slot.enemy_id == id and slot.portrait.texture != null and slot.name_label.text == str(_enemy(id)["name"])): return false
		var click_rect: Rect2 = Rect2(slot.global_position, Vector2(slot.size.x, slot.click_height()))
		poses.append(_pose(id))
		if not _expect(label + "/" + id + " 敌方点击区不遮手牌", not click_rect.intersects(scene.hand_scroll.get_global_rect())): return false
		if id != owner:
			var rect: Rect2 = slot.portrait.get_global_rect()
			if not _expect(label + "/" + id + " 副怪使用独立480中型参照且小于主怪", is_equal_approx(slot.size.x, 480.0) and slot.portrait.size.is_equal_approx(side_reference.portrait.size) and rect.size.x < main_rect.size.x and rect.size.y < main_rect.size.y): return false
			# Persisted summon role, or the authored initial enemy index, chooses the fixed side.
			var role: int = int(_enemy(id).get("formation_slot", scene._battle.enemies.find(_enemy(id))))
			if not _expect(label + "/" + id + " 副怪具有合法固定侧位", role in [1, 2]): return false
			var expected_x: float = SIDE_LEFT_X if role == 1 else SIDE_RIGHT_X
			side_reference.position = Vector2(expected_x, SIDE_GROUND_Y - side_reference.portrait.position.y - side_reference.portrait.size.y)
			if not _expect(label + "/" + id + " 副怪处于道路前景固定侧位", slot.global_position.is_equal_approx(side_reference.global_position) and _same_rect(rect, side_reference.portrait.get_global_rect())): return false
			var foot_midpoint := Vector2(rect.get_center().x, rect.end.y)
			if not _expect(label + "/" + id + " 立绘脚底中点在可见道路保守范围内", is_equal_approx(foot_midpoint.y, SIDE_GROUND_Y) and ROAD_CONTACT_RECT.has_point(foot_midpoint)): return false
			# Rectangle intersection is a layout check; opaque silhouette acceptance remains native visual QA.
			if not _expect(label + "/" + id + " 主侧立绘矩形允许边缘交叠", rect.intersection(main_rect).has_area()): return false
			sides.append(rect)
	if sides.size() == 2:
		if not _expect(label + " 两副怪分列主怪左右", (sides[0].get_center().x - main_rect.get_center().x) * (sides[1].get_center().x - main_rect.get_center().x) < 0.0): return false
	scene.pose_records.append({"label": label, "poses": poses})
	for sample_index: int in range(scene.validated_sample_count, scene.rendered_records.size()):
		var sample: Dictionary = scene.rendered_records[sample_index]
		if large:
			var sampled: Dictionary = sample["portraits"].get(owner, {})
			if not _expect(label + " 每份1/2/3成员快照主怪都等于原版参照", not sampled.is_empty() and _vector(original_reference.portrait.size) == sampled["portrait_size"] and _same_rect(_rect(sampled["portrait_rect"]), original_reference.portrait.get_global_rect())): return false
		else:
			var ordinary_sample: Dictionary = sample["portraits"].get(owner, {})
			if not _expect(label + " 每份普通怪快照仍保留原主怪几何", not ordinary_sample.is_empty() and _vector(ordinary_reference.portrait.size) == ordinary_sample["portrait_size"] and _same_rect(_rect(ordinary_sample["portrait_rect"]), ordinary_reference.portrait.get_global_rect())): return false
		if not _expect(label + " 逐快照最多显示三只且不提前显示未来成员", sample["visible_ids"].size() <= 3 and _sorted(sample["living_ids"]) == _sorted(sample["visible_ids"])): return false
	scene.validated_sample_count = scene.rendered_records.size()
	return true

func _reference_slot(width: float, height: float, at: Vector2) -> EnemySlot:
	var reference: EnemySlot = EnemySlot.new()
	reference.name = "IndependentSizeReference"
	scene.add_child(reference)
	reference.layout_for(width, height)
	reference.position = at
	reference.hide()
	reference.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return reference

func _large_primary() -> bool:
	return str(scene._battle.enemies[0].get("grade", "")) in ["BOSS", "精英"]

func _authored_size(id: String, label: String) -> bool:
	var slot: EnemySlot = scene.enemy_rack.slot_for(id)
	if not _expect(label + " 主怪及独立原版参照存在", slot != null and is_instance_valid(original_reference)): return false
	var authored: Dictionary = {"slot_position": _vector(original_reference.global_position), "portrait_size": _vector(original_reference.portrait.size), "portrait_rect": _rectangle(original_reference.portrait.get_global_rect())}
	scene.pose_records.append({"label": label, "authored_reference": authored, "actual": _pose(id)})
	return _expect(label + " Boss精英精确恢复959.5原版单体尺寸位置", slot.size.is_equal_approx(Vector2(959.5, 880.0)) and slot.global_position.is_equal_approx(original_reference.global_position) and slot.portrait.size.is_equal_approx(original_reference.portrait.size) and _same_rect(slot.portrait.get_global_rect(), original_reference.portrait.get_global_rect()))

func _overlap_input(owner: String, label: String) -> bool:
	var main: EnemySlot = scene.enemy_rack.slot_for(owner)
	var main_rect: Rect2 = _click_rect(main)
	var sides: Array[EnemySlot] = []
	for id: String in _living():
		if id != owner: sides.append(scene.enemy_rack.slot_for(id))
	for side: EnemySlot in sides:
		var overlap: Rect2 = main_rect.intersection(_click_rect(side))
		if not _expect(label + "/" + side.enemy_id + " 主侧点击区存在真实交叠", overlap.has_area()): return false
		var opaque: Vector2 = _alpha_point(main, overlap, true)
		if not _expect(label + "/" + side.enemy_id + " 交叠区有主怪不透明内核样本", opaque != Vector2.INF): return false
		if not await _pointer_select(main, opaque, label + "/" + side.enemy_id + " 主怪不透明处优先"): return false
		var visible_side: Vector2 = _visible_click_point(side, true)
		if not _expect(label + "/" + side.enemy_id + " 后排具有主怪透明处的可见点击样本", visible_side != Vector2.INF and main.portrait.get_global_rect().has_point(visible_side) and _portrait_alpha(main, visible_side) < 0.02): return false
		var before: Dictionary = _pose(side.enemy_id)
		if not await _pointer_select(side, visible_side, label + "/" + side.enemy_id + " 可见后排区域"): return false
		if not _stable(side.enemy_id, before, label + " 选择不改变后排站位"): return false
	if sides.size() == 2:
		var left: EnemySlot = sides[0] if sides[0].position.x < sides[1].position.x else sides[1]
		var right: EnemySlot = sides[1] if left == sides[0] else sides[0]
		var overlap: Rect2 = _click_rect(left).intersection(_click_rect(right))
		if not _expect(label + " 左右中型槽保留30像素点击交叠", overlap.has_area() and is_equal_approx(overlap.size.x, 30.0)): return false
		var opaque: Vector2 = _alpha_point(main, overlap, true)
		if not _expect(label + " 左右交叠内存在主怪可见身体", opaque != Vector2.INF): return false
		if not await _pointer_select(main, opaque, label + " 左右交叠处主怪身体优先"): return false
	var main_point: Vector2 = _alpha_point(main, main_rect, true)
	if not _expect(label + " 主怪具有实际不透明可点击像素", main_point != Vector2.INF): return false
	return await _pointer_select(main, main_point, label + " 主怪可见模型")

# Independent texture sampling; never call the production _has_point() as an oracle.
# Search only alpha cores (including a 2-texel neighbourhood), excluding blended edges.
func _portrait_alpha(slot: EnemySlot, point: Vector2) -> float:
	if slot.portrait.texture == null: return 0.0
	var texture: Texture2D = slot.portrait.texture
	var key: int = texture.get_instance_id()
	if not _acceptance_alpha_images.has(key):
		var read_image: Image = texture.get_image()
		if read_image == null: return -1.0
		if read_image.is_compressed() and read_image.decompress() != OK: return -1.0
		_acceptance_alpha_images[key] = read_image
	var texture_image: Image = _acceptance_alpha_images[key]
	var rect: Rect2 = slot.portrait.get_global_rect()
	var native: Vector2 = Vector2(texture_image.get_size())
	var fit: float = minf(rect.size.x / native.x, rect.size.y / native.y)
	var drawn := Rect2(rect.get_center() - native * fit * 0.5, native * fit)
	if not drawn.has_point(point): return 0.0
	var texel: Vector2i = Vector2i((point - drawn.position) / fit)
	if texel.x < 2 or texel.y < 2 or texel.x >= texture_image.get_width() - 2 or texel.y >= texture_image.get_height() - 2: return 0.5
	var lowest: float = 1.0
	var highest: float = 0.0
	for offset_y: int in range(-2, 3):
		for offset_x: int in range(-2, 3):
			var value: float = texture_image.get_pixel(texel.x + offset_x, texel.y + offset_y).a
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
	if lowest > 0.98: return 1.0
	if highest < 0.02: return 0.0
	return 0.5

func _alpha_point(slot: EnemySlot, area: Rect2, opaque: bool) -> Vector2:
	for y: int in range(int(area.position.y) + 6, int(area.end.y) - 6, 8):
		for x: int in range(int(area.position.x) + 6, int(area.end.x) - 6, 8):
			var point := Vector2(x, y)
			var alpha: float = _portrait_alpha(slot, point)
			if (opaque and alpha > 0.98) or (not opaque and alpha >= 0.0 and alpha < 0.02): return point
	return Vector2.INF

func _visible_click_point(slot: EnemySlot, within_main: bool = false) -> Vector2:
	var main: EnemySlot = scene.enemy_rack.slot_for(str(scene._battle.enemies[0]["enemy_id"]))
	if slot == main: return _alpha_point(slot, _click_rect(slot), true)
	var area: Rect2 = _click_rect(slot).intersection(slot.portrait.get_global_rect())
	if within_main: area = area.intersection(main.portrait.get_global_rect())
	for y: int in range(int(area.position.y) + 6, int(area.end.y) - 6, 8):
		for x: int in range(int(area.position.x) + 6, int(area.end.x) - 6, 8):
			var point := Vector2(x, y)
			if _portrait_alpha(slot, point) < 0.98: continue
			if main != null and not main._snapshot_dead and _portrait_alpha(main, point) >= 0.02: continue
			var covered: bool = false
			for other: EnemySlot in scene.enemy_rack.slots:
				if other != slot and other != main and other.visible and other.selectable and _click_rect(other).has_point(point): covered = true
			if not covered: return point
	return Vector2.INF

func _click_rect(slot: EnemySlot) -> Rect2:
	return Rect2(slot.global_position, Vector2(slot.size.x, slot.click_height()))

func _pointer_select(target: EnemySlot, point: Vector2, label: String) -> bool:
	get_viewport().warp_mouse(point)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	if DisplayServer.get_name() == "headless" or "--skip-native-hover" in OS.get_cmdline_user_args():
		skipped_native_checks.append(label + " 原生hover")
	else:
		var until: int = mini(Time.get_ticks_msec() + 2000, deadline)
		while Time.get_ticks_msec() < until and not _hover_matches(target):
			await get_tree().process_frame
		if not _expect(label + " 原生hover仅点亮命中实体", _hover_matches(target)): return false
	await _click(point)
	if not await _settled(label + " 真实鼠标点击"): return false
	return _expect(label + " 真实鼠标选择正确实体", scene._chosen_enemy_id() == target.enemy_id)

func _hover_matches(target: EnemySlot) -> bool:
	if scene.enemy_rack._hovered_slot() != target: return false
	for slot: EnemySlot in scene.enemy_rack.slots:
		if slot._glow.visible != (slot == target): return false
	return true

func _stable(id: String, reference: Dictionary, label: String) -> bool:
	var view: EnemySlot = scene.enemy_rack.slot_for(id)
	if not _expect(label + " 实体槽仍存在", view != null): return false
	var current: Dictionary = _pose(id)
	scene.pose_records.append({"label": label, "reference": reference.duplicate(true), "current": current})
	return _expect(label, current["instance"] == reference["instance"] and current["portrait_size"] == reference["portrait_size"] and _same_rect(_rect(current["portrait_rect"]), _rect(reference["portrait_rect"])) and current["slot_position"] == reference["slot_position"])

func _settled(label: String) -> bool:
	var until: int = mini(Time.get_ticks_msec() + WAIT_MS, deadline)
	while is_instance_valid(scene) and Time.get_ticks_msec() < until:
		if not _expect_valid_battle(): return false
		var waiting: bool = scene._presentation_pending() or scene._refresh_queued or _tween_running(scene._fan_tween)
		for slot: EnemySlot in scene.enemy_rack.slots:
			if not is_instance_valid(slot) or slot.fill == null: return _expect(label + " 敌方槽装配完整", false)
			waiting = waiting or _tween_running(slot._death_tween) or _tween_running(slot.fill.get_meta("tween") if slot.fill.has_meta("tween") else null)
		for hand_slot: Node in scene.hand_cards.get_children():
			if hand_slot is Control: waiting = waiting or not (hand_slot as Control).scale.is_equal_approx(Vector2.ONE) or (hand_slot as Control).modulate.a < 0.999
		if not waiting and scene._battle.phase == BattleStateMachine.Phase.PLAYER_ACTION: return true
		await get_tree().process_frame
	if is_instance_valid(scene) and scene._battle != null:
		print("FIXED_LAYOUT_TIMEOUT " + JSON.stringify({"label": label, "busy": scene._busy, "kind": scene._presentation_kind, "hand": scene._battle.hand.size(), "living": _living()}))
	return _expect(label + " 有界等待真实表现收尾", false)

func _expect_valid_battle() -> bool:
	if scene._battle == null or scene._resolver == null: return _expect("战斗装配失败即停止", false)
	if not scene._battle.active or scene._battle.rules.last_error != OK: return _expect("战斗规则有效且玩家存活", false)
	return true

func _click_enemy(id: String) -> bool:
	var slot: EnemySlot = scene.enemy_rack.slot_for(id)
	if not _expect("鼠标目标槽存在/" + id, slot != null): return false
	var point: Vector2 = _visible_click_point(slot)
	if not _expect("鼠标目标存在实际可见点击位置/" + id, point != Vector2.INF): return false
	await _click(point)
	return await _settled("鼠标目标切换/" + id)

func _click(point: Vector2) -> void:
	get_viewport().warp_mouse(point)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = point
	get_viewport().push_input(motion, true)
	for pressed: bool in [true, false]:
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.pressed = pressed
		get_viewport().push_input(event, true)
		await get_tree().process_frame

func _capture(label: String) -> bool:
	if DisplayServer.get_name() == "headless":
		skipped_images.append(label)
		return true
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = fixture_root.path_join(label + ".png")
	if not _expect(label + " 原生截图保存", image != null and image.save_png(path) == OK): return false
	if not _expect(label + " 原生截图分辨率正确", image.get_size() == get_window().size): return false
	images.append(path)
	return true

func _pose(id: String) -> Dictionary:
	var slot: EnemySlot = scene.enemy_rack.slot_for(id)
	if slot == null or slot.portrait == null: return {}
	return {"id": id, "instance": slot.get_instance_id(), "slot_position": _vector(slot.global_position), "portrait_size": _vector(slot.portrait.size), "portrait_rect": _rectangle(slot.portrait.get_global_rect())}

func _record(label: String) -> void:
	var poses: Array[Dictionary] = []
	for id: String in _living():
		poses.append(_pose(id) if scene.enemy_rack.slot_for(id) != null else {"id": id, "missing_view": true})
	records.append({"case": label, "window": [get_window().size.x, get_window().size.y], "living_ids": _living(), "poses": poses, "pose_samples": scene.pose_records.duplicate(true), "spawn_snapshots": scene.spawn_records.duplicate(true), "rendered_snapshots": scene.rendered_records.duplicate(true)})

func _context() -> BattleEffectContext:
	return BattleEffectContext.new(scene._battle, str(scene._battle.enemies[0]["enemy_id"]), scene._resolver.buff_catalog)

func _enemy(id: String) -> Dictionary:
	for enemy: Dictionary in scene._battle.enemies:
		if str(enemy["enemy_id"]) == id: return enemy
	return {}

func _living() -> Array[String]: return scene.living_ids(scene._battle.enemies)
func _tween_running(value: Variant) -> bool: return value is Tween and value.is_valid() and value.is_running()
func _vector(value: Vector2) -> Array: return [value.x, value.y]
func _rectangle(value: Rect2) -> Array: return [value.position.x, value.position.y, value.size.x, value.size.y]
func _rect(value: Array) -> Rect2: return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
func _same_rect(a: Rect2, b: Rect2) -> bool: return a.position.is_equal_approx(b.position) and a.size.is_equal_approx(b.size)
func _sorted(value: Array) -> Array:
	var result: Array = value.duplicate()
	result.sort()
	return result

func _expect(label: String, passed: bool) -> bool:
	checks += 1
	if not passed:
		failures += 1
		failure_labels.append(label)
	print(("PASS " if passed else "FAIL ") + label)
	return passed

func _release_scene() -> void:
	if is_instance_valid(scene): scene.free()
	scene = null
	original_reference = null
	ordinary_reference = null
	side_reference = null

func _finish() -> void:
	if finishing: return
	finishing = true
	if failures > 0 and is_instance_valid(scene) and scene._battle != null: _record("failure/latest")
	_release_scene()
	if not fixture_root.is_empty() and DirAccess.dir_exists_absolute(fixture_root):
		var report: FileAccess = FileAccess.open(fixture_root.path_join("report.json"), FileAccess.WRITE)
		if report != null:
			report.store_string(JSON.stringify({"checks": checks, "failures": failures, "failure_labels": failure_labels, "cases": records, "native_images": images, "headless_skipped_images": skipped_images, "headless_skipped_native_checks": skipped_native_checks}, "\t"))
			report.close()
		else:
			_expect("验收报告可写", false)
		for filename: String in ["game.json", "empty-board.json"]:
			for suffix: String in ["", ".tmp", ".bak"]:
				var path: String = fixture_root.path_join(filename) + suffix
				if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	print("THREE_ENEMY_FIXED checks=%d failures=%d evidence=%s" % [checks, failures, fixture_root])
	get_tree().quit(0 if failures == 0 else 1)

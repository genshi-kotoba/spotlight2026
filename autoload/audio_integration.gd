extends Node
## AudioIntegration：游戏逻辑 → Wwise 音频的桥接层（Autoload）。
##
## 不修改任何业务脚本，只监听场景树、全局信号与状态机信号，统一调用
## AudioService。所有事件名来自 Wwise/resources/wwise_ids.gd。
##
## 事件映射速查：
##   UI hover/click/back/panel              → SFX_001 ~ 005
##   卡牌 pickup/play/draw/shuffle/transform → SFX_006 / 007 / 008 / 009 / 034
##   战斗 pointer tick/turnchange           → SFX_010 / 033
##   玩家 hit/heal/death/lowhp/breath       → SFX_012 / 035 / 039 / 013 / 043 / 042
##   敌人 hit/death                         → SFX_014 / 044 / 015
##   战斗 block/buff/debuff                 → SFX_037 / 039 / 040
##   过渡 enter/exit/floor                  → SFX_022 / 024 / 023
##   地图 fogreveal/footsteps               → SFX_055 / SFX_Footsteps
##   药剂 select/use                        → SFX_052 / 053
##   典籍/奖励 gain/snap/link/chain         → SFX_051 / 048 / 049 / 050
##   State：Scene / Combat；RTPC：Player_Health / Deck_Size / Tension / Combo_Count

const AUDIO_SERVICE_PATH := "/root/AudioService"
const GLOBAL_STATE_PATH := "/root/GlobalState"
const MAP_EVENTS_PATH := "/root/MapEvents"

const UI_SFX := {
	"hover": "SFX_001_UI_Hover",
	"click": "SFX_002_UI_Click",
	"back": "SFX_003_UI_Back",
	"panel_open": "SFX_004_UI_Panel_Open",
	"panel_close": "SFX_005_UI_Panel_Close",
	"card_pickup": "SFX_006_CARD_Pickup",
	"card_play": "SFX_007_CARD_Play",
	"card_draw": "SFX_008_CARD_Draw",
	"card_shuffle": "SFX_009_CARD_Shuffle",
}
## 这些关键字命中的按钮走 SFX_003_UI_Back，其余走 SFX_002_UI_Click
const BACK_KEYWORDS_ZH := ["返回", "取消", "关闭", "离开"]
const BACK_KEYWORDS_EN := ["back", "cancel", "close"]

var _audio: Node
var _global: GlobalStateMachine
var _map_events: Node
var _current_run: RunStateMachine
var _current_battle: BattleStateMachine
var _connected_ui: Dictionary = {} # instance_id -> true
var _connected_battles: Dictionary = {} # BattleStateMachine instance_id -> true
var _connected_battle_uis: Dictionary = {} # BattleTestScene instance_id -> true
var _presented_relic_count := 0

# 当前环境声/场景状态，避免重复 post
var _current_scene_state := ""
var _current_ambient_event := ""
var _ambient_playing_id := 0
var _current_combat_state := ""

# 音乐：所有 mus_* 事件都指向同一个 Blend Container，只播一次，
# 用 Music_Combat RTPC 0/100 自动交叉淡化探索/战斗版。
const MUSIC_EVENT_DEFAULT := "mus_alchemy"
const MUSIC_EVENT_BY_SCENE := {
	"Workshop": "mus_alchemy",
	"Slum": "mus_alchemy",
	"Church": "mus_church",
	"ChurchTop": "mus_church",
}
const MUSIC_RTPC := "Music_Combat"
const MUSIC_EXPLORE_VALUE := 0.0
const MUSIC_BATTLE_VALUE := 100.0
## 换曲淡出时长（alchemy ↔ church）
const MUSIC_EVENT_FADE_MS := 4000
## Wwise 里 Music_Combat 的交叉区（截图：30–70）。
## 代码只在 30↔70 之间做坡度，实际交叉淡化时长 = MUSIC_CROSSFADE_SEC。
const MUSIC_RTPC_EDGE_LOW := 30.0
const MUSIC_RTPC_EDGE_HIGH := 70.0
const MUSIC_CROSSFADE_SEC := 2.5
const AMBIENT_FADE_MS := 800
var _music_playing_id := 0
var _music_mode_battle := false
var _current_music_event := ""
var _music_rtpc_tween: Tween
var _music_rtpc_value := 0.0
## 场景过渡黑屏期间先记待切，等 transition_finished 再真正切歌
var _scene_transition: Node
var _music_apply_pending := false
var _menu_music_pending := false

# 脚步：生产地图用 MapEvents.player_cell_entered，进图那一次不算迈步
## 用格子间隔估计步频，再用 Timer 按平滑节奏播放，避免逐格触发忽快忽慢
const FOOTSTEP_INTERVAL_MIN_MS := 200.0
const FOOTSTEP_INTERVAL_MAX_MS := 520.0
## 格子间隔乘以该系数后再当步频，拉大整体步距
const FOOTSTEP_INTERVAL_SCALE := 1.35
const FOOTSTEP_WALK_HOLD_MS := 350
const FOOTSTEP_SUPPRESS_AFTER_MAP_MS := 500
var _footstep_map_id := ""
var _footstep_primed := false
var _footstep_suppress_until_ms := 0
var _footstep_last_cell_ms := 0
var _footstep_walking_until_ms := 0
var _footstep_interval_ms := 300.0
var _footstep_timer: Timer

# Combo：当前回合已生效（结算完成）的牌数，映射到 Combo_Count RTPC（0-15）
var _combo_count := 0

# 低血呼吸（循环事件，需要记住 playing_id 以便恢复时停掉）
const BREATH_THRESHOLD := 0.30
var _breath_playing_id := 0

# 书写音效节流（monster 战斗文本逐句播会糊）
const PENWRITE_COOLDOWN_MS := 4500
var _penwrite_last_ms := -PENWRITE_COOLDOWN_MS

# 地图层切换检测（map_id 形如 xxx:floor-001）
var _last_loaded_map_id := ""

# 结算类音效队列：防止一帧内多个伤害/格挡/Buff 同时炸开
const RESOLUTION_SOUND_INTERVAL_SEC := 0.10
var _resolution_queue: Array[String] = []
var _resolution_timer: Timer

# bank 加载前的 UI 音效缓冲：刚进主菜单时 AudioService 可能还没 ready
const PENDING_SOUND_MAX := 32
var _pending_sounds: Array[String] = []
var _banks_loaded := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audio = get_node_or_null(AUDIO_SERVICE_PATH)
	if _audio == null:
		push_warning("AudioIntegration: AudioService autoload 未找到")
		return
	if _audio.is_ready:
		_banks_loaded = true
	else:
		_audio.banks_loaded.connect(_on_banks_loaded)

	_resolution_timer = Timer.new()
	_resolution_timer.name = "ResolutionSoundTimer"
	_resolution_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_resolution_timer.one_shot = false
	_resolution_timer.wait_time = RESOLUTION_SOUND_INTERVAL_SEC
	_resolution_timer.timeout.connect(_on_resolution_timer_timeout)
	add_child(_resolution_timer)

	_footstep_timer = Timer.new()
	_footstep_timer.name = "FootstepTimer"
	_footstep_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_footstep_timer.one_shot = false
	_footstep_timer.wait_time = _footstep_interval_ms / 1000.0
	_footstep_timer.timeout.connect(_on_footstep_tick)
	add_child(_footstep_timer)

	_scene_transition = get_node_or_null("/root/SceneTransition")
	if _scene_transition != null:
		if _scene_transition.has_signal("transition_finished"):
			_scene_transition.transition_finished.connect(_on_scene_transition_finished)
		if _scene_transition.has_signal("transition_failed"):
			_scene_transition.transition_failed.connect(_on_scene_transition_failed)

	_global = get_node_or_null(GLOBAL_STATE_PATH)
	if _global != null:
		_global.run_started.connect(_on_run_started)
		_global.run_continued.connect(_on_run_started)
		_global.run_finished.connect(_on_run_finished)

	_map_events = get_node_or_null(MAP_EVENTS_PATH)
	if _map_events != null:
		_map_events.map_loaded.connect(_on_map_loaded)
		_map_events.player_cell_entered.connect(_on_player_cell_entered)
		_map_events.boss_cleared.connect(_on_boss_cleared)
		_map_events.node_interaction_requested.connect(_on_node_interaction)

	# 自动给之后进入场景树的 Button / HSlider / MapScene / BattleStateMachine 接线
	if get_tree() != null:
		get_tree().node_added.connect(_on_node_added)


# ------------------------------------------------------------------ 场景树监听

func _on_node_added(node: Node) -> void:
	if node is Button:
		_connect_button(node)
	elif node is HSlider:
		_connect_slider(node)
	elif node is MapScene:
		# MapScene 的 @onready 成员要等 _ready 后才赋值
		node.ready.connect(_connect_map_scene.bind(node), CONNECT_ONE_SHOT)
	elif node is BattleStateMachine:
		_connect_battle(node)
	elif node is BattleTestScene:
		_connect_battle_ui(node)
	elif node is RunMenuOverlay:
		node.visibility_changed.connect(_on_run_menu_visibility_changed.bind(node))
	elif node is MonsterBattleText:
		node.sentence_started.connect(_on_monster_text_sentence)


func _connect_button(btn: Button) -> void:
	var id := btn.get_instance_id()
	if _connected_ui.has(id):
		return
	_connected_ui[id] = true
	btn.mouse_entered.connect(_play_ui.bind(UI_SFX["hover"]))
	btn.pressed.connect(_on_ui_button_pressed.bind(btn))
	btn.tree_exited.connect(func() -> void: _connected_ui.erase(id))


func _on_ui_button_pressed(btn: Button) -> void:
	if _is_close_button(btn):
		_play_ui(UI_SFX["panel_close"])
	elif _is_back_button(btn):
		_play_ui(UI_SFX["back"])
	else:
		_play_ui(UI_SFX["click"])


func _is_close_button(btn: Button) -> bool:
	for candidate: String in [btn.text, String(btn.name), btn.tooltip_text]:
		if candidate.contains("关闭"):
			return true
		var lower := candidate.to_lower()
		if lower == "close" or lower.begins_with("close"):
			return true
	return false


## 背包/设置/地图浮层（RunMenuOverlay）显隐即面板开合。
func _on_run_menu_visibility_changed(menu: RunMenuOverlay) -> void:
	if menu.visible:
		_play_ui(UI_SFX["panel_open"])
	else:
		_play_ui(UI_SFX["panel_close"])


## 按按钮当前文案/节点名判断是不是「返回/取消/关闭」类操作。
func _is_back_button(btn: Button) -> bool:
	for candidate: String in [btn.text, String(btn.name), btn.tooltip_text]:
		if candidate.is_empty():
			continue
		for keyword: String in BACK_KEYWORDS_ZH:
			if candidate.contains(keyword):
				return true
		var lower := candidate.to_lower()
		for keyword: String in BACK_KEYWORDS_EN:
			if lower == keyword or lower.begins_with(keyword):
				# 排除 Backpack / Background 这类同前缀但语义不同的节点
				if keyword == "back" and (lower.begins_with("backpack") or lower.begins_with("background")):
					continue
				return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_play_ui(UI_SFX["back"])


func _connect_slider(slider: HSlider) -> void:
	var id := slider.get_instance_id()
	if _connected_ui.has(id):
		return
	_connected_ui[id] = true
	slider.mouse_entered.connect(_play_ui.bind(UI_SFX["hover"]))
	slider.tree_exited.connect(func() -> void: _connected_ui.erase(id))


# ------------------------------------------------------------------ Run / 成就

func _on_run_started(run: RunStateMachine) -> void:
	_current_run = run
	_update_deck_size_rtpc(run)
	run.stat_updated.connect(_on_run_stat_updated)
	run.battle_started.connect(_on_run_battle_started)


func _on_run_battle_started(battle: BattleStateMachine) -> void:
	# _connect_battle 会在 node_added 时设置 _current_battle 并清理 tree_exited
	_current_battle = battle


func _on_run_finished(result: Dictionary) -> void:
	_current_combat_state = ""
	# 结束返回主菜单/地图时保持 Explore 状态
	_set_combat_state("Explore")
	_stop_music()


func _on_run_stat_updated(metric: StringName, value: Variant) -> void:
	match metric:
		&"deck_size":
			_set_rtpc("Deck_Size", _deck_size_to_rtpc(int(value)))
		&"health":
			if _current_run != null:
				_update_health_rtpc(int(value), _current_run.max_health)


# ------------------------------------------------------------------ 地图

func _connect_map_scene(scene: MapScene) -> void:
	if scene.mover != null:
		scene.mover.tile_entered.connect(_on_map_tile_entered.bind(scene.map_id))
	scene.map_node_entered.connect(_on_map_node_entered)
	# 直接加载的场景可能没有触发 MapEvents.map_loaded，这里兜底
	_call_deferred_set_scene_from_map(scene.map_id)


func _on_map_loaded(map_id: String, _seed: String) -> void:
	# 换层转场：同一地图从战斗返回不算
	if not _last_loaded_map_id.is_empty() and map_id != _last_loaded_map_id \
			and map_id.contains(":floor-") and _last_loaded_map_id.contains(":floor-"):
		_play("SFX_023_Trans_FloorChange")
	_last_loaded_map_id = map_id
	_footstep_map_id = map_id
	_footstep_primed = false
	# 换层/读图后的落点与传送帧不算迈步
	_footstep_suppress_until_ms = Time.get_ticks_msec() + FOOTSTEP_SUPPRESS_AFTER_MAP_MS
	_footstep_last_cell_ms = 0
	_footstep_walking_until_ms = 0
	_footstep_interval_ms = 300.0
	if _footstep_timer != null:
		_footstep_timer.stop()
	_set_scene_from_map(map_id)


## 生产地图（map_demo/map_run_demo）每走一格发一次；进图那一次是落点，不算迈步。
## 逐格只用来估计步频与维持“行走中”状态，真正发声由 _on_footstep_tick 按节拍播。
func _on_player_cell_entered(map_id: String, _coord: Vector2i) -> void:
	if map_id != _footstep_map_id:
		_footstep_map_id = map_id
		_footstep_primed = false
	if not _footstep_primed:
		_footstep_primed = true
		return
	var now := Time.get_ticks_msec()
	if now < _footstep_suppress_until_ms:
		return
	# 用格子间隔估计步频，平滑到合理区间
	if _footstep_last_cell_ms > 0:
		var delta := float(now - _footstep_last_cell_ms)
		if delta >= 40.0 and delta <= 1500.0:
			_footstep_interval_ms = lerpf(_footstep_interval_ms,
				clampf(delta * FOOTSTEP_INTERVAL_SCALE,
					FOOTSTEP_INTERVAL_MIN_MS, FOOTSTEP_INTERVAL_MAX_MS), 0.35)
	_footstep_last_cell_ms = now
	_footstep_walking_until_ms = now + FOOTSTEP_WALK_HOLD_MS
	if _footstep_timer.is_stopped():
		_play_footstep(map_id)
		_footstep_timer.wait_time = _footstep_interval_ms / 1000.0
		_footstep_timer.start()


func _on_footstep_tick() -> void:
	var now := Time.get_ticks_msec()
	if now > _footstep_walking_until_ms:
		_footstep_timer.stop()
		_footstep_last_cell_ms = 0
		return
	_footstep_timer.wait_time = _footstep_interval_ms / 1000.0
	_play_footstep(_footstep_map_id)


func _play_footstep(map_id: String) -> void:
	var material := _guess_foot_material(map_id)
	if not material.is_empty():
		_set_switch("Foot_Material", material)
	_play("SFX_Footsteps")


func _on_map_tile_entered(_coord: Vector2i, map_id: String) -> void:
	# 脚步：根据地图粗猜材质；可在 MapScene/map_id 里细化
	var material := _guess_foot_material(map_id)
	if not material.is_empty():
		_set_switch("Foot_Material", material)
	_play("SFX_Footsteps")


func _on_map_node_entered(_node_id: String, kind: int, _coord: Vector2i) -> void:
	# MapNodeKind 枚举未知，这里用保守映射：kind 值需要具体看 MapNodeKind
	# 0=战斗, 1=事件, 2=奖励, 3=商店, 4=休息, 5=Boss 等常见约定
	match kind:
		2:
			_play("SFX_051_Relic_Gain")
		3:
			_play("SFX_052_Potion_Select")
		_:
			_play(UI_SFX["click"])


func _on_boss_cleared(map_id: String, _node_id: String) -> void:
	_play("SFX_055_MAP_FogReveal")
	_set_scene_from_map(map_id)


func _on_node_interaction(request: Dictionary) -> void:
	var kind: int = request.get("kind", -1)
	match kind:
		2:
			_play("SFX_051_Relic_Gain")
		3:
			_play("SFX_053_Potion_Use")
		_:
			_play(UI_SFX["panel_open"])


# ------------------------------------------------------------------ 战斗

func _connect_battle(battle: BattleStateMachine) -> void:
	var id := battle.get_instance_id()
	if _connected_battles.has(id):
		return
	_connected_battles[id] = true
	_current_battle = battle
	battle.tree_exited.connect(func() -> void:
		_connected_battles.erase(id)
		if _current_battle == battle:
			_current_battle = null
	)
	# 生命周期与即时操作：走状态机
	battle.battle_started.connect(_on_battle_started)
	battle.battle_ended.connect(_on_battle_ended)
	battle.card_drawn.connect(_on_card_drawn)
	battle.discard_pile_shuffled.connect(_on_discard_pile_shuffled)
	# 血量 RTPC 需要原始数值：只更新 RTPC，不发声（发声交给表现层）
	battle.combatant_damaged.connect(_on_battle_health_changed)
	battle.combatant_healed.connect(_on_battle_health_changed_heal)
	# 存档恢复的战斗不会再发 battle_started，延后一帧检查 active 状态补同步
	call_deferred("_sync_restored_battle", battle)


func _on_battle_started(snapshot: Dictionary) -> void:
	_presented_relic_count = 0
	_combo_count = 0
	_set_rtpc("Combo_Count", 0.0)
	_set_combat_state("Battle")
	_apply_music_for_state()
	_play("SFX_022_TRANS_EnterBattle")
	var player: Dictionary = snapshot.get("player", {})
	_update_health_rtpc(int(player.get("health", 0)), int(player.get("max_health", 100)))


func _on_battle_ended(_result: Dictionary) -> void:
	_stop_breath()
	# 战斗音乐先保留：领奖励、看结算时还应该听到战斗版，
	# 真正回地图的 exit_battle 才切回探索。
	_set_combat_state("Explore")


## 冷恢复的战斗已经 active，但不会再次 emit battle_started。
func _sync_restored_battle(battle: BattleStateMachine) -> void:
	if not is_instance_valid(battle) or not battle.active:
		return
	_current_battle = battle
	_presented_relic_count = 0
	_combo_count = 0
	_set_rtpc("Combo_Count", 0.0)
	_set_combat_state("Battle")
	var player: Dictionary = battle.player
	_update_health_rtpc(int(player.get("health", 0)), int(player.get("max_health", 100)))
	_apply_music_for_state()


func _on_card_drawn(_card: Dictionary, _hand_size: int) -> void:
	_play(UI_SFX["card_draw"])


func _on_discard_pile_shuffled(_draw_pile_size: int) -> void:
	_play(UI_SFX["card_shuffle"])


## 怪物战斗文本逐句出现；书写音 3~4 秒，节流避免叠成一片。
func _on_monster_text_sentence(text: String, _bounds: Rect2) -> void:
	if text.strip_edges().is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _penwrite_last_ms < PENWRITE_COOLDOWN_MS:
		return
	_penwrite_last_ms = now
	_play("SFX_058_Voice_PenWrite")


## 只更新 RTPC，不发声；伤害/治疗音效由表现层 presentation_event 触发。
func _on_battle_health_changed(side: StringName, _entity_id: String,
		_damage: int, _blocked: int, health_after: int) -> void:
	if side != &"player":
		return
	var max_health := 100
	if _current_battle != null and not _current_battle.player.is_empty():
		max_health = int(_current_battle.player.get("max_health", 100))
	_update_health_rtpc(health_after, max_health)


func _on_battle_health_changed_heal(side: StringName, _entity_id: String,
		_amount: int, health_after: int) -> void:
	if side != &"player":
		return
	var max_health := 100
	if _current_battle != null and not _current_battle.player.is_empty():
		max_health = int(_current_battle.player.get("max_health", 100))
	_update_health_rtpc(health_after, max_health)


# ------------------------------------------------------------------ 战斗表现层

## BattleTestScene 的异步回放管线：在这里发声才和画面同帧。
func _connect_battle_ui(ui: BattleTestScene) -> void:
	var id := ui.get_instance_id()
	if _connected_battle_uis.has(id):
		return
	_connected_battle_uis[id] = true
	ui.presentation_event.connect(_on_battle_presentation)
	ui.tree_exited.connect(func() -> void: _connected_battle_uis.erase(id))


func _on_battle_presentation(kind: String, data: Dictionary) -> void:
	match kind:
		"card_committed":
			_play(UI_SFX["card_play"])
		"card_start":
			# 先加 combo 再播声音：RTPC 在音效开始前就位，避免播到一半变调
			_combo_count = mini(_combo_count + 1, 15)
			_set_rtpc("Combo_Count", float(_combo_count))
			var pointer := int(data.get("pointer", 0))
			_set_switch("Pointer_Position", "Pos_%d" % clampi(pointer + 1, 1, 8))
		"pointer_moved":
			# 指针前进才播 tick；回退不播（011 已砍）
			var to := int(data.get("to", 0))
			if to > int(data.get("from", 0)):
				_set_switch("Pointer_Position", "Pos_%d" % clampi(to + 1, 1, 8))
				_play_resolution("SFX_010_BATTLE_Pointer_Tick")

		"damage":
			_on_presented_damage(data)
		"block":
			_play_resolution("SFX_037_BATTLE_Block")
		"heal":
			_play_resolution("SFX_039_BATTLE_BuffGain")
		"buff":
			_on_presented_buff(data)
		"card_discarded":
			_play_resolution(UI_SFX["card_pickup"])
		"card_end":
			# combo 已在 card_start 累加；这里只保留收尾时机，不再改 RTPC
			pass
		"enemy_turn":
			_play("SFX_033_BATTLE_TurnChange")
		"turn_started":
			_combo_count = 0
			_set_rtpc("Combo_Count", 0.0)
			if int(data.get("turn", 0)) > 1:
				_play("SFX_033_BATTLE_TurnChange")
		"relic_completed":
			_on_presented_relic_completed()
		"exit_battle":
			_stop_breath()
			_play("SFX_024_Trans_ExitBattle")
			_apply_music_for_state()


func _on_presented_damage(data: Dictionary) -> void:
	var side := StringName(str(data.get("side", "")))
	var damage := int(data.get("damage", 0))
	var blocked := int(data.get("blocked", 0))
	if side == &"player":
		if blocked > 0:
			_play_resolution("SFX_059_BATTLE_HitBlocked")
		elif damage >= 10:
			_play_resolution("SFX_035_PLAYER_Hit_Heavy")
		else:
			_play_resolution("SFX_012_PLAYER_Hit_Light")
	else:
		if blocked > 0:
			_play_resolution("SFX_059_BATTLE_HitBlocked")
		elif damage >= 8:
			_play_resolution("SFX_044_ENEMY_HitPlayer")
		else:
			_play_resolution("SFX_014_ENEMY_Hit_Light")


func _on_presented_buff(data: Dictionary) -> void:
	var buff: Dictionary = data.get("buff", {})
	var buff_id := String(buff.get("buff_id", "")).to_lower()
	if buff_id in ["weak", "poison", "frail", "vulnerable"]:
		_play_resolution("SFX_040_BATTLE_DebuffGain")
	else:
		_play_resolution("SFX_039_BATTLE_BuffGain")


func _on_presented_relic_completed() -> void:
	_presented_relic_count += 1
	if _presented_relic_count % 3 == 0:
		_play_resolution("SFX_050_RELIC_ChainTrigger")
	elif _presented_relic_count % 3 == 1:
		_play_resolution("SFX_048_RELIC_Snap")
	else:
		_play_resolution("SFX_049_RELIC_Link")


# ------------------------------------------------------------------ State / RTPC / Ambient 工具

func _set_scene_from_map(map_id: String) -> void:
	var state := _map_id_to_scene_state(map_id)
	if state == _current_scene_state:
		# 场景没变（比如新局重进同一层）时，若音乐被停过则重新起
		if _current_combat_state != "Battle" and _music_playing_id == 0:
			_apply_music_for_state()
		return
	_current_scene_state = state
	if _audio != null and _audio.is_ready:
		_audio.set_state("Scene", state)
	_apply_ambient(state)
	# 地图里切场景时，若不在战斗中则切 calm 音乐
	if _current_combat_state != "Battle":
		_apply_music_for_state()


## 环境声是 Infinite 循环：换场景时先停旧的，再播新的，避免叠声。
func _apply_ambient(state: String) -> void:
	var ambient := _scene_state_to_ambient(state)
	if ambient == _current_ambient_event:
		return
	_current_ambient_event = ambient
	if _audio == null or not _audio.is_ready:
		return
	if _ambient_playing_id != 0:
		_audio.stop_event(_ambient_playing_id, AMBIENT_FADE_MS)
		_ambient_playing_id = 0
	if not ambient.is_empty():
		var playing_id: int = _audio.play(ambient)
		if playing_id > 0:
			_ambient_playing_id = playing_id


## 按当前 Scene / Combat 状态切 calm 或 battle 音乐；同一首不重播。
## 冷启动/存档恢复时场景状态可能还没从地图事件里拿到，用当前局的 map_id 兜底。
func _apply_music_for_state() -> void:
	if _is_transitioning():
		_music_apply_pending = true
		return
	_apply_music_for_state_now()


func _apply_music_for_state_now() -> void:
	var scene := _current_scene_state
	if scene.is_empty() and is_instance_valid(_current_run):
		scene = _map_id_to_scene_state(_current_run.current_map_id)
	_set_music_mode(_current_combat_state == "Battle", scene)


## 只播一次 Blend Container；探索/战斗通过 Music_Combat 自动交叉淡化。
func _set_music_mode(battle: bool, scene: String) -> void:
	_music_mode_battle = battle
	if _audio == null or not _audio.is_ready:
		return
	var event_name: String = MUSIC_EVENT_BY_SCENE.get(scene, MUSIC_EVENT_DEFAULT)
	var switching_event := event_name != _current_music_event or _music_playing_id == 0
	if switching_event:
		# 换曲时直接对齐到目标静区，再 post，避免新事件从默认交叉位置开始
		_set_music_rtpc(MUSIC_BATTLE_VALUE if battle else MUSIC_EXPLORE_VALUE)
	else:
		_ramp_music_mode(battle)
	_ensure_music_playing(event_name)


## 只在 30↔70 之间推 RTPC；两端的静区直接跳过去，保证淡变时长就是 2.5s。
func _ramp_music_mode(battle: bool) -> void:
	if _audio == null or not _audio.is_ready:
		return
	var from := _music_rtpc_value
	var to_edge := MUSIC_RTPC_EDGE_HIGH if battle else MUSIC_RTPC_EDGE_LOW
	var final_value := MUSIC_BATTLE_VALUE if battle else MUSIC_EXPLORE_VALUE
	if battle and from < MUSIC_RTPC_EDGE_LOW:
		_apply_music_rtpc(MUSIC_RTPC_EDGE_LOW)
		from = MUSIC_RTPC_EDGE_LOW
	elif not battle and from > MUSIC_RTPC_EDGE_HIGH:
		_apply_music_rtpc(MUSIC_RTPC_EDGE_HIGH)
		from = MUSIC_RTPC_EDGE_HIGH
	var span := MUSIC_RTPC_EDGE_HIGH - MUSIC_RTPC_EDGE_LOW
	var duration := MUSIC_CROSSFADE_SEC * clampf(absf(to_edge - from) / span, 0.0, 1.0)
	if duration <= 0.001:
		_apply_music_rtpc(final_value)
		return
	if _music_rtpc_tween != null and _music_rtpc_tween.is_valid():
		_music_rtpc_tween.kill()
	_music_rtpc_tween = create_tween()
	_music_rtpc_tween.set_trans(Tween.TRANS_LINEAR)
	_music_rtpc_tween.tween_method(_apply_music_rtpc, from, to_edge, duration)
	_music_rtpc_tween.finished.connect(func() -> void: _apply_music_rtpc(final_value))


## 音乐交叉淡化 RTPC 显式设在默认 2D 发声对象上，
## 避免某些 Blend 交叉只读 game object 作用域的值。
func _set_music_rtpc(value: float) -> void:
	if _audio == null or not _audio.is_ready:
		return
	if _music_rtpc_tween != null and _music_rtpc_tween.is_valid():
		_music_rtpc_tween.kill()
	_apply_music_rtpc(value)


func _apply_music_rtpc(value: float) -> void:
	_music_rtpc_value = value
	if _audio == null or not _audio.is_ready:
		return
	var target: Node = _audio.default_game_object
	_audio.set_rtpc(MUSIC_RTPC, value, target)


func _ensure_music_playing(event_name: String) -> void:
	if event_name == _current_music_event and _music_playing_id != 0:
		return
	if _audio == null or not _audio.is_ready:
		return
	if _music_playing_id != 0:
		_audio.stop_event(_music_playing_id, MUSIC_EVENT_FADE_MS)
		_music_playing_id = 0
	var playing_id: int = _audio.play(event_name)
	if playing_id > 0:
		_music_playing_id = playing_id
		_current_music_event = event_name


func _is_transitioning() -> bool:
	return _scene_transition != null and _scene_transition.has_method("is_loading") \
		and bool(_scene_transition.call("is_loading"))


func _on_scene_transition_finished(_path: String) -> void:
	if _menu_music_pending:
		_menu_music_pending = false
		_music_apply_pending = false
		_play_menu_music_now()
	elif _music_apply_pending:
		_music_apply_pending = false
		_apply_music_for_state_now()


func _on_scene_transition_failed(_path: String, _error: int) -> void:
	_on_scene_transition_finished(_path)


## 主菜单音乐（第 1/2 层 calm）；进图后由 _set_scene_from_map 接管。
func play_menu_music() -> void:
	if _is_transitioning():
		_menu_music_pending = true
		return
	_menu_music_pending = false
	_play_menu_music_now()


func _play_menu_music_now() -> void:
	_current_scene_state = ""
	_current_combat_state = ""
	if _audio != null and _audio.is_ready:
		_audio.set_state("Scene", "None")
		_audio.set_state("Combat", "Explore")
	_stop_ambient()
	_stop_breath()
	_set_music_rtpc(MUSIC_EXPLORE_VALUE)
	_ensure_music_playing(MUSIC_EVENT_DEFAULT)


func _stop_ambient() -> void:
	if _ambient_playing_id != 0 and _audio != null and _audio.is_ready:
		_audio.stop_event(_ambient_playing_id, AMBIENT_FADE_MS)
	_ambient_playing_id = 0
	_current_ambient_event = ""


func _stop_music() -> void:
	if _music_playing_id != 0 and _audio != null and _audio.is_ready:
		_audio.stop_event(_music_playing_id, MUSIC_EVENT_FADE_MS)
	_music_playing_id = 0
	_music_mode_battle = false
	_current_music_event = ""


func _call_deferred_set_scene_from_map(map_id: String) -> void:
	call_deferred("_set_scene_from_map", map_id)


func _set_combat_state(state: String) -> void:
	if state == _current_combat_state:
		return
	_current_combat_state = state
	if _audio != null and _audio.is_ready:
		_audio.set_state("Combat", state)


func _set_switch(group: String, value: String) -> void:
	if _audio != null and _audio.is_ready:
		_audio.set_switch(group, value)


func _set_rtpc(name: String, value: float) -> void:
	if _audio != null and _audio.is_ready:
		_audio.set_rtpc(name, value)


func _update_health_rtpc(health: int, max_health: int) -> void:
	if max_health <= 0:
		return
	var ratio := clampf(float(health) / float(max_health), 0.0, 1.0)
	_set_rtpc("Player_Health", ratio * 100.0)
	# Tension 与血量反向：残血高张力
	_set_rtpc("Tension", (1.0 - ratio) * 100.0)
	_update_breath(ratio)


## 低血呼吸循环：只在战斗进行中、低血且未死亡时开；其余情况一律停。
func _update_breath(ratio: float) -> void:
	var in_battle := _current_battle != null and _current_battle.active
	if ratio <= 0.0 or not in_battle:
		_stop_breath()
		return
	if ratio <= BREATH_THRESHOLD:
		if _breath_playing_id == 0 and _audio != null and _audio.is_ready:
			var playing_id: int = _audio.play("SFX_042_Player_Breath")
			if playing_id > 0:
				_breath_playing_id = playing_id
	else:
		_stop_breath()


func _stop_breath() -> void:
	if _breath_playing_id != 0 and _audio != null and _audio.is_ready:
		_audio.stop_event(_breath_playing_id)
	_breath_playing_id = 0


func _update_deck_size_rtpc(run: RunStateMachine) -> void:
	_set_rtpc("Deck_Size", _deck_size_to_rtpc(run.deck.size()))


func _deck_size_to_rtpc(size: int) -> float:
	# 牌组常见范围 10~40，映射到 0~100
	return clampf(size / 40.0 * 100.0, 0.0, 100.0)


# ------------------------------------------------------------------ 事件播放工具

func _play(event_name: String) -> void:
	if _audio == null:
		return
	if _audio.is_ready:
		_audio.play(event_name)
	elif _pending_sounds.size() < PENDING_SOUND_MAX:
		_pending_sounds.append(event_name)


func _play_ui(event_name: String) -> void:
	_play(event_name)


func _on_banks_loaded() -> void:
	_banks_loaded = true
	# 补播 bank 加载前被缓存的 UI 音效（数量不多，直接顺序播放）
	for event_name in _pending_sounds:
		if _audio != null:
			_audio.play(event_name)
	_pending_sounds.clear()


## 结算类音效进队列，避免同一帧大量伤害/格挡/Buff 同时炸开
func _play_resolution(event_name: String) -> void:
	if _audio == null or not _audio.is_ready:
		return
	if _resolution_timer.is_stopped():
		# 没有正在播放的序列：立刻播这一声，并启动 timer 处理后续排队
		_audio.play(event_name)
		_resolution_timer.start()
	else:
		_resolution_queue.append(event_name)


func _on_resolution_timer_timeout() -> void:
	if _resolution_queue.is_empty():
		_resolution_timer.stop()
		return
	var event_name: String = _resolution_queue.pop_front()
	if _audio != null and _audio.is_ready:
		_audio.play(event_name)


# ------------------------------------------------------------------ 映射表

func _map_id_to_scene_state(map_id: String) -> String:
	var lower := map_id.to_lower()
	if lower.contains("churchtop") or (lower.contains("church") and lower.contains("top")):
		return "ChurchTop"
	if lower.contains("church"):
		return "Church"
	if lower.contains("slum"):
		return "Slum"
	if lower.contains("workshop"):
		return "Workshop"
	# 生产地图 ID 形如 world:floor-001，按楼层映射场景
	var marker := lower.find("floor-")
	if marker >= 0:
		match int(lower.substr(marker + 6)):
			1:
				return "Workshop"
			2:
				return "Slum"
			3:
				return "Church"
			4:
				return "ChurchTop"
	return "None"


func _scene_state_to_ambient(state: String) -> String:
	match state:
		"Workshop":
			return "SFX_016_AMB_Workshop"
		"Slum":
			return "SFX_017_AMB_Slum"
		"Church":
			return "SFX_018_AMB_Church"
		"ChurchTop":
			return "SFX_019_AMB_ChurchTop"
		_:
			return ""


func _guess_foot_material(map_id: String) -> String:
	# 第一层木、第二层泥、第三/四层石
	match _map_id_to_scene_state(map_id):
		"Slum":
			return "Mud"
		"Church", "ChurchTop":
			return "Stone"
		_:
			return "Wood"



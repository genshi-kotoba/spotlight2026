class_name BattleTestScene
extends Control

## 战斗表现事件：在 _drain_resolution_events() 里按画面节奏逐条发出，
## 音频等表现层订阅它即可与画面同帧（而不是跟随状态机的同步 drain）。
signal presentation_event(kind: String, data: Dictionary)

## 可在检查器调整的测试参数。
@export_range(0, 20, 1) var initial_draw_count := 6
@export_range(1, 20, 1) var play_limit := 3
@export_range(0, 20, 1) var per_turn_draw_count := 3
## 结算收尾的上限。有真实效果反馈的牌实际等待跟着这张牌播出的动画走（见
## `CombatFeedback.card_animation_time`），只有上限才用这个数；上限与动画时长的
## 比例在 `FEEDBACK_SETTLE_SHARE`。
@export_range(0.05, 3.0, 0.05) var resolution_delay := 0.45
## 只改指针位置的牌没有结算内容，收尾等待压到最短。
@export_range(0.0, 1.0, 0.01) var pointer_only_delay := 0.12
## 整串结算的名义预算：一手 10 张有效果的牌约 10 秒。接近预算后自动提速，超出后加速收尾。
@export_range(2.0, 30.0, 0.5) var resolution_budget := 10.0
## 指针跳过这么多格之后开始提速。一手 10 张正好 10 格，多出来的多是多重释放的反复结算。
@export_range(1, 30, 1) var resolution_speedup_after := 10
## 常规提速的上限。再快就看不清指针落点，重结算部分另有应急档。
@export_range(1.0, 5.0, 0.1) var resolution_max_speed := 2.2
@export_range(0.05, 3.0, 0.05) var enemy_turn_delay := 0.75
## 每次行动与每段攻击独立播放，避免低伤害连击在同帧覆盖；不阻塞规则队列。
@export_range(0.0, 1.0, 0.01) var enemy_action_delay := 0.12
@export_range(0.15, 1.0, 0.01) var enemy_hit_delay := 0.32
@export_range(1.0, 2.0, 0.05) var hand_hover_multiplier := 1.5
## 悬停放大用短过渡：0.42 的弹簧节奏经试玩判定为拖沓。
@export_range(0.0, 1.0, 0.01) var hand_hover_duration := 0.06
@export_range(0.0, 1.0, 0.01) var hand_hover_return_duration := 0.18
@export var relic_board_path := RelicBoard.SAVE_PATH
@export_range(1, 99999, 1) var enemy_starting_health := 3000
## 独立测试战场可直接在检查器预览四层；正式战斗由开战存档决定。
@export_range(1, 4, 1) var test_floor_index := 1
## -1 使用楼层默认背景，其他值预览本层对应差分；不消耗随机流。
@export_range(-1, 8, 1) var test_background_variant := -1
## 测试局里同时出现几个敌人。默认 2，用来眼验多敌人排布、点选箭头与悬停光晕；
## 断言「一次致死出牌即结束战斗」的单敌人测试把它设回 1。
@export_range(1, 4, 1) var test_enemy_count := 2

## 手牌悬停扇开，规则与取值参考 reference/card-and-dice 的 HandUIController.Hover：
## 距悬停卡 1/2/3 张分别外移大/中/小距离，手牌越多幅度越小（10 张时只剩 10%）。
@export_range(0.0, 120.0, 1.0) var fan_offset_long := 58.0
@export_range(0.0, 120.0, 1.0) var fan_offset_medium := 40.0
@export_range(0.0, 120.0, 1.0) var fan_offset_short := 17.0
@export_range(0.05, 1.0, 0.01) var fan_duration_in := 0.15
@export_range(0.05, 1.0, 0.01) var fan_duration_out := 0.18
## 按手牌张数缩放的扇开系数，下标即张数（1~10，0 位弃用）。
@export var fan_factor_by_count: Array[float] = [
	0.0, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6,
]

## 打击感参数。档位判定见 CombatFeedback.tier_of，这里只放时长、振幅与节拍。
@export_range(0.0, 0.3, 0.01) var hitstop_medium := 0.05
@export_range(0.0, 0.3, 0.01) var hitstop_heavy := 0.09
@export_range(0.0, 0.3, 0.01) var hitstop_kill := 0.12
@export_range(0.0, 2.0, 0.05) var kill_beat_time := 0.45

const HAND_CARD_SCALE := 0.285
const PLAY_CARD_SCALE := HAND_CARD_SCALE * 0.5
const PLAY_CARD_SIZE := Vector2(480.0, 818.0) * PLAY_CARD_SCALE
## 出牌列始终单列，超过可见高度时纵向滚动。
const PLAY_ROW_SIZE := Vector2(PLAY_CARD_SIZE.x + PLAY_POINTER_W, PLAY_CARD_SIZE.y)
const PLAY_POINTER_W := 62.0
## 露出卡图与卡名，按 main 的手牌一半比例计算间距。
const PLAY_STEP := 83.0
const PILE_CARD_SCALE := 0.40
const HAND_SLOT_COUNT := 10
const HAND_CARD_SIZE := Vector2(480.0, 818.0) * HAND_CARD_SCALE
## 手牌行的最小宽度：与手牌视口同宽，左右各留悬停生长余量。
const HAND_AREA_WIDTH := 1178.0
## 悬停放大时卡面向左右各生长 32.4，行首尾留出同样余量，避免贴边被视口裁掉。
const HAND_HOVER_MARGIN := 34.0
const HAND_AREA_HEIGHT := 332.0
const HAND_GAP := 6.0
const HAND_ARC_SPREAD := 0.045
const HAND_ARC_RADIUS := 900.0
const HAND_MAX_WIDTH := 880.0
## 拖拽引起的收扇 / 开扇滑动时长。
const HAND_RELAYOUT_DURATION := 0.18
## 条内可填充宽度与左端起算位置：玩家条从 144 起、宽 250；Boss 条从 99 起、宽 781。
const PLAYER_BAR_LEFT := 144.0
const PLAYER_BAR_WIDTH := 250.0
const ENEMY_BAR_LEFT := 89.5
const ENEMY_BAR_WIDTH := 726.5
const BLOCK_MARKER_WIDTH := 16.0
const BUFF_ICON_REGION := Rect2(59, 62, 754, 754)
const BUFF_ICON_PATHS := {
	"poison": "res://assets/ui/UI-025/中毒.png",
	"strength": "res://assets/ui/UI-025/力量.png",
	"weak": "res://assets/ui/UI-025/虚弱.png",
}
const RELIC_BOOK_POSITION := Vector2(322, 132)
const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const CARD_TRANSFER := preload("res://ui/battle/card_transfer.gd")
const HEALTH_TRANSITION_TIME := 0.3
## 血条掉血时闪一下的暖色，走 fill_color 打亮，不用 modulate（只能往暗里乘）。
const HEALTH_FLASH_COLOR := Color(1.0, 0.62, 0.68)
## 残影与抽牌动画都按路径 preload：无头跑测试不经过编辑器扫描，用不了全局类缓存。
const HEALTH_TRAIL_SCRIPT := preload("res://ui/battle/health_bar_trail.gd")
const HAND_DEAL_ANIM := preload("res://ui/battle/hand_deal_anim.gd")
const RUN_MENU := preload("res://ui/hud/run_menu_overlay.gd")
const SANDBOX_RESOURCES := preload("res://systems/testing/sandbox_resources.gd")
const VFX_SCRIPT := preload("res://ui/battle/vfx_playback.gd")
const FEEDBACK_SCRIPT := preload("res://ui/battle/combat_feedback.gd")
const HIT_STOP_SCRIPT := preload("res://ui/battle/hit_stop.gd")
const RELIC_HINT_SCRIPT := preload("res://ui/battle/relic_hint_stack.gd")
const BLOCK_SHIELD_SCRIPT := "res://ui/battle/block_shield.gd"
const ITEM_ICON_SCRIPT := "res://ui/components/item_icon.gd"
const HOVER_TIP_SCRIPT := "res://ui/components/hover_tip.gd"
const SETTINGS_BUTTON := preload("res://ui/components/settings_button.gd")
const BATTLE_ENVIRONMENT := preload("res://ui/battle/battle_environment.gd")
# 地图查看器是别的分支的历史遗留，可能不存在；这里只做存在性检查，不硬 preload，
# 免得拉不到那个文件时整个战斗场景解析失败。缺了就退化成菜单里的占位图。
const MAP_VIEWER_PATH := "res://ui/world_map/map_viewer.gd"
## 战斗里查看地图用的快照；正式跑图时改成读跑图状态里的地图。
const MAP_SNAPSHOT_PATH := "res://data/config/flat_2d/demo_map.json"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"
const TEST_CARD_DIR := "res://data/cards/test"
const NEW_RUN_CONFIG_PATH := "res://data/config/main_menu_new_run.json"
const TEST_DECK_CARD_IDS: Array[String] = [
	"test_damage_enemy", "test_damage_self", "test_block", "test_heal",
	"test_poison", "test_weak", "test_strength", "test_move_pointer",
	"test_draw", "test_discard_choice", "test_repeat_next",
	"test_damage_enemy", "test_block", "test_heal", "test_poison",
	"test_weak", "test_strength", "test_draw", "test_discard_choice",
	"test_repeat_next",
]

## 测试局可用的敌人原型，按 test_enemy_count 取前几个。数值与正式战斗无关，只为止观感。
const TEST_ENEMIES: Array[Dictionary] = [
	{"enemy_id": "chr-025", "art_path": "res://assets/chr/CHR-025.png", "damage": 6},
	{"enemy_id": "chr-003", "art_path": "res://assets/chr/CHR-003.png", "damage": 4},
	{"enemy_id": "chr-011", "art_path": "res://assets/chr/CHR-011.png", "damage": 5},
	{"enemy_id": "chr-020", "art_path": "res://assets/chr/CHR-020.png", "damage": 8},
]


@onready var turn_label: Label = %TurnLabel
@onready var phase_label: Label = %PhaseLabel
@onready var count_label: Label = %CountLabel
@onready var hint_label: Label = %HintLabel
@onready var player_status: Label = %PlayerStatus
@onready var enemy_status: Label = %EnemyStatus
@onready var hand_cards: Control = %HandCards
@onready var hand_scroll: ScrollContainer = $HandScroll
@onready var discard_shade: ColorRect = $DiscardShade
@onready var draw_pile_root: Control = $DrawPile
@onready var discard_pile_root: Control = $DiscardPile
@onready var backpack_board: Control = $背包底板
@onready var backpack_slots: Control = $BackpackSlots
@onready var play_scroll: ScrollContainer = $PlayScroll
@onready var play_cards: Control = %PlayCards
@onready var draw_button: Button = %DrawPileButton
@onready var discard_button: Button = %DiscardPileButton
@onready var draw_pile_count: Label = $DrawPile/Count
@onready var discard_pile_count: Label = $DiscardPile/Count
@onready var cancel_button: Button = %CancelButton
@onready var play_button: Button = %PlayButton
@onready var pile_modal: Control = %PileModal
@onready var pile_title: Label = %PileTitle
@onready var pile_grid: GridContainer = %PileGrid
@onready var play_count_label: Label = $PlayCountLabel
@onready var hand_count_label: Label = $HandCountLabel
@onready var player_hp_fill: Control = $PlayerHPBar/Fill
@onready var player_hp_block: ColorRect = $PlayerHPBar/Block
@onready var player_hp_num: Label = $PlayerHPNum
@onready var player_buff_row: HBoxContainer = $PlayerBuffRow
## 敌人一格一个 EnemySlot，具体节点在 EnemyRack 里按数量建。
@onready var enemy_rack: EnemyRack = $EnemyRack

var _battle: BattleStateMachine
var _resolver: BattleEffectResolver
var _relics: RelicBattleSystem
var _relic_board := RelicBoard.new()
var _relic_catalog: Dictionary = {}
var _relic_book: RelicBookView
## 典籍提示条：挂在书页下方，每次亮格子推一条。
var _relic_hints: RelicHintStack
var _fan_target: Control
var _fan_tween: Tween
var _hand_dragging := false
var _hand_drag_origin := 0.0
var _battle_result := ""
var _buff_icon_cache: Dictionary = {}
var _buff_text_by_id: Dictionary = {}
var _buff_tip: PanelContainer
var _buff_tip_label: Label
var intent_board: MonsterIntentBoard
var _intent_tip: HoverTip
var _intent_tip_source: MonsterIntentStrip
var player_block_shield: Control
var _run_menu: RunMenuOverlay
## 战斗测试场景自带的一局，用于战斗内编辑残片；生产场景没有它。
var _test_run: RunStateMachine = null
var _sandbox_resource_run: Node = null
var _settings_button: SettingsButton
var _map_page_source: Control
var _selected_ids: Array[String] = []
## 上一轮手牌里的 instance_id；用来判断这一轮哪些牌是刚抽进来的。
var _hand_ids_previous: Dictionary = {}
var _selected_cards: Array[Dictionary] = []
var _discard_selection_ids: Array[String] = []
var _pending_discard_count := 0
var _pending_discard_card_id := ""
var _resolution_events: Array[Dictionary] = []
## 只记录真实规则已发出的事实；不以伤害预览或未来战斗状态推进画面。
var _presentation_kind := ""
var _presentation_turn := 0
var _presented_hand: Array[Dictionary] = []
var _presented_draw_count := 0
var _presented_discard_count := 0
var _presented_relic_count := 0
var _relic_flash_tweens: Dictionary = {}
var _pending_pile_presentation: Dictionary = {}
var _pending_battle_presentation: Dictionary = {}
var _queued_card_end: Dictionary = {}
## 当前这张牌是否只动了指针位置。为真时收尾等待走 pointer_only_delay。
var _card_pointer_only := false
var _discard_focus_up := false
## 蒙版只在结算真的走到「等待弃牌」那一步才抬起来。规则侧一发出弃牌请求就抬的话，
## 只要结算队列里有弃牌牌，从头到尾都压着蒙版。与 pending 计数同时判断，收尾也一定落下。
var _discard_focus_armed := false
var _display_pointer_id := ""
var _settle_pointer: TextureRect
var _pointer_tween: Tween
var _resolve_preview: Control
var _resolve_view: CardView
var _resolve_preview_card := ""
var _peek_layer: Control
var _peek_view: CardView
var _busy := false
var _animating := false
var _refresh_queued := false
## 规则队列同步结算，UI异步播放；刷新只能重绘当前播放快照，不能偷读最终血量。
var _presented_player: Dictionary = {}
var _presented_enemies: Array[Dictionary] = []
## true 表示典籍连锁正开着；连锁结束（下一个非典籍事件或队列排空）时关闭，用来只停第一拍。
var _relic_chain_open := false
var _bbcode_strip := RegEx.new()
var _card_transfers: Dictionary = {}
var _resolved_discards: Dictionary = {}
## 血量变化要能看见：记上一次的血量，差值用来飘伤害/治疗数字。
## 表现层：飘字、闪红、震动、特效，只吃战斗事件。
var _feedback: Node
var _hit_stop: HitStop
var _pacer: ResolutionPacer
## 出牌列上一次的行数，只在新增时播放入场，刷新时不会整列重放。
var _play_rows_shown := 0
var _play_insert_index := -1
var _drag_card_id := ""
var _drag_source := ""
var _drag_start := Vector2.ZERO
var _drag_active := false
var _drag_ghost: Control
## 拖着牌时扇面是否已撑开：撑开时手牌里给这张牌留出空位，牌本身还在光标上。
var _hand_gap_open := false
## 这次拖拽是否离开过扇面；出过扇面才认「拖出去过」，回来才会撑开。
var _drag_hand_ever_outside := false
## 收扇 / 开扇的滑动起点：instance_id -> [position, rotation]。为空时手牌瞬排。
var _hand_pose_from: Dictionary = {}
var _hand_relayout_tween: Tween
var _drop_hint: Panel
var _turn_pop_text := ""
## 飞书资产 UI-012「结算指针」：黑三角金边，从左往右指。
const POINTER_TEXTURE := preload("res://assets/ui/UI-012/UI-012-银.png")
const RESOLVE_PREVIEW_POS := Vector2(1440.0, 250.0)
const RESOLVE_PREVIEW_SCALE := 0.5
## 结算节奏：指针滑行按距离配速，大图出现后停一下再结算，让玩家看清发生了什么。
const POINTER_GLIDE_SPEED := 1700.0
const POINTER_GLIDE_MIN := 0.14
const POINTER_GLIDE_MAX := 0.22
const PREVIEW_HOLD := 0.5
## 结算收尾取这张牌播出动画的这个比例：飘字寿命 0.70~1.00 换算成 0.32~0.45 秒。
## 取一部分而不是全等，是让下一张牌在数字还在上浮时就开始，整串才不显得一顿一顿。
const FEEDBACK_SETTLE_SHARE := 0.45
const PLAY_PLACEHOLDER_ALPHA := 0.75
const PEEK_CARD_SCALE := 0.79
## 等待玩家弃牌时，蒙版与要高亮的节点各自抬到哪个层级。失活时全部还原为 0。
const DISCARD_SHADE_Z := 20
const DISCARD_FOCUS_Z := 30
const PLAYER_FLOAT_ANCHOR := Vector2(300.0, 118.0)
## 敌方飘字 / 特效相对槽位顶边的下沉量：由原版单敌人落点反推
## （槽顶 y=78，飘字在原版 y=330，特效在原版 y=470）。
const ENEMY_FLOAT_DROP := 252.0
const ENEMY_VFX_DROP := 392.0
## 敌方血条框按品级换图：普通用小怪框、精英用精英框，其余（BOSS）用 boss 框。
const ENEMY_BAR_FRAME_PATTERN := "res://assets/ui/UI-015/超长-%s血条框.png"
## 典籍连锁：整条连锁只停第一拍，之后连锁内部各次激活快速连播，亮格提示各自计时退场。
## 停一拍是为了把「现在在结算典籍」和「只是指针在走」区分开，不至于每次激活都停。
const RELIC_CHAIN_PAUSE := 0.25
## 触发格亮起与效果格亮起之间的节拍，两盏灯要读得出先后。
const RELIC_STEP_BEAT := 0.3


var _enchantment_hover: PanelContainer
var _enchantment_hover_id := ""
var _monster_text: MonsterBattleText
var _battle_choice_layer: CanvasLayer
var _target_enemy_id := ""
var _manual_discard_button: Button
var _relic_cells: Array[Label] = []
var _relic_title: Label
var _restart_button: Button
var _pile_selection_ids: Array[String] = []
var _display_cards: Array[Dictionary] = []
@export var deck_card_ids: Array[String] = []
@export var test_player_health := 60
@export var test_player_max_health := 100
@export var test_silver := 0


func _ready() -> void:
	$背包底板.add_theme_stylebox_override("panel", CommonUiSkin.panel("strip"))
	$出牌计数底板.add_theme_stylebox_override("panel", CommonUiSkin.panel("tiny"))
	$PileModal/Window.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel", Vector4(24, 20, 24, 20)))
	CommonUiSkin.style_navigation_button(%ClosePileButton, "close", true)
	pile_modal.z_index = 300
	draw_button.pressed.connect(_on_draw_pile_pressed)
	discard_button.pressed.connect(_on_discard_pile_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	play_button.pressed.connect(_on_play_pressed)
	_run_menu = RUN_MENU.new()
	_run_menu.name = "RunMenuOverlay"
	# 战斗测试场景是唯一允许战斗内编辑典籍的装配点，生产场景不得打开。
	_run_menu.allow_edit_in_battle = true
	add_child(_run_menu)
	$PlayerPortrait.gui_input.connect(_on_player_portrait_input)
	# 冒险菜单设置页的三个动作：战斗里也能存档、回主菜单、退出。
	_run_menu.abandon_requested.connect(_on_menu_abandon)
	_run_menu.return_to_menu_requested.connect(_on_menu_return)
	_run_menu.quit_requested.connect(_on_menu_quit)
	_run_menu.potion_requested.connect(_use_potion)
	_build_settings_button()
	hand_scroll.gui_input.connect(_on_hand_scroll_input)
	%ClosePileButton.pressed.connect(_close_pile_modal)
	%PileModalShade.gui_input.connect(_on_modal_shade_input)
	_style_backpack_slots()
	_build_block_shields()
	_build_buff_tip()
	_build_relic_hud()
	_build_resolve_preview()
	_build_settle_pointer()
	_build_peek()
	_build_relic_hints()
	_build_feedback()
	_build_intent_board()
	_start_test_battle()
	if _battle != null:
		_battle.battle_choice_requested.connect(_on_battle_choice_requested)
		var pending_choice: Dictionary = _battle.player.get("battle_choice", {})
		if not pending_choice.is_empty(): _on_battle_choice_requested(str(pending_choice.mode), int(pending_choice.count), pending_choice.candidates)
	_build_battle_actions()
	$Background.texture = BATTLE_ENVIRONMENT.texture_for_floor(_battle_environment_floor(), test_background_variant)
	_refresh_coin()
	_setup_monster_battle_text()


func _battle_environment_floor() -> int:
	return test_floor_index


func _build_feedback() -> void:
	# 多敌人时每个敌方立绘与落点都不同，表现层按实体 id 反查，不再假定只有一个敌人。
	_feedback = FEEDBACK_SCRIPT.new()
	_feedback.name = "CombatFeedback"
	add_child(_feedback)
	_feedback.setup(self, $PlayerPortrait, PLAYER_FLOAT_ANCHOR, enemy_view)
	_build_feel()
	_build_resolution_pacer()


## 典籍提示栈：挂在书页下方，盖在战场上但不拦输入，连锁起止由队列事件驱动。
func _build_relic_hints() -> void:
	_relic_hints = RELIC_HINT_SCRIPT.new()
	_relic_hints.name = "RelicHints"
	_relic_hints.z_index = 250
	_relic_hints.position = RELIC_BOOK_POSITION + Vector2(0, RelicBookView.BOOK_SIZE.y + 8.0)
	add_child(_relic_hints)


## 提示本次亮起的残片：名字 + 效果文案。触发点与效果点各推一条，各自计时退场。
func _present_relic_hint(cell: int) -> void:
	if _relic_hints == null or _relic_catalog.is_empty():
		return
	if cell < 0 or cell >= _relic_board.cells.size():
		return
	var fragment: RelicFragmentData = _relic_catalog.get(_relic_board.cells[cell])
	if fragment == null:
		return
	_relic_hints.push("%s：%s" % [fragment.display_name, _plain_relic_text(fragment.rich_description())])


## 关掉连锁边界。提示条各自计时退场，这里只复位「本连锁是否已停过第一拍」。
func _close_relic_chain() -> void:
	_relic_chain_open = false


## 提示条是普通 Label，装不下 BBCode：把 [颜色]、[lb] 与负面词条的运动标记一起去掉。
func _plain_relic_text(value: String) -> String:
	if _bbcode_strip.get_pattern().is_empty():
		_bbcode_strip.compile("\\[[^\\]]*\\]")
	return _bbcode_strip.sub(value, "", true)


## 表现层按实体 id 取敌方立绘与飘字落点。返回空字典表示这个敌人没有可显示的目标，
## 表现层据此跳过特效，而不是拿另一个敌人的立绘顶替。
func enemy_view(entity_id: String) -> Dictionary:
	var slot := enemy_rack.slot_for(entity_id)
	if slot == null:
		return {}
	var portrait_rect := slot.portrait.get_rect()
	var origin := enemy_rack.position + slot.position
	return {
		"portrait": slot.portrait,
		"feedback_z": slot.feedback_z(),
		"center": origin + portrait_rect.position + portrait_rect.size * 0.5,
		"float_anchor": origin + portrait_rect.position + Vector2(portrait_rect.size.x * 0.5, portrait_rect.size.y * 0.32),
	}



## 结算节拍：把检查器上的三个上限搬进节拍器。节拍器只是记账对象，不进场景树。
func _build_resolution_pacer() -> void:
	_pacer = ResolutionPacer.new()
	_pacer.budget = resolution_budget
	_pacer.speedup_after_hops = resolution_speedup_after
	_pacer.max_speed = resolution_max_speed


## 打击感：只有顿帧。不再有震屏——震屏靠改写已注册节点的 position 实现，
## 与刷新、布局等多个写入方抢同一个坐标，结果是敌人在结算阶段整块闪烁，
## 收益远小于代价，整块删掉。
func _build_feel() -> void:
	_hit_stop = HIT_STOP_SCRIPT.new()
	_hit_stop.name = "HitStop"
	add_child(_hit_stop)
	enemy_rack.slot_selected.connect(_on_enemy_slot_selected)


## 点战场上的敌人即切目标，不再有专门的切换按钮。目标标记（箭头 + 高亮框）就是这次点击的
## 反馈，不另写提示文字，避免与「等待玩家操作」时的提示叠加。
func _on_enemy_slot_selected(enemy_id: String) -> void:
	if _battle == null or not _battle.active or enemy_id.is_empty() or _busy or _animating:
		return
	var candidates := _battle.enemies.filter(func(enemy: Dictionary): return int(enemy.health) > 0 and str(enemy.enemy_id) == enemy_id)
	if candidates.is_empty(): return
	for enemy: Dictionary in _battle.enemies:
		if int(enemy.health) > 0 and bool(enemy.get("taunt", false)) and str(enemy.enemy_id) != enemy_id: return
	if enemy_id == _target_enemy_id:
		return
	_target_enemy_id = enemy_id
	_queue_refresh()


func _exit_tree() -> void:
	for instance_id: String in _card_transfers.keys():
		_cancel_card_transfer(instance_id)
	# 全部临时状态只属于此场景；退出不碰真实战斗队列与保存状态。
	for animation: Tween in _relic_flash_tweens.values():
		if animation != null and animation.is_valid(): animation.kill()
	_relic_flash_tweens.clear()
	_resolution_events.clear()
	_resolved_discards.clear()
	_pending_pile_presentation.clear()
	_pending_battle_presentation.clear()
	_queued_card_end.clear()
	_busy = false
	_animating = false
	_presentation_kind = ""


func _refresh_coin() -> void:
	var sandbox_run := _refill_sandbox_battle_resources()
	var run := _test_run if _test_run != null else SaveGateway.current_run()
	var silver := test_silver
	var elixir := 0
	if run != null:
		RunRewards.ensure_state(run)
		silver = run.gold
		elixir = int(run.inventory_state.elixir)
	if is_instance_valid(_battle):
		var shown: Dictionary = _presented_player if _busy and not _presented_player.is_empty() else _battle.player
		silver = int(shown.get("silver", silver))
	$Coin/Count.text = SANDBOX_RESOURCES.text(silver, sandbox_run)
	$Elixir/Count.text = SANDBOX_RESOURCES.text(elixir, sandbox_run)


func _refill_sandbox_battle_resources() -> Node:
	# 独立 battle-test 有自己的 run；只有固定地图实际持有的战斗才能使用无限货币。
	if _test_run != null or not is_instance_valid(_battle):
		return null
	var run := SaveGateway.current_run()
	if not SANDBOX_RESOURCES.active(run):
		return null
	if run.current_battle == _battle:
		_sandbox_resource_run = run
	# 战后 current_battle 已清空，保留本场的显示归属直到场景退出。
	if not is_instance_valid(_sandbox_resource_run) or _sandbox_resource_run != run:
		return null
	SANDBOX_RESOURCES.refill(run)
	return run


## 正式新局的初始卡组，与主菜单新游戏读同一份配置；读不到才退回测试卡。
func _initial_deck_from_config() -> Array[String]:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(NEW_RUN_CONFIG_PATH))
	if parsed is Dictionary and parsed.get("initial_deck") is Array and not parsed.initial_deck.is_empty():
		var result: Array[String] = []
		for card_id: String in parsed.initial_deck:
			result.append(card_id)
		return result
	return TEST_DECK_CARD_IDS.duplicate()


## 测试局的敌人表：按 test_enemy_count 取前几个原型，全部用同一份起始血量。
func _test_enemy_payload() -> Array:
	var count := clampi(test_enemy_count, 1, TEST_ENEMIES.size())
	var list: Array = []
	for index in count:
		var entry: Dictionary = TEST_ENEMIES[index]
		list.append({
			"enemy_id": entry["enemy_id"],
			"art_path": entry["art_path"],
			"health": enemy_starting_health,
			"max_health": enemy_starting_health,
			"block": 0,
			"buffs": [],
			"actions": [{"action_id": "test-attack", "damage": entry["damage"]}],
		})
	return list


## 战斗测试场景自带一局脱离存档槽位的 run，让冒险菜单在战斗内也能编辑残片。
## 生产场景不会调用它，RunRewards 的放宽开关也只在这里打开。
func _setup_test_run() -> bool:
	if _run_menu == null:
		return false
	_test_run = RunStateMachine.new()
	_test_run.name = "BattleTestRun"
	_test_run.active = true
	_test_run.run_id = "battle-test"
	_test_run.main_seed = SeedService.get_main_seed()
	add_child(_test_run)
	# 棋盘来源跟随场景指定的路径：默认即开发用盘，测试显式指向夹具时读夹具，
	# 这样测试局的构筑与菜单展示仍是同一块，且不污染开发存档。
	RunRewards.ensure_state(_test_run, relic_board_path)
	# 卡组用正式初始卡组，不再用测试卡。
	_test_run.deck.clear()
	for card_id: String in _initial_deck_from_config():
		_test_run.deck.append(card_id)
	_test_run.set_meta("battle_test_sandbox", true)
	_run_menu.set_run_override(_test_run)
	_run_menu.relic_board_updated.connect(_refresh_relic_hud)
	_refresh_backpack()
	return true


func _start_test_battle() -> void:
	if SeedService.get_main_seed().is_empty():
		SeedService.begin_run("battle-effects-ui-test")

	# 抽牌与出牌上限对齐正式节点战斗。
	var rules: Dictionary = EncounterFlow.test_rules
	initial_draw_count = int(rules.get("initial_draw_count", initial_draw_count))
	per_turn_draw_count = int(rules.get("per_turn_draw_count", per_turn_draw_count))
	play_limit = int(rules.get("play_limit", play_limit))

	_battle = BattleStateMachine.new()
	_battle.name = "BattleStateMachine"
	add_child(_battle)
	_battle.turn_started.connect(_on_turn_started)
	_battle.card_effect_requested.connect(_on_card_effect_requested)
	_battle.card_resolved.connect(_on_card_resolved)
	_connect_combat_feedback()
	_battle.discard_choice_requested.connect(_on_discard_choice_requested)
	_battle.pile_choice_requested.connect(_on_pile_choice_requested)
	_battle.battle_ended.connect(_on_battle_ended)

	var deck: Array[Dictionary] = []
	var chosen_deck: Array[String] = _initial_deck_from_config() if deck_card_ids.is_empty() else deck_card_ids.duplicate()
	for index in chosen_deck.size():
		deck.append({
			"instance_id": "test-card-%02d" % (index + 1),
			"card_id": chosen_deck[index],
		})

	var error := _battle.initialize_battle({
		"map_id": "battle-effects-ui-test",
		"node_id": "test-room",
		"battle_index": 0,
		# 首抽与每回合抽牌由本场景分别控制，状态机不额外自动抽牌。
		"draw_count": 0,
		"discard_hand_at_turn_end": false,
		"player": {
			"health": test_player_health,
			"max_health": test_player_max_health,
			"base_play_limit": play_limit,
			"silver": test_silver,
			"block": 0,
			"buffs": [],
		},
		"enemies": _test_enemy_payload(),
		"deck_instances": deck,
	})
	if error == OK:
		_resolver = BattleEffectResolver.new()
		_resolver.name = "BattleEffectResolver"
		add_child(_resolver)
		error = _resolver.attach_to_battle(_battle)
	if error == OK:
		_relic_catalog = RelicCatalog.load_definitions()
		var loaded := ERR_FILE_NOT_FOUND
		if _setup_test_run():
			# 测试局的盘从 run 同步，保证菜单显示与编辑是同一块。
			loaded = _relic_board.restore(_test_run.inventory_state.relic_board, _relic_catalog)
		else:
			loaded = _relic_board.load_from_file(_relic_catalog, relic_board_path)
		if loaded != OK and loaded != ERR_FILE_NOT_FOUND:
			error = loaded
	if error == OK:
		_relics = RelicBattleSystem.new()
		_relics.name = "RelicBattleSystem"
		add_child(_relics)
		_relics.fragment_activated.connect(_on_relic_activated)
		_relics.trigger_activated.connect(_on_relic_triggered)
		_relics.chain_limited.connect(_on_relic_chain_limited)
		error = _relics.attach_to_battle(_battle, _relic_board, _relic_catalog, _resolver.buff_catalog)
		_refresh_relic_hud()
	if error == OK:
		_sync_battle_potions()
		_battle.player["external_natural_draw"] = true
		error = _battle.start_battle()
	if error == OK and _battle.active:
		# 与正式节点战斗一致：首抽经残片自然抽牌修正。
		error = _battle.draw_cards(_relics.natural_draw_count(initial_draw_count), BattleStateMachine.DrawReason.BATTLE_START)
	if error != OK:
		_busy = true
		hint_label.text = "战斗测试初始化失败：%d" % error
		push_error("BattleTestScene: initialization failed: %d" % error)
	_queue_refresh()


func _build_settings_button() -> void:
	_settings_button = SETTINGS_BUTTON.new()
	_settings_button.name = "SettingsButton"
	_settings_button.position = Vector2(1848, 32)
	_settings_button.size = Vector2(48, 48)
	_settings_button.pressed.connect(func() -> void: _open_run_menu(2))
	add_child(_settings_button)
	# 齿轮压在背包和菜单浮层下面：弹层打开时不该露出入口。
	move_child(_settings_button, pile_modal.get_index())


func _build_relic_hud() -> void:
	# 共用完整20格书页，已开区域来自本场战斗构筑。
	_relic_book = RelicBookView.new()
	_relic_book.open_requested.connect(_open_run_menu.bind(1))
	_relic_book.name = "RelicBook"
	_relic_book.position = RELIC_BOOK_POSITION
	add_child(_relic_book)
	# 书在主角立绘后面，避免盖住人物。
	move_child(_relic_book, $HeroPortrait.get_index())
	_relic_book.attach_tip(self, 120)
	_build_test_controls()


func _build_test_controls() -> void:
	_relic_title = Label.new()
	_relic_title.visible = false
	add_child(_relic_title)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.04, 0.8)
	_restart_button = _make_test_button("重开测试", style, Vector2(24, 486), _restart_battle)
	_relic_cells = _relic_book._cells


func _connect_combat_feedback() -> void:
	_battle.rules.queue.event_processed.connect(_on_rule_event_processed)
	_battle.combatant_damaged.connect(_on_combatant_damaged)
	_battle.combatant_healed.connect(_on_combatant_healed)
	_battle.block_changed.connect(_on_block_changed)
	_battle.buff_added.connect(_on_buff_added)
	_battle.card_committed.connect(_on_card_committed_present)
	_battle.card_discarded.connect(_on_card_discarded_visual)
	_battle.card_destroyed.connect(_on_card_destroyed_visual)


func _build_intent_board() -> void:
	intent_board = MonsterIntentBoard.new()
	add_child(intent_board)
	_intent_tip = HoverTip.new()
	_intent_tip.name = "IntentTip"
	_intent_tip.z_index = 80
	add_child(_intent_tip)
	_intent_tip.get_node("TipLabel").add_theme_font_size_override("normal_font_size", 18)


func _build_block_shields() -> void:
	# 玩家侧的盾贴在血条尾端，位置与玩家立绘一样唯一；敌方的盾归 EnemySlot 自己持有，
	# 因为它随敌人数量与槽宽变化。
	var script := load(BLOCK_SHIELD_SCRIPT)
	player_block_shield = script.new()
	player_block_shield.name = "PlayerBlockShield"
	player_block_shield.position = Vector2(362, 28)
	player_block_shield.size = Vector2(58, 64)
	player_block_shield.set("number_px", 19)
	add_child(player_block_shield)


func _style_backpack_slots() -> void:
	# 和背包页同一套格子：深色底板 + UI-004 边框，只是 HUD 里更小。
	var slot_a := _atlas_texture("res://assets/ui/UI-004/物品边框1.png", Rect2(34, 28, 665, 665))
	var slot_b := _atlas_texture("res://assets/ui/UI-004/物品边框2.png", Rect2(12, 7, 708, 686))
	var index := 0
	for child: Node in $BackpackSlots.get_children():
		if not child is Panel:
			continue
		var panel := child as Panel
		var plate := StyleBoxFlat.new()
		plate.bg_color = Color(0.135, 0.112, 0.088, 0.95)
		plate.border_color = Color(0.910, 0.706, 0.333, 0.20)
		plate.set_border_width_all(1)
		plate.set_corner_radius_all(3)
		panel.add_theme_stylebox_override("panel", plate)
		var frame := Panel.new()
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxTexture.new()
		style.texture = slot_b if index % 2 == 1 else slot_a
		frame.add_theme_stylebox_override("panel", style)
		panel.add_child(frame)
		index += 1
	_refresh_backpack()


func _refresh_backpack() -> void:
	# 战斗里这排格子只是背包页那 21 格的快捷栏，读的是同一份 run.items。
	for child: Node in $BackpackSlots.get_children():
		if not child is Panel:
			continue
		for extra: Node in child.get_children():
			if String(extra.name).begins_with("ItemIcon") or String(extra.name).begins_with("ItemName"):
				child.remove_child(extra)
				extra.queue_free()
	# 沙盒读的是自带的那一局，正式流程才有存档槽位里那一局。
	var run := _test_run if _test_run != null else SaveGateway.current_run()
	var items: Array = run.items if run != null else []
	var slots := $BackpackSlots.get_children()
	for index in mini(items.size(), slots.size()):
		var item: Variant = items[index]
		var text := ""
		if item is Dictionary:
			text = str(item.get("name", RunRewards.NAMES.get(str(item.get("kind", "")), item.get("item_id", ""))))
			if text.is_empty():
				text = str(item.get("item_id", ""))
		else:
			text = str(item)
		if text.is_empty():
			continue
		var record := _item_record(text, text)
		var icon_script := load(ITEM_ICON_SCRIPT)
		var icon: Control = icon_script.make_item(item, 26.0, str(record.get("icon_path", "")))
		icon.name = "ItemIcon"
		icon.position = Vector2(6, 6)
		(slots[index] as Control).add_child(icon)
		var slot_control := slots[index] as Control
		slot_control.mouse_filter = Control.MOUSE_FILTER_STOP
		var tip := _item_tooltip(text, record)
		slot_control.mouse_entered.connect(_show_buff_tip.bind(slot_control, tip))
		slot_control.mouse_exited.connect(_hide_buff_tip)



func _item_record(item_id: String, display: String = "") -> Dictionary:
	var catalog := get_node_or_null("/root/TextCatalog")
	if catalog == null:
		return {}
	var record: Dictionary = catalog.entry("items", item_id)
	if record.is_empty() and not display.is_empty():
		# 物品表按名称兜底：战斗里的 items 可能只带显示名。
		for entry: Dictionary in catalog.entries("items"):
			if str(entry.get("name", "")) == display:
				return entry
	return record


func _item_tooltip(item_id: String, record: Dictionary) -> String:
	var display := str(record.get("name", item_id))
	var effect := str(record.get("effect", ""))
	return display if effect.is_empty() else "%s\n%s" % [display, effect]


func _add_slot_icon(slot_index: int, path: String) -> void:
	var slot := $BackpackSlots.get_child(slot_index) as Control
	if slot == null:
		return
	var icon := TextureRect.new()
	icon.texture = _atlas_texture(path, Rect2(97, 95, 859, 1108))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.position = Vector2(7, 3)
	icon.size = Vector2(24, 31)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)


func _atlas_texture(path: String, region: Rect2) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = load(path)
	atlas.region = region
	return atlas


func _refresh_relic_hud() -> void:
	if _relic_book != null:
		_relic_book.set_board(_relic_catalog, _relic_board)
	var count: int = _presented_relic_count if _busy else (_relics.activation_count if _relics != null else 0)
	_relic_title.text = "典籍 · 生效 %d 次" % count


## 同一段同步规则结算对应一条表现队列。这里从不暂停或改写业务队列，
## 因而交互暂停、致死取消、存档与随机流仍由原规则拥有。
func _begin_presentation() -> void:
	if _busy:
		return
	# 已显示的整队快照保持冻结，不能先把刚变动的业务血量渲染出去。
	if _presented_enemies.is_empty():
		_refresh_combat_status()
	_busy = true
	_presentation_turn = _battle.turn_number
	_presented_hand.assign(_battle.hand.duplicate(true))
	_presented_draw_count = _battle.draw_pile.size()
	_presented_discard_count = _battle.discard_pile.size()
	_presented_relic_count = _relics.activation_count if _relics != null else 0
	_display_cards.assign(_battle.play_zone.duplicate(true))
	_display_cards.append_array(_selected_cards.duplicate(true))


## terminal 本身不算待播放项：此谓词表示终局之前仍需完成的展示或输入。
func _presentation_pending() -> bool:
	return _busy or _animating or not _resolution_events.is_empty() \
		or not _relic_flash_tweens.is_empty() or not _resolved_discards.is_empty() \
		or not _card_transfers.is_empty() or not _queued_card_end.is_empty()


func _queue_presentation(kind: String, fields: Dictionary = {}) -> void:
	var begin := not _busy
	if begin:
		_begin_presentation()
	var enemy_snapshots: Array = []
	for enemy: Dictionary in _battle.enemies:
		enemy_snapshots.append(enemy.duplicate(true))
	var current: BattleEvent = _battle.rules.queue.current
	var from_relic: bool = current != null and (not current.metadata.get("relic_ancestry", []).is_empty() \
		or bool(current.metadata.get("relic_effect", false)))
	var event := {
		"kind": kind,
		"monster_attack": str(current.metadata.get("monster_attack", "")) if current != null else "",
		"from_relic": from_relic,
		"turn": _battle.turn_number,
		"player": _battle.player.duplicate(true),
		"enemies": enemy_snapshots,
		"hand": _battle.hand.duplicate(true),
		"draw_count": _battle.draw_pile.size(),
		"discard_count": _battle.discard_pile.size(),
		"activation_count": _relics.activation_count if _relics != null else 0,
		"play_zone": _battle.play_zone.duplicate(true),
	}
	event.merge(fields, true)
	_resolution_events.append(event)
	if begin:
		# 先收齐当前同步调用产生的事实，再开始异步回放。
		call_deferred("_drain_resolution_events")


func _apply_presentation_snapshot(event: Dictionary) -> void:
	_presentation_turn = int(event["turn"])
	_presented_hand.assign(event["hand"])
	_presented_draw_count = int(event["draw_count"])
	_presented_discard_count = int(event["discard_count"])
	_presented_relic_count = int(event["activation_count"])
	if not event["enemies"].is_empty():
		_render_combat_snapshot(event["player"], event["enemies"])


func _on_relic_triggered(cell: int, chained: bool) -> void:
	_queue_presentation("relic_trigger", {"cell": cell, "chained": chained})


func _on_relic_activated(trigger: int, effect: int, description: String) -> void:
	_queue_presentation("relic_completed", {"trigger": trigger, "effect": effect, "description": description})


func _on_rule_event_processed(event: BattleEvent) -> void:
	# activate 在动作之前，completed 在动作之后；致死会取消 completed，
	# 仍必须让确实执行过的残片亮起并收尾。
	if event.type == &"relic.activate" and bool(event.metadata.get("relic_activation_started", false)):
		_queue_presentation("relic_effect", {
			"trigger": int(event.payload.trigger), "effect": int(event.payload.effect),
		})
	elif event.type == &"flow.enemy.begin":
		_flush_card_end()
		_queue_presentation("enemy_turn")
	elif event.type == &"effect.execute":
		_queue_presentation("card_effect")
	elif event.type == &"pointer.moved":
		_queue_presentation("pointer_moved", {
			"from": int(event.payload.get("from", 0)),
			"to": int(event.payload.get("to", 0)),
		})
	elif event.type == &"monster.summon" and bool(event.metadata.get("summoned", false)):
		# event_processed 在规则追加本次召唤后触发；保留每次增长的独立整队快照。
		_queue_presentation("enemy_spawned")
	elif event.type == &"enemy.action_requested":
		_queue_presentation("enemy_action", {
			"entity_id": str(event.payload.get("enemy_id", "")),
			"action_index": int(event.payload.get("action_index", 1)),
			"action_count": int(event.payload.get("action_count", 1)),
		})
	elif event.type == &"flow.enemy.resolved":
		_queue_presentation("enemy_action_end")
	elif event.type in [&"enemy.intents_ready", &"enemy.intents_changed"]:
		_queue_presentation("intent_updated")


func _on_relic_chain_limited() -> void:
	_queue_presentation("relic_limited")


func _on_battle_ended(result: Dictionary) -> void:
	_battle_result = String(result.status)
	_flush_card_end()
	# 这里只记真实结果；标题、怪物文本停止与奖励须等前序展示全部完成。
	if not _busy:
		_begin_presentation()
		call_deferred("_drain_resolution_events")
	_queue_refresh()


func _present_battle_ended() -> void:
	if is_instance_valid(_monster_text):
		_monster_text.stop()
	hint_label.text = "战斗结束，可以返回典籍页面调整残片。"
	presentation_event.emit("battle_ended", {"status": _battle_result})


func _on_turn_started(turn_number: int) -> void:
	_refill_sandbox_battle_resources()
	_queue_presentation("turn_started")
	# 首回合在 start_battle 返回后按 initial_draw_count 抽牌；后续回合在
	# PLAYER_ACTION 信号期间同步调用，符合 BattleStateMachine 的接口约束。
	if turn_number > 1:
		var count := _relics.natural_draw_count(per_turn_draw_count) if _relics != null else per_turn_draw_count
		var error := _battle.draw_cards(count, BattleStateMachine.DrawReason.TURN_START)
		if error != OK:
			push_error("BattleTestScene: turn draw failed: %d" % error)


func _on_card_committed_present(card: Dictionary, _play_index: int) -> void:
	# 玩家点“出牌”瞬间，不是异步回放：立即发，让音频跟手。
	presentation_event.emit("card_committed", {
		"instance_id": str(card.get("instance_id", "")),
		"is_attack": _card_has_attack(card),
		"is_multi_attack": _card_is_multi_attack(card),
	})


func _on_card_effect_requested(card: Dictionary, _target: Variant, pointer: int) -> void:
	_refill_sandbox_battle_resources()
	_flush_card_end()
	_queue_presentation("card_start", {
		"instance_id": str(card.instance_id),
		"pointer": pointer,
		"is_attack": _card_has_attack(card),
		"is_multi_attack": _card_is_multi_attack(card),
	})


func _card_data_for(card: Dictionary) -> CardData:
	if _resolver == null:
		return null
	return _resolver.card_catalog.get(str(card.get("card_id", ""))) as CardData


func _card_has_attack(card: Dictionary) -> bool:
	var data := _card_data_for(card)
	if data == null:
		return false
	for effect: GameEffect in data.effects:
		if effect is CardEffectAttack and (effect as CardEffectAttack).amount > 0:
			return true
	return false


func _card_is_multi_attack(card: Dictionary) -> bool:
	var data := _card_data_for(card)
	if data == null:
		return false
	for effect: GameEffect in data.effects:
		if effect is CardEffectAttack and (effect as CardEffectAttack).times > 1:
			return true
	return false


func _on_card_resolved(card: Dictionary, pointer: int) -> void:
	_refill_sandbox_battle_resources()
	_flush_card_end()
	# card.resolved / pointer.moved 仍可派生残片。到下一续接点才展示完成，
	# 让这些反应也属于当前卡牌的可见收尾。
	_queued_card_end = {"instance_id": str(card.instance_id), "pointer": pointer}


func _flush_card_end() -> void:
	if _queued_card_end.is_empty():
		return
	var completed := _queued_card_end
	_queued_card_end = {}
	_queue_presentation("card_end", completed)


func _on_combatant_damaged(side: StringName, entity_id: String, damage: int,
		blocked: int, health_after: int) -> void:
	# 致死的判定来自信号本身，不比较快照差值；实体 id 让飘字与特效找到对应那一格。
	_queue_presentation("damage", {
		"side": side, "entity_id": entity_id, "damage": damage, "blocked": blocked,
		"lethal": health_after <= 0,
	})


func _on_combatant_healed(side: StringName, entity_id: String, amount: int,
		_health_after: int) -> void:
	_queue_presentation("heal", {"side": side, "entity_id": entity_id, "amount": amount})


func _on_block_changed(side: StringName, entity_id: String, block: int) -> void:
	_queue_presentation("block", {"side": side, "entity_id": entity_id, "block": block})


func _on_buff_added(side: StringName, _entity_id: String, buff: Dictionary) -> void:
	_queue_presentation("buff", {"side": side, "buff": buff.duplicate(true)})


func _on_discard_choice_requested(card: Dictionary, count: int,
		_candidates: Array[Dictionary]) -> void:
	_pending_discard_count = count
	_pending_discard_card_id = String(card.get("instance_id", ""))
	_discard_selection_ids.clear()
	# 请求本身不抬蒙版：等结算播到这张牌、进入等待弃牌那一步再抬。
	_discard_focus_armed = false
	_queue_refresh()


func _on_hand_card_pressed(instance_id: String) -> void:
	if _animating:
		return
	if not _battle.active:
		hint_label.text = "战斗已结束，请点击重开战斗；测试敌人生命可在检查器调整。"
		return
	if _pending_discard_count > 0:
		_select_card_to_discard(instance_id)
		return
	if _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION:
		hint_label.text = "当前结算未完成，请完成弃牌选择或重开战斗。"
		return
	var card := _find_card(_battle.hand, instance_id)
	if FinalBossRules.is_saturn(card):
		hint_label.text = "逆行土星为手牌机制牌，无法出牌；其光环在手牌中自动生效"
		return
	if _busy or (bool(card.get("occupies_slot", true)) and _used_slots() >= _battle.effective_play_limit()):
		if not _busy:
			hint_label.text = "出牌区已满（上限 %d 张）" % _battle.effective_play_limit()
		return
	if _selected_ids.has(instance_id):
		return
	if card.is_empty():
		return
	_selected_ids.append(instance_id)
	_selected_cards.append(card.duplicate(true))
	# 出牌落位不再飞牌：点完即由 _queue_refresh 重建出手牌与出牌列。
	hint_label.text = ""
	_queue_refresh()


## 等待玩家弃牌时压一层蒙版，把要操作的东西抬到蒙版之上，提示范围收窄到「谁在等你」。
## 蒙版不拦输入：弃牌是逐张点手牌后自动提交，不需要点别的按钮，也就不该挡住误点。
func _sync_discard_focus() -> void:
	var focused := _discard_focus_armed and _pending_discard_count > 0
	if focused == _discard_focus_up:
		return
	_discard_focus_up = focused
	discard_shade.visible = focused
	discard_shade.z_index = DISCARD_SHADE_Z if focused else 0
	var level := DISCARD_FOCUS_Z if focused else 0
	hand_scroll.z_index = level
	draw_pile_root.z_index = level
	discard_pile_root.z_index = level
	backpack_board.z_index = level
	backpack_slots.z_index = level


func _select_card_to_discard(instance_id: String) -> void:
	if FinalBossRules.is_saturn(_find_card(_battle.hand, instance_id)):
		hint_label.text = "逆行土星无法弃置，请选择其他手牌"
		return
	if _discard_selection_ids.has(instance_id) \
			or _find_card(_battle.hand, instance_id).is_empty():
		return
	_discard_selection_ids.append(instance_id)
	_begin_card_transfer(_find_card(_battle.hand, instance_id), "discard")
	hint_label.text = "选择弃牌：%d / %d" % [
		_discard_selection_ids.size(), _pending_discard_count,
	]
	_queue_refresh()
	if _discard_selection_ids.size() == _pending_discard_count:
		call_deferred("_submit_discard_selection")


func _submit_discard_selection() -> void:
	if _animating:
		return
	var chosen: Array[String] = _discard_selection_ids.duplicate()
	var previous_count := _pending_discard_count
	var previous_card := _pending_discard_card_id
	# 恢复队列可能立即请求下一次弃牌，先清理本次选择，避免覆盖新请求。
	_pending_discard_count = 0
	_pending_discard_card_id = ""
	_discard_selection_ids.clear()
	var error := _battle.submit_discard_choice(chosen)
	if error != OK:
		_pending_discard_count = previous_count
		_pending_discard_card_id = previous_card
		for instance_id: String in chosen:
			_cancel_card_transfer(instance_id)
		_discard_selection_ids.clear()
		hint_label.text = "提交弃牌选择失败：%d" % error
		_queue_refresh()
		return
	_queue_refresh()
	_drain_resolution_events()


func _on_cancel_pressed() -> void:
	if _busy:
		return
	for instance_id: String in _selected_ids:
		_cancel_card_transfer(instance_id)
	_selected_ids.clear()
	_selected_cards.clear()
	hint_label.text = "已取消编排，卡牌全部返回手牌"
	_queue_refresh()


func _on_play_pressed() -> void:
	# 允许空过：一张不编排也能结束回合，规则队列接受空序列。
	if _busy or not _battle.active:
		return
	# 必须在同步推进规则队列之前保存初始画面，避免刷新提前显示致死的最终快照。
	_begin_presentation()
	# 结算过程不留提示文字，提示只在玩家需要操作时出现。
	hint_label.text = ""
	_refresh_header()

	var sequence: Array[String] = _selected_ids.duplicate()
	var targets := {}
	for instance_id: String in sequence:
		targets[instance_id] = _chosen_enemy_id()
	var error := _battle.commit_player_sequence(sequence, targets)
	if error != OK:
		# 规则预算错误也可能已有部分真实事实；先收尾展示，避免遗留锁。
		if not _resolution_events.is_empty():
			_drain_resolution_events()
		else:
			_busy = false
		hint_label.text = "提交出牌序列失败：%d" % error
		_refresh_header()
		return
	_drain_resolution_events()


## 同一张牌内相邻残片事实批量亮起，日志与反馈仍按真实顺序消费。
## 每格仅等待最后一条 Tween，重复触发不会累加成数十秒的固定等待。
func _flash_relic_cell(cell: int) -> void:
	if not is_instance_valid(_relic_book):
		return
	var animation: Tween = _relic_book.flash_cell(cell)
	if animation != null:
		_relic_flash_tweens[cell] = animation


func _wait_relic_presentation() -> void:
	if _relic_flash_tweens.is_empty():
		return
	_presentation_kind = "relic_wait"
	# kill() 不保证发 finished；退出场景也不能遗留业务锁或等待旧 Tween。
	while is_inside_tree():
		var running := false
		for animation: Tween in _relic_flash_tweens.values():
			if animation != null and animation.is_valid() and animation.is_running():
				running = true
				break
		if not running:
			break
		await get_tree().process_frame
	_relic_flash_tweens.clear()


## 结算等待的唯一入口：先问节拍器要实际秒数，再照它等。名义时长照样记账，
## 「一手 10 张约 10 秒」这条目标才不依赖真实时钟，也不受顿帧压低 time_scale 干扰。
func _wait_resolution(nominal: float, from_relic := false) -> void:
	var wait := nominal if _pacer == null else _pacer.wait_for(nominal, from_relic)
	await get_tree().create_timer(wait).timeout
	if _pacer != null:
		_pacer.spend(nominal)


## 一张牌的收尾等待：跟着这张牌真实播出的动画走，上限是 resolution_delay。
## 没有真实反馈的牌（只抽牌、只调指针）落到最短档，不为了稳妥白等。
func _card_settle_wait() -> float:
	if _card_pointer_only or _feedback == null:
		return pointer_only_delay
	return clampf(_feedback.card_animation_time() * FEEDBACK_SETTLE_SHARE,
		pointer_only_delay, resolution_delay)


func _drain_resolution_events() -> void:
	if _animating or not _busy or not is_inside_tree():
		return
	# 队列预算错误等短路也要把已完成牌的表现收尾，不等待不存在的续接。
	if not _battle.rules.queue.paused:
		_flush_card_end()
	_animating = true
	if _pacer != null:
		_pacer.begin()
	while not _resolution_events.is_empty():
		var event: Dictionary = _resolution_events.pop_front()
		var kind := str(event["kind"])
		var ordinary_effect := kind in ["card_effect", "damage", "heal", "block", "card_discarded", "card_destroyed"] \
			and not bool(event.get("from_relic", false))
		# 有真实结算内容，或触发了典籍，这张牌就不算「只动了指针」。
		if ordinary_effect or kind.begins_with("relic_"):
			_card_pointer_only = false
		if ordinary_effect or kind in ["card_start", "card_end", "enemy_turn", "enemy_action", "enemy_action_end", "turn_started"]:
			await _wait_relic_presentation()
			if not is_inside_tree(): return
		_presentation_kind = kind
		_apply_presentation_snapshot(event)
		# 表现层时间点：音频等订阅者在这里接到的才是「玩家此刻看到的」。
		presentation_event.emit(kind, event)
		# 典籍连锁的边界：第一个 relic_* 事件停这一拍，之后连锁内部各次激活快速连播，
		# 直到下一个非典籍事件或队列排空才收边。不在每次激活处重复停，连锁越长越不拖。
		if kind.begins_with("relic_"):
			if not _relic_chain_open:
				_relic_chain_open = true
				await _wait_resolution(RELIC_CHAIN_PAUSE, true)
				if not is_inside_tree(): return
		elif _relic_chain_open:
			_close_relic_chain()
		match kind:
			"card_start":
				var instance_id := str(event["instance_id"])
				_display_cards.assign(event["play_zone"])
				_card_pointer_only = true
				# 指针每前进一格记一次账，跳数超阈值之后结算才开始提速。
				if _pacer != null:
					_pacer.note_pointer_hop()
				if _feedback != null:
					_feedback.begin_card()
				_queue_refresh()
				await get_tree().process_frame
				if not is_inside_tree(): return
				await _move_pointer_to(instance_id, bool(event.get("from_relic", false)))
				if not is_inside_tree(): return
				phase_label.text = "玩家回合 · 指针位置 %d" % (int(event["pointer"]) + 1)
			"card_effect":
				if not bool(event.get("pointer_only", false)):
					_card_pointer_only = false
			"card_end":
				# 收尾等待跟着这张牌真实播出的动画走，没有内容的牌落到最短档。
				await _wait_resolution(_card_settle_wait())
				if not is_inside_tree(): return
			"relic_trigger":
				# 触发格先亮，停半拍再亮效果格，两盏灯才读得出先后。
				_flash_relic_cell(int(event["cell"]))
				_present_relic_hint(int(event["cell"]))
				await _wait_resolution(RELIC_STEP_BEAT, true)
				if not is_inside_tree(): return
			"relic_effect":
				_flash_relic_cell(int(event["effect"]))
				_present_relic_hint(int(event["effect"]))
			"relic_completed":
				# 亮格时已经推过提示，结算摘要不再显示第二遍。
				_refresh_relic_hud()
			"relic_limited":
				_relic_hints.push("本条连锁已达到安全上限。")
			"damage":
				await _play_damage_feedback(event)
				if not is_inside_tree(): return
			"heal":
				_feedback.on_healed(event["side"], int(event["amount"]), str(event.get("entity_id", "")))
			"block":
				_feedback.on_block_changed(event["side"], int(event["block"]), str(event.get("entity_id", "")))
			"card_discarded":
				var card: Dictionary = event["card"]
				if not _card_transfers.has(str(card.instance_id)):
					_begin_card_transfer(card, "discard")
			"enemy_turn":
				_set_pointer("")
				phase_label.text = "怪物回合"
				await _wait_resolution(enemy_turn_delay)
				if not is_inside_tree(): return
			"enemy_action":
				var acting_name := "怪物"
				for enemy: Dictionary in event["enemies"]:
					if str(enemy.enemy_id) == str(event.entity_id):
						acting_name = str(enemy.get("name", "怪物"))
						break
				phase_label.text = "%s · 第 %d/%d 次行动" % [
					acting_name, int(event.action_index), int(event.action_count)]
				_queue_refresh()
				await _wait_resolution(enemy_action_delay)
				if not is_inside_tree(): return
			"enemy_action_end":
				await _wait_resolution(enemy_action_delay)
				if not is_inside_tree(): return
			"card_destroyed":
				_queue_refresh()
				await _wait_resolution(0.10)
				if not is_inside_tree(): return
			"turn_started":
				phase_label.text = "玩家回合 · 回合开始"
		_queue_refresh()

	_close_relic_chain()
	await _wait_relic_presentation()
	if not is_inside_tree(): return
	if _battle.has_pending_discard_choice():
		_set_pointer(_pending_discard_card_id)
		phase_label.text = "玩家回合 · 等待弃牌"
		hint_label.text = "请点击手牌弃置 %d 张（已选 %d 张）" % [
			_pending_discard_count, _discard_selection_ids.size(),
		]
		_presentation_kind = "choice"
		_animating = false
		# 结算已经播到这张弃牌牌，指针也指到它了，这里才开始压蒙版。
		_discard_focus_armed = true
		_queue_refresh()
		return
	if _battle.pending_pile_count() > 0:
		_presentation_kind = "choice"
		_animating = false
		if not _pending_pile_presentation.is_empty():
			var pending := _pending_pile_presentation
			_pending_pile_presentation = {}
			_show_pile_choice(int(pending["count"]), pending["candidates"])
		_queue_refresh()
		return
	if not _battle.player.get("battle_choice", {}).is_empty():
		_presentation_kind = "choice"
		_animating = false
		if not _pending_battle_presentation.is_empty():
			var pending := _pending_battle_presentation
			_pending_battle_presentation = {}
			_show_battle_choice(str(pending["mode"]), int(pending["count"]), pending["candidates"])
		_queue_refresh()
		return
	if not _resolved_discards.is_empty():
		for card: Dictionary in _resolved_discards.values():
			_begin_card_transfer(card, "discard", true)
		_resolved_discards.clear()
	# 包含玩家快速点牌后仍在飞行的入场与弃牌，不能在收尾前开放奖励。
	_presentation_kind = "transfers"
	while not _card_transfers.is_empty():
		await get_tree().process_frame
		if not is_inside_tree(): return
	_selected_ids.clear()
	_selected_cards.clear()
	_display_cards.clear()
	_busy = false
	_animating = false
	_presentation_kind = ""
	_set_pointer("")
	if not _battle.active:
		_present_battle_ended()
	else:
		hint_label.text = "请选择手牌编排到右侧"
	_queue_refresh()


## 一次受伤表现：飘字、闪红与特效之后叠顿帧。致死且目标是敌人时再补一拍击杀节拍，
## 只拉长表现，不改规则，结算结果仍由原路径决定。
func _play_damage_feedback(event: Dictionary) -> void:
	var side := StringName(event["side"])
	var damage := int(event["damage"])
	var blocked := int(event["blocked"])
	_feedback.on_damaged(side, damage, blocked, str(event.get("entity_id", "")))
	# 包含全额格挡的攻击也占一拍；五连击与三个独立行动都能逐次看清。
	# 快照已先应用，等待使血条有时间完成本次过渡，不拿最终状态倒灌中间帧。
	if not str(event.get("monster_attack", "")).is_empty():
		_queue_refresh()
		await _wait_resolution(enemy_hit_delay)
		if not is_inside_tree(): return
	var lost := maxi(damage - blocked, 0)
	if lost <= 0:
		return
	var lethal := bool(event.get("lethal", false)) and side != CombatFeedback.SIDE_PLAYER
	var duration := 0.0
	if lethal:
		duration = hitstop_kill
	else:
		match CombatFeedback.tier_of(lost):
			CombatFeedback.TIER_MEDIUM:
				duration = hitstop_medium
			CombatFeedback.TIER_HEAVY:
				duration = hitstop_heavy
	_hit_stop.hit_stop(duration)
	if lethal and kill_beat_time > 0.0:
		await get_tree().create_timer(kill_beat_time).timeout


func _on_draw_pile_pressed() -> void:
	if not _busy:
		_open_pile("抽牌堆", _battle.draw_pile)


func _on_discard_pile_pressed() -> void:
	if not _busy:
		_open_pile("弃牌堆", _battle.discard_pile)


func _open_pile(title: String, cards: Array[Dictionary]) -> void:
	_hide_enchantment_hover()
	pile_title.text = "%s（%d 张）" % [title, cards.size()]
	_clear_children(pile_grid)
	for card: Dictionary in cards:
		var slot := _make_card_slot(card, PILE_CARD_SCALE, false)
		var card_id := String(card.get("card_id", ""))
		if not card_id.is_empty():
			var peek := Button.new()
			peek.flat = true
			peek.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			peek.tooltip_text = ""
			peek.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			peek.pressed.connect(_peek_card.bind(card_id, card))
			slot.add_child(peek)
		pile_grid.add_child(slot)
	pile_modal.visible = true


func _close_pile_modal() -> void:
	if _battle != null and _battle.pending_pile_count() > 0:
		return
	pile_modal.visible = false


func _on_modal_shade_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_pile_modal()


func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_refresh_zones")


## —— 手牌拖拽：自己记按下 / 移动 / 松开，不依赖 Control 的 GUI 拖放 ——
## GUI 拖放在 ScrollContainer 里会先被滚动吞掉，表现是「怎么拖都没反应」。

func _input(event: InputEvent) -> void:
	if is_instance_valid(_battle_choice_layer):
		if event is InputEventKey: get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		_handle_menu_key(event)
		return
	if _run_menu.is_open() or pile_modal.visible or _peek_layer.visible or _pending_discard_count > 0:
		return
	if _busy or _battle == null or not _battle.active:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 手牌可以拖进出牌列，出牌列里的牌可以拖动改顺序。
			_drag_card_id = _hand_card_at(event.position)
			_drag_source = "hand" if not _drag_card_id.is_empty() else ""
			if _drag_card_id.is_empty():
				_drag_card_id = _play_card_at(event.position)
				_drag_source = "play" if not _drag_card_id.is_empty() else ""
			_drag_start = event.position
			_drag_active = false
			return
		if _drag_active:
			var dragged := _drag_card_id
			var source := _drag_source
			# 落点先算完再收尾：_finish_drag 会把出处牌恢复不透明，
			# 之后才清空 _drag_card_id，避免残留 id 让下一次移动又抓起来。
			var index := _play_drop_index(event.position)
			var in_play := _play_area_rect().has_point(event.position)
			var in_hand := _hand_area_rect().has_point(event.position)
			_finish_drag(in_hand)
			_drag_card_id = ""
			_drag_source = ""
			if in_play:
				if source == "play":
					_move_play_card(_selected_ids.find(dragged), index)
				elif not dragged.is_empty():
					_insert_selected_card(dragged, index)
				get_viewport().set_input_as_handled()
			elif source == "play" and in_hand:
				# 从出牌列拖回手牌区 = 撤下这张牌，等同点它一次。
				_on_play_card_pressed(dragged)
				get_viewport().set_input_as_handled()
			elif source == "hand" and not in_hand:
				# 手牌拖出去又没落到结算区：与点击等效，直接叠到出牌列末尾。
				_on_hand_card_pressed(dragged)
				get_viewport().set_input_as_handled()
			return
		_drag_card_id = ""
		_drag_source = ""
		return
	if event is InputEventMouseMotion and not _drag_card_id.is_empty():
		if not _drag_active:
			if event.position.distance_to(_drag_start) < 8.0:
				return
			_begin_drag(event.position)
		_move_drag_ghost(event.position)
		_update_hand_gap(event.position)
		_update_drop_hint(event.position)
		_update_drag_preview(event.position)


func _on_play_card_hover(slot: Control, entered: bool, instance_id := "") -> void:
	# 拖拽期间不响应悬停：手里还抓着牌时不该有大图跟着鼠标跳。
	if not is_instance_valid(slot) or _drag_active:
		return
	slot.modulate = Color(1.18, 1.18, 1.18) if entered else Color.WHITE
	if entered:
		var card := _find_selected_card(instance_id)
		if not card.is_empty():
			_show_resolve_preview(String(card.get("card_id", "")), card)
	elif not _busy:
		_resolve_preview.visible = false
	else:
		# 结算中把大图交还给指针，避免悬停移开后结算大图消失。
		_refresh_resolve_preview(_display_pointer_id)


func _play_card_at(at: Vector2) -> String:
	# 出牌列是叠放的：一张牌真正露出来的只有 PLAY_STEP 高的一条，
	# 所以从后往前按可见带命中，最上面那张优先。
	if not play_scroll.get_global_rect().has_point(at):
		return ""
	var rows := play_cards.get_children()
	for index in range(rows.size() - 1, -1, -1):
		var row := rows[index] as Control
		var band := Rect2(row.global_position, Vector2(PLAY_ROW_SIZE.x, PLAY_STEP))
		if band.has_point(at):
			var id := String(row.get_meta("instance_id", ""))
			return id if _selected_ids.has(id) else ""
	if rows.is_empty():
		return ""
	var last := rows[rows.size() - 1] as Control
	var full := Rect2(last.global_position,
		Vector2(PLAY_ROW_SIZE.x, PLAY_CARD_SIZE.y))
	if full.has_point(at):
		var id := String(last.get_meta("instance_id", ""))
		return id if _selected_ids.has(id) else ""
	return ""


func _set_drag_source_alpha(instance_id: String, alpha: float) -> void:
	# 拖出处的牌压成半透明虚影：手牌槽位和出牌列槽位都要管。
	if instance_id.is_empty():
		return
	for slot: Node in hand_cards.get_children():
		if slot is CanvasItem and String(slot.get_meta("instance_id", "")) == instance_id:
			(slot as CanvasItem).modulate.a = alpha
	# 出牌列整行一起压：只压卡槽会被悬停提亮盖掉，看着就没有虚影。
	var index := _play_row_index(instance_id)
	if index >= 0:
		var row := play_cards.get_child(index) as CanvasItem
		if row != null:
			# 这一行还在播入场淡入的话会一直把透明度写回 1.0，先把它收尾。
			var enter: Variant = row.get_meta("enter_tween") if row.has_meta("enter_tween") else null
			if enter is Tween and enter.is_valid():
				enter.kill()
				row.scale = Vector2.ONE
			row.modulate.a = alpha


func _move_play_card(from_index: int, insert_index: int) -> void:
	if from_index < 0 or from_index >= _selected_cards.size():
		return
	var at := insert_index
	if at > from_index:
		at -= 1
	at = clampi(at, 0, _selected_cards.size() - 1)
	if at == from_index:
		return
	_selected_cards.insert(at, _selected_cards.pop_at(from_index))
	_selected_ids.insert(at, _selected_ids.pop_at(from_index))
	_play_insert_index = at
	hint_label.text = ""
	_queue_refresh()


func _card_by_instance(instance_id: String) -> Dictionary:
	var card := _find_hand_card(instance_id)
	if not card.is_empty():
		return card
	var at := _selected_ids.find(instance_id)
	if at >= 0 and at < _selected_cards.size():
		return _selected_cards[at]
	return {}


func _hand_card_at(at: Vector2) -> String:
	if not hand_scroll.get_global_rect().has_point(at):
		return ""
	# 与 GUI 的绘制顺序相同：悬停牌最高，其余牌从后往前命中，支持旋转后的局部矩形。
	var slots := hand_cards.get_children()
	var hovered: Control = null
	for slot: Control in slots:
		if bool(slot.get_meta("hovered", false)):
			hovered = slot
	if hovered != null and Rect2(Vector2.ZERO, hovered.size).has_point(hovered.get_global_transform().affine_inverse() * at):
		return str(hovered.get_meta("instance_id", ""))
	slots.reverse()
	for slot: Control in slots:
		if Rect2(Vector2.ZERO, slot.size).has_point(slot.get_global_transform().affine_inverse() * at):
			return str(slot.get_meta("instance_id", ""))
	return ""


func _begin_drag(at := _drag_start) -> void:
	var card := _card_by_instance(_drag_card_id)
	if FinalBossRules.is_saturn(card):
		_drag_card_id = ""
		hint_label.text = "逆行土星留在手牌中生效，无法拖入出牌区"
		return
	if card.is_empty():
		return
	_drag_active = true
	# 手牌来源起手就压在扇面上，这时不能算「拖出去过」，否则一动就误触发开扇。
	_drag_hand_ever_outside = not _hand_area_rect().has_point(at)
	_hand_gap_open = false
	# 手牌拖出即收扇，不留半透明占位；只有出牌列的牌保留虚影。
	if _drag_source == "play":
		_set_drag_source_alpha(_drag_card_id, PLAY_PLACEHOLDER_ALPHA)
	else:
		# 收扇要有移动时间：先记下每张牌此刻的扇位，好让它们滑过去。
		_hand_pose_from = _hand_poses()
		_queue_refresh()
	if _drag_ghost == null:
		_drag_ghost = Control.new()
		_drag_ghost.name = "HandDragGhost"
		_drag_ghost.z_index = 90
		_drag_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_drag_ghost.size = PLAY_CARD_SIZE
		add_child(_drag_ghost)
	_drag_ghost.visible = true
	_drag_ghost.modulate.a = 1.0
	for child in _drag_ghost.get_children():
		child.queue_free()
	var view: CardView = CARD_SCENE.instantiate()
	view.scale = Vector2.ONE * PLAY_CARD_SCALE
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_ghost.add_child(view)
	var data := _card_data(String(card.get("card_id", "")))
	if data != null:
		view.set_card(data)
	view.set_enchantments(card)
	var drag_px := CardView.text_px_for(PLAY_CARD_SCALE)
	view.apply_compact_layout(PLAY_CARD_SCALE, drag_px.x, drag_px.y)


func _move_drag_ghost(at: Vector2) -> void:
	if _drag_ghost != null and _drag_ghost.visible:
		_drag_ghost.position = at - PLAY_CARD_SIZE * 0.5


func _update_drop_hint(at: Vector2) -> void:
	if _drop_hint == null:
		_drop_hint = Panel.new()
		_drop_hint.name = "DropHint"
		_drop_hint.z_index = 88
		_drop_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1.0, 0.85, 0.45, 0.95)
		style.set_corner_radius_all(2)
		_drop_hint.add_theme_stylebox_override("panel", style)
		add_child(_drop_hint)
	var inside := _play_area_rect().has_point(at)
	_drop_hint.visible = inside
	if not inside:
		return
	var index := _play_drop_index(at)
	var y := play_cards.global_position.y + float(index) * PLAY_STEP - 2.0
	_drop_hint.size = Vector2(PLAY_CARD_SIZE.x, 4.0)
	_drop_hint.position = Vector2(play_cards.global_position.x + PLAY_POINTER_W, y)


func _finish_drag(return_to_hand := false) -> void:
	if not _busy and _resolve_preview != null:
		_resolve_preview.hide()
	_drag_active = false
	_set_drag_source_alpha(_drag_card_id, 1.0)
	# 扇面要动的话，滑动从当前位姿接着走，别瞬跳。
	if return_to_hand or _hand_gap_open:
		_hand_pose_from = _hand_poses()
	if return_to_hand and not _drag_card_id.is_empty():
		# 归位的牌不是新抽的，不走抽牌堆的抽牌动画，直接落回空位。
		_hand_ids_previous[_drag_card_id] = true
	_hand_gap_open = false
	_queue_refresh()
	if _drag_ghost != null:
		_drag_ghost.visible = false
	if _drop_hint != null:
		_drop_hint.visible = false


## 这张牌应该排在手牌的第几位；不想留空位时返回 -1。
## 拖动中的牌不进槽位，所以要按「含它在内」的完整列表数位次。
func _hand_gap_index(displayed_hand: Array[Dictionary], dragged_id: String) -> int:
	if not _hand_gap_open or dragged_id.is_empty():
		return -1
	var index := 0
	for card: Dictionary in displayed_hand:
		var instance_id := String(card["instance_id"])
		if instance_id == dragged_id:
			return index
		if _selected_ids.has(instance_id) or _discard_selection_ids.has(instance_id):
			continue
		index += 1
	return -1


## 拖着牌跨越扇面边界：进扇面就撑开、在原位留出空位；出扇面就收扇。
func _update_hand_gap(at: Vector2) -> void:
	var inside := _hand_area_rect().has_point(at)
	# 出过扇面才算「拖出去过」：手牌来源起手就压在扇面上，不该当场又撑开。
	if not inside:
		_drag_hand_ever_outside = true
	var open := inside and _drag_hand_ever_outside
	if open == _hand_gap_open:
		return
	_hand_pose_from = _hand_poses()
	_hand_gap_open = open
	_queue_refresh()


## 槽位刚重建的这一刻，指针可能正压在它上面：Godot 会立刻给新槽位派发一次 mouse_entered，
## 于是「刚松手归位的牌」当场进入悬停，和扇面的补间抢位置，看着就是抬起来却没摆正。
## 屏蔽一帧再放开，悬停只由玩家真实的指针移动触发，下一帧指针还在上面时 Godot 会自然重派。
func _suppress_hover_until_next_frame(slot: Control) -> void:
	for child in slot.get_children():
		if child is CardView:
			var view := child as CardView
			var original := view.mouse_filter
			view.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_restore_card_view_filter.call_deferred(view, original)
			return


func _restore_card_view_filter(view: CardView, original: Control.MouseFilter) -> void:
	if is_instance_valid(view):
		view.mouse_filter = original


func _play_area_rect() -> Rect2:
	return play_scroll.get_global_rect()


func _hand_area_rect() -> Rect2:
	return hand_scroll.get_global_rect()


func _play_drop_index(at: Vector2) -> int:
	var row_index := int(roundf((at.y - play_cards.global_position.y) / PLAY_STEP))
	var selected_before := 0
	for index in mini(maxi(row_index, 0), play_cards.get_child_count()):
		if _selected_ids.has(str(play_cards.get_child(index).get_meta("instance_id", ""))):
			selected_before += 1
	return selected_before


func _insert_selected_card(instance_id: String, index: int) -> void:
	if _busy or _pending_discard_count > 0:
		return
	_on_hand_card_pressed(instance_id)
	var added := _selected_ids.find(instance_id)
	if added < 0:
		return
	var at := clampi(index, 0, _selected_cards.size() - 1)
	_selected_cards.insert(at, _selected_cards.pop_at(added))
	_selected_ids.insert(at, _selected_ids.pop_at(added))
	_play_insert_index = at


func _on_play_card_pressed(instance_id: String) -> void:
	if _busy or not _battle.active:
		return
	if not _selected_ids.has(instance_id):
		return
	_cancel_card_transfer(instance_id)
	var at := _selected_ids.find(instance_id)
	_selected_ids.remove_at(at)
	_selected_cards.remove_at(at)
	hint_label.text = ""
	_queue_refresh()


func _find_hand_card(instance_id: String) -> Dictionary:
	if _battle == null:
		return {}
	for card: Dictionary in _battle.hand:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}


func _on_card_destroyed_visual(card: Dictionary, _reason: StringName) -> void:
	_queue_presentation("card_destroyed", {"card": card.duplicate(true)})


func _on_card_discarded_visual(card: Dictionary, reason: StringName) -> void:
	if reason == &"resolved" and _busy:
		# 同步规则已入弃，仍须等指针播放完整个出牌序列后再飞走。
		_resolved_discards[str(card.instance_id)] = card.duplicate(true)
	elif _busy:
		_queue_presentation("card_discarded", {"card": card.duplicate(true)})
	else:
		if not _card_transfers.has(str(card.instance_id)):
			_begin_card_transfer(card, "discard")


func _transfer_source(instance_id: String, from_play: bool) -> CardView:
	if from_play:
		var index := _play_row_index(instance_id)
		if index >= 0:
			var slot: Node = play_cards.get_child(index).get_child(0)
			if slot.get_child_count() > 0:
				return slot.get_child(0) as CardView
	else:
		for slot: Node in hand_cards.get_children():
			if str(slot.get_meta("instance_id", "")) == instance_id:
				return slot.get_child(0) as CardView
	return null


func _begin_card_transfer(card: Dictionary, destination: String, from_play := false) -> void:
	var instance_id := str(card.instance_id)
	var source := _transfer_source(instance_id, from_play)
	if source == null and destination != "hand":
		return
	var inverse := get_global_transform_with_canvas().affine_inverse()
	var source_transform: Transform2D
	if destination == "hand":
		var center := inverse * draw_button.get_global_rect().get_center()
		var travel_scale := Vector2.ONE * CARD_TRANSFER.TRAVEL_SCALE
		source_transform = Transform2D(0.0, travel_scale, 0.0, center - Vector2(240, 409) * travel_scale)
	else:
		source_transform = inverse * source.get_global_transform_with_canvas()
	# 快速出牌/取消时不留下重影；前一飞牌若尚未落位，则从其当前位置继续。
	if _card_transfers.has(instance_id):
		var old_ghost: Control = _card_transfers[instance_id].ghost
		source_transform = old_ghost.get_transform()
		_cancel_card_transfer(instance_id)
	var ghost := CARD_TRANSFER.new()
	ghost.name = "CardTransfer"
	var view: CardView = CARD_SCENE.instantiate()
	var data := _card_data(str(card.card_id))
	if data != null:
		view.set_card(data)
	view.set_enchantments(card)
	var px := CardView.text_px_for(HAND_CARD_SCALE)
	view.apply_compact_layout(HAND_CARD_SCALE, px.x, px.y)
	ghost.add_child(view)
	add_child(ghost)
	# 等待手牌/出牌列布局和自动滚动结束，再启动；等待期间保留起飞姿态。
	ghost.size = Vector2(480, 818)
	ghost.pivot_offset = ghost.size * 0.5
	ghost.position = source_transform * ghost.pivot_offset - ghost.pivot_offset
	ghost.scale = source_transform.get_scale()
	ghost.rotation = source_transform.get_rotation()
	ghost.z_index = 200
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_transfers[instance_id] = {"ghost": ghost, "destination": destination, "from_play": from_play}
	ghost.completed.connect(_finish_card_transfer.bind(instance_id, ghost))
	if source != null:
		source.modulate.a = 0.0
	call_deferred("_launch_card_transfer", instance_id, ghost, source_transform)


func _launch_card_transfer(instance_id: String, ghost: Control, source_transform: Transform2D) -> void:
	await get_tree().process_frame
	if not is_inside_tree(): return
	await get_tree().process_frame
	if not is_inside_tree(): return
	if not _card_transfers.has(instance_id) or _card_transfers[instance_id].ghost != ghost:
		return
	var discard := str(_card_transfers[instance_id].destination) == "discard"
	ghost.start(source_transform, _card_transfer_target.bind(instance_id), discard)


## 飞牌只剩弃牌，目标固定为弃牌堆按钮。
func _card_transfer_target(instance_id: String) -> Dictionary:
	var transfer: Dictionary = _card_transfers[instance_id]
	var inverse := get_global_transform_with_canvas().affine_inverse()
	if str(transfer.destination) in ["play", "hand"]:
		var in_play := str(transfer.destination) == "play"
		var view := _transfer_source(instance_id, in_play)
		if view != null:
			var transform := inverse * view.get_global_transform_with_canvas()
			return {"center": transform * Vector2(240, 409), "scale": transform.get_scale().x,
				"rotation": transform.get_rotation()}
		if not in_play:
			return {"center": inverse * hand_cards.get_global_rect().get_center(), "scale": HAND_CARD_SCALE}
		return {"center": inverse * _play_area_rect().get_center(), "scale": PLAY_CARD_SCALE}
	return {"center": inverse * discard_button.get_global_rect().get_center(), "scale": 0.025}


func _hide_transfer_targets() -> void:
	for instance_id: String in _card_transfers:
		var transfer: Dictionary = _card_transfers[instance_id]
		if str(transfer.destination) == "play" or bool(transfer.from_play):
			var view := _transfer_source(instance_id, true)
			if view != null:
				view.modulate.a = 0.0
		else:
			var view := _transfer_source(instance_id, false)
			if view != null:
				view.modulate.a = 0.0


func _finish_card_transfer(instance_id: String, ghost: Control) -> void:
	if not _card_transfers.has(instance_id) or _card_transfers[instance_id].ghost != ghost:
		return
	if str(_card_transfers[instance_id].destination) in ["play", "hand"]:
		var view := _transfer_source(instance_id, str(_card_transfers[instance_id].destination) == "play")
		if view != null:
			view.modulate.a = 1.0
	_card_transfers.erase(instance_id)


func _cancel_card_transfer(instance_id: String) -> void:
	if not _card_transfers.has(instance_id):
		return
	_card_transfers[instance_id].ghost.cancel()
	_card_transfers.erase(instance_id)


func _refresh_zones() -> void:
	_refresh_queued = false
	_sync_discard_focus()
	if not is_inside_tree():
		return
	var insert_at := _play_insert_index
	_play_insert_index = -1
	if _battle == null:
		return
	_hide_enchantment_hover()
	_clear_children(hand_cards)
	_clear_children(play_cards)

	var hand_slots: Array[Control] = []
	_fan_target = null
	var displayed_hand: Array[Dictionary] = _presented_hand if _busy else _battle.hand
	# 拖拽中的牌挂在光标上，手牌里给它留出空位，不补牌也不飞抽牌动画。
	var dragged_id := _drag_card_id if _drag_active else ""
	var gap_index := _hand_gap_index(displayed_hand, dragged_id)
	for card: Dictionary in displayed_hand:
		var instance_id := String(card["instance_id"])
		if _selected_ids.has(instance_id) or _discard_selection_ids.has(instance_id) \
				or instance_id == dragged_id:
			continue
		var slot := _make_card_slot(card, HAND_CARD_SCALE, true)
		hand_cards.add_child(slot)
		# 重建这一刻指针可能正压在这个位置，Godot 会立刻给新槽位派发一次 mouse_entered。
		# 先屏蔽一帧再放开：下一帧指针真的还在上面时才会自然重新派发，不用自己同步悬停状态。
		_suppress_hover_until_next_frame(slot)
		hand_slots.append(slot)
	_layout_hand(hand_slots, gap_index)
	_play_deal_animation(hand_slots)
	_animate_hand_relayout(hand_slots)
	hand_count_label.text = "%d 张" % hand_slots.size()

	if _busy:
		for card: Dictionary in _display_cards:
			play_cards.add_child(_make_play_row(card))
	else:
		var preview: Array[Dictionary] = _battle.play_zone.duplicate(true)
		for card: Dictionary in _selected_cards:
			var vacant := -1
			for index in preview.size():
				if bool(preview[index].get("slot_empty", false)):
					vacant = index
					break
			if vacant < 0:
				preview.append(card)
			else:
				preview[vacant] = card
		for card: Dictionary in preview:
			play_cards.add_child(_make_play_row(card))
	# 新版单列叠牌按后牌在上显示；规则顺序仍由 main 的事件队列决定。
	for index in play_cards.get_child_count():
		play_cards.get_child(index).z_index = index + 1
	_layout_play_rows()
	if not _busy:
		_animate_play_insert(insert_at)
		_animate_new_play_row(play_cards.get_child_count())
		call_deferred("_scroll_play_to_latest")
	_hide_transfer_targets()
	_set_pointer(_display_pointer_id)
	# 刷新会重造出牌列，拖拽中的虚影透明度得按当前状态补回去，否则一站到手上就变实心。
	if _drag_active and _drag_source == "play":
		_set_drag_source_alpha(_drag_card_id, PLAY_PLACEHOLDER_ALPHA)

	_refresh_header()
	_refresh_combat_status()
	_refresh_battle_actions()


func _animate_play_insert(index: int) -> void:
	if index < 0:
		return
	# 插入点之后的牌先让出一格，再滑回位，形成"让位"手感。
	for i in range(index + 1, play_cards.get_child_count()):
		var row := play_cards.get_child(i) as Control
		if row == null:
			continue
		if _card_transfers.has(str(row.get_meta("instance_id", ""))):
			continue
		var target := row.position
		row.position = target - Vector2(0.0, PLAY_STEP)
		var tween := row.create_tween()
		tween.tween_property(row, "position", target, 0.16) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _scroll_play_to_latest() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if is_inside_tree() and is_instance_valid(play_scroll) and not _busy:
		play_scroll.scroll_vertical = 1_000_000


func _animate_new_play_row(count: int) -> void:
	# 只有"又出了一张"才播入场：清空重排、结算刷新都不重放。
	if count <= _play_rows_shown:
		_play_rows_shown = count
		return
	_play_rows_shown = count
	var row := play_cards.get_child(count - 1) as Control
	if row == null:
		return
	if _card_transfers.has(str(row.get_meta("instance_id", ""))):
		return
	row.modulate.a = 0.0
	row.scale = Vector2(0.9, 0.9)
	var tween := row.create_tween()
	row.set_meta("enter_tween", tween)
	tween.set_parallel(true)
	tween.tween_property(row, "modulate:a", 1.0, 0.16)
	tween.tween_property(row, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _refresh_header() -> void:
	if _battle == null:
		return
	var next_turn := "回合 %d" % (_presentation_turn if _busy else _battle.turn_number)
	turn_label.text = next_turn
	if next_turn != _turn_pop_text:
		_turn_pop_text = next_turn
		_pop_turn_label()
	_refresh_coin()
	if not _battle.active and not _presentation_pending():
		phase_label.text = "战斗胜利" if _battle.phase == BattleStateMachine.Phase.VICTORY else "战斗结束"
		if not _busy:
			hint_label.text = "战斗%s，点击左侧重开战斗。效果抽牌仍可触发典籍。" % ("胜利" if _battle_result == "victory" else "结束")
	elif not _busy:
		phase_label.text = "玩家回合 · 编排阶段"
	count_label.text = "首抽 %d  |  每回合抽 %d  |  出牌上限 %d" % [
		initial_draw_count, per_turn_draw_count, _battle.effective_play_limit(),
	]
	draw_pile_count.text = str(_presented_draw_count if _busy else _battle.draw_pile.size())
	discard_pile_count.text = str(_presented_discard_count if _busy else _battle.discard_pile.size())
	draw_button.disabled = _busy
	discard_button.disabled = _busy
	cancel_button.disabled = _busy or _selected_ids.is_empty()
	# 允许空过：手上没牌、出牌区也空着也能结束回合。
	play_button.disabled = _busy or not _battle.active \
		or _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION
	var locked_count := 0
	for card: Dictionary in _battle.play_zone:
		if not bool(card.get("slot_empty", false)):
			locked_count += 1
	var to_commit := _selected_ids.size() + locked_count
	# 结算数为 0 时按钮照样可点，点它就是结束回合，不再单独换文案。
	play_button.text = "结算 %d" % to_commit
	play_count_label.text = "%d/%d" % [_used_slots(), _battle.effective_play_limit()]
	_restart_button.disabled = _busy
	for slot: Node in hand_cards.get_children():
		var button := slot.get_child(1) as Button
		if button != null:
			button.disabled = not _can_click_hand()


func _pop_turn_label() -> void:
	# 回合数变化时轻轻弹一下，让"换回合了"这件事有反馈。
	turn_label.pivot_offset = turn_label.size * 0.5
	turn_label.scale = Vector2(1.18, 1.18)
	turn_label.modulate = Color(1.0, 0.92, 0.72)
	var tween := turn_label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(turn_label, "scale", Vector2.ONE, 0.24) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(turn_label, "modulate", Color.WHITE, 0.3)


func _refresh_combat_status() -> void:
	if _battle == null or _battle.enemies.is_empty():
		return
	if _busy and not _presented_player.is_empty() and not _presented_enemies.is_empty():
		_render_combat_snapshot(_presented_player, _presented_enemies)
		return
	_render_combat_snapshot(_battle.player, _battle.enemies)


## 渲染一份战斗快照。enemies 必须先复制再用：调用方会把 _presented_enemies 本身传进来，
## 直接 clear() 会把传进来的那个数组一起清空，本次渲染就成了「空敌人列表」，
## 表现是整块敌人槽被销毁重建，结算期间反复发生就是敌人在闪。
func _render_combat_snapshot(player_data: Dictionary, enemies: Array) -> void:
	var enemy_list: Array = enemies.duplicate(true)
	_presented_player = player_data.duplicate(true)
	_presented_enemies.assign(enemy_list)
	_render_health(player_hp_fill, player_hp_block, player_hp_num, player_data,
		PLAYER_BAR_LEFT, PLAYER_BAR_WIDTH, &"player")
	_render_buffs(player_buff_row, player_data.get("buffs", []), 1.0)
	player_status.text = "玩家  HP %d/%d  格挡 %d\nBuff：%s" % [
		int(player_data.get("health", 0)), int(player_data.get("max_health", 0)),
		int(player_data.get("block", 0)), _format_buffs(player_data.get("buffs", [])),
	]
	enemy_rack.refresh(enemy_list, _chosen_enemy_id())
	if intent_board != null:
		intent_board.show_snapshot(player_data, enemy_list, _resolver.buff_catalog if _resolver != null else {}, _presentation_turn if _busy else _battle.turn_number)
	var lines: Array[String] = []
	for enemy: Dictionary in enemy_list:
		_render_enemy_slot(enemy)
		lines.append("%s HP %d/%d 格挡 %d" % [
			str(enemy.get("name", "CHR-025")), int(enemy.get("health", 0)),
			int(enemy.get("max_health", 0)), int(enemy.get("block", 0)),
		])
	enemy_status.text = "\n".join(lines)


## 一个敌方槽位的全部显示内容：立绘、名字、意图、血条与 buff。
func _render_enemy_slot(enemy: Dictionary) -> void:
	var slot := enemy_rack.slot_for(str(enemy.get("enemy_id", "")))
	if slot == null:
		return
	if not slot.intent_strip.hint_requested.is_connected(_show_intent_tip):
		slot.intent_strip.hint_requested.connect(_show_intent_tip)
		slot.intent_strip.hint_hidden.connect(_hide_intent_tip)
	var portrait := str(enemy.get("art_path", ""))
	if not portrait.is_empty():
		slot.set_portrait_texture(TextCatalogService.art_texture(portrait))
	slot.set_frame_path(_enemy_bar_frame(str(enemy.get("grade", ""))))
	slot.name_label.text = str(enemy.get("name", "CHR-025"))
	var interactive := not _busy and not _animating and _battle.active and _battle.phase == BattleStateMachine.Phase.PLAYER_ACTION
	var taunt := ""
	for candidate: Dictionary in _presented_enemies:
		if int(candidate.get("health", 0)) > 0 and bool(candidate.get("taunt", false)):
			taunt = str(candidate.enemy_id)
			break
	slot.show_snapshot_status(enemy, not _presented_enemies.is_empty() and str(_presented_enemies[0].enemy_id) == str(enemy.enemy_id), interactive and (taunt.is_empty() or taunt == str(enemy.enemy_id)), intent_board.preview_for(str(enemy.enemy_id)) if intent_board != null else {})
	_render_health(slot.fill, slot.block_marker, slot.number_label, enemy,
		slot.fill_left(), slot.fill_width(), &"enemy", str(enemy.get("enemy_id", "")))
	_render_buffs(slot.buff_row, enemy.get("buffs", []), 1.0)


func _enemy_bar_frame(grade: String) -> String:
	return ENEMY_BAR_FRAME_PATTERN % {"普通": "小怪", "精英": "精英"}.get(grade, "boss")


func _render_block_shield(side: StringName, block_layers: int, entity_id := "") -> void:
	# 玩家的盾挂在玩家血条右端，始终唯一；敌方的盾归各自槽位，按实体 id 找。
	var shield: Control = player_block_shield if side == &"player" else _enemy_shield(entity_id)
	if shield != null:
		shield.set("value", block_layers)


func _enemy_shield(entity_id: String) -> Control:
	var slot := enemy_rack.slot_for(entity_id)
	return slot.shield if slot != null else null


func _render_health(fill: Control, block: ColorRect, number: Label,
		data: Dictionary, left: float, bar_width: float, side: StringName,
		entity_id := "") -> void:
	var health := int(data.get("health", 0))
	var max_health := maxi(int(data.get("max_health", 1)), 1)
	var block_layers := int(data.get("block", 0))
	var ratio := clampf(float(health) / float(max_health), 0.0, 1.0)
	# 条内左端起算：填充从金框内侧左端向右长，格挡段接在填充右端。
	# 右端斜切交给 HealthFill 自己画，格挡段跟着斜切量右移，贴住填充末端。
	fill.offset_left = left
	fill.offset_right = left + bar_width
	var slant := float(fill.get("slant")) if fill.get("slant") != null else 0.0
	var fill_right := left + bar_width * ratio + slant * ratio
	var initialized := fill.has_meta("ratio")
	var previous := float(fill.get_meta("ratio", ratio))
	fill.set_meta("ratio", ratio)
	# 残影先钉在旧长度上，等正条滑完再追上来，掉的那一截就留在眼睛里。
	var trail = HEALTH_TRAIL_SCRIPT.ensure_on(fill)
	if trail != null:
		trail.sync_from(fill, ratio, HEALTH_TRANSITION_TIME)
	if initialized and is_inside_tree() and not is_equal_approx(previous, ratio):
		var old_tween: Variant = fill.get_meta("tween") if fill.has_meta("tween") else null
		if old_tween is Tween and old_tween.is_valid():
			old_tween.kill()
		# 血条不瞬移：短补间滑到新长度，格挡段跟着走，眼睛能追到掉了多少。
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.set_parallel(true)
		tween.tween_property(fill, "ratio", ratio, HEALTH_TRANSITION_TIME).from_current()
		tween.tween_property(block, "offset_left", fill_right, HEALTH_TRANSITION_TIME)
		tween.tween_property(block, "offset_right",
			minf(fill_right + BLOCK_MARKER_WIDTH, left + bar_width + slant), HEALTH_TRANSITION_TIME)
		fill.set_meta("tween", tween)
		if ratio < previous:
			_flash_health_fill(fill)
	elif not initialized:
		# 首次直接定位；同目标刷新完全不写动画属性，包括Tween尚未开始的那一帧。
		fill.set("ratio", ratio)
		block.offset_left = fill_right
		block.offset_right = minf(fill_right + BLOCK_MARKER_WIDTH, left + bar_width + slant)
	block.visible = false
	_render_block_shield(side, block_layers, entity_id)
	number.text = "∞" if side == &"enemy" and bool(data.get("damage_trial_target", false)) else "%d/%d" % [health, max_health]


## 掉血那一拍血条自己亮一下再收回，对齐《驳回！》的 barHit。
## 走 fill_color 而不是 modulate：modulate 只能把颜色往暗里乘，亮不起来。
func _flash_health_fill(fill: Control) -> void:
	if not is_inside_tree() or fill.get("fill_color") == null:
		return
	var base: Color = fill.get_meta("base_color", fill.get("fill_color"))
	fill.set_meta("base_color", base)
	var old: Variant = fill.get_meta("flash") if fill.has_meta("flash") else null
	if old is Tween and old.is_valid():
		old.kill()
	var flash := create_tween()
	flash.set_parallel(true)
	flash.tween_property(fill, "fill_color", HEALTH_FLASH_COLOR, 0.07)
	flash.chain().tween_property(fill, "fill_color", base, 0.31) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	fill.set_meta("flash", flash)


func _render_buffs(row: HBoxContainer, buffs: Array, chip_scale := 1.0) -> void:
	_hide_buff_tip()
	_clear_children(row)
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		var debuff := buff_id in ["poison", "weak"]
		var layers := int(buff.get("layers", 0))
		var chip := Control.new()
		chip.custom_minimum_size = Vector2(36, 32) * chip_scale
		chip.mouse_filter = Control.MOUSE_FILTER_STOP
		# 悬停能看到这是什么、有什么用。自己画浮层，不用系统 tooltip。
		var tip_text := _buff_tooltip(buff_id, layers)
		chip.mouse_entered.connect(_show_buff_tip.bind(chip, tip_text))
		chip.mouse_exited.connect(_hide_buff_tip)
		var plate := Panel.new()
		plate.position = Vector2.ZERO
		plate.size = Vector2(32, 32) * chip_scale
		var plate_style := StyleBoxFlat.new()
		plate_style.bg_color = Color(0.08, 0.06, 0.05, 0.72)
		plate_style.set_corner_radius_all(6)
		plate_style.set_border_width_all(1)
		plate_style.border_color = Color(0.62, 0.5, 0.3, 0.55)
		plate.add_theme_stylebox_override("panel", plate_style)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(plate)
		var icon := TextureRect.new()
		icon.texture = _buff_icon(buff_id)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(2, 2) * chip_scale
		icon.size = Vector2(28, 28) * chip_scale
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(icon)
		var value := Label.new()
		value.text = str(layers)
		value.position = Vector2(15, 12) * chip_scale
		value.size = Vector2(16, 18) * chip_scale
		if icon.texture == null:
			# 没配图标的 buff：数字居中顶格显示，别留个空底板。
			value.position = Vector2.ZERO
			value.size = Vector2(32, 32) * chip_scale
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		else:
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.add_theme_font_size_override("font_size", maxi(11, int(round(14.0 * chip_scale))))
		value.add_theme_color_override("font_color",
			Color(0.81, 0.89, 0.66) if debuff else Color(0.949, 0.89, 0.776))
		value.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		value.add_theme_constant_override("shadow_offset_x", 1)
		value.add_theme_constant_override("shadow_offset_y", 1)
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(value)
		row.add_child(chip)


func _build_buff_tip() -> void:
	# 和背包页共用同一个浮层组件。
	var tip_script := load(HOVER_TIP_SCRIPT)
	_buff_tip = tip_script.new()
	_buff_tip.name = "BuffTip"
	_buff_tip.z_index = 80
	add_child(_buff_tip)


func _show_buff_tip(anchor: Control, text: String) -> void:
	if _buff_tip == null or not is_instance_valid(anchor):
		return
	# 提示文字也属于来源实体；后排状态说明不能借全局浮层越过主怪。
	var layer_z := 80
	var source: Node = anchor
	while source != null and source != self:
		if source is EnemySlot:
			layer_z = source.feedback_z() + 1
			break
		source = source.get_parent()
	_buff_tip.z_index = layer_z
	_buff_tip.show_for(anchor, text)


func _hide_buff_tip() -> void:
	if _buff_tip != null:
		_buff_tip.hide_tip()


func _show_intent_tip(anchor: Control, text: String) -> void:
	if _intent_tip == null or not is_instance_valid(anchor): return
	_intent_tip_source = anchor.get_parent() as MonsterIntentStrip
	_intent_tip.show_for(anchor, text)


func _hide_intent_tip(source: MonsterIntentStrip) -> void:
	if source != _intent_tip_source: return
	_intent_tip_source = null
	if is_instance_valid(_intent_tip): _intent_tip.hide_tip()



func _buff_tooltip(buff_id: String, layers: int) -> String:
	var text := _buff_text(buff_id)
	var name := String(text.get("name", buff_id))
	var detail := String(text.get("description", ""))
	if detail.is_empty():
		return "%s ×%d" % [name, layers]
	return "%s ×%d\n%s" % [name, layers, detail]


## buff 的名称与说明只在 data/buffs/*.tres 里写一次，悬停提示从这里读。
func _buff_text(buff_id: String) -> Dictionary:
	if _buff_text_by_id.has(buff_id):
		return _buff_text_by_id[buff_id]
	for file: String in ResourceLoader.list_directory("res://data/buffs"):
		if file.get_extension() not in ["tres", "res"]:
			continue
		var data := load("res://data/buffs/%s" % file) as BuffData
		if data == null:
			continue
		_buff_text_by_id[String(data.buff_id)] = {
			"name": data.display_name,
			"description": data.description,
		}
	return _buff_text_by_id.get(buff_id, {})


func _buff_icon(buff_id: String) -> Texture2D:
	if _buff_icon_cache.has(buff_id):
		return _buff_icon_cache[buff_id]
	var path: String = BUFF_ICON_PATHS.get(buff_id, "")
	if path.is_empty():
		return null
	var atlas := _atlas_texture(path, BUFF_ICON_REGION)
	_buff_icon_cache[buff_id] = atlas
	return atlas


func _can_click_hand() -> bool:
	return _battle != null and _battle.active and not _animating and (_pending_discard_count > 0 \
		or (not _busy and _battle.phase == BattleStateMachine.Phase.PLAYER_ACTION))


func _make_card_slot(card: Dictionary, card_scale: float, clickable: bool,
		title_px: int = 0, body_px: int = 0) -> Control:
	if title_px <= 0 or body_px <= 0:
		var px := CardView.text_px_for(card_scale)
		title_px = px.x
		body_px = px.y
	var slot := Control.new()
	var card_size := Vector2(480.0, 818.0) * card_scale
	slot.custom_minimum_size = card_size
	slot.size = card_size
	slot.set_meta("instance_id", String(card["instance_id"]))
	slot.set_meta("base_size", card_size)
	slot.set_meta("base_scale", card_scale)
	if clickable:
		# 手牌从底边向上生长，放大时不会向下挤出屏幕。
		slot.size_flags_vertical = Control.SIZE_SHRINK_END

	var view: CardView = CARD_SCENE.instantiate()
	view.scale = Vector2.ONE * card_scale
	# 轴心取卡面底边中点：放大时向上与左右生长。轴心在未缩放的局部坐标里，
	# 所以按基准缩放补偿偏移，否则卡面会被推离卡槽。
	view.pivot_offset = Vector2(view.custom_minimum_size.x * 0.5,
		view.custom_minimum_size.y)
	view.position = view.pivot_offset * (card_scale - 1.0)
	var data := _card_data(String(card.get("card_id", "")))
	if data != null:
		view.set_card(data)
	view.set_enchantments(card)
	view.apply_compact_layout(card_scale, title_px, body_px)
	slot.add_child(view)
	slot.tooltip_text = CardEnchantments.describe(card)
	view.tooltip_text = slot.tooltip_text

	if clickable:
		var button := Button.new()
		button.flat = true
		button.disabled = not _can_click_hand()
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.tooltip_text = ""
		button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.pressed.connect(_on_hand_card_pressed.bind(String(card["instance_id"])))
		button.mouse_entered.connect(_on_hand_card_hover_changed.bind(slot, view, true))
		button.mouse_exited.connect(_on_hand_card_hover_changed.bind(slot, view, false))
		slot.add_child(button)
	return slot


## 抽进来的牌从抽牌堆中心飞到自己的手牌位，一张一张到手上。
## 手牌每轮都会整块重建（打牌、弃牌同样如此），所以只对"这一轮新出现的牌"播放；
## 已经在手上的牌直接落位，不跟着重飞一遍。
func _play_deal_animation(slots: Array[Control]) -> void:
	var current_ids := {}
	var actual_hand: Array[Dictionary] = _presented_hand if _busy else _battle.hand
	for card: Dictionary in actual_hand:
		current_ids[str(card.instance_id)] = true
	var drawn: Array[Control] = []
	for slot in slots:
		var instance_id := str(slot.get_meta("instance_id"))
		current_ids[instance_id] = true
		if not _hand_ids_previous.has(instance_id):
			drawn.append(slot)
	_hand_ids_previous = current_ids
	var pile := get_node_or_null("DrawPile") as Control
	if drawn.is_empty() or pile == null or not pile.is_inside_tree():
		return
	# 抽牌堆中心换算到手牌容器的局部坐标，手牌位就在这套坐标里。
	var origin: Vector2 = hand_cards.get_global_transform_with_canvas().affine_inverse() \
		* (pile.get_global_transform_with_canvas() * (pile.size * 0.5))
	for index in drawn.size():
		HAND_DEAL_ANIM.play(drawn[index], origin, index)


func _layout_hand(slots: Array[Control], gap_index := -1) -> void:
	# 手牌按固定步长排在中轴上；扇开时在基准位置上加偏移，基准不随动画漂移。
	# gap_index >= 0 表示拖动中的牌在原位留空，扇面按含它的张数撑开，其余牌绕开空位。
	var count := slots.size() + (1 if gap_index >= 0 else 0)
	if count == 0:
		hand_cards.custom_minimum_size = Vector2(HAND_AREA_WIDTH, 0.0)
		hand_cards.size = Vector2(HAND_AREA_WIDTH, HAND_AREA_HEIGHT)
		return
	var gap_step := HAND_CARD_SIZE.x + HAND_GAP
	var squeeze := (HAND_MAX_WIDTH - HAND_CARD_SIZE.x) / maxf(float(count - 1), 1.0)
	var step := minf(gap_step, squeeze)
	var total := step * (count - 1) + HAND_CARD_SIZE.x
	var row_width := maxf(total + HAND_HOVER_MARGIN * 2.0, HAND_AREA_WIDTH)
	if _fan_tween != null and _fan_tween.is_valid():
		_fan_tween.kill()
	hand_cards.custom_minimum_size = Vector2(row_width, 0.0)
	hand_cards.size = Vector2(row_width, HAND_AREA_HEIGHT)
	var start := (row_width - total) * 0.5
	var center := (count - 1) * 0.5
	# 卡底边贴在 HandScroll 底边，边缘牌的扇形下沉由视口裁掉，与作者原版战斗 UI 一致。
	var base_y := HAND_AREA_HEIGHT - HAND_CARD_SIZE.y
	for order in slots.size():
		var slot := slots[order]
		var index := order + (1 if gap_index >= 0 and order >= gap_index else 0)
		slot.size = HAND_CARD_SIZE
		# 绕底边中点旋转，越靠边角度越大；同时沿弧线略微下沉，形成扇形。
		# 悬停时绕底边中点立正，保持底边高度不变。
		var angle := clampf((index - center) * HAND_ARC_SPREAD, -0.23, 0.23)
		slot.set_meta("fan_rotation", angle)
		slot.pivot_offset = Vector2(HAND_CARD_SIZE.x * 0.5, HAND_CARD_SIZE.y)
		slot.rotation = angle
		slot.position = Vector2(start + step * index,
			base_y + (1.0 - cos(angle)) * HAND_ARC_RADIUS)
		slot.set_meta("hand_index", index)
		slot.set_meta("base_x", slot.position.x)


func _fan_factor(count: int) -> float:
	if count >= 1 and count < fan_factor_by_count.size():
		return fan_factor_by_count[count]
	# 超过 10 张沿用最小幅度，保持有扇开动作但不会挤出牌区。
	return fan_factor_by_count[fan_factor_by_count.size() - 1] if count > 10 else 0.0


## 记下每张手牌此刻的扇位，作为收扇 / 开扇滑动的起点。
func _hand_poses() -> Dictionary:
	var poses := {}
	for slot: Control in hand_cards.get_children():
		poses[str(slot.get_meta("instance_id", ""))] = [slot.position, slot.rotation]
	return poses


## 拖拽引起的收扇 / 开扇：新槽先摆回旧扇位，再滑到新布局。
## 其它刷新没有快照，保持瞬排。
func _animate_hand_relayout(slots: Array[Control]) -> void:
	if _hand_pose_from.is_empty():
		return
	var poses := _hand_pose_from
	_hand_pose_from = {}
	if _hand_relayout_tween != null and _hand_relayout_tween.is_valid():
		_hand_relayout_tween.kill()
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	for slot: Control in slots:
		var pose: Variant = poses.get(str(slot.get_meta("instance_id", "")))
		if pose == null:
			continue
		var target_position := slot.position
		var target_rotation := slot.rotation
		slot.position = pose[0]
		slot.rotation = float(pose[1])
		tween.tween_property(slot, "position", target_position, HAND_RELAYOUT_DURATION)
		tween.tween_property(slot, "rotation", target_rotation, HAND_RELAYOUT_DURATION)
	_hand_relayout_tween = tween


func _refresh_hand_fan() -> void:
	# 以当前真正处于悬停态的卡为准；一张都没有时才收扇。
	var target: Control = null
	for child in hand_cards.get_children():
		if bool(child.get_meta("hovered", false)):
			target = child
			break
	if target == _fan_target:
		return
	_fan_target = target
	_apply_hand_fan(target)


func _apply_hand_fan(hovered_slot: Control) -> void:
	# 参考 reference/card-and-dice 的 HandUIController.Hover：以悬停卡为中心，
	# 左右两侧按距离 1/2/3 分别外移大/中/小距离，手牌越多幅度越小；
	# 没有悬停卡时全部回基准位。
	var slots := hand_cards.get_children()
	var count := slots.size()
	var factor := _fan_factor(count)
	var hovered_index := -1
	if hovered_slot != null and is_instance_valid(hovered_slot):
		hovered_index = int(hovered_slot.get_meta("hand_index", -1))
	var duration := fan_duration_in if hovered_index >= 0 else fan_duration_out
	# 旧的扇开补间必须先杀掉：换卡时两条补间同时写 position:x 会互相打架，
	# 表现出来就是扇开中途回缩。
	if _fan_tween != null and _fan_tween.is_valid():
		_fan_tween.kill()
	var tween := create_tween()
	_fan_tween = tween
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	for index in count:
		var slot: Control = slots[index]
		var base_x := float(slot.get_meta("base_x", slot.position.x))
		var offset := 0.0
		if hovered_index >= 0 and index != hovered_index:
			var magnitude := 0.0
			match absi(index - hovered_index):
				1: magnitude = fan_offset_long
				2: magnitude = fan_offset_medium
				3: magnitude = fan_offset_short
			if magnitude > 0.0:
				offset = magnitude * factor * (1.0 if index > hovered_index else -1.0)
			var step := minf(HAND_CARD_SIZE.x + HAND_GAP, (HAND_MAX_WIDTH - HAND_CARD_SIZE.x) / maxf(count - 1, 1.0))
			var required := maxf(0.0, HAND_CARD_SIZE.x * (1.0 + (hand_hover_multiplier - 1.0) * 0.5) + HAND_GAP + 24.0 - absi(index - hovered_index) * step)
			offset = maxf(absf(offset), required) * (1.0 if index > hovered_index else -1.0)
		tween.tween_property(slot, "position:x", base_x + offset, duration)


func _on_hand_card_hover_changed(slot: Control, view: CardView, expanded: bool) -> void:
	if not is_instance_valid(slot) or not is_instance_valid(view):
		return
	# 拖着牌时不响应手牌悬停：手里还抓着牌，扇面不该跟着鼠标放大抬升。
	if _drag_active:
		return
	slot.set_meta("hovered", expanded)
	var instance_id := str(slot.get_meta("instance_id", ""))
	if expanded:
		_show_enchantment_hover(slot, _find_card(_battle.hand, instance_id))
	elif _enchantment_hover_id == instance_id:
		_hide_enchantment_hover()
	var previous: Variant = slot.get_meta("hover_tween") if slot.has_meta("hover_tween") else null
	if previous is Tween and previous.is_valid():
		previous.kill()

	var base_scale := float(slot.get_meta("base_scale", HAND_CARD_SCALE))
	var multiplier := hand_hover_multiplier if expanded else 1.0
	var target_scale := Vector2.ONE * base_scale * multiplier
	slot.z_index = 100 if expanded else 0

	# 悬停卡绕底边中点放大（向上生长，不挤出屏幕），左右相邻卡扇开让位。
	var tween := slot.create_tween()
	tween.set_trans(Tween.TRANS_SPRING if expanded else Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_parallel(true)
	var duration := hand_hover_duration if expanded else hand_hover_return_duration
	tween.tween_property(slot, "rotation", 0.0 if expanded else float(slot.get_meta("fan_rotation", 0.0)), duration)
	# 只转正与放大，底边中点不因悬停上下漂移。
	tween.tween_property(view, "scale", target_scale,
		hand_hover_duration if expanded else hand_hover_return_duration)
	slot.set_meta("hover_tween", tween)
	# A→B 切换时 Godot 先派发 A 的离开、再派发 B 的进入；这里延后一拍统一判定，
	# 避免中途先收扇再展开。
	call_deferred("_refresh_hand_fan")


func _layout_play_rows() -> void:
	# 单列：一列最多 PLAY_ROWS_PER_COLUMN 张，按 PLAY_STEP 向下叠，最新一张在列尾。
	var rows := play_cards.get_children()
	if rows.is_empty():
		play_cards.custom_minimum_size = PLAY_ROW_SIZE
		play_cards.size = PLAY_ROW_SIZE
		return
	# 动态出牌上限可能超过十张，始终保持一列并纵向滚动，不把第十一张挤出右边界。
	var height := float(rows.size() - 1) * PLAY_STEP + PLAY_CARD_SIZE.y
	play_cards.custom_minimum_size = Vector2(PLAY_ROW_SIZE.x, height)
	play_cards.size = play_cards.custom_minimum_size
	for index in rows.size():
		var row := rows[index] as Control
		row.size = PLAY_ROW_SIZE
		row.position = Vector2(0, float(index) * PLAY_STEP)


func _make_play_row(card: Dictionary) -> Control:
	# 出牌列单列叠放：卡图与卡名都露，向下叠 PLAY_STEP，最新一张在列尾。
	var row := Control.new()
	var card_size := PLAY_CARD_SIZE
	row.custom_minimum_size = PLAY_ROW_SIZE
	row.size = PLAY_ROW_SIZE
	row.set_meta("instance_id", String(card["instance_id"]))
	if bool(card.get("slot_empty", false)):
		var empty := Label.new()
		empty.text = "空牌位"
		empty.position = Vector2(PLAY_POINTER_W, 0)
		empty.size = card_size
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(empty)
		return row
	var slot := _make_card_slot(card, PLAY_CARD_SCALE, false)
	slot.position = Vector2(PLAY_POINTER_W, 0.0)
	row.add_child(slot)

	# 点一下把牌拿回手牌。
	var button := Button.new()
	button.name = "TakeBack"
	button.flat = true
	button.disabled = _busy or not _selected_ids.has(str(card.instance_id))
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.position = Vector2(PLAY_POINTER_W, 0.0)
	button.size = Vector2(card_size.x, PLAY_STEP)
	button.pressed.connect(_on_play_card_pressed.bind(String(card["instance_id"])))
	# 悬停提亮：出牌区的牌子小，不给点提示很难看出能拖动、能点回。
	button.mouse_entered.connect(_on_play_card_hover.bind(slot, true, str(card.instance_id)))
	button.mouse_exited.connect(_on_play_card_hover.bind(slot, false, str(card.instance_id)))
	row.add_child(button)

	var highlight := Panel.new()
	highlight.name = "Highlight"
	highlight.position = Vector2(PLAY_POINTER_W - 2.0, -2.0)
	highlight.size = card_size + Vector2(4.0, 4.0)
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	highlight.visible = false
	var highlight_style := StyleBoxFlat.new()
	highlight_style.draw_center = false
	highlight_style.set_border_width_all(2)
	highlight_style.border_color = Color(1.0, 0.85, 0.45, 0.95)
	highlight_style.set_corner_radius_all(4)
	highlight.add_theme_stylebox_override("panel", highlight_style)
	row.add_child(highlight)
	return row


func _make_card_backing(card_size: Vector2) -> Panel:
	# 叠放层的不透明底：颜色比卡面暗一档，边缘收在卡框里，只负责挡住下层。
	var backing := Panel.new()
	backing.name = "Backing"
	backing.position = Vector2(2.0, 2.0)
	backing.size = card_size - Vector2(4.0, 4.0)
	backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backing_style := StyleBoxFlat.new()
	backing_style.bg_color = Color(0.07, 0.058, 0.05, 1.0)
	backing_style.set_corner_radius_all(12)
	backing.add_theme_stylebox_override("panel", backing_style)
	return backing


func _build_settle_pointer() -> void:
	# 结算指针做成一个全局节点而不是每行挂一个：这样能在两张牌之间滑过去。
	_settle_pointer = TextureRect.new()
	_settle_pointer.name = "SettlePointer"
	_settle_pointer.texture = POINTER_TEXTURE
	_settle_pointer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_settle_pointer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_settle_pointer.size = Vector2(56.0, 46.0)
	_settle_pointer.z_index = 60
	_settle_pointer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settle_pointer.visible = false
	add_child(_settle_pointer)


func _play_row_index(instance_id: String) -> int:
	for index in play_cards.get_child_count():
		if String(play_cards.get_child(index).get_meta("instance_id", "")) == instance_id:
			return index
	return -1


## 出牌列超过一屏时要滚：指针要指的那张先滚进视野，否则箭头会停在屏幕外。
func _ensure_play_visible(instance_id: String) -> void:
	var index := _play_row_index(instance_id)
	if index < 0:
		return
	var top := float(index * int(PLAY_STEP))
	var view_height := play_scroll.size.y
	var scrolled := float(play_scroll.scroll_vertical)
	if top >= scrolled and top + PLAY_STEP <= scrolled + view_height:
		return
	var lowest := maxf(0.0, play_cards.size.y - view_height)
	var target := clampf(top - PLAY_STEP, 0.0, lowest)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(play_scroll, "scroll_vertical", int(target), 0.18)
	await tween.finished


func _pointer_target(instance_id: String) -> Vector2:
	for row: Node in play_cards.get_children():
		if String(row.get_meta("instance_id", "")) != instance_id:
			continue
		var row_control := row as Control
		return Vector2(row_control.global_position.x - 4.0,
			row_control.global_position.y + PLAY_CARD_SIZE.y * 0.5 - 23.0)
	return Vector2(-400.0, -400.0)


func _place_pointer(instance_id: String, animated: bool, from_relic := false) -> void:
	if _settle_pointer == null:
		return
	if instance_id.is_empty():
		_settle_pointer.visible = false
		return
	var target := _pointer_target(instance_id)
	if not animated or not _settle_pointer.visible:
		_settle_pointer.position = target
		_settle_pointer.visible = true
		return
	if _pointer_tween != null and _pointer_tween.is_valid():
		_pointer_tween.kill()
	var glide := clampf(_settle_pointer.position.distance_to(target)
		/ POINTER_GLIDE_SPEED, POINTER_GLIDE_MIN, POINTER_GLIDE_MAX)
	if _pacer != null:
		glide = _pacer.wait_for(glide, from_relic)
	_pointer_tween = create_tween()
	_pointer_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_pointer_tween.tween_property(_settle_pointer, "position", target, glide)
	await _pointer_tween.finished


func _set_pointer(instance_id: String) -> void:
	# 指针 = 结算到哪张牌：高亮框 + 箭头 + 左侧大图一起跟着走。
	_display_pointer_id = instance_id
	_refresh_pointer_marks(instance_id)
	_place_pointer(instance_id, false)
	_refresh_resolve_preview(instance_id)


func _refresh_pointer_marks(instance_id: String) -> void:
	for row: Node in play_cards.get_children():
		var pointed := instance_id != "" \
			and String(row.get_meta("instance_id", "")) == instance_id
		var highlight := row.get_node_or_null("Highlight") as Panel
		if highlight != null:
			highlight.visible = pointed


## 结算一张牌的三拍：指针滑过去 → 左侧大图顿一下 → 再放数值与特效。
func _move_pointer_to(instance_id: String, from_relic := false) -> void:
	_display_pointer_id = instance_id
	_refresh_pointer_marks(instance_id)
	await _ensure_play_visible(instance_id)
	await _place_pointer(instance_id, true, from_relic)
	if instance_id == _display_pointer_id:
		_refresh_resolve_preview(instance_id)
		await _wait_resolution(PREVIEW_HOLD, from_relic)


func _build_resolve_preview() -> void:
	# 出牌区左侧的大图：结算到哪张就把那张放大摆出来，不用低头看小卡。
	_resolve_preview = Control.new()
	_resolve_preview.name = "ResolvePreview"
	_resolve_preview.position = RESOLVE_PREVIEW_POS
	_resolve_preview.size = Vector2(480.0, 818.0) * RESOLVE_PREVIEW_SCALE
	_resolve_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_resolve_preview.z_index = 40
	_resolve_preview.visible = false
	add_child(_resolve_preview)
	_resolve_view = CARD_SCENE.instantiate()
	_resolve_view.scale = Vector2.ONE * RESOLVE_PREVIEW_SCALE
	_resolve_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_resolve_preview.add_child(_resolve_view)


func _build_peek() -> void:
	# 牌堆/卡组点一张看大图：整屏压暗 + 0.7 倍大卡，点任意处关闭。
	_peek_layer = Control.new()
	_peek_layer.name = "PeekLayer"
	_peek_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_peek_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_peek_layer.z_index = 400
	_peek_layer.visible = false
	add_child(_peek_layer)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.018, 0.016, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(_on_peek_input)
	_peek_layer.add_child(shade)
	_peek_view = CARD_SCENE.instantiate()
	_peek_view.scale = Vector2.ONE * PEEK_CARD_SCALE
	_peek_view.position = (Vector2(1920.0, 1080.0) - Vector2(480.0, 818.0) * PEEK_CARD_SCALE) * 0.5
	_peek_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_peek_layer.add_child(_peek_view)


func _peek_card(card_id: String, card: Dictionary = {}) -> void:
	if card_id.is_empty():
		return
	var data := _card_data(card_id)
	if data == null:
		return
	_peek_view.set_card(data)
	_peek_view.set_enchantments(card)
	var peek_px := CardView.text_px_for(PEEK_CARD_SCALE)
	_peek_view.apply_compact_layout(PEEK_CARD_SCALE, peek_px.x, peek_px.y)
	_peek_layer.visible = true
	_peek_layer.modulate.a = 0.0
	_peek_layer.create_tween().tween_property(_peek_layer, "modulate:a", 1.0, 0.12)


func _on_peek_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_peek_layer.visible = false
		get_viewport().set_input_as_handled()


func _refresh_resolve_preview(instance_id: String) -> void:
	if _resolve_preview == null or _resolve_view == null:
		return
	var card := _find_selected_card(instance_id)
	if card.is_empty() or not _busy:
		_resolve_preview.visible = false
		return
	_show_resolve_preview(String(card.get("card_id", "")), card)


## 把某张卡按结算大图的规格摆到左侧。结算指针与出牌列悬停共用这一份。


func _find_selected_card(instance_id: String) -> Dictionary:
	if instance_id.is_empty():
		return {}
	for card: Dictionary in _display_cards + _selected_cards + _battle.play_zone:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}


func _on_player_portrait_input(event: InputEvent) -> void:
	# 战斗里也能看：点头像打开冒险菜单，地图页只查看不移动角色。
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_open_run_menu()


func _on_menu_abandon() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		var error: Error = gateway.abandon_run()
		if error != OK:
			hint_label.text = "放弃本局失败：%d" % error
			return
	SceneTransition.change_scene_to_file(MENU_SCENE)


func _on_menu_return() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		var error: Error = gateway.save_current()
		if error != OK:
			hint_label.text = "保存失败，仍留在战斗：%d" % error
			return
	SceneTransition.change_scene_to_file(MENU_SCENE)


func _on_menu_quit() -> void:
	var gateway := get_node_or_null("/root/SaveGateway")
	if gateway != null:
		gateway.quit_game()
	else:
		get_tree().quit()


func _open_run_menu(page: int = 1) -> void:
	_relic_book._hide_tip()
	_hide_enchantment_hover()
	if _run_menu == null or _busy:
		return
	if _map_page_source == null:
		_map_page_source = _build_map_page_source()
	_run_menu.set_battle_context(_battle, _resolver.card_catalog, _relic_board)
	_run_menu.open(page)


func _build_map_page_source() -> Control:
	# 只查看的地图：真实渲染 + 滚轮缩放 + 拖动平移，不带角色位置。
	var data := _map_snapshot_data()
	if data.is_empty():
		return null
	# 先挂进浮层再喂数据，查看器内部节点在 _ready 里才建好。
	var viewer_script: Script = null
	if ResourceLoader.exists(MAP_VIEWER_PATH):
		viewer_script = load(MAP_VIEWER_PATH) as Script
	if viewer_script == null:
		return null
	var viewer: Control = viewer_script.new() as Control
	if viewer == null:
		return null
	_run_menu.set_map_viewer(viewer)
	viewer.set_map(data, 60.0)
	return viewer


func _map_snapshot_data() -> Dictionary:
	# 战斗里没有跑图会话，按"全图已知"喂给查看器：地形与全部节点都看得见，
	# 方便战斗中规划路线。地图界面里改喂会话的已探索视图。
	if not FileAccess.file_exists(MAP_SNAPSHOT_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_SNAPSHOT_PATH))
	if not parsed is Dictionary:
		return {}
	var data: Dictionary = parsed
	for cell: Variant in data.get("cells", []):
		if cell is Dictionary:
			cell["known"] = true
	for node: Variant in data.get("nodes", []):
		if node is Dictionary:
			node["known"] = true
	return data


func _on_hand_scroll_input(event: InputEvent) -> void:
	# 空白处按住左键横拖即可翻看后面的牌；卡片自身的点击不受影响。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_hand_dragging = event.pressed
		if event.pressed:
			_hand_drag_origin = event.position.x + float(hand_scroll.scroll_horizontal)
	elif event is InputEventMouseMotion and _hand_dragging:
		hand_scroll.scroll_horizontal = int(_hand_drag_origin - event.position.x)


func _clear_children(container: Node) -> void:
	# queue_free 而不是 free，且所有点击后的刷新都经 call_deferred 进入这里；
	# 避免释放正在派发 pressed 信号的锁定对象。
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _card_data(card_id: String) -> CardData:
	return _resolver.card_catalog.get(card_id) if _resolver != null else null


static func _buff_display_name(buff_id: String) -> String:
	return String({
		"poison": "中毒", "strength": "力量", "weak": "虚弱",
		"vulnerable": "易伤", "tenacity": "坚韧",
	}.get(buff_id, buff_id))
static func _format_buffs(buffs: Array) -> String:
	if buffs.is_empty():
		return "无"
	var names: Array[String] = []
	for buff: Dictionary in buffs:
		var buff_id := String(buff.get("buff_id", ""))
		var display := String({
			"poison": "中毒", "strength": "力量", "weak": "虚弱",
		}.get(buff_id, buff_id))
		names.append("%s %d" % [display, int(buff.get("layers", 0))])
	return "、".join(names)


static func _find_card(cards: Array[Dictionary], instance_id: String) -> Dictionary:
	for card: Dictionary in cards:
		if String(card.get("instance_id", "")) == instance_id:
			return card
	return {}


func _setup_monster_battle_text() -> void:
	# 背景/怪物 < 台词 < 所有其他 UI；保留现有节点路径及输入关系。
	$Background.z_index = EnemySlot.BACKGROUND_Z
	$BackgroundDim.z_index = EnemySlot.BACKGROUND_DIM_Z
	_monster_text = MonsterBattleText.new()
	_monster_text.name = "MonsterBattleText"
	add_child(_monster_text)
	_monster_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_monster_text.context_provider = _monster_text_context
	if not is_instance_valid(_battle) or _battle.enemies.is_empty() or not _battle_result.is_empty():
		return
	var path := TextCatalog.monster_battle_text_path(_battle.enemies[0])
	if path.is_empty() or path == "暂无":
		return
	var error := _monster_text.configure(path, SeedService.get_main_seed(),
		[_battle.map_id, _battle.node_id, _battle.battle_index, path])
	if error != OK:
		push_warning("怪物战斗文本无法读取：%s (%d)" % [path, error])


func _monster_text_context() -> Dictionary:
	# 合并后的场景可能因子控件最小尺寸高于窗口；只在真正可见的视口内放字。
	var viewport_area: Rect2 = get_global_transform_with_canvas().affine_inverse() * get_viewport_rect()
	var visible_area := Rect2(Vector2.ZERO, size).intersection(viewport_area)
	var blocked: Array[Rect2] = []
	# EnemyRack 立绘不避让，其中的血条、意图与 Buff 仍是应避让的 UI。
	var inverse := get_global_transform_with_canvas().affine_inverse()
	for slot: EnemySlot in enemy_rack.slots:
		if not slot.is_visible_in_tree(): continue
		for control: Control in [slot._bar, slot.name_label, slot.buff_row, slot.intent_strip, slot.shield]:
			if control.is_visible_in_tree():
				blocked.append((inverse * control.get_global_transform_with_canvas()) * Rect2(Vector2.ZERO, control.size))
	for child: Node in get_children():
		if not child is Control or not child.is_visible_in_tree() or child == _monster_text \
				or child.name in [&"Background", &"BackgroundDim", &"EnemyRack", &"RunMenuOverlay", &"PeekLayer", &"CombatFeedback", &"BuffTip", &"IntentTip"]:
			continue
		var rect: Rect2 = child.get_rect()
		# 手持卡最大1.5倍及弹簧过冲的活动区域，一直保留而非仅避开当前小卡面。
		if child == hand_scroll:
			rect.position.y -= 150.0
			rect.size.y += 150.0
		# 出牌区即使为空也保留完整区域，不随 VBox 最小尺寸收缩。
		if child == play_scroll:
			rect = rect.merge(play_scroll.get_rect())
		if rect.has_area():
			blocked.append(rect.grow(10.0))
	return {"area": visible_area, "blockers": blocked,
		"suspended": pile_modal.visible or _run_menu.is_open() or _peek_layer.visible}


func _restart_battle() -> void:
	if not _busy:
		var error := SceneTransition.change_scene_to_file(scene_file_path)
		if error != OK:
			hint_label.text = "重开战斗失败：%d" % error


func _hide_enchantment_hover() -> void:
	_enchantment_hover_id = ""
	if is_instance_valid(_enchantment_hover):
		_enchantment_hover.hide()


func _show_enchantment_hover(slot: Control, card: Dictionary) -> void:
	_hide_enchantment_hover()
	if card.get("enchantments", []).is_empty():
		return
	if not is_instance_valid(_enchantment_hover):
		_enchantment_hover = PanelContainer.new()
		_enchantment_hover.name = "EnchantmentHover"
		_enchantment_hover.z_index = 2000
		_enchantment_hover.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := CommonUiSkin.panel("tooltip", Vector4(16, 12, 16, 12))
		_enchantment_hover.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		label.custom_minimum_size.x = 420
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 22)
		label.add_theme_color_override("font_color", Color("ecd7ab"))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_enchantment_hover.add_child(label)
		add_child(_enchantment_hover)
	var label: Label = _enchantment_hover.get_child(0)
	label.text = CardEnchantments.describe(card)
	_enchantment_hover_id = str(card.instance_id)
	_enchantment_hover.show()
	_enchantment_hover.reset_size()
	call_deferred("_position_enchantment_hover", slot, _enchantment_hover_id)


func _position_enchantment_hover(slot: Control, id: String) -> void:
	if not is_instance_valid(slot) or _enchantment_hover_id != id:
		return
	var rect := slot.get_global_rect()
	var bounds := get_viewport_rect().size
	var width := _enchantment_hover.size.x
	var height := _enchantment_hover.size.y
	_enchantment_hover.global_position = Vector2(
		clampf(rect.get_center().x - width * 0.5, 12, maxf(12, bounds.x - width - 12)),
		clampf(rect.position.y - rect.size.y * (hand_hover_multiplier - 1.0) - height - 16, 12, maxf(12, bounds.y - height - 12)))


func _card_display_name(instance_id: String) -> String:
	var card := _find_card(_selected_cards, instance_id)
	if card.is_empty():
		card = _find_card(_display_cards, instance_id)
	if card.is_empty():
		card = _find_card(_battle.play_zone, instance_id)
	if card.is_empty():
		return instance_id
	var data := _card_data(String(card.get("card_id", "")))
	return TextCatalog.display_name("cards", String(card.get("card_id", "")), data.card_name if data != null else String(card.get("card_id", instance_id)))


func _used_slots() -> int:
	var result := 0
	for zone: Array in [_selected_cards, _battle.play_zone]:
		for card: Dictionary in zone:
			if not bool(card.get("slot_empty", false)) and bool(card.get("occupies_slot", true)):
				result += 1
	return result


func _on_pile_choice_requested(count: int, candidates: Array[Dictionary]) -> void:
	_pile_selection_ids.clear()
	if _busy:
		_pending_pile_presentation = {"count": count, "candidates": candidates.duplicate(true)}
	else:
		call_deferred("_show_pile_choice", count, candidates)


func _show_pile_choice(count: int, candidates: Array[Dictionary]) -> void:
	_display_cards.assign(_battle.play_zone)
	_queue_refresh()
	_open_pile("按顺序选择弃牌堆的 %d 张牌" % count, [])
	pile_title.text = "按顺序选择 %d 张牌（候选 %d 张）" % [count, candidates.size()]
	for card: Dictionary in candidates:
		var slot := _make_card_slot(card, PILE_CARD_SCALE, false)
		var button := Button.new()
		button.flat = true
		button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.pressed.connect(_choose_pile_card.bind(str(card.instance_id), button))
		button.tooltip_text = CardEnchantments.describe(card)
		slot.add_child(button)
		pile_grid.add_child(slot)


func _choose_pile_card(id: String, button: Button) -> void:
	if _pile_selection_ids.has(id):
		return
	_pile_selection_ids.append(id)
	button.disabled = true
	button.text = str(_pile_selection_ids.size())
	if _pile_selection_ids.size() == _battle.pending_pile_count():
		call_deferred("_submit_pile_selection")


func _submit_pile_selection() -> void:
	if _animating:
		return
	var chosen: Array[String] = _pile_selection_ids.duplicate()
	_pile_selection_ids.clear()
	pile_modal.visible = false
	var error := _battle.submit_pile_choice(chosen)
	if error != OK:
		hint_label.text = "弃牌堆选择失败：%d" % error
	_queue_refresh()
	_drain_resolution_events()


func _make_test_button(text: String, style: StyleBoxFlat, position: Vector2,
		handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.position = position
	button.size = Vector2(112, 32)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color(0.749, 0.682, 0.553))
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", style)
	button.add_theme_stylebox_override("pressed", style)
	button.pressed.connect(handler)
	add_child(button)
	move_child(button, pile_modal.get_index())
	return button


func _handle_menu_key(event: InputEvent) -> void:
	# 与地图界面同一套：Esc 设置 / Tab 背包 / M 地图，再按一次退出。
	if _run_menu == null or not event is InputEventKey or event.is_echo():
		return
	if pile_modal.visible:
		if event.is_action_pressed("ui_cancel"):
			_close_pile_modal()
			get_viewport().set_input_as_handled()
		return
	var open := _run_menu.is_open()
	var page := _run_menu.current_page()
	if event.is_action_pressed("ui_cancel"):
		if open:
			_run_menu.close()
		else:
			_open_run_menu(2)
	elif event.is_action_pressed("ui_focus_next"):
		if open and page == 1:
			_run_menu.close()
		else:
			_open_run_menu(1)
	elif event.is_action_pressed("menu_map"):
		if open and page == 0:
			_run_menu.close()
		else:
			_open_run_menu(0)
	else:
		return
	get_viewport().set_input_as_handled()


func _show_resolve_preview(card_id: String, card: Dictionary = {}) -> void:
	if _resolve_preview == null or _resolve_view == null:
		return
	var data := _card_data(card_id)
	if data == null:
		_resolve_preview.hide()
		return
	if _resolve_preview_card != card_id:
		_resolve_preview_card = card_id
		_resolve_view.set_card(data)
		var px := CardView.text_px_for(RESOLVE_PREVIEW_SCALE)
		_resolve_view.apply_compact_layout(RESOLVE_PREVIEW_SCALE, px.x, px.y)
	_resolve_view.set_enchantments(card)
	_resolve_preview.show()


func _update_drag_preview(at: Vector2) -> void:
	if not _play_area_rect().has_point(at):
		_resolve_preview.hide()
		return
	var above_id := _drag_card_id
	var drop := _play_drop_index(at)
	# 用实际显示行，不按新选牌数组猜索引：保留牌、空位也占显示位置。
	for index in range(mini(drop, play_cards.get_child_count()) - 1, -1, -1):
		var candidate := str(play_cards.get_child(index).get_meta("instance_id", ""))
		if candidate != _drag_card_id and not _find_selected_card(candidate).is_empty():
			above_id = candidate
			break
	var card := _find_selected_card(above_id)
	if card.is_empty():
		card = _find_hand_card(above_id)
	if not card.is_empty():
		_show_resolve_preview(str(card.get("card_id", "")), card)


func _build_battle_actions() -> void:
	_manual_discard_button = Button.new()
	CommonUiSkin.style_button(_manual_discard_button, Vector4(8, 4, 8, 4))
	_manual_discard_button.name = "ManualDiscard"
	_manual_discard_button.position = Vector2(24, 430)
	_manual_discard_button.size = Vector2(240, 48)
	_manual_discard_button.add_theme_font_size_override("font_size", 20)
	_manual_discard_button.pressed.connect(func():
		if _busy or _relics == null: return
		_on_cancel_pressed()
		var error := _relics.request_manual_discard()
		if error != OK: hint_label.text = "本回合没有可用的手动弃牌机会。"
		_queue_refresh(), CONNECT_DEFERRED)
	add_child(_manual_discard_button)
	_refresh_battle_actions()


func _chosen_enemy_id() -> String:
	if _battle == null: return ""
	for enemy: Dictionary in _battle.enemies:
		if int(enemy.health) > 0 and bool(enemy.get("taunt", false)): return str(enemy.enemy_id)
	for enemy: Dictionary in _battle.enemies:
		if int(enemy.health) > 0 and str(enemy.enemy_id) == _target_enemy_id: return _target_enemy_id
	for enemy: Dictionary in _battle.enemies:
		if int(enemy.health) > 0: return str(enemy.enemy_id)
	return str(_battle.enemies[0].enemy_id) if not _battle.enemies.is_empty() else ""


## 底部动作栏只剩手动弃牌按钮。切换目标改为直接点战场上的敌人；用药水改为点击背包里的
## 药水原地弹选项，两者都不再占用这里的按钮位。
func _refresh_battle_actions() -> void:
	if _battle == null or not is_instance_valid(_manual_discard_button): return
	_manual_discard_button.text = "弃牌机会 %d" % [_relics.manual_discard_count() if _relics != null else 0]
	_manual_discard_button.disabled = _busy or _relics == null or _relics.manual_discard_count() <= 0


## 把这一局的药水注进战斗快照：规则侧只认 battle.player["potions"]，没有就等于点了没反应。
## 生产路径由 EncounterFlow 开局前注入，这里兜住战斗测试场景。
func _sync_battle_potions() -> void:
	if _battle == null:
		return
	var run := _test_run if _test_run != null else SaveGateway.current_run()
	if run == null:
		return
	_battle.player["potions"] = run.items.filter(
		func(value: Variant) -> bool: return value is Dictionary and value.get("kind") == "potion"
	).duplicate(true)


func _use_potion(item_id: String) -> void:
	if _busy or not _battle.active or _battle.phase != BattleStateMachine.Phase.PLAYER_ACTION: return
	_on_cancel_pressed()
	_battle.rules.submit("potion.use", {"item_id": item_id})
	_queue_refresh()
	SaveGateway.save_current()


func _on_battle_choice_requested(mode: String, count: int, candidates: Array) -> void:
	if _busy:
		_pending_battle_presentation = {"mode": mode, "count": count, "candidates": candidates.duplicate(true)}
	else:
		_show_battle_choice(mode, count, candidates)


func _show_battle_choice(mode: String, _count: int, candidates: Array) -> void:
	if is_instance_valid(_battle_choice_layer): _battle_choice_layer.queue_free()
	_battle_choice_layer = CanvasLayer.new()
	_battle_choice_layer.layer = 120
	add_child(_battle_choice_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_battle_choice_layer.add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.8)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(shade)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel", Vector4(24, 20, 24, 20)))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -520; panel.offset_right = 520; panel.offset_top = -330; panel.offset_bottom = 330
	root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	var label := Label.new()
	label.text = {"discard": "选择一张牌弃置（不会补抽）", "nullify": "选择一张牌无效化：本场战斗失去全部效果", "copy": "选择一张手牌复制"}.get(mode, "选择卡牌")
	if mode.begins_with("enchantment_"):
		label.text = "附魔：可弃置一张手牌，本次%s +50%%；也可跳过" % ("伤害" if mode == "enchantment_20" else "格挡")
	label.add_theme_font_size_override("font_size", 26)
	column.add_child(label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for card: Dictionary in candidates:
		var data := _card_data(str(card.card_id))
		var button := Button.new()
		CommonUiSkin.style_button(button)
		button.text = "%s · %s" % [data.card_name if data != null else str(card.card_id), data.description if data != null else "暂无"]
		if card.has("choice_text"): button.text = str(card.choice_text)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.custom_minimum_size.y = 60
		button.add_theme_font_size_override("font_size", 21)
		button.pressed.connect(_submit_battle_choice.bind(str(card.instance_id)), CONNECT_DEFERRED)
		list.add_child(button)


func _submit_battle_choice(id: String) -> void:
	if _animating:
		return
	var old := _battle_choice_layer
	_battle_choice_layer = null
	var ids: Array[String] = [id]
	var error := _battle.submit_battle_choice(ids)
	if error != OK:
		_battle_choice_layer = old
		hint_label.text = "选择失败：%d" % error
		return
	if is_instance_valid(old): old.queue_free()
	if _busy: _drain_resolution_events()
	_queue_refresh()

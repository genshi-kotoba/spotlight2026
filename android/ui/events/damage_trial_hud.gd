extends Control
## 独立的石碑计分面板，不改动战斗布局资产，也不接管任何战斗输入。
const Stone := preload("res://systems/events/damage_trial_rules.gd")
const PANEL_RECT := Rect2(24, 350, 380, 276)
const GOLD := Color(0.91, 0.706, 0.333)
const MUTED := Color("aaa395")

var _battle: BattleStateMachine
var _total: Label
var _progress: Label
var _reward: Label
var _tiers: Array[Label] = []
var _signature := ""
var _built := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 25
	CatalogUi.install_theme(self)
	var panel := PanelContainer.new()
	panel.name = "DamageTrialPanel"
	panel.position = PANEL_RECT.position
	panel.size = PANEL_RECT.size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("small", Vector4(20, 14, 20, 14)))
	add_child(panel)
	var body := VBoxContainer.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", 5)
	panel.add_child(body)
	body.add_child(CatalogUi.label("伤害石碑 · 三回合试炼", 22))
	_total = CatalogUi.label("累计伤害 0", 28)
	_total.add_theme_color_override("font_color", GOLD)
	body.add_child(_total)
	_progress = CatalogUi.label("第 1 / 3 回合", 18)
	body.add_child(_progress)
	for index in 4:
		var row := CatalogUi.label("", 18)
		_tiers.append(row)
		body.add_child(row)
	_reward = CatalogUi.label("仅领取最高达标档", 17)
	_reward.add_theme_color_override("font_color", MUTED)
	body.add_child(_reward)
	_built = true
	_refresh()


func bind_battle(battle: BattleStateMachine) -> void:
	_battle = battle
	_signature = ""
	set_process(true)
	if _built: _refresh()


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	if not _built: return
	if not is_instance_valid(_battle) or not _battle.is_damage_trial():
		hide()
		set_process(false)
		return
	show()
	var context: Dictionary = _battle.player.event_combat
	var total := int(context.get("total_damage", 0))
	var floor_index := int(context.get("floor", 1))
	var completed := clampi(int(context.get("completed_turns", 0)), 0, Stone.TURN_LIMIT)
	var finished := bool(context.get("finished", false))
	var pending := bool(context.get("finish_pending", false))
	var signature := str([total, floor_index, completed, finished, pending, _battle.turn_number])
	if signature == _signature: return
	_signature = signature
	_total.text = "累计伤害 %d" % total
	if finished:
		_progress.text = "已完成 3 / 3 回合 · 试炼结束"
	elif pending:
		_progress.text = "第 3 / 3 回合 · 等待回合末结算"
	else:
		_progress.text = "第 %d / 3 回合 · 已完成 %d / 3" % [clampi(_battle.turn_number, 1, Stone.TURN_LIMIT), completed]
	var limits := Stone.thresholds(floor_index)
	var tier := Stone.tier_for(total, floor_index)
	for index in _tiers.size():
		_tiers[index].text = "%s ≥ %d  ·  %s" % ["▶" if index == tier else "　", limits[index], Stone.REWARD_NAMES[index]]
		_tiers[index].add_theme_color_override("font_color", GOLD if index == tier else MUTED)
	_reward.text = "仅最高达标档：%s" % (Stone.REWARD_NAMES[tier] if tier >= 0 else "未达底档，无奖励")

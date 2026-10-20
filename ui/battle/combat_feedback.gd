class_name CombatFeedback
extends Node

## 战斗表现层：飘字、命中闪红、立绘震动、VFX-001 序列帧。
##
## 只由战斗事件驱动（受伤 / 治疗 / 格挡变化），不比较快照差值。快照记录的是
## 「某一刻的数值」，两个不同来源的快照相减会把「回到满编」误判成治疗，
## 于是同一张牌结算完怪物会闪一次回血特效。

const VfxScript := preload("res://ui/battle/vfx_playback.gd")

const SIDE_PLAYER := &"player"

## 同一侧两次特效的最小间隔，避免连锁结算时叠成一片。
const VFX_INTERVAL := 0.12
const FLOAT_OUTLINE := 6

## 伤害飘字分三档：实际掉血越重视觉越重，字号、颜色、上浮与时长一起变。
const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const LIGHT_MAX := 9
const HEAVY_MIN := 50
const FLOAT_TIERS: Array[Dictionary] = [
	{"font": 30, "color": Color(0.90, 0.72, 0.62), "rise": 40.0, "time": 0.70, "pop": 0.0},
	{"font": 42, "color": Color(1.00, 0.50, 0.42), "rise": 52.0, "time": 0.85, "pop": 1.15},
	{"font": 58, "color": Color(1.00, 0.32, 0.26), "rise": 64.0, "time": 1.00, "pop": 1.30},
]
## 治疗与格挡沿用原配色，字号固定，不做过冲弹跳。
const HEAL_TIER := {"font": 34, "color": Color(0.56, 0.95, 0.62), "rise": 56.0, "time": 0.90, "pop": 0.0}
const BLOCK_TIER := {"font": 30, "color": Color(0.62, 0.84, 1.0), "rise": 48.0, "time": 0.80, "pop": 0.0}

## 特效落点与尺寸：玩家受伤打在场景角色身上，格挡/治疗打在 HUD 一侧。
const VFX_ATTACK := {
	SIDE_PLAYER: {"at": Vector2(205.0, 610.0), "size": Vector2(130.0, 97.0)},
	&"enemy": {"at": Vector2(998.0, 470.0), "size": Vector2(300.0, 225.0)},
}
const VFX_BLOCK := {
	SIDE_PLAYER: {"at": Vector2(120.0, 120.0), "size": Vector2(110.0, 83.0)},
	&"enemy": {"at": Vector2(998.0, 470.0), "size": Vector2(140.0, 105.0)},
}
const VFX_HEAL := {
	SIDE_PLAYER: {"at": Vector2(120.0, 120.0), "size": Vector2(91.0, 68.0)},
	&"enemy": {"at": Vector2(998.0, 470.0), "size": Vector2(210.0, 157.0)},
}

var host: Control
var player_portrait: Control
var player_float_anchor := Vector2(205.0, 610.0)
## 敌方目标由宿主按实体 id 反查：多敌人时每个敌人的立绘与飘字落点都不同，
## 所以这里不缓存某一个敌人，只留一个查询函数。
var enemy_view_resolver := Callable()

var _last_block: Dictionary = {}
var _last_vfx_ms: Dictionary = {}
var _flash_tweens: Dictionary = {}
## 本张牌已经播出的最长一次反馈时长（飘字寿命），结算收尾按它走，不再拍一个常数。
## 牌开始结算时由 begin_card() 清零，所以上一张的重击不会拖慢下一张。
var _card_animation := 0.0


func setup(p_host: Control, p_player_portrait: Control,
		p_player_anchor: Vector2, p_enemy_view: Callable) -> void:
	host = p_host
	player_portrait = p_player_portrait
	player_float_anchor = p_player_anchor
	enemy_view_resolver = p_enemy_view
	_last_block = {}
	_last_vfx_ms = {}


## 掉血分档的唯一出处，顿帧与震屏的档位判定也用它，避免两处阈值各写一份。
static func tier_of(lost: int) -> int:
	if lost <= LIGHT_MAX:
		return TIER_LIGHT
	if lost < HEAVY_MIN:
		return TIER_MEDIUM
	return TIER_HEAVY


## 一张牌开始结算时调用，把上一张留下的动画时长清掉。
func begin_card() -> void:
	_card_animation = 0.0


## 本张牌到目前为止最长的一次反馈时长。没有真实反馈的牌返回 0，收尾等待就能按最短档走。
func card_animation_time() -> float:
	return _card_animation


func on_damaged(side: StringName, damage: int, blocked: int, entity_id := "") -> void:
	var lost := maxi(damage - blocked, 0)
	if lost <= 0:
		return
	_flash(side, entity_id)
	# 立绘抖动已交给整幕统一震屏，这里不再单独摇。
	_float(_anchor(side, entity_id), "-%d" % lost, FLOAT_TIERS[tier_of(lost)])
	_vfx(side, VfxPlayback.Kind.ATTACK, VFX_ATTACK, entity_id)


func on_healed(side: StringName, amount: int, entity_id := "") -> void:
	if amount <= 0:
		return
	_float(_anchor(side, entity_id), "+%d" % amount, HEAL_TIER)
	_vfx(side, VfxPlayback.Kind.HEAL, VFX_HEAL, entity_id)


func on_block_changed(side: StringName, block: int, entity_id := "") -> void:
	var key := _side_key(side, entity_id)
	var previous := int(_last_block.get(key, 0))
	_last_block[key] = block
	var gain := block - previous
	if gain <= 0:
		# 掉格挡要么是被打掉（受伤事件已经播过），要么是回合清空，不需要提示。
		return
	_float(_anchor(side, entity_id), "+%d 格挡" % gain, BLOCK_TIER)
	_vfx(side, VfxPlayback.Kind.BLOCK, VFX_BLOCK, entity_id)


## 格挡量的差分要按实体分别记账，多敌人时才不会把 A 的增减算到 B 头上。
func _side_key(side: StringName, entity_id: String) -> String:
	return str(side) if entity_id.is_empty() else "%s/%s" % [side, entity_id]


func _anchor(side: StringName, entity_id: String) -> Vector2:
	if side == SIDE_PLAYER:
		return player_float_anchor
	var view := _enemy_view(entity_id)
	return view.get("float_anchor", view.get("center", Vector2(998.0, 330.0))) as Vector2


## 多敌人时飘字挑在血条下方一点，避免和名字、意图角标抢同一块位置。
func _enemy_view(entity_id: String) -> Dictionary:
	if not enemy_view_resolver.is_valid():
		return {}
	var view: Variant = enemy_view_resolver.call(entity_id)
	return view if view is Dictionary else {}


func _flash(side: StringName, entity_id: String) -> void:
	var target: Control = player_portrait if side == SIDE_PLAYER else _enemy_view(entity_id).get("portrait", null)
	if target == null or not is_instance_valid(target):
		return
	var key := _side_key(side, entity_id)
	var previous: Tween = _flash_tweens.get(key)
	if previous != null and previous.is_valid():
		previous.kill()
	var flash := target.create_tween()
	_flash_tweens[key] = flash
	flash.tween_property(target, "modulate", Color(1.0, 0.42, 0.42, 1.0), 0.07)
	flash.tween_method(func(weight: float):
		target.modulate = Color(1.0, 0.42, 0.42, 1.0).lerp(target.get_meta("base_tint", Color.WHITE), weight), 0.0, 1.0, 0.24)


func _vfx(side: StringName, kind: int, table: Dictionary, entity_id: String) -> void:
	if host == null:
		return
	var key := _side_key(side, entity_id)
	var now := Time.get_ticks_msec()
	if now - int(_last_vfx_ms.get(key, -10000)) < int(VFX_INTERVAL * 1000.0):
		return
	_last_vfx_ms[key] = now
	var config: Dictionary = table.get(side, table[&"enemy"])
	var at: Vector2 = config["at"]
	if side != SIDE_PLAYER:
		# 特效落点跟着这一格敌人走，不再固定写在屏幕右侧。play() 的落点是相对 host
		# 的局部坐标，所以这里统一按局部坐标给，不再另外写 global_position。
		var view := _enemy_view(entity_id)
		if view.is_empty():
			return
		at = _anchor(side, entity_id) + Vector2(0.0, 140.0)
	var vfx: Sprite2D = VfxScript.new()
	host.add_child(vfx)
	vfx.play(kind, at, config["size"])
	# 特效只是手感提示，压一点不透明度，别比立绘还抢眼。
	vfx.modulate.a = 0.85


func _float(anchor: Vector2, text: String, tier: Dictionary) -> void:
	if host == null:
		return
	# 飘字寿命就是这次反馈的可见时长，取最长的一次作为本张牌的收尾依据。
	_card_animation = maxf(_card_animation, float(tier["time"]))
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", int(tier["font"]))
	label.add_theme_color_override("font_color", tier["color"])
	label.add_theme_color_override("font_outline_color", Color(0.06, 0.04, 0.03, 0.92))
	label.add_theme_constant_override("outline_size", FLOAT_OUTLINE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = anchor - Vector2(75.0, 26.0)
	label.size = Vector2(150.0, 54.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 60
	host.add_child(label)
	label.pivot_offset = label.size * 0.5
	var tween := label.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var pop := float(tier["pop"])
	if pop > 1.0:
		# 大伤害先过冲再落回，和轻伤害的纯上浮明显分开。
		label.scale = Vector2(0.72, 0.72)
		tween.tween_property(label, "scale", Vector2(pop, pop), 0.11)
		tween.tween_property(label, "scale", Vector2.ONE, 0.09)
	tween.tween_property(label, "position:y", label.position.y - float(tier["rise"]), float(tier["time"]))
	tween.parallel().tween_property(label, "modulate:a", 0.0, float(tier["time"]) * 0.6).set_delay(float(tier["time"]) * 0.4)
	tween.chain().tween_callback(label.queue_free)

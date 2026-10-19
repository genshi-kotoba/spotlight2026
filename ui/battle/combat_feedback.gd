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
const FLOAT_FONT_SIZE := 38
const FLOAT_OUTLINE := 6

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
var enemy_portrait: Control
var player_float_anchor := Vector2(205.0, 610.0)
var enemy_float_anchor := Vector2(998.0, 330.0)
var enemy_visual_provider: Callable

var _last_block: Dictionary = {}
var _last_vfx_ms: Dictionary = {}
var _portrait_homes: Dictionary = {}
var _shake_tweens: Dictionary = {}
var _flash_tweens: Dictionary = {}


func setup(p_host: Control, p_player_portrait: Control, p_enemy_portrait: Control,
		p_player_anchor: Vector2, p_enemy_anchor: Vector2) -> void:
	host = p_host
	player_portrait = p_player_portrait
	enemy_portrait = p_enemy_portrait
	player_float_anchor = p_player_anchor
	enemy_float_anchor = p_enemy_anchor
	_last_block = {SIDE_PLAYER: 0, &"enemy": 0}
	_last_vfx_ms = {}
	_portrait_homes = {SIDE_PLAYER: player_portrait.position, &"enemy": enemy_portrait.position}


func on_damaged(side: StringName, damage: int, blocked: int, entity_id: String = "") -> void:
	var lost := maxi(damage - blocked, 0)
	if lost <= 0:
		return
	_flash(side, entity_id)
	_shake(side, entity_id)
	_float(_anchor(side, entity_id), "-%d" % lost, Color(1.0, 0.44, 0.38))
	_vfx(side, VfxPlayback.Kind.ATTACK, VFX_ATTACK, entity_id)


func on_healed(side: StringName, amount: int, entity_id: String = "") -> void:
	if amount <= 0:
		return
	_float(_anchor(side, entity_id), "+%d" % amount, Color(0.56, 0.95, 0.62))
	_vfx(side, VfxPlayback.Kind.HEAL, VFX_HEAL, entity_id)


func on_block_changed(side: StringName, block: int, entity_id: String = "") -> void:
	var key := _entity_key(side, entity_id)
	var previous := int(_last_block.get(key, 0))
	_last_block[key] = block
	var gain := block - previous
	if gain <= 0:
		# 掉格挡要么是被打掉（受伤事件已经播过），要么是回合清空，不需要提示。
		return
	_float(_anchor(side, entity_id), "+%d 格挡" % gain, Color(0.62, 0.84, 1.0))
	_vfx(side, VfxPlayback.Kind.BLOCK, VFX_BLOCK, entity_id)


func _entity_key(side: StringName, entity_id: String) -> String:
	return str(side) if side == SIDE_PLAYER or entity_id.is_empty() else "enemy:" + entity_id


func _enemy_visual(entity_id: String) -> Dictionary:
	return enemy_visual_provider.call(entity_id) if enemy_visual_provider.is_valid() else {}


func _anchor(side: StringName, entity_id: String = "") -> Vector2:
	if side != SIDE_PLAYER:
		var visual := _enemy_visual(entity_id)
		if not visual.is_empty(): return visual.anchor
	return player_float_anchor if side == SIDE_PLAYER else enemy_float_anchor


func _portrait(side: StringName, entity_id: String) -> Control:
	if side == SIDE_PLAYER: return player_portrait
	return _enemy_visual(entity_id).get("portrait", enemy_portrait)


func _flash(side: StringName, entity_id: String = "") -> void:
	var target := _portrait(side, entity_id)
	if target == null or not is_instance_valid(target):
		return
	var key := _entity_key(side, entity_id)
	var previous: Tween = _flash_tweens.get(key)
	if previous != null and previous.is_valid():
		previous.kill()
	var flash := target.create_tween()
	_flash_tweens[key] = flash
	flash.tween_property(target, "modulate", Color(1.0, 0.42, 0.42, 1.0), 0.07)
	# 阶段转换可能在闪红途中从死亡恢复，结束色必须读取当前状态。
	flash.tween_method(func(weight: float):
		target.modulate = Color(1.0, 0.42, 0.42, 1.0).lerp(target.get_meta("base_tint", Color.WHITE), weight), 0.0, 1.0, 0.24)


func _shake(side: StringName, entity_id: String = "") -> void:
	var portrait := _portrait(side, entity_id)
	if not is_instance_valid(portrait):
		return
	var key := _entity_key(side, entity_id)
	var previous: Tween = _shake_tweens.get(key)
	if previous != null and previous.is_valid():
		previous.kill()
	var home: Vector2 = portrait.get_meta("feedback_home", _portrait_homes.get(side, portrait.position))
	var tween := portrait.create_tween()
	_shake_tweens[key] = tween
	tween.set_trans(Tween.TRANS_SINE)
	var start := portrait.position.x - home.x
	for offset: float in [7.0, -6.0, 4.5, -3.0, 0.0]:
		tween.tween_method(func(value: float):
			portrait.position = Vector2(portrait.get_meta("feedback_home", home)) + Vector2(value, 0), start, offset, 0.055)
		start = offset


func _vfx(side: StringName, kind: int, table: Dictionary, entity_id: String = "") -> void:
	if host == null:
		return
	var now := Time.get_ticks_msec()
	var key := _entity_key(side, entity_id)
	if now - int(_last_vfx_ms.get(key, -10000)) < int(VFX_INTERVAL * 1000.0):
		return
	_last_vfx_ms[key] = now
	var config: Dictionary = table.get(side, table[&"enemy"])
	if side != SIDE_PLAYER:
		var visual := _enemy_visual(entity_id)
		if not visual.is_empty():
			config = {"at": visual.at, "size": config.size * maxf(0.45, float(visual.scale))}
	var vfx: Sprite2D = VfxScript.new()
	host.add_child(vfx)
	vfx.play(kind, config["at"], config["size"])
	# 特效只是手感提示，压一点不透明度，别比立绘还抢眼。
	vfx.modulate.a = 0.85


func _float(anchor: Vector2, text: String, color: Color) -> void:
	if host == null:
		return
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", FLOAT_FONT_SIZE)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.06, 0.04, 0.03, 0.92))
	label.add_theme_constant_override("outline_size", FLOAT_OUTLINE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = anchor - Vector2(75.0, 26.0)
	label.size = Vector2(150.0, 54.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 60
	host.add_child(label)
	var tween := label.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "position:y", label.position.y - 56.0, 0.9)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.55).set_delay(0.35)
	tween.chain().tween_callback(label.queue_free)

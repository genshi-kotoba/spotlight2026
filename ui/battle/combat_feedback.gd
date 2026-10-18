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

var _last_block: Dictionary = {}
var _last_vfx_ms: Dictionary = {}


func setup(p_host: Control, p_player_portrait: Control, p_enemy_portrait: Control,
		p_player_anchor: Vector2, p_enemy_anchor: Vector2) -> void:
	host = p_host
	player_portrait = p_player_portrait
	enemy_portrait = p_enemy_portrait
	player_float_anchor = p_player_anchor
	enemy_float_anchor = p_enemy_anchor
	_last_block = {SIDE_PLAYER: 0, &"enemy": 0}
	_last_vfx_ms = {}


func on_damaged(side: StringName, damage: int, blocked: int) -> void:
	var lost := maxi(damage - blocked, 0)
	if lost <= 0:
		return
	_flash(side)
	_shake(side)
	_float(_anchor(side), "-%d" % lost, Color(1.0, 0.44, 0.38))
	_vfx(side, VfxPlayback.Kind.ATTACK, VFX_ATTACK)


func on_healed(side: StringName, amount: int) -> void:
	if amount <= 0:
		return
	_float(_anchor(side), "+%d" % amount, Color(0.56, 0.95, 0.62))
	_vfx(side, VfxPlayback.Kind.HEAL, VFX_HEAL)


func on_block_changed(side: StringName, block: int) -> void:
	var previous := int(_last_block.get(side, 0))
	_last_block[side] = block
	var gain := block - previous
	if gain <= 0:
		# 掉格挡要么是被打掉（受伤事件已经播过），要么是回合清空，不需要提示。
		return
	_float(_anchor(side), "+%d 格挡" % gain, Color(0.62, 0.84, 1.0))
	_vfx(side, VfxPlayback.Kind.BLOCK, VFX_BLOCK)


func _anchor(side: StringName) -> Vector2:
	return player_float_anchor if side == SIDE_PLAYER else enemy_float_anchor


func _flash(side: StringName) -> void:
	var target: Control = player_portrait if side == SIDE_PLAYER else enemy_portrait
	if target == null or not is_instance_valid(target):
		return
	var flash := target.create_tween()
	flash.tween_property(target, "modulate", Color(1.0, 0.42, 0.42, 1.0), 0.07)
	flash.tween_property(target, "modulate", Color.WHITE, 0.24)
	# 只震受伤者自己的立绘，不动整幕，避免画面边缘露出黑边。
	var origin := target.position
	var shake := target.create_tween()
	for offset in [6.0, -5.0, 4.0, -2.0]:
		shake.tween_property(target, "position:x", origin.x + offset, 0.045)
	shake.tween_property(target, "position:x", origin.x, 0.07)


func _vfx(side: StringName, kind: int, table: Dictionary) -> void:
	if host == null:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_vfx_ms.get(side, -10000)) < int(VFX_INTERVAL * 1000.0):
		return
	_last_vfx_ms[side] = now
	var config: Dictionary = table.get(side, table[&"enemy"])
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


func _shake(side: StringName) -> void:
	# 只有真掉血才抖；格挡吃满时 on_damaged 已经提前返回，不会走到这里。
	var portrait: Control = _portrait(side)
	if portrait == null:
		return
	var home := portrait.position
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	for offset: float in [7.0, -6.0, 4.5, -3.0, 0.0]:
		tween.tween_property(portrait, "position", home + Vector2(offset, 0.0), 0.055)


func _portrait(side: StringName) -> Control:
	return player_portrait if side == &"player" else enemy_portrait

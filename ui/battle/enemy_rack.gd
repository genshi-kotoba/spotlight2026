class_name EnemyRack
extends Control

## 战场上所有敌方的横向排布：按数量等分敌人区，一格一个 EnemySlot。
##
## 只建槽、摆位、把选中转成信号；每个槽里显示什么由宿主填。
## 槽位数量变化时才重建，数量不变时原地更新，避免注册到别处的目标被反复替换。
##
## 目标指示在这层统一管：光晕由槽自己画，纯悬停反馈，不悬停就灭；箭头全战场只有一个，
## 悬停时指向被悬停那格，没悬停时回到当前目标，用来标出「打谁」。
## 用一个共享箭头而不是每槽一个，是因为「箭头移过去」本身就是要看的那一下。

signal slot_selected(enemy_id: String)

const SLOT_SCRIPT := preload("res://ui/battle/enemy_slot.gd")
const GAP := 12.0
const SLOT_HEIGHT := 880.0

## 资产表 UI-017「目标选中」，原图 483×443，按原宽高比缩到固定宽度。
const ARROW_PATH := "res://assets/ui/UI-017/UI-017.png"
const ARROW_WIDTH := 72.0
const ARROW_ASPECT := 483.0 / 443.0
## 箭头落点：以立绘右上角为原点，往左下压很多，落在敌人右上身位置。
## 觉得还要更左、更下就只改这两个数。
const ARROW_OFFSET := Vector2(-92.0, 46.0)
## 箭头在敌人之间飘过去的速度，越大越快；用指数插值，不是瞬移。
const ARROW_FOLLOW := 22.0
## 静置浮动：沿「左下 → 右上」方向来回，不是上下。幅度与频率照旧可调。
const ARROW_BOB_PIXELS := 7.0
const ARROW_BOB_SPEED := 4.4
const ARROW_BOB_DIRECTION := Vector2(1.0, -1.0)

var slots: Array[EnemySlot] = []

## 敌人区矩形：与作者原版单敌人排布一致，1 个敌人时槽宽正好等于原血条框宽。
var zone := Rect2(530.0, 78.0, 959.5, SLOT_HEIGHT)

var _arrow: TextureRect
var _arrow_tween: Tween
var _arrow_visible := false
var _arrow_base := Vector2.ZERO
var _arrow_time := 0.0
var _target_id := ""


func _ready() -> void:
	_build_arrow()


func refresh(enemies: Array, target_id: String) -> void:
	_sync_slot_count(enemies.size())
	if slots.is_empty():
		return
	var width := (zone.size.x - GAP * float(slots.size() - 1)) / float(slots.size())
	var ids: Array[String] = []
	for enemy: Dictionary in enemies:
		ids.append(str(enemy.get("enemy_id", "")))
	# 宿主给的目标可能还没落到任何一格上（例如目标刚被击杀），退到第一格。
	if not ids.has(target_id) and not ids.is_empty():
		target_id = ids[0]
	_target_id = target_id
	for index in slots.size():
		var slot := slots[index]
		slot.position = Vector2(zone.position.x + float(index) * (width + GAP), zone.position.y)
		slot.layout_for(width, SLOT_HEIGHT)
		slot.enemy_id = ids[index]


func slot_for(enemy_id: String) -> EnemySlot:
	for slot: EnemySlot in slots:
		if slot.enemy_id == enemy_id:
			return slot
	return null


## 箭头悬停在哪个敌人上就在哪个敌人身上；没悬停时回到当前目标，标出「打谁」。
## 光晕是纯悬停反馈，只在这层算出来交给格子显示，确认目标后不留光晕。
func _process(delta: float) -> void:
	_arrow_time += delta
	var hovered := _hovered_slot()
	for slot: EnemySlot in slots:
		slot.set_hovered(slot == hovered)
	_aim_arrow(hovered if hovered != null else slot_for(_target_id))


## 悬停范围与点击范围一致：只认立绘上部，下面留给手牌与出牌区。
func _hovered_slot() -> EnemySlot:
	var mouse := get_local_mouse_position()
	for slot: EnemySlot in slots:
		var local := mouse - slot.position
		if local.x < 0.0 or local.x > slot.size.x:
			continue
		if local.y < 0.0 or local.y > slot.click_height():
			continue
		return slot
	return null


## 把箭头指向某一格；slot 为空表示这一帧该收起（没有目标、也没有悬停）。
func _aim_arrow(slot: EnemySlot) -> void:
	if slot == null:
		_hide_arrow()
		return
	var target := _arrow_point(slot)
	if _arrow_visible:
		_arrow_base = _arrow_base.lerp(target, 1.0 - exp(-ARROW_FOLLOW * get_process_delta_time()))
	else:
		_arrow_base = target
	_show_arrow()
	var bob := ARROW_BOB_DIRECTION.normalized() * sin(_arrow_time * ARROW_BOB_SPEED) * ARROW_BOB_PIXELS
	_arrow.position = _arrow_base + bob


func _arrow_point(slot: EnemySlot) -> Vector2:
	return slot.position + slot.arrow_corner() + ARROW_OFFSET


## 出现时从略小、透明弹到原大，落点是本帧算好的位置，所以不会有位移的突兀。
func _show_arrow() -> void:
	if _arrow_visible:
		return
	_arrow_visible = true
	_arrow.visible = true
	_arrow.scale = Vector2(0.62, 0.62)
	_arrow.modulate.a = 0.0
	_restart_arrow_tween()
	_arrow_tween.set_parallel(true)
	_arrow_tween.tween_property(_arrow, "scale", Vector2.ONE, 0.24)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_arrow_tween.tween_property(_arrow, "modulate:a", 1.0, 0.16)


## 收起时缩小淡出，腾出画面只留敌人背后的光晕。
func _hide_arrow() -> void:
	if not _arrow_visible:
		return
	_arrow_visible = false
	_restart_arrow_tween()
	_arrow_tween.set_parallel(true)
	_arrow_tween.tween_property(_arrow, "modulate:a", 0.0, 0.22)
	_arrow_tween.tween_property(_arrow, "scale", Vector2(0.78, 0.78), 0.22)
	_arrow_tween.chain().tween_callback(func() -> void: _arrow.visible = false)


## 出现与收起共用一条 tween：状态切换时先把上一条杀掉，免得两条同时改 scale。
func _restart_arrow_tween() -> void:
	if _arrow_tween != null and _arrow_tween.is_valid():
		_arrow_tween.kill()
	_arrow_tween = create_tween()


func _build_arrow() -> void:
	_arrow = TextureRect.new()
	_arrow.name = "TargetArrow"
	_arrow.texture = load(ARROW_PATH)
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.size = Vector2(ARROW_WIDTH, ARROW_WIDTH / ARROW_ASPECT)
	_arrow.pivot_offset = _arrow.size * 0.5
	# 压在血条与意图角标之上：箭头是这一下的瞬时提示，必须一眼看见。
	_arrow.z_index = 40
	_arrow.visible = false
	add_child(_arrow)


func _sync_slot_count(count: int) -> void:
	if slots.size() == count:
		return
	for slot: EnemySlot in slots:
		slot.queue_free()
	slots.clear()
	for index in count:
		var slot: EnemySlot = SLOT_SCRIPT.new()
		slot.name = "EnemySlot%d" % index
		slot.selected.connect(_on_slot_selected)
		add_child(slot)
		slots.append(slot)


func _on_slot_selected(enemy_id: String) -> void:
	slot_selected.emit(enemy_id)

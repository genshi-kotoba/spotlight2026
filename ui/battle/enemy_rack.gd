class_name EnemyRack
extends Control

## 固定三个战位：主怪居中，两名次怪分列两侧。召唤不改变已有实体的大小和位置。
##
## 只建槽、摆位、把选中转成信号；每个槽里显示什么由宿主填。
## 槽位数量变化时才重建，数量不变时原地更新，避免注册到别处的目标被反复替换。
##
## 目标指示在这层统一管：光晕由槽自己画，纯悬停反馈，不悬停就灭；箭头全战场只有一个，
## 悬停时指向被悬停那格，没悬停时回到当前目标，用来标出「打谁」。
## 用一个共享箭头而不是每槽一个，是因为「箭头移过去」本身就是要看的那一下。

signal slot_selected(enemy_id: String)

const SLOT_SCRIPT := preload("res://ui/battle/enemy_slot.gd")
const LEADER_WIDTH := 650.0 # 普通怪保留既有尺寸。
const AUTHORED_PRIMARY_RECT := Rect2(530.0, 78.0, 959.5, 880.0)
## 道路中央的紧凑三角阵：中型侧怪靠前，轮廓可与主怪交叠，不能再站到书架或护栏上。
## 两个品级共用侧位横坐标；主怪仍各自保留原始位置。
const ORDINARY_ZONE := Rect2(544.75, 70.0, 930.0, 710.0)
const LARGE_PRIMARY_ZONE := Rect2(544.75, 78.0, 930.0, 880.0)
const COMPANION_WIDTH := 480.0
const GROUND_Y := 660.0
const COMPANION_GROUND_Y := 780.0

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

## 三个战位始终占用相同地面范围；空位不会让其他单位扩张或移位。
var zone := ORDINARY_ZONE
var _large_primary := false
var _leader_id := ""
var _slots_by_id: Dictionary = {}
var _roles: Dictionary = {}

var _arrow: TextureRect
var _arrow_tween: Tween
var _arrow_visible := false
var _arrow_base := Vector2.ZERO
var _arrow_time := 0.0
var _target_id := ""


func _ready() -> void:
	_build_arrow()


func refresh(enemies: Array, target_id: String) -> void:
	if enemies.is_empty():
		return
	var ids: Array[String] = []
	for enemy: Dictionary in enemies:
		ids.append(str(enemy.get("enemy_id", "")))
	# 重开或换战斗才重置主怪；主怪死亡时不把随从提到中间。
	if _leader_id.is_empty() or not ids.has(_leader_id):
		_clear_slots()
		_leader_id = ids[0]
	var large_primary := str(enemies[0].get("grade", "普通")) in ["BOSS", "精英"]
	var profile_changed := large_primary != _large_primary
	_large_primary = large_primary
	zone = LARGE_PRIMARY_ZONE if _large_primary else ORDINARY_ZONE
	var snapshots := {}
	for enemy: Dictionary in enemies:
		snapshots[str(enemy.get("enemy_id", ""))] = enemy
	for identity: String in _slots_by_id.keys():
		if not snapshots.has(identity):
			_remove_slot(identity)
	_roles = MonsterBattleRules.formation_slots(enemies)
	for enemy: Dictionary in enemies:
		var identity := str(enemy.get("enemy_id", ""))
		if identity.is_empty() or _slots_by_id.has(identity): continue
		if int(enemy.get("health", 0)) <= 0 and identity != _leader_id: continue
		var role := int(_roles.get(identity, -1))
		if role < 0: continue
		for occupant: String in _slots_by_id.keys():
			if int(_roles.get(occupant, -1)) == role and int(snapshots.get(occupant, {}).get("health", 0)) <= 0:
				_remove_slot(occupant)
		var slot: EnemySlot = SLOT_SCRIPT.new()
		slot.name = "EnemySlot_%d" % role
		slot.enemy_id = identity
		slot.set_presentation_layer(role == 0)
		slot.selected.connect(_on_slot_selected)
		add_child(slot)
		_slots_by_id[identity] = slot
		_roles[identity] = role
		_layout_slot(slot, role)
	if profile_changed:
		for identity: String in _slots_by_id:
			_layout_slot(_slots_by_id[identity], int(_roles[identity]))
	# 数组顺序仍与敌人记录一致，位置由固定 role 决定。
	slots.clear()
	for identity: String in ids:
		if _slots_by_id.has(identity): slots.append(_slots_by_id[identity])
	# Z不改变GUI派发顺序，主怪放到最后并按透明轮廓命中，补位也保持此顺序。
	var primary := slot_for(_leader_id)
	if primary != null: move_child(primary, get_child_count() - 1)
	_target_id = target_id if _slots_by_id.has(target_id) else ""


func slot_for(enemy_id: String) -> EnemySlot:
	return _slots_by_id.get(enemy_id)


func _layout_slot(slot: EnemySlot, role: int) -> void:
	# Boss／精英始终使用原版单体矩形，与随从数量和当前选择无关。
	if role == 0 and _large_primary:
		slot.layout_for(AUTHORED_PRIMARY_RECT.size.x, AUTHORED_PRIMARY_RECT.size.y)
		slot.position = AUTHORED_PRIMARY_RECT.position
		return
	var width := LEADER_WIDTH if role == 0 else COMPANION_WIDTH
	var x := 725.0 # 普通主怪保留既有几何；只收拢侧怪到道路上。
	if role == 1: x = zone.position.x
	elif role == 2: x = zone.end.x - width
	slot.layout_for(width, zone.size.y)
	var foot := slot.portrait.position.y + slot.portrait.size.y
	var ground := GROUND_Y if role == 0 else COMPANION_GROUND_Y
	slot.position = Vector2(x, ground - foot)
	slot.custom_minimum_size.y = foot
	slot.size.y = foot


func _remove_slot(identity: String) -> void:
	var slot: EnemySlot = _slots_by_id[identity]
	_slots_by_id.erase(identity)
	slots.erase(slot)
	remove_child(slot)
	slot.queue_free()


func _clear_slots() -> void:
	for identity: String in _slots_by_id.keys(): _remove_slot(identity)
	_leader_id = ""
	_target_id = ""


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
	var children := get_children()
	for index in range(children.size() - 1, -1, -1):
		if not children[index] is EnemySlot: continue
		var slot: EnemySlot = children[index]
		if not slot.visible or not slot.selectable: continue
		if slot._has_point(mouse - slot.position): return slot
	return null


## 把箭头指向某一格；slot 为空表示这一帧该收起（没有目标、也没有悬停）。
func _aim_arrow(slot: EnemySlot) -> void:
	if slot == null:
		_hide_arrow()
		return
	_arrow.z_index = slot.feedback_z() + 1
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
	_arrow.z_index = EnemySlot.PRIMARY_BASE_Z + EnemySlot.FEEDBACK_OFFSET_Z + 1
	_arrow.visible = false
	add_child(_arrow)


func _on_slot_selected(enemy_id: String) -> void:
	slot_selected.emit(enemy_id)

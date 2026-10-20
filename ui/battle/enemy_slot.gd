class_name EnemySlot
extends Control

## 战场上单个敌方的显示单元：立绘、名字、血条、意图、buff 行与格挡盾。
##
## 只负责摆放自己的节点、把自己这块区域的点击转成 selected 信号、显示当前目标标记；
## 数值由宿主按同一套绘制函数填入（血条算法不在第二处重写）。
##
## 布局以作者原版单敌人排布为基准宽度，宽度收窄时立绘等比缩小、字号跟着缩，
## 所以 1 个敌人时与原版逐像素一致，多个敌人时并排不重叠。

signal selected(enemy_id: String)

## 原版 EnemyHPBar 的宽度，所有内部比例都以它为基准。
const AUTHORED_WIDTH := 959.5
const BAR_HEIGHT := 88.0
## 血条底图的长宽比（959.5 : 88）。窄槽里条高按它等比缩，贴图才不会被压变形。
const BAR_ASPECT := AUTHORED_WIDTH / BAR_HEIGHT
const MIN_BAR_HEIGHT := 46.0
## 填充带在原版 88 高血条里的上下沿，以及右端斜切量。
const FILL_TOP := 30.0
const FILL_BOTTOM := 62.0
const SLANT_BASE := 21.8
## 填充带在原版血条里的左起与长度，集中成比例，供宿主换算后传给同一个绘制函数。
const FILL_LEFT_RATIO := 89.5 / AUTHORED_WIDTH
const FILL_WIDTH_RATIO := 726.5 / AUTHORED_WIDTH
const PORTRAIT_TOP := 38.0
const PORTRAIT_X0 := 0.033
const PORTRAIT_X1 := 0.942
const PORTRAIT_ASPECT := 817.0 / 872.0
## 点击区只覆盖立绘上部，下部要留给出牌区，避免挡住手牌与出牌列的输入。
const CLICK_DEPTH_SHARE := 0.70
const CLICK_DEPTH_MAX := 600.0
## 每个实体占用独立层级段：后排连同HUD/反馈都低于主怪立绘；所有敌方内容低于普通UI。
const PORTRAIT_Z := -2
const BACKGROUND_Z := -100
const BACKGROUND_DIM_Z := -90
const REAR_BASE_Z := -80
const PRIMARY_BASE_Z := -20
const FEEDBACK_OFFSET_Z := 15

static var _glow_texture: GradientTexture2D
static var _portrait_masks: Dictionary = {}

const BAR_BASE_PATH := "res://assets/ui/UI-015/超长血条底图.png"
const BAR_FRAME_PATH := "res://assets/ui/UI-015/超长-boss血条框.png"
const INTENT_TEXTURE := "res://assets/ui/UI-016/攻击.png"
const INTENT_REGION := Rect2(104, 125, 847, 863)
const INTENT_RING := "res://assets/ui/UI-016/意图角标.png"
const HEALTH_FILL_SCRIPT := preload("res://ui/battle/health_fill.gd")
const BLOCK_SHIELD_SCRIPT := preload("res://ui/battle/block_shield.gd")

## 目标指示分两层：选中时立绘背后常驻一层暖光晕；箭头不常驻，只在悬停或刚切换目标时
## 短暂出现（本体在 EnemyRack 上，全战场只有一个），亮 1 秒后收起，只留下光晕。
const GLOW_ALPHA := 0.72
## 光晕相对立绘外扩多少，罩住人物轮廓即可；太大就变成一团光，收小才像从人物背后透出来。
const GLOW_SPREAD := 0.12

const NAME_COLOR := Color(1.0, 0.768627, 0.690196)
const NUMBER_COLOR := Color(1.0, 0.878431, 0.847059)
const INTENT_COLOR := Color(1.0, 0.768627, 0.690196)

var enemy_id := ""
var selectable := true
var _snapshot_initialized := false
var _snapshot_dead := false
var _death_tween: Tween
var _intent_kind := "攻击"

var portrait: TextureRect
var name_label: Label
var number_label: Label
var intent_value: Label
var buff_row: HBoxContainer
var fill: Control
var block_marker: ColorRect
var shield: Control

var _bar: Control
var _frame: TextureRect
var _intent_badge: TextureRect
var _intent_ring: TextureRect
var _glow: TextureRect
var _portrait_height := 0.0
var _label_scale := 1.0
var _layout_width := 0.0
var _portrait_top := 0.0
var _portrait_scale := 1.0
var _foreground_primary := false
var _masked_texture: Texture2D
var _portrait_mask: BitMap


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()


func set_presentation_layer(primary: bool) -> void:
	_foreground_primary = primary
	z_index = PRIMARY_BASE_Z if primary else REAR_BASE_Z


func feedback_z() -> int:
	return z_index + FEEDBACK_OFFSET_Z


## 主怪透明区域可点到后排；其不透明身体及自身HUD优先，与实际遮挡一致。
func _has_point(point: Vector2) -> bool:
	if not selectable: return false
	var hit_left := minf(0.0, portrait.position.x) if _portrait_scale > 1.0 else 0.0
	var hit_right := maxf(size.x, portrait.position.x + portrait.size.x) if _portrait_scale > 1.0 else size.x
	var hit_top := minf(0.0, portrait.position.y) if _portrait_scale > 1.0 else 0.0
	if not Rect2(Vector2(hit_left, hit_top), Vector2(hit_right-hit_left, click_height()-hit_top)).has_point(point): return false
	if not _foreground_primary: return true
	for item: Control in [_bar, name_label, number_label, buff_row, shield, _intent_badge, _intent_ring]:
		if is_instance_valid(item) and item.visible and item.get_rect().has_point(point): return true
	if portrait.texture == null or _portrait_mask == null: return true
	var texture_size := Vector2(_portrait_mask.get_size())
	var ratio := minf(portrait.size.x / texture_size.x, portrait.size.y / texture_size.y)
	var used_size := texture_size * ratio
	var pixel := (point - portrait.position - (portrait.size - used_size) * 0.5) / ratio
	if not Rect2(Vector2.ZERO, texture_size).has_point(pixel): return false
	return _portrait_mask.get_bitv(Vector2i(pixel.floor()))


func _refresh_portrait_mask() -> void:
	if not _foreground_primary or portrait.texture == _masked_texture: return
	_masked_texture = portrait.texture
	_portrait_mask = null
	if _masked_texture == null: return
	if not _portrait_masks.has(_masked_texture):
		var image := _masked_texture.get_image()
		if image == null or image.is_empty(): return
		if image.is_compressed() and image.decompress() != OK: return
		var mask := BitMap.new()
		mask.create_from_image_alpha(image, 0.1)
		_portrait_masks[_masked_texture] = mask
	_portrait_mask = _portrait_masks[_masked_texture]


## 宿主在布完位置后调用，按自己的宽度把内部比例全部换算一遍。
## 血条是超宽贴图（959.5 : 88），窄槽里用 KEEP_ASPECT_CENTERED 画会被压矮，
## 所以条高跟着槽宽等比缩，填充带与立绘起点一起缩，三者才不会互相错位。
func layout_for(slot_width: float, slot_height: float, portrait_scale := 1.0) -> void:
	_layout_width = slot_width
	_portrait_scale = clampf(portrait_scale, 1.0, 1.6)
	custom_minimum_size = Vector2(slot_width, slot_height)
	size = custom_minimum_size
	var ratio := slot_width / AUTHORED_WIDTH
	_label_scale = clampf(ratio, 0.5, 1.0)
	var bar_height := clampf(slot_width / BAR_ASPECT, MIN_BAR_HEIGHT, BAR_HEIGHT)
	var v_scale := bar_height / BAR_HEIGHT
	_bar.size = Vector2(slot_width, bar_height)
	_bar.position = Vector2.ZERO
	fill.offset_top = FILL_TOP * v_scale
	fill.offset_bottom = FILL_BOTTOM * v_scale
	fill.set("slant", SLANT_BASE * ratio)
	block_marker.offset_top = FILL_TOP * v_scale
	block_marker.offset_bottom = FILL_BOTTOM * v_scale
	# 血条框在原版里内缩一圈（19,1 → 959.1,87），按同一比例跟着条走。
	_frame.offset_left = 19.0 * ratio
	_frame.offset_top = 1.0 * v_scale
	_frame.offset_right = 959.1 * ratio
	_frame.offset_bottom = 87.0 * v_scale
	_portrait_top = PORTRAIT_TOP * v_scale
	_layout_portrait()
	name_label.position = Vector2(slot_width * 0.125, 0.0)
	name_label.size = Vector2(slot_width * 0.834, 32.0 * _label_scale)
	number_label.position = Vector2(slot_width * 0.125, 34.0 * v_scale)
	number_label.size = Vector2(slot_width * 0.219, 28.0 * _label_scale)
	buff_row.position = Vector2(slot_width * 0.125, 78.0 * v_scale)
	buff_row.size = Vector2(slot_width * 0.782, 22.0 * _label_scale)
	_apply_fonts()
	# 意图角标在作者原版里越出血条右端；单个敌人（槽宽即原宽）时保持原位不动，
	# 只有并排多个、槽被压窄时才把它收回槽内，免得压到旁边的敌人。
	var badge_x := AUTHORED_WIDTH * 0.948 * ratio
	if slot_width < AUTHORED_WIDTH * 0.9:
		badge_x = minf(badge_x, slot_width - 111.0 - 8.0)
	_intent_badge.position = Vector2(badge_x, -26.0)
	_intent_ring.position = Vector2(badge_x + 64.0, 42.0 * v_scale)
	intent_value.position = _intent_ring.position
	intent_value.size = _intent_ring.size
	shield.position = Vector2(slot_width * 0.848, 6.0 * v_scale)



## 只缩放立绘。血条、战位和手牌输入区不随最终Boss放大。
func set_portrait_texture(value: Texture2D) -> void:
	if portrait.texture == value: return
	portrait.texture = value
	_layout_portrait()


func _layout_portrait() -> void:
	if _layout_width <= 0.0: return
	var width := _layout_width * (PORTRAIT_X1 - PORTRAIT_X0)
	var base_size := Vector2(width, width * PORTRAIT_ASPECT)
	# KEEP_ASPECT_CENTERED 的图片可能是横向大图；锚点取实际图片下沿，
	# 避免放大时连同空白画布一起把Boss抬起或压入手牌。
	var image_size := base_size
	if portrait.texture != null:
		var dimensions := portrait.texture.get_size()
		image_size = dimensions * minf(base_size.x / dimensions.x, base_size.y / dimensions.y)
	var anchor := Vector2(_layout_width * PORTRAIT_X0 + base_size.x * 0.5,
		_portrait_top + (base_size.y + image_size.y) * 0.5)
	portrait.size = base_size * _portrait_scale
	portrait.position = anchor - Vector2(portrait.size.x * 0.5,
		(portrait.size.y + image_size.y * _portrait_scale) * 0.5)
	_portrait_height = portrait.size.y
	var spread := portrait.size * GLOW_SPREAD
	_glow.position = portrait.position - spread
	_glow.size = portrait.size + spread * 2.0


## 悬停反馈：鼠标压在这格上时背后亮一层暖光晕，移开就收。
## 「打谁」由共享箭头标记，不在这格常驻显示。
func set_hovered(active: bool) -> void:
	if _glow != null:
		_glow.visible = active


## 填充带在当前槽宽下的左起与长度，宿主沿用玩家血条那套绘制函数时直接取这两个值。
func fill_left() -> float:
	return _bar.size.x * FILL_LEFT_RATIO


func fill_width() -> float:
	return _bar.size.x * FILL_WIDTH_RATIO


## 血条框按敌人品级换图（小怪 / 精英 / boss），宿主填内容时调用；空路径保持当前图。
func set_frame_path(path: String) -> void:
	if _frame == null or path.is_empty():
		return
	var texture := load(path) as Texture2D
	if texture != null:
		_frame.texture = texture


func _gui_input(event: InputEvent) -> void:
	if enemy_id.is_empty() or not selectable:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if Vector2(event.position).y > click_height():
		return
	# 点击区之外留给下面的出牌区，只有落在敌人身上才吃掉这次输入。
	accept_event()
	selected.emit(enemy_id)


## 点击与悬停的有效高度：只覆盖立绘上部，下面留给出牌区，别挡手牌输入。
func click_height() -> float:
	return minf(PORTRAIT_TOP + _portrait_height * CLICK_DEPTH_SHARE, CLICK_DEPTH_MAX)


## 立绘右上角在本槽内的坐标，共享箭头按它定位。
func arrow_corner() -> Vector2:
	if _portrait_scale > 1.0:
		return Vector2(_layout_width * PORTRAIT_X1, _portrait_top)
	return portrait.position + Vector2(portrait.size.x, 0.0)


func _apply_fonts() -> void:
	name_label.add_theme_font_size_override("font_size", maxi(int(22.0 * _label_scale), 13))
	number_label.add_theme_font_size_override("font_size", maxi(int(18.0 * _label_scale), 12))
	intent_value.add_theme_font_size_override("font_size", maxi(int(26.0 * _label_scale), 15))
	shield.set("number_px", maxi(int(24.0 * _label_scale), 14))


func _build() -> void:
	# 先加光晕再加立绘：两者同 z，先入树的先画，光晕自然落在立绘背后、血条之下。
	_glow = TextureRect.new()
	_glow.name = "TargetGlow"
	_glow.z_index = PORTRAIT_Z
	_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_glow.texture = _radial_glow()
	_glow.modulate = Color(1.0, 0.92, 0.70, GLOW_ALPHA)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.visible = false
	add_child(_glow)

	portrait = TextureRect.new()
	portrait.name = "Portrait"
	portrait.z_index = PORTRAIT_Z
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(portrait)

	_bar = Control.new()
	_bar.name = "HPBar"
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar)
	var base := TextureRect.new()
	base.name = "Base"
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	base.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	base.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	base.texture = load(BAR_BASE_PATH)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(base)
	fill = HEALTH_FILL_SCRIPT.new()
	fill.name = "Fill"
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(fill)
	block_marker = ColorRect.new()
	block_marker.name = "Block"
	block_marker.color = Color(0.352941, 0.439216, 0.54902, 1.0)
	block_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block_marker.visible = false
	_bar.add_child(block_marker)
	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.texture = load(BAR_FRAME_PATH)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(frame)
	_frame = frame

	name_label = _label(NAME_COLOR)
	name_label.name = "EnemyName"
	number_label = _label(NUMBER_COLOR)
	number_label.name = "EnemyHPNum"
	buff_row = HBoxContainer.new()
	buff_row.name = "EnemyBuffRow"
	buff_row.z_index = 12
	buff_row.add_theme_constant_override("separation", 8)
	buff_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(name_label)
	add_child(number_label)
	add_child(buff_row)

	_intent_badge = TextureRect.new()
	_intent_badge.name = "IntentBadge"
	var atlas := AtlasTexture.new()
	atlas.atlas = load(INTENT_TEXTURE)
	atlas.region = INTENT_REGION
	_intent_badge.texture = atlas
	_intent_badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_intent_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_intent_badge.size = Vector2(111.0, 113.0)
	_intent_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_intent_badge)
	_intent_ring = TextureRect.new()
	_intent_ring.name = "IntentRing"
	_intent_ring.texture = load(INTENT_RING)
	_intent_ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_intent_ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_intent_ring.size = Vector2(60.0, 60.0)
	_intent_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_intent_ring)
	intent_value = _label(INTENT_COLOR)
	intent_value.name = "IntentValue"
	intent_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	intent_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(intent_value)

	shield = BLOCK_SHIELD_SCRIPT.new()
	shield.name = "EnemyBlockShield"
	shield.z_index = 13
	shield.position = Vector2(0, 6)
	shield.size = Vector2(74.0, 82.0)
	shield.call("set", "number_px", 24)
	add_child(shield)


## 一张 256×256 的径向渐变白图当光晕底，所有槽共用同一张，不各自生成。
static func _radial_glow() -> GradientTexture2D:
	if _glow_texture == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
		gradient.colors = PackedColorArray([
			Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
		var texture := GradientTexture2D.new()
		texture.gradient = gradient
		texture.fill = GradientTexture2D.FILL_RADIAL
		texture.fill_from = Vector2(0.5, 0.5)
		texture.fill_to = Vector2(1.0, 0.5)
		texture.width = 256
		texture.height = 256
		_glow_texture = texture
	return _glow_texture


func _label(color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.add_theme_font_size_override("font_size", 20)
	return label


## 沿用同一份事件快照处理意图、嘲讽和退场，不读取规则侧的最终状态。
func show_snapshot_status(enemy: Dictionary, primary: bool, interactive: bool) -> void:
	_refresh_portrait_mask()
	var dead := int(enemy.get("health", 0)) <= 0
	selectable = interactive and not dead
	var actions: Array = enemy.get("actions", [])
	var action: Dictionary = actions[0] if not actions.is_empty() else {}
	var kind := "攻击" if action.has("damage") else ("防御" if action.has("block") else "特殊")
	if kind != _intent_kind:
		var atlas := AtlasTexture.new()
		atlas.atlas = TextCatalogService.art_texture("res://assets/ui/UI-016/%s.png" % kind)
		atlas.region = INTENT_REGION
		_intent_badge.texture = atlas
		_intent_kind = kind
	intent_value.text = str(action.damage) if action.has("damage") else (str(action.block) if action.has("block") else "—")
	_intent_badge.visible = not dead
	_intent_ring.visible = not dead
	intent_value.visible = not dead
	var tint := Color(1, 1, 1, 0.25) if dead and primary else Color.WHITE
	portrait.set_meta("base_tint", tint)
	if not _snapshot_initialized:
		portrait.modulate = tint
		visible = primary or not dead
	elif dead and not _snapshot_dead:
		_death_tween = create_tween()
		_death_tween.tween_interval(0.3)
		if primary:
			_death_tween.tween_property(portrait, "modulate", tint, 0.15)
		else:
			_death_tween.tween_property(self, "modulate:a", 0.0, 0.15)
			_death_tween.tween_callback(hide)
	elif not dead and _snapshot_dead:
		if _death_tween != null and _death_tween.is_valid(): _death_tween.kill()
		modulate.a = 1.0
		portrait.modulate = Color.WHITE
		show()
	_snapshot_initialized = true
	_snapshot_dead = dead

## 卡牌预制件（卡面模板）
##
## 给别人拖进界面用的模板，不是某一张卡或某个界面的成品。用法有三种：
##   1. 编辑器里实例化 card_view.tscn，把一份 CardData 拖到检查器的卡牌数据上，
##      卡面立刻显示这份数据，不用运行
##   2. 代码里 card.set_card(data)
##   3. 只想自己填文案时 card.set_texts(卡名, 效果, 介绍)
##
## 本脚本是 @tool，在编辑器里也运行，所以：只改已有节点的 text 与 texture，不创建
## 节点、不写文件、不碰工程设置。导出属性在 _ready 之前就会触发 setter，所有渲染
## 入口都要能安全地在节点未 ready 时返回。
##
## 几何与字号默认全部在 card_view.tscn 里用锚点加偏移摆好。小卡（手牌、出牌区、
## 卡组、牌堆）由调用方调用 apply_compact_layout()：按场景中实际的文字框折行，
## 长文案在固定卡内坐标中适度缩小；悬停缩放不会重新排版。

@tool
class_name CardView
extends Control

## 卡面文字最大规格：以 0.285 倍卡（137×233）为基准，标题 16 / 描述 14。
## 其他尺寸的卡（出牌 0.23、牌堆 0.40、大图 0.62/0.7）按同一比例缩放，
## 保证同一张卡在任何位置看起来都是「同一张卡的另一尺寸」。
## 卡面字体只在「卡内坐标」定一次：手牌、出牌区、卡组、牌堆、点开的大图都是同一张卡
## 的等比缩放，放大的时候字跟着一起变大，不重新排版。
const TYPE_BASE_SCALE := 0.285
const TYPE_TITLE_PX := 16.0
const TYPE_BODY_PX := 14.0
const LOCAL_TITLE_PX := 56
const LOCAL_BODY_PX := 49
const LOCAL_OUTLINE_PX := 3
## 留出描边和阴影的安全边距，单位为卡内像素，不受悬停缩放影响。
const TEXT_SAFETY_PADDING := Vector2(8, 8)

const COMPACT_FONT_NAMES := ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC"]

static var _compact_font: SystemFont
static var _compact_body_font: SystemFont
static var _compact_text_cache: Dictionary = {}

## 数据变化后放一次。容器可以据此编排，例如数据写入后再开始发牌动画。
signal card_data_applied(card_id: StringName)

@export_group("紧凑卡面文字")
## 最大字号仍由 LOCAL_TITLE_PX / LOCAL_BODY_PX 和调用方参数决定。
@export_range(12, 56, 1) var compact_title_min_size := 28
@export_range(12, 49, 1) var compact_body_min_size := 26
@export_group("")

## 要显示的卡牌数据。在编辑器里挂上就渲染，这是给人用的入口。
@export var 卡牌数据: CardData:
	set(value):
		卡牌数据 = value
		_render_card_data()

## 8 张底图的成套数据。留空时卡框保留场景里预设的那张。
@export var 底图集: CardFaceSet:
	set(value):
		底图集 = value
		_refresh_face()

## 底图第一栏：稀有度，决定卡头形状。枚举定义在 CardData 上。
## 挂了卡牌数据时这一栏由卡自己的数据决定，这两个导出属性只在没有数据时起作用。
@export var 稀有度: CardData.Rarity = CardData.Rarity.COMMON:
	set(value):
		稀有度 = value
		_refresh_face()

## 底图第二栏：颜色，决定卡框色调。枚举定义在 CardData 上，玩法含义未定。
@export var 颜色: CardData.FaceTint = CardData.FaceTint.GRAY:
	set(value):
		颜色 = value
		_refresh_face()

@onready var _frame: TextureRect = %卡框
@onready var _art_slot: TextureRect = %插画位
@onready var _title_label: Label = %卡名
@onready var _effect_label: Label = %效果文本
@onready var _intro_label: Label = %介绍文本

var _card_id: StringName = &""
var _csv_art_applied := false
var _compact := false
var _display_scale := 1.0
var _compact_title_px := 16
var _compact_body_px := 15
# 调用方普遍是「instantiate → set_card → apply_compact_layout → add_child」，
# 设置时节点还没进树。参数先存下来，_ready 里补一次，否则小卡会退回场景默认字号。
var _compact_pending := false
var _raw_title := ""
var _raw_effect := ""
var _raw_intro := ""
var _enchantment_symbols := ""
var _boss_saturn := false
var _texts_pending := false

## 接受具体副本而非 CardData：同名牌不会共享附魔。预 ready 调用也有效。
func set_enchantments(card: Dictionary) -> void:
	var variant_changed := _boss_saturn != bool(card.get("boss_saturn", false))
	_boss_saturn = bool(card.get("boss_saturn", false))
	_enchantment_symbols = CardEnchantments.symbols(card)
	if variant_changed and is_node_ready() and 卡牌数据 != null and not _card_id.is_empty():
		_render_card_data()
	if is_node_ready():
		%附魔符号.text = _enchantment_symbols
		%附魔符号.visible = not _enchantment_symbols.is_empty()


func _ready() -> void:
	_refresh_face()
	%附魔符号.text = _enchantment_symbols
	%附魔符号.visible = not _enchantment_symbols.is_empty()
	# CSV 展示文本统一入口；编辑器预览仍读资源，空表保留原测试卡文案。
	var catalog := get_node_or_null("/root/TextCatalog")
	if not Engine.is_editor_hint() and catalog != null:
		catalog.catalog_changed.connect(_on_catalog_changed)
	# 卡牌数据为空时不动文本，场景里手写的样张文案要留着。
	if _compact_pending:
		_compact_pending = false
		_apply_compact(_display_scale, _compact_title_px, _compact_body_px)
	elif 卡牌数据 != null:
		_render_card_data()
	elif _texts_pending:
		set_texts(_raw_title, _raw_effect, _raw_intro)
	resized.connect(_refresh_compact_text)


## 主入口：直接给三段文本。intro 为空时介绍标签自动隐藏。
func set_texts(title: String, effect: String, intro: String = "") -> void:
	_raw_title = title
	_raw_effect = effect
	_raw_intro = intro
	_texts_pending = true
	if not is_node_ready():
		return
	_texts_pending = false
	if _compact:
		_refresh_compact_text()
	else:
		_title_label.text = title
		_effect_label.text = effect
	_intro_label.text = intro
	_intro_label.visible = intro != "" and not _compact


## 小卡布局：指定卡内最大字号，长文案按场景中的实际文字框适配。
## 手牌、出牌区、卡组、牌堆都走这里；全尺寸卡面（图鉴大图）不调用。
## 返回卡内坐标字号，与展示缩放无关：同一张卡只换 scale，就是常规放大缩小。
static func text_px_for(_display_scale: float) -> Vector2i:
	return Vector2i(LOCAL_TITLE_PX, LOCAL_BODY_PX)


func apply_compact_layout(display_scale: float, title_px: int = LOCAL_TITLE_PX,
		body_px: int = LOCAL_BODY_PX) -> void:
	if display_scale <= 0.0:
		return
	_compact_pending = true
	_display_scale = display_scale
	_compact_title_px = title_px
	_compact_body_px = body_px
	if not is_node_ready():
		return
	_compact_pending = false
	_apply_compact(display_scale, title_px, body_px)


func _apply_compact(display_scale: float, title_px: int, body_px: int) -> void:
	_compact = true
	_display_scale = display_scale
	_compact_title_px = title_px
	_compact_body_px = body_px
	var title_font := _compact_typeface()
	var body_font := _compact_body_typeface()
	_title_label.add_theme_font_override("font", title_font)
	_effect_label.add_theme_font_override("font", body_font)
	_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_effect_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_title_label.add_theme_constant_override("shadow_offset_x", 1)
	_title_label.add_theme_constant_override("shadow_offset_y", 1)
	_effect_label.add_theme_constant_override("shadow_offset_x", 1)
	_effect_label.add_theme_constant_override("shadow_offset_y", 1)
	# 描边固定在卡内坐标，随整张卡同步缩放。
	_effect_label.add_theme_color_override("font_outline_color", Color(0.06, 0.05, 0.04, 0.9))
	_effect_label.add_theme_constant_override("outline_size", LOCAL_OUTLINE_PX)
	_title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_title_label.max_lines_visible = 1
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_effect_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_effect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_effect_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 效果文本框几何已写进 card_view.tscn：点开的大图和手牌共用同一份预制件。
	_intro_label.visible = false
	if 卡牌数据 != null:
		_render_card_data()
	else:
		set_texts(_raw_title, _raw_effect, _raw_intro)
	# 所有卡以同一最大字号起步，只有超出实际框的文案缩小。



func _text_box(label: Label) -> Vector2:
	# 不使用 Label.size：长文本可能已把自身最小尺寸撑大。
	return Vector2(size.x * (label.anchor_right - label.anchor_left) + label.offset_right - label.offset_left,
		size.y * (label.anchor_bottom - label.anchor_top) + label.offset_bottom - label.offset_top)


func _text_height(label: Label, font_size: int, lines: int) -> float:
	return label.get_theme_font("font").get_height(font_size) * lines \
		+ label.get_theme_constant("line_spacing") * maxi(0, lines - 1)


func _refresh_compact_text() -> void:
	if not is_node_ready() or not _compact:
		return
	var title_box := _text_box(_title_label)
	var body_box := _text_box(_effect_label)
	var title_area := (title_box - TEXT_SAFETY_PADDING).max(Vector2.ONE)
	var body_area := (body_box - TEXT_SAFETY_PADDING).max(Vector2.ONE)
	var title_font := _title_label.get_theme_font("font")
	var font := _effect_label.get_theme_font("font")
	var key := JSON.stringify([_raw_title, _raw_effect, title_area.x, title_area.y, body_area.x, body_area.y,
		_compact_title_px, _compact_body_px, compact_title_min_size, compact_body_min_size,
		title_font.get_instance_id(), font.get_instance_id(), _effect_label.get_theme_constant("line_spacing")])
	if not _compact_text_cache.has(key):
		if _compact_text_cache.size() >= 512: _compact_text_cache.clear()
		_compact_text_cache[key] = _calculate_compact_text(title_area, body_area, title_font, font)
	var layout: Dictionary = _compact_text_cache[key]
	_title_label.add_theme_font_size_override("font_size", layout.title_size)
	_title_label.text = _raw_title
	_effect_label.add_theme_font_size_override("font_size", layout.body_size)
	_effect_label.max_lines_visible = layout.max_lines
	_effect_label.text = layout.text
	# 字号与最大行数先受限；几何仍由 .tscn 的锚点决定，不在脚本中重写。


func _calculate_compact_text(title_area: Vector2, body_area: Vector2, title_font: Font, font: Font) -> Dictionary:
	var title_size := maxi(1, _compact_title_px)
	var title_floor := mini(title_size, compact_title_min_size)
	while title_size > title_floor and (title_font.get_string_size(_raw_title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, title_size).x > title_area.x \
			or _text_height(_title_label, title_size, 1) > title_area.y):
		title_size -= 1
	var effect := strip_period(_raw_effect)
	var body_size := maxi(1, _compact_body_px)
	var body_floor := mini(body_size, compact_body_min_size)
	var wrapped := CardText.wrap_to_width(effect, font, body_size, body_area.x)
	if _text_height(_effect_label, body_size, wrapped.split("\n").size()) > body_area.y:
		# 二分查找最大可用字号，避免每次刷新长描述时逐字号反复测量。
		var low := body_floor
		var high := body_size - 1
		body_size = body_floor
		while low <= high:
			var candidate := (low + high) / 2
			var text := CardText.wrap_to_width(effect, font, candidate, body_area.x)
			if _text_height(_effect_label, candidate, text.split("\n").size()) <= body_area.y:
				body_size = candidate
				low = candidate + 1
			else:
				high = candidate - 1
		wrapped = CardText.wrap_to_width(effect, font, body_size, body_area.x)
	var line_height := font.get_height(body_size)
	var spacing := _effect_label.get_theme_constant("line_spacing")
	var max_lines := maxi(1, int((body_area.y + spacing) / maxf(1.0, line_height + spacing)))
	var lines := wrapped.split("\n")
	if lines.size() > max_lines:
		lines.resize(max_lines)
		var last := lines[max_lines - 1]
		while not last.is_empty() and font.get_string_size(last + "…", HORIZONTAL_ALIGNMENT_LEFT, -1.0, body_size).x > body_area.x:
			last = last.left(last.length() - 1)
		lines[max_lines - 1] = last + "…"
	return {"title_size": title_size, "body_size": body_size, "max_lines": max_lines, "text": "\n".join(lines)}


static func _compact_typeface() -> SystemFont:
	if _compact_font == null:
		_compact_font = SystemFont.new()
		_compact_font.font_names = PackedStringArray(COMPACT_FONT_NAMES)
		_compact_font.font_weight = 700
	return _compact_font


static func _compact_body_typeface() -> SystemFont:
	if _compact_body_font == null:
		_compact_body_font = SystemFont.new()
		_compact_body_font.font_names = PackedStringArray(COMPACT_FONT_NAMES)
		_compact_body_font.font_weight = 700
	return _compact_body_font


## 卡面描述不写句号：末尾的「。」「.」「．」统一去掉，数据层保持原样。
static func strip_period(text: String) -> String:
	var trimmed := text.strip_edges()
	while not trimmed.is_empty() and trimmed.right(1) in ["。", ".", "．"]:
		trimmed = trimmed.left(trimmed.length() - 1).strip_edges()
	return trimmed


func _apply_anchor_rect(control: Control, rect: Rect2, pad: bool) -> void:
	control.anchor_left = rect.position.x
	control.anchor_top = rect.position.y
	control.anchor_right = rect.position.x + rect.size.x
	control.anchor_bottom = rect.position.y + rect.size.y
	control.offset_left = 10.0 if pad else 0.0
	control.offset_top = 4.0 if pad else 0.0
	control.offset_right = -10.0 if pad else 0.0
	control.offset_bottom = -4.0 if pad else 0.0


## 便捷方法：把一份 CardData 直白地映射到卡面。传 null 等同于 clear()。
##
## 映射：卡牌名进卡名（空则退回卡牌标识），描述进效果文本，介绍留空。
## CardData 没有第二个自由文本字段，所以介绍文本留空；要填就用 set_texts()。
func set_card(data: CardData) -> void:
	卡牌数据 = data


## 按当前卡牌数据重渲染一次。给编辑器预览用：资源被改动后调它一次即可，
## 不用重新赋值卡牌数据（那样会走一遍 setter，语义上也重复）。
func refresh() -> void:
	_render_card_data()


func _on_catalog_changed() -> void:
	# set_texts() 驱动的图鉴卡面由页面刷新，不能被资源模式的 clear() 擦除。
	if 卡牌数据 != null:
		refresh()


## 按两个栏位换底图。挂了卡牌数据时会被数据覆盖，要单独指定用 set_face_texture()。
##
## 末尾不用再补一次刷新：GDScript 的属性 setter 每次赋值都会跑（赋同值也跑），
## 上面两个 setter 各自已经刷过一遍。
func set_face(rarity: CardData.Rarity, tint: CardData.FaceTint) -> void:
	稀有度 = rarity
	颜色 = tint


## 单张覆盖，绕开两栏位。缺图时不动原贴图。
func set_face_texture(texture: Texture2D) -> void:
	if texture == null or not is_node_ready():
		return
	_frame.texture = texture


## 插画位。留空即不显示插画。
func set_art_texture(texture: Texture2D) -> void:
	if not is_node_ready():
		return
	_art_slot.texture = texture


## 当前卡牌的 id，没塞过卡时是空 StringName。
func get_card_id() -> StringName:
	return _card_id


## 清空文本并放一次 card_data_applied(&"")。底图不动。
func clear() -> void:
	_card_id = &""
	set_enchantments({})
	set_texts("", "", "")
	card_data_applied.emit(_card_id)


## 卡牌数据的唯一渲染路径。setter 与 _ready 都走这里，两条路不会各渲染一套。
##
## 底图也在这里跟随数据：卡自己写着用哪一栏，卡面就贴哪一张。想单独覆盖底图用
## set_face_texture()。
func _render_card_data() -> void:
	if not is_node_ready():
		return
	if 卡牌数据 == null:
		clear()
		return
	# 两栏跟着数据走，但不写回导出属性：那两个属性会存进 .tscn，@tool 脚本在渲染里一写，
	# 打开场景就被标脏，一保存就把某张卡的两栏烙进预制件。显示走现算的生效值。
	_refresh_face()
	var title: String = 卡牌数据.card_name
	if title.is_empty():
		title = String(卡牌数据.card_id)
	var effect := 卡牌数据.description
	_card_id = 卡牌数据.card_id
	var catalog := get_node_or_null("/root/TextCatalog")
	if not Engine.is_editor_hint() and catalog != null:
		var record: Dictionary = catalog.entry("cards", String(_card_id))
		if not record.is_empty():
			title = str(record.get("name", ""))
			effect = str(record.get("effect", ""))
			set_art_texture(catalog.art_texture(str(record.get("art_path", ""))))
			_csv_art_applied = true
		elif _csv_art_applied:
			set_art_texture(null)
			_csv_art_applied = false
	if _boss_saturn:
		title = FinalBossRules.card_name()
		effect = FinalBossRules.card_description()
	set_texts(title, effect, "")
	card_data_applied.emit(_card_id)


## 当前生效的两栏：挂着数据就用数据里的，没挂才用节点上的导出属性。
## 这样场景里手写的值只在没有数据时起作用，两个真源不会互相覆盖。
func _effective_rarity() -> CardData.Rarity:
	if 卡牌数据 != null:
		return 卡牌数据.rarity
	return 稀有度


func _effective_tint() -> CardData.FaceTint:
	if 卡牌数据 != null:
		return 卡牌数据.face_tint
	return 颜色


func _refresh_face() -> void:
	# 导出属性在 _ready 之前就会触发 setter，此处要挡一下。
	if not is_node_ready():
		return
	if 底图集 == null:
		return
	var texture: Texture2D = 底图集.texture_for(_effective_rarity(), _effective_tint())
	if texture != null:
		_frame.texture = texture

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
## 卡组、牌堆）由调用方在设置 scale 后调用 apply_compact_layout()：把卡名与效果
## 字号按显示比例反算，效果文本扩到整块文字框并按真实字宽折行，避免缩放后文字
## 变成 4px 或顶出卡面。

@tool
class_name CardView
extends Control

const COMPACT_EFFECT_RECT := Rect2(0.1223, 0.700, 0.7473, 0.275)
const COMPACT_EFFECT_WIDTH := 338.0
## 卡名文字框的局部宽度（480 × (0.896 - 0.0959) - 左右各 10px 内缩）。
const COMPACT_TITLE_WIDTH := 364.0
## 描述字号下限：再小就宁可截断，不然卡面上全是糊字。
const COMPACT_BODY_MIN_PX := 10.0
## 卡面文字统一规格：以 0.285 倍卡（137×233）为基准，标题 16 / 描述 13。
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

const COMPACT_FONT_NAMES := ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC"]

static var _compact_font: SystemFont
static var _compact_body_font: SystemFont

## 数据变化后放一次。容器可以据此编排，例如数据写入后再开始发牌动画。
signal card_data_applied(card_id: StringName)

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


func _ready() -> void:
	_refresh_face()
	# CSV 展示文本统一入口；编辑器预览仍读资源，空表保留原测试卡文案。
	var catalog := get_node_or_null("/root/TextCatalog")
	if not Engine.is_editor_hint() and catalog != null:
		catalog.catalog_changed.connect(_on_catalog_changed)
	# 卡牌数据为空时不动文本，场景里手写的样张文案要留着。
	if 卡牌数据 != null:
		_render_card_data()
	if _compact_pending:
		_compact_pending = false
		_apply_compact(_display_scale, _compact_title_px, _compact_body_px)


## 主入口：直接给三段文本。intro 为空时介绍标签自动隐藏。
func set_texts(title: String, effect: String, intro: String = "") -> void:
	if not is_node_ready():
		return
	_raw_title = title
	_raw_effect = effect
	_raw_intro = intro
	_title_label.text = title
	_effect_label.text = effect if not _compact else _compact_effect(effect)
	_intro_label.text = intro
	_intro_label.visible = intro != "" and not _compact


## 小卡布局：按屏幕上的目标字号反算局部字号，效果文本占满卡面下方的文字框。
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
	# 描边按缩放反算，保证屏幕上约 1px：小卡文字压在浅色卡框上时靠它撑开对比。
	_effect_label.add_theme_color_override("font_outline_color", Color(0.06, 0.05, 0.04, 0.9))
	_effect_label.add_theme_constant_override("outline_size", LOCAL_OUTLINE_PX)
	var title_local := maxi(1, title_px)
	title_local = _fit_title_size(_raw_title, title_font, title_local,
		maxi(1, body_px))
	_title_label.add_theme_font_size_override("font_size", title_local)
	var body_local := maxi(1, body_px)
	_effect_label.add_theme_font_size_override("font_size", body_local)
	_title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
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
	# 描述字号不做逐卡自适应：所有卡同一档字，版式才对得齐。



func _fit_title_size(title: String, font: Font, wanted: int, floor_px: int) -> int:
	if title.is_empty() or font == null:
		return wanted
	var size := wanted
	while size > floor_px:
		if font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x \
			<= COMPACT_TITLE_WIDTH:
			break
		size -= 1
	return size


func _fit_body_size(effect: String, font: Font, wanted: int) -> int:
	var box_height := COMPACT_EFFECT_RECT.size.y * 818.0 - 8.0
	var floor_px := maxi(1, roundi(COMPACT_BODY_MIN_PX / _display_scale))
	for candidate in range(wanted, floor_px - 1, -1):
		var line_height := (font.get_height(candidate) if font != null \
			else float(candidate)) + 2.0
		var wrapped := CardText.wrap_to_width(effect, font, candidate, COMPACT_EFFECT_WIDTH)
		if float(wrapped.split("\n").size()) * line_height <= box_height:
			return candidate
	return floor_px


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


func _compact_effect(effect: String) -> String:
	effect = strip_period(effect)
	var font := _effect_label.get_theme_font("font")
	var font_size := _effect_label.get_theme_font_size("font_size")
	var wrapped := CardText.wrap_to_width(effect, font, font_size, COMPACT_EFFECT_WIDTH)
	if wrapped.is_empty():
		return wrapped
	# 小卡文字框最多容下几行就截到几行，避免长测试文案顶出卡面。
	var line_height := (font.get_height(font_size) if font != null else float(font_size)) + 2.0
	var max_lines := maxi(1, int((COMPACT_EFFECT_RECT.size.y * 818.0 - 8.0) / line_height))
	var lines := wrapped.split("\n")
	if lines.size() > max_lines:
		lines.resize(max_lines)
		var last := lines[max_lines - 1]
		lines[max_lines - 1] = last.substr(0, maxi(0, last.length() - 1)) + "…"
		wrapped = "\n".join(lines)
	return wrapped


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
	set_texts(title, 卡牌数据.description, "")
	_card_id = 卡牌数据.card_id
	var catalog := get_node_or_null("/root/TextCatalog")
	if not Engine.is_editor_hint() and catalog != null:
		var record: Dictionary = catalog.entry("cards", String(_card_id))
		if not record.is_empty():
			set_texts(str(record.get("name", "")), str(record.get("effect", "")), "")
			set_art_texture(catalog.art_texture(str(record.get("art_path", ""))))
			_csv_art_applied = true
		elif _csv_art_applied:
			set_art_texture(null)
			_csv_art_applied = false
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

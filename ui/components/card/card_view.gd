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
## 几何与字号全部在 card_view.tscn 里用锚点加偏移摆好。本脚本不移动任何节点、不设
## 置任何 position / size / font_size —— 要挪位置就在编辑器里选中 Title / Effect /
## ArtSlot 拖，要改字号就改它们的 theme_override_font_sizes。

@tool
class_name CardView
extends Control

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
@export var 稀有度: CardData.稀有度档 = CardData.稀有度档.日:
	set(value):
		稀有度 = value
		_refresh_face()

## 底图第二栏：颜色，决定卡框色调。枚举定义在 CardData 上，玩法含义未定。
@export var 颜色: CardData.颜色档 = CardData.颜色档.灰:
	set(value):
		颜色 = value
		_refresh_face()

@onready var _frame: TextureRect = %卡框
@onready var _art_slot: TextureRect = %插画位
@onready var _title_label: Label = %卡名
@onready var _effect_label: Label = %效果文本
@onready var _intro_label: Label = %介绍文本

var _card_id: StringName = &""


func _ready() -> void:
	_refresh_face()
	# 卡牌数据为空时不动文本，场景里手写的样张文案要留着。
	if 卡牌数据 != null:
		_render_card_data()


## 主入口：直接给三段文本。intro 为空时介绍标签自动隐藏。
func set_texts(title: String, effect: String, intro: String = "") -> void:
	if not is_node_ready():
		return
	_title_label.text = title
	_effect_label.text = effect
	_intro_label.text = intro
	_intro_label.visible = intro != ""


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


## 按两个栏位换底图。挂了卡牌数据时会被数据覆盖，要单独指定用 set_face_texture()。
##
## 末尾不用再补一次刷新：GDScript 的属性 setter 每次赋值都会跑（赋同值也跑），
## 上面两个 setter 各自已经刷过一遍。
func set_face(rarity: CardData.稀有度档, tint: CardData.颜色档) -> void:
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
	var title: String = 卡牌数据.卡牌名
	if title.is_empty():
		title = String(卡牌数据.卡牌标识)
	set_texts(title, 卡牌数据.描述, "")
	_card_id = 卡牌数据.卡牌标识
	card_data_applied.emit(_card_id)


## 当前生效的两栏：挂着数据就用数据里的，没挂才用节点上的导出属性。
## 这样场景里手写的值只在没有数据时起作用，两个真源不会互相覆盖。
func _effective_rarity() -> CardData.稀有度档:
	if 卡牌数据 != null:
		return 卡牌数据.稀有度
	return 稀有度


func _effective_tint() -> CardData.颜色档:
	if 卡牌数据 != null:
		return 卡牌数据.颜色
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

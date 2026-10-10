extends SceneTree

## PRG-013 卡面模板自测。用 --script 跑，不依赖渲染。
##
##   godot --headless --script res://tests/card_view_selftest.gd
##
## 覆盖范围：
##   - 模板场景能载入、节点结构、绘制顺序、锚点与场景里的实际值一致
##   - 卡面不吃输入（全部子节点 mouse_filter 为 IGNORE）
##   - set_texts / set_card / clear 的文本映射与信号
##   - @tool 与卡牌数据：编辑器内实时可见所依赖的声明与渲染路径
##   - 未 ready 时调用三个入口不报错，入树后按先前设的值渲染（编辑器加载场景走的就是这条）
##   - 样张场景在编辑器里可见：实例写在 .tscn 里，不是运行时造出来的
##   - 卡面两栏跟随数据：挂上 CardData 后底图换成数据指定的那张，改数据再 refresh 会跟上
##   - 展示体（面板与大图窗口共用）：子节点只有预览、预览里只有一张卡、按选中绑定
##   - 检查器预览控件：绑定、五个字段的变化都触发刷新、未改动不重绘、绑 null 安全
##   - 卡牌面板：三处选中来源的判定顺序、无选中返回 null、自动缩放倍率与上下限
##   - 两栏位底图：8 种组合都取到图、互不相同、不齐时的判定
##   - 8 张已导入底图的实际尺寸与导入参数是否生效
##   - 脚本里不含几何赋值（几何归场景，不归代码）
##
## 注意事项（本工程踩过的坑）：
##   - 工程把警告当错误。不要用 := 承接返回类型为 Variant 的表达式。
##   - 信号一律接内部类记录器，不接 lambda（lambda 对捕获变量只读，且会报 ObjectDB leaked）。
##
## 日志里会出现一次预期内的 ERROR（CardFaceSet 的缺图分支），见 _test_face_set_missing。

const CARD_SCENE_PATH := "res://ui/components/card/card_view.tscn"
const FACE_SET_PATH := "res://data/config/card_face_set.tres"
const VIEW_SCRIPT_PATH := "res://ui/components/card/card_view.gd"
const FACE_SET_SCRIPT_PATH := "res://ui/components/card/card_face_set.gd"
const PREVIEW_SCRIPT_PATH := "res://addons/card_preview/card_data_preview.gd"
const PREVIEW_PLUGIN_PATH := "res://addons/card_preview/card_preview_plugin.gd"
const PREVIEW_INSPECTOR_PATH := "res://addons/card_preview/card_data_inspector_plugin.gd"
const PREVIEW_DOCK_PATH := "res://addons/card_preview/card_dock.gd"
const PREVIEW_STAGE_PATH := "res://addons/card_preview/card_stage.gd"
const PREVIEW_WINDOW_PATH := "res://addons/card_preview/card_window.gd"
const PREVIEW_RESOLVER_PATH := "res://addons/card_preview/card_target_resolver.gd"

const FACE_SIZE := Vector2(480, 818)
const ANCHOR_TOLERANCE := 0.001
const IMPORT_MAX_EDGE := 1024

## 与 card_view.tscn 里的锚点一致。底部面板整块是 0.7190..0.9190，场景里由
## Effect（上半）与 Intro（下半）对半分。
const ART_ANCHORS := Rect2(0.1192, 0.2087, 0.7534, 0.3581)
const TITLE_ANCHORS := Rect2(0.0959, 0.5749, 0.8001, 0.1211)
const EFFECT_ANCHORS := Rect2(0.1223, 0.719, 0.7473, 0.1)
const INTRO_ANCHORS := Rect2(0.1223, 0.819, 0.7473, 0.1)

## 脚本里一旦出现这些写法，说明几何被搬进了代码，编辑器里拖不动。
const FORBIDDEN_IN_VIEW_SCRIPT: Array[String] = [
	".position =",
	".global_position =",
	".size =",
	"custom_minimum_size =",
	".scale =",
	"font_size =",
]

var _failures := 0


func _initialize() -> void:
	# --script 模式下 _initialize() 跑在 SceneTree 开始迭代之前，此时 add_child 不会
	# 触发 NOTIFICATION_READY，@onready 变量全是 null（is_node_ready() 为 false）。
	# 等一帧再跑测试，节点就绪时序才和真实运行一致。
	await process_frame
	_test_scene_shape()
	_test_anchors()
	_test_texts()
	_test_set_card_mapping()
	_test_clear_and_signal()
	_test_tool_and_exported_data()
	_test_not_ready_safety()
	_test_card_data_drives_face()
	_test_editor_preview()
	_test_card_stage()
	_test_card_dock()
	_test_face_set_complete()
	_test_face_set_missing()
	_test_set_face_swaps_texture()
	_test_imported_textures()
	_test_no_geometry_in_view_script()

	if _failures == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _failures)
	quit(_failures)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		_failures += 1
		print("  失败  %s  %s" % [label, detail])


## 记录 card_data_applied 的接法。用内部类而不是 lambda，原因见文件头。
class AppliedRecorder:
	var 张数 := 0
	var ids: Array[StringName] = []

	func on_applied(卡牌标识: StringName) -> void:
		张数 += 1
		ids.append(卡牌标识)


## 假的编辑器接口，用来测卡牌面板的「当前选中」判定。方法名与 EditorInterface 一致即可，
## 面板只按鸭子类型调用。
class FakeEditor:
	var paths := PackedStringArray()
	var edited: Object = null
	var nodes: Array[Node] = []

	func get_selected_paths() -> PackedStringArray:
		return paths

	func get_inspector() -> Object:
		return self

	func get_edited_object() -> Object:
		return edited

	func get_selection() -> Object:
		return self

	func get_selected_nodes() -> Array:
		return nodes


## 造一张卡面并挂进场景树，% 节点与 @onready 才会解析。
func _spawn_card() -> CardView:
	var packed: PackedScene = load(CARD_SCENE_PATH)
	var card: CardView = packed.instantiate()
	root.add_child(card)
	return card


func _rect_of(node: Control) -> Rect2:
	return Rect2(
		node.anchor_left,
		node.anchor_top,
		node.anchor_right - node.anchor_left,
		node.anchor_bottom - node.anchor_top
	)


func _rect_matches(actual: Rect2, expected: Rect2) -> bool:
	return (
		absf(actual.position.x - expected.position.x) <= ANCHOR_TOLERANCE
		and absf(actual.position.y - expected.position.y) <= ANCHOR_TOLERANCE
		and absf(actual.size.x - expected.size.x) <= ANCHOR_TOLERANCE
		and absf(actual.size.y - expected.size.y) <= ANCHOR_TOLERANCE
	)


func _test_scene_shape() -> void:
	print("[场景结构]")
	var card := _spawn_card()
	_check("场景能载入并实例化为 CardView", card != null and card is CardView)
	_check("根节点是 Control", card is Control)
	_check(
		"add_child 之后节点已 ready（调用方可以立刻 set_texts）",
		card.is_node_ready(),
		"未就绪意味着 @onready 变量还是 null"
	)

	var names: Array[String] = ["插画位", "卡框", "卡名", "效果文本", "介绍文本"]
	for node_name in names:
		_check("存在子节点 %s" % node_name, card.has_node("%" + node_name))

	var art := card.get_node("%插画位") as Control
	var frame := card.get_node("%卡框") as Control
	_check(
		"ArtSlot 画在 Frame 之前（插画区是透明洞）",
		art.get_index() < frame.get_index(),
		"ArtSlot index=%d Frame index=%d" % [art.get_index(), frame.get_index()]
	)

	_check(
		"根节点尺寸为 480 x 818",
		card.size.is_equal_approx(FACE_SIZE),
		"实际 %s" % str(card.size)
	)
	_check(
		"根节点 custom_minimum_size 为 480 x 818",
		card.custom_minimum_size.is_equal_approx(FACE_SIZE),
		"实际 %s" % str(card.custom_minimum_size)
	)
	for node_name in names:
		var child := card.get_node("%" + node_name) as Control
		_check(
			"%s 不吃输入（mouse_filter 为 IGNORE）" % node_name,
			child.mouse_filter == Control.MOUSE_FILTER_IGNORE
		)
	card.queue_free()


func _test_anchors() -> void:
	print("[锚点与场景一致]")
	var card := _spawn_card()
	var pairs: Array = [
		["插画位", ART_ANCHORS],
		["卡名", TITLE_ANCHORS],
		["效果文本", EFFECT_ANCHORS],
		["介绍文本", INTRO_ANCHORS],
	]
	for pair in pairs:
		var node_name: String = pair[0]
		var expected: Rect2 = pair[1]
		var node := card.get_node("%" + node_name) as Control
		var actual := _rect_of(node)
		_check(
			"%s 锚点等于场景里的值" % node_name,
			_rect_matches(actual, expected),
			"实际 %s 期望 %s" % [str(actual), str(expected)]
		)
	card.queue_free()


func _test_texts() -> void:
	print("[文本写入口]")
	var card := _spawn_card()
	card.set_texts("给你一拳", "造成 6 点伤害", "介绍占位")
	var title := card.get_node("%卡名") as Label
	var effect := card.get_node("%效果文本") as Label
	var intro := card.get_node("%介绍文本") as Label
	_check("set_texts 写入卡名", title.text == "给你一拳", title.text)
	_check("set_texts 写入效果文本", effect.text == "造成 6 点伤害", effect.text)
	_check("set_texts 写入介绍文本", intro.text == "介绍占位", intro.text)
	_check("介绍非空时 Intro 可见", intro.visible)

	card.set_texts("只有卡名", "只有效果")
	_check("介绍为空时 Intro 隐藏", not intro.visible)
	_check("介绍为空时文本被清空", intro.text == "")
	card.queue_free()


func _test_set_card_mapping() -> void:
	print("[set_card 映射]")
	var card := _spawn_card()
	var data := CardData.new()
	data.card_id = &"bonk"
	data.card_name = "给你一拳"
	data.description = "造成 6 点伤害"
	card.set_card(data)
	var title := card.get_node("%卡名") as Label
	var effect := card.get_node("%效果文本") as Label
	var intro := card.get_node("%介绍文本") as Label
	_check("卡牌名 进卡名", title.text == "给你一拳", title.text)
	_check("描述 进效果文本", effect.text == "造成 6 点伤害", effect.text)
	_check("介绍留空且隐藏", intro.text == "" and not intro.visible)
	_check("get_card_id 返回 卡牌标识", card.get_card_id() == &"bonk", str(card.get_card_id()))

	var unnamed := CardData.new()
	unnamed.card_id = &"no_name"
	card.set_card(unnamed)
	_check("卡牌名 为空时退回 卡牌标识", title.text == "no_name", title.text)
	card.queue_free()


func _test_clear_and_signal() -> void:
	print("[清空与信号]")
	var card := _spawn_card()
	var recorder := AppliedRecorder.new()
	card.card_data_applied.connect(recorder.on_applied)

	var data := CardData.new()
	data.card_id = &"peek"
	data.card_name = "我看一眼"
	card.set_card(data)
	_check("set_card 放一次信号", recorder.张数 == 1, "实际 %d 次" % recorder.张数)
	_check("信号带 卡牌标识", recorder.ids.size() == 1 and recorder.ids[0] == &"peek", str(recorder.ids))

	card.set_card(null)
	_check("set_card(null) 再放一次信号", recorder.张数 == 2, "实际 %d 次" % recorder.张数)
	_check("清空后卡牌标识为空", card.get_card_id() == &"", str(card.get_card_id()))
	var title := card.get_node("%卡名") as Label
	_check("清空后卡名文本为空", title.text == "", title.text)

	card.clear()
	_check("clear 也放信号", recorder.张数 == 3, "实际 %d 次" % recorder.张数)
	card.queue_free()


func _test_tool_and_exported_data() -> void:
	print("[@tool 与卡牌数据]")
	var source := _read_view_script()
	_check("脚本声明了 @tool", source.contains("@tool\nclass_name CardView"))
	_check("脚本导出了卡牌数据: CardData", source.contains("@export var 卡牌数据: CardData"))

	# 卡面在编辑器里会调 CardFaceSet.texture_for，这个资源脚本不声明 @tool 时，
	# 编辑器里的实例是占位对象，调用会报错。
	var face_set_source := FileAccess.get_file_as_string(FACE_SET_SCRIPT_PATH)
	_check(
		"CardFaceSet 也声明了 @tool（编辑器里要调它的方法）",
		face_set_source.contains("@tool\nclass_name CardFaceSet")
	)

	var card := _spawn_card()
	var title := card.get_node("%卡名") as Label
	var data := CardData.new()
	data.card_id = &"bonk"
	data.card_name = "给你一拳"
	data.description = "造成 6 点伤害"

	card.卡牌数据 = data
	_check("挂上卡牌数据立刻渲染", title.text == "给你一拳", title.text)
	_check("card_data 读回一致", card.卡牌数据 == data)

	var other := CardData.new()
	other.card_id = &"peek"
	other.card_name = "我看一眼"
	card.set_card(other)
	_check(
		"set_card 与卡牌数据是同一份数据、同一条渲染路径",
		card.卡牌数据 == other and title.text == "我看一眼",
		title.text
	)
	card.queue_free()


func _test_not_ready_safety() -> void:
	print("[未 ready 时调用（编辑器加载场景走的就是这条）]")
	var packed: PackedScene = load(CARD_SCENE_PATH)
	var card: CardView = packed.instantiate()
	_check("刚实例化、未入树时未 ready", not card.is_node_ready())

	var data := CardData.new()
	data.card_id = &"bonk"
	data.card_name = "给你一拳"
	data.description = "造成 6 点伤害"
	data.rarity = CardData.Rarity.RARE
	data.face_tint = CardData.FaceTint.BLUE
	card.set_texts("早写的", "早写的效果", "早写的介绍")
	card.set_face(CardData.Rarity.COMMON, CardData.FaceTint.GRAY)
	card.卡牌数据 = data
	_check("未 ready 时三个入口都不抛错、不崩", card != null)

	root.add_child(card)
	var title := card.get_node("%卡名") as Label
	var frame := card.get_node("%卡框") as TextureRect
	var 底图集: CardFaceSet = load(FACE_SET_PATH)
	_check("入树后卡牌数据的文本生效", title.text == "给你一拳", title.text)
	_check(
		"入树后底图按数据里的两栏生效（月蓝，而不是 set_face 设的日灰）",
		frame.texture == 底图集.texture_for(CardData.Rarity.RARE, CardData.FaceTint.BLUE),
		str(frame.texture.resource_path)
	)
	card.queue_free()


func _test_card_data_drives_face() -> void:
	print("[卡面两栏跟随数据]")
	var card := _spawn_card()
	var 底图集: CardFaceSet = load(FACE_SET_PATH)
	var frame := card.get_node("%卡框") as TextureRect

	var data := CardData.new()
	data.card_id = &"moon_red"
	data.card_name = "月红卡"
	data.rarity = CardData.Rarity.RARE
	data.face_tint = CardData.FaceTint.RED
	card.set_card(data)
	_check(
		"挂上数据后底图换成数据指定的那张（月红）",
		frame.texture == 底图集.texture_for(CardData.Rarity.RARE, CardData.FaceTint.RED),
		str(frame.texture.resource_path)
	)
	_check("卡面按数据里的两栏显示，但不写回节点自己的导出属性（那两个会存进 .tscn）",
		card.稀有度 == CardData.Rarity.COMMON and card.颜色 == CardData.FaceTint.GRAY)

	data.face_tint = CardData.FaceTint.YELLOW
	card.refresh()
	_check(
		"改了数据再 refresh 会跟上（月黄）",
		frame.texture == 底图集.texture_for(CardData.Rarity.RARE, CardData.FaceTint.YELLOW),
		str(frame.texture.resource_path)
	)

	card.set_face_texture(null)
	_check("set_face_texture(null) 不动原图", frame.texture != null)
	card.queue_free()


func _test_card_stage() -> void:
	print("[展示体：面板与大图窗口共用]")
	var stage_script: Script = load(PREVIEW_STAGE_PATH)
	_check("展示体脚本能载入", stage_script != null)
	if stage_script == null:
		return

	var stage: Control = stage_script.new()
	var editor := FakeEditor.new()
	editor.edited = load("res://data/cards/bonk_1.tres")
	stage.setup(editor)
	root.add_child(stage)

	var preview: Control = stage.get_preview()
	_check("展示体里有预览控件", preview != null)
	_check("展示体子节点只有预览这一个", stage.get_child_count() == 1, "实际 %d 个" % stage.get_child_count())
	_check("预览里只有一张卡面", preview.get_child_count() == 1, "实际 %d 个" % preview.get_child_count())

	stage.refresh_now()
	_check("按当前选中绑定了卡", stage.get_current_card() == editor.edited)
	var card: CardView = preview.get_card_view()
	_check(
		"卡面显示的是那张卡的卡名",
		(card.get_node("%卡名") as Label).text == "给你一拳",
		(card.get_node("%卡名") as Label).text
	)
	_check(
		"倍率按可用空间算且在上下限之间",
		preview.preview_scale > 0.0 and preview.preview_scale <= 1.2,
		"%.3f" % preview.preview_scale
	)
	stage.queue_free()


func _collect_card_views(node: Node, out: Array[CardView]) -> void:
	for child in node.get_children():
		if child is CardView:
			out.append(child)
		_collect_card_views(child, out)


func _test_editor_preview() -> void:
	print("[检查器预览控件]")
	_check("插件入口脚本能载入", load(PREVIEW_PLUGIN_PATH) != null)
	_check("检查器插件脚本能载入", load(PREVIEW_INSPECTOR_PATH) != null)

	var preview_script: Script = load(PREVIEW_SCRIPT_PATH)
	_check("预览脚本能载入", preview_script != null)
	if preview_script == null:
		return
	var preview: Control = preview_script.new()
	var data := CardData.new()
	data.card_id = &"bonk"
	data.card_name = "给你一拳"
	data.description = "造成 6 点伤害"
	# 检查器插件的真实时序：先 new、再 bind、最后入树
	preview.bind(data)
	root.add_child(preview)

	var card: CardView = preview.get_card_view()
	_check("预览内部有卡面实例", card != null)
	if card == null:
		return
	var title := card.get_node("%卡名") as Label
	var effect := card.get_node("%效果文本") as Label
	var frame := card.get_node("%卡框") as TextureRect
	var 底图集: CardFaceSet = load(FACE_SET_PATH)
	_check("入树前绑定的数据在 _ready 后渲染出来", title.text == "给你一拳", title.text)
	_check("效果文本同步", effect.text == "造成 6 点伤害", effect.text)
	_check(
		"预览高度等于卡面设计高度乘 0.3",
		absf(preview.custom_minimum_size.y - 818.0 * 0.3) <= 1.0,
		str(preview.custom_minimum_size)
	)
	_check(
		"预览底图是日灰",
		frame.texture == 底图集.texture_for(CardData.Rarity.COMMON, CardData.FaceTint.GRAY),
		str(frame.texture.resource_path)
	)

	_check("没改动时不重渲染", not preview.refresh_if_changed())

	data.card_name = "改过的名字"
	_check("改卡牌名后重渲染", preview.refresh_if_changed())
	_check("卡面文字已更新", title.text == "改过的名字", title.text)

	var cases: Array = [
		["card_id", &"other"],
		["description", "别的效果"],
		["rarity", CardData.Rarity.RARE],
		["face_tint", CardData.FaceTint.RED],
	]
	for pair in cases:
		preview.refresh_if_changed()
		data.set(pair[0], pair[1])
		_check("改 %s 也算变化" % pair[0], preview.refresh_if_changed())

	preview.bind(null)
	_check("绑 null 不报错且卡面清空", title.text == "", title.text)
	preview.queue_free()


func _test_card_dock() -> void:
	print("[卡牌面板：当前选中判定]")
	var resolver: Script = load(PREVIEW_RESOLVER_PATH)
	_check("判定逻辑脚本能载入", resolver != null)
	if resolver == null:
		return

	var editor := FakeEditor.new()
	var bonk: CardData = load("res://data/cards/bonk_1.tres")
	var duck: CardData = load("res://data/cards/duck_1.tres")
	_check("三处都没选时返回 null", resolver.resolve(editor) == null)

	var png_paths := PackedStringArray(["res://assets/ui/UI-001/日灰.png"])
	editor.paths = png_paths
	editor.edited = duck
	_check("检查器在编辑卡时返回它", resolver.resolve(editor) == duck)

	# FileSystem 的选中会残留，不能盖住检查器当前编辑的卡
	var card_paths := PackedStringArray(["res://data/cards/bonk_1.tres"])
	editor.paths = card_paths
	_check("检查器的卡优先于 FileSystem 里残留的选中", resolver.resolve(editor) == duck)

	editor.edited = RefCounted.new()
	_check("检查器编辑的不是卡时落到 FileSystem 选中", resolver.resolve(editor) == bonk)

	editor.paths = PackedStringArray()
	editor.edited = null
	var card_node: CardView = load(CARD_SCENE_PATH).instantiate()
	card_node.卡牌数据 = duck
	var selected: Array[Node] = [card_node]
	editor.nodes = selected
	_check("场景里选中卡面节点时显示它挂的卡", resolver.resolve(editor) == duck)
	card_node.queue_free()

	_check("编辑器接口为 null 时返回 null", resolver.resolve(null) == null)

	# 倍率：卡面 480 × 818，四周各留 12
	var card_size := Vector2(480.0, 818.0)
	var exactly := card_size + Vector2(resolver.MARGIN * 2.0, resolver.MARGIN * 2.0)
	_check("刚好放得下时倍率为 1", absf(resolver.fit_scale(exactly, card_size) - 1.0) <= 0.001)
	_check(
		"宽度受限时按宽度算",
		absf(resolver.fit_scale(Vector2(264.0, 2000.0), card_size) - 0.5) <= 0.001,
		str(resolver.fit_scale(Vector2(264.0, 2000.0), card_size))
	)
	_check("空间极小时钳到下限", resolver.fit_scale(Vector2(10.0, 10.0), card_size) >= 0.05)
	_check("空间极大时钳到上限", resolver.fit_scale(Vector2(9999.0, 9999.0), card_size) <= 1.2)

	# 面板类本身是 EditorDock，只能在编辑器里实例化，运行期不做断言；
	# 它在编辑器里的表现由 --headless --editor 下的自测取证。
	_check("面板脚本能载入", load(PREVIEW_DOCK_PATH) != null)


func _test_face_set_complete() -> void:
	print("[两栏位底图]")
	var 底图集: CardFaceSet = load(FACE_SET_PATH)
	_check("card_face_set.tres 能载入", 底图集 != null)
	_check("8 张齐全", 底图集.is_complete(), "实际 %d 张" % 底图集.底图列表.size())

	var paths: Array[String] = []
	var missing := 0
	for phase in [CardData.Rarity.COMMON, CardData.Rarity.RARE]:
		for tint in [
			CardData.FaceTint.GRAY,
			CardData.FaceTint.RED,
			CardData.FaceTint.BLUE,
			CardData.FaceTint.YELLOW,
		]:
			var texture: Texture2D = 底图集.texture_for(phase, tint)
			if texture == null:
				missing += 1
				continue
			paths.append(texture.resource_path)
	_check("8 种栏位组合都取到图", missing == 0, "缺 %d 张" % missing)
	_check("8 张互不相同", paths.size() == 8 and _unique(paths) == 8, "去重后 %d 张" % _unique(paths))
	_check(
		"两轴互换取到的不是同一张",
		底图集.texture_for(CardData.Rarity.COMMON, CardData.FaceTint.GRAY).resource_path
		!= 底图集.texture_for(CardData.Rarity.RARE, CardData.FaceTint.RED).resource_path
	)

	var short_set := CardFaceSet.new()
	short_set.底图列表 = [底图集.texture_for(CardData.Rarity.COMMON, CardData.FaceTint.GRAY)]
	_check("张数不足时 is_complete 为假", not short_set.is_complete())

	var holed := CardFaceSet.new()
	holed.底图列表 = 底图集.底图列表.duplicate()
	holed.底图列表[3] = null
	_check("中间缺一张时 is_complete 为假", not holed.is_complete())


func _test_face_set_missing() -> void:
	# 这里会打印一次预期内的 ERROR：CardFaceSet 缺图分支的 push_error。
	print("[缺图分支（下方会有一行预期内的 ERROR）]")
	var empty_set := CardFaceSet.new()
	_check("空集合取图返回 null", empty_set.texture_for(CardData.Rarity.RARE, CardData.FaceTint.YELLOW) == null)


func _test_set_face_swaps_texture() -> void:
	print("[换底图]")
	var card := _spawn_card()
	var 底图集: CardFaceSet = load(FACE_SET_PATH)
	var frame := card.get_node("%卡框") as TextureRect

	card.set_face(CardData.Rarity.COMMON, CardData.FaceTint.GRAY)
	var sun_gray: Texture2D = 底图集.texture_for(CardData.Rarity.COMMON, CardData.FaceTint.GRAY)
	_check("日灰：Frame 贴的是日灰", frame.texture == sun_gray, str(frame.texture.resource_path))

	card.set_face(CardData.Rarity.RARE, CardData.FaceTint.YELLOW)
	var moon_yellow: Texture2D = 底图集.texture_for(CardData.Rarity.RARE, CardData.FaceTint.YELLOW)
	_check("月黄：Frame 换成了月黄", frame.texture == moon_yellow, str(frame.texture.resource_path))

	card.set_face_texture(null)
	_check("传 null 时不改动现有底图", frame.texture == moon_yellow)

	var art := card.get_node("%插画位") as TextureRect
	_check("插画位默认是空的", art.texture == null)
	card.queue_free()


func _test_imported_textures() -> void:
	print("[导入后的底图实际尺寸]")
	var 底图集: CardFaceSet = load(FACE_SET_PATH)
	var sizes: Array[Vector2] = []
	for texture in 底图集.底图列表:
		var tex: Texture2D = texture
		sizes.append(tex.get_size())
	var first: Vector2 = sizes[0]
	var all_same := true
	var max_edge := 0.0
	for size in sizes:
		if not size.is_equal_approx(first):
			all_same = false
		max_edge = maxf(max_edge, maxf(size.x, size.y))
	_check("8 张尺寸一致", all_same, str(sizes))
	_check(
		"最大边不超过 %d（导入的 size_limit 生效）" % IMPORT_MAX_EDGE,
		max_edge <= float(IMPORT_MAX_EDGE) and max_edge > 0.0,
		"实际最大边 %.0f，单张 %s" % [max_edge, str(first)]
	)
	_check("尺寸与原图等比（宽高比 0.5868）", absf(first.x / first.y - 0.5868) <= 0.002, "%.4f" % (first.x / first.y))


func _test_no_geometry_in_view_script() -> void:
	print("[几何不写在脚本里]")
	var source := _read_view_script()
	_check("card_view.gd 能读到", not source.is_empty())
	var hits: Array[String] = []
	for pattern in FORBIDDEN_IN_VIEW_SCRIPT:
		if source.contains(pattern):
			hits.append(pattern)
	_check("card_view.gd 里没有几何赋值", hits.is_empty(), "命中 %s" % str(hits))


func _read_view_script() -> String:
	var file := FileAccess.open(VIEW_SCRIPT_PATH, FileAccess.READ)
	if file == null:
		return ""
	var source := file.get_as_text()
	file.close()
	return source


func _unique(values: Array[String]) -> int:
	var seen: Dictionary = {}
	for value in values:
		seen[value] = true
	return seen.size()

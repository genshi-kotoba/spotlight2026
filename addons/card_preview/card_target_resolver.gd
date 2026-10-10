## 卡牌面板的判定逻辑：从编辑器接口里挑出「当前选中的那张卡」，以及按可用空间算倍率
##
## 单独放一个文件、只有静态方法，是因为基类 EditorDock 只能在编辑器里实例化
## （在 --script 的非编辑器环境里 new() 会报 "Class 'EditorDock' can only be
## instantiated by editor."）。逻辑长在面板类里就没法无头自测，所以抽到这里。
##
## 编辑器接口写成 Object 按鸭子类型调用，不写 EditorInterface 这个单例名：单例名在非
## 编辑器环境下解析不出来，会让整个脚本挂掉。副作用是自测可以塞假对象进来。

@tool
extends RefCounted

## 卡面四周留的空隙。
const MARGIN := 12.0
const MIN_SCALE := 0.05
const MAX_SCALE := 1.2


## 挑出当前选中的卡。判定顺序：
##   1. 检查器正在编辑的对象，是 CardData 时
##   2. FileSystem 面板里选中的第一份 CardData（.tres）
##   3. 场景里选中的节点是 CardView 时，显示它身上挂的卡牌数据
## 三处都没有时返回 null。
##
## 检查器排在 FileSystem 前面，是因为 FileSystem 的选中会残留（面板不刷新就一直
## 记着上次点过的文件），排在前面会把检查器当前编辑的卡一直挡住。反过来，在 FileSystem
## 里点一份 .tres 时检查器也会跟着切过去，所以先看检查器不会漏掉点击文件这个动作。
static func resolve(editor: Object) -> CardData:
	if editor == null:
		return null

	var inspector: Object = editor.get_inspector()
	if inspector != null:
		var edited: Object = inspector.get_edited_object()
		if edited is CardData:
			return edited

	var paths: PackedStringArray = editor.get_selected_paths()
	for path in paths:
		if not path.ends_with(".tres"):
			continue
		var resource: Resource = ResourceLoader.load(path)
		if resource is CardData:
			return resource

	var selection: Object = editor.get_selection()
	if selection != null:
		for node in selection.get_selected_nodes():
			if node is CardView:
				var card_view: CardView = node
				if card_view.卡牌数据 != null:
					return card_view.卡牌数据

	return null


## 按可用空间算卡面倍率：两边都能放下，取较小的那个，再钳到上下限。
static func fit_scale(available: Vector2, card_size: Vector2) -> float:
	if card_size.x <= 0.0 or card_size.y <= 0.0:
		return MIN_SCALE
	var usable := Vector2(
		maxf(1.0, available.x - MARGIN * 2.0),
		maxf(1.0, available.y - MARGIN * 2.0)
	)
	return clampf(minf(usable.x / card_size.x, usable.y / card_size.y), MIN_SCALE, MAX_SCALE)

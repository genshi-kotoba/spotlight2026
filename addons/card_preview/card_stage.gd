## 卡牌展示体：右侧面板与大图窗口共用的那一块
##
## 里面只有一份预览控件，预览里只有一张卡面，没有任何标签或按钮。按容器大小自动缩放
## 居中，按「当前选中」换卡。
##
## 面板（card_dock.gd）与大图窗口（card_window.gd）都只是它的外壳，展示逻辑只写在这里
## 一处。判定「当前选中」与算倍率的纯逻辑在 card_target_resolver.gd，那样才能无头自测。

@tool
extends Control

const PREVIEW_SCRIPT := preload("res://addons/card_preview/card_data_preview.gd")
const RESOLVER := preload("res://addons/card_preview/card_target_resolver.gd")

## 兜底轮询间隔。选中的卡换了由插件接的三个信号即时通知，这个间隔只是防漏。
const RESOLVE_INTERVAL := 0.4

var _editor: Object
var _preview: Control
var _current: CardData
var _elapsed := 0.0


## 由外壳在入树前调用。
func setup(editor: Object) -> void:
	_editor = editor


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview = PREVIEW_SCRIPT.new()
	add_child(_preview)
	refresh_now()


func _process(delta: float) -> void:
	# 不可见时不判定：大图窗口默认是关着的，右侧面板也可能被折起来，那时候没必要每
	# 0.4 秒去问一次编辑器「当前选中是谁」。重新可见时会立刻判一次。
	if not is_visible_in_tree():
		return
	_elapsed += delta
	if _elapsed < RESOLVE_INTERVAL:
		return
	_elapsed = 0.0
	refresh_now()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_fit()


## 重新判定当前选中的卡并刷新。插件的信号回调也直接调它。
func refresh_now() -> void:
	if _preview == null:
		return
	var target := RESOLVER.resolve(_editor)
	if target != _current:
		_current = target
		_preview.bind(target)
	_fit()


## 当前正在显示的那张卡，给自测看。
func get_current_card() -> CardData:
	return _current


## 内部预览控件，给自测看。
func get_preview() -> Control:
	return _preview


## 让预览铺满并按其大小重算倍率。
func _fit() -> void:
	if _preview == null:
		return
	_preview.position = Vector2.ZERO
	_preview.size = size
	var card: CardView = _preview.get_card_view()
	if card == null:
		# 预览内部还没建出卡面。卡面尺寸的真源是 card_view.tscn 的 custom_minimum_size，
		# 这里不另抄一份设计尺寸当兜底，等它建好之后的 resize 再算倍率。
		return
	_preview.set_preview_scale(RESOLVER.fit_scale(size, card.custom_minimum_size))

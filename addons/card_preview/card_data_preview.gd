## 检查器里的卡面实时预览
##
## 由 card_data_inspector_plugin 插进 CardData 的属性列表顶部。内部持有一份
## card_view.tscn 实例，把被编辑的资源塞给它的卡牌数据，资源一变就让它重渲染。
##
## 为什么用轮询而不是信号：Resource.changed 不会因为属性赋值而触发 ——
## data.set("卡牌名", ...) 与 data.卡牌名 = ... 之后 changed 都触发 0 次，只有
## 显式 emit_changed() 才触发。所以实时性只能靠按固定间隔比对签名。移植参考的那份
## Unity demo（Card and Dice）里，CardPreviewer 同样是每 0.5 秒轮询。
##
## 本控件是编辑器工具，只改自己的子节点与卡面显示，不写文件、不碰工程设置。

@tool
extends Control

const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")

## 默认倍率。卡面设计尺寸 480 × 818，乘 0.3 后是 144 × 245，塞得进默认宽度的检查器。
## 卡牌面板不用这个值，它按可用空间自动算，见 card_dock.gd。
const DEFAULT_SCALE := 0.3

## 轮询间隔。改字段后最多这么久刷新一次。
const POLL_INTERVAL := 0.15

## 当前倍率。检查器预览用默认值，卡牌面板与大图窗口按可用空间调。
var preview_scale := DEFAULT_SCALE

var _card: CardView
var _target: CardData
var _signature: Array = []
var _elapsed := 0.0


func _ready() -> void:
	_card = CARD_SCENE.instantiate()
	add_child(_card)
	_apply_scale()
	if _target != null:
		_card.卡牌数据 = _target


func _process(delta: float) -> void:
	# 不可见时不轮询：检查器滚走了、面板折起来了、大图窗口没开的时候，改了字段也看不见。
	# 重新可见后的第一次轮询会照常发现变化并刷新，签名只在 refresh_if_changed 里更新。
	if not is_visible_in_tree():
		return
	_elapsed += delta
	if _elapsed < POLL_INTERVAL:
		return
	_elapsed = 0.0
	refresh_if_changed()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_center_card()


## 改倍率。卡牌面板按面板大小调它。
func set_preview_scale(value: float) -> void:
	preview_scale = clampf(value, 0.01, 4.0)
	_apply_scale()


## 绑定要预览的资源。传 null 显示空卡。
func bind(data: CardData) -> void:
	_target = data
	_signature = _signature_of(data)
	if _card != null:
		_card.卡牌数据 = data


## 比对显示字段，变了就重渲染，返回是否刷新过。公开是为了让自测能确定性地驱动它。
func refresh_if_changed() -> bool:
	if _card == null:
		return false
	var current := _signature_of(_target)
	if current == _signature:
		return false
	_signature = current
	_card.refresh()
	return true


## 内部的卡面实例，给自测与外部取用。
func get_card_view() -> CardView:
	return _card


## 卡面上会显示出来的字段。只有这些变了才值得重渲染。
##
## 用数组逐个比，不拼成一个字符串：拼串时字段里只要出现分隔符，两组不同字段就可能拼出
## 同一个串（卡名里有竖线时会发生），那一次改动会被漏掉，实时预览就静默失灵了。
func _signature_of(data: CardData) -> Array:
	if data == null:
		return []
	return [data.卡牌标识, data.卡牌名, data.描述, data.稀有度, data.颜色]


## 套用当前倍率：缩放卡面、按缩放后的尺寸给出最小尺寸、重新居中。
func _apply_scale() -> void:
	if _card == null:
		return
	_card.scale = Vector2(preview_scale, preview_scale)
	custom_minimum_size = _card.custom_minimum_size * preview_scale
	_center_card()


## 卡面按设计尺寸摆放，缩放后再居中到预览宽度里。改的是预览自己的子节点，
## 不动 card_view.tscn 自身的几何。
func _center_card() -> void:
	if _card == null:
		return
	var scaled_width := _card.custom_minimum_size.x * preview_scale
	_card.position.x = maxf(0.0, (size.x - scaled_width) * 0.5)

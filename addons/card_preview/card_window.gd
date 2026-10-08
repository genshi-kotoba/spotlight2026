## 卡牌大图窗口
##
## 菜单「项目 → 工具 → 卡牌大图」打开。里面同样只有一张卡面，窗口可以随便拉大、挪到
## 第二个显示器。跟着「当前选中」换卡，改字段实时刷新。
##
## 与右侧「卡牌」面板共用同一份展示体 card_stage.gd，因此这里也没有可测逻辑。

@tool
extends Window

const STAGE_SCRIPT := preload("res://addons/card_preview/card_stage.gd")

## 默认开多大。卡面设计尺寸 480 × 818，这个尺寸下倍率接近 1.2，是底图不糊的上限。
const DEFAULT_SIZE := Vector2i(660, 1020)

const MIN_SIZE := Vector2i(320, 500)

var _stage: Control


## 由插件在入树之后调用。入树前设 size 会被 Window 自己重置，所以插件那边是先
## add_child 再 setup。
func setup(editor: Object) -> void:
	title = "卡牌大图"
	wrap_controls = false
	min_size = MIN_SIZE
	size = DEFAULT_SIZE
	# 默认藏起来，等菜单里点了才开，不然编辑器一启动就弹一个窗口出来。
	visible = false
	_stage = STAGE_SCRIPT.new()
	_stage.setup(editor)
	add_child(_stage)


## 重新判定当前选中的卡。由插件在选中变化时调用。
func refresh_now() -> void:
	if _stage != null:
		_stage.refresh_now()

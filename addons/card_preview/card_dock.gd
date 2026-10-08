## 编辑器右侧的「卡牌」面板：只显示当前选中的那张卡
##
## 面板里只有一张卡面，没有别的卡、没有标签、没有按钮。展示逻辑全在 card_stage.gd，
## 本文件只是它的外壳。
##
## 基类必须用 EditorDock：Godot 4.7 的 EditorPlugin.add_dock() 只收 EditorDock，
## 传普通 Control 会报「not a subclass of the expected argument class」。代价是
## EditorDock 只能在编辑器里实例化，所以这里不写任何可测逻辑。

@tool
extends EditorDock

const STAGE_SCRIPT := preload("res://addons/card_preview/card_stage.gd")

const DEFAULT_MIN_SIZE := Vector2(260, 440)

var _stage: Control


## 由插件在 add_dock 之前调用。标签页属性要在入树前设好，否则标签页先按默认值建出来。
func setup(editor: Object) -> void:
	title = "卡牌"
	layout_key = "card_preview"
	default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	custom_minimum_size = DEFAULT_MIN_SIZE
	_stage = STAGE_SCRIPT.new()
	_stage.setup(editor)
	add_child(_stage)


## 重新判定当前选中的卡。由插件在选中变化时调用。
func refresh_now() -> void:
	if _stage != null:
		_stage.refresh_now()

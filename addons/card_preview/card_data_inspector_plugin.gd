## 把卡面预览插进 CardData 的检查器
##
## _parse_begin 会在属性列表最前面插一个自定义控件，所以预览出现在最上方，下面才是
## 卡牌标识、卡牌名这些字段。选中任何 CardData（打开 .tres、新建资源、在文件系统
## 里点选）都会走这里。

@tool
extends EditorInspectorPlugin

const PREVIEW_SCRIPT := preload("res://addons/card_preview/card_data_preview.gd")


func _can_handle(object: Object) -> bool:
	return object is CardData


func _parse_begin(object: Object) -> void:
	var preview: Control = PREVIEW_SCRIPT.new()
	# 控件的 _ready 还没跑，此时 bind 只记住目标；入了检查器由 _ready 补渲染。
	preview.bind(object)
	add_custom_control(preview)

class_name HoverTip
extends PanelContainer

## HUD 与背包共用的悬停浮层：深色底 + 细金边，文字自动换行。
## 系统 tooltip 在战斗里不稳定（会被全屏控件吞掉），统一用这个。

const FONT_SIZE := 15
const MIN_WIDTH := 250.0
const VIEW_MARGIN := 8.0

var _anchor_rect := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var style := CommonUiSkin.panel("tooltip", Vector4(8, 8, 8, 8))
	add_theme_stylebox_override("panel", style)
	var label := RichTextLabel.new()
	CommonUiSkin.setup_relic_text(label, FONT_SIZE)
	label.name = "TipLabel"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(MIN_WIDTH, 0)
	label.scroll_active = false
	label.threaded = false
	label.focus_mode = Control.FOCUS_NONE
	label.add_theme_color_override("default_color", Color(0.94, 0.9, 0.82))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	get_viewport().size_changed.connect(_layout_tip)


func show_for(anchor: Control, text: String, rich: bool = false) -> void:
	if not is_instance_valid(anchor):
		return
	show_at_rect(anchor.get_global_rect(), text, rich)


## 按一块全局矩形定位，浮层贴在它下沿；下方放不下就翻到上沿。
## 典籍格子是斜的四边形，没有对应的 Control 可当锚点，走这个。
func show_at_rect(rect: Rect2, text: String, rich: bool = false) -> void:
	var label := get_node_or_null("TipLabel") as RichTextLabel
	if label == null:
		return
	# 仅 RelicFragmentData 生成的已转义说明主动开启 BBCode；普通物品保持原文。
	label.bbcode_enabled = rich
	label.text = text
	_anchor_rect = rect
	visible = true
	_layout_tip()
	# 容器会延后排版，再用最新锚点校准一次，避免沿用上一条说明的尺寸。
	_layout_tip.call_deferred()


func _layout_tip() -> void:
	if not visible:
		return
	var label := get_node_or_null("TipLabel") as RichTextLabel
	if label == null:
		return
	var view := get_viewport_rect().size
	var padding := get_theme_stylebox("panel").get_minimum_size()
	var width := minf(MIN_WIDTH, maxf(1.0, view.x - VIEW_MARGIN * 2.0 - padding.x))
	# 固定换行宽度后测量富文本高度，不让标签的最小宽度被长说明撑开。
	label.custom_minimum_size = Vector2(width, 0)
	label.size = Vector2(width, maxf(1.0, label.size.y))
	var height := minf(float(label.get_content_height()),
		maxf(1.0, view.y - VIEW_MARGIN * 2.0 - padding.y))
	label.custom_minimum_size = Vector2(width, height)
	size = Vector2(width, height) + padding
	var x := clampf(_anchor_rect.position.x, VIEW_MARGIN,
		maxf(VIEW_MARGIN, view.x - VIEW_MARGIN - size.x))
	var y := _anchor_rect.end.y + 6.0
	if y + size.y > view.y - VIEW_MARGIN:
		y = _anchor_rect.position.y - size.y - 6.0
	y = clampf(y, VIEW_MARGIN, maxf(VIEW_MARGIN, view.y - VIEW_MARGIN - size.y))
	global_position = Vector2(x, y)


func hide_tip() -> void:
	visible = false

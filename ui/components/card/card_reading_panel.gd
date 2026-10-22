class_name CardReadingPanel
extends PanelContainer
## 卡面旁的完整效果阅读区；只读展示，不改变卡牌文案或选择行为。
const PANEL_WIDTH := 460.0
const BODY_SIZE := 22
const MARGIN := 24.0
const GAP := 14.0
var body: CardDescriptionLabel
var _title: Label
var _column: VBoxContainer
var _effect := ""
var _enchantments := ""
var _layout_width := -1.0
var _layout_height := -1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", CommonUiSkin.panel("small", Vector4.ONE * MARGIN))
	_column = VBoxContainer.new()
	_column.mouse_filter = Control.MOUSE_FILTER_PASS
	_column.add_theme_constant_override("separation", 12)
	add_child(_column)
	_title = Label.new()
	_title.clip_text = true
	_title.add_theme_font_override("font", CommonUiSkin.relic_bold_font())
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", Color("f5d591"))
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_title)
	var caption := Label.new()
	caption.text = "完整效果"
	caption.add_theme_font_size_override("font_size", 18)
	caption.add_theme_color_override("font_color", Color("b7a58b"))
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(caption)
	var rule := HSeparator.new()
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(rule)
	body = CardDescriptionLabel.new()
	body.clip_contents = true
	body.clip_text = true
	body.add_theme_font_override("font", CommonUiSkin.relic_font())
	body.add_theme_font_size_override("font_size", BODY_SIZE)
	body.add_theme_color_override("font_color", CommonUiSkin.TEXT)
	body.add_theme_constant_override("line_spacing", 5)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_column.add_child(body)

func set_card_text(title: String, effect: String, enchantment_text: String = "") -> void:
	if _title.text == title and _effect == effect and _enchantments == enchantment_text: return
	_title.text = title
	_effect = effect
	_enchantments = enchantment_text
	body.reset_scroll()
	_layout_width = -1.0

func place_next_to(card_rect: Rect2, viewport_rect: Rect2) -> void:
	var available := viewport_rect.size - Vector2.ONE * GAP * 2.0
	var width := minf(PANEL_WIDTH, available.x)
	var max_height := minf(760.0, available.y)
	if width != _layout_width or max_height != _layout_height:
		_reflow(width, max_height)
	var x := card_rect.end.x + GAP
	if x + size.x > viewport_rect.end.x - GAP:
		x = card_rect.position.x - size.x - GAP
	global_position = Vector2(clampf(x, viewport_rect.position.x + GAP, maxf(viewport_rect.position.x + GAP, viewport_rect.end.x - size.x - GAP)),
		clampf(card_rect.position.y, viewport_rect.position.y + GAP, maxf(viewport_rect.position.y + GAP, viewport_rect.end.y - size.y - GAP)))

func _reflow(width: float, max_height: float) -> void:
	_layout_width = width
	_layout_height = max_height
	var content_width := maxf(1, width - MARGIN * 2.0)
	var raw := _effect
	if not _enchantments.is_empty(): raw += "\n\n" + _enchantments
	var wrapped := CardText.wrap_to_width(raw, body.get_theme_font("font"), BODY_SIZE, content_width - 10.0)
	body.set_content(wrapped, 1)
	body.get_line_count()
	var row_height := 1.0
	for row in body.get_line_count(): row_height = maxf(row_height, body.get_line_height(row))
	var spacing := float(body.get_theme_constant("line_spacing"))
	var rows := wrapped.split("\n").size()
	# 标题、分隔和内边距单独计量；正文只在屏幕放不下时滚动。
	var overhead := MARGIN * 2.0 + 12 * (_column.get_child_count() - 1)
	for child: Control in _column.get_children():
		if child != body: overhead += child.get_combined_minimum_size().y
	var room := maxf(row_height, max_height - overhead)
	var full_height := rows * row_height + maxi(0, rows - 1) * spacing
	var visible_rows := rows
	var height := full_height
	if full_height > room:
		visible_rows = maxi(1, floori((room - row_height * 0.5 + spacing) / (row_height + spacing)))
		height = visible_rows * (row_height + spacing) - spacing + row_height * 0.5
	body.set_content(wrapped, visible_rows)
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	body.custom_minimum_size = Vector2(content_width, height)
	custom_minimum_size = Vector2(width, 0)
	size = Vector2(width, overhead + height)

func contains_pointer() -> bool:
	return is_visible_in_tree() and (owns_hover(self) or body.is_processing_input())

## 与真实 GUI 命中保持一致，也避免被其他弹层遮住时仍按矩形保活。
static func owns_hover(control: Control) -> bool:
	if not is_instance_valid(control) or not control.is_visible_in_tree(): return false
	var hovered := control.get_viewport().gui_get_hovered_control()
	return is_instance_valid(hovered) and (hovered == control or control.is_ancestor_of(hovered))

static func enchantment_text(card: Dictionary) -> String:
	return CardEnchantments.describe(card) if bool(card.get("one_shot", false)) or not card.get("enchantments", []).is_empty() else ""

static func card_bounds(view: Control) -> Rect2:
	var transform := view.get_global_transform_with_canvas()
	var rect := Rect2(transform * Vector2.ZERO, Vector2.ZERO)
	for corner: Vector2 in [Vector2(view.size.x, 0), view.size, Vector2(0, view.size.y)]:
		rect = rect.expand(transform * corner)
	return rect

extends CanvasLayer
## 事件对象共用悬停层，使用真实 CardView 和既有 HoverTip；不接管任何输入。
const References = preload("res://ui/events/event_text_references.gd")
const CARD_SCENE = preload("res://ui/components/card/card_view.tscn")
const CARD_SCALE := 0.62
var _owner_control: Control
var _card_root: Control
var _card: CardView
var _badge: Label
var _tip: HoverTip
var _definitions: Dictionary = {}

func _ready() -> void:
	layer = 120
	_card_root = Control.new()
	_card_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card_root)
	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 21)
	_badge.add_theme_color_override("font_outline_color", Color(0.04, 0.025, 0.02, 0.95))
	_badge.add_theme_constant_override("outline_size", 4)
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_root.add_child(_badge)
	_card = CARD_SCENE.instantiate()
	_card.position.y = 30
	_card.scale = Vector2.ONE * CARD_SCALE
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_root.add_child(_card)
	_tip = HoverTip.new()
	add_child(_tip)
	var text := _tip.get_node("TipLabel") as RichTextLabel
	text.add_theme_font_size_override("normal_font_size", 20)
	hide_preview()

func show_for(reference: Dictionary, anchor: Control) -> void:
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree() or reference.is_empty(): return
	hide_preview()
	_owner_control = anchor
	if reference.get("kind") == "card":
		if _definitions.is_empty(): _definitions = FormalCardCatalog.load_definitions().cards
		var id := str(reference.get("id", ""))
		if not _definitions.has(id): hide_preview(); return
		_card.set_card(_definitions[id])
		_card.set_enchantments(reference.get("copy", {}))
		_card.apply_compact_layout(CARD_SCALE)
		var negative := id in References.NEGATIVE_CARDS
		_badge.text = "特殊卡牌 · 含负面效果" if negative else "卡牌预览"
		_badge.add_theme_color_override("font_color", Color(References.RED) if negative else CommonUiSkin.TEXT)
		_card_root.show()
		_position_card()
	else:
		var text := References.description(reference)
		if text.is_empty(): hide_preview(); return
		_tip.show_for(anchor, text, reference.get("kind") == "fragment")
	set_process(true)

func hide_for(anchor: Control) -> void:
	if _owner_control == anchor: hide_preview()

func hide_preview() -> void:
	_owner_control = null
	if is_instance_valid(_card_root): _card_root.hide()
	if is_instance_valid(_tip): _tip.hide_tip()
	set_process(false)

func is_showing() -> bool:
	return is_instance_valid(_owner_control) and (_card_root.visible or _tip.visible)

func _process(_delta: float) -> void:
	if not is_instance_valid(_owner_control) or not _owner_control.is_visible_in_tree() or SceneTransition.is_loading():
		hide_preview()
		return
	if _card_root.visible: _position_card()

func _position_card() -> void:
	var anchor := _owner_control.get_global_rect()
	var bounds := get_viewport().get_visible_rect().size
	var dimensions := Vector2(480, 818) * CARD_SCALE + Vector2(0, 30)
	var x := anchor.position.x - dimensions.x - 20
	if x < 12: x = anchor.end.x + 20
	_card_root.position = Vector2(clampf(x, 12, maxf(12, bounds.x - dimensions.x - 12)),
		clampf(anchor.position.y, 12, maxf(12, bounds.y - dimensions.y - 12)))

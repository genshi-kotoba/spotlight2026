class_name ShopPopup
extends LootPopup
## 商店与选牌附魔共用一个模态层；确认目标后原子扣款，取消不占库存。
const SHOP_BACKGROUND := "res://assets/events/EVBG-013.png"
const SANDBOX_RESOURCES := preload("res://systems/testing/sandbox_resources.gd")
var request: Dictionary = {}
var _enchant_index := -1
var close_handler: Callable
var _card_definitions: Dictionary = {}

func _ready() -> void:
	super._ready()
	var background_texture := load(SHOP_BACKGROUND) as Texture2D
	if background_texture == null:
		return
	var background := TextureRect.new()
	background.name = "ShopBackground"
	background.texture = background_texture
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(background)
	_root.move_child(background, 0)
	# 沿用 main 的模态遮罩/附魔选牌事务，仅替换商店美术。
	_shade.color = Color(0, 0, 0, 0.20)
	_panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("event", Vector4(36, 28, 36, 28)))

func show_shop(value: Dictionary) -> void:
	request = value.duplicate(true)
	_run = SaveGateway.current_run()
	_mode = "shop"
	var error := RunShop.open(_run, request)
	if error != OK:
		_heading.text = "商店暂时无法打开"
		_description.text = "保存或节点校验失败，请关闭后重试。错误码：%d" % error
		_refresh_button.hide()
		_continue_button.text = "返回地图"
		return
	_render()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("ui_cancel"):
			_continue()
		get_viewport().set_input_as_handled()

func _render() -> void:
	for child: Node in _options.get_children():
		_options.remove_child(child)
		child.queue_free()
	_error.text = ""
	_refresh_button.hide()
	var shop := RunShop.shelf(_run, request)
	if shop.is_empty():
		return
	_heading.text = "第 %d 层商店　　银币：%s" % [int(shop.floor), SANDBOX_RESOURCES.text(_run.gold, _run)]
	_description.text = "每家店独立备货，售出不补货。附魔每张牌最多两种；确认选牌后扣费。"
	_continue_button.text = "取消选牌" if _enchant_index >= 0 else "返回地图"
	_continue_button.disabled = false
	if _enchant_index >= 0:
		_render_targets(shop)
		return
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	_options.add_child(row)
	for index in shop.cards.size():
		var offer: Dictionary = shop.cards[index]
		var column := VBoxContainer.new()
		row.add_child(column)
		_card(column, {"card_id": str(offer.id)}, 0.29)
		var price := _label("原价 %d" % int(offer.base_price), 19)
		price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(price)
		var buy := _button("已售罄" if offer.sold else ("%d 折 · " % int(offer.discount) if int(offer.discount) < 10 else "") + "%d 银币" % int(offer.price))
		buy.name = "BuyCard_%d" % index
		buy.custom_minimum_size = Vector2(155, 52)
		buy.add_theme_font_size_override("font_size", 19)
		buy.disabled = bool(offer.sold) or _run.gold < int(offer.price)
		buy.pressed.connect(_buy_card.bind(index))
		column.add_child(buy)
	var enchant_row := HBoxContainer.new()
	enchant_row.alignment = BoxContainer.ALIGNMENT_CENTER
	enchant_row.add_theme_constant_override("separation", 20)
	_options.add_child(_label("卡牌附魔", 26))
	_options.add_child(enchant_row)
	for index in shop.enchantments.size():
		var offer: Dictionary = shop.enchantments[index]
		var data: Dictionary = CardEnchantments.DEFINITIONS[offer.id]
		var column := VBoxContainer.new()
		column.custom_minimum_size.x = 330
		enchant_row.add_child(column)
		var buy := _button(("已售罄 · " if offer.sold else "") + "%s　%d 银币" % [data.name, int(offer.price)])
		buy.text = str(data.get("symbol", "")) + " " + buy.text
		buy.name = "BuyEnchant_%d" % index
		buy.custom_minimum_size = Vector2(330, 80)
		buy.tooltip_text = str(data.text)
		buy.disabled = bool(offer.sold) or _run.gold < int(offer.price) or not _has_target(str(offer.id))
		buy.pressed.connect(_select_enchantment.bind(index))
		column.add_child(buy)
		var description := _label(str(data.text), 19)
		description.custom_minimum_size.x = 330
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(description)

func _has_target(id: String) -> bool:
	_run.ensure_deck_cards()
	for card: Dictionary in _run.deck_cards:
		if CardEnchantments.can_apply(card, id):
			return true
	return false

func _render_targets(shop: Dictionary) -> void:
	var offer: Dictionary = shop.enchantments[_enchant_index]
	var data: Dictionary = CardEnchantments.DEFINITIONS[offer.id]
	_description.text = "选择一张牌附上「%s」：%s\n确认后花费 %d 银币；同名卡按副本分别选择。" % [data.name, data.text, int(offer.price)]
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 32)
	grid.add_theme_constant_override("v_separation", 20)
	scroll.add_child(grid)
	_run.ensure_deck_cards()
	for index in _run.deck_cards.size():
		var card: Dictionary = _run.deck_cards[index]
		if not CardEnchantments.can_apply(card, str(offer.id)):
			continue
		var column := VBoxContainer.new()
		grid.add_child(column)
		_card(column, card, 0.29, _enchant_card.bind(str(card.copy_id)))
		var choose := _button("选择第 %d 张（%d/2）" % [index + 1, card.enchantments.size()])
		choose.custom_minimum_size = Vector2(155, 52)
		choose.add_theme_font_size_override("font_size", 18)
		choose.name = "EnchantTarget_%d" % index
		choose.tooltip_text = CardEnchantments.describe(card)
		choose.pressed.connect(_enchant_card.bind(str(card.copy_id)))
		column.add_child(choose)

func _card(parent: Control, card: Dictionary, factor: float, selected: Callable = Callable()) -> void:
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(480, 818) * factor
	parent.add_child(slot)
	var view: CardView = CARD_SCENE.instantiate()
	view.scale = Vector2.ONE * factor
	view.size = Vector2(480, 818)
	if _card_definitions.is_empty():
		_card_definitions = FormalCardCatalog.load_definitions().cards
	view.set_card(_card_definitions[str(card.card_id)])
	view.set_enchantments(card)
	view.tooltip_text = CardEnchantments.describe(card)
	slot.add_child(view)
	if selected.is_valid():
		var hit := Button.new()
		hit.flat = true
		hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for state: String in ["normal", "hover", "pressed", "focus"]:
			hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		hit.tooltip_text = CardEnchantments.describe(card)
		hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		hit.pressed.connect(selected)
		slot.add_child(hit)

func _buy_card(index: int) -> void:
	if _working:
		return
	_working = true
	var error := RunShop.buy_card(_run, request, index)
	_working = false
	_render()
	if error != OK:
		_error.text = "购买未完成，银币与库存未变。错误码：%d" % error

func _select_enchantment(index: int) -> void:
	_enchant_index = index
	_render()

func _enchant_card(copy_id: String) -> void:
	if _working:
		return
	_working = true
	var error := RunShop.buy_enchantment(_run, request, _enchant_index, copy_id)
	_working = false
	if error == OK:
		_enchant_index = -1
	_render()
	if error != OK:
		_error.text = "附魔未完成，未扣费。可能已满、已有该附魔或存档失败。"

func _continue() -> void:
	if _enchant_index >= 0:
		_enchant_index = -1
		_render()
	else:
		var error: Error = close_handler.call() if close_handler.is_valid() else OK
		if error == OK:
			_finish()
		else:
			_error.text = "离店进度保存失败，请重试。错误码：%d" % error

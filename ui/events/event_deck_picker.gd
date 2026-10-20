extends CanvasLayer
## 素材合成的牌组选择视图；仅发送副本 ID，不直接改牌组或存档。
signal selection_confirmed(copy_ids: Array[String])
signal dismissed(copy_ids: Array[String])

const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
const CARD_SCALE := 0.36
const REQUIRED_COUNT := 2
const GRID_GAP := 24
var _selected: Array[String] = []
var _hits: Dictionary = {}
var _markers: Dictionary = {}
var _root: Control
var _grid: GridContainer
var _scroll: ScrollContainer
var _status: Label
var _confirm_button: Button
var _submitting := false

func _ready() -> void:
	layer = 90
	_root = Control.new()
	_root.name = "SynthesisDeckModal"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	CatalogUi.install_theme(_root)
	var shade := ColorRect.new()
	shade.name = "ModalShade"
	shade.color = Color(0.015, 0.012, 0.01, 0.8)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(shade)
	var panel := PanelContainer.new()
	panel.name = "DeckPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.anchor_left = 0.08
	panel.anchor_right = 0.92
	panel.anchor_top = 0.06
	panel.anchor_bottom = 0.94
	panel.add_theme_stylebox_override("panel", CommonUiSkin.panel("panel", Vector4(32, 24, 32, 24)))
	_root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := _label("素材合成 · 从牌组选择两张卡", 32)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.name = "CloseDeckPicker"
	close.text = "关闭选牌"
	CommonUiSkin.style_navigation_button(close, "close", true)
	close.pressed.connect(_dismiss)
	header.add_child(close)
	_status = _label("", 23)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.name = "DeckScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scroll)
	_grid = GridContainer.new()
	_grid.name = "EntireDeck"
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", GRID_GAP)
	_grid.add_theme_constant_override("v_separation", GRID_GAP)
	_scroll.add_child(_grid)
	_scroll.resized.connect(_layout_columns)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 24)
	column.add_child(footer)
	var note := _label("点击卡牌选中／取消；同名牌按副本分别选择。\n确认素材后选择合成结果，完成前不会消耗卡牌。", 20)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(note)
	_confirm_button = Button.new()
	_confirm_button.name = "ConfirmSynthesisCards"
	_confirm_button.custom_minimum_size = Vector2(260, 64)
	CommonUiSkin.style_button(_confirm_button)
	_confirm_button.pressed.connect(_submit)
	footer.add_child(_confirm_button)
	_refresh_selection()

func show_deck(copies: Array[Dictionary], selected: Array[String]) -> void:
	_selected.clear()
	_hits.clear()
	_markers.clear()
	_submitting = false
	for child: Node in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	var definitions: Dictionary = FormalCardCatalog.load_definitions().cards
	for index in copies.size():
		var card: Dictionary = copies[index]
		var copy_id := str(card.copy_id)
		if selected.has(copy_id) and _selected.size() < REQUIRED_COUNT and not _selected.has(copy_id):
			_selected.append(copy_id)
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 8)
		_grid.add_child(column)
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(480, 818) * CARD_SCALE
		column.add_child(slot)
		var view: CardView = CARD_SCENE.instantiate()
		view.size = Vector2(480, 818)
		view.scale = Vector2.ONE * CARD_SCALE
		if definitions.has(str(card.card_id)):
			view.set_card(definitions[str(card.card_id)])
		else:
			view.set_texts("暂无", "暂无", "")
		view.set_enchantments(card)
		view.apply_compact_layout(CARD_SCALE)
		slot.add_child(view)
		var hit := Button.new()
		hit.name = "SelectCard_%d" % index
		hit.toggle_mode = true
		hit.set_meta("copy_id", copy_id)
		hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hit.tooltip_text = "第 %d 张 · %s\n%s" % [index + 1, TextCatalog.entry("cards", str(card.card_id)).get("name", "暂无"), CardEnchantments.describe(card)]
		hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_style_card_hit(hit)
		hit.pressed.connect(_toggle_card.bind(copy_id))
		slot.add_child(hit)
		_hits[copy_id] = hit
		var marker := _label("", 20)
		marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(marker)
		_markers[copy_id] = marker
	_refresh_selection()
	_layout_columns.call_deferred()

func _style_card_hit(button: Button) -> void:
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 0.85, 0.45, 0.08) if state == "hover" else Color.TRANSPARENT
		style.border_color = Color("f1d58e")
		style.set_border_width_all(3 if state in ["pressed", "hover_pressed", "focus"] else 0)
		style.set_corner_radius_all(8)
		button.add_theme_stylebox_override(state, style)

func _layout_columns() -> void:
	_grid.columns = maxi(1, floori((_scroll.size.x - 18 + GRID_GAP) / (480 * CARD_SCALE + GRID_GAP)))

func _toggle_card(copy_id: String) -> void:
	if _submitting: return
	if _selected.has(copy_id):
		_selected.erase(copy_id)
	elif _selected.size() < REQUIRED_COUNT:
		_selected.append(copy_id)
	_refresh_selection()

func _refresh_selection() -> void:
	_status.text = "全部牌组：%d 张　　已选择 %d / %d 张" % [_hits.size(), _selected.size(), REQUIRED_COUNT]
	_confirm_button.text = "确认素材（%d / %d）" % [_selected.size(), REQUIRED_COUNT]
	_confirm_button.disabled = _submitting or _selected.size() != REQUIRED_COUNT
	for copy_id: String in _hits:
		_hits[copy_id].set_pressed_no_signal(_selected.has(copy_id))
		_markers[copy_id].text = "✓ 已选择" if _selected.has(copy_id) else "点击选择"

func show_error(message: String) -> void:
	_submitting = false
	_refresh_selection()
	_status.text += "\n" + message

func _submit() -> void:
	if _submitting or _selected.size() != REQUIRED_COUNT: return
	_submitting = true
	_refresh_selection()
	selection_confirmed.emit(_selected.duplicate())

func _dismiss() -> void:
	if not _submitting: dismissed.emit(_selected.duplicate())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.is_action_pressed("ui_cancel"):
		_dismiss()
		get_viewport().set_input_as_handled()

func _label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	return label

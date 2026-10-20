extends Control
## 单个召唤物的常驻视图；只显示当前事件快照，生命动画复用主战场实现。
signal target_pressed(enemy_id: String)
var enemy_id := ""
var portrait: TextureRect
var health_bar: Control
var health_number: Label
var block_shield: Control
var buff_row: HBoxContainer
var hit: Button
var intent: Control
var intent_badge: TextureRect
var intent_ring: TextureRect
var intent_value: Label
var _intent_kind := ""
var _name: Label
var _dead := false
var _initialized := false
var _death_tween: Tween

func setup(id: String, bar_template: Control, badge_template: TextureRect,
		ring_template: TextureRect, value_template: Label) -> void:
	enemy_id = id
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait = TextureRect.new()
	portrait.name = "Portrait"
	portrait.z_index = -2
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(portrait)
	health_bar = bar_template.duplicate() as Control
	health_bar.name = "HealthBar"
	health_bar.z_index = 2
	for key: String in ["ratio", "tween"]:
		if health_bar.get_node("Fill").has_meta(key): health_bar.get_node("Fill").remove_meta(key)
	add_child(health_bar)
	health_number = _label("HealthNumber", 18)
	_name = _label("Name", 21)
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	block_shield = load("res://ui/battle/block_shield.gd").new()
	block_shield.z_index = 3
	block_shield.size = Vector2(36, 40)
	block_shield.set("number_px", 14)
	add_child(block_shield)
	buff_row = HBoxContainer.new()
	buff_row.z_index = 3
	buff_row.add_theme_constant_override("separation", 3)
	add_child(buff_row)
	intent = Control.new()
	intent.name = "ActionIntent"
	intent.z_index = 3
	intent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intent.size = Vector2(124, 128)
	intent.scale = Vector2.ONE * 0.48
	add_child(intent)
	intent_badge = badge_template.duplicate() as TextureRect
	intent_badge.position = Vector2.ZERO
	intent.add_child(intent_badge)
	intent_ring = ring_template.duplicate() as TextureRect
	intent_ring.position = Vector2(64, 68)
	intent.add_child(intent_ring)
	intent_value = value_template.duplicate() as Label
	intent_value.position = Vector2(64, 68)
	intent_value.add_theme_font_size_override("font_size", 32)
	intent.add_child(intent_value)
	hit = Button.new()
	hit.name = "TargetPortrait"
	hit.toggle_mode = true
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.draw_center = false
		style.border_color = Color(0.95, 0.79, 0.44, 0.75)
		style.set_border_width_all(2 if state in ["hover", "pressed", "hover_pressed", "focus"] else 0)
		style.set_corner_radius_all(12)
		hit.add_theme_stylebox_override(state, style)
	hit.pressed.connect(func(): target_pressed.emit(enemy_id))
	add_child(hit)

func layout_at(rect: Rect2) -> void:
	position = rect.position
	size = rect.size
	portrait.size = size
	portrait.set_meta("feedback_home", Vector2.ZERO)
	hit.size = size
	# 为缩小的意图图标留出空间，避免压住相邻随从的短血条。
	var intent_width := intent.size.x * intent.scale.x + 4.0
	var width := minf(maxf(size.x - intent_width, 32.0), 280.0)
	var left := (size.x - width - intent_width) * 0.5
	health_bar.position = Vector2(left, -38)
	health_bar.scale = Vector2.ONE * (width / 959.5)
	health_number.position = Vector2(left, -35)
	health_number.size = Vector2(width, 26)
	_name.position = Vector2(0, -72)
	_name.size = Vector2(size.x, 30)
	block_shield.position = Vector2(left + width - 12, -43)
	buff_row.position = Vector2(left, -7)
	intent.position = Vector2(left + width + 4.0, -60)

func show_snapshot(enemy: Dictionary, selected: bool, interactive: bool) -> void:
	var path := str(enemy.get("art_path", ""))
	if not path.is_empty(): portrait.texture = TextCatalogService.art_texture(path)
	_name.text = ("▶ " if selected else "") + str(enemy.get("name", "召唤物")) + (" · 嘲讽" if bool(enemy.get("taunt", false)) else "")
	hit.set_pressed_no_signal(selected)
	hit.disabled = not interactive or int(enemy.get("health", 0)) <= 0
	hit.tooltip_text = str(enemy.get("name", "召唤物")) + " · 点击选择攻击目标"
	_show_intent(enemy)
	var dead := int(enemy.get("health", 0)) <= 0
	if not _initialized:
		visible = not dead
	elif dead and not _dead:
		# 先完成 0.3 秒血条归零，再淡出；同目标刷新不能重启动画。
		_death_tween = create_tween()
		_death_tween.tween_interval(0.3)
		_death_tween.tween_property(self, "modulate:a", 0.0, 0.15)
		_death_tween.tween_callback(hide)
	elif not dead and _dead:
		if _death_tween != null and _death_tween.is_valid(): _death_tween.kill()
		modulate.a = 1.0
		show()
	_dead = dead
	_initialized = true

func hud_bounds() -> Rect2:
	var bar_bounds := Rect2(position + Vector2(0, -72), Vector2(size.x + 28, 90))
	return bar_bounds.merge(Rect2(position + intent.position, intent.size * intent.scale))

func _show_intent(enemy: Dictionary) -> void:
	# 与本体读取同一份事件快照中的 actions，不为表现额外抽取战斗随机数。
	var actions: Array = enemy.get("actions", [])
	var action: Dictionary = actions[0] if not actions.is_empty() else {}
	var kind := "攻击" if action.has("damage") else ("防御" if action.has("block") else "特殊")
	if kind != _intent_kind:
		var badge := AtlasTexture.new()
		badge.atlas = TextCatalogService.art_texture("res://assets/ui/UI-016/%s.png" % kind)
		badge.region = Rect2(104, 125, 847, 863)
		intent_badge.texture = badge
		_intent_kind = kind
	intent_value.text = str(action.damage) if action.has("damage") else (str(action.block) if action.has("block") else "—")
	intent.visible = int(enemy.get("health", 0)) > 0

func _label(node_name: String, font_size: int) -> Label:
	var label := Label.new()
	label.name = node_name
	label.z_index = 3
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color("ffe4d6"))
	label.add_theme_color_override("font_outline_color", Color("19120f"))
	label.add_theme_constant_override("outline_size", 4)
	add_child(label)
	return label

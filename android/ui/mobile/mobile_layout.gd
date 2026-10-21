extends RefCounted
## 移动端布局集中在此处；1920×1080 保底，横向扩展使用手机额外宽度。
const HUD_SCALE := 1.35

static func setup_battle(scene: Control) -> void:
	# 手机只保留各物品格自己的底框。旧独立大底板不承担输入/数据，
	# 安全区域适配时可能盖到左上头像与血条，直接移除这层冗余装饰。
	scene.get_node("背包底板").hide()
	for path in ["PlayerPortrait", "PlayerHPBar", "PlayerHPNum", "PlayerBuffRow", "PlayerStatus",
			"BackpackSlots", "Coin", "Elixir", "RelicBook", "PlayerBlockShield", "RelicHints"]:
		var node := scene.get_node_or_null(NodePath(path)) as Control
		if node != null:
			node.position *= HUD_SCALE
			node.scale *= HUD_SCALE
			node.set_meta("mobile_hud_position", node.position)
	for path in ["DrawPile", "DiscardPile"]:
		scene.get_node(NodePath(path)).scale = Vector2.ONE * 1.3
	scene.resized.connect(layout_battle.bind(scene))
	layout_battle(scene)

static func layout_battle(scene: Control) -> void:
	var width := scene.get_viewport_rect().size.x
	var safe := safe_rect(scene)
	var height := safe.end.y
	var right := safe.end.x - 28.0
	for child in scene.get_children():
		if child is Control and child.has_meta("mobile_hud_position"):
			child.position = Vector2(child.get_meta("mobile_hud_position")) + safe.position
	var play_left := right - 204.0
	_set_rect(scene.get_node("PlayScroll"), Rect2(play_left, safe.position.y + 142, 204, height - safe.position.y - 345))
	_set_rect(scene.get_node("HandScroll"), Rect2(safe.position.x + 310, height - 446, maxf(1000, play_left - 500 - safe.position.x), 440))
	_set_rect(scene.get_node("出牌计数底板"), Rect2(play_left + 68, 96, 136, 42))
	_set_rect(scene.get_node("PlayCountLabel"), Rect2(play_left + 68, 99, 136, 38))
	_set_rect(scene.get_node("PlayButton"), Rect2(play_left, height - 183, 204, 72))
	_set_rect(scene.get_node("CancelButton"), Rect2(play_left, height - 105, 204, 72))
	scene.get_node("PlayButton").add_theme_font_size_override("font_size", 28)
	scene.get_node("CancelButton").add_theme_font_size_override("font_size", 28)
	scene.get_node("DrawPile").position = Vector2(safe.position.x + 238, height - 183)
	scene.get_node("DiscardPile").position = Vector2(play_left - 102, height - 183)
	# 新意图界面移除了旧总伤害标签，兼容仍保留它的测试场景。
	var damage_preview := scene.get_node_or_null("DamagePreview") as Control
	if damage_preview != null:
		damage_preview.position = Vector2(play_left - 195, height - 165)
	# 怪物本体保持原尺寸，只把怪物展示区在扩展后的战场居中。
	scene.get_node("EnemyRack").position.x = maxf(0, (width - 1920) * 0.42)
	scene.enemy_rack.interaction_bottom = scene.hand_scroll.global_position.y - 8.0
	for slot in scene.enemy_rack.slots:
		slot.interaction_bottom = scene.enemy_rack.interaction_bottom
	_set_rect(scene.get_node("TurnLabel"), Rect2(0, 4, width, 40))
	_set_rect(scene.get_node("DiscardShade"), Rect2(Vector2.ZERO, scene.get_viewport_rect().size))
	var settings := scene.get_node_or_null("SettingsButton") as Control
	if settings != null:
		settings.position = Vector2(right - 72, safe.position.y + 14)
		settings.size = Vector2(72, 72)
	var hint := scene.get_node_or_null("HintLabel") as Control
	if hint != null: hint.mouse_filter = Control.MOUSE_FILTER_IGNORE

static func safe_rect(node: CanvasItem) -> Rect2:
	var viewport := node.get_viewport_rect().size
	if not OS.has_feature("android"): return Rect2(Vector2.ZERO, viewport)
	var safe := Rect2(DisplayServer.get_display_safe_area())
	var screen := Vector2(DisplayServer.screen_get_size())
	if screen.x <= 0 or screen.y <= 0 or not safe.has_area(): return Rect2(Vector2.ZERO, viewport)
	return Rect2(safe.position / screen * viewport, safe.size / screen * viewport)

static func _set_rect(node: Control, rect: Rect2) -> void:
	node.position = rect.position
	node.size = rect.size

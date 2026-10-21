extends Node
var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	print(("PASS " if ok else "FAIL ") + label)
	if not ok: failures += 1

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var source := load(ItemIcon.CARD_PACK_PATH) as Texture2D
	check("card pack texture loads", source != null and source.get_size() == Vector2(556, 712))
	for kind: String in ["common_pack", "rare_pack"]:
		for side: float in [26.0, 46.0]:
			var icon := ItemIcon.make_item({"item_id":"test-" + kind, "kind":kind}, side, ItemIcon.FALLBACK_PATH)
			check(kind + " uses supplied pack art at size " + str(side), icon.texture == source and icon.size == Vector2(side, side))
			check(kind + " preserves aspect and does not intercept input", icon.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED and icon.mouse_filter == Control.MOUSE_FILTER_IGNORE)
			icon.free()
	for alias: String in ItemIcon.CARD_PACK_NAMES:
		var icon := ItemIcon.make_item(alias, 26)
		check("legacy pack name " + alias, icon.texture == source)
		icon.free()
	for kind: String in ["fragment", "fragment_pack", "enchantment_book", "potion"]:
		var icon := ItemIcon.make_item({"kind":kind}, 26)
		check("other item unchanged: " + kind, icon.texture != null and icon.texture != source)
		icon.free()
	var items: Array = [{"item_id":"test-common", "kind":"common_pack"}, {"item_id":"test-rare", "kind":"rare_pack"}]
	var hud := RunStatusPanel.new()
	add_child(hud)
	hud.set_items(items)
	for index in 2:
		var icon := hud._slots[index].get_node("ItemArt/ItemIcon") as TextureRect
		check("map HUD slot " + str(index) + " uses pack art", icon != null and icon.texture == source)
	var run := RunStateMachine.new()
	run.items = items
	var overlay := RunMenuOverlay.new()
	add_child(overlay)
	for index in 2:
		var slot := overlay._item_slot(run, index, index)
		var icons: Array = slot.get_children().filter(func(node: Node): return node is ItemIcon)
		check("inventory/settlement slot " + str(index) + " uses pack art", icons.size() == 1 and icons[0].texture == source)
		slot.free()
	overlay.queue_free()
	run.free()
	hud.queue_free()
	print("CARD_PACK_ICON_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

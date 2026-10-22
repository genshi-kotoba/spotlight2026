extends "res://ui/battle/battle_test_scene.gd"

## 正式牌测试入口。分组仅改变测试牌组，不改正式存档与主菜单默认牌组。
func _ready() -> void:
	var group := int(get_tree().root.get_meta("formal_card_test_group", 0))
	if group > 0:
		deck_card_ids.clear()
		for number in range((group - 1) * 10 + 1, mini(group * 10 + 1, 71)):
			deck_card_ids.append(str(number))
		initial_draw_count = deck_card_ids.size()
	var chooser := OptionButton.new()
	chooser.name = "DeckGroup"
	chooser.position = Vector2(24, 585)
	chooser.size = Vector2(460, 48)
	chooser.add_item("正式卡牌：全部 1–70（随机首抽%d张）" % int(EncounterFlow.test_rules.get("initial_draw_count", initial_draw_count)))
	for index in 7:
		chooser.add_item("正式卡牌：%02d–%02d（全部进入首抽）" % [index * 10 + 1, (index + 1) * 10])
	chooser.select(group)
	chooser.item_selected.connect(func(index: int):
		if _busy:
			chooser.select(group)
			return
		get_tree().root.set_meta("formal_card_test_group", index)
		SceneTransition.change_scene_to_file(scene_file_path))
	add_child(chooser)
	super._ready()
	move_child(chooser, pile_modal.get_index())

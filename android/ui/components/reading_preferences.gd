const BLOCK_SIZE := Vector2(536, 232)
const SIZES := [22, 28, 32, 36, 40, 48]

static func build(parent: Control, origin := Vector2.ZERO) -> Control:
	var block := VBoxContainer.new()
	block.name = "ReadingPreferences"
	block.position = origin
	block.custom_minimum_size = BLOCK_SIZE
	block.add_theme_constant_override("separation", 12)
	parent.add_child(block)
	var title := CatalogUi.label("说明文字", 28)
	block.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	block.add_child(row)
	var readout := CatalogUi.label("", 28)
	readout.name = "ReadingSizeValue"
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	readout.custom_minimum_size = Vector2(176, 64)
	var smaller := CatalogUi.button("缩小", "SmallerText")
	var larger := CatalogUi.button("放大", "LargerText")
	for button: Button in [smaller, larger]:
		button.custom_minimum_size = Vector2(144, 64)
	row.add_child(smaller)
	row.add_child(readout)
	row.add_child(larger)
	var update := func():
		var current := ReadingSettings.body_size()
		readout.text = "%d 号" % current
		smaller.disabled = current <= SIZES.front()
		larger.disabled = current >= SIZES.back()
	smaller.pressed.connect(func():
		var index := SIZES.find(ReadingSettings.body_size())
		ReadingSettings.set_body_size(SIZES[maxi(0, index - 1)])
		update.call())
	larger.pressed.connect(func():
		var index := SIZES.find(ReadingSettings.body_size())
		ReadingSettings.set_body_size(SIZES[mini(SIZES.size() - 1, index + 1)])
		update.call())
	update.call()
	var sample := CatalogUi.label("卡牌与典籍详情 · 长文可滚动", 24)
	sample.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	block.add_child(sample)
	return block

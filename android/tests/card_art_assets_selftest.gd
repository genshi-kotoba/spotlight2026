extends Node
## Validate real card-art imports and the shared catalog without touching player saves.
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveGateway.save_path = "res://.godot/card-art-test-%d/game.json" % Time.get_ticks_usec()
	_check("isolated save", SaveGateway.load_current() == OK)
	var records: Array[Dictionary] = TextCatalog.entries("cards")
	var catalog := FormalCardCatalog.load_definitions()
	_check("70 card records", records.size() == 70)
	_check("formal catalog loads", catalog.error == OK and catalog.cards.size() == 70)
	var filenames := DirAccess.get_files_at("res://assets/card")
	var battle_card := preload("res://ui/components/card/card_view.tscn").instantiate() as CardView
	add_child(battle_card)
	var preview_host := Control.new()
	add_child(preview_host)
	var png_count := 0
	var jpeg_count := 0
	for record: Dictionary in records:
		var path: String = record.art_path
		var extension := path.get_extension()
		var expected := "Card-%03d.%s" % [int(record.id), extension]
		_check("card %s exact filename and format" % record.id,
			path == "res://assets/card/" + expected and filenames.has(expected)
			and extension in ["png", "jpeg"])
		var texture := TextCatalogService.art_texture(path)
		var source_image: Image = texture.get_image() if texture != null else null
		_check("card %s texture uses cropped artwork dimensions" % record.id,
			texture != null and source_image != null
			and texture.get_size() == Vector2(source_image.get_size())
			and source_image.get_width() >= 890 and source_image.get_width() <= 920
			and source_image.get_height() >= 780 and source_image.get_height() <= 815)
		_check("card %s has no exterior white margins" % record.id,
			source_image != null and _edges_are_colored(source_image))
		var definition: CardData = catalog.cards.get(record.id)
		_check("card %s battle and encyclopedia use same art" % record.id,
			definition != null and definition.art_path == path)
		battle_card.set_card(definition)
		var battle_art := battle_card.get_node("%插画位") as TextureRect
		_check("card %s hand view binds artwork" % record.id,
			battle_art.texture != null and battle_art.texture.resource_path == path)
		_check("card %s hand artwork covers its frame without margins" % record.id,
			battle_art.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
			and battle_art.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED)
		var preview := CatalogUi.preview(preview_host, record, "cards", 0.5)
		var preview_art := preview.get_child(0).get_node("%插画位") as TextureRect
		_check("card %s encyclopedia preview binds artwork" % record.id,
			preview_art.texture != null and preview_art.texture.resource_path == path)
		_check("card %s encyclopedia artwork covers its frame without margins" % record.id,
			preview_art.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED)
		preview.queue_free()
		png_count += int(extension == "png")
		jpeg_count += int(extension == "jpeg")
	_check("32 PNG and 38 JPEG imports", png_count == 32 and jpeg_count == 38)
	battle_card.queue_free()
	preview_host.queue_free()
	await get_tree().process_frame
	print("CARD_ART_ASSETS_RESULT failures=%d" % failures)
	get_tree().quit(failures)


func _edges_are_colored(image: Image) -> bool:
	var width := image.get_width()
	var height := image.get_height()
	var colored := [0, 0, 0, 0]
	for x in width:
		colored[0] += int(_is_colored(image.get_pixel(x, 0)))
		colored[1] += int(_is_colored(image.get_pixel(x, height - 1)))
	for y in height:
		colored[2] += int(_is_colored(image.get_pixel(0, y)))
		colored[3] += int(_is_colored(image.get_pixel(width - 1, y)))
	return colored[0] > width * 0.7 and colored[1] > width * 0.7 \
		and colored[2] > height * 0.7 and colored[3] > height * 0.7


func _is_colored(pixel: Color) -> bool:
	return minf(pixel.r, minf(pixel.g, pixel.b)) < 245.0 / 255.0


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		push_error("FAIL " + label)

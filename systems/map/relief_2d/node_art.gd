extends RefCounted
## Map-node artwork only. EVBG references identify the design's event; event
## panel backgrounds are deliberately not used as world-map sprites.
const ROOT := "res://assets/map_nodes/alchemy/"
const EVENT_ART := {
	"great_work": ROOT + "great_work.png", "medical": ROOT + "medical.png",
	"empty_gambling_table": ROOT + "empty_gambling_table.png",
	"death_and_taxes": ROOT + "death_and_taxes.png", "wishing_well": ROOT + "wishing_well.png",
	"beast_fight": ROOT + "beast_fight.png", "damage_stele": ROOT + "damage_stele.png",
	"object_confession": ROOT + "object_confession.png", "codex_exchange": ROOT + "codex_exchange.png",
	"material_synthesis": ROOT + "material_synthesis.png", "material_upgrade": ROOT + "material_upgrade.png",
	"listening_conch": ROOT + "listening_conch.png",
}
static var _textures: Dictionary = {}
static var _opaque_rects: Dictionary = {}
static var _transparent_rects: Dictionary = {}
static var _font: SystemFont
static var _ink_bottom: Dictionary = {}
const ALPHA_MASK_SIZE := 64
const ALPHA_OCCLUSION_THRESHOLD := 0.60

static func describe(node: Dictionary) -> Dictionary:
	var kind: String = str(node.get("type", "event"))
	var label: String = str(node.get("display_name", ""))
	var texture := ""
	if kind == "event":
		if not node.get("opened", false):
			label = "?"
			texture = ROOT + "question.png"
		else:
			texture = EVENT_ART.get(str(node.get("event_kind", "")), "")
			if label.is_empty(): label = "事件"
	else:
		texture = ROOT + kind + ".png" if kind in ["battle", "elite", "boss", "shop", "chest", "pile"] else ""
		if label.is_empty(): label = {"battle":"战斗", "boss":"首领", "shop":"商店", "chest":"宝箱", "pile":"残堆", "elite":"精英"}.get(kind, "事件")
	return {"texture":texture, "label":label, "completed":bool(node.get("completed", false)), "type":kind, "body_radius":float(node.get("body_radius", 0.0)), "body_capsule":node.get("body_capsule", {}).duplicate(true)}

static func texture(path: String) -> Texture2D:
	if path.is_empty(): return null
	if not _textures.has(path):
		var image := Image.new()
		if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
			_textures[path] = null
			return null
		# This runs with texture creation on the main thread, never in geometry
		# preparation. Retain holes/disconnected parts; PNG corners are not solids.
		var partition := _build_alpha_partition(image)
		_opaque_rects[path] = partition.opaque
		_transparent_rects[path] = partition.transparent
		image.fix_alpha_edges()
		image.generate_mipmaps()
		_textures[path] = ImageTexture.create_from_image(image)
	return _textures[path]

static func target_rect(bounds: Rect2, dimensions: Vector2) -> Rect2:
	if dimensions.x <= 0.0 or dimensions.y <= 0.0: return Rect2()
	var fit := minf(bounds.size.x / dimensions.x, bounds.size.y / dimensions.y)
	var size := dimensions * fit
	return Rect2(Vector2(bounds.get_center().x - size.x * .5, bounds.end.y - size.y), size)

static func is_actor_occluder(visual: Dictionary) -> bool:
	# Released combat and loot artwork is visibly translucent; binary clipping
	# would turn those faded pixels back into an invisible opaque obstacle.
	return not str(visual.get("texture", "")).is_empty() and not (visual.get("completed", false) and visual.get("type", "") in ["battle", "elite", "boss", "chest", "pile"])

static func opaque_rects(path: String) -> Array[Rect2]:
	if not _textures.has(path): texture(path)
	var result: Array[Rect2] = []
	result.assign(_opaque_rects.get(path, []))
	return result

static func transparent_rects(path: String) -> Array[Rect2]:
	if not _textures.has(path): texture(path)
	var result: Array[Rect2] = []
	result.assign(_transparent_rects.get(path, []))
	return result

static func _build_alpha_partition(image: Image) -> Dictionary:
	var mask: Image = image.duplicate()
	var scale := minf(1.0, float(ALPHA_MASK_SIZE) / maxf(mask.get_width(), mask.get_height()))
	mask.resize(maxi(1, roundi(mask.get_width() * scale)), maxi(1, roundi(mask.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	var opaque: Array[Rect2] = []
	var transparent: Array[Rect2] = []
	var previous: Array[Dictionary] = [{}, {}]
	for y in mask.get_height():
		var current: Array[Dictionary] = [{}, {}]
		var x := 0
		while x < mask.get_width():
			var solid := mask.get_pixel(x, y).a >= ALPHA_OCCLUSION_THRESHOLD
			var part := 0 if solid else 1
			var rectangles: Array[Rect2] = opaque if solid else transparent
			var start := x
			while x < mask.get_width() and (mask.get_pixel(x, y).a >= ALPHA_OCCLUSION_THRESHOLD) == solid: x += 1
			var run := Vector2i(start, x)
			var index: int = int(previous[part].get(run, -1))
			if index < 0:
				index = rectangles.size()
				rectangles.append(Rect2(start, y, x - start, 1))
			else:
				var rect := rectangles[index]
				rect.size.y += 1.0
				rectangles[index] = rect
			current[part][run] = index
		previous = current
	var dimensions := Vector2(mask.get_width(), mask.get_height())
	for rectangles: Array[Rect2] in [opaque, transparent]:
		for i in rectangles.size(): rectangles[i] = Rect2(rectangles[i].position / dimensions, rectangles[i].size / dimensions)
	return {"opaque": opaque, "transparent": transparent}

static func font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	return _font

static func lines(label: String) -> PackedStringArray:
	if label.length() <= 3: return PackedStringArray([label])
	var split := ceili(label.length() / 2.0)
	return PackedStringArray([label.left(split), label.substr(split)])

static func label_layout(label: String, bounds: Rect2) -> Array[Dictionary]:
	# Text is rooted at the same bottom edge as a PNG. In particular, a ?
	# must not float at rectangle centre above an invisible solid on the floor.
	var rows := PackedStringArray()
	var columns := 2 if bounds.size.x < 65.0 else 3
	for start in range(0, label.length(), columns): rows.append(label.substr(start, columns))
	if rows.is_empty(): rows.append("?")
	var face := font()
	var size := 48 if label == "?" else 25
	while size > 8:
		var fits := face.get_height(size) + (rows.size()-1)*size*1.16 <= bounds.size.y-4.0
		for row in rows:
			fits = fits and face.get_string_size(row,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x <= bounds.size.x-4.0
		if fits: break
		size -= 1
	var y := bounds.end.y - ink_bottom(rows[rows.size()-1], size) - 2.0 - (rows.size()-1)*size*1.16
	var result: Array[Dictionary] = []
	for row in rows:
		var width := face.get_string_size(row,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x
		result.append({"text":row,"size":size,"point":Vector2(bounds.get_center().x-width*.5,y)})
		y += size*1.16
	return result

static func ink_bottom(text: String, size: int) -> float:
	# Font descent includes reserved whitespace (14px for PingFang 40px,
	# while '?' painted pixels end at 1px). Align actual ink, not that margin.
	var cache_key := text + ":" + str(size)
	if _ink_bottom.has(cache_key): return float(_ink_bottom[cache_key])
	var shaped := TextLine.new()
	shaped.add_string(text, font(), size)
	var server := TextServerManager.get_primary_interface()
	var bottom := 0.0
	for glyph: Dictionary in server.shaped_text_get_glyphs(shaped.get_rid()):
		var dimensions := server.font_get_glyph_size(glyph.font_rid, Vector2i(glyph.font_size, 0), glyph.index)
		if dimensions.y <= 0.0: continue
		var offset := server.font_get_glyph_offset(glyph.font_rid, Vector2i(glyph.font_size, 0), glyph.index)
		bottom = maxf(bottom, glyph.offset.y + offset.y + dimensions.y)
	_ink_bottom[cache_key] = bottom
	return bottom

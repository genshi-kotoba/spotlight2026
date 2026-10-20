extends RefCounted
## Presentation-only menace around the existing elite PNG. These bounded
## billows use a shared generated alpha texture, never particles or game RNG.
const PUFFS_PER_SIDE := 5
const PUFF_LIFETIME := 2.8
static var _mist: Texture2D

static func is_active(command: Dictionary) -> bool:
	var visual: Dictionary = command.get("visual", {})
	return bool(command.get("elite_steam", false)) and visual.get("type", "") == "elite" \
		and not bool(visual.get("completed", false)) and command.get("rect", Rect2()).has_area()

static func bounds(rect: Rect2) -> Rect2:
	# Include rotated, expanding high wisps so edge-of-screen steam cannot
	# freeze while its sprite is already outside the viewport.
	return rect.grow(maxf(rect.size.x, rect.size.y) * .70)

static func draw_behind(canvas: CanvasItem, rect: Rect2, elapsed: float) -> void:
	var phase := _phase(rect)
	var foot := Vector2(rect.get_center().x, rect.end.y)
	var w := rect.size.x
	var h := rect.size.y
	# A low root haze attaches the rising steam to the marker's contact plane.
	_puff(canvas, foot + Vector2(0, -h * .055), Vector2(w * 1.22, h * .20), 0.0, Color(.12, .015, .035, .23))
	for side: float in [-1.0, 1.0]:
		for index in PUFFS_PER_SIDE:
			var age := fposmod(elapsed / PUFF_LIFETIME + float(index) / PUFFS_PER_SIDE + phase + side * .13, 1.0)
			var curl := age * TAU * 1.35 - elapsed * .62 + phase * TAU + side
			var center := foot + Vector2(side * w * (.34 + .13 * sin(curl) + .10 * age), -h * (.04 + 1.18 * age))
			center.x += w * .055 * sin(curl * 2.1)
			var size := Vector2(w * (.34 + age * .34), h * (.28 + age * .15))
			var fade := sin(age * PI) * (1.0 - age * .32)
			var rotation := side * (.35 + .34 * sin(curl))
			# Crimson is an undertone between soot lobes, with a dense black core.
			_puff(canvas, center + Vector2(-side * w * .025, h * .018), size * 1.18, rotation, Color(.38, .018, .052, fade * .27))
			_puff(canvas, center, size, rotation, Color(.025, .016, .025, fade * .88))
			_puff(canvas, center + Vector2(side * size.x * .15, -size.y * .16), size * .62, -rotation, Color(.045, .023, .036, fade * .48))
		_filament(canvas, rect, elapsed, phase, side, false)

static func draw_front(canvas: CanvasItem, rect: Rect2, elapsed: float) -> void:
	var phase := _phase(rect)
	# Only the lower outside edges cross the PNG. The eye and its silhouette
	# remain legible; there is no full-sprite red wash or opaque foreground veil.
	for side: float in [-1.0, 1.0]:
		var roll := elapsed * 1.5 + phase * TAU + side
		var center := Vector2(rect.get_center().x + side * rect.size.x * (.43 + .025 * sin(roll)), rect.end.y - rect.size.y * (.10 + .025 * cos(roll)))
		_puff(canvas, center, rect.size * Vector2(.39, .23), side * .3, Color(.06, .018, .03, .38))
		_filament(canvas, rect, elapsed, phase, side, true)

static func _filament(canvas: CanvasItem, rect: Rect2, elapsed: float, phase: float, side: float, front: bool) -> void:
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	var segments := 18
	var foot := Vector2(rect.get_center().x, rect.end.y)
	for index in segments + 1:
		var t := float(index) / segments
		var wave := t * TAU * 1.4 - elapsed * 1.7 + phase * TAU + side
		var x := side * rect.size.x * (.40 + .095 * sin(wave) + t * .055)
		var y := -rect.size.y * (.04 + t * (.33 if front else .97))
		points.append(foot + Vector2(x, y))
		colors.append(Color(.58, .045, .09, sin(t * PI) * (.34 if front else .30)))
	# A narrow colored vein is softened by a wider low-opacity wine-red trace.
	canvas.draw_polyline(points, Color(.24, .012, .035, .16), maxf(.8, rect.size.x * .028), true)
	canvas.draw_polyline_colors(points, colors, maxf(.5, rect.size.x * .010), true)

static func _phase(rect: Rect2) -> float:
	# Stable decorrelation by display-space anchor; no gameplay stream or seed.
	return fposmod(sin(rect.get_center().dot(Vector2(.017, .031))) * 17.13, 1.0)

static func _puff(canvas: CanvasItem, center: Vector2, size: Vector2, rotation: float, tint: Color) -> void:
	canvas.draw_set_transform(center, rotation)
	canvas.draw_texture_rect(_texture(), Rect2(-size * .5, size), false, tint)
	canvas.draw_set_transform(Vector2.ZERO)

static func _texture() -> Texture2D:
	if _mist != null: return _mist
	var image := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	for y in 96:
		for x in 96:
			var point := (Vector2(x, y) + Vector2(.5, .5)) / 48.0 - Vector2.ONE
			var angle := point.angle()
			var edge := 1.0 + .07 * sin(angle * 5.0 + .4) + .045 * sin(angle * 8.0)
			var radius := point.length() / edge
			var alpha := pow(maxf(0.0, 1.0 - radius * radius), 2.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	image.generate_mipmaps()
	_mist = ImageTexture.create_from_image(image)
	return _mist

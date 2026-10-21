class_name MonsterBattleText
extends Control

## 纯表现层：私有随机上下文、批量自绘，不消费 SeedService 的玩法随机流。
signal sentence_started(text: String, bounds: Rect2)

@export_range(0.01, 0.5, 0.005) var character_interval := 0.16
@export_range(0.01, 0.5, 0.01) var perturb_interval := 0.1
@export var angle_multiplier := 1.0
@export var curve_scale := 1.0
const FONT_MIN := 200
const FONT_MAX := 240
const NEXT_DELAY := 3.0
const RECENT_SENTENCE_COUNT := 4
const AUTO_FADE_DELAY := 3.0
const FADE_DURATION := 1.0
const INK := Color(1.0, 1.0, 1.0, 0.60)
const INK_TOP := Color("e8bc58") # 字形顶部：金色。
const INK_BOTTOM := Color("c4313b") # 字形底部：红色。
const CENTER_CLEAR_RATIO := 0.08 # 仅约束整句中心偏向左右，不再封死整条中央战场。
const MARGIN := 4.0
const READABLE_SIZE := 24.0 # 实际显示字号优先目标；长句仍按空间等比适配。
const MIN_SIZING_CHARACTERS := 15 # 短句按至少15个汉字的空间计算显示缩放。
const SENTENCE_ENDINGS := ["。", "｡", ".", "．", "！", "!", "？", "?"]
const GLYPH_MOTION := preload("res://ui/components/text_glyph_motion.gd")

var sentences: Array[String] = []
var context_provider: Callable
var active_sentences: Array[Dictionary] = []
var source_path := ""
var last_error: Error = OK
var _random: SeedRegistry
var _selection: RandomStream
var _appearance: RandomStream
var _serial := 0
var _time := 0.0
var _next_at := 0.0
var _running := false
var _font: SystemFont
var _pending_text := ""
var _pending_layout: Dictionary = {}
var _recent_sentences: Array[String] = []
var _next_side := 0 # 0左、1右；优先轮换，单侧无空间时才回退。


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = -1
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["SimHei", "黑体", "Noto Sans CJK SC", "WenQuanYi Micro Hei", "sans-serif"])
	_font.font_weight = 400
	_font.allow_system_fallback = true


static func parse_sentences(source: String) -> Array[String]:
	var result: Array[String] = []
	var pending := ""
	var lines := source.trim_prefix(String.chr(0xFEFF)).replace("\r\n", "\n").replace("\r", "\n").split("\n")
	for raw: String in lines:
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		pending += line
		# 仅标点位于行末时断句；同一行内的句号、问号、感叹号仍保留在原句。
		if line.right(1) in SENTENCE_ENDINGS:
			result.append(pending)
			pending = ""
		elif line.ends_with("；") or line.ends_with(";"):
			pending += "\n"
	# 文件末尾没有结束标点或换行也不丢文本。
	if not pending.strip_edges().is_empty():
		result.append(pending.strip_edges())
	return result


func configure(path: String, seed_text: String, identity: Array) -> Error:
	stop()
	source_path = path
	var loaded := TextCatalog.read_text(path)
	last_error = loaded.error
	sentences = parse_sentences(loaded.text)
	if last_error != OK or sentences.is_empty():
		return last_error
	_random = SeedRegistry.new("monster-battle-text-ruina-v2")
	_random.begin_run(JSON.stringify([seed_text, identity]))
	_selection = _random.get_stream(&"presentation.sentences", identity)
	_appearance = _random.get_stream(&"presentation.glyphs", identity)
	_serial = 0
	_time = 0.0
	_next_at = 0.0
	_pending_text = ""
	_pending_layout = {}
	_running = true
	return OK


func stop() -> void:
	_running = false
	active_sentences.clear()
	_pending_text = ""
	_pending_layout = {}
	_recent_sentences.clear()
	_next_side = 0
	queue_redraw()


func _process(delta: float) -> void:
	advance(delta)


## 不依赖 Timer/Tween 的时间线，暂停、退出无悬挂协程，可确定性自测。
func advance(delta: float) -> void:
	if not _running or not context_provider.is_valid():
		return
	var context: Dictionary = context_provider.call()
	if bool(context.get("suspended", false)):
		visible = false
		return
	visible = true
	_time += maxf(delta, 0.0)
	var area: Rect2 = context.get("area", Rect2(Vector2.ZERO, size))
	var blockers: Array = context.get("blockers", []).duplicate()
	# UI/窗口尺寸改变后旧句也要重新验证；宁可清除，也不在 UI 下冒出半句话。
	var layout_invalidated := false
	for index in range(active_sentences.size() - 1, -1, -1):
		var sentence := active_sentences[index]
		var unsafe := not is_safe(sentence.bounds, area, blockers)
		if _time >= float(sentence.expires) or unsafe:
			active_sentences.remove_at(index)
			layout_invalidated = layout_invalidated or unsafe
	if layout_invalidated and active_sentences.is_empty():
		# 已不可见的长句不能继续占着播放时隙，导致新位置迟迟不出字。
		_next_at = minf(_next_at, _time)
	if _time >= _next_at:
		_start_sentence(area, blockers)
	queue_redraw()


static func is_safe(bounds: Rect2, area: Rect2, blockers: Array) -> bool:
	if not area.encloses(bounds):
		return false
	for blocked: Rect2 in blockers:
		if blocked.intersects(bounds):
			return false
	return true


static func center_exclusion(area: Rect2) -> Rect2:
	return Rect2(area.position + Vector2(area.size.x * (1.0 - CENTER_CLEAR_RATIO) * 0.5, 0),
		Vector2(area.size.x * CENTER_CLEAR_RATIO, area.size.y))


static func free_regions(area: Rect2, blockers: Array) -> Array[Rect2]:
	var regions: Array[Rect2] = [area.grow(-12.0)]
	for blocked: Rect2 in blockers:
		var remaining: Array[Rect2] = []
		for region: Rect2 in regions:
			var cut := region.intersection(blocked)
			if not cut.has_area():
				remaining.append(region)
				continue
			for piece: Rect2 in [
				Rect2(region.position, Vector2(cut.position.x - region.position.x, region.size.y)),
				Rect2(Vector2(cut.end.x, region.position.y), Vector2(region.end.x - cut.end.x, region.size.y)),
				Rect2(Vector2(cut.position.x, region.position.y), Vector2(cut.size.x, cut.position.y - region.position.y)),
				Rect2(Vector2(cut.position.x, cut.end.y), Vector2(cut.size.x, region.end.y - cut.end.y)),
			]:
				if piece.has_area():
					remaining.append(piece)
		regions = remaining
	# 矩形相减产生的是不重叠分片，不是最大可用区域。先扩展再选位，
	# 否则相邻空白被当作独立窄条，整句只能缩成几像素。
	var expanded: Array[Rect2] = []
	for region: Rect2 in regions:
		for horizontal_first: bool in [true, false]:
			var candidate := region
			for step in 4:
				candidate = _expand_region(candidate, area.grow(-12.0), blockers, (step % 2 == 0) == horizontal_first)
			if not expanded.has(candidate):
				expanded.append(candidate)
	return expanded


static func _expand_region(region: Rect2, area: Rect2, blockers: Array, horizontal: bool) -> Rect2:
	var low := area.position.x if horizontal else area.position.y
	var high := area.end.x if horizontal else area.end.y
	for blocked: Rect2 in blockers:
		if horizontal:
			if blocked.end.y <= region.position.y or blocked.position.y >= region.end.y:
				continue
			if blocked.end.x <= region.position.x:
				low = maxf(low, blocked.end.x)
			elif blocked.position.x >= region.end.x:
				high = minf(high, blocked.position.x)
		else:
			if blocked.end.x <= region.position.x or blocked.position.x >= region.end.x:
				continue
			if blocked.end.y <= region.position.y:
				low = maxf(low, blocked.end.y)
			elif blocked.position.y >= region.end.y:
				high = minf(high, blocked.position.y)
	return Rect2(low, region.position.y, high - low, region.size.y) if horizontal else Rect2(region.position.x, low, region.size.x, high - low)


func _unit(stream: RandomStream) -> float:
	return float(stream.int_range(0, 16777216)) / 16777216.0


## TextServer 提供实际字形矩形、字距和回退字体，围绕字形中心变换。
func _layout(text: String, font_size: int) -> Dictionary:
	var glyphs: Array[Dictionary] = []
	var reveal_times: Array[float] = []
	var change_ticks := {}
	var typing_duration := 0.0
	for index in text.length():
		reveal_times.append(typing_duration)
		change_ticks[maxi(0, int(ceil(typing_duration / perturb_interval - 0.000001)))] = true
		# 原作首字立即显示；仅普通空格不等待，换行仍参与逐字时序。
		if text.substr(index, 1) != " ":
			typing_duration += character_interval
	var server := TextServerManager.get_primary_interface()
	var source_index := 0
	var baseline := _font.get_ascent(font_size)
	var bounds := Rect2()
	var has_bounds := false
	var line_index := 0
	var line_widths: Array[float] = []
	for line: String in text.split("\n"):
		var shaped := server.create_shaped_text()
		server.shaped_text_add_string(shaped, line, _font.get_rids(), font_size)
		var cursor := 0.0
		for info: Dictionary in server.shaped_text_get_glyphs(shaped):
			for repeat_index in int(info.repeat):
				var position := Vector2(cursor, baseline) + Vector2(info.offset)
				var font_rid: RID = info.font_rid
				var glyph_index := int(info.index)
				if font_rid.is_valid():
					var offset := server.font_get_glyph_offset(font_rid, Vector2i(font_size, 0), glyph_index)
					var glyph_size := server.font_get_glyph_size(font_rid, Vector2i(font_size, 0), glyph_index)
					var texture_rid := RID()
					var texture_uvs := PackedVector2Array()
					if glyph_size.x > 0.0 and glyph_size.y > 0.0 and server.font_get_glyph_texture_idx(font_rid, Vector2i(font_size, 0), glyph_index) >= 0:
						texture_rid = server.font_get_glyph_texture_rid(font_rid, Vector2i(font_size, 0), glyph_index)
						var atlas_size := server.font_get_glyph_texture_size(font_rid, Vector2i(font_size, 0), glyph_index)
						var uv_rect := Rect2(server.font_get_glyph_uv_rect(font_rid, Vector2i(font_size, 0), glyph_index))
						texture_uvs = PackedVector2Array([uv_rect.position / atlas_size,
							Vector2(uv_rect.end.x, uv_rect.position.y) / atlas_size,
							uv_rect.end / atlas_size, Vector2(uv_rect.position.x, uv_rect.end.y) / atlas_size])
					var center := position + offset + glyph_size * 0.5
					# 包围所有可能的单字旋转/1.2倍尺寸扰动，而非只检查基线。
					var half := glyph_size * 0.6
					var angle_limit := minf(absf(deg_to_rad(5.0 * angle_multiplier)), PI * 0.5)
					var extent := Vector2(half.x + half.y * sin(angle_limit), half.y + half.x * sin(angle_limit))
					extent += Vector2.ONE * absf(curve_scale)
					var box := Rect2(center - extent, extent * 2.0)
					bounds = bounds.merge(box) if has_bounds else box
					has_bounds = true
					var last_index := mini(source_index + int(info.end) - 1, reveal_times.size() - 1)
					glyphs.append({"ch": line.substr(int(info.start), int(info.end) - int(info.start)),
						"position": position, "center": center, "draw_offset": position - center,
						"quad_half": glyph_size * 0.5,
						"font_rid": font_rid, "index": glyph_index, "line": line_index,
						"texture_rid": texture_rid, "texture_uvs": texture_uvs,
						"advance_end": cursor + float(info.advance), "reveal_at": reveal_times[maxi(last_index, 0)]})
				cursor += float(info.advance)
		line_widths.append(cursor)
		# 为逐字前缀的对齐重排保留整行宽度。
		var line_box := Rect2(0, baseline - _font.get_ascent(font_size), maxf(cursor, 1.0), _font.get_height(font_size))
		bounds = bounds.merge(line_box) if has_bounds else line_box
		has_bounds = true
		server.free_rid(shaped)
		source_index += line.length() + 1
		line_index += 1
		baseline += _font.get_height(font_size)
	# 前缀居中/右对齐时，末字可能宽于完整句末字；额外包住其尺寸脉冲。
	bounds = bounds.grow(MARGIN + font_size * 0.25)
	for glyph: Dictionary in glyphs:
		glyph.position -= bounds.position
		glyph.center -= bounds.position
	return {"glyphs": glyphs, "size": bounds.size, "font_size": font_size,
		"typing_duration": typing_duration, "complete_offset": reveal_times.back() if not reveal_times.is_empty() else 0.0,
		"line_widths": line_widths, "change_ticks": change_ticks}


func _choose_sentence() -> String:
	var unique: Array[String] = []
	for text: String in sentences:
		if not text.strip_edges().is_empty() and not unique.has(text):
			unique.append(text)
	# 最近4句按实际文本去重；数量不足时依次放开最旧的限制，有限遍历。
	for relaxed in range(_recent_sentences.size() + 1):
		var recent := _recent_sentences.slice(relaxed)
		var available := unique.filter(func(text: String): return not recent.has(text))
		if not available.is_empty():
			return available[int(_selection.int_range(0, available.size()))]
	return ""


func _sizing_reference(text: String, layout: Dictionary) -> Vector2:
	var actual_size: Vector2 = layout.size
	# 换行和空白不算字；只扩充适配参考尺寸，不补字、不改变逐字时序或实际排版。
	var character_count := text.replace("\n", "").replace(" ", "").replace("\t", "").length()
	if character_count <= 0 or character_count >= MIN_SIZING_CHARACTERS:
		return actual_size
	var reference := _layout("国".repeat(MIN_SIZING_CHARACTERS), int(layout.font_size))
	return actual_size.max(Vector2(reference.size))


func _start_sentence(area: Rect2, blockers: Array) -> void:
	if area.size.x < 320.0 or area.size.y < 180.0:
		# 极小视口没有可读的战场空间，等待恢复，而不是继续显示几像素文字。
		_next_at = _time + 0.25
		return
	if _pending_text.is_empty():
		_pending_text = _choose_sentence()
		if _pending_text.is_empty():
			_next_at = _time + 0.25
			return
		_pending_layout = _layout(_pending_text, int(_appearance.int_range(FONT_MIN, FONT_MAX + 1)))
		_pending_layout["fit_size"] = _sizing_reference(_pending_text, _pending_layout)
		_pending_layout["angle"] = deg_to_rad(float(_appearance.int_range(-15, 15)))
		_pending_layout["motion_seed"] = int(_appearance.int_range(0, 2147483647))
	var text := _pending_text
	# 两条长周期PRNG流持续推进；不缓存每句的流，也不创建会循环的小随机池。
	var stream := _appearance
	var regions := free_regions(area, blockers)
	# 先按源文件显式换行排出自然长度，再将整句等比缩放；绝不自动折行。
	var layout := _pending_layout
	var angle := float(layout.angle)
	var natural_size: Vector2 = layout.size
	var rotated_size := Vector2(absf(cos(angle)) * natural_size.x + absf(sin(angle)) * natural_size.y,
		absf(sin(angle)) * natural_size.x + absf(cos(angle)) * natural_size.y)
	var fit_size: Vector2 = layout.fit_size
	var rotated_fit_size := Vector2(absf(cos(angle)) * fit_size.x + absf(sin(angle)) * fit_size.y,
		absf(sin(angle)) * fit_size.x + absf(cos(angle)) * fit_size.y)
	var choices: Array[Dictionary] = []
	var side_scales := [0.0, 0.0]
	var center_gap := center_exclusion(area)
	for region: Rect2 in regions:
		var placement := region.grow(-0.5)
		if not placement.has_area():
			continue
		for side in 2:
			# 句身可经过怪物，但句子中心不能居中。左右各计算真实可用宽度，
			# 不再为了避开一整条中央空白而把长句压进几像素宽的区域。
			var side_width := 2.0 * (center_gap.position.x - 1.0 - placement.position.x) if side == 0 else 2.0 * (placement.end.x - center_gap.end.x - 1.0)
			var fit_scale := minf(1.0, minf(minf(placement.size.x, side_width) / rotated_fit_size.x, placement.size.y / rotated_fit_size.y))
			if fit_scale <= 0.0:
				continue
			choices.append({"region": placement, "render_scale": fit_scale, "size": rotated_size * fit_scale, "side": side})
			side_scales[side] = maxf(side_scales[side], fit_scale)
	if choices.is_empty():
		# 极小窗口/完整遮挡时不截断文本；等可用区域恢复再尝试。
		_next_at = _time + 0.25
		return
	# 先为同一句确定左右共用的缩放，再选位置；右侧空白更多也不能单独放大。
	var common_scale := maxf(side_scales[0], side_scales[1])
	if side_scales[0] > 0.0 and side_scales[1] > 0.0:
		var both_fit := minf(side_scales[0], side_scales[1])
		if float(layout.font_size) * both_fit >= READABLE_SIZE:
			common_scale = both_fit
	# 某侧完全不可用或只能显示微小文字时，仍允许退到可读的那侧，而非强行缩小两侧。
	choices = choices.filter(func(candidate: Dictionary): return float(candidate.render_scale) + 0.000001 >= common_scale)
	for candidate: Dictionary in choices:
		candidate.render_scale = common_scale
		candidate.size = rotated_size * common_scale
	var side_choices := choices.filter(func(candidate: Dictionary): return int(candidate.side) == _next_side)
	if not side_choices.is_empty():
		choices = side_choices
	# 按可放置面积选区域，不让细碎边角与宽阔战场拥有相同权重。
	var weighted: Array = []
	for index in choices.size():
		var free_space: Vector2 = _placement_origins(choices[index], center_gap).size
		weighted.append({"value": index, "weight": maxf(free_space.x, 1.0) * maxf(free_space.y, 1.0)})
	var choice: Dictionary = choices[int(stream.weighted_pick(weighted))]
	var origins := _placement_origins(choice, center_gap)
	var origin := origins.position + Vector2(_unit(stream), _unit(stream)) * origins.size
	var bounds := Rect2(origin, choice.size)
	var glyphs: Array = layout.glyphs
	var complete_at := _time + float(layout.complete_offset)
	var done_at := _time + float(layout.typing_duration) + NEXT_DELAY
	# 原作地图管理器在 DisplayDone 后创建新句，并令旧句同时淡出。
	for previous: Dictionary in active_sentences:
		previous.fade_at = minf(float(previous.fade_at), _time)
		previous.expires = float(previous.fade_at) + FADE_DURATION
	var relative_x := (bounds.get_center().x - area.position.x) / maxf(area.size.x, 1.0)
	var alignment := HORIZONTAL_ALIGNMENT_LEFT if relative_x < 0.25 else HORIZONTAL_ALIGNMENT_RIGHT if relative_x > 0.75 else HORIZONTAL_ALIGNMENT_CENTER
	active_sentences.append({"text": text, "bounds": bounds, "glyphs": glyphs,
		"side": choice.side,
		"font_size": layout.font_size, "render_scale": choice.render_scale,
		"local_size": natural_size, "angle": angle, "alignment": alignment,
		"line_widths": layout.line_widths, "motion_seed": layout.motion_seed,
		"change_ticks": layout.change_ticks,
		"started": _time, "complete": complete_at,
		"display_done": done_at, "fade_at": done_at + AUTO_FADE_DELAY,
		"expires": done_at + AUTO_FADE_DELAY + FADE_DURATION})
	_serial += 1
	_next_side = 1 - int(choice.side)
	_recent_sentences.append(text)
	if _recent_sentences.size() > RECENT_SENTENCE_COUNT:
		_recent_sentences.pop_front()
	_next_at = done_at
	_pending_text = ""
	_pending_layout = {}
	sentence_started.emit(text, bounds)


static func _placement_origins(choice: Dictionary, center_gap: Rect2) -> Rect2:
	var region: Rect2 = choice.region
	var bounds_size: Vector2 = choice.size
	var low := region.position
	var high := region.end - bounds_size
	if int(choice.side) == 0:
		high.x = minf(high.x, center_gap.position.x - 1.0 - bounds_size.x * 0.5)
	else:
		low.x = maxf(low.x, center_gap.end.x + 1.0 - bounds_size.x * 0.5)
	return Rect2(low, (high - low).max(Vector2.ZERO))


## 按句/字/离散时间片寻址的32位混合；绘制不推进随机流，帧率不改变抖动。
static func _motion_unit(seed_value: int, index: int, tick: int, channel: int) -> float:
	return GLYPH_MOTION.unit(seed_value, index, tick, channel)


static func sentence_alpha(sentence: Dictionary, at_time: float) -> float:
	return clampf(1.0 - (at_time - float(sentence.fade_at)) / FADE_DURATION, 0.0, 1.0)


static func glyph_ink_colors(alpha: float) -> PackedColorArray:
	var opacity := INK.a * clampf(alpha, 0.0, 1.0)
	var top := Color(INK_TOP, opacity)
	var bottom := Color(INK_BOTTOM, opacity)
	return PackedColorArray([top, top, bottom, bottom])


func glyph_pose(sentence: Dictionary, index: int, at_time: float) -> Dictionary:
	var tick := maxi(0, int(floor((at_time - float(sentence.started)) / perturb_interval + 0.000001)))
	var changed: bool = sentence.change_ticks.has(tick)
	var motion_seed := int(sentence.motion_seed)
	return GLYPH_MOTION.sample(motion_seed, index, tick, curve_scale, angle_multiplier, changed)


func _visible_widths(sentence: Dictionary, at_time: float) -> PackedFloat32Array:
	var widths := PackedFloat32Array()
	widths.resize(sentence.line_widths.size())
	for glyph: Dictionary in sentence.glyphs:
		if float(glyph.reveal_at) <= at_time - float(sentence.started) + 0.000001:
			widths[int(glyph.line)] = maxf(widths[int(glyph.line)], float(glyph.advance_end))
	return widths


func _glyph_transform(sentence: Dictionary, index: int, at_time: float, widths: PackedFloat32Array) -> Transform2D:
	var glyph: Dictionary = sentence.glyphs[index]
	var pose := glyph_pose(sentence, index, at_time)
	var line := int(glyph.line)
	var alignment_factor := 0.0 if sentence.alignment == HORIZONTAL_ALIGNMENT_LEFT else 1.0 if sentence.alignment == HORIZONTAL_ALIGNMENT_RIGHT else 0.5
	# 整行按共同容器对齐，逐字前缀随新增字符重排，而不是提前固定最终字位。
	var full_width := float(sentence.line_widths.max())
	var prefix_shift := Vector2((full_width - widths[line]) * alignment_factor, 0)
	var local_center: Vector2 = glyph.center + prefix_shift - Vector2(sentence.local_size) * 0.5 + Vector2(pose.offset)
	var render_scale := float(sentence.render_scale)
	var origin: Vector2 = sentence.bounds.get_center() + local_center.rotated(float(sentence.angle)) * render_scale
	return Transform2D(float(sentence.angle) + float(pose.angle), Vector2.ONE * render_scale * float(pose.scale), 0.0, origin)


func _draw() -> void:
	for sentence: Dictionary in active_sentences:
		var age := _time - float(sentence.started)
		var visible_widths := _visible_widths(sentence, _time)
		var colors := glyph_ink_colors(sentence_alpha(sentence, _time))
		for index in sentence.glyphs.size():
			var glyph: Dictionary = sentence.glyphs[index]
			if float(glyph.reveal_at) > age + 0.000001:
				continue
			draw_set_transform_matrix(_glyph_transform(sentence, index, _time, visible_widths))
			if not RID(glyph.texture_rid).is_valid():
				continue # 空格等无可见位图的字形仍保留原字距及逐字时序。
			var half: Vector2 = glyph.quad_half
			var corners := PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
			# 在原字形四角间插值颜色，渐变随字形一起旋转、缩放。
			RenderingServer.canvas_item_add_polygon(get_canvas_item(), corners, colors, glyph.texture_uvs, glyph.texture_rid)
	draw_set_transform(Vector2.ZERO)

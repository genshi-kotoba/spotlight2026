class_name MapLayout
extends RefCounted

## 地图数据与通行规则。纯数据，不持有节点。
##
## 通行需同时满足两条：
##   1. 目标格地形可通行
##   2. 相邻两格的高差不超过 CLIMB_LIMIT_WORLD，上下对称
##
## 爬升限值说的是世界高度，不是层数。层数由 step_height 决定，
## 而 step_height 是可以随手调的视觉参数 —— 若把限值写成「几层」，
## 调一次台阶高度就会连带改掉玩法，而且是静默的。
## 所以判定统一换算成世界高度再比。

## 允许爬升的世界高度上限。超过就走不过去，上下对称。
##
## 取 0.5：一层 0.25 时，两级以内能上，三级开始拦。
## 说限值时请带单位。之前沟通里说的「1 个单位」是按「一层等于 0.5」估的，
## 而实际一层是 0.25，那个「1」换算过来是 0.5 个世界单位、也就是两级。
const CLIMB_LIMIT_WORLD := 0.5

## 一个高度层级在世界里的尺寸。这是默认值，实际以 MapBuilder 的导出属性为准。
const STEP_HEIGHT := 0.25

## 字符表里数字与字母能表示的最高层级。墙高推断用它做上界。
## 0 到 9 用数字，10 到 35 用大写字母，所以一格仍然只占一个字符。
const MAX_HEIGHT := 35

## 字符表缓存。不要写成静态初始化表达式 ——
## 静态初始化阶段调用本类的静态函数会失败，整张表会变成空的，
## 表现是解析时每个格子都报「不在字符表中」，而且只在编辑器加载场景时出现，
## 用 --script 单独跑测试反而正常。踩过一次，改成首次访问时构建。
static var _charset_cache: Dictionary = {}


## 编辑器文本布局的字符表。一个字符一格。
##
## 数字与字母都是高度层级，不是世界高度。一层在世界里有多大由 STEP_HEIGHT 决定。
## 用一个字符表示到 35 级，是为了既能让山峰堆得很高，文本又还能一眼看出地形形状。
##
## 表是按规则生成的，不是手抄的：手抄 36 条迟早会漏或者串位。
static func charset() -> Dictionary:
	if _charset_cache.is_empty():
		_charset_cache = _build_charset()
	return _charset_cache


static func _build_charset() -> Dictionary:
	var table := {
		".": null,                                            # 无此格
		" ": null,                                            # 无此格（容忍空格）
		"r": {"height": 1, "terrain": MapTerrain.Terrain.ROAD},
		"#": {"height": 1, "terrain": MapTerrain.Terrain.WALL, "follow_height": true},
		"@": {"height": 1, "terrain": MapTerrain.Terrain.PLAIN, "start": true},
	}
	for level in MAX_HEIGHT + 1:
		table[_char_for_level(level)] = {
			"height": level,
			"terrain": MapTerrain.Terrain.PLAIN,
		}
	return table


## 层级转字符：0 到 9 用数字，10 起用 A 往后数。
static func _char_for_level(level: int) -> String:
	if level < 10:
		return str(level)
	return String.chr("A".unicode_at(0) + level - 10)


## 坐标 -> MapTile
var tiles: Dictionary = {}
var start_coord: Vector2i = Vector2i.ZERO
var has_start: bool = false

## 一个高度层级在世界里的尺寸。由构建方传入，爬升判定按它换算成世界高度。
var step_height: float = STEP_HEIGHT


## 从文本网格构建。行号为 row，列号为 col，内部转成轴向坐标。
##
## p_step_height 要与实际生成网格用的值一致，否则通行判定和看到的地形会对不上。
static func from_text(text: String, p_step_height: float = STEP_HEIGHT) -> MapLayout:
	var layout := MapLayout.new()
	layout.step_height = p_step_height
	var rows := _dedent(text).split("\n", true)
	var follow_height: Array[Vector2i] = []
	var table := charset()

	for row in rows.size():
		var line: String = rows[row]
		for col in line.length():
			var ch := line[col]
			if not table.has(ch):
				push_warning("MapLayout: 第 %d 行第 %d 列的字符 '%s' 不在字符表中，已跳过" % [row + 1, col + 1, ch])
				continue
			var spec = table[ch]
			if spec == null:
				continue

			var coord := HexCoord.offset_to_axial(col, row)
			var tile := MapTile.new(coord, spec["height"], spec["terrain"])
			if spec.get("start", false):
				layout.start_coord = coord
				layout.has_start = true
			layout.tiles[coord] = tile

			if spec.get("follow_height", false):
				follow_height.append(coord)

	# 墙的高度要等周围地形都解析完才能推，所以放到第二轮
	for coord in follow_height:
		var tile: MapTile = layout.tiles[coord]
		tile.height = layout.height_from_neighbours(coord)

	return layout


## 取周围可通行邻格里最常见的高度。
##
## 墙体嵌在哪一层就长在哪一层。若写死成固定高度，把井号放进高地会凹成一个坑，
## 看上去像陷阱而不是墙，通行判定也会被高度差顺带挡掉，掩盖地形阻挡本身。
func height_from_neighbours(coord: Vector2i) -> int:
	var counts := PackedInt32Array()
	counts.resize(MAX_HEIGHT + 1)

	var found := 0
	for neighbor in HexCoord.neighbors(coord):
		var tile: MapTile = tiles.get(neighbor)
		if tile == null or not tile.is_passable():
			continue
		counts[clampi(tile.height, 0, MAX_HEIGHT)] += 1
		found += 1

	if found == 0:
		return 1

	var best := 1
	var best_count := 0
	for h in counts.size():
		if counts[h] > best_count:
			best_count = counts[h]
			best = h
	return best


## 剥掉所有非空行共有的前导缩进，让源码里的多行地图不必顶格书写。
static func _dedent(text: String) -> String:
	var lines := text.split("\n")
	var indent := -1

	for line in lines:
		if line.strip_edges().is_empty():
			continue
		var leading := line.length() - line.lstrip(" \t").length()
		indent = leading if indent < 0 else mini(indent, leading)

	if indent <= 0:
		return text

	var result: Array[String] = []
	for line in lines:
		result.append(line.substr(mini(indent, line.length())))
	return "\n".join(result)


func has_tile(coord: Vector2i) -> bool:
	return tiles.has(coord)


func tile_at(coord: Vector2i) -> MapTile:
	return tiles.get(coord)


func size() -> int:
	return tiles.size()


## 通行判定的唯一入口。寻路、点击可达性、路径预览都走它。
func can_move(from: Vector2i, to: Vector2i) -> bool:
	var source: MapTile = tiles.get(from)
	if source == null or not source.is_passable():
		return false

	var target: MapTile = tiles.get(to)
	if target == null or not target.is_passable():
		return false

	# 上下对称：低到高与高到低受同一条限制，避免「掉下去上不来」的单向陷阱。
	# 来源格也要求可站人，否则 can_move 会随查询方向变化 ——
	# 站在墙上时「墙到平地」返回真而「平地道墙」返回假，是个潜在的坑。
	#
	# 换算成世界高度再比，而不是比层数。层数大小由 step_height 决定，
	# 那个值在编辑器里随手可调；比层数的话，调一次视觉参数就静默改了玩法。
	var rise := absi(target.height - source.height) * step_height
	return rise <= CLIMB_LIMIT_WORLD


func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	return MapPathfinder.find_path(from, to, can_move)


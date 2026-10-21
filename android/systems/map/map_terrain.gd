class_name MapTerrain
extends RefCounted

## 地形表。每种地形带一个通行标记与一个表现颜色。
##
## 地形只负责「这一格本身能不能站人」，不负责高低差。
## 高低差带来的爬升限制在 MapLayout.can_move 里单独判。

enum Terrain {
	PLAIN = 0,
	ROAD = 1,
	WALL = 2,
}

const TABLE := {
	Terrain.PLAIN: {"passable": true, "color": Color(0.55, 0.55, 0.58)},
	Terrain.ROAD: {"passable": true, "color": Color(0.68, 0.64, 0.52)},
	Terrain.WALL: {"passable": false, "color": Color(0.26, 0.22, 0.24)},
}


static func is_passable(terrain: int) -> bool:
	if not TABLE.has(terrain):
		return false
	return TABLE[terrain]["passable"]


static func color_of(terrain: int) -> Color:
	if not TABLE.has(terrain):
		return Color.MAGENTA
	return TABLE[terrain]["color"]

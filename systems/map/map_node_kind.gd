class_name MapNodeKind
extends RefCounted

## 地图节点类别。数值会进入局内存档，已有值不要重排。
enum Type {
	NONE = 0,
	START = 1,
	BATTLE = 2,
	ELITE = 3,
	BOSS = 4,
	EVENT = 5,
	SHOP = 6,
}


static func display_name(kind: int) -> String:
	match kind:
		Type.START:
			return "起点"
		Type.BATTLE:
			return "普通战斗"
		Type.ELITE:
			return "精英战斗"
		Type.BOSS:
			return "Boss"
		Type.EVENT:
			return "随机事件"
		Type.SHOP:
			return "商店"
		_:
			return "无节点"


static func marker(kind: int) -> String:
	match kind:
		Type.START:
			return "起"
		Type.BATTLE:
			return "战"
		Type.ELITE:
			return "精"
		Type.BOSS:
			return "王"
		Type.EVENT:
			return "事"
		Type.SHOP:
			return "店"
		_:
			return ""


static func color(kind: int) -> Color:
	match kind:
		Type.START:
			return Color(0.45, 0.95, 0.55)
		Type.BATTLE:
			return Color(0.95, 0.72, 0.30)
		Type.ELITE:
			return Color(0.95, 0.35, 0.25)
		Type.BOSS:
			return Color(0.78, 0.18, 0.88)
		Type.EVENT:
			return Color(0.35, 0.75, 1.0)
		Type.SHOP:
			return Color(0.95, 0.90, 0.35)
		_:
			return Color.WHITE

class_name RandomEventCatalog
extends RefCounted
## 编号严格对应策划案顺序；仅派生独立种子，不消费主随机流。
const SCENE := "res://ui/events/random_event_scene.tscn"
const NAMES := ["伟大炼成", "医疗", "空置赌桌", "死亡与赋税", "许愿池", "与兽共斗",
	"伤害石碑", "器物告白", "典籍交换", "素材合成", "素材升级", "倾听海螺"]
const BACKGROUNDS := ["EVBG-001.png", "EVBG-002.jpg", "EVBG-003.png", "EVBG-004.png",
	"EVBG-005.png", "EVBG-006.jpg", "EVBG-007.png", "EVBG-008.jpg", "EVBG-009.png",
	"EVBG-010.jpg", "EVBG-011.jpg", "EVBG-012.png"]
const MapEventIds = preload("res://systems/map/flat_2d/alchemy_event_catalog.gd")

## 显式地图身份优先；旧地图仍沿用原来的独立事件种子。
## 仅用于尚未打开的事件，已提交的 RunRandomEvents 状态不重新解析。
static func index_for_map_node(seed_text: String, map_id: String, node: Dictionary) -> int:
	var content_id := str(node.get("content_id", ""))
	if content_id.begins_with("alchemy/events/"):
		var id := content_id.trim_prefix("alchemy/events/")
		var index: int = MapEventIds.ids().find(id)
		if index >= 0:
			return index
	return index_for_node(seed_text, map_id, str(node.get("node_id", node.get("id", ""))))

static func stream(seed_text: String, map_id: String, node_id: String, purpose := "identity") -> RandomStream:
	var source := SeedRegistry.new(str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	source.begin_run(seed_text)
	return source.get_stream(RandomDomains.EVENT_POOL, ["events-v1", map_id, node_id, purpose])

static func index_for_node(seed_text: String, map_id: String, node_id: String) -> int:
	return int(stream(seed_text, map_id, node_id).int_range(0, NAMES.size()))

static func background(index: int) -> String:
	return "res://assets/events/" + str(BACKGROUNDS[clampi(index, 0, 11)])

static func choices(index: int) -> Array:
	match index:
		0: return ["失去10生命，获得随机药水", "失去20生命，获得随机药水和普通卡包", "离开"]
		1: return ["恢复40生命", "恢复20生命，获得100银币", "失去20生命，获得500银币", "离开"]
		2: return ["花费400银币抽取奖励（最多三次）", "离开"]
		3: return ["失去10生命，获得普通卡包", "失去20生命，获得随机残片", "离开"]
		4: return ["获得300银币", "花费200银币，为随机两张牌附魔", "花费500银币，选择两张牌附魔", "离开"]
		5: return ["挑战三只强化恶犬", "离开"]
		6: return ["开始三回合伤害试炼", "离开"]
		10: return ["选择升级素材", "离开"]
		7: return ["接受：获得圣杯幻象（负面卡牌）和稀有卡包", "拒绝：获得100银币", "离开"]
		8: return ["选择一个典籍残片交换", "离开"]
		9: return ["选择两张卡牌合成", "离开"]
		11: return ["被束缚：下场战斗牌位-1，胜利额外获得稀有卡包", "共歌唱：获得普通卡包", "砸碎：获得带随机负面效果的残片", "离开"]
	return []

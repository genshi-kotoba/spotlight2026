class_name CardEnchantments
extends RefCounted
## 附魔描述与约束的唯一来源；只在具体副本上保存 ID，不改 CardData 共享资源。
const DEFINITIONS := {
	"damage_50": {"name": "锋锐", "text": "该牌对敌人造成的直接伤害 +50%（向下取整）", "price": 100},
	"repeat_2": {"name": "回响", "text": "该牌总共触发两次", "price": 100},
}

static func valid(value: Variant) -> bool:
	if not value is Array or value.size() > 2:
		return false
	var seen := {}
	for id: Variant in value:
		if not id is String or not DEFINITIONS.has(id) or seen.has(id):
			return false
		seen[id] = true
	return true

static func can_apply(card: Dictionary, id: String) -> bool:
	var current: Array = card.get("enchantments", [])
	return DEFINITIONS.has(id) and current.size() < 2 and not current.has(id)

static func describe(card: Dictionary) -> String:
	var lines := PackedStringArray()
	for id: String in card.get("enchantments", []):
		if DEFINITIONS.has(id):
			lines.append("%s：%s" % [DEFINITIONS[id].name, DEFINITIONS[id].text])
	return "附魔（%d/2）\n%s" % [lines.size(), "\n".join(lines)] if not lines.is_empty() else "附魔（0/2）：无"

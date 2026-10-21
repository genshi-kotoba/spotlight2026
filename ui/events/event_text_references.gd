extends RefCounted
## 纯展示引用：只读取已知名称和已生成物品，不抽奖励、不修改事件或存档。
const NEGATIVE_CARDS := FormalCardCatalog.NEGATIVE_CARD_IDS
const RED := "ff7878"
const GOLD := "edc985"
const POTIONS := ["抽两张牌", "获得5点格挡", "复制一张手牌", "本回合增加一个牌位"]
const ITEM_TEXT := {
	"common_pack": "普通卡包\n放入背包后打开，从生成的普通卡牌候选中选择一张。",
	"rare_pack": "稀有卡包\n放入背包后打开，从生成的稀有卡牌候选中选择一张。",
	"pack": "卡包\n获得的是未打开的卡包，具体类型以本次事件的实际奖励为准。",
	"potion": "随机药水\n奖励生成后才确定种类：抽两张牌、获得5点格挡、复制一张手牌，或本回合增加一个牌位。",
	"fragment": "随机典籍残片\n奖励生成后才确定具体能力；可在背包与典籍中查看、装配。",
	"negative_fragment": "带负面效果的残片\n生成后同时具有残片能力和负面词条；请查看实际残片说明。",
	"enchantment": "附魔\n附加在所选卡牌副本上，同名牌的不同副本分别保存。具体结果生成后显示。",
	"conch": "海螺束缚\n下一场战斗减少一个牌位，胜利额外获得稀有卡包。伤害石碑不消耗束缚。",
}
static var _cards: Array = []

static func candidates(extra: Array = []) -> Array:
	if _cards.is_empty():
		for card: Dictionary in TextCatalog.entries("cards"):
			if not str(card.get("name", "")).is_empty():
				_cards.append({"alias": str(card.name), "kind": "card", "id": str(card.id)})
	var result: Array = extra.duplicate(true)
	result.append_array(_cards)
	for pair: Array in [["普通卡牌包", "common_pack"], ["普通卡包", "common_pack"],
		["稀有卡牌包", "rare_pack"], ["稀有卡包", "rare_pack"], ["卡包", "pack"],
		["带随机负面效果的残片", "negative_fragment"], ["典籍残片", "fragment"], ["随机残片", "fragment"],
		["随机药水", "potion"], ["药水", "potion"], ["附魔", "enchantment"], ["海螺束缚", "conch"]]:
		result.append({"alias": str(pair[0]), "kind": "item", "id": str(pair[1])})
	for index in POTIONS.size():
		result.append({"alias": str(POTIONS[index]), "kind": "potion", "id": str(index)})
	return result

static func decorate(plain: String, extra: Array = []) -> Dictionary:
	var choices := candidates(extra)
	var refs := {}
	var output := ""
	var cursor := 0
	while cursor < plain.length():
		var next := plain.length()
		var picked: Dictionary = {}
		for value: Dictionary in choices:
			var alias := str(value.get("alias", ""))
			if alias.is_empty(): continue
			var at := plain.find(alias, cursor)
			if at >= 0 and (at < next or (at == next and alias.length() > str(picked.get("alias", "")).length())):
				next = at
				picked = value
		output += escape(plain.substr(cursor, next - cursor))
		if picked.is_empty(): break
		var token := "object_%d" % refs.size()
		refs[token] = picked.duplicate(true)
		var negative: bool = (picked.kind == "card" and str(picked.id) in NEGATIVE_CARDS) or (picked.kind == "item" and picked.id == "negative_fragment")
		output += "[url=%s][color=#%s][u]%s[/u][/color][/url]" % [token, RED if negative else GOLD, escape(str(picked.alias))]
		cursor = next + str(picked.alias).length()
	return {"text": output, "refs": refs}

static func fragment_reference(id: String) -> Dictionary:
	var fragment := RelicCatalog.resolve(id)
	return {} if fragment == null else {"alias": fragment.display_name, "kind": "fragment", "id": id}

static func description(reference: Dictionary) -> String:
	match str(reference.get("kind", "")):
		"fragment":
			var fragment := RelicCatalog.resolve(str(reference.get("id", "")))
			return fragment.rich_text(23) if fragment != null else "残片资料不可用"
		"potion":
			var index := int(reference.get("id", -1))
			return "药水\n" + POTIONS[index] + "\n战斗中使用一次" if index in range(POTIONS.size()) else "药水资料不可用"
		"item": return str(ITEM_TEXT.get(str(reference.get("id", "")), ""))
	return ""

static func escape(value: String) -> String:
	return value.replace("[", "[lb]")

extends RefCounted
## Pure material-upgrade operations. The caller owns authorization, snapshots,
## saving and rollback; previews never modify the run or consume an input.
const VERSION := 1
const POTION_NAMES := ["抽两张牌", "获得5点格挡", "复制一张手牌", "本回合增加一个牌位"]


static func candidates(run: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _editable(run):
		return result
	for raw: Variant in run.items:
		if not _eligible(raw):
			continue
		var item: Dictionary = raw
		if _input_index(run, str(item.item_id)) < 0:
			continue
		var source_label := "普通卡包 → 药水三选一"
		if item.kind == "potion":
			source_label = "药水 · %s → 典籍残片三选一" % POTION_NAMES[int(item.potion)]
		elif item.kind == "fragment":
			var fragment: RelicFragmentData = RelicCatalog.resolve(str(item.fragment_id))
			source_label = "典籍残片 · %s → 稀有卡包" % fragment.display_name
		result.append({"id": str(item.item_id), "kind": str(item.kind),
			"label": source_label + "\n物品：" + str(item.item_id)})
	return result


static func offers(run: Node, item_id: String, rng: RandomStream) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var index := _input_index(run, item_id)
	if index < 0:
		return result
	var input: Dictionary = run.items[index]
	if input.kind == "fragment":
		# Final tier is a sealed rare pack, granted directly after input confirmation.
		result.append(_offer(item_id, "fragment", "rare_pack", "rare_pack", true))
		return result
	if rng == null:
		return result
	if input.kind == "common_pack":
		var potions: Array = [0, 1, 2, 3]
		if rng.shuffle_in_place(potions) != OK:
			return result
		for position in range(3):
			var potion := int(potions[position])
			var offer := _offer(item_id, "common_pack", "potion", "potion:%d" % potion)
			offer["potion"] = potion
			result.append(offer)
	else:
		var definitions := RelicCatalog.load_definitions()
		var primaries: Array = []
		for id: String in RelicCatalog.reward_ids(definitions):
			if definitions[id].kind in [RelicFragmentData.Kind.TRIGGER, RelicFragmentData.Kind.EFFECT]:
				primaries.append(id)
		if primaries.size() < 3 or rng.shuffle_in_place(primaries) != OK:
			return result
		for position in range(3):
			# Distinct primary abilities ensure all three generated combinations differ.
			var fragment_id := RelicCatalog.generate(rng, str(primaries[position]))
			var offer := _offer(item_id, "potion", "fragment", "fragment:" + fragment_id)
			offer["fragment_id"] = fragment_id
			if not valid_offer(offer, "potion", item_id):
				return []
			result.append(offer)
	return result


static func apply_choice(run: Node, item_id: String, offer: Dictionary) -> Dictionary:
	var index := _input_index(run, item_id)
	if index < 0:
		return _failure(ERR_DOES_NOT_EXIST)
	var input: Dictionary = run.items[index]
	if not valid_offer(offer, str(input.kind), item_id):
		return _failure(ERR_INVALID_DATA)
	var inventory: Variant = run.get("inventory_state")
	if not inventory is Dictionary or not _whole(inventory.get("next_item")) or int(inventory.next_item) < 0:
		return _failure(ERR_INVALID_DATA)
	var serial := int(inventory.next_item) + 1
	var output_id := "event-upgrade-%d" % serial
	for raw: Variant in run.items:
		if raw is Dictionary and raw.get("item_id") == output_id:
			return _failure(ERR_ALREADY_EXISTS)
	var output := {"item_id": output_id, "kind": str(offer.kind)}
	var result_fragments: Array[String] = []
	if offer.kind == "potion":
		output["potion"] = int(offer.potion)
	elif offer.kind == "fragment":
		output["fragment_id"] = str(offer.fragment_id)
		result_fragments.append(str(offer.fragment_id))
	else:
		output["options"] = []
		output["rerolled"] = false
	# No mutation precedes the complete preflight. Replace exactly the selected
	# input item with one output; the caller atomically commits or restores this.
	run.items[index] = output
	run.inventory_state.next_item = serial
	return {"error": OK, "result": "素材升级获得：" + label(offer), "result_fragments": result_fragments}


static func valid_offer(value: Variant, source_kind: String = "", input_id: String = "") -> bool:
	if not value is Dictionary or not _whole(value.get("version")) or int(value.version) != VERSION:
		return false
	if not value.get("id") is String or not value.get("input_id") is String or str(value.input_id).is_empty():
		return false
	if not value.get("source_kind") is String or not value.get("kind") is String or not value.get("direct") is bool:
		return false
	if (not source_kind.is_empty() and value.source_kind != source_kind) or (not input_id.is_empty() and value.input_id != input_id):
		return false
	var fields: Array = ["version", "id", "input_id", "source_kind", "kind", "direct"]
	match str(value.source_kind):
		"common_pack":
			fields.append("potion")
			if value.kind != "potion" or value.direct or not _whole(value.get("potion")) or int(value.potion) not in range(POTION_NAMES.size()):
				return false
			if value.id != "potion:%d" % int(value.potion):
				return false
		"potion":
			fields.append("fragment_id")
			if value.kind != "fragment" or value.direct or not value.get("fragment_id") is String:
				return false
			if not _generated_fragment(str(value.fragment_id)) or value.id != "fragment:" + str(value.fragment_id):
				return false
		"fragment":
			if value.kind != "rare_pack" or not value.direct or value.id != "rare_pack":
				return false
		_:
			return false
	if value.size() != fields.size():
		return false
	for field: String in fields:
		if not value.has(field):
			return false
	return true


static func valid_offers(values: Variant, source_kind: String = "", input_id: String = "") -> bool:
	if not values is Array or values.is_empty() or not valid_offer(values[0], source_kind, input_id):
		return false
	var kind := str(values[0].source_kind)
	var input := str(values[0].input_id)
	if values.size() != (1 if kind == "fragment" else 3):
		return false
	var seen := {}
	for raw: Variant in values:
		if not valid_offer(raw, kind, input) or seen.has(raw.id):
			return false
		seen[raw.id] = true
	return true


static func label(offer: Dictionary) -> String:
	if not valid_offer(offer):
		return "无效升级结果"
	if offer.kind == "potion":
		return "药水 · " + str(POTION_NAMES[int(offer.potion)])
	if offer.kind == "fragment":
		var fragment: RelicFragmentData = RelicCatalog.resolve(str(offer.fragment_id))
		return "典籍残片 · " + fragment.display_name
	return "稀有卡包 × 1"


static func _offer(input_id: String, source_kind: String, kind: String, id: String, direct: bool = false) -> Dictionary:
	return {"version": VERSION, "id": id, "input_id": input_id,
		"source_kind": source_kind, "kind": kind, "direct": direct}


static func _editable(run: Node) -> bool:
	return is_instance_valid(run) and run.get("active") == true and run.get("current_battle") == null and run.get("items") is Array


static func _input_index(run: Node, item_id: String) -> int:
	if not _editable(run) or item_id.is_empty():
		return -1
	var found := -1
	for position in run.items.size():
		var raw: Variant = run.items[position]
		if not raw is Dictionary or raw.get("item_id") != item_id:
			continue
		if found >= 0 or not _eligible(raw):
			return -1
		found = position
	return found


static func _eligible(value: Variant) -> bool:
	if not value is Dictionary or not value.get("item_id") is String or str(value.item_id).is_empty():
		return false
	match str(value.get("kind", "")):
		"common_pack":
			return value.get("options") is Array and value.options.is_empty() and value.get("rerolled") == false
		"potion":
			return _whole(value.get("potion")) and int(value.potion) in range(POTION_NAMES.size())
		"fragment":
			return value.get("fragment_id") is String and RelicCatalog.resolve(str(value.fragment_id)) != null
	return false


static func _generated_fragment(id: String) -> bool:
	if not id.begins_with("RF1/"):
		return false
	var data: RelicFragmentData = RelicCatalog.resolve(id)
	if data == null:
		return false
	var rewards := RelicCatalog.reward_ids()
	return data.base_fragment_id in rewards and data.name_fragment_id in rewards


static func _whole(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and absf(float(value)) < 9007199254740991.0


static func _failure(error: int) -> Dictionary:
	return {"error": error, "result": "", "result_fragments": []}

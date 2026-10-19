class_name RunShop
extends RefCounted
## 每层/节点单独持久化货架；所有交易使用奖励系统相同的原子保存/回滚。
static func key(map_id: String, node_id: String) -> String:
	return map_id + "/" + node_id

static func generate(seed_text: String, map_id: String, node_id: String, floor_index: int) -> Dictionary:
	var source := SeedRegistry.new(str(ProjectSettings.get_setting("application/config/seed_content_version", "")))
	source.begin_run(seed_text)
	var rng := source.get_stream(RandomDomains.SHOP, ["shelf-v1", map_id, node_id])
	var common := RunRewards._card_pool("common_pack")
	var rare := RunRewards._card_pool("rare_pack")
	if rng == null or common.size() < 6:
		return {}
	common.sort()
	rare.sort()
	rng.shuffle_in_place(common)
	rng.shuffle_in_place(rare)
	var ids: Array = common.slice(0, 6)
	# 稀有出现率作为测试规则暂定 50%，最多替换一格。
	if not rare.is_empty() and int(rng.int_range(0, 2)) == 1:
		ids[5] = rare[0]
	var extra := clampi(floor_index - 1, 0, 2) * 50
	var cards: Array = []
	var eligible: Array = []
	for index in ids.size():
		var is_rare := rare.has(ids[index])
		var price := (350 if is_rare else int(rng.int_range(100, 151))) + extra
		cards.append({"id": str(ids[index]), "base_price": price, "price": price, "discount": 10, "sold": false})
		if not is_rare:
			eligible.append(index)
	rng.shuffle_in_place(eligible)
	for index in 2:
		var offer: Dictionary = cards[eligible[index]]
		offer.discount = int(rng.int_range(2, 6)) if index == 0 else int(rng.int_range(5, 9))
		offer.price = int(floor(int(offer.base_price) * int(offer.discount) / 10.0))
	var enchantments: Array = []
	var enchant_ids := CardEnchantments.DEFINITIONS.keys()
	enchant_ids.sort()
	for index in 3:
		var id := str(rng.pick(enchant_ids))
		enchantments.append({"id": id, "price": int(CardEnchantments.DEFINITIONS[id].price), "sold": false})
	return {"version": 1, "floor": floor_index, "cards": cards, "enchantments": enchantments}

static func open(run: Node, request: Dictionary) -> Error:
	if not _authorized(run, request):
		return ERR_UNAUTHORIZED
	RunRewards.ensure_state(run)
	var shop_key := key(str(request.map_id), str(request.node_id))
	if run.inventory_state.get("shops", {}).has(shop_key):
		return OK
	var generated := generate(str(run.main_seed), str(request.map_id), str(request.node_id), int(request.floor_index))
	if generated.is_empty():
		return ERR_UNAVAILABLE
	var before := RunRewards._capture(run)
	if not run.inventory_state.has("shops"):
		run.inventory_state.shops = {}
	run.inventory_state.shops[shop_key] = generated
	return RunRewards._commit(run, before)

static func shelf(run: Node, request: Dictionary) -> Dictionary:
	return run.inventory_state.get("shops", {}).get(key(str(request.get("map_id", "")), str(request.get("node_id", ""))), {}).duplicate(true)

static func buy_card(run: Node, request: Dictionary, index: int) -> Error:
	return _buy(run, request, "cards", index, "")

static func buy_enchantment(run: Node, request: Dictionary, index: int, copy_id: String) -> Error:
	return _buy(run, request, "enchantments", index, copy_id)

static func _buy(run: Node, request: Dictionary, kind: String, index: int, copy_id: String) -> Error:
	if not _authorized(run, request):
		return ERR_UNAUTHORIZED
	var shop_key := key(str(request.map_id), str(request.node_id))
	var shop := shelf(run, request)
	if shop.is_empty() or index < 0 or index >= shop[kind].size():
		return ERR_INVALID_PARAMETER
	var offer: Dictionary = shop[kind][index]
	if bool(offer.sold):
		return ERR_ALREADY_EXISTS
	if run.gold < int(offer.price):
		return ERR_UNAVAILABLE
	run.ensure_deck_cards()
	var chosen := -1
	if kind == "enchantments":
		for position in run.deck_cards.size():
			if str(run.deck_cards[position].copy_id) == copy_id and CardEnchantments.can_apply(run.deck_cards[position], str(offer.id)):
				chosen = position
		if chosen < 0:
			return ERR_INVALID_PARAMETER
	var before := RunRewards._capture(run)
	run.gold -= int(offer.price)
	if kind == "cards":
		if not run.card_pool.has(str(offer.id)):
			run.card_pool.append(str(offer.id))
		run.add_card(str(offer.id), false)
	else:
		run.deck_cards[chosen].enchantments.append(str(offer.id))
	run.inventory_state.shops[shop_key][kind][index].sold = true
	return RunRewards._commit(run, before)

static func _authorized(run: Node, request: Dictionary) -> bool:
	if not RunRewards._can_edit(run) or not RunRewards.pending(run).is_empty():
		return false
	var session: RefCounted = EncounterFlow.session
	return session != null and not session.pending.is_empty() and request.get("type") == "shop" \
		and session.pending == request and request.get("map_id") == session.map_id \
		and run.map_ids.find(run.current_map_id) + 1 == int(request.get("floor_index", 0))

static func valid_shops(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for shop_key: Variant in value:
		var shop: Variant = value[shop_key]
		if not shop_key is String or not shop is Dictionary or not RunStateMachine._integer_equals(shop.get("version"), 1) or not shop.get("cards") is Array or shop.cards.size() != 6 or not shop.get("enchantments") is Array or shop.enchantments.size() != 3:
			return false
		var floor_index: Variant = RunStateMachine._integer_value(shop.get("floor"))
		if floor_index == null or floor_index < 1 or floor_index > 3:
			return false
		var seen := {}
		var discounted: Array[int] = []
		var rares := 0
		for offer: Variant in shop.cards:
			if not offer is Dictionary or not offer.get("id") is String or seen.has(offer.id) or not offer.get("sold") is bool:
				return false
			seen[offer.id] = true
			var entry := TextCatalog.entry("cards", str(offer.id))
			var base: Variant = RunStateMachine._integer_value(offer.get("base_price"))
			var price: Variant = RunStateMachine._integer_value(offer.get("price"))
			var discount: Variant = RunStateMachine._integer_value(offer.get("discount"))
			if entry.is_empty() or base == null or price == null or discount == null or price < 0 or discount not in range(2, 11):
				return false
			var extra := (int(shop.floor) - 1) * 50
			if str(entry.rarity) == "稀有":
				rares += 1
				if base != 350 + extra or discount != 10:
					return false
			elif str(entry.rarity) != "普通" or base < 100 + extra or base > 150 + extra:
				return false
			if price != int(floor(base * discount / 10.0)):
				return false
			if discount < 10:
				discounted.append(discount)
		discounted.sort()
		if rares > 1 or discounted.size() != 2 or discounted[0] not in range(2, 6) or discounted[1] not in range(5, 9):
			return false
		for offer: Variant in shop.enchantments:
			if not offer is Dictionary or not CardEnchantments.DEFINITIONS.has(offer.get("id")) or not offer.get("sold") is bool or offer.get("price") != 100:
				return false
	return true

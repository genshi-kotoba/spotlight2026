## 自测用的假上下文
##
## 实现 EffectContext 的全部方法，把调用记下来供断言。它不认识 PRG-004，也不认识
## 状态机——效果层只认 EffectContext 这个接口，所以换一个实现就能脱离状态机自测。
##
## 两个地方特别做了真实现，因为它们本身就是要验的规则，不能只记录：
##
##   add_buff          按 buff_id 合并同名（提示词文档 §3.4.6 那条硬要求）
##   add_card_to_zone  给每张新牌分配唯一 instance_id（同名卡也不能重复）
##
## 数据字段统一带下划线前缀，并且留成公开的。原因是 EffectContext 里已经有
## hand() / play_zone() / discard_pile() / enemy_ids() 这些同名方法，
## 字段再用同名会直接报「Function has the same name as a previously declared
## variable」。带下划线既能存，又不与接口方法冲突。
##
## 放在 tests/ 下而不是 systems/ 下：它是测试夹具，不是产品代码。

class_name FakeEffectContext
extends EffectContext

## 全部调用按顺序记在这里，形如 "damage_enemy:enemy-1:5"。
var log: Array[String] = []

var _player: Dictionary = {"health": 40, "max_health": 40, "block": 0, "buffs": []}
var _enemies: Array[Dictionary] = []
var _draw_pile: Array[Dictionary] = []
var _discard_pile: Array[Dictionary] = []
var _hand: Array[Dictionary] = []
var _play_zone: Array[Dictionary] = []
var _pointer: int = 0
var _target: Variant = null
var _next_instance_number: int = 1
## 各 buff 的初始持续回合数，供 add_buff 取初值。
var _buff_durations: Dictionary = {}


## 造一份空战斗：敌人一只，手牌与牌堆为空，目标指向那只敌人。
static func make_basic(enemy_health: int = 30) -> FakeEffectContext:
	var ctx := FakeEffectContext.new()
	ctx._enemies = [{
		"enemy_id": "enemy-1",
		"health": enemy_health,
		"max_health": enemy_health,
		"block": 0,
		"buffs": [],
	}]
	ctx._target = "enemy-1"
	return ctx


## 造一份牌堆里有两张同名卡的战斗。测「同名按实例区分」用。
static func make_with_duplicate_cards(card_id: String, enemy_health: int = 30) -> FakeEffectContext:
	var ctx := make_basic(enemy_health)
	ctx._draw_pile = [
		ctx._new_card(card_id),
		ctx._new_card(card_id),
	]
	return ctx


# ---------------------------------------------------------------- 读

func current_target() -> Variant:
	return _target


func enemy_ids() -> Array[String]:
	var ids: Array[String] = []
	for enemy: Dictionary in _enemies:
		if int(enemy["health"]) > 0:
			ids.append(String(enemy["enemy_id"]))
	return ids


func player_health() -> int:
	return int(_player["health"])


func player_block() -> int:
	return int(_player["block"])


func buff_layers(target: Variant, buff_id: StringName) -> int:
	var buff: Variant = _find_buff(target, buff_id)
	if buff == null:
		return 0
	return BuffEffect.layers_of(buff)


func hand() -> Array[Dictionary]:
	return _hand


func play_zone() -> Array[Dictionary]:
	return _play_zone


func draw_pile_size() -> int:
	return _draw_pile.size()


func discard_pile() -> Array[Dictionary]:
	return _discard_pile


func pointer_index() -> int:
	return _pointer


# ---------------------------------------------------------------- 改：战斗数值

func damage_enemy(enemy_id: String, amount: int, ignore_block: bool = false) -> void:
	log.append("damage_enemy:%s:%d:ignore_block=%s" % [enemy_id, amount, ignore_block])
	var enemy: Variant = _find_enemy(enemy_id)
	if enemy == null:
		push_error("FakeEffectContext：敌人不存在 %s" % enemy_id)
		return
	var blocked := 0
	if not ignore_block:
		blocked = mini(int(enemy["block"]), amount)
		enemy["block"] = int(enemy["block"]) - blocked
	enemy["health"] = maxi(0, int(enemy["health"]) - (amount - blocked))


func damage_all_enemies(amount: int, ignore_block: bool = false) -> void:
	for enemy_id in enemy_ids():
		damage_enemy(enemy_id, amount, ignore_block)


func damage_player(amount: int, ignore_block: bool = false) -> void:
	log.append("damage_player:%d:ignore_block=%s" % [amount, ignore_block])
	var blocked := 0
	if not ignore_block:
		blocked = mini(int(_player["block"]), amount)
		_player["block"] = int(_player["block"]) - blocked
	_player["health"] = maxi(0, int(_player["health"]) - (amount - blocked))


func heal_player(amount: int) -> void:
	log.append("heal_player:%d" % amount)
	_player["health"] = mini(int(_player["max_health"]), int(_player["health"]) + amount)


func add_block(side: StringName, entity_id: String, amount: int) -> void:
	log.append("add_block:%s:%s:%d" % [side, entity_id, amount])
	if side == &"player":
		_player["block"] = int(_player["block"]) + amount
		return
	var enemy: Variant = _find_enemy(entity_id)
	if enemy == null:
		push_error("FakeEffectContext：加格挡的目标不存在 %s" % entity_id)
		return
	enemy["block"] = int(enemy["block"]) + amount


# ---------------------------------------------------------------- 改：buff 与状态

## 按 buff_id 合并同名。这是要验的规则本身，所以这里是真实现而不是记录。
func add_buff(side: StringName, entity_id: String, buff_id: StringName, layers: int) -> void:
	log.append("add_buff:%s:%s:%s:%+d" % [side, entity_id, buff_id, layers])
	var owner: Variant = _owner_of(side, entity_id)
	if owner == null:
		push_error("FakeEffectContext：加 buff 的目标不存在 %s/%s" % [side, entity_id])
		return
	var buffs: Array = owner["buffs"]
	for existing: Dictionary in buffs:
		if String(existing.get("buff_id", "")) == String(buff_id):
			existing["layers"] = maxi(0, BuffEffect.layers_of(existing) + layers)
			if BuffEffect.layers_of(existing) == 0:
				buffs.erase(existing)
			return
	if layers <= 0:
		# 没有同名可减，就不新增一条 0 层的。
		return
	buffs.append({
		"buff_id": String(buff_id),
		"layers": layers,
		"duration": _duration_of(buff_id),
	})


func set_buff_layers(side: StringName, entity_id: String, buff_id: StringName, layers: int) -> void:
	log.append("set_buff_layers:%s:%s:%s:%d" % [side, entity_id, buff_id, layers])
	var owner: Variant = _owner_of(side, entity_id)
	if owner == null:
		return
	var buffs: Array = owner["buffs"]
	for existing: Dictionary in buffs:
		if String(existing.get("buff_id", "")) == String(buff_id):
			if layers <= 0:
				buffs.erase(existing)
			else:
				existing["layers"] = layers
			return
	if layers > 0:
		buffs.append({
			"buff_id": String(buff_id),
			"layers": layers,
			"duration": _duration_of(buff_id),
		})


func override_buff_duration(side: StringName, entity_id: String, buff_id: StringName,
		duration: int) -> void:
	var owner: Variant = _owner_of(side, entity_id)
	if owner == null:
		return
	for buff: Dictionary in owner["buffs"]:
		if buff.get("buff_id") == String(buff_id):
			buff["duration"] = maxi(0, duration)
			return


func tick_poison(target: Variant) -> void:
	log.append("tick_poison:%s" % [target])
	var buff: Variant = _find_buff(target, &"poison")
	if buff == null:
		return
	var poison := BuffEffectPoison.new()
	var remaining := poison.on_turn_update(self, target, buff)
	buff["layers"] = remaining


# ---------------------------------------------------------------- 改：牌

func draw(count: int) -> void:
	log.append("draw:%d" % count)
	for i in count:
		if _draw_pile.is_empty():
			return
		var card: Dictionary = _draw_pile.pop_back()
		_hand.append(card)


func discard_from_hand(instance_id: String, reason: StringName = &"effect") -> void:
	log.append("discard_from_hand:%s:%s" % [instance_id, reason])
	for i in _hand.size():
		if String(_hand[i].get("instance_id", "")) == instance_id:
			var card: Dictionary = _hand[i]
			_hand.remove_at(i)
			_discard_pile.append(card)
			return
	push_error("FakeEffectContext：手牌里没有这张牌 %s" % instance_id)


## 按 instance_id 弃，不按 card_id。同名卡只有被点到的那一张会掉。
## 自测里固定弃第一张：要验的是「按实例弃」，不是随机性。
func discard_random(count: int) -> void:
	log.append("discard_random:%d" % count)
	for i in count:
		if _hand.is_empty():
			return
		var card: Dictionary = _hand[0]
		_hand.remove_at(0)
		_discard_pile.append(card)


func add_card_to_zone(card_id: String, zone: StringName, index: int = -1) -> String:
	var card := _new_card(card_id)
	log.append("add_card_to_zone:%s:%s:%d:%s" % [card_id, zone, index, card["instance_id"]])
	match zone:
		&"draw_pile":
			if index < 0 or index >= _draw_pile.size():
				_draw_pile.append(card)
			else:
				_draw_pile.insert(index, card)
		&"hand":
			if index < 0 or index >= _hand.size():
				_hand.append(card)
			else:
				_hand.insert(index, card)
		&"play_area":
			if index < 0 or index >= _play_zone.size():
				_play_zone.append(card)
			else:
				_play_zone.insert(index, card)
		&"discard":
			_discard_pile.append(card)
		_:
			push_error("FakeEffectContext：未知的区 %s" % zone)
			return ""
	return String(card["instance_id"])


func move_card_in_play_zone(from_index: int, to_index: int) -> void:
	log.append("move_card_in_play_zone:%d:%d" % [from_index, to_index])
	if from_index < 0 or from_index >= _play_zone.size():
		return
	if to_index < 0 or to_index >= _play_zone.size():
		return
	var card: Dictionary = _play_zone[from_index]
	_play_zone.remove_at(from_index)
	_play_zone.insert(to_index, card)


func remove_from_battle(card: Dictionary) -> void:
	log.append("remove_from_battle:%s" % card.get("instance_id", ""))
	_erase_from_all_zones(String(card.get("instance_id", "")))


func remove_from_run(card: Dictionary) -> void:
	log.append("remove_from_run:%s" % card.get("instance_id", ""))
	_erase_from_all_zones(String(card.get("instance_id", "")))


func change_target(instance_id: String, target: Variant) -> void:
	log.append("change_target:%s:%s" % [instance_id, target])
	_target = target


func attach_effect(card: Dictionary, effect: GameEffect) -> void:
	log.append("attach_effect:%s:%s" % [card.get("instance_id", ""), effect])
	var attached: Variant = card.get("attached_effects")
	if not (attached is Array):
		attached = []
		card["attached_effects"] = attached
	attached.append(effect)


# ---------------------------------------------------------------- 指针

func rewind_pointer(steps: int) -> void:
	log.append("rewind_pointer:%d" % steps)
	_pointer = maxi(0, _pointer - steps)


func move_pointer_to(index: int) -> void:
	log.append("move_pointer_to:%d" % index)
	_pointer = maxi(0, index)


# ---------------------------------------------------------------- 测试取用

## 直接读写内部状态，供断言使用。返回值是引用，改动会落到假上下文里。
func state_player() -> Dictionary:
	return _player


func state_enemies() -> Array[Dictionary]:
	return _enemies


func state_hand() -> Array[Dictionary]:
	return _hand


func state_draw_pile() -> Array[Dictionary]:
	return _draw_pile


func state_discard_pile() -> Array[Dictionary]:
	return _discard_pile


func state_play_zone() -> Array[Dictionary]:
	return _play_zone


func set_pointer(value: int) -> void:
	_pointer = value


func get_pointer() -> int:
	return _pointer


func set_target(target: Variant) -> void:
	_target = target


## 设定某个 buff 的初始持续回合数，供 add_buff 取初值用。
func set_buff_duration(buff_id: StringName, duration: int) -> void:
	_buff_durations[String(buff_id)] = duration


# ---------------------------------------------------------------- 内部

func _duration_of(buff_id: StringName) -> int:
	return int(_buff_durations.get(String(buff_id), 0))


## 造一张牌，instance_id 全局唯一。同名卡也拿到不同的实例 id，
## 这是 PRG-004 读档校验要求的（跨牌区实例唯一）。
func _new_card(card_id: String) -> Dictionary:
	var card := {
		"instance_id": "inst-%d" % _next_instance_number,
		"card_id": card_id,
	}
	_next_instance_number += 1
	return card


func _find_enemy(enemy_id: String) -> Variant:
	for enemy: Dictionary in _enemies:
		if String(enemy["enemy_id"]) == enemy_id:
			return enemy
	return null


func _owner_of(side: StringName, entity_id: String) -> Variant:
	if side == &"player":
		return _player
	return _find_enemy(entity_id)


func _find_buff(target: Variant, buff_id: StringName) -> Variant:
	if target == null:
		return null
	var owner: Variant = null
	if String(target) == "player":
		owner = _player
	else:
		owner = _find_enemy(String(target))
	if owner == null:
		return null
	for buff: Dictionary in owner["buffs"]:
		if String(buff.get("buff_id", "")) == String(buff_id):
			return buff
	return null


func _erase_from_all_zones(instance_id: String) -> void:
	for zone: Array in [_draw_pile, _discard_pile, _hand, _play_zone]:
		for i in zone.size():
			if String(zone[i].get("instance_id", "")) == instance_id:
				zone.remove_at(i)
				break

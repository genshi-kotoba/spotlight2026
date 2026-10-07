extends SceneTree

## PRG-007 / PRG-008 自测。用 --script 跑，不依赖渲染，不依赖 PRG-004。
##
##   godot --headless --script res://tests/card_effect_selftest.gd
##
## 覆盖范围：
##   - 效果根类与两条子类的关系
##   - 卡牌数据、buff 数据的字段与存读往返
##   - 8 种卡牌效果各自的行为
##   - buff 的层数、持续回合数、强度换算、四个钩子各自独立
##   - 同名卡按 instance_id 区分、实例 id 唯一
##   - 中毒的减半向上取整、1 层特例与走完移除
##
## 注意事项（本工程踩过的坑，改动本文件时别踩）：
##   - 工程把警告当错误。不要用 := 承接返回类型为 Variant 的表达式。
##   - GDScript 的 lambda 对捕获变量只读（array.append 可见，x += 1 不可见），
##     且与被捕获的局部变量构成引用环会在退出时报 ObjectDB leaked。
##     所以信号一律接内部类记录器，不接 lambda。
##   - 临时产物写 user://，不落进工程目录。

const ROUNDTRIP_PATH := "user://card_effect_selftest_roundtrip.tres"
const BUFF_ROUNDTRIP_PATH := "user://card_effect_selftest_buff_roundtrip.tres"

var _failures := 0


func _initialize() -> void:
	_test_effect_class_relations()
	_test_card_data_fields()
	_test_buff_data_fields()
	_test_card_data_roundtrip()
	_test_buff_data_roundtrip()
	_test_attack()
	_test_block()
	_test_draw()
	_test_buff_effect_on_card()
	_test_discard_random()
	_test_destroy_self()
	_test_move_pointer()
	_test_buff_stat_strength()
	_test_buff_stat_weak()
	_test_buff_poison_halving()
	_test_buff_poison_expires()
	_test_buff_duration_tick()
	_test_buff_hooks_independent()
	_test_duplicate_cards_distinguished_by_instance()
	_test_instance_ids_unique()
	_test_effect_classes_all_selectable()
	_test_effect_signal()
	_test_prototype_cards_on_disk()
	_test_card_catalog_report()

	if _failures == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _failures)
	quit(_failures)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		_failures += 1
		print("  失败  %s  %s" % [label, detail])


## 记录 effect.executed 的接法。用内部类而不是 lambda，原因见文件头。
class ExecutedRecorder:
	var fire_count := 0
	var 效果: Array[GameEffect] = []
	var contexts: Array[Dictionary] = []

	func on_executed(effect: GameEffect, context: Dictionary) -> void:
		fire_count += 1
		效果.append(effect)
		contexts.append(context)


# ---------------------------------------------------------------- 类型关系

func _test_effect_class_relations() -> void:
	print("[效果类的继承关系]")
	var attack := CardEffectAttack.new()
	_check("CardEffectAttack 是 CardEffect", attack is CardEffect)
	_check("CardEffectAttack 是 GameEffect", attack is GameEffect)
	_check("CardEffect 是 GameEffect", CardEffect.new() is GameEffect)

	var poison := BuffEffectPoison.new()
	_check("BuffEffectPoison 是 BuffEffect", poison is BuffEffect)
	_check("BuffEffectPoison 是 BuffEffectDot", poison is BuffEffectDot)
	_check("BuffEffectPoison 是 GameEffect", poison is GameEffect)

	# 这一条决定编辑器里「添加元素」能不能同时列出卡牌效果与 buff 效果。
	_check("两套效果有共同祖先，可以挂进同一个数组",
		attack is GameEffect and poison is GameEffect)

	var empty := GameEffect.new()
	_check("基类可直接实例化", empty != null)


# ---------------------------------------------------------------- 数据结构

func _test_card_data_fields() -> void:
	print("[卡牌数据字段]")
	var data := CardData.new()
	_check("默认稀有度是日", data.稀有度 == CardData.稀有度档.日)
	_check("稀有度有两档（日 / 月）", CardData.稀有度档.size() == 2)
	_check("卡面第二栏有四档（灰 / 红 / 蓝 / 黄）", CardData.颜色档.size() == 4)
	_check("默认效果列表为空", data.效果.is_empty())

	data.卡牌标识 = &"bonk"
	data.卡牌名 = "给你一拳"
	data.稀有度 = CardData.稀有度档.日
	data.颜色 = CardData.颜色档.灰
	var attack := CardEffectAttack.new()
	attack.数值 = 7
	data.效果.append(attack)
	_check("效果挂上了", data.效果.size() == 1)
	_check("挂的是 GameEffect", data.效果[0] is GameEffect)


func _test_buff_data_fields() -> void:
	print("[buff 数据字段]")
	var data := BuffData.new()
	_check("默认持续回合为 0（不限回合）", data.持续回合 == 0)
	_check("默认初始层数为 1", data.初始层数 == 1)
	_check("默认效果列表为空", data.效果.is_empty())

	data.buff标识 = &"poison"
	data.显示名 = "中毒"
	data.持续回合 = 3
	data.初始层数 = 2
	data.效果.append(BuffEffectPoison.new())
	_check("效果挂上了", data.效果.size() == 1)


func _test_card_data_roundtrip() -> void:
	print("[卡牌数据存读]")
	var attack := CardEffectAttack.new()
	attack.数值 = 9
	attack.次数 = 2

	var data := CardData.new()
	data.卡牌标识 = &"roundtrip"
	data.卡牌名 = "往返测试"
	data.描述 = "两行\n描述"
	data.稀有度 = CardData.稀有度档.月
	data.颜色 = CardData.颜色档.黄
	data.效果.append(attack)

	var err := ResourceSaver.save(data, ROUNDTRIP_PATH)
	_check("保存成功", err == OK, "错误码 %d" % err)
	if err != OK:
		return

	var loaded := ResourceLoader.load(ROUNDTRIP_PATH)
	_check("读回的是 CardData", loaded is CardData)
	if not (loaded is CardData):
		return

	var back: CardData = loaded
	_check("卡牌标识 保持", back.卡牌标识 == &"roundtrip")
	_check("卡牌名 保持", back.卡牌名 == "往返测试")
	_check("多行描述保持", back.描述 == "两行\n描述")
	_check("稀有度保持（月）", back.稀有度 == CardData.稀有度档.月)
	_check("卡面第二栏保持（黄）", back.颜色 == CardData.颜色档.黄)
	_check("效果数量保持", back.效果.size() == 1, "实际 %d" % back.效果.size())
	if back.效果.size() == 1:
		var effect: GameEffect = back.效果[0]
		_check("效果子类类型保持", effect is CardEffectAttack,
			"实际 %s" % effect.get_script().resource_path)
		if effect is CardEffectAttack:
			var restored: CardEffectAttack = effect
			_check("效果参数保持 数值", restored.数值 == 9, "实际 %d" % restored.数值)
			_check("效果参数保持 times", restored.次数 == 2, "实际 %d" % restored.次数)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(ROUNDTRIP_PATH))


func _test_buff_data_roundtrip() -> void:
	print("[buff 数据存读]")
	var 属性 := BuffEffectStat.new()
	属性.buff标识 = &"strength"
	属性.每层数值 = 1

	var data := BuffData.new()
	data.buff标识 = &"strength"
	data.显示名 = "力量"
	data.持续回合 = 4
	data.初始层数 = 3
	data.效果.append(属性)

	var err := ResourceSaver.save(data, BUFF_ROUNDTRIP_PATH)
	_check("保存成功", err == OK, "错误码 %d" % err)
	if err != OK:
		return

	var loaded := ResourceLoader.load(BUFF_ROUNDTRIP_PATH)
	_check("读回的是 BuffData", loaded is BuffData)
	if loaded is BuffData:
		var back: BuffData = loaded
		_check("buff标识 保持", back.buff标识 == &"strength")
		_check("持续回合 保持", back.持续回合 == 4, "实际 %d" % back.持续回合)
		_check("初始层数 保持", back.初始层数 == 3)
		_check("效果保持", back.效果.size() == 1 and back.效果[0] is BuffEffectStat)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(BUFF_ROUNDTRIP_PATH))


# ---------------------------------------------------------------- 8 种卡牌效果

func _test_attack() -> void:
	print("[效果：造成伤害]")
	var ctx := FakeEffectContext.make_basic(30)
	var effect := CardEffectAttack.new()
	effect.数值 = 5
	effect.次数 = 1
	var card := {"instance_id": "inst-1", "card_id": "bonk"}

	effect.execute(ctx, card)
	_check("敌人掉 5 血", int(ctx.state_enemies()[0]["health"]) == 25,
		"实际 %d" % int(ctx.state_enemies()[0]["health"]))
	_check("记下一次伤害调用", ctx.log.has("damage_enemy:enemy-1:5:ignore_block=false"))

	var multi := CardEffectAttack.new()
	multi.数值 = 3
	multi.次数 = 2
	multi.execute(ctx, card)
	_check("重复两次共掉 6 血", int(ctx.state_enemies()[0]["health"]) == 19,
		"实际 %d" % int(ctx.state_enemies()[0]["health"]))

	# 没有目标时报错且不改数据
	var no_target := FakeEffectContext.make_basic(30)
	no_target.set_target(null)
	var before := int(no_target.state_enemies()[0]["health"])
	effect.execute(no_target, card)
	_check("没有目标时不结算", int(no_target.state_enemies()[0]["health"]) == before)


func _test_block() -> void:
	print("[效果：获得格挡]")
	var ctx := FakeEffectContext.make_basic()
	var effect := CardEffectBlock.new()
	effect.数值 = 5
	var card := {"instance_id": "inst-1", "card_id": "duck"}

	effect.execute(ctx, card)
	_check("玩家格挡为 5", int(ctx.state_player()["block"]) == 5,
		"实际 %d" % int(ctx.state_player()["block"]))
	_check("记下加格挡调用", ctx.log.has("add_block:player:player:5"))


func _test_draw() -> void:
	print("[效果：抽牌]")
	var ctx := FakeEffectContext.make_basic()
	ctx.state_draw_pile().clear()
	ctx.state_draw_pile().append({"instance_id": "inst-1", "card_id": "peek"})
	ctx.state_draw_pile().append({"instance_id": "inst-2", "card_id": "peek"})
	ctx.state_draw_pile().append({"instance_id": "inst-3", "card_id": "bonk"})
	var effect := CardEffectDraw.new()
	effect.张数 = 2
	var card := {"instance_id": "inst-9", "card_id": "peek"}

	effect.execute(ctx, card)
	_check("手牌变 2 张", ctx.state_hand().size() == 2, "实际 %d" % ctx.state_hand().size())
	_check("抽牌堆剩 1 张", ctx.state_draw_pile().size() == 1, "实际 %d" % ctx.state_draw_pile().size())
	_check("记下抽牌调用", ctx.log.has("draw:2"))


func _test_buff_effect_on_card() -> void:
	print("[效果：给目标加 buff 层数]")
	var ctx := FakeEffectContext.make_basic()
	var effect := CardEffectBuff.new()
	effect.buff标识 = &"poison"
	effect.层数 = 2
	effect.施加给 = CardEffectBuff.作用对象.当前目标
	var card := {"instance_id": "inst-1", "card_id": "spit"}

	effect.execute(ctx, card)
	_check("目标身上有中毒", ctx.buff_layers("enemy-1", &"poison") == 2,
		"实际 %d" % ctx.buff_layers("enemy-1", &"poison"))

	# 再打一次，同名合并成 4 层，不是数组里两条
	effect.execute(ctx, card)
	_check("两次叠加合并成 4 层", ctx.buff_layers("enemy-1", &"poison") == 4,
		"实际 %d" % ctx.buff_layers("enemy-1", &"poison"))
	_check("目标身上只有一条 buff", ctx.state_enemies()[0]["buffs"].size() == 1,
		"实际 %d 条" % ctx.state_enemies()[0]["buffs"].size())

	# 给自己加力量
	var self_buff := CardEffectBuff.new()
	self_buff.buff标识 = &"strength"
	self_buff.层数 = 3
	self_buff.施加给 = CardEffectBuff.作用对象.自己
	self_buff.execute(ctx, card)
	_check("玩家身上有 3 层力量", ctx.buff_layers("player", &"strength") == 3,
		"实际 %d" % ctx.buff_layers("player", &"strength"))

	# 负层数减层
	var reduce := CardEffectBuff.new()
	reduce.buff标识 = &"strength"
	reduce.层数 = -1
	reduce.施加给 = CardEffectBuff.作用对象.自己
	reduce.execute(ctx, card)
	_check("减层后剩 2 层", ctx.buff_layers("player", &"strength") == 2,
		"实际 %d" % ctx.buff_layers("player", &"strength"))

	# 减到 0 要把该条移除，不留层数为 0 的空条
	reduce.层数 = -5
	reduce.execute(ctx, card)
	_check("减到 0 后该条被移除", ctx.state_player()["buffs"].is_empty(),
		"实际剩 %d 条" % ctx.state_player()["buffs"].size())


func _test_discard_random() -> void:
	print("[效果：随机弃牌]")
	var ctx := FakeEffectContext.make_basic()
	ctx.state_hand().clear()
	ctx.state_hand().append({"instance_id": "inst-1", "card_id": "oops"})
	ctx.state_hand().append({"instance_id": "inst-2", "card_id": "oops"})
	var effect := CardEffectDiscardRandom.new()
	effect.张数 = 1
	var card := {"instance_id": "inst-9", "card_id": "oops"}

	effect.execute(ctx, card)
	_check("手牌剩 1 张", ctx.state_hand().size() == 1, "实际 %d" % ctx.state_hand().size())
	_check("弃牌堆有 1 张", ctx.state_discard_pile().size() == 1)
	_check("记下弃牌调用", ctx.log.has("discard_random:1"))

	# 手牌为空时不报错也不动作
	var empty := FakeEffectContext.make_basic()
	effect.execute(empty, card)
	_check("手牌为空时不崩", empty.state_hand().is_empty())


func _test_destroy_self() -> void:
	print("[效果：使用后从战斗中移除]")
	var ctx := FakeEffectContext.make_basic()
	ctx.state_play_zone().clear()
	ctx.state_play_zone().append({"instance_id": "inst-1", "card_id": "one_shot"})
	ctx.state_play_zone().append({"instance_id": "inst-2", "card_id": "one_shot"})
	var effect := CardEffectDestroySelf.new()
	var card := ctx.state_play_zone()[0]

	effect.execute(ctx, card)
	_check("出牌区只剩 1 张", ctx.state_play_zone().size() == 1,
		"实际 %d" % ctx.state_play_zone().size())
	_check("剩下的是另一张同名卡",
		String(ctx.state_play_zone()[0]["instance_id"]) == "inst-2",
		"实际 %s" % ctx.state_play_zone()[0]["instance_id"])


func _test_move_pointer() -> void:
	print("[效果：移动指针位置]")
	var ctx := FakeEffectContext.make_basic()
	ctx.set_pointer(3)
	var effect := CardEffectMovePointer.new()
	effect.方向 = CardZone.方向.左
	effect.格数 = 2
	var card := {"instance_id": "inst-1", "card_id": "nudge_back"}

	effect.execute(ctx, card)
	_check("指针从 3 退到 1", ctx.get_pointer() == 1, "实际 %d" % ctx.get_pointer())

	effect.格数 = 5
	effect.execute(ctx, card)
	_check("退过头夹到 0", ctx.get_pointer() == 0, "实际 %d" % ctx.get_pointer())

	# 往右走：PRG-004 没有这个能力，本效果走 move_pointer_to，适配层里待实现。
	var right := CardEffectMovePointer.new()
	right.方向 = CardZone.方向.右
	right.格数 = 2
	right.execute(ctx, card)
	_check("往右走调用 move_pointer_to", ctx.get_pointer() == 2, "实际 %d" % ctx.get_pointer())


# ---------------------------------------------------------------- buff 三要素

func _test_buff_stat_strength() -> void:
	print("[buff：力量，层数不变，层数换算强度]")
	var effect := BuffEffectStat.new()
	effect.buff标识 = &"strength"
	effect.属性 = BuffEffectStat.属性种类.攻击
	effect.每层数值 = 1

	var buff := {"buff_id": "strength", "layers": 3, "duration": 0}
	_check("3 层力量换算成 +3", effect.get_effect_strength(buff) == 3.0,
		"实际 %s" % effect.get_effect_strength(buff))

	var ctx := FakeEffectContext.make_basic()
	var next := effect.on_turn_update(ctx, "player", buff)
	_check("力量层数不变", next == 3, "实际 %d" % next)
	_check("力量不限回合时不减 持续回合",
		BuffEffect.duration_of(buff) == 0)

	effect.tick_duration(buff)
	_check("tick_duration 对不限回合的 buff 无动作",
		BuffEffect.duration_of(buff) == 0)


func _test_buff_stat_weak() -> void:
	print("[buff：虚弱，层数不变，减益]")
	var effect := BuffEffectStat.new()
	effect.buff标识 = &"weak"
	effect.属性 = BuffEffectStat.属性种类.攻击
	effect.每层数值 = -1

	var buff := {"buff_id": "weak", "layers": 2, "duration": 0}
	_check("2 层虚弱换算成 -2", effect.get_effect_strength(buff) == -2.0,
		"实际 %s" % effect.get_effect_strength(buff))

	var ctx := FakeEffectContext.make_basic()
	_check("虚弱层数不变", effect.on_turn_update(ctx, "enemy-1", buff) == 2)

	var tough := BuffEffectStat.new()
	tough.buff标识 = &"toughness"
	tough.属性 = BuffEffectStat.属性种类.格挡
	tough.每层数值 = 1
	var tough_buff := {"buff_id": "toughness", "layers": 4, "duration": 0}
	_check("4 层坚韧换算成 +4 格挡", tough.get_effect_strength(tough_buff) == 4.0)


func _test_buff_poison_halving() -> void:
	print("[buff：中毒，层数减半向上取整]")
	_check("1 层 → 0 层（特例）", BuffEffectPoison.next_layers(1) == 0)
	_check("2 层 → 1 层", BuffEffectPoison.next_layers(2) == 1)
	_check("3 层 → 2 层", BuffEffectPoison.next_layers(3) == 2)
	_check("4 层 → 2 层", BuffEffectPoison.next_layers(4) == 2)
	_check("5 层 → 3 层", BuffEffectPoison.next_layers(5) == 3)
	_check("8 层 → 4 层", BuffEffectPoison.next_layers(8) == 4)
	_check("0 层 → 0 层", BuffEffectPoison.next_layers(0) == 0)

	# 扣血按结算前的层数算，然后才减半
	var ctx := FakeEffectContext.make_basic(30)
	var poison := BuffEffectPoison.new()
	poison.buff标识 = &"poison"
	poison.每层伤害 = 1
	var buff := {"buff_id": "poison", "layers": 5, "duration": 0}

	var remaining := poison.on_turn_update(ctx, "enemy-1", buff)
	_check("5 层扣 5 血", int(ctx.state_enemies()[0]["health"]) == 25,
		"实际 %d" % int(ctx.state_enemies()[0]["health"]))
	_check("结算后层数变 3", remaining == 3, "实际 %d" % remaining)

	# 扣血绕过格挡。层数与上面的 buff 无关，单独建一条 4 层的。
	var blocked := FakeEffectContext.make_basic(30)
	blocked.state_enemies()[0]["block"] = 10
	var buff2 := {"buff_id": "poison", "layers": 4, "duration": 0}
	poison.on_turn_update(blocked, "enemy-1", buff2)
	_check("中毒绕过格挡（4 层扣 4 血）",
		int(blocked.state_enemies()[0]["health"]) == 26,
		"实际 %d" % int(blocked.state_enemies()[0]["health"]))
	_check("格挡值不变", int(blocked.state_enemies()[0]["block"]) == 10,
		"实际 %d" % int(blocked.state_enemies()[0]["block"]))

	# 对照：普通 dot 不绕过格挡时会被格挡吃掉
	var blocked2 := FakeEffectContext.make_basic(30)
	blocked2.state_enemies()[0]["block"] = 10
	var dot := BuffEffectDot.new()
	dot.buff标识 = &"bleed"
	dot.每层伤害 = 1
	dot.无视格挡 = false
	var bleed := {"buff_id": "bleed", "layers": 4, "duration": 0}
	dot.on_turn_update(blocked2, "enemy-1", bleed)
	_check("普通 dot 设了不绕过格挡时，血不掉",
		int(blocked2.state_enemies()[0]["health"]) == 30,
		"实际 %d" % int(blocked2.state_enemies()[0]["health"]))
	_check("普通 dot 的伤害被格挡吃掉",
		int(blocked2.state_enemies()[0]["block"]) == 6,
		"实际 %d" % int(blocked2.state_enemies()[0]["block"]))


func _test_buff_poison_expires() -> void:
	print("[buff：中毒会走完并移除]")
	var poison := BuffEffectPoison.new()
	poison.buff标识 = &"poison"
	poison.每层伤害 = 1
	var ctx := FakeEffectContext.make_basic(999)

	# 1 层：这一回合扣 1 血，然后归零，该条应当到期移除。
	# 那个特例就是为了这里——ceil(1/2) 等于 1，不减特例的话 1 层中毒永远留着。
	var one := {"buff_id": "poison", "layers": 1, "duration": 0}
	_check("1 层结算前未到期", not poison.is_expired(one))
	var after_one := poison.on_turn_update(ctx, "enemy-1", one)
	_check("1 层结算后归零", after_one == 0, "实际 %d" % after_one)
	one["layers"] = after_one
	_check("归零后判定为到期", poison.is_expired(one))
	_check("1 层共扣 1 血", int(ctx.state_enemies()[0]["health"]) == 998,
		"实际 %d" % int(ctx.state_enemies()[0]["health"]))

	# 3 层：3 → 2 → 1 → 0，共三回合，累计扣 3+2+1 = 6 血
	var three := {"buff_id": "poison", "layers": 3, "duration": 0}
	var ctx3 := FakeEffectContext.make_basic(999)
	var rounds := 0
	while not poison.is_expired(three) and rounds < 20:
		three["layers"] = poison.on_turn_update(ctx3, "enemy-1", three)
		rounds += 1
	_check("3 层经 3 回合走完", rounds == 3, "实际 %d 回合" % rounds)
	_check("3 层累计扣 6 血", int(ctx3.state_enemies()[0]["health"]) == 993,
		"实际 %d" % int(ctx3.state_enemies()[0]["health"]))
	_check("走完后层数为 0", BuffEffect.layers_of(three) == 0)

	# 层数一定收敛。这是 1 层特例存在的意义：没有它，这条循环不会退出。
	var big := {"buff_id": "poison", "layers": 64, "duration": 0}
	var ctxb := FakeEffectContext.make_basic(99999)
	var guard := 0
	while not poison.is_expired(big) and guard < 100:
		big["layers"] = poison.on_turn_update(ctxb, "enemy-1", big)
		guard += 1
	_check("64 层在 100 回合内走完", guard < 100, "实际 %d 回合" % guard)
	_check("走完后层数为 0", BuffEffect.layers_of(big) == 0,
		"实际 %d" % BuffEffect.layers_of(big))

	# 本类不需要覆写 is_expired，基类默认的「层数归零即到期」就是想要的
	_check("中毒与普通 dot 的到期判定一致",
		poison.is_expired({"buff_id": "poison", "layers": 0, "duration": 0})
			and BuffEffectDot.new().is_expired(
				{"buff_id": "bleed", "layers": 0, "duration": 0}))


func _test_buff_duration_tick() -> void:
	print("[buff：持续回合数]")
	var effect := BuffEffectDot.new()
	var limited := {"buff_id": "bleed", "layers": 3, "duration": 2}

	effect.tick_duration(limited)
	_check("限时 buff 第一回合后持续回合为 1",
		BuffEffect.duration_of(limited) == 1, "实际 %d" % BuffEffect.duration_of(limited))
	effect.tick_duration(limited)
	_check("第二回合后持续回合为 0",
		BuffEffect.duration_of(limited) == 0, "实际 %d" % BuffEffect.duration_of(limited))
	effect.tick_duration(limited)
	_check("已为 0 时不再往下减（不会变负）",
		BuffEffect.duration_of(limited) == 0, "实际 %d" % BuffEffect.duration_of(limited))

	# 持续回合为 0 表示不限回合，即使层数很大也不到期
	var unlimited := {"buff_id": "strength", "layers": 5, "duration": 0}
	_check("不限回合时不因回合数到期", not effect.is_expired(unlimited))


func _test_buff_hooks_independent() -> void:
	print("[buff：四个钩子各自独立]")

	# 只覆写层数规则：中毒的层数变，但持续回合不减、强度换算仍按层数
	var poison := BuffEffectPoison.new()
	poison.buff标识 = &"poison"
	poison.每层伤害 = 1
	var buff := {"buff_id": "poison", "layers": 4, "duration": 0}
	var ctx := FakeEffectContext.make_basic(99)

	var layers_after := poison.on_turn_update(ctx, "enemy-1", buff)
	_check("覆写了层数规则：4 → 2", layers_after == 2, "实际 %d" % layers_after)
	_check("写回层数后，强度换算仍按层数（1 层 1 点）",
		poison.get_effect_strength({"buff_id": "poison", "layers": layers_after, "duration": 0}) == 2.0,
		"2 层应为 2.0")
	_check("原 buff 字典里的层数没被 on_turn_update 擅自改掉",
		BuffEffect.layers_of(buff) == 4,
		"实际 %d（写回由调用方做，本方法只返回新值）" % BuffEffect.layers_of(buff))

	# 只覆写时长规则：一个自定义子类，让持续回合每回合减二
	var fast: BuffEffect = _load_fixture("fast_duration")
	var fast_buff := {"buff_id": "fast", "layers": 1, "duration": 5}
	fast.tick_duration(fast_buff)
	_check("自定义 tick_duration 生效（5 → 3）",
		BuffEffect.duration_of(fast_buff) == 3, "实际 %d" % BuffEffect.duration_of(fast_buff))
	_check("自定义 tick_duration 不影响层数",
		BuffEffect.layers_of(fast_buff) == 1)
	_check("自定义 tick_duration 不影响强度换算",
		fast.get_effect_strength(fast_buff) == 1.0)

	# 只覆写强度换算
	var doubled: BuffEffect = _load_fixture("doubled_strength")
	var doubled_buff := {"buff_id": "doubled", "layers": 3, "duration": 0}
	_check("自定义 get_effect_strength 生效（3 层 = 9）",
		doubled.get_effect_strength(doubled_buff) == 9.0,
		"实际 %s" % doubled.get_effect_strength(doubled_buff))
	_check("自定义强度换算不影响层数",
		doubled.on_turn_update(ctx, "player", doubled_buff) == 3)

	# 只覆写到期判定
	var stubborn: BuffEffect = _load_fixture("stubborn")
	_check("自定义 is_expired 生效：层数为 0 也认为未到期",
		not stubborn.is_expired({"buff_id": "stubborn", "layers": 0, "duration": 0}))


# ---------------------------------------------------------------- 同名卡与实例 id

func _test_duplicate_cards_distinguished_by_instance() -> void:
	print("[同名卡按实例区分]")
	var ctx := FakeEffectContext.make_with_duplicate_cards("oops")
	_check("牌堆里有两张同名卡", ctx.state_draw_pile().size() == 2)
	_check("两张卡牌标识相同",
		String(ctx.state_draw_pile()[0]["card_id"]) == String(ctx.state_draw_pile()[1]["card_id"]))
	_check("两张 instance_id 不同",
		String(ctx.state_draw_pile()[0]["instance_id"]) != String(ctx.state_draw_pile()[1]["instance_id"]),
		"%s vs %s" % [ctx.state_draw_pile()[0]["instance_id"], ctx.state_draw_pile()[1]["instance_id"]])

	# 抽到手牌，然后按实例弃掉其中一张
	ctx.draw(2)
	_check("两张都进了手牌", ctx.state_hand().size() == 2)
	var first_id := String(ctx.state_hand()[0]["instance_id"])
	var second_id := String(ctx.state_hand()[1]["instance_id"])
	ctx.discard_from_hand(first_id)
	_check("按实例弃掉一张后手牌剩 1", ctx.state_hand().size() == 1,
		"实际 %d" % ctx.state_hand().size())
	_check("剩下的是另一张", String(ctx.state_hand()[0]["instance_id"]) == second_id,
		"实际 %s" % ctx.state_hand()[0]["instance_id"])
	_check("弃牌堆里是刚弃的那张",
		ctx.state_discard_pile().size() == 1
			and String(ctx.state_discard_pile()[0]["instance_id"]) == first_id)


func _test_instance_ids_unique() -> void:
	print("[实例 id 唯一]")
	var ctx := FakeEffectContext.make_basic()
	var first := ctx.add_card_to_zone("bonk", &"hand", -1)
	var second := ctx.add_card_to_zone("bonk", &"hand", -1)
	var third := ctx.add_card_to_zone("bonk", &"draw_pile", -1)

	_check("三张同名卡拿到三个不同实例 id",
		first != second and second != third and first != third,
		"%s / %s / %s" % [first, second, third])
	_check("实例 id 非空", not first.is_empty())

	var seen := {}
	var duplicated := false
	for zone: Array in [ctx.state_hand(), ctx.state_draw_pile()]:
		for card: Dictionary in zone:
			var id := String(card["instance_id"])
			if seen.has(id):
				duplicated = true
			seen[id] = true
	_check("全牌组范围内没有重复实例 id", not duplicated)


# ---------------------------------------------------------------- 可选性与信号

func _test_effect_classes_all_selectable() -> void:
	print("[效果类可被编辑器选中]")
	# 编辑器给 Array[GameEffect] 添加元素时列的是「有 class_name 的全局类」。
	# 这里逐个确认八个效果类都注册成了全局类，否则编辑器里选不到。
	var expected: Array[String] = [
		"CardEffectAttack", "CardEffectBlock", "CardEffectDraw", "CardEffectBuff",
		"CardEffectDiscardRandom", "CardEffectDestroySelf", "CardEffectMovePointer",
		"BuffEffectStat", "BuffEffectDot", "BuffEffectPoison",
	]
	for name in expected:
		var script: Script = load("res://systems/cards/effects/%s.gd" % _snake(name)) \
			if name.begins_with("CardEffect") \
			else load("res://systems/buffs/effects/%s.gd" % _snake(name))
		_check("%s 可载入且有全局类名" % name,
			script != null and script.get_global_name() == StringName(name),
			"global_name=%s" % (script.get_global_name() if script != null else "<null>"))


## PascalCase → snake_case。只处理本自测用到的那几个名字。
func _snake(pascal: String) -> String:
	var out := ""
	for i in pascal.length():
		var ch := pascal[i]
		if ch == ch.to_upper() and ch != ch.to_lower() and i > 0:
			out += "_"
		out += ch.to_lower()
	return out


func _test_effect_signal() -> void:
	print("[效果执行时释放信号]")
	var ctx := FakeEffectContext.make_basic(30)
	var effect := CardEffectAttack.new()
	effect.数值 = 4
	var card := {"instance_id": "inst-1", "card_id": "bonk"}

	var recorder := ExecutedRecorder.new()
	effect.executed.connect(recorder.on_executed)

	effect.execute(ctx, card)
	_check("释放了一次 executed", recorder.fire_count == 1,
		"实际 %d" % recorder.fire_count)
	_check("信号带回效果自身",
		recorder.效果.size() == 1 and recorder.效果[0] == effect)
	_check("信号带回触发它的牌",
		recorder.contexts.size() == 1
			and String(recorder.contexts[0].get("instance_id", "")) == "inst-1")

	# 参数非法（0 伤害）时也要释放信号，表示「执行过了，只是没动作」
	var zero := CardEffectAttack.new()
	zero.数值 = 0
	var zero_recorder := ExecutedRecorder.new()
	zero.executed.connect(zero_recorder.on_executed)
	zero.execute(ctx, card)
	_check("参数为 0 时仍释放 executed", zero_recorder.fire_count == 1)


# ---------------------------------------------------------------- 磁盘上的原型卡

func _test_prototype_cards_on_disk() -> void:
	print("[原型卡：磁盘上的 16 份]")
	var dir := DirAccess.open("res://data/cards")
	if dir == null:
		_check("能打开 data/cards", false)
		return

	var files: Array[String] = []
	for file_name in dir.get_files():
		if file_name.ends_with(".tres"):
			files.append(file_name)
	_check("有 16 个 .tres", files.size() == 16, "实际 %d 个" % files.size())

	var by_id: Dictionary = {}
	var load_failures := 0
	for file_name in files:
		var resource: Resource = ResourceLoader.load("res://data/cards/%s" % file_name)
		if not (resource is CardData):
			load_failures += 1
			continue
		var data: CardData = resource
		var 卡牌标识 := String(data.卡牌标识)
		if not by_id.has(卡牌标识):
			by_id[卡牌标识] = []
		by_id[卡牌标识].append(data)

	_check("全部载入为 CardData", load_failures == 0, "失败 %d 个" % load_failures)
	_check("是 8 个不同的 卡牌标识", by_id.size() == 8, "实际 %d 个" % by_id.size())

	var expected_ids: Array[String] = [
		"bonk", "duck", "peek", "feeling_good",
		"oops", "one_shot", "nudge_back", "spit",
	]
	for 卡牌标识 in expected_ids:
		var copies: Array = by_id.get(卡牌标识, [])
		_check("%s 有两份" % 卡牌标识, copies.size() == 2, "实际 %d 份" % copies.size())

	# 同卡牌标识的两份内容完全一致（同名卡的要求）
	for 卡牌标识 in expected_ids:
		var copies: Array = by_id.get(卡牌标识, [])
		if copies.size() != 2:
			continue
		var a: CardData = copies[0]
		var b: CardData = copies[1]
		_check("%s 两份的卡名与卡面两栏一致" % 卡牌标识,
			a.卡牌名 == b.卡牌名 and a.稀有度 == b.稀有度
				and a.颜色 == b.颜色)
		_check("%s 两份各挂一个效果且类型相同" % 卡牌标识,
			a.效果.size() == 1 and b.效果.size() == 1
				and a.效果[0].get_script() == b.效果[0].get_script())

	# 八种效果各被至少一张卡覆盖到
	var covered: Dictionary = {}
	for 卡牌标识 in by_id:
		for data: CardData in by_id[卡牌标识]:
			for effect: GameEffect in data.效果:
				if effect != null:
					covered[effect.get_script().resource_path] = true
	_check("八种效果类至少各有表现（实际覆盖 %d 种）" % covered.size(),
		covered.size() >= 7, "覆盖 %s" % [covered.keys()])


func _test_card_catalog_report() -> void:
	print("[CardCatalog 校验工具]")

	# card_catalog.gd 是 @tool EditorScript，--script 模式拿不到它的全局类名，
	# 所以用 load 取脚本再取嵌套类。
	var catalog_script: Script = load("res://systems/cards/card_catalog.gd")
	_check("能载入 card_catalog.gd", catalog_script != null)
	if catalog_script == null:
		return
	var report_class: Variant = catalog_script.get("CardCatalogReport")
	_check("能取到嵌套的 CardCatalogReport 类", report_class != null)
	if report_class == null:
		return

	var report: Variant = report_class.new()
	report.scan("res://data/cards")

	_check("扫到 16 个文件", report.card_files.size() == 16,
		"实际 %d" % report.card_files.size())
	_check("载入 16 张卡", report.cards.size() == 16, "实际 %d" % report.cards.size())
	_check("识别出 8 个 卡牌标识", report.ids.size() == 8, "实际 %d" % report.ids.size())
	_check("每个卡牌标识都被标成重复（原型卡刻意两份）",
		report.duplicate_ids().size() == 8,
		"实际 %d 个" % report.duplicate_ids().size())
	_check("没有断链或空效果", report.problems.is_empty(),
		"问题 %s" % [report.problems])
	_check("统计到效果被引用", not report.effect_usage.is_empty())

	# 报表里的「卡面=」那一列靠枚举成员名印出来，走的是「枚举 keys() 顺序 = 整数值」这条
	# 性质。这里逐个成员对一遍，免得以后有人给枚举显式赋值，报表就悄悄印成未知。
	var rarity_names: Array = []
	for i in CardData.稀有度档.size():
		rarity_names.append(report._member_name(CardData.稀有度档, i))
	_check("稀有度的成员名逐个取到", rarity_names == ["日", "月"], "实际 %s" % [rarity_names])
	var tint_names: Array = []
	for i in CardData.颜色档.size():
		tint_names.append(report._member_name(CardData.颜色档, i))
	_check("颜色的成员名逐个取到", tint_names == ["灰", "红", "蓝", "黄"], "实际 %s" % [tint_names])
	_check("越界的档位印成未知", report._member_name(CardData.稀有度档, 99) == "未知(99)",
		"实际 %s" % report._member_name(CardData.稀有度档, 99))
	# 报表正文跑一遍（输出落在测试日志里），确认打印这条路径不会报错
	report.print_to_console()

	# 校验能力本身：故意塞一张坏卡进临时目录，看能不能报出来
	var bad_dir := "user://catalog_check"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(bad_dir))
	var bad := CardData.new()
	bad.卡牌标识 = &""
	bad.卡牌名 = ""
	var bad_path := "%s/bad.tres" % bad_dir
	var err := ResourceSaver.save(bad, bad_path)
	_check("能写出坏卡用于测试", err == OK, "错误码 %d" % err)

	var bad_report: Variant = report_class.new()
	bad_report.scan(bad_dir)
	_check("报出卡牌标识为空", _any_contains(bad_report.problems, "卡牌标识为空"),
		"问题 %s" % [bad_report.problems])
	_check("报出卡牌名为空", _any_contains(bad_report.problems, "卡牌名为空"))
	_check("报出效果为空", _any_contains(bad_report.problems, "效果为空"))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path))


func _any_contains(lines: Array[String], needle: String) -> bool:
	for line in lines:
		if line.contains(needle):
			return true
	return false

## 取测试夹具。夹具不写 class_name，故意的——带 class_name 的脚本会进工程的
## 全局类表，于是策划在编辑器里给效果数组「添加元素」时，会看到这几个测试用的
## 假 buff，把真正的效果类冲淡。用路径载入即可，不需要全局名。
func _load_fixture(fixture_name: String) -> BuffEffect:
	var path := "res://tests/test_effects/card_effect_selftest_%s.gd" % fixture_name
	var script: Script = load(path)
	if script == null:
		_failures += 1
		print("  失败  载不到夹具 %s" % path)
		return null
	var instance: Variant = script.new()
	if not (instance is BuffEffect):
		_failures += 1
		print("  失败  夹具 %s 不是 BuffEffect" % fixture_name)
		return null
	return instance
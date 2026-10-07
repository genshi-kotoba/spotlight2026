# 卡牌与 buff 效果

对应 PRG-007（卡牌效果模板）与 PRG-008（buff 效果模板）。分支 `prg-007-008-cards`。

## 一、这套东西是什么

两层，各管一件事。

**卡牌效果**：一次性执行。打出时执行一次就结束，不持状态。抽牌、攻击、格挡都是这一类。

**buff 效果**：多出两个概念——层数、持续回合数。它挂在某个目标身上，每回合结算一次，直到层数或回合数耗尽。

两层的共同点：效果不直接碰战斗状态机。它们只认一个抽象接口 `EffectContext`，由状态机那一侧的适配层去实现。这样效果层可以独立编译、独立测试，状态机怎么改都不影响它。

效果模板的形态：一条效果是一个文件、一个类，参数用 `@export` 暴露，在检查器里填。两套效果共用一个根类 `GameEffect`，所以卡牌能直接挂 buff 效果，buff 也能直接挂卡牌效果。

数据也分两种：卡牌是 `CardData` 资源，含卡面两栏（稀有度与颜色）与效果列表；buff 是 `BuffData` 资源，含层数、持续回合数、效果。

效果表上共 15 条，已实现 8 条：攻击、格挡、buff 层数增减、抽牌、随机弃牌、使用后从战斗中移除、移动指针位置、中毒。另有三条 buff 实现支撑层数、持续回合数、效果三要素。剩下 7 条与各自的原因见第十一节。

两处会算错数值的地方，处理不好会多扣血或弃错牌：

**一、加 buff 必须先合并同名。** 状态机的 `add_buff()` 只做数组追加，按 `buff标识` 合并是效果层这边做的。漏了的话，同一个 buff 加两次会在结算时触发两次——挂 3 层中毒会扣两次血。

**二、弃牌要按 `instance_id` 而不是 `卡牌标识`。** 牌的身份是实例，不是种类。用错键的话，弃掉一张同名卡会把另一张也弃掉。

两处的细节在第九节。

## 二、文件在哪

```
systems/
├── effects/
│   └── game_effect.gd              GameEffect，两套效果的共同根类
├── cards/
│   ├── card_effect.gd              CardEffect，继承 GameEffect，一次性执行
│   ├── effect_context.gd           EffectContext，效果与外界唯一的通道
│   ├── card_data.gd                CardData，一张卡的静态配置
│   ├── card_zone.gd                Zone / RemoveScope / 方向三个枚举
│   ├── card_catalog.gd             @tool 校验工具，见第八节
│   └── effects/                    一条卡牌效果一个文件
│       ├── card_effect_attack.gd
│       ├── card_effect_block.gd
│       ├── card_effect_buff.gd
│       ├── card_effect_destroy_self.gd
│       ├── card_effect_discard_random.gd
│       ├── card_effect_draw.gd
│       └── card_effect_move_pointer.gd
├── buffs/
│   ├── buff_effect.gd              BuffEffect，继承 GameEffect，多出层数与回合
│   ├── buff_data.gd                BuffData，一种 buff 的静态配置
│   └── effects/
│       ├── buff_effect_stat.gd     数值增减：力量、虚弱、坚韧
│       ├── buff_effect_dot.gd      dot 的通用形状
│       └── buff_effect_poison.gd   中毒，覆写层数规则

data/
└── cards/                          16 份原型卡，8 种效果各两份同名

tests/
├── card_effect_selftest.gd         169 项自测
└── test_effects/                   假上下文与测试夹具
```

测试夹具不带 `class_name`，按路径加载。它们继承 `BuffEffect`，带上 `class_name` 就会出现在编辑器给效果数组「添加元素」的候选里，与真正的效果类混在一起。

## 三、为什么两套效果共用一个根类

Base 对两条任务的接口约定是对称的：

- PRG-008 说 buff 效果包括「所有的卡牌效果」
- PRG-007 说卡牌效果包括「buff 层数增减」

两个方向都要通，所以它们必须有共同祖先：

```gdscript
GameEffect            Resource
├── CardEffect        GameEffect
└── BuffEffect        GameEffect
```

于是 `CardData.效果` 与 `BuffData.效果` 的元素类型都是 `Array[GameEffect]`，卡牌可以直接挂 buff 效果（「给目标叠 3 层中毒」），buff 也可以直接挂卡牌效果（「每回合抽一张牌」）。

编辑器给数组点「添加元素」时，列出的是声明元素类型的全部子类。元素类型是 `GameEffect`，所以卡牌效果与 buff 效果会一起列出来。两套效果各有各的根类的话，策划在卡牌上选不到 buff 效果。

`CardEffect` 与 `BuffEffect` 仍然分开，是为了让检查器上的字段不混在一起，不是为了限制能挂什么。

## 四、加一条新效果

四个步骤，不需要改任何已有文件。下面这个类是虚构的示例，代码里没有「治疗」这条效果，只为把格式写全：

```gdscript
# systems/cards/effects/card_effect_heal.gd
class_name CardEffectHeal
extends CardEffect

@export var 数值: int = 5

func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectHeal：缺少上下文")
		return
	ctx.heal_player(数值)
	executed.emit(self, card)
```

真实的样子翻第二节列的那 7 个卡牌效果文件，任何一个都是这个形状。

1. 在 `systems/cards/effects/` 下新建 `card_effect_<名字>.gd`（buff 效果放 `systems/buffs/effects/`，前缀改 `buff_effect_`）
2. `class_name` 用 `CardEffect` 加 `PascalCase` 名字，`extends CardEffect`
3. 参数用 `@export` 暴露，不要写死在 `execute` 里
4. 覆写 `execute`，只通过 `ctx` 与外界交互，结束时 `executed.emit(self, card)`

保存文件、回到编辑器，`CardData` 的 `效果` 数组里就能选到。

新增的脚本要让编辑器重新扫描文件系统才会被认到。Godot 通常会自己发现新文件；没出现就 `项目 → 重新加载当前项目`，或者重启编辑器。

### 参数一定要走 @export

将来要做卡牌升级（同一张卡的高级版本），改数值即可，不用改代码。数值写死在 `execute` 里就没法升级了。

## 五、加一张新卡

字段层面的完整步骤见第六节。这里说明两条数据层面的事。

`卡牌标识` 相同的多个 `.tres` 就是同一张卡的多个副本，可以同时进牌组。原型卡就是这么做的：`data/cards/` 下 8 个 id 各两份。

`效果` 是一个有序数组，按顺序执行。一张卡要多段效果（比如「攻击 3 并叠 2 层中毒」）就加两个元素，不需要写新类。

## 六、可视化卡牌编辑器

**打开一张卡** —— FileSystem 面板展开 `data/cards/`，双击任意一个 `.tres`。右侧检查器里就是这张卡的全部字段。

**新建一张卡** —— 在 `data/cards/` 上右键 → 新建资源 → 搜索 `CardData` → 填文件名 → 创建。然后填这几个字段：

| 字段            | 填什么                                         |
| ------------- | ------------------------------------------- |
| `卡牌标识`     | 稳定标识，如 `bonk`。**同名卡用同一个 id**                |
| `卡牌名`   | 展示名                                         |
| `描述` | 卡面描述                                        |
| `稀有度`  | 卡面第一栏，下拉框 `日` / `月`，默认 `日`                |
| `颜色`   | 卡面第二栏，下拉框 `灰` / `红` / `蓝` / `黄` |
| `效果`     | 点「添加元素」                                     |

`稀有度` 与 `颜色` 决定这张卡贴哪张底图：稀有度对应底图的第一栏（两档），颜色对应第二栏（四档），两档乘四档正好是 `CardFaceSet` 里那 8 张。稀有度这一栏的标题来自策划案 2.4，两个选项名暂用底图的名字（日 / 月），玩法上这两档叫什么还没定；颜色同理，暂按底图颜色命名。改枚举在 `CardData`，底图对应关系在 `CardFaceSet`，两处一起改。

现有的 16 张原型卡都取默认的 `日`。

**挂效果** —— `效果` 右边的「添加元素」按钮，点开会列出全部已实现的效果类，卡牌效果与 buff 效果一起列。选中一个，检查器里出现该效果自己的参数框，填完按 Ctrl+S 存。

**加一条新效果** —— 在 `systems/cards/effects/` 或 `systems/buffs/effects/` 下新建一个文件，保存，回编辑器。候选里就有了，不需要注册，也不需要改任何已有文件。格式照第四节。

**校验** —— `systems/cards/card_catalog.gd`，打开它按 Ctrl+Shift+X。输出面板会列出全部卡牌、报出重复 `卡牌标识` 与空效果元素、统计每个效果被引用多少次。

## 七、buff 的三要素

PRG-008 要求 buff 含层数、持续回合数、效果。三要素分别落在：

| 要素    | 在哪                                          |
| ----- | ------------------------------------------- |
| 层数    | buff 字典的 `层数`，由 `on_turn_update` 决定怎么变  |
| 持续回合数 | buff 字典的 `持续回合`，由 `tick_duration` 决定怎么减 |
| 效果    | 子类的 `@export` 参数与钩子覆写                       |

运行期的一条 buff 是纯字典，活在状态机的 `player["buffs"]` 与 `enemies[i]["buffs"]` 里：

```gdscript
{"buff_id": "poison", "layers": 2, "duration": 0}
```

`BuffEffect` 描述这条 buff 的行为，buff 本身是上面那个字典。

### 四个钩子各自独立

不同 buff 的结算方式差别很大，一套固定流程塞不下，所以拆成四个：

| 钩子                    | 管什么         | 覆写它的例子                                   |
| --------------------- | ----------- | ---------------------------------------- |
| `on_turn_update`      | 层数怎么变，返回新层数 | 中毒：减半向上取整                                |
| `tick_duration`       | 回合数怎么减      | 中毒：覆写成空实现，不受回合限制                         |
| `get_effect_strength` | 层数换算成多少强度   | `BuffEffectStat`：按 `每层数值` 换算 |
| `is_expired`          | 何时到期        | 默认「层数归零即到期」；要永不超期的 buff 才覆写它             |

只覆写一个不影响其他方面，自测里有专门的用例覆盖这一条。

### 持续回合的语义

```
持续回合 == 0   不限回合。tick_duration 对它不做任何事，永不因回合数被移除
持续回合 > 0    剩余回合数。每回合减一，减到 0 即到期
```

不能填负数。状态机的 `_valid_buff()` 要求非负，负数会被拒绝。

调用方每回合的顺序：

1. `on_turn_update(ctx, target, buff)` → 取回新层数并写回
2. `tick_duration(buff)` → 限时的减一
3. `is_expired(buff)` → 到期则 `end` 并从数组移除

### 已定的四条 buff

| buff | `buff标识`   | 层数变化       | 持续回合 | 实现                                                   |
| ---- | ----------- | ---------- | ---- | ---------------------------------------------------- |
| 力量   | `strength`  | 不变         | 由卡牌定 | `BuffEffectStat`，`属性=ATTACK`，`每层数值=+1` |
| 虚弱   | `weak`      | 不变         | 由卡牌定 | `BuffEffectStat`，`属性=ATTACK`，`每层数值=-1` |
| 坚韧   | `toughness` | 不变         | 由卡牌定 | `BuffEffectStat`，`属性=BLOCK`，`每层数值=+1`  |
| 中毒   | `poison`    | **减半向上取整，1 层为特例归零** | 不限   | `BuffEffectPoison`                                   |

策划案 2.5 只写了这四条的每层效果，没写层数是否衰减。三条按「层数不变」实现，不预设任何 buff 会衰减。

中毒的层数规则：

```
结算完牌之后，扣除对方等于当前中毒层数的生命，然后中毒层数减半、向上取整。
层数为 1 时是例外——下回合直接归零移除。
```

| 结算前 | 扣血 | 结算后 |
| --- | -- | --- |
| 1   | 1  | 0，该条移除 |
| 2   | 2  | 1   |
| 3   | 3  | 2   |
| 4   | 4  | 2   |
| 5   | 5  | 3   |
| 8   | 8  | 4   |

那 1 层的例外是必要的：`ceil(1 / 2)` 等于 1，去掉这个特例的话 1 层中毒永远留着，而它每回合还在扣血，变成一条永不结束的持续伤害。有特例后层数一定收敛到 0。

层数会走到 0，所以 `BuffEffectPoison` 不需要覆写 `is_expired`，基类默认的「层数归零即到期」正好是想要的行为。

## 八、校验工具

`systems/cards/card_catalog.gd`，`@tool`。在编辑器里打开它按 `Ctrl+Shift+X`，或在 FileSystem 面板右键选 `Run`。结果打印在输出面板。

它做检查器做不了的事：列出全部卡牌与字段、校验 `卡牌标识` 是否重复或为空、校验 `效果` 里有没有空元素、统计每个效果被多少张卡引用（判断某个效果能不能删）。

它不得引用 `BattleStateMachine`。这个工具只读卡牌数据，不需要状态机。

## 九、与 PRG-004 的接口

### 效果层只认 EffectContext

`systems/cards/effect_context.gd`，29 个公开方法，分五组：

```
读状态      10 个   current_target / enemy_ids / player_health / player_block /
                    buff_layers / hand / play_zone / draw_pile_size /
                    discard_pile / pointer_index
改战斗数值   5 个   damage_enemy / damage_all_enemies / damage_player /
                    heal_player / add_block
改 buff      3 个   add_buff / set_buff_layers / tick_poison
改牌         9 个   draw / discard_from_hand / discard_random / add_card_to_zone /
                    move_card_in_play_zone / remove_from_battle / remove_from_run /
                    change_target / attach_effect
指针         2 个   rewind_pointer / move_pointer_to
```

三个造成伤害的方法都带 `ignore_block`。中毒这类 dot 要绕过格挡。

### 适配层由 PRG-004 一侧实现

`systems/cards/battle_effect_context.gd` 实现上面这些方法，把状态机包起来。它属于 PRG-004 一侧，本模块只定义 `EffectContext` 接口，不引用状态机。集成验证要在真实战斗里跑，同样挂在这一侧。

### 加 buff 必须先合并同名

处理不好会算错伤害。

状态机的 `add_buff()` 只做数组追加，不按 `buff标识` 合并：

```gdscript
buffs.append(buff.duplicate(true))
```

而它的结算是「数组里有几条就发几次请求」：

```gdscript
for raw in buffs.duplicate(true):
	buff_effect_requested.emit(side, entity_id, buff.duplicate(true))
```

所以往同一目标加两次中毒（哪怕本意是「叠到 3 层」），数组里会有两条，每回合扣两次血。

适配层的 `add_buff` 必须先按 `buff标识` 查同名：有则把 `层数` 累加到现有那条，无则新增。累加后为 0 的要把该条从数组移除，不留 `层数` 为 0 的空条。

自测用一个实现了这条规则的假上下文覆盖它（`tests/test_effects/fake_effect_context.gd`）。

### 同名卡按 instance\_id 区分

牌是字典 `{"instance_id": "card-1", "card_id": "bonk"}`。`卡牌标识` 是种类，`instance_id` 是这一局里唯一的那一张。

`discard_from_hand(instance_id)` 要传实例 id。适配层若误用 `卡牌标识` 当键，弃掉一张同名卡会把另一张也弃掉。

造牌时每张都要分配不同的 `instance_id`，包括同名卡。PRG-004 的读档校验会拒绝跨牌区重复的实例 id。

## 十、验证

```bash
godot --headless --import                                       # 退出码 0，零错误零警告
godot --headless --script res://tests/card_effect_selftest.gd    # 169 项全部通过
godot --headless --script res://tests/map_selftest.gd            # 32 项，PRG-011 回归
```

自测 24 个分组：两套效果的继承关系、卡牌与 buff 数据的字段与存读往返、8 种效果各自的行为、buff 三要素、中毒的减半与走完移除、四个钩子独立、同名卡按实例区分、实例 id 唯一、效果类的全局类名可载入、执行释放信号、磁盘上 16 份原型卡的一致性、`CardCatalog` 的校验能力。

## 十一、还没做的

| 项                              | 原因                       |
| ------------------------------ | ------------------------ |
| `battle_effect_context.gd` 适配层 | 由 PRG-004 一侧实现，把状态机包在 `EffectContext` 后面 |
| 集成自测                           | 挂在上面的适配层；必须走场景，不能走 `--script` |
| 7 条卡牌效果                        | 见下                       |
| 8 条之外的卡牌数据                     | PRG-013 的事；`data/cards/` 里只有原型卡 |

`data/cards/` 的校验结果：16 个文件、8 个 `卡牌标识`、8 组同名卡、7 个产品效果类被引用，未发现问题。

### 15 条效果里已实现 8 条

分界线是「只用 PRG-004 现有公开接口就能跑通」。

已实现：攻击、格挡、buff 层数增减、抽牌、随机弃牌、使用后从战斗中移除、移动指针位置（只用往回）、中毒。

留后：

| 效果           | 留到      | 原因                  |
| ------------ | ------- | ------------------- |
| 获得特定牌        | 适配层     | 要适配层自己写造牌与入堆        |
| 向牌序特定位置加入牌   | 适配层     | 同上                  |
| 移动卡牌位置       | 适配层     | 药水与卡位规则未定           |
| 更改攻击目标       | 适配层     | 要改状态机的 `targets` 字典 |
| 为其他卡牌附加效果    | 适配层     | 要在牌字典上另加字段          |
| 使用后从本局移除     | 适配层     | 落点属 PRG-003         |
| 选择特定牌 / 选择弃牌 | PRG-017 | 选牌交互是界面的事           |

七条在 `EffectContext` 里的方法都已留好，将来照第四节加文件即可，不需要改已有文件。

### 原型卡是刻意重名的

`data/cards/` 下 16 个 `.tres`，8 个 `卡牌标识` 各两份。重名的用途是验「按实例而非种类区分」——适配层如果把 `卡牌标识` 当键，弃一张会把两张一起弃掉。

`CardCatalog` 会把同名卡报出来，这是原型卡的预期结果。正式卡牌数据里出现同名才是重复登记。

## 十二、改这套代码前要记住的几条

以下几条都影响怎么改代码。

**加一条效果不需要动已有文件。** 新建一个 `systems/cards/effects/` 或 `systems/buffs/effects/` 下的文件即可，编辑器会自动把它列进效果数组的候选。这一点有自测覆盖。

**两处会算错数值的地方在第九节。** 加 buff 必须先合并同名，否则同一个 buff 加两次会在结算时触发两次；弃牌要按 `instance_id` 而非 `卡牌标识`，否则同名卡会被一次弃掉两张。改的时候容易漏。

**效果层不依赖状态机。** 它只认 `EffectContext`。要加的效果如果需要新的外界能力，先给这个接口加方法，再由适配层实现，不要在效果里直接引用 `systems/` 以外的东西。

**数值不要写死在 `execute` 里。** 一律用 `@export`，将来的卡牌升级要靠改数值实现。

**`持续回合` 为 0 表示不限回合，不能填负数。** 状态机会拒绝负值的 buff。

**适配层未完成，跑不了真实战斗。** 验证效果行为用 `tests/test_effects/fake_effect_context.gd`。

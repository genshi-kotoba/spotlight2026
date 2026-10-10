# 卡牌与 buff 效果

对应 PRG-007（卡牌效果模板）与 PRG-008（buff 效果模板）。分支 `prg-007-008-cards`。

当前战斗执行架构已重构为事件队列 + 规则引擎；详见 [09-战斗事件队列与规则引擎.md](09-战斗事件队列与规则引擎.md)。下文保留效果资源与早期原型的说明，运行时接入以新架构为准。

## 给人看的这一段

### 做完了什么

PRG-007 和 PRG-008。

**效果模板。** 一条效果是一个文件、一个类，参数用 `@export` 暴露，在检查器里填。两套效果共用一个根类 `GameEffect`，所以卡牌能直接挂 buff 效果，buff 也能直接挂卡牌效果。

**卡牌与 buff 的数据。** 卡牌是 `CardData` 资源，含稀有度、类型、效果列表。buff 是 `BuffData` 资源，含层数、持续回合数、效果。

当前已覆盖攻击、自伤、治疗、格挡、buff 层数增减、抽牌、随机弃牌、玩家选择弃牌、使用后从战斗中移除、左右移动指针、重复后一张牌和中毒。选择弃牌通过显式暂停/提交协议完成，不在效果回调中等待 UI。

### 可能会出问题的地方

有两处，都不是风格问题，是会算错数值的。

**一、加 buff 必须先合并同名。** 状态机的 `add_buff()` 只做数组追加；效果通过上下文提交 `action.buff_add`，执行器调用 `change_buff_layers()` 按 `buff_id` 合并。漏了的话，同一个 buff 加两次会在结算时触发两次——挂 3 层中毒会扣两次血。

**二、弃牌要按 `instance_id` 而不是 `card_id`。** 牌的身份是实例，不是种类。用错键的话，弃掉一张同名卡会把另一张也弃掉。

两处的细节在第八节。

### 留下的问题

接的第一阶段的代码。有两处要说明。

**一、效果层原先和状态机绑在一起。** 第一阶段的 `CardEffectContext` 是个空占位，等 PRG-004 定接口。合并时补上 `BattleEffectContext` 与 `BattleEffectResolver`；当前解析器注册事件规则，上下文只提交动作，效果不再依赖请求信号的同步返回。

这一轮改成效果层只认自己定义的抽象接口 `EffectContext`，状态机那一侧另写适配层去实现。效果层因此不依赖状态机，可以在假上下文上独立自测。

**二、第一阶段的测试夹具进了全局类表。** 那三个夹具当时为了验「编辑器能否列出来」，特意写了 `class_name`；它们继承 `BuffEffect`，于是出现在编辑器给效果数组「添加元素」的候选里，与真正的效果类混在一起。已改为不带 `class_name`、按路径加载。

### 可视化卡牌编辑器

操作方式：

**打开一张卡** —— FileSystem 面板展开 `data/cards/`，双击任意一个 `.tres`。右侧检查器里就是这张卡的全部字段。

**新建一张卡** —— 在 `data/cards/` 上右键 → 新建资源 → 搜索 `CardData` → 填文件名 → 创建。然后填这几个字段：

| 字段            | 填什么                                         |
| ------------- | ------------------------------------------- |
| `card_id`     | 稳定标识，如 `bonk`。**同名卡用同一个 id**                |
| `card_name`   | 展示名                                         |
| `description` | 卡面描述                                        |
| `rarity`      | 下拉框，`COMMON` / `RARE`                       |
| `kind`        | 下拉框，`DAMAGE` / `BUFF` / `SHIFT` / `SPECIAL` |
| `face_tint`   | 卡框色调，`GRAY` / `RED` / `BLUE` / `YELLOW`      |
| `effects`     | 点「添加元素」                                     |

**挂效果** —— `effects` 右边的「添加元素」按钮，点开会列出全部已实现的效果类，卡牌效果与 buff 效果一起列。选中一个，检查器里出现该效果自己的参数框，填完按 Ctrl+S 存。

**加一条新效果** —— 在 `systems/cards/effects/` 或 `systems/buffs/effects/` 下新建一个文件，保存，回编辑器。候选里就有了。不需要注册，不需要改任何已有文件，格式照第四节。

**校验** —— `systems/cards/card_catalog.gd`，打开它按 Ctrl+Shift+X。输出面板会列出全部卡牌、报出重复 `card_id` 与空效果元素、统计每个效果被引用多少次。

### 本轮的状态

已完成：效果层、数据结构、8 条效果、8x2 份原型卡、4 份 buff 配置、通用卡面预制件、8 张卡框、编辑器实时预览插件、效果与卡面自测、`CardCatalog` 校验工具、PRG-004 适配层及真实战斗集成测试。

早期原型之后已补上测试战斗界面、选择弃牌、左右移动指针、重复后一张牌和统一事件引擎；其余未适配能力见第十节。

<br />

> "For those who come after."

## 一、这套东西是什么

两层，各管一件事。

**卡牌效果**：一次性执行。打出时执行一次就结束，不持状态。抽牌、攻击、格挡都是这一类。

**buff 效果**：多出两个概念——层数、持续回合数。它挂在某个目标身上，每回合结算一次，直到层数或回合数耗尽。

两层的共同点：**效果不直接碰战斗状态机**。它们只认一个抽象接口 `EffectContext`，由状态机那一侧的适配层去实现。这样效果层可以独立编译、独立测试，状态机怎么改都不影响它。

## 二、文件在哪

```
systems/
├── effects/
│   └── game_effect.gd              GameEffect，两套效果的共同根类
├── cards/
│   ├── card_effect.gd              CardEffect，继承 GameEffect，一次性执行
│   ├── effect_context.gd           EffectContext，效果与外界唯一的通道
│   ├── card_data.gd                CardData，一张卡的静态配置
│   ├── card_zone.gd                Zone / RemoveScope / PointerDir 三个枚举
│   ├── card_catalog.gd             @tool 校验工具，见第七节
│   ├── battle_effect_context.gd    PRG-004 战斗状态的 EffectContext 适配
│   ├── battle_effect_resolver.gd   资源目录、效果请求与适配层的连接器
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
├── cards/                          16 份原型卡，8 种效果各两份同名
└── buffs/                          力量、虚弱、坚韧、中毒 4 份配置

tests/
├── card_effect_selftest.gd         166 项自测
├── card_battle_integration_selftest.gd/.tscn
│                                    真实状态机、效果与存读档集成自测
└── test_effects/                   假上下文与测试夹具
```

## 三、为什么两套效果共用一个根类

Base 对两条任务的接口约定是**对称**的：

- PRG-008 说 buff 效果包括「所有的卡牌效果」
- PRG-007 说卡牌效果包括「buff 层数增减」

两个方向都要通，所以它们必须有共同祖先：

```gdscript
GameEffect            Resource
├── CardEffect        GameEffect
└── BuffEffect        GameEffect
```

于是 `CardData.effects` 与 `BuffData.effects` 的元素类型都是 `Array[GameEffect]`，卡牌可以直接挂 buff 效果（「给目标叠 3 层中毒」），buff 也可以直接挂卡牌效果（「每回合抽一张牌」）。

**这一条是整套设计的关键。** 编辑器给数组点「添加元素」时，列出的是**声明元素类型的全部子类**。元素类型是 `GameEffect`，所以卡牌效果与 buff 效果会一起列出来。如果两套效果各有各的根类，策划在卡牌上就选不到 buff 效果。

`CardEffect` 与 `BuffEffect` 仍然分开，是为了让检查器上的字段不混在一起，不是为了限制能挂什么。

## 四、加一条新效果

**四个步骤，不改任何已有文件。** 下面以已经实现的「治疗」效果示范格式：

```gdscript
# systems/cards/effects/card_effect_heal.gd
class_name CardEffectHeal
extends CardEffect

@export var amount: int = 5

func execute(ctx: EffectContext, card: Dictionary) -> void:
	if ctx == null:
		push_error("CardEffectHeal：缺少上下文")
		return
	ctx.heal_player(amount)
	executed.emit(self, card)
```

要看真实的样子，翻第二节列的那 7 个卡牌效果文件，任何一个都是这个形状。

1. 在 `systems/cards/effects/` 下新建 `card_effect_<名字>.gd`（buff 效果放 `systems/buffs/effects/`，前缀改 `buff_effect_`）
2. `class_name` 用 `CardEffect` 加 `PascalCase` 名字，`extends CardEffect`
3. 参数用 `@export` 暴露，**不要写死在 execute 里**
4. 覆写 `execute`，只通过 `ctx` 与外界交互，结束时 `executed.emit(self, card)`

保存文件、回到编辑器，`CardData` 的 `effects` 数组里就能选到。

**新增的脚本要重新扫描文件系统**编辑器才认。Godot 会自己发现新文件；如果没出现，`项目 → 重新加载当前项目`，或者重启编辑器。

### 参数一定要走 @export

将来要做卡牌升级（同一张卡的高级版本），改数值即可，不用改代码。数值写死在 `execute` 里就没法升级了。

## 五、加一张新卡

完整步骤见第零节的「可视化卡牌编辑器」。这里补两条字段层面的事。

`card_id` 相同的多个 `.tres` 就是同一张卡的多个副本，可以同时进牌组。原型卡就是这么做出来的：`data/cards/` 下 8 个 id 各两份。

`effects` 是一个有序数组，按顺序执行。一张卡要多段效果（比如「攻击 3 并叠 2 层中毒」）就加两个元素，不需要写新类。

## 六、buff 的三要素

PRG-008 要求 buff 含层数、持续回合数、效果。三要素分别落在：

| 要素    | 在哪                                          |
| ----- | ------------------------------------------- |
| 层数    | buff 字典的 `layers`，由 `on_turn_update` 决定怎么变  |
| 持续回合数 | buff 字典的 `duration`，由 `tick_duration` 决定怎么减 |
| 效果    | 子类的 `@export` 参数与钩子覆写                       |

运行期的一条 buff 是纯字典，活在状态机的 `player["buffs"]` 与 `enemies[i]["buffs"]` 里：

```gdscript
{"buff_id": "poison", "layers": 2, "duration": 0}
```

`BuffEffect` 是它的行为描述，不是它本身。

### 四个钩子各自独立

不同 buff 的结算方式差别很大，一套固定流程塞不下，所以拆成四个：

| 钩子                    | 管什么         | 覆写它的例子                                   |
| --------------------- | ----------- | ---------------------------------------- |
| `on_turn_update`      | 层数怎么变，返回新层数 | 中毒：减半向上取整                                |
| `tick_duration`       | 回合数怎么减      | 中毒：覆写成空实现，不受回合限制                         |
| `get_effect_strength` | 层数换算成多少强度   | `BuffEffectStat`：按 `amount_per_layer` 换算 |
| `is_expired`          | 何时到期        | 默认「层数归零即到期」；要永不超期的 buff 才覆写它             |

**只覆写一个不影响其他方面。** 自测里有专门的用例验这一条。

### duration 的语义

```
duration == 0   不限回合。tick_duration 对它不做任何事，永不因回合数被移除
duration > 0    剩余回合数。每回合减一，减到 0 即到期
```

**不能填负数。** 状态机的 `_valid_buff()` 要求非负，负数会被拒绝。

调用方每回合的顺序：

1. `on_turn_update(ctx, target, buff)` → 取回新层数并写回
2. `tick_duration(buff)` → 限时的减一
3. `is_expired(buff)` → 到期则 `end` 并从数组移除

### 已定的四条 buff

| buff | `buff_id`   | 层数变化       | 持续回合 | 实现                                                   |
| ---- | ----------- | ---------- | ---- | ---------------------------------------------------- |
| 力量   | `strength`  | 不变         | 1 回合 | `BuffEffectStat`，`stat=ATTACK`，`amount_per_layer=+1` |
| 虚弱   | `weak`      | 不变         | 1 回合 | `BuffEffectStat`，`stat=ATTACK`，`amount_per_layer=-1` |
| 坚韧   | `toughness` | 不变         | 由卡牌定 | `BuffEffectStat`，`stat=BLOCK`，`amount_per_layer=+1`  |
| 中毒   | `poison`    | **减半向上取整，1 层为特例归零** | 不限   | `BuffEffectPoison`                                   |

策划案 2.5 只写了这四条的每层效果，没写层数是否衰减。三条按「层数不变」实现——**不预设任何 buff 会衰减**。

中毒的层数规则是口述确认的：

```
中毒目标的回合结束时，扣除等于当前中毒层数的生命，然后中毒层数减半、向上取整。
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

**那个 1 层的例外是必要的。** `ceil(1 / 2)` 等于 1，不减这个特例的话 1 层中毒永远留着，而它每回合还在扣血，于是一条永不结束的持续伤害。有了特例，层数一定收敛到 0。

因为层数会走到 0，`BuffEffectPoison` **不需要**覆写 `is_expired`——基类默认的「层数归零即到期」正好是想要的行为。

## 七、校验工具

`systems/cards/card_catalog.gd`，`@tool`。在编辑器里打开它按 `Ctrl+Shift+X`，或在 FileSystem 面板右键选 `Run`。结果打印在输出面板。

它做检查器做不了的事：列出全部卡牌与字段、校验 `card_id` 是否重复或为空、校验 `effects` 里有没有空元素、统计每个效果被多少张卡引用（判断某个效果能不能删）。

**它不得引用** **`BattleStateMachine`。** 校验工具只负责静态卡牌数据，不应因为战斗状态机的依赖变化而失去独立运行能力。

## 八、与 PRG-004 的接口

### 效果层只认 EffectContext

`systems/cards/effect_context.gd`，29 个公开方法，分五组：

```
读状态      10 个   current_target / enemy_ids / player_health / player_block /
                    buff_layers / hand / play_zone / draw_pile_size /
                    discard_pile / pointer_index
改战斗数值   5 个   damage_enemy / damage_all_enemies / damage_player /
                    heal_player / add_block
改 buff      4 个   add_buff / set_buff_layers / override_buff_duration / tick_poison
改牌         9 个   draw / discard_from_hand / discard_random / add_card_to_zone /
                    move_card_in_play_zone / remove_from_battle / remove_from_run /
                    change_target / attach_effect
指针         2 个   rewind_pointer / move_pointer_to
```

三个造成伤害的方法都带 `ignore_block`。中毒这类 dot 要绕过格挡。

### 适配层与解析器已经接通

`systems/cards/battle_effect_context.gd` 把 `EffectContext` 的写操作编译为 `action.*` 指令；读取仍返回当前状态。`BattleEffectResolver` 注册 `card.effect_requested`、`buff.effect_requested` 等事件规则，按 `card_id` / `buff_id` 加载资源，将效果数组按顺序展开进统一队列。`BattleStatRules` 在动作执行时读取 Buff 修正数值，`BattleActionRules` 最后调用状态机公共方法落实结果。原请求信号保留供观察，不再承担系统效果执行。

选择弃牌可以放在效果数组任意位置，队列暂停后保留剩余效果；提交准确数量的实例 ID 后恢复，也支持连续两次选择弃牌。

`RunStateMachine` 无论新建还是恢复战斗都会挂载解析器。资源目录存在相同 `card_id` 时，解析器按路径排序选第一份作为定义；原型卡的同名副本因此有确定行为。

`CardEffectMovePointer.LEFT` 映射到 `request_pointer_rewind()`，`RIGHT` 映射到 `request_pointer_move_to()`。同一张移动牌在一段出牌序列中只允许成功改变一次指针，避免回跳后再次触发自身形成永久循环；所有真实触发仍受 256 次结算上限保护。

### 加 buff 必须先合并同名

**这一条不处理好会算错伤害，接手时不要漏。**

状态机的 `add_buff()` 只做数组追加，不按 `buff_id` 合并：

```gdscript
buffs.append(buff.duplicate(true))
```

而它的结算是「数组里有几条就发几次请求」：

```gdscript
for raw in buffs.duplicate(true):
	buff_effect_requested.emit(side, entity_id, buff.duplicate(true))
```

所以往同一目标加两次中毒（哪怕本意是「叠到 3 层」），数组里会有两条，**每回合扣两次血**。

`action.buff_add` 执行器必须通过 `change_buff_layers()` 按 `buff_id` 查同名：有则把 `layers` 累加到现有那条，无则新增。累加后为 0 的要把该条从数组移除，不留 `layers` 为 0 的空条。

自测里用一个真实实现的假上下文验过这条规则（`tests/test_effects/fake_effect_context.gd`）。

### 同名卡按 instance\_id 区分

牌是字典 `{"instance_id": "card-1", "card_id": "bonk"}`。`card_id` 是种类，`instance_id` 是这一局里唯一的那一张。

`discard_from_hand(instance_id)` 要传**实例** id。**适配层若误用** **`card_id`** **当键，弃掉一张同名卡会把另一张也弃掉。**

造牌时每张都要分配不同的 `instance_id`，包括同名卡。PRG-004 的读档校验会拒绝跨牌区重复的实例 id。

## 九、验证

```bash
godot --headless --import                                       # 退出码 0，零错误零警告
godot --headless --script res://tests/card_effect_selftest.gd    # 166 项全部通过
godot --headless --script res://tests/map_selftest.gd            # 32 项，PRG-011 回归
godot --headless --path . --scene res://tests/state_machine_selftest.tscn
godot --headless --path . --scene res://tests/card_battle_integration_selftest.tscn
```

效果自测覆盖两套效果的继承关系、卡牌与 buff 数据的字段与存读往返、8 种效果各自的行为、buff 三要素、中毒的减半与走完移除、四个钩子独立、同名卡按实例区分、实例 id 唯一、效果类的全局类名可载入、执行释放信号、磁盘上 16 份原型卡的一致性、`CardCatalog` 的校验能力。集成自测另覆盖真实 `RunStateMachine` 创建战斗、攻击与中毒结算、同名 buff 合并、一次性卡移除、回合推进，以及战斗与随机快照联合恢复后继续执行资源效果。

## 十、还没做的

| 项                              | 原因                       |
| ------------------------------ | ------------------------ |
| 7 条卡牌效果                        | 见下                       |
| 8 条之外的卡牌数据                     | PRG-013 的事，本轮只放原型卡       |
| 正式战斗表现层                        | 当前已有测试战斗界面，正式美术与表现仍需完善 |

`CardCatalog` 与检查器已在编辑器里实际运行过：16 个文件、8 个 `card_id`、8 组同名卡、7 个产品效果类被引用、未发现问题。

### 15 条效果里，本轮交了 8 条

分界线是「**只用 PRG-004 现有公开接口就能跑通**」。

**已实现**：攻击、自伤、治疗、格挡、buff 层数增减、抽牌、随机弃牌、选择弃牌、使用后从战斗中移除、左右移动指针、重复后一张牌、中毒。

**留后**（接口已预留，但真实战斗适配尚未实现）：

| 效果           | 留到      | 原因                  |
| ------------ | ------- | ------------------- |
| 获得特定牌        | 适配层     | 要适配层自己写造牌与入堆        |
| 向牌序特定位置加入牌   | 适配层     | 同上                  |
| 移动卡牌位置       | 适配层     | 药水与卡位规则未定           |
| 更改攻击目标       | 适配层     | 要改状态机的 `targets` 字典 |
| 为其他卡牌附加效果    | 适配层     | 要在牌字典上另加字段          |
| 使用后从本局移除     | 适配层     | 落点属 PRG-003         |
| 选择特定牌 | 后续目标选择 UI | 当前已完成选择弃牌；其他选牌语义仍需按具体卡牌补充 |

七条在 `EffectContext` 里的方法都已留好，将来照第四节加文件即可，不需要改已有文件。

### 原型卡是刻意重名的

`data/cards/` 下 16 个 `.tres`，8 个 `card_id` 各两份。重名不是为了做升级版，是为了验「按实例而非种类区分」——适配层如果把 `card_id` 当键，弃一张会把两张一起弃掉。

`CardCatalog` 会把同名卡报出来，这在本轮是预期的。正式卡牌数据里出现同名才是重复登记。

### 删掉的东西

第一阶段的 `CardHandle` 类型**已删除**。牌改用 PRG-004 的字典表示，那个整数编号的类型不再需要。同时删掉了配套的 `card_effect_context.gd` 占位文件。

如果你在别的分支上见过这两个文件，那是第一阶段的产物。

## 十一、接手前需要知道的几条

不是评价，是事实，都影响你怎么改代码。

**加一条效果不需要动已有文件。** 新建一个 `systems/cards/effects/` 或 `systems/buffs/effects/` 下的文件即可，编辑器会自动把它列进效果数组的候选。这一点有自测覆盖。

**两处会算错数值的地方，在第八节。** 加 buff 必须先合并同名，否则同一个 buff 加两次会在结算时触发两次；弃牌要按 `instance_id` 而非 `card_id`，否则同名卡会被一次弃掉两张。这两条不是风格问题，改的时候容易漏。

**效果层不依赖状态机。** 它只认 `EffectContext`。如果你要加的效果需要新的外界能力，先给这个接口加方法，再由适配层实现，不要在效果里直接引用 `systems/` 以外的东西。

**数值不要写死在** **`execute`** **里。** 一律用 `@export`。将来的卡牌升级要靠改数值实现。

**`duration`** **为 0 表示不限回合，不能填负数。** 状态机会拒绝负值的 buff。

**适配层已可跑真实战斗。** 单效果行为可用 `tests/test_effects/fake_effect_context.gd` 验证；涉及回合、牌区、buff 结算或存读档时，应运行 `tests/card_battle_integration_selftest.tscn`。

# 交接：战斗界面与卡面 UI

对应分支 `prg-017-018-ui`。这轮把战斗界面从「能跑」推到「能看」，主要动的是卡面渲染、战斗 HUD、出牌区交互和结算节奏。下面按「改了什么、在哪、怎么验证、还差什么」写。

## 未解决：战斗中典籍的显示

这条先写在最前面，免得接手的人以为已经做完。

战斗界面左上角那本典籍（`RelicBookView`，底图 UI-026）现在只是**静态展示**：按 `RelicBoard` 的 4×5 格子画出来、装配了哪块就显示哪块的贴图，没有任何交互，也没有「触发某个残片时亮一下」的表现。

要做的是：把残片按斜书页的透视贴到格子上（现在是正交切格子），并在 `battle_effect_rules` 触发某个残片时点亮对应格。装配动作应该在**背包界面**里完成（把残片从背包格拖到典籍上），战斗内不允许改。

## 零、快速接入

1. `git switch prg-017-018-ui`，用 Godot 4.7.2 打开工程根目录。
2. **首次打开让编辑器自己扫一遍资源**。命令行拉下来直接跑脚本会报 `Could not find type "SeedRegistry"`，因为全局类缓存还没生成；先执行一次 `godot --path . --headless --import`，之后再跑什么都不会报。
3. 直接 F5 就是战斗界面：`project.godot` 的 `run/main_scene` 在这条 UI 分支上指向 `ui/battle/battle_test_scene.tscn`，方便测。合进主线前要改回主菜单 `ui/main_menu/main_menu.tscn`，这条在合分支时别忘了。
4. 想改布局：改对应 `.tscn` 的节点矩形，不要改代码里算的坐标；`battle_test_scene.gd` 只负责刷新数值和交互。
5. 自测命令见第六节，八条全过再提。

## 一、卡面

统一的卡面预制件是 `ui/components/card/card_view.tscn` + `ui/components/card/card_view.gd`。所有位置（手牌、出牌区、牌堆、卡组、点开的大图）都实例化这一个场景，只是外层 `scale` 不同，不再各自排一套版式。

- 字号只在**卡内坐标**定一次：`LOCAL_TITLE_PX = 56`、`LOCAL_BODY_PX = 49`、`LOCAL_OUTLINE_PX = 3`。任何位置只改 `scale`，所以点开的大图就是同一张卡等比放大，不会出现「大图字更大、行距变了」。
- 描述不做逐卡自适应，所有卡同一档字、同一个框（`效果文本` 节点写在 tscn 里），水平居中 + 垂直居中，末行不会因为只剩一个字而重排。
- `description` 末尾的句号由 `CardView.strip_period()` 在渲染时去掉，`.tres` 里写不写句号都一样。
- 标题超宽时 `_fit_title_size()` 逐档降字号，`COMPACT_TITLE_WIDTH = 364`。
- 空卡图占位是白色底（`StyleBoxFlat_art_back.bg_color`），换正式卡图时只改 `art_back` 的 stylebox 或给 `art` 贴图。

改字号的正确姿势：改 `LOCAL_*` 常量，不要在各调用点传不同字号，否则又会回到「字到处乱飘」。

## 二、战斗界面

`ui/battle/battle_test_scene.tscn` / `.gd` 是战斗主界面。改布局优先改 tscn 里的节点矩形，别在代码里算坐标。

- **血条**：填充是自绘的 `ui/battle/health_fill.gd`（`HealthFill`），画平行四边形，右端跟着底图的斜切走，所以满血时不再留一个斜角缺口。`ratio` 做补间，格挡不再画成一条蓝色色块。
- **格挡盾**：`ui/battle/block_shield.gd`（`BlockShield`），画在血条右尾并盖住一段条身，盾面写层数。玩家 58×64 @ (346,30)、敌人 74×82 @ (1368,78)。
- **buff 行**：玩家行在血条左下 `(150,86)`，敌人在血条下沿 `(650,156)` 向右叠；chip 是 26×26 底板 + 22×22 图标 + 右下角层数，没配图标的 buff 数字居中。悬停走公共浮层。
- **敌人名字**：`EnemyName` 左端与血条数字同起点（x=650），底边压在血条红色填充上沿。
- **结算指针**：用 UI-012 的银色版 `UI-012-银.png`，59×48 左右，落在当前结算牌左侧。
- **抽牌堆/弃牌堆**：卡背 64×116，数字 20 号、名字 13 号，以屏幕中轴线对称摆在手牌两侧——抽牌堆 `(322,886)`、弃牌堆 `(1484,886)`，点开看牌堆大图。
- **左侧立绘与典籍**：主角立绘 `HeroPortrait` 矩形 `(-146,446)-(458.7,1414.2)`（底边留在屏幕外，保证腿露出来）；典籍 `RELIC_BOOK_POSITION = (0,286)`，两者上下错开不重叠。
- **货币**：左上角银币 `Coin`（`run.gold`，UI-023）与万灵药 `Elixir`（`run.elixir`，UI-028），两枚都用 AtlasTexture 裁掉透明边，尺寸一致。
- **蒙版**：战斗底图 `BackgroundDim` 0.34，弹窗/背包遮罩 `PileModalShade` 与 `RunMenuOverlay` 的 `_shade` 都是 0.85。
- **背包快捷栏**：21 格（7×3），和背包页是同一份 `run.items`，只是显示。物品用图标 + 悬停详情，不写文字。
- **特效**：`ui/battle/combat_feedback.gd` 由事件驱动（`combatant_damaged` / `combatant_healed` / `block_changed`），不再用「快照相减」判断血量变化 —— 那种写法会在每张牌结算时误判成治疗，BOSS 身上一直冒绿十字。序列帧播放见 `ui/battle/vfx_playback.gd`。

## 三、出牌区与指针

- 单列，`PLAY_STEP = 110`（卡名带底边 108，再小就被下一张切字），`PLAY_CARD_SCALE = 0.19`。
- 结算指针是**全局单节点**（`_settle_pointer`），不是每行挂一个。按距离配速 `clampf(distance / 1700.0, 0.14, 0.38)` 从上一张滑到当前张，落在卡牌左侧。
- 每张牌的节奏：指针滑到位 → 左侧大图淡入 → 停 `PREVIEW_HOLD = 0.5` 秒 → 结算数值与特效，整张约 1 秒。
- 交互全部手写在 `_input()` 里（GUI 拖放会被 ScrollContainer 吃掉）：
  - 手牌拖到出牌区：位移超过 8px 起拖，半透明虚影跟手，金色插入线标落点，松开按 y 换算插入位。
  - 出牌区内部拖动改序：只在被拖的那张原位留半透明占位，其余正常。
  - 点击出牌区的牌 = 拿回手牌（每行的 `TakeBack` 按钮）。
  - 点击牌堆/卡组 = 弹大图。

## 四、数据

- 卡面文案在 `data/cards/**/*.tres` 的 `card_name` / `description`。这轮把过长的规则文本缩短成一句效果，长解释留给卡牌详情或图鉴。
- 物品表 `data/text/items.csv`：`编号, 物品名, 图标路径, 效果文本`。图标路径直接写 `res://assets/ui/...`，换美术只改这一列。
- `TextCatalogService`（`systems/text/text_catalog.gd`）多了一个 `"items"` 分类；`tests/text_catalog_selftest.gd` 里只对四份「待策划填写」的模板断言「只有表头」，物品表是真实数据表，单独断言条数。
- 万灵药 `run_state_machine.gd` 里新增 `elixir` 字段（`change_elixir()`），写进快照；旧档没有这一项时按 0 读，不算损坏。
- 典籍板面 `systems/relics/relic_board.gd`：`COLUMNS = 4`、`ROWS = 5`（20 格），存档版本 2，1 版（4×3）的旧档载入时会平移到前 12 格。

## 五、资源

按项目约定不自造资源。这轮用到的资产编号：

| 编号 | 用途 | 位置 |
| --- | --- | --- |
| UI-003 | 大按钮 | `assets/ui/UI-003/` |
| UI-004 | 通用物品槽位框 | `assets/ui/UI-004/` |
| UI-012 | 结算指针 | `assets/ui/UI-012/` |
| UI-013 | 卡背 | `assets/ui/UI-013/` |
| UI-015 | 血条底图与边框 | `assets/ui/UI-015/` |
| UI-016 | 怪物意图标识 | `assets/ui/UI-016/` |
| UI-020 | 典籍残片 | `assets/ui/UI-020/` |
| UI-022 | 药剂图标（六色） | `assets/ui/UI-022/` |
| UI-023 | 银币图标 | `assets/ui/UI-023/` |
| UI-025 | buff 图标 | `assets/ui/UI-025/` |
| UI-026 | 典籍底图 | `assets/ui/UI-026/` |
| UI-028 | 万灵药图标 | `assets/ui/UI-028/` |

只保留代码与场景真正用到的编号。表里下过但没用上的（UI-002 物品描述底框、UI-006 关闭图标、UI-017 目标选中、UI-018 地图节点、UI-021）已经清掉，需要时用下面的命令重新拉：

```
lark-cli base +record-download-attachment --base-token NrDGbRJ00aQfI1sVvugczGHHnmb \
  --table-id tblWIEha9sBO0EWl --record-id <record_id> --output assets/ui/<编号> --overwrite
```

`assets/vfx/VFX-001/` 下的图集由交付的 BMP 序列转成透明底（脚本在 `docs/ops/` 有记录）。

## 六、自测

```
godot --path . res://tests/card_battle_integration_selftest.tscn --quit-after 900
godot --path . res://tests/battle_hand_input_selftest.tscn --quit-after 900
godot --path . res://tests/battle_effect_rules_selftest.tscn --quit-after 900
godot --path . res://tests/relic_ui_selftest.tscn --quit-after 900
godot --path . res://tests/relic_system_selftest.tscn --quit-after 900
godot --path . res://tests/battle_event_engine_selftest.tscn --quit-after 900
godot --path . res://tests/main_menu_integration_selftest.tscn --quit-after 900
godot --path . res://tests/text_catalog_selftest.tscn --quit-after 900
```

七个战斗/UI 自测 + 文本自测全过。退出码 0 且输出「全部通过」才算过。

## 七、还没做

1. **典籍改造**：战斗内应该只做点亮显示（斜书 + 贴合格子的残片，触发哪个亮哪个），装配改到背包页把残片拖到典籍上。当前战斗内还是旧的 `RelicBookView` 平铺格子，没有拖拽装配。
2. **物品使用**：`BattleStateMachine` 没有 `use_item` 接口，快捷栏只能看，点了没反应。
3. **卡面美术**：所有卡图仍是白色占位块，等正式卡图。
4. **音效**：战斗没有任何音效接入。

## 八、改之前先看

- 卡面任何位置不一致，先怀疑「是不是没走 `apply_compact_layout`」。`run_menu_overlay` 的大图曾经就因为漏调这一个方法，字号和外面不一致。
- 改 tscn 时注意 Godot 4.7 写出的节点属性**不带缩进**，用带 tab 的字符串做替换会静默不匹配。
- 战斗里不要用 `tooltip_text`，用 `ui/components/hover_tip.gd`（`HoverTip`），系统 tooltip 会被全屏控件吞掉。

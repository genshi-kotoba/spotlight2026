# 第四层：顶端

## 接入和流程

新开局使用 `main_menu_new_run.json` 的四个 map_ids，地图配置第4项为 `{"template":"summit-v1"}`。前三层的生成器和随机地址不变。第四层模板仅允许 floor_index=4，不接受其他配额参数，不消费地图随机流。

固定坐标：出生 `[0,0]` → 商店 `[6,0]` → Boss `[12,0]`。通路三格宽，节点位于同一轴线；商店可绕行、反复进入。地图只有商店与 Boss 两个交互节点，出生属于 snapshot.spawn。保持一坐标一通行面，高度只影响呈现。第四层使用固定显示种子和固定高度配置，货架保持随机。

第三层 Boss 胜利后，EncounterFlow 推进第四层；领取第三层奖励后回到第四层地图。第四层 Boss 胜利只设置 pending_run_victory，必须领取完最终奖励才由 RunResults 结束冒险。旧版三层存档保留原 map_ids、地图配置和终点，不自动补第四层。RunStateMachine 新建/恢复接受3或4层。

## 商店

RunShop 的接口与键不变：`open(run, request)`、`shelf(run, request)`、`buy_card(...)`、`buy_enchantment(...)`。键为 map_id/node_id。第四层沿用第三层价位，6张卡与3个附魔，独立种子 `shop/shelf-v1/map_id/node_id`；生成一次后将货架、售价和已售标记写入原存档，重进/读档不刷新。仍由原子保存/失败回滚保护交易。

## 固定 Boss

`MonsterCatalog.create("23", 4)`：人造之神，方舟缔造者，305生命。每敌方回合固定3动：攻击8、力量+1、格挡8。模板的怪物分配固定为23，即使以后候选表增加 Boss 也不随机替换。

首次降到半血时钳制为153并锁血，同回合后续攻击、残片和持续伤害均不穿透。下一玩家回合开始进入二阶段并解锁；一阶段每回合1张专属土星，二阶段每回合2张。

专属土星使用70号卡插画，但 `boss_saturn=true` 标识单独规则，普通70不变。右侧卡牌伤害+2、左侧-1，多个土星叠加；不可出牌、不可弃置。抽牌满手时从右向左跳过土星，弃掉前一张可弃牌。回合末摧毁所有土星及各自左侧手牌的并集，每个副本只一次，依次失去5、10、15……生命，忽略格挡。每次回合末计数重置。摧毁仅移除本场战斗副本，不删除永久牌组。

以下是本轮为落地补齐的明确规则：力量每次+1、半血取153、二阶段持续两张土星、回合末计数重置、重叠范围去重、机制牌不可提交到出牌区。

## 战斗与 UI 接口

- `FinalBossRules.is_saturn(card)` / `card_name()` / `card_description()` 供机制和卡面复用，勿修改70号卡的通用表。
- 机制牌属性 `boss_saturn`、`temporary`、`boss_owner` 只随 battle snapshot 保存，无永久 copy_id。Run永久牌组校验拒绝 boss_saturn/boss_owner。
- `BattleStateMachine.card_destroyed(card, reason)` / 队列事实 `card.destroyed` 区别于弃牌，不将销毁卡放入弃牌堆。
- UI外管自然抽牌时在开战前设置 `battle.player.external_natural_draw=true`，初始/每回合自然抽均调用 `draw_cards(count, BATTLE_START/TURN_START)`，即使 count=0 也调用；完成事实 `cards.natural_draw_completed` 后插入土星。自主抽牌的状态机保留原有 flow.turn.action 兜底。效果抽牌不触发额外土星。空出牌序列可结束玩家回合，以免仅剩机制牌时无法继续。
- 土星位置使用本场已有 battle.logic 随机流，不重置 SeedService；boss_saturn_turn 防止恢复或重复回调多发。
- 半血、阶段和发牌守卫保存在敌人字典中，通过原有 battle snapshot 冷恢复。无新增存档版本或全局重置。

## 验证边界

开发验证脚本与原生预览引导器在任务 output/verification、native-stage/qa 中，不属于产品提交。初版原生验收从隔离的第三层 Boss 前开始；美术与正式入口补充后，另外从主菜单新局验证第一至第四层的真实场景切换、领奖与最终结算，共33项通过。后一次验证用测试设置完成路线前置、调试结束 Boss 战，不代表自然游玩的四层完整通关。前三层生成另与旧版按相同种子对照。macOS 当前主线缺 Wwise 原生库，音频不在本轮验收范围。

## 第四层美术显示与正式入口补充

第四层 Boss/商店复用 UI-018 的 boss.png、shop.png，由 renderer_2d 的节点立绘分支绘制；第二、三层保留原有显示方式。既有圆形物理体、PNG下沿落点、迷雾、透明分区和已完成淡出不变。商店内景使用 EVBG-013，战斗本体使用 CHR-025。

人造之神（monster_id=23）的战斗立绘放大至1.35倍。EnemyRack只为该实体选择尺度；EnemySlot按 KEEP_ASPECT_CENTERED 实际图片的下沿保持落点，不放大血条和意图标记。贴图赋值使用 set_portrait_texture() 以同步显示和点击轮廓；箭头保留在屏幕内，手牌区仍优先接收输入。

正式工程仍以 ui/main_menu/main_menu.tscn 开始，新局完整顺序为第一→第二→第三→第四层，第四层Boss全领奖后结算。直达第四层的隔离引导器只属于旧验收应用，不进入正式工程。此次完整流程预览以主菜单开局，使用独立存档。

## 团队接入速查

| 模块 | 接口或配置 | 调用约束 |
|---|---|---|
| 新局层数 | `data/config/main_menu_new_run.json` 的 `map_ids`；`data/config/relief_2d/exploration.json` 的 `floors` | 两处按层序配对；第四项为 `world:floor-004` 与 `{"template":"summit-v1"}`。 |
| 地图生成 | 现有 `planar_map_generator.gd.generate(seed_source, map_id, floor_index, config)` | 第四层仅传 `{"template":"summit-v1"}`，不混入随机地图配额；返回原 schema_version=1 的 snapshot，继续交给原 MapRun/Session。 |
| 进层与结束 | `EncounterFlow.final_floor_count()` 与既有 Boss 胜利/领奖流程 | 不由界面手动跳层或提前结算；旧三层存档仍按其原配置结束。 |
| 随机货架 | `RunShop.open(run, request)`、`shelf(run, request)`、`buy_card(run, request, index)`、`buy_enchantment(run, request, index, copy_id)` | request 继续使用 Session 当前 pending 请求，包含 map_id/node_id/floor_index；不要在重进时直接调用 generate 重刷货架。 |
| 临时机制牌 | `FinalBossRules.is_saturn(card)`；`BattleStateMachine.card_destroyed` | 按副本属性识别，不凭 card_id=70 判断；销毁与弃置分离，禁止写入永久牌组。 |
| 自然抽牌与表现 | `external_natural_draw`、`draw_cards(count, reason)`；`EnemySlot.set_portrait_texture(texture)` | 外管抽牌必须完成 BATTLE_START/TURN_START 批次（包括0张）再让规则发机制牌；立绘通过 setter 更新，确保点击轮廓同步。 |

第四层立绘复用仓库已有资源：`assets/map_nodes/alchemy/boss.png`、`shop.png`、`assets/events/EVBG-013.png`、`assets/chr/CHR-025.png`。放大倍率集中在 `EnemyRack.FINAL_BOSS_PORTRAIT_SCALE`，目前为1.35，仅作用于23号怪物本体。没有新增外部依赖、存档版本或 seed 域，不改变前三层随机地址。

本次提交不携带 QA 脚本、测试场景、验收存档、预览包或调试设置开关；`ui/battle/battle_test_scene.gd` 是正式地图战斗继承的既有基类，属于运行依赖，必须随机制/UI接线一并提交。

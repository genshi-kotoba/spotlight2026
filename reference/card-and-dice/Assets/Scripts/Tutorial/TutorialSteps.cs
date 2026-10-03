// =============================================================================
// 模块：教学系统 - TutorialSteps 教学配置资产（ScriptableObject）
// 用途：教学全流程配置。运行时由 TutorialDirector 从 Resources 读取。
//       生成路径两条：① Inspector 手填；② 菜单 Tools/教程/创建 TutorialSteps 配置
//       （调 LoadDefaultsTutorial() 一键铺当前定稿的完整流程 S1–S42 共 42 拍）。
// ★2026-09-13 从 TutorialStepData.cs 拆出（排查发现，非风格偏好）：
//   Unity 的 MonoScript 只暴露「与 .cs 文件名同名的类」。TutorialSteps 混在
//   TutorialStepData.cs 里时，TutorialSteps.asset 的 m_Script 永远指不到它 ——
//   资产在编辑器里能看能改（靠内存实例），一旦 domain reload / 强制重导入，
//   Resources.Load 就返回 null、教学彻底不启动（`m_Script: {fileID: 0}`）。
//   拆成同名文件后引用才能正确序列化。改资产结构请改本文件，不要改资产 YAML。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

namespace Tutorial
{
    /// <summary>
    /// 教学配置资产。运行时由 TutorialDirector 从 Resources 读取。
    /// 创建方式：菜单 Tools/教程/创建 TutorialSteps 配置（自动放到 Assets/Resources/Tutorial/）。
    /// 在 Inspector 里手填每条拍即可，无需改代码。
    /// </summary>
    public class TutorialSteps : ScriptableObject
    {
        public List<TutorialStepData> steps = new List<TutorialStepData>();

        /// <summary>载入 2026-09-14 用户定稿的新手教程全流程（S1–S42，共 42 拍）。</summary>
        public void LoadDefaultsTutorial()
        {
            steps = new List<TutorialStepData>
            {
                // ---- S1 出生：清 UI + 0 骰 + 移动教学（框玩家 + 行动点，无引线）----
                Step("S1移动教学", TutorialTrigger.OnStart, TutorialRelease.PlayerMoved,
                    "这是你",
                    "点击地图上的格子进行移动，移动将会消耗行动点。\n请试着向右移动。",
                    focus: TutorialFocus.Player, showConfirm: false, drawLeader: false,
                    uiHide: new[]{"TurnText","ConsumableBar","HudBtn_0","HudBtn_1","HandView","EnergyPointDisplay","DrawPile","DiscardPile"},
                    setDicePerTurn: 0, focus2Path: "StatusBar/ActionPointsText",
                    watchCheckpoints: true,
                    cellList: new[]{ new Vector2Int(2,4), new Vector2Int(2,5), new Vector2Int(2,6), new Vector2Int(2,7), new Vector2Int(2,8) }),

                // ---- S2 检查点A（x=2 列）：停下+挂起回合+锁 → 镜头操作教学（操作完成后停 2 秒再推进）----
                Step("S2镜头教学", TutorialTrigger.ArriveAnyCell, TutorialRelease.CameraOperated,
                    "镜头操作",
                    "轻推 WASD 移动镜头，滚动滚轮缩放镜头。",
                    focus: TutorialFocus.None, showConfirm: false,
                    cellList: new[]{ new Vector2Int(2,4), new Vector2Int(2,5), new Vector2Int(2,6), new Vector2Int(2,7), new Vector2Int(2,8) },
                    autoEndTurn: true, lockInput: true, releaseDelay: 2f),

                // ---- S3 镜头操作完成后：补 4 骰 + 回到玩家回合 + 探索骰介绍（消耗 1 枚骰才推进）----
                Step("S3探索骰", TutorialTrigger.OnPreviousReleased, TutorialRelease.DiceConsumed,
                    "探索骰子",
                    "超过基础行动点的移动，每两格将会消耗一枚探索骰子。\n每回合最多花费 2 枚。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/DiceArea",
                    showConfirm: false,
                    setDicePerTurn: 4, startPlayerTurn: true,
                    watchCheckpoints: true,
                    cellList: new[]{ new Vector2Int(9,5), new Vector2Int(9,6), new Vector2Int(9,7) }),

                // ---- S4 检查点B（x=9 列）：停下+挂起回合（纯动作拍，不弹卡）----
                Step("S4检查点B", TutorialTrigger.ArriveAnyCell, TutorialRelease.Instant,
                    "", "", silent: true,
                    cellList: new[]{ new Vector2Int(9,5), new Vector2Int(9,6), new Vector2Int(9,7) },
                    autoEndTurn: true, lockInput: true),

                // ---- S5 战斗教学开场：运镜对准怪1 + 介绍敌人（框敌人本体）----
                Step("S5这是敌人", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "这是敌人",
                    "鼠标放到它周围的格子上，可以查看它的视野范围。",
                    focus: TutorialFocus.NamedEnemy, focusEnemyName: "哥布林",
                    cameraFly: true, focusCell: new Vector2Int(12,6), lockInput: true),

                // ---- S6 限定移动到怪1身边（补能量防卡死；走到 (13,6) 才推进，不给「知道了」）----
                Step("S6靠近敌人", TutorialTrigger.OnPreviousReleased, TutorialRelease.ArriveCell,
                    "抢占身位",
                    "现在，移动到它的身边。",
                    focus: TutorialFocus.MapCell, focusCell: new Vector2Int(13,6),
                    releaseCell: new Vector2Int(13,6),
                    showConfirm: false, resumeFollow: true,
                    startPlayerTurn: true, setEnergy: 3,
                    restrictMove: true, allowedCell: new Vector2Int(13,6), lockInput: true),

                // ---- S7 敌人发现你 / 你抢了先机 ----
                Step("S7先机", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "先手优势",
                    "敌人已经发现你了，不过你已经抢占了先机。",
                    focus: TutorialFocus.NamedEnemy, focusEnemyName: "哥布林", lockInput: true),

                // ---- S8 显示手牌（仅纵劈）+ 同时高亮敌人 → 拖动出牌 ----
                Step("S8纵劈", TutorialTrigger.OnPreviousReleased, TutorialRelease.CardPlayed,
                    "打出纵劈",
                    "拖动卡牌，对敌人使用纵劈吧！",
                    focus: TutorialFocus.HudPath, focusUiPath: "HandView",
                    // ★2026-09-13 用户需求：出牌的同时把敌人也圈亮（单蒙版双洞，两处都是真亮）
                    focus2: TutorialFocus.NamedEnemy, focus2EnemyName: "哥布林",
                    uiShow: new[]{"EnergyPointDisplay","DrawPile","DiscardPile","HandView"},
                    deckSingleCard: true, cardName: "纵劈", lockInput: true),

                // ---- S9 出牌消耗讲解 ----
                Step("S9出牌消耗", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "非战斗出牌",
                    "在非战斗状态下打出卡牌，需要消耗对应能量与 1 枚探索骰子。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/DiceArea", lockInput: true),

                // ---- S10 自动结束回合（纯动作拍）----
                Step("S10结束回合", TutorialTrigger.OnPreviousReleased, TutorialRelease.Instant,
                    "", "", silent: true, autoEndTurn: true, lockInput: true),

                // ---- S11 [伏击] 讲解 1（无高亮目标 → 全屏压暗，提示「现在还不能操作」）----
                Step("S11伏击", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "伏击",
                    "在非战斗状态下，对非战斗敌人造成伤害即可造成「伏击」。",
                    lockInput: true),

                // ---- S12 [伏击] 讲解 2 ----
                Step("S12伏击效果", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "伏击 · 效果",
                    "「伏击」将立即结束当前回合并使双方进入战斗状态，并且将你的能量回复至 3 点。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/EnergyPointDisplay", lockInput: true),

                // ---- S13 真正进战斗（恢复牌库 + 完成伏击 → 自动抽 5 张）----
                Step("S13战斗开始", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "真正的战斗",
                    "在战斗状态下打出卡牌，仅需消耗对应的能量点。",
                    restoreDeck: true, completeAmbush: true, lockInput: true),

                // ---- S14 敌人意图 ----
                Step("S14敌人意图", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "敌人意图",
                    "敌人将会展示它的意图和移动，鼠标悬停在地图格子上可以查看敌人意图的变化。",
                    focus: TutorialFocus.NamedEnemy, focusEnemyName: "哥布林", lockInput: true),

                // ---- S15 右侧敌人面板 ----
                Step("S15敌人面板", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "敌人面板",
                    "你可以在此处查看战斗中所有敌人的意图，以及它们每回合的行动点。",
                    focus: TutorialFocus.HudPath, focusUiPath: "EnemyRosterPanel", lockInput: true),

                // ---- S16 追击规则 ----
                Step("S16追击", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "追击",
                    "当敌人无法完成攻击意图后，会进行追击尽可能的接近你，并在下回合增加 1 点行动点（可叠加，有上限，直到完成攻击意图）。",
                    lockInput: true),

                // ---- S17 解锁自由行动 ----
                Step("S17自由行动", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "自由行动",
                    "现在，使用卡牌和走位战胜敌人吧！",
                    // ★2026-09-13 封格保持到整段教学结束：S17 起封 6 格，
                    //   S18/S19 继续 blockCells=true 顶住，S20（VictorySettled）才清空。
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(9,5),  new Vector2Int(9,6),  new Vector2Int(9,7) }),

                // ---- S18 下个回合：整备教学 + 染红 20 列 ----
                Step("S18整备", TutorialTrigger.PlayerTurnStarted, TutorialRelease.Prepared,
                    "能量管理",
                    "能量不会自动回复。你可以使用「整备」消耗一枚探索骰子，使能量回复至 3 点（每回合限一次）。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/EnergyPointDisplay",
                    // ★2026-09-14 用户口径：本拍不锁操作（lockInput 保持 0，6 格禁行照旧由 S17 延续），
                    //   但触发要等「玩家进入新回合 **且能量真的低于 3**」——否则能量已 ≥3 时无法整备，
                    //   release=Prepared 永远达不成会卡死。门槛没满足就先挂起，玩家自由操作把能量花下去。
                    triggerEnergyBelow: 3,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(9,5),  new Vector2Int(9,6),  new Vector2Int(9,7) }),

                // ---- S19 自动整备 ----
                Step("S19自动整备", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "自动整备",
                    "自动整备可以在能量为 0 时自动进行整备操作。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/EnergyPointDisplay/AutoPrepareToggle",
                    // ★2026-09-14 用户要求：本拍之前「自动整备」开关整体不显示，S19 出现才点亮
                    revealAutoPrepare: true,
                    // 继续顶住封格 —— 直到 S20（VictorySettled，击杀敌人）才解开
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(9,5),  new Vector2Int(9,6),  new Vector2Int(9,7) }),

                // ---- S20 击杀后：恢复常规状态（回合数/消耗品栏仍隐藏，卡包仍未解锁）----
                Step("S20阶段完成", TutorialTrigger.VictorySettled, TutorialRelease.OnConfirmButton,
                    "阶段性完成",
                    "很好，敌人已被解决。接下来由你自由探索。\n（回合数与消耗品栏暂不显示，战术卡包尚未解锁。）",
                    uiShow: new[]{"HudBtn_0"}),

                // ---- S21 击杀怪1后：封 22 列 + 走向篝火 ----
                Step("S21走向篝火", TutorialTrigger.OnPreviousReleased, TutorialRelease.ArriveCell,
                    "篝火",
                    "前面那堆火是篝火。在篝火旁休息，能花掉身上的探索骰子回复生命。\n过去看看。",
                    releaseCell: new Vector2Int(21, 6),
                    focus: TutorialFocus.MapCell, focusCell: new Vector2Int(21, 6),
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S22 到达篝火：点击打开篝火界面（教程期不自动弹，必须点）----
                Step("S22点击篝火", TutorialTrigger.OnPreviousReleased, TutorialRelease.BonfireOpened,
                    "升起的火堆",
                    "点一下脚下的篝火，打开篝火界面。",
                    focus: TutorialFocus.MapCell, focusCell: new Vector2Int(21, 6),
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S23 篝火界面：休息回血 ----
                Step("S23休息回血", TutorialTrigger.OnPreviousReleased, TutorialRelease.BonfireRested,
                    "休息",
                    "选「休息」，会消耗掉全部探索骰子，按数量回复生命。\n休息完，这个回合就结束了。",
                    focus: TutorialFocus.HudPath, focusUiPath: "BonfireUI/Panel/BtnRest",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S24 休息后：篝火旁生成箱子（复用遗物袋）+ 解锁背包/卡包按钮；只教「打开箱子」----
                Step("S24打开箱子", TutorialTrigger.OnPreviousReleased, TutorialRelease.LootOpened,
                    "箱子",
                    "篝火旁有只箱子，走上去打开它。",
                    focus: TutorialFocus.MapCell, focusCell: new Vector2Int(21, 5),
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) },
                    uiShow: new[]{"HudBtn_0", "HudBtn_1"},
                    spawnChest: true, chestCell: new Vector2Int(21, 5),
                    chestDice: DefaultChestDice(), chestDiceCount: 20,
                    chestDice2: DefaultPotion(), chestDice2Count: 1),

                // ---- S25 高亮箱内两件东西 → 要求把箱子拿空（★LootEmptied：拿过不等于拿空）----
                //   为什么要"拿空"：S28 要指着消耗品栏讲那瓶回血药水，玩家少拿一瓶这里就落空。
                Step("S25拿取", TutorialTrigger.OnPreviousReleased, TutorialRelease.LootEmptied,
                    "拿取",
                    "箱子里是战斗骰子和一瓶回血药水。点它们收进背包，或者直接点「一键全拿」把箱子拿空。",
                    focus: TutorialFocus.HudPath,
                    focusUiPath: "LootPopupPanel/Panel/Card_袋内物资/Grid_袋内物资/BagSlot_0",
                    focus2: TutorialFocus.HudPath,
                    focus2Path: "LootPopupPanel/Panel/Card_袋内物资/Grid_袋内物资/BagSlot_1",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S26 打开背包（关闭箱窗后推进上来）----
                Step("S26打开背包", TutorialTrigger.OnPreviousReleased, TutorialRelease.InventoryOpened,
                    "背包",
                    "战利品都收好了。点一下 HUD 上的背包按钮，打开背包看看。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/BagCardSettingsBar/HudBtn_0",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S27 介绍背包分区（关掉背包才推进）----
                Step("S27背包分区", TutorialTrigger.OnPreviousReleased, TutorialRelease.InventoryClosed,
                    "背包分区",
                    "背包分四个区：常规放材料与杂物，骰子区放战斗骰，道具区是消耗品，右下角这一格是保险箱。\n看完按 B 或点「关闭」把背包收起来。",
                    focus: TutorialFocus.HudPath, focusUiPath: "InventoryPanel/Panel/Card_常规",
                    focus2: TutorialFocus.HudPath, focus2Path: "InventoryPanel/Panel/Card_保险箱",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S28 解锁并介绍消耗品栏（★2026-09-13 用户纠正：只讲解，不要求真的用掉消耗品）----
                //   原实现要求「用掉一件消耗品」才推进；但玩家刚在 S23 篝火休息完、血量是健康的，
                //   为过教学去灌一瓶药既不合理也走不通 → 改成「点知道了」推进的纯讲解拍。
                Step("S28消耗品栏", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "消耗品栏",
                    "顶栏这排格子就是消耗品栏，跟背包的道具区同步。\n从箱子里拿到的那瓶回血药水就放在这里——需要的时候点一下就能用。",
                    // 焦点用整排容器而不是 PotionSlot1：药水被玩家换到别的格子、或那格恰好为空时，
                    // 指具体格子会高亮落空；容器焦点取 active 子节点并集，整排一起亮。
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/ConsumableBar",
                    uiShow: new[]{"ConsumableBar", "HudBtn_0", "HudBtn_1"},
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S29 装填教学 · 1 打开卡包（20+22 双封到 S35 结束：装填教学期间玩家关在口袋里）----
                Step("S29打开卡包", TutorialTrigger.OnPreviousReleased, TutorialRelease.CardPackOpened,
                    "装填",
                    "战斗骰子要装进卡牌的骰槽，卡牌才能发挥真正的实力。\n点一下 HUD 上的「卡包」按钮。",
                    focus: TutorialFocus.HudPath, focusUiPath: "StatusBar/BagCardSettingsBar/HudBtn_1",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) },
                    uiShow: new[]{"HudBtn_0", "HudBtn_1"}),

                // ---- S30 装填教学 · 2 打开装填界面 ----
                //   ★激活动作：把牌库所有带骰槽的卡标成「未装填」——教程里玩家的卡不默认装填，
                //   要玩家亲手装一遍（非教程图才由系统自动装填 + 右下角提示）。
                Step("S30打开装填", TutorialTrigger.OnPreviousReleased, TutorialRelease.LoadoutOpened,
                    "进入装填",
                    "点「装填」按钮，进入装填界面。",
                    focus: TutorialFocus.HudPath, focusUiPath: "CardPackPanel/Panel/LoadoutButton",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) },
                    unloadAllCards: true),

                // ---- S31 装填教学 · 3 点左侧一张卡 ----
                //   高亮卡列表容器；玩家点大类行或子菜单实例行都算（OnCardSelected）。
                //   dimScreen=false：装填界面是模态面板，压暗会把界面一起盖住。
                Step("S31点一张卡", TutorialTrigger.OnPreviousReleased, TutorialRelease.CardSelected,
                    "选一张卡",
                    "左边是牌库清单。点一张卡（比如纵劈）——点大类行会展开同名卡子菜单。\n" +
                    "在大类上装填会作用于所有同名卡；在子菜单里点一张，就只给那一张装。",
                    focus: TutorialFocus.HudPath, focusUiPath: "LoadoutPanel/Panel/CardList",
                    showConfirm: false, dimScreen: false,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S32 装填教学 · 4 点右侧骰子槽（★v2.5 细化拆拍）----
                Step("S32点骰子槽", TutorialTrigger.OnPreviousReleased, TutorialRelease.SlotSelected,
                    "选中骰子槽",
                    "右侧是这张卡的骰子槽。点一下「槽 1」把它选中。",
                    focus: TutorialFocus.HudPath, focusUiPath: "LoadoutPanel/Panel/SlotArea/DiceSlot_0",
                    showConfirm: false, dimScreen: false,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S33 装填教学 · 5 下方选骰子装上 ----
                //   「卸下」行（AssignDice(null)）不算装填——提示里明确叫玩家点一个真骰子。
                Step("S33选骰子", TutorialTrigger.OnPreviousReleased, TutorialRelease.LoadoutConfigured,
                    "装上骰子",
                    "下方是可选骰子列表。点一个骰子（比如破旧骰子），装进刚选的槽。\n" +
                    "第一行的「卸下」= 这个槽留空、战斗时用临时骰子，先别点它。",
                    focus: TutorialFocus.HudPath, focusUiPath: "LoadoutPanel/Panel/DiceList",
                    showConfirm: false, dimScreen: false,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S34 装填教学 · 6 自动装填 ----
                Step("S34自动装填", TutorialTrigger.OnPreviousReleased, TutorialRelease.LoadoutConfigured,
                    "自动装填",
                    "手动装一张就够练手了，剩下的交给「自动装填」：把还没装填的卡一键装上背包里最好的战斗骰子。\n" +
                    "已经手动装过的卡不会被覆盖。",
                    focus: TutorialFocus.HudPath, focusUiPath: "LoadoutPanel/Panel/AutoLoadoutButton",
                    showConfirm: false, dimScreen: false,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S35 装填教学 · 7 收尾（★用户定稿：不给「知道了」，关掉两个界面才推进）----
                //   release=CardPackClosed：装填界面必先关、卡包后关 → 关包 = 终点。
                //   dimScreen=false：装填/卡包界面还开着，压暗会盖住界面。
                //   ★2026-09-14 二改：S29–S35 期间 20+22 双封（用户定稿：装填教学把玩家关在口袋里）；
                //     Director 封格已改替换语义——S36 激活时自动放开 22、续封 20，无需断链拍。
                Step("S35装填完成", TutorialTrigger.OnPreviousReleased, TutorialRelease.CardPackClosed,
                    "装填完成",
                    "所有卡牌都已经装上战斗骰子了。只有装上战斗骰子，卡牌才能发挥真正的实力。\n" +
                    "关掉装填界面和卡包界面，回到地图。",
                    focus: TutorialFocus.None, drawLeader: false, showConfirm: false, dimScreen: false,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(22,5), new Vector2Int(22,6), new Vector2Int(22,7) }),

                // ---- S36 第二幕 · 1 运镜看怪（★照 S5 范式：运镜对准大室双怪 + 锁操作）----
                //   ★2026-09-14 改版：激活时移除篝火 + 封住身后 20 列（y=4 行 x20-22 是墙，完全封死）；
                //   取消原 S37 检查点——玩家确认后自由进大室，靠红?触发推进意图传导。
                Step("S36注意两怪", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "注意，前面有两只",
                    "大室里有两只怪：一只哥布林，一只史莱姆。\n先看清楚它们的位置和走位。",
                    focus: TutorialFocus.NamedEnemy, focusEnemyName: "哥布林",
                    focus2: TutorialFocus.NamedEnemy, focus2EnemyName: "史莱姆",
                    cameraFly: true, focusCell: new Vector2Int(28,6), lockInput: true,
                    removeBonfire: true, blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(35,5), new Vector2Int(35,6), new Vector2Int(35,7) }),

                // ---- S37 第二幕 · 2 身后封口保持 + 介绍巡逻（结束几个回合观察，红?亮起时 S38 自动接上）----
                Step("S37巡逻介绍", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "它们在巡逻",
                    "这两只怪每回合都会来回巡逻。\n连续结束几个回合，看它们怎么走、离你多远。\n" +
                    "身后路口已经封住，不用担心被包抄。",
                    focus: TutorialFocus.NamedEnemy, focusEnemyName: "哥布林",
                    focus2: TutorialFocus.NamedEnemy, focus2EnemyName: "史莱姆",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(35,5), new Vector2Int(35,6), new Vector2Int(35,7) }),

                // ---- S38 第二幕 · 3 意图传导（红?首次亮起 = 怪看见了怪；画面与文案同帧吻合）----
                Step("S38意图传导", TutorialTrigger.RedQuestionBadge, TutorialRelease.OnConfirmButton,
                    "警报会传染",
                    "哥布林亮起红!——它发现你了。\n再看史莱姆：它没看见你，但看见了同伴的警报，亮起了问号。\n" +
                    "小队之间会传导警戒：一只惊动，附近的怪都会警觉。",
                    focus: TutorialFocus.NamedEnemy, focusEnemyName: "哥布林",
                    focus2: TutorialFocus.NamedEnemy, focus2EnemyName: "史莱姆",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(35,5), new Vector2Int(35,6), new Vector2Int(35,7) }),

                // ---- S39 第二幕 · 4 探索抽牌 + 封住东口（防直奔藏身处跳过战斗）----
                Step("S39探索抽牌", TutorialTrigger.OnPreviousReleased, TutorialRelease.OnConfirmButton,
                    "探索的手牌",
                    "探索阶段每个回合开始，都会从牌库随机抽 5 张手牌；没打出的牌回合结束自动放回牌库，" +
                    "下回合重新抽——每回合手牌都是新的。\n打牌要花探索骰。",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(35,5), new Vector2Int(35,6), new Vector2Int(35,7) }),

                // ---- S40 第二幕 · 5 重投教学（战斗开始解锁；重投或点「知道了」都推进）----
                //   激活动作：enableReroll 解锁门禁 + setDice=3 保底（保证有骰可花）。
                //   RequestRelease 与 release 类型无关 → showConfirm=true + release=RerollUsed = 二选一推进。
                Step("S40重投", TutorialTrigger.EnterBattle, TutorialRelease.RerollUsed,
                    "重投",
                    "骰子不满意？悬停一张手牌，右下角有 ⟳ 重投按钮：按住它再松开，" +
                    "花 1 枚探索骰，这张卡的全部骰子一起重掷，卡面数字就地刷新。\n" +
                    "战斗和探索都能用。试试看——或者点「知道了」先跳过。",
                    showConfirm: true, dimScreen: false, setDice: 3, enableReroll: true,
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(35,5), new Vector2Int(35,6), new Vector2Int(35,7) }),

                // ---- S41 第二幕 · 6 恭喜（第二场战斗胜利；怪3 若还在，玩家自行决定打法）----
                Step("S41恭喜", TutorialTrigger.VictorySettled, TutorialRelease.OnConfirmButton,
                    "漂亮！",
                    "这场打得干净利落。剩下怎么走你自己决定——偷袭、正面、绕路都行。",
                    blockCells: true,
                    cellList: new[]{ new Vector2Int(20,5), new Vector2Int(20,6), new Vector2Int(20,7),
                                     new Vector2Int(35,5), new Vector2Int(35,6), new Vector2Int(35,7) }),

                // ---- S42 第二幕 · 7 前往藏身处（走到 O(39,6)：教学完成 + 入口放行 → 进藏身处）----
                //   不封格：本拍激活即解除 S36 起的所有禁行（走到 O 时 HideoutEntrance 已放行）。
                // ---- S42 第二幕 · 7 前往藏身处（走到 O(39,6)：教学完成 + 入口放行 → 进藏身处）----
                //   不封格：本拍激活即解除全部禁行（走到 O 时 HideoutEntrance 已放行）。
                //   ★2026-09-14 用户定稿：requireAllEnemiesDefeated——必须战胜两只怪（场上无存活敌人）
                //   本拍才会出现；上一拍解除时若战斗提前胜利、怪没清完，Director 每帧重试等清场。
                Step("S42前往藏身处", TutorialTrigger.OnPreviousReleased, TutorialRelease.ArriveCell,
                    "回家",
                    "两只怪都清掉了。穿过小走廊，前面就是藏身处入口——你的局外基地。\n走进去，教程完成。",
                    focus: TutorialFocus.MapCell, focusCell: new Vector2Int(39,6),
                    releaseCell: new Vector2Int(39,6), completesTutorial: true,
                    requireAllEnemiesDefeated: true),
            };
        }

        /// <summary>
        /// 默认装填用的「破旧骰子」物品（S24 教学箱子的主内容物）。
        /// ★编辑器专用：只有「Tools/教程/创建 TutorialSteps 配置」重新生成资产时才需要；
        ///   运行时读的是已序列化进资产里的引用，不经过这里。
        /// </summary>
        private static ItemData DefaultChestDice()
        {
#if UNITY_EDITOR
            return UnityEditor.AssetDatabase.LoadAssetAtPath<ItemData>("Assets/Data/Items/破旧骰子.asset");
#else
            return null;
#endif
        }

        /// <summary>★v2.3 箱子里的第二件东西：回血药水（S25 让玩家练「在消耗品栏点用」）。</summary>
        private static ItemData DefaultPotion()
        {
#if UNITY_EDITOR
            return UnityEditor.AssetDatabase.LoadAssetAtPath<ItemData>("Assets/Data/Items/回血药水.asset");
#else
            return null;
#endif
        }

        private static TutorialStepData Step(string id, TutorialTrigger t, TutorialRelease r, string title, string body,
            TutorialFocus focus = TutorialFocus.None, bool showConfirm = true, bool completesTutorial = false,
            Vector2Int triggerCell = default, Vector2Int releaseCell = default, TutorialBoxAnchor boxAnchor = TutorialBoxAnchor.TopLeft,
            string[] uiHide = null, string[] uiShow = null, Vector2Int[] cellList = null,
            int setDice = -1, int setDicePerTurn = -1, int setEnergy = -1,
            bool startPlayerTurn = false, bool autoEndTurn = false, bool cameraFly = false,
            bool deckSingleCard = false, bool restoreDeck = false, bool completeAmbush = false,
            bool lockInput = false, bool restrictMove = false, Vector2Int allowedCell = default,
            bool blockCells = false, bool silent = false, bool drawLeader = true,
            string focusUiPath = "", string focus2Path = "", string focusEnemyName = "", string cardName = "",
            Vector2Int focusCell = default, bool watchCheckpoints = false,
            float releaseDelay = 0f, bool resumeFollow = false,
            bool spawnChest = false, Vector2Int chestCell = default, ItemData chestDice = null, int chestDiceCount = 20,
            TutorialFocus focus2 = TutorialFocus.None, Vector2Int focus2Cell = default,
            ItemData chestDice2 = null, int chestDice2Count = 1,
            string focus2EnemyName = "", bool unloadAllCards = false, bool dimScreen = true,
            bool enableReroll = false, bool removeBonfire = false,
            bool requireAllEnemiesDefeated = false, bool revealAutoPrepare = false,
            int triggerEnergyBelow = -1)
        {
            var s = new TutorialStepData
            {
                id = id, trigger = t, release = r, title = title, body = body,
                focus = focus, showConfirm = showConfirm, completesTutorial = completesTutorial,
                boxAnchor = boxAnchor, silent = silent, drawLeader = drawLeader,
                setDice = setDice, setDicePerTurn = setDicePerTurn, setEnergy = setEnergy,
                startPlayerTurn = startPlayerTurn, autoEndTurn = autoEndTurn, cameraFly = cameraFly,
                deckSingleCard = deckSingleCard, restoreDeck = restoreDeck, completeAmbush = completeAmbush,
                lockInput = lockInput, restrictMove = restrictMove, blockCells = blockCells,
                focusUiPath = focusUiPath, focus2UiPath = focus2Path, focusEnemyName = focusEnemyName,
                cardName = cardName, watchCheckpoints = watchCheckpoints,
                releaseDelay = releaseDelay, resumeFollow = resumeFollow,
                allowedCell = allowedCell == default ? new Vector2Int(13, 6) : allowedCell,
                triggerCell = triggerCell == default ? new Vector2Int(20, 6) : triggerCell,
                releaseCell = releaseCell == default ? new Vector2Int(20, 6) : releaseCell,
                focusCell = focusCell == default ? new Vector2Int(20, 6) : focusCell,
                spawnChest = spawnChest,
                chestCell = chestCell == default ? new Vector2Int(21, 5) : chestCell,
                chestDice = chestDice,
                chestDiceCount = chestDiceCount,
                chestDice2 = chestDice2,
                chestDice2Count = chestDice2Count,
                focus2 = focus2,
                focus2Cell = focus2Cell == default ? new Vector2Int(20, 6) : focus2Cell,
                unloadAllCards = unloadAllCards,
                dimScreen = dimScreen,
                enableReroll = enableReroll,
                removeBonfire = removeBonfire,
                requireAllEnemiesDefeated = requireAllEnemiesDefeated,
                revealAutoPrepare = revealAutoPrepare,
                triggerEnergyBelow = triggerEnergyBelow,
            };
            // ★v2.3：focus2=NamedEnemy 复用同一个 focusEnemyName 会与主焦点打架（S8 主焦点是手牌区、
            //   只有名字过滤属于第二目标）→ 单独给第二目标一个名字过滤。
            // ★v2.6：focus2EnemyName 进真字段（ApplySecondFocus 空时回落 focusEnemyName），
            //   不再覆写主焦点的 focusEnemyName —— 否则"主=哥布林 副=史莱姆"会双双圈到史莱姆。
            s.focus2EnemyName = focus2EnemyName;
            if (uiHide != null) s.uiHide = new List<string>(uiHide);
            if (uiShow != null) s.uiShow = new List<string>(uiShow);
            if (cellList != null) s.cellList = new List<Vector2Int>(cellList);
            return s;
        }
    }
}

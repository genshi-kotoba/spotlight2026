// =============================================================================
// 模块：Tutorial - 教学拍数据模型（通用编辑器的基础，v2）
// 用途：把「一条教学提示 + 一组激活动作」抽成可在 Inspector 里手填的数据。
//       v2（2026-09-12 用户全流程定稿）新增：
//       检查点列 / UI 显隐 / 骰子·能量设定 / 挂起回合 / 限定格 / 禁行格 /
//       相机运镜 / 出牌触发 / 教学牌库 / 伏击接管 / 第二焦点。
//       v2.3（2026-09-13）新增：第二焦点可指定世界目标（敌人/格子）、箱子第二件内容物、
//       背包/消耗品/箱子打开 四条解除条件。
// 你（策划/本人）在 Unity 编辑器里改的是 TutorialSteps.asset，不用碰代码。
// ★2026-09-13：TutorialSteps 资产类已拆到同名文件 TutorialSteps.cs —— Unity 的 MonoScript
//   只暴露「与 .cs 文件名同名的类」，混在本文件里资产会丢掉脚本引用（Resources.Load 返回 null）。
//   本文件现在只装枚举 + TutorialStepData（单条拍的数据模型）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

namespace Tutorial
{
    /// <summary>触发条件（这条提示什么时候出现）。</summary>
    public enum TutorialTrigger
    {
        OnStart,              // 教学启动时立即弹（仅首拍用）
        OnPreviousReleased,   // 上一拍解除后顺延（链式：不挑时机，紧跟上一拍）
        ExplorationTurnStarted, // 探索态回合开始
        EnterBattle,          // 进入战斗
        EnterExploring,       // 战斗胜利后回到探索
        RedQuestionBadge,     // 视野内出现红`?`威胁预告
        EnemyEntersView,      // 视野内第一次出现存活敌人
        HoverPreviewShown,    // 悬停预览可用
        VictorySettled,       // 战斗胜利结算
        AmbushLaunched,       // 玩家发起一次偷袭
        ArriveCell,           // 玩家走到指定格子（用 triggerCell）
        ArriveAnyCell,        // ★v2 玩家走到 cellList 中任意一格（检查点列）
        CardPlayed,           // ★v2 打出 cardName 的卡（空 = 任意卡）
        PlayerTurnStarted,    // ★v2 战斗玩家回合开始（下个回合用）
    }

    /// <summary>解除条件（这条提示什么时候收起 / 推进到下一拍）。</summary>
    public enum TutorialRelease
    {
        OnConfirmButton,      // 玩家点「知道了」
        PlayerMoved,          // 玩家移动 ≥ 1 格
        LeaveSpawn,           // 玩家离开出生格
        RedQuestionGone,      // 红`?`消失
        AmbushLaunched,       // 玩家发起一次偷袭
        LootSelected,         // 玩家完成一次掠夺选择
        HoverPreviewHeld,     // 成功悬停某可达格 ≥ 0.5s
        ArriveCell,           // 走到指定格子（用 releaseCell）
        Manual,               // 不自动解除；下一拍触发时自动盖掉
        CameraOperated,       // ★v2 玩家操作了镜头（WASD 平移 或 滚轮缩放，任一即可）
        CardPlayed,           // ★v2 打出 cardName 的卡（空 = 任意卡）
        Prepared,             // ★v2 玩家完成一次整备（手动或自动）
        Instant,              // ★v2 激活后立即解除（纯动作拍：激活动作做完就顺延下一拍）
        // ★★纪律：新增枚举值一律追加到末尾！插在中间会让旧资产里按序号序列化的值整体错位
        //   （2026-09-12 实锤：DiceConsumed 曾插在 Instant 前，导致资产里 S4/S10 的 Instant 被错读成 DiceConsumed 而卡死）。
        DiceConsumed,         // ★v2.1 玩家消耗 1 枚探索骰（移动自动扣骰 或 点骰子按钮，两条链路都算）
        BonfireOpened,        // ★v2.2 玩家打开了篝火界面（BonfireUI.ShowBonfire）
        BonfireRested,        // ★v2.2 玩家在篝火完成一次休息（BonfireUI.OnRest 结束）
        LoadoutConfigured,    // ★v2.2 玩家在装填界面完成一次装填（手动换骰 或 点「自动装填」）
        LootOpened,           // ★v2.3 玩家走到了箱子/遗物袋格、搜刮窗自动打开（LootPopupUI.Open）
        InventoryOpened,      // ★v2.3 玩家打开了背包界面（InventoryUI.Open）
        InventoryClosed,      // ★v2.3 玩家关掉了背包界面（InventoryUI.Close）
        ConsumableUsed,       // ★v2.3 玩家用掉了一件消耗品（ConsumableBar.UseSlot 结算成功）
                              //   ★2026-09-13 暂未挂拍：S28 已改成「只讲解消耗品栏」的拍。
                              //   钩子（ConsumableBar.OnConsumableUsed）保留备用，将来若要教真用消耗品可直接挂。
        LootEmptied,          // ★v2.3.1 玩家把箱子/遗物袋**拿空**了（LootPopupUI.Close 时 IsEmpty==true）
                              //   与 LootSelected 的区别：LootSelected = 拿过任意一件；LootEmptied = 拿空。
                              //   S25 用后者，保证后续 S28 高亮的消耗品栏里确实有那瓶药。
        CardPackOpened,       // ★v2.4 玩家打开了卡包界面（CardPackUI.Show）
        LoadoutOpened,        // ★v2.4 玩家打开了装填界面（LoadoutUI.Open）
        CardSelected,         // ★v2.4 玩家在装填界面点了左侧一张卡（大类行或子菜单实例行都算）
        CardPackClosed,       // ★v2.4 玩家**真正关掉**了卡包界面（S33 收尾：装填界面必先关、卡包后关）
        SlotSelected,         // ★v2.5 玩家点了装填界面右侧一个骰子槽（LoadoutUI.OnSlotSelected）
        RerollUsed,           // ★v2.6 玩家完成了一次重投（CardRerollButton.OnRerolled；重投教学拍同时保留「知道了」兜底）
    }

    /// <summary>高亮焦点（黄铜圈 + 引线指向哪里）。</summary>
    public enum TutorialFocus
    {
        None,        // 不圈任何东西（纯文字卡）
        HudDice,     // 顶部探索骰区
        HudHand,     // 手牌区
        HudEnergy,   // 能量指示器
        HudEndTurn,  // 结束回合按钮
        HudPath,     // ★v2 UICanvas 下的任意节点（focusUiPath）
        Player,      // 玩家脚下（世界坐标，跟随移动）
        FirstEnemy,  // 第一个存活敌人（世界坐标，跟随移动）
        NamedEnemy,  // ★v2 名字包含 focusEnemyName 的存活敌人中离玩家最近者
        MapCell,     // 指定地图格（focusCell，世界坐标）
        ScreenRect   // 指定屏幕矩形（focusScreenRect，像素）
    }

    /// <summary>提示框在屏幕哪个角（Auto = 左上角，2026-09-13 定稿：所有提示框默认左上）。</summary>
    public enum TutorialBoxAnchor
    {
        Auto,        // ★默认左上角（运行时按 TopLeft 处理；保留枚举位是为了旧资产序列化兼容）
        TopLeft,
        TopRight,
        BottomLeft,
        BottomRight,
        Center
    }

    /// <summary>单条教学拍的可序列化配置（v2）。</summary>
    [System.Serializable]
    public class TutorialStepData
    {
        [Tooltip("拍的唯一 id（调试用，例如 S1 / 镜头 / 伏击）")] public string id = "Step";
        public TutorialTrigger trigger = TutorialTrigger.OnPreviousReleased;
        [Tooltip("trigger=ArriveCell 时：玩家走到这个坐标才触发")] public Vector2Int triggerCell = new Vector2Int(20, 6);
        [Tooltip("trigger/release=ArriveAnyCell 或 CardPlayed 时使用的格子列表")] public List<Vector2Int> cellList = new List<Vector2Int>();
        public TutorialRelease release = TutorialRelease.OnConfirmButton;
        [Tooltip("release=ArriveCell 时：走到这个坐标才解除")] public Vector2Int releaseCell = new Vector2Int(20, 6);
        [Tooltip("是否显示「知道了」按钮（false=靠行为自动收起，不卡操作）")] public bool showConfirm = true;
        [Tooltip("解除条件达成后延迟 N 秒再收卡推进（0=立即）。用于「操作完成后停一拍再讲下一条」")] public float releaseDelay = 0f;
        [Tooltip("激活时镜头恢复跟随玩家（从教学运镜交还跟随，如 S6 允许移动前）")] public bool resumeFollow = false;
        [Tooltip("解除时是否标记教学完成（tutorialStage→1，下次启动进藏身处）")] public bool completesTutorial = false;

        // ---------- 文案 ----------
        [Tooltip("卡片标题（大字；silent=true 时不弹卡）")] public string title = "标题";
        [TextArea(2, 6)] [Tooltip("卡片正文（支持换行）")] public string body = "正文说明文字……";
        [Tooltip("本拍不弹提示卡（纯动作拍：只执行激活动作）")] public bool silent = false;

        // ---------- 焦点 ----------
        public TutorialFocus focus = TutorialFocus.None;
        [Tooltip("focus=MapCell / cameraFly 时使用的地图格")] public Vector2Int focusCell = new Vector2Int(20, 6);
        [Tooltip("focus=ScreenRect 时：圈这个屏幕矩形（x,y,w,h，屏幕像素，原点左下）")] public Rect focusScreenRect = new Rect(0, 0, 200, 200);
        [Tooltip("focus=HudPath 时：UICanvas 下的节点路径（如 StatusBar/DiceArea）")] public string focusUiPath = "";
        [Tooltip("focus=NamedEnemy 时：敌人名字包含此串（如 哥布林），取离玩家最近者")] public string focusEnemyName = "";
        [Tooltip("★v2.6 focus2=NamedEnemy 时：第二焦点敌人名字（空 = 回落 focusEnemyName）")] public string focus2EnemyName = "";
        [Tooltip("是否从卡片拉一条黄铜引线指向焦点")] public bool drawLeader = true;

        // ---------- ★v2.3 第二焦点（可选，与主焦点同时亮） ----------
        [Tooltip("第二焦点类型。None = 不用（若 focus2UiPath 非空仍按 UI 节点处理，兼容 v2 旧数据）")]
        public TutorialFocus focus2 = TutorialFocus.None;
        [Tooltip("focus2=MapCell 时使用的地图格")] public Vector2Int focus2Cell = new Vector2Int(20, 6);
        [Tooltip("focus2=HudPath 时：UICanvas 下的节点路径（如 StatusBar/ActionPointsText）")] public string focus2UiPath = "";

        // ---------- 提示框位置 ----------
        [Tooltip("提示框在屏幕哪个角（Auto/TopLeft = 左上角默认）")] public TutorialBoxAnchor boxAnchor = TutorialBoxAnchor.TopLeft;
        [Tooltip("提示框相对角点的像素偏移（向右/下为正）")] public Vector2 boxOffset = Vector2.zero;

        // ---------- ★v2 激活动作（激活本拍时依次执行） ----------
        [Tooltip("激活时隐藏的 UI（UICanvas 下节点名或名字前缀，如 TurnText / DrawPile）")] public List<string> uiHide = new List<string>();
        [Tooltip("激活时显示的 UI（同上）")] public List<string> uiShow = new List<string>();
        [Tooltip("激活时把探索骰池设为恰好 N 枚（-1=不改）")] public int setDice = -1;
        [Tooltip("激活时设置每回合探索骰数 dicePerTurn（-1=不改）")] public int setDicePerTurn = -1;
        [Tooltip("激活时把能量设为 N（-1=不改）")] public int setEnergy = -1;
        [Tooltip("激活时开始一个新的探索玩家回合（从挂起中恢复）")] public bool startPlayerTurn = false;
        [Tooltip("激活时自动结束当前探索回合（挂起式：不巡逻、不开下一回合）")] public bool autoEndTurn = false;
        [Tooltip("激活时镜头缓慢飞到 focusCell 中心并恢复默认缩放")] public bool cameraFly = false;
        [Tooltip("激活时把手牌/牌库临时换成仅一张 cardName")] public bool deckSingleCard = false;
        [Tooltip("激活时恢复完整牌库（配合伏击进战斗）")] public bool restoreDeck = false;
        [Tooltip("激活时完成被接管的伏击：进入战斗（玩家先手）")] public bool completeAmbush = false;
        [Tooltip("激活时锁住玩家操作（移动/出牌/结束回合/耗骰）；release=CardPlayed 时自动放行出牌")] public bool lockInput = false;
        [Tooltip("激活时把牌库所有带骰槽的卡标记为「未装填」（教程 S29-S33 用：让玩家从头走一遍装填）")] public bool unloadAllCards = false;
        [Tooltip("激活时解锁教程期的重投屏蔽（CardView.EnsureRerollButton 门禁，S41 重投教学拍用）")] public bool enableReroll = false;
        [Tooltip("激活时移除场景内全部篝火（拆 BonfireTile 组件+标记，不动地形格；S36 改版用）")] public bool removeBonfire = false;
        [Tooltip("★2026-09-14 激活时点亮「自动整备」开关：教程图里该开关默认整体隐藏（S19 教学拍出现前不给玩家看），" +
                 "本拍置 true 才显示。非教程图不受此门禁影响。")] public bool revealAutoPrepare = false;
        [Tooltip("激活门槛：场上必须无任何存活敌人（教学 S42 前往藏身处——战胜两只怪才会出现）")] public bool requireAllEnemiesDefeated = false;
        [Tooltip("★2026-09-14 触发附加门槛：玩家能量低于该值时才激活本拍（-1 = 不启用）。\n" +
                 "用于 S18：进入新回合后要能量真的掉到 3 以下才弹「整备」教学——\n" +
                 "若回合开始时能量已 ≥3（无法整备、release=Prepared 永远达不成）就先挂起等待，\n" +
                 "期间不锁操作，玩家打牌把能量花下去即可满足。")] public int triggerEnergyBelow = -1;
        [Tooltip("focus=None 且要玩家点「知道了」时是否整屏压暗（默认压；卡包/装填等模态界面打开着的拍要关掉，否则把界面也压暗）")] public bool dimScreen = true;
        [Tooltip("激活时只允许移动到 allowedCell")] public bool restrictMove = false;
        [Tooltip("restrictMove 的目标格")] public Vector2Int allowedCell = new Vector2Int(13, 6);
        [Tooltip("激活时把 cellList 染红并禁行（清空前点击无效）")] public bool blockCells = false;
        [Tooltip("激活时在 chestCell 生成一个箱子（★v2.2：复用遗物袋机制，玩家走到该格自动弹搜刮窗）")]
        public bool spawnChest = false;
        [Tooltip("spawnChest 的箱子格坐标")] public Vector2Int chestCell = new Vector2Int(21, 5);
        [Tooltip("spawnChest 箱内主物品（ItemData，如破旧骰子）")] public ItemData chestDice;
        [Tooltip("spawnChest 箱内主物品数量")] public int chestDiceCount = 20;
        [Tooltip("★v2.3 spawnChest 箱内第二件物品（可选，如回血药水）")] public ItemData chestDice2;
        [Tooltip("★v2.3 spawnChest 箱内第二件物品数量")] public int chestDice2Count = 1;
        [Tooltip("本拍激活期间监听检查点：玩家移动途中踏入 cellList 任意一格 → 立即中断移动并激活下一拍")] public bool watchCheckpoints = false;
        [Tooltip("触发/解除 CardPlayed 时的卡名过滤（空 = 任意卡）")] public string cardName = "";
    }

}

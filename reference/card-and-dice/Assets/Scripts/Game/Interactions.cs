// =============================================================================
// 模块：P7 交互管理器 - Interactions（纯静态类）
// 用途：集中管理玩家交互的可行性，提供唯一的"能不能交互"判断入口：
//       1. 拖动卡牌中 → 禁止触发其他卡牌的悬停效果
//       2. ActionSystem 执行动作链中 → 禁止开始新的拖动/交互
// 参考教程：NSWells P7 Card Dragging 的 Interactions 系统
// 与视频的差异：视频用 MonoBehaviour 挂场景 Systems 对象；本项目无 Inspector
//       配置需求，用纯静态类零成本接入（用户 2026-08-16 确认）。
// ★2026-09-14：新增 DevPanelOpen —— 开发者面板（F9）打开时屏蔽全部游戏输入。
// =============================================================================

using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 全局交互管理器（纯静态类）。
/// 拖动流程约定（与视频一致）：
///   CardView.OnBeginDrag 设 PlayerIsDragging = true
///   CardView.OnEndDrag   设 PlayerIsDragging = false
/// </summary>
public static class Interactions
{
    /// <summary>
    /// 玩家是否正在拖动卡牌。
    /// 由 CardView 的 OnBeginDrag / OnEndDrag 维护。
    /// </summary>
    public static bool PlayerIsDragging { get; set; }

    /// <summary>
    /// ★2026-08-18：卡牌交互流是否进行中（拖动 / 点击跟随 / 箭头指向）。
    /// 由 HandUIController 的 BeginFlow / ClearFlowVisuals 维护。
    /// HexMover 消费：为 true 时禁用全部移动交互——
    /// 点击移动、移动路径预览高亮、鼠标指向格子高亮（修"出牌时还能移动"bug）。
    /// </summary>
    public static bool CardInteractionActive { get; set; }

    /// <summary>
    /// ★2026-08-25 探索事件弹窗模态锁：事件/鉴定/撤离确认弹窗打开期间为 true。
    /// 消费方：HexMover（禁移动交互）、PlayerCanInteract（禁拖牌）。
    /// 由 EventPopupUI 在打开/关闭时维护（探索系统 v2 §7.4 弹窗模态）。
    /// </summary>
    public static bool ModalPopupActive { get; set; }

    /// <summary>
    /// ★2026-09-14 开发者面板（F9，仅编辑器）全屏锁：**面板打开期间屏蔽全部游戏输入**——
    /// WASD 平移 / 滚轮缩放镜头、点击移动与悬停预览、空格结束回合、出牌、背包开关键。
    /// 由 DevPanel 在开/关时维护（打开=true / 关闭=false）。
    /// 面板自己的按钮不受影响（独立 Canvas + EventSystem，走 UI 事件系统而非裸 Input）。
    /// ★2026-09-17 起 DevPanel 在正式包里同样编译（用户裁定导出包可用 F9）→ 构建包里打开面板同样置 true。
    /// 消费方：Interactions 自身（PlayerCanInteract / CanUseEndTurnButton / AnyOverlayOpen）、
    ///         HexMover、CameraController、InventoryUI、EnemyMovePreview。
    /// </summary>
    public static bool DevPanelOpen { get; set; }

    // ==================================================================
    // ★2026-09-12 教学门禁（由 TutorialDirector 维护，教学拍数据驱动）
    // ==================================================================
    /// <summary>教学锁：锁住 移动 / 出牌 / 结束回合 / 耗骰（教学提示确认链期间）。</summary>
    public static bool TutorialLockInput { get; set; }

    /// <summary>教学锁的例外：当前拍要求玩家出牌（release=CardPlayed）时放行出牌、其余照锁。</summary>
    public static bool TutorialAllowCards { get; set; }

    /// <summary>教学限定：只允许移动到该格（null = 不限定）。</summary>
    public static Vector2Int? TutorialAllowedCell { get; set; }

    /// <summary>教学禁行格（染红、点击无效，如 Hex_20_5/6/7）。</summary>
    public static readonly System.Collections.Generic.HashSet<Vector2Int> TutorialBlockedCells
        = new System.Collections.Generic.HashSet<Vector2Int>();

    /// <summary>教学检查点：多格移动途中踏入任意一格 → 立即中断后续移动（MoveSequence 每步检查）。</summary>
    public static readonly System.Collections.Generic.HashSet<Vector2Int> TutorialCheckpointCells
        = new System.Collections.Generic.HashSet<Vector2Int>();

    /// <summary>
    /// 玩家是否可以交互（开始拖动 / 打出卡牌等主动操作）。
    /// ActionSystem 正在执行动作链（动画/结算）时返回 false，防止结算期间再次出牌。
    /// </summary>
    public static bool PlayerCanInteract()
    {
        // ★开发者面板打开：最高优先级，一切玩家操作为它让路
        if (DevPanelOpen) return false;

        // ★教学锁：锁操作期间禁出牌（当前拍要求出牌时放行）
        if (TutorialLockInput && !TutorialAllowCards) return false;

        // ★2026-08-25 探索态禁牌 → ★2026-09-05 探索态全解禁（用户定稿）：
        // 探索中随时可打牌，每张牌消耗 1 枚探索骰子（CanPayCardCost 查、PlayCardSystem 扣）。
        // 警戒中打中警戒单位 → 偷袭进战斗（§9.1.2，PlayCardSystem 快照检测）。
        // 拦截点覆盖 CardView.OnBeginDrag 与 HandUIController.BeginClickFollow 两个入口；
        // 悬停查看（PlayerCanHover）不受影响。

        // M6-5（2026-08-19）：敌人回合互斥——敌人行动期间禁止玩家拖动/出牌/移动。
        if (TurnManager.Instance != null && TurnManager.Instance.IsEnemyTurn())
        {
            return false;
        }

        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState == GameState.Exploring
            && ExplorationTurnManager.Instance != null
            && !ExplorationTurnManager.Instance.IsPlayerPhase())
        {
            return false;
        }

        // ActionSystem 未创建（极端情况）视为可交互
        return ActionSystem.Instance == null || !ActionSystem.Instance.IsPerforming;
    }

    /// <summary>结束回合只在玩家行动阶段可点（探索巡逻 / 战斗敌人回合都锁住）。</summary>
    public static bool CanUseEndTurnButton()
    {
        if (DevPanelOpen) return false;        // ★开发者面板打开
        if (TutorialLockInput) return false;   // ★教学锁：提示确认链期间不能结束回合
        if (ModalPopupActive) return false;
        if (GameStateManager.Instance == null) return false;

        if (GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            return TurnManager.Instance != null
                && TurnManager.Instance.IsPlayerTurn()
                && !TurnManager.Instance.IsEnemyTurn();
        }

        if (GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            return ExplorationTurnManager.Instance != null
                && ExplorationTurnManager.Instance.IsPlayerPhase();
        }

        return false;
    }

    // ★2026-09-16 性能二批：结束回合按钮缓存（原实现每次 GameObject.Find 走整棵层级树，
    //   而本方法在每次回合边界要调 2–3 次）。按钮不存在时不缓存，下次继续找。
    static Button s_endTurnButton;

    public static void RefreshEndTurnButton()
    {
        if (s_endTurnButton == null)
        {
            GameObject obj = GameObject.Find("UICanvas/EndTurnButton");
            if (obj == null) return;
            s_endTurnButton = obj.GetComponent<Button>();
            if (s_endTurnButton == null) return;
        }
        s_endTurnButton.interactable = CanUseEndTurnButton();
    }

    /// <summary>
    /// 出牌费用门槛检查（拖动/点击前置拦截统一入口）。
    ///   战斗态与探索态都检查能量 CanAfford；探索态额外检查至少剩 1 枚探索骰。
    ///   （用户 2026-09-09：探索打牌除扣探索骰外也扣能量）
    /// 实际扣费在 PlayCardSystem.PerformPlayCard 按状态分流。
    /// </summary>
    public static bool CanPayCardCost(Card card)
    {
        if (card == null) return false;

        // 能量检查（战斗态与探索态都扣能量）
        EnergyPointDisplay epd = Object.FindObjectOfType<EnergyPointDisplay>();
        if (epd != null && !epd.CanAfford(card.CurrentCost)) return false;

        // 探索态额外检查探索骰子（每张牌 1 枚）
        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            return ExplorationTurnManager.Instance != null
                   && ExplorationTurnManager.Instance.RemainingExplorationDice() > 0;
        }

        return true;
    }

    /// <summary>
    /// 玩家是否可以触发卡牌悬停效果。
    /// 拖动卡牌期间返回 false（避免拖动时其他卡牌跟着扇开/立正）。
    /// </summary>
    public static bool PlayerCanHover()
    {
        return !PlayerIsDragging;
    }

    // ==================================================================
    // ★2026-09-12 全局快捷键（右键耗骰换步 / 空格结束回合）的「让路」判定
    // ==================================================================
    // 用户定稿的例外只有两条（"打开背包的时候以及手上正操作着卡牌的时候"），
    // 但把所有"会挡住战场"的界面一并算进来才安全——不然会出现
    // 「在事件弹窗里按空格把回合结束了」这种不可逆的事故。

    /// <summary>
    /// 手牌 / 战术卡交互流进行中：拖动、点击跟随、箭头指向任一成立即为 true。
    /// ★快捷键必须让路 —— "手上正操作着卡牌"的时候就该只认卡牌操作。
    /// </summary>
    public static bool CardFlowBusy => CardInteractionActive || PlayerIsDragging;

    /// <summary>
    /// 有面板 / 弹窗 / 全屏界面打开（挡住战场）。
    /// ModalPopupActive 覆盖：背包 InventoryUI、装填 LoadoutUI、事件 EventPopupUI、
    /// 搜刮 LootPopupUI、篝火 BonfireUI、战报 BattleSettlementUI。
    /// CardPackUI 是非模态设计（不置 ModalPopupActive），单独判；
    /// 设置 / 魂灯同样单独判。开发者面板（DevPanelOpen）也算一种。
    /// </summary>
    public static bool AnyOverlayOpen()
    {
        if (DevPanelOpen) return true;
        if (ModalPopupActive) return true;
        if (CardPackUI.Instance != null && CardPackUI.Instance.IsOpen) return true;
        if (SettingsUI.IsOpen) return true;
        if (SoulLanternUI.IsOpen) return true;
        return false;
    }

    /// <summary>
    /// 全局快捷键当前是否可用（空格 / 右键共用）：没有界面挡着 + 没有在操作卡牌 + 不在结算。
    /// </summary>
    public static bool CanUseGlobalHotkeys()
    {
        if (TutorialLockInput) return false;   // ★教学锁：空格等快捷键一并让路
        if (AnyOverlayOpen()) return false;
        if (CardFlowBusy) return false;
        if (ActionSystem.Instance != null && ActionSystem.Instance.IsPerforming) return false;
        return true;
    }
}

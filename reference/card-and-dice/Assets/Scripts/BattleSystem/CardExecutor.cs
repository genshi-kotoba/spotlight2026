// =============================================================================
// 模块：M5b 卡牌战斗执行器 CardExecutor
// 用途：编排"选中→能量检查→射程→目标→掷骰→效果→弃牌"完整打牌链路
// 设计依据：《开发计划》M5 任务清单 + 《总策划案》第十一部分战斗系统
// 职责边界：
//   - 只做"执行编排"，不持有牌堆数据（CardPileManager 管）
//   - 不直接操作 UI（通过事件通知 HandUIController/BattleHUD）
//   - 不直接扣血（调 EnemyController.TakeDamage）
//   - 不直接管能量（调 EnergyPointDisplay.TryConsumeEnergy）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 打牌执行状态机（线性流程，Demo 不需要复杂状态机）
/// </summary>
public enum CardExecutionState
{
    Idle,           // 空闲，等待玩家选中卡牌
    CardSelected,   // 已选中卡牌，等待选择目标
    Executing,      // 正在执行（掷骰/应用效果中），禁止新输入
}

/// <summary>
/// M5b 卡牌战斗执行器单例。
/// 挂载于 MainScene 的 GameManager 对象（与 TurnManager/GameStateManager 共存）。
/// 订阅 HandUIController.OnCardSelected 事件驱动整个打牌流程。
/// </summary>
public class CardExecutor : MonoBehaviour
{
    // ======== 单例 ========
    public static CardExecutor Instance { get; private set; }

    // ======== 配置 ========
    [Header("调试")]
    [Tooltip("是否打印详细执行日志（答辩演示时可关闭）")]
    public bool VerboseLog = true;

    // ======== 运行时状态 ========
    /// <summary>当前执行状态</summary>
    public CardExecutionState State { get; private set; } = CardExecutionState.Idle;

    /// <summary>当前选中的卡牌运行时实例（null = 未选中）</summary>
    public Card SelectedCard { get; private set; }

    /// <summary>当前选中的目标敌人（null = 未选中）</summary>
    public EnemyController SelectedTarget { get; private set; }

    /// <summary>当前选中的 CardView（用于取消选中时恢复边框）</summary>
    private CardView _selectedCardView;

    // ======== 缓存引用 ========
    private HexMover _hexMover;
    private EnergyPointDisplay _energyDisplay;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    private void Start()
    {
        // 缓存引用
        _hexMover = FindObjectOfType<HexMover>();
        _energyDisplay = FindObjectOfType<EnergyPointDisplay>();

        // 订阅 HandUIController 的选中事件
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.OnCardSelected += OnCardSelected;
            HandUIController.Instance.OnSelectionCleared += OnSelectionCleared;
        }

        // 订阅 GameStateManager：离开战斗时重置状态
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged += HandleStateChanged;
        }
    }

    private void OnDestroy()
    {
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.OnCardSelected -= OnCardSelected;
            HandUIController.Instance.OnSelectionCleared -= OnSelectionCleared;
        }
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged -= HandleStateChanged;
        }
    }

    // ------------------------------------------------------------------
    // M5b-1 已实现：卡牌选中 + 能量检查 + 状态切换
    // ------------------------------------------------------------------

    /// <summary>
    /// 卡牌被选中回调（由 HandUIController.OnCardSelected 事件驱动）。
    /// HandUIController 已做能量检查，这里只做状态切换 + 射程/目标高亮请求。
    /// </summary>
    private void OnCardSelected(CardView cardView)
    {
        if (cardView == null || cardView.CardData == null) return;

        // 如果正在执行中，忽略新选中
        if (State == CardExecutionState.Executing)
        {
            Debug.LogWarning("[CardExecutor] 正在执行中，无法选中新卡牌");
            return;
        }

        // 取消之前的选中（如果有）
        CancelSelection();

        SelectedCard = cardView.Card;
        _selectedCardView = cardView;
        State = CardExecutionState.CardSelected;

        if (VerboseLog && SelectedCard != null)
        {
            Debug.Log($"[CardExecutor] 状态切换：Idle → CardSelected | 卡牌={SelectedCard.Data?.cardName}, " +
                      $"能量消耗={SelectedCard.CurrentCost}");
        }

        // TODO M5b-2：射程高亮 + 目标高亮
        // OnRequestRangeHighlight?.Invoke(playerCoord, range);
        // OnRequestTargetHighlight?.Invoke(敌人列表);
    }

    /// <summary>
    /// 选中被清除回调（由 HandUIController.OnSelectionCleared 事件驱动）。
    /// </summary>
    private void OnSelectionCleared()
    {
        if (State != CardExecutionState.CardSelected) return;

        ResetSelection();
        if (VerboseLog) Debug.Log("[CardExecutor] 选中被清除，状态恢复 Idle");
    }

    /// <summary>
    /// 尝试选择一个目标敌人。由 EnemyController.OnPointerClick 驱动。
    /// M5b-1 仅做骨架：检查状态 → 记录目标 → 留待 M5b-2/3 实现射程检查和执行。
    /// </summary>
    /// <param name="target">目标敌人</param>
    public void TrySelectTarget(EnemyController target)
    {
        if (State != CardExecutionState.CardSelected)
        {
            Debug.LogWarning("[CardExecutor] 当前状态不是 CardSelected，忽略目标选择");
            return;
        }
        if (target == null) return;
        if (SelectedCard == null) return;

        // TODO M5b-2：射程检查 - HexDistance(playerCoord, target.CurrentCoord) <= range
        // TODO M5b-3：开始执行 - ExecuteCardPipeline()

        SelectedTarget = target;
        Debug.Log($"[CardExecutor] 目标已选择：{target.gameObject.name}（M5b-2 射程检查待实现）");
    }

    /// <summary>
    /// 取消当前选中（点空地 / ESC / 右键调用）。
    /// 清除高亮 + 清除选中态 + 重置状态。
    /// </summary>
    public void CancelSelection()
    {
        if (State == CardExecutionState.Idle) return;

        // 清除选中卡牌的边框
        if (_selectedCardView != null)
        {
            _selectedCardView.SetSelected(false);
            _selectedCardView = null;
        }

        // 通知 HandUIController 清除选中
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.ClearSelection();
        }

        // TODO M5b-2：清除射程高亮
        // OnClearRangeHighlight?.Invoke();

        ResetSelection();
    }

    /// <summary>
    /// 重置选中状态（不触发额外事件，供内部调用）
    /// </summary>
    private void ResetSelection()
    {
        SelectedCard = null;
        SelectedTarget = null;
        _selectedCardView = null;
        State = CardExecutionState.Idle;
    }

    // ------------------------------------------------------------------
    // M5b-3 待实现（仅签名，供后续实现）
    // ------------------------------------------------------------------

    /// <summary>
    /// 获取指定 ValueConfig 的解析结果（baseValue + 骰子点数）。
    /// M5b-3 核心公式：finalValue = baseValue + diceRoll（若绑定了骰子）。
    /// </summary>
    /// <param name="config">数值配置</param>
    /// <param name="diceResults">本次掷骰结果数组（索引对应 DiceSelect 枚举）</param>
    /// <returns>解析后的最终数值</returns>
    public int ResolveValue(ValueConfig config, int[] diceResults)
    {
        // ★M5b-3（2026-08-18）实现：基础值 + 选中骰子点数（F5.2）
        if (config == null) return 0;

        int finalValue = config.baseValue;
        if (config.diceSelect != DiceSelect.无 && diceResults != null)
        {
            int diceIdx = (int)config.diceSelect - 1;
            if (diceIdx >= 0 && diceIdx < diceResults.Length)
            {
                int diceValue = diceResults[diceIdx];
                if (diceValue > 0) finalValue += diceValue; // -1（未投）按 0 计
            }
        }
        return finalValue;
    }

    /// <summary>
    /// 计算玩家坐标到目标坐标的六边形距离。
    /// 用于射程检查（M5b-2）。
    /// 当前使用 offset 坐标系（Hex_{x}_{y}），先转 cube 再算距离。
    /// ★2026-08-18 修正：本项目地图是【平顶六边形 + 奇数列偏移】（odd-q offset，
    /// 见 HexGridLayout.GetHexPos：奇数 x 列在 z 方向偏移 h/2），
    /// 原实现误用 odd-r（奇数行偏移）公式，导致距离随位置系统性出错
    /// （高亮不完整/越界，且同格复现）。高亮与射程判定共用本函数，一处修正两处全好。
    /// </summary>
    /// <param name="from">起点坐标</param>
    /// <param name="to">终点坐标</param>
    /// <returns>六边形格距</returns>
    public static int HexDistance(Vector2Int from, Vector2Int to)
    {
        int fromCol = from.x;
        int fromRow = from.y;
        int toCol = to.x;
        int toRow = to.y;

        // Offset → Cube（odd-q offset，平顶布局，奇数列下移）
        // 参考：https://www.redblobgames.com/grids/hexagons/#conversions-offset
        int fromCubeX = fromCol;
        int fromCubeZ = fromRow - (fromCol - (fromCol & 1)) / 2;
        int fromCubeY = -fromCubeX - fromCubeZ;

        int toCubeX = toCol;
        int toCubeZ = toRow - (toCol - (toCol & 1)) / 2;
        int toCubeY = -toCubeX - toCubeZ;

        // Cube 距离 = max(|dx|, |dy|, |dz|)
        int dx = Mathf.Abs(toCubeX - fromCubeX);
        int dy = Mathf.Abs(toCubeY - fromCubeY);
        int dz = Mathf.Abs(toCubeZ - fromCubeZ);

        return Mathf.Max(dx, dy, dz);
    }

    // ------------------------------------------------------------------
    // 状态切换处理
    // ------------------------------------------------------------------
    private void HandleStateChanged(GameState oldState, GameState newState)
    {
        // 离开战斗时重置
        if (newState != GameState.Battle)
        {
            CancelSelection();
        }
    }
}
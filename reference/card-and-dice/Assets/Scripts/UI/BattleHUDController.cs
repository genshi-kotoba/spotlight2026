// =============================================================================
// 模块：M5a 底部战斗 HUD BattleHUDController
// 用途：抽牌堆计数 + 弃牌堆计数 + 结束回合按钮绑定
// 设计依据：docs/superpowers/specs/2026-08-08-m5a-card-runtime-ui-design.md §2.4
// 职责边界：只管 HUD 数据刷新和按钮绑定，不重写已有组件
// =============================================================================
using UnityEngine;
using UnityEngine.UI;
using TMPro;

/// <summary>
/// 底部战斗 HUD 控制器。
/// 订阅 CardPileManager.OnPileRefreshed 刷新抽/弃计数；
/// 结束回合按钮绑定 TurnManager.EndPlayerTurn()。
/// 注意：TurnManager 已有自己的 EndTurnButton 查找逻辑（GameObject.Find("UICanvas/EndTurnButton")），
/// 如果 BattleHUDController 的 EndTurnButton 为空，则不重复绑定。
/// </summary>
public class BattleHUDController : MonoBehaviour
{
    [Header("UI 引用")]
    [Tooltip("抽牌堆计数文本，显示抽牌堆剩余张数")]
    public TMP_Text DrawPileCountText;

    [Tooltip("弃牌堆计数文本，显示弃牌堆张数")]
    public TMP_Text DiscardPileCountText;

    [Tooltip("结束回合按钮（如果底部 HUD 有自己的按钮才绑，否则 null 由 TurnManager 自己处理）")]
    public Button EndTurnButton;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Start()
    {
        // 订阅牌堆刷新事件
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.OnPileRefreshed += RefreshCounts;
            RefreshCounts(); // 初始刷新一次
        }

        // 绑定结束回合按钮（可选：如果底部 HUD 有自己的按钮）
        if (EndTurnButton != null && TurnManager.Instance != null)
        {
            EndTurnButton.onClick.AddListener(() => TurnManager.Instance.EndPlayerTurn());
        }
    }

    private void OnDestroy()
    {
        // 取消订阅，避免内存泄漏
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.OnPileRefreshed -= RefreshCounts;
        }
    }

    // ------------------------------------------------------------------
    // 数据刷新
    // ------------------------------------------------------------------

    /// <summary>
    /// 刷新抽牌堆和弃牌堆的计数文本
    /// </summary>
    private void RefreshCounts()
    {
        if (CardPileManager.Instance == null) return;

        if (DrawPileCountText != null)
        {
            DrawPileCountText.text = CardPileManager.Instance.DrawPile.Count.ToString();
        }

        if (DiscardPileCountText != null)
        {
            DiscardPileCountText.text = CardPileManager.Instance.DiscardPile.Count.ToString();
        }
    }
}
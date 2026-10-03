// =============================================================================
// 模块：P4.5 动作系统 - CardPileSystem 牌堆系统
// 用途：注册 DrawCardAction / DiscardCardAction 的执行者，
//       把抽牌/弃牌动作接到 CardPileManager（复用 M5a 的三 List 管理逻辑）
// 公式依据：F2.1 战斗前抽 5 张；手牌上限 10（Demo 锁定值）
// =============================================================================
using System.Collections;
using UnityEngine;

/// <summary>
/// 牌堆系统：处理抽牌与弃牌动作的执行。
/// 挂载于场景 ActionSystem 物体（OnEnable 注册 / OnDisable 注销）。
/// </summary>
public class CardPileSystem : MonoBehaviour
{
    private void OnEnable()
    {
        ActionSystem.AttachPerformer<DrawCardAction>(PerformDrawCard);
        ActionSystem.AttachPerformer<DiscardCardAction>(PerformDiscardCard);
    }

    private void OnDisable()
    {
        ActionSystem.DetachPerformer<DrawCardAction>();
        ActionSystem.DetachPerformer<DiscardCardAction>();
    }

    /// <summary>
    /// 执行者：抽 Count 张牌到手牌。
    /// CardPileManager.DrawCards 内部自动处理：
    ///   - 手牌满（10）停止抽牌
    ///   - 抽牌堆空 → 弃牌堆洗回抽牌堆
    ///   - 触发 OnCardDrawn 事件（HandUIController 自动实例化 CardView）
    /// </summary>
    private IEnumerator PerformDrawCard(DrawCardAction action)
    {
        if (CardPileManager.Instance == null)
        {
            Debug.LogError("[CardPileSystem] CardPileManager 不存在，无法抽牌");
            yield break;
        }

        var drawn = CardPileManager.Instance.DrawCards(action.Count);
        action.DrawnCards.AddRange(drawn);

        Debug.Log($"[CardPileSystem] 抽牌动作完成：请求 {action.Count} 张，实际 {drawn.Count} 张");

        // TODO M5b-3：抽牌动画（卡牌从抽牌堆飞入手牌）在此处接入
        yield break;
    }

    /// <summary>
    /// 执行者：把指定手牌移入弃牌堆。
    /// CardPileManager.DiscardHandCard 内部触发 OnCardDiscarded 事件（UI 自动移除 CardView）。
    /// </summary>
    private IEnumerator PerformDiscardCard(DiscardCardAction action)
    {
        if (CardPileManager.Instance == null)
        {
            Debug.LogError("[CardPileSystem] CardPileManager 不存在，无法弃牌");
            yield break;
        }

        CardPileManager.Instance.DiscardHandCard(action.Card);
        yield break;
    }
}

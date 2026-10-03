// =============================================================================
// 模块：P4.5 动作系统 - DiscardCardAction 弃牌动作
// 用途：打出的卡牌进入弃牌堆（M5b-3 打牌链路第 8 步）
//       与"回合结束整手弃"（DiscardAllHand）区分：本动作只弃指定一张
// =============================================================================

/// <summary>
/// 把指定手牌移入弃牌堆的游戏动作。
/// </summary>
public class DiscardCardAction : GameAction
{
    /// <summary>要弃的手牌（运行时实例）</summary>
    public Card Card { get; }

    public DiscardCardAction(Card card)
    {
        Card = card;
    }
}

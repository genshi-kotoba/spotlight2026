// =============================================================================
// 模块：P8 动作系统 - PlayCardAction 出牌动作
// 用途：打出一张手牌（M5b-3 打牌链路核心动作）
// 参考教程：NSWells P8 Play Card Action
// 执行链路（PlayCardSystem 注册的 Performer）：
//   Performer：触发卡牌效果（M5b-3 占位）
//   反应链：ConsumeEnergyAction（扣能量）→ DiscardCardAction（进弃牌堆）
// 公式依据：F1.x 能量系统（费用 = Card.CurrentCost，支持动态降费）
// =============================================================================

/// <summary>
/// 打出一张手牌的游戏动作。
/// Pre 阶段订阅者可修改费用（通过修改 Card.CurrentCost）或取消打出。
/// </summary>
public class PlayCardAction : GameAction
{
    /// <summary>要打出的手牌（运行时实例）</summary>
    public Card Card { get; }

    /// <summary>
    /// 指向选定的目标敌人（2026-08-18 出牌交互重构新增）。
    /// null = 无指向卡（自身/全体）；M5b-3 效果结算时按 targetType 分发。
    /// </summary>
    public EnemyController Target { get; }

    public PlayCardAction(Card card) : this(card, null) { }

    public PlayCardAction(Card card, EnemyController target)
    {
        Card = card;
        Target = target;
    }
}
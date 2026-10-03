// =============================================================================
// 模块：P4.5 动作系统 - DrawCardAction 抽牌动作
// 用途：所有抽牌（回合开始抽牌/卡牌效果抽牌/连锁抽牌）统一封装为该动作
// =============================================================================
using System.Collections.Generic;

/// <summary>
/// 抽牌的游戏动作。
/// Pre 阶段订阅者可修改 Count（如"抽牌数 +1"的被动）。
/// Performer 执行后写入 DrawnCards（实际抽到的卡），Post 订阅者可连锁（如"每抽一张牌掉血"的诅咒刀）。
/// </summary>
public class DrawCardAction : GameAction
{
    /// <summary>抽牌数量（Pre 阶段可修改）</summary>
    public int Count { get; set; }

    /// <summary>实际抽到的卡牌列表（Performer 写回，类型为运行时实例 Card）</summary>
    public List<Card> DrawnCards { get; } = new List<Card>();

    public DrawCardAction(int count = 1)
    {
        Count = count;
    }
}

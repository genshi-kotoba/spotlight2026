// =============================================================================
// 模块：探索系统第二步 - 人物属性运行时 CharacterStats
// 用途：汇总玩家「持有集合」的花色点数，得到四维属性（体质/力量/敏捷/智力）。
//       是鉴定第一阶梯（基础分）与探索移动（敏捷加值）的数据源。
// 设计依据：《设计增补_探索系统_v2.md》
//   §5 人物属性 / D9 持有集合实时汇总 / F4.5 敏捷→移动 / F7.1 每 3 点属性降 1 难度
// 挂载方式：纯静态工具类，无需挂载；任意处通过 CharacterStats.力量 等访问。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 人物属性运行时（花色四维，纯静态）。
/// 属性 = 玩家持有卡牌对应花色点数总和（D9）：抽牌堆 + 弃牌堆 + 手牌
///       （+ 战术槽卡；在场能力牌后续系统接入后再计入，见 CountSuit TODO）。
/// 每次访问实时重算（持有集合较小，无缓存必要；卡牌进出集合由各系统直接反映）。
/// </summary>
public static class CharacterStats
{
    /// <summary>F4.5/F7.1 属性→数值转化除数（3:1）：⌊属性 ÷ 3⌋</summary>
    public const int AttributeDivisor = 3;

    /// <summary>F4.5 敏捷→探索移动行动点加值：⌊敏捷 ÷ 3⌋（探索系统 v2 §4.1）</summary>
    public const int AgiMoveDivisor = 3;

    // -------- 四维属性（花色点数总和） --------
    public static int 体质 => CountSuit(SuitOption.黄色);
    public static int 力量 => CountSuit(SuitOption.红色);
    public static int 敏捷 => CountSuit(SuitOption.绿色);
    public static int 智力 => CountSuit(SuitOption.蓝色);

    /// <summary>
    /// ★D19 v2.12：鉴定面板暂存卡（已从手牌摘除、尚未真正弃牌）。
    /// 仍计入持有集合——"准备弃"不算"已弃"，属性不能提前缩水
    ///（修"提交卡牌后属性提供的难度减少消失"bug）。
    /// 生命周期由 EventPopupUI 维护：飞入面板时加入；
    /// 确认鉴定（进弃牌堆）/ 取消退回（回手牌）时移除。
    /// </summary>
    public static readonly List<Card> PendingCards = new List<Card>();

    /// <summary>获取指定花色对应的属性点数（鉴定「对应花色」基础分数据源用）。</summary>
    public static int GetSuitStat(SuitOption suit) => CountSuit(suit);

    /// <summary>
    /// 计算持有集合中某花色的总点数（D9）。
    /// 持有集合 = 抽牌堆 + 弃牌堆 + 手牌；战术槽、在场能力牌后续接入。
    /// </summary>
    private static int CountSuit(SuitOption suit)
    {
        if (suit == SuitOption.无 || CardPileManager.Instance == null) return 0;

        int total = 0;
        total += CountSuitIn(CardPileManager.Instance.DrawPile, suit);
        total += CountSuitIn(CardPileManager.Instance.DiscardPile, suit);
        total += CountSuitIn(CardPileManager.Instance.Hand, suit);
        total += CountSuitIn(PendingCards, suit); // ★v2.12：鉴定面板暂存卡仍算持有
        total += CountSuitIn(TacticSlotRuntime.Cards(), suit); // ★S12：战术槽卡仍算持有（D9 + spec §5）
        // TODO: + 在场能力牌花色（D9，对应系统接入后补）
        return total;
    }

    private static int CountSuitIn(List<Card> pile, SuitOption suit)
    {
        int total = 0;
        if (pile == null) return 0;
        foreach (Card card in pile)
        {
            if (card?.Data != null) total += card.Data.GetSuitCount(suit);
        }
        return total;
    }
}
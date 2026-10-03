// =============================================================================
// 模块：探索系统 - 鉴定四阶梯 CheckSystem
// 用途：鉴定（技能检定）的纯逻辑层：基础分①/战术加成②/动态干预③/投骰判定④。
// 设计依据：《设计增补_探索系统_v2.md》
//   §7.1 四阶梯 / §7.2 公式（基础分=⌊属性÷3⌋、弃牌干预=对应花色点数 1:1）
//   §7.3 成本口径（投骰=1 骰子；弃牌干预=耗该牌 energyCost）
// 职责边界：只算数值，不碰 UI / 不消耗资源（消耗由 EventPopupUI 调用各系统执行）
// =============================================================================
using UnityEngine;

/// <summary>
/// 鉴定四阶梯逻辑（纯静态）。
/// 成功条件（§7.2）：d6 点数 ≥ D − 基础分① − 战术加成② − 动态干预③
/// </summary>
public static class CheckSystem
{
    /// <summary>② 战术加成（Demo 第一版占位 +0，战术槽系统接入后生效）</summary>
    public const int TacticalBonusDefault = 0;

    /// <summary>CheckType → 花色映射（鉴定对应属性 ↔ SuitOption）</summary>
    public static SuitOption GetSuit(CheckType type)
    {
        switch (type)
        {
            case CheckType.力量: return SuitOption.红色;
            case CheckType.敏捷: return SuitOption.绿色;
            case CheckType.智力: return SuitOption.蓝色;
            case CheckType.体质: return SuitOption.黄色;
            default: return SuitOption.无;
        }
    }

    /// <summary>
    /// ① 基础分 = ⌊对应花色属性值 ÷ 3⌋（§7.2 用户定稿 3:1）。
    /// 属性值来自 CharacterStats（持有卡牌花色总和，D9）。
    /// </summary>
    public static int GetBaseScore(CheckType type)
    {
        return CharacterStats.GetSuitStat(GetSuit(type)) / CharacterStats.AttributeDivisor;
    }

    /// <summary>
    /// ② 战术加成（Demo 占位 0；§12.2-5 战术槽接入后改为读槽内卡牌）。
    /// </summary>
    public static int GetTacticalBonus(CheckType type)
    {
        return TacticalBonusDefault;
    }

    /// <summary>
    /// ③ 动态干预的降难度值 = 弃置牌「对应花色」点数（1:1，§7.2 用户定稿）。
    /// 注意：该方法只算数值；能量消耗（该牌 energyCost）与弃牌动作由调用方执行。
    /// </summary>
    public static int GetDiscardBonus(CardData card, CheckType type)
    {
        if (card == null) return 0;
        return card.GetSuitCount(GetSuit(type));
    }

    /// <summary>
    /// 实际需要掷出的目标值（投骰前显示用）：
    /// 目标 Y = D − ① − ② − ③（已含动态干预），最低钳到 1（d6≥1 恒成立=自动成功仍需投骰确认）。
    /// </summary>
    public static int GetTargetNumber(int difficulty, CheckType type, int discardBonus)
    {
        int target = difficulty - GetBaseScore(type) - GetTacticalBonus(type) - discardBonus;
        return Mathf.Max(1, target);
    }

    /// <summary>
    /// ④ 最终判定：掷 d6 与目标值比较。
    /// ★投掷消耗 1 枚探索骰子（§7.3）——由调用方（EventPopupUI）先扣骰子再调用本方法。
    /// </summary>
    /// <returns>true = 鉴定成功</returns>
    public static bool Resolve(int difficulty, CheckType type, int discardBonus, out int rolled, out int target)
    {
        rolled = Random.Range(1, 7); // d6：1-6
        target = GetTargetNumber(difficulty, type, discardBonus);
        return rolled >= target;
    }
}

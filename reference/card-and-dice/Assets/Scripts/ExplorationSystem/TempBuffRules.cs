// =============================================================================
// 模块：探索系统 - 临时强化规则 TempBuffRules
// 用途：增益槽的纯规则（同种不叠加 / 上限 / 三项已接线效果查表）。design §2 / §3.5。
// 纯函数：持有表由调用方传入（L2 可断言）。
// =============================================================================
using System.Collections.Generic;

public static class TempBuffRules
{
    /// <summary>增益槽并存上限（design §8-5 建议 3，待终拍）。满则拒绝获得，不静默丢。</summary>
    public const int MaxSlots = 3;

    /// <summary>是否已持有该种类（design §2：同种不叠加）。</summary>
    public static bool HasKind(IList<TempBuffData> held, TempBuffKind kind)
    {
        return Find(held, kind) != null;
    }

    /// <summary>持有表里该种类的条目（无则 null）。</summary>
    public static TempBuffData Find(IList<TempBuffData> held, TempBuffKind kind)
    {
        if (held == null) return null;
        foreach (TempBuffData b in held)
        {
            if (b != null && b.kind == kind) return b;
        }
        return null;
    }

    /// <summary>能否获得（同种不叠加 + 槽位上限）。不能获得时 out reason 给出原因文案。</summary>
    public static bool CanAcquire(IList<TempBuffData> held, TempBuffData buff, out string reason)
    {
        reason = null;
        if (buff == null) { reason = "强化为空"; return false; }
        if (HasKind(held, buff.kind)) { reason = "已持有同类强化"; return false; }
        if (held != null && held.Count >= MaxSlots) { reason = "增益槽已满"; return false; }
        return true;
    }

    /// <summary>「有数」：下场战斗起始手牌加成张数。</summary>
    public static int HandSizeBonus(IList<TempBuffData> held)
    {
        TempBuffData b = Find(held, TempBuffKind.有数);
        return b != null ? b.value : 0;
    }

    /// <summary>「暖身」：下场战斗第 1 回合能量加成。</summary>
    public static int FirstTurnEnergyBonus(IList<TempBuffData> held)
    {
        TempBuffData b = Find(held, TempBuffKind.暖身);
        return b != null ? b.value : 0;
    }

    /// <summary>「壮胆」：下场战斗第一次攻击的伤害加成。</summary>
    public static int FirstAttackDamageBonus(IList<TempBuffData> held)
    {
        TempBuffData b = Find(held, TempBuffKind.壮胆);
        return b != null ? b.value : 0;
    }
}

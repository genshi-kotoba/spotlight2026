// =============================================================================
// 模块：探索系统 - 事件池抽取 EventPoolDraw
// 用途：荒野图事件格的池选择与去重抽取（design §3.1 / §5）。
// 纯函数 + 显式传入 rng：L2 编辑态断言不需要场景。
// =============================================================================
using System.Collections.Generic;

public static class EventPoolDraw
{
    /// <summary>群系 → 事件池标签（design §5.2：草坡 100% 通用池 = 草坡人味）。</summary>
    public static BiomeTag PoolFor(WastelandGenerator.BiomeId biome)
    {
        if (biome == WastelandGenerator.BiomeId.Grass) return BiomeTag.通用;
        int i = (int)biome;
        if (i < 0 || i > 6) return BiomeTag.通用;
        return (BiomeTag)i;                    // BiomeTag 取值与 BiomeId 数值对齐（Task 1）
    }

    /// <summary>
    /// 该格抽哪个池（design §5.2）：草坡格恒通用池；其余群系 30% 通用 / 70% 本群系池。
    /// </summary>
    /// <param name="roll01">[0,1) 随机数（调用方给 Random.value；L2 断言给定值）</param>
    public static BiomeTag DecidePool(WastelandGenerator.BiomeId biome, float roll01)
    {
        BiomeTag own = PoolFor(biome);
        if (own == BiomeTag.通用) return BiomeTag.通用;
        return roll01 < 0.3f ? BiomeTag.通用 : own;
    }

    /// <summary>某标签池的候选事件（biomeTag 完全相等；null 与空 eventId 跳过）。</summary>
    public static List<EventData> Candidates(IList<EventData> all, BiomeTag tag)
    {
        var list = new List<EventData>();
        if (all == null) return list;
        foreach (EventData e in all)
        {
            if (e == null || string.IsNullOrEmpty(e.eventId)) continue;
            if (e.biomeTag == tag) list.Add(e);
        }
        return list;
    }

    /// <summary>
    /// 抽一个事件（design §5.3 优先级）：
    ///   ① 本图未用过 且 ≠excludeId  → ② 未用过 → ③ ≠excludeId → ④ 任意（池用尽允许重复）
    /// 每层内按 rng 均匀抽。候选为空返回 null。
    /// </summary>
    /// <param name="usedIds">本图已投放的 eventId 集合</param>
    /// <param name="excludeId">相邻格刚抽到的事件 id（相邻不抽同一个）</param>
    public static EventData Pick(List<EventData> pool, ICollection<string> usedIds,
                                 string excludeId, System.Random rng)
    {
        if (pool == null || pool.Count == 0) return null;
        if (rng == null) rng = new System.Random();

        EventData best = PickTier(pool, usedIds, excludeId, rng, true, true);
        if (best != null) return best;
        best = PickTier(pool, usedIds, excludeId, rng, true, false);
        if (best != null) return best;
        best = PickTier(pool, usedIds, excludeId, rng, false, true);
        if (best != null) return best;
        return PickTier(pool, usedIds, excludeId, rng, false, false);
    }

    private static EventData PickTier(List<EventData> pool, ICollection<string> usedIds, string excludeId,
                                      System.Random rng, bool needUnused, bool needNotExclude)
    {
        var tier = new List<EventData>();
        foreach (EventData e in pool)
        {
            if (e == null) continue;
            if (needUnused && usedIds != null && usedIds.Contains(e.eventId)) continue;
            if (needNotExclude && !string.IsNullOrEmpty(excludeId) && e.eventId == excludeId) continue;
            tier.Add(e);
        }
        if (tier.Count == 0) return null;
        return tier[rng.Next(tier.Count)];
    }
}

// =============================================================================
// 模块：Meta - SoulExtraction 灵魂提取装置（一怪一池 · 无放回）
// 用途：藏身处设施③的全部规则，UI 只调这里（面板不自己算池/权重）：
//   · 池 = 该怪产出全集（EnemyData.lootCards ＋ EnemyData.passives）− MetaWallet.unlockedRecipes
//     —— 池状态**派生**、零新增存档字段（design §6-2；成立条件见 §14-7：已解锁 ≡ 已抽出）
//   · 1 灵魂 / 抽（SoulExtractionConfig.soulCostPerDraw）；抽到即从池中移除，机制上不存在重复
//   · 权重按稀有度四档（卡取 CardData.rarity、被动取 PassiveData.rarity）
//   · 抽干后该种灵魂 = 纯资源（兑换口径待定，UI 只显示「已抽干」）
// 设计依据：docs/2026-09-16_藏身处-design.md v2.1 §6
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class SoulExtraction
{
    /// <summary>一次抽取的结果（失败也返回，看 ok / reason）。</summary>
    public class DrawResult
    {
        public bool ok;
        public string reason;          // 失败原因（UI 直显）
        public CardData card;          // 二选一（抽出卡配方）
        public PassiveData passive;    // 二选一（抽出被动配方）
        public CardRarity rarity;      // 抽中项的稀有度
        public int poolRemaining;      // 抽完后的池剩余
    }

    // ------------------------------------------------------------------
    // 池（产出全集 − 已解锁）
    // ------------------------------------------------------------------

    public static List<CardData> RemainingCards(EnemyData e)
    {
        List<CardData> list = new List<CardData>();
        if (e == null || e.lootCards == null) return list;
        foreach (CardData c in e.lootCards)
            if (c != null && !MetaWallet.IsRecipeUnlocked(c.cardID)) list.Add(c);
        return list;
    }

    public static List<PassiveData> RemainingPassives(EnemyData e)
    {
        List<PassiveData> list = new List<PassiveData>();
        if (e == null || e.passives == null) return list;
        foreach (PassiveData p in e.passives)
            if (p != null && !MetaWallet.IsRecipeUnlocked(p.passiveName)) list.Add(p);
        return list;
    }

    /// <summary>池的全集大小（不含已抽出项；面板显示「池 x/y」的 y）。</summary>
    public static int PoolTotal(EnemyData e)
    {
        if (e == null) return 0;
        int n = 0;
        if (e.lootCards != null) foreach (CardData c in e.lootCards) if (c != null) n++;
        if (e.passives != null) foreach (PassiveData p in e.passives) if (p != null) n++;
        return n;
    }

    /// <summary>池的剩余（面板显示「池 x/y」的 x；≤0 = 已抽干）。</summary>
    public static int PoolRemaining(EnemyData e)
    {
        return RemainingCards(e).Count + RemainingPassives(e).Count;
    }

    // ------------------------------------------------------------------
    // 卡池预览（全集 + 状态；纯函数，L2 可断言）
    // ------------------------------------------------------------------

    /// <summary>预览的一行：池内一项 + 是否已抽出。</summary>
    public class PoolEntry
    {
        public string id;         // 卡 = cardID / 被动 = passiveName（与 unlockedRecipes 同键）
        public string name;       // 显示名
        public CardRarity rarity;
        public bool isCard;       // true = 卡牌配方 / false = 被动配方
        public bool drawn;        // 已抽出（= MetaWallet.IsRecipeUnlocked）
    }

    /// <summary>稀有度序号（排序用，不依赖 enum 数值顺序）：传说 3 ← 普通 0。</summary>
    public static int RarityRank(CardRarity r)
    {
        switch (r)
        {
            case CardRarity.传说: return 3;
            case CardRarity.稀有: return 2;
            case CardRarity.优秀: return 1;
            default: return 0;
        }
    }

    /// <summary>
    /// 池的全集预览（排序：未抽出在前 → 稀有度降序 → 卡先被动后；插入排序=稳定，L2 可逐字断言）。
    /// </summary>
    public static List<PoolEntry> PoolPreview(EnemyData e)
    {
        List<PoolEntry> all = new List<PoolEntry>();
        if (e == null) return all;

        if (e.lootCards != null)
        {
            foreach (CardData c in e.lootCards)
            {
                if (c == null) continue;
                PoolEntry pe = new PoolEntry();
                pe.id = c.cardID; pe.name = c.cardName; pe.rarity = c.rarity;
                pe.isCard = true; pe.drawn = MetaWallet.IsRecipeUnlocked(c.cardID);
                all.Add(pe);
            }
        }
        if (e.passives != null)
        {
            foreach (PassiveData p in e.passives)
            {
                if (p == null) continue;
                PoolEntry pe = new PoolEntry();
                pe.id = p.passiveName; pe.name = p.passiveName; pe.rarity = p.rarity;
                pe.isCard = false; pe.drawn = MetaWallet.IsRecipeUnlocked(p.passiveName);
                all.Add(pe);
            }
        }

        for (int i = 1; i < all.Count; i++)          // 稳定插入排序（池 ≤7 项）
        {
            PoolEntry cur = all[i];
            int j = i - 1;
            while (j >= 0 && Before(cur, all[j]))
            {
                all[j + 1] = all[j];
                j--;
            }
            all[j + 1] = cur;
        }
        return all;
    }

    static bool Before(PoolEntry a, PoolEntry b)
    {
        if (a.drawn != b.drawn) return !a.drawn;
        int ra = RarityRank(a.rarity), rb = RarityRank(b.rarity);
        if (ra != rb) return ra > rb;
        return a.isCard && !b.isCard;
    }

    // ------------------------------------------------------------------
    // 权重（纯函数，L2 可确定性断言）
    // ------------------------------------------------------------------

    /// <summary>按候选稀有度生成权重数组（下标与候选对齐）。</summary>
    public static int[] BuildWeights(List<CardRarity> rarities, SoulExtractionConfig cfg)
    {
        if (cfg == null) cfg = SoulExtractionConfig.Load();
        int[] w = new int[rarities.Count];
        for (int i = 0; i < rarities.Count; i++) w[i] = cfg.WeightOf(rarities[i]);
        return w;
    }

    public static int TotalWeight(int[] weights)
    {
        if (weights == null) return 0;
        int t = 0;
        foreach (int w in weights) t += Mathf.Max(1, w);
        return t;
    }

    /// <summary>纯函数：权重前缀和选下标；roll 落在 [0, TotalWeight)。空数组返回 -1，越界钳到最后一档。</summary>
    public static int PickIndex(int[] weights, int roll)
    {
        if (weights == null || weights.Length == 0) return -1;
        int acc = 0;
        for (int i = 0; i < weights.Length; i++)
        {
            acc += Mathf.Max(1, weights[i]);
            if (roll < acc) return i;
        }
        return weights.Length - 1;
    }

    // ------------------------------------------------------------------
    // 抽取编排
    // ------------------------------------------------------------------

    /// <summary>
    /// 抽一次。顺序：查池 → 扣魂 → 抽 → 写配方。任一前置不满足 = 不动任何账。
    /// rng 传 null 用默认随机；传固定种子便于断言。
    /// </summary>
    public static DrawResult Draw(EnemyData enemy, string soulName, System.Random rng, SoulExtractionConfig cfg)
    {
        DrawResult r = new DrawResult();
        if (enemy == null) { r.reason = "该灵魂没有对应的怪"; return r; }

        List<CardData> cards = RemainingCards(enemy);
        List<PassiveData> passives = RemainingPassives(enemy);
        int total = cards.Count + passives.Count;
        r.poolRemaining = total;
        if (total <= 0) { r.reason = "已抽干"; return r; }

        if (cfg == null) cfg = SoulExtractionConfig.Load();
        if (!MetaWallet.TryConsumeSoul(soulName, cfg.soulCostPerDraw)) { r.reason = "灵魂不足"; return r; }
        if (rng == null) rng = new System.Random();

        List<CardRarity> rarities = new List<CardRarity>();
        foreach (CardData c in cards) rarities.Add(c != null ? c.rarity : CardRarity.普通);
        foreach (PassiveData p in passives) rarities.Add(p != null ? p.rarity : CardRarity.普通);

        int[] weights = BuildWeights(rarities, cfg);
        int idx = PickIndex(weights, rng.Next(TotalWeight(weights)));

        if (idx < cards.Count)
        {
            r.card = cards[idx];
            r.rarity = r.card.rarity;
            MetaWallet.AddRecipe(r.card.cardID);
        }
        else
        {
            r.passive = passives[idx - cards.Count];
            r.rarity = r.passive.rarity;
            MetaWallet.AddRecipe(r.passive.passiveName);
        }
        r.ok = true;
        r.poolRemaining = total - 1;
        return r;
    }

    /// <summary>
    /// 批量抽取：每魂 1 抽、逐抽无放回，抽满 count 次或某抽失败即停（同一怪物池内继续扣池）。
    /// 返回全部尝试过的结果（正常 = count 条 ok；中途失败 = 失败那条也含在内）。
    /// </summary>
    public static List<DrawResult> DrawMany(EnemyData enemy, string soulName, int count, System.Random rng, SoulExtractionConfig cfg)
    {
        List<DrawResult> list = new List<DrawResult>();
        for (int i = 0; i < count; i++)
        {
            DrawResult r = Draw(enemy, soulName, rng, cfg);
            list.Add(r);
            if (!r.ok) break;
        }
        return list;
    }
}

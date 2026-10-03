// =============================================================================
// 模块：小队掉落配置（SquadPatrolData 的掉落编辑区数据模型）
// 用途：掉落配置从 EnemyData 迁到巡逻资产后，所有可配数据 + 纯函数（归一化/抽样/退化链/快照）
//       都在这里；Inspector（SquadPatrolDataInspector）与运行时三条通道（遗物袋/灵魂/三选一）共用。
// 设计依据：docs/2026-09-12_小队掉落编辑-design.md §3/§5/§9
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>灵魂三态：沿用预设（读预设的 soulItem）/ 覆盖（用 soulOverride）/ 关闭（不掉）。</summary>
public enum SoulDropMode { 沿用预设, 覆盖, 关闭 }

/// <summary>材料掉落行：材料/骰子 + 数量区间（闭区间，每袋独立滚一次）。</summary>
[Serializable]
public class MaterialDropRange
{
    [Tooltip("掉落物模板（只收 ItemType.材料 / ItemType.骰子）")]
    public ItemData item;

    [Tooltip("数量下限（含）")]
    public int min = 1;

    [Tooltip("数量上限（含）；会与下限自动夹取")]
    public int max = 1;
}

/// <summary>加权卡条目。weight = 池内相对权重（≥0；全 0 或池空 = 空池）。</summary>
[Serializable]
public class WeightedCardEntry
{
    [Tooltip("卡牌模板")]
    public CardData card;

    [Tooltip("池内相对权重")]
    public float weight = 1f;
}

/// <summary>成员掉落配置（与 SquadPatrolData.squad.units 一一对账）。</summary>
[Serializable]
public class MemberDropConfig
{
    [Tooltip("对应哪个成员（下标 + 预设双对齐；模板改动后不一致面板/运行时只警告）")]
    public EnemyData presetRef;

    [Header("灵魂")]
    [Tooltip("沿用预设 = 用 presetRef.soulItem；覆盖 = 用 soulOverride；关闭 = 不掉")]
    public SoulDropMode soulMode = SoulDropMode.沿用预设;

    [Tooltip("覆盖用的灵魂物品（仅 soulMode = 覆盖 时生效）")]
    public ItemData soulOverride;

    [Header("材料（含骰子）")]
    [Tooltip("每行独立滚一次数量；空表 = 该成员不掉材料（掉什么完全看这里，没有兜底）")]
    public List<MaterialDropRange> materials = new List<MaterialDropRange>();

    [Header("三选一卡池")]
    [Tooltip("该成员在三选一敌人侧的候选池（按小队级稀有度表抽；空 = 该成员不供卡）")]
    public List<WeightedCardEntry> rewardCards = new List<WeightedCardEntry>();

    [Header("遗物袋")]
    [Tooltip("遗物袋出卡概率（不走稀有度表）")]
    [Range(0f, 1f)]
    public float bagCardChance = 0.3f;

    [Tooltip("遗物袋卡池（按权重直接抽；空池 = 不掉卡）")]
    public List<WeightedCardEntry> bagCards = new List<WeightedCardEntry>();
}

/// <summary>
/// 一支巡逻小队的掉落配置：小队级（三选一稀有度权重）+ 成员级（灵魂/材料/卡池）。
/// 纯数据 + 静态纯函数，面板与运行时共用，L2 断言可直接调。
/// </summary>
[Serializable]
public class SquadDropConfig
{
    // ------------------------------------------------------------------
    // 小队级：三选一稀有度权重（运行时求和归一化；全 0 → 该小队不出卡牌奖励）
    // ------------------------------------------------------------------
    [Tooltip("三选一候选的稀有度权重（每张候选独立滚一次）：普通/优秀/稀有/传说。全 0 = 不出卡牌奖励")]
    public int commonWeight = 60;
    public int uncommonWeight = 25;
    public int rareWeight = 12;
    public int legendaryWeight = 3;

    [Tooltip("成员配置（自动按 squad.units 对账；多出的条目保留不删）")]
    public List<MemberDropConfig> members = new List<MemberDropConfig>();

    // preset 不一致只警告一次（每次击杀都会调 FindMember，避免刷屏）
    static readonly HashSet<string> _warnedPresetMismatch = new HashSet<string>();

    // ------------------------------------------------------------------
    // 纯函数（面板显示 + 运行时抽样 + 迁移/对账；L2 断言直接调）
    // ------------------------------------------------------------------

    /// <summary>
    /// 四档稀有度归一化概率（长度 4 = 普通/优秀/稀有/传说）。
    /// ★2026-09-12 用户定稿：全 0 → 返回全 0（面板显示 0%）＝ 该小队不出卡牌奖励
    /// —— 旧口径「全 0 按四档均匀 25%」会让玩家以为关掉了、实际照样出卡。
    /// </summary>
    public static float[] RarityPercents(int common, int uncommon, int rare, int legendary)
    {
        int c = Mathf.Max(0, common);
        int u = Mathf.Max(0, uncommon);
        int r = Mathf.Max(0, rare);
        int l = Mathf.Max(0, legendary);
        int sum = c + u + r + l;
        if (sum <= 0) return new[] { 0f, 0f, 0f, 0f };
        return new[] { (float)c / sum, (float)u / sum, (float)r / sum, (float)l / sum };
    }

    /// <summary>四档稀有度权重是否至少一个 &gt; 0（全 0 = 该小队不出卡牌奖励，用户 2026-09-12 定稿）。</summary>
    public static bool HasRarityWeight(SquadDropConfig cfg)
    {
        return cfg != null
            && (cfg.commonWeight > 0 || cfg.uncommonWeight > 0 || cfg.rareWeight > 0 || cfg.legendaryWeight > 0);
    }

    /// <summary>按权重滚一档稀有度（roll01 ∈ [0,1)）；返回 0-3，对应 CardRarity 下标；权重全 0 → -1（不出卡）。</summary>
    public static int RollRarityIndex(int common, int uncommon, int rare, int legendary, float roll01)
    {
        float[] p = RarityPercents(common, uncommon, rare, legendary);
        float acc = 0f;
        for (int i = 0; i < 4; i++)
        {
            acc += p[i];
            if (roll01 < acc) return i;
        }
        return -1;      // 全 0：acc 恒 0，任何 roll01 都落不进四档
    }

    /// <summary>池内加权抽，返回下标；池空/权重全 0/卡为空 返回 -1（roll01 ∈ [0,1)）。</summary>
    public static int PickWeightedIndex(List<WeightedCardEntry> pool, float roll01)
    {
        if (pool == null) return -1;

        float sum = 0f;
        for (int i = 0; i < pool.Count; i++)
        {
            WeightedCardEntry e = pool[i];
            if (e == null || e.card == null || e.weight <= 0f) continue;
            sum += e.weight;
        }
        if (sum <= 0f) return -1;

        float target = roll01 * sum;
        float acc = 0f;
        int lastIndex = -1;
        for (int i = 0; i < pool.Count; i++)
        {
            WeightedCardEntry e = pool[i];
            if (e == null || e.card == null || e.weight <= 0f) continue;
            acc += e.weight;
            lastIndex = i;
            if (target < acc) return i;
        }
        return lastIndex;
    }

    /// <summary>材料数量：闭区间 [min,max] 内滚（min&gt;max 自动夹取；roll01 ∈ [0,1)）。</summary>
    public static int RollAmount(MaterialDropRange row, float roll01)
    {
        if (row == null) return 0;
        int lo = Mathf.Max(0, Mathf.Min(row.min, row.max));
        int hi = Mathf.Max(0, Mathf.Max(row.min, row.max));
        int span = hi - lo + 1;
        if (span <= 0) return 0;
        int v = lo + (int)(roll01 * span);
        return Mathf.Clamp(v, lo, hi);
    }

    /// <summary>单个成员被抽中的概率（编制成员等权 → 1/N）。面板显示用。</summary>
    public static float MemberPercent(SquadDropConfig cfg)
    {
        int n = cfg != null && cfg.members != null ? cfg.members.Count : 0;
        return n > 0 ? 1f / n : 0f;
    }

    /// <summary>
    /// 三选一敌人侧抽一张卡（每个候选槽独立跑一次）。
    /// 退化链：该成员该稀有度 → 全小队该稀有度（成员等权合并） → 该成员任意稀有度 → null（让给玩家牌库）。
    /// ★稀有度权重全 0 → 直接 null：该小队不出卡牌奖励（用户 2026-09-12 定稿，不走「任意稀有度」兜底）。
    /// <paramref name="exclude"/> = 本组已出现的卡（避免重复行）。
    /// </summary>
    public static CardData DrawEnemyCard(SquadDropConfig cfg, ICollection<CardData> exclude,
        float rollRarity, float rollMember, float rollCard)
    {
        if (cfg == null || cfg.members == null || cfg.members.Count == 0) return null;

        int rarity = RollRarityIndex(cfg.commonWeight, cfg.uncommonWeight, cfg.rareWeight, cfg.legendaryWeight, rollRarity);
        if (rarity < 0) return null;

        // 成员等权：3 哥布林 + 2 史莱姆 → 每成员 20%，聚合 60% / 40%
        int mi = Mathf.Clamp((int)(rollMember * cfg.members.Count), 0, cfg.members.Count - 1);
        MemberDropConfig member = cfg.members[mi];

        CardData hit = DrawFromPool(member != null ? member.rewardCards : null, rarity, exclude, rollCard, true);
        if (hit != null) return hit;

        hit = DrawFromAllMembers(cfg.members, rarity, exclude, rollCard);
        if (hit != null) return hit;

        return DrawFromPool(member != null ? member.rewardCards : null, -1, exclude, rollCard, false);
    }

    /// <summary>运行时封装：三滚都取 Random.value。</summary>
    public static CardData DrawEnemyCard(SquadDropConfig cfg, ICollection<CardData> exclude)
    {
        return DrawEnemyCard(cfg, exclude, UnityEngine.Random.value, UnityEngine.Random.value, UnityEngine.Random.value);
    }

    /// <summary>单池抽样：可选按稀有度过滤 + 排除已出现；权重无效的条目跳过。</summary>
    static CardData DrawFromPool(List<WeightedCardEntry> pool, int rarity, ICollection<CardData> exclude,
        float roll01, bool filterRarity)
    {
        if (pool == null) return null;

        var filtered = new List<WeightedCardEntry>();
        foreach (WeightedCardEntry e in pool)
        {
            if (e == null || e.card == null || e.weight <= 0f) continue;
            if (filterRarity && rarity >= 0 && (int)e.card.rarity != rarity) continue;
            if (exclude != null && exclude.Contains(e.card)) continue;
            filtered.Add(e);
        }
        int idx = PickWeightedIndex(filtered, roll01);
        return idx >= 0 ? filtered[idx].card : null;
    }

    /// <summary>全小队合并池（成员等权：每个成员的池先归一化到权重和 1，避免卡多的成员被动放大）。</summary>
    static CardData DrawFromAllMembers(List<MemberDropConfig> members, int rarity, ICollection<CardData> exclude, float roll01)
    {
        var merged = new List<WeightedCardEntry>();

        foreach (MemberDropConfig m in members)
        {
            if (m == null || m.rewardCards == null) continue;

            float sum = 0f;
            foreach (WeightedCardEntry e in m.rewardCards)
            {
                if (e == null || e.card == null || e.weight <= 0f) continue;
                if (rarity >= 0 && (int)e.card.rarity != rarity) continue;
                if (exclude != null && exclude.Contains(e.card)) continue;
                sum += e.weight;
            }
            if (sum <= 0f) continue;

            foreach (WeightedCardEntry e in m.rewardCards)
            {
                if (e == null || e.card == null || e.weight <= 0f) continue;
                if (rarity >= 0 && (int)e.card.rarity != rarity) continue;
                if (exclude != null && exclude.Contains(e.card)) continue;
                merged.Add(new WeightedCardEntry { card = e.card, weight = e.weight / sum });
            }
        }

        int idx = PickWeightedIndex(merged, roll01);
        return idx >= 0 ? merged[idx].card : null;
    }

    /// <summary>该巡逻实际生效的掉落配置：本巡逻成员表非空 → 用自己的（覆盖）；否则继承小队模板的。</summary>
    public static SquadDropConfig EffectiveConfig(SquadPatrolData patrol)
    {
        if (patrol == null) return null;
        SquadDropConfig own = patrol.dropConfig;
        if (own != null && own.members != null && own.members.Count > 0) return own;
        return patrol.squad != null && patrol.squad.dropConfig != null ? patrol.squad.dropConfig : own;
    }

    /// <summary>
    /// 查该敌人所属成员配置：先解析生效配置（巡逻覆盖 → 模板继承），再按 UnitIndex 取成员。
    /// 无巡逻 / 无配置 / 下标越界 → null（设计 §3：场景手摆敌人无魂/卡/材料，只有遗物袋兜底）。
    /// </summary>
    public static MemberDropConfig FindMember(EnemyController enemy)
    {
        if (enemy == null) return null;
        SquadPatrolGroup group = enemy.PatrolGroup;
        SquadPatrolData patrol = group != null ? group.SourcePatrol : null;
        SquadDropConfig cfg = EffectiveConfig(patrol);
        if (cfg == null || cfg.members == null) return null;

        int i = enemy.UnitIndex;
        if (i < 0 || i >= cfg.members.Count) return null;

        MemberDropConfig member = cfg.members[i];
        if (member == null) return null;

        // preset 双对齐校验：模板改过成员顺序 → 只警告一次，仍按下标取（面板同一处也有警告）
        EnemySquadData squad = patrol.squad;
        if (squad != null && squad.units != null && i < squad.units.Count && squad.units[i] != null && member.presetRef != null)
        {
            EnemyData expect = squad.units[i].preset;
            if (expect != null && member.presetRef != expect)
            {
                string key = patrol.name + "#" + i;
                if (_warnedPresetMismatch.Add(key))
                {
                    Debug.LogWarning($"[小队掉落] 巡逻「{patrol.patrolName}」成员 #{i} 配置的预设（{member.presetRef.enemyName}）" +
                                     $"与模板（{expect.enemyName}）不一致，按下标沿用配置");
                }
            }
        }
        return member;
    }

    /// <summary>解灵魂三态：沿用预设（presetSoul，null = 不掉）/ 覆盖 / 关闭；无配置 → null。</summary>
    public static ItemData ResolveSoul(MemberDropConfig cfg, ItemData presetSoul)
    {
        if (cfg == null) return null;
        switch (cfg.soulMode)
        {
            case SoulDropMode.关闭: return null;
            case SoulDropMode.覆盖: return cfg.soulOverride;
            default: return presetSoul;
        }
    }

    /// <summary>
    /// 按 squad.units 对账成员列表：不足补默认（presetRef = units[i].preset）、补 null 条目与空缺 presetRef；
    /// 多出的条目**保留不删**（可能对应刚被移除的成员，面板会标注）。有改动返回 true。
    /// </summary>
    public static bool SyncMembers(SquadDropConfig cfg, EnemySquadData squad)
    {
        if (cfg == null) return false;
        if (cfg.members == null) { cfg.members = new List<MemberDropConfig>(); }

        bool changed = false;
        if (squad != null && squad.units != null)
        {
            for (int i = 0; i < squad.units.Count; i++)
            {
                EnemyData preset = squad.units[i] != null ? squad.units[i].preset : null;

                if (i >= cfg.members.Count)
                {
                    cfg.members.Add(new MemberDropConfig { presetRef = preset });
                    changed = true;
                    continue;
                }
                if (cfg.members[i] == null)
                {
                    cfg.members[i] = new MemberDropConfig { presetRef = preset };
                    changed = true;
                    continue;
                }
                if (cfg.members[i].presetRef == null && preset != null)
                {
                    cfg.members[i].presetRef = preset;
                    changed = true;
                }
            }
        }
        return changed;
    }

    /// <summary>
    /// 深拷贝快照（「战利品卡牌」物品用）：用物品时早已离开那场战斗，不能引用会被改动的巡逻资产内容。
    /// memberLimit &gt; 0 时只取前 N 名（= 编制人数，裁掉面板上保留的多余条目）。
    /// </summary>
    public static SquadDropConfig CloneForSnapshot(SquadDropConfig src, int memberLimit)
    {
        if (src == null) return null;

        var copy = new SquadDropConfig
        {
            commonWeight = src.commonWeight,
            uncommonWeight = src.uncommonWeight,
            rareWeight = src.rareWeight,
            legendaryWeight = src.legendaryWeight
        };

        if (src.members == null) return copy;
        int count = memberLimit > 0 && memberLimit < src.members.Count ? memberLimit : src.members.Count;
        for (int i = 0; i < count; i++)
        {
            copy.members.Add(CloneMember(src.members[i]));
        }
        return copy;
    }

    static MemberDropConfig CloneMember(MemberDropConfig m)
    {
        if (m == null) return null;

        var copy = new MemberDropConfig
        {
            presetRef = m.presetRef,
            soulMode = m.soulMode,
            soulOverride = m.soulOverride,
            bagCardChance = m.bagCardChance
        };
        if (m.materials != null)
            foreach (MaterialDropRange r in m.materials)
                if (r != null) copy.materials.Add(new MaterialDropRange { item = r.item, min = r.min, max = r.max });
        if (m.rewardCards != null)
            foreach (WeightedCardEntry e in m.rewardCards)
                if (e != null) copy.rewardCards.Add(new WeightedCardEntry { card = e.card, weight = e.weight });
        if (m.bagCards != null)
            foreach (WeightedCardEntry e in m.bagCards)
                if (e != null) copy.bagCards.Add(new WeightedCardEntry { card = e.card, weight = e.weight });
        return copy;
    }
}

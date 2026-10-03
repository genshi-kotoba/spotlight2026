// =============================================================================
// 掉落配置共享绘制器（design 2026-09-12 §4；两个面板复用）
//   · 小队模板面板（EnemySquadDataInspector）：编辑模板默认配置 → 正式图随机遭遇用它
//   · 巡逻面板（SquadPatrolDataInspector）：成员表非空时编辑（覆盖模板）
// owner = Undo/SetDirty 目标（SquadPatrolData 或 EnemySquadData 资产）
// =============================================================================
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;

public static class SquadDropConfigDrawer
{
    /// <summary>完整掉落区：小队级稀有度 + 成员块（自动按 squad.units 对账补齐）。</summary>
    public static void Draw(Object owner, SquadDropConfig drop, EnemySquadData squad, string title)
    {
        EditorGUILayout.Space(10);
        EditorGUILayout.LabelField(title, EditorStyles.boldLabel);

        if (drop == null) return;
        if (drop.members == null) drop.members = new List<MemberDropConfig>();

        // 对账：成员块数量不足时补默认（多出的条目保留不删，下面会标注）
        int want = squad != null && squad.units != null ? squad.units.Count : 0;
        if (drop.members.Count < want)
        {
            Undo.RecordObject(owner, "补齐掉落成员配置");
            SquadDropConfig.SyncMembers(drop, squad);
            EditorUtility.SetDirty(owner);
        }

        DrawRarityWeights(owner, drop);

        if (squad == null || squad.units == null || squad.units.Count == 0)
        {
            EditorGUILayout.HelpBox("小队模板还没有成员（units 为空）→ 在小队模板里加成员后，成员掉落块会自动出现。", MessageType.Warning);
            return;
        }

        EditorGUILayout.Space(6);
        EditorGUILayout.LabelField($"成员掉落（模板 {squad.units.Count} 名）", EditorStyles.boldLabel);
        for (int i = 0; i < drop.members.Count; i++)
        {
            DrawMemberBlock(owner, drop, squad, i);
        }
    }

    /// <summary>只读摘要（巡逻继承态显示模板配置用）。</summary>
    public static void DrawReadOnlySummary(SquadDropConfig drop, EnemySquadData squad)
    {
        if (drop == null || drop.members == null || drop.members.Count == 0)
        {
            EditorGUILayout.HelpBox("小队模板的掉落配置还是空的 —— 选中模板资产（Assets/Data/Squads）在「掉落配置」区编辑。",
                                    MessageType.Warning);
            return;
        }
        float[] rp = SquadDropConfig.RarityPercents(drop.commonWeight, drop.uncommonWeight, drop.rareWeight, drop.legendaryWeight);
        EditorGUILayout.LabelField(SquadDropConfig.HasRarityWeight(drop)
            ? $"稀有度：普通 {rp[0] * 100f:0.#}% · 优秀 {rp[1] * 100f:0.#}% · 稀有 {rp[2] * 100f:0.#}% · 传说 {rp[3] * 100f:0.#}%"
            : "稀有度：权重全 0 → 该小队不出卡牌奖励");
        for (int i = 0; i < drop.members.Count; i++)
        {
            EditorGUILayout.LabelField(SummaryOf(drop.members[i], UnitAt(squad, i)));
        }
    }

    static string SummaryOf(MemberDropConfig m, EnemyUnitConfig unit)
    {
        if (m == null) return "（空块）";

        string who = unit != null && unit.preset != null ? unit.preset.enemyName : "预设缺失";
        // 「沿用预设」运行期读的是敌人当前预设（EnemyData.soulItem），摘要就取模板成员当前预设，避免换预设后显示陈旧值
        EnemyData livePreset = unit != null && unit.preset != null ? unit.preset : m.presetRef;
        string soul = m.soulMode == SoulDropMode.沿用预设
            ? (livePreset != null && livePreset.soulItem != null ? livePreset.soulItem.itemName : "无")
            : m.soulMode.ToString();

        string mats = "";
        if (m.materials != null)
        {
            foreach (MaterialDropRange r in m.materials)
            {
                if (r != null && r.item != null) mats += r.item.itemName + "×" + r.min + "~" + r.max + " ";
            }
        }
        if (mats == "") mats = "无";

        int reward = m.rewardCards != null ? m.rewardCards.Count : 0;
        int bag = m.bagCards != null ? m.bagCards.Count : 0;
        return $"#  {who}｜魂={soul}｜材料={mats}｜三选一={reward}张｜袋={m.bagCardChance:0.##}×{bag}张";
    }

    static void DrawRarityWeights(Object owner, SquadDropConfig drop)
    {
        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField("三选一稀有度（每张候选独立滚一次）", EditorStyles.boldLabel);

        int c = EditorGUILayout.IntField("普通 权重", drop.commonWeight);
        int u = EditorGUILayout.IntField("优秀 权重", drop.uncommonWeight);
        int r = EditorGUILayout.IntField("稀有 权重", drop.rareWeight);
        int l = EditorGUILayout.IntField("传说 权重", drop.legendaryWeight);
        if (c != drop.commonWeight || u != drop.uncommonWeight || r != drop.rareWeight || l != drop.legendaryWeight)
        {
            Undo.RecordObject(owner, "改稀有度权重");
            drop.commonWeight = Mathf.Max(0, c);
            drop.uncommonWeight = Mathf.Max(0, u);
            drop.rareWeight = Mathf.Max(0, r);
            drop.legendaryWeight = Mathf.Max(0, l);
            EditorUtility.SetDirty(owner);
        }

        float[] p = SquadDropConfig.RarityPercents(drop.commonWeight, drop.uncommonWeight, drop.rareWeight, drop.legendaryWeight);
        EditorGUILayout.LabelField(SquadDropConfig.HasRarityWeight(drop)
            ? "实际概率"
            : "实际概率（全 0 = 不出卡牌奖励）",
            $"普通 {p[0] * 100f:0.#}% · 优秀 {p[1] * 100f:0.#}% · 稀有 {p[2] * 100f:0.#}% · 传说 {p[3] * 100f:0.#}%");
        if (!SquadDropConfig.HasRarityWeight(drop))
        {
            EditorGUILayout.HelpBox("四档权重全为 0 → 该小队**不出卡牌奖励**（战后不再掉「战利品卡牌」）。", MessageType.Info);
        }
    }

    static void DrawMemberBlock(Object owner, SquadDropConfig drop, EnemySquadData squad, int i)
    {
        MemberDropConfig cfg = drop.members[i];
        if (cfg == null)
        {
            Undo.RecordObject(owner, "新建成员掉落配置");
            cfg = new MemberDropConfig { presetRef = PresetAt(squad, i) };
            drop.members[i] = cfg;
            EditorUtility.SetDirty(owner);
        }

        // 新增字段兜底（老资产反序列化后可能是 null）
        if (cfg.materials == null) cfg.materials = new List<MaterialDropRange>();
        if (cfg.rewardCards == null) cfg.rewardCards = new List<WeightedCardEntry>();
        if (cfg.bagCards == null) cfg.bagCards = new List<WeightedCardEntry>();

        EditorGUILayout.BeginVertical(EditorStyles.helpBox);

        EditorGUILayout.BeginHorizontal();
        EditorGUILayout.LabelField(HeaderOf(squad, i), EditorStyles.boldLabel);
        GUILayout.FlexibleSpace();
        EditorGUILayout.LabelField($"抽中占比 {SquadDropConfig.MemberPercent(drop) * 100f:0.#}%", GUILayout.Width(120));
        EditorGUILayout.EndHorizontal();

        DrawUnitWarning(squad, cfg, i);
        DrawSoulSection(owner, cfg);
        DrawMaterialSection(owner, cfg);
        DrawCardPoolSection(owner, "三选一卡池 · 敌人侧走小队级稀有度表", cfg.rewardCards, "三选一卡");
        DrawBagSection(owner, cfg);

        EditorGUILayout.EndVertical();
        EditorGUILayout.Space(4);
    }

    static void DrawUnitWarning(EnemySquadData squad, MemberDropConfig cfg, int i)
    {
        EnemyUnitConfig unit = UnitAt(squad, i);
        if (unit == null)
        {
            EditorGUILayout.HelpBox($"模板里没有第 {i + 1} 名成员 —— 本块是历史残留配置（保留不删）。", MessageType.Warning);
            return;
        }
        if (cfg.presetRef != null && unit.preset != null && cfg.presetRef != unit.preset)
        {
            EditorGUILayout.HelpBox($"配置的预设（{cfg.presetRef.enemyName}）与模板成员（{unit.preset.enemyName}）不一致 —— " +
                                    "模板成员顺序改过？请核对本块内容。", MessageType.Warning);
        }
    }

    static void DrawSoulSection(Object owner, MemberDropConfig cfg)
    {
        EditorGUILayout.Space(2);
        EditorGUILayout.LabelField("灵魂", EditorStyles.miniBoldLabel);

        EditorGUILayout.BeginHorizontal();
        SoulDropMode mode = (SoulDropMode)EditorGUILayout.EnumPopup("模式", cfg.soulMode);
        if (mode != cfg.soulMode)
        {
            Undo.RecordObject(owner, "改灵魂模式");
            cfg.soulMode = mode;
            EditorUtility.SetDirty(owner);
        }
        if (cfg.soulMode == SoulDropMode.沿用预设)
        {
            ItemData presetSoul = cfg.presetRef != null ? cfg.presetRef.soulItem : null;
            EditorGUILayout.LabelField(presetSoul != null ? $"预设：{presetSoul.itemName}" : "预设未配（不掉）",
                                       GUILayout.Width(200));
        }
        EditorGUILayout.EndHorizontal();

        if (cfg.soulMode == SoulDropMode.覆盖)
        {
            ItemData soul = (ItemData)EditorGUILayout.ObjectField("灵魂物品", cfg.soulOverride, typeof(ItemData), false);
            if (soul != cfg.soulOverride)
            {
                Undo.RecordObject(owner, "改灵魂覆盖");
                cfg.soulOverride = soul;
                EditorUtility.SetDirty(owner);
            }
            if (cfg.soulOverride != null && cfg.soulOverride.type != ItemType.灵魂)
            {
                EditorGUILayout.HelpBox("覆盖物品的类型不是「灵魂」—— SoulIntake 会按类型拒绝入灯。", MessageType.Warning);
            }
        }
    }

    static void DrawMaterialSection(Object owner, MemberDropConfig cfg)
    {
        EditorGUILayout.Space(2);
        EditorGUILayout.LabelField("材料（含骰子；数量为闭区间，每袋独立滚）", EditorStyles.miniBoldLabel);

        for (int r = 0; r < cfg.materials.Count; r++)
        {
            MaterialDropRange row = cfg.materials[r];
            if (row == null) { row = new MaterialDropRange(); cfg.materials[r] = row; }

            EditorGUILayout.BeginHorizontal();
            ItemData item = (ItemData)EditorGUILayout.ObjectField(row.item, typeof(ItemData), false);
            int min = EditorGUILayout.IntField(row.min, GUILayout.Width(50));
            EditorGUILayout.LabelField("~", GUILayout.Width(12));
            int max = EditorGUILayout.IntField(row.max, GUILayout.Width(50));
            bool changed = item != row.item || min != row.min || max != row.max;
            bool remove = GUILayout.Button("删", GUILayout.Width(28));
            EditorGUILayout.EndHorizontal();

            if (changed)
            {
                Undo.RecordObject(owner, "改材料掉落");
                row.item = item;
                row.min = Mathf.Max(0, min);
                row.max = Mathf.Max(0, max);
                if (row.max < row.min) row.max = row.min;
                EditorUtility.SetDirty(owner);
            }
            if (row.item != null && row.item.type != ItemType.材料 && row.item.type != ItemType.骰子)
            {
                EditorGUILayout.HelpBox($"「{row.item.itemName}」类型是 {row.item.type} —— 只支持 材料 / 骰子，运行时会跳过。",
                                        MessageType.Warning);
            }
            if (remove)
            {
                Undo.RecordObject(owner, "删除材料掉落");
                cfg.materials.RemoveAt(r);
                EditorUtility.SetDirty(owner);
                break;
            }
        }

        if (GUILayout.Button("+ 材料行"))
        {
            Undo.RecordObject(owner, "新增材料掉落");
            cfg.materials.Add(new MaterialDropRange());
            EditorUtility.SetDirty(owner);
        }
    }

    static void DrawCardPoolSection(Object owner, string title,
        List<WeightedCardEntry> pool, string addLabel)
    {
        EditorGUILayout.Space(2);
        EditorGUILayout.LabelField($"{title}（权重为池内相对值；空池 = 不掉）", EditorStyles.miniBoldLabel);

        for (int r = 0; r < pool.Count; r++)
        {
            WeightedCardEntry row = pool[r];
            if (row == null) { row = new WeightedCardEntry(); pool[r] = row; }

            EditorGUILayout.BeginHorizontal();
            CardData card = (CardData)EditorGUILayout.ObjectField(row.card, typeof(CardData), false);
            float weight = EditorGUILayout.FloatField(row.weight, GUILayout.Width(50));
            EditorGUILayout.LabelField(card != null ? card.rarity.ToString() : "—", GUILayout.Width(40));
            bool changed = card != row.card || !Mathf.Approximately(weight, row.weight);
            bool remove = GUILayout.Button("删", GUILayout.Width(28));
            EditorGUILayout.EndHorizontal();

            if (changed)
            {
                Undo.RecordObject(owner, "改卡池");
                row.card = card;
                row.weight = Mathf.Max(0f, weight);
                EditorUtility.SetDirty(owner);
            }
            if (remove)
            {
                Undo.RecordObject(owner, "删除卡池条目");
                pool.RemoveAt(r);
                EditorUtility.SetDirty(owner);
                break;
            }
        }

        if (GUILayout.Button($"+ {addLabel}"))
        {
            Undo.RecordObject(owner, "新增卡池条目");
            pool.Add(new WeightedCardEntry());
            EditorUtility.SetDirty(owner);
        }
    }

    static void DrawBagSection(Object owner, MemberDropConfig cfg)
    {
        EditorGUILayout.Space(2);
        EditorGUILayout.LabelField("遗物袋", EditorStyles.miniBoldLabel);

        float chance = EditorGUILayout.Slider("出卡概率", cfg.bagCardChance, 0f, 1f);
        if (!Mathf.Approximately(chance, cfg.bagCardChance))
        {
            Undo.RecordObject(owner, "改遗物袋出卡概率");
            cfg.bagCardChance = chance;
            EditorUtility.SetDirty(owner);
        }
        DrawCardPoolSection(owner, "遗物袋卡池（不走稀有度表）", cfg.bagCards, "遗物袋卡");
    }

    // ------------------------------------------------------------------
    // 成员信息小工具
    // ------------------------------------------------------------------
    static EnemyUnitConfig UnitAt(EnemySquadData squad, int i)
    {
        if (squad == null || squad.units == null) return null;
        if (i < 0 || i >= squad.units.Count) return null;
        return squad.units[i];
    }

    static EnemyData PresetAt(EnemySquadData squad, int i)
    {
        EnemyUnitConfig unit = UnitAt(squad, i);
        return unit != null ? unit.preset : null;
    }

    static string HeaderOf(EnemySquadData squad, int i)
    {
        EnemyUnitConfig unit = UnitAt(squad, i);
        if (unit == null || unit.preset == null) return $"#{i + 1}（预设缺失）";
        return $"#{i + 1} {unit.preset.enemyName}（{unit.EffectiveRole}）";
    }
}

// =============================================================================
// 模块：Meta - WorkshopConfig 工坊配置
// 用途：工坊三件套的全部数值旋钮（制卡成本 / 拆解返还 / 被动激活系数 / 制骰成本 / 怪材兑物资比价）。
//       谁读它：Workshop（编排）、HideoutController 面板（显示成本与余额）。
// 设计依据：docs/2026-09-16_藏身处-design.md v2.1 §7、§11（旋钮表）
// 资产位置：Assets/Resources/WorkshopConfig.asset（缺资产走内存默认，游戏照常跑）
// 生成/补齐：菜单 Tools/藏身处/2. 工坊配置表
// ★ 数值全 [PLACEHOLDER]，等 Playtest 校准；设计 §12：三旋钮交叉（掉落+ / 返还+ / 成本-）
//   必须共用同一张标定表，禁止各自拍数 —— 全部旋钮集中在本资产，不要散落硬编码。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "工坊配置", menuName = "CardDice/工坊配置")]
public class WorkshopConfig : ScriptableObject
{
    public const string ResourcePath = "WorkshopConfig";

    [Tooltip("制卡碎片成本（下标 = CardRarity 0–3：普通/优秀/稀有/传说）[PLACEHOLDER]")]
    public int[] shardCostByRarity = { 2, 4, 8, 12 };

    [Tooltip("制卡对应家族怪材成本（下标同上；该族三件套任一）[PLACEHOLDER]")]
    public int[] familyMaterialCostByRarity = { 1, 2, 4, 6 };

    [Tooltip("被动激活：怪材消耗 = 价值(value) × 本系数 [PLACEHOLDER]")]
    public int passiveCostPerValue = 2;

    [Tooltip("拆解返还率（碎片成本的 %；手动回收与结算拆解同率，恒 < 100）")]
    public int scrapReturnPercent = 75;

    [Tooltip("族材 → 物资：1 件族材兑入的物资数 [PLACEHOLDER]")]
    public int familyMaterialToSalvage = 1;

    [Tooltip("独特素材 → 物资：1 件独特兑入的物资数 [PLACEHOLDER]")]
    public int uniqueMaterialToSalvage = 3;

    /// <summary>制骰配方（B3 取「初始全列」：菜单预填全部骰子物品）[PLACEHOLDER·将来改抽取/掉落]。</summary>
    [Serializable]
    public class DiceRecipe
    {
        public ItemData dice;
        public int salvageCost = 3;
    }
    public List<DiceRecipe> diceRecipes = new List<DiceRecipe>();

    /// <summary>该稀有度的制卡碎片成本（越界钳到端点）。</summary>
    public int ShardCostOf(CardRarity r)
    {
        return Pick(shardCostByRarity, (int)r, 2);
    }

    /// <summary>该稀有度的制卡怪材成本。</summary>
    public int MaterialCostOf(CardRarity r)
    {
        return Pick(familyMaterialCostByRarity, (int)r, 1);
    }

    /// <summary>拆解返还碎片数（纯函数：floor(碎片成本 × 返还率)）。</summary>
    public int ScrapShardsOf(int shardCost)
    {
        if (shardCost <= 0) return 0;
        return Mathf.FloorToInt(shardCost * Mathf.Clamp(scrapReturnPercent, 0, 99) / 100f);
    }

    static int Pick(int[] table, int index, int fallback)
    {
        if (table == null || table.Length == 0) return fallback;
        if (index < 0) index = 0;
        if (index >= table.Length) index = table.Length - 1;
        return Mathf.Max(0, table[index]);
    }

    static WorkshopConfig _fallback;

    /// <summary>取 Resources 资产；没有资产则返回内存默认值（不落盘、不报错）。</summary>
    public static WorkshopConfig Load()
    {
        WorkshopConfig cfg = Resources.Load<WorkshopConfig>(ResourcePath);
        if (cfg != null) return cfg;
        if (_fallback == null)
        {
            _fallback = CreateInstance<WorkshopConfig>();
            _fallback.name = ResourcePath + "（内存默认）";
        }
        return _fallback;
    }
}

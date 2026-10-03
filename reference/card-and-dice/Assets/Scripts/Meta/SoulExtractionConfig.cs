// =============================================================================
// 模块：Meta - SoulExtractionConfig 装置抽取配置
// 用途：灵魂提取装置的抽取权重表（按四档稀有度分档）与单抽魂耗。
//       谁读它：SoulExtraction（权重/魂耗）、HideoutController 面板（显示魂耗）。
// 设计依据：docs/2026-09-16_藏身处-design.md v2.1 §6-5、§11「稀有度权重」
// 资产位置：Assets/Resources/SoulExtractionConfig.asset
// 生成/补齐：菜单 Tools/藏身处/1. 装置配置表
// ★ 数值全 [PLACEHOLDER]，等 Playtest 校准；命途「机缘Ⅱ 掉落稀有度权重↑」（B6）将来改这里。
// =============================================================================
using UnityEngine;

[CreateAssetMenu(fileName = "装置抽取配置", menuName = "CardDice/装置抽取配置")]
public class SoulExtractionConfig : ScriptableObject
{
    public const string ResourcePath = "SoulExtractionConfig";

    [Tooltip("四档权重：普通 / 优秀 / 稀有 / 传说（下标 = CardRarity 的 0–3）")]
    public int[] rarityWeights = { 50, 30, 15, 5 };

    [Tooltip("单抽消耗的灵魂数（v1 沿用 1 魂 1 抽）")]
    public int soulCostPerDraw = 1;

    static SoulExtractionConfig _fallback;

    /// <summary>取该稀有度的权重（下限 1，保证任何档都抽得到）。</summary>
    public int WeightOf(CardRarity rarity)
    {
        int i = (int)rarity;
        if (rarityWeights == null || i < 0 || i >= rarityWeights.Length) return 1;
        return Mathf.Max(1, rarityWeights[i]);
    }

    /// <summary>取 Resources 资产；没有资产则返回内存默认值（不落盘、不报错，游戏照常跑）。</summary>
    public static SoulExtractionConfig Load()
    {
        SoulExtractionConfig cfg = Resources.Load<SoulExtractionConfig>(ResourcePath);
        if (cfg != null) return cfg;
        if (_fallback == null)
        {
            _fallback = CreateInstance<SoulExtractionConfig>();
            _fallback.name = ResourcePath + "（内存默认）";
        }
        return _fallback;
    }
}

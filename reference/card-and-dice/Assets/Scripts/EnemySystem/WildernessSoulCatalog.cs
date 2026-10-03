// =============================================================================
// 模块：敌人系统 - 荒野灵魂目录 WildernessSoulCatalog
// 用途：把「灵魂物品 → 该怪的 EnemyData」这条**反向索引**落成 Resources 资产 ——
//       藏身处「灵魂提取装置」按玩家魂灯里的灵魂反查产出池：
//         池 = EnemyData.lootCards ＋ EnemyData.passives − MetaWallet.unlockedRecipes
//       为什么必须落表：EnemyData 资产在 Assets/Data/Enemies/ 下（不在 Resources），
//       运行期 Resources.LoadAll 扫不到；且灵魂物品对怪是单向引用，反查只能查表。
// 生成：菜单 Tools/荒野/8. 灵魂池目录（WildernessContentBuilder）
// 资产位置：Assets/Resources/WildernessSoulCatalog.asset
// 设计依据：docs/2026-09-16_藏身处-design.md v2.1 §6（灵魂提取装置）
// 说明：比 WildernessChestCatalog 多一个 Load() 静态助手 —— 本表有两个消费点
//       （SoulExtraction 逻辑层与藏身处 UI），不想两处各写一遍 Resources.Load。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "荒野灵魂目录", menuName = "CardDice/荒野灵魂目录")]
public class WildernessSoulCatalog : ScriptableObject
{
    public const string ResourcePath = "WildernessSoulCatalog";

    /// <summary>一行 = 一种灵魂 → 产它的怪。</summary>
    [Serializable]
    public class SoulRow
    {
        [Tooltip("灵魂物品（ItemData.itemName 即面板与钱包里的名字）")]
        public ItemData soul;

        [Tooltip("产出这个灵魂的怪（它的 lootCards ＋ passives 就是装置抽取池的全集）")]
        public EnemyData enemy;
    }

    [Tooltip("43 只荒野怪各一行（构建器生成）")]
    public List<SoulRow> rows = new List<SoulRow>();

    private Dictionary<string, EnemyData> _index;

    /// <summary>灵魂名 → 怪。查不到返回 null（UI 直接跳过该条灵魂）。</summary>
    public EnemyData EnemyFor(string soulName)
    {
        if (string.IsNullOrEmpty(soulName)) return null;
        if (_index == null)
        {
            _index = new Dictionary<string, EnemyData>();
            foreach (SoulRow r in rows)
            {
                if (r == null || r.soul == null || r.enemy == null) continue;
                if (!_index.ContainsKey(r.soul.itemName)) _index.Add(r.soul.itemName, r.enemy);
            }
        }
        EnemyData e;
        return _index.TryGetValue(soulName, out e) ? e : null;
    }

    /// <summary>取 Resources 资产；没有资产返回 null（调用方自己决定降级文案）。</summary>
    public static WildernessSoulCatalog Load()
    {
        return Resources.Load<WildernessSoulCatalog>(ResourcePath);
    }
}

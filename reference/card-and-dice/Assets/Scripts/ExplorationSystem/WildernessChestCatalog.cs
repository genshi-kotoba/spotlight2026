// =============================================================================
// 模块：探索系统 - 荒野宝箱目录 WildernessChestCatalog
// 用途：荒野图「箱子」格的内容来源——按格所在群系查一行，掷数量后填装。
//       箱子本体复用遗物袋管线（CorpseRegistry.Spawn + CorpseSpawner 标记），
//       所以踩上去开的就是玩家已经熟悉的搜刮弹窗。
//       资产位置：Assets/Resources/WildernessChestCatalog.asset
// 口径依据（2026-09-16 用户）：「一个家族最好三种普通材料，怪物分别掉一种，
//       另一个在对应地图的箱子里」——本表存的就是那第三件。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "荒野宝箱目录", menuName = "CardDice/荒野宝箱目录")]
public class WildernessChestCatalog : ScriptableObject
{
    public const string ResourcePath = "WildernessChestCatalog";

    /// <summary>一行 = 一个群系的开箱内容。</summary>
    [Serializable]
    public class ChestLootRow
    {
        [Tooltip("群系数值（对齐 WastelandGenerator.BiomeId：草坡0 密林1 洞穴2 废墟3 古林4 沼泽5 荒村6）")]
        public int biome;

        [Tooltip("族名（只作 Inspector 可读性，投放逻辑不读）")]
        public string family;

        [Tooltip("开箱得到的材料 = 该族三件套里的「箱材」")]
        public ItemData item;

        public int min = 2;
        public int max = 4;
    }

    [Tooltip("七个群系各一行")]
    public List<ChestLootRow> rows = new List<ChestLootRow>();

    /// <summary>按群系数值取行；没有匹配返回 null。</summary>
    public ChestLootRow RowFor(int biome)
    {
        foreach (ChestLootRow r in rows)
        {
            if (r != null && r.biome == biome) return r;
        }
        return null;
    }
}

// =============================================================================
// 模块：探索系统 - 荒野宝箱投放 WildernessChestPlacer
// 用途：把地图上所有 'C'/'c' 格（MapLayoutBuilder.AllChestCoords）填上内容。
//       ★此前这些坐标只是烘出来摆着看——没有任何运行期消费方，箱子全是空的。
// 时机：ExpeditionMapRouter 荒野分支，WildernessEventPlacer.PlaceAll 之后、放玩家之前。
// 口径：内容按格所在群系取「箱材」（族材三件套里的第三件，怪不掉），
//       箱子本体复用遗物袋管线 → 踩上去开的是同一种搜刮弹窗。
// =============================================================================
using UnityEngine;

public static class WildernessChestPlacer
{
    /// <summary>
    /// 给 layout 里每个宝箱格生成一个装了族材的箱子。
    /// 群系读不到（手写图 / 越界）时兜底主群系——本方法只在随机荒野分支被调用。
    /// </summary>
    public static int PlaceAll(MapLayoutBuilder layout, WastelandGenerator.WastelandLayout gen, int seed)
    {
        if (layout == null) return 0;

        WildernessChestCatalog catalog = Resources.Load<WildernessChestCatalog>(
            WildernessChestCatalog.ResourcePath);
        if (catalog == null || catalog.rows.Count == 0)
        {
            Debug.LogWarning("[宝箱投放] Resources 里没有 WildernessChestCatalog（或 rows 为空），本图箱子全是空的");
            return 0;
        }

        System.Random rng = new System.Random(seed);
        int placed = 0, skipped = 0, cells = 0;

        foreach (Vector2Int cell in layout.AllChestCoords)
        {
            cells++;

            WastelandGenerator.BiomeId biome;
            if (!WastelandRunContext.TryGetBiome(cell, out biome) && gen != null)
                biome = gen.mainBiome;

            WildernessChestCatalog.ChestLootRow row = catalog.RowFor((int)biome);
            if (row == null || row.item == null)
            {
                Debug.LogWarning($"[宝箱投放] 群系 {biome}({(int)biome}) 在目录里没有可用行，跳过 Hex_{cell.x}_{cell.y}");
                skipped++;
                continue;
            }

            // 箱子走遗物袋管线：名字叫「箱子」→ 弹窗标题与尸体区分开
            CorpseContainer chest = CorpseRegistry.Spawn(cell, "箱子");
            if (chest == null) { skipped++; continue; }

            int amount = rng.Next(row.min, row.max + 1);   // 上限含（Random.Next 上界不含）
            chest.AddItem(row.item, amount);
            placed++;
        }

        Debug.Log($"[宝箱投放] 本图宝箱格 {cells} 个 → 实际装填 {placed} 个" +
                  (skipped > 0 ? $"（跳过 {skipped}）" : ""));
        return placed;
    }
}

// =============================================================================
// 模块：探索系统 - 荒野事件投放 WildernessEventPlacer
// 用途：把 22 个事件格（MapLayoutBuilder 收集的 E 格）铺上事件（design §3.1 / §5）。
// 时机：ExpeditionMapRouter 荒野分支，WastelandRunContext.Set(gen) 之后、放玩家之前。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class WildernessEventPlacer
{
    /// <summary>
    /// 给 layout 里的事件候选格逐个挂 EventTile。
    /// 规则（design §5.2/§5.3）：按格群系 30% 通用 / 70% 本群系；同图不重复优先；
    /// 相邻格不抽同一事件；池用尽允许重复。
    /// </summary>
    public static int PlaceAll(MapLayoutBuilder layout, WastelandGenerator.WastelandLayout gen, int seed)
    {
        if (layout == null) return 0;

        WildernessEventCatalog catalog = Resources.Load<WildernessEventCatalog>(
            WildernessEventCatalog.ResourcePath);
        if (catalog == null || catalog.events.Count == 0)
        {
            Debug.LogWarning("[事件投放] Resources 里没有 WildernessEventCatalog（或 events 为空），本图无事件");
            return 0;
        }

        List<Vector2Int> cells = layout.eventCandidateCoords;      // 已是 public 字段（MapLayoutBuilder :91）
        if (cells == null || cells.Count == 0)
        {
            Debug.Log("[事件投放] 本图没有事件候选格");
            return 0;
        }

        System.Random rng = new System.Random(seed);
        var used = new HashSet<string>();
        var lastByCoord = new Dictionary<Vector2Int, string>();
        int placed = 0;

        foreach (Vector2Int cell in cells)
        {
            WastelandGenerator.BiomeId biome;
            if (!WastelandRunContext.TryGetBiome(cell, out biome)) biome = WastelandGenerator.BiomeId.Grass;

            BiomeTag tag = EventPoolDraw.DecidePool(biome, (float)rng.NextDouble());
            List<EventData> pool = EventPoolDraw.Candidates(catalog.events, tag);
            if (pool.Count == 0) pool = EventPoolDraw.Candidates(catalog.events, BiomeTag.通用);

            string excludeId = NeighborEventId(cell, lastByCoord);
            EventData picked = EventPoolDraw.Pick(pool, used, excludeId, rng);
            if (picked == null) continue;

            EventTile tile = PlaceTile(cell, picked);
            if (tile == null) continue;

            used.Add(picked.eventId);
            lastByCoord[cell] = picked.eventId;
            placed++;
        }

        Debug.Log($"[事件投放] 本图事件格 {cells.Count} 个 → 实际铺上 {placed} 个（去重池 {used.Count} 种）");
        return placed;
    }

    /// <summary>相邻（六向）已铺格的事件 id（相邻不抽同一个；没有则 null）。</summary>
    static string NeighborEventId(Vector2Int cell, Dictionary<Vector2Int, string> placed)
    {
        HexCoord.Cube c = HexCoord.ToCube(cell);
        for (int dir = 0; dir < HexCoord.Directions.Length; dir++)
        {
            Vector2Int n = HexCoord.FromCube(c + HexCoord.Directions[dir]);
            string id;
            if (placed.TryGetValue(n, out id)) return id;
        }
        return null;
    }

    /// <summary>在格上补一个 EventTile（HexGridLayout 建格时没挂；coord 必须显式写，
    /// 因为此刻 HexTile.coordinates 还没解析出来）。</summary>
    static EventTile PlaceTile(Vector2Int cell, EventData data)
    {
        GameObject go = GameObject.Find($"Hex_{cell.x}_{cell.y}");
        if (go == null)
        {
            Debug.LogWarning($"[事件投放] 找不到格节点 Hex_{cell.x}_{cell.y}");
            return null;
        }

        EventTile tile = go.GetComponent<EventTile>();
        if (tile == null) tile = go.AddComponent<EventTile>();
        tile.eventData = data;
        tile.coord = cell;                 // ★显式写：Awake 阶段 HexTile.coordinates 还是 (0,0)
        tile.dimAfterConsumed = true;
        return tile;
    }
}

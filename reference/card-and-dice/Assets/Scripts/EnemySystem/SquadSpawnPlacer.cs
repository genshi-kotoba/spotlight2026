// =============================================================================
// 模块：敌人系统 - SquadSpawnPlacer 每局随机落位解算
// 用途：把巡逻资产的「基准路线」按 <see cref="SquadPatrolData.spawnJitterRadius"/> 每局平移一次，
//       使同一个地方每局刷怪的位置不同，而路线形状不变。
//
// 为什么在 cube 空间平移（关键）：
//   odd-q 偏移坐标直接相加**不是**刚体平移——奇偶列错位时 (dx,0) 会斜跳。
//   所以这里统一走 HexCoord.FormationSlot(cell, delta, 0)：
//     FromCube(ToCube(cell) + ToCube(delta))
//   faceSteps=0 时 RotateSteps 原样返回，于是等价于「立方体加法」= 严格平移。
//
// 为什么需要「同组共用偏移」：
//   教程图要演示【跨小队意图传导】：怪2 / 怪3 必须恒定相距 3 格（≤ 视野 3）。
//   若两只各自随机，间距会漂到 6~7，传导就断了。
//   把两条巡逻填同一个 jitterGroupId → 整组刚性平移 → 组内相对站位**严格不变**，
//   随机性与教学几何同时成立。
//
// 合法性：候选偏移必须让【该组全部成员的全部路径点】都落在界内 + 可通行格上；
//         一个都不合法时退化为偏移 0（宁可不随机，也不要把怪丢进墙里）。
// 会话缓存：每局开图前 ResetSession()，同组的偏移在整局内只解算一次。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class SquadSpawnPlacer
{
    /// <summary>随机组 key → 本局使用的偏移（会话缓存）</summary>
    private static readonly Dictionary<string, Vector2Int> GroupDelta = new Dictionary<string, Vector2Int>();

    private static bool _hasGrid;
    private static HexGridLayout _grid;
    private static TerrainManager _terrain;

    /// <summary>每局开图前调用：清空缓存，让下一次解算重新掷点。</summary>
    public static void ResetSession()
    {
        GroupDelta.Clear();
        _hasGrid = false;
        _grid = null;
        _terrain = null;
    }

    /// <summary>把一条基准路线整体平移 delta（cube 空间严格平移）。</summary>
    public static List<Vector2Int> Shift(IList<Vector2Int> waypoints, Vector2Int delta)
    {
        var list = new List<Vector2Int>();
        if (waypoints == null) return list;
        if (delta == Vector2Int.zero)
        {
            for (int i = 0; i < waypoints.Count; i++) list.Add(waypoints[i]);
            return list;
        }
        for (int i = 0; i < waypoints.Count; i++)
        {
            list.Add(HexCoord.FormationSlot(waypoints[i], delta, 0));
        }
        return list;
    }

    /// <summary>
    /// 一次把整批巡逻的「本局实际路线」算出来。
    /// 返回：巡逻 → 平移后的路径点。半径 0 / 无路径的巡逻不出现在表里（调用方用原值即可）。
    /// </summary>
    public static Dictionary<SquadPatrolData, List<Vector2Int>> ResolveAll(IList<SquadPatrolData> patrols)
    {
        var result = new Dictionary<SquadPatrolData, List<Vector2Int>>();
        if (patrols == null || patrols.Count == 0) return result;

        // ---- ① 按「随机组」归堆：填了 jitterGroupId 的共用一个偏移，没填的各算各的 ----
        var groups = new Dictionary<string, List<SquadPatrolData>>();
        foreach (SquadPatrolData p in patrols)
        {
            if (p == null || p.spawnJitterRadius <= 0 || !p.HasPatrolPath) continue;
            string key = !string.IsNullOrEmpty(p.jitterGroupId)
                ? "G:" + p.jitterGroupId
                : "I:" + p.GetInstanceID();

            if (!groups.TryGetValue(key, out List<SquadPatrolData> list))
            {
                list = new List<SquadPatrolData>();
                groups[key] = list;
            }
            list.Add(p);
        }
        if (groups.Count == 0) return result;

        EnsureWorld();

        // ---- ② 每组掷一次偏移（同一 key 复用缓存 → 整局稳定）----
        foreach (KeyValuePair<string, List<SquadPatrolData>> kv in groups)
        {
            if (!GroupDelta.TryGetValue(kv.Key, out Vector2Int delta))
            {
                delta = PickDelta(kv.Value);
                GroupDelta[kv.Key] = delta;
                Debug.Log($"[随机落位] 组「{kv.Key}」偏移 {delta}" +
                          $"（成员 {kv.Value.Count} 条巡逻）" +
                          (delta == Vector2Int.zero ? " ← 半径内没有全合法偏移，退化为不随机" : ""));
            }

            foreach (SquadPatrolData p in kv.Value)
            {
                result[p] = Shift(p.patrolWaypoints, delta);
            }
        }
        return result;
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    /// <summary>在「该组最大半径」内挑一个让全组路线都合法的偏移；一个都没有返回 zero。</summary>
    private static Vector2Int PickDelta(List<SquadPatrolData> members)
    {
        int radius = 0;
        foreach (SquadPatrolData m in members)
        {
            if (m.spawnJitterRadius > radius) radius = m.spawnJitterRadius;
        }

        List<Vector2Int> candidates = EnumerateDeltas(radius);
        var valid = new List<Vector2Int>();
        foreach (Vector2Int d in candidates)
        {
            if (AllValid(members, d)) valid.Add(d);
        }

        if (valid.Count == 0) return Vector2Int.zero;
        return valid[Random.Range(0, valid.Count)];
    }

    /// <summary>偏移 d 是否让该组【全部成员的全部路径点】都落在界内且可通行。</summary>
    private static bool AllValid(List<SquadPatrolData> members, Vector2Int d)
    {
        foreach (SquadPatrolData m in members)
        {
            if (m.patrolWaypoints == null) continue;
            foreach (Vector2Int w in m.patrolWaypoints)
            {
                Vector2Int c = HexCoord.FormationSlot(w, d, 0);
                if (_grid != null &&
                    (c.x < 0 || c.y < 0 || c.x >= _grid.gridSize.x || c.y >= _grid.gridSize.y))
                {
                    return false;
                }
                if (_terrain != null && !_terrain.IsPassable(c)) return false;
            }
        }
        return true;
    }

    /// <summary>六边半径 radius 内的全部偏移（含 0）。行范围留 ±1 余量，覆盖 odd-q 剪切带来的行漂移。</summary>
    private static List<Vector2Int> EnumerateDeltas(int radius)
    {
        var list = new List<Vector2Int>();
        for (int x = -radius; x <= radius; x++)
        {
            for (int y = -radius - 1; y <= radius + 1; y++)
            {
                var d = new Vector2Int(x, y);
                if (CardExecutor.HexDistance(Vector2Int.zero, d) <= radius) list.Add(d);
            }
        }
        return list;
    }

    private static void EnsureWorld()
    {
        if (_hasGrid) return;
        _grid = Object.FindObjectOfType<HexGridLayout>();
        _terrain = Object.FindObjectOfType<TerrainManager>();
        _hasGrid = true;
    }
}

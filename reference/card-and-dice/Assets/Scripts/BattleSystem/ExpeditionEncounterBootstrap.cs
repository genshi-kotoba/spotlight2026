// =============================================================================
// 模块：战斗系统 - ExpeditionEncounterBootstrap 开局敌人布点
// 职责：一局探索开始时，决定这张图上出现哪些敌人、各在哪、怎么巡逻。
//
// ★2026-09-12 重构（用户定调：地图上不要直接放怪，怪物生成应该是随机的）
//   旧版的「地图文本 g / m / G 字符 → MapEnemySpawner 按点位生成」已删除。
//   现在只有两个来源，都不允许「某个格子上钉着一只怪」：
//
//   ① 固定巡逻（SquadPatrols/*.asset，按 mapId 过滤）
//      —— 教程 / 剧情 / 手工精摆的正式图内容。
//         可带 spawnJitterRadius（±N 小随机）与 jitterGroupId（同组刚性平移）。
//         spawnOnStart=false 的只登记不生成，等剧情脚本触发（教程逃跑篇的大巡逻队）。
//
//   ② 随机遭遇（地图 x 遭遇区 + EncounterTable）
//      —— 正式图主力。每个遭遇区每局掷点决定：
//         刷几支小队（数量）/ 抽哪个小队模板（类型）/ 区内随机路线（路径）。
//         ★2026-09-16 起取表按「区所在群系」分池（(图,群系) → (图,通用) → (通用,通用)）。
//
//   ③ 野外巡逻（★2026-09-16 新增，随机荒野专有）
//      —— 生成器撒在骨架通路上的巡逻锚点 → 按锚点所在群系查表抽小队 → 锚点周边连随机路线。
//         无荒野上下文（雾镇/教程）时整条路不跑。
//
//   三者最终都走 SpawnResolver + SquadPatrolGroup，行为完全一致。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public class ExpeditionEncounterBootstrap : MonoBehaviour
{
    [Tooltip("关掉原点残留敌人，避免挡住清场")]
    [SerializeField] private bool deactivateUnboundSceneEnemies = true;

    [Tooltip("生成出来的敌人挂到哪个父物体下（留空 = 场景根）")]
    [SerializeField] private Transform spawnParent;

    [Tooltip("是否执行遭遇区随机刷怪（临时关掉可只看固定巡逻，方便调试）")]
    [SerializeField] private bool enableRandomEncounters = true;

    /// <summary>「没有参照点」的哨兵值（用于「离出生点至少 N 格」的约束）。</summary>
    private static readonly Vector2Int NoPoint = new Vector2Int(-9999, -9999);

    /// <summary>野外巡逻路线候选半径：锚点周围几格内取路径点（§3.5.7 · D2 默认 6，可后调）。</summary>
    private const int WildernessRouteRadius = 6;

    private void Start()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring)
        {
            return;
        }

        if (deactivateUnboundSceneEnemies)
        {
            DeactivateUnboundEnemies();
        }

        // 每局重置随机落位缓存 → 本次出击重新掷点
        SquadSpawnPlacer.ResetSession();

        MapLayoutBuilder layout = FindObjectOfType<MapLayoutBuilder>();
        string mapId = layout != null && layout.layoutFile != null ? layout.layoutFile.name : "";

        // ★2026-09-16 本局荒野上下文（群系图 / 巡逻锚点）：随机荒野图由 ExpeditionMapRouter 交接，
        //   手写图（雾镇）为 null → 下游按旧行为走（不查群系、不撒野外巡逻）。
        if (WastelandRunContext.HasContext)
        {
            WastelandGenerator.WastelandLayout gen = WastelandRunContext.Layout;
            int cols = gen.biomeRows != null && gen.biomeRows.Count > 0 ? gen.biomeRows[0].Length : 0;
            Debug.Log($"[遭遇床] 荒野上下文就绪：种子 {gen.seed}，群系图 {gen.biomeRows.Count} 行×{cols} 列，" +
                      $"巡逻锚点 {gen.patrolAnchors.Count} 个，出生点 Hex_{gen.spawnPos.x}_{gen.spawnPos.y}");
        }

        int fixedSquads = SpawnFixedPatrols(mapId);
        int zoneSquads = enableRandomEncounters ? SpawnEncounterZones(layout, mapId) : 0;
        int wildSquads = enableRandomEncounters ? SpawnWildernessPatrols(layout, mapId) : 0;

        Debug.Log($"[遭遇床] 地图「{mapId}」开局布点完成：固定巡逻 {fixedSquads} 支｜遭遇区随机 {zoneSquads} 支｜野外巡逻 {wildSquads} 支");
    }

    // ==================================================================
    // ① 固定巡逻（SquadPatrols 资产）
    // ==================================================================

    private int SpawnFixedPatrols(string mapId)
    {
        List<SquadPatrolData> all = SquadPatrolLoader.LoadFor(mapId);

        var pending = new List<SquadPatrolData>();
        int deferred = 0;
        foreach (SquadPatrolData p in all)
        {
            if (p == null) continue;
            if (p.squad == null)
            {
                Debug.LogWarning($"[遭遇床] 跳过「{p.name}」：未拖入小队模板");
                continue;
            }
            if (!p.HasPatrolPath)
            {
                Debug.LogWarning($"[遭遇床] 跳过「{p.patrolName}」：没有路径点（至少填一个出生格）");
                continue;
            }
            if (!p.spawnOnStart)
            {
                deferred++;
                continue;
            }
            pending.Add(p);
        }

        // ★每局随机落位：同 jitterGroupId 的巡逻共用同一个刚性偏移（组内相对站位不变）
        Dictionary<SquadPatrolData, List<Vector2Int>> placed = SquadSpawnPlacer.ResolveAll(pending);

        int spawned = 0;
        foreach (SquadPatrolData p in pending)
        {
            placed.TryGetValue(p, out List<Vector2Int> route);
            List<EnemyController> units = SpawnResolver.Spawn(p, spawnParent, route);
            if (units != null && units.Count > 0)
            {
                spawned++;
                Vector2Int at = route != null && route.Count > 0 ? route[0] : p.patrolWaypoints[0];
                Debug.Log($"[遭遇床] 固定巡逻「{p.patrolName}」落点 Hex_{at.x}_{at.y}" +
                          $"（小队「{p.squad.squadName}」，{units.Count} 只，" +
                          (route != null ? $"本局随机偏移后路线 {route.Count} 点" : $"基准路线 {p.patrolWaypoints.Count} 点") + "）");
            }
        }

        if (deferred > 0)
        {
            Debug.Log($"[遭遇床] 另有 {deferred} 支巡逻 spawnOnStart=false（留给剧情触发），本局不生成");
        }
        return spawned;
    }

    // ==================================================================
    // ② 随机遭遇（地图 x 遭遇区）
    // ==================================================================

    private int SpawnEncounterZones(MapLayoutBuilder layout, string mapId)
    {
        if (layout == null || layout.encounterZones == null || layout.encounterZones.Count == 0)
        {
            return 0;
        }

        HexGridLayout grid = FindObjectOfType<HexGridLayout>();
        TerrainManager terrain = FindObjectOfType<TerrainManager>();
        HexMover player = FindObjectOfType<HexMover>();
        Vector2Int start = ResolveStartCoord(layout);

        int total = 0;
        int noTable = 0;
        int emptyPool = 0;
        foreach (EncounterZone zone in layout.encounterZones)
        {
            string biomeLetter, biomeName;
            ResolveZoneBiome(zone, out biomeLetter, out biomeName);

            // ★2026-09-16 按区所在群系取表（荒野）：(图,群系) → (图,通用) → (通用,通用)。
            //   无荒野上下文（雾镇/教程）时 biomeLetter 为空 → 与旧行为完全一致（查同图通用）。
            EncounterTable table = EncounterTableLoader.LoadFor(mapId, biomeLetter);
            if (table == null) { noTable++; continue; }
            if (table.ValidEntryCount == 0) { emptyPool++; continue; }

            total += RollZone(zone, table, grid, terrain, player, start, biomeName);
        }

        if (noTable > 0)
        {
            Debug.Log($"[遭遇床] 地图「{mapId}」有 {noTable} 个遭遇区没有匹配的遭遇表 → 这些区不刷");
        }
        if (emptyPool > 0)
        {
            Debug.LogWarning($"[遭遇床] 有 {emptyPool} 个遭遇区的表概率池为空（没配小队模板或权重都是 0）→ 这些区不刷");
        }
        return total;
    }

    /// <summary>区中心格所在群系（查群系图；无荒野上下文 / 查不到 → 两个输出都为空串）。</summary>
    private static void ResolveZoneBiome(EncounterZone zone, out string letter, out string name)
    {
        letter = "";
        name = "";
        WastelandGenerator.BiomeId biome;
        if (!WastelandRunContext.TryGetBiome(zone.center, out biome)) return;
        WastelandGenerator.BiomeDef def = WastelandGenerator.Def(biome);
        letter = def.mapLetter.ToString();
        name = def.displayName;
    }

    /// <summary>掷一个区：抽数量 / 抽类型 / 生成随机路径。</summary>
    private int RollZone(EncounterZone zone, EncounterTable table,
        HexGridLayout grid, TerrainManager terrain, HexMover player, Vector2Int start, string biomeName)
    {
        List<Vector2Int> candidates = BuildCandidates(zone, terrain, grid, player, start, table.minDistanceFromStart);
        if (candidates.Count == 0)
        {
            Debug.LogWarning($"[遭遇床] 遭遇区 #{zone.index}（中心 {zone.center}）没有可用格" +
                             $"（可通行 + 离出生点 ≥ {table.minDistanceFromStart}）→ 跳过");
            return 0;
        }

        int want = Random.Range(table.minSquadsPerZone, table.maxSquadsPerZone + 1);
        if (want <= 0) return 0;

        var anchors = new List<Vector2Int>();
        int spawned = 0;

        for (int i = 0; i < want; i++)
        {
            EnemySquadData squad = table.RollSquad();
            if (squad == null) break;

            if (!PickAnchor(candidates, anchors, table.minSquadSeparation, out Vector2Int anchor))
            {
                Debug.Log($"[遭遇床] 遭遇区 #{zone.index} 放不下第 {i + 1} 支小队（间距/边距不够）→ 提前收手");
                break;
            }
            anchors.Add(anchor);

            List<Vector2Int> route = BuildRoute(anchor, candidates, table, grid);
            SquadPatrolData patrol = MakeRuntimePatrol(squad, route, table,
                $"随机遭遇_区{zone.index}_{i + 1}", $"区{zone.index}·{squad.squadName}·{i + 1}");
            List<EnemyController> units = SpawnResolver.Spawn(patrol, spawnParent);
            if (units != null && units.Count > 0)
            {
                spawned++;
                Debug.Log($"[遭遇床] 遭遇区 #{zone.index} 第 {i + 1} 支：小队「{squad.squadName}」" +
                          $"锚点 Hex_{anchors[anchors.Count - 1].x}_{anchors[anchors.Count - 1].y}，" +
                          $"随机路线 {route.Count} 点 [{string.Join(" → ", route.ConvertAll(c => HexCoord.FormatCell(c)))}]，" +
                          $"巡逻步幅 {patrol.squadPatrolAP}");
            }
        }

        Debug.Log($"[遭遇床] 遭遇区 #{zone.index}（中心 {zone.center}{BiomeSuffix(biomeName)}，{zone.CellCount} 格）：" +
                  $"候选 {candidates.Count} 格 → 掷出 {want} 支 → 落地 {spawned} 支");
        return spawned;
    }

    /// <summary>日志用群系后缀（无群系 → 空串）。</summary>
    private static string BiomeSuffix(string biomeName)
    {
        return string.IsNullOrEmpty(biomeName) ? "" : $"，群系 {biomeName}";
    }

    /// <summary>区内可用格：可通行 + 界内 + 离出生点够远 + 不在玩家脚下。</summary>
    private List<Vector2Int> BuildCandidates(EncounterZone zone, TerrainManager terrain,
        HexGridLayout grid, HexMover player, Vector2Int start, int minFromStart)
    {
        var list = new List<Vector2Int>();
        foreach (Vector2Int c in zone.cells)
        {
            if (IsUsableCell(c, terrain, grid, player, start, minFromStart)) list.Add(c);
        }
        return list;
    }

    /// <summary>候选格判定：界内 + 可通行 + 不在玩家脚下 + 离出生点够远（遭遇区与野外巡逻共用）。</summary>
    private static bool IsUsableCell(Vector2Int c, TerrainManager terrain, HexGridLayout grid,
        HexMover player, Vector2Int start, int minFromStart)
    {
        if (grid != null &&
            (c.x < 0 || c.y < 0 || c.x >= grid.gridSize.x || c.y >= grid.gridSize.y))
        {
            return false;
        }
        if (terrain != null && !terrain.IsPassable(c)) return false;
        if (player != null && player.CurrentCoord == c) return false;
        if (start != NoPoint && minFromStart > 0 &&
            CardExecutor.HexDistance(c, start) < minFromStart)
        {
            return false;
        }
        return true;
    }

    /// <summary>以 center 为心、radius 内的可用格（野外巡逻路线候选；含 center 自身）。</summary>
    private static List<Vector2Int> BuildAreaCandidates(Vector2Int center, int radius,
        TerrainManager terrain, HexGridLayout grid, HexMover player, Vector2Int start, int minFromStart)
    {
        var list = new List<Vector2Int>();
        for (int dx = -radius; dx <= radius; dx++)
        {
            for (int dy = -radius; dy <= radius; dy++)
            {
                var c = new Vector2Int(center.x + dx, center.y + dy);
                if (CardExecutor.HexDistance(c, center) > radius) continue;
                if (IsUsableCell(c, terrain, grid, player, start, minFromStart)) list.Add(c);
            }
        }
        return list;
    }

    /// <summary>区内随机挑一个锚点，且与已有锚点保持 minSeparation。</summary>
    private static bool PickAnchor(List<Vector2Int> candidates, List<Vector2Int> taken,
        int minSeparation, out Vector2Int anchor)
    {
        anchor = Vector2Int.zero;
        var ok = new List<Vector2Int>();
        foreach (Vector2Int c in candidates)
        {
            bool clash = false;
            foreach (Vector2Int t in taken)
            {
                if (CardExecutor.HexDistance(c, t) < minSeparation) { clash = true; break; }
            }
            if (!clash) ok.Add(c);
        }
        if (ok.Count == 0) return false;
        anchor = ok[Random.Range(0, ok.Count)];
        return true;
    }

    /// <summary>
    /// 在区内随机连出一条巡逻路线：路径点个数 randomWaypoints，
    /// 逐段做 A* 连通校验（连不通就换一个候选点重试），保证巡逻真的走得通。
    /// </summary>
    private static List<Vector2Int> BuildRoute(Vector2Int anchor, List<Vector2Int> candidates,
        EncounterTable table, HexGridLayout grid)
    {
        int want = Random.Range(table.minWaypoints, table.maxWaypoints + 1);
        var route = new List<Vector2Int> { anchor };
        if (want <= 1 || grid == null) return route;

        var pool = new List<Vector2Int>(candidates);
        pool.Remove(anchor);
        var astar = new AStarPathfinding(grid);

        for (int i = 1; i < want && pool.Count > 0; i++)
        {
            bool linked = false;
            for (int attempt = 0; attempt < 12 && pool.Count > 0; attempt++)
            {
                int idx = Random.Range(0, pool.Count);
                Vector2Int next = pool[idx];
                pool.RemoveAt(idx);

                List<Vector2Int> path = astar.FindPath(route[route.Count - 1], next, allowOccupiedTarget: true);
                if (path != null && path.Count > 1)
                {
                    route.Add(next);
                    linked = true;
                    break;
                }
            }
            if (!linked) break;
        }
        return route;
    }

    /// <summary>运行期拼一条巡逻资产（不落盘）：小队 + 随机路线 + 随机步幅。名字由调用方给（遭遇区 / 野外巡逻两种命名）。</summary>
    private static SquadPatrolData MakeRuntimePatrol(EnemySquadData squad, List<Vector2Int> route,
        EncounterTable table, string soName, string patrolName)
    {
        SquadPatrolData patrol = ScriptableObject.CreateInstance<SquadPatrolData>();
        patrol.name = soName;
        patrol.mapId = "";                       // 运行期产物，不参与资产过滤
        patrol.squad = squad;
        patrol.patrolName = patrolName;
        patrol.squadPatrolAP = Random.Range(table.patrolAPMin, table.patrolAPMax + 1);
        patrol.squadSearchAP = 0;
        patrol.maxSearchCount = 2;
        patrol.patrolLoopMode = SquadPatrolLoopMode.往返;
        patrol.patrolWaypoints = route;
        patrol.spawnJitterRadius = 0;            // 已经是随机落位的结果，不再二次随机
        patrol.jitterGroupId = "";
        patrol.spawnOnStart = true;
        return patrol;
    }

    /// <summary>离出生点约束的参照格：优先地图出生点，其次教程「入」，最后玩家当前格。</summary>
    private static Vector2Int ResolveStartCoord(MapLayoutBuilder layout)
    {
        if (layout != null && layout.hasSpawn) return layout.spawnCoord;
        if (layout != null && layout.hasEntrance) return layout.entranceCoord;
        HexMover player = FindObjectOfType<HexMover>();
        if (player != null) return player.CurrentCoord;
        return NoPoint;
    }

    // ==================================================================
    // ③ 野外巡逻（★2026-09-16 新增：随机荒野专有——骨架通路锚点 → 按锚点群系抽小队）
    //    设计依据：随机远征 design v17 §3.5.7（锚点由 WastelandGenerator 撒在骨架通路上，
    //    距出生点 ≥ spawnClearRadius+3、锚点互距 ≥5；本方法只做消费：
    //    查锚点所在群系表 → 抽小队 → 锚点周边 R 格内连随机路线 → 与遭遇区同管线落地）。
    // ==================================================================

    /// <summary>
    /// 把荒野生成器撒的巡逻锚点变成真巡逻队。无荒野上下文（雾镇/教程）→ 0 支。
    /// 过滤：表查不到 / 池空 / 锚点不可通行 / 被单位占用 / 离出生点 &lt; 表 minDistanceFromStart → 跳过。
    /// </summary>
    private int SpawnWildernessPatrols(MapLayoutBuilder layout, string mapId)
    {
        if (!WastelandRunContext.HasContext) return 0;

        WastelandGenerator.WastelandLayout gen = WastelandRunContext.Layout;
        if (gen.patrolAnchors == null || gen.patrolAnchors.Count == 0) return 0;

        HexGridLayout grid = FindObjectOfType<HexGridLayout>();
        TerrainManager terrain = FindObjectOfType<TerrainManager>();
        HexMover player = FindObjectOfType<HexMover>();
        Vector2Int start = ResolveStartCoord(layout);

        int spawned = 0;
        int skipped = 0;
        for (int i = 0; i < gen.patrolAnchors.Count; i++)
        {
            WastelandGenerator.PatrolAnchor anchor = gen.patrolAnchors[i];
            WastelandGenerator.BiomeDef def = WastelandGenerator.Def(anchor.biome);

            EncounterTable table = EncounterTableLoader.LoadFor(mapId, def.mapLetter.ToString());
            if (table == null || table.ValidEntryCount == 0) { skipped++; continue; }

            if (!IsUsableCell(anchor.pos, terrain, grid, player, start, table.minDistanceFromStart)) { skipped++; continue; }
            if (UnitOccupancy.IsOccupied(anchor.pos)) { skipped++; continue; }

            EnemySquadData squad = table.RollSquad();
            if (squad == null) { skipped++; continue; }

            List<Vector2Int> candidates = BuildAreaCandidates(anchor.pos, WildernessRouteRadius,
                terrain, grid, player, start, table.minDistanceFromStart);
            if (candidates.Count == 0) { skipped++; continue; }

            List<Vector2Int> route = BuildRoute(anchor.pos, candidates, table, grid);
            SquadPatrolData patrol = MakeRuntimePatrol(squad, route, table,
                $"野外巡逻_锚{i}", $"野外{i}·{def.displayName}·{squad.squadName}");
            List<EnemyController> units = SpawnResolver.Spawn(patrol, spawnParent);
            if (units != null && units.Count > 0)
            {
                spawned++;
                Debug.Log($"[遭遇床] 野外巡逻 锚点 Hex_{anchor.pos.x}_{anchor.pos.y} 群系={def.displayName} " +
                          $"小队「{squad.squadName}」路线 {route.Count} 点 " +
                          $"[{string.Join(" → ", route.ConvertAll(c => HexCoord.FormatCell(c)))}] 步幅 {patrol.squadPatrolAP}");
            }
        }

        Debug.Log($"[遭遇床] 野外巡逻：{gen.patrolAnchors.Count} 个锚点 → 落地 {spawned} 支" +
                  (skipped > 0 ? $"，跳过 {skipped} 个（离出生点近 / 不可通行 / 被占用 / 无怪池）" : ""));
        return spawned;
    }

    private static void DeactivateUnboundEnemies()
    {
        foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
        {
            if (enemy == null) continue;
            Vector3 p = enemy.transform.position;
            if (p.sqrMagnitude < 0.25f)
            {
                Debug.Log($"[遭遇床] 停用原点残留敌人 {enemy.gameObject.name}");
                enemy.gameObject.SetActive(false);
            }
        }
    }
}

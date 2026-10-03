// =============================================================================
// 模块：探索系统 - 事件进战刷怪 EventCombatSpawner
// 用途：事件鉴定失败当场遇袭（design §3.3）：按玩家所在地格群系抽 1~2 只普通成员，
//       就近生成、全部置警戒，交由 ExplorationTurnManager 走「被动遇袭」既有路径。
// 依赖：EncounterTable（(图,群系) 概率池）+ SpawnResolver（落格/初始化/占位登记）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class EventCombatSpawner
{
    /// <summary>
    /// 在 anchor 附近生成 count 只敌人（1~2）。返回实际生成的控制器列表（可能为空 = 没表/没格子）。
    /// </summary>
    public static List<EnemyController> SpawnAt(Vector2Int anchor, int count)
    {
        var result = new List<EnemyController>();
        if (count <= 0) return result;

        // ① 地图 id（与 ExpeditionEncounterBootstrap 同一取法）
        MapLayoutBuilder layout = Object.FindObjectOfType<MapLayoutBuilder>();
        string mapId = layout != null && layout.layoutFile != null ? layout.layoutFile.name : "";

        // ② 群系字母（design §3.3：按玩家所在地格群系抽）
        WastelandGenerator.BiomeId biome;
        if (!WastelandRunContext.TryGetBiome(anchor, out biome))
        {
            Debug.LogWarning("[事件进战] 取不到地格群系，退化为通用表");
            biome = WastelandGenerator.BiomeId.Grass;
        }
        string biomeLetter = WastelandGenerator.Def(biome).mapLetter.ToString();

        // ③ 抽一支小队模板，只落地前 count 只
        EncounterTable table = EncounterTableLoader.LoadFor(mapId, biomeLetter);
        if (table == null)
        {
            Debug.LogWarning($"[事件进战] 地图「{mapId}」群系「{biomeLetter}」没有遭遇表，不进战");
            return result;
        }
        EnemySquadData squad = table.RollSquad();
        if (squad == null)
        {
            Debug.LogWarning($"[事件进战] 遭遇表「{table.name}」没抽到小队，不进战");
            return result;
        }

        HexGridLayout grid = Object.FindObjectOfType<HexGridLayout>();
        Transform parent = grid != null ? grid.transform : null;

        result = SpawnResolver.Spawn(squad, anchor, parent, null, null, count);
        Debug.Log($"[事件进战] 地格 {anchor} 群系「{WastelandGenerator.Def(biome).displayName}」："
                  + $"从「{squad.squadName}」落地 {result.Count} 只（请求 {count}）");
        return result;
    }
}

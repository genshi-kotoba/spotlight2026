// =============================================================================
// 模块：战斗系统 - EncounterTableLoader 随机遭遇表加载
// 目录：Assets/Resources/Encounters（Resources 路径 "Encounters"）
// 为什么用 Resources.LoadAll 而不是编辑器扫文件夹：
//   编辑器与真机共用同一套代码路径，不需要再维护一份 catalog 资产
//   （巡逻资产那边是因为历史包袱才用了 catalog + 后处理器）。
// 选择规则（★2026-09-16 群系分池：荒野按群系查家族怪池）：
//   ① (mapId, biome) 完全匹配；有多张则合并概率池（内容叠加）
//   ② (mapId, 空群系) 同图通用表
//   ③ (空 mapId, 空群系) 全局兜底表
//   ③ 都没有 → 返回 null（本图不刷随机遭遇）
// 不带群系的旧入口 LoadFor(mapId) = LoadFor(mapId, null)：只认「群系为空」的表，
//   —— 防止同图的多张群系表被当成「同图多张表」误合并进同一个概率池（关键坑）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class EncounterTableLoader
{
    public const string ResourceFolder = "Encounters";

    private static EncounterTable[] _all;

    /// <summary>清缓存（编辑器里改了表之后调一次即可；运行时不需要）。</summary>
    public static void Invalidate()
    {
        _all = null;
    }

    public static EncounterTable[] LoadAll()
    {
        if (_all == null) _all = Resources.LoadAll<EncounterTable>(ResourceFolder);
        return _all;
    }

    /// <summary>取某张地图的遭遇表（不带群系 = 只认通用表）；没有返回 null。</summary>
    public static EncounterTable LoadFor(string mapId)
    {
        return LoadFor(mapId, null);
    }

    /// <summary>
    /// 取表：先 (mapId, biome) 精确，其次 (mapId, 空)，最后 (空, 空) 兜底。
    /// biome 传 null / 空 = 跳过第一级（与旧行为完全一致）。
    /// </summary>
    public static EncounterTable LoadFor(string mapId, string biome)
    {
        EncounterTable[] all = LoadAll();
        if (all == null || all.Length == 0) return null;

        if (!string.IsNullOrEmpty(biome))
        {
            EncounterTable exact = Pick(all, mapId, biome);
            if (exact != null) return exact;
        }

        EncounterTable mapGeneric = Pick(all, mapId, "");
        if (mapGeneric != null) return mapGeneric;

        return Pick(all, "", "");
    }

    /// <summary>取一组参数完全匹配的表：0 张 → null，1 张 → 本体，多张 → 合并概率池。</summary>
    private static EncounterTable Pick(EncounterTable[] all, string mapId, string biome)
    {
        var matched = new List<EncounterTable>();
        foreach (EncounterTable t in all)
        {
            if (t == null) continue;
            if (t.mapId == mapId && t.biome == biome) matched.Add(t);
        }

        if (matched.Count == 0) return null;
        if (matched.Count == 1) return matched[0];
        return Merge(matched, mapId, biome);
    }

    /// <summary>多张同(图,群系)的表合并概率池（数量与路径范围取并集，宽松优先）。</summary>
    private static EncounterTable Merge(List<EncounterTable> tables, string mapId, string biome)
    {
        EncounterTable merged = ScriptableObject.CreateInstance<EncounterTable>();
        merged.name = "遭遇表_合并_" + (string.IsNullOrEmpty(biome) ? mapId : mapId + "_" + biome);
        merged.mapId = mapId;
        merged.biome = biome;
        merged.entries = new List<EncounterTable.Entry>();

        bool first = true;
        foreach (EncounterTable t in tables)
        {
            if (t.entries != null)
            {
                foreach (EncounterTable.Entry e in t.entries)
                {
                    if (e != null) merged.entries.Add(e);
                }
            }
            if (first)
            {
                merged.minSquadsPerZone = t.minSquadsPerZone;
                merged.maxSquadsPerZone = t.maxSquadsPerZone;
                merged.minWaypoints = t.minWaypoints;
                merged.maxWaypoints = t.maxWaypoints;
                merged.patrolAPMin = t.patrolAPMin;
                merged.patrolAPMax = t.patrolAPMax;
                merged.minDistanceFromStart = t.minDistanceFromStart;
                merged.minSquadSeparation = t.minSquadSeparation;
                first = false;
            }
            else
            {
                merged.minSquadsPerZone = Mathf.Min(merged.minSquadsPerZone, t.minSquadsPerZone);
                merged.maxSquadsPerZone = Mathf.Max(merged.maxSquadsPerZone, t.maxSquadsPerZone);
                merged.minWaypoints = Mathf.Min(merged.minWaypoints, t.minWaypoints);
                merged.maxWaypoints = Mathf.Max(merged.maxWaypoints, t.maxWaypoints);
                merged.patrolAPMin = Mathf.Min(merged.patrolAPMin, t.patrolAPMin);
                merged.patrolAPMax = Mathf.Max(merged.patrolAPMax, t.patrolAPMax);
                merged.minDistanceFromStart = Mathf.Min(merged.minDistanceFromStart, t.minDistanceFromStart);
                merged.minSquadSeparation = Mathf.Min(merged.minSquadSeparation, t.minSquadSeparation);
            }
        }

        string what = string.IsNullOrEmpty(biome) ? "地图「" + mapId + "」" : "地图「" + mapId + "」群系「" + biome + "」";
        Debug.Log($"[遭遇表] {what}有 {tables.Count} 张表，已合并概率池（共 {merged.entries.Count} 项）");
        return merged;
    }
}

// =============================================================================
// 模块：战斗系统 - EncounterTable 随机遭遇表
// 用途：描述「一张地图上的遭遇区里会刷出什么」——不写坐标、不写具体哪一格有怪，
//       只给**概率池**与**数量范围**，由 ExpeditionEncounterBootstrap 运行期掷点。
//
// 每局随机的三件事（★2026-09-12 用户定调）：
//   ① 数量：每个遭遇区刷几支小队（minSquadsPerZone ~ maxSquadsPerZone）
//   ② 类型：每支小队从小队模板池里按 weight 抽（哥布林巡逻队 / 单只史莱姆 / …）
//   ③ 路径：每支小队的巡逻路线在区内随机取点生成（点数 randomWaypoints）
//
// 存放位置：Assets/Resources/Encounters/*.asset
//   放 Resources 是为了「编辑器与真机同一套加载路径」（Resources.LoadAll），
//   不用再维护一份 catalog 资产。
//
// 与 SquadPatrolData 的分工：
//   · SquadPatrolData = 固定巡逻（教程 / 剧情 / 手工精摆，可带 ±N 小随机）
//   · EncounterTable   = 随机遭遇（正式图主力，每局都不一样）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "遭遇表_", menuName = "卡牌与骰子/随机遭遇表", order = 15)]
public class EncounterTable : ScriptableObject
{
    /// <summary>概率池里的一项：一个小队模板 + 权重。</summary>
    [Serializable]
    public class Entry
    {
        [Tooltip("小队模板（Assets/Data/Squads）。想刷「单只」就把 1 个成员的小队模板拖进来")]
        public EnemySquadData squad;

        [Tooltip("抽取权重（相对值，越大越常见）")]
        [Min(0)]
        public int weight = 1;
    }

    [Tooltip("本表属于哪张地图：填地图布局文件名（MapLayoutBuilder.layoutFile.name，如 fogtown）。\n" +
             "留空 = 通用兜底表（没有地图专属表时用它）。")]
    public string mapId = "";

    [Tooltip("本表服务哪个群系（荒野家族怪池·§3.5.9）：填群系图字母 G/J/C/R/A/B/W（草坡/密林/洞穴/废墟/古林/河湾/荒村）。\n" +
             "留空 = 不限群系（同图通用 / 全局兜底）。查表顺序：(图,群系) → (图,通用) → (通用,通用)。")]
    public string biome = "";

    [Header("① 数量：每个遭遇区刷几支小队")]
    [Tooltip("区内最少刷几支小队")]
    [Range(0, 6)]
    public int minSquadsPerZone = 1;

    [Tooltip("区内最多刷几支小队")]
    [Range(0, 6)]
    public int maxSquadsPerZone = 2;

    [Header("② 类型：从概率池抽")]
    [Tooltip("可刷的小队模板池（按 weight 抽）。空 = 本表不生成任何敌人")]
    public List<Entry> entries = new List<Entry>();

    [Header("③ 路径：每支小队的巡逻路线")]
    [Tooltip("巡逻路线最少几个路径点（1 = 原地驻守哨位，不走动）")]
    [Range(1, 6)]
    public int minWaypoints = 2;

    [Tooltip("巡逻路线最多几个路径点")]
    [Range(1, 6)]
    public int maxWaypoints = 3;

    [Tooltip("巡逻步幅下限（每回合走几格）")]
    [Range(0, 4)]
    public int patrolAPMin = 1;

    [Tooltip("巡逻步幅上限")]
    [Range(0, 4)]
    public int patrolAPMax = 2;

    [Header("防贴脸 / 防扎堆")]
    [Tooltip("小队出生点离「玩家出生格（或玩家当前位置）」至少这么远（六边距离）")]
    [Range(0, 30)]
    public int minDistanceFromStart = 8;

    [Tooltip("同一个遭遇区里，两支小队之间至少隔这么远（六边距离）")]
    [Range(0, 12)]
    public int minSquadSeparation = 4;

    /// <summary>概率池里有效（配了小队模板且权重 > 0）的条目数。</summary>
    public int ValidEntryCount
    {
        get
        {
            if (entries == null) return 0;
            int n = 0;
            foreach (Entry e in entries)
            {
                if (e != null && e.squad != null && e.weight > 0) n++;
            }
            return n;
        }
    }

    /// <summary>按权重抽一个小队模板；池空返回 null。</summary>
    public EnemySquadData RollSquad()
    {
        if (entries == null || entries.Count == 0) return null;

        int total = 0;
        foreach (Entry e in entries)
        {
            if (e != null && e.squad != null && e.weight > 0) total += e.weight;
        }
        if (total <= 0) return null;

        int roll = UnityEngine.Random.Range(0, total);
        foreach (Entry e in entries)
        {
            if (e == null || e.squad == null || e.weight <= 0) continue;
            roll -= e.weight;
            if (roll < 0) return e.squad;
        }
        return null;
    }
}

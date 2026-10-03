// =============================================================================
// 小队巡逻布局：引用一份小队模板 + 本图上的出生/路径。同一小队可拖进多份巡逻资产。
// 资产建议放在 Assets/Data/SquadPatrols
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public enum SquadPatrolLoopMode { 往返, 循环 }

[CreateAssetMenu(fileName = "巡逻_", menuName = "卡牌与骰子/小队巡逻", order = 14)]
public class SquadPatrolData : ScriptableObject
{
    [Tooltip("拖入 Assets/Data/Squads 里的小队模板（只含成员与站位）")]
    public EnemySquadData squad;

    [Tooltip("显示名（方便区分同一小队的不同路线）")]
    public string patrolName = "新巡逻";

    [Tooltip("★2026-09-12 本巡逻属于哪张地图。填地图布局文件名（对应 MapLayoutBuilder.layoutFile.name，如 fogtown）。\n" +
             "留空 = 通用：任何地图都会生成。\n" +
             "为什么需要：巡逻资产是【全局扫描】加载的（SquadPatrolLoader 扫整个 SquadPatrols 文件夹），\n" +
             "项目里场景/地图变多之后，不填 mapId 的巡逻会漏到每一张图上、且坐标是别的图写死的。")]
    public string mapId = "";

    [Tooltip("整队探索巡逻步数（未进战斗时全员共用；拐弯时内外圈再加减）。0 = 沿用各怪 EnemyData.patrolAP")]
    [Range(0, 5)]
    public int squadPatrolAP = 2;

    [Tooltip("搜索/归队步数（脱战黄`?`散开搜寻与白`?`归队共用，§10.1）。0 = 沿用上方巡逻AP")]
    [Range(0, 5)]
    public int squadSearchAP = 0;

    [Tooltip("一次意图循环内最多触发几次散开搜寻（§4，2026-09-08 用户定稿：默认 2）。用尽后再次丢失视野 → 跳过搜寻直接放弃回家（白`?`归队回血→回巡逻→复原）")]
    [Range(0, 5)]
    public int maxSearchCount = 2;

    [Tooltip("路径走完后：往返=倒序折返；循环=从终点接到起点")]
    public SquadPatrolLoopMode patrolLoopMode = SquadPatrolLoopMode.往返;

    [Tooltip("路径点（地图格子编号，如 12_16）。第一个点 = 出生锚点，朝下一个点排头尾。\n" +
             "★2026-09-12 起这是「基准路线」，实际落点可被 spawnJitterRadius 每局随机平移。")]
    public List<Vector2Int> patrolWaypoints = new List<Vector2Int>();

    public bool HasPatrolPath => patrolWaypoints != null && patrolWaypoints.Count >= 1;

    // ------------------------------------------------------------------
    // ★2026-09-12 每局随机落位
    // ------------------------------------------------------------------

    [Header("★每局随机落位")]
    [Tooltip("随机落位半径（六边距离）。0 = 完全固定，坐标写死（剧情/教程关键位可关）。\n" +
             ">0 = 每局开图时在该半径内随机挑一个「整条路线全都合法」的偏移，路线形状不变。\n" +
             "建议：教程 ±2（保证教学几何）｜正式图 ±6~10（同一个地方每局位置都不同）")]
    [Range(0, 12)]
    public int spawnJitterRadius = 0;

    [Tooltip("随机分组：填了同一串名字的巡逻共用【同一个】随机偏移量（整组刚性平移），组内相对站位严格不变。\n" +
             "用途：需要固定相对位置的一组（如教程演示跨队传导的两只怪，必须恒定相距 3 格）。\n" +
             "留空 = 这条巡逻自己随机，与别的巡逻无关。")]
    public string jitterGroupId = "";

    [Tooltip("开图时是否直接生成。\n" +
             "开 = 常规（进图就有）。\n" +
             "关 = 只登记不生成，等剧情脚本按需触发（如教程逃跑篇那支大巡逻队）。")]
    public bool spawnOnStart = true;

    // ------------------------------------------------------------------
    // ★2026-09-12 掉落配置（design：docs/2026-09-12_小队掉落编辑-design.md）
    // 同一小队模板的不同巡逻各自独立；EnemyData 上的旧掉落字段已废弃。
    // ------------------------------------------------------------------
    [Tooltip("本巡逻专属的掉落配置：小队级三选一稀有度 + 成员级灵魂/材料/卡池。在 Inspector 下方编辑")]
    public SquadDropConfig dropConfig = new SquadDropConfig();
}

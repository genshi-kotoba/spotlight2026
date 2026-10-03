// =============================================================================
// 模块：探索系统 - 随机荒野生成器 WastelandGenerator（v2 · 群系制）
// 用途：程序化生成一张「随机荒野」地图，产出与手写 txt **完全同构**的 ASCII 行
//       （列 = x 向右递增，行 = y 向下递增，第 1 行是 y=0 位于屏幕最上方）——
//       下游（MapLayoutBuilder 的建造 / 刷地形 / 登记节点 / 遭遇区归组 /
//       篝火挂载 / 撤离点 / 玩家摆位）**零改动**：生成器只是"另一个写 txt 的人"。
//
// 设计依据：docs/2026-09-15_随机远征-design.md
//   · §3.5.5 生成流程 v5（十一步 · v10 定稿）
//   · §3.5.3  群系池（7 群系：草坡/密林/洞穴/废墟/古林/河湾/荒村 · v14 删岩地）
//   · §3.5.3b 每局抽 3 + 地形族去重（N21① · 本稿 v15 落地）
//   · §3.5.3c 主群系（面积加权放大）+ 全图唯一大结构 + Boss 位（N22=甲 纯随机）
//   · §3.5.2  红墙 # = Mountain（真阻挡）、_ = Indoor（1AP 地板）—— 均为现成映射
//   · §3.5.4  群系图载体 = 第二张 ASCII 网格（N14 = ①）
//
// ★本轮口径（2026-09-15 用户裁定，覆盖文档 v10 的 N20=甲）：
//   1. **真 7 选 3**：草坡也参与抽（不再"草坡铺底不参与抽"）。
//   2. **地形族去重**（N21①）：林{密林,古林} / 建筑{废墟,荒村} 同族最多 1 个。
//   3. **草坡 = 强盗家族**：抽中草坡时，草坡上生成「强盗营地」类建筑据点；
//      其余地形基本全是大平地（`f` 只稀疏点缀）。
//
// 地图方言（与 MapLayoutBuilder 完全一致，**不新增任何字符**）：
//   .  平地（1 AP）   f  树林（2 AP）   w  水（3 AP）
//   #  红墙 = Mountain（**不可通行**，荒野读作岩壁/崖/残墙）
//   _  室内地板 = Indoor（1 AP，人造据点专用；★洞穴内部不用 _，用 . 与少量 w）
//   S  出生点（= 家 = 撤离点，每图 1 个）
//   F  篝火   C  室外宝箱   E  事件候选位   x  据点驻守锚点（连片 = 一个遭遇区）
//
// 生成流程（§3.5.5 十一步）：
//   0  抽群系      7 选 3（地形族去重）+ 纯随机指定 1 个主群系（种子决定）
//   1  群系分区    Voronoi 3 种子点 + 边界噪声抖动；主群系距离加权 → 地盘更大
//   2  地貌铺底    按各群系配方铺 . / f / w / #（全局噪声场 + 群系阈值；洞穴岩体做团块化）
//   3  骨架拼接    团块 + 通道（路网，跨群系连通；通道把骨架上的 # 挖穿成平地）
//   4  林缘        骨架外沿铺 f（只在"配方里有 f"的群系生效：草坡/密林/古林）
//   5  结构层      各群系专属结构（倒木/巨石/残墙/环形树阵/礁石/房舍）
//   6  边界收口    外圈强化地貌（有 f 的群系铺林，河湾铺水；★废墟/荒村不铺红墙崖边——边缘正常地形）
//   7  据点        每个抽中群系 1~2 个（草坡 = 强盗营地）；# 围合留门 + _ 地板 + C/E/x
//   8  大结构      只落主群系：多房间复合体（3~5 房串联），最深处 = Boss 房（Boss 位记进元数据）
//   9  内容 + 巡逻锚点   宝箱/事件/篝火散点 + 骨架通路上撒巡逻锚点（带群系归属）
//   10 校验 + 修复  BFS 连通性（# 真阻挡）；内容点不可达 → 把挡路的 # 降级为平地（能"修"）
//
// ★可复现：不用 UnityEngine.Random，同 (seed, settings) → 逐字节相同。
// ★Boss 说明：Boss 怪的四件套属 T16 专项轮（⏸）；本层只落「Boss 房 + Boss 位锚点」，
//   bossPos 记在 WastelandLayout 元数据里，供投放层 / 目标层（N25）接线。
// =============================================================================
using System;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

public static class WastelandGenerator
{
    // ---- 地图方言（与 MapLayoutBuilder 共用同一套字符）----
    public const char CH_PLAIN     = '.';
    public const char CH_FOREST    = 'f';
    public const char CH_WATER     = 'w';
    public const char CH_WALL      = '#';
    public const char CH_INDOOR    = '_';
    public const char CH_SPAWN     = 'S';
    public const char CH_BONFIRE   = 'F';
    public const char CH_CHEST     = 'C';
    public const char CH_EVENT     = 'E';
    public const char CH_ENCOUNTER = 'x';

    // ---- 材质/结构标签（A 方案 · 与 ASCII 并行的第二层；渲染层按标签选瓦片）----
    // 地形 . f w / 内容 S F C E x / 室内 _ 在 matRows 里直接透传（与 terrainRows 同字符）；
    // 真正要做细分的是 #（CH_WALL）：逻辑层它只表示"真阻挡"，美术上至少 8 种材质，见 FinalizeMaterialGrid。
    // 群系配色另走 biomeRows（mapLetter），不与本层耦合。
    public const char MT_MOUNTAIN   = 'M';   // 通用山体（草坡/古林/沼泽的崖边、山包）
    public const char MT_CAVE_ROCK  = 'R';   // 洞穴岩（外圈山体 + 隧道间岩）
    public const char MT_CAMP_WALL  = 'W';   // 强盗营地木/石围墙
    public const char MT_BUILDING   = 'B';   // 人造建筑墙（首领屋/村舍/地主大宅）
    public const char MT_RUIN_WALL  = 'U';   // 废墟断墙 / 塌石（残破石墙）
    public const char MT_TOMB       = 'T';   // 墓碑 / 石棺（亡者墓园）
    public const char MT_ALTAR      = 'A';   // 祭坛石（古林祭坛）
    public const char MT_ROOT       = 'K';   // 树根盘 / 倒木（密林根腔、古林/密林树）
    public const char MT_ISLE_RING  = 'I';   // 环湖岩带（沼泽湖心岛）
    public const char MT_BONE       = 'O';   // 兽巢骨墙 / 骨堆（密林兽巢）

    // ==================================================================
    // 群系定义（§3.5.3 · 7 群系）
    // ==================================================================
    public enum BiomeId { Grass = 0, Jungle = 1, Cave = 2, Ruins = 3, AncientForest = 4, Swamp = 5, WildVillage = 6 }

    public class BiomeDef
    {
        public BiomeId id;
        public string displayName;      // 群系名
        public char mapLetter;          // 群系图（第二张网格）用的字母
        public int terrainFamily;       // 地形族（N21① 去重用）：0 空旷 1 林 2 岩 3 建筑 4 水
        public int visionModifier;      // 群系视野修正（N31）：双方生效、最低 1
        public string familyName;       // 怪物家族（§3.5.9）
        public string bossName;         // 家族 Boss（四件套 ⏸ T16）
        public string strongholdName;   // 普通据点名
        public string bigStructureName; // 大结构名（§3.5.3d）
        public char interiorFloor;      // 据点/大结构内部地板字符（洞穴不用 _）
        public bool hasForest, hasWater, hasRock;
        public float forestThreshold, waterThreshold, rockThreshold; // 全局噪声场的群系阈值

        public BiomeDef(BiomeId id, string name, char letter, int family, int vision,
            string familyName, string boss, string stronghold, string bigStruct, char floor)
        {
            this.id = id; displayName = name; mapLetter = letter; terrainFamily = family;
            visionModifier = vision; this.familyName = familyName; bossName = boss;
            strongholdName = stronghold; bigStructureName = bigStruct; interiorFloor = floor;
        }
    }

    /// <summary>7 群系定义表（§3.5.3 · 阈值是"高于即该地形"的全局噪声阈值，可调）。</summary>
    public static readonly BiomeDef[] Biomes =
    {
        //                                                              族  视野  家族          Boss         据点         大结构       内地板
        new BiomeDef(BiomeId.Grass,         "草坡", 'G', 0,  0, "强盗",       "强盗头目",   "强盗营地",   "强盗大营",   '_')
            { hasForest = true,  forestThreshold = 0.80f },
        //  ★密林（用户 2026-09-16：「密林里面大部分是树，然后可能会刷河流湖泊，还有小山」）：
        //    · 大部分是树 → 由 `CarveForestClearings` 反向生成（先整片铺 `f` 再挖少量空地）保证
        //    · 河流湖泊     → 新开 `hasWater`，阈值取高（0.66）→ 只在噪声峰值处成"河/湖"，不漫成水乡
        //    · 小山         → `rockThreshold` 从 0.90 下调到 0.80，让 `#` 偶尔冒头成零散小山包
        //      （0.90 时 `#` 仅约 3%，几乎看不见；0.80 大约翻倍，仍是"点缀"而不是岩区）
        new BiomeDef(BiomeId.Jungle,        "密林", 'J', 1, -1, "狼族",       "狼王",       "兽巢",       "兽巢骨堆洞", '_')
            { hasForest = true,  forestThreshold = 0.35f,
              hasWater = true,   waterThreshold  = 0.66f,
              hasRock = true,    rockThreshold   = 0.80f },
        new BiomeDef(BiomeId.Cave,          "洞穴", 'C', 2, -1, "蛛族",       "蛛母",       "蛛巢",       "蛛巢深窟",   '.')
            { hasRock = true, rockThreshold = 0.30f },
        new BiomeDef(BiomeId.Ruins,         "废墟", 'R', 3, -1, "骸骨系",     "骸王",       "骨冢",       "亡者墓园",   '_')
            { hasRock = true, rockThreshold = 0.86f },
        new BiomeDef(BiomeId.AncientForest, "古林", 'A', 1, -2, "树族",       "古树·树心",  "林心祭坛",   "环形祭坛",   '_')
            { hasForest = true, forestThreshold = 0.22f, hasRock = true, rockThreshold = 0.90f },
        new BiomeDef(BiomeId.Swamp,         "沼泽", 'B', 4,  0, "沼泽潜伏者", "沼泽主宰",   "浸水营地",   "湖心岛",     '.')
            { hasForest = true, forestThreshold = 0.46f, hasWater = true, waterThreshold = 0.42f },
        new BiomeDef(BiomeId.WildVillage,   "荒村", 'W', 3, -1, "巨怪族",     "双头暴君",   "占据的村舍", "地主大宅",   '_')
            { hasRock = true, rockThreshold = 0.86f },
    };

    public static BiomeDef Def(BiomeId id) { return Biomes[(int)id]; }

    /// <summary>一次生成的完整产物（N14=①：地形行 + 群系行 + 结构元数据）。</summary>
    public class WastelandLayout
    {
        public int seed;
        public List<string> terrainRows;                 // → 喂 MapLayoutBuilder（下游零改动）
        public List<string> biomeRows;                   // → 群系图（可 dump 渲染 / 投放层查怪池）
        public List<string> matRows;                     // → 材质/结构标签网格（A 方案；与 terrainRows 同坐标系）
        public BiomeId[] drawnBiomes;                    // 本局抽中的 3 个群系
        public BiomeId mainBiome;                        // 主群系（大结构 + Boss 所在）
        public Vector2Int spawnPos;
        public bool hasBoss;                             // 大结构是否落成
        public Vector2Int bossPos;                       // Boss 驻扎位（大结构最深处）
        public BiomeId bossBiome;
        public List<StructureInfo> strongholds = new List<StructureInfo>();
        public StructureInfo bigStructure;               // 全图唯一（可为 null：放不下的兜底局）
        public List<PatrolAnchor> patrolAnchors = new List<PatrolAnchor>();
        public List<MatRect> matRects = new List<MatRect>();   // 材质归组矩形（A 方案：最终化 matRows 用）
        public string validation;                        // 校验报告（含修复结果）

        /// <summary>
        /// 喂 MapLayoutBuilder 的文本：地形行 + 可选材质段。
        /// ★2026-09-16 带材质地图（A 方案接线）：matRows 以 `//MAT` 段附加在地形行后 ——
        ///   旧版 MapLayoutBuilder 会把 `//` 行当注释忽略，**但会误吃材质行**，
        ///   所以配套的解析端必须认得 //MAT（见 MapLayoutBuilder.SplitLayoutSections）。
        ///   手写图（raid_town.txt 等）没有 //MAT 段 → 行为与从前完全一致。
        /// </summary>
        public string ToText()
        {
            string terrain = WastelandGenerator.ToText(terrainRows);
            if (matRows == null || matRows.Count == 0) return terrain;
            var sb = new System.Text.StringBuilder(terrain.Length + 8 + matRows.Count * 128);
            sb.Append(terrain);
            sb.Append("\n//MAT\n");
            sb.Append(WastelandGenerator.ToText(matRows));
            return sb.ToString();
        }
    }

    public class StructureInfo
    {
        public string name;          // 兽巢 / 强盗营地 / 蛛巢 …（大结构另有大结构名）
        public BiomeId biome;
        public Vector2Int center;
        public bool isBigStructure;
    }

    /// <summary>材质归组矩形（A 方案：matRows 最终化用）。记录每个"成形的结构"占地与其墙材质标签。</summary>
    public class MatRect
    {
        public int x0, y0, rw, rh;   // 占地矩形（左上角 + 宽高，单位：格）
        public char matTag;          // 该结构墙的材质标签（MT_*）
    }

    public class PatrolAnchor
    {
        public Vector2Int pos;
        public BiomeId biome;        // 巡逻队按所在群系的家族抽（§3.5.7）
    }

    /// <summary>生成参数。全部带默认值 —— 不传就是"标准档"（80×50）。</summary>
    [Serializable]
    public class Settings
    {
        [Header("尺寸（Q3 已定 v17：120×75，面积≈雾镇 2.25 倍）")]
        public int width = 120;
        public int height = 75;

        [Header("地貌层（全局噪声场 · 群系阈值见 BiomeDef）")]
        public float waterScale = 0.055f;
        public float forestScale = 0.115f;
        public float rockScale = 0.09f;

        [Header("★密林/古林反向生成（整片铺树 → 挖少量空地）")]
        [Tooltip("空地占区域面积比例：0.18 = 树占 82%、空地 18%（密林要\"树连着树\"）")]
        public float forestClearRatio = 0.18f;

        [Header("群系分区（Voronoi）")]
        [Tooltip("主群系距离除数：>1 = 主群系地盘放大（§3.5.3c）")]
        public float mainBiomeWeight = 1.7f;
        [Tooltip("分区边界噪声抖动幅度（格）——接缝不是直线")]
        public float biomeJitterAmp = 6.0f;

        [Header("骨架层（团块 / 通道）—— 数量按 120×75 面积标定")]
        public int blobCount = 14;
        public float blobRadiusMin = 3.2f;
        public float blobRadiusMax = 5.4f;
        public int corridorHalfWidth = 1;
        public int extraLinks = 4;

        [Header("据点（v17：每抽中群系 2~3 个，全图约 6~9 个）")]
        public int strongholdBaseCount = 2;         // 每抽中群系保底
        public int strongholdExtraChancePct = 60;   // 保底之外再抽 1 个的概率

        [Header("大结构（§3.5.3c：多房间复合体，N24=甲）")]
        public int bigRoomsMin = 3;
        public int bigRoomsMax = 5;

        [Header("内容（v17：数量按 120×75 面积 2.25 倍标定）")]
        public int chestCount = 27;
        public int eventCount = 22;
        public int bonfireCount = 4;
        public int patrolAnchorCount = 13;          // 巡逻锚点（原 §3.5.7「5~8 支」按面积放大）

        [Header("间距约束")]
        public int contentMinSeparation = 3;
        public int spawnClearRadius = 3;

        public Settings Clone() { return (Settings)MemberwiseClone(); }
    }

    // ==================================================================
    // 入口
    // ==================================================================
    public static WastelandLayout Generate(int seed, Settings s)
    {
        if (s == null) s = new Settings();
        int w = Mathf.Max(24, s.width);
        int h = Mathf.Max(24, s.height);

        var rng = new System.Random(seed);          // ★不用 UnityEngine.Random（可复现）
        var layout = new WastelandLayout { seed = seed };

        float oF = (float)rng.NextDouble() * 512f;  // 全局噪声场偏移（同种子同场）
        float oW = (float)rng.NextDouble() * 512f;
        float oR = (float)rng.NextDouble() * 512f;

        // ---- 0 抽群系：7 选 3 + 地形族去重 + 纯随机主群系（N22=甲）----
        BiomeId[] drawn = DrawBiomes(rng);
        layout.drawnBiomes = drawn;
        layout.mainBiome = drawn[rng.Next(drawn.Length)];

        // ---- 1 群系分区：Voronoi 3 种子点 + 边界抖动；主群系加权放大 ----
        //   ★用户 2026-09-16：「不要让山洞地形放在地图中间分割另外两个群系」
        //     洞穴区若横在地图中段，会把另外两个群系隔开 → 只能靠 ConnectRegions
        //     以「穿山代价 24」硬凿通（最后手段，形态上是山体被开膛）。
        //     根治办法是**抽种子点时就把洞穴挤到边侧**（见 PickVoronoiSeeds）。
        var seeds = PickVoronoiSeeds(rng, w, h, drawn);
        var biomeOf = new BiomeId[w, h];
        var regionCells = new List<Vector2Int>[Biomes.Length];
        for (int i = 0; i < Biomes.Length; i++) regionCells[i] = new List<Vector2Int>();
        BuildBiomeMap(biomeOf, regionCells, seeds, drawn, layout.mainBiome, s, rng, oR, w, h);

        // ---- 2 地貌铺底：按群系配方铺 . / f / w / # ----
        char[,] g = new char[w, h];
        FillTerrain(g, biomeOf, s, oF, oW, oR, w, h);

        // ---- 2b ★密林/古林"反向生成"：默认整片铺满树，再挖出少量空地 ----
        //    用户 2026-09-16：「你这密林都没树了」——根因是低频率噪声把树团成孤立斑块，
        //    斑块之间是成片空地。密林要的是"树连着树，只留少量空隙"，所以反过来做：
        //    先全铺 f，再挖 `chance` 比例的空地点（小、不成片），空地才是"缝"。
        CarveForestClearings(g, biomeOf, s, rng, w, h);

        // ---- 3 骨架拼接：团块 + 通道（路网，跨群系连通）----
        bool[,] skel = new bool[w, h];
        List<Vector2Int> centers = PickBlobCenters(rng, s, w, h);
        for (int i = 0; i < centers.Count; i++)
            CarveBlob(g, skel, centers[i], s.blobRadiusMin, s.blobRadiusMax, rng, w, h, biomeOf);
        for (int i = 0; i + 1 < centers.Count; i++)
            CarveCorridor(g, skel, centers[i], centers[i + 1], s.corridorHalfWidth, w, h, rng, biomeOf);
        for (int k = 0; k < s.extraLinks && centers.Count >= 4; k++)
        {
            int a = rng.Next(centers.Count), b = rng.Next(centers.Count);
            if (a != b) CarveCorridor(g, skel, centers[a], centers[b], s.corridorHalfWidth, w, h, rng, biomeOf);
        }

        // ★出生点提前定（第 4/7/8 步都要用；洞穴封山也要靠它判断洞口是否真的通得出去）
        Vector2Int spawn = PickSpawn(rng, centers, biomeOf, w, h);
        SetIfTerrain(g, spawn.x, spawn.y, CH_SPAWN, w, h);
        layout.spawnPos = spawn;

        // ---- 3b ★洞穴封山：山体是"最终形态"——必须在骨架之后（否则骨架会把山挖回平地）
        BuildCaveMass(g, biomeOf, skel, rng, w, h, spawn);
        // ★封山会覆盖出生点所在格（出生点若落在洞穴区，会被封成山体）——补回来
        if (g[spawn.x, spawn.y] == CH_WALL) g[spawn.x, spawn.y] = CH_SPAWN;

        // ---- 4 林缘：骨架外沿铺 f（只在配方里有 f 的群系生效）----
        ApplySkeletonFringe(g, biomeOf, skel, w, h);

        // ---- 4b ★密林/古林补树：把骨架在林地中央挖出的"大空地"缝回 f（用户：密林大部分是树）
        //         必须在骨架之后（骨架是"挖空地"的元凶），也必须在结构层之前
        //         （否则会把据点/大结构内部也填成树林）。只动 CH_PLAIN + 非骨架格。
        RefillForest(g, biomeOf, skel, rng, w, h);

        // ---- 5 结构层：各群系专属结构（红墙只落在非骨架格）----
        var occupied = new bool[w, h];              // 结构占地登记（防重叠）
        MarkOccupied(occupied, spawn, 2, w, h);     // ★出生点先占位：散点结构不许盖在它头上
        PlaceBiomeStructures(g, biomeOf, occupied, rng, regionCells, drawn, w, h, skel);

        // ---- 6 边界收口：外圈强化地貌（按群系给崖/林/水）----
        ApplyRim(g, biomeOf, 2, w, h);

        // ---- 7 据点：每抽中群系 1~2 个（草坡 = 强盗营地）----
        PlaceStrongholds(g, biomeOf, occupied, rng, regionCells, layout, s, skel, w, h);

        // ---- 8 大结构：只落主群系（多房间复合体 + Boss 房）----
        PlaceBigStructure(g, biomeOf, occupied, rng, regionCells, layout, s, skel, w, h);

        // ---- 9 内容 + 巡逻锚点 ----
        var used = new List<Vector2Int> { spawn };

        ScatterSingle(g, biomeOf, s.chestCount,  CH_CHEST,  used, rng, s, w, h, allowCave: false);
        ScatterSingle(g, biomeOf, s.eventCount,  CH_EVENT,  used, rng, s, w, h, allowCave: false);
        ScatterSingle(g, biomeOf, s.bonfireCount, CH_BONFIRE, used, rng, s, w, h, allowCave: false);
        PickPatrolAnchors(layout, g, skel, biomeOf, rng, spawn, s, w, h);

        // ---- 9b ★全图连通性兜底：把所有"与出生点不连通的可走陆地"接回主路网 ----
        //    ★这是 2026-09-16 冒烟 FAIL 的真正根因（不是 RepairPath 算法不行）：
        //      骨架只挖了 14 个团块 + 通道，剩下的地面**字符上虽是 . / f，但被
        //      红墙 / 崖 / 山体 / 水围成孤岛**。实测 seed 26 出生点可达仅 52.1%，
        //      另有**一整块 1461 格的陆地**被彻底切开，33 个内容点全在上面。
        //      内容层（ScatterSingle / 据点 / 大结构）在上面撒点，怎么修都修不到 ——
        //      RepairPath 要跨 100+ 格的红墙带，或者被洞穴山体的"不可穿越"规则彻底堵死。
        //      正解：**内容层之前**先把陆地连通性治了，让内容层永远只往"已经连通的陆地"上撒。
        layout.validation += ConnectRegions(g, biomeOf, spawn, rng, w, h);

        // ---- 10 校验 + 修复（# 真阻挡；不可达内容点 → 降级挡路红墙）----
        layout.validation += ValidateAndRepair(g, biomeOf, layout, w, h);

        // ★出生点兜底：万一仍被覆盖（结构密集时会发生），螺旋外扩找最近的纯地形格重摆；
        //   一圈都找不到就把原格强制降为平地（出生点绝不能丢——它是撤离点）
        if (g[spawn.x, spawn.y] != CH_SPAWN)
        {
            bool placed = false;
            for (int r = 1; r <= 24 && !placed; r++)
                for (int dy = -r; dy <= r && !placed; dy++)
                    for (int dx = -r; dx <= r && !placed; dx++)
                    {
                        if (Mathf.Abs(dx) != r && Mathf.Abs(dy) != r) continue;   // 只扫环上
                        int x = spawn.x + dx, y = spawn.y + dy;
                        if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                        if (!IsTerrain(g[x, y])) continue;
                        g[x, y] = CH_SPAWN;
                        spawn = new Vector2Int(x, y);
                        layout.spawnPos = spawn;
                        placed = true;
                    }
            if (!placed) { g[spawn.x, spawn.y] = CH_SPAWN; }   // 最后兜底：强制清格
            layout.validation += placed
                ? $"  ⚠️出生点被覆盖，已就近重摆 → {spawn.x},{spawn.y}"
                : "  ⚠️出生点被覆盖且周围无空地，已强制清格";
        }

        // ---- A 方案：材质/结构标签网格（与地形行同坐标系；渲染层按标签选瓦片，下游不读则零改动）----
        FinalizeMaterialGrid(g, biomeOf, layout, w, h);

        layout.terrainRows = ToRows(g, w, h);
        layout.biomeRows = ToBiomeRows(biomeOf, w, h);
        return layout;
    }

    // ==================================================================
    // 第 0 步：抽群系
    // ==================================================================
    /// <summary>7 选 3 + 地形族去重（N21①）：林{密林,古林} / 建筑{废墟,荒村} 同族最多 1 个。</summary>
    public static BiomeId[] DrawBiomes(System.Random rng)
    {
        var pool = new List<BiomeId>();
        foreach (BiomeDef b in Biomes) pool.Add(b.id);
        // Fisher-Yates 洗牌
        for (int i = pool.Count - 1; i > 0; i--)
        {
            int j = rng.Next(i + 1);
            BiomeId tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp;
        }

        var picked = new List<BiomeId>();
        var usedFamilies = new HashSet<int>();
        foreach (BiomeId id in pool)
        {
            if (picked.Count >= 3) break;
            int fam = Def(id).terrainFamily;
            if (usedFamilies.Contains(fam)) continue;   // 同族最多 1 个（防"两片树林"）
            picked.Add(id);
            usedFamilies.Add(fam);
        }
        // 兜底：极端情况下凑不满 3（理论上不会：5 个族、每族 ≥1）
        for (int i = 0; i < pool.Count && picked.Count < 3; i++)
            if (!picked.Contains(pool[i])) picked.Add(pool[i]);

        return picked.ToArray();
    }

    // ==================================================================
    // 第 1 步：Voronoi 群系分区
    // ==================================================================
    private struct VoronoiSeed { public Vector2Int pos; public BiomeId biome; public bool pinBiome; }

    /// <summary>抽 3 个 Voronoi 种子点。
    ///
    /// ★★用户 2026-09-16：「**不要让山洞地形放在地图中间分割另外两个群系**」——
    ///   洞穴区铺满 `#`（真阻挡），如果它的 Voronoi 区横在地图中段，就会把另外两个
    ///   群系实质隔断：两片陆地只能靠 ConnectRegions 以「穿山代价 24」凿通，
    ///   形态上表现为"山体被开了一道口子"，而且那格山也变成通道（不再致密）。
    ///   → 解法：**在抽种子点阶段就把洞穴挤到地图一侧**，让它和边界相贴，
    ///     而不是成为"夹在两个群系中间的一堵墙"。
    ///
    /// 两条策略：
    ///   ① **洞穴贴边**：若抽中的 3 个群系里有洞穴，把洞穴的种子点放到**随机一条边的中点附近**，
    ///      另外两个点放在**过地图中心、洞穴对侧**的位置（横向岔开）→ 洞穴永远在图的边缘、
    ///      另两个群系在剩下的空间里彼此相邻，不会被洞穴夹住。
    ///   ② **普通散布**：没有洞穴时按原来的"两两保持间距"抽点（行为与改动前一致）。
    /// </summary>
    private static List<VoronoiSeed> PickVoronoiSeeds(System.Random rng, int w, int h, BiomeId[] drawn)
    {
        // ---- 找出洞穴（若这局抽到了它）----
        bool hasCave = false;
        for (int i = 0; i < drawn.Length; i++) if (drawn[i] == BiomeId.Cave) { hasCave = true; break; }

        var list = new List<VoronoiSeed>();
        int margin = 6;

        if (hasCave)
        {
            // ★① 洞穴贴边：随机挑一条边，种子点落在该边中点附近（带随机滑动）
            int side = rng.Next(4);                                   // 0=左 1=右 2=上 3=下
            int cx, cy;
            switch (side)
            {
                case 0: cx = margin; cy = rng.Next(h / 4, h * 3 / 4); break;               // 左边
                case 1: cx = w - 1 - margin; cy = rng.Next(h / 4, h * 3 / 4); break;       // 右边
                case 2: cx = rng.Next(w / 4, w * 3 / 4); cy = margin; break;               // 上边
                default: cx = rng.Next(w / 4, w * 3 / 4); cy = h - 1 - margin; break;      // 下边
            }
            var cavePos = new Vector2Int(cx, cy);

            // ★另两个种子点放在"洞穴的对侧"：以洞穴→地图中心的连线为轴，把两点放到中心另一侧，
            //   这样洞穴与它们之间隔着整张图的中段，另两个群系可以彼此相邻（不是被洞穴夹住）。
            float ccx = w * 0.5f, ccy = h * 0.5f;                      // 地图中心
            float ux = ccx - cx, uy = ccy - cy;                        // 洞穴 → 中心
            float ulen = Mathf.Sqrt(ux * ux + uy * uy);
            if (ulen < 0.001f) { ux = 1f; uy = 0f; ulen = 1f; }
            ux /= ulen; uy /= ulen;
            // 垂直方向（用于把两个点岔开），以及"越过中心继续前推"的位移长度
            float px = -uy, py = ux;
            float push = Mathf.Min(w, h) * 0.22f;                       // 越过中心后继续前推的距离
            float spread = Mathf.Min(w, h) * 0.26f;                     // 两个点横向岔开的距离

            for (int i = 0; i < 2; i++)
            {
                float sgn = (i == 0) ? 1f : -1f;
                int tx = Mathf.RoundToInt(ccx + ux * push + px * spread * sgn);
                int ty = Mathf.RoundToInt(ccy + uy * push + py * spread * sgn);
                tx = Mathf.Clamp(tx, margin, w - 1 - margin);
                ty = Mathf.Clamp(ty, margin, h - 1 - margin);
                list.Add(new VoronoiSeed { pos = new Vector2Int(tx, ty) });
            }
            list.Add(new VoronoiSeed { pos = cavePos, pinBiome = true });   // ★贴边的点 = 洞穴的固定位置
            return list;
        }

        // ---- ③ 无洞穴：普通散布（两两保持间距）----
        float minSep = Mathf.Min(w, h) / 3.2f;
        int tries = 0;
        while (list.Count < 3 && tries < 300)
        {
            tries++;
            var p = new Vector2Int(rng.Next(margin, w - margin), rng.Next(margin, h - margin));
            bool ok = true;
            for (int i = 0; i < list.Count; i++)
                if (Vector2Int.Distance(p, list[i].pos) < minSep) { ok = false; break; }
            if (ok) list.Add(new VoronoiSeed { pos = p });
        }
        while (list.Count < 3)                                  // 兜底
            list.Add(new VoronoiSeed { pos = new Vector2Int(rng.Next(margin, w - margin), rng.Next(margin, h - margin)) });
        return list;
    }

    /// <summary>每格归属最近种子点 → 群系图；主群系距离除以权重 → 地盘放大；逐种子噪声抖动接缝。</summary>
    private static void BuildBiomeMap(BiomeId[,] biomeOf, List<Vector2Int>[] regionCells,
        List<VoronoiSeed> seeds, BiomeId[] drawn, BiomeId main, Settings s, System.Random rng, float noiseOff, int w, int h)
    {
        // 群系洗牌后绑到种子点（绑定写回种子结构——主群系加权按它判）
        // ★例外：`pinBiome = true` 的种子点（本局抽到洞穴时那个"贴边点"）**必须绑洞穴**，
        //   否则贴边就白做了——洞穴还是会随机落到中间去（用户 2026-09-16 口径）。
        var shuffled = new List<BiomeId>(drawn);
        for (int i = shuffled.Count - 1; i > 0; i--)
        {
            int j = rng.Next(i + 1);
            BiomeId tmp = shuffled[i]; shuffled[i] = shuffled[j]; shuffled[j] = tmp;
        }
        // 先把 Cave 换到 pinBiome 的那个槽位（若本局确实有洞穴）
        for (int i = 0; i < seeds.Count; i++)
        {
            if (!seeds[i].pinBiome) continue;
            if (shuffled[i] == BiomeId.Cave) break;
            int swapWith = shuffled.IndexOf(BiomeId.Cave);
            if (swapWith < 0) break;                                // 本局没抽到洞穴 → 无需处理
            BiomeId t = shuffled[i];
            shuffled[i] = BiomeId.Cave;
            shuffled[swapWith] = t;
            break;
        }
        for (int i = 0; i < seeds.Count; i++)
            seeds[i] = new VoronoiSeed { pos = seeds[i].pos, pinBiome = seeds[i].pinBiome, biome = shuffled[i % shuffled.Count] };

        // 每个种子点自己的抖动噪声偏移（边界不是直线的关键）
        float[] jx = new float[seeds.Count], jy = new float[seeds.Count];
        var jr = new System.Random(0x51CE);
        for (int i = 0; i < seeds.Count; i++) { jx[i] = (float)jr.NextDouble() * 256f; jy[i] = (float)jr.NextDouble() * 256f; }

        float amp = s.biomeJitterAmp;
        float mainW = Mathf.Max(1f, s.mainBiomeWeight);

        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int best = 0;
                float bestD = float.MaxValue;
                for (int i = 0; i < seeds.Count; i++)
                {
                    float d = Vector2Int.Distance(new Vector2Int(x, y), seeds[i].pos);
                    if (seeds[i].biome == main) d /= mainW;                       // ★主群系地盘放大
                    float n = Mathf.PerlinNoise((x + jx[i]) * 0.07f, (y + jy[i]) * 0.07f);
                    d += (n - 0.5f) * amp;                                        // ★边界抖动
                    if (d < bestD) { bestD = d; best = i; }
                }
                BiomeId b = seeds[best].biome;
                biomeOf[x, y] = b;
                regionCells[(int)b].Add(new Vector2Int(x, y));
            }
        }
    }

    // ==================================================================
    // 第 2 步：地貌铺底
    // ==================================================================
    private static void FillTerrain(char[,] g, BiomeId[,] biomeOf, Settings s,
        float oF, float oW, float oR, int w, int h)
    {
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                BiomeDef d = Def(biomeOf[x, y]);
                char c = CH_PLAIN;
                // ★★沼泽（用户 2026-09-16：「不是大片水域，而是陆地与水地打碎了混合在一起，
                //    星星点点的」）：关键是**水不能成片**。两个动作叠加：
                //    ① 噪声尺度拉到 ×6.0（原 ×3.4）→ 单个水洼的直径压到 1~3 格量级，碎成点
                //    ② 水门槛下调到 0.42 → 点数够多但不连片（配合高频，连通性天然被打散）
                //    ★为什么不直接再加频率：Perlin 在尺度 > 8 时相邻格几乎独立，会退化成"随机噪点"
                //      （看起来像电视雪花，不像沼泽）。×6.0 是本轮试出的"仍能看出水洼形状"的上限。
                bool isSwamp = d.id == BiomeId.Swamp;
                float fs = isSwamp ? s.forestScale * 6.0f : s.forestScale;
                float ws = isSwamp ? s.waterScale * 6.0f : s.waterScale;
                float nF = d.hasForest ? Mathf.PerlinNoise((x + oF) * fs, (y + oF) * fs) : 0f;
                float nW = d.hasWater  ? Mathf.PerlinNoise((x + oW) * ws,  (y + oW) * ws)  : 0f;
                float nR = d.hasRock   ? Mathf.PerlinNoise((x + oR) * s.rockScale,   (y + oR) * s.rockScale)   : 0f;

                if (d.id == BiomeId.Cave)
                {
                    // ★洞穴：地貌留到骨架之后再由 BuildCaveMass 整片封山（山体是最终形态）
                    c = CH_PLAIN;
                }
                else if (isSwamp)
                {
                    // ★沼泽：水 / 树 / 平地三种格子混乱破碎拼合——两个独立高频噪声各自抢占。
                    //   ★关键：**树优先于水**（不是水优先）→ 水只能填树没占的缝，
                    //     天然被树打断成"星星点点"，不会连成整片水面。
                    if (nF > d.forestThreshold) c = CH_FOREST;
                    else if (nW > d.waterThreshold) c = CH_WATER;
                }
                else
                {
                    if (d.hasForest && nF > d.forestThreshold) c = CH_FOREST;
                    if (d.hasWater && nW > d.waterThreshold) c = CH_WATER;
                    if (d.hasRock && nR > d.rockThreshold) c = CH_WALL;
                }
                g[x, y] = c;
            }
        }
    }

    /// <summary>
    /// ★洞穴：把"洞穴群系"整片变成山体，只留几条狭长扭曲的隧道（用户 2026-09-16 口径）。
    /// ★必须放在骨架之后调用——山体是最终形态，不是初始形态（骨架会把山挖回平地）。
    ///   保可达：隧道从骨架格出发钻，天然接住路网。
    /// </summary>
    private static void BuildCaveMass(char[,] g, BiomeId[,] biomeOf, bool[,] skel,
        System.Random rng, int w, int h, Vector2Int spawn)
    {
        // 收集洞穴区域的骨架格（候选入口）
        var skelCells = new List<Vector2Int>();
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                if (Def(biomeOf[x, y]).id != BiomeId.Cave) continue;
                if (skel[x, y]) skelCells.Add(new Vector2Int(x, y));
            }
        if (skelCells.Count == 0) return;

        // 1) 整片封成山体
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                if (Def(biomeOf[x, y]).id != BiomeId.Cave) continue;
                if (g[x, y] == CH_SPAWN) continue;
                if (g[x, y] == CH_INDOOR) continue;      // 据点内部不封（据点要能进）
                g[x, y] = CH_WALL;
            }

        // 2) ★入口：整片区域只留 2 个洞口
        //    用户 2026-09-16：「山体多一点，可探索空间小一点」
        //    ★洞口必须真的"通得出去"——这是 2026-09-16 最大的一处坑：
        //      只检查"洞外一格不是墙"是不够的，那一格很可能是隔壁群系里另一个孤立小块，
        //      主干于是成了"山里孤岛"，洞里放的所有宝箱/事件全部不可达
        //      （实测冒烟 200 seed 里 105 个 FAIL，元凶就是它）。
        //      现在改为：**封山后立刻对全图做一次从出生点出发的 flood**，
        //      洞口只有在"洞外邻居属于该可达集"时才算合格候选。
        //      ① 贴群系边界（洞外一步真的跨出洞穴区）
        //      ② 洞外格子属于从出生点可达的路网
        //      ③ 洞外不是墙/水
        //    满足者里优先选**彼此最远**的两个，让主隧道尽量横穿洞穴区。
        var reach0 = FloodFromSpawn(g, spawn, w, h);
        int wantEntries = Mathf.Max(2, (w + h) / 90);          // 120+75 = 195 → 2 个
        var exits = new List<Vector2Int>();
        var exitsLoose = new List<Vector2Int>();
        foreach (Vector2Int c in skelCells)
        {
            int[] dxs, dys; HexDirs(c.x, out dxs, out dys);
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = c.x + dxs[i], ny = c.y + dys[i];
                if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) continue;
                if (Def(biomeOf[nx, ny]).id == BiomeId.Cave) continue;      // 这一步得真的跨出去
                if (g[nx, ny] == CH_WALL || g[nx, ny] == CH_WATER) continue; // 洞外不能是墙/水
                if (reach0[nx, ny]) exits.Add(c);                            // ★合格洞口
                else exitsLoose.Add(c);                                      // 备选（洞外暂不可达）
                break;
            }
        }
        var pool = exits.Count > 0 ? exits : (exitsLoose.Count > 0 ? exitsLoose : skelCells);
        var entries = new List<Vector2Int>();
        for (int k = 0; k < pool.Count && entries.Count < wantEntries; k++)
        {
            Vector2Int c = pool[rng.Next(pool.Count)];
            bool near = false;
            foreach (Vector2Int e in entries)
                if (Mathf.Abs(e.x - c.x) + Mathf.Abs(e.y - c.y) < 30) { near = true; break; }
            if (!near) entries.Add(c);
        }
        if (entries.Count < 2)
            for (int k = 0; k < pool.Count && entries.Count < 2; k++)
            {
                Vector2Int c = pool[k];
                if (entries.Count == 0 || Mathf.Abs(entries[0].x - c.x) + Mathf.Abs(entries[0].y - c.y) >= 4)
                    entries.Add(c);
            }
        if (entries.Count == 0) entries.Add(skelCells[0]);
        if (entries.Count == 1) entries.Add(skelCells[skelCells.Count - 1]);

        // 3) ★★隧道网络（用户 2026-09-16：「洞穴里面最好是隧道网络，就像环世界里面的洞穴一样」）
        //
        //  ★形态目标：**一张交织的隧道网** —— 几条主干（度=2 的狭长扭曲走廊）在洞里延展、
        //    彼此只在地道真正相交处交汇，大量可走格仍是"走廊中的一格"（度=2），
        //    只留下少量岔口，并有若干死胡同（尽头放宝箱）。
        //    环世界的洞穴就是这样：走廊四通八达，但**每条走廊本身都是窄的**，不是被挖空的大厅。
        //
        //  ★★血泪教训（本轮 4 次翻车，直接指标是"十字口占比"）：
        //    1. 「入口两两互连」→ 反复扫刷成蜂巢（度≥4 占 82.6%）。
        //    2. 「分段 HexWalk」→ 段间互不共享 visited，必然自我交错（度≥4 占 52%）。
        //    3. 「自避游走复用」看起来安全，其实**照样会炸** —— 自避只是"不踩自己走过的格"，
        //       它**允许原地后退、也允许紧贴自己已挖的隧道平行开挖**：
        //         · 原地后退一步 → 新格与旧格只隔 1 格，两者之间的"墙"被挤掉 → 两条隧道并成一条宽的
        //         · 平行开挖     → 同理，两条 1 格宽隧道之间只留 1 格墙，视觉上就是一条 2 格宽走廊
        //       实测度数分布从「直道 45~123 / 岔口 44~82 / 十字 53~175」劣化到
        //       「直道 ~260 / 岔口 ~300 / **十字 ~1000**」，交叉口占 60%+，山体被啃成筛子。
        //    4. 把"贴墙"门槛一刀切到极严 → 隧道只敢往没挖过的空地钻，
        //       洞穴塌成一条**孤立细线**（种子 0.37，端点 5/直道 45，大半互不连通）——又太过了。
        //
        //  ★★本轮定稿的硬约束（均衡点，围绕"1 格宽隧道不许并线"）：
        //    a) **禁止原地后退**：每步硬性排除"上一步所在格"。
        //    b) **禁并线**：新格与上一步"隔 1 格相望"（共享 ≥2 邻居）→ 弃这一步。
        //    c) **禁贴墙**：新格对已有隧道的邻居数 ≥ 3 → 弃（≥3 才会把两侧墙都挤掉；=2 仍允许拐弯）。
        //    d) **终止即汇入**：候选里若出现"已有隧道格"，收作终点（自然成岔口），本段结束。
        //    e) **主干额外加长**（`caveCells * 0.22` 下限）：主干是"洞的主路"，
        //       短了洞穴就只剩几个小口袋，没有可探索感。
        var spine = new List<Vector2Int>();
        var allTunnel = new List<Vector2Int>();          // ★全局隧道格（所有已挖通道），供"汇入"判定

        // 3-0) 先挖主干：入口 → 洞内深处（自避游走，带全部硬约束 · isMain=true 会被加长）
        if (entries.Count >= 2)
        {
            spine = CarveCaveSpine(g, biomeOf, entries[0], entries[1], rng, w, h, ref allTunnel, true);
            if (spine.Count == 0) { allTunnel.Add(entries[0]); }
        }
        else
        {
            CarveCaveTunnel(g, biomeOf, entries[0], entries[0], rng, w, h);
            spine.Add(entries[0]);
            allTunnel.Add(entries[0]);
        }
        // 其余入口各自短接线接到主干（不是彼此互连）——保证外部路网能进来
        for (int i = 2; i < entries.Count; i++)
        {
            Vector2Int best = spine.Count > 0 ? spine[0] : entries[0];
            int bd = int.MaxValue;
            foreach (Vector2Int p in spine)
            {
                int d = HexDist(p, entries[i]);
                if (d < bd) { bd = d; best = p; }
            }
            CarveCaveTunnel(g, biomeOf, best, entries[i], rng, w, h);
        }

        // 3a) ★网段：从"已有隧道"上再引出若干条支线，向洞穴区深处延展。
        //     每条支线起点必须是已有隧道格（否则凭空在山里开洞）；
        //     延展方向是随机远点；**沿途遇到已有隧道即汇入并停止**（自然成岔口）。
        //     ★起点从 allTunnel 里抽（而非只从主干 spine 抽）→ 网段层层向外生长，
        //       这才是"网"而不是"一条主线 + 几条平行支线"。
        int webBranches = Mathf.Max(3, (w + h) / 34);            // 195/34 ≈ 5 条
        for (int b = 0, tries = 0; b < webBranches && tries < webBranches * 20; tries++)
        {
            if (allTunnel.Count == 0) break;
            Vector2Int from = allTunnel[rng.Next(allTunnel.Count)];
            if (g[from.x, from.y] == CH_WALL) continue;
            Vector2Int to = new Vector2Int(0, 0); bool okTo = false;
            for (int t = 0; t < 40; t++)
            {
                int tx = rng.Next(1, w - 1), ty = rng.Next(1, h - 1);
                if (Def(biomeOf[tx, ty]).id != BiomeId.Cave) continue;
                if (HexDist(from, new Vector2Int(tx, ty)) < 14) continue;   // 太近没意义
                to = new Vector2Int(tx, ty); okTo = true; break;
            }
            if (!okTo) continue;
            var seg = CarveCaveSpine(g, biomeOf, from, to, rng, w, h, ref allTunnel, false);
            if (seg.Count >= 10) { b++; spine.Add(from); spine.AddRange(seg); }
        }

        // 3b) ★死胡同支洞：从已有隧道上随机起步往外钻，**走到头就停**，尽头放宝箱
        //     约束：起点方向必须"山体厚实"（前 3 格全是墙），且支洞每一步都要检查贴墙，
        //     防止支洞贴着主干平行开挖（会连成宽洞、把山体啃成筛子）
        var tips = new List<Vector2Int>();
        int branches = Mathf.Max(4, (w + h) / 22);              // 195/22 ≈ 8 条
        for (int b = 0; b < branches * 8 && tips.Count < branches; b++)
        {
            if (allTunnel.Count == 0) break;
            Vector2Int start = allTunnel[rng.Next(allTunnel.Count)];
            if (g[start.x, start.y] == CH_WALL) continue;        // 起点必须在主干上

            int[] dxs, dys; HexDirs(start.x, out dxs, out dys);
            // 起点方向：优先朝"山体厚实"的一侧（该方向前 3 格都还是墙）
            var okDirs = new List<int>();
            for (int i = 0; i < HexNeighborCount; i++)
            {
                bool thick = true;
                int cx = start.x, cy = start.y;
                for (int s2 = 0; s2 < 3; s2++)
                {
                    HexDirs(cx, out dxs, out dys);
                    int nx = cx + dxs[i], ny = cy + dys[i];
                    if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1
                        || Def(biomeOf[nx, ny]).id != BiomeId.Cave
                        || g[nx, ny] != CH_WALL) { thick = false; break; }
                    cx = nx; cy = ny;
                }
                if (thick) okDirs.Add(i);
            }
            if (okDirs.Count == 0) continue;
            int dir = okDirs[rng.Next(okDirs.Count)];
            int len = 10 + rng.Next(13);                         // 10~22 格
            Vector2Int cur = start, tip = start;
            int dug = 0;
            for (int step = 0; step < len; step++)
            {
                if (step % 4 == 0 && rng.Next(100) < 45) dir = rng.Next(HexNeighborCount);
                HexDirs(cur.x, out dxs, out dys);
                int nx = cur.x + dxs[dir], ny = cur.y + dys[dir];
                if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) break;
                if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) break;
                if (g[nx, ny] != CH_WALL) break;                 // 撞上已有通道 → 停（这才是死胡同）
                cur = new Vector2Int(nx, ny);
                // ★支洞也走 2~3 格宽（与主干口径一致）；这里只挖"中心格"，
                //   下面的 DigCaveCell 会把它和六向邻居一起挖开
                g[cur.x, cur.y] = CH_PLAIN; dug++;
                DigCaveCell(g, biomeOf, cur.x, cur.y, rng, w, h, radius: 1);
                tip = cur;
            }
            if (dug >= 6 && (tip.x != start.x || tip.y != start.y)) tips.Add(tip);
        }

        // 4) 入口格开口（保证接上外部路网）——洞口开成一小段 2~3 格宽的喇叭口
        foreach (Vector2Int e in entries)
        {
            if (g[e.x, e.y] == CH_WALL) g[e.x, e.y] = CH_PLAIN;
            // ★洞口不再只是"一格 + 右邻居"，而是和隧道同宽的六向一簇，
            //   否则 3 格宽的隧道到洞口突然收成 1 格，视觉上像被卡住。
            int[] ex, ey; HexDirs(e.x, out ex, out ey);
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = e.x + ex[i], ny = e.y + ey[i];
                if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) continue;
                if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) continue;   // 洞口不越界（洞外留给外部路网）
                if (g[nx, ny] == CH_WALL) g[nx, ny] = CH_PLAIN;
            }
        }

        // 5) ★死胡同尽头放宝箱（用户：「死胡同尽头放点宝箱就行」）
        //    ★★2026-09-16 修：隧道从 1 格宽改 2~3 格宽后，**"度数=1 的端点格"几乎消失了** ——
        //      3 格宽的走廊末端是一个 2~3 格的小平台，平台里每格都能看到 2~5 个可走邻居，
        //      "度数 ≤1"这个旧判据在宽隧道里基本选不出东西（改宽后会变成洞内几乎没宝箱）。
        //    → 新判据：**"离岔口的纵深"**。先标出所有"邻域带岔口"的格（度数 ≥3 的格本身
        //      以及它的六向邻居），从这些格做一次 BFS，得到每个可走格的"离岔口步数"。
        //      步数越大 = 越往死胡同里钻。取步数最大的若干格、且要求它**确实是末端**
        //      （邻域里没有"步数更大"的格）→ 那就是死胡同尽头。
        var junctionSeed = new List<Vector2Int>();
        int[] jx, jy;
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                if (Def(biomeOf[x, y]).id != BiomeId.Cave) continue;
                char c0 = g[x, y];
                if (c0 == CH_WALL || c0 == CH_SPAWN || c0 == CH_INDOOR) continue;
                HexDirs(x, out jx, out jy);
                int deg = 0;
                for (int i = 0; i < HexNeighborCount; i++)
                {
                    int nx = x + jx[i], ny = y + jy[i];
                    if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) continue;
                    if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) continue;
                    if (g[nx, ny] != CH_WALL) deg++;
                }
                if (deg >= 3) junctionSeed.Add(new Vector2Int(x, y));
            }
        // 从岔口集做多源 BFS：depth[格] = 离最近岔口的步数（-1 = 未访问/不可走）
        var depth = new int[w, h];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) depth[x, y] = -1;
        var q = new Queue<Vector2Int>();
        foreach (Vector2Int s in junctionSeed)
        {
            if (depth[s.x, s.y] < 0) { depth[s.x, s.y] = 0; q.Enqueue(s); }
            HexDirs(s.x, out jx, out jy);
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = s.x + jx[i], ny = s.y + jy[i];
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) continue;
                char c1 = g[nx, ny];
                if (c1 == CH_WALL || c1 == CH_SPAWN || c1 == CH_INDOOR) continue;
                if (depth[nx, ny] < 0) { depth[nx, ny] = 0; q.Enqueue(new Vector2Int(nx, ny)); }
            }
        }
        while (q.Count > 0)
        {
            Vector2Int cur2 = q.Dequeue();
            HexDirs(cur2.x, out jx, out jy);
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = cur2.x + jx[i], ny = cur2.y + jy[i];
                if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) continue;
                if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) continue;
                char c2 = g[nx, ny];
                if (c2 == CH_WALL || c2 == CH_SPAWN || c2 == CH_INDOOR) continue;
                if (depth[nx, ny] >= 0) continue;
                depth[nx, ny] = depth[cur2.x, cur2.y] + 1;
                q.Enqueue(new Vector2Int(nx, ny));
            }
        }
        // 候选 = 纵深 ≥ MIN_DEPTH 的格；按纵深降序排，越深越优先（真正的尽头）
        const int MIN_DEPTH = 4;
        var deep = new List<Vector2Int>();
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                if (depth[x, y] < MIN_DEPTH) continue;
                char c3 = g[x, y];
                if (c3 == CH_WALL || c3 == CH_SPAWN || c3 == CH_INDOOR || c3 == CH_CHEST) continue;
                deep.Add(new Vector2Int(x, y));
            }
        deep.Sort((p1, p2) => depth[p2.x, p2.y].CompareTo(depth[p1.x, p1.y]));

        // 洞口附近排除（别把宝箱堵在洞口）
        var deadEnds = new List<Vector2Int>();
        foreach (Vector2Int t in deep)
        {
            bool nearEntry = false;
            foreach (Vector2Int e in entries)
                if (Mathf.Abs(t.x - e.x) + Mathf.Abs(t.y - e.y) <= 4) { nearEntry = true; break; }
            if (nearEntry) continue;
            // 彼此不要挨太近（一个死胡同只放一个）
            bool tooClose = false;
            foreach (Vector2Int d in deadEnds)
                if (HexDist(t, d) <= 3) { tooClose = true; break; }
            if (tooClose) continue;
            deadEnds.Add(t);
        }

        // 每条死胡同都给一个宝箱；太多则截断（避免洞穴区变成宝箱仓库）
        //   ★宽隧道后死胡同变多，上限从 `(w+h)/30` 抬到 `(w+h)/22` 让洞里有点东西可捡
        int maxChests = Mathf.Max(3, (w + h) / 22);              // 195/22 ≈ 8 个
        for (int i = 0; i < deadEnds.Count; i++)
        {
            if (i >= maxChests) break;
            Vector2Int t = deadEnds[i];
            g[t.x, t.y] = CH_CHEST;
        }
        // tips 里没被上面覆盖到的，也补上（tips 天然是支洞末端）
        for (int i = 0; i < tips.Count && i < maxChests; i++)
        {
            Vector2Int t = tips[i];
            if (t.x < 1 || t.y < 1 || t.x >= w - 1 || t.y >= h - 1) continue;
            char ct = g[t.x, t.y];
            if (ct == CH_SPAWN || ct == CH_INDOOR || ct == CH_CHEST) continue;
            if (ct == CH_WALL) continue;                          // ★宽化后 tips 可能落在新挖开的围壁上，跳过
            g[t.x, t.y] = CH_CHEST;
        }
    }

    /// <summary>★洞穴挖开一格（用户 2026-09-16：「山洞的地图好像有点太窄了，**2-3格宽吧**」）。
    ///
    /// 之前是**严格 1 格宽**（只把路径格本身改成 `.`），洞壁全靠山体——形态最"狭长"，
    /// 但玩家在里面根本转不开身（六边形里 1 格宽走廊连错身都做不到）。
    /// 现在把每条隧道的路径格**再向外扩 1 圈**（六向邻居），得到 2~3 格宽：
    ///   · 走廊段（直道）扩出来是 3 格宽的一条带（中心 + 两侧）；
    ///   · 拐角处因为采样重叠，实际观感是 2~3 格的"圆钝转角"，不会出现锐角尖刺。
    ///
    /// ★为什么用**六向邻居**扩而不是 4 向的 3×3 方块：地图是 odd-q 平顶六边形，
    ///   4 向方块扩会在斜向留下"多挖的角"，走廊截面变成锯齿（本项目此前多处踩过）。
    ///   `HexDirs` 拿到的 6 个邻居才是真正的"相邻格"。
    /// ★"只加深、不拓宽"：**只把 `#` 改成可走**，已经是 `_`/`S`/`C`/`F` 的格一律不动
    ///   （据点内部、出生点、已放好的内容点不能被隧道吃掉）。
    /// </summary>
    private static void DigCaveCell(char[,] g, BiomeId[,] biomeOf, int x, int y, System.Random rng, int w, int h, int radius)
    {
        for (int ry = -radius; ry <= radius; ry++)
            for (int rx = -radius; rx <= radius; rx++)
            {
                int cx = x + rx, cy = y + ry;
                if (cx < 1 || cy < 1 || cx >= w - 1 || cy >= h - 1) continue;
                // 半径 ≤1 时就是"路径格 + 六向邻居"，用六边形距离裁掉方块的斜角
                if (radius >= 1 && HexDist(new Vector2Int(x, y), new Vector2Int(cx, cy)) > radius) continue;
                DigOne(g, biomeOf, cx, cy, rng);
            }
    }

    /// <summary>挖开单格：把山体 `#` 改成可走（少量暗河）；**不动**已成形的地板/出生点/内容点。</summary>
    private static void DigOne(char[,] g, BiomeId[,] biomeOf, int x, int y, System.Random rng)
    {
        if (Def(biomeOf[x, y]).id != BiomeId.Cave) return;
        char c = g[x, y];
        if (c == CH_SPAWN || c == CH_INDOOR || c == CH_CHEST || c == CH_BONFIRE || c == CH_EVENT) return;
        if (c != CH_WALL) return;                                   // 已是通道 → 不动（幂等）
        g[x, y] = rng.Next(100) < 6 ? CH_WATER : CH_PLAIN;           // 少量暗河
    }

    /// <summary>★洞穴主干 / 网段：从 from 到 to（大方向）挖一条**2~3 格宽**的自避隧道。
    /// 返回新挖出的格序列，并把这些格追加进 allTunnel（全局隧道集合）。
    ///
    /// ★为什么必须"自避 + 三重硬约束"（本轮 4 次翻车的最终答案）：
    ///   自避只能保证"不踩自己走过的格"，**远远不够** —— 它允许原地后退、也允许紧贴自己
    ///   已挖的隧道平行开挖；两种情况下两条 1 格宽隧道之间只隔 1 格墙，那面墙随后被挤掉，
    ///   两条隧道并成一条 2 格宽的走廊，交叉口数量爆炸（实测十字口 53 → 1000+/局），
    ///   洞穴整体退化成蜂巢。所以除自避外还需：
    ///     · 禁原地后退：排除上一步所在格（否则立刻造成并线）
    ///     · 禁贴墙：新格对已有隧道的六向邻居数 ≥3，或与上一步"隔 1 格相望" → 弃这一步
    ///       （"隔 1 格相望"= 两者共享 ≥2 个邻居，即典型并线信号）
    ///     · 终止即汇入：候选里出现已有隧道格 → 收作终点，自然形成岔口
    ///   ★汇入次数由调用方通过 allTunnel 规模间接控制，避免岔口密度过高。
    ///   ★★allTunnel 必须由**所有**挖通道的调用点共享（同一份"已有隧道"集合），
    ///      否则每条通道都以为自己走在处女地上，贴墙并线照旧发生。</summary>
    private static List<Vector2Int> CarveCaveSpine(char[,] g, BiomeId[,] biomeOf,
        Vector2Int from, Vector2Int to, System.Random rng, int w, int h,
        ref List<Vector2Int> allTunnel, bool isMain)
    {
        var spine = new List<Vector2Int>();
        if (from.x < 1 || from.y < 1 || from.x >= w - 1 || from.y >= h - 1) return spine;

        var visited = new HashSet<int>();
        visited.Add(from.y * w + from.x);

        // ★已挖隧道格查找表（O(1)）：来自全局 allTunnel。
        //   ★注意 allTunnel 是引用传递的 List，调用方在同一次 BuildCaveMass 里
        //     反复挖通道时会不断往里追加 → 这里每次进来都重建一份，拿到最新快照。
        var tunnel = new HashSet<int>();
        foreach (Vector2Int p in allTunnel) tunnel.Add(p.y * w + p.x);

        var cur = from;
        if (g[from.x, from.y] == CH_WALL) g[from.x, from.y] = CH_PLAIN;
        var prev = new Vector2Int(-1, -1);                 // ★上一步（禁原地后退）

        // ★长度上限：按洞穴区面积的平方根量级（约等于横穿一次的规模）。
        //   走到上限就停 —— 停下的位置天然成为一条长死胡同的末端。
        int caveCells = 0;
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
                if (Def(biomeOf[x, y]).id == BiomeId.Cave) caveCells++;
        int maxSteps = Mathf.Max(20, (int)(System.Math.Sqrt((double)caveCells) * 1.45));
        // ★主干（isMain）额外加长：主干是"洞的主路"，短了洞穴就只剩几个小口袋，没有可探索感。
        //   网段（!isMain）保持默认上限，避免把山体挖穿。
        if (isMain) maxSteps = Mathf.Max(maxSteps, Mathf.RoundToInt(caveCells * 0.22f));

        int[] dxs, dys;

        // ★★"并线/贴墙"判定（本轮翻车的核心，务必看懂）：
        //   目标：禁止"两条 1 格宽隧道之间只留 1 格墙"（那条墙一旦被挤掉，两条隧道就并成
        //   一条 2 格宽的走廊，洞穴退化为蜂巢）。
        //
        //   ★错法（之前两次翻车都是它）：拿"新格 vs 上一步 prev"数共同邻居。
        //     在六边形网格里，A→B 走一步后，B 的邻居里天然就有 2 个与 A 相邻
        //     （六边形的"菱形"结构：A、B 共享 2 个邻居是**一步直走的正常几何**）
        //     → 该判定对**每一次正常前进**都返回 true，游走一步都走不出去。
        //     实测：CarveCaveSpine 被调用 101 次只挖出 8 格、99 次空返回，
        //     洞穴于是完全由 CarveCaveTunnel 那几条线构成（山体 94%，可走仅 228 格）。
        //
        //   ★对法：数"新格 nx 周围**已有隧道的邻居数**"（`adjTunnel`），
        //     但**把 cur（当前格）排除在外** —— cur 是"上一步"，不是"另一条隧道"。
        //     直走时 adjTunnel=0；拐弯时 adjTunnel=1（上一格）→ 减掉 cur 后也是 0；
        //     只有真正贴着"**另一段**已有隧道"平行开挖时，adjTunnel 才会 ≥2。
        //     门槛取 2：允许偶尔擦边，禁止并线。
        const int ADJ_TUNNEL_LIMIT = 2;

        for (int step = 0; step < maxSteps; step++)
        {
            if (cur.x == to.x && cur.y == to.y) break;
            HexDirs(cur.x, out dxs, out dys);

            var cand = new List<int>();          // 邻居索引
            var candD = new List<int>();         // 到 to 的距离（软推进用）
            int mergeDir = -1;                   // ★若某邻居是已有隧道 → 优先汇入
            // ★★第一步特殊处理：起始格本身就在隧道上，它的邻居里必然有隧道格，
            //    若第一步就允许"汇入"，那条支线会在原地立即结束（实测 100/100 全部走空）。
            //    所以第一步**只允许向外生长**（不许汇入已有隧道）。
            bool allowMerge = spine.Count > 0;
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = cur.x + dxs[i], ny = cur.y + dys[i];
                if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) continue;
                if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) continue;
                // ★汇入：这一步踩进已有隧道 → 收作终点（岔口），不再继续
                if (allowMerge && tunnel.Contains(ny * w + nx) && !visited.Contains(ny * w + nx))
                { mergeDir = i; break; }
                if (tunnel.Contains(ny * w + nx)) continue;              // 第一步：隧道格直接不可选
                if (visited.Contains(ny * w + nx)) continue;
                if (prev.x >= 0 && nx == prev.x && ny == prev.y) continue;   // (a) 禁原地后退
                // (b) ★禁并线：数新格周边"**别的**隧道"的邻居数。
                //     · 排除 cur（上一步本身，不是"另一条隧道"）
                //     · 排除**本次游走自己走过的格**（visited）—— 自避游走会拐回来贴着
                //       自己几格前的身位，那是同一条隧道在盘旋，不是两条隧道并线
                int adjTunnel = 0;
                HexDirs(nx, out int[] ndx, out int[] ndy);
                for (int k = 0; k < HexNeighborCount; k++)
                {
                    int ax = nx + ndx[k], ay = ny + ndy[k];
                    if (ax < 0 || ay < 0 || ax >= w || ay >= h) continue;
                    if (ax == cur.x && ay == cur.y) continue;            // 上一步
                    if (visited.Contains(ay * w + ax)) continue;         // 本游走自己
                    if (tunnel.Contains(ay * w + ax)) adjTunnel++;
                }
                if (adjTunnel >= ADJ_TUNNEL_LIMIT) continue;
                cand.Add(i);
                candD.Add(HexDist(new Vector2Int(nx, ny), to));
            }

            // ★★第一步没有合法候选（起点被自己的隧道邻居围住）→ 放宽：
            //    允许"背对隧道"生长一步，即只求 adjTunnel 最小的那一格。
            //    没有这一步，网段会在原地全部走空（实测 100/100）。
            if (cand.Count == 0 && !allowMerge)
            {
                int bestAdj = int.MaxValue;
                for (int i = 0; i < HexNeighborCount; i++)
                {
                    int nx = cur.x + dxs[i], ny = cur.y + dys[i];
                    if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) continue;
                    if (Def(biomeOf[nx, ny]).id != BiomeId.Cave) continue;
                    if (tunnel.Contains(ny * w + nx)) continue;
                    if (visited.Contains(ny * w + nx)) continue;
                    int a = 0;
                    HexDirs(nx, out int[] qdx, out int[] qdy);
                    for (int k = 0; k < HexNeighborCount; k++)
                    {
                        int ax2 = nx + qdx[k], ay2 = ny + qdy[k];
                        if (ax2 < 0 || ay2 < 0 || ax2 >= w || ay2 >= h) continue;
                        if (ax2 == cur.x && ay2 == cur.y) continue;
                        if (visited.Contains(ay2 * w + ax2)) continue;
                        if (tunnel.Contains(ay2 * w + ax2)) a++;
                    }
                    if (a < bestAdj) { bestAdj = a; cand.Clear(); candD.Clear(); cand.Add(i); candD.Add(HexDist(new Vector2Int(nx, ny), to)); }
                }
            }

            int pick;
            if (mergeDir >= 0)
            {
                pick = mergeDir;                       // ★汇入已有隧道 → 结束本条
            }
            else
            {
                if (cand.Count == 0) break;            // 钻到死路 → 到此为止（本身就是死胡同）
                // 选向：78% 概率优先"离 to 更近"（软推进），否则纯随机
                if (rng.Next(100) < 78)
                {
                    int bd = int.MaxValue;
                    var best = new List<int>();
                    for (int k = 0; k < cand.Count; k++)
                    {
                        if (candD[k] < bd) { bd = candD[k]; best.Clear(); best.Add(k); }
                        else if (candD[k] == bd) best.Add(k);
                    }
                    pick = cand[best[rng.Next(best.Count)]];
                }
                else pick = cand[rng.Next(cand.Count)];
            }

            prev = cur;
            HexDirs(cur.x, out dxs, out dys);
            cur = new Vector2Int(cur.x + dxs[pick], cur.y + dys[pick]);
            visited.Add(cur.y * w + cur.x);

            if (mergeDir >= 0) break;                  // ★汇入即停

            // ★2~3 格宽：路径格本身 + 六向邻居一起挖（用户：「山洞太窄了，2-3格宽吧」）。
            //   半径取 1（六边形距离 ≤1 = 中心 + 6 邻居）→ 直道截面 3 格、拐角自然收成 2~3 格。
            DigCaveCell(g, biomeOf, cur.x, cur.y, rng, w, h, radius: 1);
            spine.Add(cur);
            tunnel.Add(cur.y * w + cur.x);
            allTunnel.Add(cur);
            if (HexDist(cur, to) == 0) break;
        }
        return spine;
    }

    /// <summary>在洞穴区域里从 a 钻一条狭长扭曲的隧道到 b（六向 · 真 1 格宽）。
    /// ★用户 2026-09-16：「几条狭长、扭曲隧道」「多来点斜着的」。
    /// 直接 a→b 的贪心路径在水平/垂直距离大时会退化成一条直线长条，所以改成
    /// **分段游走**：先把 a→b 拆成 2~4 段，每段终点在前进方向上随机偏移，
    /// 逐段再走六边形路径——这样隧道必然拐来拐去，而不是一条直走廊。</summary>
    private static void CarveCaveTunnel(char[,] g, BiomeId[,] biomeOf, Vector2Int from, Vector2Int to,
        System.Random rng, int w, int h)
    {
        int segs = 2 + rng.Next(3);                       // 2~4 段
        var waypoints = new List<Vector2Int>();
        for (int i = 1; i < segs; i++)
        {
            float t = i / (float)segs;
            int mx = Mathf.RoundToInt(from.x + (to.x - from.x) * t);
            int my = Mathf.RoundToInt(from.y + (to.y - from.y) * t);
            // 垂直于前进方向抖动 ±6 格：中段明显跑偏
            int ox = rng.Next(-6, 7), oy = rng.Next(-6, 7);
            waypoints.Add(new Vector2Int(mx + ox, my + oy));
        }
        waypoints.Add(to);

        var pts = new List<Vector2Int> { from };
        pts.AddRange(waypoints);
        for (int i = 0; i + 1 < pts.Count; i++)
        {
            var path = HexWalk(pts[i], pts[i + 1], rng, w, h, twist: 0.65f);
            if (path.Count == 0) path.Add(pts[i + 1]);
            foreach (Vector2Int p in path)
            {
                // ★2~3 格宽（用户 2026-09-16：「山洞的地图好像有点太窄了，2-3格宽吧」）——
                //   原先是严格 1 格宽，洞壁全靠山体，形态最狭长但玩家转不开身。
                //   现在同样用六向扩 1 圈；洞口那两格已在第 4 步单独开过口，这里不重复处理。
                int px = p.x, py = p.y;
                if (px < 1 || py < 1 || px >= w - 1 || py >= h - 1) continue;
                DigCaveCell(g, biomeOf, px, py, rng, w, h, radius: 1);
            }
        }
    }


    // ==================================================================
    // ★六边形网格工具（odd-q offset · 平顶）
    //   权威定义见 BattleSystem/CardExecutor.HexDistance（同一套坐标约定）：
    //     偶数列 x：邻居 (±1,0) (0,±1) (+1,-1) (-1,-1)
    //     奇数列 x：邻居 (±1,0) (0,±1) (+1,+1) (-1,+1)
    //   —— ASCII 方格里的"斜向"在六边形里就是合法邻居，所以路径不该锁成十字。
    // ==================================================================
    /// <summary>奇数列判定（odd-q：奇数列整体下移半格）。</summary>
    private static bool HexOddCol(int x) { return (x & 1) != 0; }

    /// <summary>返回 (x,y) 的 6 个六边形邻居方向偏移（含斜向）。</summary>
    private static void HexDirs(int x, out int[] dx, out int[] dy)
    {
        if (HexOddCol(x))
        {
            dx = new[] {  1, -1, 0,  0,  1, -1 };
            dy = new[] {  0,  0, 1, -1,  1,  1 };
        }
        else
        {
            dx = new[] {  1, -1, 0,  0,  1, -1 };
            dy = new[] {  0,  0, 1, -1, -1, -1 };
        }
    }

    private static int HexNeighborCount { get { return 6; } }

    /// <summary>六边形距离（与 CardExecutor.HexDistance 完全一致：offset → cube → max）。</summary>
    private static int HexDist(Vector2Int a, Vector2Int b)
    {
        int acx = a.x, acz = a.y - (a.x - (a.x & 1)) / 2;
        int bcx = b.x, bcz = b.y - (b.x - (b.x & 1)) / 2;
        int acy = -acx - acz, bcy = -bcx - bcz;
        return Mathf.Max(Mathf.Abs(bcx - acx), Mathf.Max(Mathf.Abs(bcy - acy), Mathf.Abs(bcz - acz)));
    }

    /// <summary>
    /// ★沿六边形 6 向从 a 走到 b 的路径（贪心 + 每步只选合法邻居）。
    /// 返回逐步坐标（含起点，不含终点后的格）。twist 越大越绕。
    /// ★惯性偏向：一旦决定绕行，会连续若干步保持同侧——否则每步独立掷骰会被贪心立刻拉回直线，
    ///   路径永远"看着是直的"（洞穴隧道要的正是持续的扭曲，用户 2026-09-16）。
    /// </summary>
    private static List<Vector2Int> HexWalk(Vector2Int a, Vector2Int b, System.Random rng,
        int w, int h, float twist)
    {
        var path = new List<Vector2Int>();
        Vector2Int cur = a;
        int guard = 0, maxSteps = (w + h) * 6;
        int biasDir = -1, biasLeft = 0;              // ★当前保持的绕行方向 / 剩余步数
        while ((cur.x != b.x || cur.y != b.y) && guard++ < maxSteps)
        {
            int[] dxs, dys; HexDirs(cur.x, out dxs, out dys);
            int bestD = int.MaxValue;
            var cand = new List<int>();
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = cur.x + dxs[i], ny = cur.y + dys[i];
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                int d = HexDist(new Vector2Int(nx, ny), b);
                if (d < bestD) { bestD = d; cand.Clear(); cand.Add(i); }
                else if (d == bestD) cand.Add(i);
            }
            if (cand.Count == 0) break;
            int pick = cand[rng.Next(cand.Count)];

            // ★惯性绕行：biasLeft > 0 时优先沿用 biasDir（若它仍让距离可控）
            if (biasLeft > 0 && biasDir >= 0)
            {
                int nx = cur.x + dxs[biasDir], ny = cur.y + dys[biasDir];
                if (nx >= 0 && ny >= 0 && nx < w && ny < h
                    && HexDist(new Vector2Int(nx, ny), b) <= bestD + 3)
                {
                    pick = biasDir;
                    biasLeft--;
                }
                else { biasDir = -1; biasLeft = 0; }   // 走不通/离太远 → 放弃这次偏向
            }
            // 起一次新的绕行：选一个略偏离的方向，并保持 2~5 步
            else if (rng.NextDouble() < twist)
            {
                var alts = new List<int>();
                for (int i = 0; i < HexNeighborCount; i++)
                {
                    int nx = cur.x + dxs[i], ny = cur.y + dys[i];
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    int d = HexDist(new Vector2Int(nx, ny), b);
                    if (d <= bestD + 2) alts.Add(i);
                }
                if (alts.Count > 0)
                {
                    pick = alts[rng.Next(alts.Count)];
                    biasDir = pick;
                    biasLeft = 2 + rng.Next(4);           // ★连续 2~5 步同侧 → 真正弯出来
                }
            }
            cur = new Vector2Int(cur.x + dxs[pick], cur.y + dys[pick]);
            path.Add(cur);
        }
        return path;
    }

    // ==================================================================
    // 第 3 步：骨架（团块 + 通道）
    // ==================================================================
    private static List<Vector2Int> PickBlobCenters(System.Random rng, Settings s, int w, int h)
    {
        int margin = 6;
        float minSep = s.blobRadiusMax * 2.0f;
        int want = Mathf.Max(3, s.blobCount);

        var list = new List<Vector2Int>();
        int tries = 0;
        while (list.Count < want && tries < want * 80)
        {
            tries++;
            var p = new Vector2Int(rng.Next(margin, Mathf.Max(margin + 1, w - margin)),
                                   rng.Next(margin, Mathf.Max(margin + 1, h - margin)));
            bool ok = true;
            for (int i = 0; i < list.Count; i++)
                if (Vector2Int.Distance(p, list[i]) < minSep) { ok = false; break; }
            if (ok) list.Add(p);
        }
        if (list.Count == 0) list.Add(new Vector2Int(w / 2, h / 2));
        return list;
    }

    private static void CarveBlob(char[,] g, bool[,] skel, Vector2Int c, float rMin, float rMax,
        System.Random rng, int w, int h, BiomeId[,] biomeOf)
    {
        float r = Mathf.Lerp(rMin, rMax, (float)rng.NextDouble());
        // ★林地里"团块"（空地）必须小：密林要的是"树连着树、只留少量空隙"，
        //   默认 3.2~5.4 半径会挖出 30~90 格的大空地，直接把林子打成筛子。
        //   在密林/古林里把半径压到 45%（≈1.4~2.4，一格宽的小空地），
        //   走廊本身只有 halfW=1 宽，于是骨架在林中表现为"细路穿林"而不是"空地连着空地"。
        if (Def(biomeOf[c.x, c.y]).id == BiomeId.Jungle
            || Def(biomeOf[c.x, c.y]).id == BiomeId.AncientForest)
            r *= 0.45f;
        float phase = (float)rng.NextDouble() * 97f;
        int ri = Mathf.CeilToInt(r * 1.4f);

        for (int dy = -ri; dy <= ri; dy++)
        {
            for (int dx = -ri; dx <= ri; dx++)
            {
                int x = c.x + dx, y = c.y + dy;
                if (x < 0 || y < 0 || x >= w || y >= h) continue;
                float ang = Mathf.Atan2(dy, dx);
                float jitter = Mathf.PerlinNoise(phase, phase + Mathf.Abs(ang) * 2.2f);
                float rr = r * (0.80f + 0.34f * jitter);
                if (dx * dx + dy * dy > rr * rr) continue;
                g[x, y] = CH_PLAIN;
                skel[x, y] = true;
            }
        }
    }

    private static void CarveCorridor(char[,] g, bool[,] skel, Vector2Int a, Vector2Int b,
        int halfW, int w, int h, System.Random rng, BiomeId[,] biomeOf)
    {
        // ★走六边形 6 向路径（含斜向），不再是"先横后竖"的楼梯状直角
        var path = HexWalk(a, b, rng, w, h, twist: 0.30f);
        if (path.Count == 0) path.Add(b);

        // ★★林地里通道必须更窄（用户：「密林里面大部分是树」）：
        //   原实现每一步挖 (2*halfW+1)² 的**方块**（halfW=1 时是 3×3），
        //   沿路连续铺过去 → 林中被铲出一条 3 格宽的长带，这才是"空地"的真正来源。
        //   改为**沿路径逐格 1 格宽**（只挖路径本身 + 相邻 1 格，且只在该群系的林地里），
        //   让通道变成"细路穿林"。非林地群系照旧（要保持开阔路网）。
        bool inForest = false;
        for (int s = 0; s < path.Count; s++)
            if (Def(biomeOf[path[s].x, path[s].y]).id == BiomeId.Jungle
                || Def(biomeOf[path[s].x, path[s].y]).id == BiomeId.AncientForest) { inForest = true; break; }
        int effHalfW = inForest ? 0 : halfW;

        for (int s = 0; s < path.Count; s++)
        {
            int x = path[s].x, y = path[s].y;
            for (int dx = -effHalfW; dx <= effHalfW; dx++)
            {
                for (int dy = -effHalfW; dy <= effHalfW; dy++)
                {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    g[nx, ny] = CH_PLAIN;               // ★通道把骨架上的 # 挖穿（沼泽=浅滩，洞穴=隧道）
                    skel[nx, ny] = true;
                }
            }
        }
    }

    // ==================================================================
    // 第 4 步：林缘（只在配方里有 f 的群系生效）
    // ==================================================================
    /// <summary>
    /// ★密林/古林反向生成：整片先铺满 `f`，再挖出少量空地（用户 2026-09-16）。
    /// —— 密林要"树连着树、只留少量空隙"；空地是小块、彼此不成片的"缝"。
    /// 每个空地用一个半径 1.2~2.6 的不规则小团，数量按 `forestClearingRate` 控制；
    /// 空地面积上限约为区域面积的 `forestClearRatio`（默认 0.18 ≈ 留 18% 空地）。
    /// </summary>
    private static void CarveForestClearings(char[,] g, BiomeId[,] biomeOf, Settings s,
        System.Random rng, int w, int h)
    {
        foreach (BiomeId id in new[] { BiomeId.Jungle, BiomeId.AncientForest })
        {
            // 先全铺树（只改纯平地，不动水/墙/室内）
            int cells = 0;
            for (int y = 1; y < h - 1; y++)
                for (int x = 1; x < w - 1; x++)
                {
                    if (Def(biomeOf[x, y]).id != id) continue;
                    cells++;
                    if (g[x, y] == CH_PLAIN) g[x, y] = CH_FOREST;
                }
            if (cells == 0) continue;

            // 要挖出的空地总量（格）
            int budget = Mathf.RoundToInt(cells * s.forestClearRatio);
            int carved = 0, guard = 0;
            while (carved < budget && guard++ < cells)
            {
                int cx = rng.Next(2, Mathf.Max(3, w - 2));
                int cy = rng.Next(2, Mathf.Max(3, h - 2));
                if (Def(biomeOf[cx, cy]).id != id) continue;
                if (g[cx, cy] != CH_FOREST) continue;

                float r = 1.2f + (float)rng.NextDouble() * 1.4f;      // 1.2~2.6：小空地，不成片
                float phase = (float)rng.NextDouble() * 97f;
                int ri = Mathf.CeilToInt(r);
                for (int dy = -ri; dy <= ri; dy++)
                    for (int dx = -ri; dx <= ri; dx++)
                    {
                        int x = cx + dx, y = cy + dy;
                        if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                        if (Def(biomeOf[x, y]).id != id) continue;
                        if (g[x, y] != CH_FOREST) continue;
                        float jitter = Mathf.PerlinNoise(phase, phase + Mathf.Abs(dy) * 1.7f);
                        float rr = r * (0.75f + 0.45f * jitter);
                        if (dx * dx + dy * dy > rr * rr) continue;
                        g[x, y] = CH_PLAIN;
                        carved++;
                    }
            }
        }
    }

    /// <summary>
    /// ★密林/古林"补树"（第 4b 步）——用户 2026-09-16：「密林里面大部分是树」。
    ///
    /// ★为什么光靠 2b 的 `CarveForestClearings` 不够：
    ///   2b 在骨架**之前**跑（整片铺树 → 挖空）。而第 3 步的 `CarveBlob` / `CarveCorridor`
    ///   会往路面写 `CH_PLAIN`，把密林中央挖出大块大块的"十字形空地"。
    ///   实测密林树占比只有 28%（平地 59%）——玩家看到的"空地"其实就是骨架路网，
    ///   而不是 2b 挖的那些"小缝"。
    ///
    /// ★做法：骨架之后，**把"周围树很密"的平地缝回 `f`**，只留下真正够窄的路。
    ///   判定用"六向邻居里已有多少树"：
    ///     · 邻居树 ≥ 3 → 一定是林中的缝 → 补回 `f`
    ///     · 邻居树 == 2 → 视作路缘，按 `edgeKeep` 概率补（让路有点毛边、不是光板）
    ///     · 邻居树 ≤ 1 → 认作真正的通路 → 保持 `f` 外的原样（可通行）
    ///   ★只动 `CH_PLAIN`，绝不动水/墙/室内/内容点，也不动 `skel` 里的格
    ///     （否则会把路网彻底堵死、内容点全不可达）。
    ///   ★补树必须**迭代 2 轮**：第 1 轮补出来的树会成为第 2 轮的邻居，
    ///     密度会从"路缘"向外扩散一格，形成更厚的林墙（单轮只能收一圈）。
    /// </summary>
    private static void RefillForest(char[,] g, BiomeId[,] biomeOf, bool[,] skel,
        System.Random rng, int w, int h)
    {
        foreach (BiomeId id in new[] { BiomeId.Jungle, BiomeId.AncientForest })
        {
            // ★古林本来就够密（约 45%），补太多会变成实心绿墙 → 阈值更高、只补一轮
            bool isJungle = id == BiomeId.Jungle;
            int minTreeNbr = isJungle ? 2 : 3;       // 补树门槛（邻居树数）
            int rounds = isJungle ? 3 : 2;
            float edgeKeep = isJungle ? 0.35f : 0.12f;

            for (int round = 0; round < rounds; round++)
            {
                var toForest = new List<Vector2Int>();
                for (int y = 1; y < h - 1; y++)
                    for (int x = 1; x < w - 1; x++)
                    {
                        if (Def(biomeOf[x, y]).id != id) continue;
                        if (g[x, y] != CH_PLAIN) continue;
                        if (skel[x, y]) continue;          // ★骨架路上的格不补（保连通与可达）

                        int treeNbr = 0;
                        int[] dxs, dys; HexDirs(x, out dxs, out dys);
                        for (int i = 0; i < HexNeighborCount; i++)
                        {
                            int nx = x + dxs[i], ny = y + dys[i];
                            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                            if (g[nx, ny] == CH_FOREST) treeNbr++;
                        }
                        if (treeNbr >= minTreeNbr) toForest.Add(new Vector2Int(x, y));
                        else if (treeNbr == minTreeNbr - 1 && rng.Next(100) < edgeKeep * 100)
                            toForest.Add(new Vector2Int(x, y));
                    }
                for (int i = 0; i < toForest.Count; i++) g[toForest[i].x, toForest[i].y] = CH_FOREST;
            }
        }
    }

    private static void ApplySkeletonFringe(char[,] g, BiomeId[,] biomeOf, bool[,] skel, int w, int h)
    {
        var toForest = new List<Vector2Int>();

        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                if (skel[x, y]) continue;
                if (g[x, y] != CH_PLAIN) continue;
                BiomeDef bd = Def(biomeOf[x, y]);
                if (bd.id == BiomeId.Cave) continue;            // ★洞穴：山体里不长树
                if (bd.id == BiomeId.Grass) continue;            // ★草坡：口径＝"基本大平地"，不沿骨架铺树枝状绿带
                if (!bd.hasForest) continue;                     // 废墟/荒村/沼泽不铺林缘

                bool touching = false;
                for (int dy = -1; dy <= 1 && !touching; dy++)
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        if (skel[nx, ny]) { touching = true; break; }
                    }
                if (touching) toForest.Add(new Vector2Int(x, y));
            }
        }
        for (int i = 0; i < toForest.Count; i++) g[toForest[i].x, toForest[i].y] = CH_FOREST;
    }

    // ==================================================================
    // 第 5 步：各群系专属结构
    // ==================================================================
    private static void PlaceBiomeStructures(char[,] g, BiomeId[,] biomeOf, bool[,] occupied,
        System.Random rng, List<Vector2Int>[] regionCells, BiomeId[] drawn, int w, int h, bool[,] skel)
    {
        foreach (BiomeId id in drawn)
        {
            var cells = regionCells[(int)id];
            if (cells.Count == 0) continue;
            int area = cells.Count;

            switch (id)
            {
                case BiomeId.Grass:            // 草坡：散点巨石（唯一掩体）+ 少量枯树
                    ScatterStructures(g, biomeOf, occupied, cells, rng, 1, 1, Mathf.Max(2, area / 400), w, h);
                    break;
                case BiomeId.Jungle:           // 密林：无房——只有成片倒木（自然、杂乱）
                    ScatterStructures(g, biomeOf, occupied, cells, rng, 4, 1, Mathf.Max(4, area / 220), w, h);
                    break;
                case BiomeId.Cave:             // 洞穴：隧道已在第 2b 步钻出，不再撒散点结构
                    break;
                case BiomeId.Ruins:            // 废墟：★散点废屋 = 别的群系的标准房架扣几段墙（2026-09-16 口径，密度翻倍）+ 路边稀疏断壁
                    ScatterStructures(g, biomeOf, occupied, cells, rng, -1, -1, Mathf.Max(6, area / 350), w, h, RuinHouseFootprint);
                    ScatterRoadRuins(g, occupied, cells, rng, Mathf.Max(3, area / 500), w, h, skel);
                    ScatterRuinsWeeds(g, biomeOf, occupied, cells, rng, area, w, h);   // ★杂草：绿色点状分布
                    break;
                case BiomeId.AncientForest:    // 古林：树木规律分布（规整网格树）——不是随机的
                    ScatterPatternTrees(g, biomeOf, occupied, cells, rng, area, w, h);
                    break;
                case BiomeId.Swamp:            // 沼泽：地貌本身就是"破碎拼合"，不撒结构
                    break;
                case BiomeId.WildVillage:      // 荒村：稍完整的房舍（规整 # 框 + 大 _ 地板 + 门）
                    ScatterStructures(g, biomeOf, occupied, cells, rng, -1, -1, Mathf.Max(4, area / 260), w, h, HouseFootprint);
                    break;
            }
        }
    }

    /// <summary>古林：树木按规整间距落点（±1 抖动）——刻意区别于密林的杂乱。</summary>
    private static void ScatterPatternTrees(char[,] g, BiomeId[,] biomeOf, bool[,] occupied,
        List<Vector2Int> cells, System.Random rng, int area, int w, int h)
    {
        var inRegion = new HashSet<Vector2Int>(cells);
        int spacing = 3 + rng.Next(2);                 // 规则网格间距
        int ox = rng.Next(spacing), oy = rng.Next(spacing);
        for (int gy = oy; gy < h; gy += spacing)
        {
            for (int gx = ox; gx < w; gx += spacing)
            {
                int x = gx + rng.Next(3) - 1;          // ±1 抖动：看得出是人造的规律，但不呆板
                int y = gy + rng.Next(3) - 1;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                var p = new Vector2Int(x, y);
                if (!inRegion.Contains(p)) continue;
                if (occupied[p.x, p.y]) continue;
                if (g[x, y] != CH_PLAIN && g[x, y] != CH_FOREST) continue;   // ★出生点/内容点不会被树盖掉
                if (rng.Next(100) < 45)                    // 留些空位，避免板正的棋盘感
                {
                    g[x, y] = CH_WALL;
                    MarkOccupied(occupied, p, 0, w, h);    // ★只登记树本身——整片林子都登记会把据点位置挤光
                }
            }
        }
    }

    /// <summary>矩形/线性小结构撒点。w×h>0 = 线性条；否则用 footprint 回调画。</summary>
    private static void ScatterStructures(char[,] g, BiomeId[,] biomeOf, bool[,] occupied,
        List<Vector2Int> cells, System.Random rng, int rw, int rh, int count, int w, int h,
        Action<char[,], Vector2Int, System.Random, int, int> footprint = null)
    {
        int placed = 0, tries = 0, maxTries = count * 40;
        while (placed < count && tries < maxTries)
        {
            tries++;
            Vector2Int p = cells[rng.Next(cells.Count)];
            if (occupied[p.x, p.y]) continue;
            if (g[p.x, p.y] == CH_SPAWN) continue;               // ★别把出生点当落点
            if (IsNearOccupied(occupied, p, 2, w, h)) continue;

            if (footprint != null)
            {
                footprint(g, p, rng, w, h);
                MarkOccupied(occupied, p, 2, w, h);   // ★登记半径 2（半径 4 会把整片区域占满，据点没地方落）
            }
            else
            {
                int len = Mathf.Max(2, rw + rng.Next(2));
                bool horiz = rng.Next(2) == 0;
                for (int i = 0; i < len; i++)
                {
                    int x = p.x + (horiz ? i : 0), y = p.y + (horiz ? 0 : i);
                    if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) break;
                    if (g[x, y] == CH_SPAWN) continue;                   // ★不压出生点（跳过该格，不 break）
                    g[x, y] = CH_WALL;
                }
                MarkOccupied(occupied, p, 1, w, h);
            }
            placed++;
        }
    }

    /// <summary>
    /// ★废墟残墙：只画"一段断墙"（直线段 + 随机折断），**不再是成形房屋**。
    /// 用户 2026-09-16：「废墟里面应该是断垣残恒，是完全支离破碎的，不会有现在这么完整的房子」。
    /// </summary>
    private static void RuinFootprint(char[,] g, Vector2Int c, System.Random rng, int w, int h)
    {
        // 随机一段墙：长 3~7，方向按六边形 6 向之一
        int[] dxs, dys; HexDirs(c.x, out dxs, out dys);
        int d = rng.Next(6);
        int len = 3 + rng.Next(5);
        for (int i = 0; i < len; i++)
        {
            int x = c.x + dxs[d] * i, y = c.y + dys[d] * i;
            if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) break;
            if (g[x, y] == CH_SPAWN || g[x, y] == CH_INDOOR) continue;
            if (rng.Next(100) < 78) g[x, y] = CH_WALL;            // 折断：22% 缺格，墙不连续
        }
        // 有时再拐一小段（成 L 形残角，仍不成形）
        if (rng.Next(100) < 45)
        {
            int d2 = (d + 2 + rng.Next(3)) % 6;
            int len2 = 2 + rng.Next(3);
            for (int i = 1; i <= len2; i++)
            {
                int x = c.x + dxs[d2] * i, y = c.y + dys[d2] * i;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) break;
                if (g[x, y] == CH_SPAWN || g[x, y] == CH_INDOOR) continue;
                if (rng.Next(100) < 70) g[x, y] = CH_WALL;
            }
        }
    }

    /// <summary>★废墟塌石堆：2~4 格零散 `#`（倒下来的石块/柱础，堵路但不连片）。</summary>
    private static void RubbleFootprint(char[,] g, Vector2Int c, System.Random rng, int w, int h)
    {
        int n = 2 + rng.Next(3);
        for (int i = 0; i < n; i++)
        {
            int x = c.x + rng.Next(3) - 1, y = c.y + rng.Next(3) - 1;
            if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] == CH_SPAWN || g[x, y] == CH_INDOOR) continue;
            if (g[x, y] == CH_PLAIN) g[x, y] = CH_WALL;
        }
    }

    /// <summary>
    /// ★废墟杂草：`f`（树林格）以**零散点状**撒进废墟——不是成片绿块，是缝隙里长出来的草。
    /// 用户 2026-09-16：「同时也杂草丛生，绿色点应该是点状分布」。
    /// </summary>
    private static void ScatterRuinsWeeds(char[,] g, BiomeId[,] biomeOf, bool[,] occupied,
        List<Vector2Int> cells, System.Random rng, int area, int w, int h)
    {
        int want = Mathf.Max(30, area / 22);       // 点很多、每个点很小
        int placed = 0, tries = 0, maxTries = want * 30;
        while (placed < want && tries < maxTries)
        {
            tries++;
            Vector2Int p = cells[rng.Next(cells.Count)];
            if (p.x < 1 || p.y < 1 || p.x >= w - 1 || p.y >= h - 1) continue;
            if (g[p.x, p.y] != CH_PLAIN) continue;              // 只长在空地上（不长进墙里）
            if (occupied[p.x, p.y]) continue;
            g[p.x, p.y] = CH_FOREST;
            placed++;
        }
    }

    /// <summary>荒村房舍：完整 # 框 + 1 个门 + 大 _ 地板。</summary>
    private static void HouseFootprint(char[,] g, Vector2Int c, System.Random rng, int w, int h)
    {
        int rw = 4 + rng.Next(3), rh = 3 + rng.Next(3);
        BuildFrame(g, c, rw, rh, rng, doorCount: 1, interior: CH_INDOOR, w, h);
    }

    /// <summary>大结构"房间"按主群系给不同形态——外观各群系不同（用户 2026-09-16 口径）。</summary>
    private static void BuildBigRoom(char[,] g, BiomeId[,] biomeOf, Vector2Int c, int rw, int rh,
        BiomeId id, System.Random rng, int w, int h, bool isFirst, bool isLast)
    {
        switch (id)
        {
            case BiomeId.Grass:
                // ★强盗大营：大围墙内几顶帐篷，末间是首领屋（唯一的完整房子）
                if (isLast) BuildFrame(g, c, rw, rh, rng, doorCount: 1, interior: CH_INDOOR, w, h);
                else BuildEncampment(g, c, rw, rh, rng, w, h, -1);
                break;

            case BiomeId.Ruins:
                // ★墓地：规整排列的墓碑（# 短条）+ 通道，末间是墓穴主室
                BuildGraveyard(g, c, rw, rh, rng, w, h, isLast);
                break;

            case BiomeId.AncientForest:
                // ★祭坛：一圈规整树阵围出中央石台，末间是主祭坛（中央台阶）
                BuildAltar(g, c, rw, rh, rng, w, h, isLast);
                break;

            case BiomeId.Swamp:
                // ★湖心岛：一圈水围出中心小岛，末间岛更大
                BuildLakeIsle(g, c, rw, rh, rng, w, h, isLast);
                break;

            case BiomeId.WildVillage:
                // ★地主大宅：整体框架大，内部隔成多间
                BuildBigHouse(g, c, rw, rh, rng, w, h, isLast);
                break;

            case BiomeId.Jungle:
                // ★巨树根腔（用户 2026-09-16：「密林一个就没有房子」）：
                //   没有房子，只有几株巨树的根盘错成腔室 + 骨堆；末间是主根腔（Boss 巢）
                BuildTreeRootHollow(g, c, rw, rh, rng, w, h, isLast);
                break;

            case BiomeId.Cave:
                // 洞穴大结构：房间即"腔室"（地板，四周山体）
                BuildFrame(g, c, rw, rh, rng, doorCount: isFirst ? 2 : 1, interior: CH_PLAIN, w, h);
                break;

            default:   // 兜底：规整围合（当前 7 群系均已单独分派，不会走到这里）
                BuildFrame(g, c, rw, rh, rng, doorCount: isFirst ? 2 : 1, interior: Def(id).interiorFloor, w, h);
                break;
        }
    }

    /// <summary>大结构房间之间走廊的地板字符（祭坛/墓地走石道，沼泽走浅滩）。</summary>
    private static char LinkFloor(BiomeId id)
    {
        switch (id)
        {
            case BiomeId.Cave:          return CH_PLAIN;      // 洞穴隧道是岩地
            case BiomeId.Swamp:         return CH_PLAIN;      // 沼泽的堤道
            case BiomeId.AncientForest: return CH_PLAIN;      // ★古林：露天林地小径（不该有室内地板）
            case BiomeId.Jungle:        return CH_PLAIN;      // ★密林：巨型根腔之间也是林地
            default:                    return CH_INDOOR;     // 人造/半人造结构走地板
        }
    }

    /// <summary>
    /// ★墓地（废墟大结构）：**露天**——荒草地 + 稀疏**孤立**墓碑（每块碑六向无其他 `#`）。
    /// 2026-09-16 用户反馈：成排密铺的墓碑会被墙体自动连接渲染成「一大片连起来的墙」→
    /// 改为散碑（彼此隔开，各自成孤立小碑），只有主墓区的石棺环是刻意成形的结构。
    /// </summary>
    private static void BuildGraveyard(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, bool isLast)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (edge) { g[x, y] = rng.Next(100) < 70 ? CH_WALL : CH_PLAIN; continue; }  // 围墙残缺
                g[x, y] = rng.Next(100) < 25 ? CH_FOREST : CH_PLAIN;   // 荒草点状
            }
        // 稀疏墓碑：随机落点，每块碑保证自身 + 六向邻居都没有别的 `#`（渲染成孤立小碑）
        int tombs = Mathf.Max(3, rw * rh / 18);
        for (int k = 0; k < tombs * 10 && tombs > 0; k++)
        {
            int dx = 1 + rng.Next(Mathf.Max(1, rw - 1));
            int dy = 1 + rng.Next(Mathf.Max(1, rh - 1));
            int x = x0 + dx, y = y0 + dy;
            if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] != CH_PLAIN && g[x, y] != CH_FOREST) continue;
            if (!IsolatedWallSpot(g, x, y, w, h)) continue;
            g[x, y] = CH_WALL;
            tombs--;
        }
        if (isLast)   // 主墓区：中央清空，一圈石棺（# 小环——墓园里唯一成形的结构）
        {
            for (int dy = -3; dy <= 3; dy++)
                for (int dx = -3; dx <= 3; dx++)
                {
                    int x = c.x + dx, y = c.y + dy;
                    if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                    if (g[x, y] == CH_SPAWN) continue;
                    g[x, y] = CH_PLAIN;
                }
            for (int a = 0; a < 12; a++)
            {
                float ang = a / 12f * Mathf.PI * 2f;
                int x = c.x + Mathf.RoundToInt(Mathf.Cos(ang) * 2.0f);
                int y = c.y + Mathf.RoundToInt(Mathf.Sin(ang) * 1.7f);
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = CH_WALL;                                  // 石棺 / 祭台
            }
        }
    }

    /// <summary>(x,y) 及其 3×3 邻域（含六向）是否都没有 `#`——孤立墓碑/孤石的落点判据。</summary>
    private static bool IsolatedWallSpot(char[,] g, int x, int y, int w, int h)
    {
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++)
            {
                int nx = x + dx, ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                if (g[nx, ny] == CH_WALL) return false;
            }
        return true;
    }

    /// <summary>★祭坛（古林大结构）：一圈规整树阵围出中央**露天**石台（没有 `_` 室内地板）。</summary>
    private static void BuildAltar(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, bool isLast)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        // 内部＝露天林地空地（.），不是室内地板
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = CH_PLAIN;
            }
        // 外圈：等距树阵（每 2 格一棵，留 2 个入口）
        int gapA = rng.Next(4), gapB = (gapA + 2) % 4;
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                int side = dy == 0 ? 0 : (dx == rw ? 1 : (dy == rh ? 2 : 3));
                if (side == gapA || side == gapB) { g[x, y] = CH_PLAIN; continue; }   // 入口
                bool onGrid = (dx % 2 == 0) || (dy % 2 == 0);
                g[x, y] = onGrid ? CH_WALL : CH_FOREST;
            }
        if (isLast)   // 主祭坛：中央台阶（# 围一圈，中心留空地）
        {
            int mx = c.x, my = c.y;
            for (int a = 0; a < 16; a++)
            {
                float ang = a / 16f * Mathf.PI * 2f;
                int x = mx + Mathf.RoundToInt(Mathf.Cos(ang) * 2.5f);
                int y = my + Mathf.RoundToInt(Mathf.Sin(ang) * 2.0f);
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = CH_WALL;
            }
        }
    }

    /// <summary>★湖心岛：一圈水围出中心小岛（岛 = 平地，水 = 3AP 慢地）。</summary>
    /// <summary>
    /// ★湖心岛（沼泽大结构 Boss 位）：地表**相对完整**的湖心岛。
    /// 用户 2026-09-16：「boss 大结构可以是一个地表相对完整的湖心岛」。
    /// ——环湖水域要明确（水圈成环、不留破口），岛面干净（平地为主 + 少量石台/枯树），
    ///   末间（Boss 位）岛面更大、中央一圈石台。整岛靠**一条栈桥**与岸连通。
    /// </summary>
    private static void BuildLakeIsle(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, bool isLast)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        int cx = c.x, cy = c.y;
        float isleR = Mathf.Max(2.2f, Mathf.Min(rw, rh) * 0.40f) + (isLast ? 1.6f : 0f);
        // ★环湖水带要有明确厚度（否则沼泽本就到处是水，岛与水融成一片、看不出"湖心岛"）
        float waterR = isleR + (isLast ? 2.6f : 2.0f);

        // 1) 先整体铺水（成环），再在中心填出岛 —— 保证"湖心岛"的水圈是完整闭环
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                float d = Vector2Int.Distance(new Vector2Int(x, y), new Vector2Int(cx, cy));
                if (d <= isleR)
                {
                    // 岛面：平地为主，岛缘一点沙洲感（树），**保持"相对完整"**
                    g[x, y] = (d > isleR - 1.2f && rng.Next(100) < 34) ? CH_FOREST : CH_PLAIN;
                }
                else if (d <= waterR)
                {
                    g[x, y] = CH_WATER;                                  // ★环湖水带（厚度明确）
                }
                // waterR 之外不动：保留沼泽原有地貌（水洼/树/平地），岛才有"嵌在湿地里的感觉"
            }

        // 2) 岛面细节：少量石台（#，天然礁石）+ 枯树，别把岛面搞碎（保持"相对完整"）
        int rocks = 1 + rng.Next(3) + (isLast ? 2 : 0);
        for (int k = 0; k < rocks; k++)
        {
            float ang = (float)(rng.NextDouble() * Mathf.PI * 2.0);
            float rr = (float)(rng.NextDouble() * isleR * 0.72);
            int x = cx + Mathf.RoundToInt(Mathf.Cos(ang) * rr);
            int y = cy + Mathf.RoundToInt(Mathf.Sin(ang) * rr);
            if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] == CH_SPAWN || g[x, y] == CH_WATER) continue;
            g[x, y] = CH_WALL;
        }
        if (isLast)   // 末间＝Boss 位：中央一圈石台（祭台/巢座），岛面最大
        {
            for (int a = 0; a < 12; a++)
            {
                float ang = a / 12f * Mathf.PI * 2f;
                int x = cx + Mathf.RoundToInt(Mathf.Cos(ang) * 2.0f);
                int y = cy + Mathf.RoundToInt(Mathf.Sin(ang) * 1.7f);
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN || g[x, y] == CH_WATER) continue;
                g[x, y] = CH_WALL;
            }
        }

        // 3) 一条栈桥（1 格宽）穿过水带连到岸 —— 保证可达（沿六边形 6 向选最短出水方向）
        int[] dxs, dys; HexDirs(cx, out dxs, out dys);
        int bestDir = -1, bestLen = int.MaxValue;
        for (int d = 0; d < HexNeighborCount; d++)
        {
            int len = 0;
            int x = cx, y = cy;
            while (len < Mathf.Max(rw, rh) * 2)
            {
                x += dxs[d]; y += dys[d]; len++;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) { len = int.MaxValue; break; }
                if (g[x, y] != CH_WATER) break;      // 出水 = 到岸
            }
            if (len < bestLen) { bestLen = len; bestDir = d; }
        }
        if (bestDir >= 0 && bestLen != int.MaxValue)
        {
            int x = cx, y = cy;
            for (int step = 0; step <= bestLen; step++)
            {
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) break;
                if (g[x, y] == CH_WATER) g[x, y] = CH_PLAIN;          // 栈桥
                x += dxs[bestDir]; y += dys[bestDir];
            }
        }
    }

    /// <summary>
    /// ★巨树根腔（密林大结构）：没有房子。
    ///   外围 = 一圈盘根错节的断巨石（# 断续围合，天然开口）；
    ///   内部 = 踩平的林地（.）+ 骨堆（散点 #，表示"这里吃过东西"）；
    ///   末间 = 主根腔：更空、更大的腔体，中央一株巨树树心（环形根盘）＝ Boss 巢。
    /// </summary>
    private static void BuildTreeRootHollow(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, bool isLast)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        // 外围盘根：断续的巨石（78% 密 → 有天然的"漏水口"，不是规整围墙）
        int gapA = rng.Next(4), gapB = (gapA + 2) % 4;
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                int side = dy == 0 ? 0 : (dx == rw ? 1 : (dy == rh ? 2 : 3));
                if (side == gapA || side == gapB) { g[x, y] = CH_PLAIN; continue; }   // 天然入口
                if (rng.Next(100) < 78) g[x, y] = CH_WALL;
            }
        // 内部：踩平的林地 + 骨堆
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = rng.Next(100) < (isLast ? 4 : 12) ? CH_WALL : CH_PLAIN;
            }
        // 主根腔：中央巨树树心——一圈环形根盘（# 环），环内是裸露的树心空地
        if (isLast)
        {
            int mx = c.x, my = c.y;
            for (int a = 0; a < 18; a++)
            {
                float ang = a / 18f * Mathf.PI * 2f;
                int x = mx + Mathf.RoundToInt(Mathf.Cos(ang) * 2.6f);
                int y = my + Mathf.RoundToInt(Mathf.Sin(ang) * 2.2f);
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                if (rng.Next(100) < 82) g[x, y] = CH_WALL;                              // 根盘（有缺口）
            }
        }
    }

    /// <summary>
    /// ★古林·祭祀空地（据点形态）：没有房子——一圈树（`#`，天然不规则）围出林间空地，
    /// 中央用石头摆一个露天祭坛（环形石台 + 中心石）。用户 2026-09-16：
    /// 「古林应该是没有房子的，只有几个树木围成的空地，里面有祭坛什么的，是那种露天祭坛」。
    /// </summary>
    private static void BuildGroveAltar(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, int forcedSide)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        int gapA = (forcedSide >= 0) ? forcedSide : rng.Next(4);
        int gapB = (gapA + 2) % 4;
        // 一圈树围（不规则：树是点，不是墙线；留 2 个缺口当出入口）
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                int side = dy == 0 ? 0 : (dx == rw ? 1 : (dy == rh ? 2 : 3));
                if (side == gapA || side == gapB) { g[x, y] = CH_PLAIN; continue; }   // 入口
                // 树不是密排：约 70% 成活，且树上/树间保留缝隙
                if (rng.Next(100) < 70) g[x, y] = CH_WALL;
            }
        // 内部：全部踩平（空地）
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = CH_PLAIN;
            }
        // 中央露天祭坛：一圈石台（# 环）+ 中心一块立石
        int mx = c.x, my = c.y;
        for (int a = 0; a < 14; a++)
        {
            float ang = a / 14f * Mathf.PI * 2f;
            int x = mx + Mathf.RoundToInt(Mathf.Cos(ang) * 1.9f);
            int y = my + Mathf.RoundToInt(Mathf.Sin(ang) * 1.6f);
            if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] == CH_SPAWN) continue;
            if (rng.Next(100) < 80) g[x, y] = CH_WALL;
        }
    }

    /// <summary>
    /// ★废墟·废屋（普通据点）——2026-09-16 用户口径推翻旧做法：
    /// 「直接使用别的群系的结构的房子，然后扣掉几格一个就行了」。
    /// 做法：标准房架（BuildFrame：# 框 + 1 门朝骨架路 + _ 地板，与荒村村舍同构），
    /// 再从外墙随机扣掉 2~5 格（只扣边中段，四角保留——留得住"这是个房子"的轮廓）。
    /// </summary>
    private static void BuildRuinCourt(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, int forcedSide)
    {
        BuildFrame(g, c, rw, rh, rng, doorCount: 1, interior: CH_INDOOR, w, h, forcedSide);

        // 扣墙：2~3 段塌墙（每段连续 2~3 格）
        KnockWalls(g, c, rw, rh, rng, 2 + rng.Next(2), w, h);
    }

    /// <summary>
    /// ★塌墙：随机挑 chunks 条边，各抠**连续 2~3 格**（像塌掉的一段墙，不是散点小洞）。
    /// 只抠边中段（不扣四角），保证残架仍看得出房屋轮廓。废墟据点庭院 / 散点废屋共用。
    /// </summary>
    private static void KnockWalls(char[,] g, Vector2Int c, int rw, int rh, System.Random rng, int chunks, int w, int h)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        for (int s = 0; s < chunks; s++)
        {
            int side = rng.Next(4);
            int len = 2 + rng.Next(2);                       // 连续 2~3 格
            if (side == 0 || side == 2)                      // 上 / 下边
            {
                int maxStart = rw - 1 - len;
                if (maxStart < 1) continue;
                int dx0 = 1 + rng.Next(maxStart);
                for (int k = 0; k < len; k++)
                    ClearWall(g, x0 + dx0 + k, side == 0 ? y0 : y0 + rh, w, h);
            }
            else                                             // 左 / 右边
            {
                int maxStart = rh - 1 - len;
                if (maxStart < 1) continue;
                int dy0 = 1 + rng.Next(maxStart);
                for (int k = 0; k < len; k++)
                    ClearWall(g, side == 1 ? x0 + rw : x0, y0 + dy0 + k, w, h);
            }
        }
    }

    /// <summary>边界内且是墙 → 扒成平地（塌墙用）。</summary>
    private static void ClearWall(char[,] g, int x, int y, int w, int h)
    {
        if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) return;
        if (g[x, y] == CH_WALL) g[x, y] = CH_PLAIN;
    }

    /// <summary>
    /// ★废墟散点废屋（2026-09-16 用户口径）：「直接使用别的群系的结构的房子，然后扣掉几格一个就行了」——
    /// 即标准房架（与荒村 HouseFootprint 同一套 BuildFrame），再随机抠 2~4 格边中段墙。
    /// </summary>
    private static void RuinHouseFootprint(char[,] g, Vector2Int c, System.Random rng, int w, int h)
    {
        int rw = 4 + rng.Next(3), rh = 3 + rng.Next(3);
        BuildFrame(g, c, rw, rh, rng, doorCount: 1, interior: CH_INDOOR, w, h);
        KnockWalls(g, c, rw, rh, rng, 1 + rng.Next(2), w, h);   // 1~2 段塌墙（每段连续 2~3 格）
    }

    /// <summary>
    /// ★废墟：沿骨架路稀疏撒断垣残壁（1~2 格 `#`，不连片、不成形）。
    /// 用户 2026-09-16：「例如路上稍微放一点断垣残壁看看」。
    /// </summary>
    private static void ScatterRoadRuins(char[,] g, bool[,] occupied, List<Vector2Int> cells,
        System.Random rng, int count, int w, int h, bool[,] skel)
    {
        // 候选：群系内、离骨架路 ≤2 格的平地
        var candidates = new List<Vector2Int>();
        foreach (var p in cells)
        {
            if (p.x < 2 || p.y < 2 || p.x >= w - 2 || p.y >= h - 2) continue;
            if (g[p.x, p.y] != CH_PLAIN) continue;
            if (occupied[p.x, p.y]) continue;
            if (NearSkeleton(skel, p, 2, w, h)) candidates.Add(p);
        }
        if (candidates.Count == 0) return;

        int placed = 0, tries = 0;
        while (placed < count && tries < count * 30)
        {
            tries++;
            var p = candidates[rng.Next(candidates.Count)];
            if (occupied[p.x, p.y]) continue;
            g[p.x, p.y] = CH_WALL;
            MarkOccupied(occupied, p, 1, w, h);   // 半径 1：断壁可以贴得较近，但不叠
            // 偶尔多带 1 格：像一段真的断掉的墙
            if (rng.Next(100) < 40)
            {
                int[] dxs, dys; HexDirs(p.x, out dxs, out dys);
                int d = rng.Next(6);
                int x = p.x + dxs[d], y = p.y + dys[d];
                if (x >= 1 && y >= 1 && x < w - 1 && y < h - 1
                    && g[x, y] == CH_PLAIN && !occupied[x, y])
                {
                    g[x, y] = CH_WALL;
                    MarkOccupied(occupied, new Vector2Int(x, y), 0, w, h);
                }
            }
            placed++;
        }
    }

    /// <summary>骨架路（skel）是否在 p 的 maxDist 六边形距离内。</summary>
    private static bool NearSkeleton(bool[,] skel, Vector2Int p, int maxDist, int w, int h)
    {
        for (int dy = -maxDist; dy <= maxDist; dy++)
            for (int dx = -maxDist; dx <= maxDist; dx++)
            {
                int x = p.x + dx, y = p.y + dy;
                if (x < 0 || y < 0 || x >= w || y >= h) continue;
                if (skel[x, y] && HexDist(p, new Vector2Int(x, y)) <= maxDist) return true;
            }
        return false;
    }

    /// <summary>★地主大宅：大框架 + 内部隔墙分成多间（每间留门）。</summary>
    private static void BuildBigHouse(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, bool isLast)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        // 先铺内部地板
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = CH_INDOOR;
            }
        // 外墙 + 大门
        int doorX = x0 + rw / 2;
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = (x == doorX && dy == rh) ? CH_PLAIN : CH_WALL;
            }
        // 内部隔墙：横竖各一道，各留一个门（宅子被分成 4 间）
        int midY = y0 + rh / 2, midX = x0 + rw / 2;
        for (int dx = 1; dx < rw; dx++)
        {
            int x = x0 + dx, y = midY;
            if (x == midX || x == midX + 1) continue;             // 留门
            if (y < 1 || x < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] == CH_SPAWN) continue;
            g[x, y] = CH_WALL;
        }
        for (int dy = 1; dy < rh; dy++)
        {
            if (dy == 1 || dy == rh - 1) continue;                // 留门
            int x = midX, y = y0 + dy;
            if (y < 1 || x < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] == CH_SPAWN) continue;
            g[x, y] = CH_WALL;
        }
    }

    /// <summary>
    /// # 框 + 指定数量门缺口 + 内部地板。
    /// forcedSide（0 上 / 1 右 / 2 下 / 3 左）：第一个门开在这一侧——据点用它把门朝向最近的骨架路。
    /// ★任何格都不覆盖出生点 'S'。
    /// </summary>
    private static void BuildFrame(char[,] g, Vector2Int c, int rw, int rh, System.Random rng,
        int doorCount, char interior, int w, int h, int forcedSide = -1)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        var doors = new HashSet<Vector2Int>();
        for (int i = 0; i < doorCount; i++)
        {
            int side = (i == 0 && forcedSide >= 0) ? forcedSide : rng.Next(4);
            if (side == 0) doors.Add(new Vector2Int(x0 + rng.Next(1, Mathf.Max(2, rw)), y0));
            else if (side == 1) doors.Add(new Vector2Int(x0 + rw, y0 + rng.Next(1, Mathf.Max(2, rh))));
            else if (side == 2) doors.Add(new Vector2Int(x0 + rng.Next(1, Mathf.Max(2, rw)), y0 + rh));
            else doors.Add(new Vector2Int(x0, y0 + rng.Next(1, Mathf.Max(2, rh))));
        }

        for (int dy = 0; dy <= rh; dy++)
        {
            for (int dx = 0; dx <= rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;                       // ★保护出生点
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (edge)
                {
                    if (doors.Contains(new Vector2Int(x, y))) g[x, y] = CH_PLAIN;   // 门 = 缺口
                    else g[x, y] = CH_WALL;
                }
                else g[x, y] = interior;
            }
        }
    }

    /// <summary>最近骨架格相对 p 的方向 → BuildFrame 的边编号（0 上 / 1 右 / 2 下 / 3 左）。找不到 = -1。</summary>
    private static int NearestSkeletonSide(bool[,] skel, Vector2Int p, int w, int h)
    {
        int bestD = int.MaxValue;
        int dx = 0, dy = 0;
        for (int y = Mathf.Max(1, p.y - 14); y < Mathf.Min(h - 1, p.y + 15); y++)
            for (int x = Mathf.Max(1, p.x - 14); x < Mathf.Min(w - 1, p.x + 15); x++)
            {
                if (!skel[x, y]) continue;
                int d = Mathf.Abs(x - p.x) + Mathf.Abs(y - p.y);
                if (d < bestD) { bestD = d; dx = x - p.x; dy = y - p.y; }
            }
        if (bestD == int.MaxValue) return -1;
        if (Mathf.Abs(dx) >= Mathf.Abs(dy)) return dx >= 0 ? 1 : 3;
        return dy >= 0 ? 2 : 0;
    }

    private static bool IsNearOccupied(bool[,] occupied, Vector2Int p, int r, int w, int h)    {
        for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++)
            {
                int x = p.x + dx, y = p.y + dy;
                if (x < 0 || y < 0 || x >= w || y >= h) continue;
                if (occupied[x, y]) return true;
            }
        return false;
    }

    private static void MarkOccupied(bool[,] occupied, Vector2Int p, int r, int w, int h)
    {
        for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++)
            {
                int x = p.x + dx, y = p.y + dy;
                if (x < 0 || y < 0 || x >= w || y >= h) continue;
                occupied[x, y] = true;
            }
    }

    // ==================================================================
    // 第 6 步：边界收口
    // ==================================================================
    private static void ApplyRim(char[,] g, BiomeId[,] biomeOf, int t, int w, int h)
    {
        if (t <= 0) return;
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int d = Mathf.Min(Mathf.Min(x, w - 1 - x), Mathf.Min(y, h - 1 - y));
                if (d >= t) continue;
                if (g[x, y] == CH_SPAWN) continue;                            // ★别把出生点收进林/崖/水里

                BiomeDef def = Def(biomeOf[x, y]);
                if (def.id == BiomeId.Cave) g[x, y] = CH_WALL;               // 洞穴：外圈全是山体
                else if (def.id == BiomeId.Swamp) g[x, y] = CH_WATER;        // 沼泽：外圈是水
                else if (def.id == BiomeId.Grass) g[x, y] = CH_FOREST;       // ★草坡：边缘收成林地（腹地仍是开阔大平地）
                else if (def.hasForest)
                {
                    float n = Mathf.PerlinNoise(x * 0.21f + 13.7f, y * 0.21f + 71.3f);
                    g[x, y] = (d == 0 && n > 0.46f && !def.hasRock) ? CH_WATER : CH_FOREST;
                }
                else if (def.hasWater && !def.hasRock) g[x, y] = CH_WATER;
                // ★2026-09-16 用户：「地图边缘不要放红色，边缘照样正常生成」——
                //   废墟/荒村不再铺红墙崖边，边缘就是正常地形（什么都不做）
            }
        }
    }

    // ==================================================================
    // 第 7 步：据点（按群系给不同形态）
    // ==================================================================
    /// <summary>
    /// 据点形态按群系分派：
    ///   草坡＝大围墙圈起的简易帐篷营地（帐篷 = 2×2 _，中间一口火 F，首领住屋在角落）
    ///   密林＝兽巢（无房，只有围成一圈的巨石与骨堆）
    ///   其余＝规整围合 · 内部按群系配地板
    /// </summary>
    private static void BuildStronghold(char[,] g, BiomeId[,] biomeOf, Vector2Int c, int rw, int rh,
        BiomeId id, System.Random rng, int w, int h, int forcedSide, List<MatRect> matRects = null)
    {
        if (id == BiomeId.Grass)
        {
            // 首领屋是"房屋"不是栅栏：单独登记成建筑材质（先营地表后首领屋，首领屋覆盖优先生效）
            int[] hut = BuildEncampment(g, c, rw, rh, rng, w, h, forcedSide);
            if (matRects != null && hut != null)
                matRects.Add(new MatRect { x0 = hut[0], y0 = hut[1], rw = hut[2], rh = hut[3], matTag = MT_BUILDING });
            return;
        }
        if (id == BiomeId.Jungle)
        {
            BuildBeastDen(g, c, rw, rh, rng, w, h, forcedSide,
                hollow: true, openSides: forcedSide >= 0 ? forcedSide : rng.Next(4));
            return;
        }
        if (id == BiomeId.AncientForest)
        {
            // ★古林：没有房子——只有一圈树围出的空地，中间一个露天祭坛
            BuildGroveAltar(g, c, rw, rh, rng, w, h, forcedSide);
            return;
        }
        if (id == BiomeId.Ruins)
        {
            // ★废墟：被摧毁的城镇——仍看得出房屋结构（断墙 + 残存地板），但四处是豁口
            BuildRuinCourt(g, c, rw, rh, rng, w, h, forcedSide);
            return;
        }
        if (id == BiomeId.Swamp)
        {
            // ★沼泽：完全露天，没有任何房屋结构——一圈树桩/浮木围出的空地
            BuildSwampHollow(g, c, rw, rh, rng, w, h, forcedSide);
            return;
        }
        // 洞穴 / 荒村：洞穴内部＝洞厅平地，荒村＝规整房舍
        BuildFrame(g, c, rw, rh, rng, doorCount: 2, interior: Def(id).interiorFloor, w, h, forcedSide);
    }

    /// <summary>
    /// ★沼泽·树桩围地（普通据点）：**完全露天、没有任何房屋结构**。
    /// 用户 2026-09-16：「沼泽是露天的，没有房屋结构」。
    /// 一圈稀疏树桩/浮木（`f` 为主 + 点状 `#` 残木）围出的水洼空地，内部零建筑。
    /// </summary>
    private static void BuildSwampHollow(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, int forcedSide)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        int gapA = (forcedSide >= 0) ? forcedSide : rng.Next(4);
        int gapB = (gapA + 2) % 4;
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                int side = dy == 0 ? 0 : (dx == rw ? 1 : (dy == rh ? 2 : 3));
                if (side == gapA || side == gapB) continue;         // 两处豁口
                // 外围：树桩（f）为主 —— 沼泽的"围合"靠植被，不是墙
                if (rng.Next(100) < 62) g[x, y] = rng.Next(100) < 24 ? CH_WALL : CH_FOREST;
            }
        // 内部：露天水洼空地 —— 平地 + 局部浅水，**没有任何地板/房屋**
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN || g[x, y] == CH_INDOOR) continue;
                g[x, y] = rng.Next(100) < 26 ? CH_WATER : CH_PLAIN;  // 露天水洼
            }
        // 内部零星枯树（点状，不连片）
        int snags = 2 + rng.Next(3);
        for (int k = 0; k < snags; k++)
        {
            int x = x0 + 1 + rng.Next(Mathf.Max(1, rw - 1));
            int y = y0 + 1 + rng.Next(Mathf.Max(1, rh - 1));
            if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
            if (g[x, y] == CH_SPAWN) continue;
            g[x, y] = CH_FOREST;
        }
    }

    /// <summary>
    /// ★草坡·强盗营地：一圈大围墙 + 里面几顶简易帐篷（2×2 `_`）+ 中心篝火 + 角落首领屋。
    /// 围墙上留 2 个缺口（一个朝路）。
    /// ★墙恒 1 格厚：首领屋与围墙之间必须留 ≥1 格空隙（用户 2026-09-16：栅栏不能叠成一坨）。
    /// 返回首领屋的占地矩形（hx, hy, w, h）——供材质标签层把首领屋标成"建筑"而非栅栏。
    /// </summary>
    private static int[] BuildEncampment(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, int forcedSide)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        // 围墙（留 2 个门缺口）
        var doors = new HashSet<Vector2Int>();
        for (int i = 0; i < 2; i++)
        {
            int side = (i == 0 && forcedSide >= 0) ? forcedSide : rng.Next(4);
            if (side == 0) doors.Add(new Vector2Int(x0 + rng.Next(1, Mathf.Max(2, rw)), y0));
            else if (side == 1) doors.Add(new Vector2Int(x0 + rw, y0 + rng.Next(1, Mathf.Max(2, rh))));
            else if (side == 2) doors.Add(new Vector2Int(x0 + rng.Next(1, Mathf.Max(2, rw)), y0 + rh));
            else doors.Add(new Vector2Int(x0, y0 + rng.Next(1, Mathf.Max(2, rh))));
        }
        // 营地内部先全铺平地（帐篷之间是空地，不是室内）
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = CH_PLAIN;
            }
        // 围墙
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                g[x, y] = doors.Contains(new Vector2Int(x, y)) ? CH_PLAIN : CH_WALL;
            }
        // 帐篷：2×2 `_`，按营地面积撒（大围墙里得有一堆东西）
        int tents = 3 + rng.Next(3) + (rw * rh) / 90;
        for (int t = 0; t < tents; t++)
        {
            int tx = x0 + 1 + rng.Next(Mathf.Max(1, rw - 3));
            int ty = y0 + 1 + rng.Next(Mathf.Max(1, rh - 3));
            if (tx + 1 >= x0 + rw || ty + 1 >= y0 + rh) continue;
            if (tx < 1 || ty < 1 || tx + 1 >= w - 1 || ty + 1 >= h - 1) continue;   // ★边界检查
            bool blocked = false;
            for (int ddy = 0; ddy < 2; ddy++)
                for (int ddx = 0; ddx < 2; ddx++)
                {
                    char cc = g[tx + ddx, ty + ddy];
                    if (cc == CH_WALL || cc == CH_INDOOR || cc == CH_SPAWN) blocked = true;
                }
            if (blocked) continue;
            for (int ddy = 0; ddy < 2; ddy++)
                for (int ddx = 0; ddx < 2; ddx++) g[tx + ddx, ty + ddy] = CH_INDOOR;
        }
        // 首领屋：角落一栋小房（# 框 + _ 内部 + 1 门）——只有首领住屋子
        // ★与围墙留 ≥1 格空隙（rw≥8 / rh≥6 时收紧；草坡营地 rw12~15 / rh9~11 恒满足）
        bool flipX = rng.Next(2) == 0, flipY = rng.Next(2) == 0;
        int hx = rw >= 8 ? (flipX ? x0 + rw - 5 : x0 + 2) : x0 + 1;
        int hy = rh >= 6 ? (flipY ? y0 + rh - 4 : y0 + 2) : y0 + 1;
        BuildFrame(g, new Vector2Int(hx + 1, hy + 1), 3, 2, rng, doorCount: 1, interior: CH_INDOOR, w, h);
        return new[] { hx, hy, 4, 3 };
        // 中心篝火：营地的"人烟"标记（复用 F 字符）
        int cx = c.x, cy = c.y;
        if (cx > 1 && cy > 1 && cx < w - 1 && cy < h - 1 && g[cx, cy] == CH_PLAIN) g[cx, cy] = CH_BONFIRE;
    }

    /// <summary>
    /// ★密林·兽巢：没有房子——一圈巨石围出的空地 + 内部骨堆（散点 `#`）。
    /// hollow=true 时内部不铺骨堆（留给"根腔/洞穴"），并在 openSides 侧留一个明显开口
    /// （据点靠它朝向路网；大结构靠它当 Boss 房入口）。
    /// </summary>
    private static void BuildBeastDen(char[,] g, Vector2Int c, int rw, int rh,
        System.Random rng, int w, int h, int forcedSide, bool hollow = false, int openSides = -1)
    {
        int x0 = c.x - rw / 2, y0 = c.y - rh / 2;
        int gap1 = (openSides >= 0) ? openSides : rng.Next(4);
        int gap2 = (gap1 + 1 + rng.Next(2)) % 4;
        // 围一圈巨石（留 1~2 个缺口）——不是规整的墙，是天然的岩/树围
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                bool edge = dx == 0 || dy == 0 || dx == rw || dy == rh;
                if (!edge) continue;
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                int side = dy == 0 ? 0 : (dx == rw ? 1 : (dy == rh ? 2 : 3));
                if (side == gap1 || side == gap2) continue;              // 天然缺口
                if (rng.Next(100) < 78) g[x, y] = CH_WALL;               // 不连续：有些地方漏风
            }
        // 内部：骨堆（散点 #）＋ 一点空地；hollow = 只扫成空地（根腔）
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (g[x, y] == CH_SPAWN) continue;
                g[x, y] = (!hollow && rng.Next(100) < 12) ? CH_WALL : CH_PLAIN;   // 骨堆
            }
    }

    private static void PlaceStrongholds(char[,] g, BiomeId[,] biomeOf, bool[,] occupied,
        System.Random rng, List<Vector2Int>[] regionCells, WastelandLayout layout,
        Settings s, bool[,] skel, int w, int h)
    {
        foreach (BiomeId id in layout.drawnBiomes)
        {
            var cells = regionCells[(int)id];
            if (cells.Count == 0) continue;

            int count = s.strongholdBaseCount + (rng.Next(100) < s.strongholdExtraChancePct ? 1 : 0);
            BiomeDef def = Def(id);

            for (int n = 0; n < count; n++)
            {
                bool ok = false;
                for (int attempt = 0; attempt < 40 && !ok; attempt++)
                {
                    Vector2Int p = cells[rng.Next(cells.Count)];
                    if (p.x < 4 || p.y < 4 || p.x >= w - 5 || p.y >= h - 5) continue;
                    if (IsNearOccupied(occupied, p, 3, w, h)) continue;      // ★半径 3（原 4：结构密集的群系会找不到落位）
                    if (Distance(p, layout.spawnPos) < s.spawnClearRadius + 6) continue;

                    int rw = 5 + rng.Next(3), rh = 4 + rng.Next(2);
                    // ★草坡营地要比别人大（围墙 + 帐篷 + 角落首领屋 + 中心篝火，5×4 塞不下）
                    // ★草坡营地要比别人大（围墙里面得塞得下一堆帐篷；用户 2026-09-16：再大一点）
                    if (id == BiomeId.Grass) { rw += 7 + rng.Next(4); rh += 5 + rng.Next(3); }

                    // ★据点只落在自己的群系区域内：整个矩形（含框）都得是同群系，
                    //   否则据点会"探"到邻近群系里（用户 2026-09-16：古林区冒出米色房屋就是这原因）
                    if (!RectInBiome(biomeOf, p, rw, rh, id, w, h)) continue;

                    // 第一个门朝向最近的骨架路（玩家沿路走就能看到门），第二个门随机
                    int forcedSide = NearestSkeletonSide(skel, p, w, h);
                    // A 方案：先登记据点占地（营地墙材质），再建结构——首领屋在 BuildStronghold 内
                    // 追加自己的"建筑"矩形，后登记者覆盖优先生效（首领屋=房屋，不是栅栏）
                    layout.matRects.Add(new MatRect
                    {
                        x0 = p.x - rw / 2, y0 = p.y - rh / 2, rw = rw, rh = rh,
                        matTag = StrongholdMatTag(id)
                    });
                    BuildStronghold(g, biomeOf, p, rw, rh, id, rng, w, h, forcedSide, layout.matRects);

                    // 据点内含：C 1~2 + E 1 + x 驻守锚点 1~2（复用现有遭遇区链路，代码零改动）
                    var inner = InteriorCells(g, p, rw, rh, w, h);
                    PlaceInside(g, inner, rng, CH_CHEST, 1 + rng.Next(2));
                    PlaceInside(g, inner, rng, CH_EVENT, 1);
                    PlaceInside(g, inner, rng, CH_ENCOUNTER, 1 + rng.Next(2));

                    layout.strongholds.Add(new StructureInfo
                    {
                        name = def.strongholdName,
                        biome = id,
                        center = new Vector2Int(p.x + rw / 2, p.y + rh / 2),
                        isBigStructure = false
                    });
                    MarkOccupied(occupied, p, Mathf.Max(rw, rh) / 2 + 3, w, h);
                    ok = true;
                }
                if (!ok)
                    layout.validation += $"  ⚠️{def.strongholdName}（{def.displayName}）没找到落位，跳过";
            }
        }
    }

    // ==================================================================
    // 第 8 步：大结构（主群系专属 · 多房间复合体 · Boss 房）
    // ==================================================================
    private static void PlaceBigStructure(char[,] g, BiomeId[,] biomeOf, bool[,] occupied,
        System.Random rng, List<Vector2Int>[] regionCells, WastelandLayout layout,
        Settings s, bool[,] skel, int w, int h)
    {
        BiomeDef def = Def(layout.mainBiome);
        var cells = regionCells[(int)layout.mainBiome];
        if (cells.Count == 0) return;

        int roomCount = s.bigRoomsMin + rng.Next(Mathf.Max(1, s.bigRoomsMax - s.bigRoomsMin + 1));
        int roomsBuilt = 0;
        var roomCenters = new List<Vector2Int>();

        // 首间候选：只挑离地图边足够远的格子（过滤边角，别让复合体挤在悬崖边）
        // ★洞穴收紧后区域被山体切得较碎，边界候选会让整条房链越界 → 候选取"离群系质心最近的 60%"，
        //   保证大结构（蛛巢深窟）真的嵌在主群系腹地里。
        var candidates = new List<Vector2Int>();
        foreach (Vector2Int c in cells)
            if (c.x >= 8 && c.y >= 8 && c.x < w - 9 && c.y < h - 9) candidates.Add(c);
        if (candidates.Count == 0) candidates.AddRange(cells);
        if (def.id == BiomeId.Cave && candidates.Count > 12)
        {
            long sx = 0, sy = 0;
            foreach (Vector2Int c in candidates) { sx += c.x; sy += c.y; }
            Vector2Int centroid = new Vector2Int((int)(sx / candidates.Count), (int)(sy / candidates.Count));
            candidates.Sort((p, q) => HexDist(p, centroid).CompareTo(HexDist(q, centroid)));
            candidates = candidates.GetRange(0, Mathf.Max(12, candidates.Count * 3 / 5));
        }

        Vector2Int cursor = candidates[rng.Next(candidates.Count)];
        Vector2Int firstCenter = cursor;

        // 4 个串联方向，每间房系统性遍历（洗牌起始序），别靠运气
        int[] dirIdx = { 0, 1, 2, 3 };
        int[] ddx = { 1, -1, 0, 0 }, ddy = { 0, 0, 1, -1 };

        // 已建房间的矩形（留 1 格缓冲）——房间自交用几何检测，不靠占用圈（占用圈会挡死串联方向）
        var roomRects = new List<int[]>();
        int prevRW = 0, prevRH = 0, firstRW = 0, firstRH = 0;

        int branchRetries = 0;                      // 分支重试计数（有上限，防概率性长尾）
        for (int i = 0; i < roomCount; i++)
        {
            bool ok = false;
            int failBounds = 0, failOccupied = 0;
            for (int attempt = 0; attempt < 4 * 10 && !ok; attempt++)
            {
                int rw = 5 + rng.Next(4), rh = 4 + rng.Next(3);
                // ★荒村：Boss 房一定要大——房间尺寸整体放大
                if (def.id == BiomeId.WildVillage) { rw += 3 + rng.Next(3); rh += 2 + rng.Next(3); }
                // ★草坡：强盗大营也是"围起来的营地"，比一般房间大一大档
                if (def.id == BiomeId.Grass) { rw += 6 + rng.Next(4); rh += 5 + rng.Next(3); }
                if (attempt % 4 == 0)   // 每 4 次（一轮方向）重洗方向序
                {
                    for (int k = dirIdx.Length - 1; k > 0; k--)
                    {
                        int j = rng.Next(k + 1);
                        int t = dirIdx[k]; dirIdx[k] = dirIdx[j]; dirIdx[j] = t;
                    }
                }
                int dir = dirIdx[attempt % 4];
                int dirX = ddx[dir], dirY = ddy[dir];
                // 中心距 = 上一间**实际矩形半宽** + 新间**实际矩形半宽** + 走廊 3 格
                // ★注意：矩形带 1 格缓冲，实际半宽是 (rw+1)/2 + 1，比 rw/2 大 1~2 —— 用 rw/2 会让
                //   两间矩形贴上甚至相交（沼泽等未放大的群系会因此连丢两间 → Boss 落不成）
                int halfW = (rw + 1) / 2 + 1, halfH = (rh + 1) / 2 + 1;
                int prevHalfW = (prevRW + 1) / 2 + 1, prevHalfH = (prevRH + 1) / 2 + 1;
                Vector2Int c;
                if (i == 0) c = cursor;
                else if (dirX != 0) c = new Vector2Int(cursor.x + dirX * (prevHalfW + halfW + 3), cursor.y);
                else c = new Vector2Int(cursor.x, cursor.y + dirY * (prevHalfH + halfH + 3));

                if (c.x < 6 || c.y < 6 || c.x >= w - 7 || c.y >= h - 7) { failBounds++; continue; }
                // ★不做 occupied 检查：大结构本来就该"覆盖"散落的小结构（巨石/残墙被压掉是正常的），
                //   小结构的占用圈会把主群系区域铺满，导致大结构永远放不下。
                //   冲突只防两样：越界 + 与已建房间矩形相交。

                // 房间矩形（中心 ± 半宽高）+ 1 格缓冲，与已建房间相交则重试
                int rx0 = c.x - rw / 2 - 1, ry0 = c.y - rh / 2 - 1;
                int rx1 = c.x + (rw + 1) / 2 + 1, ry1 = c.y + (rh + 1) / 2 + 1;
                bool overlaps = false;
                foreach (int[] r in roomRects)
                {
                    if (rx0 <= r[2] && r[0] <= rx1 && ry0 <= r[3] && r[1] <= ry1) { overlaps = true; break; }
                }
                if (overlaps) { failOccupied++; continue; }

                // ★按主群系给"房间"不同形态（大结构的外观各群系不同）
                BuildBigRoom(g, biomeOf, c, rw, rh, def.id, rng, w, h, i == 0, i == roomCount - 1);

                if (i > 0)
                {
                    // 与上一间之间的走廊：把两间之间的墙挖穿成地板（门 = 通道口）
                    CarveLink(g, roomCenters[roomCenters.Count - 1], c, LinkFloor(def.id), w, h);
                }
                else
                {
                    firstCenter = c;
                    // 入口通道：从首间中心往最近骨架格挖一条 1 宽地板/平地 → 保证大结构可达
                    CarveToSkeleton(g, c, skel, w, h);
                }

                var inner = InteriorCells(g, c, rw, rh, w, h);
                PlaceInside(g, inner, rng, CH_ENCOUNTER, 1 + rng.Next(2));
                if (rng.Next(100) < 70)
                {
                    // ★废墟：箱子什么的贴墙放（被摧毁的城镇，箱子是靠墙堆的）
                    if (def.id == BiomeId.Ruins) PlaceInsideAgainstWall(g, inner, rng, CH_CHEST, 1, w, h);
                    else PlaceInside(g, inner, rng, CH_CHEST, 1);
                }

                roomCenters.Add(c);
                roomRects.Add(new[] { rx0, ry0, rx1, ry1 });
                // A 方案：大结构逐房登记占地 + 墙材质标签。
                // ★草坡大营的末间是首领屋（BuildFrame 房屋）→ 标"建筑"，别让它跟着整营标成栅栏
                char roomMat = (def.id == BiomeId.Grass && i == roomCount - 1)
                    ? MT_BUILDING : BigStructMatTag(def.id);
                layout.matRects.Add(new MatRect
                {
                    x0 = rx0, y0 = ry0, rw = rx1 - rx0, rh = ry1 - ry0,
                    matTag = roomMat
                });
                cursor = c;
                prevRW = rw; prevRH = rh;
                if (i == 0) { firstRW = rw; firstRH = rh; }
                MarkOccupied(occupied, c, Mathf.Max(rw, rh) / 2 + 2, w, h);   // 给后面的据点留 spacing
                roomsBuilt++;
                ok = true;
            }
            if (!ok && roomCenters.Count > 1 && ++branchRetries <= 14)
            {
                // 从首间重新分支再试（多翼），而不是整条链作废；上限 14 次，防概率性长尾
                cursor = roomCenters[0];
                prevRW = firstRW; prevRH = firstRH;
                i--;                       // 这一间重试（for 会 i++）
                continue;
            }
            if (!ok)
            {
                layout.validation += $"  ⚠️大结构第{i + 1}间放不下（越界{failBounds}/重叠{failOccupied}）";
                break;
            }
        }

        if (roomsBuilt >= s.bigRoomsMin)
        {
            Vector2Int bossRoom = roomCenters[roomCenters.Count - 1];
            layout.hasBoss = true;
            layout.bossPos = bossRoom;
            layout.bossBiome = layout.mainBiome;
            layout.bigStructure = new StructureInfo
            {
                name = def.bigStructureName,
                biome = layout.mainBiome,
                center = firstCenter,
                isBigStructure = true
            };
            // 房间落成时已逐房 MarkOccupied，这里不再叠一个 9 格大圈（会把主群系区域的据点位挤光）
        }
        else
        {
            layout.validation += "  ⚠️大结构没放下（主群系区域太小）——本局无 Boss";
        }
    }

    /// <summary>两间房中心之间挖一条地板走廊（自动把两堵框墙挖穿 = 门）。</summary>
    private static void CarveLink(char[,] g, Vector2Int a, Vector2Int b, char floor, int w, int h)
    {
        int x = a.x, y = a.y;
        int guard = 0;
        while ((x != b.x || y != b.y) && guard++ < (w + h))
        {
            if (x != b.x) x += Math.Sign(b.x - x);
            else if (y != b.y) y += Math.Sign(b.y - y);
            if (x > 0 && y > 0 && x < w - 1 && y < h - 1 && g[x, y] != CH_SPAWN) g[x, y] = floor;   // ★不覆盖出生点
        }
    }

    /// <summary>从 p 向最近的骨架格挖 1 宽平地（大结构入口通道，保可达）。</summary>
    private static void CarveToSkeleton(char[,] g, Vector2Int p, bool[,] skel, int w, int h)
    {
        int bestD = int.MaxValue;
        Vector2Int best = p;
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                if (!skel[x, y]) continue;
                int d = Mathf.Abs(x - p.x) + Mathf.Abs(y - p.y);
                if (d < bestD) { bestD = d; best = new Vector2Int(x, y); }
            }
        if (bestD == int.MaxValue) return;

        int x2 = p.x, y2 = p.y;
        int guard = 0;
        while ((x2 != best.x || y2 != best.y) && guard++ < (w + h))
        {
            if (x2 != best.x) x2 += Math.Sign(best.x - x2);
            else if (y2 != best.y) y2 += Math.Sign(best.y - y2);
            if (x2 > 0 && y2 > 0 && x2 < w - 1 && y2 < h - 1 && g[x2, y2] == CH_WALL)
                g[x2, y2] = CH_PLAIN;
        }
    }

    // ==================================================================
    // 第 9 步：内容散点 / 巡逻锚点
    // ==================================================================
    /// <summary>选出生点：在"靠近地图中心"的骨架团块中心里随机挑一个。
    /// ★必须避开洞穴群系（2026-09-16 坑）：洞穴整片是山体，出生点若落在里面，
    ///   四周全是墙 → 出生点成孤岛，全图内容点直接判不可达（实测 80~96 个点 FAIL）。</summary>
    private static Vector2Int PickSpawn(System.Random rng, List<Vector2Int> centers,
        BiomeId[,] biomeOf, int w, int h)
    {
        if (centers.Count == 0) return new Vector2Int(w / 2, h / 2);
        var sorted = new List<Vector2Int>(centers);
        Vector2Int mid = new Vector2Int(w / 2, h / 2);
        sorted.Sort((p, q) => Vector2Int.Distance(q, mid).CompareTo(Vector2Int.Distance(p, mid)));
        int span = Mathf.Max(1, sorted.Count * 2 / 3);
        // 先在内侧 2/3 里找非洞穴的；找不到就全表找；再找不到才认命
        for (int pass = 0; pass < 2; pass++)
        {
            int lim = pass == 0 ? span : sorted.Count;
            var ok = new List<Vector2Int>();
            for (int i = 0; i < lim && i < sorted.Count; i++)
                if (Def(biomeOf[sorted[i].x, sorted[i].y]).id != BiomeId.Cave) ok.Add(sorted[i]);
            if (ok.Count > 0) return ok[rng.Next(ok.Count)];
        }
        int pick = rng.Next(0, span);
        if (pick >= sorted.Count) pick = sorted.Count - 1;
        return sorted[pick];
    }

    private static void PickPatrolAnchors(WastelandLayout layout, char[,] g, bool[,] skel, BiomeId[,] biomeOf,
        System.Random rng, Vector2Int spawn, Settings s, int w, int h)
    {
        int placed = 0, tries = 0;
        int want = Mathf.Max(1, s.patrolAnchorCount);
        while (placed < want && tries < want * 60)
        {
            tries++;
            int x = rng.Next(1, w - 1), y = rng.Next(1, h - 1);
            if (!skel[x, y]) continue;
            // ★2026-09-16 修锚点落墙：skel 是骨架期快照，之后的结构层/山体/边界收口会把部分骨架格
            //   改成红墙 —— 必须以**终稿字符**复核（实测约 5% 锚点落墙，消费侧 IsUsableCell 跳过，
            //   等于白白浪费 patrolAnchorCount 的怪密度配额）。
            if (g[x, y] == CH_WALL) continue;
            // ★洞穴区不放巡逻锚点：洞内可走格是孤立支洞，锚点放那儿永远不可达
            if (Def(biomeOf[x, y]).id == BiomeId.Cave) continue;
            var p = new Vector2Int(x, y);
            if (Distance(p, spawn) < s.spawnClearRadius + 3) continue;

            bool dup = false;
            foreach (PatrolAnchor a in layout.patrolAnchors)
                if (Distance(a.pos, p) < 5) { dup = true; break; }
            if (dup) continue;

            layout.patrolAnchors.Add(new PatrolAnchor { pos = p, biome = biomeOf[x, y] });
            placed++;
        }
    }

    /// <summary>撒单点内容（宝箱 / 事件位 / 篝火）：只落在纯地形格上，互相留出间距。
    /// ★洞穴区的可走格**不参与**——洞穴是"山体 + 几条隧道"，可走格总共才 200~350 格
    ///   且分散在若干条互不连通的支洞里，内容点撒进去大多走不到（用户要的"死胡同宝箱"
    ///   由 BuildCaveMass 单独负责，见那里的度数=1 逻辑）。</summary>
    private static void ScatterSingle(char[,] g, BiomeId[,] biomeOf, int count, char ch,
        List<Vector2Int> used, System.Random rng, Settings s, int w, int h, bool allowCave)
    {
        if (count <= 0) return;
        int lo = 2;
        int placed = 0, tries = 0, maxTries = count * 60;

        while (placed < count && tries < maxTries)
        {
            tries++;
            int x = rng.Next(lo, w - lo), y = rng.Next(lo, h - lo);
            if (!IsTerrain(g[x, y])) continue;
            if (!allowCave && Def(biomeOf[x, y]).id == BiomeId.Cave) continue;
            bool tooClose = false;
            for (int i = 0; i < used.Count; i++)
                if (Mathf.Abs(used[i].x - x) + Mathf.Abs(used[i].y - y) < s.contentMinSeparation) { tooClose = true; break; }
            if (tooClose) continue;
            g[x, y] = ch;
            used.Add(new Vector2Int(x, y));
            placed++;
        }
    }

    // ==================================================================
    // 第 9b 步：★全图连通性兜底
    // ==================================================================
    /// <summary>
    /// ★把所有"与出生点不连通的可走陆地"接回主路网（用户 2026-09-16 冒烟 FAIL 的真正根因）。
    ///
    /// 为什么需要这一步（而不是靠第 10 步的 RepairPath）：
    ///   骨架只挖了 14 个团块 + 通道，其余地面**字符上虽是 . / f，但被红墙 / 崖 / 山体 / 水
    ///   围成孤岛**。实测 seed 26 出生点可达仅 52.1%，另有一整块 1461 格的陆地被彻底切开，
    ///   33 个内容点全落在上面。此时 RepairPath 要跨 100+ 格的隔离带，或者必须穿过
    ///   "不可穿越"的洞穴山体 —— 它天然修不通，这不是算法问题而是拓扑问题。
    ///
    /// 做法（自底向上，O(陆地格数)）：
    ///   1) 从出生点 flood，得到主陆地块。
    ///   2) 把所有**连通的非主陆地块**按大小排序（大的优先，通道要最短）。
    ///   3) 每块用一次"多源 Dijkstra"找它到主陆地的**最低代价路径**：
    ///      墙/水 = 代价 1（可以凿，但尽量少凿）、陆地 = 代价 0（同块内自由走），
    ///      **洞穴山体 = 不可穿越**（形态是硬的，绝不为了连通在山里开路）。
    ///   4) 沿路径把挡路的 # / w 降级为平地（w 降级成浅滩平地），连通块并入主陆地。
    ///   5) 重复直到没有剩余孤块，或连续两轮无进展（被山体彻底隔死时放弃并计入报告）。
    ///
    /// 注：只在**内容层之前**调用，保证内容层撒点永远落在已连通的陆地上。
    /// </summary>
    private static string ConnectRegions(char[,] g, BiomeId[,] biomeOf, Vector2Int spawn,
        System.Random rng, int w, int h)
    {
        string report = "";
        int totalJoined = 0, totalDug = 0, stuck = 0;

        // ★性能：这几个缓冲区全程复用。早先每轮/每块都 new 一个 int[w,h] + 线性扫优先队列，
        //   实测让 120×75 单次生成从 7.6ms 涨到 27ms（GenAll 跑 21000 次从 2m40s 涨到 9m43s）。
        int n = w * h;
        var main = new bool[w, h];
        var compId = new int[w, h];
        var dist = new int[n];
        var prev = new int[n];
        var heap = new IntHeap(n);

        for (int round = 0; round < 60; round++)
        {
            FloodInto(main, g, spawn, w, h);

            // 1) 找出所有"非主陆地"的连通块（★六边形 6 向，与游戏移动一致）
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) compId[x, y] = -1;
            var comps = new List<List<int>>();          // 存 y*w+x，省对象
            var stack = new List<int>();

            for (int y = 1; y < h - 1; y++)
                for (int x = 1; x < w - 1; x++)
                {
                    if (main[x, y] || compId[x, y] >= 0) continue;
                    char c0 = g[x, y];
                    if (c0 == CH_WALL || c0 == CH_WATER) continue;
                    int id = comps.Count;
                    var cells = new List<int>();
                    stack.Clear();
                    stack.Add(y * w + x); compId[x, y] = id;
                    while (stack.Count > 0)
                    {
                        int p = stack[stack.Count - 1]; stack.RemoveAt(stack.Count - 1);
                        int px = p % w, py = p / w;
                        cells.Add(p);
                        HexNeighbors(px, py, w, h, (nx, ny) =>
                        {
                            if (main[nx, ny] || compId[nx, ny] >= 0) return;
                            char c = g[nx, ny];
                            if (c == CH_WALL || c == CH_WATER) return;
                            compId[nx, ny] = id;
                            stack.Add(ny * w + nx);
                        });
                    }
                    comps.Add(cells);
                }

            if (comps.Count == 0) break;

            // 2) 大块优先（通道短、破坏小）
            comps.Sort((a, b) => b.Count.CompareTo(a.Count));
            bool progress = false;

            // ★只在"真的凿了通道"时才重算可达集 —— 早先每块都重算一次，是最大的一处浪费。
            bool needFlood = false;
            foreach (List<int> cells in comps)
            {
                if (cells.Count == 0) continue;
                int rep = cells[0];
                int rx = rep % w, ry = rep / w;
                if (needFlood) { FloodInto(main, g, spawn, w, h); needFlood = false; }
                if (main[rx, ry]) continue;             // 已被前面某块的通道接上

                int dug = DigCheapestPath(g, biomeOf, main, cells, dist, prev, heap, w, h);
                if (dug >= 0)
                {
                    totalJoined++;
                    totalDug += dug;
                    progress = true;
                    needFlood = true;                  // 地形变了，下块之前要重算
                }
                else stuck++;
            }

            if (!progress) break;
        }

        if (totalJoined > 0)
            report += $"  ⚠️{totalJoined} 块孤立陆地 → 已凿通接回主路网（共降级 {totalDug} 格）";
        if (stuck > 0)
            report += $"  ⚠️{stuck} 块孤立陆地被山体彻底隔死 → 无法连通（洞内区不受影响）";
        return report;
    }

    /// <summary>六边形 6 向邻居枚举（★不分配数组：HexDirs 每次 new 两个 int[6]，在热路径上是主要开销）。</summary>
    private static void HexNeighbors(int x, int y, int w, int h, System.Action<int, int> fn)
    {
        int sh = ((x & 1) == 1) ? 1 : -1;               // odd-q：奇数列向下偏，偶数列向上偏
        int nx = x + 1, ny = y;            if (nx >= 0 && nx < w && ny >= 0 && ny < h) fn(nx, ny);
        nx = x - 1; ny = y;                if (nx >= 0 && nx < w && ny >= 0 && ny < h) fn(nx, ny);
        nx = x; ny = y + 1;                if (nx >= 0 && nx < w && ny >= 0 && ny < h) fn(nx, ny);
        nx = x; ny = y - 1;                if (nx >= 0 && nx < w && ny >= 0 && ny < h) fn(nx, ny);
        nx = x + 1; ny = y + sh;           if (nx >= 0 && nx < w && ny >= 0 && ny < h) fn(nx, ny);
        nx = x - 1; ny = y + sh;           if (nx >= 0 && nx < w && ny >= 0 && ny < h) fn(nx, ny);
    }

    /// <summary>把 flood 结果写进调用方提供的 reach（复用数组，避免每轮 new）。</summary>
    private static void FloodInto(bool[,] reach, char[,] g, Vector2Int spawn, int w, int h)
    {
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) reach[x, y] = false;
        if (spawn.x < 0 || spawn.y < 0 || spawn.x >= w || spawn.y >= h) return;
        var q = new Queue<Vector2Int>();
        q.Enqueue(spawn);
        reach[spawn.x, spawn.y] = true;
        while (q.Count > 0)
        {
            Vector2Int p = q.Dequeue();
            int px = p.x, py = p.y;
            HexNeighbors(px, py, w, h, (nx, ny) =>
            {
                if (reach[nx, ny] || g[nx, ny] == CH_WALL) return;
                reach[nx, ny] = true;
                q.Enqueue(new Vector2Int(nx, ny));
            });
        }
    }

    /// <summary>把一整块孤立陆地接回 main：多源 Dijkstra，返回降级格数；接不上返回 -1。
    /// 起点 = 该块所有格（代价 0），终点 = 任一 main 格。墙/水 = 代价 1（可凿）。
    /// ★洞穴区：
    ///   · **已成形的隧道格（可走）= 代价 0，可自由通过**（隧道本来就是路网的一部分）；
    ///   · **山体格 = 代价 24**（重罚而不是禁止）—— 平时绝不走（隧道更便宜），
    ///     但当地块被整片山体彻底包死、别无他路时，允许"打穿一条最薄的隧道"把陆地接回来。
    ///     这是 2026-09-16 冒烟 FAIL 的最后一道保险：洞穴 Voronoi 区可能横在两张陆地之间，
    ///     若绝对禁穿，主陆地就被永久切成两半，内容点怎么修都不可达（实测 seed 31/123/134/
    ///     139/153/156 共 6 个 seed 卡在这里，单块孤立 1193~2304 格）。
    ///     ★代价取 24 而非 1：确保"只要存在非洞穴路线就绝不穿山"，穿山只是最后手段。</summary>
    private static int DigCheapestPath(char[,] g, BiomeId[,] biomeOf, bool[,] main,
        List<int> cells, int[] dist, int[] prev, IntHeap heap, int w, int h)
    {
        const int UNSEEN = int.MaxValue;
        const int CAVE_DIG_COST = 24;                       // 穿一格山体的代价
        int n = w * h;
        for (int i = 0; i < n; i++) { dist[i] = UNSEEN; prev[i] = -1; }

        heap.Clear();
        foreach (int c in cells)
        {
            if (dist[c] == UNSEEN) { dist[c] = 0; prev[c] = -1; heap.Push(c, 0); }
        }

        int goal = -1;
        while (heap.Count > 0)
        {
            int cur = heap.Pop(out int cd);
            if (cd > dist[cur]) continue;                   // 过期条目
            int cx = cur % w, cy = cur / w;
            if (main[cx, cy]) { goal = cur; break; }

            int fx = cx, fy = cy;
            HexNeighbors(fx, fy, w, h, (nx, ny) =>
            {
                char ch = g[nx, ny];
                int cost;
                if (Def(biomeOf[nx, ny]).id == BiomeId.Cave)
                {
                    if (ch == CH_WALL) cost = CAVE_DIG_COST;    // 山体：重罚（最后手段）
                    else if (ch == CH_WATER) cost = 4;          // 暗河：略绕
                    else cost = 0;                              // 隧道格：就是路，白走
                }
                else cost = (ch == CH_WALL || ch == CH_WATER) ? 1 : 0;

                int ni = ny * w + nx;
                int nd = cd + cost;
                if (nd < dist[ni])
                {
                    dist[ni] = nd;
                    prev[ni] = cur;
                    heap.Push(ni, nd);
                }
            });
        }

        if (goal < 0) return -1;

        // 回溯：把路径上的 # / w 降级为平地（含被重罚打通的山体，这正是"最后手段"的落地）
        int dug = 0;
        int node = goal;
        int guard = 0;
        while (node >= 0 && guard++ < n)
        {
            int nx = node % w, ny = node / w;
            if (g[nx, ny] == CH_WALL) { g[nx, ny] = CH_PLAIN; dug++; }
            else if (g[nx, ny] == CH_WATER) { g[nx, ny] = CH_PLAIN; dug++; }   // 水→浅滩
            node = prev[node];
        }
        return dug;
    }

    /// <summary>极简二叉最小堆（替代早先的"线性扫 + List.RemoveAt"，后者在 9000 格网格上是 O(n²)）。</summary>
    private struct IntHeap
    {
        private int[] _node; private int[] _key; private int _n;
        public IntHeap(int cap) { _node = new int[cap]; _key = new int[cap]; _n = 0; }
        public int Count { get { return _n; } }
        public void Clear() { _n = 0; }
        public void Push(int node, int key)
        {
            if (_n >= _node.Length) System.Array.Resize(ref _node, _node.Length * 2);
            if (_n >= _key.Length) System.Array.Resize(ref _key, _key.Length * 2);
            int i = _n++;
            _node[i] = node; _key[i] = key;
            while (i > 0)
            {
                int p = (i - 1) / 2;
                if (_key[p] <= _key[i]) break;
                Swap(p, i); i = p;
            }
        }
        public int Pop(out int key)
        {
            key = _key[0];
            int node = _node[0];
            _n--;
            if (_n > 0)
            {
                _node[0] = _node[_n]; _key[0] = _key[_n];
                int i = 0;
                while (true)
                {
                    int l = i * 2 + 1, r = l + 1, m = i;
                    if (l < _n && _key[l] < _key[m]) m = l;
                    if (r < _n && _key[r] < _key[m]) m = r;
                    if (m == i) break;
                    Swap(m, i); i = m;
                }
            }
            return node;
        }
        private void Swap(int a, int b)
        {
            int t = _node[a]; _node[a] = _node[b]; _node[b] = t;
            t = _key[a]; _key[a] = _key[b]; _key[b] = t;
        }
    }

    // ==================================================================
    // 第 10 步：校验 + 修复
    // ==================================================================
    /// <summary>
    /// BFS 连通性（# 不可通行）：所有内容点（S/C/E/F/x/Boss 位/巡逻锚点）必须从出生点可达。
    /// 不可达 → 把该内容点到最近可达格之间的挡路 # 降级为平地（§3.5.2：校验要能"修"）。
    /// </summary>
    private static string ValidateAndRepair(char[,] g, BiomeId[,] biomeOf, WastelandLayout layout, int w, int h)
    {
        string report = "";
        int removed = 0, relocated = 0;
        for (int pass = 0; pass < 4; pass++)
        {
            var reach = FloodFromSpawn(g, layout.spawnPos, w, h);

            var targets = new List<Vector2Int>();
            CollectContent(g, targets, w, h);
            foreach (PatrolAnchor a in layout.patrolAnchors) targets.Add(a.pos);
            if (layout.hasBoss) targets.Add(layout.bossPos);

            var unreachable = new List<Vector2Int>();
            foreach (Vector2Int t in targets)
                if (!reach[t.x, t.y]) unreachable.Add(t);

            if (unreachable.Count == 0) break;

            int repaired = 0;
            foreach (Vector2Int t in unreachable)
            {
                // ★洞穴区的 # 是"山体"，是形态本身，不允许被降级炸开——
                //   否则每个不可达内容点都会在山里炸出一条 L 形通道，
                //   实测这正是"洞穴可走格几千、十字逾千"的真正原因（2026-09-16 定位）。
                //   洞穴里不可达的内容点改为**就近搬到可达格**（保住内容，不破坏山体）；
                //   实在没地方搬才清除。
                if (Def(biomeOf[t.x, t.y]).id == BiomeId.Cave)
                {
                    // ★例外：洞穴里的**宝箱**是"死胡同尽头的奖励"，是用户点名的设计，
                    //   不通就让它不通（那正是死胡同的意义），不要搬走也不要清除。
                    if (g[t.x, t.y] == CH_CHEST) continue;

                    char keep = g[t.x, t.y];
                    Vector2Int dst = NearestReachable(reach, t, 12, w, h);
                    if (dst.x >= 0 && (dst.x != t.x || dst.y != t.y)
                        && g[dst.x, dst.y] != CH_SPAWN && g[dst.x, dst.y] != CH_INDOOR)
                    {
                        g[dst.x, dst.y] = keep;
                        g[t.x, t.y] = CH_WALL;
                        relocated++;
                    }
                    else
                    {
                        g[t.x, t.y] = CH_WALL;
                        removed++;
                    }
                    continue;
                }
                repaired += RepairPath(g, biomeOf, reach, t, w, h);
            }
            if (repaired > 0) report += $"  ⚠️{unreachable.Count} 个内容点不可达 → 已降级 {repaired} 格红墙修通";
            if (relocated > 0) report += $"  ⚠️{relocated} 个内容点落在洞穴山体上 → 已就近搬进隧道";
            if (removed > 0) report += $"  ⚠️{removed} 个内容点无位可放 → 已清除（不破坏山体）";
        }
        return report;
    }

    /// <summary>在 radius 半径内找离 p 最近的可达且是纯地形的格；找不到返回 (-1,-1)。</summary>
    private static Vector2Int NearestReachable(bool[,] reach, Vector2Int p, int radius, int w, int h)
    {
        int bestD = int.MaxValue;
        Vector2Int best = new Vector2Int(-1, -1);
        for (int dy = -radius; dy <= radius; dy++)
            for (int dx = -radius; dx <= radius; dx++)
            {
                int x = p.x + dx, y = p.y + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) continue;
                if (!reach[x, y]) continue;
                int d = Mathf.Abs(dx) + Mathf.Abs(dy);
                if (d < bestD) { bestD = d; best = new Vector2Int(x, y); }
            }
        return best;
    }

    /// <summary>从出生点出发的连通性 flood（分配新数组版；ConnectRegions 走复用缓冲的 FloodInto）。
    /// ★必须用**六边形 6 向**——地图与移动都是 odd-q offset 平顶六边形（权威定义
    ///   `CardExecutor.HexDistance`）。早先这里用的是 4 向（上下左右），与游戏实际移动规则
    ///   不符，导致**大量"假孤立"**：4 向判定不可达而 6 向其实走得到。
    ///   实测 seed 26 会因此虚报 1478 格孤立（4 向可达 1999 / 6 向可达 3477），
    ///   进而让 ValidateAndRepair / ConnectRegions 去凿根本不存在的墙 —— 这就是
    ///   2026-09-16 冒烟 FAIL 数量"怎么改都纹丝不动"的根源（2026-09-16 定位）。</summary>
    private static bool[,] FloodFromSpawn(char[,] g, Vector2Int spawn, int w, int h)
    {
        var reach = new bool[w, h];
        FloodInto(reach, g, spawn, w, h);
        return reach;
    }

    private static void CollectContent(char[,] g, List<Vector2Int> targets, int w, int h)
    {
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                char c = g[x, y];
                if (c == CH_SPAWN || c == CH_CHEST || c == CH_EVENT || c == CH_BONFIRE || c == CH_ENCOUNTER)
                    targets.Add(new Vector2Int(x, y));
            }
    }

    /// <summary>把不可达内容点接到可达路网上：沿"最低代价路径"把挡路 # 降级为平地，返回降级格数。
    /// ★洞穴区：隧道格（可走）代价 0，山体格代价 24（重罚而非禁止）——与 `DigCheapestPath` 同一口径。
    ///   理由：`ConnectRegions`（第 9b 步）已经在内容层之前把陆地连通性治过一遍，**正常情况下
    ///   这里根本不需要动用穿山**；但结构层（据点/大结构）可能在连通之后又新砌红墙把某个
    ///   内容点圈死，那时允许"打穿一条最薄的山体"作为兜底，好过让内容点直接判死。
    ///   早先这里是"洞穴绝对不可穿"，实测断在 6 个 seed 上（2026-09-16）。</summary>
    private static int RepairPath(char[,] g, BiomeId[,] biomeOf, bool[,] reach, Vector2Int t, int w, int h)
    {
        const int CAVE_DIG_COST = 24;
        int n = w * h;
        var dist = new int[n];
        var prev = new int[n];
        for (int i = 0; i < n; i++) { dist[i] = int.MaxValue; prev[i] = -1; }
        var heap = new IntHeap(n);
        int start = t.y * w + t.x;
        dist[start] = 0;
        heap.Push(start, 0);
        int goal = -1;

        while (heap.Count > 0)
        {
            int cur = heap.Pop(out int cd);
            if (cd > dist[cur]) continue;
            int cx = cur % w, cy = cur / w;
            if (reach[cx, cy]) { goal = cur; break; }                 // 撞到可达路网 → 完成

            int fx = cx, fy = cy;
            HexNeighbors(fx, fy, w, h, (nx, ny) =>
            {
                if (nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1) return;
                char ch = g[nx, ny];
                int cost;
                if (Def(biomeOf[nx, ny]).id == BiomeId.Cave)
                {
                    if (ch == CH_WALL) cost = CAVE_DIG_COST;   // 山体：重罚（最后手段）
                    else if (ch == CH_WATER) cost = 4;
                    else cost = 0;                             // 隧道格：白走
                }
                else cost = (ch == CH_WALL) ? 1 : (ch == CH_WATER ? 1 : 0);

                int ni = ny * w + nx;
                int nd = cd + cost;
                if (nd < dist[ni])
                {
                    dist[ni] = nd;
                    prev[ni] = cur;
                    heap.Push(ni, nd);
                }
            });
        }
        if (goal < 0) return 0;

        int repaired = 0;
        int node = goal;
        while (node != start && node >= 0)
        {
            int nx = node % w, ny = node / w;
            if (g[nx, ny] == CH_WALL) { g[nx, ny] = CH_PLAIN; repaired++; }
            else if (g[nx, ny] == CH_WATER) { g[nx, ny] = CH_PLAIN; repaired++; }
            node = prev[node];
        }
        return repaired;
    }

    // ==================================================================
    // 输出
    // ==================================================================
    public static List<string> ToRows(char[,] g, int w, int h)
    {
        var rows = new List<string>(h);
        var sb = new StringBuilder(w);
        for (int y = 0; y < h; y++)
        {
            sb.Length = 0;
            for (int x = 0; x < w; x++) sb.Append(g[x, y]);
            rows.Add(sb.ToString());
        }
        return rows;
    }

    public static List<string> ToBiomeRows(BiomeId[,] biomeOf, int w, int h)
    {
        var rows = new List<string>(h);
        var sb = new StringBuilder(w);
        for (int y = 0; y < h; y++)
        {
            sb.Length = 0;
            for (int x = 0; x < w; x++) sb.Append(Def(biomeOf[x, y]).mapLetter);
            rows.Add(sb.ToString());
        }
        return rows;
    }

    /// <summary>行数组 → 单个字符串（可直接写盘成 .txt）。</summary>
    public static string ToText(List<string> rows)
    {
        if (rows == null || rows.Count == 0) return "";
        var sb = new StringBuilder();
        for (int i = 0; i < rows.Count; i++)
        {
            sb.Append(rows[i]);
            if (i < rows.Count - 1) sb.Append('\n');
        }
        return sb.ToString();
    }

    // ==================================================================
    // A 方案：材质/结构标签网格（matRows）
    // ==================================================================
    /// <summary>据点（按群系分派形态）的墙材质标签。</summary>
    private static char StrongholdMatTag(BiomeId id)
    {
        switch (id)
        {
            case BiomeId.Grass:         return MT_CAMP_WALL;   // 强盗营地木/石围墙
            case BiomeId.Jungle:        return MT_BONE;        // 兽巢巨石骨环
            case BiomeId.AncientForest: return MT_ALTAR;       // 树围祭坛石
            case BiomeId.Ruins:         return MT_RUIN_WALL;   // 废屋断墙
            case BiomeId.Swamp:         return MT_ROOT;        // 树桩/浮木残木
            case BiomeId.WildVillage:   return MT_BUILDING;    // 规整村舍
            case BiomeId.Cave:          return MT_CAVE_ROCK;   // 洞内石室
            default:                    return MT_MOUNTAIN;
        }
    }

    /// <summary>大结构（按主群系分派形态）的墙材质标签。</summary>
    private static char BigStructMatTag(BiomeId id)
    {
        switch (id)
        {
            case BiomeId.Grass:         return MT_CAMP_WALL;   // 强盗大营
            case BiomeId.Jungle:        return MT_ROOT;        // 巨树根腔
            case BiomeId.AncientForest: return MT_ALTAR;       // 环形祭坛
            case BiomeId.Ruins:         return MT_TOMB;        // 亡者墓园
            case BiomeId.Swamp:         return MT_ISLE_RING;   // 湖心岛环湖水带
            case BiomeId.WildVillage:   return MT_BUILDING;    // 地主大宅
            case BiomeId.Cave:          return MT_CAVE_ROCK;   // 洞厅
            default:                    return MT_MOUNTAIN;
        }
    }

    /// <summary>未归入任何成形结构的 #（散点山/树/石）按群系给默认材质。</summary>
    private static char BiomeWallDefault(BiomeId id)
    {
        switch (id)
        {
            case BiomeId.Cave:          return MT_CAVE_ROCK;
            case BiomeId.Ruins:         return MT_RUIN_WALL;   // 废墟地表散落的断墙/塌石
            case BiomeId.WildVillage:   return MT_BUILDING;    // 村落散落的石砌残段
            case BiomeId.AncientForest: return MT_ROOT;        // 古林树=墙（树干材质）
            case BiomeId.Jungle:        return MT_ROOT;        // 密林倒木/根
            default:                    return MT_MOUNTAIN;    // 草坡/沼泽：普通山体
        }
    }

    /// <summary>
    /// 根据地形网格 + 结构归组（matRects），生成材质/结构标签网格 matRows（与 terrainRows 同坐标系）。
    /// 规则：① 成形结构矩形内的 # → 该结构的墙材质标签；② 剩余 # → 按所在群系给默认材质；
    /// ③ 其余字符（. f w / S F C E x / _）直接透传，群系配色另走 biomeRows。
    /// </summary>
    private static void FinalizeMaterialGrid(char[,] g, BiomeId[,] biomeOf, WastelandLayout layout, int w, int h)
    {
        char[,] mat = new char[w, h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                mat[x, y] = g[x, y];

        foreach (MatRect r in layout.matRects)
        {
            int x1 = Mathf.Min(w - 1, r.x0 + r.rw);
            int y1 = Mathf.Min(h - 1, r.y0 + r.rh);
            for (int y = Mathf.Max(0, r.y0); y <= y1; y++)
                for (int x = Mathf.Max(0, r.x0); x <= x1; x++)
                    if (g[x, y] == CH_WALL) mat[x, y] = r.matTag;
        }

        // ★2b 废墟特判（2026-09-16 用户反馈「一大片连起来的墙」）：
        //    地形噪声的岩石隆起没有 matRect，走"群系默认=断墙 U"→ 渲染成连片断墙网。
        //    按 6 向连通域大小区分：**大团 = 自然山体（→ M 山体材质）**，小簇 = 人造断墙/废屋（→ 保持 U）。
        //    门槛 24：废屋房架最多 ~19 格（rw6+rh5 周长 22 - 门 1 - 塌墙 2~6），路边断壁 ≤2 格，
        //    自然岩石团实测 70~140+；据点/大结构已在 matRect 里，不参与此判定。
        var compId = new int[w, h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) compId[x, y] = -1;
        var compSize = new List<int>();
        var flood = new Queue<Vector2Int>();
        for (int sy = 0; sy < h; sy++)
            for (int sx = 0; sx < w; sx++)
            {
                if (mat[sx, sy] != CH_WALL || compId[sx, sy] >= 0) continue;
                int id = compSize.Count;
                compSize.Add(0);
                compId[sx, sy] = id;
                flood.Enqueue(new Vector2Int(sx, sy));
                while (flood.Count > 0)
                {
                    var p = flood.Dequeue();
                    compSize[id]++;
                    int[] dxs, dys; HexDirs(p.x, out dxs, out dys);
                    for (int i = 0; i < 6; i++)
                    {
                        int nx = p.x + dxs[i], ny = p.y + dys[i];
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        if (mat[nx, ny] != CH_WALL || compId[nx, ny] >= 0) continue;
                        compId[nx, ny] = id;
                        flood.Enqueue(new Vector2Int(nx, ny));
                    }
                }
            }

        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (mat[x, y] == CH_WALL)
                {
                    char d = BiomeWallDefault(biomeOf[x, y]);
                    if (biomeOf[x, y] == BiomeId.Ruins && compSize[compId[x, y]] > 24)
                        d = MT_MOUNTAIN;                    // ★自然山体，不是断墙
                    mat[x, y] = d;
                }

        layout.matRows = ToRows(mat, w, h);
    }

    // ==================================================================
    // 小工具
    // ==================================================================
    /// <summary>
    /// ★据点矩形（以 p 为中心、rw×rh 的外框）是否整个落在指定群系区域内。
    /// 用于「据点只落在自己的群系区域内」——防止据点探进邻近群系（会在别人的地盘上盖房子）。
    /// </summary>
    private static bool RectInBiome(BiomeId[,] biomeOf, Vector2Int p, int rw, int rh,
        BiomeId id, int w, int h)
    {
        int x0 = p.x - rw / 2, y0 = p.y - rh / 2;
        for (int dy = 0; dy <= rh; dy++)
            for (int dx = 0; dx <= rw; dx++)
            {
                int x = x0 + dx, y = y0 + dy;
                if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) return false;
                if (Def(biomeOf[x, y]).id != id) return false;
            }
        return true;
    }

    private static int Distance(Vector2Int a, Vector2Int b)
    {
        return Mathf.Abs(a.x - b.x) + Mathf.Abs(a.y - b.y);
    }

    private static bool IsTerrain(char c)
    {
        return c == CH_PLAIN || c == CH_FOREST || c == CH_WATER;
    }

    private static void SetIfTerrain(char[,] g, int x, int y, char ch, int w, int h)
    {
        if (x < 0 || y < 0 || x >= w || y >= h) return;
        if (!IsTerrain(g[x, y])) return;     // 内容只放在纯地形格上（不覆盖结构 / 据点 / 出生点）
        g[x, y] = ch;
    }

    private static List<Vector2Int> InteriorCells(char[,] g, Vector2Int frameTopLeft, int rw, int rh, int w, int h)
    {
        var list = new List<Vector2Int>();
        for (int dy = 1; dy < rh; dy++)
            for (int dx = 1; dx < rw; dx++)
            {
                int x = frameTopLeft.x + dx, y = frameTopLeft.y + dy;
                if (x < 0 || y < 0 || x >= w || y >= h) continue;
                if (g[x, y] == CH_INDOOR || g[x, y] == CH_PLAIN || g[x, y] == CH_WATER)
                    list.Add(new Vector2Int(x, y));
            }
        return list;
    }

    private static void PlaceInside(char[,] g, List<Vector2Int> inner, System.Random rng, char ch, int count)
    {
        for (int n = 0; n < count && inner.Count > 0; n++)
        {
            int idx = rng.Next(inner.Count);
            Vector2Int p = inner[idx];
            inner.RemoveAt(idx);
            g[p.x, p.y] = ch;
        }
    }

    /// <summary>
    /// ★贴墙放内容（用户 2026-09-16：「废墟是已经被摧毁的城镇，箱子什么的也贴墙放」）——
    /// 优先选"紧邻 `#` 墙"的室内格；找不到再退回任意室内格。
    /// </summary>
    private static void PlaceInsideAgainstWall(char[,] g, List<Vector2Int> inner,
        System.Random rng, char ch, int count, int w, int h)
    {
        // 先筛出贴墙候选（六边形 6 邻居里有 `#`）
        var nearWall = new List<Vector2Int>();
        foreach (Vector2Int p in inner)
        {
            int[] dxs, dys; HexDirs(p.x, out dxs, out dys);
            for (int i = 0; i < HexNeighborCount; i++)
            {
                int nx = p.x + dxs[i], ny = p.y + dys[i];
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                if (g[nx, ny] == CH_WALL) { nearWall.Add(p); break; }
            }
        }
        for (int n = 0; n < count; n++)
        {
            List<Vector2Int> pool = nearWall.Count > 0 ? nearWall : inner;
            if (pool.Count == 0) return;
            Vector2Int p = pool[rng.Next(pool.Count)];
            g[p.x, p.y] = ch;
            nearWall.Remove(p);
            inner.Remove(p);
        }
    }
}

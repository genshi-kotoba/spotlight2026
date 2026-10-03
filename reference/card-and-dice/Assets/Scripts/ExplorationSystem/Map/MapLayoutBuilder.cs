// =============================================================================
// 模块：探索系统 - 地图布局生成器 MapLayoutBuilder
// 用途：把一张人类可读的文本布局（Assets/Data/Maps/*.txt）烘焙成 Map / Map1 网格：
//       ① 按文本尺寸重建六边形网格
//       ② 刷地形（平地 / 树林 / 水 / 红墙 / 室内地板）
//       ③ 登记节点坐标（出生点 / 篝火 / 宝箱 / 事件候选位）
//
// 为什么这么做（而不是在 Inspector 里手摆格子）：
//   · 地图内容需要一个可版本控制、可批量编辑的载体。一张 1500 格的地图手摆不现实，
//     文本布局可以整体重画、整体 diff、整体回滚。
//   · 地形即玩法：移动成本与阻挡完全由 TerrainManager 驱动，
//     A* 寻路 / 玩家移动(HexMover) / 敌人 AI(MoveAIController, EnemyController) /
//     威胁预测(ThreatPredictor) / 出生校验(SpawnResolver) 全部已接入 IsPassable + GetActionCost。
//     所以"做地形"= 把 terrainType 刷对，不需要写任何额外的移动代码。
//
// 设计依据：2026-09-11 地图重做决策
//   · 地景固定、篝火固定、宝箱位置固定；事件格随机撒、宝箱内容随机
//   · 红墙（Mountain）围出可进入的室内；室内独立地板色
//   · 篝火密度约每 190 格 1 个（1500 格 → 7-8 个）
//   · 出生点 = 撤离点 = 玩家的"家"
//
// 文本格式（列 = x 向右递增；行 = y 向下递增，即第 1 行是 y=0、位于屏幕最上方）：
//   .  平地（1 AP，可通行）
//   f  树林（2 AP，可通行）
//   w  水  （3 AP，可通行）
//   #  红墙（不可通行）—— 用来围房屋 / 室内结构
//   _  室内木地板（1 AP，可通行）
//   c  室内木地板 + 宝箱（连片摆放时写成一排 ccccc）
//   S  出生点（=家=撤离点，室外平地；每张图只能有 1 个）
//   s  出生点（同上，但落在室内木地板上——"家"在屋里的图用这个）
//   F  篝火
//   C  室外宝箱
//   E  事件候选位（本批只登记坐标，事件格由运行期随机撒）
//   x  遭遇区（★2026-09-12）——「这一带会刷怪」，连成一片 = 一个区。
//      ★只圈区域，不写具体怪物：刷几支小队 / 什么类型 / 走什么巡逻路线，
//        每局由 EncounterDirector 在区内掷点决定。
//   // 行首注释；空行忽略
//
// ★2026-09-12 敌人「去地图化」（用户定调）：
//   地图文本**不再直接放怪**（旧的 g / m / G 字符已删除）——怪物生成应该是随机的。
//   现在敌人只有两个来源，都不能是「某个格子上钉着一只怪」：
//     ① SquadPatrols/*.asset —— 固定巡逻（教程 / 剧情 / 手工精摆），可带 ±N 小随机
//     ② 本文件的 x 遭遇区 + EncounterTable —— 每局随机的数量 / 类型 / 路径（正式图主力）
//
// ★2026-09-12 教程图 v3 字符：
//   I  入（玩家进场/出生格，室外平地；替代 S 在教程图里的角色）
//   H  家（教程剧情格；不承担出生点职责——出生点已由 I 承担）
//   o  敌方专用口（家所在的"上/下"开口）—— 巡逻队进出锚点；
//      玩家能站上去，但界外没有格子 → 走不出去（零新机制）
//   O  藏身处入口 —— 走到此格教程结束，进入局外藏身处
//   段序：I 入 → H 家(o 上/下口) → 卡口 → 怪1 → F 篝火 + C 箱子
//         → 大室 怪2 + 怪3 → 小走廊 → O 藏身处入口
//   ⚠️ 教程图的这几只怪写在 SquadPatrols 资产里（mapId = tutorial_alley），不写在本文件。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 布局烘焙器：把一张人类可读的 ASCII 地图变成可玩的六边格战场。
/// ★2026-09-12：不再产出敌人点位——敌人由 SquadPatrols 资产 + x 遭遇区在运行期生成。
/// </summary>
public class MapLayoutBuilder : MonoBehaviour
{
    [Header("目标网格（场景里已有的 Map / Map1 的 HexGridLayout；材质与位置保持原样）")]
    public HexGridLayout mapGrid;
    public HexGridLayout map1Grid;

    [Header("布局源文件（Assets/Data/Maps/*.txt）")]
    public TextAsset layoutFile;

    [Header("节点预览标记（仅方便在编辑器里一眼看到篝火/宝箱/事件位，不影响玩法）")]
    public bool showPreviewMarkers = true;

    [Header("★2026-09-12 教程图标记")]
    [Tooltip("本图是新手教程图 → 隐藏「还没解锁」的系统：\n" +
             "  · 篝火面板的「调整战术卡槽」按钮\n" +
             "  · 战术卡包按钮 / 战术卡槽面板\n" +
             "  · 卡包页右侧的战术卡槽边栏（含装载/卸下门禁）\n" +
             "教程只教「移动 / 打牌 / 篝火 / 装填」，战术卡槽留到正式图再登场。")]
    public bool tutorialMap = false;

    [Header("烘焙结果（只读；供撤离点 / 宝箱 / 事件撒点等系统读取）")]
    public Vector2Int gridSize;
    [Tooltip("★2026-09-16 带材质地图：//MAT 段解析出的墙材质标签网格（x,y → MT_* 字符；无段 = null）")]
    public char[,] materialGrid;
    [Tooltip("出生点 = 家 = 撤离点")]
    public Vector2Int spawnCoord;
    public bool hasSpawn;
    public List<Vector2Int> bonfireCoords = new List<Vector2Int>();
    public List<Vector2Int> outdoorChestCoords = new List<Vector2Int>();
    public List<Vector2Int> indoorChestCoords = new List<Vector2Int>();
    [Tooltip("事件候选位：本批只登记坐标，运行期从这些位置里随机抽 N 个摆事件格")]
    public List<Vector2Int> eventCandidateCoords = new List<Vector2Int>();

    [Header("★2026-09-12 教程图 v3 节点（布局字符 I / H / o / O）")]
    [Tooltip("「入」——玩家进场/出生格（字符 I）。教程开场玩家在此")]
    public Vector2Int entranceCoord;
    public bool hasEntrance;
    [Tooltip("「家」——教程剧情格（字符 H）。不承担出生点职责，出生点由 I 承担")]
    public Vector2Int homeCoord;
    public bool hasHome;
    [Tooltip("敌方专用口（字符 o）——家所在列的「上/下」开口，巡逻队进出锚点。" +
             "玩家能站上去，但界外没有格子 → 走不出去")]
    public List<Vector2Int> enemyGateCoords = new List<Vector2Int>();
    [Tooltip("「藏身处入口」（字符 O）——走到此格教程结束，进入局外藏身处")]
    public Vector2Int homebaseEntranceCoord;
    public bool hasHomebaseEntrance;

    [Header("★2026-09-12 遭遇区（布局字符 x）——「这一带会刷怪」，不指定具体怪物")]
    [Tooltip("遭遇区的原始格子（连成一片的 x）。归组结果见 encounterZones")]
    public List<Vector2Int> encounterZoneCoords = new List<Vector2Int>();
    [Tooltip("按六边连通性归组后的遭遇区。EncounterDirector 在运行期逐区掷点刷怪")]
    public List<EncounterZone> encounterZones = new List<EncounterZone>();

    /// <summary>所有宝箱格（室外 + 室内），供宝箱系统一次性读取。</summary>
    public IEnumerable<Vector2Int> AllChestCoords
    {
        get
        {
            foreach (var c in outdoorChestCoords) yield return c;
            foreach (var c in indoorChestCoords) yield return c;
        }
    }

    // ------------------------------------------------------------------
    // 教程图判定（★2026-09-12）
    // ------------------------------------------------------------------
    // 谁需要它：篝火面板（是否给「调整战术卡槽」按钮）、战术卡槽面板（是否显示战术按钮）、
    //           卡包页（是否铺战术卡槽边栏 / 是否允许装载）。
    // 为什么仍用「场景里的烘焙器」而不是场景名：★2026-09-15 场景已拆分（TutorialScene /
    // FogTownScene，一个场景 = 一张图），场景名本来也能判了；但判据继续跟着「布局文件」走更稳
    // —— 它不会因为场景改名 / 被复制而静默失配，而十几处调用点都读这个属性。

    private static MapLayoutBuilder _active;

    /// <summary>当前场景是不是新手教程图（烘焙器上的 tutorialMap 开关）。</summary>
    public static bool IsTutorial
    {
        get
        {
            if (_active == null) _active = FindObjectOfType<MapLayoutBuilder>();
            return _active != null && _active.tutorialMap;
        }
    }

    private void Awake()
    {
        _active = this;
    }

    // ------------------------------------------------------------------
    // 烘焙
    // ------------------------------------------------------------------

    [ContextMenu("Build Map From Layout")]
    public void BuildFromLayout()
    {
        if (layoutFile == null)
        {
            Debug.LogError("[MapLayoutBuilder] 未指定布局文件（layoutFile）");
            return;
        }
        if (mapGrid == null || map1Grid == null)
        {
            Debug.LogError("[MapLayoutBuilder] 未指定 Map / Map1 的 HexGridLayout");
            return;
        }

        List<string> rows;
        List<string> matRows;
        SplitLayoutSections(layoutFile.text, out rows, out matRows);
        if (rows.Count == 0)
        {
            Debug.LogError("[MapLayoutBuilder] 布局文件没有有效行（检查是否全是注释/空行）");
            return;
        }

        int h = rows.Count;
        int w = 0;
        for (int i = 0; i < rows.Count; i++) w = Mathf.Max(w, rows[i].Length);
        gridSize = new Vector2Int(w, h);

        // ---- ⓪ 材质网格（★2026-09-16 带材质地图）：//MAT 段 → char[,]，无段 = null（手写图照旧）----
        materialGrid = null;
        if (matRows != null && matRows.Count > 0)
        {
            var grid = new char[w, h];
            for (int y = 0; y < h; y++)
            {
                string mrow = y < matRows.Count ? matRows[y] : null;
                if (mrow == null) continue;
                for (int x = 0; x < w; x++)
                    grid[x, y] = x < mrow.Length ? mrow[x] : '\0';
            }
            materialGrid = grid;
        }

        // ---- ① 重建网格（Map 与 Map1 同尺寸，共 2×w×h 个六边格）----
        mapGrid.gridSize = gridSize;
        map1Grid.gridSize = gridSize;
        mapGrid.LayoutGrid();
        map1Grid.LayoutGrid();

        // ---- ② 刷地形 + ③ 登记节点 ----
        ResetRegistries();
        var index = BuildTileIndex(mapGrid);
        TerrainManager terrain = Object.FindObjectOfType<TerrainManager>();
        if (terrain != null) terrain.ClearWallTags();   // ★换图防串味：清掉上一局的墙材质标签

        for (int y = 0; y < h; y++)
        {
            string row = rows[y];
            for (int x = 0; x < w; x++)
            {
                char c = x < row.Length ? row[x] : '.';
                Vector2Int coord = new Vector2Int(x, y);
                TerrainManager.TerrainType type = TerrainFromChar(c);

                // ★红墙格先把材质标签登记进 TerrainManager（其 SetTerrain 染色路径要查这张表，
                //   否则会把墙格统一刷回标准地形色），再落数据，最后落格子上的墙材质。
                if (type == TerrainManager.TerrainType.Mountain && materialGrid != null)
                    terrain?.SetWallTag(coord, materialGrid[x, y]);

                // ★先落数据与地形色，再落墙材质 —— 顺序不能反：
                //   SetTerrain 内部会按地形类型重刷一次合并网格材质（TerrainManager.UpdateTileColor），
                //   若放在 ApplyWallMaterial 之后会把刚上的墙材质盖回标准地形色（实测踩坑 2026-09-17）。
                if (terrain != null) terrain.SetTerrain(coord, type);

                if (index.TryGetValue(coord, out HexTile tile) && tile != null)
                {
                    tile.ApplyTerrain(type);
                    // ★2026-09-16 带材质地图：红墙格附加材质标签（山体/断墙/墓碑/骨堆…），
                    //   渲染层按标签选共享材质。只对 '#'（Mountain）生效； Indoor 地板暂不区分。
                    if (type == TerrainManager.TerrainType.Mountain && materialGrid != null)
                    {
                        char tag = materialGrid[x, y];
                        if (tag != '\0' && tag != '#') tile.ApplyWallMaterial(tag);
                    }
                }

                switch (c)
                {
                    case 'S':
                    case 's':
                        spawnCoord = coord;
                        hasSpawn = true;
                        break;
                    case 'F': bonfireCoords.Add(coord); break;
                    case 'C': outdoorChestCoords.Add(coord); break;
                    case 'c': indoorChestCoords.Add(coord); break;
                    case 'E': eventCandidateCoords.Add(coord); break;
                    case 'x': encounterZoneCoords.Add(coord); break;

                    // ★2026-09-12 教程图 v3 新字符
                    case 'I':
                        entranceCoord = coord;
                        hasEntrance = true;
                        break;
                    case 'H':
                        homeCoord = coord;
                        hasHome = true;
                        break;
                    case 'o': enemyGateCoords.Add(coord); break;
                    case 'O':
                        homebaseEntranceCoord = coord;
                        hasHomebaseEntrance = true;
                        break;
                }
            }
        }

        // ---- 遭遇区：把连成一片的 x 归组成区（被墙隔开的另一片 = 另一个区）----
        encounterZones = EncounterZone.GroupConnected(encounterZoneCoords);

        // ★2026-09-16 带材质地图：诊断日志——一眼看出 //MAT 段有没有解析进来、墙标签发了多少
        if (materialGrid != null)
        {
            int wallCells = 0, tagged = 0;
            var tags = new HashSet<char>();
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    if (rows[y][x] != '#') continue;
                    wallCells++;
                    char t = materialGrid[x, y];
                    if (t != '\0' && t != '#') { tagged++; tags.Add(t); }
                }
            Debug.Log($"[MapLayoutBuilder] 材质段：{matRows.Count} 行｜墙格 {wallCells}，已带标签 {tagged}" +
                      $"（{string.Join(",", tags)}）——若 tagged=0 说明材质没生效，查这里");
        }
        else
        {
            Debug.Log("[MapLayoutBuilder] 材质段：无（本图没有 //MAT 段——手写图属正常；随机荒野出现这行说明 ToText 没带出材质）");
        }

        // ---- 篝火实体：挂在 Map1 对应格上（与 BonfireTile.CreateAtStart 的挂法一致）----
        PlaceBonfires();

        // ---- 节点预览标记 ----
        BuildPreviewMarkers();

        // ★2026-09-15 地图重构：合并网格的重建平时推到帧末批量做，这里显式刷一次，
        //   保证烘焙一结束（编辑器点菜单 / 运行期换图）地图立刻可见。
        //   顺带把 Map1 覆盖层的缓存清掉——整层刚被重建，缓存指向的是已销毁的旧层。
        HexTileColorizer.InvalidateLayerCache();
        if (mapGrid != null && mapGrid.layerRenderer != null) mapGrid.layerRenderer.Flush();
        if (map1Grid != null && map1Grid.layerRenderer != null) map1Grid.layerRenderer.Flush();

        Debug.Log($"[MapLayoutBuilder] 地图烘焙完成：{w}×{h} = {w * h} 格。\n" +
                  $"  出生点(家/撤离点)：{(hasSpawn ? spawnCoord.ToString() : "【缺失，请在布局里写一个 S】")}\n" +
                  $"  篝火 {bonfireCoords.Count} 个｜宝箱 {outdoorChestCoords.Count + indoorChestCoords.Count} 个" +
                  $"（室外 {outdoorChestCoords.Count} / 室内 {indoorChestCoords.Count}）｜事件候选位 {eventCandidateCoords.Count} 个\n" +
                  $"  遭遇区 {encounterZones.Count} 个（共 {encounterZoneCoords.Count} 格，{ZoneSummary()}）" +
                  $"｜敌人不再写在本文件里（SquadPatrols 资产 + 遭遇区运行期生成）\n" +
                  $"  ★v3：「入」{(hasEntrance ? entranceCoord.ToString() : "—")}" +
                  $"｜「家」{(hasHome ? homeCoord.ToString() : "—")}" +
                  $"｜敌方口 {enemyGateCoords.Count} 个 {string.Join(",", enemyGateCoords)}" +
                  $"｜藏身处入口 {(hasHomebaseEntrance ? homebaseEntranceCoord.ToString() : "—")}");
    }

    /// <summary>日志用：每个遭遇区的格子数与中心格。</summary>
    private string ZoneSummary()
    {
        if (encounterZones.Count == 0) return "无";
        var sb = new System.Text.StringBuilder();
        foreach (EncounterZone z in encounterZones)
        {
            if (sb.Length > 0) sb.Append(" / ");
            sb.Append($"#{z.index} 中心{z.center} {z.CellCount}格");
        }
        return sb.ToString();
    }

    [ContextMenu("Clear Map (删除 Map/Map1 全部格子)")]
    public void ClearMap()
    {
        ClearChildren(mapGrid);
        ClearChildren(map1Grid);
        ResetRegistries();
        HexTileColorizer.InvalidateLayerCache();
        Debug.Log("[MapLayoutBuilder] 已清空 Map / Map1 的全部格子");
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    private void ResetRegistries()
    {
        hasSpawn = false;
        spawnCoord = Vector2Int.zero;
        bonfireCoords.Clear();
        outdoorChestCoords.Clear();
        indoorChestCoords.Clear();
        eventCandidateCoords.Clear();
        encounterZoneCoords.Clear();
        encounterZones.Clear();
        hasEntrance = false;
        entranceCoord = Vector2Int.zero;
        hasHome = false;
        homeCoord = Vector2Int.zero;
        enemyGateCoords.Clear();
        hasHomebaseEntrance = false;
        homebaseEntranceCoord = Vector2Int.zero;
    }

    /// <summary>过滤注释行（//）与空行；保留行内空格以免错位（但行尾空白裁掉）。</summary>
    private static List<string> ParseRows(string text)
    {
        List<string> terrain, _;
        SplitLayoutSections(text, out terrain, out _);
        return terrain;
    }

    /// <summary>
    /// ★2026-09-16 带材质地图：把布局文本拆成地形段与材质段。
    ///   `//MAT` 行之后 = 材质标签网格（与地形同坐标系，同宽同高；缺格按 '\0' 补）。
    ///   没有 //MAT 段（手写图 / 旧格式）→ matRows = null，行为与从前完全一致。
    ///   其它 `//` 注释行两段都忽略；空行忽略。
    /// </summary>
    private static void SplitLayoutSections(string text, out List<string> terrainRows, out List<string> matRows)
    {
        terrainRows = new List<string>();
        matRows = null;
        bool inMat = false;
        string[] lines = text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
        foreach (string raw in lines)
        {
            string trimmed = raw.Trim();
            if (trimmed.StartsWith("//"))
            {
                if (string.Equals(trimmed, "//MAT", System.StringComparison.OrdinalIgnoreCase))
                {
                    inMat = true;
                    matRows = new List<string>();
                }
                continue;                                   // 其余注释行：两段都忽略
            }
            if (trimmed.Length == 0) continue;
            if (inMat) matRows.Add(raw.TrimEnd());
            else terrainRows.Add(raw.TrimEnd());
        }
    }

    private static TerrainManager.TerrainType TerrainFromChar(char c)
    {
        switch (c)
        {
            case 'f': return TerrainManager.TerrainType.Forest;
            case 'w': return TerrainManager.TerrainType.Water;
            case '#': return TerrainManager.TerrainType.Mountain;   // 红墙，不可通行
            case '_':
            case 'c':
            case 's': return TerrainManager.TerrainType.Indoor;     // 室内木地板
            default: return TerrainManager.TerrainType.Plain;       // . S F C E x I H o O
        }
    }

    private static Dictionary<Vector2Int, HexTile> BuildTileIndex(HexGridLayout grid)
    {
        var index = new Dictionary<Vector2Int, HexTile>();
        if (grid == null) return index;
        foreach (Transform child in grid.transform)
        {
            if (!child.name.StartsWith("Hex_")) continue;
            string[] parts = child.name.Split('_');
            if (parts.Length < 3) continue;
            if (!int.TryParse(parts[1], out int x) || !int.TryParse(parts[2], out int y)) continue;
            HexTile tile = child.GetComponent<HexTile>();
            if (tile != null) index[new Vector2Int(x, y)] = tile;
        }
        return index;
    }

    private static void ClearChildren(HexGridLayout grid)
    {
        if (grid == null) return;
        var children = new List<GameObject>();
        foreach (Transform child in grid.transform) children.Add(child.gameObject);
        foreach (var go in children)
        {
            if (Application.isPlaying) Destroy(go); else DestroyImmediate(go);
        }
    }

    private void PlaceBonfires()
    {
        if (map1Grid == null) return;
        foreach (Vector2Int coord in bonfireCoords)
        {
            Transform tile = FindChild(map1Grid.transform, coord);
            if (tile == null)
            {
                Debug.LogWarning($"[MapLayoutBuilder] 篝火：未找到 Map1 的 Hex_{coord.x}_{coord.y}");
                continue;
            }
            BonfireTile bt = tile.GetComponent<BonfireTile>();
            if (bt == null) bt = tile.gameObject.AddComponent<BonfireTile>();
            bt.coord = coord;
        }
    }

    private static Transform FindChild(Transform parent, Vector2Int coord)
    {
        if (parent == null) return null;
        string target = $"Hex_{coord.x}_{coord.y}";
        foreach (Transform child in parent)
        {
            if (child.name == target) return child;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // 节点预览标记：只为了让地图"看得见内容"，不参与任何玩法判定。
    // 真实实体（篝火 BonfireTile / 宝箱 / 事件格）由各自系统在运行期或后续批次挂载。
    // ------------------------------------------------------------------

    private const string PreviewRootName = "NodePreviewMarkers";

    private void BuildPreviewMarkers()
    {
        Transform old = transform.Find(PreviewRootName);
        if (old != null)
        {
            if (Application.isPlaying) Destroy(old.gameObject); else DestroyImmediate(old.gameObject);
        }
        // ★2026-09-15：标记纯属编辑器预览（MapNodePreviewCleaner 运行期会删掉场景里已存的），
        //   运行期干脆不再生成——雾镇遭遇区 385 格 + 宝箱/事件 ≈ 430 个标记，
        //   旧实现每个标记 new 一份自发光 Standard 材质 = 430 条不合批 draw call。
        if (!showPreviewMarkers || Application.isPlaying) return;

        Transform root = new GameObject(PreviewRootName).transform;
        root.SetParent(transform, false);

        foreach (Vector2Int c in bonfireCoords) MakeMarker(root, c, "Bonfire", new Color(1.00f, 0.42f, 0.05f));
        foreach (Vector2Int c in outdoorChestCoords) MakeMarker(root, c, "Chest", new Color(1.00f, 0.80f, 0.30f));
        foreach (Vector2Int c in indoorChestCoords) MakeMarker(root, c, "ChestIndoor", new Color(0.95f, 0.60f, 0.15f));
        foreach (Vector2Int c in eventCandidateCoords) MakeMarker(root, c, "EventSpot", new Color(0.62f, 0.35f, 0.95f));
        // ★2026-09-12：遭遇区用紫红大平板铺出来（它是「一片区域」而不是一个点，
        //   标记尺寸随格子数放大，编辑器里一眼看出哪一带会刷怪）
        foreach (EncounterZone z in encounterZones)
        {
            Color zoneColor = new Color(0.92f, 0.20f, 0.45f);
            foreach (Vector2Int c in z.cells) MakeMarker(root, c, "EncounterZone" + z.index, zoneColor, 0.9f, 0.16f);
        }

        // ★v3 教程图节点：尺寸/高度错开，俯视一眼分辨
        if (hasEntrance)
            MakeMarker(root, entranceCoord, "EntranceIn", new Color(0.20f, 0.55f, 1.00f), 1.20f, 0.30f);
        if (hasHome)
            MakeMarker(root, homeCoord, "Home", new Color(1.00f, 0.85f, 0.20f), 1.20f, 0.30f);
        foreach (Vector2Int c in enemyGateCoords)
            MakeMarker(root, c, "EnemyGate", new Color(0.10f, 0.85f, 0.85f), 0.80f, 0.22f);
        if (hasHomebaseEntrance)
            MakeMarker(root, homebaseEntranceCoord, "HomebaseEntrance", new Color(0.20f, 1.00f, 0.45f), 1.45f, 0.85f);
    }

    private void MakeMarker(Transform parent, Vector2Int coord, string label, Color color,
        float scaleMul = 1f, float yOffset = 0.45f)
    {
        Transform tile = FindChild(map1Grid != null ? map1Grid.transform : null, coord);
        if (tile == null) return;

        GameObject m = GameObject.CreatePrimitive(PrimitiveType.Cube);
        m.name = label + "_" + coord.x + "_" + coord.y;
        m.transform.position = new Vector3(tile.position.x, tile.position.y + yOffset, tile.position.z);
        // 标记尺寸随格子放大：长巷一张图有 300+ 格，远景下小方块会看不清
        float s = (map1Grid != null && map1Grid.outerSize > 0f) ? map1Grid.outerSize : 1f;
        s *= scaleMul;
        m.transform.localScale = new Vector3(0.62f * s, 0.42f * s, 0.62f * s);
        m.transform.SetParent(parent, true);

        Collider col = m.GetComponent<Collider>();
        if (col != null)
        {
            if (Application.isPlaying) Destroy(col); else DestroyImmediate(col);
        }

        Renderer r = m.GetComponent<Renderer>();
        if (r != null)
        {
            // ★2026-09-15 性能：同色标记共用一份材质（静态缓存），
            //   不再每个标记 new 一份——430 个标记从 430 份材质/430 条 draw call
            //   收敛到十来种共享材质（同材质可合批）；阴影全关（预览方块不需要投影）。
            r.sharedMaterial = GetMarkerMaterial(color);
            r.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            r.receiveShadows = false;
        }
    }

    /// <summary>标记材质按颜色缓存（★2026-09-15：见 MakeMarker 注释）。</summary>
    private static readonly Dictionary<Color, Material> s_markerMaterials = new Dictionary<Color, Material>();

    private static Material GetMarkerMaterial(Color color)
    {
        if (s_markerMaterials.TryGetValue(color, out Material cached) && cached != null) return cached;

        Material mat = new Material(Shader.Find("Standard"));
        mat.color = color;
        mat.EnableKeyword("_EMISSION");
        mat.SetColor("_EmissionColor", color * 0.9f);
        s_markerMaterials[color] = mat;
        return mat;
    }
}

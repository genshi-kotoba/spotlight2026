using UnityEngine;
using System.Collections.Generic;

public class TerrainManager : MonoBehaviour
{
    public enum TerrainType
    {
        Plain,    // 平原，默认地形
        Forest,   // 森林，绿色，需要2点行动点
        Water,    // 水域，蓝色，需要3点行动点
        Mountain, // 山脉（地图上的「红色墙」），红色，无法通行 —— 用于围出房屋/室内结构
        Indoor    // 室内木地板，暖褐色，1点行动点、可通行 —— 与室外区分，箱子密集区
    }
    
    [System.Serializable]
    public class TerrainData
    {
        public TerrainType type;
        public Color color;
        public int actionCost;
        public bool passable;
    }
    
    [Header("地形配置")]
    public List<TerrainData> terrainTypes = new List<TerrainData>();

    /// <summary>地形变更计数（VisionSystem 可见集缓存失效信号）。SetTerrain 每写一次 +1。</summary>
    public static int Version { get; private set; }

    private Dictionary<Vector2Int, TerrainType> terrainGrid = new Dictionary<Vector2Int, TerrainType>();

    // ------------------------------------------------------------------
    // ★2026-09-15 性能修复（两处，实测定位）
    // ------------------------------------------------------------------

    /// <summary>
    /// 地形数据按枚举值直接索引（O(1) 数组），替代原来的
    /// `terrainTypes.Find(t => t.type == type)`（每次调用分配一个闭包 + 线性扫描）。
    /// ★为什么必须改：A* 每访问一个邻居就要调 IsPassable + GetActionCost 各一次，
    ///   而两者内部都走 GetTerrainData → 单次寻路 ≈ 4.8 万次 List.Find + 闭包分配
    ///   （实测单次跨图寻路 8.18ms）。敌人 AI / 玩家移动成本查询同样受益。
    /// </summary>
    private TerrainData[] terrainDataByType;

    /// <summary>
    /// 坐标 → 该格 MeshRenderer 的索引（惰性构建，地图重建后必须失效重建成）。
    /// ★为什么必须改：UpdateTileColor 原来每次调用都 `GameObject.Find("Map")`（全场景扫描）
    ///   + 遍历 Map 的 4000 个子物体找名字匹配，而**烘一张 80×50 图会调用它 4000 次**
    ///   ≈ 4000 次全场景 Find + 数百万次字符串比较，这是"进雾镇好久"的主因。
    /// </summary>
    private static Transform s_mapRoot;
    private static HexLayerRenderer s_mapLayer;

    /// <summary>
    /// 地图网格被重建（HexGridLayout.LayoutGrid / ClearMap）后调用：
    /// 索引里存的是**旧格子的渲染器引用**，不失效会静默染色失败。
    /// </summary>
    public static void InvalidateTileRenderCache()
    {
        s_mapRoot = null;
        s_mapLayer = null;
    }
    
    private void Awake()
    {
        // 初始化地形类型数据
        InitializeTerrainTypes();
    }
    
    private void Start()
    {
        // 为所有格子设置默认地形，但只在terrainGrid为空时才执行
        // 这样可以保留编辑器中设置的地形
        if (terrainGrid.Count == 0)
        {
            SetDefaultTerrain();
        }
    }
    
    #if UNITY_EDITOR
    private void OnValidate()
    {
        // 在编辑器中属性变化时初始化地形类型数据
        InitializeTerrainTypes();
    }
    #endif
    
    /// <summary>
    /// 地形的权威颜色表（单一数据源）。
    /// TerrainManager 的 Inspector 配置、TerrainMaterialLibrary 的地形材质、
    /// HexTile 的编辑态上色三处都从这里取值，避免各写一份后逐渐漂移。
    /// </summary>
    public static Color DefaultColorFor(TerrainType type)
    {
        switch (type)
        {
            case TerrainType.Forest:   return new Color(0f, 0.5f, 0f);
            case TerrainType.Water:    return new Color(0f, 0f, 0.5f);
            case TerrainType.Mountain: return new Color(0.5f, 0f, 0f);
            case TerrainType.Indoor:   return new Color(0.42f, 0.32f, 0.20f);
            default:                   return Color.gray;   // Plain
        }
    }

    public void InitializeTerrainTypes()
    {
        // 清空现有数据
        terrainTypes.Clear();
        
        // 添加地形类型
        // 颜色统一走 DefaultColorFor（单一数据源，与地形材质库 / HexTile 保持一致）
        terrainTypes.Add(new TerrainData { type = TerrainType.Plain, color = DefaultColorFor(TerrainType.Plain), actionCost = 1, passable = true }); // 平原，灰
        terrainTypes.Add(new TerrainData { type = TerrainType.Forest, color = DefaultColorFor(TerrainType.Forest), actionCost = 2, passable = true }); // 小树林，暗绿，2 AP
        terrainTypes.Add(new TerrainData { type = TerrainType.Water, color = DefaultColorFor(TerrainType.Water), actionCost = 3, passable = true }); // 河流，暗蓝，3 AP
        terrainTypes.Add(new TerrainData { type = TerrainType.Mountain, color = DefaultColorFor(TerrainType.Mountain), actionCost = 0, passable = false }); // 红墙，不可通行
        terrainTypes.Add(new TerrainData { type = TerrainType.Indoor, color = DefaultColorFor(TerrainType.Indoor), actionCost = 1, passable = true }); // 室内木地板，暖褐

        // ★2026-09-15：同步重建「按枚举值索引」的快速查表（见 GetTerrainData 注释）
        RebuildTerrainLookup();
    }

    /// <summary>按枚举值重建 O(1) 查表（本类的唯一地形数据源仍是 terrainTypes 列表）。</summary>
    private void RebuildTerrainLookup()
    {
        int count = System.Enum.GetValues(typeof(TerrainType)).Length;
        terrainDataByType = new TerrainData[count];

        for (int i = 0; i < terrainTypes.Count; i++)
        {
            TerrainData d = terrainTypes[i];
            if (d == null) continue;
            int idx = (int)d.type;
            if (idx >= 0 && idx < count) terrainDataByType[idx] = d;
        }

        // 兜底：缺配置的类型一律回落平原，避免返回 null（原实现也是回落 Plain）
        TerrainData fallback = terrainDataByType[(int)TerrainType.Plain];
        for (int i = 0; i < count; i++)
        {
            if (terrainDataByType[i] == null) terrainDataByType[i] = fallback;
        }
    }
    
    private void SetDefaultTerrain()
    {
        // 找到Map对象
        GameObject mapObject = GameObject.Find("Map");
        if (mapObject != null)
        {
            // 遍历所有格子
            foreach (Transform child in mapObject.transform)
            {
                if (child.name.StartsWith("Hex_"))
                {
                    // 解析坐标
                    string[] parts = child.name.Split('_');
                    if (parts.Length >= 3)
                    {
                        int x = int.Parse(parts[1]);
                        int y = int.Parse(parts[2]);
                        Vector2Int coord = new Vector2Int(x, y);
                        
                        // 只对没有设置过地形的格子设置默认值
                        if (!terrainGrid.ContainsKey(coord))
                        {
                            SetTerrain(coord, TerrainType.Plain);
                        }
                    }
                }
            }
        }
    }
    
    public void SetTerrain(Vector2Int coord, TerrainType type)
    {
        Version++;

        // 更新字典
        terrainGrid[coord] = type;

        // 更新格子颜色
        UpdateTileColor(coord, type);
    }

    // ------------------------------------------------------------------
    // ★2026-09-17 带材质地图：墙材质标签登记表
    // ------------------------------------------------------------------
    // 为什么需要：SetTerrain 的染色路径（含 HexTile.Start → UpdateTerrain 的下一帧重刷）
    // 只知道地形类型，会把红墙格统一刷回标准地形色，把 MapLayoutBuilder 上的墙材质盖掉
    // （实测踩坑：标签在格子上、合并网格里却只有 5 种地形材质）。
    // 烘焙时由 MapLayoutBuilder 先登记标签再 SetTerrain；查询侧统一"有标签 → 墙材质"。

    private readonly Dictionary<Vector2Int, char> wallTags = new Dictionary<Vector2Int, char>();

    /// <summary>登记/清除某格的墙材质标签（烘焙期调用；'\0' 或 '#' = 清除）。</summary>
    public void SetWallTag(Vector2Int coord, char tag)
    {
        if (tag == '\0' || tag == '#') wallTags.Remove(coord);
        else wallTags[coord] = tag;
    }

    /// <summary>整图重建前清空标签登记（换图防串味）。</summary>
    public void ClearWallTags() => wallTags.Clear();

    private void UpdateTileColor(Vector2Int coord, TerrainType type)
    {
#if UNITY_EDITOR
        // ★2026-09-09：编辑态不写 renderer.material——编辑器里 HexTile.OnValidate 会链式调到这里
        //（UpdateTerrain → SetTerrain → UpdateTileColor），原来每格实例化一份材质泄漏进场景，
        // 打开场景就刷上千条红字（编辑态可视颜色由 HexTile.UpdateTileColor 自己负责）。
        // 顺带省掉编辑态 O(格子数²) 的 GameObject.Find + 子物体遍历。
        if (!Application.isPlaying) return;
#endif

        // ★2026-09-15 地图重构：格子不再自带渲染器，地形色改由本层的合并网格承载。
        //   原实现维护「coord → MeshRenderer」索引并逐格换 sharedMaterial；
        //   合并后一格就没有渲染器了，改为让 HexLayerRenderer 把该格划进对应地形材质的分组。
        // ★2026-09-17 带材质地图：红墙格有材质标签 → 墙材质（与 HexTile.UpdateTileColor 同口径）。
        HexLayerRenderer layer = FindMapLayer();
        if (layer != null)
        {
            char tag;
            Material mat = (type == TerrainType.Mountain
                            && wallTags.TryGetValue(coord, out tag) && tag != '\0')
                ? TerrainMaterialLibrary.GetWall(tag)
                : TerrainMaterialLibrary.Get(type);
            layer.SetTileMaterial(coord, mat);
        }
    }

    /// <summary>取 Map 地形层的合并网格渲染器（★2026-09-15 地图重构）。</summary>
    private static HexLayerRenderer FindMapLayer()
    {
        if (s_mapLayer != null) return s_mapLayer;

        if (s_mapRoot == null)
        {
            GameObject mapObject = GameObject.Find("Map");
            s_mapRoot = mapObject != null ? mapObject.transform : null;
        }
        if (s_mapRoot == null) return null;

        s_mapLayer = s_mapRoot.GetComponent<HexLayerRenderer>();
        return s_mapLayer;
    }

    // ★2026-09-15 地图重构：原 FindTileRenderer（coord → MeshRenderer 索引）已删除——
    //   合并网格后一格没有渲染器，地形色统一走 HexLayerRenderer.SetTileMaterial。
    
    public TerrainData GetTerrainData(Vector2Int coord)
    {
        // ★2026-09-15：改 O(1) 查表（原实现 terrainTypes.Find(闭包) 每次调用都分配委托 + 线性扫描，
        //   是 A* 8.18ms/次 的主要来源——单次寻路 ≈ 4.8 万次该调用）。
        if (terrainDataByType == null) RebuildTerrainLookup();

        if (terrainGrid.TryGetValue(coord, out TerrainType type))
        {
            int idx = (int)type;
            if (idx >= 0 && idx < terrainDataByType.Length && terrainDataByType[idx] != null)
                return terrainDataByType[idx];
        }
        // 默认返回平原
        return terrainDataByType[(int)TerrainType.Plain];
    }
    
    public bool IsPassable(Vector2Int coord)
    {
        TerrainData data = GetTerrainData(coord);
        return data.passable;
    }
    
    public int GetActionCost(Vector2Int coord)
    {
        // ★2026-09-12 用户定稿：遗物袋格 = 箱子，进格耗 2 AP（等同树林/绿色格子）。
        // 遗物袋是死亡格上的实体箱子，走到它上面要多一步「翻捡」，成本从平地 1 抬到 2。
        // 放这里是唯一数据源：玩家移动(HexMover)、A* 寻路、敌人 AI 全走 GetActionCost，一处生效。
        if (CorpseRegistry.Has(coord)) return 2;

        TerrainData data = GetTerrainData(coord);
        return data.actionCost;
    }
}
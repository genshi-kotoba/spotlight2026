using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

public class HexTile : MonoBehaviour
{
    [Header("地形设置")]
    public TerrainManager.TerrainType terrainType = TerrainManager.TerrainType.Plain;

    /// <summary>
    /// ★2026-09-16 带材质地图：红墙格的材质标签（WastelandGenerator.MT_*，A 方案 matRows）。
    /// '\0' = 无标签（手写图 / 旧格式）→ 走默认 Mountain 材质。只有 '#' 格会有非空标签。
    /// </summary>
    [HideInInspector]
    public char wallMaterialTag = '\0';
    
    [HideInInspector]
    public Vector2Int coordinates;

    /// <summary>★2026-09-15：coordinates 是否已成功解析（(0,0) 本身是合法坐标，需要标志位区分"尚未解析"）。</summary>
    [HideInInspector]
    public bool hasCoordinates;
    
    private void Start()
    {
        // 解析坐标
        ParseCoordinates();
        
        // 直接更新当前格子的颜色
        UpdateTileColor();
        // 通知TerrainManager更新地形数据
        UpdateTerrain();
    }
    
    private void OnValidate()
    {
        // 编辑器中属性变化时更新
        ParseCoordinates();
        // 直接更新当前格子的颜色，不依赖TerrainManager
        UpdateTileColor();
        // 同时通知TerrainManager更新地形数据
        UpdateTerrain();
    }
    
    private void UpdateTileColor()
    {
        // 检查物体是否属于Map，只修改Map中的对象颜色
        if (!IsTileInMap())
            return;

        // ★2026-09-15 地图重构：格子不再自带渲染器（HexRenderer 已从生成流程下线），
        //   地形色改由本层的合并网格渲染器 HexLayerRenderer 承载。
        if (s_layerRenderer == null) s_layerRenderer = GetComponentInParent<HexLayerRenderer>();
        if (s_layerRenderer == null) return;

        // 地形色仍是【每种地形一份的共享材质】（TerrainMaterialLibrary），
        // 只是最终由 HexLayerRenderer 把这一格划进该材质的分组、重建所在分块。
        // ★2026-09-16 带材质地图：红墙格带材质标签（山体/断墙/墓碑/骨堆…）→ 按标签选墙材质。
        Material mat = (terrainType == TerrainManager.TerrainType.Mountain && wallMaterialTag != '\0')
            ? TerrainMaterialLibrary.GetWall(wallMaterialTag)
            : TerrainMaterialLibrary.Get(terrainType);
        if (mat != null) s_layerRenderer.SetTileMaterial(coordinates, mat);
    }

    /// <summary>地形类型 → 格子颜色。统一委托给 TerrainManager.DefaultColorFor（单一数据源）。</summary>
    static Color ColorForTerrain(TerrainManager.TerrainType type)
    {
        return TerrainManager.DefaultColorFor(type);
    }
    
    /// <summary>
    /// 由地图生成器（MapLayoutBuilder）批量调用：设置地形并立即刷新格子颜色。
    /// 与 OnValidate 的区别：不依赖 Inspector 改动，不会触发 TerrainManager 的全量查找。
    /// </summary>
    public void ApplyTerrain(TerrainManager.TerrainType type)
    {
        terrainType = type;
        wallMaterialTag = '\0';         // ★重刷地形即重置墙标签（BuildFromLayout 之后可能紧跟 ApplyWallMaterial）
        ParseCoordinates();
        UpdateTileColor();
    }

    /// <summary>
    /// ★2026-09-16 带材质地图：给红墙格附加材质标签并立即重刷颜色。
    /// 与 ApplyTerrain 的调用序：先 ApplyTerrain(type)（重置标签），再 ApplyWallMaterial(tag)。
    /// </summary>
    public void ApplyWallMaterial(char tag)
    {
        wallMaterialTag = tag;
        UpdateTileColor();
    }

    private bool IsTileInMap()
    {
        // 检查单元格的父对象是否是map
        Transform parent = transform.parent;
        while (parent != null)
        {
            if (parent.name == "Map")
            {
                return true;
            }
            parent = parent.parent;
        }
        return false;
    }
    
    private void ParseCoordinates()
    {
        // 从物体名称解析坐标
        if (name.StartsWith("Hex_"))
        {
            string[] parts = name.Split('_');
            if (parts.Length >= 3)
            {
                int x = int.Parse(parts[1]);
                int y = int.Parse(parts[2]);
                coordinates = new Vector2Int(x, y);
                hasCoordinates = true;
            }
        }
    }
    
    private void UpdateTerrain()
    {
        // 检查物体是否属于Map，只更新Map中的对象的地形数据
        if (!IsTileInMap())
            return;

        // ★2026-09-15 性能修复：TerrainManager 引用静态缓存。
        //   原实现每个格子的 Start/OnValidate 都 FindObjectOfType 全场景扫一遍——
        //   雾镇 80×50 = Map 层 4000 格 = 进场时 4000 次全场景扫描（O(n²)），进场大卡。
        //   静态字段跨场景由 Unity 假 null 兜底：被销毁后下次调用会重新查找。
        if (s_terrainManager == null)
        {
            s_terrainManager = FindObjectOfType<TerrainManager>();
        }
        if (s_terrainManager != null && coordinates != Vector2Int.zero)
        {
            s_terrainManager.SetTerrain(coordinates, terrainType);
        }
    }

    /// <summary>TerrainManager 静态缓存（★2026-09-15：见 UpdateTerrain 注释）。</summary>
    private static TerrainManager s_terrainManager;

    /// <summary>本层合并网格渲染器静态缓存（★2026-09-15 地图重构）。</summary>
    private static HexLayerRenderer s_layerRenderer;

    /// <summary>无法解析坐标时的返回值（染色会被 HexLayerRenderer 忽略）。</summary>
    public static readonly Vector2Int InvalidCoord = new Vector2Int(-1, -1);

    /// <summary>
    /// 从格子物体取逻辑坐标（★2026-09-15 地图重构新增）。
    /// 合并网格后格子不再自带渲染器，染色改为传坐标——这里统一提供「物体 → 坐标」的解析，
    /// 供 HexMover 的路径预览 / 视野高亮等"手里只有 GameObject"的地方使用。
    /// 优先读组件缓存（避免每次重新 Split 名字产生 GC），回落名字解析。
    /// </summary>
    public static Vector2Int CoordOf(GameObject tile)
    {
        if (tile == null) return InvalidCoord;

        HexTile ht = tile.GetComponent<HexTile>();
        if (ht != null && ht.hasCoordinates) return ht.coordinates;

        // 兜底：解析 Hex_x_y（组件尚未 Start、或 coordinates 还没解析时走这里）
        string[] parts = tile.name.Split('_');
        if (parts.Length >= 3 && int.TryParse(parts[1], out int x) && int.TryParse(parts[2], out int y))
            return new Vector2Int(x, y);

        return InvalidCoord;
    }
}
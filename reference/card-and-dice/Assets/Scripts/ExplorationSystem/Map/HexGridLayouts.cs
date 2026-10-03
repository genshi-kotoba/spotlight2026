// =============================================================================
// 模块：探索系统 - 六边格布局生成器 HexGridLayout
// 用途：按 gridSize 生成 Hex_x_y 数据节点（坐标 / 地形数据 / 碰撞体 / 挂载点），
//       并把「绘制」交给同节点的 HexLayerRenderer（整层合并网格）。
//
// ★2026-09-15 地图重构（用户拍板）：
//   原来这里给每格 AddComponent<HexRenderer>()（MeshFilter + MeshRenderer + MeshCollider）
//   → 雾镇 80×50 两层共 8000 个渲染器，CPU 每帧要为它们做剔除 / 排序 / 合批准备，
//   实测两层合计 ≈ 8ms（占整帧 17ms 近一半），是「什么都没做也只有 50 帧」的真身。
//   现在格子只保留【数据节点】，渲染改由 HexLayerRenderer 整层合并成少数几个网格。
//
//   刻意保留 Hex_x_y 节点与它的名字格式，因为十几处调用点把它当"地址"用：
//     · transform.Find($"Hex_{x}_{y}")   —— 出生点落位、篝火挂载、事件挂载、
//                                            教程投放、尸体标记、敌方意图视觉
//     · 射线命中 hit.collider.name.StartsWith("Hex_") —— 玩家悬停/点击/绑坐标、
//                                            敌人向下射线绑坐标、篝火与事件点击
//     · GameObject.Find("Map") 下的子物体遍历 —— 地形默认值、高亮清除
//   保留它们 ⇒ 上述链路全部零改动。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

[ExecuteAlways]
public class HexGridLayout : MonoBehaviour
{
    [Header("网格设置")]
    public Vector2Int gridSize = new Vector2Int(5, 5);

    [Header("方块设置")]
    public float outerSize = 1f;
    public float innerSize = 0f;
    public float height = 0.5f;
    public Material material;

    [Header("碰撞体生成")]
    [Tooltip("是否给格子生成 MeshCollider。Map 层必须开（鼠标拾取与落点解析全靠它）；Map1 高光层关掉")]
    public bool generateColliders = true;

    [Header("★2026-09-15 批量渲染")]
    [Tooltip("承担本层绘制的合并网格渲染器。留空时 LayoutGrid / 打开场景会自动补上。")]
    public HexLayerRenderer layerRenderer;

    /// <summary>当前网格的格子总数（LayoutGrid 之后有效）。</summary>
    public int TileCount => Mathf.Max(0, gridSize.x) * Mathf.Max(0, gridSize.y);

    /// <summary>
    /// 层语义：地形层（节点名 "Map"）按 HexTile.terrainType 上色；
    /// 覆盖层（"Map1"：边框 + 高亮）统一用 material 底色。
    /// 判据与 HexTile.IsTileInMap() 保持一致（都认节点名 "Map"）。
    /// </summary>
    public bool IsTerrainLayer => name == "Map";

    // 在编辑器面板里，右键点击脚本组件，选择 "Generate Grid" 即可刷新
    [ContextMenu("Generate Grid")]
    public void LayoutGrid()
    {
        // ★2026-09-15：网格重建 → TerrainManager 的「坐标 → 格子渲染器」索引立即失效。
        //   不失效的后果：索引里存的是刚被 Destroy 的旧格子，后续 SetTerrain 染色静默失败。
        TerrainManager.InvalidateTileRenderCache();

        // 1. 清理所有旧格子。只删 Hex_ 前缀——_HexBatch 是合并网格容器，归 HexLayerRenderer 管。
        List<GameObject> children = new List<GameObject>();
        foreach (Transform child in transform)
        {
            if (!child.name.StartsWith("Hex_")) continue;
            children.Add(child.gameObject);
        }
        // 保持 DestroyImmediate：BuildFromLayout 在 LayoutGrid 之后【立刻】重建坐标索引，
        //   延迟销毁（Destroy）会让新旧同名格子同时存在 → 索引可能指向将被销毁的旧对象。
        children.ForEach(child => DestroyImmediate(child));

        // 2. 生成数据节点
        Mesh sharedHexMesh = HexMeshFactory.Get(innerSize, outerSize, height);
        for (int y = 0; y < gridSize.y; y++)
        {
            for (int x = 0; x < gridSize.x; x++)
            {
                GameObject tile = new GameObject($"Hex_{x}_{y}");
                tile.transform.SetParent(this.transform);
                tile.transform.localPosition = HexLocalPos(x, y, outerSize);

                tile.AddComponent<HexTile>();

                // ★碰撞体挂在数据节点上（这一格已经没有 MeshRenderer 了）：
                //   射线命中后 hit.collider.name 仍是 Hex_x_y / tag 仍是 Ground，
                //   玩家拾取、敌人绑坐标、篝火与事件点击全部照旧。
                if (generateColliders && sharedHexMesh != null)
                {
                    MeshCollider mc = tile.AddComponent<MeshCollider>();
                    mc.sharedMesh = sharedHexMesh;
                }

                tile.tag = "Ground";
            }
        }

        // 3. 交给合并网格渲染器绘制
        EnsureLayerRenderer();
        if (layerRenderer != null)
        {
            layerRenderer.Configure(gridSize, innerSize, outerSize, height, material);
        }

        Debug.Log($"六边形网格已生成！{gridSize.x}×{gridSize.y} = {TileCount} 格（合并网格渲染，不再每格一个渲染器）");
    }

    /// <summary>格坐标 → 本地位置（平顶六边形；x 向右递增，y 向下递增）。</summary>
    public static Vector3 HexLocalPos(int x, int y, float outerSize)
    {
        float s = outerSize;
        float w = 2f * s * 0.75f;
        float h = Mathf.Sqrt(3) * s;
        float offset = (x % 2 != 0) ? h / 2f : 0;
        return new Vector3(x * w, 0, -(y * h + offset));
    }

    // ------------------------------------------------------------------
    // 旧版「每格一个渲染器」清理
    // ------------------------------------------------------------------

    /// <summary>
    /// 清掉格子上旧版「每格一个渲染器」的组件（HexRenderer + 它带来的 MeshFilter / MeshRenderer）。
    ///
    /// ★为什么需要（2026-09-15 地图重构收尾）：
    ///   TutorialScene 里的教程图是【编辑期烘焙进场景】的那份，而 ExpeditionMapRouter 刻意
    ///   「教程图不重烘焙」。于是重构前烘焙的 HexRenderer 一直活到现在，后果有三：
    ///     ① 与 HexLayerRenderer 的合并网格**重复绘制**同一片几何；
    ///     ② 继续交「每格一个 MeshRenderer」的 CPU 人头税（教程图 520×2 = 1040 个）；
    ///     ③ 它的材质是烘焙时的旧值，而 HexTile 的地形色已改走 HexLayerRenderer，
    ///        两边会显示不一致（改了地形看不出来）。
    ///   碰撞体不受影响 —— MeshCollider 是独立组件，删掉 HexRenderer 之后它仍在，
    ///   鼠标拾取 / 落点解析 / 敌人绑坐标全部照旧。
    /// </summary>
    /// <returns>清掉的格子数（0 = 本来就是干净的）。</returns>
    public int StripLegacyTileRenderers()
    {
        int stripped = 0;
        foreach (Transform child in transform)
        {
            if (!child.name.StartsWith("Hex_")) continue;

            HexRenderer legacy = child.GetComponent<HexRenderer>();
            MeshFilter filter = child.GetComponent<MeshFilter>();
            MeshRenderer draw = child.GetComponent<MeshRenderer>();
            if (legacy == null && filter == null && draw == null) continue;

            // 运行时 Destroy（延迟到帧末即可），编辑态必须 DestroyImmediate 才会落盘。
            if (legacy != null) { if (Application.isPlaying) Destroy(legacy); else DestroyImmediate(legacy); }
            if (filter != null) { if (Application.isPlaying) Destroy(filter); else DestroyImmediate(filter); }
            if (draw != null) { if (Application.isPlaying) Destroy(draw); else DestroyImmediate(draw); }
            stripped++;
        }
        return stripped;
    }

    /// <summary>本层是否已经有 Hex_x_y 数据节点。</summary>
    public bool HasHexTiles()
    {
        foreach (Transform child in transform)
            if (child.name.StartsWith("Hex_")) return true;
        return false;
    }

    // ------------------------------------------------------------------
    // 层渲染器
    // ------------------------------------------------------------------

    public void EnsureLayerRenderer()
    {
        if (layerRenderer == null) layerRenderer = GetComponent<HexLayerRenderer>();
        if (layerRenderer == null) layerRenderer = gameObject.AddComponent<HexLayerRenderer>();
    }

    private void OnEnable()
    {
        if (Application.isPlaying)
        {
            // 把合并网格建起来并（顺带）清掉旧版每格渲染器。两种情况都会走到这里：
            //   · 打开场景：合并网格标了 HideFlags.DontSave（不进场景），需要重建 ——
            //     教程图至今直接用场景烘焙版（路由刻意不为它重烘焙），它的格子还带着
            //     重构前的 HexRenderer，靠 RebuildLayerFromTiles 里的清理一并处理；
            //   · 播放中改脚本触发域重载：非序列化的 _chunks 被清空，而块对象留存成
            //     "孤儿块" ⇒ 地图继续渲染旧几何、染色静默失效（就地重建一次即可自愈）。
            if (layerRenderer == null) layerRenderer = GetComponent<HexLayerRenderer>();
            if (layerRenderer != null && !layerRenderer.IsConfigured && HasHexTiles())
            {
                RebuildLayerFromTiles();
            }
            return;
        }
#if UNITY_EDITOR
        // 合并网格标了 HideFlags.DontSave（不进场景），所以打开场景时要重建一次，
        // 否则编辑器里 Map / Map1 会是空的。delayCall 避开序列化流程中做重活。
        UnityEditor.EditorApplication.delayCall -= EditorPreviewRebuild;
        UnityEditor.EditorApplication.delayCall += EditorPreviewRebuild;
#endif
    }

#if UNITY_EDITOR
    private void OnValidate()
    {
        if (Application.isPlaying) return;
        UnityEditor.EditorApplication.delayCall -= EditorPreviewRebuild;
        UnityEditor.EditorApplication.delayCall += EditorPreviewRebuild;
    }

    /// <summary>编辑态重建入口（`delayCall` 调用；正文见 RebuildLayerFromTiles）。</summary>
    private void EditorPreviewRebuild()
    {
        if (this == null || Application.isPlaying) return;
        RebuildLayerFromTiles();
    }
#endif

    /// <summary>
    /// 从场景里已有的 Hex_x_y 数据节点重建本层合并网格（网格尺寸反推 + 地形色回填）。
    /// 编辑态【打开场景】与运行时【播放中改脚本触发域重载之后】都要用到，
    /// 所以这里刻意不设 Application.isPlaying 限制。返回是否真的执行了重建。
    /// 地形色只在「地形层」（Map）生效——与运行时 HexTile.IsTileInMap() 的判据一致；
    /// Map1 覆盖层保持 material 底色（黑边框）。
    /// </summary>
    public bool RebuildLayerFromTiles()
    {
        // 顺带清掉旧版每格渲染器：凡是走「从已有 Hex_ 节点重建」的时机，
        // 都是把渲染收口到合并网格的时机（场景烘焙的教程图靠这里变干净）。
        StripLegacyTileRenderers();

        int maxX = -1, maxY = -1, count = 0;
        foreach (Transform child in transform)
        {
            if (!child.name.StartsWith("Hex_")) continue;
            string[] parts = child.name.Split('_');
            if (parts.Length < 3) continue;
            if (!int.TryParse(parts[1], out int x) || !int.TryParse(parts[2], out int y)) continue;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
            count++;
        }
        if (count == 0) return false;   // 还没生成过网格

        gridSize = new Vector2Int(maxX + 1, maxY + 1);

        EnsureLayerRenderer();
        if (layerRenderer == null) return false;

        layerRenderer.Configure(gridSize, innerSize, outerSize, height, material);

        if (IsTerrainLayer)
        {
            foreach (Transform child in transform)
            {
                if (!child.name.StartsWith("Hex_")) continue;
                string[] parts = child.name.Split('_');
                if (parts.Length < 3) continue;
                if (!int.TryParse(parts[1], out int tx) || !int.TryParse(parts[2], out int ty)) continue;

                HexTile tile = child.GetComponent<HexTile>();
                if (tile == null) continue;
                // ★2026-09-17 带材质地图：墙格带材质标签 → 按标签取墙材质（与 HexTile.UpdateTileColor 同一口径），
                //   否则这条恢复路径会把墙格统一刷回标准地形色，墙材质整层丢失。
                Material tileMat = (tile.terrainType == TerrainManager.TerrainType.Mountain && tile.wallMaterialTag != '\0')
                    ? TerrainMaterialLibrary.GetWall(tile.wallMaterialTag)
                    : TerrainMaterialLibrary.Get(tile.terrainType);
                layerRenderer.SetTileMaterial(new Vector2Int(tx, ty), tileMat);
            }
        }

        layerRenderer.Flush();
        return true;
    }

}

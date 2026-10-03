// =============================================================================
// 模块：探索系统 - 格子染色工具 HexTileColorizer
// 用途：统一「给某个格子换颜色」这件事——运行时高亮 / 移动路径预览 /
//       敌人视野预警 / 卡牌射程 / 教程禁行格，全部走这里。
//
// ★2026-09-15 地图重构（用户拍板）：本类不再要求格子自带 Renderer。
//   旧实现：拿格子的 MeshRenderer 设 MaterialPropertyBlock——前提是「每格一个渲染器」，
//   而那正是 8000 个渲染器 CPU 人头税的来源（雾镇两层实测 ≈8ms/帧）。
//   新实现：传【坐标】，转交该层的 HexLayerRenderer，由它把这一格划进对应材质的分组、
//   重建所在分块的合并网格（一帧批量一次）。
//
//   对外语义完全不变：
//     · 传 Color.black = 恢复底色（Map1 覆盖层的权威底色就是黑）；
//     · 其它颜色 = 高亮。
//
// 与地形色的分工（不变）：
//   · 运行时高亮 / 路径预览（不需要存档）→ 本类（HexLayerRenderer 的颜色材质）。
//   · 地形底色（需要存档、编辑态可见）→ TerrainMaterialLibrary 的共享材质资产，
//     同样经由 HexLayerRenderer.SetTileMaterial 落到合并网格上。
// =============================================================================
using UnityEngine;

public static class HexTileColorizer
{
    /// <summary>Map1 覆盖层渲染器缓存（全部运行时高亮都画在这一层）。</summary>
    private static HexLayerRenderer s_overlayLayer;

    /// <summary>Map1 覆盖层的权威底色（黑）。传它即「恢复底色」。</summary>
    public static readonly Color BaseBlack = Color.black;

    private const string OverlayLayerName = "Map1";

    /// <summary>取 Map1 覆盖层（边框 + 高亮层）。找不到返回 null（染色静默跳过）。</summary>
    public static HexLayerRenderer OverlayLayer
    {
        get
        {
            if (s_overlayLayer != null) return s_overlayLayer;
            GameObject go = GameObject.Find(OverlayLayerName);
            if (go == null) return null;
            s_overlayLayer = go.GetComponent<HexLayerRenderer>();
            return s_overlayLayer;
        }
    }

    /// <summary>地图重建 / 换场景后清缓存（防拿到已销毁的旧层）。</summary>
    public static void InvalidateLayerCache()
    {
        s_overlayLayer = null;
    }

    /// <summary>把 Map1 上坐标为 coord 的格子染成 color（Color.black = 恢复底色）。</summary>
    public static void SetColor(Vector2Int coord, Color color)
    {
        HexLayerRenderer layer = OverlayLayer;
        if (layer == null) return;
        layer.SetTileColor(coord, color);
    }

    /// <summary>指定层染色（需要染非 Map1 层的场合）。</summary>
    public static void SetColor(HexLayerRenderer layer, Vector2Int coord, Color color)
    {
        if (layer == null) return;
        layer.SetTileColor(coord, color);
    }

    /// <summary>读取某格当前生效的颜色（教程禁行格「存原色→还原」用）。</summary>
    public static Color GetColor(Vector2Int coord)
    {
        HexLayerRenderer layer = OverlayLayer;
        return layer != null ? layer.GetTileColor(coord) : Color.white;
    }

    /// <summary>整层恢复底色。比逐格恢复快——一次清空映射，不是 4000 次逐格赋值。</summary>
    public static void ResetAll()
    {
        HexLayerRenderer layer = OverlayLayer;
        if (layer != null) layer.ResetAll();
    }
}

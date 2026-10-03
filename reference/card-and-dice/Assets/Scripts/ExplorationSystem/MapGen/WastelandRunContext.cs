// =============================================================================
// 模块：探索系统 - WastelandRunContext 随机荒野本局上下文（生成器 → 消费方中转）
// 用途：把 WastelandGenerator 的本局产物（群系图 / 巡逻锚点 / 出生点）从生成处
//       （ExpeditionMapRouter.Route，sceneLoaded 时机）交到消费处
//       （ExpeditionEncounterBootstrap.Start）——两者之间没有直接引用，用静态中转。
//
// 生命周期：
//   · Set    —— Route() 随机荒野分支生成成功后调用；
//   · Clear  —— 雾镇（手写图）路径 / 教程路径走 Clear 语义；当局结束
//               （ExpeditionLifecycle.EndExpedition）也清，防残留污染下一局。
//
// 设计依据：docs/2026-09-15_随机远征-design.md v17 §3.5.7（巡逻队按锚点所在群系抽）
// =============================================================================
using UnityEngine;

public static class WastelandRunContext
{
    private static WastelandGenerator.WastelandLayout _layout;

    /// <summary>本局是否有随机荒野上下文（雾镇 / 教程图时为 false）。</summary>
    public static bool HasContext { get { return _layout != null; } }

    /// <summary>本局荒野产物（HasContext 为 false 时为 null）。</summary>
    public static WastelandGenerator.WastelandLayout Layout { get { return _layout; } }

    public static void Set(WastelandGenerator.WastelandLayout layout) { _layout = layout; }

    public static void Clear() { _layout = null; }

    /// <summary>
    /// 格坐标 → 群系（查群系图）。行列约定与地图文本一致：biomeRows[y][x]。
    /// 无上下文 / 越界返回 false（biome 输出 Grass 兜底）。
    /// </summary>
    public static bool TryGetBiome(Vector2Int coord, out WastelandGenerator.BiomeId biome)
    {
        biome = WastelandGenerator.BiomeId.Grass;
        if (_layout == null || _layout.biomeRows == null) return false;
        if (coord.y < 0 || coord.y >= _layout.biomeRows.Count) return false;

        string row = _layout.biomeRows[coord.y];
        if (string.IsNullOrEmpty(row) || coord.x < 0 || coord.x >= row.Length) return false;
        return TryBiomeFromLetter(row[coord.x], out biome);
    }

    /// <summary>群系字母 → BiomeId（字母表 = WastelandGenerator.Biomes[].mapLetter）。</summary>
    public static bool TryBiomeFromLetter(char letter, out WastelandGenerator.BiomeId biome)
    {
        WastelandGenerator.BiomeDef[] defs = WastelandGenerator.Biomes;
        for (int i = 0; i < defs.Length; i++)
        {
            if (defs[i].mapLetter == letter)
            {
                biome = defs[i].id;
                return true;
            }
        }
        biome = WastelandGenerator.BiomeId.Grass;
        return false;
    }
}

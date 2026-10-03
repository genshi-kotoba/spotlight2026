// =============================================================================
// 模块：M5b-2 卡牌射程高亮 CardRangeHighlight
// 用途：悬停/拖动/左键选中"有射程的卡牌"时，把玩家周围射程内的 Map1 格子染色，
//       给玩家"这张牌能打多远"的可视反馈（机制同 HexMover 移动路径虚影）。
// 设计依据：docs/superpowers/specs/2026-08-18-card-play-interaction-targeting-design.md §九-3
// ★用户需求 2026-08-18 修订：
//   1. 范围高亮改用黄色，与移动路径预览一致（原红色废弃）
//   2. 射程是纯粹的距离：六边形格距 ≤ range 即高亮，不受地形行动点消耗影响
//   3. 箭头指向有效目标时，目标所在格子单独红色高亮（HighlightTargetTile）
// ★用户需求 2026-08-18 双色语义（最终修订）：
//   黄色 = 展示射程（哪些格子可达/可选）——悬停、拖拽、箭头模式全程保留
//   红色 = 当前指向/生效的目标格子：
//     - 单一指向卡（直刺/纵劈/断筋）：箭头模式下范围保持黄色，
//       仅箭头指向的目标格变红（HighlightTargetTile）
//     - 无指向全体卡（横斩）：指向范围内所有格子 → 过线后整片变红（active=true）
//     - 自身卡（防御）：指向玩家自身 → 过线后玩家脚底格变红（active=true）
//   → Show(center, range, active)：active=false 画黄（射程展示），true 画红（无指向卡生效）
// 实现说明：
//   - 静态类，Show/Clear 成对调用。
//   - ★底色策略（2026-08-18 修订，修"黄色高亮残留"bug）：
//     Map1 格子的权威底色固定为黑色（HexMover.InitializeMap1Colors 启动染黑，
//     且 HexMover 所有清理路径都恢复黑色）。本类 Clear 也统一恢复黑色，
//     不再"保存当前色→恢复"——若保存瞬间格子上残留移动路径预览的黄
//     （鼠标从地图滑上卡牌时预览未必已清），旧方案会把黄色当"原色"写回，
//     两套系统交错时序下产生无法复现的黄色残留。
//   - 距离计算复用 CardExecutor.HexDistance（六边形 offset→cube 距离）。
//   - ★2026-09-11 性能：染色改走 HexTileColorizer（MaterialPropertyBlock）。
//     原实现用 renderer.material.color，而 renderer.material 每次访问都会
//     克隆一份材质实例——240 格的 Map1 上单次悬停就会克隆几百份材质并破坏合批，
//     1500 格正式图会更严重。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class CardRangeHighlight
{
    /// <summary>Map1 格子权威底色（与 HexMover.InitializeMap1Colors 一致）</summary>
    private static readonly Color BaseColor = Color.black;

    /// <summary>可用范围颜色（半透明黄，与 HexMover.pathColor 移动预览一致）——"能打多远"</summary>
    private static readonly Color RangeColor = new Color(1f, 1f, 0f, 0.5f);

    /// <summary>生效范围颜色（半透明红）——"打出去后哪些格子/目标生效"（★2026-08-17 用户双色语义）</summary>
    private static readonly Color ActiveColor = new Color(1f, 0.25f, 0.2f, 0.5f);

    /// <summary>指向目标格颜色（更亮的红，区别于生效范围红——"锁定目标"语义）</summary>
    private static readonly Color TargetColor = new Color(1f, 0.35f, 0.3f, 0.55f);

    // ★2026-09-15 地图重构：格子不再自带渲染器，全部按坐标记录（Clear 时恢复底色）
    private static readonly List<Vector2Int> _tintedCoords = new List<Vector2Int>();

    /// <summary>当前红高亮的目标格（null = 无）</summary>
    private static Vector2Int? _targetCoord = null;

    /// <summary>当前范围染色使用的颜色（黄/红，HighlightTargetTile 恢复旧目标格时用）</summary>
    private static Color _currentRangeColor = RangeColor;

    /// <summary>Map1 缓存（★2026-08-17 性能：避免每次 Show 都 GameObject.Find 全场景找）</summary>
    private static GameObject _map1Cache;

    /// <summary>
    /// 高亮 center 坐标周围六边形距离 range 内的所有 Map1 格子。
    /// ★用户 2026-08-18：range == 0 时高亮 center 自身一格（防御等自身卡
    /// "过线=可打出"时高亮玩家脚底格的反馈）；range < 0 才等价于 Clear。
    /// ★用户 2026-08-17 双色语义：active=false 黄色（可用范围预览），
    /// active=true 红色（打出去后生效的格子）。
    /// 重复调用自动先清旧高亮（悬停切换卡牌时刷新）。
    /// </summary>
    /// <param name="center">中心坐标（一般是玩家 CurrentCoord）</param>
    /// <param name="range">射程（六边形格距，纯距离不受地形影响）</param>
    /// <param name="active">true=红色生效态；false=黄色可用态（默认）</param>
    public static void Show(Vector2Int center, int range, bool active = false)
    {
        Clear();
        if (range < 0) return;

        if (_map1Cache == null) _map1Cache = GameObject.Find("Map1");
        GameObject map1 = _map1Cache;
        if (map1 == null) return;

        _currentRangeColor = active ? ActiveColor : RangeColor;

        foreach (Transform child in map1.transform)
        {
            // 解析格子名 Hex_x_y（与 HexMover.FindTileByCoordInMap1 同格式）
            Vector2Int coord;
            if (!TryParseTileName(child.name, out coord)) continue;
            if (CardExecutor.HexDistance(center, coord) > range) continue;

            // 染色并记录（底色恢复用权威黑色，不存当前色——见文件头注释）
            // ★2026-09-15 地图重构：改传坐标（合并网格按坐标染色）
            _tintedCoords.Add(coord);
            HexTileColorizer.SetColor(coord, _currentRangeColor);
        }
    }

    /// <summary>
    /// 箭头指向有效目标时，把目标所在格子红高亮（叠加在范围染色之上）。
    /// 每帧调用安全：目标变化时先把旧目标格恢复成当前范围色（黄或红），再染新目标格。
    /// coord = null 时只清除红高亮（指向无效/空目标时）。
    /// </summary>
    public static void HighlightTargetTile(Vector2Int? coord)
    {
        // 恢复旧目标格为当前范围色（目标格必然在射程范围内）
        if (_targetCoord.HasValue)
        {
            HexTileColorizer.SetColor(_targetCoord.Value, _currentRangeColor);
            _targetCoord = null;
        }

        if (coord == null) return;

        // 目标格必须在本轮高亮范围内（理论不发生，射程判定已过滤）
        if (!_tintedCoords.Contains(coord.Value)) return;

        _targetCoord = coord.Value;
        HexTileColorizer.SetColor(coord.Value, TargetColor);
    }

    /// <summary>清除射程高亮与目标格红高亮，恢复格子底色（权威黑色）</summary>
    public static void Clear()
    {
        for (int i = 0; i < _tintedCoords.Count; i++)
        {
            HexTileColorizer.SetColor(_tintedCoords[i], BaseColor);
        }
        _tintedCoords.Clear();
        _targetCoord = null;
        _currentRangeColor = RangeColor;
    }

    /// <summary>解析格子名 Hex_x_y → 坐标</summary>
    private static bool TryParseTileName(string name, out Vector2Int coord)
    {
        coord = default;
        if (string.IsNullOrEmpty(name) || !name.StartsWith("Hex_")) return false;

        string[] parts = name.Split('_');
        if (parts.Length != 3) return false;

        int x, y;
        if (!int.TryParse(parts[1], out x) || !int.TryParse(parts[2], out y)) return false;

        coord = new Vector2Int(x, y);
        return true;
    }
}

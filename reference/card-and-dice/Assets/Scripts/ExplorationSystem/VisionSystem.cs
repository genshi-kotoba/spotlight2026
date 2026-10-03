// =============================================================================
// 模块：视野系统（★2026-09-16 用户定稿「红/绿阻挡」；★2026-09-17 修订「直线判定」）
// 用途：统一敌我视野判定，替换所有 HexDistance ≤ visionRange 的纯距离口径。
// 规则（docs/2026-09-16_视野阻挡-design.md，只作用于视野判定，不碰攻击射程）：
//   视野不拐弯：看得见 ⇔ 从观察者到目标的**直线**上没有红格，且
//   直线距离 ≤ 有效视野（敌人侧：直线穿过绿格 → 视野 -1，最多 -1；玩家侧 10 格不扣绿）。
//   红格（Mountain，不可通行）在直线上任何一格（含目标格）→ 直接看不见；
//   绿格（Forest）在直线上（含目标格）→ 有效视野 -1（穿一片林和穿两片林效果相同）。
// 实现：六角网格直线插值（cube 坐标 lerp，红blobgames 算法）+ 逐格查地形。
//   可见集按 (起点, 视距, 绿罚) 缓存；地形变更 / 切场景 / 超上限清空。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class VisionSystem
{
    public const int BasePlayerVisionRange = 10;
    public const bool EnemyGreenPenalty = true;

    /// <summary>
    /// 玩家当前视野：基础 10 + 整装被动加值（RunModifiers.VisionRangeBonus，随当局销毁）。
    /// ★2026-09-17 由 const 改为属性（B4 整装被动可加视野）；调用点写法不变。
    /// </summary>
    public static int PlayerVisionRange
    {
        get { return BasePlayerVisionRange + RunModifiers.VisionRangeBonus; }
    }

    const int CacheCap = 768;

    static readonly Dictionary<long, HashSet<Vector2Int>> _cache = new Dictionary<long, HashSet<Vector2Int>>();
    static readonly List<Vector2Int> _lineScratch = new List<Vector2Int>();
    static int _terrainVersion = -1;
    static HexGridLayout _grid;
    static TerrainManager _terrain;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
    static void HookSceneLoad()
    {
        UnityEngine.SceneManagement.SceneManager.sceneLoaded += (s, m) => ClearCache();
    }

    public static void ClearCache()
    {
        _cache.Clear();
        _terrainVersion = TerrainManager.Version;
        _grid = null;
        _terrain = null;
    }

    /// <summary>六角距离（odd-q offset → cube，与 CardExecutor.HexDistance 同公式，本系统自持不跨模块）。</summary>
    public static int Distance(Vector2Int a, Vector2Int b)
    {
        int dx = b.x - a.x;
        int dz = (b.y - (b.x - (b.x & 1)) / 2) - (a.y - (a.x - (a.x & 1)) / 2);
        int dy = -dx - dz;
        int m = Mathf.Abs(dx);
        if (Mathf.Abs(dy) > m) m = Mathf.Abs(dy);
        if (Mathf.Abs(dz) > m) m = Mathf.Abs(dz);
        return m;
    }

    /// <summary>
    /// 六角网格直线：from 与 to 之间（不含两端）的格子，按红blobgames cube 插值取整。
    /// 结果写入 outCells（先 Clear）。
    /// </summary>
    static void LineBetweenInto(Vector2Int from, Vector2Int to, int n, List<Vector2Int> outCells)
    {
        outCells.Clear();
        if (n < 2) return;

        float ax = from.x;
        float az = from.y - (from.x - (from.x & 1)) / 2f;
        float bx = to.x;
        float bz = to.y - (to.x - (to.x & 1)) / 2f;

        for (int i = 1; i < n; i++)
        {
            float t = (float)i / n;
            float px = ax + (bx - ax) * t;
            float pz = az + (bz - az) * t;
            float py = -px - pz;

            int rx = (int)Mathf.Round(px);
            int rz = (int)Mathf.Round(pz);
            int ry = (int)Mathf.Round(py);

            float dx = Mathf.Abs(rx - px);
            float dy = Mathf.Abs(ry - py);
            float dz = Mathf.Abs(rz - pz);

            if (dx > dy && dx > dz) rx = -ry - rz;
            else if (dy > dz) ry = -rx - rz;
            else rz = -rx - ry;

            outCells.Add(new Vector2Int(rx, rz + (rx - (rx & 1)) / 2));
        }
    }

    /// <summary>from 是否看得见 to（绿罚开关区分敌我口径；直线判定，不拐弯）。</summary>
    public static bool CanSee(Vector2Int from, Vector2Int to, int range, bool greenPenalty)
    {
        if (_grid == null) _grid = Object.FindObjectOfType<HexGridLayout>();
        if (_terrain == null) _terrain = Object.FindObjectOfType<TerrainManager>();
        return CanSeeGrid(from, to, range, greenPenalty);
    }

    static bool CanSeeGrid(Vector2Int from, Vector2Int to, int range, bool greenPenalty)
    {
        if (range <= 0) return false;
        if (from == to) return true;
        int dist = Distance(from, to);
        if (dist > range) return false;

        // 直线途经格：两端之间 + 目标格本身（目标格是红→看不见；是绿→计入穿林）
        _lineScratch.Clear();
        LineBetweenInto(from, to, dist, _lineScratch);
        _lineScratch.Add(to);

        bool hasGrid = _grid != null;
        TerrainManager terrain = _terrain;
        bool sawGreen = false;
        for (int i = 0; i < _lineScratch.Count; i++)
        {
            Vector2Int c = _lineScratch[i];
            if (hasGrid && (c.x < 0 || c.y < 0 || c.x >= _grid.gridSize.x || c.y >= _grid.gridSize.y)) return false;
            if (terrain != null)
            {
                if (!terrain.IsPassable(c)) return false;
                if (terrain.GetTerrainData(c).type == TerrainManager.TerrainType.Forest) sawGreen = true;
            }
        }
        return !(greenPenalty && sawGreen && dist > range - 1);
    }

    /// <summary>可见集（带缓存）：bbox 枚举 range 内所有候选格，逐个直线判定。</summary>
    public static HashSet<Vector2Int> GetVisibleSet(Vector2Int from, int range, bool greenPenalty)
    {
        if (_terrainVersion != TerrainManager.Version)
        {
            _terrainVersion = TerrainManager.Version;
            _cache.Clear();
        }
        long key = CacheKey(from, range, greenPenalty);
        HashSet<Vector2Int> set;
        if (_cache.TryGetValue(key, out set)) return set;
        if (_cache.Count >= CacheCap) _cache.Clear();

        if (_grid == null) _grid = Object.FindObjectOfType<HexGridLayout>();
        if (_terrain == null) _terrain = Object.FindObjectOfType<TerrainManager>();

        set = new HashSet<Vector2Int>();
        if (range > 0)
        {
            set.Add(from);
            for (int dx = -range; dx <= range; dx++)
            {
                for (int dy = -range; dy <= range; dy++)
                {
                    Vector2Int to = new Vector2Int(from.x + dx, from.y + dy);
                    if (to == from) continue;
                    if (Distance(from, to) > range) continue;
                    if (CanSeeGrid(from, to, range, greenPenalty)) set.Add(to);
                }
            }
        }
        _cache[key] = set;
        return set;
    }

    static long CacheKey(Vector2Int from, int range, bool greenPenalty)
    {
        return ((long)from.x << 40) | ((long)from.y << 8) | ((long)(range & 0x7F) << 1) | (greenPenalty ? 1L : 0L);
    }

    /// <summary>
    /// 直线判定核心（纯函数，编辑态 L2 断言用，无场景依赖）。
    /// line(from,to) = 直线上「不含 from、含 to」的格子序列；dist = from..to 距离。
    /// 任一格 isBlocked → 不可见；任一格 isForest → 有效视野 -1（绿罚开启时，最多 -1）。
    /// </summary>
    public static bool CanSeeCore(Vector2Int from, Vector2Int to, int range, bool greenPenalty, int dist,
        System.Func<Vector2Int, Vector2Int, IEnumerable<Vector2Int>> line,
        System.Func<Vector2Int, bool> isBlocked,
        System.Func<Vector2Int, bool> isForest)
    {
        if (range <= 0) return false;
        if (from == to) return true;
        if (dist > range) return false;

        bool sawGreen = false;
        foreach (Vector2Int c in line(from, to))
        {
            if (isBlocked(c)) return false;
            if (isForest(c)) sawGreen = true;
        }
        return !(greenPenalty && sawGreen && dist > range - 1);
    }

    /// <summary>
    /// 可见集核心（纯函数，编辑态 L2 断言用）：BFS（neighbors）枚举 range 内候选格，
    /// 每格独立直线判定（CanSeeCore）——BFS 只负责「够得着」，直线才决定「看得见」，
    /// 因此绕墙可达但直线被墙挡的格子**不可见**（视野不拐弯）。
    /// </summary>
    public static HashSet<Vector2Int> ComputeVisibleSet(
        Vector2Int from, int range, bool greenPenalty,
        System.Func<Vector2Int, IEnumerable<Vector2Int>> neighbors,
        System.Func<Vector2Int, Vector2Int, IEnumerable<Vector2Int>> line,
        System.Func<Vector2Int, bool> isBlocked,
        System.Func<Vector2Int, bool> isForest)
    {
        var visible = new HashSet<Vector2Int>();
        if (range <= 0) return visible;
        visible.Add(from);

        var visited = new HashSet<Vector2Int>();
        visited.Add(from);
        var frontier = new List<Vector2Int>();
        frontier.Add(from);
        var next = new List<Vector2Int>();

        for (int d = 1; d <= range; d++)
        {
            next.Clear();
            for (int i = 0; i < frontier.Count; i++)
            {
                foreach (Vector2Int n in neighbors(frontier[i]))
                {
                    if (!visited.Add(n)) continue;
                    if (CanSeeCore(from, n, range, greenPenalty, d, line, isBlocked, isForest)) visible.Add(n);
                    next.Add(n);
                }
            }
            var tmp = frontier; frontier = next; next = tmp;
        }
        return visible;
    }
}

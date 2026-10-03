using UnityEngine;
using System.Collections.Generic;

public class AStarPathfinding
{
    private class Node
    {
        public Vector2Int position;
        public Node parent;
        public float gCost; // 从起点到当前节点的成本
        public float hCost; // 从当前节点到终点的预估成本
        public float fCost { get { return gCost + hCost; } }

        public Node(Vector2Int pos)
        {
            position = pos;
        }
    }

    private HexGridLayout gridLayout;
    private TerrainManager terrainManager;

    // ★修正（P2）：TerrainManager 静态缓存——本类每次寻路都 new 一次，
    // 旧实现每次 new 都 FindObjectOfType<TerrainManager>()（Unity 最慢 API 之一）。
    private static TerrainManager _cachedTerrain;

    public AStarPathfinding(HexGridLayout grid)
    {
        gridLayout = grid;
        if (_cachedTerrain == null) _cachedTerrain = Object.FindObjectOfType<TerrainManager>();
        terrainManager = _cachedTerrain;
    }

    // ==================================================================
    // ★2026-09-15 性能重写（实测：单次跨图寻路 8.18ms → 目标 < 1ms）
    // ------------------------------------------------------------------
    // 旧实现慢在三处，全部与"格子数 × 步数"相乘：
    //   ① openSet 是 List，取最小 fCost 是**线性扫描**、Remove/Contains 也是线性扫描
    //      → 整体退化成 O(n²)；
    //   ② 每展开一个节点都 `GetFlatTopNeighbors()` **新分配一个 List**（外加 int[][] 邻居表），
    //      一次寻路要分配上千个小对象；
    //   ③ 每次邻居都要 terrainManager.IsPassable + GetActionCost，而它们内部走
    //      `terrainTypes.Find(闭包)` → 单次寻路约 4.8 万次委托分配 + 线性查找。
    //      （③ 已在 TerrainManager 侧改成 O(1) 查表修复）
    // 现在的做法：格子用「一维 id = y*w + x」直接索引数组，开放集用**整型桶队列**
    //   （启发式 HexDistance 与地形成本都是整数 → f 是整数 → f 作桶下标，单调递增，
    //     O(1) 取值且完全确定），缓冲区静态复用 → 寻路过程零 GC。
    // 行为保持：占位规则 / 教学禁行格 / 终点豁免 / 地形成本 / 贴线直走快路径 全部不变；
    //   仅"同代价路径之间选哪条"可能与旧实现不同（等代价，游戏表现等价）。
    // ==================================================================

    private static readonly Vector2Int[] OddOffsets =
    {
        new Vector2Int(1, 0), new Vector2Int(1, 1), new Vector2Int(0, 1),
        new Vector2Int(-1, 1), new Vector2Int(-1, 0), new Vector2Int(0, -1)
    };

    private static readonly Vector2Int[] EvenOffsets =
    {
        new Vector2Int(1, -1), new Vector2Int(1, 0), new Vector2Int(0, 1),
        new Vector2Int(-1, 0), new Vector2Int(-1, -1), new Vector2Int(0, -1)
    };

    /// <summary>贴线直走用的邻居缓冲（同步使用、用完即弃，避免每步分配）。</summary>
    private static readonly List<Vector2Int> s_neighborScratch = new List<Vector2Int>(6);

    // 静态复用缓冲（寻路是同步单线程，不会重入）
    private static int[] s_g;
    private static int[] s_parent;
    private static bool[] s_hasG;
    private static bool[] s_closed;
    private static Queue<int>[] s_buckets;
    private static int s_bucketHigh;

    /// <summary>
    /// A* 寻路。★2026-08-19 单位占位规则（用户需求）：不论敌我，有单位站的格子不可通行——
    /// 占位格既不能作为路径中间格（绕开走），默认也不能作为终点（玩家点击占位格由
    /// HexMover 上层直接拒绝）。例外：allowOccupiedTarget=true 时终点豁免占位检查，
    /// 供敌人「向玩家格子寻路」使用（WalkTo 迭代路径时会提前停在玩家格之前，不会真踩上去）。
    /// ★2026-08-21 零碰撞混合方案（用户需求）：enemyRequester 非空时，敌人寻路把友军所在格
    /// 视为可通行（不互相卡位），只挡玩家格+虚拟保留格；落点选择由 MoveAIController.IsWalkableCell
    /// 用 IsOccupied 单独把关（最终落点仍不与友军重叠）。enemyRequester=null（玩家寻路）时行为不变。
    /// </summary>
    /// <param name="startPos">起点（移动单位自身所在格，不参与占位检查）</param>
    /// <param name="targetPos">终点</param>
    /// <param name="allowOccupiedTarget">true=终点允许被单位占据（敌人逼近玩家场景）</param>
    /// <param name="enemyRequester">发起寻路的敌人（非空=零碰撞模式，友军格可穿越）；null=玩家寻路（挡所有）</param>
    /// <param name="planningReserved">计划保留格（EnemyLandingPlanner 全局解算传入——先解算者的计划落点对本寻路表现为阻挡；null=不启用）</param>
    /// <returns>路径坐标列表（含起点终点）；null=无路可达</returns>
    public List<Vector2Int> FindPath(Vector2Int startPos, Vector2Int targetPos, bool allowOccupiedTarget = false, EnemyController enemyRequester = null, HashSet<Vector2Int> planningReserved = null)
    {
        // 一次性构建占位集合：玩家寻路挡所有；敌人寻路零碰撞只挡玩家+计划保留格
        HashSet<Vector2Int> occupied = enemyRequester != null
            ? UnitOccupancy.GetTransitOccupiedTiles(enemyRequester, planningReserved)
            : UnitOccupancy.GetOccupiedTiles(planningReserved);

        // ★2026-09-05 贴线直走优先（巡逻斜走修复）：平顶六边形里平地上「直走」与「斜走」
        // 步数相同、代价相同，标准 A* 在等代价路径中会随机选一条弯路（如 11,14→13,13→15,12
        // →…→21,14 的拱形）。先尝试「每步向目标逼近 1 格且贴起终点连线最近」的路径——
        // 长度恒等于 HexDistance（理论最优下界），被地形/单位挡住才返回 null 回退标准 A*。
        bool playerPath = enemyRequester == null;   // ★2026-09-13 教学禁行格只挡玩家路径
        List<Vector2Int> straight = TryStraightPath(startPos, targetPos, occupied, allowOccupiedTarget, playerPath);
        if (straight != null) return straight;

        // 起/终点越界：正常玩法不会发生（落点都来自地图格），为保持行为完全一致走旧实现兜底
        if (!IsInBounds(startPos) || !IsInBounds(targetPos))
            return FindPathLegacy(startPos, targetPos, allowOccupiedTarget, enemyRequester, occupied, playerPath);

        return SearchWithBuckets(startPos, targetPos, occupied, allowOccupiedTarget, playerPath);
    }

    // ------------------------------------------------------------------
    // 快速搜索：一维 id 索引数组 + 整型桶队列
    // ------------------------------------------------------------------

    private List<Vector2Int> SearchWithBuckets(Vector2Int startPos, Vector2Int targetPos,
        HashSet<Vector2Int> occupied, bool allowOccupiedTarget, bool playerPath)
    {
        int w = gridLayout.gridSize.x;
        int h = gridLayout.gridSize.y;
        int cellCount = w * h;
        EnsureBuffers(cellCount);

        int startId = startPos.y * w + startPos.x;
        int targetId = targetPos.y * w + targetPos.x;

        System.Array.Clear(s_g, 0, cellCount);
        System.Array.Clear(s_parent, 0, cellCount);
        System.Array.Clear(s_hasG, 0, cellCount);
        System.Array.Clear(s_closed, 0, cellCount);
        for (int i = 0; i <= s_bucketHigh; i++) s_buckets[i].Clear();
        s_bucketHigh = 0;

        s_hasG[startId] = true;
        s_g[startId] = 0;
        s_parent[startId] = -1;
        Push(CardExecutor.HexDistance(startPos, targetPos), startId);

        int curF = 0;

        while (true)
        {
            int curId = PopMin(ref curF);
            if (curId < 0) return null;                 // 开放集空 → 无路可达
            if (s_closed[curId]) continue;              // 同格多次入队，取最优的那次
            s_closed[curId] = true;

            if (curId == targetId) return BuildPath(startId, targetId, w);

            int cx = curId % w;
            int cy = curId / w;
            Vector2Int current = new Vector2Int(cx, cy);
            Vector2Int[] offsets = (cx & 1) != 0 ? OddOffsets : EvenOffsets;
            int gCur = s_g[curId];

            for (int i = 0; i < 6; i++)
            {
                int nx = cx + offsets[i].x;
                int ny = cy + offsets[i].y;
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;

                Vector2Int neighbor = new Vector2Int(nx, ny);

                // 地形可通行
                if (terrainManager != null && !terrainManager.IsPassable(neighbor)) continue;

                // ★2026-09-13 教学禁行格：玩家寻路不可穿过/踏上（TutorialDirector 染红的格子）
                if (playerPath && Interactions.TutorialBlockedCells.Count > 0
                    && Interactions.TutorialBlockedCells.Contains(neighbor)) continue;

                // ★2026-08-19 单位占位：有人站的格子不可通行（终点豁免见 allowOccupiedTarget）
                if (occupied.Contains(neighbor) && !(allowOccupiedTarget && neighbor == targetPos)) continue;

                int moveCost = terrainManager != null ? terrainManager.GetActionCost(neighbor) : 1;
                if (moveCost < 1) moveCost = 1;
                int newG = gCur + moveCost;

                int nid = ny * w + nx;
                if (s_hasG[nid] && s_g[nid] <= newG) continue;

                s_hasG[nid] = true;
                s_g[nid] = newG;
                s_parent[nid] = curId;

                Push(newG + CardExecutor.HexDistance(neighbor, targetPos), nid);
            }
        }
    }

    private static void EnsureBuffers(int cellCount)
    {
        if (s_g == null || s_g.Length < cellCount)
        {
            s_g = new int[cellCount];
            s_parent = new int[cellCount];
            s_hasG = new bool[cellCount];
            s_closed = new bool[cellCount];
        }
        if (s_buckets == null)
        {
            s_buckets = new Queue<int>[256];
            for (int i = 0; i < s_buckets.Length; i++) s_buckets[i] = new Queue<int>();
            s_bucketHigh = 0;
        }
    }

    /// <summary>把格 id 放进 f 值对应的桶（f 超出桶数组时按需扩容）。</summary>
    private static void Push(int f, int cellId)
    {
        if (f < 0) f = 0;
        if (f >= s_buckets.Length)
        {
            int newLen = s_buckets.Length;
            while (f >= newLen) newLen *= 2;
            var grown = new Queue<int>[newLen];
            for (int i = 0; i < grown.Length; i++)
                grown[i] = i < s_buckets.Length ? s_buckets[i] : new Queue<int>();
            s_buckets = grown;
        }
        s_buckets[f].Enqueue(cellId);
        if (f > s_bucketHigh) s_bucketHigh = f;
    }

    /// <summary>
    /// 取 f 最小的格（同 f 内先进先出）。启发式与地形成本都是整数、且启发式一致
    /// → f 沿路径单调不减 → 只需单向游标即可，无需堆。
    /// </summary>
    private static int PopMin(ref int curF)
    {
        while (curF <= s_bucketHigh)
        {
            if (s_buckets[curF].Count > 0) return s_buckets[curF].Dequeue();
            curF++;
        }
        return -1;
    }

    private static List<Vector2Int> BuildPath(int startId, int targetId, int w)
    {
        var path = new List<Vector2Int>();
        int cur = targetId;
        int guard = 100000;   // 防御性上限
        while (cur != -1 && guard-- > 0)
        {
            path.Add(new Vector2Int(cur % w, cur / w));
            if (cur == startId) break;
            cur = s_parent[cur];
        }
        path.Reverse();
        return path;
    }

    /// <summary>
    /// 旧实现（起/终点越界时的兜底，正常玩法不触发）—— 保留以保证行为完全一致。
    /// </summary>
    private List<Vector2Int> FindPathLegacy(Vector2Int startPos, Vector2Int targetPos,
        bool allowOccupiedTarget, EnemyController enemyRequester, HashSet<Vector2Int> occupied, bool playerPath)
    {
        List<Node> openSet = new List<Node>();
        Dictionary<Vector2Int, float> gCosts = new Dictionary<Vector2Int, float>();
        Dictionary<Vector2Int, Node> nodeMap = new Dictionary<Vector2Int, Node>();

        Node startNode = new Node(startPos);
        startNode.gCost = 0;
        startNode.hCost = GetDistance(startPos, targetPos);
        openSet.Add(startNode);
        gCosts[startPos] = 0;
        nodeMap[startPos] = startNode;

        while (openSet.Count > 0)
        {
            Node currentNode = openSet[0];
            for (int i = 1; i < openSet.Count; i++)
            {
                if (openSet[i].fCost < currentNode.fCost || (openSet[i].fCost == currentNode.fCost && openSet[i].hCost < currentNode.hCost))
                {
                    currentNode = openSet[i];
                }
            }

            openSet.Remove(currentNode);

            if (currentNode.position == targetPos) return RetracePath(startNode, currentNode);

            for (int d = 0; d < 6; d++)
            {
                Vector2Int[] offsets = (currentNode.position.x & 1) != 0 ? OddOffsets : EvenOffsets;
                Vector2Int neighborPos = currentNode.position + offsets[d];

                if (!IsInBounds(neighborPos)) continue;
                if (terrainManager != null && !terrainManager.IsPassable(neighborPos)) continue;
                if (playerPath && Interactions.TutorialBlockedCells.Count > 0
                    && Interactions.TutorialBlockedCells.Contains(neighborPos)) continue;
                if (occupied.Contains(neighborPos) && !(allowOccupiedTarget && neighborPos == targetPos)) continue;

                float moveCost = 1f;
                if (terrainManager != null) moveCost = terrainManager.GetActionCost(neighborPos);

                float newGCost = currentNode.gCost + moveCost;

                if (!gCosts.ContainsKey(neighborPos) || newGCost < gCosts[neighborPos])
                {
                    Node neighborNode;
                    if (nodeMap.ContainsKey(neighborPos))
                    {
                        neighborNode = nodeMap[neighborPos];
                    }
                    else
                    {
                        neighborNode = new Node(neighborPos);
                        nodeMap[neighborPos] = neighborNode;
                    }

                    neighborNode.gCost = newGCost;
                    neighborNode.hCost = GetDistance(neighborPos, targetPos);
                    neighborNode.parent = currentNode;
                    gCosts[neighborPos] = newGCost;

                    if (!openSet.Contains(neighborNode)) openSet.Add(neighborNode);
                }
            }
        }

        return null;
    }

    // ------------------------------------------------------------------
    // ★2026-09-05 贴线直走：等代价路径中选「最直」的一条
    // ------------------------------------------------------------------

    /// <summary>
    /// 贪心贴线走：每步只考虑「使到目标的 HexDistance 恰好 -1」的合法邻居，
    /// 其中选世界 XZ 平面上离「起点→终点连线」最近的一个。
    /// 返回路径长度恒 = HexDistance(start, target)（最优）；任一步走不通 → null（回退 A*）。
    /// </summary>
    private List<Vector2Int> TryStraightPath(Vector2Int start, Vector2Int target,
        HashSet<Vector2Int> occupied, bool allowOccupiedTarget, bool playerPath = false)
    {
        if (start == target) return new List<Vector2Int> { start };

        int remaining = CardExecutor.HexDistance(start, target);
        if (remaining <= 0) return new List<Vector2Int> { start };

        List<Vector2Int> path = new List<Vector2Int> { start };
        Vector2Int current = start;
        int guard = remaining * 2 + 10; // 防御性上限（正常每步 remaining-1，不会超过）

        while (current != target && guard-- > 0)
        {
            Vector2Int best = current;
            float bestCost = float.MaxValue;
            float bestDeviation = float.MaxValue;

            FillNeighbors(current, s_neighborScratch);
            for (int i = 0; i < s_neighborScratch.Count; i++)
            {
                Vector2Int n = s_neighborScratch[i];

                // 必须严格向目标逼近 1 格（保证总长 = HexDistance）
                if (CardExecutor.HexDistance(n, target) != remaining - 1) continue;
                if (!IsStepAllowed(n, occupied, target, allowOccupiedTarget, playerPath)) continue;

                // ★先比地形成本、再比贴线度：平地上（成本全 1）纯选最直；
                // 有森林/水域等高成本格时优先绕开便宜格——直线穿森林会多付 AP。
                float cost = terrainManager != null ? terrainManager.GetActionCost(n) : 1f;
                float deviation = LineDeviation(n, start, target);

                if (cost < bestCost || (cost == bestCost && deviation < bestDeviation))
                {
                    bestCost = cost;
                    bestDeviation = deviation;
                    best = n;
                }
            }

            if (best == current) return null; // 贴线方向被挡 → 回退标准 A*
            path.Add(best);
            current = best;
            remaining--;
        }

        return current == target ? path : null;
    }

    /// <summary>单格通行检查（与 A* 主循环同规则：界内 + 地形 + 占位/终点豁免 + 教学禁行格）。</summary>
    private bool IsStepAllowed(Vector2Int pos, HashSet<Vector2Int> occupied,
        Vector2Int targetPos, bool allowOccupiedTarget, bool playerPath = false)
    {
        if (!IsInBounds(pos)) return false;
        if (terrainManager != null && !terrainManager.IsPassable(pos)) return false;
        if (occupied.Contains(pos) && !(allowOccupiedTarget && pos == targetPos)) return false;
        // ★2026-09-13 教学禁行格：只挡玩家路径（与 A* 主循环同规则）
        if (playerPath && Interactions.TutorialBlockedCells.Count > 0
            && Interactions.TutorialBlockedCells.Contains(pos)) return false;
        return true;
    }

    /// <summary>格子世界坐标（与 HexGridLayout 生成公式一致：奇数列 z 方向偏移 h/2，行朝 -z）。</summary>
    private Vector3 GetWorldPos(Vector2Int c)
    {
        float s = gridLayout.outerSize;
        float w = 2f * s * 0.75f;
        float h = Mathf.Sqrt(3f) * s;
        float offset = (c.x % 2 != 0) ? h / 2f : 0f;
        return gridLayout.transform.TransformPoint(new Vector3(c.x * w, 0f, -(c.y * h + offset)));
    }

    /// <summary>格子中心到「起点→终点连线」的 XZ 垂直距离（衡量路径直不直）。</summary>
    private float LineDeviation(Vector2Int pos, Vector2Int start, Vector2Int target)
    {
        Vector2 p = new Vector2(GetWorldPos(pos).x, GetWorldPos(pos).z);
        Vector2 a = new Vector2(GetWorldPos(start).x, GetWorldPos(start).z);
        Vector2 b = new Vector2(GetWorldPos(target).x, GetWorldPos(target).z);

        Vector2 ab = b - a;
        float len2 = ab.sqrMagnitude;
        if (len2 < 1e-6f) return 0f;

        float t = Mathf.Clamp01(Vector2.Dot(p - a, ab) / len2);
        return Vector2.Distance(p, a + ab * t);
    }

    private List<Vector2Int> RetracePath(Node startNode, Node endNode)
    {
        List<Vector2Int> path = new List<Vector2Int>();
        Node currentNode = endNode;

        while (currentNode != null)
        {
            path.Add(currentNode.position);
            currentNode = currentNode.parent;
        }

        path.Reverse();
        return path;
    }

    /// <summary>把某格的 6 个邻居填进 outList（复用缓冲，不再每步分配）。</summary>
    private static void FillNeighbors(Vector2Int p, List<Vector2Int> outList)
    {
        outList.Clear();
        bool odd = (p.x & 1) != 0;
        Vector2Int[] offsets = odd ? OddOffsets : EvenOffsets;
        for (int i = 0; i < 6; i++)
            outList.Add(new Vector2Int(p.x + offsets[i].x, p.y + offsets[i].y));
    }

    private bool IsInBounds(Vector2Int pos)
    {
        return pos.x >= 0 && pos.x < gridLayout.gridSize.x && pos.y >= 0 && pos.y < gridLayout.gridSize.y;
    }

    private float GetDistance(Vector2Int a, Vector2Int b)
    {
        // ★修正（P0-2）：旧实现 dx + max(0, dy - dx/2) 是 odd-q 的近似式，启发式不一致，
        // 会破坏 A* 最优性。直接复用 CardExecutor.HexDistance（odd-q 转立方坐标的正确距离）。
        return CardExecutor.HexDistance(a, b);
    }
}

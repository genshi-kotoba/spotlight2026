// =============================================================================
// 模块：M6-3 敌人系统 - MoveAIController 移动 AI
// 用途：敌人每回合「怎么走」——按移动预设计算落点（含预设失败降级 + 疾跑兜底）。
// 设计依据：《设计增补_敌人系统_v2.md》§4 移动预设、§4.5 逃路方向量化 + fallback 链、§15.6
// 职责边界：
//   - 只做「落点决策」，不写 SO、不碰 UI、不结算伤害（伤害由 EnemyCardExecutor 负责）
//   - 预设降级发生在 EvaluateLanding 内部（§15.6 关键约定）：Flank/Intercept/Kite/KeepAway
//     找不到满足约束的落点 → 自动降级为「本能」直线靠近返回；唯一 null = 无路可达 → 疾跑
// 运行时状态已在 EnemyController（合并 EnemyRuntime，见 project_rules / v2 §16-11）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人移动决策静态类。核心产物 = <see cref="EvaluateLanding"/> 返回的落点坐标 + 移动消耗。
/// 每回合对每只怪只跑一次落点计算；IntentEvaluator 复用此落点做射程判定（两步解耦）。
/// </summary>
public static class MoveAIController
{
    // ------------------------------------------------------------------
    // ★P2 性能缓存：HexGridLayout / TerrainManager / 存活敌人 是静态场景对象，
    // 旧实现每次调用都 FindObjectOfType(s)（Unity 最慢 API，热路径里重复调用导致卡顿）。
    // 改为惰性缓存 + 存活敌人每帧缓存。Unity 的 == null 对已销毁对象返回 true，
    // 场景重载（Play 结束）后自动重取，不会持脏引用。
    // ------------------------------------------------------------------
    private static HexGridLayout _grid;
    private static TerrainManager _terrain;
    private static EnemyController[] _aliveEnemies;
    private static int _enemiesFrame = -1;

    private static HexGridLayout Grid => _grid != null ? _grid : (_grid = Object.FindObjectOfType<HexGridLayout>());
    private static TerrainManager Terrain => _terrain != null ? _terrain : (_terrain = Object.FindObjectOfType<TerrainManager>());
    private static EnemyController[] AliveEnemies
    {
        get
        {
            if (_enemiesFrame != Time.frameCount)
            {
                var list = new List<EnemyController>();
                foreach (var e in Object.FindObjectsOfType<EnemyController>())
                {
                    if (e != null && !e.IsDead && e.gameObject.activeInHierarchy) list.Add(e);
                }
                _aliveEnemies = list.ToArray();
                _enemiesFrame = Time.frameCount;
            }
            return _aliveEnemies;
        }
    }

    // ------------------------------------------------------------------
    // 公开入口：按移动预设计算落点（含降级）
    // ------------------------------------------------------------------

    // ★2026-08-19 移动与意图解耦（用户确认）后 ChasePlayer 已删除：
    // 追击语义已内含于 EvaluateLanding 的 WalkToward——移动力进不了射程时
    // 走到预算尽头（能走多近走多近），配合 EnemyController.MoveBudget（AP+疾跑值）
    // 天然实现「够不到就多走几格追上来」。

    /// <summary>
    /// 计算本回合落点（★2026-08-19「假设玩家坐标」版，统一入口）。
    /// §3.8 移动预览用：把玩家「假设走到某格」后的坐标传入，落点计算（绕后/射程格/直线靠近）
    /// 全部基于假设坐标，得到「玩家真的走过去后敌人会怎么走」。
    /// 修复前问题：本方法内部自己 FindObjectOfType 取真实玩家坐标，预览时假设坐标
    /// 只参与了 IntentEvaluator 的射程判定，落点从不随假设位置变化（敌人永远"在原地"）。
    /// ★2026-08-22 新增 planningReserved 参数：EnemyLandingPlanner 全局解算时传入
    /// 「先解算者的计划落点集合」——这些格子对本次落点计算表现为已占（后解算者避让），
    /// 实现多名敌人计划落点互斥（修复用户报告的落点虚影重合）。
    /// </summary>
    /// <param name="enemy">施法敌人</param>
    /// <param name="attackRange">射程参数</param>
    /// <param name="playerCoord">假设/真实的玩家坐标（落点计算的数据源）</param>
    /// <param name="apCost">输出：移动到落点消耗的移动力</param>
    /// <param name="planningReserved">计划保留格（先解算者的计划落点：挡中途穿越 + 挡落点；null=独立计算）</param>
    /// <param name="simOccupied">★2026-08-23 顺序模拟棋盘（假设玩家 + 全部敌人模拟位置：
    /// 已解算者=计划落点、未解算者=原格；只挡「落点」不挡「穿越」）。null=独立计算（查真实场景）</param>
    /// <returns>落点坐标；null=无路可达</returns>
    public static Vector2Int? EvaluateLanding(EnemyController enemy, int attackRange, Vector2Int playerCoord, out int apCost, HashSet<Vector2Int> planningReserved = null, HashSet<Vector2Int> simOccupied = null)
    {
        apCost = 0;
        if (enemy == null || enemy.data == null) return null;

        Vector2Int start = enemy.CurrentCoord;
        if (playerCoord.x < 0 || playerCoord.y < 0)
        {
            Debug.LogWarning("[MoveAIController] 无有效玩家坐标，无法计算落点");
            return start;
        }
        Vector2Int p = playerCoord;
        int budget = enemy.MoveBudget; // moveRange + 追击值

        switch (enemy.data.movePreset)
        {
            case MoveAIPresetType.本能:
                return WalkToward(enemy, start, p, budget, attackRange, out apCost, planningReserved, simOccupied);

            case MoveAIPresetType.包抄:
            {
                Vector2Int? behind = FindFlankCell(enemy, start, p, simOccupied);
                if (behind.HasValue)
                {
                    Vector2Int? landing = WalkTo(enemy, start, behind.Value, p, budget, attackRange, out apCost, planningReserved, simOccupied);
                    if (landing.HasValue) return landing; // 绕后成功
                }
                return WalkToward(enemy, start, p, budget, attackRange, out apCost, planningReserved, simOccupied); // 降级本能
            }

            case MoveAIPresetType.拦截:
            {
                Vector2Int? ip = FindRangeCell(enemy, p, attackRange, preferAway: false, simOccupied);
                if (ip.HasValue)
                {
                    Vector2Int? landing = WalkTo(enemy, start, ip.Value, p, budget, attackRange, out apCost, planningReserved, simOccupied);
                    if (landing.HasValue) return landing;
                }
                return WalkToward(enemy, start, p, budget, attackRange, out apCost, planningReserved, simOccupied); // 降级本能
            }

            case MoveAIPresetType.风筝:
            {
                Vector2Int? k = FindRangeCell(enemy, p, attackRange, preferAway: true, simOccupied);
                if (k.HasValue)
                {
                    Vector2Int? landing = WalkTo(enemy, start, k.Value, p, budget, attackRange, out apCost, planningReserved, simOccupied);
                    if (landing.HasValue) return landing;
                }
                return WalkToward(enemy, start, p, budget, attackRange, out apCost, planningReserved, simOccupied); // 降级本能
            }

            case MoveAIPresetType.远离:
            {
                Vector2Int? ka = FindRangeCell(enemy, p, attackRange, preferAway: true, simOccupied);
                if (ka.HasValue)
                {
                    Vector2Int? landing = WalkTo(enemy, start, ka.Value, p, budget, attackRange, out apCost, planningReserved, simOccupied);
                    if (landing.HasValue) return landing;
                }
                return WalkToward(enemy, start, p, budget, attackRange, out apCost, planningReserved, simOccupied); // 降级本能
            }

            default: // 守卫 / 自爆 / 炮台 / 游击 / 召唤者 等预留预设，先按本能兜底
                return WalkToward(enemy, start, p, budget, attackRange, out apCost, planningReserved, simOccupied);
        }
    }

    // ------------------------------------------------------------------
    // 基础移动：直线靠近 / 定点走位
    // ------------------------------------------------------------------

    /// <summary>
    /// 「本能」直线靠近：已在射程内则不移动；否则沿 A* 向玩家逼近，进入射程即停。
    /// 设计依据：v2 §4.2 本能（够到→相邻→攻击；剩余 AP 不用）。
    /// </summary>
    private static Vector2Int? WalkToward(EnemyController enemy, Vector2Int start, Vector2Int p, int budget, int desiredRange, out int apCost, HashSet<Vector2Int> planningReserved = null, HashSet<Vector2Int> simOccupied = null)
    {
        apCost = 0;
        if (CardExecutor.HexDistance(start, p) <= desiredRange) return start; // 已在射程内，原地
        return WalkTo(enemy, start, p, p, budget, desiredRange, out apCost, planningReserved, simOccupied);
    }

    /// <summary>
    /// 从 start 向 target 走位，预算 budget 内尽可能到达目标；一旦进入 desiredRange 即停。
    /// 返回 null = A* 无路可达（障碍封死）。绝不站到玩家格子上（距离 < 1 时已提前停）。
    /// ★2026-08-23 顺序模拟：落点判定用 simOccupied（模拟棋盘=假设玩家+已解算者落点+未解算者原格），
    /// 中途穿越仍用 planningReserved（零碰撞：只有玩家格/先解算者落点阻挡，未解算友军格可穿）。
    /// </summary>
    private static Vector2Int? WalkTo(EnemyController enemy, Vector2Int start, Vector2Int target, Vector2Int playerCoord, int budget, int desiredRange, out int apCost, HashSet<Vector2Int> planningReserved = null, HashSet<Vector2Int> simOccupied = null)
    {
        apCost = 0;
        if (start == target) return start;

        List<Vector2Int> path = FindPath(start, target, enemy, planningReserved);
        if (path == null || path.Count <= 1) return null; // 无路可达

        Vector2Int landing = start;
        TerrainManager terrain = Terrain;

        for (int i = 1; i < path.Count; i++)
        {
            Vector2Int c = path[i];
            if (c == playerCoord) break; // 不占玩家格
            // ★2026-08-21 零碰撞：中途友军格可穿越（不卡位），只挡玩家格+保留格。
            if (UnitOccupancy.IsBlockedForEnemyTransit(c, enemy, planningReserved)) break;

            int cost = terrain != null ? terrain.GetActionCost(c) : 1;
            if (cost <= 0) cost = 1;
            if (apCost + cost > budget) break; // 超出移动预算

            apCost += cost; // 穿越成本照付（含友军格）
            // ★落点不重叠：landing 只更新到「模拟棋盘上无人」的格——
            // simOccupied 含 假设玩家 + 已解算者的计划落点 + 未解算者的原格，
            // 恰是「本敌移动时刻」的真实占位快照（先动者已离原格、后动者尚未动）。
            if (!UnitOccupancy.IsOccupied(c, simOccupied))
            {
                landing = c;
            }
            // 射程判定用实际落点 landing（而非当前推进格 c——c 可能被友军占而敌人实际站 landing）
            if (CardExecutor.HexDistance(landing, playerCoord) <= desiredRange) break; // 到攻击距离即停
        }

        // ★2026-08-23 射程内保停兜底（修复用户报告：预算内明明能走到玩家身边的另一相邻格，
        // 却因主 A* 路径末端的相邻格被先动者保留，中途截断停在射程外 → 意图变「追击」）：
        // 主 A* 只探索「start→target」一条线；此处按总预算做一次全向可达搜索，
        // 找「预算内可达 + 可停留（模拟棋盘无人）+ 已进射程」的最佳格替换 landing。
        // 仅接近型预设启用；远离预设停在射程外是设计目标（保持距离），不能被兜底拉回玩家身边。
        if (CardExecutor.HexDistance(landing, playerCoord) > desiredRange
            && (enemy.data == null || enemy.data.movePreset != MoveAIPresetType.远离))
        {
            Vector2Int? alt = FindStoppableCellInRange(enemy, start, playerCoord, budget, desiredRange, out int altCost, planningReserved, simOccupied);
            if (alt.HasValue)
            {
                landing = alt.Value;
                apCost = altCost;
            }
        }
        return landing;
    }

    /// <summary>
    /// ★2026-08-23 预算内「可停留且在射程内」格子搜索（Dijkstra，<see cref="WalkTo"/> 射程内保停兜底）。
    /// 与主 A*（只探索一条 start→target 线）互补：全向扩展所有预算内可达格。
    /// 中途格遵循零碰撞规则（友军格可穿越；玩家格/保留格阻挡）；停留候选须无任何占位（含保留格）。
    /// 评分：与玩家距离越接近 desiredRange 越优（拦截/风筝要极限射程，近战要贴脸），
    /// 同距离花费小者优先（少走路）。
    /// </summary>
    /// <param name="enemy">施法敌人（远离预设由调用方过滤，本方法不再判断）</param>
    /// <param name="start">起点（敌人当前格）</param>
    /// <param name="playerCoord">玩家坐标</param>
    /// <param name="budget">移动预算（AP+疾跑）</param>
    /// <param name="desiredRange">期望射程</param>
    /// <param name="pathCost">输出：到最佳格的最小地形花费</param>
    /// <param name="planningReserved">计划保留格（先动者落点：中途阻挡 + 不可停留）</param>
    /// <param name="simOccupied">顺序模拟棋盘（假设玩家+已解算者落点+未解算者原格：不可停留）</param>
    /// <returns>最佳落点；预算内没有任何「可停留且在射程内」的格子时返回 null</returns>
    private static Vector2Int? FindStoppableCellInRange(EnemyController enemy, Vector2Int start, Vector2Int playerCoord, int budget, int desiredRange, out int pathCost, HashSet<Vector2Int> planningReserved, HashSet<Vector2Int> simOccupied)
    {
        pathCost = 0;
        HexGridLayout grid = Grid;
        TerrainManager terrain = Terrain;
        if (grid == null) return null;

        // ★2026-09-15 性能重写：旧实现 frontier 用 List + 线性取最小 + Contains 查重 → O(n²)。
        //   空旷大图（随机荒野 80×50 大平地）预算内可达格有数百个，单次调用几十 ms；
        //   全场解算/悬停预览里每敌都跑一次 → 整帧卡死。改「整数代价桶队列」Dijkstra
        //   （与 AStarPathfinding.SearchWithBuckets 同思路）：地形成本全为整数且总额 ≤ budget
        //   → 桶下标即代价，游标单向推进 = O(1) 取最小。结果等价（最小代价集相同；
        //   等代价格之间的取舍可能与旧版不同，游戏表现等价）。
        var dist = new Dictionary<Vector2Int, int>(64) { { start, 0 } };
        var buckets = new Queue<Vector2Int>[budget + 1];
        for (int i = 0; i <= budget; i++) buckets[i] = new Queue<Vector2Int>();
        buckets[0].Enqueue(start);

        Vector2Int? best = null;
        int bestDist = int.MinValue; // 与玩家距离（越接近 desiredRange 越大越优）
        int bestCost = int.MaxValue;

        for (int curCost = 0; curCost <= budget; curCost++)
        {
            Queue<Vector2Int> q = buckets[curCost];
            while (q.Count > 0)
            {
                Vector2Int cur = q.Dequeue();
                if (dist.TryGetValue(cur, out int dc) && dc != curCost) continue; // 过期条目（已有更优路径）

                foreach (Vector2Int n in GetNeighbors(cur))
                {
                    if (n.x < 0 || n.y < 0 || n.x >= grid.gridSize.x || n.y >= grid.gridSize.y) continue;
                    if (terrain != null && !terrain.IsPassable(n)) continue;
                    if (n == playerCoord) continue; // 假设玩家格不可穿越（与 WalkTo 的提前停一致）
                    // 零碰撞中途规则：玩家格/保留格阻挡（友军格可穿越）
                    if (UnitOccupancy.IsBlockedForEnemyTransit(n, enemy, planningReserved)) continue;

                    int step = terrain != null ? terrain.GetActionCost(n) : 1;
                    if (step <= 0) step = 1;
                    int newCost = curCost + step;
                    if (newCost > budget) continue; // 超预算不可达

                    if (dist.TryGetValue(n, out int oldCost) && oldCost <= newCost) continue; // 已有更优路径

                    dist[n] = newCost;
                    buckets[newCost].Enqueue(n);

                    // 停留候选：模拟棋盘上无人（玩家+已解算者落点+未解算者原格）且已进射程
                    if (!UnitOccupancy.IsOccupied(n, simOccupied))
                    {
                        int d = CardExecutor.HexDistance(n, playerCoord);
                        if (d <= desiredRange && (d > bestDist || (d == bestDist && newCost < bestCost)))
                        {
                            bestDist = d;
                            bestCost = newCost;
                            best = n;
                            pathCost = newCost;
                        }
                    }
                }
            }
        }
        return best;
    }

    // ------------------------------------------------------------------
    // 预设目标格选择（Flank 绕后 / 通用极限射程格）
    // ------------------------------------------------------------------

    /// <summary>
    /// 包抄绕后格：枚举玩家周围 6 个相邻格，选「离最近友军最远」（=玩家背对友军一侧）的可行格。
    /// 无友军 → 返回 null（调用方降级本能）。设计依据：v2 §4.5 逃路方向量化 + §4.2 包抄。
    /// </summary>
    private static Vector2Int? FindFlankCell(EnemyController enemy, Vector2Int start, Vector2Int p, HashSet<Vector2Int> simOccupied = null)
    {
        EnemyController ally = FindNearestAlly(enemy, p);
        if (ally == null) return null; // 场上无友军，无法绕后

        HexGridLayout grid = Grid;
        TerrainManager terrain = Terrain;

        Vector2Int best = p;
        int bestScore = int.MinValue;
        bool found = false;

        foreach (Vector2Int n in GetNeighbors(p))
        {
            if (!IsWalkableCell(n, grid, terrain, simOccupied)) continue;
            if (n == start) continue;
            int d = CardExecutor.HexDistance(n, ally.CurrentCoord);
            if (d > bestScore) { bestScore = d; best = n; found = true; }
        }
        return found ? best : (Vector2Int?)null;
    }

    /// <summary>
    /// 通用「指定距离」目标格：扫描全图，选与玩家六边形距离 == desiredRange 的可行格。
    /// 评分偏好：有友军→取离友军最远（绕后）；无友军→preferAway 取离当前最远（后撤）/最近（导向）。
    /// 供 Intercept（极限射程堵路）/ Kite（极远打退）/ KeepAway（拉距离）复用。设计依据：v2 §4.2。
    /// </summary>
    private static Vector2Int? FindRangeCell(EnemyController enemy, Vector2Int p, int desiredRange, bool preferAway, HashSet<Vector2Int> simOccupied = null)
    {
        HexGridLayout grid = Grid;
        TerrainManager terrain = Terrain;
        if (grid == null) return null;

        EnemyController ally = FindNearestAlly(enemy, p);
        Vector2Int startCoord = enemy.CurrentCoord;
        Vector2Int? best = null;
        int bestScore = int.MinValue;

        // ★2026-09-15 性能：旧实现全图 4000 格逐格 HexDistance 扫描（拦截/风筝/远离每敌每计划各一次
        //   × 全场解算 × 悬停预览每次换格 → 热点）。改环枚举：六边形距离恰 == desiredRange 的格子
        //   直接沿环走一圈产出（O(r)），候选集与全图扫描完全相同，只是遍历顺序不同。
        foreach (Vector2Int c in EnumerateRing(p, desiredRange, grid.gridSize.x, grid.gridSize.y))
        {
            if (!IsWalkableCell(c, grid, terrain, simOccupied)) continue;

            int score;
            if (ally != null) score = CardExecutor.HexDistance(c, ally.CurrentCoord);
            else if (preferAway) score = CardExecutor.HexDistance(c, startCoord);
            else score = -CardExecutor.HexDistance(c, startCoord);

            if (score > bestScore) { bestScore = score; best = c; }
        }
        return best;
    }

    /// <summary>
    /// ★2026-09-15 环枚举：产出与 center 六边形距离恰为 radius 的全部界内格（odd-q offset）。
    /// 换算与 CardExecutor.HexDistance 同一套 cube 公式（redblobgames）：
    /// offset→cube: x=col, z=row-(col-(col&amp;1))/2；cube→offset: col=x, row=z+(x-(x&amp;1))/2。
    /// </summary>
    private static IEnumerable<Vector2Int> EnumerateRing(Vector2Int center, int radius, int w, int h)
    {
        if (radius <= 0)
        {
            if (radius == 0 && center.x >= 0 && center.y >= 0 && center.x < w && center.y < h)
                yield return center;
            yield break;
        }

        int cc = center.x, cr = center.y;
        int cx = cc, cz = cr - (cc - (cc & 1)) / 2, cy = -cx - cz;

        // 6 个 cube 方向（x, y, z；y = -x - z）
        int[] DX = { 1, 1, 0, -1, -1, 0 };
        int[] DY = { -1, 0, 1, 1, 0, -1 };
        int[] DZ = { 0, -1, -1, 0, 1, 1 };

        // 起点 = center + dir[4] * radius，然后逐边绕环（标准 ring 算法）
        int sx = cx + DX[4] * radius;
        int sz = cz + DZ[4] * radius;

        for (int side = 0; side < 6; side++)
        {
            for (int step = 0; step < radius; step++)
            {
                int col = sx;
                int row = sz + (sx - (sx & 1)) / 2;
                if (col >= 0 && row >= 0 && col < w && row < h)
                    yield return new Vector2Int(col, row);
                sx += DX[side];
                sz += DZ[side];   // 环上行走只需跟踪 x/z（y 由 -x-z 隐含）
            }
        }
        // cy 仅用于文档性换算完整性，未参与环行走 —— 抑制未用告警
        _ = cy;
    }

    // ------------------------------------------------------------------
    // 底层工具
    // ------------------------------------------------------------------

    /// <summary>奇偶 q（odd-q）平顶六边形邻居枚举，与 AStarPathfinding.GetFlatTopNeighbors 对齐。
    /// （public 供合围留口计数 CountEscapeCellsExact 复用）</summary>
    public static List<Vector2Int> GetNeighbors(Vector2Int p)
    {
        var result = new List<Vector2Int>(6);
        int[][] odd = { new int[] { 1, 0 }, new int[] { 1, 1 }, new int[] { 0, 1 }, new int[] { -1, 1 }, new int[] { -1, 0 }, new int[] { 0, -1 } };
        int[][] even = { new int[] { 1, -1 }, new int[] { 1, 0 }, new int[] { 0, 1 }, new int[] { -1, 0 }, new int[] { -1, -1 }, new int[] { 0, -1 } };
        int[][] offsets = (p.x % 2 != 0) ? odd : even;
        foreach (var o in offsets) result.Add(new Vector2Int(p.x + o[0], p.y + o[1]));
        return result;
    }

    /// <summary>A* 寻路（复用现有 AStarPathfinding）。
    /// ★2026-08-19 终点豁免占位：WalkToward 的寻路终点常是玩家所在格（被占），不豁免会永远无路可达——
    /// WalkTo 迭代路径时会停在占位格之前，不会真踩上去。
    /// ★2026-08-21 零碰撞混合方案（用户需求）：传入 enemyRequester，敌人寻路时友军所在格可穿越
    /// （不互相卡位），只挡玩家格+保留格；落点选择由 IsWalkableCell 用 IsOccupied 单独把关（不重叠）。</summary>
    private static List<Vector2Int> FindPath(Vector2Int start, Vector2Int target, EnemyController enemy, HashSet<Vector2Int> planningReserved = null)
    {
        HexGridLayout grid = Grid;
        if (grid == null) return null;
        return new AStarPathfinding(grid).FindPath(start, target, allowOccupiedTarget: true, enemyRequester: enemy, planningReserved: planningReserved);
    }

    /// <summary>最近存活友军敌人（用于「背对友军」方向量化）。</summary>
    private static EnemyController FindNearestAlly(EnemyController self, Vector2Int p)
    {
        EnemyController nearest = null;
        int minDist = int.MaxValue;
        foreach (EnemyController e in AliveEnemies)
        {
            if (e == self || e.IsDead || e.data == null) continue;
            int d = CardExecutor.HexDistance(e.CurrentCoord, p);
            if (d < minDist) { minDist = d; nearest = e; }
        }
        return nearest;
    }

    /// <summary>
    /// 格子是否可行走（界内 + 地形可通行 + ★2026-08-19 无单位占位）。
    /// 供包抄格/射程格等「落点候选」筛选：有单位（敌我不论）的格子不能作为落点。
    /// ★2026-08-23 simOccupied：顺序模拟棋盘（假设玩家+已解算者落点+未解算者原格）——
    /// 计划解算时传模拟棋盘（不扫真实场景，先动者的原格已腾出、正确视为可停）；
    /// null=独立查询模式（扫真实场景单位）。
    /// </summary>
    private static bool IsWalkableCell(Vector2Int c, HexGridLayout grid, TerrainManager terrain, HashSet<Vector2Int> simOccupied = null)
    {
        if (grid != null && (c.x < 0 || c.y < 0 || c.x >= grid.gridSize.x || c.y >= grid.gridSize.y)) return false;
        if (terrain != null && !terrain.IsPassable(c)) return false;
        if (UnitOccupancy.IsOccupied(c, simOccupied)) return false; // 单位占位（模拟棋盘或真实场景）：不可作为落点
        return true;
    }

    // ------------------------------------------------------------------
    // ★2026-08-22 合围留口（escape route）工具：防多只近战怪占满玩家 6 邻格形成死局
    // ------------------------------------------------------------------

    /// <summary>
    /// 该格是否为玩家 6 邻格（六边形距离 == 1）。合围留口判定用。
    /// </summary>
    public static bool IsPlayerNeighbor(Vector2Int cell, Vector2Int playerCoord)
    {
        return CardExecutor.HexDistance(cell, playerCoord) == 1;
    }

    /// <summary>
    /// ★2026-08-23 精确逃生口计数：遍历玩家 6 邻格，统计「界内 & 地形可通行 & 占位集外」的格子数。
    /// 合围留口不变量用：任何敌人计划落点生效后，此值须 ≥ EnemyLandingPlanner.MinEscapeCells。
    /// 与旧场景扫描版的区别：只按传入的「移动后占位集」判定（不扫描场景单位）——
    /// 先解算的敌人已按计划落点站位、原格已腾出，不能再把「即将离开的原格」误计为被占
    /// （旧版高估占用 → 有逃生口却误触发留口改派，敌人被错误赶去射程外变追击）。
    /// </summary>
    /// <param name="playerCoord">玩家坐标</param>
    /// <param name="occupiedSet">完整移动后占位集（所有会留在场上的单位落点，含不动者原格）</param>
    /// <returns>玩家 6 邻格中的逃生口数</returns>
    public static int CountEscapeCellsExact(Vector2Int playerCoord, HashSet<Vector2Int> occupiedSet)
    {
        HexGridLayout grid = Grid;
        TerrainManager terrain = Terrain;
        if (grid == null) return 0;

        int count = 0;
        foreach (Vector2Int n in GetNeighbors(playerCoord))
        {
            if (n.x < 0 || n.y < 0 || n.x >= grid.gridSize.x || n.y >= grid.gridSize.y) continue;
            if (terrain != null && !terrain.IsPassable(n)) continue;
            if (occupiedSet != null && occupiedSet.Contains(n)) continue;
            count++;
        }
        return count;
    }

    /// <summary>
    /// 合围留口降级目标格：找「与玩家六边形距离 &gt; attackRange」、可通行、未被占、离玩家最近的格子。
    /// 用于：某敌人计划落点会填满玩家最后一个逃生口时，把它改派到射程外（近战 attackRange=1 → 距离 ≥2），
    /// 保住玩家逃生口（合围留口不变量）。
    /// ★2026-08-23 simOccupied：改用顺序模拟棋盘判定占位（未解算敌人的原格也算占——
    /// 它们此刻还站在那里，改派落点不能与之重叠）。
    /// 找不到（全图无非邻可站格）→ 返回 null（调用方回退「保持原地」）。
    /// </summary>
    public static Vector2Int? FindNearestNonSurroundCell(EnemyController enemy, Vector2Int playerCoord, int attackRange, HashSet<Vector2Int> simOccupied = null)
    {
        HexGridLayout grid = Grid;
        TerrainManager terrain = Terrain;
        if (grid == null) return null;

        // ★2026-09-15 性能：旧实现全图 4000 格扫描找「距离 > attackRange 的最近格」。
        // 改环枚举逐圈外扩：从 attackRange+1 圈开始，第一圈有可站格即返回（即最近）——
        // 候选集与结果等价（同圈等距，取哪一格是等价选择）。
        int maxRadius = grid.gridSize.x + grid.gridSize.y;   // 覆盖全图的防御性上限
        for (int r = attackRange + 1; r <= maxRadius; r++)
        {
            foreach (Vector2Int c in EnumerateRing(playerCoord, r, grid.gridSize.x, grid.gridSize.y))
            {
                if (IsWalkableCell(c, grid, terrain, simOccupied)) return c;
            }
        }
        return null;
    }
}
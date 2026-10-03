// =============================================================================
// 模块：Game - UnitOccupancy 单位占位查询
// 用途：回答「某个格子现在有没有单位（玩家或敌人）站着」。
// ★2026-08-19 用户新规则：移动时不论敌我，任何单位不能与其他单位同处一格——
//        有单位的格子 = 不可到达的红色格子（玩家移动点击拒绝、A* 中间格阻挡、
//        敌人落点/走位避开）。
//
// ★2026-09-15 性能重写（静态注册表，实测定位）：
//   原实现是「无注册表，每次调用现场扫描场景单位」——即
//   `Object.FindObjectsOfType<EnemyController>()` + `FindObjectOfType<HexMover>()`。
//   雾镇图场景有约 1.2 万个对象，全场景扫描一次 **6.5ms**（实测），而
//   A* 每次 FindPath 都要先构建一次占位集 → **单次寻路 8.18ms 里 6.5ms 是这个**，
//   悬停路径预览 / 点击移动 / 敌人落点检查全部在付这笔钱。
//   现在改为**注册表**：单位在 OnEnable/OnDisable 自注册/注销，
//   查询只遍历存活单位列表（11 只敌人 ≈ 亚微秒级），行为完全不变。
//   兜底：玩家引用为 Unity 假 null（未注册/已销毁/换场景）时会重新查找，
//   但带 0.5s 冷却，避免"场景里没有玩家"时退化成每次调用都全场景扫描。
//
// 注意：调用方若在「自己正在移动」的场景查询，需自行排除移动单位自身坐标
//        （A* 起点不作为邻居检查，天然不受影响）。
// ★2026-08-22 保留格参数化：原全局静态保留格（Reserve/ClearReserved）已删除——
//        全局保留格在「敌人回合执行中途视觉层刷新预览」时会污染执行阶段的寻路
//        （执行阶段 A* 会把预览保留格当真实阻挡）。改为「计划保留格」由调用方
//        以参数传入（EnemyLandingPlanner 解算时传局部 HashSet），不落任何全局状态，
//        计划可随时安全重算。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 单位占位静态查询：格子是否被任意存活单位（玩家/敌人）占据。
/// planningReserved 参数（可选）：「全局落点计划」解算中先解算者的计划落点集合，
/// 传入后这些格子也按已占处理（后解算者避让），实现多名敌人计划落点互斥。
/// </summary>
public static class UnitOccupancy
{
    /// <summary>
    /// ★2026-08-23 计划解算期的「假设玩家坐标」：EnemyLandingPlanner.ComputePlan 解算期间设置，
    /// 使 A* 中途占位/穿越检查用「假设落点」而非玩家真实 CurrentCoord。
    /// 修复：玩家移动中 CurrentCoord 还是中间格，若 A* 误把中间格当障碍，会导致
    /// 预览（解算假设落点）与执行（玩家已到落点）的寻路结果不同 → 哥布林等包抄怪落点非确定。
    /// null = 用真实玩家坐标（玩家寻路 / 敌人回合执行阶段）。
    /// </summary>
    public static Vector2Int? SimulatedPlayerCoord;

    // ------------------------------------------------------------------
    // ★2026-09-15 单位注册表（替代每次调用的全场景扫描）
    // ------------------------------------------------------------------

    private static readonly List<EnemyController> s_enemies = new List<EnemyController>(32);
    private static HexMover s_player;
    private static float s_nextPlayerSearchTime;

    /// <summary>
    /// ★2026-09-15：存活单位注册表的只读视图——供「每次悬停 / 每帧」的遍历使用，
    /// 替代 Object.FindObjectsOfType（雾镇图 1.2 万对象实测 3.47ms/次）。
    /// 注意：内部列表随单位启用/停用增删，请勿缓存此引用跨帧使用；
    /// 列表可能含已死单元（死亡不注销），调用方需自行过滤 IsDead。
    /// </summary>
    public static IReadOnlyList<EnemyController> LivingEnemies => s_enemies;

    /// <summary>敌人启用时自注册（EnemyController.OnEnable 调用）。</summary>
    public static void RegisterEnemy(EnemyController enemy)
    {
        if (enemy == null || s_enemies.Contains(enemy)) return;
        s_enemies.Add(enemy);
    }

    /// <summary>敌人停用/销毁时注销（EnemyController.OnDisable / OnDestroy 调用）。</summary>
    public static void UnregisterEnemy(EnemyController enemy)
    {
        if (enemy == null) return;
        s_enemies.Remove(enemy);
    }

    /// <summary>玩家启用时自注册（HexMover.OnEnable 调用）。</summary>
    public static void RegisterPlayer(HexMover player)
    {
        if (player != null) s_player = player;
    }

    /// <summary>玩家停用/销毁时注销（HexMover.OnDisable / OnDestroy 调用）。</summary>
    public static void UnregisterPlayer(HexMover player)
    {
        if (player == s_player) s_player = null;
    }

    /// <summary>
    /// 取当前玩家。正常情况下走注册表；为 Unity 假 null（未注册 / 已销毁 / 换场景）
    /// 时重新查找，带 0.5s 冷却避免无玩家场景里的每次调用都全场景扫描。
    /// </summary>
    private static HexMover Player
    {
        get
        {
            if (s_player == null && Time.realtimeSinceStartup >= s_nextPlayerSearchTime)
            {
                s_player = Object.FindObjectOfType<HexMover>();
                s_nextPlayerSearchTime = Time.realtimeSinceStartup + 0.5f;
            }
            return s_player;
        }
    }

    /// <summary>
    /// 单点查询：该格子是否被任意存活单位占据。
    /// ★2026-08-23 顺序模拟语义（用户需求重构：逐敌算完再算下一只）：
    /// 传入 simOccupied（EnemyLandingPlanner 的模拟棋盘占位集）时只查该集合、
    /// 不再扫描场景——模拟棋盘是唯一事实：已解算敌人按「计划落点」站位（原格已腾出）、
    /// 未解算敌人仍在原格。修复：场景实时扫描会把「已解算、即将离开原格的敌人」的
    /// 原格误判为被占 → 后动者明明有格子可停却被判无位 → 意图变追击。
    /// null=独立查询模式（玩家寻路等）：查真实单位注册表（玩家 + 存活敌人）。
    /// </summary>
    /// <param name="coord">格子逻辑坐标</param>
    /// <param name="simOccupied">模拟棋盘占位集（计划器逐敌解算传入；null=只查真实单位）</param>
    /// <returns>true=有人站着（不可到达/不可作为落点）</returns>
    public static bool IsOccupied(Vector2Int coord, HashSet<Vector2Int> simOccupied = null)
    {
        // 模拟模式：纯查集合（先解算者的原格已从集合移除 → 正确视为可停）
        if (simOccupied != null) return simOccupied.Contains(coord);

        HexMover player = Player;
        if (player != null && player.CurrentCoord == coord) return true;

        for (int i = 0; i < s_enemies.Count; i++)
        {
            EnemyController enemy = s_enemies[i];
            if (enemy == null || enemy.IsDead || !enemy.gameObject.activeInHierarchy) continue;
            if (enemy.CurrentCoord == coord) return true;
        }
        return false;
    }

    /// <summary>
    /// 构建当前全部占位格集合（A* 每次 FindPath 调一次，避免逐邻居扫描；含可选计划保留格）。
    /// </summary>
    /// <param name="planningReserved">计划保留格（可选，玩家寻路不传）</param>
    /// <returns>所有存活单位所在格 + 计划保留格的集合</returns>
    public static HashSet<Vector2Int> GetOccupiedTiles(HashSet<Vector2Int> planningReserved = null)
    {
        var set = new HashSet<Vector2Int>();
        if (planningReserved != null) set.UnionWith(planningReserved);

        HexMover player = Player;
        if (player != null) set.Add(player.CurrentCoord);

        for (int i = 0; i < s_enemies.Count; i++)
        {
            EnemyController enemy = s_enemies[i];
            if (enemy == null || enemy.IsDead || !enemy.gameObject.activeInHierarchy) continue;
            set.Add(enemy.CurrentCoord);
        }
        return set;
    }

    // ------------------------------------------------------------------
    // ★2026-08-21 敌人中途零碰撞查询（混合方案：中途友军可穿越 + 落点仍避友军）
    // ------------------------------------------------------------------

    /// <summary>
    /// ★2026-08-21 敌人 A* 中途格占位集合（零碰撞：友军可穿越，只挡玩家+计划保留格）。
    /// 供 AStarPathfinding.FindPath 的 enemyRequester 模式使用：敌人寻路时，
    /// 其他敌人所在格不再视为不可通行（可穿越通过），但玩家格和计划保留格仍阻挡。
    /// 这样敌人移动中途不互相卡位，但落点选择（IsWalkableCell）仍用 IsOccupied 挡所有
    /// ——确保最终落点不与友军重叠。
    /// </summary>
    /// <param name="requester">发起寻路的敌人（自身不挡自己，A* 起点也不查，故无需特别排除）</param>
    /// <param name="planningReserved">计划保留格（EnemyLandingPlanner 解算传入；null=只挡玩家格）</param>
    /// <returns>玩家所在格 + 计划保留格（不含敌人占位）</returns>
    public static HashSet<Vector2Int> GetTransitOccupiedTiles(EnemyController requester, HashSet<Vector2Int> planningReserved = null)
    {
        var set = new HashSet<Vector2Int>();
        if (planningReserved != null) set.UnionWith(planningReserved);

        // ★2026-08-23 解算期优先用「假设玩家坐标」（ComputePlan 传入的落点），
        // 否则玩家移动中 CurrentCoord 是中间格，会污染计划解算的 A*。
        if (SimulatedPlayerCoord.HasValue)
        {
            set.Add(SimulatedPlayerCoord.Value);
        }
        else
        {
            HexMover player = Player;
            if (player != null) set.Add(player.CurrentCoord);
        }

        // 注意：不加入任何敌人占位 —— 零碰撞核心（友军格可穿越）
        return set;
    }

    /// <summary>
    /// ★2026-08-21 敌人中途单点查询（零碰撞：友军可穿越，只挡玩家+计划保留格）。
    /// 供 MoveAIController.WalkTo 逐格移动检查使用：敌人移动中途遇到友军格可继续通过，
    /// 只有玩家格/计划保留格才中断。落点选择仍用 IsOccupied（挡所有）。
    /// </summary>
    public static bool IsBlockedForEnemyTransit(Vector2Int coord, EnemyController requester, HashSet<Vector2Int> planningReserved = null)
    {
        if (planningReserved != null && planningReserved.Contains(coord)) return true;

        // ★2026-08-23 解算期优先用「假设玩家坐标」，避免玩家移动中把中间格当障碍。
        if (SimulatedPlayerCoord.HasValue)
        {
            if (SimulatedPlayerCoord.Value == coord) return true;
        }
        else
        {
            HexMover player = Player;
            if (player != null && player.CurrentCoord == coord) return true;
        }

        // 友军不阻挡 —— 零碰撞
        return false;
    }

    /// <summary>
    /// 探索巡逻齐步走：预先登记「本波结束时谁停在哪」。
    /// 移动中可以穿过别人当前格，但落点必须互斥（含玩家格）。
    /// </summary>
    public static class PatrolLandingClaims
    {
        static HashSet<Vector2Int> _cells;

        public static bool IsActive => _cells != null;

        public static void Begin()
        {
            _cells = GetOccupiedTiles();
        }

        public static void End()
        {
            _cells = null;
        }

        public static void Release(Vector2Int coord)
        {
            _cells?.Remove(coord);
        }

        public static bool CanStop(Vector2Int coord)
        {
            return _cells == null || !_cells.Contains(coord);
        }

        public static void Claim(Vector2Int coord)
        {
            _cells?.Add(coord);
        }
    }
}

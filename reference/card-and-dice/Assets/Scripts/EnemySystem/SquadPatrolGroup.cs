// =============================================================================
// 小队路径巡逻：路线锚点沿路点走；编队中心可偏一格让全员步数更均匀。往返朝向 +180°。
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class SquadPatrolGroup : MonoBehaviour
{
    public EnemySquadData Source { get; private set; }
    public SquadPatrolData SourcePatrol { get; private set; }
    public readonly List<EnemyController> Members = new List<EnemyController>();
    public readonly Dictionary<EnemyController, Vector2Int> TemplateOffset = new Dictionary<EnemyController, Vector2Int>();

    List<Vector2Int> _waypoints;
    SquadPatrolLoopMode _mode;
    int _patrolAP;
    int _searchAP;
    int _maxSearchCount;
    int _wpIndex;
    int _dir = 1;
    Vector2Int _route;
    Vector2Int _anchor;
    int _face;

    // ---- 远场廉价推进缓存（★2026-09-16 性能批）：只是缓存，不是新状态 ----
    // 段路径 = 「某个路线点 → 当前目标路点」的整条 A*；远场小队每回合只把 _farIdx 往前推 patrolAP 格。
    // 失效判定见 ExecuteFarFieldTurn：目标变了 / 走到段尾 / 路线被外部改动（_farPath[_farIdx] != _route）。
    List<Vector2Int> _farPath;
    int _farIdx;
    Vector2Int _farPathTarget;

    public Vector2Int Anchor => _anchor;

    /// <summary>
    /// 小队巡逻步距（<c>squadPatrolAP</c>，缺省 2），常态巡逻用。
    /// 搜索/归队步距 = <see cref="SearchAP"/>（§10.1）。
    /// 注意：白`?`回巡逻（回合5）期间会被 <see cref="BeginReturnRoute"/> 临时抬到全员最大战斗预算。
    /// </summary>
    public int PatrolAP => _patrolAP;

    /// <summary>搜索/归队步距（<c>squadSearchAP</c>，0 = 沿用 <c>squadPatrolAP</c>）。黄`?`散开与白`?`归队共用（§10.1，2026-09-08 用户定稿）。</summary>
    public int SearchAP => _searchAP;

    /// <summary>一次意图循环内散开搜寻的触发上限（<c>maxSearchCount</c>，缺省 2，§4）。</summary>
    public int MaxSearchCount => _maxSearchCount;

    // ---- 白`?`回巡逻（回合5）借用巡逻代码时暂存的真实巡逻状态 ----
    List<Vector2Int> _savedWaypoints;
    SquadPatrolLoopMode _savedMode;
    int _savedWpIndex;
    int _savedDir;
    int _savedPatrolAP;
    Vector2Int _savedAnchor;
    int _savedFace;
    bool _onReturnRoute;

    /// <summary>
    /// 是否正走在白`?`回巡逻的**临时两点路线**上（§4b 回合5）。
    /// 为 true 时整队移动由 <see cref="ExecutePatrolTurn"/> 接手，成员各自的
    /// <see cref="EnemyController.PatrolTurn"/> 必须让出，否则会被驱动两次。
    /// </summary>
    public bool IsOnReturnRoute => _onReturnRoute;

    /// <summary>
    /// 离给定格最近的路点（§13 leash 距离参照：路线巡逻 = 到最近路点的六边距离）。
    /// 无路点时返回 <c>false</c>，调用方退化为 <c>PatrolHomeCoord</c>。
    /// </summary>
    public bool TryGetNearestWaypoint(Vector2Int from, out Vector2Int waypoint)
    {
        waypoint = from;
        if (_waypoints == null || _waypoints.Count == 0) return false;

        int best = int.MaxValue;
        foreach (Vector2Int wp in _waypoints)
        {
            int d = CardExecutor.HexDistance(from, wp);
            if (d < best)
            {
                best = d;
                waypoint = wp;
            }
        }
        return true;
    }

    /// <summary>
    /// 白`?`归队（回合4）：以 <paramref name="anchor"/>（= 散开搜索参照点，也就是「散开搜索的位置」）
    /// 为编队中心重建**巡逻阵型**（§4b）。朝向取「锚点 → 最近路点」，表示队伍已经转向准备回去；
    /// 无路点可参照时沿用当前巡逻朝向。槽位不可站 → 退回锚点本身，再由停点互斥顺到旁边。
    /// </summary>
    public bool TryGetRegroupSlot(EnemyController e, Vector2Int anchor, out Vector2Int slot)
    {
        slot = anchor;
        if (e == null) return false;

        HexGridLayout grid = ExplorationPerf.Grid;      // ★2026-09-16 性能批：热点缓存（原为每次全场景扫）
        if (grid == null) return false;
        TerrainManager terrain = ExplorationPerf.Terrain;

        int face = _face;
        Vector2Int wp;
        if (TryGetNearestWaypoint(anchor, out wp) && wp != anchor) face = HexCoord.FacingSteps(anchor, wp);

        Vector2Int local;
        if (!TemplateOffset.TryGetValue(e, out local)) local = e.PatrolFormationOffset;
        slot = HexCoord.FormationSlot(anchor, local, face);

        if (!IsOpenCell(slot, grid, terrain)) slot = anchor;
        return IsOpenCell(slot, grid, terrain);
    }

    /// <summary>
    /// 白`?`回巡逻（回合5）：把路点连成折线，求 <paramref name="from"/> 到折线的**垂足**（§4b）。
    /// 六边格没有解析意义上的垂直投影，改用「逐段在 cube 空间线性插值采样 → 取六边距离最近的可站格」，
    /// 采样密度 = 段长 × 4，误差在半格以内。
    /// </summary>
    /// <param name="nextWpIndex">
    /// 垂足落在段 wp[k]—wp[k+1] 上时，按当前行进方向续接的路点下标：
    /// <c>_dir &gt; 0</c> → k+1，<c>_dir &lt; 0</c> → k（保持原巡逻方向，不因掉队而反转）。
    /// </param>
    public bool TryGetRouteProjection(Vector2Int from, out Vector2Int foot, out int nextWpIndex)
    {
        foot = from;
        nextWpIndex = _wpIndex;
        if (_waypoints == null || _waypoints.Count == 0) return false;

        if (_waypoints.Count == 1)
        {
            foot = _waypoints[0];
            nextWpIndex = 0;
            return true;
        }

        HexGridLayout grid = ExplorationPerf.Grid;      // ★2026-09-16 性能批：热点缓存（原为每次全场景扫）
        if (grid == null) return false;
        TerrainManager terrain = ExplorationPerf.Terrain;

        int best = int.MaxValue;
        bool found = false;
        for (int k = 0; k + 1 < _waypoints.Count; k++)
        {
            Vector2Int a = _waypoints[k];
            Vector2Int b = _waypoints[k + 1];

            Vector2Int segFoot;
            if (!HexCoord.TrySegmentFoot(from, a, b, cell => IsOpenCell(cell, grid, terrain), out segFoot)) continue;

            int d = CardExecutor.HexDistance(from, segFoot);
            if (d < best)
            {
                best = d;
                foot = segFoot;
                // 保持原巡逻方向续接：_dir>0 朝 k+1 走，_dir<0 朝 k 走
                nextWpIndex = _dir > 0 ? k + 1 : k;
                found = true;
            }
        }

        // 整条折线都站不了人（极端：地形/占位封死）→ 退回最近路点
        return found || TryGetNearestWaypoint(from, out foot);
    }

    /// <summary>
    /// 归线到位（或回合5走完仍没到、回合6 复原后就地并入）后，把巡逻状态接到垂足所在的那一段：
    /// 路线锚点 <c>_route</c> = 垂足、路点下标 = <paramref name="nextWpIndex"/>、**行进方向 <c>_dir</c> 不变**。
    /// 同队多名成员各自归线时会互相覆盖——回合4 已经原地重整过、队形很紧，垂足彼此只差一两格，覆盖无实质影响。
    /// </summary>
    public void ResumeRouteAt(Vector2Int foot, int nextWpIndex)
    {
        if (_waypoints == null || _waypoints.Count == 0) return;
        _route = foot;
        _wpIndex = Mathf.Clamp(nextWpIndex, 0, _waypoints.Count - 1);
        _cacheValid = false;
    }

    // ------------------------------------------------------------------
    // 白`?`回巡逻（回合5）：临时两点路线，把归线交给巡逻代码本身
    // ------------------------------------------------------------------

    /// <summary>
    /// 白`?`归队走完 → 白`?`回巡逻（§3 回合5 / §4b）：暂存真实巡逻状态，
    /// 用 <c>[当前队心, 巡逻折线垂足]</c> 顶出一条**临时两点路线**，之后这一回合的整队移动
    /// 完全交给 <see cref="ComputeTurnPlan"/> / <see cref="ExecutePatrolTurn"/>。
    /// </summary>
    /// <remarks>
    /// ★为什么不自己写归线：自己算落点会绕开 <see cref="TravelFaceFor"/>（往返的头尾翻转 + 180° 朝向）
    /// 与 <see cref="ChoosePlaceAnchor"/> / <c>HexCoord.FormationSlot</c>（阵型绕中心旋转），
    /// 队伍走到垂足时朝向还是旧的，得再花一回合原地掉头/转阵（用户实测 2026-09-08）。
    /// 顶一条临时路线进去，巡逻代码自己就会把朝向和阵型一起摆正。
    /// ★队心已经在折线上（投影垂足 = 队心）或没有折线可投时**不动路点**：
    /// 这一回合直接由真实巡逻接手，效果就是「就地重整队形继续走」。
    /// </remarks>
    public void BeginReturnRoute()
    {
        if (_onReturnRoute) return;   // 同队多名成员各自推进阶段 → 只装一次

        PruneDead();
        var live = new List<EnemyController>();
        foreach (EnemyController m in Members) if (m != null && !m.IsDead) live.Add(m);
        if (live.Count == 0) return;

        _savedWaypoints = _waypoints;
        _savedMode = _mode;
        _savedWpIndex = _wpIndex;
        _savedDir = _dir;
        _savedPatrolAP = _patrolAP;
        _savedAnchor = _anchor;
        _savedFace = _face;
        _onReturnRoute = true;

        // 垂足按队心求、全队共用一个归线点（§4b）——必须在覆盖 _waypoints 之前算。
        Vector2Int from = SearchScatterPlanner.Centroid(live);
        Vector2Int foot;
        if (_waypoints != null && _waypoints.Count > 0
            && TryGetRouteProjection(from, out foot, out _) && foot != from)
        {
            _waypoints = new List<Vector2Int> { from, foot };
            _mode = SquadPatrolLoopMode.往返;
            _wpIndex = 1;      // 「正在朝垂足走」
            _dir = 1;
            _route = from;
            _anchor = from;
            _face = HexCoord.FacingSteps(from, foot);
        }

        // 归线是全力赶路，不是慢悠悠巡逻：步数上限抬到全员最大的战斗移动预算（行动点 + 疾跑）。
        _patrolAP = Mathf.Max(_patrolAP, MaxMoveBudget(live));
        _cacheValid = false;
    }

    /// <summary>
    /// 回巡逻结束（回合6 复原 / 中途重新进战）：还原真实路点与行进方向，
    /// 再从**绕行终点**重新投影接回原折线——绕行走到了哪一段就接哪一段（§4b「不强制走完全程」）。
    /// </summary>
    public void EndReturnRoute()
    {
        if (!_onReturnRoute) return;
        _onReturnRoute = false;

        Vector2Int detourRoute = _route;   // 就地并入：绕行推进到哪，真实巡逻就从哪接着走
        _waypoints = _savedWaypoints;
        _mode = _savedMode;
        _wpIndex = _savedWpIndex;
        _dir = _savedDir;
        _patrolAP = _savedPatrolAP;
        _anchor = _savedAnchor;
        _face = _savedFace;
        _savedWaypoints = null;

        // 先还原 _dir 再投影：TryGetRouteProjection 用 _dir 决定续接 k 还是 k+1，
        // 拿绕行期间的 _dir=1 去算会把真实路线的行进方向接反。
        Vector2Int foot;
        int nextWp;
        if (_waypoints != null && _waypoints.Count > 0
            && TryGetRouteProjection(detourRoute, out foot, out nextWp))
        {
            ResumeRouteAt(foot, nextWp);
            _anchor = foot;
        }
        else
        {
            _route = detourRoute;
        }
        _cacheValid = false;
    }

    /// <summary>全员里最大的战斗移动预算（行动点 + 疾跑），归线期间当整队步数上限用。</summary>
    static int MaxMoveBudget(List<EnemyController> members)
    {
        int best = 0;
        foreach (EnemyController m in members)
        {
            if (m == null || m.IsDead) continue;
            best = Mathf.Max(best, m.MoveBudget);
        }
        return Mathf.Max(1, best);
    }

    /// <param name="waypointsOverride">
    /// ★2026-09-12 每局随机落位：<see cref="SquadSpawnPlacer"/> 平移后的实际路线。
    /// 传了就用它，否则用 patrol.patrolWaypoints。
    /// </param>
    public static SquadPatrolGroup Create(SquadPatrolData patrol, Vector2Int startAnchor, Transform parent,
        IList<Vector2Int> waypointsOverride = null)
    {
        EnemySquadData squad = patrol != null ? patrol.squad : null;
        var go = new GameObject("小队巡逻_" + (patrol != null && !string.IsNullOrEmpty(patrol.patrolName)
            ? patrol.patrolName
            : (squad != null ? squad.squadName : "未命名")));
        if (parent != null) go.transform.SetParent(parent, false);
        var g = go.AddComponent<SquadPatrolGroup>();
        g.Source = squad;
        g.SourcePatrol = patrol;
        if (waypointsOverride != null && waypointsOverride.Count > 0)
        {
            g._waypoints = new List<Vector2Int>(waypointsOverride);
        }
        else
        {
            g._waypoints = patrol != null && patrol.patrolWaypoints != null
                ? new List<Vector2Int>(patrol.patrolWaypoints)
                : new List<Vector2Int>();
        }
        g._mode = patrol != null ? patrol.patrolLoopMode : SquadPatrolLoopMode.往返;
        g._patrolAP = patrol != null && patrol.squadPatrolAP > 0 ? patrol.squadPatrolAP : 2;
        g._searchAP = patrol != null && patrol.squadSearchAP > 0 ? patrol.squadSearchAP : g._patrolAP;
        g._maxSearchCount = patrol != null ? patrol.maxSearchCount : 2;
        g._route = startAnchor;
        g._anchor = startAnchor;
        g._wpIndex = g._waypoints.Count >= 2 ? 1 : 0;
        g._dir = 1;
        if (g._waypoints.Count >= 2)
        {
            g._face = HexCoord.FacingSteps(g._waypoints[0], g._waypoints[1]);
        }
        return g;
    }

    public void Register(EnemyController member, Vector2Int templateOffset)
    {
        if (member == null) return;
        Members.Add(member);
        TemplateOffset[member] = templateOffset;
        member.PatrolGroup = this;
        member.PatrolFormationOffset = templateOffset;
    }

    /// <summary>
    /// 本小队是否含任意一名参战者（正在战斗的敌人）。
    /// ★2026-09-10：用于区分「参战小队」（战斗中冻结巡逻，由战斗执行器驱动）与
    /// 「纯非参战小队」（战斗中继续巡逻，设计增补_威胁预告与搜索 §8）。
    /// </summary>
    public bool HasAnyParticipant()
    {
        if (BattleResultHandler.Instance == null) return false;
        foreach (EnemyController m in Members)
        {
            if (m != null && !m.IsDead && BattleResultHandler.Instance.IsParticipant(m)) return true;
        }
        return false;
    }

    public bool IsIdleMember(EnemyController e)
    {
        if (e == null || e.IsDead) return false;
        // ★2026-09-09 修复：白`?`回巡逻装了临时路线时这段移动**就是**整队归线，必须算空闲。
        //   原顺序里 IsResting（白回巡逻阶段命中）会先 return false，导致 ExecutePatrolTurn
        //   判 anyIdle=false 直接空过、白`?`第二回合怪物原地不动。故把该例外提前到 IsResting 判定之前。
        if (e.IsReturningHome && _onReturnRoute) return true;
        if (e.IsAlerted || e.IsCurious || e.IsSearching || e.IsResting || e.IsChasing) return false;
        if (e.IsReturningHome && !_onReturnRoute) return false;
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            if (BattleResultHandler.Instance != null && BattleResultHandler.Instance.IsParticipant(e))
                return false;
        }
        return true;
    }

    /// <summary>
    /// ★下一回合整队**真实**落点（威胁预告与搜索 §2.2 红`?`预测口径 / §17「小队落点干跑抽纯函数」）。
    /// 与 <see cref="ExecutePatrolTurn"/> 共用同一份计划（<see cref="ComputeTurnPlan"/>）——
    /// 项目铁律「预览 = 执行」：红`?`亮就一定看得见，不亮就一定看不见。
    /// 纯查询：不推进 _route/_face/_wpIndex/_anchor、不移动单位、不占格。
    /// </summary>
    /// <returns>每个会移动的成员的落点；无法预测（无路点 / 无网格）返回空表。</returns>
    public Dictionary<EnemyController, Vector2Int> PredictNextLandings()
    {
        var result = new Dictionary<EnemyController, Vector2Int>();

        TurnPlan plan = ComputeTurnPlan();
        if (!plan.valid) return result;

        // 同队成员本回合都会离开自己脚下的格子（执行器 PatrolLandingClaims.Release 同口径），
        // 所以它们不算路径尾段的障碍。
        var moving = new HashSet<Vector2Int>();
        foreach (EnemyController m in plan.paths.Keys)
        {
            if (m != null) moving.Add(m.CurrentCoord);
        }

        foreach (KeyValuePair<EnemyController, List<Vector2Int>> kv in plan.paths)
        {
            List<Vector2Int> memberPath = kv.Value;
            if (memberPath == null || memberPath.Count <= 1) continue;
            int take = Mathf.Min(plan.budget, memberPath.Count - 1);
            if (take < 1) continue;
            result[kv.Key] = SettleLanding(memberPath, take, moving);
        }
        return result;
    }

    /// <summary>
    /// 把计划落点收敛到**执行时真能停下的那一格**。
    /// <see cref="EnemyController.MoveToCoordSmooth"/> 会沿路径从尾往回退，直到遇到一个没被占的停点；
    /// 而计划阶段的 <see cref="IsOpenCell"/> 只查界内/地形/玩家格，<c>PlanNonOverlappingPaths</c>
    /// 也只保证队内不重叠——路径尾段完全可能压在别的单位（追击者、好奇围观者、别的小队、散开搜索者）身上。
    /// 预测若照抄 <c>path[take]</c>，就会报一个走不到的落点：红`?`亮了、敌人实际少走几格、根本没看见玩家
    /// （用户实测 2026-09-08「小队巡逻的距离减少了导致没有看见玩家」）。
    /// </summary>
    static Vector2Int SettleLanding(List<Vector2Int> path, int take, HashSet<Vector2Int> moving)
    {
        int end = take;
        while (end > 0 && UnitOccupancy.IsOccupied(path[end]) && !moving.Contains(path[end])) end--;
        return path[end];
    }

    /// <summary>
    /// 一个敌人回合的完整移动计划（纯数据，无副作用）。执行器提交并走它，红`?`预告只读它，
    /// 两者因此不可能给出不同的落点。
    /// </summary>
    public struct TurnPlan
    {
        /// <summary>成员 → 预解算路径（含起点）；可能含绕行（交换位置时尽量不共用格子）</summary>
        public Dictionary<EnemyController, List<Vector2Int>> paths;
        /// <summary>本回合齐步走步数上限</summary>
        public int budget;
        // ---- 以下为解算出的新状态，仅 <see cref="CommitPlan"/> 会写回字段 ----
        public Vector2Int route;
        public Vector2Int anchor;
        public int face;
        public int wpIndex;
        public int dir;
        /// <summary>false = 解算失败（无路点 / 无网格），执行器与预告都应当跳过</summary>
        public bool valid;
    }

    TurnPlan _cachedPlan;
    long _cachedSignature;
    Vector2Int _cachedPlayerCoord;
    bool _cacheValid;

    /// <summary>
    /// 解算下一回合的整队移动计划。按 (棋盘签名, 玩家坐标) 缓存：
    /// 徽章每敌一个、都在 LateUpdate 里问，同一回合内两者都不变 → 整队只算一次
    /// （<see cref="PlanNonOverlappingPaths"/> 会排列成员顺序做多次 A*，不能每次现算）。
    /// ★必须带上玩家坐标：<see cref="EnemyLandingPlanner.CurrentSignature"/> 只覆盖敌人的
    /// 坐标/揭示代数/AP/疾跑，而 <see cref="ChoosePlaceAnchor"/> 走的 IsOpenCell 会把玩家所在格
    /// 判为不可用——玩家一移动，整队锚点就可能换一格。
    /// </summary>
    public TurnPlan ComputeTurnPlan()
    {
        long sig = EnemyLandingPlanner.CurrentSignature;
        // ★2026-09-16 性能批：原本每队每次解算 3 次全场景 FindObjectOfType（荒野图 ≈ 万对象），改走 ExplorationPerf 缓存。
        HexMover player = ExplorationPerf.Player;
        Vector2Int playerCoord = player != null ? player.CurrentCoord : new Vector2Int(int.MinValue, int.MinValue);

        if (_cacheValid && _cachedSignature == sig && _cachedPlayerCoord == playerCoord) return _cachedPlan;

        var plan = new TurnPlan
        {
            paths = new Dictionary<EnemyController, List<Vector2Int>>(),
            wpIndex = _wpIndex,
            dir = _dir,
            route = _route,
            anchor = _anchor,
            face = _face,
            valid = false
        };

        if (_waypoints == null || _waypoints.Count == 0) return plan; // 不缓存：路点可能稍后才配上

        // 与 ExecutePatrolTurn 头部守卫同源：战斗态整队巡逻停摆、根本不会移动。
        // 照样解算会让红`?`对一个永不发生的移动发出预警（误报）。不缓存——状态随时会切回来。
        // ★2026-09-10：仅「含参战者」的小队在战斗态冻结巡逻（参战者由战斗执行器驱动，不能巡逻）。
        // 纯非参战小队在战斗中继续巡逻（设计增补_威胁预告与搜索 §8：未参战小队继续巡逻），
        // 故放开其解算——红`?`威胁预告也会如实反映它们的移动（预览=执行铁律）。
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle
            && HasAnyParticipant())
        {
            return plan;
        }

        HexGridLayout grid = ExplorationPerf.Grid;
        if (grid == null) return plan;                                // 不缓存：网格可能稍后才生成
        TerrainManager terrain = ExplorationPerf.Terrain;

        // ① 路点到达 → 换下一段（在副本上演算，不写字段）
        int wpIndex = _wpIndex;
        int dir = _dir;
        SimulateIndexAdvance(ref wpIndex, ref dir, _route);
        Vector2Int destWp = _waypoints[Mathf.Clamp(wpIndex, 0, _waypoints.Count - 1)];

        // ② 路线锚点沿路点推进 patrolAP 步
        Vector2Int route = _route;
        List<Vector2Int> routePath = new AStarPathfinding(grid).FindPath(_route, destWp, allowOccupiedTarget: true);
        if (routePath != null && routePath.Count > 1)
        {
            route = routePath[Mathf.Min(_patrolAP, routePath.Count - 1)];
        }

        // ③ 朝向按新路段重算（往返回来 = 去程 + 180°）
        int face = TravelFaceFor(wpIndex, dir, _face);

        var idle = new List<EnemyController>();
        foreach (EnemyController m in Members)
        {
            if (IsIdleMember(m)) idle.Add(m);
        }

        // ④ 编队中心可偏一格让全员步数更均匀 → 槽位 → 尽量不共用格子的路径
        Vector2Int anchor = ChoosePlaceAnchor(route, face, idle, grid, terrain);
        var targets = new Dictionary<EnemyController, Vector2Int>();
        foreach (EnemyController m in idle)
        {
            Vector2Int local;
            if (!TemplateOffset.TryGetValue(m, out local)) local = m.PatrolFormationOffset;
            targets[m] = HexCoord.FormationSlot(anchor, local, face);
        }

        Dictionary<EnemyController, List<Vector2Int>> paths = PlanNonOverlappingPaths(idle, targets, grid);

        // ⑤ 步数上限：让最远的人也走得到，但最多比 patrolAP 多 2
        int longest = 0;
        int sumDist = 0;
        foreach (KeyValuePair<EnemyController, List<Vector2Int>> kv in paths)
        {
            int steps = kv.Value != null ? kv.Value.Count - 1 : 0;
            if (steps > longest) longest = steps;
            Vector2Int target;
            if (targets.TryGetValue(kv.Key, out target))
                sumDist += Mathf.Max(0, CardExecutor.HexDistance(kv.Key.CurrentCoord, target));
        }
        int n = Mathf.Max(1, idle.Count);
        int avg = (sumDist + n - 1) / n;

        plan.paths = paths;
        plan.budget = Mathf.Clamp(Mathf.Max(_patrolAP, Mathf.Max(avg, longest)), _patrolAP, _patrolAP + 2);
        plan.route = route;
        plan.anchor = anchor;
        plan.face = face;
        plan.wpIndex = wpIndex;
        plan.dir = dir;
        plan.valid = true;

        _cachedPlan = plan;
        _cachedSignature = sig;
        _cachedPlayerCoord = playerCoord;
        _cacheValid = true;
        return plan;
    }

    /// <summary>提交计划状态（仅执行器调用）。提交后缓存立即失效——字段已变，下次要算下一回合。</summary>
    void CommitPlan(TurnPlan plan)
    {
        _wpIndex = plan.wpIndex;
        _dir = plan.dir;
        _route = plan.route;
        _anchor = plan.anchor;
        _face = plan.face;
        _cacheValid = false;
    }

    /// <summary>
    /// <see cref="AdvanceIndexIfArrived"/> 的纯版本：在 (wpIndex, dir) 副本上演算「已到当前路点 → 换下一段」，
    /// 不写任何字段，供 <see cref="ComputeTurnPlan"/> 干跑。
    /// </summary>
    void SimulateIndexAdvance(ref int wpIndex, ref int dir, Vector2Int route)
    {
        if (_waypoints == null || _waypoints.Count == 0) return;
        if (CardExecutor.HexDistance(route, _waypoints[Mathf.Clamp(wpIndex, 0, _waypoints.Count - 1)]) > 0) return;
        if (_waypoints.Count == 1) return;

        if (_mode == SquadPatrolLoopMode.循环)
        {
            wpIndex = (wpIndex + 1) % _waypoints.Count;
            return;
        }

        int next = wpIndex + dir;
        if (next >= _waypoints.Count)
        {
            dir = -1;
            wpIndex = _waypoints.Count - 2;
        }
        else if (next < 0)
        {
            dir = 1;
            wpIndex = 1;
        }
        else
        {
            wpIndex = next;
        }
    }

    public IEnumerator ExecutePatrolTurn()
    {
        PruneDead();
        if (Members.Count == 0)
        {
            Destroy(gameObject);
            yield break;
        }

        // ★2026-09-10：仅冻结「含参战者」的小队；纯非参战小队战斗中照常巡逻（§8）。
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle
            && HasAnyParticipant())
        {
            yield break;
        }

        bool anyIdle = false;
        foreach (EnemyController m in Members)
        {
            if (IsIdleMember(m)) { anyIdle = true; break; }
        }
        if (!anyIdle) yield break;

        if (_waypoints == null || _waypoints.Count == 0) yield break;

        // ★2026-09-16 性能批：远场小队走廉价推进（不算 A*、不排成员顺序、不播逐格动画）。
        //   三条门槛一起卡：① 不在白`?`回巡逻（临时路线必须整队齐步）
        //   ② 全员空闲（搜索/追击/休整要的是完整解算）③ **全员**都在 PatrolLodRadius 之外
        //   —— 用「全员」而不是队心：只要有一位成员在半径内，它的徽章就可能正在算红`?`，
        //   两边必须同源（铁律「预览 = 执行」）。半径 30 > 渲染裁剪半径 26 ⇒ 玩家看得见的永远走完整解算。
        if (!_onReturnRoute && AllMembersIdle() && AllMembersFarFromPlayer())
        {
            ExecuteFarFieldTurn();
            yield break;
        }

        // 计划与红`?`威胁预告共用同一份（铁律「预览 = 执行」）：预告读到的落点就是这里会走到的落点。
        System.Diagnostics.Stopwatch planWatch = ExplorationPerf.StartTimer();
        TurnPlan plan = ComputeTurnPlan();
        ExplorationPerf.EndPlanScope(planWatch);
        if (!plan.valid) yield break;
        CommitPlan(plan);

        var memberMoves = new List<IEnumerator>();
        var movers = new List<EnemyController>();
        foreach (KeyValuePair<EnemyController, List<Vector2Int>> kv in plan.paths)
        {
            EnemyController m = kv.Key;
            List<Vector2Int> memberPath = kv.Value;
            if (memberPath == null || memberPath.Count <= 1) continue;

            int take = Mathf.Min(plan.budget, memberPath.Count - 1);
            if (take < 1) continue;
            movers.Add(m);
            memberMoves.Add(m.MoveToCoordSmooth(memberPath[take], memberPath.GetRange(0, take + 1)));
        }

        // 齐步走前先腾出「本回合会离开」的格子，后排才能停进前排刚离开的格（中途可穿过，停点仍互斥）。
        if (UnitOccupancy.PatrolLandingClaims.IsActive)
        {
            foreach (EnemyController m in movers)
            {
                UnitOccupancy.PatrolLandingClaims.Release(m.CurrentCoord);
            }
        }

        yield return CoroutineBatch.WhenAll(this, memberMoves);

        // ★2026-09-10：巡逻落点撞见玩家 → 被动遇袭（探索态逻辑）。战斗中此判定交由
        //   TryDisengageAfterEnemyTurn 的「非参战小队看见玩家 → 整队参战」统一处理，
        //   避免巡逻协程中途切状态污染战斗回合。故战斗态跳过该检测。
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            foreach (EnemyController m in Members)
            {
                if (m == null || m.IsDead) continue;
                if (ExplorationTurnManager.Instance != null
                    && ExplorationTurnManager.Instance.CheckPatrolVisionPublic(m))
                {
                    yield break;
                }
            }
        }

        AdvanceIndexIfArrived();
    }

    /// <summary>全员都是常态巡逻状态（没有一员在搜索/追击/休整/警戒）。</summary>
    bool AllMembersIdle()
    {
        foreach (EnemyController m in Members)
        {
            if (m == null) continue;
            if (!IsIdleMember(m)) return false;
        }
        return true;
    }

    /// <summary>
    /// 全员（存活成员）离玩家都超过 <see cref="ExplorationPerf.PatrolLodRadius"/>。
    /// ★用「全员」而不是队心：只要有一位成员在半径内，它的意图徽章就可能正在算红`?`，
    /// 徽章读的是完整解算的计划 —— 两边必须同源（铁律「预览 = 执行」）。空队返回 false（保守不降级）。
    /// </summary>
    bool AllMembersFarFromPlayer()
    {
        bool any = false;
        foreach (EnemyController m in Members)
        {
            if (m == null || m.IsDead) continue;
            any = true;
            if (!ExplorationPerf.IsFarFromPlayer(m.CurrentCoord, ExplorationPerf.PatrolLodRadius)) return false;
        }
        return any;
    }

    /// <summary>
    /// ★2026-09-16 性能批：远场小队的廉价巡逻推进。与 <see cref="ComputeTurnPlan"/> **同源**地推进路线
    /// （<see cref="SimulateIndexAdvance"/> 干跑 + 段路径缓存 ⇒ 一回合只把下标推 <see cref="PatrolAP"/> 格，
    /// 约十回合才算一次 A*），成员**直接落位**到编队槽位，不排成员顺序、不播逐格动画。
    /// 玩家看不见的区域不值得为「走位好看」付完整解算的钱；一旦有人进半径，下回合立刻恢复完整解算。
    /// </summary>
    void ExecuteFarFieldTurn()
    {
        System.Diagnostics.Stopwatch farWatch = ExplorationPerf.StartTimer();

        // ① 路点到达 → 换下一段（与 ComputeTurnPlan 同一套干跑，不写字段）
        int wpIndex = _wpIndex;
        int dir = _dir;
        SimulateIndexAdvance(ref wpIndex, ref dir, _route);
        Vector2Int destWp = _waypoints[Mathf.Clamp(wpIndex, 0, _waypoints.Count - 1)];

        // ② 段路径缓存：只在「无缓存 / 目标变了 / 走到段尾 / 路线被外部改过（ResumeRouteAt 等）」时算一次 A*
        if (_farPath == null || _farPath.Count == 0 || _farPathTarget != destWp
            || _farIdx >= _farPath.Count - 1 || _farPath[_farIdx] != _route)
        {
            List<Vector2Int> path;
            if (_route == destWp)
            {
                path = new List<Vector2Int> { _route };     // 单路点 / 已站在目标点上：不走 A*
            }
            else
            {
                HexGridLayout pathGrid = ExplorationPerf.Grid;
                path = pathGrid != null
                    ? new AStarPathfinding(pathGrid).FindPath(_route, destWp, allowOccupiedTarget: true)
                    : null;
            }
            if (path == null || path.Count == 0)
            {
                ExplorationPerf.EndFarScope(farWatch);      // 无网格 / 无路可达：这回合原地不动，下回合再试
                return;
            }
            _farPath = path;
            _farPathTarget = destWp;
            _farIdx = 0;
        }

        // ③ 整队沿缓存路径推进（步距与完整解算同为 patrolAP）
        _farIdx = Mathf.Min(_farIdx + Mathf.Max(1, _patrolAP), _farPath.Count - 1);
        Vector2Int route = _farPath[_farIdx];
        int face = TravelFaceFor(wpIndex, dir, _face);

        // ④ 成员就地落位：编队槽位 → 队心 → 原地（落点互斥与完整解算同口径）
        HexGridLayout grid = ExplorationPerf.Grid;
        TerrainManager terrain = ExplorationPerf.Terrain;
        bool claims = UnitOccupancy.PatrolLandingClaims.IsActive;
        if (claims)
        {
            // 先腾出「本回合会离开」的格子：换阵时后排才能停进前排刚离开的格（与 ExecutePatrolTurn 同口径）
            foreach (EnemyController m in Members)
            {
                if (m != null && !m.IsDead) UnitOccupancy.PatrolLandingClaims.Release(m.CurrentCoord);
            }
        }

        var taken = new HashSet<Vector2Int>();
        foreach (EnemyController m in Members)
        {
            if (m == null || m.IsDead) continue;

            Vector2Int local;
            if (!TemplateOffset.TryGetValue(m, out local)) local = m.PatrolFormationOffset;
            Vector2Int slot = HexCoord.FormationSlot(route, local, face);

            if (!IsOpenCell(slot, grid, terrain) || !UnitOccupancy.PatrolLandingClaims.CanStop(slot) || !taken.Add(slot))
                slot = route;
            if (!IsOpenCell(slot, grid, terrain) || !UnitOccupancy.PatrolLandingClaims.CanStop(slot) || !taken.Add(slot))
                slot = m.CurrentCoord;                      // 极端拥挤：原地不动，下回合再说

            if (slot != m.CurrentCoord) m.MoveToCoord(slot);
            if (claims) UnitOccupancy.PatrolLandingClaims.Claim(slot);
        }

        // ⑤ 提交状态（与 CommitPlan 同源）+ 让缓存的完整解算作废
        _wpIndex = wpIndex;
        _dir = dir;
        _route = route;
        _anchor = route;
        _face = face;
        _cacheValid = false;
        AdvanceIndexIfArrived();

        ExplorationPerf.EndFarScope(farWatch);

        // ⑥ 落点撞见玩家 → 被动遇袭（与完整解算同口径；远场半径远大于任何视野，正常不会触发）
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            foreach (EnemyController m in Members)
            {
                if (m == null || m.IsDead) continue;
                if (ExplorationTurnManager.Instance != null
                    && ExplorationTurnManager.Instance.CheckPatrolVisionPublic(m))
                {
                    return;
                }
            }
        }
    }

    /// <summary>
    /// 路段朝向。往返走同一条边时，回来 = 去程朝向 + 180°（不各算一次最近邻向，避免横线平局拧阵）。
    /// 参数化以便 <see cref="ComputeTurnPlan"/> 在副本上演算（干跑不写字段）。
    /// </summary>
    int TravelFaceFor(int wpIndex, int dir, int fallbackFace)
    {
        if (_waypoints == null || _waypoints.Count < 2) return fallbackFace;

        int dst = Mathf.Clamp(wpIndex, 0, _waypoints.Count - 1);
        int src;
        if (_mode == SquadPatrolLoopMode.循环)
        {
            src = (dst - dir + _waypoints.Count) % _waypoints.Count;
        }
        else
        {
            src = Mathf.Clamp(dst - dir, 0, _waypoints.Count - 1);
        }
        if (src == dst) return fallbackFace;

        bool wrap = _mode == SquadPatrolLoopMode.循环 && Mathf.Abs(src - dst) != 1;
        if (wrap)
        {
            int loopFace = HexCoord.FacingSteps(_waypoints[_waypoints.Count - 1], _waypoints[0]);
            return dir > 0 ? loopFace : (loopFace + 3) % 6;
        }

        int lo = Mathf.Min(src, dst);
        int hi = Mathf.Max(src, dst);
        int edgeFace = HexCoord.FacingSteps(_waypoints[lo], _waypoints[hi]);
        return src < dst ? edgeFace : (edgeFace + 3) % 6;
    }

    /// <summary>
    /// 路线锚点本身 + 周围 6 格，选让全员到自己槽位的「最远的人」尽量近、步数差尽量小的中心。
    /// </summary>
    Vector2Int ChoosePlaceAnchor(Vector2Int route, int face, List<EnemyController> idle,
        HexGridLayout grid, TerrainManager terrain)
    {
        if (idle == null || idle.Count == 0) return route;

        Vector2Int best = route;
        int bestScore = int.MaxValue;
        var candidates = new List<Vector2Int> { route };
        foreach (Vector2Int n in MoveAIController.GetNeighbors(route)) candidates.Add(n);

        foreach (Vector2Int place in candidates)
        {
            if (!IsOpenCell(place, grid, terrain)) continue;

            var used = new HashSet<Vector2Int>();
            int sum = 0;
            int maxD = 0;
            int minD = int.MaxValue;
            bool ok = true;
            foreach (EnemyController m in idle)
            {
                if (!TemplateOffset.TryGetValue(m, out Vector2Int local)) local = m.PatrolFormationOffset;
                Vector2Int slot = HexCoord.FormationSlot(place, local, face);
                if (!used.Add(slot) || !IsOpenCell(slot, grid, terrain))
                {
                    ok = false;
                    break;
                }
                int d = CardExecutor.HexDistance(m.CurrentCoord, slot);
                sum += d;
                if (d > maxD) maxD = d;
                if (d < minD) minD = d;
            }
            if (!ok) continue;

            int spread = maxD - minD;
            int score = maxD * 100 + spread * 40 + sum * 2 + (place == route ? 0 : 1);
            if (score < bestScore)
            {
                bestScore = score;
                best = place;
            }
        }

        return best;
    }

    /// <summary>
    /// 交换位置时路径尽量不共用格子：允许比最短路多走 1 格绕开；绕超过 1 格则允许重叠。
    /// </summary>
    Dictionary<EnemyController, List<Vector2Int>> PlanNonOverlappingPaths(
        List<EnemyController> idle, Dictionary<EnemyController, Vector2Int> targets, HexGridLayout grid)
    {
        var best = AssignPathsInOrder(idle, targets, grid);
        int bestScore = ScorePaths(best);
        if (idle.Count <= 1 || idle.Count > 5) return best;

        var order = new List<EnemyController>(idle);
        foreach (List<EnemyController> perm in Permute(order, 0))
        {
            var plan = AssignPathsInOrder(perm, targets, grid);
            int score = ScorePaths(plan);
            if (score < bestScore)
            {
                bestScore = score;
                best = plan;
            }
        }
        return best;
    }

    Dictionary<EnemyController, List<Vector2Int>> AssignPathsInOrder(
        List<EnemyController> order, Dictionary<EnemyController, Vector2Int> targets, HexGridLayout grid)
    {
        var result = new Dictionary<EnemyController, List<Vector2Int>>();
        var claimed = new HashSet<Vector2Int>();
        var astar = new AStarPathfinding(grid);

        foreach (EnemyController m in order)
        {
            if (!targets.TryGetValue(m, out Vector2Int slot)) continue;
            if (m.CurrentCoord == slot)
            {
                result[m] = new List<Vector2Int> { m.CurrentCoord };
                continue;
            }

            List<Vector2Int> shortest = astar.FindPath(m.CurrentCoord, slot, allowOccupiedTarget: true, enemyRequester: m);
            if (shortest == null || shortest.Count <= 1)
            {
                result[m] = shortest;
                continue;
            }

            int limit = shortest.Count; // 节点数；允许多 1 格 ⇒ detour.Count <= shortest.Count + 1
            List<Vector2Int> detour = claimed.Count == 0
                ? null
                : astar.FindPath(m.CurrentCoord, slot, allowOccupiedTarget: true, enemyRequester: m, planningReserved: claimed);

            List<Vector2Int> chosen = shortest;
            if (detour != null && detour.Count > 1 && detour.Count <= limit + 1)
            {
                chosen = detour;
            }

            result[m] = chosen;
            for (int i = 1; i < chosen.Count; i++) claimed.Add(chosen[i]);
        }

        return result;
    }

    static int ScorePaths(Dictionary<EnemyController, List<Vector2Int>> plan)
    {
        var used = new Dictionary<Vector2Int, int>();
        int length = 0;
        foreach (var kv in plan)
        {
            List<Vector2Int> path = kv.Value;
            if (path == null) { length += 50; continue; }
            length += Mathf.Max(0, path.Count - 1);
            for (int i = 1; i < path.Count - 1; i++)
            {
                Vector2Int c = path[i];
                used.TryGetValue(c, out int n);
                used[c] = n + 1;
            }
        }
        int overlap = 0;
        foreach (var kv in used)
        {
            if (kv.Value > 1) overlap += kv.Value - 1;
        }
        return overlap * 100 + length;
    }

    static IEnumerable<List<EnemyController>> Permute(List<EnemyController> items, int start)
    {
        if (start >= items.Count - 1)
        {
            yield return new List<EnemyController>(items);
            yield break;
        }

        for (int i = start; i < items.Count; i++)
        {
            EnemyController tmp = items[start];
            items[start] = items[i];
            items[i] = tmp;
            foreach (var p in Permute(items, start + 1)) yield return p;
            items[i] = items[start];
            items[start] = tmp;
        }
    }

    static bool IsOpenCell(Vector2Int cell, HexGridLayout grid, TerrainManager terrain)
    {
        if (grid != null && (cell.x < 0 || cell.y < 0 || cell.x >= grid.gridSize.x || cell.y >= grid.gridSize.y))
        {
            return false;
        }
        if (terrain != null && !terrain.IsPassable(cell)) return false;
        // ★2026-09-16 性能批：本函数在槽位搜索里被密集调用（锚点 7 候补 × 全员），原实现每次全场景找玩家。
        HexMover player = ExplorationPerf.Player;
        if (player != null && player.CurrentCoord == cell) return false;
        return true;
    }

    void AdvanceIndexIfArrived()
    {
        if (_waypoints == null || _waypoints.Count == 0) return;
        if (CardExecutor.HexDistance(_route, _waypoints[Mathf.Clamp(_wpIndex, 0, _waypoints.Count - 1)]) > 0)
        {
            return;
        }

        if (_waypoints.Count == 1) return;

        if (_mode == SquadPatrolLoopMode.循环)
        {
            _wpIndex = (_wpIndex + 1) % _waypoints.Count;
            return;
        }

        int next = _wpIndex + _dir;
        if (next >= _waypoints.Count)
        {
            _dir = -1;
            _wpIndex = _waypoints.Count - 2;
        }
        else if (next < 0)
        {
            _dir = 1;
            _wpIndex = 1;
        }
        else
        {
            _wpIndex = next;
        }
    }

    void PruneDead()
    {
        for (int i = Members.Count - 1; i >= 0; i--)
        {
            if (Members[i] == null || Members[i].IsDead)
            {
                if (Members[i] != null) TemplateOffset.Remove(Members[i]);
                Members.RemoveAt(i);
            }
        }
    }
}

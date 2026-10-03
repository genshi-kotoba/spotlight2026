// =============================================================================
// 散开搜索规划（黄`?`搜捕）：职责槽位扇形散开 + 固定巡逻 AP + leash 裁剪 + 落点互斥
// 设计依据：《设计增补_威胁预告与搜索阶段.md》§12（方案 A 职责映射）/ §13（leash）/ §10.1（AP 映射）
// 参照点 = LastSeenCoord —— 脱战搜捕时是玩家最后消失格，陷阱响应时由陷阱格顶替写入。
// 职责边界：只做规划（落点 + 路径），不扣血、不碰 UI、不改徽章状态。
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 黄`?`散开搜索的落点解算器。与巡逻队形（<see cref="SquadPatrolGroup"/>）互不干涉：
/// 巡逻走路线锚点 + 编队槽位，搜索走参照点 + 职责扇形槽位。
/// </summary>
public static class SearchScatterPlanner
{
    /// <summary>一只敌人本回合的搜索移动解算结果。</summary>
    public struct SearchMove
    {
        public EnemyController enemy;
        /// <summary>落点（= CurrentCoord 表示原地，仍计一次搜索回合）</summary>
        public Vector2Int landing;
        /// <summary>预解算路径（含起点）；null = 原地不动</summary>
        public List<Vector2Int> path;
        /// <summary>本回合搜索步数 = 固定巡逻 AP（<see cref="GetSearchAP"/>）</summary>
        public int searchAP;
        /// <summary>true = 离扇形顶点超出牵绳半径的掉队者，本回合归队而非向外散开（§13）</summary>
        public bool pulledBack;
    }

    /// <summary>
    /// 职责 → 首选槽位（δ = 相对主方向 d 的旋转步数，圈层 0=外圈 / 1=内圈）。§12 表。
    /// </summary>
    /// <remarks>
    /// ★δ 只允许 {0, +1, -1}：本项目是**平顶**六边格，六个邻向的世界方位是
    /// N / NW / SW / S / SE / NE —— **前进半球只有 3 个方向**（δ0=正前、δ+1=右前、δ-1=左前），
    /// δ±2 不是文档原先以为的「正左 / 正右」，而是**侧后** SE / SW。
    /// 实测（主轴=北、顶点 5_1、队心 5_1）：δ+2 槽位落在 (10,4)，相对队心的前向分量 = −4.33，
    /// 比整支队伍还靠后 5 格 —— 这就是用户看到的「散开还是到处乱跑、往回跑」。
    /// 六边格没有 90° 侧向，第 4/5 名成员只能靠**内圈**（同方向、更短）拉开纵深，
    /// 正好落回文档里「辅助跟随近卫、落在其后方」的原意。
    /// </remarks>
    static readonly Dictionary<CombatRole, int[]> RoleSlots = new Dictionary<CombatRole, int[]>
    {
        { CombatRole.先锋, new[] { Slot(0, 0) } },
        { CombatRole.近卫, new[] { Slot(1, 0), Slot(-1, 0) } },
        { CombatRole.狙击, new[] { Slot(-1, 0), Slot(1, 0) } },
        { CombatRole.术士, new[] { Slot(1, 1), Slot(-1, 1), Slot(0, 1) } },
        { CombatRole.辅助, new[] { Slot(-1, 1), Slot(1, 1), Slot(0, 1) } },
    };

    /// <summary>未知职责的兜底首选：两翼外圈。</summary>
    static readonly int[] FallbackPrefs = { Slot(1, 0), Slot(-1, 0) };

    /// <summary>全部 6 个槽位（3 方向 × 2 圈层），按「外圈中→外圈两翼→内圈中→内圈两翼」排。</summary>
    static readonly int[] AllSlots =
    {
        Slot(0, 0), Slot(1, 0), Slot(-1, 0), Slot(0, 1), Slot(1, 1), Slot(-1, 1),
    };

    /// <summary>槽位编码：δ ∈ {-1,0,+1} × 圈层 ∈ {0,1} → 0..5。</summary>
    static int Slot(int delta, int ring) { return (delta + 1) * 2 + ring; }
    static int SlotDelta(int slot) { return slot / 2 - 1; }
    static int SlotRing(int slot) { return slot % 2; }

    /// <summary>领取槽位的行动顺序：先锋→近卫→狙击→术士→辅助（§12）。</summary>
    static readonly Dictionary<CombatRole, int> RoleOrder = new Dictionary<CombatRole, int>
    {
        { CombatRole.先锋, 0 },
        { CombatRole.近卫, 1 },
        { CombatRole.狙击, 2 },
        { CombatRole.术士, 3 },
        { CombatRole.辅助, 4 },
    };

    /// <summary>
    /// 搜索/归队/回巡逻的移动步数 = **小队设定的搜索行动点**（<c>squadSearchAP</c>，0 = 沿用 <c>squadPatrolAP</c>，缺省 2），
    /// 独立敌人 = <see cref="EnemyData.patrolAP"/>（§10.1，2026-09-08 用户定稿：黄`?`/白`?` 共用此选项）。
    /// </summary>
    /// <remarks>
    /// ★2026-09-08 回退定稿：曾改用战斗移动预算（剩余行动点 + 疾跑），实测「保留疾跑跑得太远」；
    /// 更早「敌人走得慢」其实是 leash 锚点 bug 导致的不移动，不是固定 AP 的锅。回退后散开步距与
    /// 普通巡逻同口径，搜索阶段不再结算疾跑。
    /// 白`?`回巡逻（回合5）期间 <see cref="SquadPatrolGroup.PatrolAP"/> 被临时抬到全员最大战斗预算
    /// （<see cref="SquadPatrolGroup.BeginReturnRoute"/>），此值随之上浮——这是回合5 的既定语义，非回退遗漏。
    /// </remarks>
    public static int GetSearchAP(EnemyController e)
    {
        if (e == null || e.data == null) return 1;
        int ap;
        if (e.PatrolGroup != null && e.PatrolGroup.SearchAP > 0) ap = e.PatrolGroup.SearchAP;
        else ap = Mathf.Max(1, e.data.patrolAP);

        // ★2026-09-09 用户定稿：先锋 = 设定搜索 AP + 1（高速突进型，搜捕冲得更远）；
        // 近卫等其余角色不变。
        if (e.data.combatRole == CombatRole.先锋) ap += 1;

        return ap;
    }

    /// <summary>
    /// 解算一批搜索者的落点。按**小队**分组（多小队同时搜捕 → 各自独立散开，§12），
    /// 组内按行动顺序依次领取空闲扇形槽位。槽位池 = **前进半球** 3 方向 × 2 圈层（§12），
    /// 侧后 / 正后一律不分配——往回走的格子是队伍刚搜过的地方，重搜没有意义还看着像乱跑。
    /// </summary>
    /// <remarks>
    /// ★不能按参照点坐标分组：同队成员的 <c>LastSeenCoord</c> 由 AlertPropagation 在不同时机写入
    /// （直接目击者写当时玩家格、被传导者抄队友、好奇围观者写锚点格），坐标经常不一致。
    /// 按坐标分组会把一支小队拆成几组，每组都以为只有自己 → 各自领取先锋槽位 d → 队形散乱、
    /// 成员互相重叠（用户实测 2026-09-08：先锋跑到后排、近卫偏得太远）。
    /// </remarks>
    /// <remarks>
    /// ★主轴必须全队共享一根（<see cref="SquadAxis"/>）：早期实现按文档 §12 原文让每只敌人
    /// 用「自己 → 参照点」各算主轴，结果队员分布在参照点两侧时主轴相反、扇形对折——
    /// 站在参照点北边的近卫拿到 d=正南、槽位 d±1，反而朝南穿过参照点跑到队伍背后，
    /// 而南侧的先锋 d=正北直插，两人对穿（用户实测「先锋跑到后面去、近卫太偏」）。
    /// 共享主轴后 takenSlots 才真的互斥：同一根轴上的方向下标才有可比性。
    /// </remarks>
    public static List<SearchMove> Plan(List<EnemyController> searchers)
    {
        var moves = new List<SearchMove>();
        if (searchers == null || searchers.Count == 0) return moves;

        var groups = new Dictionary<int, List<EnemyController>>();
        int soloKey = -1;
        foreach (EnemyController e in searchers)
        {
            if (e == null || e.IsDead || e.data == null) continue;
            // 独立敌人（SquadId < 0）各成一组：用递减负数作键，与真实 SquadId（≥0）不会相撞
            int key = e.SquadId >= 0 ? e.SquadId : soloKey--;
            List<EnemyController> list;
            if (!groups.TryGetValue(key, out list))
            {
                list = new List<EnemyController>();
                groups[key] = list;
            }
            list.Add(e);
        }

        // 整批只查一次：FindObjectOfType 很贵，逐只敌人查会拖慢搜索回合
        HexGridLayout grid = Object.FindObjectOfType<HexGridLayout>();
        TerrainManager terrain = Object.FindObjectOfType<TerrainManager>();

        foreach (KeyValuePair<int, List<EnemyController>> kv in groups)
        {
            List<EnemyController> members = kv.Value;
            members.Sort(ActionOrder);

            Vector2Int refPoint = SquadReference(members);
            Vector2Int centroid = Centroid(members);
            int axis = SquadAxis(members, centroid, refPoint);
            Vector2Int apex = FanApex(centroid, refPoint, axis);
            var takenSlots = new HashSet<int>();
            foreach (EnemyController e in members)
            {
                moves.Add(PlanOne(e, apex, axis, takenSlots, grid, terrain));
            }
        }
        return moves;
    }

    /// <summary>
    /// 小队共享参照点（§12「各小队以各自参照点独立散开」）：取行动顺序最靠前者
    /// （先锋→近卫→狙击→术士→辅助）的有效 <c>LastSeenCoord</c>——前排通常最先目击玩家。
    /// 全队都没有目击记录 → 退化为队心，至少让扇形有一个共同原点。
    /// 白`?`原地重整复用同一个点作为编队锚点（§4b），所以是 public。
    /// </summary>
    public static Vector2Int SquadReference(List<EnemyController> members)
    {
        if (members == null || members.Count == 0) return new Vector2Int(int.MinValue, int.MinValue);

        // 自带排序：Plan 与白`?`原地重整都要拿同一个点，不能因传入顺序不同而结果不同
        var sorted = new List<EnemyController>(members);
        sorted.Sort(ActionOrder);

        foreach (EnemyController e in sorted)
        {
            if (e != null && e.LastSeenCoord.x != int.MinValue) return e.LastSeenCoord;
        }
        return Centroid(sorted);
    }

    /// <summary>队心 = 成员当前坐标的整数平均。单只敌人时就是它自己。</summary>
    public static Vector2Int Centroid(List<EnemyController> members)
    {
        long sumX = 0, sumY = 0;
        int n = 0;
        foreach (EnemyController e in members)
        {
            if (e == null) continue;
            sumX += e.CurrentCoord.x;
            sumY += e.CurrentCoord.y;
            n++;
        }
        if (n == 0) return new Vector2Int(int.MinValue, int.MinValue);
        return new Vector2Int((int)(sumX / n), (int)(sumY / n));
    }

    /// <summary>
    /// 全队共享的扇形主轴（§12 主方向 d）= **来时路的前进方向**，来时路本身 = 后方 d+3（永不分配）。
    /// </summary>
    /// <remarks>
    /// ★优先级：①「本轮警戒起点队心 → 当前队心」的真实位移 —— 进入黄`?`前的上一阶段（追击）
    /// 一定是朝参照点**直着走**的，这段位移就是来时路，最可靠。
    /// ②本轮没挪过窝（陷阱整队原地警戒，§7.1）→「队心 → 参照点」。
    /// ③参照点也压在队心上（陷阱就在脚下触发）→ 背离牵绳锚点，即巡逻路线的前进方向。
    /// ★不能把②当首选：追击经常把整队**冲过**参照点，那时「队心 → 参照点」指向身后，
    /// 扇形会朝玩家逃跑的反方向展开（用户实测「先锋跑到后面去」）。
    /// </remarks>
    static int SquadAxis(List<EnemyController> members, Vector2Int centroid, Vector2Int refPoint)
    {
        if (centroid.x == int.MinValue) return 0;

        Vector2Int from = AlertStartCentroid(members);
        if (from.x != int.MinValue && from != centroid)
            return HexCoord.NearestDirIndex(HexCoord.ToCube(centroid) - HexCoord.ToCube(from));

        if (centroid != refPoint)
            return HexCoord.NearestDirIndex(HexCoord.ToCube(refPoint) - HexCoord.ToCube(centroid));

        Vector2Int anchor = SquadLeashAnchor(members, centroid);
        if (anchor != centroid)
            return HexCoord.NearestDirIndex(HexCoord.ToCube(centroid) - HexCoord.ToCube(anchor));
        return 0;
    }

    /// <summary>
    /// 本轮警戒起点的队心（来时路的起点）。成员入队时机不同（传导有先后），
    /// 所以只对有记录的成员取平均；全队都没记录 → <c>int.MinValue</c>。
    /// </summary>
    static Vector2Int AlertStartCentroid(List<EnemyController> members)
    {
        long sumX = 0, sumY = 0;
        int n = 0;
        foreach (EnemyController e in members)
        {
            if (e == null || e.AlertStartCoord.x == int.MinValue) continue;
            sumX += e.AlertStartCoord.x;
            sumY += e.AlertStartCoord.y;
            n++;
        }
        if (n == 0) return new Vector2Int(int.MinValue, int.MinValue);
        return new Vector2Int((int)(sumX / n), (int)(sumY / n));
    }

    /// <summary>
    /// 扇形顶点（§12）：参照点 R 在队伍**前方**时用 R；队伍已经冲过 R 时改用当前队心。
    /// </summary>
    /// <remarks>
    /// ★顶点不能无条件取 R：追击经常把整队送到 R 之外，这时 R 在身后，绕 R 算出来的槽位也全在身后，
    /// 先锋会掉头往回跑（用户实测 2026-09-08「先锋都往回跑去了」）。
    /// 判定用沿主轴的 cube 投影符号：delta 与主轴单位方向点积 &gt; 0 = R 在前方。
    /// </remarks>
    static Vector2Int FanApex(Vector2Int centroid, Vector2Int refPoint, int axis)
    {
        if (centroid.x == int.MinValue || refPoint.x == int.MinValue) return refPoint;
        HexCoord.Cube d = HexCoord.Directions[((axis % 6) + 6) % 6];
        HexCoord.Cube delta = HexCoord.ToCube(refPoint) - HexCoord.ToCube(centroid);
        return delta.x * d.x + delta.y * d.y + delta.z * d.z > 0 ? refPoint : centroid;
    }

    /// <summary>
    /// 全队共享的**巡逻**锚点：小队/点对点路线巡逻 = 最近路点 / 较近端点；随机游走 = 出生点。
    /// </summary>
    /// <remarks>
    /// ★只服务 <see cref="SquadAxis"/> 的第③级兜底（参照点也压在队心上 → 主轴 = 背离巡逻锚点，
    /// 也就是巡逻路线的前进方向）——那里要的是「家在哪个方向」，所以必须取巡逻路点。
    /// **不再是 §13 leash 的距离参照**：leash 已改锚扇形顶点（见 <c>PlanOne</c>），
    /// 否则「别离家太远」会和「沿来时路向前散开」结构性打架，把整个扇形裁没。
    /// </remarks>
    public static Vector2Int SquadLeashAnchor(List<EnemyController> members, Vector2Int at)
    {
        foreach (EnemyController e in members)
        {
            if (e == null || e.PatrolGroup == null) continue;
            Vector2Int wp;
            if (e.PatrolGroup.TryGetNearestWaypoint(at, out wp)) return wp;
        }
        foreach (EnemyController e in members)
        {
            if (e == null || !e.HasPatrolRoute) continue;
            int toA = CardExecutor.HexDistance(at, e.patrolPointA);
            int toB = CardExecutor.HexDistance(at, e.patrolPointB);
            return toA <= toB ? e.patrolPointA : e.patrolPointB;
        }
        foreach (EnemyController e in members)
        {
            if (e != null) return e.PatrolHomeCoord;
        }
        return at;
    }

    /// <summary>
    /// 按解算结果齐步走（批量移动：无落点预览、最后行动，§9）。
    /// 落点互斥沿用 <see cref="UnitOccupancy.PatrolLandingClaims"/>，与巡逻齐步走同一套预约机制。
    /// </summary>
    public static IEnumerator RunMoves(MonoBehaviour host, List<SearchMove> moves)
    {
        if (host == null || moves == null || moves.Count == 0) yield break;

        var coroutines = new List<IEnumerator>();
        var movers = new List<EnemyController>();
        foreach (SearchMove m in moves)
        {
            if (m.enemy == null || m.enemy.IsDead) continue;
            if (m.path == null || m.path.Count <= 1 || m.landing == m.enemy.CurrentCoord) continue;
            movers.Add(m.enemy);
            coroutines.Add(m.enemy.MoveToCoordSmooth(m.landing, m.path));
        }
        if (coroutines.Count == 0) yield break;

        // 齐步走前先腾出「本回合会离开」的格子，后排才能停进前排刚离开的格（与 SquadPatrolGroup 一致）
        if (UnitOccupancy.PatrolLandingClaims.IsActive)
        {
            foreach (EnemyController e in movers)
            {
                UnitOccupancy.PatrolLandingClaims.Release(e.CurrentCoord);
            }
        }

        yield return CoroutineBatch.WhenAll(host, coroutines);
    }

    // ------------------------------------------------------------------
    // 内部解算
    // ------------------------------------------------------------------

    static SearchMove PlanOne(EnemyController e, Vector2Int apex, int axis, HashSet<int> takenSlots,
        HexGridLayout grid, TerrainManager terrain)
    {
        int ap = GetSearchAP(e);
        int leash = e.data.searchLeashRadius;
        // ★leash 参照 = **扇形顶点**（≈玩家最后消失格 / 陷阱格），不是巡逻路点
        //  （<c>EnemyData.searchLeashRadius</c> 的 Tooltip 与 §13 原本就是这个意思）。
        //   锚在巡逻路点时这条规则与散开扇形**结构性对立**：主轴 = 来时路的前进方向 = 远离路点的方向，
        //   而追击本身就把整队朝那个方向推出去 5-6 格 → 进黄`?`时先锋那条射线上每一格都比上一格离家更远、
        //   全部超 leash → <see cref="FanSlot"/> 由远及近过滤到 dist=1 全被裁掉 → 退回顶点 →
        //   顶点就在队伍脚下 → 路径长度 1（用户实测「先锋只移动了一格」）。
        //   探针实测（ap=4 leash=6）：离家 5 格时先锋只能走 1 格，离家 6 格起整条射线归零、全队原地。
        //   改成锚在顶点后，leash 的语义回到「别离开丢目标的地方太远」，与「别离家太远」不再打架；
        //   回家由白`?`回合4/5/6 的归队→回巡逻→复原负责，不需要搜索阶段兼管。
        Vector2Int anchor = apex;
        bool overLeash = leash > 0 && CardExecutor.HexDistance(e.CurrentCoord, anchor) > leash;

        var move = new SearchMove
        {
            enemy = e,
            searchAP = ap,
            landing = e.CurrentCoord,
            path = null,
            pulledBack = overLeash
        };

        Vector2Int target;
        if (overLeash)
        {
            // §13：离扇形顶点超 leash 的掉队个体不参与向外散开、不占槽位，先归队回到顶点。
            // ★必须走 A* 而不是「沿方向逐格 + leash 过滤」：后者对已经超半径的敌人会把
            // 每一个邻格都判成超半径（连朝顶点 inward 的那格也是），第一步就无候选 → 永久原地不动。
            target = anchor;
        }
        else
        {
            target = FanSlot(apex, axis, PickSlot(e.data.combatRole, axis, takenSlots), ap, anchor, leash, grid, terrain);
        }

        if (target == e.CurrentCoord) return move;

        List<Vector2Int> path = e.FindPatrolPath(e.CurrentCoord, target);
        if (path == null || path.Count <= 1) return move;

        // 一回合只走 ap 步；槽位比这远就是「朝槽位方向推进 ap 格」，下回合继续。
        int steps = Mathf.Min(ap, path.Count - 1);

        // 落点互斥只在**停点**上判定：中途允许穿过队友刚离开的格（与 SquadPatrolGroup 齐步走一致）。
        // 沿路径回退到第一个可停的格；全不可停 → 原地（仍计一次搜索回合）。
        while (steps > 0 && !CanStop(path[steps])) steps--;
        if (steps <= 0) return move;

        move.landing = path[steps];
        move.path = path.GetRange(0, steps + 1);
        return move;
    }

    /// <summary>
    /// 扇形槽位**坐标**（§12）：以顶点 <c>apex</c> 为**扇形顶点**，把主轴方向旋转 δ×60° 后拉出 dist 格。
    /// </summary>
    /// <remarks>
    /// ★槽位是坐标不是方向：旧实现给每只敌人一个方向下标、让它从**自己脚下**逐格射线推进，
    /// 结果是四条起点不同、互不相干的射线——扇形顶点散在每个人自己脚下，队伍看起来就是各走各的
    /// （用户实测「完全就是乱跑」）。改成定点后，全队共用一个顶点，才是一个张开的扇面。
    /// ★射线长度由**圈层**决定，不再用 `ap + |δ|`：外圈 = ap+1（一回合走不满 → 朝槽位方向推进），
    /// 内圈 = max(2, ap−1)，前后差 1-2 格就是纵深。原先按 |δ| 加长是想让两翼拉得更开，但 δ±2 在本项目的
    /// 平顶六边格上是**侧后**方向，加长只是把术士/辅助更狠地推到队伍背后（见 <see cref="RoleSlots"/>）。
    /// 相邻两条外圈射线夹角 60° → 等边三角形 → 成员间距 = ap+1，正好落进 §12 的几何账
    /// （> 视野 3-4 → 同队互不可见 → 传导链断裂 → 各个击破窗口成立）。
    /// </remarks>
    static Vector2Int FanSlot(Vector2Int apex, int axis, int slot, int ap,
        Vector2Int anchor, int leash, HexGridLayout grid, TerrainManager terrain)
    {
        HexCoord.Cube dir = HexCoord.RotateSteps(HexCoord.Directions[((axis % 6) + 6) % 6], SlotDelta(slot));
        HexCoord.Cube origin = HexCoord.ToCube(apex);
        // 内圈下限 2 格：ap 现在是固定巡逻 AP（小队 3 / 独立 2），ap−1 会压到 1-2；
        // 下限 2 兜住「内圈成员原地不动/只走 1 格」的情况，避免看着像没散开。
        // ap=3 时与同一条射线上外圈成员（ap+1=4）仍差 2 格；ap=2 时内外圈差 1 格，可接受。
        int reach = SlotRing(slot) == 0 ? ap + 1 : Mathf.Max(2, ap - 1);

        // 沿射线由远及近取第一个可用格：同时满足 §13 牵绳半径 + 界内 + 地形可通行。
        // ★anchor == apex（见 PlanOne），而 cell 恰好在射线上离 apex `dist` 格，
        //   所以这条 leash 判定退化成「dist > leash」= **圈层半径封顶 = min(reach, leash)**。
        //   这正是想要的：leash 只压住步距极高的敌人（外圈 ap+1 > leash 时封顶），不再随追击深度整条归零。
        // ★界内/可通行必须在这里裁：射线拉出去很容易越出棋盘（实测 δ0 dist4 → 行 −1），
        // 越界的槽位会让 A* 直接返回 null → 这只敌人整回合原地不动，扇形凭空缺一角。
        for (int dist = reach; dist >= 1; dist--)
        {
            Vector2Int cell = HexCoord.FromCube(origin + Scale(dir, dist));
            if (leash > 0 && CardExecutor.HexDistance(cell, anchor) > leash) continue;
            if (grid != null && (cell.x < 0 || cell.y < 0 || cell.x >= grid.gridSize.x || cell.y >= grid.gridSize.y)) continue;
            if (terrain != null && !terrain.IsPassable(cell)) continue;
            return cell;
        }
        return apex; // 整条射线都不可用 → 退回顶点本身（至少朝队伍收拢，不会僵死）
    }

    static HexCoord.Cube Scale(HexCoord.Cube c, int k)
    {
        return new HexCoord.Cube(c.x * k, c.y * k, c.z * k);
    }

    /// <summary>停点合法性：齐步走期间查落点预约表，否则查真实占位。</summary>
    static bool CanStop(Vector2Int cell)
    {
        return UnitOccupancy.PatrolLandingClaims.IsActive
            ? UnitOccupancy.PatrolLandingClaims.CanStop(cell)
            : !UnitOccupancy.IsOccupied(cell);
    }

    /// <summary>
    /// 领取扇形槽位：按职责首选列表取第一个空闲槽位，全被占再按 <see cref="AllSlots"/> 兜底。
    /// 槽位池 = 前进半球 3 方向 × 2 圈层 = 6 个，**没有侧后 / 后方槽位**（§12）。
    /// </summary>
    static int PickSlot(CombatRole role, int d, HashSet<int> takenSlots)
    {
        int[] prefs;
        if (!RoleSlots.TryGetValue(role, out prefs)) prefs = FallbackPrefs;

        foreach (int slot in prefs)
        {
            if (takenSlots.Add(TakenKey(d, slot))) return slot;
        }

        foreach (int slot in AllSlots)
        {
            if (takenSlots.Add(TakenKey(d, slot))) return slot;
        }

        return Slot(0, 0); // 六个槽位全满（>6 人同队）：与队友同向，靠落点互斥把它们错开
    }

    /// <summary>
    /// 互斥键 = 归一化后的**世界方向** × 圈层。
    /// ★必须带上主轴 d 归一化：takenSlots 是全队共享的一张表，只有落到同一个方向下标上才可比。
    /// </summary>
    static int TakenKey(int d, int slot)
    {
        return SlotOf(d, SlotDelta(slot)) * 2 + SlotRing(slot);
    }

    static int SlotOf(int d, int delta)
    {
        return ((d + delta) % 6 + 6) % 6;
    }

    static int ActionOrder(EnemyController a, EnemyController b)
    {
        int byRole = RoleRank(a).CompareTo(RoleRank(b));
        if (byRole != 0) return byRole;
        int byTurn = a.TurnOrder.CompareTo(b.TurnOrder);
        if (byTurn != 0) return byTurn;
        return a.GetInstanceID().CompareTo(b.GetInstanceID());
    }

    static int RoleRank(EnemyController e)
    {
        if (e == null || e.data == null) return 9;
        return RoleOrder.TryGetValue(e.data.combatRole, out int rank) ? rank : 9;
    }
}

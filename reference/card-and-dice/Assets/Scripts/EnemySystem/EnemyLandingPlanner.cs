// =============================================================================
// 模块：M6 敌人系统 - EnemyLandingPlanner 全局落点计划器
// 用途：对「给定玩家坐标（真实或假设）」统一解算全场敌人的落点与将打出的意图，
//       带「先动者落点保留」避让（后解算者不计划去同一格）+ 棋盘签名缓存。
// ★2026-08-22 新增，修复用户报告「怪物最后的落点还是有重合」：
//   根因不在执行侧（EnemyTurnExecutor 两阶段解算已验证无重合），而在展示侧——
//   EnemyIntentVisuals（落点虚影/虚线/攻击弧线）与 EnemyIntentBadgeUI（意图徽章）
//   各自独立调用 IntentEvaluator.ResolveTurn，互相不知道别人的计划落点，
//   多名敌人的虚影环会叠在同一格（实测 4 环同格），且展示的意图与实际执行不一致。
//   方案：本计划器与执行器共用同一套「按行动顺序逐敌解算 + 保留格避让」算法，
//   展示层与执行器统一从本类取计划 → 展示=执行（§3.6 铁律）。
// 设计依据：《设计增补_敌人系统_v2.md》§3.6「陷阵之志式完美信息」（展示=执行）、
//   §4.2 移动预设、§15.6 关键约定。
// 职责边界：
//   - 只做「计划」：解算全场敌人的 落点 + chosen 意图 + 移动消耗，不改任何运行时状态
//     （不 RestoreActionPoints / 不 RevealIntent / 不 AddSprint——那些是执行器的事）；
//   - 保留格是「解算局部变量」（HashSet 逐计划新建），不用全局静态保留——
//     计划可随时安全重算（含敌人回合执行中途的预览刷新），不会污染执行阶段的寻路。
// 性能：棋盘签名（所有存活敌人的坐标/揭示代数/AP/疾跑值哈希）每帧只算一次，
//   签名不变直接命中缓存；变化才整体重算（N 只敌人 × A*）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人全局落点计划器（静态）。所有「想知道敌人会怎么走/打哪张牌」的调用方
/// （视觉层虚影/虚线/弧线/徽章、敌人回合执行器、移动预览）统一从本类取计划。
/// </summary>
public static class EnemyLandingPlanner
{
    /// <summary>
    /// 单个敌人的计划结果。
    /// </summary>
    public class PlanEntry
    {
        /// <summary>敌人实例</summary>
        public EnemyController enemy;
        /// <summary>计划落点（无路可达=原地）</summary>
        public Vector2Int landing;
        /// <summary>站在落点解析出的将打出小意图；null=全部不可行（疾跑兜底）</summary>
        public RevealedIntentOption chosen;
        /// <summary>移动到落点的移动力消耗</summary>
        public int apCost;
        /// <summary>
        /// ★2026-08-22 预解算的移动路径（当前格 → 落点，含起点）。执行阶段直接走这条「冻结」路径，
        /// 不再按已变化棋盘重新寻路。null = 原地不动（无移动，无需路径）。
        /// </summary>
        public List<Vector2Int> path;
        /// <summary>
        /// ★2026-09-08 红`!`逼近条目：被传导的问号单位本回合只移动逼近、不出牌（chosen 恒 null），
        /// 且不结算疾跑兜底（疾跑只来自追击意图/黄`?`搜捕，§10.2）。执行器据此跳过 AddSprint。
        /// </summary>
        public bool approachOnly;
    }

    /// <summary>缓存槽：按「玩家坐标」分槽（真实坐标 1 槽 + 实时预览/锁定快照各 1 槽）。</summary>
    private class CacheSlot
    {
        /// <summary>棋盘签名（签名变化=计划过期需重算）</summary>
        public long signature;
        /// <summary>按行动顺序排列的计划</summary>
        public List<PlanEntry> ordered;
        /// <summary>单敌快查表</summary>
        public Dictionary<EnemyController, PlanEntry> byEnemy;
    }

    /// <summary>缓存槽字典（key=玩家坐标）。悬停乱飘会产生少量槽，超限整体清空。</summary>
    private static readonly Dictionary<Vector2Int, CacheSlot> _cache = new Dictionary<Vector2Int, CacheSlot>();

    /// <summary>缓存槽上限（真实 1 + 实时预览 1 + 锁定 1 + 悬停漂移余量）。</summary>
    private const int MaxCacheSlots = 8;

    /// <summary>
    /// 合围留口不变量：任何敌人计划落点生效后，玩家 6 邻格中「可通行 & 未被占」的格子数
    /// 始终 ≥ 此值（即玩家永远保有逃生口）。调优旋钮：某些 Boss 战可设 0 以允许围死。
    /// 设计依据：合围留口原则（设计增补_敌人系统 待补章节）。
    /// </summary>
    public const int MinEscapeCells = 1;

    // ---- ★P1 执行锁定：敌人回合逐敌执行期间，敌人坐标逐格变化（签名随之变），
    // 但计划已在阶段一冻结。锁定期间 GetSlot 直接返回冻结计划（不重算），
    // 保证视觉层预览 = 执行器实际落点（修复"前一个敌人动完，后动者预览漂移"）。----
    private static bool _executionLock = false;
    private static Vector2Int _lockCoord;

    /// <summary>锁定当前玩家坐标下的全场计划（敌人回合阶段一调用，内部强制重算一次并缓存）。</summary>
    public static void LockExecution(Vector2Int playerCoord)
    {
        _executionLock = false; // 先清掉可能残留的旧锁，保证 forceRefresh 真正重算（而非命中旧冻结槽）
        _lockCoord = playerCoord;
        GetOrderedPlan(playerCoord, forceRefresh: true); // 未锁定，forceRefresh 正常重算
        _executionLock = true;
    }

    /// <summary>解除执行锁定（敌人回合结束后调用，下一玩家回合重新揭示/重算）。</summary>
    public static void UnlockExecution()
    {
        _executionLock = false;
    }

    // ---- 棋盘签名的每帧缓存（同帧多个视觉组件查询只扫描一次场景）----
    // ★只缓存「签名值」（供节流判断），不缓存敌人列表——同帧内生成/死亡的新单位
    //   不会进列表（LateUpdate 先于 execute_code/协程回调时会把生成前状态缓存住，
    //   计划会漏掉新敌人）。ComputePlan 一律现场重扫（见 CollectAliveEnemies）。
    private static int _sigFrame = -1;                 // 签名计算所在帧
    private static long _sigValue;                     // 签名值

    // ★2026-09-15 性能：计划内路径解算用的网格缓存（Unity 的 == null 对已销毁对象返回 true，
    //   场景重载后自动重取，不会持脏引用）
    private static HexGridLayout _planGrid;

    // ------------------------------------------------------------------
    // 公开入口
    // ------------------------------------------------------------------

    /// <summary>
    /// 取全局计划（按行动顺序排列）。棋盘签名不变时命中缓存；变化（或 forceRefresh）时整体重算。
    /// 执行器（EnemyTurnExecutor 阶段一）与视觉层共用本入口，保证展示=执行。
    /// </summary>
    /// <param name="playerCoord">玩家坐标（真实位置或移动预览的假设位置）</param>
    /// <param name="forceRefresh">true=跳过缓存强制重算（执行器在恢复 AP/揭示意图等状态变更后用）</param>
    /// <returns>按行动顺序的计划列表（无存活敌人时为空表）</returns>
    public static List<PlanEntry> GetOrderedPlan(Vector2Int playerCoord, bool forceRefresh = false)
    {
        CacheSlot slot = GetSlot(playerCoord, forceRefresh);
        return slot.ordered;
    }

    /// <summary>
    /// 单敌查询（视觉层用）：该玩家坐标下此敌人的计划落点/将打出意图。
    /// </summary>
    /// <param name="enemy">目标敌人</param>
    /// <param name="playerCoord">玩家坐标（真实或假设）</param>
    /// <returns>计划条目；敌人不在计划内（无数据/已死）返回 null</returns>
    public static PlanEntry GetEntry(EnemyController enemy, Vector2Int playerCoord)
    {
        if (enemy == null) return null;
        CacheSlot slot = GetSlot(playerCoord, false);
        PlanEntry entry;
        slot.byEnemy.TryGetValue(enemy, out entry);
        return entry;
    }

    /// <summary>
    /// 当前棋盘签名（视觉层节流用）。任一敌人的 坐标/揭示代数/AP/疾跑值 变化
    /// （含死亡离开）→ 签名变化 → 各视觉组件需重取计划（别人的变化也会影响我的落点）。
    /// 同帧多组件调用只扫描一次场景（ComputeSignature 帧内缓存）。
    /// </summary>
    public static long CurrentSignature
    {
        get { return ComputeSignature(); }
    }

    // ------------------------------------------------------------------
    // 缓存槽管理
    // ------------------------------------------------------------------

    /// <summary>取缓存槽：签名命中直接返回；未命中/强制刷新则重算计划并写回。</summary>
    private static CacheSlot GetSlot(Vector2Int playerCoord, bool forceRefresh)
    {
        // ★P1 执行锁定：敌人回合逐敌执行期间，直接返回冻结计划（不重算、不算签名），
        // 否则前一个敌人移动后签名变化，视觉层重算会让后动者预览漂移。
        if (_executionLock && playerCoord == _lockCoord)
        {
            CacheSlot frozen;
            if (_cache.TryGetValue(playerCoord, out frozen) && frozen != null) return frozen;
        }

        long sig = ComputeSignature();

        CacheSlot slot;
        _cache.TryGetValue(playerCoord, out slot);
        if (!forceRefresh && slot != null && slot.signature == sig)
        {
            return slot; // 棋盘未变：命中缓存
        }

        // 重算并写回（ComputePlan 从实时状态解算，签名仅用于下次失效判定）
        slot = new CacheSlot();
        slot.signature = sig;
        slot.ordered = ComputePlan(playerCoord);
        slot.byEnemy = new Dictionary<EnemyController, PlanEntry>();
        foreach (PlanEntry e in slot.ordered)
        {
            slot.byEnemy[e.enemy] = e;
        }

        if (_cache.Count >= MaxCacheSlots)
        {
            _cache.Clear(); // 悬停漂移撑爆槽位：整体清空（重算成本低，可接受）
        }
        _cache[playerCoord] = slot;
        return slot;
    }

    // ------------------------------------------------------------------
    // 棋盘签名（缓存失效判定）
    // ------------------------------------------------------------------

    /// <summary>
    /// 计算棋盘签名：所有存活敌人（含无数据单位——其占位影响落点）的
    /// 实例ID / 当前坐标 / 揭示代数 / 行动点 / 疾跑值 混合哈希。
    /// 同帧只扫描一次场景（多个视觉组件每帧查询的开销摊薄为 1 次扫描）。
    /// ★签名值同帧缓存可能滞后于「帧内生成/死亡」——仅影响缓存失效判定延迟一帧，
    ///   计划本体（ComputePlan）用现场重扫的敌人列表，不受此滞后影响。
    /// </summary>
    private static long ComputeSignature()
    {
        if (_sigFrame == Time.frameCount)
        {
            return _sigValue; // 同帧复用（协程恢复与 LateUpdate 混布也安全：值只增不变性由调用时序保证）
        }

        long h = 1469598103L; // FNV 偏移基数

        // ★2026-09-16 性能批：改走占位表注册表（EnemyController.OnEnable/OnDisable 维护）。
        //   原 FindObjectsOfType<EnemyController>() 在万对象的大地图上是全场景扫 + 每次分配数组；
        //   注册表语义与它一致（非激活 / 已销毁都不在表内）。
        foreach (EnemyController e in UnitOccupancy.LivingEnemies)
        {
            if (e == null || e.IsDead) continue;
            // 签名混合：实例ID + 坐标 + 揭示代数 + 行动点 + 疾跑值（任一变化 → 计划过期）
            h = Mix(h, e.GetInstanceID());
            h = Mix(h, e.CurrentCoord.x);
            h = Mix(h, e.CurrentCoord.y);
            h = Mix(h, e.RevealGeneration);
            h = Mix(h, e.CurrentActionPoints);
            h = Mix(h, e.SprintAccumulated);
            // ★P1：大意图下标也入签名——AdvanceIntent 推进意图循环会改变
            // ResolveMoveGuideRange 的射程参数（进而改变落点），此前未入签名，
            // 导致玩家回合预览可能命中过期缓存（dumb 落点）。
            h = Mix(h, e.CurrentIntentIndex);
        }

        _sigFrame = Time.frameCount;
        _sigValue = h;
        return h;
    }

    /// <summary>FNV-1a 风格哈希混合（long 防碰撞）。</summary>
    private static long Mix(long h, int v)
    {
        h ^= v;
        h *= 1099511628211L;
        return h;
    }

    // ------------------------------------------------------------------
    // 计划解算（与 EnemyTurnExecutor 原「阶段一」算法完全一致）
    // ------------------------------------------------------------------

    /// <summary>
    /// 解算全场敌人的计划：按行动顺序（角色优先级 → 小队先后 → 实例ID）逐敌
    /// ResolveTurn，先解算者的落点加入「解算局部保留格」，后解算者避让——
    /// 保证计划内部所有落点互不重合、也不重合任何单位当前占位。
    /// ★本方法不修改任何敌人运行时状态（纯计算，展示层可随时调用）。
    /// ★敌人列表现场重扫（不用签名帧缓存）：同帧生成的新单位也要进计划
    ///   （修复：LateUpdate 先行缓存把帧内生成前状态钉住 → 计划漏新敌人）。
    /// ★2026-08-23 严格顺序模拟（用户需求：算完第一个，再算第二个，以此类推）：
    ///   维护一个「模拟棋盘」simOccupied = 假设玩家格 + 全部存活敌人的模拟位置
    ///   （已解算者=计划落点、未解算者=原格、无数据单位=原格恒定）。每解算一只：
    ///   ① 原格出盘（它即将离开）→ ② 在当前模拟棋盘上解算落点（落点判定只认模拟棋盘，
    ///   不扫真实场景——修复：场景扫描把「已解算、马上要离开原格的敌人」的原格误判为被占，
    ///   后动者明明有格可停却被判无位 → 意图变追击）→ ③ 落点入盘（对后续敌人表现为
    ///   已站定的先动者）。中途穿越仍走零碰撞规则（planningReserved=先解算者落点才挡路）。
    /// </summary>
    private static List<PlanEntry> ComputePlan(Vector2Int playerCoord)
    {
        // ★2026-08-23 解算期把「假设玩家坐标」写入 UnitOccupancy，供 A* 中途占位/穿越检查使用
        //（否则玩家移动中 CurrentCoord 还是中间格，A* 会把错误格子当障碍 → 包抄怪落点非确定，预览≠执行）。
        UnitOccupancy.SimulatedPlayerCoord = playerCoord;

        var result = new List<PlanEntry>();

        // ★P2：一次扫描收集全部存活敌人（含无数据单位），再派生"有数据者"（与执行器过滤一致）。
        var allAlive = new List<EnemyController>();
        // ★2026-09-16 性能批：改走占位表注册表（EnemyController.OnEnable/OnDisable 维护）。
        //   原 FindObjectsOfType<EnemyController>() 在万对象的大地图上是全场景扫 + 每次分配数组；
        //   注册表语义与它一致（非激活 / 已销毁都不在表内）。
        foreach (EnemyController e in UnitOccupancy.LivingEnemies)
        {
            if (e == null || e.IsDead) continue;
            allAlive.Add(e);
        }
        var enemies = new List<EnemyController>();
        foreach (EnemyController e in allAlive)
        {
            if (e.data == null) continue;
            if (GameStateManager.Instance != null
                && GameStateManager.Instance.CurrentState == GameState.Battle
                && BattleResultHandler.Instance != null
                && !BattleResultHandler.Instance.IsParticipant(e))
            {
                continue;
            }
            // ★脱战问号阶段：被传导红`!`的单位本回合**要动**（★2026-09-08 用户定稿：按战斗行动点
            //   向玩家逼近、有落点预览、不攻击）→ 进计划（chosen=null 逼近条目）；
            //   其余问号单位（黄`?`散开 / 白`?`归队回巡逻）是批量移动者、无落点预览，不进计划。
            //   威胁预告与搜索 §9——移动由 SearchScatterPlanner / PatrolTurn 按搜索步距解算。
            //   留在计划里会白占保留格挡住战斗移动者，且预览≠执行。
            if (e.SearchPhase != EnemyController.DisengagePhase.None && !e.IsAlerted) continue;
            enemies.Add(e);
        }

        // 行动顺序与执行器完全一致：先锋(0) → 近卫(1) → 狙击(2) → 术士(3) → 辅助(4)；
        // 同优先级按 TurnOrder（先遇到的小队先动、队内配置序），同序按 InstanceID 稳定。
        enemies.Sort((a, b) =>
        {
            int byRole = RolePriority(a.data.combatRole).CompareTo(RolePriority(b.data.combatRole));
            if (byRole != 0) return byRole;
            int byOrder = a.TurnOrder.CompareTo(b.TurnOrder);
            return byOrder != 0 ? byOrder : a.GetInstanceID().CompareTo(b.GetInstanceID());
        });

        // ---- 顺序模拟棋盘初始化：解算开始前的真实占位快照 ----
        // reserved   = 先解算者的计划落点（对后解算者：挡中途穿越 + 不可停留）
        // simOccupied= 模拟棋盘全占位（假设玩家 + 全部存活敌人：已解算者=落点、未解算者=原格，
        //              含无数据单位——执行器跳过、永不移动，占位恒定有效）。只用于落点判定。
        var reserved = new HashSet<Vector2Int>();
        var simOccupied = new HashSet<Vector2Int>();
        if (playerCoord.x >= 0 && playerCoord.y >= 0) simOccupied.Add(playerCoord);
        foreach (EnemyController e in allAlive)
        {
            simOccupied.Add(e.CurrentCoord);
        }

        // ★逐敌串行解算：每只敌人的落点都基于「前面的敌人已按计划落点站位」的棋盘计算
        Vector2Int playerPos = playerCoord; // 活坐标（击退会推它；本次 ApplyPositionalEffect 恒等 → 不变）
        foreach (EnemyController e in enemies)
        {
            // ① 本敌即将离开原格 → 出盘（若最终原地不动，落点稍后加回）
            simOccupied.Remove(e.CurrentCoord);

            // ② 在「先动者已到落点、后动者仍在原格」的模拟棋盘上解算本敌。
            // ★2026-09-08 被传导红`!`（问号阶段 IsAlerted）分支：只解算逼近落点、不出牌——
            // 按战斗行动点（MoveBudget=AP+疾跑）向玩家逼近、执行各自移动预设（combat role 顺序
            // 已由上方排序保证），射程参数取冻结意图链（下回合续接后正是照此站位攻击）；
            // chosen 恒 null → 执行器只移动、不攻击、不疾跑兜底。
            bool approachOnly = e.SearchPhase != EnemyController.DisengagePhase.None;
            RevealedIntentOption chosen;
            Vector2Int landing;
            int apCost;
            if (approachOnly)
            {
                int guide = IntentEvaluator.ResolveFrozenMoveGuideRange(e);
                Vector2Int? l = MoveAIController.EvaluateLanding(e, guide, playerPos, out apCost, reserved, simOccupied);
                landing = l.HasValue ? l.Value : e.CurrentCoord; // 无路可达 → 原地
                chosen = null;
            }
            else
            {
                IntentEvaluator.ResolveTurn(e, playerPos, out chosen, out landing, out apCost, reserved, simOccupied);
            }

            // ③ 合围留口：落点若填满玩家最后一个逃生口 → 降级到射程外最近格 / 保持原地。
            // 射程参数按条目类型取（逼近条目用冻结链，否则 RevealedIntent 为空会按 1 算错）。
            int guideRange = approachOnly
                ? IntentEvaluator.ResolveFrozenMoveGuideRange(e)
                : IntentEvaluator.ResolveMoveGuideRange(e);
            landing = ApplySurroundGuard(e, landing, playerPos, guideRange, simOccupied, ref chosen, ref apCost);
            if (approachOnly) chosen = null; // 逼近条目绝不携带攻击意图（含留口降级重解析后）

            // ④ ★2026-08-22 预解算移动路径：在「任何敌人开始移动前」就把 A* 路径冻结进计划里。
            // 执行阶段直接走这条路径（不再按已变化棋盘重新寻路），否则别人先动后我的路会
            // 重新规划、走穿别人新占据的格子（用户报告的「移动路径混乱」）。
            // 路径用保留格避让（先动者落点对本敌表现为阻挡）→ 与落点互斥严格一致。
            // ★2026-09-15 性能：grid 查找移出循环（旧实现每敌一次 FindObjectOfType）。
            List<Vector2Int> path = null;
            if (landing != e.CurrentCoord)
            {
                if (_planGrid == null) _planGrid = Object.FindObjectOfType<HexGridLayout>();
                if (_planGrid != null)
                {
                    path = new AStarPathfinding(_planGrid).FindPath(e.CurrentCoord, landing, allowOccupiedTarget: false, enemyRequester: e, planningReserved: reserved);
                }
            }

            // ⑤ 落点入盘：本敌变成「已站定的先动者」，后续敌人据此解算（顺序模拟的核心）
            reserved.Add(landing);
            simOccupied.Add(landing);
            playerPos = ApplyPositionalEffect(playerPos, chosen, reserved); // ★预留：本次恒返回入参

            // ★P2：移除每敌诊断 Log（预览悬停时计划频繁重算，Log 刷屏导致卡顿）。

            result.Add(new PlanEntry { enemy = e, landing = landing, chosen = chosen, apCost = apCost, path = path, approachOnly = approachOnly });
        }

        UnitOccupancy.SimulatedPlayerCoord = null; // 解算结束，恢复用真实玩家坐标
        return result;
    }

    // ------------------------------------------------------------------
    // ★2026-08-22 合围留口守卫 + 位移传播钩子（击退预留）
    // ------------------------------------------------------------------

    /// <summary>
    /// 合围留口守卫：若某敌人的「计划落点」会填满玩家 6 邻格中最后一个逃生口，
    /// 则把落点降级到「射程外最近格」（或保持原地），确保玩家始终保有逃生口。
    /// 不触发：落点非玩家邻格、或玩家仍保有 ≥ MinEscapeCells 个逃生口。
    /// ★2026-08-23 修复计数：改用 simOccupied（顺序模拟棋盘）精确判定——
    /// 先解算者已按计划落点站位、原格已腾出；此前场景扫描把「即将离开的原格」误计为被占，
    /// 高估占用导致有逃生口却误触发留口（敌人被错误改派到射程外变追击）。
    /// 触发后：改派到 FindNearestNonSurroundCell 找的射程外最近格（占位也按模拟棋盘判定），
    /// 并站在新落点重解析 chosen（近战通常 → null → 疾跑兜底）；
    /// 找不到射程外格则保持原地（不占邻格）。
    /// </summary>
    private static Vector2Int ApplySurroundGuard(EnemyController e, Vector2Int landing, Vector2Int playerPos, int guideRange,
        HashSet<Vector2Int> simOccupied, ref RevealedIntentOption chosen, ref int apCost)
    {
        // 落点不在玩家 6 邻格 → 不触发
        if (!MoveAIController.IsPlayerNeighbor(landing, playerPos)) return landing;

        // 逃生口精确计数：当前敌人站在候选落点上，其余单位按「顺序模拟棋盘」站位
        //（本敌原格已在 ComputePlan 中移除；原地不动时落点=原格，占位集语义仍正确）。
        // 若「本敌占掉落点后再数」仍 ≥ 阈值 → 不触发。
        var checkSet = new HashSet<Vector2Int>(simOccupied) { landing };
        if (MoveAIController.CountEscapeCellsExact(playerPos, checkSet) >= MinEscapeCells) return landing;

        // 触发留口：改派到射程外最近格（射程参数由调用方按条目类型给定：逼近=冻结链 / 正常=已揭示链）
        Vector2Int? alt = MoveAIController.FindNearestNonSurroundCell(e, playerPos, guideRange, simOccupied);
        Debug.Log($"[EnemyLandingPlanner] 合围留口触发：{e.name} 落点{landing}会封死玩家最后逃生口 → " +
                  (alt.HasValue ? $"改派到射程外{alt.Value}" : "保持原地"));
        if (alt.HasValue)
        {
            landing = alt.Value;
            chosen = IntentEvaluator.ResolveChosenOnLanding(e, landing, playerPos); // 站在新落点重解析（近战通常 → null = 疾跑）
        }
        else
        {
            landing = e.CurrentCoord;   // 找不到射程外格 → 保持原地，不占邻格
            chosen = IntentEvaluator.ResolveChosenOnLanding(e, landing, playerPos);
            apCost = 0;                 // 原地不动无移动消耗
        }
        return landing;
    }

    /// <summary>
    /// ★预留：敌人「位移类」卡牌对玩家坐标的传播。本次恒返回入参（击退/拉拽机制未实现）。
    /// 未来接入击退时，在此根据 chosen 对应卡牌的位移效果更新 playerPos，
    /// 并遵守「推入占格 → 击退失效」规则（用户 2026-08-22 拍板，仅记录待未来落实）。
    /// </summary>
    private static Vector2Int ApplyPositionalEffect(Vector2Int playerPos, RevealedIntentOption chosen, HashSet<Vector2Int> reserved)
    {
        return playerPos; // 占位：无位移效果
    }

    // ------------------------------------------------------------------
    // 角色优先级（与执行顺序绑定，供本类与 EnemyTurnExecutor 共用）
    // ------------------------------------------------------------------

    /// <summary>
    /// CombatRole → 行动优先级（值小先动）。
    /// 顺序：先锋(0) → 近卫(1) → 狙击(2) → 术士(3) → 辅助(4)。
    /// 设计依据：用户需求——先锋(高速突进)最先动抢占位、近卫跟进、狙击找射程位、
    /// 术士输出+上buff/debuff、辅助最后增益。同优先级内按 TurnOrder（小队先后）次级排序。
    /// 注意：与 SpawnResolver.RolePriority（落地顺序）数值一致，全项目统一。
    /// </summary>
    public static int RolePriority(CombatRole role)
    {
        switch (role)
        {
            case CombatRole.先锋: return 0;
            case CombatRole.近卫: return 1;
            case CombatRole.狙击: return 2;
            case CombatRole.术士: return 3;
            case CombatRole.辅助: return 4;
            default: return 4; // 未知角色默认最后
        }
    }
}

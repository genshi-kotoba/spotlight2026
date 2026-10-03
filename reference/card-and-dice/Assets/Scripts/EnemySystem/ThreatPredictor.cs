// =============================================================================
// 模块：追击与搜索系统 - ThreatPredictor 威胁预告预测器（红`?`）
// 用途：预测「批量移动者下一次移动的落点是否会看见玩家」，供徽章亮红`?`。
// 设计依据：《设计增补_威胁预告与搜索阶段.md》§2（刷新时机 / 预测口径 / 不改行为）。
// 核心原则（§2）：纯预测——敌人实际移动时机与进战规则完全不变，红`?`只是玩家回合内的信息提示。
//   预告亮着、玩家不躲、敌人落点看见玩家 → 照旧被动遇袭（§2.2 末条 / §5.3）。
// 职责边界：只读查询。不写任何敌人状态、不移动单位、不占格、不改落点计划。
// 刷新时机（§2.1）：由 EnemyIntentBadgeUI 的变化检测节流驱动（玩家坐标 / 敌人坐标 /
//   棋盘签名任一变化才重算），不做每帧预测。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 红`?`威胁预告预测器（静态、无状态）。
/// </summary>
public static class ThreatPredictor
{
    /// <summary>
    /// 该敌人下一次移动的落点是否会看见玩家（§2.2）。
    /// **只服务批量移动者**：逐一行动者（战斗态参战者 / 探索态红`!`）本来就有落点预览，
    /// 红`?`对它们冗余不显示。只判定落点视野，不判定途中经过格（Demo 简化）。
    /// </summary>
    public static bool WillSeePlayerNextMove(EnemyController e, Vector2Int playerCoord)
    {
        if (e == null || e.IsDead || e.data == null) return false;
        if (IsSequentialMover(e)) return false;

        foreach (Vector2Int landing in PredictLandings(e))
        {
            if (landing.x == int.MinValue) continue;
            if (VisionSystem.CanSee(landing, playerCoord, e.data.visionRange, VisionSystem.EnemyGreenPenalty)) return true;
        }
        return false;
    }

    /// <summary>
    /// 逐一行动者（§9）：战斗态参战者 + 红`!`警戒者。它们逐一行动且显示落点预览，
    /// 红`?`存在的唯一理由是给「没有落点预览的批量移动者」预警（§2.2）。
    /// ★2026-09-08 红`!`先判定：被传导的问号单位已进 EnemyLandingPlanner（有逼近落点预览），
    /// 是逐一行动者，红`?`对其冗余；探索态红`!`同样逐一（警戒当回合放弃移动）。
    /// ★问号阶段例外（非红`!`）：黄`?`/白`?`敌人被排除出计划（无落点预览），
    /// 移动由 <see cref="SearchScatterPlanner"/> / PatrolTurn 批量解算——即便在战斗态是参战者，
    /// 它仍然是批量移动者，红`?`是它唯一的预警（§2.2 表列了陷阱后散开搜索与白`?`回巡逻两行）。
    /// </summary>
    static bool IsSequentialMover(EnemyController e)
    {
        if (e.IsAlerted) return true;
        if (e.SearchPhase != EnemyController.DisengagePhase.None) return false;
        if (BattleResultHandler.Instance != null && BattleResultHandler.Instance.IsParticipant(e)) return true;
        return false;
    }

    // ------------------------------------------------------------------
    // 落点预测口径（§2.2 表）
    // ------------------------------------------------------------------

    /// <summary>
    /// 按敌人当前的移动类型返回预测落点集合。多数类型只有唯一落点；
    /// 随机游走返回 BFS 可达集（"可能看见"的保守警告）。
    /// </summary>
    static IEnumerable<Vector2Int> PredictLandings(EnemyController e)
    {
        // 黄`?`散开搜索：干跑 SearchScatterPlanner（主方向 = 参照点，陷阱时已被陷阱格顶替）
        if (e.IsSearching)
        {
            // ★必须把**同队全部搜索者**一起丢进去：扇形槽位按行动顺序（先锋→近卫→…）依次领取，
            //   只丢一个进去它会领到先锋槽位 d，而真实解算里它可能拿到近卫的 d±1 → 预测≠执行。
            //   Plan 按小队独立分组，所以「只取同队搜索者」与「取全场搜索者」对本敌结果完全一致。
            var group = new List<EnemyController>();
            // ★2026-09-16 性能批：走占位表注册表，避免每次预告都全场景扫 EnemyController
            foreach (EnemyController other in UnitOccupancy.LivingEnemies)
            {
                if (other == null || other.IsDead || !other.IsSearching) continue;
                if (other != e && !AlertPropagation.SameSquad(e, other)) continue;
                group.Add(other);
            }

            List<SearchScatterPlanner.SearchMove> moves = SearchScatterPlanner.Plan(group);
            foreach (SearchScatterPlanner.SearchMove m in moves)
            {
                if (m.enemy == e) yield return m.landing;
            }
            yield break;
        }

        int ap = Mathf.Max(1, e.data.patrolAP);

        // 白`?`归队：在散开搜索的位置原地重整成巡逻阵型，用搜索步距
        if (e.SearchPhase == EnemyController.DisengagePhase.白归队)
        {
            yield return StepToward(e, e.GetRegroupTarget(), Mathf.Max(1, SearchScatterPlanner.GetSearchAP(e)));
            yield break;
        }

        // 白`?`回巡逻 / 归线：走到巡逻折线上离自己最近的垂足
        if (e.IsReturningHome || e.SearchPhase == EnemyController.DisengagePhase.白回巡逻)
        {
            // ★小队装了临时两点路线（回合5）→ 整队齐步走，落点必须读执行器共用的那份计划。
            //   单人 StepToward 算的是「直奔自己的阵型槽位」，与整队解算（编队中心可偏一格 +
            //   步数上限 + 停点互斥）不是一回事 → 红`?`会报一个走不到的落点。
            if (e.PatrolGroup != null && e.PatrolGroup.IsOnReturnRoute)
            {
                Dictionary<EnemyController, Vector2Int> landings = e.PatrolGroup.PredictNextLandings();
                Vector2Int slot;
                if (landings.TryGetValue(e, out slot)) yield return slot;
                yield break;
            }
            yield return StepToward(e, e.GetReturnTarget(out _), ap);
            yield break;
        }

        // 追击巡逻：朝最后目击点
        if (e.IsChasing)
        {
            yield return StepToward(e, e.LastSeenCoord, ap);
            yield break;
        }

        // 黄`?`好奇围观：朝骚动锚点
        if (e.IsCurious)
        {
            Vector2Int dest = e.CuriousAnchor != null && !e.CuriousAnchor.IsDead
                ? e.CuriousAnchor.CurrentCoord
                : e.LastSeenCoord;
            yield return StepToward(e, dest, ap);
            yield break;
        }

        // 小队路线巡逻：读执行器共用的那份计划（ComputeTurnPlan，铁律「预览 = 执行」）
        if (e.PatrolGroup != null)
        {
            Dictionary<EnemyController, Vector2Int> landings = e.PatrolGroup.PredictNextLandings();
            Vector2Int slot;
            // 不在计划里 = 这回合不会移动（路径无效 / 步数为 0 / 战斗态整队停摆）→ 没有落点可预警
            if (landings.TryGetValue(e, out slot)) yield return slot;
            yield break;
        }

        // 点对点路线巡逻：沿路线推进 patrolAP 步的落点。
        // 折返方向是私有状态，两个路点都预测一遍（保守：任一方向会看见就警告）。
        if (e.HasPatrolRoute)
        {
            yield return StepToward(e, e.patrolPointA, ap);
            yield return StepToward(e, e.patrolPointB, ap);
            yield break;
        }

        // 随机游走：BFS patrolAP 步内全部可能落点（受地形/占位/巡逻半径约束）
        foreach (Vector2Int cell in ReachableSet(e, ap)) yield return cell;
    }

    /// <summary>沿 A* 路径朝目标走 steps 步后的落点（走不到就取路径末端；无路可走 = 原地）。</summary>
    static Vector2Int StepToward(EnemyController e, Vector2Int target, int steps)
    {
        if (target.x == int.MinValue || target == e.CurrentCoord) return e.CurrentCoord;

        List<Vector2Int> path = e.FindPatrolPath(e.CurrentCoord, target);
        if (path == null || path.Count <= 1) return e.CurrentCoord;
        return path[Mathf.Min(Mathf.Max(1, steps), path.Count - 1)];
    }

    /// <summary>
    /// 随机游走 BFS 可达集（§2.2「可能看见」的保守警告）。
    /// 约束与 <c>EnemyController.RandomPatrolNeighbor</c> 同源：界内 + 地形可通行 +
    /// 不出巡逻半径 + 不与其他单位重叠——保证预测口径与实际随机步一致。
    /// </summary>
    static HashSet<Vector2Int> ReachableSet(EnemyController e, int depth)
    {
        var reachable = new HashSet<Vector2Int> { e.CurrentCoord };

        HexGridLayout grid = Object.FindObjectOfType<HexGridLayout>();
        if (grid == null) return reachable;
        TerrainManager terrain = Object.FindObjectOfType<TerrainManager>();

        var visited = new HashSet<Vector2Int>(reachable);
        var frontier = new List<Vector2Int> { e.CurrentCoord };

        for (int step = 0; step < depth && frontier.Count > 0; step++)
        {
            var next = new List<Vector2Int>();
            foreach (Vector2Int cur in frontier)
            {
                foreach (Vector2Int n in MoveAIController.GetNeighbors(cur))
                {
                    if (!visited.Add(n)) continue;
                    if (n.x < 0 || n.y < 0 || n.x >= grid.gridSize.x || n.y >= grid.gridSize.y) continue;
                    if (terrain != null && !terrain.IsPassable(n)) continue;
                    if (CardExecutor.HexDistance(n, e.PatrolHomeCoord) > e.data.patrolRadius) continue;
                    if (UnitOccupancy.IsOccupied(n)) continue;

                    reachable.Add(n);
                    next.Add(n);
                }
            }
            frontier = next;
        }
        return reachable;
    }
}

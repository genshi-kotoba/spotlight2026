// =============================================================================
// 模块：M6-5 敌人系统 - EnemyTurnExecutor 敌人回合执行器
// 用途：敌人回合「全局落点解算 → 按序执行移动 + 出牌」的统一编排。
// 设计依据：《设计增补_敌人系统_v2.md》§3.2 意图推进 / §4.2 移动预设 / §15.7 回合回调时机。
// ★2026-08-21 用户需求重构（全局移动解算 + 小队行动顺序）：
//   两阶段执行——阶段一按行动顺序逐敌解算落点（先解算者的落点 Reserve 为虚拟占位，
//   后解算者避让，杜绝多名敌人计划同格）；阶段二按同一顺序逐敌移动+出牌
//   （执行用实时占位，先动者已真实占格，天然互斥）。
//   行动顺序：TurnOrder 升序（先遇到=先生成的小队先动，队内按 units 配置顺序），
//   场景摆放敌人默认 int.MaxValue 最后动，同序按 InstanceID 稳定排序。
// 职责边界：只做编排（调用 IntentEvaluator + MoveAIController + EnemyCardExecutor），
//   不写 SO、不碰 UI、不直接扣血。
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人回合静态执行器。由 TurnManager.EnemyTurn 调用 Run() 驱动整个敌人回合。
/// </summary>
public static class EnemyTurnExecutor
{
    // ------------------------------------------------------------------
    // 公开入口：整个敌人回合的协程
    // ------------------------------------------------------------------

    /// <summary>
    /// 敌人回合总流程（★2026-08-22 改用 EnemyLandingPlanner 统一解算）：
    ///   阶段一·全局落点解算——先恢复 AP / 兜底揭示意图，再从 EnemyLandingPlanner
    ///   取「全场计划」（与视觉层虚影/虚线/徽章共用同一份计划 → 展示=执行，§3.6 铁律）；
    ///   计划器内部按行动顺序逐敌解算 + 保留格避让，落点互斥；
    ///   阶段二·按序执行——同一顺序逐敌移动+出牌，间隔 stepDelay 便于观察。
    /// 修复前问题：执行器与视觉层各自独立解算（互不知计划落点）→ 多名敌人虚影环
    /// 叠同一格、展示意图与实际执行不一致（用户报告的「落点还是有重合」）。
    /// </summary>
    /// <param name="stepDelay">每只敌人行动的间隔（秒），让玩家看清移动与出牌</param>
    public static IEnumerator Run(float stepDelay = 0.6f)
    {
        // ---- 收集存活敌人（含 data 过滤，与计划器 ComputePlan 的过滤一致）----
        var enemies = new List<EnemyController>();
        foreach (EnemyController enemy in Object.FindObjectsOfType<EnemyController>())
        {
            if (enemy == null || enemy.IsDead) continue;
            if (enemy.data == null)
            {
                Debug.LogWarning($"[EnemyTurnExecutor] {enemy.name} 未指定 EnemyData，跳过");
                continue;
            }
            if (GameStateManager.Instance != null
                && GameStateManager.Instance.CurrentState == GameState.Battle
                && BattleResultHandler.Instance != null
                && !BattleResultHandler.Instance.IsParticipant(enemy))
            {
                continue;
            }
            enemies.Add(enemy);
        }

        // ---- 回合前置状态：兜底揭示（★P1：行动点恢复已移到玩家回合开始 TurnManager，这里不再恢复——
        // 避免把断筋「减行动点」在敌人移动前抹掉，导致预览≠执行）----
        HexMover player = Object.FindObjectOfType<HexMover>();
        Vector2Int playerCoord = player != null ? player.CurrentCoord : new Vector2Int(-1, -1);
        foreach (EnemyController enemy in enemies)
        {
            // 回合起点快照：必须在任何移动之前，且不能被下面的 continue 挡掉
            //（散开搜索主轴要靠它倒推「上一个阶段直着走」的位移，见 EnemyController.TurnStartCoord）。
            enemy.MarkTurnStart();

            // ★2026-09-09 疾跑下回合生效：把上一回合 AddSprint 攒下的待生效追击值并入本回合，
            // 本回合移动预算（MoveBudget）才会抬升——本回合移动中刚加的疾跑不影响本回合（见 AddSprint）。
            enemy.FoldSprintPending();

            // ★2026-09-08 修复：问号阶段参战者回合开始已看见玩家 → 立即转回战斗意图 + 同队传导（§4）。
            // 只靠脱战判定兜底会先按散开/归队走掉、晚一回合才进战（用户实测贴脸仍是白`?`）。
            // 转回后 SearchPhase 已清空 → 本回合按战斗意图行动（回到回合2 追击节奏）。
            if (enemy.SearchPhase != EnemyController.DisengagePhase.None
                && VisionSystem.CanSee(enemy.CurrentCoord, playerCoord, enemy.data.visionRange, VisionSystem.EnemyGreenPenalty))
            {
                enemy.ReEngageOnSight();
            }

            // ★黄`?`/白`?`期间意图循环暂停（威胁预告与搜索 §11）：意图已冻结清空，
            //   这里绝不能兜底重揭（会重掷骰，破坏"重新进战从冻结处续接不重掷"）。
            if (enemy.SearchPhase != EnemyController.DisengagePhase.None) continue;

            // 极端兜底：玩家回合未走揭示（如直接调测试入口）→ 现场揭示一份
            if (enemy.RevealedIntent == null || enemy.RevealedIntent.options.Count == 0)
            {
                enemy.RevealIntent();
            }
        }

        // ---- 阶段一：从计划器取全局计划（展示=执行的唯一数据源）----
        // ★P1：LockExecution 先强制重算一次并锁定——阶段二逐敌执行时敌人坐标逐格变化，
        // 视觉层仍读这份冻结计划（不再重算），保证预览=执行。
        EnemyLandingPlanner.LockExecution(playerCoord);
        List<EnemyLandingPlanner.PlanEntry> plan = EnemyLandingPlanner.GetOrderedPlan(playerCoord);

        Debug.Log($"[EnemyTurnExecutor] 敌人回合：{plan.Count} 只存活敌人，行动顺序 = 角色优先级(先锋→近卫→狙击→术士→辅助) + 小队先后" +
                  (plan.Count > 0 ? $"（首动：{plan[0].enemy.name} [{plan[0].enemy.data.combatRole}]#{plan[0].enemy.TurnOrder}）" : ""));

        // ---- 阶段二：按计划顺序逐敌执行（移动 + 出牌）----
        foreach (EnemyLandingPlanner.PlanEntry entry in plan)
        {
            EnemyController enemy = entry.enemy;
            if (enemy == null || enemy.IsDead) continue; // 极端：解算与执行间被效果杀死

            yield return ExecuteAction(enemy, entry.landing, entry.chosen, entry.path, entry.approachOnly);

            // 清场胜利已切回探索：立刻停掉剩余敌人行动
            if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState != GameState.Battle)
            {
                EnemyLandingPlanner.UnlockExecution();
                yield break;
            }

            yield return new WaitForSeconds(stepDelay);
        }

        // ---- 阶段三：脱战问号阶段的批量移动（威胁预告与搜索 §9：批量、无预览、最后动）----
        //   回合3 黄`?`散开搜寻 → SearchScatterPlanner 整批解算（职责槽位互斥 + leash 裁剪）；
        //   回合4 白`?`归队重整队形 → 复用 PatrolTurn 的归队分支（朝小队锚点，搜索步距）。
        //   搜索/归队阶段保持 Battle 态（§3），所以这里仍在敌人回合内驱动。
        var scatter = new List<EnemyController>();
        var restJobs = new List<IEnumerator>();
        foreach (EnemyController enemy in enemies)
        {
            if (enemy == null || enemy.IsDead) continue;
            if (enemy.SearchPhase == EnemyController.DisengagePhase.None) continue;
            // ★2026-09-08 被传导红`!`的问号单位已进阶段二计划（逼近移动+落点预览），
            // 这里跳过防二次移动；不散开/不归队/不回血，下回合由 RevealAllEnemyIntents 切战斗意图。
            if (enemy.IsAlerted) continue;
            if (enemy.IsSearching) scatter.Add(enemy);
            else restJobs.Add(enemy.PatrolTurn());
        }

        if (scatter.Count > 0 || restJobs.Count > 0)
        {
            MonoBehaviour host = Object.FindObjectOfType<TurnManager>();
            UnitOccupancy.PatrolLandingClaims.Begin();
            try
            {
                yield return CoroutineBatch.WhenAll(host, restJobs);
                if (scatter.Count > 0)
                {
                    List<SearchScatterPlanner.SearchMove> moves = SearchScatterPlanner.Plan(scatter);
                    yield return SearchScatterPlanner.RunMoves(host, moves);
                }
            }
            finally
            {
                UnitOccupancy.PatrolLandingClaims.End();
            }

            // 本回合问号阶段的移动已走完 → 下回合开始推进（黄`?`→白`?`归队回75% 等，§3）
            foreach (EnemyController enemy in enemies)
            {
                if (enemy != null && !enemy.IsDead) enemy.MarkPhaseMoveDone();
            }
        }

        EnemyLandingPlanner.UnlockExecution(); // ★P1 解除执行锁定（下一玩家回合重新揭示/重算）

        Debug.Log("[EnemyTurnExecutor] 敌人回合结束");
    }

    // ------------------------------------------------------------------
    // 角色优先级已迁移至 EnemyLandingPlanner.RolePriority（公共）——
    // 执行器与视觉层统一从计划器取「按序计划」，排序逻辑只此一份。
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // 单只敌人的「移动 + 出牌」执行（落点与出牌已在阶段一全局解算）
    // ------------------------------------------------------------------

    /// <summary>
    /// 执行一只敌人的回合（★2026-08-21 改为接收阶段一的预解算结果）。
    ///   ① 移动：走预解算落点（已避开先动敌人的计划格）；逐格平滑、速度与玩家一致；
    ///   ② 出牌：用预解算的 chosen（站在该落点解析的第一条可行意图）；
    ///   ③ 全失败：不出牌，只疾跑兜底（AddSprint 累积追击值，下回合移动力+）。
    /// 设计依据：v2 §3.2「大意图 = if-else 链」+ §3.3 揭示值不再重投 + §4.3 疾跑。
    /// </summary>
    /// <param name="enemy">施法敌人</param>
    /// <param name="plannedLanding">阶段一全局解算的移动落点（含互斥避让）</param>
    /// <param name="plannedChosen">阶段一站在落点解析出的将打出意图（null=全失败疾跑兜底）</param>
    /// <param name="plannedPath">阶段一预解算的移动路径（含起点；null=原地不动）</param>
    /// <param name="approachOnly">★2026-09-08 红`!`逼近条目：只移动逼近不出牌（chosen 恒 null），
    /// 且不结算疾跑兜底——疾跑只来自追击意图/黄`?`搜捕（§10.2），逼近不累积。</param>
    public static IEnumerator ExecuteAction(EnemyController enemy, Vector2Int plannedLanding, RevealedIntentOption plannedChosen, List<Vector2Int> plannedPath = null, bool approachOnly = false)
    {
        // ★2026-08-22 用户需求：怪物开始行动（移动）后不再显示移动虚线，只显示目的地虚影；
        // 移动结束全隐藏（见 EnemyIntentVisuals 的 IntentConsumed 分支三态处理）。
        enemy.MarkIntentConsumed();

        // ① 移动阶段：沿预解算路径逐格平滑走到落点（无论出不出牌都移动）
        if (plannedLanding != enemy.CurrentCoord)
        {
            yield return enemy.MoveToCoordSmooth(plannedLanding, plannedPath);
        }

        // ② 出牌阶段：站在落点的 if-else 链结果（阶段一已解析）
        if (plannedChosen != null)
        {
            // ★2026-09-16 姿态打断（架弩）：上一玩家回合把它打掉血 → 架势散了，
            //   本回合不出手，回退大意图到「架弩」那一步重放（用户定稿：「被打断就重新释放这个意图」）。
            //   置于 ExecuteCard 之前：被打断就不该有伤害结算。
            if (enemy.ConsumeStanceBroken())
            {
                yield break;
            }

            // 打出意图卡牌（复用已揭示锁死的骰子点数，不再重投，§3.3）
            EnemyCardExecutor.ExecuteCard(enemy, plannedChosen.rolledCard);

            // ★2026-09-16 一出手就收架：姿态（架弩）在持有者成功出手后清除。
            //   不这么做的话它会一直挂到被打断为止，白赚后续每一击的下限。
            if (EffectManager.Instance != null) EffectManager.Instance.ClearStances(enemy.gameObject, "出手");

            // 成功打出非疾跑意图：按 advanceOnSuccess 决定是否推进大意图。
            // ★疾跑不再在此清零（威胁预告与搜索 §10.2）：疾跑是防逃跑升级曲线，
            //   只在**复原回合**清零（EnemyController.FinishDisengage），成功攻击不算"追上了就歇"。
            if (plannedChosen.option.advanceOnSuccess) enemy.AdvanceIntent();
            yield break;
        }

        // ③ 全部意图都打不到：已移动仍够不着 → 疾跑兜底（不出牌、不推进大意图，
        //    下回合移动力 +sprintValue 重试当前意图，§4.3）。
        //    ★2026-09-08 红`!`逼近条目例外：只逼近不出牌，不累积疾跑。
        //    ★AddSprint 内部有 canSprint 开关：未勾选的怪（站桩/BOSS）不累积，只移动什么都不做
        if (!approachOnly) enemy.AddSprint();
    }
}

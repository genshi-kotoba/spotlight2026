// =============================================================================
// 模块：M6-3 敌人系统 - IntentEvaluator 意图评估
// 用途：解析敌人本回合「移动到哪 + 打哪张牌」。
// 设计依据：《设计增补_敌人系统_v2.md》§3.2 / §4 / §15.6
// ★2026-08-19 用户确认重构：移动与意图彻底解耦——
//   ① 移动落点只由「移动预设」决定（本能=接近/包抄=绕后/风筝=拉开…），
//      射程参数取链中第一个攻击性小意图（对近战预设恒为 1，与当前意图无关）；
//      哪怕意图解析结果是防御（自卡），怪物也按预设接近玩家；
//   ② 出牌在移动后解析 if-else 链：站在落点，第一条「距离≤射程」的意图打出
//      （range=0 自卡永远可行）；全失败 → 疾跑兜底（AddSprint，不出牌）。
// 执行器（EnemyTurnExecutor）/ 常显视觉（EnemyIntentVisuals）/ 意图徽章
// （EnemyIntentBadgeUI）三方共用 <see cref="ResolveTurn"/>，保证展示=执行。
// =============================================================================
using UnityEngine;
using System.Collections.Generic;

/// <summary>
/// 敌人意图评估静态类。核心入口 = <see cref="ResolveTurn"/>：一次解析出移动落点 + 将打出的卡。
/// </summary>
public static class IntentEvaluator
{
    /// <summary>
    /// 解析敌人本回合行动（真实玩家位置版）。
    /// </summary>
    public static bool ResolveTurn(EnemyController enemy, out RevealedIntentOption chosen, out Vector2Int landing, out int apCost)
    {
        HexMover player = Object.FindObjectOfType<HexMover>();
        Vector2Int coord = player != null ? player.CurrentCoord : new Vector2Int(-1, -1);
        return ResolveTurn(enemy, coord, out chosen, out landing, out apCost);
    }

    /// <summary>
    /// 解析敌人本回合行动（带「假设玩家坐标」重载，供移动预览共用）。
    /// 两步解耦（★2026-08-19 用户确认：移动与意图无关）：
    ///   ① 移动落点：MoveAIController.EvaluateLanding 按移动预设计算（与当前意图无关），
    ///      射程参数 = 链中第一个攻击性小意图经 ResolveMoveGuideRange 换算（近战预设恒 1）；
    ///   ② 出牌：站在落点遍历 if-else 链，第一条「与玩家距离 ≤ 卡牌射程」的意图胜出
    ///      （range=0 自卡无需距离判定，永远可行——防御兜底语义）。
    /// ★2026-08-22 新增 planningReserved 参数：EnemyLandingPlanner 全局解算时传入
    /// 「先解算者的计划落点集合」——落点计算把这些格视为已占（后解算者避让），
    /// 实现多名敌人计划落点互斥（修复用户报告的落点重合）。null=独立解算（单敌调用）。
    /// </summary>
    /// <param name="enemy">施法敌人</param>
    /// <param name="playerCoord">假设/真实的玩家坐标</param>
    /// <param name="chosen">输出：将打出的小意图（含已掷骰卡牌）；null=全失败</param>
    /// <param name="landing">输出：移动落点（按预设，与意图无关；无路可达=原地）</param>
    /// <param name="apCost">输出：移动消耗</param>
    /// <param name="planningReserved">计划保留格（先解算者的计划落点：挡中途穿越 + 挡落点；null=独立解算）</param>
    /// <param name="simOccupied">★2026-08-23 顺序模拟棋盘（假设玩家 + 全部敌人的模拟位置：
    /// 已解算者=计划落点、未解算者=原格；只挡「落点」不挡「穿越」——穿越走零碰撞规则）。
    /// EnemyLandingPlanner 逐敌解算传入；null=独立解算（查真实场景占位）</param>
    /// <returns>true=有可打出意图（移动后出牌）；false=全失败（仍移动 + 疾跑兜底）</returns>
    public static bool ResolveTurn(EnemyController enemy, Vector2Int playerCoord, out RevealedIntentOption chosen, out Vector2Int landing, out int apCost, HashSet<Vector2Int> planningReserved = null, HashSet<Vector2Int> simOccupied = null)
    {
        chosen = null;
        landing = enemy != null ? enemy.CurrentCoord : new Vector2Int(-1, -1);
        apCost = 0;

        if (enemy == null || enemy.RevealedIntent == null) return false;
        if (playerCoord.x < 0 || playerCoord.y < 0) return false;

        // ① 移动落点：只按移动预设（射程参数与「当前意图是什么」无关）
        int guideRange = ResolveMoveGuideRange(enemy);
        Vector2Int? l = MoveAIController.EvaluateLanding(enemy, guideRange, playerCoord, out apCost, planningReserved, simOccupied);
        landing = l.HasValue ? l.Value : enemy.CurrentCoord; // 无路可达 → 原地

        // ② 站在落点解析 if-else 链：第一条可行的打出（复用 ResolveChosenOnLanding）
        chosen = ResolveChosenOnLanding(enemy, landing, playerCoord);
        return chosen != null;
    }

    /// <summary>
    /// ★2026-08-22 抽出「站在给定落点解析将打出意图」的 if-else 链，供两处复用：
    ///   ① ResolveTurn 内部（正常流程）；
    ///   ② EnemyLandingPlanner 合围留口降级后，站在「射程外新落点」重新解析 chosen。
    /// 语义与 ResolveTurn 第二步完全一致：range≤0 自卡永远可行；否则距离≤射程者胜出；全失败返回 null。
    /// </summary>
    /// <param name="enemy">施法敌人</param>
    /// <param name="landing">敌人最终落点</param>
    /// <param name="playerCoord">玩家坐标</param>
    /// <returns>将打出的意图；null=全部打不到（疾跑兜底）</returns>
    public static RevealedIntentOption ResolveChosenOnLanding(EnemyController enemy, Vector2Int landing, Vector2Int playerCoord)
    {
        if (enemy == null || enemy.RevealedIntent == null) return null;

        foreach (RevealedIntentOption reveal in enemy.RevealedIntent.options)
        {
            if (reveal == null || reveal.option == null || reveal.option.card == null) continue;

            int range = reveal.option.card.Range;
            if (range <= 0) return reveal; // 自卡（如防御）：无需距离判定，永远可行
            if (CardExecutor.HexDistance(landing, playerCoord) <= range) return reveal;
        }
        return null; // 全失败 → 疾跑兜底
    }

    /// <summary>
    /// 问号阶段「冻结意图」的移动射程参数（红`!`逼近落点 / 「?→猛击5」悬停预览共用）：
    /// 取冻结链中第一个攻击性小意图经 <see cref="ResolveAttackRange"/> 换算；无冻结可续/纯自卡 → 1。
    /// 与 <see cref="ResolveMoveGuideRange"/> 同语义，但数据源是 <see cref="EnemyController.FrozenIntent"/>
    /// （问号阶段 RevealedIntent 已冻结清空）——保证红`!`逼近站位 = 下回合续接后的攻击站位。
    /// </summary>
    public static int ResolveFrozenMoveGuideRange(EnemyController enemy)
    {
        EnemyRevealedIntent frozen = enemy != null ? enemy.FrozenIntent : null;
        if (frozen != null)
        {
            foreach (RevealedIntentOption reveal in frozen.options)
            {
                if (reveal == null || reveal.option == null || reveal.option.card == null) continue;
                if (reveal.option.card.Range > 0)
                    return ResolveAttackRange(enemy, reveal.option);
            }
        }
        return 1;
    }

    /// <summary>
    /// 站在给定落点解析「冻结意图」链（问号阶段悬停预览「?→猛击5」用）。
    /// 与 <see cref="ResolveChosenOnLanding"/> 同语义：range≤0 自卡永远可行；否则距离≤射程者胜出；全失败 null。
    /// </summary>
    public static RevealedIntentOption ResolveFrozenChosen(EnemyController enemy, Vector2Int landing, Vector2Int playerCoord)
    {
        EnemyRevealedIntent frozen = enemy != null ? enemy.FrozenIntent : null;
        if (frozen == null) return null;

        foreach (RevealedIntentOption reveal in frozen.options)
        {
            if (reveal == null || reveal.option == null || reveal.option.card == null) continue;

            int range = reveal.option.card.Range;
            if (range <= 0) return reveal;
            if (CardExecutor.HexDistance(landing, playerCoord) <= range) return reveal;
        }
        return null; // 全失败 → 疾跑兜底
    }

    /// <summary>
    /// 移动预设的「射程参数」：取链中第一个攻击性小意图（range>0）经 <see cref="ResolveAttackRange"/>
    /// 换算。整链无攻击卡（纯自卡）→ 1（按本能贴脸接近，用户确认「意图是防御也按预设接近玩家」）。
    /// 设计依据：v2 §15.6 ResolveAttackRange。
    /// </summary>
    public static int ResolveMoveGuideRange(EnemyController enemy)
    {
        if (enemy == null || enemy.data == null || enemy.RevealedIntent == null) return 1;

        foreach (RevealedIntentOption reveal in enemy.RevealedIntent.options)
        {
            if (reveal == null || reveal.option == null || reveal.option.card == null) continue;
            if (reveal.option.card.Range > 0)
                return ResolveAttackRange(enemy, reveal.option);
        }
        return 1;
    }

    /// <summary>
    /// 各预设需要的「射程参数」：近战=1（相邻），远程 Kite/Intercept=卡牌射程，KeepAway=保持最小距离。
    /// 设计依据：v2 §15.6 ResolveAttackRange。
    /// </summary>
    public static int ResolveAttackRange(EnemyController enemy, EnemyIntentOption option)
    {
        switch (enemy.data.movePreset)
        {
            case MoveAIPresetType.风筝:
            case MoveAIPresetType.拦截:
                return option.card.Range;                       // 远程要「极限射程」
            case MoveAIPresetType.远离:
                return enemy.data.moveParams.keepAwayMinDist;   // 远离用「最小距离」
            default:                                            // 本能 / 包抄 / 守卫 等近战
                return 1;                                       // 近战 = 相邻
        }
    }

    /// <summary>
    /// ★2026-09-17 问号阶段「意图转换预览」的解析结果（头顶徽章与意图卡面共用）：
    /// 假设玩家走到 hoverCoord（该格在视野内），该敌将立即切换战斗意图——
    /// 从冻结意图链（§11 不重掷）解析第一条可行小意图。
    /// 不满足（非问号阶段 / 悬停格不在视野内 / 无冻结可续）或全失败 → null。
    /// </summary>
    public static RevealedIntentOption ResolveQuestionChosen(EnemyController enemy, Vector2Int hoverCoord)
    {
        if (enemy == null || enemy.data == null) return null;
        if (enemy.SearchPhase == EnemyController.DisengagePhase.None) return null;
        // 与 CheckQuestionPhaseWalkIn 判定同口径（红/绿直线阻挡）
        if (!VisionSystem.CanSee(enemy.CurrentCoord, hoverCoord, enemy.data.visionRange, VisionSystem.EnemyGreenPenalty)) return null;
        if (enemy.FrozenIntent == null) return null;

        int guide = ResolveFrozenMoveGuideRange(enemy);
        Vector2Int? l = MoveAIController.EvaluateLanding(enemy, guide, hoverCoord, out int _);
        Vector2Int landing = l.HasValue ? l.Value : enemy.CurrentCoord;
        return ResolveFrozenChosen(enemy, landing, hoverCoord);
    }
}

// =============================================================================
// 警戒传导：感叹号 / 问号视野图（探索系统 v2 §9.1.4，2026-09-06 用户定稿）
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 探索与战斗共用的警戒图刷新。感叹号只在同队视野连锁；问号给外队看热闹和同队落单靠近。
/// </summary>
public static class AlertPropagation
{
    public static bool Sees(EnemyController observer, Vector2Int target)
    {
        if (observer == null || observer.IsDead || observer.data == null) return false;
        return VisionSystem.CanSee(observer.CurrentCoord, target, observer.data.visionRange, VisionSystem.EnemyGreenPenalty);
    }

    public static bool Sees(EnemyController observer, EnemyController other)
    {
        if (other == null || other.IsDead) return false;
        return Sees(observer, other.CurrentCoord);
    }

    public static bool SameSquad(EnemyController a, EnemyController b)
    {
        return a != null && b != null && a.SquadId >= 0 && a.SquadId == b.SquadId;
    }

    public static bool IsFighting(EnemyController enemy)
    {
        if (enemy == null || enemy.IsDead) return false;
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            return false;
        }
        return BattleResultHandler.Instance != null && BattleResultHandler.Instance.IsParticipant(enemy);
    }

    public static List<EnemyController> LivingEnemies()
    {
        var list = new List<EnemyController>();
        // ★2026-09-16 性能批：本函数在「玩家每走一格」的视野脉冲里被调用（OnPlayerStepped →
        //   CheckAlertAtLanding → Refresh），原 FindObjectsOfType 在荒野图（≈万对象）上是每次全场景扫。
        //   改走占位表注册表；过滤口径不变（非激活/已销毁不在表内，这里再滤一次死亡与无数据）。
        foreach (EnemyController e in UnitOccupancy.LivingEnemies)
        {
            if (e == null || e.IsDead || e.data == null) continue;
            list.Add(e);
        }
        return list;
    }

    /// <summary>
    /// 全场重算传导。返回本帧是否有新的「看见玩家」发起人（供 F3.3 能量转化）。
    /// </summary>
    public static bool Refresh()
    {
        HexMover player = ExplorationPerf.Player;   // ★2026-09-16 性能批：热点缓存（逐格脉冲调用）
        if (player == null) return false;

        Vector2Int playerPos = player.CurrentCoord;
        List<EnemyController> enemies = LivingEnemies();
        bool newOrigin = false;

        foreach (EnemyController e in enemies)
        {
            if (IsFighting(e)) continue;
            if (!Sees(e, playerPos)) continue;
            if (!e.IsAlertOrigin) newOrigin = true;
            e.BecomeAlerted(isOrigin: true);
            e.LastSeenCoord = playerPos;
        }

        bool changed = true;
        int guard = 0;
        while (changed && guard++ < 32)
        {
            changed = false;
            foreach (EnemyController a in enemies)
            {
                if (a.IsAlerted || IsFighting(a)) continue;
                foreach (EnemyController b in enemies)
                {
                    if (a == b) continue;
                    if (!SameSquad(a, b)) continue;
                    if (!b.IsAlerted && !IsFighting(b)) continue;
                    if (!Sees(a, b)) continue;
                    a.BecomeAlerted(isOrigin: false);
                    if (b.LastSeenCoord.x != int.MinValue) a.LastSeenCoord = b.LastSeenCoord;
                    changed = true;
                    break;
                }
            }
        }

        foreach (EnemyController a in enemies)
        {
            if (a.IsAlerted || IsFighting(a)) continue;
            if (a.SquadId < 0) continue;

            EnemyController anchor = null;
            int best = int.MaxValue;
            bool squadHasConfirmed = false;
            foreach (EnemyController b in enemies)
            {
                if (a == b || !SameSquad(a, b)) continue;
                if (!b.IsAlerted && !IsFighting(b)) continue;
                squadHasConfirmed = true;
                int d = CardExecutor.HexDistance(a.CurrentCoord, b.CurrentCoord);
                if (d < best)
                {
                    best = d;
                    anchor = b;
                }
            }

            if (squadHasConfirmed && anchor != null)
            {
                a.BecomeCurious(anchor, promoteNextTurn: true);
            }
        }

        foreach (EnemyController a in enemies)
        {
            if (a.IsAlerted || IsFighting(a) || a.PromoteToAlertNextTurn) continue;
            foreach (EnemyController b in enemies)
            {
                if (a == b || SameSquad(a, b)) continue;
                if (!b.IsAlertOrigin) continue;
                if (!Sees(a, b)) continue;
                a.BecomeCurious(b, promoteNextTurn: false);
                break;
            }
        }

        changed = true;
        guard = 0;
        while (changed && guard++ < 32)
        {
            changed = false;
            foreach (EnemyController a in enemies)
            {
                if (a.IsAlerted || IsFighting(a) || a.IsCurious) continue;
                foreach (EnemyController b in enemies)
                {
                    if (a == b || !SameSquad(a, b) || !b.IsCurious) continue;
                    if (!Sees(a, b)) continue;
                    a.BecomeCurious(b.CuriousAnchor != null ? b.CuriousAnchor : b, b.PromoteToAlertNextTurn);
                    changed = true;
                    break;
                }
            }
        }

        ResolveForeignCuriousFade(enemies, playerPos);
        return newOrigin;
    }

    static void ResolveForeignCuriousFade(List<EnemyController> enemies, Vector2Int playerPos)
    {
        foreach (EnemyController a in enemies)
        {
            if (!a.IsCurious || a.PromoteToAlertNextTurn || a.IsAlerted) continue;
            if (Sees(a, playerPos)) continue;

            EnemyController anchor = a.CuriousAnchor;
            if (anchor == null || anchor.IsDead)
            {
                a.ClearCurious();
                continue;
            }

            bool hotspotHot = anchor.IsAlerted || anchor.IsAlertOrigin || IsFighting(anchor);
            int dist = CardExecutor.HexDistance(a.CurrentCoord, anchor.CurrentCoord);
            if (dist <= 1 && !hotspotHot)
            {
                a.ClearCurious();
            }
        }
    }

    /// <summary>同队问号：下回合强制升感叹号；战斗中则加入本场。</summary>
    public static void PromoteDueSameSquad()
    {
        foreach (EnemyController e in LivingEnemies())
        {
            if (!e.PromoteToAlertNextTurn) continue;
            e.BecomeAlerted(isOrigin: false);
            e.PromoteToAlertNextTurn = false;
            e.ClearCurious();

            if (GameStateManager.Instance != null
                && GameStateManager.Instance.CurrentState == GameState.Battle
                && BattleResultHandler.Instance != null)
            {
                BattleResultHandler.Instance.AddParticipant(e);
                e.EnterCombatDisplay();
                e.RestoreActionPoints();
                e.RevealIntent();
            }
        }
    }

    /// <summary>进战：参战者摘掉探索感叹号，改显示战斗意图；问号单位保留。</summary>
    public static void OnEnterCombat(IEnumerable<EnemyController> combatants)
    {
        var set = new HashSet<EnemyController>();
        if (combatants != null)
        {
            foreach (EnemyController e in combatants) if (e != null) set.Add(e);
        }

        foreach (EnemyController e in LivingEnemies())
        {
            if (!set.Contains(e)) continue;
            e.IsChasing = false;
            e.ResetSearchStatesPublic();
            e.EnterCombatDisplay();
        }
    }

    /// <summary>战斗中未参战的问号单位，用巡逻步数靠近锚点。</summary>
    public static IEnumerator MoveCuriousNonCombatants()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            yield break;
        }

        foreach (EnemyController e in LivingEnemies())
        {
            if (e.IsDead || !e.IsCurious) continue;
            if (BattleResultHandler.Instance != null && BattleResultHandler.Instance.IsParticipant(e))
            {
                continue;
            }
            yield return e.PatrolTurn();
            Refresh();
        }
    }

    public static List<EnemyController> CollectAlertedSeeds(EnemyController extra)
    {
        var seeds = new List<EnemyController>();
        if (extra != null && !extra.IsDead) seeds.Add(extra);
        foreach (EnemyController e in LivingEnemies())
        {
            if (e.IsAlerted) seeds.Add(e);
        }
        return seeds;
    }
}

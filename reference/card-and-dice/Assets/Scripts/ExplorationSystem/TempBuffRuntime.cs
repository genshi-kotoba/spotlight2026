// =============================================================================
// 模块：探索系统 - 临时强化运行时 TempBuffRuntime
// 用途：局内增益槽（design §3.5）：事件获得 → 下场战斗开始时应用 → 战斗结束即耗。
//       纯静态、无场景依赖；顶栏订阅 OnChanged 即时刷新（即时性铁律）。
//
// ★接线范围（本批）：有数（起始手牌 +1）/ 壮胆（首次攻击 +2）/ 暖身（第 1 回合 +1 能量）。
//   其余 7 种（6 枚群系免类 + 护心镜）**只入槽、只显示**，战斗效果待敌人线词条与
//   暴击引擎落稿后补 switch 分支（转交清单第 1/2 项）。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

public static class TempBuffRuntime
{
    static readonly List<TempBuffData> _held = new List<TempBuffData>();

    /// <summary>槽内变化（顶栏刷新用）。</summary>
    public static event Action OnChanged;

    /// <summary>只读视图（规则判定传它进 TempBuffRules）。</summary>
    public static IList<TempBuffData> Held { get { return _held; } }

    public static int Count { get { return _held.Count; } }

    /// <summary>获得一条（同种不叠加、上限 3）。返回 false 时 why 给出原因。</summary>
    public static bool Grant(TempBuffData buff, out string why)
    {
        if (!TempBuffRules.CanAcquire(_held, buff, out why)) return false;

        _held.Add(buff);
        Debug.Log($"[事件] 获得临时强化「{buff.buffName}」（{buff.kind}）；下场战斗生效。当前 {_held.Count}/{TempBuffRules.MaxSlots}");
        OnChanged?.Invoke();
        return true;
    }

    public static void ClearAll()
    {
        if (_held.Count == 0) return;
        _held.Clear();
        OnChanged?.Invoke();
    }

    // ------------------------------------------------------------------
    // 战斗接线（由 TurnManager / ActionSystem 调用）
    // ------------------------------------------------------------------

    /// <summary>「有数」：本场起始手牌加成张数（非首回合恒 0）。</summary>
    public static int HandSizeBonusForTurn(int turn)
    {
        if (turn != 1) return 0;
        return TempBuffRules.HandSizeBonus(_held);
    }

    /// <summary>「暖身」：第 1 回合额外能量（在 StartNewTurn 的能量→AP 换算之后调，避免被折算掉）。</summary>
    public static int FirstTurnEnergyBonus()
    {
        return TempBuffRules.FirstTurnEnergyBonus(_held);
    }

    // ------------------------------------------------------------------
    // 壮胆：首次攻击 +2
    // ------------------------------------------------------------------
    static Action<DealDamageAction> _firstStrikeReaction;
    static bool _firstStrikeUsed;

    /// <summary>战斗开始：若持「壮胆」→ 挂首次攻击反应（Pre 阶段改 RawDamage）。</summary>
    public static void OnBattleBegin()
    {
        _firstStrikeUsed = false;
        int bonus = TempBuffRules.FirstAttackDamageBonus(_held);
        if (bonus <= 0) return;

        if (_firstStrikeReaction == null) _firstStrikeReaction = OnDealDamagePre;
        ActionSystem.SubscribeReaction(_firstStrikeReaction, ReactionTiming.Pre);
        Debug.Log($"[事件] 「壮胆」已挂：本场第一次攻击 +{bonus}");
    }

    /// <summary>战斗结束：卸反应 + 清空全场增益（design §2 共同规则：战斗结束即消耗）。</summary>
    public static void OnBattleEnd()
    {
        if (_firstStrikeReaction != null)
            ActionSystem.UnsubscribeReaction(_firstStrikeReaction, ReactionTiming.Pre);
        ClearAll();
    }

    static void OnDealDamagePre(DealDamageAction action)
    {
        if (action == null || action.SourceCard == null) return;   // 环境/连锁伤害不算「你的攻击」
        if (_firstStrikeUsed) return;

        int bonus = TempBuffRules.FirstAttackDamageBonus(_held);
        if (bonus <= 0) return;

        _firstStrikeUsed = true;
        action.RawDamage += bonus;
        Debug.Log($"[事件] 「壮胆」生效：首次攻击 +{bonus}（raw {action.RawDamage - bonus} → {action.RawDamage}）");
    }
}

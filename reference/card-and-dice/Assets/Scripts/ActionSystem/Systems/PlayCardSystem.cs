// =============================================================================
// 模块：P8 动作系统 - PlayCardSystem 出牌系统
// 用途：注册 PlayCardAction 的执行者，串联出牌完整链路：
//   1. Performer：效果结算（M5b-3 已实现：伤害/防御/效果三类分发）
//   2. 反应链：消耗能量（ConsumeEnergyAction）→ 进弃牌堆（DiscardCardAction）
// 参考教程：NSWells P8 Play Card Action + P9 Card Effects + P16 TargetMode
// 架构约定（P4.5）：执行者内部要执行新动作，必须用 AddReaction 而非 Perform
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 出牌系统：处理打出卡牌动作的执行。
/// 挂载于场景 ActionSystem 物体（OnEnable 注册 / OnDisable 注销）。
/// </summary>
public class PlayCardSystem : MonoBehaviour
{
    /// <summary>玩家缓存（"自己"目标解析 + 虚弱伤害修正查询单位）</summary>
    private static HexMover _playerCache;

    /// <summary>★2026-09-12 教学：任意卡牌被打出（动作链开始时广播，含战术槽出牌）。</summary>
    public static event System.Action<Card> OnCardPlayed;

    private void OnEnable()
    {
        ActionSystem.AttachPerformer<PlayCardAction>(PerformPlayCard);
    }

    private void OnDisable()
    {
        ActionSystem.DetachPerformer<PlayCardAction>();
    }

    /// <summary>
    /// 执行者：打出卡牌。
    /// 链路：掷骰兜底 → 消耗绑定骰子 → 效果结算 → 扣能量 → 弃牌。
    /// 注：能量检查在 CardView.OnBeginDrag / OnEndDrag 已用 CanAfford 前置拦截，
    ///     正常流程不会出现能量不足还打出（ConsumeEnergyAction 的 Cancelled 仅作兜底）。
    /// </summary>
    private IEnumerator PerformPlayCard(PlayCardAction action)
    {
        Card card = action.Card;
        if (card == null)
        {
            Debug.LogWarning("[PlayCardSystem] PlayCardAction 的 Card 为空，跳过");
            yield break;
        }

        Debug.Log($"[PlayCardSystem] 打出：{card.Data.cardName}（费用 {card.CurrentCost}，目标 {(action.Target != null ? action.Target.gameObject.name : "无")}）");
        OnCardPlayed?.Invoke(card);   // ★教学钩子： TutorialDirector 用它触发/解除「打出某卡」拍

        // ===== 1. 掷骰兜底（边缘情况 5.1：打出时骰子尚未投掷 → 先投再结算）=====
        // 正常流程抽牌时已自动掷（总策划案 6.2.2）；此处兜底覆盖重置/异常路径
        if (!card.HasRolled)
        {
            Debug.Log("[PlayCardSystem] 骰子未投掷，兜底掷骰");
            card.RollAllDice();
        }

        // ===== 2. 骰子付款（★2026-09-09 用户定稿：付款时机从抽牌移到打出）=====
        // 打出时按有效装填逐颗扣背包真实骰，不足的槽用临时劣质骰兜底（PayOnPlay）。
        // 点数在抽牌时已用装填骰掷好（读骰值玩法），此处只扣费、不重掷。
        DicePayment.PayOnPlay(card);

        // ===== 3. 效果结算（M5b-3 核心：按 effects 列表分发）=====
        if (card.Data.effects != null && card.Data.effects.Count > 0)
        {
            foreach (CardEffect effect in card.Data.effects)
            {
                if (effect == null) continue;
                ResolveCardEffect(card, effect, action.Target);
            }
        }
        else
        {
            Debug.Log($"[PlayCardSystem] {card.Data.cardName} 无战斗效果，仅消耗资源");
        }

        // ===== 4. 费用结算（★2026-09-09 用户定稿：探索打牌 = 战斗打牌 + 额外 1 枚探索骰）=====
        //   战斗骰子（弹药）在打出时已由上方步骤 2 的 DicePayment.PayOnPlay 扣除（战斗态与探索态一致）。
        //   探索态额外扣 1 枚探索骰子；能量消耗（ConsumeEnergyAction）战斗态与探索态都执行。
        bool explorationPlay = GameStateManager.Instance != null
                               && GameStateManager.Instance.CurrentState == GameState.Exploring;
        if (explorationPlay)
        {
            if (ExplorationTurnManager.Instance != null
                && ExplorationTurnManager.Instance.TryConsumeExplorationDice())
            {
                Debug.Log("[PlayCardSystem] 探索打牌：消耗 1 枚探索骰子");
            }
            else
            {
                Debug.LogWarning("[PlayCardSystem] 探索打牌：探索骰不足");
            }
        }
        // 战斗态与探索态都扣能量（用户 2026-09-09：探索打牌除扣骰外也扣能量）
        ActionSystem.Instance.AddReaction(new ConsumeEnergyAction(card.CurrentCost));

        // ===== 5. 进弃牌堆（反应链：触发 OnCardDiscarded → HandUIController 重排手牌）=====
        ActionSystem.Instance.AddReaction(new DiscardCardAction(card));

        // ===== 6. ★探索打牌命中检测（威胁预告与搜索 §6.1，2026-09-07 定稿）=====
        // 快照比对法：记录打牌前全场敌人的 HP + 状态效果数，动作链执行完毕后比对——
        //   任何敌人受到伤害/负面效果 → 偷袭入口（强制结束回合 + 骰转能量 + 玩家先手）。
        //   ★「非警戒单位转搜查」分支已删除：探索态攻击任何敌人一律走偷袭入口（§19-4），
        //     不存在"搜查中再被打"。奖励是否全额由小队资格决定（§6.2），在 TriggerAmbush 内结算。
        if (explorationPlay)
        {
            StartCoroutine(AmbushWatchRoutine(SnapshotAllEnemies()));
        }

        yield break;
    }

    /// <summary>打牌前的全场存活敌人快照：HP + 身上活跃状态效果数（命中检测用）</summary>
    private static Dictionary<EnemyController, int[]> SnapshotAllEnemies()
    {
        var snap = new Dictionary<EnemyController, int[]>();
        foreach (EnemyController e in FindObjectsOfType<EnemyController>())
        {
            if (e == null || e.IsDead) continue;
            int effectCount = EffectManager.Instance != null
                ? EffectManager.Instance.GetActiveEffectCount(e.gameObject)
                : 0;
            snap[e] = new[] { e.CurrentHP, effectCount };
        }
        return snap;
    }

    /// <summary>
    /// 探索打牌命中监测协程：等本张牌的动作链（含伤害/状态反应）全部结算完，再逐个比对快照。
    /// ★2026-09-07 定稿（威胁预告与搜索 §6.1 / §19-4）：探索态攻击**任何**敌人 = 偷袭入口，
    /// 不再区分警戒与否（原「未警戒 → 转搜查」分支已随 BeginInvestigation 一起删除）。
    /// 奖励是否全额由小队资格决定（§6.2），在 <see cref="ExplorationTurnManager.TriggerAmbush"/> 内结算。
    /// 自身牌（防御/治疗）对敌人无影响，不触发任何事。
    /// </summary>
    private IEnumerator AmbushWatchRoutine(Dictionary<EnemyController, int[]> snapshot)
    {
        // 等待动作链（Performer + 全部反应）执行完毕
        while (ActionSystem.Instance != null && ActionSystem.Instance.IsPerforming)
        {
            yield return null;
        }
        yield return null; // 再等一帧让 HP 扣减/死亡/状态落定

        // 中途已被切到战斗（异常路径）→ 不重复触发
        if (GameStateManager.Instance == null
            || GameStateManager.Instance.CurrentState != GameState.Exploring)
        {
            yield break;
        }

        var hitEnemies = new List<EnemyController>();
        foreach (var kv in snapshot)
        {
            EnemyController e = kv.Key;
            if (e == null) continue;

            bool killed = e.IsDead;
            bool damaged = killed || e.CurrentHP < kv.Value[0];
            bool debuffed = !killed && EffectManager.Instance != null
                            && EffectManager.Instance.GetActiveEffectCount(e.gameObject) > kv.Value[1];

            if (!damaged && !debuffed) continue;

            Debug.Log($"[PlayCardSystem] 偷袭入口成立：{e.gameObject.name} " +
                      (killed ? "被击杀" : damaged ? "受到伤害" : "被施加负面效果"));
            hitEnemies.Add(e);
        }

        if (hitEnemies.Count > 0)
        {
            if (ExplorationTurnManager.Instance != null)
            {
                ExplorationTurnManager.Instance.TriggerAmbush(hitEnemies);
            }
        }
        else
        {
            AlertPropagation.Refresh();
        }
    }

    // ------------------------------------------------------------------
    // M5b-3 效果分发（P9 效果执行 + P16 目标模式的合并实现）
    // ------------------------------------------------------------------

    /// <summary>
    /// 单条卡牌效果分发：按 effectType 路由到 伤害/防御/效果 三条链路。
    /// 数值全部走 Card.ResolveValue（F5.2：基础值 + 骰子点数，骰子已在此前掷好）。
    /// </summary>
    private void ResolveCardEffect(Card card, CardEffect effect, EnemyController arrowTarget)
    {
        switch (effect.effectType)
        {
            case CardEffectType.伤害:
            {
                // 攻击次数（默认 1；多次 = 多个 DealDamageAction 依次进反应链）
                int count = Mathf.Max(1, card.ResolveValue(effect.attackCountConfig));
                int baseDamage = card.ResolveValue(effect.damageConfig);
                // ★2026-09-16 力量加法口径：每段都吃（力量 = 多段卡放大器）。循环内层数不变 → 提到循环外。
                int perHitDamage = ApplyWeakness(ApplyStrength(baseDamage));

                foreach (GameObject targetObj in ResolveTargets(card, effect.targetType, arrowTarget))
                {
                    EnemyController enemy = targetObj.GetComponent<EnemyController>();
                    if (enemy == null) continue; // 目标必须是敌人

                    for (int i = 0; i < count; i++)
                    {
                        ActionSystem.Instance.AddReaction(
                            new DealDamageAction(card.Data, enemy, perHitDamage));
                    }
                }
                break;
            }

            case CardEffectType.防御:
            {
                // 防御 = 给自己叠护甲层数（P23：护甲是状态效果，1层挡1点）
                int count = Mathf.Max(1, card.ResolveValue(effect.defenseCountConfig));
                int armorPerHit = card.ResolveValue(effect.defenseConfig);
                int totalArmor = armorPerHit * count;

                GameObject player = GetPlayerRoot();
                if (player != null && totalArmor > 0)
                {
                    ActionSystem.Instance.AddReaction(
                        new AddStatusAction("护甲", totalArmor, player));
                    Debug.Log($"[PlayCardSystem] 防御：玩家获得 {totalArmor} 层护甲（{armorPerHit}×{count}）");
                }
                break;
            }

            case CardEffectType.效果:
            {
                // 施加状态效果（断筋→虚弱 等，effectTypeName 对应 EffectFactory 注册键）
                int count = Mathf.Max(1, card.ResolveValue(effect.effectCountConfig));
                int stacksPerHit = card.ResolveValue(effect.effectStacksConfig);

                foreach (GameObject target in ResolveTargets(card, effect.targetType, arrowTarget))
                {
                    for (int i = 0; i < count; i++)
                    {
                        ActionSystem.Instance.AddReaction(
                            new AddStatusAction(effect.effectTypeName, stacksPerHit, target));
                    }
                }
                break;
            }
        }
    }

    /// <summary>
    /// 目标解析（P16 TargetMode 的简化合并版）：
    /// 目标敌人 → 箭头选定 Target（M5b-2）；自己 → 玩家根物体；
    /// 射程内所有敌人 → 场景存活敌人过滤 HexDistance ≤ 卡牌射程。
    /// 返回统一 List（敌人类效果返回 EnemyController、状态类返回 GameObject），
    /// 这里返回 List&lt;GameObject&gt;，伤害分支再转 EnemyController。
    /// </summary>
    private List<GameObject> ResolveTargets(Card card, CardTargetType targetType, EnemyController arrowTarget)
    {
        var result = new List<GameObject>();

        switch (targetType)
        {
            case CardTargetType.目标敌人:
                if (arrowTarget != null && !arrowTarget.IsDead)
                {
                    result.Add(arrowTarget.gameObject);
                }
                else
                {
                    // 无指向卡的兜底：目标敌人但箭头为空（不应发生，防御）
                    Debug.LogWarning($"[PlayCardSystem] {card.Data.cardName} 需要目标但 Target 为空，效果落空");
                }
                break;

            case CardTargetType.自己:
                GameObject player = GetPlayerRoot();
                if (player != null) result.Add(player);
                break;

            case CardTargetType.射程内所有敌人:
                HexMover playerMover = GetPlayerMover();
                int range = card.Data.Range;
                foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
                {
                    if (enemy.IsDead) continue;
                    if (playerMover != null &&
                        CardExecutor.HexDistance(playerMover.CurrentCoord, enemy.CurrentCoord) > range)
                    {
                        continue; // 射程外
                    }
                    result.Add(enemy.gameObject);
                }
                break;
        }
        return result;
    }

    /// <summary>
    /// 力量加成（★2026-09-16 改加法，对齐设计页 R1）：攻击者身上每层力量使**每次命中**伤害 +1。
    /// 多段攻击的每一段都吃 —— 力量是「多段卡」的放大器（1 点伤害 × t1 次的连击只靠力量涨）。
    /// 与骰面上下限轴正交：力量不改骰面、不参与暴击判定。
    /// 与虚弱的先后：先加力量、后乘虚弱 —— 虚弱是最终输出折扣，能削弱力量。
    /// </summary>
    private int ApplyStrength(int damage)
    {
        if (damage <= 0) return damage;

        HexMover player = GetPlayerMover();
        if (player == null || EffectManager.Instance == null) return damage;

        int stacks = EffectManager.Instance.GetEffectStacks(player.gameObject, "StrengthEffect");
        if (stacks <= 0) return damage;

        int boosted = damage + StrengthEffect.BonusFor(stacks);
        Debug.Log($"[PlayCardSystem] 力量 {stacks} 层：伤害 {damage} → {boosted}（每次命中 +{stacks * StrengthEffect.DamagePerStack}）");
        return boosted;
    }

    /// <summary>
    /// 虚弱修正：玩家身上有虚弱（层数>0）时造成的伤害 ×0.75（固定，不叠加）。
    /// 用户拍板 2026-08-18；向下取整，最低 1 点（伤害≤0 时不动）。
    /// </summary>
    private int ApplyWeakness(int damage)
    {
        if (damage <= 0) return damage;

        HexMover player = GetPlayerMover();
        if (player == null || EffectManager.Instance == null) return damage;

        if (EffectManager.Instance.GetEffectStacks(player.gameObject, "WeaknessEffect") > 0)
        {
            int weakened = Mathf.Max(1, Mathf.FloorToInt(damage * WeaknessEffect.DamageMultiplier));
            Debug.Log($"[PlayCardSystem] 虚弱：伤害 {damage} → {weakened}（-25%）");
            return weakened;
        }
        return damage;
    }

    /// <summary>玩家 HexMover 缓存（受击后不销毁，战斗期间稳定）</summary>
    private static HexMover GetPlayerMover()
    {
        if (_playerCache == null) _playerCache = FindObjectOfType<HexMover>();
        return _playerCache;
    }

    /// <summary>玩家根物体（"自己"目标 + 护甲施加目标）</summary>
    private static GameObject GetPlayerRoot()
    {
        HexMover mover = GetPlayerMover();
        return mover != null ? mover.gameObject : null;
    }
}
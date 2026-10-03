// =============================================================================
// 模块：M6-2 敌人系统 - EnemyCardExecutor 敌人出牌执行器
// 用途：敌人打出意图卡牌（意图 = 打一张卡，设计文档 v2 §3）。
// 与玩家出牌（PlayCardSystem）的区别：
//   1. 敌人不消耗能量（敌人没有能量系统，energyCost 保留但不出扣）
//   2. 自动锁玩家为目标，无拖拽/箭头 UI（§3.4）
//   3. 敌我识别重映射 targetType（§3.5）：
//        自己 → 敌人自己；目标敌人 → 玩家；射程内所有敌人 → 玩家
//   4. AOE 友伤由 effect.friendlyFire 开关控制（默认 false，不伤友军）
// 结算管线：直接复用现有组件（PlayerHealth / EnemyController / EffectManager），
//   不新增副作用动作类型；伤害先扣护甲由 PlayerHealth.TakeDamage / EnemyController.TakeDamage 内部完成。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人出牌执行器（静态工具类，由 TurnManager 敌人回合或 IntentEvaluator 调用）。
/// 不挂载场景，无状态；每次调用即完成一次「敌人打一张卡」的完整结算。
/// </summary>
public static class EnemyCardExecutor
{
    // ------------------------------------------------------------------
    // 公开入口
    // ------------------------------------------------------------------

    /// <summary>
    /// 让敌人打出一张卡牌（用 CardData 模板，内部创建 Card 并掷骰）。
    /// 适用于 M6-3/M6-4 接入意图循环前的最小验证路径。
    /// </summary>
    /// <param name="source">施法敌人</param>
    /// <param name="cardData">要打出的卡牌模板</param>
    public static void ExecuteCard(EnemyController source, CardData cardData)
    {
        if (source == null || cardData == null) return;

        Card card = new Card(cardData);
        card.Owner = source.gameObject;   // ★2026-09-16 骰面修正挂人身上，掷骰前要先认主人
        card.RollAllDice();
        ExecuteCard(source, card);
    }

    /// <summary>
    /// 让敌人打出一张卡牌（用已创建的 Card 运行时实例）。
    /// M6-4 揭示阶段可能已预先掷骰锁死数值，直接传入复用；未掷骰则此处兜底掷。
    /// </summary>
    /// <param name="source">施法敌人</param>
    /// <param name="card">卡牌运行时实例（骰子点数已掷或未掷）</param>
    public static void ExecuteCard(EnemyController source, Card card)
    {
        if (source == null || card == null || card.Data == null)
        {
            Debug.LogWarning("[EnemyCardExecutor] source 或 card 为空，跳过出牌");
            return;
        }

        if (!card.HasRolled) card.RollAllDice(); // 边缘情况 5.1：未掷骰兜底

        Debug.Log($"[EnemyCardExecutor] {source.gameObject.name} 打出 {card.Data.cardName}（不耗能，自动锁玩家）");

        foreach (CardEffect effect in card.Data.effects)
        {
            if (effect == null) continue;
            ResolveEffect(source, card, effect);
        }
    }

    // ------------------------------------------------------------------
    // 效果分发（镜像 PlayCardSystem.ResolveCardEffect，但 source=敌 target=玩家）
    // ------------------------------------------------------------------

    /// <summary>单条卡牌效果分发：伤害/防御/效果 三类。</summary>
    private static void ResolveEffect(EnemyController source, Card card, CardEffect effect)
    {
        switch (effect.effectType)
        {
            case CardEffectType.伤害:
            {
                int count = Mathf.Max(1, card.ResolveValue(effect.attackCountConfig));
                int baseDamage = card.ResolveValue(effect.damageConfig);

                foreach (GameObject target in ResolvePrimaryTargets(source, effect))
                {
                    ApplyDamage(source, target, baseDamage, count);
                }

                // 友伤：AOE（射程内所有敌人）且 friendlyFire=true → 射程内其它友军敌人同受伤害（自身除外）
                if (effect.friendlyFire && effect.targetType == CardTargetType.射程内所有敌人)
                {
                    int range = card.Data.Range;
                    foreach (EnemyController ally in Object.FindObjectsOfType<EnemyController>())
                    {
                        if (ally == source || ally.IsDead) continue;
                        if (CardExecutor.HexDistance(source.CurrentCoord, ally.CurrentCoord) > range) continue;
                        ApplyDamage(source, ally.gameObject, baseDamage, count);
                    }
                }
                break;
            }

            case CardEffectType.防御:
            {
                // 敌人「防御」= 给自己叠护甲（与玩家防御卡同源，目标重映射为「自己」）
                int armorPerHit = card.ResolveValue(effect.defenseConfig);
                int dCount = Mathf.Max(1, card.ResolveValue(effect.defenseCountConfig));
                int totalArmor = armorPerHit * dCount;
                if (totalArmor > 0)
                {
                    ApplyStatus("护甲", source.gameObject, totalArmor, source);
                }
                break;
            }

            case CardEffectType.效果:
            {
                // 给重映射后的目标（通常是玩家）施加状态效果（虚弱/力量/移动点减少等）
                int count = Mathf.Max(1, card.ResolveValue(effect.effectCountConfig));
                int stacksPerHit = card.ResolveValue(effect.effectStacksConfig);
                int totalStacks = stacksPerHit * count;

                foreach (GameObject target in ResolvePrimaryTargets(source, effect))
                {
                    ApplyStatus(effect.effectTypeName, target, totalStacks, source);
                }
                break;
            }
        }
    }

    // ------------------------------------------------------------------
    // 目标重映射（§3.5 敌我识别铁律）
    // ------------------------------------------------------------------

    /// <summary>
    /// 按施法者（敌人）视角重映射目标：
    /// 自己 → 敌人自己；目标敌人 → 玩家；射程内所有敌人 → 玩家。
    /// 友伤（friendlyFire）由伤害分支单独追加，不在此主目标列表中（避免重复）。
    /// </summary>
    private static List<GameObject> ResolvePrimaryTargets(EnemyController source, CardEffect effect)
    {
        var result = new List<GameObject>();

        switch (effect.targetType)
        {
            case CardTargetType.自己:
                result.Add(source.gameObject); // 敌人自己（如自愈/自保）
                break;

            case CardTargetType.目标敌人:
                AddPlayer(result); // 敌人眼里唯一的「敌方」= 玩家
                break;

            case CardTargetType.射程内所有敌人:
                AddPlayer(result); // 敌方只有玩家一人
                break;
        }
        return result;
    }

    /// <summary>把玩家根物体加入目标列表（找不到则警告）。</summary>
    private static void AddPlayer(List<GameObject> list)
    {
        PlayerHealth player = Object.FindObjectOfType<PlayerHealth>();
        if (player != null)
        {
            list.Add(player.gameObject);
        }
        else
        {
            Debug.LogWarning("[EnemyCardExecutor] 未找到 PlayerHealth，效果落空");
        }
    }

    // ------------------------------------------------------------------
    // 结算辅助
    // ------------------------------------------------------------------

    /// <summary>
    /// 对目标结算 count 段伤害：玩家走 PlayerHealth，敌人走 EnemyController（两者都内置护甲优先扣血）。
    /// ★2026-09-16 力量改加法后，攻击者（source）每层力量使**每段** +1
    /// —— 敌人侧的「拉距成长 +1 力」「嗅迹 +1 力」靠这里真正落地。
    /// </summary>
    private static void ApplyDamage(EnemyController source, GameObject target, int baseDamage, int count)
    {
        if (target == null) return;

        PlayerHealth player = target.GetComponent<PlayerHealth>();
        EnemyController enemy = target.GetComponent<EnemyController>();

        int stacks = GetStrengthStacks(source);
        int perHit = baseDamage + StrengthEffect.BonusFor(stacks);
        if (stacks > 0)
            Debug.Log($"[EnemyCardExecutor] 力量 {stacks} 层：每段伤害 {baseDamage} → {perHit}");

        for (int i = 0; i < count; i++)
        {
            if (player != null) player.TakeDamage(perHit);
            else if (enemy != null) enemy.TakeDamage(perHit);
        }
    }

    /// <summary>攻击者身上的力量层数（EffectManager 按英文类名查）。</summary>
    private static int GetStrengthStacks(EnemyController source)
    {
        if (source == null || EffectManager.Instance == null) return 0;
        return EffectManager.Instance.GetEffectStacks(source.gameObject, "StrengthEffect");
    }

    /// <summary>
    /// 对目标施加状态效果（EffectFactory 双键注册：中文名/英文类名）。
    /// ★2026-09-16 姿态登记：若挂上的是「挨打就散」的姿态效果（如架弩的骰面下限·姿态）
    /// 且目标是施法者本人，记下当前大意图下标——打断后 EnemyController 回退到这里重放。
    /// </summary>
    private static void ApplyStatus(string effectName, GameObject target, int stacks, EnemyController source = null)
    {
        if (target == null || stacks <= 0) return;

        Effect effect = EffectFactory.Create(effectName);
        if (effect == null)
        {
            Debug.LogWarning($"[EnemyCardExecutor] 未注册的效果名 '{effectName}'，跳过");
            return;
        }

        EffectManager.Instance?.ApplyEffect(effect, target, stacks, EffectApplyTiming.立即);

        if (source != null && effect.BreaksOnDamage && target == source.gameObject)
        {
            source.MarkStanceIntent();
        }
    }
}
// =============================================================================
// 模块：P4.5 动作系统 - ActionChainTest 连锁触发验证测试
// 用途：复刻 P4.5 视频的示例场景，验证动作系统连锁执行正确：
//   抽一张牌（DrawCardAction）
//     → 触发"诅咒之刃"的 Post 反应：每抽一张牌对敌人造成 3 点伤害
//       → 触发"狂战随从"的 Post 反应：敌人每受一次伤打印属性成长（可继续连锁）
//   预期 Console 输出顺序：
//   [CardPileSystem] 抽牌 → [DamageSystem] 受击 3 点 → [ActionChainTest] 连锁反应打印 → 链完成
// 使用方式：挂在场景任意物体上（建议 ActionSystem 物体），
//           Inspector 右键组件 → 选「P4.5 连锁测试」
// =============================================================================
using UnityEngine;

/// <summary>
/// P4.5 动作链连锁验证测试（演示用，验收后可删除或保留作答辩展示）。
/// </summary>
public class ActionChainTest : MonoBehaviour
{
    [ContextMenu("P4.5 连锁测试：抽牌→伤害→连锁反应")]
    public void RunChainTest()
    {
        if (ActionSystem.Instance == null)
        {
            Debug.LogError("[ActionChainTest] 场景中没有 ActionSystem，测试中止");
            return;
        }

        // 模拟视频中的两件"装备"：订阅两个 Post 反应
        // 订阅时机：Perform 之前（正式项目中装备在战斗开始时订阅，战斗结束注销）
        ActionSystem.SubscribeReaction<DrawCardAction>(OnCardDrawn_CursedBlade, ReactionTiming.Post);
        ActionSystem.SubscribeReaction<DealDamageAction>(OnDamageDealt_Berserker, ReactionTiming.Post);

        Debug.Log("========== P4.5 动作链测试开始：执行 DrawCardAction(1) ==========");

        // 顶层动作：抽一张牌
        ActionSystem.Instance.Perform(new DrawCardAction(1), () =>
        {
            Debug.Log("========== P4.5 动作链测试完成（整条链含连锁全部执行完毕） ==========");

            // 测试完毕注销订阅（避免影响后续正常打牌流程）
            ActionSystem.UnsubscribeReaction<DrawCardAction>(OnCardDrawn_CursedBlade, ReactionTiming.Post);
            ActionSystem.UnsubscribeReaction<DealDamageAction>(OnDamageDealt_Berserker, ReactionTiming.Post);
        });
    }

    /// <summary>
    /// 模拟"诅咒之刃"：每当抽一张牌后，对场景中第一个存活敌人造成 3 点伤害。
    /// 反应规则：只创建新动作 + AddReaction，不直接执行逻辑（视频核心约定）。
    /// </summary>
    private void OnCardDrawn_CursedBlade(DrawCardAction action)
    {
        EnemyController enemy = FindObjectOfType<EnemyController>();
        if (enemy == null || enemy.IsDead)
        {
            Debug.Log("[诅咒之刃] 场景无存活敌人，跳过反应");
            return;
        }

        Debug.Log($"[诅咒之刃] 抽牌触发反应：对 {enemy.gameObject.name} 造成 3 点伤害");
        // 关键：用 AddReaction 挂接，动作系统会在当前阶段后统一执行
        ActionSystem.Instance.AddReaction(new DealDamageAction(null, enemy, 3));
    }

    /// <summary>
    /// 模拟"狂战随从"：敌人每受一次伤，打印属性成长提示。
    /// 这里演示 Post 反应可以读取 FinalDamage 并继续无限连锁（实际项目按需 AddReaction）。
    /// </summary>
    private void OnDamageDealt_Berserker(DealDamageAction action)
    {
        Debug.Log($"[狂战随从] 受伤触发反应：{action.Target.gameObject.name} 实际受伤 {action.FinalDamage} 点，" +
                  $"随从每点伤害获得 +{action.FinalDamage} 攻击（演示打印，不再继续连锁）");

        // 如需继续连锁（对应视频"随从每项属性+3"），在此 AddReaction 新动作即可：
        // ActionSystem.Instance.AddReaction(new SomeAction(...));
    }
}

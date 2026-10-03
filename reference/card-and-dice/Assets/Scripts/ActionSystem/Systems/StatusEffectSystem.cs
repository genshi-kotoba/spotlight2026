// =============================================================================
// 模块：M5b-3 动作系统 - StatusEffectSystem 状态效果系统
// 用途：注册 AddStatusAction 的执行者，把动作接到 EffectManager.ApplyEffect
// 对齐 P23 StatusEffectSystem：执行者遍历目标列表逐个施加
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 状态效果系统：处理所有 AddStatusAction 的执行。
/// 挂载于场景 ActionSystem 物体（OnEnable 注册 / OnDisable 注销）。
/// </summary>
public class StatusEffectSystem : MonoBehaviour
{
    private void OnEnable()
    {
        ActionSystem.AttachPerformer<AddStatusAction>(PerformAddStatus);
    }

    private void OnDisable()
    {
        ActionSystem.DetachPerformer<AddStatusAction>();
    }

    /// <summary>
    /// 执行者：对每个目标施加状态效果。
    /// 效果实例由 EffectFactory 按中文名创建；叠加语义由 EffectManager 处理
    /// （同类型同目标 → 层数累加；新实例 → Apply 回调）。
    /// </summary>
    private IEnumerator PerformAddStatus(AddStatusAction action)
    {
        if (action.Stacks <= 0 || action.Targets.Count == 0) yield break;

        // 未注册的效果名 → 警告并跳过（卡牌数据写错名字时的防御）
        if (EffectFactory.Create(action.EffectName) == null)
        {
            Debug.LogWarning($"[StatusEffectSystem] 未注册的效果名 '{action.EffectName}'，跳过（请在 EffectFactory._creators 注册）");
            yield break;
        }

        foreach (GameObject target in action.Targets)
        {
            if (target == null) continue;

            // 每个目标创建独立 Effect 实例（EffectManager 按类型+目标判重叠加）
            Effect effect = EffectFactory.Create(action.EffectName);
            if (effect == null) continue;

            EffectManager.Instance?.ApplyEffect(effect, target, action.Stacks, EffectApplyTiming.立即);

            // TODO M5b-4：施加状态的表现（头顶飘字/图标弹跳）在此接入
        }

        yield break;
    }
}

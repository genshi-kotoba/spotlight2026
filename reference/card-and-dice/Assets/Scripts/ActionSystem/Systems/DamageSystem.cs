// =============================================================================
// 模块：P4.5 动作系统 - DamageSystem 伤害系统
// 用途：注册 DealDamageAction 的执行者，把伤害动作接到 EnemyController.TakeDamage
// 减伤公式：finalDamage = max(0, rawDamage - defense)
// 职责边界：不管伤害从哪来（卡牌/反伤/环境），统一走此执行者结算
// =============================================================================
using System.Collections;
using UnityEngine;

/// <summary>
/// 伤害系统：处理所有 DealDamageAction 的执行。
/// 挂载于场景 ActionSystem 物体（OnEnable 注册 / OnDisable 注销）。
/// </summary>
public class DamageSystem : MonoBehaviour
{
    private void OnEnable()
    {
        ActionSystem.AttachPerformer<DealDamageAction>(PerformDealDamage);
    }

    private void OnDisable()
    {
        ActionSystem.DetachPerformer<DealDamageAction>();
    }

    /// <summary>
    /// 执行者：对目标结算伤害。
    /// 减伤在 EnemyController.TakeDamage 内部完成，此处只透传并写回 FinalDamage。
    /// TODO M5b-4：伤害动画 / 浮动伤害数字在此处接入（yield return 等待动画）
    /// </summary>
    private IEnumerator PerformDealDamage(DealDamageAction action)
    {
        // 被取消（无敌/闪避）→ 不执行
        if (action.Cancelled) yield break;

        // 目标无效 → 不执行
        if (action.Target == null || action.Target.IsDead)
        {
            Debug.LogWarning("[DamageSystem] 伤害目标无效（null 或已死亡），跳过");
            yield break;
        }

        // 结算：内部执行 finalDamage = max(0, rawDamage - defense) 并扣血、广播 OnHPChanged
        action.FinalDamage = action.Target.TakeDamage(action.RawDamage);

        Debug.Log($"[DamageSystem] {action.Target.gameObject.name} 受击：raw={action.RawDamage}, final={action.FinalDamage}");

        // TODO M5b-4：播放受击动画（DOTween 抖动）+ 浮动伤害数字，期间 yield return
        yield break;
    }
}

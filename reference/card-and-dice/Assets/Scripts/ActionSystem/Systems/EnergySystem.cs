// =============================================================================
// 模块：P4.5 动作系统 - EnergySystem 能量系统
// 用途：注册 ConsumeEnergyAction 的执行者，把能量消耗动作接到 EnergyPointDisplay
// 公式依据：F1.1 能量上限 9 / F1.2 整备回复补满至 3（Demo 显示 当前能量/3）
// =============================================================================
using System.Collections;
using UnityEngine;

/// <summary>
/// 能量系统：处理能量消耗动作的执行。
/// 挂载于场景 ActionSystem 物体（OnEnable 注册 / OnDisable 注销）。
/// </summary>
public class EnergySystem : MonoBehaviour
{
    private void OnEnable()
    {
        ActionSystem.AttachPerformer<ConsumeEnergyAction>(PerformConsumeEnergy);
    }

    private void OnDisable()
    {
        ActionSystem.DetachPerformer<ConsumeEnergyAction>();
    }

    /// <summary>
    /// 执行者：尝试扣除能量。
    /// 能量充足 → 扣除并更新 UI；不足 → 置 Cancelled（不扣），由打牌流程决定后续处理。
    /// </summary>
    private IEnumerator PerformConsumeEnergy(ConsumeEnergyAction action)
    {
        // 被取消 = 免费打出（智力判定不消耗等），直接跳过
        if (action.Cancelled) yield break;

        EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd == null)
        {
            Debug.LogError("[EnergySystem] 场景中找不到 EnergyPointDisplay，无法扣除能量");
            yield break;
        }

        if (!epd.TryConsumeEnergy(action.Amount))
        {
            // 能量不足：取消本动作（不扣能量），打牌流程应在此前已用 CanAfford 检查过
            action.Cancelled = true;
            Debug.LogWarning($"[EnergySystem] 能量不足：需要 {action.Amount}，当前 {epd.CurrentEnergy}，动作取消");
        }

        yield break;
    }
}

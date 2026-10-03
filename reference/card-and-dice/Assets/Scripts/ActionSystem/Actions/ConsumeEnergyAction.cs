// =============================================================================
// 模块：P4.5 动作系统 - ConsumeEnergyAction 消耗能量动作
// 用途：打牌消耗能量（M5b-3 打牌链路第 9 步）
// 公式依据：F1.x 能量系统（整备回复补满至 3）
// =============================================================================

/// <summary>
/// 消耗能量的游戏动作。
/// Pre 阶段订阅者可修改 Amount（如"降低 1 点费用"）或置 Cancelled（如免费打出）。
/// Performer 执行时若能量不足则置 Cancelled 并警告（不扣能量）。
/// </summary>
public class ConsumeEnergyAction : GameAction
{
    /// <summary>要消耗的能量数（Pre 阶段可修改）</summary>
    public int Amount { get; set; }

    /// <summary>是否被取消（Pre 反应取消 = 免费打出；能量不足 = Performer 置 true）</summary>
    public bool Cancelled { get; set; }

    public ConsumeEnergyAction(int amount)
    {
        Amount = amount;
        Cancelled = false;
    }
}

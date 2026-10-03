// =============================================================================
// 模块：P4.5 动作系统 - ReactionTiming 反应时机枚举
// 参考：NSWells P4.5 Action & Reaction System
// =============================================================================

/// <summary>
/// 反应订阅的触发时机。
/// </summary>
public enum ReactionTiming
{
    /// <summary>动作执行前触发：可读取并修改动作数据（如修改伤害值、置 Cancelled 取消）</summary>
    Pre,

    /// <summary>动作执行后触发：可读取执行结果（如 FinalDamage）并连锁新动作</summary>
    Post
}

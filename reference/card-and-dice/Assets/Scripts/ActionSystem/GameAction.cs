// =============================================================================
// 模块：P4.5 动作系统 - GameAction 游戏动作抽象基类
// 用途：每一个游戏行为（伤害/抽牌/弃牌/消耗能量）都封装为一个动作对象，
//       动作只持有数据，不持有执行逻辑（执行逻辑在各 System 的 Performer 里）
// 参考：NSWells P4.5 Action & Reaction System
// 设计文档：docs/superpowers/refs/action-reaction-system.md §2.1
// =============================================================================
using System.Collections.Generic;

/// <summary>
/// 游戏动作抽象基类（纯数据容器）。
/// 每个动作持有三个反应列表，分别对应三个阶段：
///   PreReactions      —— 动作执行【前】触发（可修改/取消动作数据）
///   PerformerReactions—— 执行者执行【中】追加的副反应（如打出卡牌时效果生成的动作）
///   PostReactions     —— 动作执行【后】触发（连锁触发新动作）
/// </summary>
public abstract class GameAction
{
    /// <summary>动作执行前的反应列表（Pre 订阅者通过 AddReaction 填充）</summary>
    public List<GameAction> PreReactions { get; } = new List<GameAction>();

    /// <summary>执行者阶段追加的反应列表（Performer 内部通过 AddReaction 填充）</summary>
    public List<GameAction> PerformerReactions { get; } = new List<GameAction>();

    /// <summary>动作执行后的反应列表（Post 订阅者通过 AddReaction 填充）</summary>
    public List<GameAction> PostReactions { get; } = new List<GameAction>();
}

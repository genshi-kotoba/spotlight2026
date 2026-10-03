// =============================================================================
// 模块：P4.5 动作系统 - DealDamageAction 造成伤害动作
// 用途：所有伤害（卡牌伤害/反伤/连锁伤害）统一封装为该动作
// 减伤公式：finalDamage = max(0, rawDamage - defense)（在 EnemyController.TakeDamage 内执行）
// =============================================================================
using UnityEngine;

/// <summary>
/// 造成伤害的游戏动作。
/// Pre 阶段订阅者可修改 RawDamage（如 Buff 增伤）或置 Cancelled 取消（如无敌）。
/// Performer 执行后写入 FinalDamage（减防后实际伤害），Post 订阅者可读取连锁（如吸血）。
/// </summary>
public class DealDamageAction : GameAction
{
    /// <summary>伤害来源卡牌（无来源时可 null，如环境伤害）</summary>
    public CardData SourceCard { get; }

    /// <summary>受伤目标敌人</summary>
    public EnemyController Target { get; }

    /// <summary>原始伤害（未减防，Pre 阶段可修改）</summary>
    public int RawDamage { get; set; }

    /// <summary>实际伤害（减防后，Performer 写回，Post 阶段可读）</summary>
    public int FinalDamage { get; set; }

    /// <summary>是否被 Pre 反应取消（取消则 Performer 不执行）</summary>
    public bool Cancelled { get; set; }

    public DealDamageAction(CardData source, EnemyController target, int rawDamage)
    {
        SourceCard = source;
        Target = target;
        RawDamage = rawDamage;
        FinalDamage = 0;
        Cancelled = false;
    }
}

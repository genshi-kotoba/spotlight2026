// =============================================================================
// 模块：M5b-3 动作系统 - AddStatusAction 施加状态效果动作
// 用途：把"给目标施加状态效果"封装为 GameAction（对齐 P23 AddStatusEffectGameAction）
//       走 ActionSystem 统一执行，Pre/Post 阶段可挂 Reaction（如"施加状态时触发"）
// 执行者：StatusEffectSystem → EffectManager.ApplyEffect
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 施加状态效果的游戏动作。
/// Targets 为列表（P16 目标系统约定）：单体目标传单元素，全体传多元素。
/// EffectName 为效果中文名（EffectFactory 注册键，如 "护甲"/"虚弱"）。
/// </summary>
public class AddStatusAction : GameAction
{
    /// <summary>效果中文名（EffectFactory 注册键）</summary>
    public string EffectName { get; }

    /// <summary>施加层数</summary>
    public int Stacks { get; }

    /// <summary>目标列表（单位根物体：EnemyController/PlayerHealth 所在物体）</summary>
    public List<GameObject> Targets { get; }

    public AddStatusAction(string effectName, int stacks, List<GameObject> targets)
    {
        EffectName = effectName;
        Stacks = stacks;
        Targets = targets ?? new List<GameObject>();
    }

    /// <summary>单目标构造便捷重载</summary>
    public AddStatusAction(string effectName, int stacks, GameObject target)
    {
        EffectName = effectName;
        Stacks = stacks;
        Targets = new List<GameObject>();
        if (target != null) Targets.Add(target);
    }
}

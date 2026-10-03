// =============================================================================
// 模块：M6 敌人系统 - PassiveData 被动技能
// 用途：被动 = 效果集合（开局赋予的状态效果 + 属性修饰），敌我通用
// 设计依据：《设计增补_敌人系统_v2.md》§5 被动技能
// ★工程适配：v2 原文用 EffectData SO 引用；本项目效果系统是「名称驱动」
//   （EffectFactory.Create(name)，见 Effects.cs），不存在 EffectData SO，
//   故状态效果授予改为按名称字符串引用，复用现有 effectTypeName 约定。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 被动可修饰的属性类型（预留扩展）。
/// 设计依据：v2 §5.2。
/// </summary>
public enum AttributeType
{
    MoveRange,     // 移动力
    VisionRange    // 视野
}

/// <summary>
/// 属性修饰（如「移动力+1」）。纯被动、无触发，开局常驻生效。
/// 设计依据：v2 §5.2。
/// </summary>
[Serializable]
public class AttributeModifier
{
    [Tooltip("修饰的属性类型")]
    public AttributeType attribute = AttributeType.MoveRange;

    [Tooltip("增量（可为负，如移动力-1）")]
    public int delta;
}

/// <summary>
/// 被动授予类型：显式二选一（OnValidate 强制互斥，杜绝两都填/都不填）。
/// 设计依据：v2 §5.2、§16-12。
/// </summary>
public enum GrantType
{
    StatusEffect,        // 状态效果（血条下显示图标，L1）
    AttributeModifier    // 属性修饰（仅面板显示，L2）
}

/// <summary>
/// 单条被动授予：要么是一个状态效果，要么是一个属性修饰，二选一。
/// 设计依据：v2 §5.2。
/// </summary>
[Serializable]
public class PassiveGrant
{
    [Tooltip("授予类型（二选一，OnValidate 强制互斥）")]
    public GrantType type = GrantType.StatusEffect;

    [Tooltip("状态效果名（EffectFactory 注册键，中文或英文类名，如'护甲'/'虚弱'）。type==StatusEffect 时用")]
    public string statusEffectName = "";

    [Tooltip("层数（如荆棘 3）。type==StatusEffect 时用")]
    public int stacks;

    [Tooltip("属性修饰（如移动力+1）。type==AttributeModifier 时用")]
    public AttributeModifier attribute;

    /// <summary>
    /// OnValidate 调用：强制互斥。StatusEffect → 属性清空；AttributeModifier → 效果名/层数清空。
    /// 设计依据：v2 §15.3。
    /// </summary>
    public void ValidateMutex()
    {
        if (type == GrantType.StatusEffect)
        {
            attribute = null;
        }
        else
        {
            statusEffectName = "";
            stacks = 0;
        }
        if (stacks < 0) stacks = 0;
    }
}

/// <summary>
/// 被动技能数据。装上后即生效，敌我通用（灵魂提取后玩家可装同一被动）。
/// 设计依据：v2 §5。
/// </summary>
[CreateAssetMenu(fileName = "NewPassive", menuName = "卡牌与骰子/被动技能", order = 12)]
public class PassiveData : ScriptableObject
{
    [Tooltip("被动唯一标识（自动生成）")]
    public string passiveID;

    [Tooltip("被动显示名")]
    public string passiveName = "新被动";

    [Tooltip("被动完整描述（面板展示）")]
    [TextArea]
    public string description;

    [Tooltip("被动图标")]
    public Sprite icon;

    [Tooltip("效果集合（每条 grant 是一个状态效果或属性修饰）")]
    public List<PassiveGrant> grants = new List<PassiveGrant>();

    [Tooltip("稀有度（抽取权重档）。四档与卡牌共用 CardRarity —— 灵魂提取装置按它分档抽")]
    public CardRarity rarity = CardRarity.普通;

    [Tooltip("价值点 1–4（手标）：被动编队预算吃它、激活成本＝价值×系数。刻度参考：1 小额属性 / 2 中额或单条件 / 3 强机制 / 4 改写规则")]
    [Range(1, 4)]
    public int value = 1;

    private void OnEnable()
    {
        if (string.IsNullOrEmpty(passiveID))
        {
            passiveID = "PASSIVE_" + System.DateTime.Now.ToString("HHmmss");
        }
    }

    private void OnValidate()
    {
        if (grants != null)
        {
            foreach (var g in grants)
            {
                if (g != null) g.ValidateMutex();
            }
        }
    }
}
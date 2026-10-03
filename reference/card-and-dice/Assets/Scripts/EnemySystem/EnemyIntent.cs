// =============================================================================
// 模块：M6 敌人系统 - EnemyIntent 意图结构
// 用途：定义敌人意图循环（大意图 if-else 链 + 小意图打牌选项）
// 设计依据：《设计增补_敌人系统_v2.md》§3 意图系统
// 核心理念：意图 = 打出一张卡牌（D2 / 方案 A：共享玩家 CardData）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 小意图 = 打一张卡。优先级体现在它在 EnemyBigIntent.options 列表中的顺序（从上到下）。
/// 设计依据：v2 §3.1。
/// </summary>
[Serializable]
public class EnemyIntentOption
{
    [Tooltip("要打出的卡牌（共享玩家 CardData，方案 A）")]
    public CardData card;

    [Tooltip("骰子槽 1（可空 = 沿用 card 自带骰子）")]
    public DiceData diceSlot1;
    [Tooltip("骰子槽 2（可空 = 沿用 card 自带骰子）")]
    public DiceData diceSlot2;
    [Tooltip("骰子槽 3（可空 = 沿用 card 自带骰子）")]
    public DiceData diceSlot3;
    [Tooltip("骰子槽 4（可空 = 沿用 card 自带骰子）")]
    public DiceData diceSlot4;

    [Tooltip("true=成功后下回合推进到下一个大意图；false=重试当前大意图")]
    public bool advanceOnSuccess = true;
}

/// <summary>
/// 大意图 = 一个回合的 if-else 链。一个大意图对应一个敌人回合。
/// options 从上到下依次尝试，第一个能完成的小意图被执行。
/// 设计依据：v2 §3.1「大意图 = if-else 链」。
/// </summary>
[Serializable]
public class EnemyBigIntent
{
    [Tooltip("小意图 if-else 链（优先级从上到下）")]
    public List<EnemyIntentOption> options = new List<EnemyIntentOption>();
}

/// <summary>
/// 揭示的单个小意图：原始配置 + 已掷骰锁死的运行时卡牌。
/// 设计依据：v2 §3.3 —— 玩家回合开始投所有小意图骰子，数值锁死，敌人回合不再重投。
/// 纯运行时对象（含 Card 实例），不序列化。
/// </summary>
public class RevealedIntentOption
{
    /// <summary>原始小意图配置（priority 体现在 EnemyBigIntent.options 中的顺序）</summary>
    public EnemyIntentOption option;

    /// <summary>已掷骰锁死的运行时卡牌实例（数值固定，敌人回合执行时直接复用）</summary>
    public Card rolledCard;
}

/// <summary>
/// 揭示的整回合意图：一个大意图 + 其所有小意图的已掷骰卡牌（按优先级顺序）。
/// 优先小意图 = options[0]（if-else 链首位）。
/// </summary>
public class EnemyRevealedIntent
{
    /// <summary>本回合大意图下标（指向 EnemyData.intentLoop）</summary>
    public int bigIntentIndex;

    /// <summary>已揭示的小意图（按优先级从上到下）</summary>
    public List<RevealedIntentOption> options = new List<RevealedIntentOption>();

    /// <summary>优先小意图（if-else 链首位，优先级最高）</summary>
    public RevealedIntentOption Primary => options.Count > 0 ? options[0] : null;
}
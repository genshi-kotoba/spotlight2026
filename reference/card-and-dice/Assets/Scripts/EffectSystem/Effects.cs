using UnityEngine;
using System.Collections.Generic;

/// <summary>
/// 效果工厂：按效果名创建 Effect 实例。
/// ★2026-08-18 双键注册：中文名（"护甲"）与英文类名（"ArmorEffect"）都接受——
/// 现有卡牌资产（直刺/断筋/嗅盐）的 effectTypeName 存的是英文类名（Inspector 手填），
/// 新卡可用中文（可读性更好）。EffectManager.GetEffectStacks 查询键统一用英文类名
/// （GetType().Name），与本工厂的英文键天然一致。
/// 新增效果类时在 _creators 加两行（中文名+英文类名）即可。
/// </summary>
public static class EffectFactory
{
    private static readonly Dictionary<string, System.Func<Effect>> _creators =
        new Dictionary<string, System.Func<Effect>>
    {
        // 中文名键（新数据推荐）
        { "虚弱", () => new WeaknessEffect() },
        { "力量", () => new StrengthEffect() },
        { "生命回复", () => new HealEffect() },
        { "行动", () => new ActionEffect() },
        { "移动点减少", () => new MovePointReductionEffect() },
        { "减少移动点", () => new MovePointReductionEffect() }, // 类内 Name 为"减少移动点"，双中文键兼容
        { "护甲", () => new ArmorEffect() },
        // ★2026-09-16 骰面上下限修正（设计页 R1）：一次性 / 持续 各一轴
        { "骰面下限", () => new DiceFloorModifierEffect() },
        { "骰面上限", () => new DiceCeilModifierEffect() },
        { "骰面下限·持续", () => new DiceFloorDurationEffect() },
        { "骰面上限·持续", () => new DiceCeilDurationEffect() },
        { "骰面下限·姿态", () => new DiceFloorStanceEffect() },
        // 英文类名键（兼容现有卡牌资产数据）
        { "WeaknessEffect", () => new WeaknessEffect() },
        { "StrengthEffect", () => new StrengthEffect() },
        { "HealEffect", () => new HealEffect() },
        { "ActionEffect", () => new ActionEffect() },
        { "MovePointReductionEffect", () => new MovePointReductionEffect() },
        { "ArmorEffect", () => new ArmorEffect() },
        { "DiceFloorModifierEffect", () => new DiceFloorModifierEffect() },
        { "DiceCeilModifierEffect", () => new DiceCeilModifierEffect() },
        { "DiceFloorDurationEffect", () => new DiceFloorDurationEffect() },
        { "DiceCeilDurationEffect", () => new DiceCeilDurationEffect() },
        { "DiceFloorStanceEffect", () => new DiceFloorStanceEffect() },
    };

    /// <summary>
    /// 按效果名（中文或英文类名）创建效果实例；未注册的名字返回 null（调用方警告并跳过）。
    /// </summary>
    public static Effect Create(string effectName)
    {
        if (!string.IsNullOrEmpty(effectName) && _creators.TryGetValue(effectName, out var creator))
        {
            return creator();
        }
        return null;
    }
}

/// <summary>
/// 护甲效果（M5b-3 / P23 对齐）
/// 1 层护甲挡 1 点伤害：TakeDamage 入口先扣护甲（见 EnemyController/PlayerHealth）。
///
/// ★2026-09-14 清零时机修正（用户定稿）：**谁的回合开始，清谁的护甲**——
///   玩家护甲 → 玩家回合开始清零（TurnManager.StartNewTurn）→ 因此能覆盖完整个敌人回合；
///   敌人护甲 → 敌人回合开始清零（TurnManager.EnemyTurn 开头）→ 因此能覆盖完整个玩家回合。
///   旧实现「玩家回合结束（=敌人回合开头）统一清零」把双方护甲在第 0 步就抹掉，
///   玩家的防御牌永远来不及挡敌人那一下（用户实测：防御没有效果）。
///   语义同杀戮尖塔（格挡持续到**持有者自己**的下个回合开始）——旧注释写「回合结束清零」是错的。
///   注意：敌人护甲在 EnemyTurn **最开头**清 → 之后敌人整回合新叠的甲能活过玩家回合；
///   同理玩家回合开始清完后新叠的甲能活过敌人回合。
///
/// 清零不再走通用回合末衰减（见 OnTurnUpdate）：由 EffectManager.ClearArmor 显式清算。
/// </summary>
public class ArmorEffect : Effect
{
    public ArmorEffect()
    {
        Name = "护甲";
        Description = "每层抵挡1点伤害，持续到自己的下个回合开始";
        TargetType = EffectTargetType.人物;
    }

    public override void Apply(GameObject target, int stacks)
    {
        // 层数记录在 EffectManager（EffectInstance.Stacks），此处仅日志
        Debug.Log($"{target.name} 获得 {stacks} 层护甲");
    }

    public override void End(GameObject target)
    {
        Debug.Log($"{target.name} 的护甲消失");
    }

    /// <summary>
    /// 护甲不吃通用回合末衰减：层数原样返回（旧实现返回 0 = 在 EffectManager.OnTurnEnd
    /// 里被整体清零，清零时机不对，见类注释）。
    /// 现在的清零点是持有者**自己回合开始** → TurnManager 调 EffectManager.ClearArmor。
    /// </summary>
    public override int OnTurnUpdate(GameObject target, int currentStacks)
    {
        return currentStacks;
    }
}

/// <summary>
/// 虚弱效果
/// ★用户拍板 2026-08-18：固定伤害-25%（不随层数叠加），层数只是持续时间，每回合-1
/// </summary>
public class WeaknessEffect : Effect
{
    /// <summary>虚弱减伤系数（固定 25%，与层数无关）</summary>
    public const float DamageMultiplier = 0.75f;

    public WeaknessEffect()
    {
        Name = "虚弱";
        Description = "造成的伤害减少25%（固定，不叠加），层数每回合-1";
        TargetType = EffectTargetType.人物;
    }

    public override void Apply(GameObject target, int stacks)
    {
        Debug.Log($"{target.name} 获得 {stacks} 层虚弱（持续 {stacks} 回合，期间伤害-25%）");
    }

    public override void End(GameObject target)
    {
        Debug.Log($"{target.name} 的虚弱效果结束");
    }

    /// <summary>
    /// 强度 = 有层数时固定 0.75 倍伤害系数；层数不参与计算。
    /// </summary>
    public override float GetEffectStrength(int stacks)
    {
        return stacks > 0 ? DamageMultiplier : 1f;
    }
}

/// <summary>
/// 力量效果（★2026-09-16 改「加法」口径，对齐设计页 R1：力量 = 每次命中伤害 +1/点）
/// 每层使**每次命中**伤害 +1 —— 多段攻击的每一段都 +1，所以力量是「多段卡」的放大器。
/// 与骰面上下限轴正交：力量不改骰面、不参与暴击判定（4 点力量也要骰到 4 才暴击）。
/// 层数每回合-1。
/// </summary>
public class StrengthEffect : Effect
{
    /// <summary>每层力量的每次命中加伤。设计口径：+1/点（旧实装是 +25%，全库无消费方，已废弃）</summary>
    public const int DamagePerStack = 1;

    public StrengthEffect()
    {
        Name = "力量";
        Description = "每层使每次命中伤害 +1，多段攻击每段都加；层数每回合-1";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>
    /// 层数 → 每次命中的加伤值。玩家侧（PlayCardSystem）与敌人侧（EnemyCardExecutor）
    /// 的伤害管线共用同一换算，避免两边口径漂移。
    /// </summary>
    public static int BonusFor(int stacks)
    {
        return stacks > 0 ? stacks * DamagePerStack : 0;
    }

    public override void Apply(GameObject target, int stacks)
    {
        // 应用力量效果
        Debug.Log($"{target.name} 获得 {stacks} 层力量效果");
    }

    public override void End(GameObject target)
    {
        // 结束力量效果
        Debug.Log($"{target.name} 的力量效果结束");
    }
}

/// <summary>
/// 生命回复效果（★瞬时：立即回血，不注册持续状态，UI 不显示）
/// 每获得一层生命回复将会立即使玩家当前的血量+1，无法超过血量上限
/// </summary>
public class HealEffect : Effect
{
    public HealEffect()
    {
        Name = "生命回复";
        Description = "每获得一层生命回复将会立即使玩家当前的血量+1，无法超过血量上限";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>瞬时效果：结算完不注册持续实例（★2026-08-19，见 Effect.IsInstant）</summary>
    public override bool IsInstant => true;

    public override void Apply(GameObject target, int stacks)
    {
        // 应用生命回复效果
        Debug.Log($"{target.name} 获得 {stacks} 层生命回复效果");

        // ★2026-08-18 M5b-3 真正实现：每层立即回 1 点血（嗅盐卡此前是空壳不回血）
        // 玩家 → PlayerHealth.Heal；敌人 → EnemyController.Heal（两者上限截断逻辑已内置）
        var playerHealth = target.GetComponent<PlayerHealth>();
        if (playerHealth != null)
        {
            playerHealth.Heal(stacks);
            return;
        }

        var enemy = target.GetComponent<EnemyController>();
        if (enemy != null)
        {
            enemy.Heal(stacks);
        }
    }

    public override void End(GameObject target)
    {
        // 瞬时效果不注册持续实例，End 不会被调用（abstract 强制实现，保留空壳）
        Debug.Log($"{target.name} 的生命回复效果结束");
    }
}

/// <summary>
/// 行动效果（★瞬时：立即加 AP，不注册持续状态，UI 不显示）
/// 每获得一层行动将会立即使玩家当前行动点+1
/// </summary>
public class ActionEffect : Effect
{
    public ActionEffect()
    {
        Name = "行动";
        Description = "每获得一层行动将会立即使玩家当前行动点+1";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>瞬时效果：结算完不注册持续实例（★2026-08-19，见 Effect.IsInstant）</summary>
    public override bool IsInstant => true;

    public override void Apply(GameObject target, int stacks)
    {
        // 应用行动效果
        Debug.Log($"{target.name} 获得 {stacks} 层行动效果");

        // 查找目标的HexMover组件
        // ★2026-08-18 删除 FindObjectOfType 兜底：兜底会把效果错误落到玩家身上
        //（目标是敌人时敌人无 HexMover → 原兜底逻辑误伤玩家 AP）。目标没有就跳过。
        HexMover mover = target.GetComponent<HexMover>();

        if (mover != null)
        {
            // 为目标增加行动点
            mover.currentActionPoints += stacks;
            // 确保不超过最大行动点
            mover.currentActionPoints = Mathf.Min(mover.currentActionPoints, mover.maxActionPoints);
            Debug.Log($"{target.name} 获得 {stacks} 点行动点，当前行动点：{mover.currentActionPoints}");
        }
    }

    public override void End(GameObject target)
    {
        // 瞬时效果不注册持续实例，End 不会被调用（abstract 强制实现，保留空壳）
        Debug.Log($"{target.name} 的行动效果结束");
    }
}

/// <summary>
/// 减少移动点效果（★瞬时：立即扣移动点，不注册持续状态，UI 不显示——用户 2026-08-19 确认
/// 「断筋不算一个效果，不需要在面板上展示，直接扣对应的移动点就行」）
/// 每获得一层减少移动点将会立即使目标当前移动点-1
/// </summary>
public class MovePointReductionEffect : Effect
{
    public MovePointReductionEffect()
    {
        Name = "减少移动点";
        Description = "每获得一层减少移动点将会立即使目标当前移动点-1（瞬时结算，无持续）";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>瞬时效果：结算完不注册持续实例（★2026-08-19，见 Effect.IsInstant）</summary>
    public override bool IsInstant => true;

    public override void Apply(GameObject target, int stacks)
    {
        // 应用减少移动点效果
        Debug.Log($"{target.name} 获得 {stacks} 层减少移动点效果");

        // 查找目标的HexMover组件
        // ★2026-08-18 删除 FindObjectOfType 兜底（断筋打敌人时曾误扣玩家 AP）。
        // ★同日接入敌人 AP：敌人无 HexMover，但 EnemyController 已有行动点体系
        //（上限=data.moveRange），断筋打敌人现在真正扣其 AP。
        HexMover mover = target.GetComponent<HexMover>();

        if (mover != null)
        {
            // 为目标减少行动点
            mover.currentActionPoints = Mathf.Max(0, mover.currentActionPoints - stacks);
            Debug.Log($"{target.name} 减少 {stacks} 点行动点，当前行动点：{mover.currentActionPoints}");
            return;
        }

        // 敌人分支：EnemyController.ModifyActionPoints 内部夹在 0~moveRange
        var enemy = target.GetComponent<EnemyController>();
        if (enemy != null)
        {
            enemy.ModifyActionPoints(-stacks);
        }
    }

    public override void End(GameObject target)
    {
        // 瞬时效果不注册持续实例，End 不会被调用（abstract 强制实现，保留空壳）
        Debug.Log($"{target.name} 的减少移动点效果结束");
    }
}

// =====================================================================
// ★2026-09-16 骰面上下限修正（设计页 R1 六条铁律的实装）
//
// 语义（R1）：
//   · 一卡一轴：同一张卡只改下限或只改上限，力量是第三条独立轴。
//   · 生效时点＝下一次掷骰：只影响**还没掷的骰**（重投/新抽的牌才吃到）。
//   · 暴击判据：结算生效值 ≥ 骰面原有最大值（d4 → ≥4）＝暴击；
//     下限钳到面值（d4 的 +3）＝必暴；上限抬高＝暴击率上升（阈值仍是 4，不跟着抬）。
//   · 未标「持续 N 回合」的 ＝ 一次性（下一次掷骰结算后消失）。
//
// 两类各两轴 = 4 个类：
//   一次性（ConsumeOnRoll）——架弩/瞄准/磨刀/磨斧/磨盾/踩点/蓄螯/上弦/孢囊膨胀/蛮劲
//   持续（回合衰减）    ——磨牙 2 回合 / 狼嚎 1 回合 / 号令 1 回合
// 层数即修正值（3 层 = 下限 +3）。
// =====================================================================

/// <summary>
/// 骰面下限修正（一次性）：掷骰后骰值至少为「面值最小值 + 层数」，钳到面值最大值。
/// d4 的 +3 ＝ 必然掷出 4 ＝ 下一击必暴。掷骰结算后本条自动消失。
/// </summary>
public class DiceFloorModifierEffect : Effect
{
    public DiceFloorModifierEffect()
    {
        Name = "骰面下限";
        Description = "下一次掷骰时骰子下限 +层数；结算后消失";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>一次性：掷骰结算后消耗（不走 OnTurnUpdate 衰减）</summary>
    public override bool ConsumeOnRoll => true;

    /// <summary>不按回合衰减 —— 施放回合末就衰减掉的话，施放者自身下一回合出牌永远吃不到。</summary>
    public override int OnTurnUpdate(GameObject target, int currentStacks) => currentStacks;

    public override void Apply(GameObject target, int stacks) { }
    public override void End(GameObject target) { }
}

/// <summary>骰面下限修正（持续）：效果同上，但按回合衰减（「持续 N 回合」的卡用）。</summary>
public class DiceFloorDurationEffect : Effect
{
    public DiceFloorDurationEffect()
    {
        Name = "骰面下限·持续";
        Description = "掷骰时骰子下限 +层数，每回合-1";
        TargetType = EffectTargetType.人物;
    }

    public override void Apply(GameObject target, int stacks) { }
    public override void End(GameObject target) { }
}

/// <summary>
/// 骰面上限修正（一次性）：掷骰后骰值 +层数，可超过面值最大值。
/// d4 的 +1 → 值域 1~5，掷出 4 或 5 都 ≥ 原面值最大值 4 → 暴击率 25%→50%（阈值不跟着抬）。
/// </summary>
public class DiceCeilModifierEffect : Effect
{
    public DiceCeilModifierEffect()
    {
        Name = "骰面上限";
        Description = "下一次掷骰时骰子上限 +层数；结算后消失";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>一次性：掷骰结算后消耗（不走 OnTurnUpdate 衰减）</summary>
    public override bool ConsumeOnRoll => true;

    /// <summary>不按回合衰减 —— 施放回合末就衰减掉的话，施放者自身下一回合出牌永远吃不到。</summary>
    public override int OnTurnUpdate(GameObject target, int currentStacks) => currentStacks;

    public override void Apply(GameObject target, int stacks) { }
    public override void End(GameObject target) { }
}

/// <summary>骰面上限修正（持续）：效果同上，但按回合衰减（「持续 N 回合」的卡用）。</summary>
public class DiceCeilDurationEffect : Effect
{
    public DiceCeilDurationEffect()
    {
        Name = "骰面上限·持续";
        Description = "掷骰时骰子上限 +层数，每回合-1";
        TargetType = EffectTargetType.人物;
    }

    public override void Apply(GameObject target, int stacks) { }
    public override void End(GameObject target) { }
}

/// <summary>
/// ★2026-09-16 骰面下限修正（姿态版）——强弩手「架弩」专用。
/// 与 <see cref="DiceFloorModifierEffect"/> 的区别只有两条：
///   ① <see cref="Effect.BreaksOnDamage"/> = true：持有者掉血 → 架子散，瞄准作废。
///   ② <see cref="Effect.ConsumeOnRoll"/> = false：**不**被掷骰消耗。
///      「掷骰即消耗」在这里会毁掉打断窗口——敌人攻击的骰子是在玩家回合开始时
///      就预掷锁死的（v2 §3.3），若预掷即吃掉姿态，玩家整回合都没有机会打断。
///      所以姿态的寿命是「架起来 → 直到挨打或出手」，出手时由
///      EffectManager.ClearStances 统一收架（见 EnemyTurnExecutor.ExecuteAction）。
/// 间隔不衰减：一次架弩跨一个敌人回合生效，按回合衰减会在吃到的前一晚就没了。
/// </summary>
public class DiceFloorStanceEffect : Effect
{
    public DiceFloorStanceEffect()
    {
        Name = "骰面下限·姿态";
        Description = "掷骰时骰子下限 +层数；自身掉血则立刻失效";
        TargetType = EffectTargetType.人物;
    }

    /// <summary>姿态不吃"掷骰即消耗"——见类注释②。</summary>
    public override bool ConsumeOnRoll => false;

    /// <summary>挨打掉血就散（打断窗口）。</summary>
    public override bool BreaksOnDamage => true;

    /// <summary>不按回合衰减：架起来要跨一个敌人回合才吃到兑现。</summary>
    public override int OnTurnUpdate(GameObject target, int currentStacks) => currentStacks;

    public override void Apply(GameObject target, int stacks) { }
    public override void End(GameObject target) { }
}

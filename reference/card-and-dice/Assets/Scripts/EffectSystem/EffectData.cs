using UnityEngine;

/// <summary>
/// 效果目标类型枚举
/// </summary>
public enum EffectTargetType
{
    人物,    // 施加于人物
    骰子     // 施加于骰子
}

/// <summary>
/// 效果施加时机枚举
/// </summary>
public enum EffectApplyTiming
{
    立即,    // 立即施加
    下回合    // 下回合施加
}

/// <summary>
/// 目标类型枚举
/// </summary>
public enum TargetType
{
    自身,
    跟随卡牌
}

/// <summary>
/// 效果基类
/// </summary>
public abstract class Effect
{
    /// <summary>
    /// 效果名称
    /// </summary>
    public string Name { get; protected set; }
    
    /// <summary>
    /// 效果描述
    /// </summary>
    public string Description { get; protected set; }
    
    /// <summary>
    /// 效果目标类型
    /// </summary>
    public EffectTargetType TargetType { get; protected set; }

    /// <summary>
    /// ★2026-08-19 瞬时效果语义（用户确认）：立即结算、不注册持续实例。
    /// true = Apply 一次算完就结束：不进 EffectManager.activeEffects（不叠加、
    /// 不在右侧面板/徽章显示、无回合衰减），如断筋扣移动点/生命回复/行动+AP。
    /// false = 持续状态效果（默认），注册后按 OnTurnUpdate 衰减，如护甲/虚弱/力量。
    /// </summary>
    public virtual bool IsInstant => false;

    /// <summary>
    /// ★2026-09-16 骰面修正一次性语义：true = 该效果在**下一次掷骰结算后被消耗**
    /// （不进 OnTurnUpdate 衰减）。只有骰面上下限修正的一次性版本覆写为 true；
    /// 其余效果默认 false，行为与改造前完全一致。
    /// </summary>
    public virtual bool ConsumeOnRoll => false;

    /// <summary>
    /// ★2026-09-16 姿态语义（架弩）：true = 效果在**持有者掉血**时立刻清除。
    /// 与 ConsumeOnRoll 的分工：那是"用掉就散"（掷骰消耗），这是"挨打就散"（受击打断）。
    /// 姿态给玩家一个可打断的窗口：强弩手架弩叠出「下一击必暴」，玩家把它打疼 →
    /// 架子散、瞄准作废，它还得回头重新架一次（意图回退，见 EnemyController.ConsumeStanceBroken）。
    /// 注：护甲吸收掉的不算「掉血」（TakeDamage 在护甲吃满时就 return 了），所以
    /// 「防御+4 但挨打失效」两者不冲突——血掉得下去时护甲必然已经归零。
    /// </summary>
    public virtual bool BreaksOnDamage => false;
    
    /// <summary>
    /// 效果图标
    /// </summary>
    public Sprite Icon { get; protected set; }
    
    /// <summary>
    /// 构造函数
    /// </summary>
    protected Effect()
    {
        // 自动加载图标
        LoadIcon();
    }
    
    /// <summary>
    /// 加载效果图标
    /// 从 Material/Effect 目录加载同名图片
    /// </summary>
    private void LoadIcon()
    {
        string iconPath = $"Material/Effect/{Name}";
        Icon = Resources.Load<Sprite>(iconPath);
    }
    
    /// <summary>
    /// 应用效果
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <param name="stacks">效果层数</param>
    public abstract void Apply(GameObject target, int stacks);
    
    /// <summary>
    /// 效果结束
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    public abstract void End(GameObject target);
    
    /// <summary>
    /// 每回合更新
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <param name="currentStacks">当前层数</param>
    /// <returns>更新后的层数</returns>
    public virtual int OnTurnUpdate(GameObject target, int currentStacks)
    {
        // 默认每回合层数减1
        return currentStacks - 1;
    }
    
    /// <summary>
    /// 计算效果强度
    /// </summary>
    /// <param name="stacks">效果层数</param>
    /// <returns>效果强度</returns>
    public virtual float GetEffectStrength(int stacks)
    {
        return stacks;
    }
}




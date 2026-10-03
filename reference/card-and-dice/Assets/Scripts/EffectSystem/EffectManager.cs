using UnityEngine;
using System.Collections.Generic;

/// <summary>
/// 效果实例类
/// </summary>
public class EffectInstance
{
    public Effect Effect { get; set; }
    public GameObject Target { get; set; }
    public int Stacks { get; set; }
    public bool IsActive { get; set; } = true;
    public bool IsPending { get; set; } = false; // 是否为下回合施加的效果
}

/// <summary>
/// 效果管理器
/// 负责处理效果的应用、持续和移除
/// </summary>
public class EffectManager : MonoBehaviour
{
    /// <summary>
    /// 单例实例
    /// </summary>
    public static EffectManager Instance { get; private set; }

    /// <summary>
    /// 所有活跃的效果实例
    /// </summary>
    private List<EffectInstance> activeEffects = new List<EffectInstance>();

    private void Awake()
    {
        // 确保单例
        if (Instance == null)
        {
            Instance = this;
            DontDestroyOnLoad(gameObject);
        }
        else
        {
            Destroy(gameObject);
        }
    }

    /// <summary>
    /// 应用效果到目标
    /// </summary>
    /// <param name="effect">效果实例</param>
    /// <param name="target">目标游戏对象</param>
    /// <param name="stacks">效果层数</param>
    /// <param name="timing">施加时机</param>
    public void ApplyEffect(Effect effect, GameObject target, int stacks, EffectApplyTiming timing)
    {
        if (effect == null || target == null || stacks <= 0)
            return;

        Debug.Log($"应用效果: {effect.Name} 到 {target.name}, 层数: {stacks}, 时机: {timing}");

        // ★2026-08-19 瞬时效果（IsInstant）：立即结算一次就完，不注册持续实例——
        // 不叠加层数、不进 UI（右侧面板/徽章）、无回合衰减。
        // 修复 bug：断筋「减少移动点2」此前注册后 OnTurnUpdate 不衰减，回合结束
        // 仍挂在面板上永不消失（用户反馈）。瞬时效果本就「不算一个效果」（用户确认）。
        if (effect.IsInstant)
        {
            effect.Apply(target, stacks);
            return;
        }

        // 检查是否已有相同效果
        EffectInstance existingInstance = null;
        foreach (var instance in activeEffects)
        {
            if (instance.Effect.GetType() == effect.GetType() && instance.Target == target && instance.IsActive)
            {
                existingInstance = instance;
                break;
            }
        }

        if (existingInstance != null)
        {
            // 叠加层数
            existingInstance.Stacks += stacks;
            Debug.Log($"效果叠加: {effect.Name} 层数变为: {existingInstance.Stacks}");
        }
        else
        {
            // 创建新效果实例
            EffectInstance newInstance = new EffectInstance
            {
                Effect = effect,
                Target = target,
                Stacks = stacks,
                IsPending = (timing == EffectApplyTiming.下回合)
            };

            // 立即施加的效果
            if (timing == EffectApplyTiming.立即)
            {
                effect.Apply(target, stacks);
            }

            // 添加到活跃效果列表
            activeEffects.Add(newInstance);
        }
    }

    /// <summary>
    /// 处理回合开始时的效果
    /// </summary>
    public void OnTurnStart()
    {
        // 处理下回合施加的效果
        List<EffectInstance> instantToResolve = null; // ★瞬时效果结算后待移除
        foreach (var instance in activeEffects)
        {
            if (instance.IsPending)
            {
                instance.Effect.Apply(instance.Target, instance.Stacks);
                instance.IsPending = false;
                Debug.Log($"下回合效果生效: {instance.Effect.Name} 到 {instance.Target.name}");

                // ★2026-08-19 瞬时效果结算完毕即移除，不留在持续列表（防残留）
                if (instance.Effect.IsInstant)
                {
                    instantToResolve = instantToResolve ?? new List<EffectInstance>();
                    instantToResolve.Add(instance);
                }
            }
        }

        if (instantToResolve != null)
        {
            foreach (var instance in instantToResolve)
            {
                activeEffects.Remove(instance);
            }
        }
    }

    /// <summary>
    /// 处理回合结束时的效果
    /// </summary>
    public void OnTurnEnd()
    {
        List<EffectInstance> effectsToRemove = new List<EffectInstance>();

        foreach (var instance in activeEffects)
        {
            if (!instance.IsActive || instance.IsPending)
                continue;

            // 每回合更新
            int newStacks = instance.Effect.OnTurnUpdate(instance.Target, instance.Stacks);
            instance.Stacks = newStacks;

            // 检查效果是否结束
            if (instance.Stacks <= 0)
            {
                effectsToRemove.Add(instance);
            }
        }

        // 移除结束的效果
        foreach (var instance in effectsToRemove)
        {
            EndEffect(instance);
        }
    }

    /// <summary>
    /// 结束效果
    /// </summary>
    /// <param name="instance">效果实例</param>
    private void EndEffect(EffectInstance instance)
    {
        Debug.Log($"效果结束: {instance.Effect.Name} 从 {instance.Target.name}");
        
        // 执行效果结束逻辑
        instance.Effect.End(instance.Target);
        
        // 从活跃效果列表中移除
        activeEffects.Remove(instance);
    }

    /// <summary>
    /// 获取目标上的所有效果
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <returns>目标上的效果列表</returns>
    public List<EffectInstance> GetEffectsOnTarget(GameObject target)
    {
        List<EffectInstance> targetEffects = new List<EffectInstance>();
        
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.IsActive)
            {
                targetEffects.Add(instance);
            }
        }
        
        return targetEffects;
    }

    /// <summary>
    /// 移除目标上的所有效果
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    public void RemoveAllEffectsFromTarget(GameObject target)
    {
        List<EffectInstance> effectsToRemove = new List<EffectInstance>();
        
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target)
            {
                effectsToRemove.Add(instance);
            }
        }
        
        foreach (var instance in effectsToRemove)
        {
            EndEffect(instance);
        }
    }

    /// <summary>
    /// 移除目标上的特定类型效果
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <param name="effectTypeName">效果类型名称</param>
    public void RemoveEffectsOfTypeFromTarget(GameObject target, string effectTypeName)
    {
        List<EffectInstance> effectsToRemove = new List<EffectInstance>();
        
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.Effect.GetType().Name == effectTypeName)
            {
                effectsToRemove.Add(instance);
            }
        }
        
        foreach (var instance in effectsToRemove)
        {
            EndEffect(instance);
        }
    }

    /// <summary>
    /// 获取目标身上活跃效果实例数（★2026-09-05 偷袭检测用：数量增加 = 被施加了新状态）。
    /// </summary>
    public int GetActiveEffectCount(GameObject target)
    {
        int count = 0;
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.IsActive) count++;
        }
        return count;
    }

    /// <summary>
    /// 获取目标上的特定效果层数
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <param name="effectTypeName">效果类型名称</param>
    /// <returns>效果层数</returns>
    public int GetEffectStacks(GameObject target, string effectTypeName)
    {
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.Effect.GetType().Name == effectTypeName && instance.IsActive)
            {
                return instance.Stacks;
            }
        }
        return 0;
    }

    /// <summary>
    /// ★2026-09-16 骰面上下限修正查询（设计页 R1「骰面语言」）：
    /// 汇总目标身上所有骰面修正效果的层数——下限/上限各一路，一次性与持续版相加
    /// （两者是不同 Effect 类型，各自独立叠加；可同时存在，如持续在身时再补一张一次性）。
    /// 待施加（IsPending）的不算：下回合才生效。
    /// </summary>
    /// <param name="target">目标游戏对象（持卡人 / 掷骰者）</param>
    /// <param name="floorBonus">骰子下限加成（无修正为 0）</param>
    /// <param name="ceilBonus">骰子上限加成（无修正为 0）</param>
    public void GetDiceFaceModifiers(GameObject target, out int floorBonus, out int ceilBonus)
    {
        floorBonus = 0;
        ceilBonus = 0;
        if (target == null) return;

        foreach (var instance in activeEffects)
        {
            if (instance.Target != target || !instance.IsActive || instance.IsPending) continue;

            if (instance.Effect is DiceFloorModifierEffect || instance.Effect is DiceFloorDurationEffect
                || instance.Effect is DiceFloorStanceEffect)
                floorBonus += instance.Stacks;
            else if (instance.Effect is DiceCeilModifierEffect || instance.Effect is DiceCeilDurationEffect)
                ceilBonus += instance.Stacks;
        }
    }

    /// <summary>
    /// ★2026-09-16 清除目标身上全部「姿态」效果（<see cref="Effect.BreaksOnDamage"/> == true），
    /// 触发 Effect.End 并返回清除的实例数。两个调用点，语义都是「架势散了」：
    ///   ① 持有者掉血 —— EnemyController.TakeDamage（挨打 → 打断，配合意图回退）
    ///   ② 持有者出手 —— EnemyTurnExecutor.ExecuteAction 出牌成功后（一出手就收架）
    /// 护甲吸收掉的不算掉血（TakeDamage 在护甲吃满时提前 return），所以 +4 护甲
    /// 恰好就是「要打断这个架势，你得打得动它」的门槛。
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <param name="reason">日志用原因（"受击" / "出手"）</param>
    /// <returns>被清除的姿态实例数（无姿态为 0）</returns>
    public int ClearStances(GameObject target, string reason)
    {
        if (target == null) return 0;

        List<EffectInstance> toRemove = null;
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.IsActive && instance.Effect.BreaksOnDamage)
            {
                toRemove = toRemove ?? new List<EffectInstance>();
                toRemove.Add(instance);
            }
        }

        if (toRemove == null) return 0;

        foreach (var instance in toRemove)
        {
            Debug.Log($"[姿态] {target.name} 的 {instance.Effect.Name}({instance.Stacks}) 散了（{reason}）");
            EndEffect(instance);
        }
        return toRemove.Count;
    }

    /// <summary>
    /// ★2026-09-16 掷骰结算后消耗一次性骰面修正（<see cref="Effect.ConsumeOnRoll"/> == true 的实例，触发 Effect.End）。
    /// 由 <see cref="Card"/> 的三个掷骰入口在应用修正后调用；持续版（Duration 系列）不受影响，走 OnTurnUpdate 衰减。
    /// </summary>
    /// <param name="target">目标游戏对象（持卡人 / 掷骰者）</param>
    public void ConsumeRollModifiers(GameObject target)
    {
        if (target == null) return;

        List<EffectInstance> toRemove = null;
        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.IsActive && instance.Effect.ConsumeOnRoll)
            {
                toRemove = toRemove ?? new List<EffectInstance>();
                toRemove.Add(instance);
            }
        }

        if (toRemove != null)
        {
            foreach (var instance in toRemove)
            {
                Debug.Log($"[骰面修正] 一次性修正 {instance.Effect.Name}({instance.Stacks}) 已消耗于 {target.name}");
                EndEffect(instance);
            }
        }
    }

    /// <summary>
    /// ★2026-09-14 护甲整体清算：清掉目标身上全部护甲层数并移除实例（触发 Effect.End）。
    /// 调用时机由「持有者自己的回合开始」决定（见 ArmorEffect 类注释）：
    ///   玩家 → TurnManager.StartNewTurn；敌人 → TurnManager.EnemyTurn 开头。
    /// 与 <see cref="ReduceEffectStacks"/> 的区别：那里是「受击按吸收量扣减」，
    /// 这里是「回合开始不计伤的整体清零」。
    /// </summary>
    /// <param name="target">目标游戏对象（玩家根物体 / 敌人根物体）</param>
    /// <returns>被清掉的护甲总层数（目标无护甲时返回 0）</returns>
    public int ClearArmor(GameObject target)
    {
        if (target == null) return 0;

        int cleared = 0;
        List<EffectInstance> toRemove = null;

        foreach (var instance in activeEffects)
        {
            if (instance.Target != target || !instance.IsActive) continue;
            if (!(instance.Effect is ArmorEffect)) continue;

            cleared += instance.Stacks;
            toRemove = toRemove ?? new List<EffectInstance>();
            toRemove.Add(instance);
        }

        if (toRemove != null)
        {
            foreach (var instance in toRemove)
            {
                EndEffect(instance);
            }
        }

        return cleared;
    }

    /// <summary>
    /// ★2026-09-14 玩家护甲清算（战斗/探索两个回合管理器共用）。
    /// 目标 = 场景唯一 `HexMover` 所在物体（= 玩家根物体，与 PlayCardSystem.GetPlayerRoot()
    /// 施加护甲的对象同源；敌人不挂 HexMover，见 MovePointReductionEffect 的敌人分支）。
    /// 调用点：`TurnManager.StartNewTurn`（战斗玩家回合开始）/ `ExplorationTurnManager.StartNewExplorationTurn`
    /// （探索回合 = 玩家回合开始）。进战斗的第一回合由 TurnManager 传 preserve 跳过，见 BeginBattleFromExploring。
    /// </summary>
    /// <returns>被清掉的护甲层数（无护甲/无玩家时 0）</returns>
    public static int ClearPlayerArmor()
    {
        if (Instance == null) return 0;

        // ★2026-09-16 性能二批：改走缓存玩家（原 FindObjectOfType<HexMover> 全场景扫 ≈3–4ms/回合开始）
        HexMover mover = ExplorationPerf.Player;
        if (mover == null) return 0;

        int cleared = Instance.ClearArmor(mover.gameObject);
        if (cleared > 0)
        {
            Debug.Log($"[护甲] 玩家回合开始 → {mover.gameObject.name} 护甲清零（-{cleared}）");
        }
        return cleared;
    }

    /// <summary>
    /// ★M5b-3（2026-08-18）：减少目标上的特定效果层数（护甲受击扣减用）。
    /// 层数归零自动移除该效果实例（触发 Effect.End）。
    /// </summary>
    /// <param name="target">目标游戏对象</param>
    /// <param name="effectTypeName">效果类型名称（类名，如 "ArmorEffect"）</param>
    /// <param name="amount">减少的层数（负数忽略）</param>
    /// <returns>实际减少的层数（无该效果时为 0）</returns>
    public int ReduceEffectStacks(GameObject target, string effectTypeName, int amount)
    {
        if (amount <= 0) return 0;

        foreach (var instance in activeEffects)
        {
            if (instance.Target == target && instance.Effect.GetType().Name == effectTypeName && instance.IsActive)
            {
                int actual = Mathf.Min(instance.Stacks, amount);
                instance.Stacks -= actual;

                if (instance.Stacks <= 0)
                {
                    EndEffect(instance);
                }
                return actual;
            }
        }
        return 0;
    }
}



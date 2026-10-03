// =============================================================================
// 模块：M5a 玩家血量数据源 PlayerHealth
// 用途：玩家 HP 运行时数据源，供左上角血量显示（x/x）及后续战斗模块订阅。
// 设计依据：《设计增补_公式与调优旋钮.md》F4.3 最大生命值
//   maxHp = baseHp + floor(conBonus * conHpCoef) + levelBonus
// Demo 初值锁定：baseHp = 30（战士），暂无体质/等级加成，见 project_rules.md
// Demo 阶段：仅提供数据源与受击/治疗接口，战斗扣血逻辑 M6 再补。
// =============================================================================
using System;
using UnityEngine;

/// <summary>
/// 玩家血量数据源。
/// 挂载到 Player 对象上，供 StatusBarManager（左上角 血量 x/x）等 UI 订阅。
/// </summary>
public class PlayerHealth : MonoBehaviour
{
    [Header("数据")]
    [Tooltip("角色基础 HP（Demo 锁定战士 30，公式 F4.3 baseHp）")]
    [SerializeField] private int baseHp = 30;

    /// <summary>当前 HP（运行时初始化）</summary>
    [SerializeField] private int currentHP;

    /// <summary>当前 HP（只读外部访问）</summary>
    public int CurrentHP => currentHP;

    /// <summary>最大 HP（F4.3 baseHp）。★2026-09-14：藏身处「最大生命」数值强化已删除，无跨局加值。</summary>
    public int MaxHP => baseHp;

    /// <summary>是否已死亡</summary>
    public bool IsDead { get; private set; } = false;

    /// <summary>
    /// 血量变化事件。参数 (当前HP, 最大HP)
    /// 供左上角血量显示 / 脚下血条订阅
    /// </summary>
    public event Action<int, int> OnHPChanged;

    private void Awake()
    {
        // 初始化当前 HP 为最大 HP（含藏身处强化加值）
        currentHP = MaxHP;
    }

    /// <summary>
    /// 玩家受击。
    /// ★M5b-3（2026-08-18）：先扣护甲（1层挡1点，EffectManager 管理，防御卡施加），
    /// 剩余伤害直接扣血（Demo 无防御属性减伤，玩家减伤由 M6 战斗接入）。
    /// </summary>
    /// <param name="rawDamage">原始伤害（>0 才生效）</param>
    /// <returns>实际扣除的 HP</returns>
    public int TakeDamage(int rawDamage)
    {
        if (IsDead || rawDamage <= 0) return 0;

        // ===== 1. 护甲扣减（1 层护甲挡 1 点伤害，按吸收量减层）=====
        int remaining = rawDamage;
        if (EffectManager.Instance != null)
        {
            int armor = EffectManager.Instance.GetEffectStacks(gameObject, "ArmorEffect");
            if (armor > 0)
            {
                int absorbed = EffectManager.Instance.ReduceEffectStacks(gameObject, "ArmorEffect", remaining);
                remaining -= absorbed;
                Debug.Log($"[PlayerHealth] 护甲吸收 {absorbed} 点，剩余伤害 {remaining}");
            }
        }
        if (remaining <= 0) return 0; // 全被护甲吸收，不掉血

        int oldHP = currentHP;
        currentHP = Mathf.Max(0, currentHP - remaining);

        Debug.Log($"[PlayerHealth] 受击：rawDamage={rawDamage}, HP {oldHP}→{currentHP}");

        // 广播血量变化（供 UI 刷新）
        OnHPChanged?.Invoke(currentHP, MaxHP);

        if (currentHP <= 0 && !IsDead)
        {
            Die();
        }

        return oldHP - currentHP;
    }

    /// <summary>
    /// 治疗玩家。
    /// </summary>
    public void Heal(int amount)
    {
        if (IsDead || amount <= 0) return;

        int oldHP = currentHP;
        currentHP = Mathf.Min(baseHp, currentHP + amount);
        OnHPChanged?.Invoke(currentHP, MaxHP);
    }

    /// <summary>
    /// 死亡处理：标记死亡并通知 BattleResultHandler（Demo 重载场景）。
    /// </summary>
    private void Die()
    {
        IsDead = true;
        Debug.Log("[PlayerHealth] 玩家死亡");
        if (BattleResultHandler.Instance != null)
        {
            BattleResultHandler.Instance.NotifyPlayerDied();
        }
    }
}
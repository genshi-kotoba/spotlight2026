// =============================================================================
// 模块：M6 敌人系统 - EnemySquadData 敌人小队
// 用途：地图上生成的永远是「敌人小队」。小队 = 编队模板 + 成员（预设 + 微调 + 站位）
// 设计依据：《设计增补_敌人系统_v2.md》§6 敌人小队
// ★2026-08-19 M6-6 序列化修复：原实现用 int?/CombatRole? 等可空类型表达「可空=沿用预设」，
//   但 Unity 序列化器不认 Nullable——Inspector 完全不显示、也不存盘，覆盖功能形同虚设。
//   现改为 Unity 标准的「勾选框 + 值」模式（OptInt 结构 / bool+字段），语义不变：
//   勾选 = 覆盖预设；不勾 = 沿用预设。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>编队角色（用于小队自动摆位 + ★2026-08-21 敌人回合行动顺序）。
/// 设计依据：v2 §6.1。★2026-08-19 中文化（原 Melee/Ranged/...）。
/// ★2026-08-23 角色体系重构：刺客→先锋、近战→近卫、远程→狙击，新增术士，删除驻守
/// （驻守改为 movePreset 概念，不再属于 combatRole）。
/// 行动顺序 = 枚举顺序：先锋(0) → 近卫(1) → 狙击(2) → 术士(3) → 辅助(4)。</summary>
public enum CombatRole { 先锋, 近卫, 狙击, 术士, 辅助 }

/// <summary>编队模板（一键摆位）。设计依据：v2 §6.3。★2026-08-19 中文化（原 Clump/Line/...）。</summary>
public enum FormationType { 聚拢, 横排, 楔形, 方阵, 散开 }

/// <summary>
/// 可选整数（Unity 序列化友好的「可空 int」）：
/// on=true 时 value 生效（覆盖预设），on=false 时忽略 value（沿用预设）。
/// </summary>
[Serializable]
public struct OptInt
{
    [Tooltip("勾选 = 覆盖预设值")]
    public bool on;
    [Tooltip("覆盖值（勾选时生效）")]
    public int value;
}

/// <summary>
/// 小队成员 = 敌人预设 + 微调覆盖 + 初始站位。
/// 覆盖规则：勾选/有内容 = 覆盖预设；不勾/空 = 沿用预设。设计依据：v2 §6.1。
/// </summary>
[Serializable]
public class EnemyUnitConfig
{
    [Tooltip("敌人预设（必填，成员的基础数据来源）")]
    public EnemyData preset;

    [Header("数值覆盖（勾选=覆盖预设）")]
    [Tooltip("血量区间下限覆盖")]
    public OptInt hpMinOverride;
    [Tooltip("血量区间上限覆盖")]
    public OptInt hpMaxOverride;

    [Tooltip("移动力覆盖")]
    public OptInt moveRangeOverride;
    [Tooltip("视野覆盖")]
    public OptInt visionRangeOverride;

    [Header("模块覆盖（勾选=覆盖预设）")]
    [Tooltip("编队角色覆盖（影响自动摆位）")]
    public bool overrideCombatRole;
    [Tooltip("编队角色（勾选覆盖时生效）")]
    public CombatRole combatRole;

    [Tooltip("意图循环覆盖（大意图 if-else 链，勾选且列表非空时生效）")]
    public bool overrideIntentLoop;
    [Tooltip("意图循环（勾选覆盖时生效）")]
    public List<EnemyBigIntent> intentLoop;

    [Tooltip("移动预设覆盖")]
    public bool overrideMovePreset;
    [Tooltip("移动预设（勾选覆盖时生效）")]
    public MoveAIPresetType movePreset;

    [Tooltip("移动参数覆盖")]
    public bool overrideMoveParams;
    [Tooltip("移动参数（勾选覆盖时生效）")]
    public MoveParams moveParams;

    [Tooltip("被动技能覆盖（勾选且列表非空时生效）")]
    public bool overridePassives;
    [Tooltip("被动技能列表（勾选覆盖时生效）")]
    public List<PassiveData> passives;

    [Header("初始站位")]
    [Tooltip("相对小队锚点的六边形偏移（奇偶 q/r 坐标，默认 0,0）。可用「按编队模板自动填」一键生成")]
    public Vector2Int hexOffset;

    // ------------------------------------------------------------------
    // 便捷读取（供 SpawnResolver / 编辑器预览统一取「生效值」）
    // ------------------------------------------------------------------

    /// <summary>生效编队角色：勾选覆盖用覆盖值，否则用预设值（无预设兜底近卫）。</summary>
    public CombatRole EffectiveRole
    {
        get
        {
            if (overrideCombatRole) return combatRole;
            if (preset != null) return preset.combatRole;
            return CombatRole.近卫;
        }
    }
}

/// <summary>
/// 敌人小队数据。地图生成单位 = 小队（想单怪 = 只有 1 个成员的小队）。
/// 设计依据：v2 §6。
/// </summary>
[CreateAssetMenu(fileName = "NewSquad", menuName = "卡牌与骰子/敌人小队", order = 13)]
public class EnemySquadData : ScriptableObject
{
    [Tooltip("小队唯一标识（自动生成）")]
    public string squadID;

    [Tooltip("小队显示名")]
    public string squadName = "新小队";

    [Tooltip("编队模板（一键摆位：按成员编队角色自动填 hexOffset）")]
    public FormationType formation = FormationType.聚拢;

    [Tooltip("小队成员列表")]
    public List<EnemyUnitConfig> units = new List<EnemyUnitConfig>();

    // ------------------------------------------------------------------
    // ★2026-09-12 掉落配置（design：docs/2026-09-12_小队掉落编辑-design.md）
    // 小队模板级默认掉落：正式图「随机遭遇」是运行期用本模板现拼巡逻的，
    // 没有巡逻资产可编辑 → 配置的家在这里；巡逻资产 dropConfig 成员表非空 = 覆盖本配置。
    // ------------------------------------------------------------------
    [Tooltip("本小队的默认掉落配置（小队级三选一稀有度 + 成员级灵魂/材料/卡池）。在 Inspector 下方编辑")]
    public SquadDropConfig dropConfig = new SquadDropConfig();

    private void OnEnable()
    {
        if (string.IsNullOrEmpty(squadID))
        {
            squadID = "SQUAD_" + System.DateTime.Now.ToString("HHmmss");
        }
    }
}

// =============================================================================
// 模块：M6 敌人系统 - EnemyData ScriptableObject（v2 重构）
// 用途：定义敌人静态属性数据，作为 EnemyController 的数据源
// 设计依据：《设计增补_敌人系统_v2.md》§2 敌人数据模型（D8：砍掉攻击力/防御力）
// 职责边界：只存静态数据，不含行为逻辑与运行时状态（运行时状态在 EnemyController）
// 核心变更（v2）：
//   - 删除 attack / defense 字段（伤害/护甲全部住在意图卡牌里）
//   - maxHP 改为血量区间 hpMin/hpMax（生成时闭区间随机，制造个体差异）
//   - 新增：combatRole / sprintValue / sprintMax / prefab / intentLoop /
//           movePreset / moveParams / passives（四正交模块拼装）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人静态数据 ScriptableObject。
/// 通过菜单 `卡牌与骰子/敌人数据` 创建实例，存放在 Assets/Data/Enemies/ 目录下。
/// 敌人由四正交模块拼装：数值（本类）/ 意图循环（intentLoop）/ 移动预设（movePreset）
/// / 被动技能（passives），彼此解耦。设计依据：v2 §1。
/// </summary>
[CreateAssetMenu(fileName = "NewEnemy", menuName = "卡牌与骰子/敌人数据", order = 11)]
public class EnemyData : ScriptableObject
{
    // ------------------------------------------------------------------
    // 基础信息
    // ------------------------------------------------------------------
    [Header("基础信息")]
    [Tooltip("敌人唯一标识符（自动生成，格式 ENEMY_时间戳）")]
    public string enemyID;

    [Tooltip("敌人显示名称")]
    public string enemyName = "新敌人";

    // ------------------------------------------------------------------
    // 数值（无攻防！伤害/护甲全部住在意图卡牌里）
    // ------------------------------------------------------------------
    [Header("数值（无攻防，伤害/护甲在意图卡牌里）")]
    [Tooltip("血量区间下限（生成时在 [hpMin, hpMax] 闭区间随机。哥布林建议 [12,16]）")]
    [Range(1, 999)]
    public int hpMin = 10;

    [Tooltip("血量区间上限（生成时在 [hpMin, hpMax] 闭区间随机）")]
    [Range(1, 999)]
    public int hpMax = 14;

    [Tooltip("基础移动力 = 行动点")]
    [Range(0, 20)]
    public int moveRange = 3;

    [Tooltip("视野范围（★脱战规则 2026-09-05：敌人回合移毕仍无任何敌人视野覆盖玩家 → 脱战，" +
             "即有效追击范围 = 敌人每回合移动力 + visionRange 的动态过程，不再用固定 +2 圈）")]
    [Range(0, 20)]
    public int visionRange = 3;

    // ------------------------------------------------------------------
    // 探索态巡逻（D13b，2026-09-05 定稿：探索态敌人常态巡逻/追击巡逻）
    // ------------------------------------------------------------------
    [Tooltip("巡逻行动点（无 SquadPatrols 路径时的单怪随机游走步数；有巡逻布局时用布局上的队速）")]
    [Range(0, 5)]
    public int patrolAP = 2;

    [Tooltip("普通巡逻半径（出生点附近随机游走的范围，格）")]
    [Range(0, 6)]
    public int patrolRadius = 2;

    [Tooltip("搜索牵绳半径（黄`?`散开搜索时离扇形顶点 LastSeenCoord/陷阱格的最大格数；" +
             "超限则该敌人本回合改为朝顶点归队，不再外扩）。" +
             "同时是散开扇形的圈层半径封顶：外圈 = min(步距+1, 本值)、内圈 = min(max(2, 步距−1), 本值)。" +
             "★嫌敌人散得不够开就抬这个值，不是抬行动点。设计依据：威胁预告与搜索 §13")]
    [Range(0, 12)]
    public int searchLeashRadius = 6;

    [Tooltip("编队角色（用于小队自动摆位，可被小队成员覆盖）")]
    public CombatRole combatRole = CombatRole.近卫;

    // ------------------------------------------------------------------
    // 疾跑（通用反风筝兜底，按怪配置）
    // ------------------------------------------------------------------
    [Header("疾跑（通用兜底，按怪配置）")]
    [Tooltip("★2026-08-19 用户需求：疾跑通用兜底开关。勾选=所有意图都不可用时累积追击值（下回合移动力+）；不勾=该怪不能疾跑（如站桩怪/BOSS），无可用意图时只按预设移动、什么都不做")]
    public bool canSprint = true;

    [Tooltip("单次疾跑数值（疾跑时追击值 +sprintValue，仅 canSprint 勾选时生效）")]
    [Range(1, 20)]
    public int sprintValue = 1;

    [Tooltip("疾跑最大值（追击值封顶，仅 canSprint 勾选时生效）")]
    [Range(1, 20)]
    public int sprintMax = 3;

    // ------------------------------------------------------------------
    // 掉落物
    // ★2026-09-12 迁移：掉落明细（材料/区间/卡池/出卡率/三选一卡池）已全部迁到
    //   SquadPatrolData.dropConfig 的 Inspector 面板；本资产只剩「默认灵魂」一个字段，
    //   供成员配置的「沿用预设」模式读取。设计依据：docs/2026-09-12_小队掉落编辑-design.md
    // ------------------------------------------------------------------
    [Header("掉落物")]
    [Tooltip("专属灵魂物品（每次击杀产一条，走战后结算弹窗入魂灯，不进遗物袋）。留空 = 该敌人不产灵魂")]
    public ItemData soulItem;

    // ------------------------------------------------------------------
    // 视觉资源
    // ------------------------------------------------------------------
    [Header("视觉资源")]
    [Tooltip("敌人头像/图标（用于战斗 UI，可空）")]
    public Sprite icon;

    [Tooltip("场景实体预制体（原「Cube 根 Y=0.5」结构的预制体化，可空）")]
    public GameObject prefab;

    // ------------------------------------------------------------------
    // 意图循环（核心新增）
    // ------------------------------------------------------------------
    [Header("意图循环（大意图 if-else 链）")]
    [Tooltip("有序大意图列表，一个大意图 = 一个回合")]
    public List<EnemyBigIntent> intentLoop = new List<EnemyBigIntent>();

    // ------------------------------------------------------------------
    // 移动预设（核心新增）
    // ------------------------------------------------------------------
    [Header("移动预设")]
    [Tooltip("行为逻辑类型（决定每回合怎么走）")]
    public MoveAIPresetType movePreset = MoveAIPresetType.本能;

    [Tooltip("该预设的参数（见 MoveParams）")]
    public MoveParams moveParams = new MoveParams();

    // ------------------------------------------------------------------
    // 被动技能（核心新增）
    // ------------------------------------------------------------------
    [Header("被动技能（效果集合）")]
    [Tooltip("开局拥有的被动技能列表（白板之上的加成）")]
    public List<PassiveData> passives = new List<PassiveData>();

    [Header("灵魂装置产出池")]
    [Tooltip("该怪可被「灵魂提取装置」抽出的卡牌配方全集（构建器从内容表 loot 落）。池剩余 = 它 − MetaWallet.unlockedRecipes")]
    public List<CardData> lootCards = new List<CardData>();

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    private void OnEnable()
    {
        if (string.IsNullOrEmpty(enemyID))
        {
            GenerateUniqueID();
        }
    }

    /// <summary>生成唯一 ID，格式：ENEMY_时间戳后6位</summary>
    public void GenerateUniqueID()
    {
        string timestamp = System.DateTime.Now.ToString("HHmmss");
        enemyID = "ENEMY_" + timestamp;
    }

    private void OnValidate()
    {
        if (hpMin < 1) hpMin = 1;
        if (hpMax < hpMin) hpMax = hpMin;
        if (moveRange < 0) moveRange = 0;
        if (visionRange < 0) visionRange = 0;
        if (sprintValue < 1) sprintValue = 1;
        if (sprintMax < 1) sprintMax = 1;
    }

    /// <summary>
    /// 生成时血量在 [hpMin, hpMax] 闭区间随机。
    /// 注意：Random.Range(int,int) 上界开区间，故 +1。设计依据：v2 §16-5。
    /// </summary>
    public int RollHP()
    {
        return UnityEngine.Random.Range(hpMin, hpMax + 1);
    }
}
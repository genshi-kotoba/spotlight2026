// =============================================================================
// 模块：探索系统 - 事件模板数据 EventData
// 用途：事件的 ScriptableObject 模板（类比 EnemyData / CardData），
//       定义「标题 + 描述 + 选项列表」，每个选项可带四阶梯鉴定（探索系统 v2 §7.5）。
// 设计依据：《设计增补_探索系统_v2.md》§7.5 事件模板 / D15 通用弹窗
// 资产位置：Assets/Data/Events/（由事件编辑器 EventEditorWindow 创建管理）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 鉴定类型（§7.1）：对应四花色属性。无 = 此选项不需要鉴定（直接结算）。
/// 运气 = 纯赌注（design §4.6 赌摊「押大/押小」）：照常投骰、照常烧 1 探索骰，
/// 但**不吃任何属性基础分与弃牌加成**（映射到 <see cref="SuitOption.无"/>，
/// 两个点数统计接口对「无」恒返回 0）→ 目标值就是 D 本身，掷出 d6 ≥ D 即成功。
/// </summary>
public enum CheckType
{
    无,
    力量, // 红色
    敏捷, // 绿色
    智力, // 蓝色
    体质, // 黄色
    运气  // 纯 d6 ≥ D（无属性）
}

/// <summary>
/// 事件池群系标签（design §3.1）。取值**刻意与 <see cref="WastelandGenerator.BiomeId"/> 数值对齐**
/// （通用 = -1 表示无群系）。群系名用代码口径（B6 = Swamp = 「沼泽」）。
/// </summary>
public enum BiomeTag
{
    通用 = -1,   // 无群系（草坡人味池，design §5.2）
    草坡 = 0,    // BiomeId.Grass —— 设计上不用（草坡格 100% 抽通用池）
    密林 = 1,    // BiomeId.Jungle
    洞穴 = 2,    // BiomeId.Cave
    废墟 = 3,    // BiomeId.Ruins
    古林 = 4,    // BiomeId.AncientForest
    沼泽 = 5,    // BiomeId.Swamp
    荒村 = 6     // BiomeId.WildVillage
}

/// <summary>
/// 事件模板（SO）。一次事件 = 一个 EventData 资产。
/// 放置方式：地图格子 GameObject 挂 EventTile 组件引用本资产（§7.5 触发）。
/// </summary>
[CreateAssetMenu(fileName = "新事件", menuName = "CardDice/事件模板")]
public class EventData : ScriptableObject
{
    [Header("基本信息")]
    [Tooltip("事件唯一标识（自动生成用文件名即可）")]
    public string eventId;

    [Tooltip("事件标题（弹窗顶部显示）")]
    public string title = "新事件";

    [TextArea(3, 8)]
    [Tooltip("事件描述（弹窗正文，支持多行）")]
    public string description = "事件描述";

    [Tooltip("一次性事件：触发后本局不再触发；否则每次落点都触发")]
    public bool once = true;

    [Tooltip("事件池群系标签（design §3.1）。通用 = 草坡人味池；投放按标签分池")]
    public BiomeTag biomeTag = BiomeTag.通用;

    [Header("选项列表（至少 1 个）")]
    [Tooltip("玩家可选项。每个选项可带鉴定（checkType≠无）或直接结算（checkType=无）")]
    public List<EventOption> options = new List<EventOption>();
}

/// <summary>
/// 事件选项。checkType=无 → 直接走 success 结果；否则走四阶梯鉴定（§7.1-§7.4）。
/// </summary>
[System.Serializable]
public class EventOption
{
    [Tooltip("选项按钮文案")]
    public string optionText = "选项";

    [Header("鉴定配置（checkType=无 时下方忽略）")]
    [Tooltip("鉴定类型：无=不鉴定直接成功")]
    public CheckType checkType = CheckType.无;

    [Tooltip("目标难度 D（§7.2：d6 ≥ D - 基础分 - 战术加成 - 弃牌干预 则成功）")]
    public int difficulty = 4;

    [Header("代价（design §3.2：付物换利）")]
    [Tooltip("要付出才可选本选项。空 = 免费。确认的那一刻扣，鉴定失败不退")]
    public List<EventItemCost> costs = new List<EventItemCost>();

    [Header("结果")]
    [Tooltip("鉴定成功 / 直接结算的结果")]
    public EventResult success;

    [Tooltip("鉴定失败的结果（checkType=无 时不会用到）")]
    public EventResult failure;
}

/// <summary>
/// 事件选项的物品代价（design §3.2）。指定 item 优先；anyOfType=true 时按 ItemType 在全背包清点
/// （材料 / 消耗品的多格合计）。
/// </summary>
[System.Serializable]
public class EventItemCost
{
    [Tooltip("指定物品（填了它且 anyOfType=false → 只认这个物品）")]
    public ItemData item;

    [Tooltip("按类型计：任意该类型物品皆可")]
    public bool anyOfType;

    [Tooltip("anyOfType=true 时生效的类型")]
    public ItemType type = ItemType.材料;

    [Tooltip("需要付出的数量")]
    public int amount = 1;
}

/// <summary>
/// 事件结果（奖励/惩罚）。Demo 只落地文案 + 数值变化；addCards 先记录待接入。
/// ★endEvent（用户 2026-09-05 定稿）：按结果粒度控制事件是否结束——
///   勾选 = 该结果结算后事件解决（隐藏地图标记、本局不再触发，如宝箱打开）；
///   不勾 = 事件保留，可再次尝试（如撬锁失败、绕道离开）。每个选项的成功/失败各自配置。
/// </summary>
[System.Serializable]
public class EventResult
{
    [TextArea(2, 5)]
    [Tooltip("结果文案（成功/失败各自填写）")]
    public string flavorText = "……";

    [Tooltip("本结果结算后是否结束事件：结束后隐藏地图标记、本局不再触发（宝箱消失）；" +
             "不勾则事件保留可再次尝试")]
    public bool endEvent = false;

    [Header("数值变化（Demo 版）")]
    [Tooltip("HP 变化（负数=受伤）")]
    public int hpChange = 0;

    [Tooltip("能量变化")]
    public int energyChange = 0;

    [Tooltip("探索骰子变化（负数=额外消耗）")]
    public int diceChange = 0;

    [Header("获得卡牌（记录用，加牌入组逻辑待牌组循环阶段接入）")]
    public List<CardData> addCards = new List<CardData>();

    [Header("获得物品（spec §10：鉴定成功入对应分区）")]
    public List<EventItemReward> addItems = new List<EventItemReward>();

    [Header("荒野事件扩展（design §3.3–§3.6）")]
    [Tooltip("物资变化（直入局外账 MetaWallet，正加负扣）")]
    public int salvageChange = 0;

    [Tooltip("本结果结算后进战（失败遇袭，design §3.3）")]
    public bool triggerCombat = false;

    [Tooltip("进战的敌人只数（1~2 只，按玩家所在地格群系抽普通成员）")]
    [Range(1, 2)] public int combatEnemyCount = 1;

    [Tooltip("需玩家选 N 张牌删除（0 = 不触发；design §3.4）")]
    public int removeCards = 0;

    [Tooltip("需玩家选 N 张牌复制（0 = 不触发；design §3.4）")]
    public int duplicateCards = 0;

    [Tooltip("授予临时强化（下场战斗生效、战后即耗；design §3.5）")]
    public TempBuffData grantBuff;
}

/// <summary>
/// 事件物品奖励条目（spec §10）。
/// 灵魂/容器在背包内不可堆叠 → amount 恒填 1；材料/骰子/消耗品可 >1。
/// </summary>
[System.Serializable]
public class EventItemReward
{
    [Tooltip("奖励物品（ItemData）。灵魂进魂灯，其余进对应分区")]
    public ItemData item;

    [Tooltip("数量。灵魂/容器填 1——它们在背包里不可堆叠")]
    public int amount = 1;
}

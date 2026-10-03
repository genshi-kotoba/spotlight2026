// =============================================================================
// 模块：M7 背包系统 - ItemData ScriptableObject
// 用途：物品静态模板（材料 / 消耗品 / 卡牌 / 灵魂 / 骰子 / 容器），背包与掉落的数据源
// 设计依据：docs/superpowers/specs/2026-09-08-背包系统-design.md §2（方案一：数据驱动）
// 职责边界：只存静态数据；运行时数量与位置在 Inventory / InventorySlot
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>物品类型（spec §2）。决定进哪个分区：骰子→骰子分区、消耗品→道具分区、其余→常规分区。</summary>
public enum ItemType
{
    材料,
    消耗品,
    卡牌,
    灵魂,
    骰子,
    /// <summary>容器类物品（当前只有魂灯）：占常规分区 1 格，内含独立空间，不可丢弃</summary>
    容器
}

/// <summary>消耗品使用效果（spec §16：回血药水 +5 HP、回能量药水 +2 能量）。</summary>
public enum ConsumableEffect
{
    无,
    回血5,
    回能量2
}

/// <summary>
/// 物品模板。菜单 `卡牌与骰子/物品数据` 创建，存放 Assets/Data/Items/。
/// </summary>
[CreateAssetMenu(fileName = "NewItem", menuName = "卡牌与骰子/物品数据", order = 12)]
public class ItemData : ScriptableObject
{
    [Header("基础信息")]
    [Tooltip("物品唯一标识符（构建器自动生成，格式 ITEM_时间戳）")]
    public string itemID;

    [Tooltip("显示名称")]
    public string itemName = "新物品";

    [Tooltip("描述（弹窗与 tooltip 用）")]
    [TextArea]
    public string description;

    [Tooltip("图标（暂无美术时留空，UI 用名称首字占位）")]
    public Sprite icon;

    [Header("背包规则")]
    [Tooltip("物品类型（决定分区归属）")]
    public ItemType type = ItemType.材料;

    [Tooltip("单格堆叠上限。材料 20；骰子 100（子弹语义，spec §2/§16）；消耗品/卡牌/灵魂/容器 = 1")]
    [Range(1, 999)]
    public int stackLimit = 20;

    [Header("类型专属引用")]
    [Tooltip("type = 消耗品 时的使用效果")]
    public ConsumableEffect useEffect = ConsumableEffect.无;

    [Tooltip("type = 卡牌 时指向的卡牌模板（spec §2 cardRef）")]
    public CardData cardRef;

    /// <summary>
    /// ★2026-09-12 战利品卡牌专用**运行时**字段：这张「卡牌物品」自己在三选一时的配置快照
    /// （= 产出它的小队掉落配置深拷贝：编制全体成员的 rewardCards + 小队级稀有度权重）。
    ///
    /// 为什么放这儿：卡牌奖励从「当场弹三选一」改成「掉一个占背包格的物品、玩家后来再用」后，
    /// 用物品时已经离开了那场战斗，巡逻资产的配置可能已被改动 —— 所以必须在掉落那一刻**随物品一起带走**。
    ///
    /// 非资产数据：不序列化、不进 Inspector（背包本身是当局内对象，重载场景即消失）。
    /// </summary>
    [System.NonSerialized]
    public SquadDropConfig runtimeDropConfig;

    [Tooltip("type = 骰子 时指向的战斗骰子模板（spec §2 diceRef；装填与扣骰按此匹配）")]
    public DiceData diceRef;
}

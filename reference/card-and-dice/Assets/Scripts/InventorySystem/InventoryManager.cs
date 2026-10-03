// =============================================================================
// 模块：M7 背包系统 - InventoryManager 背包管理器
// 用途：背包唯一入口（场景单例）。持有 Inventory、注入力量加值、维护
//       DiceData↔ItemData 映射、开局初始物资与魂灯占格、对外材料计数
// 设计依据：spec §3（分区/容量）、§7（魂灯占 1 格）、§13（ExpeditionWallet 退役）
// 挂载：MainScene 的 SetUp（与 DiceInventoryManager / BattleResultHandler 同处）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

public class InventoryManager : MonoBehaviour
{
    public static InventoryManager Instance { get; private set; }

    [Header("背包")]
    [Tooltip("魂灯物品（ItemType.容器）。开局自动占常规分区 1 格（spec §7）")]
    [SerializeField] private ItemData soulLanternItem;

    [Tooltip("本局可用的战斗骰子物品清单（DiceData↔ItemData 映射来源，装填界面也读它）")]
    [SerializeField] private List<ItemData> diceItems = new List<ItemData>();

    [Tooltip("开局初始物资（Demo 调试用；正式由整装待发/藏身处决定）")]
    [SerializeField] private List<StartingItem> startingItems = new List<StartingItem>();

    [Tooltip("★2026-09-12 用户定稿：不再需要初始资源——关闭后不发魂灯占格、不发初始物资（背包全空）。")]
    [SerializeField] private bool grantInitialResources = false;

    /// <summary>背包模型（分区/堆叠/魂灯全在这里）</summary>
    public Inventory Inventory { get; private set; } = new Inventory();

    /// <summary>背包内容变化（UI 订阅刷新）</summary>
    public event Action OnInventoryChanged;

    [Serializable]
    public class StartingItem
    {
        public ItemData item;
        [Range(1, 999)] public int amount = 1;
    }

    private CardPileManager _pile;

    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    private void OnDestroy()
    {
        if (Instance == this) Instance = null;
        UnhookPile();
    }

    private void Start()
    {
        Inventory.OnChanged += RaiseChanged;
        Inventory.Lantern.OnChanged += RaiseChanged;

        // 魂灯占 1 格（spec §7：背包内占 1 格、可挪动的容器物品）
        // ★2026-09-12：grantInitialResources=false（新默认）时跳过——背包完全空，
        //   没有魂灯、没有回血药、没有战斗骰子（用户：初始资源不需要了）。
        if (grantInitialResources)
        {
            if (soulLanternItem != null && !Inventory.HasLanternItem(soulLanternItem))
            {
                Inventory.TryAdd(soulLanternItem, 1, out _);
            }

            // 初始物资
            foreach (StartingItem si in startingItems)
            {
                if (si?.item == null || si.amount <= 0) continue;
                Inventory.TryAdd(si.item, si.amount, out int added);
                if (added < si.amount)
                {
                    Debug.LogWarning($"[InventoryManager] 初始物资 {si.item.itemName} 只放入 {added}/{si.amount}（容量不足）");
                }
            }
        }

        // ★2026-09-14：藏身处「起始战斗骰」数值强化已删除（设计稿 §0），开局不再发额外骰子。

        // ★2026-09-17 B4 T7：整装发放（骰子/消耗品入背包分区、被动应用、属性加值写入
        // RunModifiers）。必须早于下面的 ReallocateHandDice——首回合手牌要能分配到带出的真实骰。
        // 卡组合并在 CardDeckManager.Awake 已完成（Awake 恒先于 Start）。
        LoadoutDistribution.DistributeAtRunStart();

        SyncStrengthBonus();
        HookPile();

        // ★2026-09-09 修复：首个探索回合的抽牌可能早于本 Start（Unity 脚本间 Start 顺序不保证），
        // 导致首回合 ReallocateHandDice 时真实骰池仍为 0（全临时骰、打牌不扣真实骰）。
        // 初始物资就绪后强制重分配一次手牌，让首回合手牌也正确显示真实骰。
        DicePayment.ReallocateHandDice();

        Debug.Log($"[InventoryManager] 背包就绪：常规 {Inventory.General.Count}/{Inventory.GeneralCapacity} 格、" +
                  $"骰子 {Inventory.Dice.Count}/{Inventory.DiceCapacity} 格、道具 {Inventory.Consumables.Count}/{Inventory.ConsumableCapacity} 格、" +
                  $"魂灯 {Inventory.Lantern.Count}/{SoulLantern.Capacity}");
    }

    // ------------------------------------------------------------------
    // 力量 → 常规分区容量（F4.2：1 格/点，spec §3/§16）
    // ------------------------------------------------------------------

    /// <summary>
    /// 同步力量加值。力量来自持有卡牌的花色汇总（CharacterStats），
    /// 牌堆变化时刷新（订阅 OnPileRefreshed），不做每帧轮询。
    /// </summary>
    public void SyncStrengthBonus()
    {
        Inventory.StrengthBonus = CharacterStats.力量;
    }

    private void HookPile()
    {
        _pile = FindObjectOfType<CardPileManager>();
        if (_pile == null) return;
        _pile.OnPileRefreshed += SyncStrengthBonus;
    }

    private void UnhookPile()
    {
        if (_pile == null) return;
        _pile.OnPileRefreshed -= SyncStrengthBonus;
        _pile = null;
    }

    private void RaiseChanged()
    {
        OnInventoryChanged?.Invoke();
    }

    // ------------------------------------------------------------------
    // 对外查询 / 操作
    // ------------------------------------------------------------------

    /// <summary>本局全部骰子物品（装填界面的可选骰子来源）。</summary>
    public IReadOnlyList<ItemData> AllDiceItems => diceItems;

    /// <summary>DiceData → 对应物品模板（骰子分区扣减/返还用）。找不到返回 null。</summary>
    public ItemData GetDiceItem(DiceData dice)
    {
        if (dice == null) return null;
        foreach (ItemData item in diceItems)
        {
            if (item != null && item.diceRef == dice) return item;
        }
        return null;
    }

    /// <summary>某种战斗骰子在背包内的数量（DiceInventoryManager.GetAvailableCount 用）。</summary>
    public int CountDice(DiceData dice)
    {
        ItemData item = GetDiceItem(dice);
        return item != null ? Inventory.CountOf(item) : 0;
    }

    /// <summary>扣除某种战斗骰子。返回实际扣除数量。</summary>
    public int RemoveDice(DiceData dice, int amount)
    {
        ItemData item = GetDiceItem(dice);
        return item != null ? Inventory.Remove(item, amount) : 0;
    }

    /// <summary>返还某种战斗骰子（未打出的手牌弃置时）。返回是否放入成功。</summary>
    public bool AddDice(DiceData dice, int amount)
    {
        ItemData item = GetDiceItem(dice);
        if (item == null)
        {
            Debug.LogWarning($"[InventoryManager] 找不到骰子物品映射：{(dice != null ? dice.diceName : "null")}（检查 diceItems 配置）");
            return false;
        }
        return Inventory.TryAdd(item, amount, out int added) && added >= amount;
    }

    /// <summary>顶栏「材料 N」读数（替代 ExpeditionWallet.Materials，spec §13）。</summary>
    public int MaterialCount => Inventory.CountOfType(ItemType.材料);

    /// <summary>
    /// 加入任意物品（搜刮/事件奖励/掉落统一入口）。
    /// 灵魂自动进魂灯（灯满则返回 false，由调用方走销毁选择流程，spec §7/§9）。
    /// </summary>
    public bool AddItem(ItemData item, int amount, out int added)
    {
        added = 0;
        if (item == null || amount <= 0) return false;

        if (item.type == ItemType.灵魂 && Inventory.Lantern.IsFull)
        {
            Debug.Log($"[InventoryManager] 魂灯已满（{SoulLantern.Capacity}），灵魂 {item.itemName} 需玩家选择销毁");
            return false;
        }

        bool full = Inventory.TryAdd(item, amount, out added);
        if (added < amount)
        {
            Debug.Log($"[InventoryManager] {item.itemName} 只放入 {added}/{amount}（背包空间不足）");
        }
        return full;
    }

    /// <summary>当局结束清理（遗物袋消散同一出口调用，spec §8/§14）。</summary>
    public void ClearForNewExpedition()
    {
        Inventory.General.Clear();
        Inventory.Dice.Clear();
        Inventory.Consumables.Clear();
        Inventory.Lantern.Clear();
        if (soulLanternItem != null) Inventory.TryAdd(soulLanternItem, 1, out _);
        OnInventoryChanged?.Invoke();
        Debug.Log("[InventoryManager] 当局结束：背包已清空（魂灯重新占格）");
    }

    // ------------------------------------------------------------------
    // 使用消耗品（spec §11 点击使用 / §16 效果表）
    // ------------------------------------------------------------------

    /// <summary>
    /// 使用一个消耗品：先结算效果再扣 1 个（效果无法结算时不扣，避免白喝）。
    /// 背包界面与顶栏 ConsumableBar（Task 22）共用此入口。
    /// </summary>
    /// <returns>true = 已使用并扣除</returns>
    public bool TryUseConsumable(ItemData item)
    {
        if (item == null || item.type != ItemType.消耗品) return false;
        if (Inventory.CountOf(item) <= 0) return false;

        switch (item.useEffect)
        {
            case ConsumableEffect.回血5:
            {
                // 场景暂无 PlayerHealth 组件：用 SendMessage 向带 "Player" 标签的物体发 Heal(int)，
                // 将来实装玩家血量系统时只要挂一个 Heal(int) 方法即可，无需改这里（效果无法结算则不消耗）。
                GameObject player = GameObject.FindWithTag("Player");
                if (player == null)
                {
                    Debug.LogWarning("[InventoryManager] 场景中找不到 Player（无标签或不存在），回血药水无法结算（不消耗）");
                    return false;
                }
                Inventory.Remove(item, 1);
                player.SendMessage("Heal", 5, SendMessageOptions.DontRequireReceiver);
                Debug.Log($"[InventoryManager] 使用 {item.itemName}：HP +5（已发送 Heal 消息给 Player）");
                return true;
            }
            case ConsumableEffect.回能量2:
            {
                EnergyPointDisplay energy = FindObjectOfType<EnergyPointDisplay>();
                if (energy == null)
                {
                    Debug.LogWarning("[InventoryManager] 场景中没有 EnergyPointDisplay，回能量药水无法结算（不消耗）");
                    return false;
                }
                Inventory.Remove(item, 1);
                // ★2026-09-14：改走 AddEnergy —— 受能量上限 energyMax（默认 9）约束。
                // 旧写法直接 SetEnergy(+2) 且 SetEnergy 不限上限，能量能顶到 9 以上。
                int gainedEnergy = energy.AddEnergy(2);
                Debug.Log($"[InventoryManager] 使用 {item.itemName}：能量 +{gainedEnergy} → {energy.CurrentEnergy}（上限 {energy.EnergyMax}）");
                return true;
            }
            default:
                Debug.Log($"[InventoryManager] {item.itemName} 的 useEffect = 无，未配置效果，不消耗");
                return false;
        }
    }
}

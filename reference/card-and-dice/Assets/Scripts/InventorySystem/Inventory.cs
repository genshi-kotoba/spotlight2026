// =============================================================================
// 模块：M7 背包系统 - Inventory 背包模型
// 用途：三分区（常规/骰子/道具）的容量、堆叠、增删、丢弃 + 魂灯
// 设计依据：spec §3（分区结构，策划案 §4.7 对齐）、§16（数值默认）
// 纯 C# 无场景依赖：力量加值由 InventoryManager 注入 StrengthBonus（便于编辑器断言）
//
// 分区规则（spec §3）：
//   常规 12 + 力量×1 格，放材料/卡牌/容器；骰子与道具专用区满后的溢出缓冲
//   骰子分区 6 格，只放骰子（装填从这里取骰）
//   道具分区 3 格，只放消耗品（与顶栏 ConsumableBar 3 格一致）
//   灵魂不入格 → 直接进魂灯（SoulLantern）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

public enum InventoryPartition
{
    常规,
    骰子,
    道具
}

public class Inventory
{
    public const int BaseGeneralCapacity = 12;   // spec §16：常规分区 12 格
    public const int DiceCapacity = 6;           // spec §16：骰子分区 6（可配）
    public const int ConsumableCapacity = 3;     // spec §16：道具分区 3

    public readonly List<InventorySlot> General = new List<InventorySlot>();
    public readonly List<InventorySlot> Dice = new List<InventorySlot>();
    public readonly List<InventorySlot> Consumables = new List<InventorySlot>();

    /// <summary>魂灯（spec §7）：灵魂唯一归处</summary>
    public SoulLantern Lantern { get; } = new SoulLantern();

    /// <summary>力量加值格数（F4.2：1 格/点）。由 InventoryManager 从 CharacterStats.力量 同步</summary>
    public int StrengthBonus { get; set; }

    /// <summary>背包变化（UI 刷新用）</summary>
    public event Action OnChanged;

    public int GeneralCapacity => BaseGeneralCapacity + Mathf.Max(0, StrengthBonus);

    public List<InventorySlot> GetPartition(InventoryPartition p)
    {
        switch (p)
        {
            case InventoryPartition.骰子: return Dice;
            case InventoryPartition.道具: return Consumables;
            default: return General;
        }
    }

    public int GetCapacity(InventoryPartition p)
    {
        switch (p)
        {
            case InventoryPartition.骰子: return DiceCapacity;
            case InventoryPartition.道具: return ConsumableCapacity;
            default: return GeneralCapacity;
        }
    }

    /// <summary>物品首选分区（spec §3：专用区优先接收对应类型）。</summary>
    public static InventoryPartition PreferredPartition(ItemData item)
    {
        if (item == null) return InventoryPartition.常规;
        switch (item.type)
        {
            case ItemType.骰子: return InventoryPartition.骰子;
            case ItemType.消耗品: return InventoryPartition.道具;
            default: return InventoryPartition.常规;
        }
    }

    // ------------------------------------------------------------------
    // 增 / 删 / 查
    // ------------------------------------------------------------------

    /// <summary>
    /// 加入物品。灵魂直送魂灯；其余先堆叠进首选分区，专用区满则溢出到常规分区（spec §3）。
    /// </summary>
    /// <param name="added">实际放入数量（背包满时 &lt; amount）</param>
    /// <returns>true = 全部放入</returns>
    public bool TryAdd(ItemData item, int amount, out int added)
    {
        added = 0;
        if (item == null || amount <= 0) return false;

        if (item.type == ItemType.灵魂)
        {
            while (added < amount && Lantern.TryAdd(item)) added++;
            if (added > 0) OnChanged?.Invoke();
            return added >= amount;
        }

        InventoryPartition preferred = PreferredPartition(item);
        added += AddToPartition(preferred, item, amount - added);
        if (added < amount && preferred != InventoryPartition.常规)
        {
            added += AddToPartition(InventoryPartition.常规, item, amount - added);
        }

        if (added > 0) OnChanged?.Invoke();
        return added >= amount;
    }

    /// <summary>往指定分区放：先堆满已有同物品格，再开新格（不超容量）。返回实际放入数量。</summary>
    private int AddToPartition(InventoryPartition p, ItemData item, int amount)
    {
        if (amount <= 0) return 0;

        List<InventorySlot> slots = GetPartition(p);
        int capacity = GetCapacity(p);
        int limit = Mathf.Max(1, item.stackLimit);
        int added = 0;

        foreach (InventorySlot slot in slots)
        {
            if (slot.item != item) continue;
            int room = limit - slot.count;
            if (room <= 0) continue;
            int move = Mathf.Min(room, amount - added);
            slot.count += move;
            added += move;
            if (added >= amount) return added;
        }

        while (added < amount && slots.Count < capacity)
        {
            int move = Mathf.Min(limit, amount - added);
            slots.Add(new InventorySlot(item, move));
            added += move;
        }

        return added;
    }

    /// <summary>移除物品（跨分区，按 骰子→道具→常规 顺序）。返回实际移除数量。</summary>
    public int Remove(ItemData item, int amount)
    {
        if (item == null || amount <= 0) return 0;

        int removed = 0;
        removed += RemoveFromPartition(InventoryPartition.骰子, item, amount - removed);
        if (removed < amount) removed += RemoveFromPartition(InventoryPartition.道具, item, amount - removed);
        if (removed < amount) removed += RemoveFromPartition(InventoryPartition.常规, item, amount - removed);

        if (removed > 0) OnChanged?.Invoke();
        return removed;
    }

    private int RemoveFromPartition(InventoryPartition p, ItemData item, int amount)
    {
        if (amount <= 0) return 0;

        List<InventorySlot> slots = GetPartition(p);
        int removed = 0;
        for (int i = slots.Count - 1; i >= 0 && removed < amount; i--)
        {
            if (slots[i].item != item) continue;
            int take = Mathf.Min(slots[i].count, amount - removed);
            slots[i].count -= take;
            removed += take;
            if (slots[i].count <= 0) slots.RemoveAt(i);
        }

        return removed;
    }

    /// <summary>
    /// 按类型移除（事件代价「任意材料 / 任意消耗品」用；design §3.2）。
    /// 顺序与 <see cref="Remove"/> 一致：骰子 → 道具 → 常规，每分区内从后往前。
    /// </summary>
    public int RemoveOfType(ItemType type, int amount)
    {
        if (amount <= 0) return 0;

        int removed = 0;
        removed += RemoveTypeFrom(InventoryPartition.骰子, type, amount - removed);
        if (removed < amount) removed += RemoveTypeFrom(InventoryPartition.道具, type, amount - removed);
        if (removed < amount) removed += RemoveTypeFrom(InventoryPartition.常规, type, amount - removed);

        if (removed > 0) OnChanged?.Invoke();
        return removed;
    }

    private int RemoveTypeFrom(InventoryPartition p, ItemType type, int amount)
    {
        if (amount <= 0) return 0;

        List<InventorySlot> slots = GetPartition(p);
        int removed = 0;
        for (int i = slots.Count - 1; i >= 0 && removed < amount; i--)
        {
            if (slots[i].item == null || slots[i].item.type != type) continue;
            int take = Mathf.Min(slots[i].count, amount - removed);
            slots[i].count -= take;
            removed += take;
            if (slots[i].count <= 0) slots.RemoveAt(i);
        }
        return removed;
    }

    /// <summary>某物品在全背包的总数量。</summary>
    public int CountOf(ItemData item)
    {
        if (item == null) return 0;
        int n = 0;
        n += CountIn(General, item);
        n += CountIn(Dice, item);
        n += CountIn(Consumables, item);
        return n;
    }

    private static int CountIn(List<InventorySlot> slots, ItemData item)
    {
        int n = 0;
        foreach (InventorySlot s in slots) if (s.item == item) n += s.count;
        return n;
    }

    /// <summary>某类型物品总数（顶栏「材料 N」用）。</summary>
    public int CountOfType(ItemType type)
    {
        int n = 0;
        n += CountTypeIn(General, type);
        n += CountTypeIn(Dice, type);
        n += CountTypeIn(Consumables, type);
        return n;
    }

    private static int CountTypeIn(List<InventorySlot> slots, ItemType type)
    {
        int n = 0;
        foreach (InventorySlot s in slots) if (s.item != null && s.item.type == type) n += s.count;
        return n;
    }

    /// <summary>某类型物品的格子清单（跨三分区；撤离/阵亡结算按物品名归并成堆用）。</summary>
    public List<InventorySlot> SlotsOfType(ItemType type)
    {
        var list = new List<InventorySlot>();
        CollectSlots(General, type, list);
        CollectSlots(Dice, type, list);
        CollectSlots(Consumables, type, list);
        return list;
    }

    private static void CollectSlots(List<InventorySlot> slots, ItemType type, List<InventorySlot> into)
    {
        foreach (InventorySlot s in slots)
            if (s != null && s.item != null && s.item.type == type) into.Add(s);
    }

    // ------------------------------------------------------------------
    // 丢弃（spec §3）
    // ------------------------------------------------------------------
    // 注：spec §3 的「点击整堆转移」指遗物袋→背包（LootPopupUI 点左侧格子整堆拿取时调
    //     InventoryManager.AddItem，由 TryAdd 的首选分区+溢出规则落位），
    //     背包分区之间不做手动搬运，故此处不提供 MoveStack。

    /// <summary>
    /// 就地销毁一格（spec §3 丢弃）。容器类（魂灯）不可丢弃——内含灵魂，误销毁代价过高。
    /// </summary>
    public bool DiscardAt(InventoryPartition p, int index)
    {
        List<InventorySlot> slots = GetPartition(p);
        if (index < 0 || index >= slots.Count) return false;
        if (slots[index].item != null && slots[index].item.type == ItemType.容器) return false;

        slots.RemoveAt(index);
        OnChanged?.Invoke();
        return true;
    }

    /// <summary>魂灯是否已在背包内占格（开局由 InventoryManager 放入 1 个）。</summary>
    public bool HasLanternItem(ItemData lanternItem)
    {
        return lanternItem != null && CountOf(lanternItem) > 0;
    }
}

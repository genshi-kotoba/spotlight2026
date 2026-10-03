// =============================================================================
// 模块：M7 背包系统 - InventorySlot 背包格子
// 用途：一格 = 一个物品模板 + 当前数量（堆叠）。纯 C#，供 Inventory 与遗物袋共用
// 设计依据：spec §2/§3（堆叠与整堆转移）
// =============================================================================
using System;

/// <summary>
/// 背包/容器内的一格。count 恒 ≥ 1（降到 0 的格子由 Inventory 移除）。
/// </summary>
[Serializable]
public class InventorySlot
{
    public ItemData item;
    public int count;

    public InventorySlot(ItemData item, int count)
    {
        this.item = item;
        this.count = count;
    }

    /// <summary>该格还能再装多少（受 ItemData.stackLimit 限制）。</summary>
    public int FreeSpace
    {
        get
        {
            if (item == null) return 0;
            return Math.Max(0, item.stackLimit - count);
        }
    }
}

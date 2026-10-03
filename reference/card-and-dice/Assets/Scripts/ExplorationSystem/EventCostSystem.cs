// =============================================================================
// 模块：探索系统 - 事件代价结算 EventCostSystem
// 用途：事件选项的付物换利（design §3.2）——可付性判定 / 缺哪一条 / 原子扣除 / 代价文案。
// 纯静态不持状态：背包由调用方传入（L2 编辑态断言可 new Inventory() 直接跑）。
// =============================================================================
using System.Collections.Generic;
using System.Text;

public static class EventCostSystem
{
    /// <summary>某条代价当前能从背包凑出多少（指定物品跨分区清点 / anyOfType 按类型合计）。</summary>
    public static int Available(EventItemCost cost, Inventory inv)
    {
        if (cost == null || inv == null) return 0;
        if (cost.item != null && !cost.anyOfType) return inv.CountOf(cost.item);
        if (cost.anyOfType) return inv.CountOfType(cost.type);
        return 0;
    }

    /// <summary>某选项是否付得起（全部代价条目都够）。</summary>
    public static bool CanPay(EventOption opt, Inventory inv)
    {
        return FirstMissing(opt, inv) == null;
    }

    /// <summary>第一条付不起的代价（都付得起返回 null）。按钮置灰与提示共用。</summary>
    public static EventItemCost FirstMissing(EventOption opt, Inventory inv)
    {
        if (opt == null || opt.costs == null) return null;
        foreach (EventItemCost c in opt.costs)
        {
            if (c == null || c.amount <= 0) continue;
            if (Available(c, inv) < c.amount) return c;
        }
        return null;
    }

    /// <summary>
    /// 扣代价（design §3.2：确认即扣、鉴定失败不退）。
    /// 任一条不够 → 不扣任何东西并返回 false（原子性，防止只扣一半）。
    /// </summary>
    public static bool Pay(EventOption opt, Inventory inv)
    {
        if (opt == null || opt.costs == null || opt.costs.Count == 0) return true;
        if (inv == null) return false;
        if (!CanPay(opt, inv)) return false;

        foreach (EventItemCost c in opt.costs)
        {
            if (c == null || c.amount <= 0) continue;
            if (c.item != null && !c.anyOfType) inv.Remove(c.item, c.amount);
            else if (c.anyOfType) inv.RemoveOfType(c.type, c.amount);
        }
        return true;
    }

    /// <summary>代价条目的显示名（指定物品用 itemName；按类型用类型名）。</summary>
    public static string NameOf(EventItemCost c)
    {
        if (c == null) return "?";
        if (c.item != null && !c.anyOfType) return c.item.itemName;
        return c.type.ToString();
    }

    /// <summary>
    /// 代价后缀文案（design §1.6 自带数量，如「材料×2」）。
    /// ★批 3 造资产约定：optionText **不写代价**，代价一律由本方法渲染（避免文案与字段对不上）。
    /// 空代价返回 ""。
    /// </summary>
    public static string CostSuffix(EventOption opt)
    {
        if (opt == null || opt.costs == null || opt.costs.Count == 0) return "";
        StringBuilder sb = new StringBuilder();
        foreach (EventItemCost c in opt.costs)
        {
            if (c == null || c.amount <= 0) continue;
            if (sb.Length > 0) sb.Append('＋');
            sb.Append(NameOf(c)).Append('×').Append(c.amount);
        }
        return sb.ToString();
    }
}

// =============================================================================
// 模块：M7 战利品 - CorpseContainer 遗物袋（尸体容器）
// 用途：一个死亡格上的可搜刮容器：物资条目（材料/骰子/消耗品）+ 概率一张卡牌。
// 设计依据：背包与战利品系统 spec §8（遗物袋：单向容器 / 清空后消失 / 当局结束消散 /
//           移动经过停下开弹窗 / 搜刮额外消耗 1 行动点 / 卡点击走小弹窗）
// ★为什么不是 MonoBehaviour：遗物袋"不阻挡移动"，做成场景物体会引入碰撞体、
//   脚下射线误命中（EnemyController.UpdateCurrentCoordFromPhysics / HexMover 都靠
//   命中 Hex_ 名字绑坐标）、A* 占格三个坑。纯数据 + CorpseRegistry 按格查询绕开全部。
//   地图上的可视标记由 CorpseSpawner 单独负责（无碰撞体的压扁立方体）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 一个遗物袋。**单向容器**：只能取（ReduceAt / ResolveCard），不能放入（AddItem 仅供生成时填装）。
/// </summary>
public class CorpseContainer
{
    /// <summary>所在格坐标（注册表的键，不可变）</summary>
    public readonly Vector2Int Coord;

    /// <summary>产出这个袋子的敌人名（同格合并时保留第一个）</summary>
    public readonly string EnemyName;

    /// <summary>物资条目。灵魂不入袋（spec §8：灵魂统一走战后结算弹窗）</summary>
    public readonly List<InventorySlot> Items = new List<InventorySlot>();

    /// <summary>袋内卡牌（spec §8：概率一张、随机单张、无三选一）。null = 没有卡 / 卡已处理</summary>
    public CardData CardDrop { get; private set; }

    public CorpseContainer(Vector2Int coord, string enemyName)
    {
        Coord = coord;
        EnemyName = string.IsNullOrEmpty(enemyName) ? "未知敌人" : enemyName;
    }

    /// <summary>
    /// 填装物资（**仅生成时调用**，单向容器不对外开放放入）。
    /// 堆叠口径与背包一致：先填已有格的空位（ItemData.stackLimit），装满再开新格。
    /// </summary>
    public void AddItem(ItemData item, int amount)
    {
        if (item == null || amount <= 0) return;

        foreach (InventorySlot slot in Items)
        {
            if (slot == null || slot.item != item) continue;
            int room = slot.FreeSpace;
            if (room <= 0) continue;

            int put = Mathf.Min(room, amount);
            slot.count += put;
            amount -= put;
            if (amount <= 0) return;
        }

        Items.Add(new InventorySlot(item, amount));
    }

    /// <summary>放入卡牌（仅生成时调用）。已有卡则覆盖——同格合并时后死那张顶掉前一张。</summary>
    public void SetCardDrop(CardData card)
    {
        if (card == null) return;
        CardDrop = card;
    }

    /// <summary>
    /// 卡牌被收下或销毁（spec §8 小弹窗的两个出口 + ESC 之外的处理）。
    /// ESC 是"返回"，不调本方法——卡留在袋里下次还能选。
    /// </summary>
    public void ResolveCard()
    {
        CardDrop = null;
    }

    /// <summary>
    /// 从第 index 格取走 amount 个（搜刮确认时调用）。
    /// </summary>
    /// <returns>实取数量（≤ amount；格子数量不足时只取到有的那么多）。降到 0 的格子立即移除。</returns>
    public int ReduceAt(int index, int amount)
    {
        if (index < 0 || index >= Items.Count || amount <= 0) return 0;

        InventorySlot slot = Items[index];
        if (slot == null) return 0;

        int take = Mathf.Min(amount, slot.count);
        slot.count -= take;
        if (slot.count <= 0) Items.RemoveAt(index);
        return take;
    }

    /// <summary>袋子是否已空（物资 + 卡牌都清空 → spec §8「清空后消失」，由 CorpseRegistry.Remove 收走）。</summary>
    public bool IsEmpty => Items.Count == 0 && CardDrop == null;

    /// <summary>物资总件数（弹窗标题与「一键全拿」的可行性判断用）。</summary>
    public int TotalItemCount
    {
        get
        {
            int n = 0;
            foreach (InventorySlot slot in Items)
            {
                if (slot != null) n += slot.count;
            }
            return n;
        }
    }
}

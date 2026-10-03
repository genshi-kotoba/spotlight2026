// =============================================================================
// 模块：背包 - SoulIntake 灵魂入库（自动入灯 + 灯满挂起）
// 用途：任何来源的灵魂（战斗击杀 / 探索击杀）统一走这里：
//       灯未满 → 直接进魂灯；灯满 → 登记为「挂起」，等玩家在魂灯界面处理。
// 设计依据：docs/2026-09-12_战后结算改右侧汇报条-design.md §2.4
// 生命周期：纯静态；离开本局由 ExpeditionLifecycle.EndExpedition 调 ClearAll
//          （用户定稿：挂起灵魂不处理 = 带回藏身处自动销毁）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 灵魂入库统一入口。<b>取代</b>原先散在 CorpseSpawner / BattleRewardLedger / BattleSettlementUI
/// 三处的「入灯 or 跳过」逻辑——三处口径不一致会导致同一只怪发两个魂，或灯满时静默丢失。
/// </summary>
public static class SoulIntake
{
    /// <summary>一条挂起中的灵魂（魂灯满，玩家还没处理）。</summary>
    public class Pending
    {
        public ItemData soul;
        /// <summary>来源敌人名（提示行显示用）。</summary>
        public string source;
        /// <summary>已处理（进灯成功，或玩家放弃）。</summary>
        public bool resolved;
    }

    static readonly List<Pending> _pending = new List<Pending>();

    /// <summary>挂起列表只读视图（类名 Pending 与属性同名的冲突：属性用 PendingSouls）。</summary>
    public static IReadOnlyList<Pending> PendingSouls => _pending;

    /// <summary>还有未处理的挂起灵魂 → 战后汇报条<b>不淡出</b>。</summary>
    public static bool HasPending
    {
        get
        {
            for (int i = 0; i < _pending.Count; i++)
            {
                if (_pending[i] != null && !_pending[i].resolved) return true;
            }
            return false;
        }
    }

    public static int PendingCount
    {
        get
        {
            int n = 0;
            for (int i = 0; i < _pending.Count; i++)
            {
                if (_pending[i] != null && !_pending[i].resolved) n++;
            }
            return n;
        }
    }

    /// <summary>
    /// 灵魂自动入库：灯未满 → 直接进灯并返回 true；灯满 → 登记为挂起并返回 false。
    /// 传 null / 类型不是灵魂 → 视为「没什么可收的」返回 true（调用方不必特判）。
    /// </summary>
    public static bool TryClaim(ItemData soul, string source)
    {
        if (soul == null || soul.type != ItemType.灵魂) return true;

        SoulLantern lantern = Lantern();
        if (lantern != null && lantern.TryAdd(soul))
        {
            Debug.Log($"[灵魂入库] {source} 的灵魂「{soul.itemName}」已入魂灯（{lantern.Count}/{SoulLantern.Capacity}）");
            return true;
        }

        _pending.Add(new Pending { soul = soul, source = source });
        Debug.Log($"[灵魂入库] 魂灯已满：{source} 的灵魂「{soul.itemName}」挂起，等玩家在魂灯界面处理");
        return false;
    }

    /// <summary>
    /// 玩家在魂灯界面销毁灯内第 <paramref name="lanternIndex"/> 条，给 <paramref name="p"/> 腾位。
    /// 成功 = 旧灵魂销毁 + 新灵魂进灯 + 该挂起条目标记已处理。
    /// </summary>
    public static bool ResolveByDestroying(Pending p, int lanternIndex)
    {
        if (p == null || p.resolved) return false;
        SoulLantern lantern = Lantern();
        if (lantern == null) return false;
        if (lanternIndex < 0 || lanternIndex >= lantern.Count) return false;

        string destroyed = lantern.Souls[lanternIndex] != null ? lantern.Souls[lanternIndex].itemName : "（空）";
        if (!lantern.RemoveAt(lanternIndex)) return false;

        // 位刚腾出、类型在 TryClaim 已验过 → 必成。万一没成也必须标记已处理：
        // 旧灵魂已经销毁了，留着未处理只会让玩家再点一次、再白销毁一条。
        if (!lantern.TryAdd(p.soul))
            Debug.LogError($"[灵魂入库] 腾位后仍收不进「{p.soul.itemName}」——容量或类型被外部改过？");

        p.resolved = true;
        Debug.Log($"[灵魂入库] 销毁「{destroyed}」腾位，收进「{p.soul.itemName}」→ {lantern.Count}/{SoulLantern.Capacity}");
        return true;
    }

    /// <summary>放弃一条挂起灵魂（它消散，不进灯）。</summary>
    public static void Discard(Pending p)
    {
        if (p == null || p.resolved) return;
        p.resolved = true;
        Debug.Log($"[灵魂入库] 放弃挂起灵魂「{(p.soul != null ? p.soul.itemName : "?")}」");
    }

    /// <summary>离开本局：挂起灵魂全部自动销毁（用户定稿：不处理就带不回藏身处）。</summary>
    public static void ClearAll()
    {
        if (_pending.Count > 0)
        {
            Debug.Log($"[灵魂入库] 当局结束：{_pending.Count} 条挂起灵魂自动销毁");
        }
        _pending.Clear();
    }

    static SoulLantern Lantern()
    {
        InventoryManager mgr = InventoryManager.Instance != null
            ? InventoryManager.Instance
            : Object.FindObjectOfType<InventoryManager>();
        return mgr != null && mgr.Inventory != null ? mgr.Inventory.Lantern : null;
    }
}

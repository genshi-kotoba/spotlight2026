// =============================================================================
// 模块：Meta - LoadoutDistribution 整装开局发放
// 用途：出击进图后，把整装快照（B4）一次性发放到当局：
//   · 骰子/消耗品 → 背包分区（InventoryManager，走 Inventory.TryAdd 自动分流）
//   · 被动 grants → StatusEffect 型：EffectFactory.Create + EffectManager 挂玩家；
//     AttributeModifier 型：写入 RunModifiers（移动/视野加值）
//   发放完 ClearLoadout()——卡组合并在 CardDeckManager.BuildRuntimeDeck（Awake）
//   已读，恒先于本处（InventoryManager.Start）执行。
//   空快照 = 现状行为不变（保底骰自动生效）。
// 调用点：InventoryManager.Start（三个出击场景都有 InventoryManager）。
// 设计依据：docs/superpowers/plans/2026-09-17-藏身处B4-整装出击.md T7
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class LoadoutDistribution
{
    public static void DistributeAtRunStart()
    {
        MetaWallet.LoadoutSnapshot s = MetaWallet.PeekLoadout();
        if (!HasAny(s)) return;

        GrantBag(s);
        ApplyPassives(s);

        MetaWallet.ClearLoadout();
        Debug.Log("[整装] 开局发放完成，快照已清空");
    }

    static bool HasAny(MetaWallet.LoadoutSnapshot s)
    {
        if (s == null) return false;
        if (s.cards != null && s.cards.Count > 0) return true;
        if (s.passives != null && s.passives.Count > 0) return true;
        return HasCount(s.dice) || HasCount(s.consumables);
    }

    static bool HasCount(List<MetaWallet.NamedStack> stacks)
    {
        if (stacks == null) return false;
        foreach (MetaWallet.NamedStack st in stacks)
            if (st != null && st.count > 0) return true;
        return false;
    }

    // ------------------------------------------------------------------
    // 背包发放
    // ------------------------------------------------------------------

    static void GrantBag(MetaWallet.LoadoutSnapshot s)
    {
        InventoryManager inv = InventoryManager.Instance;
        if (inv == null)
        {
            Debug.LogWarning("[整装] 场景没有 InventoryManager，骰子/消耗品无法发放");
            return;
        }

        GrantStacks(inv, s.dice);
        GrantStacks(inv, s.consumables);
    }

    static void GrantStacks(InventoryManager inv, List<MetaWallet.NamedStack> stacks)
    {
        if (stacks == null) return;
        foreach (MetaWallet.NamedStack st in stacks)
        {
            if (st == null || st.count <= 0 || string.IsNullOrEmpty(st.name)) continue;

            ItemData item = ResolveItem(st.name);
            if (item == null)
            {
                Debug.LogWarning($"[整装] 实物 {st.name} 查不到物品资产（跑菜单 Tools/藏身处/4. 物品目录），未发放");
                continue;
            }

            inv.Inventory.TryAdd(item, st.count, out int added);
            if (added < st.count)
                Debug.LogWarning($"[整装] {st.name} 只发放 {added}/{st.count}（分区容量不足）");
            else
                Debug.Log($"[整装] 发放 {st.name} ×{added}");
        }
    }

    /// <summary>名字 → ItemData：背包 diceItems → 物品目录 → 制骰配方，三源兜底。</summary>
    static ItemData ResolveItem(string itemName)
    {
        InventoryManager inv = InventoryManager.Instance;
        if (inv != null && inv.AllDiceItems != null)
            foreach (ItemData it in inv.AllDiceItems)
                if (it != null && it.itemName == itemName) return it;

        ItemCatalog cat = ItemCatalog.Load();
        if (cat != null)
        {
            ItemData found = cat.ByName(itemName);
            if (found != null) return found;
        }

        WorkshopConfig cfg = WorkshopConfig.Load();
        if (cfg != null && cfg.diceRecipes != null)
            foreach (WorkshopConfig.DiceRecipe r in cfg.diceRecipes)
                if (r != null && r.dice != null && r.dice.itemName == itemName) return r.dice;

        return null;
    }

    // ------------------------------------------------------------------
    // 被动应用
    // ------------------------------------------------------------------

    static void ApplyPassives(MetaWallet.LoadoutSnapshot s)
    {
        if (s.passives == null || s.passives.Count == 0) return;

        WildernessCraftCatalog cat = WildernessCraftCatalog.Load();
        GameObject player = PlayerRoot();

        foreach (string pn in s.passives)
        {
            PassiveData p = cat != null ? cat.PassiveFor(pn) : null;
            if (p == null)
            {
                Debug.LogWarning($"[整装] 被动 {pn} 查不到资产（工坊素材目录缺失？），跳过");
                continue;
            }
            if (p.grants == null || p.grants.Count == 0)
            {
                Debug.Log($"[整装] 被动 {p.passiveName} 无 grants（机制未实装或纯说明），无开局效果");
                continue;
            }

            foreach (PassiveGrant g in p.grants)
            {
                if (g == null) continue;
                if (g.type == GrantType.StatusEffect) ApplyStatusGrant(p, g, player);
                else ApplyAttributeGrant(p, g);
            }
        }
    }

    static void ApplyStatusGrant(PassiveData p, PassiveGrant g, GameObject player)
    {
        if (player == null)
        {
            Debug.LogWarning($"[整装] 场景没有玩家（HexMover），被动 {p.passiveName} 的状态效果 {g.statusEffectName} 未应用");
            return;
        }
        if (EffectManager.Instance == null)
        {
            Debug.LogWarning($"[整装] 场景没有 EffectManager，被动 {p.passiveName} 的状态效果 {g.statusEffectName} 未应用");
            return;
        }

        Effect e = EffectFactory.Create(g.statusEffectName);
        if (e == null)
        {
            Debug.LogWarning($"[整装] 被动 {p.passiveName} 的效果 {g.statusEffectName} 未注册（EffectFactory），跳过");
            return;
        }

        EffectManager.Instance.ApplyEffect(e, player, g.stacks, EffectApplyTiming.立即);
        Debug.Log($"[整装] 被动 {p.passiveName}：玩家获得 {e.Name} ×{g.stacks}");
    }

    static void ApplyAttributeGrant(PassiveData p, PassiveGrant g)
    {
        if (g.attribute == null)
        {
            Debug.LogWarning($"[整装] 被动 {p.passiveName} 的属性修饰为空，跳过");
            return;
        }

        if (g.attribute.attribute == AttributeType.MoveRange)
        {
            RunModifiers.MoveRangeBonus += g.attribute.delta;
            Debug.Log($"[整装] 被动 {p.passiveName}：移动力 {g.attribute.delta:+0;-0}（当局累计 +{RunModifiers.MoveRangeBonus}）");
        }
        else if (g.attribute.attribute == AttributeType.VisionRange)
        {
            RunModifiers.VisionRangeBonus += g.attribute.delta;
            Debug.Log($"[整装] 被动 {p.passiveName}：视野 {g.attribute.delta:+0;-0}（当局累计 +{RunModifiers.VisionRangeBonus}）");
        }
    }

    /// <summary>玩家根物体（= HexMover 所在物体，与 EffectManager.ClearPlayerArmor 同源）。</summary>
    static GameObject PlayerRoot()
    {
        HexMover mover = ExplorationPerf.Player;
        return mover != null ? mover.gameObject : null;
    }
}

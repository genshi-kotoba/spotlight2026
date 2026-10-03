// =============================================================================
// 模块：Meta - Workshop 卡牌工坊（三件套逻辑层）
// 用途：藏身处「卡牌工坊」的全部规则，UI 只调这里（面板不自己算成本/返还）：
//   · 制卡：配方（unlockedRecipes 门槛）＋ 卡牌碎片×a ＋ 该族三件套「任一」×b → 卡牌库存
//   · 拆解：卡牌库存 ×1 → 碎片 +floor(碎片成本×75%)（怪材不退；只禁初始卡组的口径见设计 §7.4
//     ——初始卡组从不进库存，天然不可拆）
//   · 被动激活：被动配方 ＋ 该族三件套「任一」×（value × 系数）→ passiveUnlocks（永久）
//   · 制骰：物资×c → 实物库（骰子）
//   · 兑物资：族材×1 或 独特×1 → 物资（按配置比价；碎片不可兑）
// 失败一律不动账（先全量前置检查，再依次扣料）。
// 设计依据：docs/2026-09-16_藏身处-design.md v2.1 §7（工坊三件套 / 回收）；统合 §2.3-⑤⑥⑦⑧⑨。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class Workshop
{
    /// <summary>一次工坊动作的结果（失败也返回，看 ok / reason）。</summary>
    public class Result
    {
        public bool ok;
        public string reason;   // 失败原因（UI 直显）
        public int amount;      // 产出 / 返还数量（拆解 = 碎片数）
        public string label;    // 产出物名（卡名 / 被动名 / 骰子名）
    }

    // ------------------------------------------------------------------
    // 成本纯函数（L2 可确定性断言）
    // ------------------------------------------------------------------

    public static int ShardCost(CardData card, WorkshopConfig cfg)
    {
        if (cfg == null) cfg = WorkshopConfig.Load();
        return card == null ? 0 : cfg.ShardCostOf(card.rarity);
    }

    public static int MaterialCost(CardData card, WorkshopConfig cfg)
    {
        if (cfg == null) cfg = WorkshopConfig.Load();
        return card == null ? 0 : cfg.MaterialCostOf(card.rarity);
    }

    /// <summary>拆解返还碎片（纯：floor(碎片成本 × 75%)；只退碎片，怪材不退）。</summary>
    public static int ScrapShards(int shardCost, WorkshopConfig cfg)
    {
        if (cfg == null) cfg = WorkshopConfig.Load();
        return cfg.ScrapShardsOf(shardCost);
    }

    public static int ScrapShardsOf(CardData card, WorkshopConfig cfg)
    {
        return ScrapShards(ShardCost(card, cfg), cfg);
    }

    /// <summary>被动激活怪材成本（纯：value × 系数）。</summary>
    public static int ActivationCost(PassiveData passive, WorkshopConfig cfg)
    {
        if (cfg == null) cfg = WorkshopConfig.Load();
        if (passive == null) return 0;
        return Mathf.Max(1, passive.value) * Mathf.Max(1, cfg.passiveCostPerValue);
    }

    /// <summary>该材料兑 1 件得多少物资（族材 / 独特查目录；其余 0 = 不可兑）。</summary>
    public static int SalvageRate(string materialName, WildernessCraftCatalog cat, WorkshopConfig cfg)
    {
        if (cfg == null) cfg = WorkshopConfig.Load();
        if (cat == null || string.IsNullOrEmpty(materialName)) return 0;
        if (cat.IsFamilyMaterial(materialName)) return Mathf.Max(0, cfg.familyMaterialToSalvage);
        if (cat.IsUniqueMaterial(materialName)) return Mathf.Max(0, cfg.uniqueMaterialToSalvage);
        return 0;
    }

    // ------------------------------------------------------------------
    // 编排（先全量前置检查，再依次扣料；失败不动账）
    // ------------------------------------------------------------------

    /// <summary>制卡：碎片×a ＋ 该族三件套任一×b → 卡牌库存 +1。</summary>
    public static Result TryCraftCard(string cardID, WildernessCraftCatalog cat, WorkshopConfig cfg)
    {
        Result r = new Result();
        if (cfg == null) cfg = WorkshopConfig.Load();
        if (!MetaWallet.IsRecipeUnlocked(cardID)) { r.reason = "配方未抽出，先去灵魂提取装置"; return r; }

        CardData card = cat != null ? cat.CardFor(cardID) : null;
        if (card == null) { r.reason = "工坊素材目录里没有这张卡"; return r; }

        string family = cat.FamilyOfCard(cardID);
        List<string> mats = cat.MaterialNamesOf(family);
        if (mats.Count == 0) { r.reason = family + " 没有族材配置"; return r; }

        int shardNeed = ShardCost(card, cfg);
        int matNeed = MaterialCost(card, cfg);
        if (MetaWallet.MaterialCountOf(MetaWallet.ShardMaterialName) < shardNeed) { r.reason = "卡牌碎片不足，需 " + shardNeed; return r; }
        if (MetaWallet.MaterialCountAnyOf(mats) < matNeed) { r.reason = family + "族材不足，需 " + matNeed; return r; }

        MetaWallet.TryConsumeAnyMaterial(new List<string> { MetaWallet.ShardMaterialName }, shardNeed);
        MetaWallet.TryConsumeAnyMaterial(mats, matNeed);
        MetaWallet.AddCraftedCard(cardID, 1);
        r.ok = true; r.amount = 1; r.label = card.cardName;
        return r;
    }

    /// <summary>拆闲置卡：库存 ×1 → 碎片 +floor(碎片成本×75%)（怪材不退）。</summary>
    public static Result TryScrapCard(string cardID, WildernessCraftCatalog cat, WorkshopConfig cfg)
    {
        Result r = new Result();
        if (cfg == null) cfg = WorkshopConfig.Load();
        if (MetaWallet.CraftedCardCount(cardID) < 1) { r.reason = "库存里没有这张卡"; return r; }

        CardData card = cat != null ? cat.CardFor(cardID) : null;
        if (card == null) { r.reason = "工坊素材目录里没有这张卡"; return r; }

        int back = ScrapShardsOf(card, cfg);
        if (back <= 0) { r.reason = "该卡没有拆解返还"; return r; }

        MetaWallet.TryConsumeCraftedCard(cardID, 1);
        MetaWallet.AddMaterial(MetaWallet.ShardMaterialName, back);
        r.ok = true; r.amount = back; r.label = card.cardName;
        return r;
    }

    /// <summary>被动激活：该族三件套任一×（value×系数）→ 永久激活。</summary>
    public static Result TryActivatePassive(string passiveName, WildernessCraftCatalog cat, WorkshopConfig cfg)
    {
        Result r = new Result();
        if (cfg == null) cfg = WorkshopConfig.Load();
        if (!MetaWallet.IsRecipeUnlocked(passiveName)) { r.reason = "配方未抽出，先去灵魂提取装置"; return r; }
        if (MetaWallet.IsPassiveActive(passiveName)) { r.reason = "该被动已激活"; return r; }

        PassiveData passive = cat != null ? cat.PassiveFor(passiveName) : null;
        if (passive == null) { r.reason = "工坊素材目录里没有这条被动"; return r; }

        string family = cat.FamilyOfPassive(passiveName);
        List<string> mats = cat.MaterialNamesOf(family);
        if (mats.Count == 0) { r.reason = family + " 没有族材配置"; return r; }

        int need = ActivationCost(passive, cfg);
        if (MetaWallet.MaterialCountAnyOf(mats) < need) { r.reason = family + "族材不足，需 " + need; return r; }

        MetaWallet.TryConsumeAnyMaterial(mats, need);
        MetaWallet.ActivatePassive(passiveName);
        r.ok = true; r.amount = 1; r.label = passive.passiveName;
        return r;
    }

    /// <summary>制骰：物资×c → 实物库。</summary>
    public static Result TryCraftDice(string diceItemName, WorkshopConfig cfg)
    {
        Result r = new Result();
        if (cfg == null) cfg = WorkshopConfig.Load();
        if (string.IsNullOrEmpty(diceItemName)) { r.reason = "缺骰子名"; return r; }

        WorkshopConfig.DiceRecipe recipe = null;
        if (cfg.diceRecipes != null)
            foreach (WorkshopConfig.DiceRecipe x in cfg.diceRecipes)
                if (x != null && x.dice != null && x.dice.itemName == diceItemName) { recipe = x; break; }
        if (recipe == null) { r.reason = "工坊配置里没有这个制骰配方"; return r; }

        int cost = Mathf.Max(0, recipe.salvageCost);
        if (MetaWallet.MaterialCountOf(MetaWallet.SalvageName) < cost) { r.reason = "物资不足，需 " + cost; return r; }

        if (cost > 0) MetaWallet.TryConsumeAnyMaterial(new List<string> { MetaWallet.SalvageName }, cost);
        MetaWallet.AddStoredItem(diceItemName, 1);
        r.ok = true; r.amount = 1; r.label = diceItemName;
        return r;
    }

    /// <summary>兑物资：族材/独特 ×1 → 物资（按配置比价；碎片与未分类材料不可兑）。</summary>
    public static Result TryExchangeSalvage(string materialName, WildernessCraftCatalog cat, WorkshopConfig cfg)
    {
        Result r = new Result();
        if (cfg == null) cfg = WorkshopConfig.Load();
        int rate = SalvageRate(materialName, cat, cfg);
        if (rate <= 0) { r.reason = "这种材料不可兑物资"; return r; }
        if (MetaWallet.MaterialCountOf(materialName) < 1) { r.reason = "没有这种材料"; return r; }

        MetaWallet.TryConsumeAnyMaterial(new List<string> { materialName }, 1);
        MetaWallet.AddMaterial(MetaWallet.SalvageName, rate);
        r.ok = true; r.amount = rate; r.label = materialName;
        return r;
    }
}

// =============================================================================
// 模块：敌人系统 - WildernessCraftCatalog 荒野工坊素材目录
// 用途：工坊三件套（制卡 / 被动激活 / 怪材兑物资）需要的运行期索引：
//   · 卡 → 家族（制卡吃哪一族怪材）；被动 → 家族（激活烧哪一族）
//   · 家族 → 三件套族材（「任一」扣料 / 仓库按族显示 / 兑物资分类）
//   · 独特素材表（15 件，比价与仓库用）
//   为什么必须落表：卡/被动/材料资产在 Assets/Data 下（不在 Resources），运行期扫不到；
//   JSON 的 family 字段只在构建期可用（同 B2 灵魂目录的理由）。
// 生成：菜单 Tools/荒野/9. 工坊素材目录（WildernessContentBuilder）
// 资产位置：Assets/Resources/WildernessCraftCatalog.asset
// 设计依据：docs/2026-09-16_藏身处-design.md v2.1 §7（工坊三件套）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "荒野工坊素材目录", menuName = "CardDice/荒野工坊素材目录")]
public class WildernessCraftCatalog : ScriptableObject
{
    public const string ResourcePath = "WildernessCraftCatalog";

    /// <summary>一行 = 一族 × 三件套族材。</summary>
    [Serializable]
    public class FamilyRow
    {
        public string family;                                     // 密林 / 草坡 / …
        public List<ItemData> materials = new List<ItemData>();   // 三件套（怪掉 A/B ＋ 箱出 C）
    }

    /// <summary>一行 = 一张可制作卡 → 家族。</summary>
    [Serializable]
    public class CardRow
    {
        public CardData card;
        public string family;
    }

    /// <summary>一行 = 一条被动 → 家族。</summary>
    [Serializable]
    public class PassiveRow
    {
        public PassiveData passive;
        public string family;
    }

    public List<FamilyRow> families = new List<FamilyRow>();
    public List<CardRow> cards = new List<CardRow>();
    public List<PassiveRow> passives = new List<PassiveRow>();
    public List<ItemData> uniqueMaterials = new List<ItemData>();

    // ---- 运行期索引（懒建） ----
    private Dictionary<string, FamilyRow> _familyIndex;
    private Dictionary<string, CardRow> _cardIndex;
    private Dictionary<string, PassiveRow> _passiveIndex;
    private HashSet<string> _familyMaterialNames;
    private HashSet<string> _uniqueMaterialNames;

    private void BuildIndex()
    {
        if (_cardIndex != null) return;
        _familyIndex = new Dictionary<string, FamilyRow>();
        _cardIndex = new Dictionary<string, CardRow>();
        _passiveIndex = new Dictionary<string, PassiveRow>();
        _familyMaterialNames = new HashSet<string>();
        _uniqueMaterialNames = new HashSet<string>();

        if (families != null)
            foreach (FamilyRow f in families)
            {
                if (f == null || string.IsNullOrEmpty(f.family)) continue;
                if (!_familyIndex.ContainsKey(f.family)) _familyIndex.Add(f.family, f);
                if (f.materials == null) continue;
                foreach (ItemData m in f.materials)
                    if (m != null && !string.IsNullOrEmpty(m.itemName)) _familyMaterialNames.Add(m.itemName);
            }
        if (cards != null)
            foreach (CardRow c in cards)
                if (c != null && c.card != null && !string.IsNullOrEmpty(c.card.cardID) && !_cardIndex.ContainsKey(c.card.cardID))
                    _cardIndex.Add(c.card.cardID, c);
        if (passives != null)
            foreach (PassiveRow p in passives)
                if (p != null && p.passive != null && !string.IsNullOrEmpty(p.passive.passiveName) && !_passiveIndex.ContainsKey(p.passive.passiveName))
                    _passiveIndex.Add(p.passive.passiveName, p);
        if (uniqueMaterials != null)
            foreach (ItemData m in uniqueMaterials)
                if (m != null && !string.IsNullOrEmpty(m.itemName)) _uniqueMaterialNames.Add(m.itemName);
    }

    /// <summary>卡ID → CardData（不在目录里返回 null——UI 跳过该行）。</summary>
    public CardData CardFor(string cardID)
    {
        if (string.IsNullOrEmpty(cardID)) return null;
        BuildIndex();
        CardRow r;
        return _cardIndex.TryGetValue(cardID, out r) ? r.card : null;
    }

    /// <summary>卡ID → 家族（查不到返回 null）。</summary>
    public string FamilyOfCard(string cardID)
    {
        if (string.IsNullOrEmpty(cardID)) return null;
        BuildIndex();
        CardRow r;
        return _cardIndex.TryGetValue(cardID, out r) ? r.family : null;
    }

    /// <summary>被动名 → PassiveData（查不到返回 null）。</summary>
    public PassiveData PassiveFor(string passiveName)
    {
        if (string.IsNullOrEmpty(passiveName)) return null;
        BuildIndex();
        PassiveRow r;
        return _passiveIndex.TryGetValue(passiveName, out r) ? r.passive : null;
    }

    /// <summary>被动名 → 家族（查不到返回 null）。</summary>
    public string FamilyOfPassive(string passiveName)
    {
        if (string.IsNullOrEmpty(passiveName)) return null;
        BuildIndex();
        PassiveRow r;
        return _passiveIndex.TryGetValue(passiveName, out r) ? r.family : null;
    }

    /// <summary>家族 → 三件套资产（查不到返回空表，调用方不用判空）。</summary>
    public List<ItemData> MaterialsOf(string family)
    {
        if (string.IsNullOrEmpty(family)) return new List<ItemData>();
        BuildIndex();
        FamilyRow r;
        return _familyIndex.TryGetValue(family, out r) && r.materials != null ? r.materials : new List<ItemData>();
    }

    /// <summary>家族 → 三件套材料名（扣料「任一」语义用）。</summary>
    public List<string> MaterialNamesOf(string family)
    {
        List<string> names = new List<string>();
        foreach (ItemData m in MaterialsOf(family))
            if (m != null && !string.IsNullOrEmpty(m.itemName)) names.Add(m.itemName);
        return names;
    }

    /// <summary>是否 21 件族材之一。</summary>
    public bool IsFamilyMaterial(string itemName)
    {
        if (string.IsNullOrEmpty(itemName)) return false;
        BuildIndex();
        return _familyMaterialNames.Contains(itemName);
    }

    /// <summary>是否 15 件独特素材之一。</summary>
    public bool IsUniqueMaterial(string itemName)
    {
        if (string.IsNullOrEmpty(itemName)) return false;
        BuildIndex();
        return _uniqueMaterialNames.Contains(itemName);
    }

    /// <summary>取 Resources 资产；没有资产返回 null（调用方自己决定降级文案）。</summary>
    public static WildernessCraftCatalog Load()
    {
        return Resources.Load<WildernessCraftCatalog>(ResourcePath);
    }
}

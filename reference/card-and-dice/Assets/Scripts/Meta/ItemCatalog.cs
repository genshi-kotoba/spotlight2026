// =============================================================================
// 模块：Meta - ItemCatalog 物品目录（整装发放用）
// 用途：整装快照里的实物只有名字（NamedStack.name）——开局发放要把名字解回
//       ItemData 资产。为什么必须落表：物品资产在 Assets/Data/Items 下
//       （不在 Resources），运行期扫不到（同 WildernessCraftCatalog 的理由）。
// 收录范围：骰子 + 消耗品（整装背包页能带出的两类实物）。
// 生成/补齐：菜单 Tools/藏身处/4. 物品目录（ItemCatalogBuilder）
// 资产位置：Assets/Resources/ItemCatalog.asset
// 设计依据：docs/superpowers/plans/2026-09-17-藏身处B4-整装出击.md T7
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "物品目录", menuName = "CardDice/物品目录")]
public class ItemCatalog : ScriptableObject
{
    public const string ResourcePath = "ItemCatalog";

    public List<ItemData> items = new List<ItemData>();

    /// <summary>按物品名取资产；查不到返回 null。</summary>
    public ItemData ByName(string itemName)
    {
        if (string.IsNullOrEmpty(itemName)) return null;
        foreach (ItemData it in items)
            if (it != null && it.itemName == itemName) return it;
        return null;
    }

    /// <summary>取 Resources 资产；没有资产返回 null（调用方自己决定降级）。</summary>
    public static ItemCatalog Load()
    {
        return Resources.Load<ItemCatalog>(ResourcePath);
    }
}

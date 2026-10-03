// =============================================================================
// 编辑器工具：ItemCatalogBuilder 物品目录构建器（菜单 Tools/藏身处/4）
// 用途：扫 Assets/Data/Items 下的骰子/消耗品物品资产，落成 Resources 目录
//       （整装开局发放把实物名字解回 ItemData 用；Assets/Data 运行期扫不到）。
// 幂等：已存在的目录资产只更新列表、不重复创建。
// 惯例参照：Assets/Scripts/Editor/DefaultDeckCatalogBuilder.cs
// =============================================================================
#if UNITY_EDITOR
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;

public static class ItemCatalogBuilder
{
    const string ItemDir  = "Assets/Data/Items";
    const string OutPath  = "Assets/Resources/ItemCatalog.asset";

    [MenuItem("Tools/藏身处/4. 物品目录（整装发放）")]
    public static void Build()
    {
        var list = new List<ItemData>();
        string[] guids = AssetDatabase.FindAssets("t:ItemData", new[] { ItemDir });
        foreach (string guid in guids)
        {
            ItemData it = AssetDatabase.LoadAssetAtPath<ItemData>(AssetDatabase.GUIDToAssetPath(guid));
            if (it == null) continue;
            if (it.type != ItemType.骰子 && it.type != ItemType.消耗品) continue;
            list.Add(it);
        }
        list.Sort((a, b) => string.CompareOrdinal(a.itemName, b.itemName));

        ItemCatalog cat = AssetDatabase.LoadAssetAtPath<ItemCatalog>(OutPath);
        if (cat == null)
        {
            cat = ScriptableObject.CreateInstance<ItemCatalog>();
            AssetDatabase.CreateAsset(cat, OutPath);
        }
        cat.items = list;
        EditorUtility.SetDirty(cat);

        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log($"[ItemCatalogBuilder] 物品目录已更新：{OutPath} 共 {list.Count} 件（骰子+消耗品）");
    }
}
#endif

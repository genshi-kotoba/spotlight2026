// =============================================================================
// 编辑器菜单：生成/补齐「工坊配置表」资产
// 位置：Assets/Resources/WorkshopConfig.asset（照 SoulExtractionConfigBuilder 的 LoadOrCreate 口径）
// 幂等：已存在则只 SetDirty 不覆盖 —— 用户调过的成本/比价不会被菜单跑没；
//       制骰配方只在空表时预填（预填 = Assets/Data/Items 下全部「骰子」物品）。
// =============================================================================
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;

public static class WorkshopConfigBuilder
{
    [MenuItem("Tools/藏身处/2. 工坊配置表")]
    public static void CreateConfig()
    {
        const string path = "Assets/Resources/" + WorkshopConfig.ResourcePath + ".asset";
        WorkshopConfig cfg = AssetDatabase.LoadAssetAtPath<WorkshopConfig>(path);
        if (cfg == null)
        {
            if (!AssetDatabase.IsValidFolder("Assets/Resources"))
                AssetDatabase.CreateFolder("Assets", "Resources");
            cfg = ScriptableObject.CreateInstance<WorkshopConfig>();
            AssetDatabase.CreateAsset(cfg, path);
        }

        int prefill = 0;
        if (cfg.diceRecipes == null || cfg.diceRecipes.Count == 0)
        {
            cfg.diceRecipes = new List<WorkshopConfig.DiceRecipe>();
            foreach (string guid in AssetDatabase.FindAssets("t:ItemData", new[] { "Assets/Data/Items" }))
            {
                ItemData item = AssetDatabase.LoadAssetAtPath<ItemData>(AssetDatabase.GUIDToAssetPath(guid));
                if (item == null || item.type != ItemType.骰子) continue;
                cfg.diceRecipes.Add(new WorkshopConfig.DiceRecipe { dice = item, salvageCost = 3 });
                prefill++;
            }
        }

        EditorUtility.SetDirty(cfg);
        AssetDatabase.SaveAssets();
        Debug.Log("[藏身处] 工坊配置表 → " + path + "（制骰配方 " + cfg.diceRecipes.Count +
                  " 条" + (prefill > 0 ? "，本次预填 " + prefill : "") + "；数值全 PLACEHOLDER）");
    }
}

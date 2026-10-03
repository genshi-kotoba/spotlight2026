// =============================================================================
// 编辑器菜单：生成/补齐「装置抽取配置表」资产
// 位置：Assets/Resources/SoulExtractionConfig.asset（照 WildernessContentBuilder 的 LoadOrCreate 口径）
// 幂等：已存在则只 SetDirty 不覆盖 —— 用户调过的权重不会被菜单跑没。
// =============================================================================
using UnityEditor;
using UnityEngine;

public static class SoulExtractionConfigBuilder
{
    [MenuItem("Tools/藏身处/1. 装置配置表")]
    public static void CreateConfig()
    {
        const string path = "Assets/Resources/" + SoulExtractionConfig.ResourcePath + ".asset";
        SoulExtractionConfig cfg = AssetDatabase.LoadAssetAtPath<SoulExtractionConfig>(path);
        if (cfg == null)
        {
            if (!AssetDatabase.IsValidFolder("Assets/Resources"))
                AssetDatabase.CreateFolder("Assets", "Resources");
            cfg = ScriptableObject.CreateInstance<SoulExtractionConfig>();
            AssetDatabase.CreateAsset(cfg, path);
        }
        EditorUtility.SetDirty(cfg);
        AssetDatabase.SaveAssets();
        Debug.Log("[藏身处] 装置配置表 → " + path + "（权重 " + string.Join("/", cfg.rarityWeights) +
                  "，单抽魂耗 " + cfg.soulCostPerDraw + "）");
    }
}

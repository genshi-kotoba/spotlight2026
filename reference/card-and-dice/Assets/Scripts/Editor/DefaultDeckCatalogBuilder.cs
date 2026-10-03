// =============================================================================
// 编辑器工具：DefaultDeckCatalog 生成 / 补齐
// 用途：把场景里 CardDeckManager 的初始牌组配置抄进 Assets/Resources/DefaultDeckCatalog.asset，
//       让藏身处整装面板与开局构建共用同一份「固定初始卡组」（单一数据源）。
// 取数顺序：① 当前已加载场景里的 CardDeckManager（直接读组件）；
//           ② TutorialScene 场景文件（文本解析 m_Script GUID + initialDeckEntries 块）。
// 菜单：Tools/藏身处/3. 默认卡组目录
// =============================================================================
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;

public static class DefaultDeckCatalogBuilder
{
    const string AssetPath = "Assets/Resources/DefaultDeckCatalog.asset";
    const string SceneFallback = "Assets/Scenes/TutorialScene.unity";

    [MenuItem("Tools/藏身处/3. 默认卡组目录")]
    public static void Build()
    {
        List<DefaultDeckCatalog.Entry> entries = CollectFromLoadedScenes();
        if (entries.Count == 0) entries = CollectFromSceneFile(SceneFallback);
        if (entries.Count == 0)
        {
            Debug.LogWarning("[默认卡组目录] 没找到初始牌组配置（场景里没有 CardDeckManager）");
            return;
        }

        DefaultDeckCatalog cat = AssetDatabase.LoadAssetAtPath<DefaultDeckCatalog>(AssetPath);
        if (cat == null)
        {
            cat = ScriptableObject.CreateInstance<DefaultDeckCatalog>();
            AssetDatabase.CreateAsset(cat, AssetPath);
        }
        cat.entries = entries;
        EditorUtility.SetDirty(cat);
        AssetDatabase.SaveAssets();

        int total = 0;
        foreach (DefaultDeckCatalog.Entry e in entries) total += e.count;
        Debug.Log($"[默认卡组目录] 已写入 {entries.Count} 种卡牌，共 {total} 张 → {AssetPath}");
    }

    static List<DefaultDeckCatalog.Entry> CollectFromLoadedScenes()
    {
        var result = new List<DefaultDeckCatalog.Entry>();
        CardDeckManager mgr = Object.FindObjectOfType<CardDeckManager>();
        if (mgr == null) return result;

        SerializedProperty prop = new SerializedObject(mgr).FindProperty("initialDeckEntries");
        if (prop == null) return result;
        for (int i = 0; i < prop.arraySize; i++)
        {
            SerializedProperty e = prop.GetArrayElementAtIndex(i);
            SerializedProperty card = e.FindPropertyRelative("cardData");
            SerializedProperty count = e.FindPropertyRelative("count");
            if (card == null || card.objectReferenceValue == null) continue;
            result.Add(new DefaultDeckCatalog.Entry
            {
                card = (CardData)card.objectReferenceValue,
                count = count != null ? count.intValue : 1
            });
        }
        return result;
    }

    static List<DefaultDeckCatalog.Entry> CollectFromSceneFile(string scenePath)
    {
        var result = new List<DefaultDeckCatalog.Entry>();
        if (!File.Exists(scenePath)) return result;
        string text = File.ReadAllText(scenePath);

        string scriptGuid = AssetDatabase.AssetPathToGUID("Assets/Scripts/CardSystem/CardDeckManager.cs");
        if (string.IsNullOrEmpty(scriptGuid)) return result;

        int idx = text.IndexOf("guid: " + scriptGuid, System.StringComparison.Ordinal);
        if (idx < 0) return result;
        int block = text.IndexOf("initialDeckEntries:", idx, System.StringComparison.Ordinal);
        if (block < 0) return result;
        int end = text.IndexOf("defaultTacticCards:", block, System.StringComparison.Ordinal);
        if (end < 0) end = text.IndexOf("\n---", block, System.StringComparison.Ordinal);
        if (end < 0) end = text.Length;

        Regex entry = new Regex(@"- cardData: \{fileID: 11400000, guid: ([0-9a-f]+), type: 2\}\r?\n\s+count: (\d+)");
        foreach (Match m in entry.Matches(text.Substring(block, end - block)))
        {
            string path = AssetDatabase.GUIDToAssetPath(m.Groups[1].Value);
            CardData card = string.IsNullOrEmpty(path) ? null : AssetDatabase.LoadAssetAtPath<CardData>(path);
            if (card == null) continue;
            int count;
            if (!int.TryParse(m.Groups[2].Value, out count) || count <= 0) continue;
            result.Add(new DefaultDeckCatalog.Entry { card = card, count = count });
        }
        return result;
    }
}

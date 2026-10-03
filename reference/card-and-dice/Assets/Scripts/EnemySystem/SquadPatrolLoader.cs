// =============================================================================
// 收集全部小队巡逻布局：编辑器直接扫 SquadPatrols 文件夹；真机读 Resources 目录。
// ★2026-09-12 多地图迭代：新增 LoadFor(mapId) —— 按 SquadPatrolData.mapId 过滤，
//   留空的巡逻 = 通用（任何图都生成），填了的只在该地图生成。
//   mapId 取 MapLayoutBuilder.layoutFile.name（布局文件名，如 fogtown）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

public static class SquadPatrolLoader
{
    public const string Folder = "Assets/Data/SquadPatrols";
    public const string CatalogResourceName = "SquadPatrolCatalog";

    public static List<SquadPatrolData> LoadAll()
    {
        var list = new List<SquadPatrolData>();
#if UNITY_EDITOR
        CollectFromFolder(list);
        if (list.Count > 0) return list;
#endif
        SquadPatrolCatalog catalog = Resources.Load<SquadPatrolCatalog>(CatalogResourceName);
        if (catalog != null && catalog.patrols != null)
        {
            foreach (SquadPatrolData p in catalog.patrols)
            {
                if (p != null) list.Add(p);
            }
        }
        return list;
    }

    /// <summary>
    /// ★2026-09-12 按地图过滤（多场景迭代）。
    /// mapId 留空的巡逻 = 通用，任何地图都生成；填了的只在该地图 id 匹配时生成。
    /// mapId 取 <c>MapLayoutBuilder.layoutFile.name</c>（布局文件名，如 fogtown）。
    /// mapId 传空 = 不过滤（保持旧行为，供没有 MapLayoutBuilder 的场景用）。
    /// </summary>
    public static List<SquadPatrolData> LoadFor(string mapId)
    {
        List<SquadPatrolData> all = LoadAll();
        if (string.IsNullOrEmpty(mapId)) return all;

        var list = new List<SquadPatrolData>();
        int skipped = 0;
        foreach (SquadPatrolData p in all)
        {
            if (p == null) continue;
            if (string.IsNullOrEmpty(p.mapId) || p.mapId == mapId) list.Add(p);
            else skipped++;
        }
        if (skipped > 0)
        {
            Debug.Log($"[巡逻加载] 地图「{mapId}」：命中 {list.Count} 份，过滤掉 {skipped} 份属于别的地图的巡逻");
        }
        return list;
    }

#if UNITY_EDITOR
    public static void CollectFromFolder(List<SquadPatrolData> list)
    {
        if (!AssetDatabase.IsValidFolder(Folder)) return;
        string[] guids = AssetDatabase.FindAssets("t:SquadPatrolData", new[] { Folder });
        foreach (string guid in guids)
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            SquadPatrolData data = AssetDatabase.LoadAssetAtPath<SquadPatrolData>(path);
            if (data != null) list.Add(data);
        }
    }

    public static void WriteResourcesCatalog()
    {
        var list = new List<SquadPatrolData>();
        CollectFromFolder(list);

        if (!AssetDatabase.IsValidFolder("Assets/Resources"))
        {
            AssetDatabase.CreateFolder("Assets", "Resources");
        }

        string catalogPath = "Assets/Resources/" + CatalogResourceName + ".asset";
        SquadPatrolCatalog catalog = AssetDatabase.LoadAssetAtPath<SquadPatrolCatalog>(catalogPath);
        if (catalog == null)
        {
            catalog = ScriptableObject.CreateInstance<SquadPatrolCatalog>();
            AssetDatabase.CreateAsset(catalog, catalogPath);
        }
        catalog.patrols = list;
        EditorUtility.SetDirty(catalog);
        AssetDatabase.SaveAssets();
    }
#endif
}

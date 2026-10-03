#if UNITY_EDITOR
using UnityEngine;
using UnityEditor;
using System.IO;
using System.Collections.Generic;

/// <summary>
/// ★美术接入：把 Assets/Resources/EnemyPortraits/ 下的精灵按文件名批量绑定到 EnemyData.icon。
/// 用法：菜单 Tools > 美术接入 > 批量绑定敌人 icon。打开工程后点一次即可，重复点击幂等。
/// （注：EnemyPortraitImporter 已在贴图导入时自动绑定，本菜单仅作为手动兜底。）
/// 前提：EnemyPortraits 里的 png 文件名需与 EnemyData.enemyName（或资产文件名）一致。
/// </summary>
public static class AssignEnemyIcons
{
    private const string Folder = "Assets/Resources/EnemyPortraits";

    [MenuItem("Tools/美术接入/批量绑定敌人 icon（按文件名匹配 EnemyPortraits）")]
    public static void Run()
    {
        if (!Directory.Exists(Folder))
        {
            Debug.LogError("[美术接入] 找不到文件夹：" + Folder);
            return;
        }

        string[] pngs = Directory.GetFiles(Folder, "*.png");
        int done = 0, skip = 0;

        foreach (string png in pngs)
        {
            // 确保按 Sprite 导入（否则 LoadAssetAtPath<Sprite> 会返回 null）
            TextureImporter imp = AssetImporter.GetAtPath(png) as TextureImporter;
            if (imp != null && imp.textureType != TextureImporterType.Sprite)
            {
                imp.textureType = TextureImporterType.Sprite;
                imp.spritePixelsPerUnit = 256;
                imp.SaveAndReimport();
            }

            Sprite sprite = AssetDatabase.LoadAssetAtPath<Sprite>(png);
            if (sprite == null) { skip++; continue; }

            string name = Path.GetFileNameWithoutExtension(png);
            string[] guids = AssetDatabase.FindAssets("t:EnemyData");
            foreach (string g in guids)
            {
                string path = AssetDatabase.GUIDToAssetPath(g);
                EnemyData ed = AssetDatabase.LoadAssetAtPath<EnemyData>(path);
                if (ed == null) continue;

                if (ed.enemyName == name || Path.GetFileNameWithoutExtension(path) == name)
                {
                    if (ed.icon != sprite)
                    {
                        ed.icon = sprite;
                        EditorUtility.SetDirty(ed);
                        done++;
                    }
                }
            }
        }

        AssetDatabase.SaveAssets();
        Debug.Log($"[美术接入] 绑定完成：成功 {done}，跳过 {skip}（未找到精灵/资产）");
    }
}
#endif

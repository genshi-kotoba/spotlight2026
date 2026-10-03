#if UNITY_EDITOR
using UnityEngine;
using UnityEditor;
using System.IO;

/// <summary>
/// ★美术接入（全自动，零点击）：
/// 1) 强制把 Resources/EnemyPortraits/ 与 Resources/PlayerPortrait/ 下的 png 按 Sprite 导入
///    （否则 Resources.Load&lt;Sprite&gt; 会拿到 null）。
/// 2) 导入敌人贴图时，按文件名 = EnemyData.enemyName 自动绑定到 data.icon（生成正确 AssetDatabase 引用，
///    不依赖手写 guid，规避中文 Resources 路径在非 Windows 平台的隐患；战斗内与图鉴同时生效）。
/// 3) 导入玩家贴图时，自动把 PlayerPortraitSwapper 挂到 Player.prefab（替换地图方块）。
///
/// 打开工程 Unity 会自动导入这两批贴图并触发本处理器；若想手动重绑，
/// 仍可调用菜单 Tools > 美术接入 > 批量绑定敌人 icon。
/// </summary>
public class EnemyPortraitImporter : AssetPostprocessor
{
    private const string EnemyFolder = "/Resources/EnemyPortraits/";
    private const string PlayerFolder = "/Resources/PlayerPortrait/";
    private const string PlayerSpriteFile = "Player.png";
    private const string PlayerPrefabPath = "Assets/Prefabs/Player.prefab";

    void OnPostprocessTexture(Texture2D texture)
    {
        if (assetPath.IndexOf(EnemyFolder, System.StringComparison.Ordinal) < 0 &&
            assetPath.IndexOf(PlayerFolder, System.StringComparison.Ordinal) < 0)
            return;

        TextureImporter importer = assetImporter as TextureImporter;
        if (importer == null) return;

        // 逐项比对后再改：值没变就不会触发重新导入，天然避免循环
        if (importer.textureType != TextureImporterType.Sprite)
            importer.textureType = TextureImporterType.Sprite;
        if (importer.spriteImportMode != SpriteImportMode.Single)
            importer.spriteImportMode = SpriteImportMode.Single;

        // FullRect：保证精灵是整张贴图的规整方块（缩放大小时用 rect 计算才准）
        TextureImporterSettings settings = new TextureImporterSettings();
        importer.ReadTextureSettings(settings);
        if (settings.spriteMeshType != SpriteMeshType.FullRect)
        {
            settings.spriteMeshType = SpriteMeshType.FullRect;
            importer.SetTextureSettings(settings);
        }

        if (importer.spritePixelsPerUnit != 256f)
            importer.spritePixelsPerUnit = 256f;
        if (importer.maxTextureSize != 512)
            importer.maxTextureSize = 512;
        if (!importer.mipmapEnabled)
            importer.mipmapEnabled = true;          // 512px 贴在格子上是重度缩小，需要 mip 抗闪烁
        if (!importer.alphaIsTransparency)
            importer.alphaIsTransparency = true;
        if (importer.filterMode != FilterMode.Bilinear)
            importer.filterMode = FilterMode.Bilinear;
        if (importer.wrapMode != TextureWrapMode.Clamp)
            importer.wrapMode = TextureWrapMode.Clamp;
    }

    void OnPostprocessAllAssets(string[] importedAssets, string[] deletedAssets,
        string[] movedAssets, string[] movedFromAssetPaths)
    {
        bool enemyDataDirty = false;

        foreach (string path in importedAssets)
        {
            // ---- 敌人：按文件名绑定 EnemyData.icon ----
            if (path.IndexOf(EnemyFolder, System.StringComparison.Ordinal) >= 0 &&
                path.EndsWith(".png", System.StringComparison.OrdinalIgnoreCase))
            {
                if (BindEnemyIcon(path)) enemyDataDirty = true;
            }

            // ---- 玩家：挂 PlayerPortraitSwapper 到 Player.prefab ----
            if (path.IndexOf(PlayerFolder, System.StringComparison.Ordinal) >= 0 &&
                path.EndsWith(PlayerSpriteFile, System.StringComparison.OrdinalIgnoreCase))
            {
                WirePlayerPrefab();
            }
        }

        if (enemyDataDirty) AssetDatabase.SaveAssets();
    }

    private static bool BindEnemyIcon(string pngPath)
    {
        string name = Path.GetFileNameWithoutExtension(pngPath);
        string dataPath = $"Assets/Data/Enemies/{name}.asset";
        if (!File.Exists(dataPath)) dataPath = $"Assets/Data/Enemies/Wilderness/{name}.asset";
        if (!File.Exists(dataPath)) return false;

        EnemyData data = AssetDatabase.LoadAssetAtPath<EnemyData>(dataPath);
        Sprite sprite = AssetDatabase.LoadAssetAtPath<Sprite>(pngPath);
        if (data == null || sprite == null) return false;
        if (data.icon == sprite) return false;

        data.icon = sprite;
        EditorUtility.SetDirty(data);
        return true;
    }

    private static void WirePlayerPrefab()
    {
        try
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(PlayerPrefabPath);
            if (prefab == null) return;
            if (prefab.GetComponent<PlayerPortraitSwapper>() != null) return;
            prefab.AddComponent<PlayerPortraitSwapper>();
            EditorUtility.SetDirty(prefab);
            AssetDatabase.SaveAssets();
        }
        catch (System.Exception e)
        {
            Debug.LogWarning("[美术接入] 自动挂载 PlayerPortraitSwapper 失败（可手动在 Player.prefab 挂一次）：" + e.Message);
        }
    }
}
#endif

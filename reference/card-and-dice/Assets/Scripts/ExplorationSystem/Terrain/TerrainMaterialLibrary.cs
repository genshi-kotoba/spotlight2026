// =============================================================================
// 模块：探索系统 - 地形材质库 TerrainMaterialLibrary
// 用途：每种地形提供【一份共享材质】，供 Map 层全部格子按地形引用。
//
// 为什么（2026-09-11 场景体积优化）：
//   原实现 HexTile.UpdateTileColor() 每格 Instantiate 一份材质来改颜色：
//     240 格 = 240 份材质实例被写进场景（0.52 MB）；1500 格正式图 = 3000 份（约 6 MB）。
//   改成"每种地形一份材质资产"后，场景里每格只存一条 GUID 引用，总体积趋近于零。
//
// 与 MPB 的分工（见 HexTileColorizer 文件头）：
//   地形色必须能在编辑态看见、且保存进场景 → 只能用材质，不能用 MaterialPropertyBlock。
//
// 落盘位置：Assets/Resources/Terrain/Terrain_<地形>.mat
//   放在 Resources 下是为了运行期（TerrainManager.SetTerrain）也能加载到，
//   总大小 5 份小材质，对包体影响可忽略。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

public static class TerrainMaterialLibrary
{
    private const string ResourceSubFolder = "Terrain";
    private const string AssetFolder = "Assets/Resources/Terrain";
    private const string TemplateAssetPath = "Assets/Materials/HexTileMaterial.mat";

    private static readonly Dictionary<TerrainManager.TerrainType, Material> s_cache =
        new Dictionary<TerrainManager.TerrainType, Material>();

    /// <summary>取该地形的共享材质。首次调用时按需生成资产，之后一直复用同一份。</summary>
    public static Material Get(TerrainManager.TerrainType type)
    {
        if (s_cache.TryGetValue(type, out Material cached) && cached != null) return cached;

        Material material = LoadOrCreate(type);
        s_cache[type] = material;
        return material;
    }

    private static Material LoadOrCreate(TerrainManager.TerrainType type)
    {
        string materialName = $"Terrain_{type}";

        // ① 先只读查找（任何时机调用都安全）
        Material existing = Resources.Load<Material>($"{ResourceSubFolder}/{materialName}");
        if (existing != null) return existing;

#if UNITY_EDITOR
        existing = AssetDatabase.LoadAssetAtPath<Material>($"{AssetFolder}/{materialName}.mat");
        if (existing != null) return existing;

        // ② 资产确实不存在时才创建。包一层 try：
        //    AssetDatabase 写入在序列化过程中（OnValidate / 场景加载）可能被拒绝，
        //    这种情况下退回运行时兜底，不让一次颜色刷新打断编辑器的导入流程。
        try
        {
            return CreateAsset(type, materialName);
        }
        catch (System.Exception e)
        {
            Debug.LogWarning($"[TerrainMaterialLibrary] 材质资产 {materialName} 创建失败，改用运行时材质：{e.Message}");
            return CreateRuntimeMaterial(type, materialName);
        }
#else
        return CreateRuntimeMaterial(type, materialName);
#endif
    }

#if UNITY_EDITOR
    private static Material CreateAsset(TerrainManager.TerrainType type, string materialName)
    {
        // 基于现有 HexTileMaterial 生成变体，保留原有的金属度/光滑度等设置
        Material template = AssetDatabase.LoadAssetAtPath<Material>(TemplateAssetPath);
        Material created = template != null
            ? new Material(template)
            : new Material(Shader.Find("Standard"));

        created.name = materialName;
        created.color = TerrainManager.DefaultColorFor(type);

        if (!AssetDatabase.IsValidFolder(AssetFolder))
        {
            if (!AssetDatabase.IsValidFolder("Assets/Resources"))
                AssetDatabase.CreateFolder("Assets", "Resources");
            AssetDatabase.CreateFolder("Assets/Resources", "Terrain");
        }

        AssetDatabase.CreateAsset(created, $"{AssetFolder}/{materialName}.mat");
        AssetDatabase.SaveAssets();
        return AssetDatabase.LoadAssetAtPath<Material>($"{AssetFolder}/{materialName}.mat");
    }
#endif

    /// <summary>资产不可用时的兜底：现造一份，颜色仍然正确（只是不进场景，每次重新生成）。</summary>
    private static Material CreateRuntimeMaterial(TerrainManager.TerrainType type, string materialName)
    {
        return new Material(Shader.Find("Standard"))
        {
            name = materialName,
            color = TerrainManager.DefaultColorFor(type)
        };
    }

    // ==================================================================
    // ★2026-09-16 带材质地图（A 方案）：红墙格按材质标签（WastelandGenerator.MT_*）选材质
    // ==================================================================
    // 为什么放在这里：墙格仍是 Mountain 地形（阻挡/寻路逻辑零改动），只是"看起来"不同 ——
    // 与地形色同一套"每种标签一份共享材质"的机制，HexLayerRenderer 自动按材质分组合批。
    // 颜色为【临时色块】（对齐已验收的 Python 预览色板）；正式贴图阶段换成带纹理的材质资产，
    // 资产名不变（Terrain_Wall_<标签>），游戏代码无需再动。

    private static readonly Dictionary<char, Material> s_wallCache = new Dictionary<char, Material>();

    /// <summary>取该墙材质标签的共享材质。未知标签回落到通用山体色。</summary>
    public static Material GetWall(char tag)
    {
        if (s_wallCache.TryGetValue(tag, out Material cached) && cached != null) return cached;

        Material material = LoadOrCreateWall(tag);
        s_wallCache[tag] = material;
        return material;
    }

    /// <summary>标签 → 临时色板（与地图预览渲染器 render_ftk.py 同一套观感）。</summary>
    private static Color WallColorFor(char tag)
    {
        switch (tag)
        {
            case 'M': return new Color(0.502f, 0.486f, 0.455f);   // 通用山体（灰岩）
            case 'R': return new Color(0.290f, 0.275f, 0.329f);   // 洞穴岩（暗紫岩）
            case 'W': return new Color(0.545f, 0.420f, 0.290f);   // 营地围墙（木栅）
            case 'B': return new Color(0.784f, 0.761f, 0.706f);   // 建筑墙（灰白墙）
            case 'U': return new Color(0.545f, 0.522f, 0.471f);   // 废墟断墙（风化石）
            case 'T': return new Color(0.659f, 0.635f, 0.588f);   // 墓碑/石棺（浅碑石）
            case 'A': return new Color(0.486f, 0.533f, 0.580f);   // 祭坛石（青石）
            case 'K': return new Color(0.369f, 0.294f, 0.220f);   // 树根/倒木（深木棕）
            case 'I': return new Color(0.435f, 0.443f, 0.451f);   // 环湖岩带（湿岩）
            case 'O': return new Color(0.847f, 0.824f, 0.753f);   // 骨墙/骨堆（骨白）
            default:  return TerrainManager.DefaultColorFor(TerrainManager.TerrainType.Mountain);
        }
    }

    private static Material LoadOrCreateWall(char tag)
    {
        string materialName = $"Terrain_Wall_{tag}";

        Material existing = Resources.Load<Material>($"{ResourceSubFolder}/{materialName}");
        if (existing != null) return existing;

#if UNITY_EDITOR
        existing = AssetDatabase.LoadAssetAtPath<Material>($"{AssetFolder}/{materialName}.mat");
        if (existing != null) return existing;

        try
        {
            return CreateWallAsset(tag, materialName);
        }
        catch (System.Exception e)
        {
            Debug.LogWarning($"[TerrainMaterialLibrary] 墙材质 {materialName} 创建失败，改用运行时材质：{e.Message}");
            return new Material(Shader.Find("Standard")) { name = materialName, color = WallColorFor(tag) };
        }
#else
        return new Material(Shader.Find("Standard")) { name = materialName, color = WallColorFor(tag) };
#endif
    }

#if UNITY_EDITOR
    private static Material CreateWallAsset(char tag, string materialName)
    {
        Material template = AssetDatabase.LoadAssetAtPath<Material>(TemplateAssetPath);
        Material created = template != null
            ? new Material(template)
            : new Material(Shader.Find("Standard"));

        created.name = materialName;
        created.color = WallColorFor(tag);

        if (!AssetDatabase.IsValidFolder(AssetFolder))
        {
            if (!AssetDatabase.IsValidFolder("Assets/Resources"))
                AssetDatabase.CreateFolder("Assets", "Resources");
            AssetDatabase.CreateFolder("Assets/Resources", "Terrain");
        }

        AssetDatabase.CreateAsset(created, $"{AssetFolder}/{materialName}.mat");
        AssetDatabase.SaveAssets();
        return AssetDatabase.LoadAssetAtPath<Material>($"{AssetFolder}/{materialName}.mat");
    }
#endif
}

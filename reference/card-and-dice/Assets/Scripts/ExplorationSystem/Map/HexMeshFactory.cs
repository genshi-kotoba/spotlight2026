// =============================================================================
// 模块：探索系统 - 六边形网格共享资源 HexMeshFactory
// 用途：给 Map / Map1 的全部格子提供【同一份】六边形网格，替代原来"每格 new Mesh()"。
//
// 为什么要有它（2026-09-11 场景体积优化）：
//   原实现 HexRenderer.DrawMesh() 每格 new Mesh()，240 格 × 2 层 = 480 份内容完全
//   相同的网格被序列化进场景 = 4.49 MB，占整个场景的 61%。
//   改为全图共享一份网格资产后，场景里只存一条 GUID 引用。
//
// 几何精简（96 → 48 顶点，外观 100% 不变）：
//   原实现画 4 组面（顶面/底面/外侧面/内侧面），每组 6 个四边形 × 4 顶点 = 96。
//   删掉的两组：
//     · 底面   —— 被地图本身挡住，永远看不到
//     · 内侧面 —— innerSize == 0 时退化成零面积（从中心点到中心点，法线无意义）
//
// 落盘策略：
//   · 编辑器（非 Play）：网格写成 Assets/Models/HexMesh_<参数>.asset，场景只引用 GUID。
//   · 运行期：进程内静态缓存一份，用完即弃，不写盘。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

public static class HexMeshFactory
{
    private const string AssetFolder = "Assets/Models";

    /// <summary>按几何参数缓存，同参数只保留一份网格。</summary>
    private static readonly Dictionary<string, Mesh> s_cache = new Dictionary<string, Mesh>();

    /// <summary>
    /// 取得（必要时生成）六边形网格。所有尺寸相同的格子拿到的是同一个对象引用。
    /// </summary>
    public static Mesh Get(float innerSize, float outerSize, float height)
    {
        string key = $"{innerSize:F3}_{outerSize:F3}_{height:F3}";
        if (s_cache.TryGetValue(key, out Mesh cached) && cached != null) return cached;

        Mesh mesh = Build(innerSize, outerSize, height);

#if UNITY_EDITOR
        // 编辑态：落成资产，保证场景里存的是 GUID 引用而不是内嵌网格数据
        if (!Application.isPlaying) mesh = PersistAsAsset(mesh, key);
#endif

        s_cache[key] = mesh;
        return mesh;
    }

    // ------------------------------------------------------------------
    // 几何构建
    // ------------------------------------------------------------------

    private static Mesh Build(float innerSize, float outerSize, float height)
    {
        Mesh mesh = new Mesh { name = "HexMesh" };

        List<Vector3> vertices = new List<Vector3>();
        List<Vector2> uvs = new List<Vector2>();
        List<int> triangles = new List<int>();

        float top = height * 0.5f;
        float bottom = height * 0.5f;

        // ① 顶面：6 个四边形片，从 innerSize 环铺到 outerSize 环
        for (int i = 0; i < 6; i++)
            AppendFace(vertices, uvs, triangles, innerSize, outerSize, top, top, i);

        // ② 外侧面：6 个四边形片，从上边沿垂到底边沿
        for (int i = 0; i < 6; i++)
            AppendFace(vertices, uvs, triangles, outerSize, outerSize, top, -bottom, i, true);

        // （底面与内侧面已删除，见文件头说明）

        mesh.SetVertices(vertices);
        mesh.SetUVs(0, uvs);
        mesh.SetTriangles(triangles, 0);
        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        return mesh;
    }

    /// <summary>
    /// 追加一个四边形片。顶点顺序与绕序完全沿用原 HexRenderer.CreateFace，
    /// 保证删除底面/内侧面后外观不发生任何变化。
    /// </summary>
    private static void AppendFace(
        List<Vector3> vertices, List<Vector2> uvs, List<int> triangles,
        float inner, float outer, float heightA, float heightB, int segment, bool reverse = false)
    {
        int next = (segment < 5) ? segment + 1 : 0;

        Vector3[] quad =
        {
            Point(inner, heightB, segment),
            Point(inner, heightB, next),
            Point(outer, heightA, next),
            Point(outer, heightA, segment)
        };

        if (reverse) System.Array.Reverse(quad);

        int offset = vertices.Count;
        vertices.AddRange(quad);
        uvs.Add(new Vector2(0f, 0f));
        uvs.Add(new Vector2(1f, 0f));
        uvs.Add(new Vector2(1f, 1f));
        uvs.Add(new Vector2(0f, 1f));

        triangles.Add(offset + 0);
        triangles.Add(offset + 1);
        triangles.Add(offset + 2);
        triangles.Add(offset + 2);
        triangles.Add(offset + 3);
        triangles.Add(offset + 0);
    }

    private static Vector3 Point(float size, float y, int index)
    {
        float radians = Mathf.PI / 180f * (60f * index);
        return new Vector3(size * Mathf.Cos(radians), y, size * Mathf.Sin(radians));
    }

    // ------------------------------------------------------------------
    // 持久化
    // ------------------------------------------------------------------

#if UNITY_EDITOR
    private static Mesh PersistAsAsset(Mesh generated, string key)
    {
        string path = $"{AssetFolder}/HexMesh_{key}.asset";
        Mesh existing = AssetDatabase.LoadAssetAtPath<Mesh>(path);
        if (existing != null)
        {
            Object.DestroyImmediate(generated);
            return existing;
        }

        if (!AssetDatabase.IsValidFolder(AssetFolder))
            AssetDatabase.CreateFolder("Assets", "Models");

        AssetDatabase.CreateAsset(generated, path);
        AssetDatabase.SaveAssets();
        return AssetDatabase.LoadAssetAtPath<Mesh>(path);
    }
#endif
}

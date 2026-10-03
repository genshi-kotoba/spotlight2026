// =============================================================================
// 模块：探索系统 - 单个六边格的网格渲染 HexRenderer
// 用途：给一个格子绑定网格与材质（几何参数由 HexGridLayout 传入）。
//
// ★2026-09-11 体积优化：
//   · 网格不再"每格 new Mesh()"，改为向 HexMeshFactory 取【全图共享的一份】。
//     原来 480 格 = 480 份内容完全相同的网格写进场景 = 4.49 MB，占场景 61%。
//   · 几何从 96 顶点精简到 48 顶点：删掉永远看不到的底面，以及 innerSize == 0
//     时退化成零面积的内侧面。外观 100% 不变。
//   · MeshCollider 改为可选（generateCollider）：Map1 高光层不需要——
//     反正 DisableMap1Colliders 在 Start 里就把它整批禁用了，白占体积。
//
// 为什么 Map 层必须保留 MeshCollider：
//   鼠标拾取全部走 Physics.Raycast（HexMover 落点解析与悬停、BonfireTile 点击、
//   EventTile 点击），依赖的就是格子的碰撞体。删了这套交互会当场失效。
// =============================================================================
using UnityEngine;

[RequireComponent(typeof(MeshFilter), typeof(MeshRenderer))]
public class HexRenderer : MonoBehaviour
{
    [Header("几何")]
    public float innerSize;
    public float outerSize;
    public float height;

    [Header("材质")]
    public Material material;

    [Header("碰撞体（Map 层必须开；Map1 高光层关掉）")]
    public bool generateCollider = true;

    private Mesh m_mesh;

    public void DrawMesh()
    {
        MeshFilter meshFilter = GetComponent<MeshFilter>();
        MeshRenderer meshRenderer = GetComponent<MeshRenderer>();

        // 同尺寸参数的所有格子拿到的是同一个 Mesh 对象引用
        m_mesh = HexMeshFactory.Get(innerSize, outerSize, height);
        meshFilter.sharedMesh = m_mesh;

        if (material != null) meshRenderer.sharedMaterial = material;

        // ★2026-09-15 性能：平铺六边地形不需要投影/接收——
        //   雾镇 80×50 两层共 8000 个 MeshRenderer，Standard 材质默认阴影全开，
        //   场景里只要有阴影光 = 8000 个阴影投射器 + 8000 个接收器，白白多两大包渲染开销。
        meshRenderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        meshRenderer.receiveShadows = false;

        if (!generateCollider) return;

        MeshCollider collider = GetComponent<MeshCollider>();
        if (collider == null) collider = gameObject.AddComponent<MeshCollider>();
        collider.sharedMesh = m_mesh;
    }
}

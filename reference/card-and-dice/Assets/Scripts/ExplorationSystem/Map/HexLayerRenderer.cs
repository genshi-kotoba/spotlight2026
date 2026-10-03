// =============================================================================
// 模块：探索系统 - 网格层批量渲染 HexLayerRenderer
// 用途：把一整层六边格（Map 地形层 / Map1 边框层）合并成少数几个 Mesh 来渲染，
//       取代原「每格一个 GameObject + MeshRenderer」的做法。
//
// ★为什么（2026-09-15 地图重构，用户拍板）：
//   雾镇 80×50 两层共 8000 个 MeshRenderer。Profiler 显示 GPU 侧并不吃力
//   （Draw Calls ~490、三角形 1.2 万——动态合批早就把它们并掉了），
//   但 CPU 每帧必须为这 8000 个渲染器做「剔除 / 排序 / 合批准备」，
//   实测两层合计 ≈ 8ms，占整帧 17ms 的近一半。这就是「什么都没做也只有 50 帧」的真身，
//   也正是「每格一个 GameObject」这个原型做法的天花板。
//
//   对照文明6（用户提问）：它的地形根本不是每格一个对象，而是合并网格 + 纹理混合，
//   格子只是数组里的数据。本类把渲染侧对齐到同一思路，而**逻辑侧保持原样**——
//   每格仍保留 Hex_x_y 数据节点：坐标解析、篝火/事件挂载、射线拾取全部照旧。
//
// 做法：
//   · 整层按 chunkCells × chunkCells 分块，每块一个 Mesh / MeshRenderer
//     （分块而非整图一块：① 顶点数留在 UInt16 内 ② 保留视锥剔除 ③ 重建只影响局部）。
//   · 块内按「材质」再分 submesh——地形层 = 地形类型；边框层 = 底色黑 + 各高亮色。
//     于是"给某格染色"只是改它属于哪个 submesh，不需要 per-tile 材质实例或 MPB。
//   · 染色 = 写「坐标 → 材质」映射 + 标脏；重建推到 LateUpdate 批量做（一帧一次）。
//   · 合并网格标 HideFlags.DontSave，不序列化进场景（打开场景时重建，成本毫秒级）。
//
// 与旧实现的关系：
//   · 旧 HexRenderer（每格 MeshFilter + MeshRenderer + MeshCollider）不再用于渲染；
//     Map 层的 MeshCollider 由 HexGridLayout 直接挂在 Hex_x_y 数据节点上（拾取链路不变）。
//   · HexTileColorizer 由「传 Renderer」改为「传坐标」，对外语义不变。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

[ExecuteAlways]
public class HexLayerRenderer : MonoBehaviour
{
    [Header("几何参数（由 HexGridLayout.LayoutGrid 写入，与格子布局保持一致）")]
    public float innerSize = 0f;
    public float outerSize = 1f;
    public float height = 0.5f;

    [Header("默认材质（没有被单独上色的格子用它）")]
    public Material defaultMaterial;

    [Header("分块边长（格）。越小重建越局部，越大块数越少")]
    [Range(4, 32)] public int chunkCells = 12;

    /// <summary>分块节点的容器名（HexGridLayout 清理子物体时会跳过它）。</summary>
    public const string BatchRootName = "_HexBatch";

    private static readonly int ColorId = Shader.PropertyToID("_Color");

    // ---- 运行时状态（非序列化：域重载后由 Configure 重建）----
    private Vector2Int _gridSize;
    private bool _configured;

    /// <summary>坐标 → 覆盖材质。没有条目 = 用 defaultMaterial。</summary>
    private readonly Dictionary<Vector2Int, Material> _tileMaterial = new Dictionary<Vector2Int, Material>();

    /// <summary>分块键（cx &lt;&lt; 12 | cy）→ 分块。</summary>
    private readonly Dictionary<int, Chunk> _chunks = new Dictionary<int, Chunk>();

    /// <summary>需要重建的分块键（脏标记）。</summary>
    private readonly HashSet<int> _dirtyChunks = new HashSet<int>();

    /// <summary>高亮色 → 材质实例（边框层用；同色共享一份，避免 per-tile 材质）。</summary>
    private readonly Dictionary<Color, Material> _colorMaterials = new Dictionary<Color, Material>();

    private Transform _batchRoot;

    /// <summary>分块重建时的复用容器（这两条是热路径，避免每次 new 字典/列表）。</summary>
    private readonly List<Material> _groupOrder = new List<Material>();
    private readonly Dictionary<Material, List<Vector2Int>> _groups = new Dictionary<Material, List<Vector2Int>>();

    // 单格网格的顶点数据（一次性取出缓存——Mesh.vertices 每次访问都会分配新数组）
    private Vector3[] _hexVertices;
    private Vector3[] _hexNormals;
    private Vector2[] _hexUVs;
    private int[] _hexTriangles;

    private class Chunk
    {
        public Mesh mesh;
        public MeshFilter filter;
        public MeshRenderer renderer;

        // ---- 几何：与材质无关，Configure 后只建一次 ----
        public bool geometryBuilt;
        public Vector3[] verts;
        public Vector3[] norms;
        public Vector2[] uvs;
        public Bounds bounds;
        public int x0, y0, x1, y1;

        // ---- 材质分组：染色变化时重排 ----
        public readonly List<Material> materials = new List<Material>();
        public readonly List<int[]> subTris = new List<int[]>();
    }

    // ------------------------------------------------------------------
    // 对外 API
    // ------------------------------------------------------------------

    public Vector2Int GridSize => _gridSize;
    public bool IsConfigured => _configured;

    /// <summary>
    /// 配置并重建整层。网格尺寸 / 几何 / 底色变化时调用（HexGridLayout.LayoutGrid 与
    /// 编辑态打开场景时）。
    /// </summary>
    public void Configure(Vector2Int gridSize, float inner, float outer, float h, Material def)
    {
        _gridSize = gridSize;
        innerSize = inner;
        outerSize = outer;
        height = h;
        if (def != null) defaultMaterial = def;

        _tileMaterial.Clear();
        // 颜色材质：只在「克隆基准材质换了」时才重建那份缓存。
        //   不能无脑销毁——上一轮的块网格 sharedMaterials 可能还指着它们，
        //   销毁会变成粉红丢失材质。数量级极小（同屏几种高亮色），留着不构成泄漏。
        if (!ReferenceEquals(_colorMaterialBasis, defaultMaterial))
        {
            _colorMaterials.Clear();
            _colorMaterialBasis = defaultMaterial;
        }
        CacheHexGeometry();
        RebuildChunkObjects();
        MarkAllDirty();

        // ★必须在 Flush 之前置位：BuildChunk 与 _validCoord 都以 _configured 为前置条件。
        //   放在 Flush 之后 ⇒ Configure 自己的这一次 Flush 全程早退（空操作），
        //   而 Flush 结尾又会无条件清空脏标记 ⇒ 这些块永远停在空网格上，再也不会重建。
        //   （实测症状：地图切换后整个覆盖层渲染不出来。）
        _configured = true;
        Flush();
    }

    /// <summary>只改尺寸与几何（不动已有上色），用于编辑态恢复。</summary>
    public void ConfigureGeometry(Vector2Int gridSize, float inner, float outer, float h, Material def)
    {
        _gridSize = gridSize;
        innerSize = inner;
        outerSize = outer;
        height = h;
        if (def != null) defaultMaterial = def;

        _configured = true;      // 同 Configure：必须早于 Flush / 任何 SetTileMaterial
        CacheHexGeometry();
        RebuildChunkObjects();
        MarkAllDirty();
        Flush();
    }

    /// <summary>给某格设置材质（null 或 defaultMaterial = 恢复默认）。</summary>
    public void SetTileMaterial(Vector2Int coord, Material material)
    {
        if (!_validCoord(coord)) return;

        Material next = material != null ? material : defaultMaterial;
        Material current = ResolveMaterial(coord);
        if (ReferenceEquals(current, next)) return;

        if (next == null || ReferenceEquals(next, defaultMaterial)) _tileMaterial.Remove(coord);
        else _tileMaterial[coord] = next;

        MarkDirty(coord);
    }

    /// <summary>
    /// 给某格上色（边框层高亮用）。颜色 → 材质实例，同色共享一份。
    /// 传 defaultMaterial 的底色（如 Color.black）时等价于恢复默认。
    /// </summary>
    public void SetTileColor(Vector2Int coord, Color color)
    {
        if (!_validCoord(coord)) return;

        Material mat = MaterialForColor(color);
        SetTileMaterial(coord, mat);
    }

    /// <summary>读取某格当前生效的颜色（高亮态优先，回落默认材质色）。教程禁行格「存原色→还原」用。</summary>
    public Color GetTileColor(Vector2Int coord)
    {
        Material m = ResolveMaterial(coord);
        if (m == null) return Color.white;
        return m.HasProperty(ColorId) ? m.GetColor(ColorId) : m.color;
    }

    /// <summary>整层恢复默认材质（等价于「清掉全部高亮」）。</summary>
    public void ResetAll()
    {
        if (_tileMaterial.Count == 0) return;

        // ★只把【真正有覆盖的格子】所在的块标脏。
        //   原实现直接 MarkAllDirty()：雾镇 80×50 会把 35 个块全部重建（实测 ≈4.08ms），
        //   而实际上往往只有少数几块被染过色 —— 那是「打开卡牌交互流」时的一次可见卡顿。
        foreach (var kv in _tileMaterial) MarkDirty(kv.Key);
        _tileMaterial.Clear();
    }

    /// <summary>把全部格子标脏（网格重建后调用）。</summary>
    public void MarkAllDirty()
    {
        foreach (var kv in _chunks)
        {
            kv.Value.geometryBuilt = false;   // 几何参数可能已变，连顶点一起重建
            _dirtyChunks.Add(kv.Key);
        }
        // 分块对象可能刚建好还没进 _chunks 之外的情况：兜底按网格尺寸全量标
        if (_chunks.Count == 0) _forceAllDirty = true;
    }

    private bool _forceAllDirty;

    /// <summary>Flush 的复用缓冲（避免每次重建都分配列表）。</summary>
    private readonly List<int> _flushKeys = new List<int>();

    /// <summary>立即重建全部脏分块（烘焙收尾 / 需要同帧生效时显式调用）。</summary>
    public void Flush()
    {
        if (_forceAllDirty)
        {
            _forceAllDirty = false;
            int cxCount = ChunkCountX, cyCount = ChunkCountY;
            for (int cy = 0; cy < cyCount; cy++)
                for (int cx = 0; cx < cxCount; cx++)
                    _dirtyChunks.Add((cx << 12) | cy);
        }

        if (_dirtyChunks.Count == 0) return;

        // 先把待构建的键搬出来再清空：构建过程中可能又有坐标被标脏
        //（例如构建之后紧跟着 SetTileColor），直接遍历原集合会踩"集合被修改"异常。
        _flushKeys.Clear();
        foreach (int key in _dirtyChunks) _flushKeys.Add(key);
        _dirtyChunks.Clear();

        foreach (int key in _flushKeys)
        {
            int cx = (key >> 12) & 0xFFF;
            int cy = key & 0xFFF;
            // ★构建失败（未配置 / 几何还没就绪）→ 把脏标记放回去，下帧再试。
            //   原实现无条件清空：只要有一次在"还没准备好"的时刻被 Flush，
            //   该块就永远停在空网格上 —— 这是覆盖层整层消失的根因。
            if (!BuildChunk(cx, cy)) _dirtyChunks.Add(key);
        }
    }

    /// <summary>当前实际存在的合并网格数量（调试/校验用）。</summary>
    public int ChunkCount => _chunks.Count;

    // ------------------------------------------------------------------
    // 内部：坐标与脏标记
    // ------------------------------------------------------------------

    private int ChunkCountX => _gridSize.x <= 0 ? 0 : Mathf.CeilToInt((float)_gridSize.x / chunkCells);
    private int ChunkCountY => _gridSize.y <= 0 ? 0 : Mathf.CeilToInt((float)_gridSize.y / chunkCells);

    private bool _validCoord(Vector2Int c)
    {
        return _configured && c.x >= 0 && c.y >= 0 && c.x < _gridSize.x && c.y < _gridSize.y;
    }

    private Material ResolveMaterial(Vector2Int coord)
    {
        if (_tileMaterial.TryGetValue(coord, out Material m) && m != null) return m;
        return defaultMaterial;
    }

    private void MarkDirty(Vector2Int coord)
    {
        int cx = coord.x / chunkCells;
        int cy = coord.y / chunkCells;
        _dirtyChunks.Add((cx << 12) | cy);
    }

    private Material MaterialForColor(Color color)
    {
        // 底色（边框层权威底色 = 黑）不走单独材质，直接回默认——与旧 HexTileColorizer
        // 的「黑色不走 MPB」约定等价，避免给 4000 格留 4000 个材质条目。
        if (color == Color.black && defaultMaterial != null)
        {
            // 默认材质本身就是黑色（Map1 的 HexTileMaterial），直接回默认
            if (defaultMaterial.color == Color.black) return defaultMaterial;
        }

        if (_colorMaterials.TryGetValue(color, out Material cached) && cached != null) return cached;

        Material basis = defaultMaterial;
        Material inst;
        if (basis != null)
        {
            inst = new Material(basis);
        }
        else
        {
            inst = new Material(Shader.Find("Standard"));
        }
        inst.hideFlags = HideFlags.DontSave;
        inst.name = $"HexLayerColor_{ColorUtility.ToHtmlStringRGBA(color)}";
        inst.SetColor(ColorId, color);
        inst.color = color;

        _colorMaterials[color] = inst;
        return inst;
    }

    /// <summary>颜色材质的克隆基准（换了才重建缓存，见 Configure）。</summary>
    private Material _colorMaterialBasis;

    // ------------------------------------------------------------------
    // 内部：分块对象
    // ------------------------------------------------------------------

    private void CacheHexGeometry()
    {
        Mesh hex = HexMeshFactory.Get(innerSize, outerSize, height);
        if (hex == null) return;
        _hexVertices = hex.vertices;
        _hexNormals = hex.normals;
        _hexUVs = hex.uv;
        _hexTriangles = hex.triangles;
    }

    private void EnsureBatchRoot()
    {
        if (_batchRoot != null) return;

        Transform existing = transform.Find(BatchRootName);
        if (existing != null)
        {
            // ★域重载后遗症（Play 中途脚本重编译 / 播放中改脚本）：
            //   块对象标了 HideFlags.DontSave，会随域重载留存下来；
            //   而 _chunks 是非序列化字典，重载后是空的 —— 这些子节点就成了"孤儿"。
            //   若照旧复用，新建块会与孤儿块重名并存：孤儿块永不更新（染色在这一层静默失效），
            //   而且它们仍然在渲染旧几何。判据很明确 —— 本层还没有任何块引用，
            //   却已经存在块子节点 ⇒ 一律清掉重建。
            if (_chunks.Count == 0 && existing.childCount > 0)
            {
                if (Application.isPlaying) Destroy(existing.gameObject);
                else DestroyImmediate(existing.gameObject);
            }
            else
            {
                _batchRoot = existing;
                return;
            }
        }

        var go = new GameObject(BatchRootName);
        go.hideFlags = HideFlags.DontSave;
        go.transform.SetParent(transform, false);
        _batchRoot = go.transform;
    }

    private void RebuildChunkObjects()
    {
        EnsureBatchRoot();
        int cxCount = ChunkCountX;
        int cyCount = ChunkCountY;

        // ① 删掉超出当前范围的 / 已失效的分块
        var stale = new List<int>();
        foreach (var kv in _chunks)
        {
            int cx = (kv.Key >> 12) & 0xFFF;
            int cy = kv.Key & 0xFFF;
            if (cx >= cxCount || cy >= cyCount || kv.Value.filter == null) stale.Add(kv.Key);
        }
        foreach (int key in stale) DestroyChunk(key);

        // ② 建齐当前范围的分块对象
        for (int cy = 0; cy < cyCount; cy++)
            for (int cx = 0; cx < cxCount; cx++)
                EnsureChunk(cx, cy);
    }

    private Chunk EnsureChunk(int cx, int cy)
    {
        int key = (cx << 12) | cy;
        if (_chunks.TryGetValue(key, out Chunk existing) && existing.filter != null) return existing;

        var go = new GameObject($"Chunk_{cx}_{cy}");
        go.hideFlags = HideFlags.DontSave;
        go.transform.SetParent(_batchRoot, false);

        MeshFilter mf = go.AddComponent<MeshFilter>();
        MeshRenderer mr = go.AddComponent<MeshRenderer>();
        // 与旧 HexRenderer 一致：平铺地形不投影、不接收阴影
        mr.shadowCastingMode = ShadowCastingMode.Off;
        mr.receiveShadows = false;

        Mesh mesh = new Mesh { name = $"HexChunk_{cx}_{cy}" };
        mesh.hideFlags = HideFlags.DontSave;
        mesh.indexFormat = IndexFormat.UInt16;
        mf.sharedMesh = mesh;

        var chunk = new Chunk { mesh = mesh, filter = mf, renderer = mr };
        _chunks[key] = chunk;
        return chunk;
    }

    private void DestroyChunk(int key)
    {
        if (!_chunks.TryGetValue(key, out Chunk c)) return;
        _chunks.Remove(key);
        _dirtyChunks.Remove(key);

        if (c.filter != null)
        {
            if (Application.isPlaying) Destroy(c.filter.gameObject); else DestroyImmediate(c.filter.gameObject);
        }
        if (c.mesh != null)
        {
            if (Application.isPlaying) Destroy(c.mesh); else DestroyImmediate(c.mesh);
        }
    }

    private void ClearChunks()
    {
        var keys = new List<int>(_chunks.Keys);
        foreach (int k in keys) DestroyChunk(k);
        if (_batchRoot != null)
        {
            if (Application.isPlaying) Destroy(_batchRoot.gameObject); else DestroyImmediate(_batchRoot.gameObject);
            _batchRoot = null;
        }
    }

    // ------------------------------------------------------------------
    // 内部：合并网格构建
    // ------------------------------------------------------------------

    /// <summary>重建一个分块。返回 false 表示"这次没法建"（脏标记会被保留，下帧重试）。</summary>
    private bool BuildChunk(int cx, int cy)
    {
        if (!_configured || _hexVertices == null || _hexTriangles == null) return false;

        Chunk chunk = EnsureChunk(cx, cy);
        if (chunk == null || chunk.mesh == null) return false;

        chunk.x0 = cx * chunkCells;
        chunk.y0 = cy * chunkCells;
        chunk.x1 = Mathf.Min(chunk.x0 + chunkCells, _gridSize.x);
        chunk.y1 = Mathf.Min(chunk.y0 + chunkCells, _gridSize.y);

        if (!chunk.geometryBuilt || chunk.verts == null) BuildChunkGeometry(chunk);
        BuildChunkSubMeshes(chunk);
        return true;
    }

    /// <summary>
    /// 本块的顶点/法线/UV。顶点顺序固定为「块内 (y, x) 逐格 × 每格 N 顶点」，
    /// **与材质分组无关** —— 这是染色能只重排三角形、不重传顶点的前提。
    /// </summary>
    private void BuildChunkGeometry(Chunk c)
    {
        int cells = (c.x1 - c.x0) * (c.y1 - c.y0);
        int hexVerts = _hexVertices.Length;
        int need = cells * hexVerts;

        if (c.verts == null || c.verts.Length < need)
        {
            c.verts = new Vector3[need];
            c.norms = new Vector3[need];
            c.uvs = new Vector2[need];
        }

        int vi = 0;
        for (int y = c.y0; y < c.y1; y++)
        {
            for (int x = c.x0; x < c.x1; x++)
            {
                Vector3 offset = HexGridLayout.HexLocalPos(x, y, outerSize);
                for (int v = 0; v < hexVerts; v++)
                {
                    c.verts[vi] = _hexVertices[v] + offset;
                    c.norms[vi] = _hexNormals[v];
                    c.uvs[vi] = _hexUVs[v];
                    vi++;
                }
            }
        }
        c.geometryBuilt = true;

        Mesh mesh = c.mesh;
        mesh.Clear();
        mesh.indexFormat = need > 65000 ? IndexFormat.UInt32 : IndexFormat.UInt16;
        mesh.SetVertices(c.verts, 0, vi);
        mesh.SetNormals(c.norms, 0, vi);
        mesh.SetUVs(0, c.uvs, 0, vi);

        // 分块范围只与几何有关（顶点位置固定），算一次交剔除用。
        //   之后重排三角形时不再重算——那是每次悬停都要走的热路径。
        float outer = Mathf.Max(outerSize, 0.0001f);
        float w = 2f * outer * 0.75f;
        float hh = Mathf.Sqrt(3f) * outer;
        float minX = c.x0 * w - outer;
        float maxX = (c.x1 - 1) * w + outer;
        float maxZ = outer;                                         // 偶数行 y=0 时 z=0，留出一格外扩
        float minZ = -((c.y1 - 1) * hh + hh * 0.5f) - outer;
        float halfH = Mathf.Max(height, 0.0001f) * 0.5f;
        c.bounds = new Bounds(
            new Vector3((minX + maxX) * 0.5f, 0f, (minZ + maxZ) * 0.5f),
            new Vector3(maxX - minX, halfH * 2f, maxZ - minZ));
        mesh.bounds = c.bounds;
    }

    /// <summary>按材质把本块格子拆成 submesh。染色变化只走这一段，不碰顶点。</summary>
    private void BuildChunkSubMeshes(Chunk c)
    {
        int hexVerts = _hexVertices.Length;
        int hexTris = _hexTriangles.Length;

        _groupOrder.Clear();
        _groups.Clear();
        for (int y = c.y0; y < c.y1; y++)
        {
            for (int x = c.x0; x < c.x1; x++)
            {
                var coord = new Vector2Int(x, y);
                Material m = ResolveMaterial(coord);
                if (m == null) continue;

                if (!_groups.TryGetValue(m, out List<Vector2Int> list))
                {
                    list = new List<Vector2Int>();
                    _groups[m] = list;
                    _groupOrder.Add(m);
                }
                list.Add(coord);
            }
        }

        int width = c.x1 - c.x0;
        c.materials.Clear();
        c.subTris.Clear();

        for (int gi = 0; gi < _groupOrder.Count; gi++)
        {
            Material m = _groupOrder[gi];
            List<Vector2Int> list = _groups[m];
            var tris = new int[list.Count * hexTris];

            for (int i = 0; i < list.Count; i++)
            {
                Vector2Int coord = list[i];
                // 顶点基址 = 该格在块内的固定序号 × 每格顶点数（与材质分组无关）
                int vBase = ((coord.y - c.y0) * width + (coord.x - c.x0)) * hexVerts;
                int tBase = i * hexTris;
                for (int t = 0; t < hexTris; t++) tris[tBase + t] = vBase + _hexTriangles[t];
            }
            c.subTris.Add(tris);
            c.materials.Add(m);
        }

        Mesh mesh = c.mesh;
        mesh.subMeshCount = c.subTris.Count;
        for (int i = 0; i < c.subTris.Count; i++) mesh.SetTriangles(c.subTris[i], i, false);
        mesh.bounds = c.bounds;             // 上面没让 Unity 重算 bounds，这里补回固定值
        c.renderer.sharedMaterials = c.materials.ToArray();
        c.renderer.enabled = c.subTris.Count > 0;
    }

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    private void LateUpdate()
    {
        if (_dirtyChunks.Count > 0 || _forceAllDirty) Flush();
    }

    private void OnDestroy()
    {
        // ★不要在这里销毁块对象 / 网格：
        //   · 块对象标了 HideFlags.DontSave，退出 Play / 关闭场景时由 Unity 自行回收；
        //   · 在 OnDestroy 里再调 DestroyImmediate 会踩"销毁中再销毁"的警告与递归风险。
        //   本层被 SetActive(false) 时不要清空——块是子节点，Unity 会连它一起隐藏，
        //   重新启用后原样回来（清空反而会导致运行态地图消失）。
        _chunks.Clear();
        _dirtyChunks.Clear();
        _colorMaterials.Clear();
        _batchRoot = null;
        _configured = false;
    }
}

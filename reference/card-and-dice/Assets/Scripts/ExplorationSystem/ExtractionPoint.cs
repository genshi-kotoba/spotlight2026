// =============================================================================
// 模块：探索系统 - 主动撤离点 ExtractionPoint（纯静态类）
// 用途：玩家走回「家」格（= 出生格 = 撤离点，布局字符 'S'）→ 弹撤离确认 →
//       确认后把当局材料/灵魂**全额**入账 MetaWallet → 回藏身处。
//
// 为什么需要它（P0 闭环缺口）：
//   2026-09-12 按设计删掉了篝火上的「撤离（回藏身处）」按钮——理由正确
//   （总策划案 §2：篝火 ≠ 撤离点 ≠ 藏身处），但「家」格这一侧一直没补上，
//   于是本局唯一能回藏身处的路只剩「死亡」。
//   没有主动撤离，远征收益就拿不回去 →「再贪一点还是撤」这条核心张力不成立，
//   后面的委托/随机图做完也无法"带走收益"。
//
// 设计依据：
//   · docs/2026-09-15_委托随机远征-design.md §8「第 0 步：补主动撤离」
//   · docs/2026-09-14_雾镇分区-design.md §2.1「藏身处入口 ＝ 出生点 ＝ 撤离点」
//   · 游戏设计文档 总策划案 终极版 §2「篝火 ≠ 撤离点 ≠ 藏身处」
//
// 触发规则（三条缺一不可）：
//   ① 本局是雾镇这类「剧情突袭图」—— 教程图不参与
//      （教程有自己的 'O' 藏身处入口 + 教学门禁，见 HideoutEntrance）。
//   ② 玩家**先离开过撤离点**（_armed）—— 否则开局就站在 S 格上，
//      会立刻弹出"要不要撤"。离开一次即武装，走回来才弹。
//   ③ 当前没有面板/弹窗挡着（AnyOverlayOpen）—— 不打断玩家正在看的事件/篝火/背包。
//   弹过一次就 _prompted；**离开撤离点 → 复位**，再走回来才会再弹。
//
// 结算口径（与死亡对照）：
//   主动撤离 ＝ 材料 + 灵魂**全额**入账（MetaWallet.DepositRun）
//   玩家死亡 ＝ 材料丢进尸体待回收、灵魂**保留一半**（MetaWallet.RecordDeath）
//   → 这个差额就是"贪死于否"的全部意义。
//
// ⏸ 未做（按 §8 执行顺序留给后续步骤，不是漏做）：
//   · 「完成委托目标才开启撤离点」（Q4）—— 现在只要走回家格就能撤；
//   · 局内时间条耗尽后的强制撤离 / 收益打折（Q1 · L2）；
//   · 「本局带回收益」的结算面板 —— 当前靠藏身处的资源条体现（这是刻意的最小实现）。
// =============================================================================
using UnityEngine;
using UnityEngine.SceneManagement;

public static class ExtractionPoint
{
    /// <summary>本局是否已弹出过撤离确认（离开撤离点即复位）——防止弹窗一关又弹、死循环。</summary>
    private static bool _prompted;

    /// <summary>「已武装」：玩家离开过撤离点一次 → 远征真正开始，回到 S 格才有资格触发。</summary>
    private static bool _armed;

    /// <summary>确认撤离后的防重入（LoadScene 延迟到帧末，期间 Update 还会跑）。</summary>
    private static bool _leaving;

    private static MapLayoutBuilder _builder;
    private static bool _resolved;                 // 找过一次就不再找（FindObjectOfType 禁入每帧路径）
    private static GameObject _markerRoot;         // 撤离点地面标记（每次进图重建）

    static ExtractionPoint()
    {
        SceneManager.sceneLoaded += (_, __) => ResetForNewScene();
    }

    private static void ResetForNewScene()
    {
        _prompted = false;
        _armed = false;
        _leaving = false;
        _builder = null;
        _resolved = false;
        _markerRoot = null;
    }

    /// <summary>
    /// 每帧检查：玩家站在撤离点（＝家＝出生格 'S'）上 → 弹撤离确认。
    /// 由 ExplorationTurnManager.Update 调用（与 HideoutEntrance.HandleArrival 同一挂载点）。
    /// </summary>
    public static void HandleArrival(HexMover playerMover)
    {
        if (_leaving || playerMover == null) return;

        // 只在探索态触发（战斗中/结算中不弹）
        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState != GameState.Exploring) return;

        // 已有面板/弹窗挡着 → 这一帧不打扰（关掉后还会再判一次）
        if (Interactions.AnyOverlayOpen() || Interactions.TutorialLockInput) return;

        if (!EnsureBuilder()) return;

        // 教程图走自己的 'O' 藏身处入口（HideoutEntrance）——本类不介入
        if (MapLayoutBuilder.IsTutorial) return;
        if (!_builder.hasSpawn) return;

        Vector2Int cur = playerMover.CurrentCoord;

        // 离开撤离点 → 复位（同时完成"武装"：远征正式开始了）
        if (cur != _builder.spawnCoord)
        {
            if (!_armed) _armed = true;
            _prompted = false;
            return;
        }

        if (!_armed || _prompted) return;

        _prompted = true;
        Debug.Log($"[撤离] 玩家回到撤离点 Hex_{cur.x}_{cur.y} → 弹撤离确认");
        ExtractionUI.Show();
    }

    /// <summary>
    /// 确认撤离：取数 → 全额入账 → 清当局静态 → 回藏身处。
    /// ⚠️ 顺序不能改：取数必须早于 EndExpedition（它会清空背包），
    ///    EndExpedition 又必须早于 LoadScene（静态清理器依赖存活的订阅者）。
    /// </summary>
    public static void ConfirmExtraction()
    {
        if (_leaving) return;
        _leaving = true;

        var materials = new System.Collections.Generic.List<MetaWallet.NamedStack>();
        var souls = new System.Collections.Generic.List<ItemData>();
        InventoryManager inv = InventoryManager.Instance;
        if (inv != null)
        {
            materials = MetaWallet.AggregateStacks(inv.Inventory.SlotsOfType(ItemType.材料));
            souls.AddRange(inv.Inventory.Lantern.Souls);   // 复制一份：EndExpedition 会清空
        }

        MetaWallet.DepositRun(materials, souls);           // ★撤离＝全额入账（材料按种类）
        Debug.Log($"[撤离] 带回材料 {MetaWallet.SumOf(materials)}（{MetaWallet.SummaryOf(materials)}）、" +
                  $"灵魂 {souls.Count} 条 → 回藏身处");

        ExpeditionLifecycle.EndExpedition("主动撤离");
        SceneManager.LoadScene(MetaWallet.HIDEOUT_SCENE);
    }

    // ------------------------------------------------------------------
    // 撤离点地面标记
    // ------------------------------------------------------------------
    // 走回「家」格才能撤 —— 但这个格子在地图上没有任何标识的话，玩家根本找不到它。
    // 这里在地面摆一个单格标记（1 个 cube，去掉碰撞体，走 MaterialPropertyBlock 上色
    // 所以不会产生材质实例）。挂在独立根节点下，避开 MapNodePreviewCleaner 的清理范围。

    private const string MarkerRootName = "ExtractionMarker";

    /// <summary>是否在撤离点地面摆标记。想关掉（比如换成美术做的撤离点）把这里改 false 即可。</summary>
    private const bool ShowExtractionMarker = true;

    private static bool EnsureBuilder()
    {
        if (_resolved) return _builder != null;
        _resolved = true;                                  // 找过一次就不再找
        _builder = Object.FindObjectOfType<MapLayoutBuilder>();
        if (_builder != null && ShowExtractionMarker && !MapLayoutBuilder.IsTutorial) BuildMarker();
        return _builder != null;
    }

    private static void BuildMarker()
    {
        if (_markerRoot != null || _builder == null || !_builder.hasSpawn) return;
        Transform grid = _builder.map1Grid != null ? _builder.map1Grid.transform : null;
        if (grid == null) return;

        Vector2Int c = _builder.spawnCoord;
        Transform tile = grid.Find($"Hex_{c.x}_{c.y}");
        if (tile == null) return;

        _markerRoot = new GameObject(MarkerRootName);
        _markerRoot.transform.SetParent(_builder.transform, false);

        GameObject m = GameObject.CreatePrimitive(PrimitiveType.Cube);
        m.name = $"Extraction_{c.x}_{c.y}";
        float s = _builder.map1Grid.outerSize > 0f ? _builder.map1Grid.outerSize : 1f;
        m.transform.position = new Vector3(tile.position.x, tile.position.y + 0.30f, tile.position.z);
        m.transform.localScale = new Vector3(0.72f * s, 0.30f * s, 0.72f * s);
        m.transform.SetParent(_markerRoot.transform, true);

        Collider col = m.GetComponent<Collider>();          // 有碰撞体会挡住格子拾取射线
        if (col != null) Object.Destroy(col);

        // 用 MPB 上色（不 new 材质，保持合批）——撤离点用青绿，与篝火橙、宝箱金区分。
        // 两个属性名都设：内置管线用 _Color，URP 用 _BaseColor（多设一个不存在的属性无害）。
        Renderer r = m.GetComponent<Renderer>();
        if (r != null)
        {
            Color markerColor = new Color(0.20f, 1.00f, 0.55f);
            var mpb = new MaterialPropertyBlock();
            mpb.SetColor(ColorId, markerColor);
            mpb.SetColor(BaseColorId, markerColor);
            r.SetPropertyBlock(mpb);
        }
    }

    private static readonly int ColorId = Shader.PropertyToID("_Color");
    private static readonly int BaseColorId = Shader.PropertyToID("_BaseColor");
}

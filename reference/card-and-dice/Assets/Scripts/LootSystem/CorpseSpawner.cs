// =============================================================================
// 模块：M8 战利品 - 遗物袋生成器 CorpseSpawner
// 用途：敌人死亡 → 生成/合并遗物袋（掉落表 + 概率一张卡）→ 死亡格放无碰撞体标记
// 设计依据：docs/superpowers/specs/2026-09-08-背包系统-design.md §8
// 挂载：MainScene SetUp/GameManager（构建器 Tools/背包/3 自动挂）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 遗物袋生成器。数据归 CorpseRegistry，本类只负责「死亡 → 填袋」与「注册表 → 地图标记」。
/// 标记不是数据源，删掉重建即可，所以同步是全量幂等的。
/// </summary>
public class CorpseSpawner : MonoBehaviour
{
    public static CorpseSpawner Instance { get; private set; }

    [Header("地图标记外观（★2026-09-12 用户定稿：遗物袋 = 箱子，不是压扁薄片）")]
    [Tooltip("箱子缩放：正常高度的小木箱（不再压成贴地薄片）")]
    public Vector3 MarkerScale = new Vector3(0.5f, 0.38f, 0.5f);

    [Tooltip("箱子颜色：深棕木箱。美术到位后换正式箱子素材")]
    public Color MarkerColor = new Color(0.40f, 0.27f, 0.14f, 1f);

    [Tooltip("箱子离地高度（底部贴地：scale.y/2）")]
    public float MarkerLift = 0.19f;

    [Header("阵亡尸体回收（突袭场景：MetaWallet 只存材料数量、不存具体物品，回收时统一用它）")]
    [Tooltip("回收阵亡尸体时生成的材料（构建器填 铁屑）。★不再是敌人掉落兜底 —— " +
             "敌人掉什么完全由小队模板 / 巡逻的掉落配置决定，配置里没有就不产袋。")]
    public ItemData fallbackMaterialItem;

    [Header("★2026-09-12 探索击杀掉落（用户：探索里打死怪也要有掉落窗口和掉落物）")]
    [Tooltip("探索态击杀：把该敌人的专属灵魂**直接入魂灯**。\n" +
             "（战斗态的灵魂走战后结算弹窗，由 BattleRewardLedger 记账；本开关只补探索态那条路）")]
    public bool autoClaimSoulOnExploreKill = true;

    [Tooltip("★2026-09-12 默认关：探索击杀**不再立刻弹搜刮窗**（用户定稿：打断节奏）。\n" +
             "改为右侧掉落汇报条告知「地上有遗物袋」，玩家想要就自己走过去搜刮——\n" +
             "既保留「只拿一部分」的选择权，又不按停节奏。\n" +
             "开回来 = 恢复旧的「击杀即弹窗」行为（仅调试对比用）。")]
    public bool autoOpenLootOnExploreKill = false;

    readonly Dictionary<Vector2Int, GameObject> _markers = new Dictionary<Vector2Int, GameObject>();
    /// <summary>探索击杀产生的、还没弹过窗的遗物袋（仅 autoOpenLootOnExploreKill 调试开关打开时使用）。</summary>
    readonly List<CorpseContainer> _pendingLoot = new List<CorpseContainer>();
    Transform _mapRoot;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(this);              // 只销毁重复的组件，不能 Destroy(gameObject)——宿主是 GameManager
            return;
        }
        Instance = this;
    }

    void OnEnable()
    {
        EnemyController.EnemyDied += HandleEnemyDied;
        CorpseRegistry.OnChanged += SyncMarkers;
    }

    void OnDisable()
    {
        EnemyController.EnemyDied -= HandleEnemyDied;
        CorpseRegistry.OnChanged -= SyncMarkers;
    }

    void OnDestroy()
    {
        if (Instance == this) Instance = null;
    }

    // ------------------------------------------------------------------
    // 死亡 → 填袋
    // ------------------------------------------------------------------

    /// <summary>
    /// 敌人死亡回调。坐标非法时 Spawn 返回 null（内部已 Warning），本方法直接放弃。
    /// ★2026-09-12 用户定稿：没有「教程图不产袋」硬拦截、也没有空配置兜底 ——
    ///   掉什么完全由小队模板 / 巡逻的掉落配置决定，配置滚完没有内容就不产袋。
    /// </summary>
    void HandleEnemyDied(EnemyController enemy)
    {
        if (enemy == null) return;

        // 探索态击杀：灵魂直接入魂灯（战斗态的灵魂走 BattleRewardLedger）+ 右下角告知。
        // 灵魂不进袋，与下面「没内容就不产袋」互不影响。
        // ★2026-09-12 判据用「死亡瞬间定格的状态」而不是现读：战斗最后一击的胜利结算会在同一
        //   次死亡事件链里先切回 Exploring，现读会把战斗击杀误判成探索击杀（单杀双魂的根因）。
        string enemyName = EnemyNameOf(enemy);
        bool exploreKill = enemy.StateAtDeath == GameState.Exploring;
        if (exploreKill && autoClaimSoulOnExploreKill)
        {
            ItemData soul = SoulFor(enemy);
            if (soul != null)
            {
                bool soulClaimed = SoulIntake.TryClaim(soul, enemyName);
                // 统一走右下角堆叠列表：魂灯已满 → 常驻待处理；已入灯 → 一行字告知
                LootClaimPopupUI.ShowExploreKill(enemyName, soulClaimed);
            }
        }

        // 先滚内容，再决定产不产袋：配置里没有可掉的东西 → 连袋带标记都不产。
        // （旧行为「先产袋、空了补兜底铁屑」会让「删掉落物」变成「掉一个装着铁屑的袋子」。）
        MemberDropConfig cfg = SquadDropConfig.FindMember(enemy);
        List<InventorySlot> materials = RollMaterials(cfg, enemyName);
        CardData card = RollCard(cfg);
        if (materials.Count == 0 && card == null)
        {
            Debug.Log($"[CorpseSpawner] {enemyName} 的掉落配置没有可掉的东西 → 不产遗物袋");
            return;
        }

        CorpseContainer corpse = CorpseRegistry.Spawn(enemy.CurrentCoord, enemyName);
        if (corpse == null) return;

        foreach (InventorySlot row in materials) corpse.AddItem(row.item, row.count);
        if (corpse.CardDrop == null && card != null)          // 同格合并：袋里已有卡就不顶掉（先死那张留下）
        {
            corpse.SetCardDrop(card);
            Debug.Log($"[CorpseSpawner] {corpse.EnemyName} 的遗物袋里有一张卡：{card.cardName}");
        }

        // 探索态击杀：立刻弹掉落窗（仅 autoOpenLootOnExploreKill 调试开关打开时；默认关）。
        // 同样用 exploreKill：战斗击杀的袋子留在地上，战后自己走过去搜刮。
        if (exploreKill && autoOpenLootOnExploreKill) _pendingLoot.Add(corpse);
    }

    /// <summary>当前是否探索态（战斗态的掉落全部走战后结算，不在这里发）。</summary>
    static bool IsExploring()
    {
        return GameStateManager.Instance != null
               && GameStateManager.Instance.CurrentState == GameState.Exploring;
    }

    /// <summary>
    /// 解该敌人该掉的灵魂（★2026-09-12 三态）：沿用预设 = preset.soulItem / 覆盖 = soulOverride / 关闭 = 不掉。
    /// 无巡逻配置 → null（design §9-6：场景手摆怪不产魂）。取在 clone 上的 soulItem 与预设同值（Instantiate 拷贝）。
    /// </summary>
    static ItemData SoulFor(EnemyController enemy)
    {
        MemberDropConfig cfg = SquadDropConfig.FindMember(enemy);
        ItemData presetSoul = enemy != null && enemy.data != null ? enemy.data.soulItem : null;
        return SquadDropConfig.ResolveSoul(cfg, presetSoul);
    }

    /// <summary>
    /// 逐个弹探索击杀的掉落窗。三条门禁，缺一个都会在错误时机弹窗：
    ///   ① 状态已不是探索（打完就进战斗了）→ 整队作废，袋子留地上战后搜刮
    ///   ② 有模态窗 / 正在操作卡牌 / 结算中 → 等下一帧
    ///   ③ 袋子已被搜刮清空 → 跳过
    /// </summary>
    void Update()
    {
        if (_pendingLoot.Count == 0) return;

        if (!IsExploring())
        {
            _pendingLoot.Clear();
            return;
        }

        if (Interactions.ModalPopupActive || Interactions.CardFlowBusy) return;
        if (ActionSystem.Instance != null && ActionSystem.Instance.IsPerforming) return;

        CorpseContainer next = _pendingLoot[0];
        _pendingLoot.RemoveAt(0);

        if (next == null || next.IsEmpty) return;
        if (CorpseRegistry.Get(next.Coord) == null) return;

        LootPopupUI.OpenFor(next);
    }

    static string EnemyNameOf(EnemyController enemy)
    {
        return enemy.data != null && !string.IsNullOrEmpty(enemy.data.enemyName)
            ? enemy.data.enemyName
            : "未知敌人";
    }

    /// <summary>
    /// 滚「死亡敌人所属成员」的巡逻配置里的材料行（★2026-09-12 改读小队模板 / 巡逻覆盖）。
    /// 每行独立滚数量区间；灵魂不进袋（走灵魂三态）；非材料/骰子的条目跳过并警告。
    /// 只滚内容不入袋 —— 调用方先看有没有东西，再决定产不产袋。
    /// </summary>
    static List<InventorySlot> RollMaterials(MemberDropConfig cfg, string enemyName)
    {
        var result = new List<InventorySlot>();
        if (cfg == null || cfg.materials == null) return result;

        foreach (MaterialDropRange row in cfg.materials)
        {
            if (row == null || row.item == null) continue;
            if (row.item.type != ItemType.材料 && row.item.type != ItemType.骰子)
            {
                Debug.LogWarning($"[CorpseSpawner] {enemyName} 的掉落条目「{row.item.itemName}」不是材料/骰子" +
                                 $"（{row.item.type}），已跳过 —— 请在小队模板 / 巡逻面板的掉落配置里改");
                continue;
            }

            int amount = SquadDropConfig.RollAmount(row, Random.value);
            if (amount <= 0) continue;

            result.Add(new InventorySlot(row.item, amount));
        }
        return result;
    }

    /// <summary>
    /// 概率掉一张该成员配置的袋内卡（概率与卡池都来自掉落配置，按池内权重抽，不走稀有度表）。
    /// 只滚「掉不掉、是哪张」，入袋在调用方（产袋之后）。
    /// </summary>
    static CardData RollCard(MemberDropConfig cfg)
    {
        if (cfg == null || cfg.bagCards == null || cfg.bagCards.Count == 0) return null;
        if (cfg.bagCardChance <= 0f) return null;
        if (Random.value >= cfg.bagCardChance) return null;

        int idx = SquadDropConfig.PickWeightedIndex(cfg.bagCards, Random.value);
        return idx >= 0 ? cfg.bagCards[idx].card : null;
    }

    // ------------------------------------------------------------------
    // 注册表 → 地图标记（全量幂等）
    // ------------------------------------------------------------------

    /// <summary>
    /// 同步地图标记与注册表。先删失效再补缺；不在 All() 遍历中改注册表。
    /// </summary>
    void SyncMarkers()
    {
        var stale = new List<Vector2Int>();
        foreach (KeyValuePair<Vector2Int, GameObject> kv in _markers)
        {
            if (kv.Value == null || CorpseRegistry.Get(kv.Key) == null) stale.Add(kv.Key);
        }
        foreach (Vector2Int coord in stale)
        {
            DestroySafely(_markers[coord]);
            _markers.Remove(coord);
        }

        foreach (CorpseContainer corpse in CorpseRegistry.All())
        {
            if (_markers.ContainsKey(corpse.Coord)) continue;
            GameObject marker = CreateMarker(corpse.Coord);
            if (marker != null) _markers[corpse.Coord] = marker;
        }
    }

    GameObject CreateMarker(Vector2Int coord)
    {
        if (!TryGetCellWorldPos(coord, out Vector3 world))
        {
            Debug.LogWarning($"[CorpseSpawner] 找不到 Hex_{coord.x}_{coord.y}，遗物袋数据仍在但没有地图标记");
            return null;
        }

        GameObject marker = GameObject.CreatePrimitive(PrimitiveType.Cube);
        marker.name = $"Corpse_{coord.x}_{coord.y}";

        // 碰撞体会污染向下射线（EnemyController / HexMover 靠命中 "Hex_" 绑坐标）与 A* 占格判定。
        // enabled = false 立即生效，Destroy 等帧末，两个都写。
        Collider col = marker.GetComponent<Collider>();
        if (col != null)
        {
            col.enabled = false;
            DestroySafely(col);
        }

        marker.transform.SetParent(MapRoot, false);
        marker.transform.position = world + Vector3.up * MarkerLift;
        marker.transform.localScale = MarkerScale;

        MeshRenderer mr = marker.GetComponent<MeshRenderer>();
        if (mr != null) mr.material.color = MarkerColor;

        return marker;
    }

    Transform MapRoot
    {
        get
        {
            if (_mapRoot == null)
            {
                GameObject map = GameObject.Find("Map");
                _mapRoot = map != null ? map.transform : null;
            }
            return _mapRoot;
        }
    }

    /// <summary>
    /// Destroy 在编辑态会报错，而 L2 断言需要在编辑态驱动 SyncMarkers，所以统一走这里。
    /// </summary>
    static void DestroySafely(Object target)
    {
        if (target == null) return;
#if UNITY_EDITOR
        if (!Application.isPlaying)
        {
            Object.DestroyImmediate(target);
            return;
        }
#endif
        Object.Destroy(target);
    }

    /// <summary>
    /// 格子坐标 → 世界坐标。口径逐行对齐 EnemyIntentVisuals.TryGetWorldPos:631-657。
    /// </summary>
    bool TryGetCellWorldPos(Vector2Int coord, out Vector3 world)
    {
        world = Vector3.zero;

        Transform root = MapRoot;
        if (root != null)
        {
            Transform tile = root.Find($"Hex_{coord.x}_{coord.y}");
            if (tile != null)
            {
                world = tile.position;
                return true;
            }
        }

        // 兜底：HexGridLayout 公式（平顶，奇数列在 z 方向偏移 h/2）
        HexGridLayout grid = FindObjectOfType<HexGridLayout>();
        if (grid == null) return false;

        float s = grid.outerSize;
        float w = 2f * s * 0.75f;
        float h = Mathf.Sqrt(3f) * s;
        float offset = (coord.x % 2 != 0) ? h / 2f : 0f;
        Vector3 local = new Vector3(coord.x * w, 0f, -(coord.y * h + offset));
        world = grid.transform.TransformPoint(local);
        return true;
    }
}

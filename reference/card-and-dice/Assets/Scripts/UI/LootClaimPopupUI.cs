// =============================================================================
// 模块：UI - LootClaimPopupUI 战后结算堆叠列表（★2026-09-12 重构：合并告知条与操作弹窗）
// 用途：战斗胜利 / 探索击杀后的掉落反馈，**统一**为一个「从下往上堆叠」的条目列表，
//       锚定在结束回合按钮上方（右下角），逐条往上堆。
//       显示顺序（从下往上，用户定稿）：
//         ① 魂灯已满的灵魂（需操作：常驻不淡出、无法关闭，点击 → 魂灯处理子窗）
//         ② 卡牌奖励（需操作：8s 才淡出、右键可提前关，点击 → 三选一）
//         ③ 魂灯未满的灵魂（纯告知：一行字，1.6s 快速淡出）
//       ★2026-09-12 用户定稿：去掉「材料已落入遗物袋」告知行（走过去看到袋子就行，不必提示）。
// 设计依据：docs/2026-09-12_战后结算改右侧汇报条-design.md §2（用户二次定稿）
// 模态：本体**非模态**（不锁移动/结束回合）；三选一与魂灯处理两个子窗是真模态。
// 位置：右下角（结束回合按钮上方）——取代原先右上角两个浮动面板（重叠问题的根因）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using DG.Tweening;

public class LootClaimPopupUI : MonoBehaviour
{
    static LootClaimPopupUI _instance;

    // ---- 布局常量（右下角，从下往上堆） ----
    const float InfoRowHeight = 28f;    // 告知型（魂灯未满）：一行字
    const float ActionRowHeight = 48f;  // 操作型（魂灯已满）：加高，方便点击
    const float CardRowHeight = 64f;    // 卡牌奖励：比普通条目大一号，但不喧宾夺主（★2026-09-12 用户回看「倒也不用这么大」→ 92 收到 64）
    const int CardRowFont = 16;
    const float RowSpacing = 3f;
    const float Padding = 8f;
    /// <summary>面板右边缘离画布右边的距离（与 ComputeAnchor 同一口径）。</summary>
    const float AnchorRightInset = 16f;
    /// <summary>找不到结束回合按钮时的兜底面板宽度。</summary>
    const float FallbackPanelWidth = 270f;
    /// <summary>面板宽度：★2026-09-12 用户定稿「宽度不要超过结束回合按钮的左边」——Build 时按按钮实测。</summary>
    float _panelWidth = FallbackPanelWidth;

    const float InfoStay = 1.6f;   // 魂灯未满：一行字快速淡出
    const float CardStay = 8f;     // 卡牌奖励：等更久才淡出
    const float FadeDur = 0.25f;   // 淡出时长

    // ---- 行类型 ----
    enum RowKind { PendingSoul, CardReward, Info }

    class Row
    {
        public RowKind kind;
        public GameObject go;
        public CanvasGroup cg;
        public float remaining;            // 存活秒数；-1 = 常驻（魂灯已满）
        public bool fading;
        public float height;               // 行高（操作型 48 / 告知型 28）
        public ItemData cardItem;          // CardReward 点击用
        public SoulIntake.Pending pending; // PendingSoul 点击用
    }

    RectTransform _panelRT;
    readonly List<Row> _rows = new List<Row>();
    bool _built;
    bool _open;
    float _pollTimer;
    int _signature;

    // ---- 魂灯处理子窗（真模态） ----
    RectTransform _lanternRoot;
    RectTransform _lanternPanelRT;
    Text _lanternSummary;
    readonly List<GameObject> _lanternRows = new List<GameObject>();
    SoulIntake.Pending _handling;
    bool _lanternBuilt;

    // ------------------------------------------------------------------
    // 实例生命周期
    // ------------------------------------------------------------------
    static LootClaimPopupUI Ensure()
    {
        if (_instance != null) return _instance;
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            Debug.LogWarning("[战后结算] 找不到 UICanvas，无法显示");
            return null;
        }
        GameObject go = new GameObject("LootClaimPopupUI");
        go.transform.SetParent(canvas.transform, false);
        _instance = go.AddComponent<LootClaimPopupUI>();
        return _instance;
    }

    void OnDestroy()
    {
        if (_instance == this) _instance = null;
    }

    // ------------------------------------------------------------------
    // 静态入口
    // ------------------------------------------------------------------
    /// <summary>
    /// 战斗胜利后弹出（BattleResultHandler 调用）。只放需要操作 + 需要告知的条目；
    /// 全部为空就不弹。
    /// </summary>
    public static void ShowAfterVictory()
    {
        BattleRewardLedger.RollCardRewards();   // 掷卡牌奖励（rolled 守卫保证不重掷）

        // 没有任何条目可显示 → 不弹
        // （★2026-09-12：材料不再单独出条目 —— 地上有没有袋子玩家走过去就看见，不必提示）
        if (!SoulIntake.HasPending
            && BattleRewardLedger.GrantedCardItems.Count == 0
            && ClaimedCount() == 0)
            return;

        LootClaimPopupUI ui = Ensure();
        if (ui == null) return;

        ui.BeginBuild();

        // ① 魂灯已满（常驻）
        foreach (SoulIntake.Pending p in SoulIntake.PendingSouls)
            if (p != null && !p.resolved) ui.AddPendingSoulRow(p);

        // ② 卡牌奖励（8s）
        foreach (ItemData card in BattleRewardLedger.GrantedCardItems)
            if (card != null && InventoryHas(card)) ui.AddCardRow(card);

        // ③ 魂灯未满（一行字）
        int claimed = ClaimedCount();
        if (claimed > 0) ui.AddInfoRow($"灵魂 ×{claimed} 已入魂灯");

        ui.FinishBuild();
    }

    /// <summary>探索态击杀（CorpseSpawner 调用）。魂灯已满 → 常驻待处理；已入灯 → 一行字告知。</summary>
    public static void ShowExploreKill(string enemyName, bool soulClaimed)
    {
        LootClaimPopupUI ui = Ensure();
        if (ui == null) return;

        ui.BeginBuild();

        foreach (SoulIntake.Pending p in SoulIntake.PendingSouls)
            if (p != null && !p.resolved) ui.AddPendingSoulRow(p);

        if (soulClaimed) ui.AddInfoRow($"灵魂 · {enemyName} 已入魂灯");

        ui.FinishBuild();
    }

    static int ClaimedCount()
    {
        int n = 0;
        foreach (BattleRewardLedger.SoulEntry e in BattleRewardLedger.Souls)
            if (e != null && e.claimed) n++;
        return n;
    }

    static bool InventoryHas(ItemData item)
    {
        InventoryManager mgr = InventoryManager.Instance;
        return mgr == null || mgr.Inventory.CountOf(item) > 0;
    }

    // ------------------------------------------------------------------
    // 构建 / 添加行
    // ------------------------------------------------------------------
    /// <summary>开始一轮构建：清空旧行（每次 Show 都从数据源全量重建）。</summary>
    void BeginBuild()
    {
        if (!_built) Build();
        if (_panelRT == null) return;

        ClearRows();
        _signature = Signature();
    }

    void FinishBuild()
    {
        if (_panelRT == null) return;

        if (_rows.Count == 0)
        {
            Hide();
            return;
        }

        Relayout();
        _open = true;
        _panelRT.gameObject.SetActive(true);
        _pollTimer = 0.5f;
        PopupFX.PlayOpen(_panelRT);
    }

    void ClearRows()
    {
        foreach (Row r in _rows) if (r.go != null) Destroy(r.go);
        _rows.Clear();
    }

    void AddPendingSoulRow(SoulIntake.Pending p)
    {
        SoulIntake.Pending captured = p;

        // ★2026-09-12 用户定稿：不写灵魂名字，一行短文案即可
        Row row = CreateRow("魂灯已满　点击处理", RowKind.PendingSoul,
                            () => OpenLanternPanel(captured), captured: p);
        // 挂起条目底色加深（用户定稿「加深一下」）
        Image bg = row.go.GetComponent<Image>();
        if (bg != null) bg.color = new Color(0.30f, 0.10f, 0.06f, 0.95f);
    }

    void AddCardRow(ItemData card)
    {
        ItemData captured = card;
        CreateRow("战利品卡牌　·　点击进行选择", RowKind.CardReward,
                  () => CardRewardPickUI.Show(captured), cardItem: card);
    }

    void AddInfoRow(string text)
    {
        CreateRow(text, RowKind.Info, null);
    }

    Row CreateRow(string text, RowKind kind, UnityEngine.Events.UnityAction onClick,
                  ItemData cardItem = null, SoulIntake.Pending captured = null)
    {
        GameObject go = new GameObject("LootRow_" + _rows.Count, typeof(RectTransform));
        go.transform.SetParent(_panelRT, false);

        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = rt.anchorMax = new Vector2(0f, 0f);
        rt.pivot = new Vector2(0f, 0f);
        float h = kind == RowKind.Info ? InfoRowHeight
                : kind == RowKind.CardReward ? CardRowHeight
                : ActionRowHeight;
        rt.sizeDelta = new Vector2(_panelWidth - Padding * 2f, h);

        Image bg = go.AddComponent<Image>();
        bg.sprite = InventoryUIKit.WhitePixel;
        bg.color = kind == RowKind.CardReward
            ? new Color(0.20f, 0.13f, 0.04f, 0.92f)     // ★卡牌奖励：底色略亮，与告知行区分
            : new Color(0.11f, 0.07f, 0.02f, 0.86f);

        if (kind == RowKind.Info)
        {
            bg.raycastTarget = false;   // 纯告知：不挡点击
        }
        else
        {
            Button btn = go.AddComponent<Button>();
            btn.targetGraphic = bg;      // 过渡效果挂到背景图上
            if (onClick != null) btn.onClick.AddListener(onClick);
        }

        int fontSize = kind == RowKind.CardReward ? CardRowFont : 13;
        Text label = InventoryUIKit.CreateLabel("Label", go.transform, text, fontSize,
                                                InventoryUIKit.Cream, TextAnchor.MiddleLeft);
        label.rectTransform.anchorMin = Vector2.zero;
        label.rectTransform.anchorMax = Vector2.one;
        label.rectTransform.offsetMin = new Vector2(10f, 2f);
        label.rectTransform.offsetMax = new Vector2(-10f, -2f);
        label.raycastTarget = false;

        CanvasGroup cg = go.AddComponent<CanvasGroup>();

        Row row = new Row
        {
            kind = kind,
            go = go,
            cg = cg,
            remaining = kind == RowKind.PendingSoul ? -1f
                      : kind == RowKind.CardReward ? CardStay
                      : InfoStay,
            height = h,
            cardItem = cardItem,
            pending = captured
        };
        _rows.Add(row);
        return row;
    }

    /// <summary>从下往上排布：index 0 贴面板底，往上递增。每条目用自己的高度。</summary>
    void Relayout()
    {
        float total = Padding * 2f - RowSpacing;
        for (int i = 0; i < _rows.Count; i++) total += _rows[i].height + RowSpacing;
        _panelRT.sizeDelta = new Vector2(_panelWidth, total);

        float y = Padding;
        for (int i = 0; i < _rows.Count; i++)
        {
            RectTransform rt = _rows[i].go.GetComponent<RectTransform>();
            rt.anchoredPosition = new Vector2(Padding, y);
            y += _rows[i].height + RowSpacing;
        }
    }

    // ------------------------------------------------------------------
    // Update：逐条目淡出 + 右键关闭 + 低频对账
    // ------------------------------------------------------------------
    void Update()
    {
        if (!_built || _panelRT == null || !_open) return;

        // 低频对账（0.5s）：卡牌物品被用掉 / 挂起灵魂被处理 → 对应行消失
        _pollTimer -= Time.unscaledDeltaTime;
        if (_pollTimer <= 0f)
        {
            _pollTimer = 0.5f;
            int sig = Signature();
            if (sig != _signature)
            {
                _signature = sig;
                ReconcileRows();
            }
        }

        // 有魂灯已满 → 面板常驻（永不淡出、无法关闭），右键天然失效
        bool hasPending = HasPendingRow();

        // 逐条目倒计时（魂灯已满 remaining=-1 不参与）
        for (int i = _rows.Count - 1; i >= 0; i--)
        {
            Row r = _rows[i];
            if (r.fading || r.remaining < 0f) continue;
            r.remaining -= Time.unscaledDeltaTime;
            if (r.remaining <= 0f) FadeRow(r);
        }

        // 右键提前关闭：仅当没有魂灯已满（挂起条目钉住时右键无效）
        if (!hasPending
            && Input.GetMouseButtonDown(1)
            && RectTransformUtility.RectangleContainsScreenPoint(_panelRT, Input.mousePosition))
        {
            foreach (Row r in _rows) if (!r.fading) FadeRow(r);
        }
    }

    bool HasPendingRow()
    {
        for (int i = 0; i < _rows.Count; i++)
            if (_rows[i].kind == RowKind.PendingSoul && !_rows[i].fading) return true;
        return false;
    }

    /// <summary>内容签名：存活卡牌物品数 + 挂起灵魂数。变了才做增删对账。</summary>
    int Signature()
    {
        int alive = 0;
        foreach (ItemData card in BattleRewardLedger.GrantedCardItems)
            if (card != null && InventoryHas(card)) alive++;
        return alive * 100 + SoulIntake.PendingCount;
    }

    /// <summary>
    /// 对账：把「已被外部处理掉」的行移除（卡牌物品被用掉 / 挂起灵魂已 resolved）。
    /// Info 行（魂灯未满/材料）不参与对账，靠自己的倒计时淡出。
    /// </summary>
    void ReconcileRows()
    {
        var toRemove = new List<Row>();
        foreach (Row r in _rows)
        {
            if (r.kind == RowKind.CardReward && (r.cardItem == null || !InventoryHas(r.cardItem)))
                toRemove.Add(r);
            else if (r.kind == RowKind.PendingSoul && (r.pending == null || r.pending.resolved))
                toRemove.Add(r);
        }
        foreach (Row r in toRemove) RemoveRow(r);
    }

    void FadeRow(Row r)
    {
        if (r == null || r.fading || r.go == null) return;
        r.fading = true;
        r.cg.DOKill();
        r.cg.DOFade(0f, FadeDur).SetEase(Ease.InQuad)
          .OnComplete(() => RemoveRow(r));
    }

    void RemoveRow(Row r)
    {
        if (r == null) return;
        _rows.Remove(r);
        if (r.go != null) Destroy(r.go);

        if (_rows.Count == 0)
        {
            Hide();
            return;
        }
        Relayout();
    }

    void Hide()
    {
        _open = false;
        if (_panelRT != null) _panelRT.gameObject.SetActive(false);
    }

    // ------------------------------------------------------------------
    // 构建面板（右下角，结束回合按钮上方）
    // ------------------------------------------------------------------
    void Build()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null) return;

        _panelWidth = MeasurePanelWidth();

        GameObject go = new GameObject("LootClaimPopup", typeof(RectTransform));
        go.transform.SetParent(canvas.transform, false);
        _panelRT = go.GetComponent<RectTransform>();

        // 右下角锚定：pivot(1,0)，锚在结束回合按钮上方，从下往上堆
        _panelRT.anchorMin = _panelRT.anchorMax = new Vector2(1f, 0f);
        _panelRT.pivot = new Vector2(1f, 0f);
        _panelRT.anchoredPosition = ComputeAnchor();
        _panelRT.sizeDelta = new Vector2(_panelWidth, 40f);

        Image bg = go.AddComponent<Image>();
        bg.sprite = InventoryUIKit.WhitePixel;
        bg.color = new Color(0.11f, 0.07f, 0.02f, 0.72f);   // 半透明深棕底
        bg.raycastTarget = false;   // 本体非模态：面板底不挡点击；右键走坐标检测，不依赖 raycast

        _built = true;
    }

    /// <summary>锚点 = 结束回合按钮正上方。找不到按钮时用兜底位置。</summary>
    Vector2 ComputeAnchor()
    {
        GameObject btn = GameObject.Find("UICanvas/EndTurnButton");
        if (btn != null)
        {
            RectTransform brt = btn.transform as RectTransform;
            if (brt != null)
            {
                // 按钮顶部（同 (1,0) 坐标系）= anchoredPosition.y + sizeDelta.y*(1-pivot.y)
                float top = brt.anchoredPosition.y + brt.sizeDelta.y * (1f - brt.pivot.y);
                return new Vector2(-AnchorRightInset, top + 6f);
            }
        }
        return new Vector2(-AnchorRightInset, 230f);   // 兜底：右下角上方
    }

    /// <summary>
    /// 面板宽度 = 面板右边缘（-16）到**结束回合按钮左边缘**的距离 ——
    /// ★2026-09-12 用户定稿「宽度不要超过结束回合按钮的左边」，两条边正好对齐。
    /// 按钮同锚 (1,0)，左边缘 = anchoredPosition.x - sizeDelta.x * pivot.x。
    /// </summary>
    float MeasurePanelWidth()
    {
        GameObject btn = GameObject.Find("UICanvas/EndTurnButton");
        if (btn != null)
        {
            RectTransform brt = btn.transform as RectTransform;
            if (brt != null)
            {
                float left = brt.anchoredPosition.x - brt.sizeDelta.x * brt.pivot.x;
                float w = -AnchorRightInset - left;
                if (w > 120f && w < 900f) return w;   // 合理区间守卫：按钮异常缩放时不至于出怪宽度
            }
        }
        return FallbackPanelWidth;
    }

    // ------------------------------------------------------------------
    // 魂灯处理子窗（真模态；沿用原 BattleSettlementUI Task 20 的灯满子页逻辑）
    // ------------------------------------------------------------------
    void OpenLanternPanel(SoulIntake.Pending p)
    {
        if (p == null || p.resolved) return;
        _handling = p;

        if (!_lanternBuilt) BuildLanternPanel();
        if (_lanternRoot == null) { _handling = null; return; }

        _lanternRoot.gameObject.SetActive(true);
        Interactions.ModalPopupActive = true;
        Interactions.RefreshEndTurnButton();
        RefreshLanternPanel();

        PopupFX.PlayOpen(_lanternPanelRT);
    }

    void BuildLanternPanel()
    {
        _lanternRoot = InventoryUIKit.CreateOverlay("LootLanternPanel");
        if (_lanternRoot == null) return;

        Vector2 size = new Vector2(560f, 540f);
        float half = size.y * 0.5f;

        Image panel = InventoryUIKit.CreatePanel("Panel", _lanternRoot, size, Vector2.zero, InventoryUIKit.PanelBg);
        _lanternPanelRT = panel.rectTransform;
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        Text title = InventoryUIKit.CreateLabel("Title", panel.transform, "魂灯已满 · 销毁一条腾位", 20,
                                                 InventoryUIKit.Brass, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(title.rectTransform, new Vector2(size.x - 40f, 28f), new Vector2(0f, half - 30f));

        _lanternSummary = InventoryUIKit.CreateLabel("Summary", panel.transform, "", 14, InventoryUIKit.Muted,
                                                      TextAnchor.MiddleCenter);
        InventoryUIKit.Place(_lanternSummary.rectTransform, new Vector2(size.x - 40f, 24f), new Vector2(0f, half - 60f));

        Text hint = InventoryUIKit.CreateLabel("Hint", panel.transform,
            "点一条销毁它、把新灵魂收进来　·　「放弃」= 新灵魂消散　·　ESC = 稍后再说",
            14, InventoryUIKit.Cream, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(hint.rectTransform, new Vector2(size.x - 40f, 30f), new Vector2(0f, -half + 84f));

        InventoryUIKit.CreateButton("ForfeitButton", panel.transform, "放弃这条", new Vector2(150f, 36f),
                                    new Vector2(-110f, -half + 36f), ForfeitPending);
        InventoryUIKit.CreateButton("BackButton", panel.transform, "返回", new Vector2(150f, 36f),
                                    new Vector2(110f, -half + 36f), CloseLanternPanel);

        _lanternBuilt = true;
    }

    void RefreshLanternPanel()
    {
        if (_lanternRoot == null || _handling == null) return;

        InventoryManager mgr = InventoryManager.Instance != null
            ? InventoryManager.Instance
            : Object.FindObjectOfType<InventoryManager>();
        if (mgr == null) return;
        SoulLantern lantern = mgr.Inventory.Lantern;

        string name = _handling.soul != null ? _handling.soul.itemName : "?";
        _lanternSummary.text = $"要收进来：{name}（来自「{_handling.source}」）　·　魂灯 {lantern.Count}/{SoulLantern.Capacity}";

        foreach (GameObject row in _lanternRows) Destroy(row);
        _lanternRows.Clear();

        for (int i = 0; i < lantern.Count; i++)
        {
            ItemData soul = lantern.Souls[i];
            int index = i;
            string text = $"{(soul != null ? soul.itemName : "（空）")}　·　点击销毁它，腾出位置";
            Button btn = InventoryUIKit.CreateButton($"Lantern_{i}", _lanternPanelRT, text,
                                                     new Vector2(500f, 30f), LanternRowPos(i),
                                                     () => ResolvePending(index));
            StyleRow(btn);
            _lanternRows.Add(btn.gameObject);
        }
    }

    Vector2 LanternRowPos(int row)
    {
        float top = 540f * 0.5f - 84f;
        return new Vector2(0f, top - row * (30f + 3f) - 15f);
    }

    void ResolvePending(int lanternIndex)
    {
        if (_handling == null) return;
        if (SoulIntake.ResolveByDestroying(_handling, lanternIndex))
        {
            CloseLanternPanel();
            ReconcileRows();        // 挂起条目消失；全空则 Hide
        }
    }

    void ForfeitPending()
    {
        if (_handling == null) return;
        SoulIntake.Discard(_handling);
        CloseLanternPanel();
        ReconcileRows();
    }

    void CloseLanternPanel()
    {
        _handling = null;
        foreach (GameObject row in _lanternRows) Destroy(row);
        _lanternRows.Clear();
        if (_lanternRoot != null) _lanternRoot.gameObject.SetActive(false);
        Interactions.ModalPopupActive = false;
        Interactions.RefreshEndTurnButton();
    }

    static void StyleRow(Button btn)
    {
        Text label = btn.GetComponentInChildren<Text>();
        if (label == null) return;
        label.fontSize = 13;
        label.alignment = TextAnchor.MiddleLeft;
        label.rectTransform.offsetMin = new Vector2(10f, 2f);
        label.rectTransform.offsetMax = new Vector2(-10f, -2f);
    }
}

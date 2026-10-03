// =============================================================================
// 模块：M7 背包系统 - CardPackUI 卡包界面（2026-09-10 重做）
// 用途：展示当局牌库（CardDeckManager.Library）的**完整卡面** + 竖向滚动；
//       右侧新增「战术卡槽」边栏——**2 格上下一列竖排**，把卡拖进某一格 = 装载该格，
//       拖出/点击 = 卸下。
// 设计依据：docs/superpowers/specs/2026-09-10-卡包装载与战术槽装帧-design.md
//           2026-09-08-背包系统-design.md §4 卡包（独立模块）/ §5 战术卡槽
// 装载入口：**只有这里**（战斗内 TacticSlotsPanel 只负责"使用"，不负责装载）
// 拖拽方式：**幽灵卡**——不搬动网格里的原卡（否则 GridLayoutGroup 重排、卡位跳动），
//           起手时另建一张卡面跟随鼠标，松手落在哪个槽格内 = 装进哪格。
// 事件路由：CardView.PackHost == this 时，CardView 把点击/拖拽/悬停转发到本面板
//           （仿 TacticSlotsPanel.TacticHost 与 EventPopupUI.IsPanelCard 的既有先例）。
//
// ★2026-09-12 教程图：**不铺右侧战术卡槽边栏**（整套战术卡槽在教程里未解锁）。
//   主区卡面网格顺势横向居中；装载/卸下门禁（TacticAdjustAllowed）也直接判死。
//   教程结束后（正式图）边栏照旧，装载规则不变。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class CardPackUI : MonoBehaviour
{
    static CardPackUI _instance;
    public static CardPackUI Instance => _instance;

    [Header("布局（[PLACEHOLDER · 待调]）")]
    public Vector2 PanelSize = new Vector2(1240f, 680f);
    [Tooltip("主区滚动框（完整卡面网格）")]
    public Vector2 GridAreaSize = new Vector2(880f, 540f);
    public Vector2 GridAreaPos = new Vector2(-160f, -20f);
    [Tooltip("列数上限（5 列 = 5×154 + 4×16 = 834，刚好放进 880）")]
    public int GridColumns = 5;
    public Vector2 GridSpacing = new Vector2(16f, 16f);
    [Tooltip("边栏（战术卡槽：★2 列 × 无限行 + 竖向滚动）")]
    public Vector2 SidebarSize = new Vector2(300f, 540f);
    public Vector2 SidebarPos = new Vector2(455f, -20f);
    [Tooltip("边栏槽内卡面缩放（叠加在预制体 scale 之上）——两列并排要塞进边栏宽度")]
    public float SlotCardScale = 0.78f;
    [Tooltip("槽格间距（列间距 / 行间距）")]
    public Vector2 SlotCellSpacing = new Vector2(8f, 8f);
    [Tooltip("边栏内的滚动视口尺寸（行数由槽内卡量决定，超出即竖向滚动）")]
    public Vector2 SlotGridSize = new Vector2(276f, 380f);
    [Tooltip("滚动视口中心相对边栏中心")]
    public Vector2 SlotGridPos = new Vector2(0f, 10f);

    [Tooltip("卡牌视图预制体（留空则运行时从 HandUIController 解析）")]
    public CardView CardViewPrefab;

    // ------------------------------------------------------------------
    // 运行时
    // ------------------------------------------------------------------

    RectTransform _root, _content, _sidebar;
    RectTransform _slotGridArea, _slotContent;      // ★边栏内的 2 列滚动网格（视口 / 内容）
    Text _hint;

    // 边栏战术槽（★2 列 × 无限行；按 TacticSlotRuntime.DisplaySlotCount 建格）
    readonly List<RectTransform> _slotCells = new List<RectTransform>();
    readonly List<CardView> _slotCards = new List<CardView>();
    readonly List<TacticSlotFrame> _slotFrames = new List<TacticSlotFrame>();
    readonly List<Image> _slotBgs = new List<Image>();

    readonly List<CardView> _gridViews = new List<CardView>();
    readonly Dictionary<CardView, Card> _gridMap = new Dictionary<CardView, Card>();

    // 幽灵卡拖拽
    CardView _ghost;
    CardView _dragSource;
    Card _dragCard;
    bool _dragFromSlot;
    Vector2 _dragPointer;

    // 从预制体解析出的卡面几何（自适配：不写死 110×154 / 1.4）
    Vector2 _cardDesignSize = new Vector2(110f, 154f);
    float _cardScale = 1f;

    bool _built, _isOpen;

    // ------------------------------------------------------------------
    // ★选牌模式（design 荒野事件 §3.4）：复用本面板的真卡面与滚动网格
    // ------------------------------------------------------------------
    private bool _pickMode;
    private int _pickCount;
    private string _pickTitle;
    private System.Action<List<Card>> _onPicked;
    private readonly List<Card> _picked = new List<Card>();
    private GameObject _pickBar;
    private Text _pickTip;
    private Button _pickConfirmBtn;

    public bool IsOpen => _isOpen;

    /// <summary>★2026-09-13 教学钩子：卡包界面被打开。零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnCardPackOpened;

    /// <summary>★2026-09-13 教学钩子：玩家**真正关掉**了卡包界面（S33 装填收尾用）。
    /// 注意：点「装填」进装填界面也会先走一次 Hide() —— 教学拍按 release 类型分流，不受影响。</summary>
    public static event System.Action OnCardPackClosed;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void Start()
    {
        if (!_built) Build();
    }

    private void OnDestroy()
    {
        if (_instance == this) _instance = null;
        TacticSlotRuntime.OnChanged -= OnSlotChanged;
        _built = false;
    }

    void OnSlotChanged()
    {
        if (!_built) return;
        EnsureSidebarCells();     // ★格子数变了先重建（2 列 × 无限行 → 行数随卡量增长）
        RefreshLooks();
        RefreshSidebar();
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------

    void Build()
    {
        ResolvePrefab();

        // ★防重复叠加（踩坑防线）：编辑器里反复 Build()/Show()（菜单、测试脚本、反复开关）
        //   会叠出多个 "CardPackPanel" 根。它们不在场景文件里，但**是场景对象**，
        //   进入 Play 会被一起带进去 —— 曾出现「画面上多出一套卡包 + 一个游离的『新卡牌』卡面」。
        //   开建之前先把本会话遗留的旧根清掉（资源/预制体不动，只清场景对象）。
        Transform[] staleAll = Resources.FindObjectsOfTypeAll<Transform>();
        for (int i = 0; i < staleAll.Length; i++)
        {
            Transform st = staleAll[i];
            if (st == null || st.name != "CardPackPanel") continue;
            if (!st.gameObject.scene.IsValid()) continue;      // 空 scene = 资源，跳过
            Destroy(st.gameObject);
        }

        _root = InventoryUIKit.CreateOverlay("CardPackPanel");
        if (_root == null) return;

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, PanelSize, Vector2.zero, InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        float halfW = PanelSize.x * 0.5f;
        float halfH = PanelSize.y * 0.5f;

        // ★2026-09-12 教程图：整套战术卡槽未解锁 —— 不铺右侧边栏，主区网格顺势居中。
        //   为什么不是「铺了再隐藏」：铺格会建 Button/Outline/装帧 一堆节点，
        //   隐藏只是看不见、仍然存在；教程里干脆不建，连拖拽落点判定都不存在。
        bool showTacticSidebar = !MapLayoutBuilder.IsTutorial;
        float gridX = showTacticSidebar ? GridAreaPos.x : 0f;
        float titleX = showTacticSidebar ? -170f : 0f;

        // 标题 + 副提示
        Text title = InventoryUIKit.CreateLabel("Title", panel.transform, "卡包", 24, InventoryUIKit.Brass,
                                                TextAnchor.UpperLeft);
        InventoryUIKit.Place(title.rectTransform, new Vector2(900f, 34f), new Vector2(titleX, halfH - 30f));

        Text sub = InventoryUIKit.CreateLabel("SubTitle", panel.transform, "当局牌库（完整卡面）", 14,
                                              InventoryUIKit.Muted, TextAnchor.UpperLeft);
        InventoryUIKit.Place(sub.rectTransform, new Vector2(GridAreaSize.x, 24f), new Vector2(gridX, halfH - 62f));

        // 主区：完整卡面滚动网格
        RectTransform gridArea = InventoryUIKit.CreateScrollGrid("CardGrid", panel.transform, GridAreaSize,
                                                                 new Vector2(gridX, GridAreaPos.y), CellSize,
                                                                 GridSpacing, GridColumns, out _content);
        if (gridArea == null) Debug.LogWarning("[CardPackUI] 卡面网格创建失败");

        // 边栏：战术卡槽（教程图不建）
        if (showTacticSidebar) BuildSidebar(panel.transform, halfW, halfH);
        else Debug.Log("[CardPackUI] 教程图：卡包不铺战术卡槽边栏");

        // 底部按钮
        InventoryUIKit.CreateButton("LoadoutButton", panel.transform, "装填", new Vector2(110f, 40f),
                                    new Vector2(-90f, -halfH + 26f), OpenLoadout);
        InventoryUIKit.CreateButton("CloseButton", panel.transform, "关闭", new Vector2(110f, 40f),
                                    new Vector2(60f, -halfH + 26f), Hide);

        _built = true;
    }

    /// <summary>边栏 = 标题 + N 个竖排槽格（战术槽装帧）+ 提示行。</summary>
    void BuildSidebar(Transform panel, float halfW, float halfH)
    {
        Image side = InventoryUIKit.CreatePanel("TacticSidebar", panel, SidebarSize, SidebarPos,
                                               new Color(0.07f, 0.045f, 0.015f, 0.98f));
        Outline ol = side.gameObject.AddComponent<Outline>();
        ol.effectColor = InventoryUIKit.Gold;
        ol.effectDistance = new Vector2(2f, -2f);
        _sidebar = side.rectTransform;

        Text head = InventoryUIKit.CreateLabel("Header", _sidebar, "战术卡槽", 18, InventoryUIKit.Brass,
                                               TextAnchor.MiddleCenter);
        InventoryUIKit.Place(head.rectTransform, new Vector2(270f, 28f), new Vector2(0f, SidebarSize.y * 0.5f - 26f));

        Text tip = InventoryUIKit.CreateLabel("Tip", _sidebar, "拖卡进来装载", 13, InventoryUIKit.Muted,
                                              TextAnchor.MiddleCenter);
        InventoryUIKit.Place(tip.rectTransform, new Vector2(270f, 22f), new Vector2(0f, SidebarSize.y * 0.5f - 52f));

        // ★2026-09-10 三次定稿：边栏战术槽 = **2 列 × 无限行 + 竖向滚动**
        //   （与战斗内战术面板同一套布局：左右横着 2 格，竖着随卡量无限下拉）
        _slotGridArea = InventoryUIKit.CreateScrollGrid("TacticSlotGrid", _sidebar, SlotGridSize, SlotGridPos,
                                                        SidebarCellSize, SlotCellSpacing,
                                                        TacticSlotRuntime.Columns, out _slotContent);
        if (_slotGridArea == null) Debug.LogWarning("[CardPackUI] 战术槽滚动网格创建失败");

        RebuildSidebarGrid();

        _hint = InventoryUIKit.CreateLabel("Hint", _sidebar, "", 13, InventoryUIKit.Muted, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(_hint.rectTransform, new Vector2(272f, 60f), new Vector2(0f, -SidebarSize.y * 0.5f + 34f));
        _hint.horizontalOverflow = HorizontalWrapMode.Wrap;
    }

    /// <summary>边栏槽格视觉尺寸 = 卡面设计尺寸 × 预制体缩放 × SlotCardScale。</summary>
    Vector2 SidebarCellSize
    {
        get
        {
            return new Vector2(_cardDesignSize.x * _cardScale * SlotCardScale,
                               _cardDesignSize.y * _cardScale * SlotCardScale);
        }
    }

    /// <summary>
    /// 按 DisplaySlotCount 重建边栏槽格（★2 列 × 无限行）。
    /// 只有「格子数变了」才需要重建；内容/CD 变化走 RefreshSidebar，避免卡位跳动。
    /// </summary>
    void RebuildSidebarGrid()
    {
        if (_slotContent == null) return;

        // 销毁旧格（连带其子节点：装帧 + 卡面）
        for (int i = 0; i < _slotCells.Count; i++)
        {
            if (_slotCells[i] != null) Destroy(_slotCells[i].gameObject);
        }
        _slotCells.Clear();
        _slotCards.Clear();
        _slotFrames.Clear();
        _slotBgs.Clear();

        Vector2 cellSize = SidebarCellSize;
        int slotCount = TacticSlotRuntime.DisplaySlotCount;

        for (int i = 0; i < slotCount; i++)
        {
            RectTransform cell = InventoryUIKit.CreateRect("TacticSlotCell" + (i + 1), _slotContent);

            Image bg = cell.gameObject.AddComponent<Image>();
            bg.sprite = InventoryUIKit.WhitePixel;
            bg.color = InventoryUIKit.SlotBg;
            Outline col = cell.gameObject.AddComponent<Outline>();
            col.effectColor = new Color(0.55f, 0.44f, 0.28f, 0.7f);
            col.effectDistance = new Vector2(1f, -1f);

            _slotCells.Add(cell);
            _slotBgs.Add(bg);
            // 战术槽装帧（自设为第一个子节点 → 光晕画在卡面之后）
            _slotFrames.Add(TacticSlotFrame.Attach(cell, cellSize));
            // 槽内卡面（常驻，空槽时隐藏；比网格卡小一号，两列才排得下）
            _slotCards.Add(CreateCardView(cell, cellSize, SlotCardScale));

            // 槽格可点（点空槽给提示；点有卡=卸下由卡面转发，这里兜底空槽点击）。
            // for 循环变量不按迭代捕获 → 必须 copy 出 captured，否则回调里拿到的是槽数。
            int captured = i;
            Button cellBtn = cell.gameObject.AddComponent<Button>();
            cellBtn.targetGraphic = bg;
            cellBtn.onClick.AddListener(() => OnSlotCellClicked(captured));
        }
    }

    /// <summary>槽格数与当前应显示数不一致就重建（装载/卸下跨行时触发）。</summary>
    void EnsureSidebarCells()
    {
        if (_slotContent == null) return;                 // ★教程图：边栏根本没建
        if (_slotCards.Count != TacticSlotRuntime.DisplaySlotCount) RebuildSidebarGrid();
    }

    void ResolvePrefab()
    {
        if (CardViewPrefab == null && HandUIController.Instance != null)
        {
            CardViewPrefab = HandUIController.Instance.CardViewPrefab;
        }
        if (CardViewPrefab == null && CardViewCreator.Instance != null)
        {
            CardViewPrefab = CardViewCreator.Instance.CardViewPrefab;
        }

        if (CardViewPrefab != null)
        {
            RectTransform prt = CardViewPrefab.transform as RectTransform;
            if (prt != null && prt.sizeDelta.x > 1f && prt.sizeDelta.y > 1f) _cardDesignSize = prt.sizeDelta;
            float s = CardViewPrefab.transform.localScale.x;
            _cardScale = (s > 0.01f) ? s : 1f;
        }
        else
        {
            Debug.LogError("[CardPackUI] CardViewPrefab 解析失败：卡包无法显示卡面");
        }
    }

    /// <summary>槽格视觉尺寸 = 卡面设计尺寸 × 预制体缩放（布局按矩形算，缩放只是视觉溢出）。</summary>
    Vector2 CellSize => new Vector2(_cardDesignSize.x * _cardScale, _cardDesignSize.y * _cardScale);

    CardView CreateCardView(RectTransform parent, Vector2 boxSize, float scaleFactor = 1f)
    {
        if (CardViewPrefab == null || parent == null) return null;

        CardView cv = Instantiate(CardViewPrefab, parent);
        cv.name = "PackCard";
        cv.PackHost = this;                                  // ★事件路由回本面板
        cv.transform.localScale = Vector3.one * (_cardScale * scaleFactor);

        RectTransform rt = cv.transform as RectTransform;
        if (rt != null)
        {
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.sizeDelta = _cardDesignSize;                   // 格内居中；视觉尺寸由 localScale 决定
            rt.anchoredPosition = Vector2.zero;
        }
        return cv;
    }

    // ------------------------------------------------------------------
    // 显隐
    // ------------------------------------------------------------------

    public void Show()
    {
        if (!_built) Build();
        if (_root == null) return;

        _isOpen = true;
        _root.gameObject.SetActive(true);
        PopupFX.PlayOpen(_root);                        // ★2026-09-12 统一入场手感
        OnCardPackOpened?.Invoke();                     // ★教学钩子（教程 S25 用）

        TacticSlotRuntime.OnChanged -= OnSlotChanged;
        TacticSlotRuntime.OnChanged += OnSlotChanged;

        // ★2026-09-10：槽内卡骰值兜底（force=false —— 已有骰点不动，只补从没掷过的）。
        //   没有这一步，边栏卡面会停在 [1+战斗骰子1] 占位，与手牌卡面
        //   「最终值 + 悬停算式小窗」的体感不一致（用户报的 bug）。
        DicePayment.RefreshSlotDice(false);

        // ★2026-09-10：槽内卡骰值兜底（force=false —— 已有骰点不动，只补从没掷过的）。
        //   没有这一步，边栏卡面会停在 [1+战斗骰子1] 占位，与手牌卡面
        //   「最终值 + 悬停算式小窗」的体感不一致（用户报的 bug）。
        DicePayment.RefreshSlotDice(false);

        RebuildGrid();
        EnsureSidebarCells();
        RefreshSidebar();

        if (_pickMode)
        {
            EnsurePickBar();
            RefreshPickState();
            return;                       // 选牌模式不碰战术槽侧栏与篝火门禁
        }

        // ★2026-09-11 篝火门禁：站在篝火格上才可调整战术槽；否则为查看模式
        if (BonfireTile.IsPlayerOnBonfire())
        {
            SetHint(TacticSlotRuntime.OccupiedCount > 0
                ? "篝火·战术卡槽调整中：点击或拖拽可装载、卸下；冷却中的卡取不出来"
                : "篝火·战术卡槽调整中：从左侧把卡拖到槽格即可装载", InventoryUIKit.Cream);
        }
        else
        {
            SetHint("战术卡槽仅在篝火处可调整，当前为查看模式", InventoryUIKit.Muted);
        }
    }

    public void Hide()
    {
        bool wasOpen = _isOpen;
        // 拖动中关闭 → 幽灵卡必须销毁，否则残留一个悬空卡面
        DestroyGhost();
        ResetDragState();
        DestroyGrid();
        RefreshSidebar();

        if (_pickMode)
        {
            _pickMode = false;
            _picked.Clear();
            _onPicked = null;
            DestroyPickBar();
        }

        _isOpen = false;
        TacticSlotRuntime.OnChanged -= OnSlotChanged;
        if (_root != null) _root.gameObject.SetActive(false);
        if (wasOpen) OnCardPackClosed?.Invoke();        // ★教学钩子：只在"真开着→关"的沿上广播
    }

    public void Toggle()
    {
        if (_isOpen) Hide();
        else Show();
    }

    /// <summary>
    /// 打开选牌模式（design §3.4）。candidates = **完整牌库**（用户 2026-09-16 拍板：
    /// 战术槽内的卡、已装填的卡都能删，不做排除）。
    /// 选满 count 张后按确认 → 回调 onPicked → 自动关闭。
    /// </summary>
    public void OpenPickMode(int count, string title, System.Action<List<Card>> onPicked)
    {
        if (count <= 0) { onPicked?.Invoke(new List<Card>()); return; }

        _pickMode = true;
        _pickCount = count;
        _pickTitle = title;
        _onPicked = onPicked;
        _picked.Clear();
        Show();
    }

    /// <summary>可选卡判定（用户 2026-09-16 拍板：按完整牌库算，只挡空引用）。</summary>
    public static bool IsPickable(Card card)
    {
        return card != null && card.Data != null;
    }

    private void Update()
    {
        if (!_isOpen) return;
        if (Input.GetKeyDown(KeyCode.Escape)) Hide();      // ★2026-09-11：卡包界面 ESC 关闭（与装填→卡包返回链闭合）
    }

    void OpenLoadout()
    {
        LoadoutUI loadout = FindObjectOfType<LoadoutUI>();
        if (loadout == null)
        {
            Debug.LogWarning("[CardPackUI] UICanvas 上没有 LoadoutUI 组件（先跑 Tools/背包/4. 挂载 UI 组件到 UICanvas）");
            return;
        }
        Hide();
        LoadoutUI.Open();
    }

    // ------------------------------------------------------------------
    // ★选牌模式（design 荒野事件 §3.4）
    // ------------------------------------------------------------------

    void EnsurePickBar()
    {
        if (_pickBar != null) { _pickBar.SetActive(true); return; }
        if (_root == null) return;

        RectTransform bar = InventoryUIKit.CreateRect("PickBar", _root);
        bar.anchorMin = new Vector2(0f, 0f);
        bar.anchorMax = new Vector2(1f, 0f);
        bar.pivot = new Vector2(0.5f, 0f);
        bar.sizeDelta = new Vector2(0f, 64f);
        bar.anchoredPosition = new Vector2(0f, 8f);

        Image bg = bar.gameObject.AddComponent<Image>();
        bg.sprite = InventoryUIKit.WhitePixel;
        bg.color = new Color(0.06f, 0.04f, 0.02f, 0.92f);

        _pickTip = InventoryUIKit.CreateLabel("Tip", bar, "", 18, InventoryUIKit.Cream, TextAnchor.MiddleLeft);
        RectTransform tipRT = _pickTip.rectTransform;
        tipRT.anchorMin = new Vector2(0f, 0f);
        tipRT.anchorMax = new Vector2(0.7f, 1f);
        tipRT.offsetMin = new Vector2(20f, 0f);
        tipRT.offsetMax = Vector2.zero;

        RectTransform btnRT = InventoryUIKit.CreateRect("Confirm", bar);
        btnRT.anchorMin = new Vector2(0.72f, 0.15f);
        btnRT.anchorMax = new Vector2(0.98f, 0.85f);
        btnRT.offsetMin = btnRT.offsetMax = Vector2.zero;

        Image btnBg = btnRT.gameObject.AddComponent<Image>();
        btnBg.sprite = InventoryUIKit.WhitePixel;
        btnBg.color = InventoryUIKit.Brass;

        _pickConfirmBtn = btnRT.gameObject.AddComponent<Button>();
        _pickConfirmBtn.targetGraphic = btnBg;
        Text bt = InventoryUIKit.CreateLabel("Label", btnRT, "确 认", 20,
                                             InventoryUIKit.PanelBg, TextAnchor.MiddleCenter);
        InventoryUIKit.Stretch(bt.rectTransform);
        _pickConfirmBtn.onClick.AddListener(OnPickConfirmed);

        _pickBar = bar.gameObject;
        _pickBar.transform.SetAsLastSibling();
    }

    void DestroyPickBar()
    {
        if (_pickBar != null) Destroy(_pickBar);
        _pickBar = null;
        _pickTip = null;
        _pickConfirmBtn = null;
    }

    void TogglePick(CardView cv)
    {
        Card card = null;
        if (cv != null) _gridMap.TryGetValue(cv, out card);
        if (card == null) return;

        if (_picked.Contains(card))
        {
            _picked.Remove(card);
        }
        else
        {
            if (_picked.Count >= _pickCount)
            {
                SetHint($"最多选 {_pickCount} 张", InventoryUIKit.Muted);
                return;
            }
            _picked.Add(card);
        }
        ApplyPickLook(cv, _picked.Contains(card));
        RefreshPickState();
    }

    /// <summary>选中标记（复用 EquippedBadge 的成套视觉，另起一个「已选」角标）。</summary>
    static void ApplyPickLook(CardView cv, bool on)
    {
        if (cv == null) return;
        Transform old = cv.transform.Find("PickedBadge");
        if (on && old == null)
        {
            RectTransform plate = InventoryUIKit.CreateRect("PickedBadge", cv.transform);
            plate.anchorMin = plate.anchorMax = new Vector2(0.5f, 0f);
            plate.pivot = new Vector2(0.5f, 0f);
            plate.sizeDelta = new Vector2(84f, 20f);
            plate.anchoredPosition = new Vector2(0f, 4f);

            Image bg = plate.gameObject.AddComponent<Image>();
            bg.sprite = InventoryUIKit.WhitePixel;
            bg.color = new Color(0.10f, 0.06f, 0.02f, 0.95f);
            bg.raycastTarget = false;

            Outline oln = plate.gameObject.AddComponent<Outline>();
            oln.effectColor = InventoryUIKit.Cream;
            oln.effectDistance = new Vector2(1f, -1f);

            Text t = InventoryUIKit.CreateLabel("Label", plate, "已选", 12,
                                                InventoryUIKit.Brass, TextAnchor.MiddleCenter);
            InventoryUIKit.Stretch(t.rectTransform);
        }
        else if (!on && old != null)
        {
            Destroy(old.gameObject);
        }
    }

    void RefreshPickState()
    {
        if (_pickTip != null)
            _pickTip.text = $"{_pickTitle}　已选 {_picked.Count}/{_pickCount}";
        if (_pickConfirmBtn != null)
        {
            bool ok = _picked.Count == _pickCount;
            _pickConfirmBtn.interactable = ok;
            Image img = _pickConfirmBtn.targetGraphic as Image;
            if (img != null) img.color = ok ? InventoryUIKit.Brass : InventoryUIKit.Muted;
        }
    }

    void OnPickConfirmed()
    {
        if (_picked.Count != _pickCount) return;
        List<Card> result = new List<Card>(_picked);
        System.Action<List<Card>> cb = _onPicked;
        Hide();                                // Hide 会清 _pickMode/_picked/_onPicked
        cb?.Invoke(result);
    }

    // ------------------------------------------------------------------
    // 网格（完整卡面）
    // ------------------------------------------------------------------

    void RebuildGrid()
    {
        DestroyGrid();
        if (_content == null) return;

        CardDeckManager dm = CardDeckManager.Instance;
        if (dm == null || dm.Library == null || dm.Library.Count == 0)
        {
            Text empty = InventoryUIKit.CreateLabel("EmptyHint", _content, "（牌库为空）", 16,
                                                    InventoryUIKit.Muted, TextAnchor.MiddleCenter);
            RectTransform ert = empty.rectTransform;
            ert.anchorMin = ert.anchorMax = new Vector2(0.5f, 1f);
            ert.pivot = new Vector2(0.5f, 1f);
            ert.sizeDelta = new Vector2(GridAreaSize.x - 20f, 40f);
            ert.anchoredPosition = new Vector2(0f, -20f);
            return;
        }

        foreach (Card card in dm.Library)
        {
            if (card == null) continue;
            if (_pickMode && !IsPickable(card)) continue;      // 选牌模式只列可选的

            CardView cv = CreateCardView(_content, CellSize);
            if (cv == null) break;

            cv.SetCard(card);
            cv.InteractionLocked = false;
            cv.gameObject.SetActive(true);

            _gridViews.Add(cv);
            _gridMap[cv] = card;
        }

        if (_pickMode) { _picked.Clear(); RefreshPickState(); return; }   // 选牌模式不做「已装载」外观
        RefreshLooks();
    }

    void DestroyGrid()
    {
        foreach (CardView cv in _gridViews)
        {
            if (cv != null) Destroy(cv.gameObject);
        }
        _gridViews.Clear();
        _gridMap.Clear();

        // 空库提示节点也一并清（它没有登记在 _gridViews）
        if (_content != null)
        {
            Transform t = _content.Find("EmptyHint");
            if (t != null) Destroy(t.gameObject);
        }
    }

    /// <summary>只刷新「已装载」外观（压暗 + 角标），不重建节点——装载/卸下后调它，避免卡位跳动。</summary>
    void RefreshLooks()
    {
        foreach (KeyValuePair<CardView, Card> kv in _gridMap)
        {
            if (kv.Key == null) continue;
            ApplyEquippedLook(kv.Key, TacticSlotRuntime.Contains(kv.Value));
        }
    }

    /// <summary>已装载的卡在网格里压暗 + 挂「战术槽」角标（它已不在抽牌堆，玩家要看得见）。</summary>
    static void ApplyEquippedLook(CardView cv, bool on)
    {
        if (cv == null) return;

        CanvasGroup cg = cv.GetComponent<CanvasGroup>();       // 预制体自带，取用即可
        if (cg == null) cg = cv.gameObject.AddComponent<CanvasGroup>();
        cg.alpha = on ? 0.45f : 1f;

        Transform old = cv.transform.Find("EquippedBadge");
        if (on && old == null)
        {
            RectTransform plate = InventoryUIKit.CreateRect("EquippedBadge", cv.transform);
            plate.anchorMin = plate.anchorMax = new Vector2(0.5f, 0f);
            plate.pivot = new Vector2(0.5f, 0f);
            plate.sizeDelta = new Vector2(84f, 20f);
            plate.anchoredPosition = new Vector2(0f, 4f);

            Image bg = plate.gameObject.AddComponent<Image>();
            bg.sprite = InventoryUIKit.WhitePixel;
            bg.color = new Color(0.10f, 0.06f, 0.02f, 0.95f);
            bg.raycastTarget = false;                        // 别挡住卡面点击

            Outline oln = plate.gameObject.AddComponent<Outline>();
            oln.effectColor = InventoryUIKit.Gold;
            oln.effectDistance = new Vector2(1f, -1f);

            Text t = InventoryUIKit.CreateLabel("Label", plate, "战术槽", 12, InventoryUIKit.Brass,
                                                TextAnchor.MiddleCenter);
            InventoryUIKit.Stretch(t.rectTransform);
        }
        else if (!on && old != null)
        {
            Destroy(old.gameObject);
        }
    }

    // ------------------------------------------------------------------
    // 边栏（战术卡槽）
    // ------------------------------------------------------------------

    /// <summary>按 TacticSlotRuntime 刷新**每一个**竖排槽格（有卡亮装帧 / 冷却熄灭 / 空槽隐藏）。</summary>
    void RefreshSidebar()
    {
        EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();

        for (int i = 0; i < _slotCards.Count; i++)
        {
            CardView cv = _slotCards[i];
            if (cv == null) continue;

            Card card = TacticSlotRuntime.Get(i);
            int cd = TacticSlotRuntime.GetCooldown(i);
            bool occupied = card != null && card.Data != null;

            if (occupied)
            {
                if (!ReferenceEquals(cv.CardData, card.Data)) cv.SetCard(card);
                cv.gameObject.SetActive(true);
                if (i < _slotFrames.Count && _slotFrames[i] != null)
                {
                    _slotFrames[i].SetOccupied(true);
                    _slotFrames[i].SetLit(cd <= 0);
                }
                if (epd != null) cv.SetEnergyAffordable(epd.CanAfford(card.CurrentCost));
            }
            else
            {
                cv.gameObject.SetActive(false);
                if (i < _slotFrames.Count && _slotFrames[i] != null) _slotFrames[i].SetOccupied(false);
            }

            if (i < _slotBgs.Count && _slotBgs[i] != null) _slotBgs[i].color = InventoryUIKit.SlotBg;
        }
    }

    void OnSlotCellClicked(int index)
    {
        if (!TacticAdjustAllowed())
        {
            SetHint("战术卡槽仅在篝火处可调整，当前为查看模式", InventoryUIKit.Muted);
            return;
        }
        if (TacticSlotRuntime.Get(index) == null)
        {
            SetHint($"槽 {index + 1} 是空的：把左侧卡面拖进来装载", InventoryUIKit.Muted);
        }
    }

    // ------------------------------------------------------------------
    // CardView 路由：悬停 / 点击 / 拖拽
    // ------------------------------------------------------------------

    public void OnPackCardHovered(CardView cv, bool on)
    {
        // 悬停某个槽内卡 → 该格装帧联动发光
        int idx = _slotCards.IndexOf(cv);
        if (idx >= 0 && idx < _slotFrames.Count && _slotFrames[idx] != null) _slotFrames[idx].SetHover(on);
    }

    public void OnPackCardClicked(CardView cv)
    {
        if (cv == null) return;

        // ★选牌模式（design §3.4）：点击 = 选中/取消，不走装载/卸下逻辑
        if (_pickMode)
        {
            if (_gridMap.ContainsKey(cv)) TogglePick(cv);
            return;
        }

        // 点槽内卡 = 卸下该槽
        int slotIdx = _slotCards.IndexOf(cv);
        if (slotIdx >= 0)
        {
            Card held = TacticSlotRuntime.Get(slotIdx);
            if (held != null && held.Data != null)
            {
                // ★2026-09-10（用户定稿）：鉴定事件开着时，点槽内卡 = 把它送进 DISCARD 面板
                //   参与弃牌鉴定 —— 战术槽不再是「躲避弃牌的保险箱」，藏在槽里的卡照样能被弃。
                //   弹窗关着时（常态）才是普通的「点击卸下回牌库」。
                //   FindObjectOfType 默认只看 active 对象：弹窗收起时它天然返回 null，
                //   所以这里不需要额外判 activeSelf。
                EventPopupUI popup = FindObjectOfType<EventPopupUI>();
                if (popup != null && popup.IsCheckPanelOpen && popup.FlySlotCardToDiscardPanel(held))
                {
                    SetHint($"{held.Data.cardName} 已送去弃牌鉴定", InventoryUIKit.Cream);
                    RefreshSidebar();
                    RefreshLooks();
                    return;
                }

                // ★2026-09-11 篝火门禁：非篝火 = 查看模式，不可卸下（事件弃牌鉴定已在上方面走，不受此限）
                if (!TacticAdjustAllowed())
                {
                    SetHint("战术卡槽仅在篝火处可调整，当前为查看模式", InventoryUIKit.Muted);
                    return;
                }

                // ★v9：冷却中的卡锁在槽里（用完就想换下一张 = 每回合白嫖一次战术效果）
                if (!TacticSlotRuntime.CanUnequip(slotIdx))
                {
                    SetHint($"{held.Data.cardName} 冷却中（剩 {TacticSlotRuntime.GetCooldown(slotIdx)} 回合）：取不出来",
                            InventoryUIKit.Muted);
                    return;
                }

                TacticSlotRuntime.Unequip(slotIdx);
                SetHint($"已卸下 {held.Data.cardName}（回牌库）", InventoryUIKit.Muted);
            }
            return;
        }

        Card card = CardOf(cv);
        if (card == null) return;

        if (TacticSlotRuntime.Contains(card))
        {
            SetHint($"{card.Data.cardName} 已在战术卡槽内", InventoryUIKit.Muted);
            return;
        }

        // ★2026-09-11 篝火门禁：非篝火 = 查看模式，不可装载
        if (!TacticAdjustAllowed())
        {
            SetHint("战术卡槽仅在篝火处可调整，当前为查看模式", InventoryUIKit.Muted);
            return;
        }

        // 点击装载 = 装进第一个空槽（要精确指定落哪格请用拖拽）
        int empty = TacticSlotRuntime.FirstEmptyIndex();
        if (empty < 0)
        {
            SetHint($"战术卡槽已满（{TacticSlotRuntime.SlotCount}/{TacticSlotRuntime.SlotCount}）：先卸下一张", InventoryUIKit.Muted);
            return;
        }
        TryEquip(card, empty);
    }

    public void OnPackCardDragStarted(CardView cv, Vector2 screen, Camera cam)
    {
        if (cv == null) return;
        if (_pickMode) return;                 // 选牌模式不拖拽

        // ★2026-09-11 篝火门禁：查看模式下禁止拖拽调整
        if (!TacticAdjustAllowed())
        {
            SetHint("战术卡槽仅在篝火处可调整，当前为查看模式", InventoryUIKit.Muted);
            return;
        }

        Card card = CardOf(cv);
        if (card == null || card.Data == null) return;

        int slotIdx = _slotCards.IndexOf(cv);
        _dragSource = cv;
        _dragCard = card;
        _dragFromSlot = slotIdx >= 0;
        _dragPointer = screen;

        CreateGhost(card, screen, cam, _dragFromSlot ? SlotCardScale : 1f);
        SetHint(_dragFromSlot
            ? "拖出槽格 = 卸下；拖到另一格 = 换格"
            : $"拖到右侧某个槽格装载「{card.Data.cardName}」", InventoryUIKit.Brass);
    }

    public void OnPackCardDragged(CardView cv, Vector2 screen, Camera cam)
    {
        _dragPointer = screen;
        if (_ghost != null) FollowMouse(_ghost, screen, cam);

        // 落点高亮：鼠标在哪一格就亮哪一格
        int hover = SlotIndexUnderPointer();
        for (int i = 0; i < _slotBgs.Count; i++)
        {
            if (_slotBgs[i] == null) continue;
            _slotBgs[i].color = (i == hover) ? InventoryUIKit.SlotSel : InventoryUIKit.SlotBg;
        }
    }

    public void OnPackCardDragEnded(CardView cv, Vector2 screen, Camera cam)
    {
        // ★2026-09-11 篝火门禁安全兜底（正常已在 DragStarted 拦掉）
        if (!TacticAdjustAllowed())
        {
            DestroyGhost();
            ResetDragState();
            return;
        }

        int slotIdx = SlotIndexUnderPointer();
        bool fromSlot = _dragFromSlot;
        int fromIdx = _slotCards.IndexOf(cv);
        Card card = _dragCard;

        DestroyGhost();
        ResetDragState();
        for (int i = 0; i < _slotBgs.Count; i++)
        {
            if (_slotBgs[i] != null) _slotBgs[i].color = InventoryUIKit.SlotBg;
        }

        if (card == null || card.Data == null) return;

        if (fromSlot)
        {
            if (slotIdx < 0)
            {
                // 拖出所有槽格 = 卸下
                if (!TacticSlotRuntime.CanUnequip(fromIdx))
                {
                    SetHint($"{card.Data.cardName} 冷却中（剩 {TacticSlotRuntime.GetCooldown(fromIdx)} 回合）：取不出来",
                            InventoryUIKit.Muted);
                }
                else
                {
                    TacticSlotRuntime.Unequip(fromIdx);
                    SetHint($"已卸下 {card.Data.cardName}（回牌库）", InventoryUIKit.Muted);
                }
            }
            else if (slotIdx != fromIdx)
            {
                // 拖到另一格 = 换格；目标格被占则原样装回（★v9：冷却中的卡锁槽，换不了）
                if (!TacticSlotRuntime.CanUnequip(fromIdx))
                {
                    SetHint($"{card.Data.cardName} 冷却中：换不了格", InventoryUIKit.Muted);
                }
                else
                {
                    string reason;
                    TacticSlotRuntime.Unequip(fromIdx);
                    if (TacticSlotRuntime.TryEquipAt(slotIdx, card, out reason))
                    {
                        SetHint($"已换到槽 {slotIdx + 1}", InventoryUIKit.Cream);
                    }
                    else
                    {
                        TacticSlotRuntime.TryEquipAt(fromIdx, card, out reason);
                        SetHint(reason, InventoryUIKit.Muted);
                    }
                }
            }
        }
        else if (slotIdx >= 0)
        {
            TryEquip(card, slotIdx);
        }
        else
        {
            SetHint("没有落到槽格上——拖到右侧战术卡槽即可装载", InventoryUIKit.Muted);
        }

        RefreshLooks();
        RefreshSidebar();
    }

    // ------------------------------------------------------------------
    // 幽灵卡
    // ------------------------------------------------------------------

    void CreateGhost(Card card, Vector2 screen, Camera cam, float scaleFactor = 1f)
    {
        DestroyGhost();
        if (CardViewPrefab == null || _root == null) return;

        // 挂在遮罩根（不在滚动 Content 下）→ 不会被滚动区裁剪
        _ghost = Instantiate(CardViewPrefab, _root);
        _ghost.name = "PackDragGhost";
        _ghost.PackHost = null;                    // 幽灵不接事件
        _ghost.InteractionLocked = true;
        _ghost.transform.localScale = Vector3.one * (_cardScale * scaleFactor);
        _ghost.transform.SetAsLastSibling();

        RectTransform rt = _ghost.transform as RectTransform;
        if (rt != null)
        {
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.sizeDelta = _cardDesignSize;
        }

        // 幽灵绝不能吃射线：它比原卡大，会截走后续的悬停/点击。
        // ★注意：CardViewUI 预制体根节点**自带 CanvasGroup**，而 CanvasGroup 是
        //   [DisallowMultipleComponent]——直接 AddComponent 会返回 null（踩过这个坑）。
        //   必须先 GetComponent 取用，取不到才新建。
        CanvasGroup cg = _ghost.GetComponent<CanvasGroup>();
        if (cg == null) cg = _ghost.gameObject.AddComponent<CanvasGroup>();
        cg.blocksRaycasts = false;
        cg.interactable = false;
        cg.alpha = 0.92f;

        _ghost.SetCard(card);
        _ghost.gameObject.SetActive(true);
        FollowMouse(_ghost, screen, cam);
    }

    void DestroyGhost()
    {
        if (_ghost != null) Destroy(_ghost.gameObject);
        _ghost = null;
    }

    void ResetDragState()
    {
        _dragSource = null;
        _dragCard = null;
        _dragFromSlot = false;
    }

    void FollowMouse(CardView cv, Vector2 screen, Camera cam)
    {
        if (cv == null || _root == null) return;
        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(_root, screen, cam, out Vector2 local))
        {
            cv.transform.localPosition = new Vector3(local.x, local.y, 0f);
        }
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    Card CardOf(CardView cv)
    {
        if (cv == null) return null;
        int slotIdx = _slotCards.IndexOf(cv);
        if (slotIdx >= 0) return TacticSlotRuntime.Get(slotIdx);
        if (_gridMap.TryGetValue(cv, out Card c)) return c;
        return null;
    }

    /// <summary>鼠标下的槽格序号；不在任何槽格上 → -1（拖拽落点判定）。</summary>
    int SlotIndexUnderPointer()
    {
        // ★滚动后必须加视口裁剪：被滚出视野的格子坐标仍「包含」该点，但它其实看不见也点不到
        if (_slotGridArea != null &&
            !RectTransformUtility.RectangleContainsScreenPoint(_slotGridArea, _dragPointer, null)) return -1;

        for (int i = 0; i < _slotCells.Count; i++)
        {
            if (_slotCells[i] == null) continue;
            if (RectTransformUtility.RectangleContainsScreenPoint(_slotCells[i], _dragPointer, null)) return i;
        }
        return -1;
    }

    void TryEquip(Card card, int index)
    {
        string reason;
        if (TacticSlotRuntime.TryEquipAt(index, card, out reason))
        {
            SetHint($"已装载：{card.Data.cardName}——不进抽牌堆；整备 {TacticSlotRuntime.EquipDelayTurns} 回合后可用",
                    InventoryUIKit.Cream);
        }
        else
        {
            SetHint(reason, InventoryUIKit.Muted);
        }
    }

    void SetHint(string text, Color color)
    {
        if (_hint == null) return;
        _hint.text = text;
        _hint.color = color;
    }

    /// <summary>
    /// 能否调整战术卡槽。两道门禁：
    ///   ① ★2026-09-12 教程图：整套战术卡槽未解锁 → 永远不可调（连"查看模式"都不该有装载入口）
    ///   ② ★2026-09-11 篝火门禁：站在篝火格上（且处于探索模式）才允许装载 / 卸下
    /// </summary>
    bool TacticAdjustAllowed() => !MapLayoutBuilder.IsTutorial && BonfireTile.IsPlayerOnBonfire();
}

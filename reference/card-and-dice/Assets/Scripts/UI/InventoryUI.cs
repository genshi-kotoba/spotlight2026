// =============================================================================
// 模块：M7 背包系统 - InventoryUI 背包主界面
// 用途：B 键随时打开；四区紧凑布局（用户 2026-09-09 定）。
//   左列（同宽对齐）：道具 3 格横排（上）、常规 4×3 大网格（下）。
//   右列（同宽对齐）：骰子 2×3 分两排（上）、保险箱 1 小格（下，左贴 → 右下缺角）。
//   顶部对齐、底部对齐 → 完整矩形；保险箱紧邻常规分区，拖拽距离短。
// 设计依据：spec §11（背包界面）、§3（分区）、§16（容量）。
// 挂载：UICanvas（由 Tools/背包/4 添加）；实现零美术，代码动态创建（InventoryUIKit）。
// 坐标约定（自洽，勿手改）：
//   格子正方形 cell×cell，间距 spacing；卡片 = pad + headerH + pad + grid + pad。
//   网格中心 y = cardH/2 - pad - headerH - pad - gridH/2（固定 -pad-... 与 gridH 无关）。
//   网格左对齐：网格中心 x = -cardW/2 + pad + gridW/2。
//   CreateSlotGrid 的 origin = 第一个格子「左上角」(-gridW/2, gridH/2)。
// 模态：打开时 Interactions.ModalPopupActive = true（禁移动/禁拖牌/禁结束回合）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class InventoryUI : MonoBehaviour
{
    [Header("开关")]
    [Tooltip("打开/关闭背包的按键（spec §11：B 键随时打开）")]
    [SerializeField] private KeyCode toggleKey = KeyCode.B;

    // 布局常量（非序列化，避免场景旧值污染；改此处即时生效）
    private static readonly Vector2 panelSize = new Vector2(548f, 584f);
    private static readonly Vector2 cellSize = new Vector2(68f, 68f);   // 格子一律正方形
    private static readonly Vector2 cellSpacing = new Vector2(8f, 8f);
    private const float pad = 12f;         // 卡片内边距
    private const float headerH = 22f;     // 卡片标题行高
    private const float cardGap = 16f;     // 卡片间距

    static InventoryUI _instance;
    public static InventoryUI Instance => _instance;
    public static bool IsOpen => _instance != null && _instance._isOpen;

    /// <summary>★v2.3（2026-09-13）教学钩子：背包被打开 / 被关掉
    /// （对应 tutorial release = InventoryOpened / InventoryClosed）。零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnInventoryOpened;
    public static event System.Action OnInventoryClosed;

    RectTransform _root;
    RectTransform _panelRt;          // 面板本体（拖拽目标）
    Vector2 _dragOffset;             // 拖拽起始偏移
    Text _summaryText;
    Text _hintText;

    readonly Dictionary<InventoryPartition, List<InventoryUIKit.SlotCell>> _cells
        = new Dictionary<InventoryPartition, List<InventoryUIKit.SlotCell>>();
    readonly Dictionary<InventoryPartition, Text> _headers = new Dictionary<InventoryPartition, Text>();

    Button _discardButton;
    Button _safeButton;

    bool _built;
    bool _isOpen;
    InventoryPartition _selectedPartition = InventoryPartition.常规;
    int _selectedIndex = -1;
    /// <summary>★2026-09-12 已订阅变化事件的背包实例（未订阅 = null）。</summary>
    Inventory _subscribedInventory;

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void OnDestroy()
    {
        if (_instance != this) return;
        _instance = null;
        Unsubscribe();
        if (_isOpen) SetModal(false);
    }

    private void Update()
    {
        // ★2026-09-14 开发者面板（F9）打开期间：背包开关键 / ESC 一并让路，
        //   否则面板盖在屏幕上时按快捷键会在底下把背包装出来。
        if (Interactions.DevPanelOpen) return;

        if (Input.GetKeyDown(KeyCode.Escape))
        {
            if (SoulLanternUI.IsOpen) { SoulLanternUI.Close(); return; }
            if (_isOpen) { Close(); return; }
        }

        if (Input.GetKeyDown(toggleKey) && !SoulLanternUI.IsOpen)
        {
            if (_isOpen) Close();
            else TryOpen();
        }
    }

    public void TryOpen()
    {
        if (Interactions.ModalPopupActive) return;
        if (InventoryManager.Instance == null)
        {
            Debug.LogWarning("[InventoryUI] 场景中没有 InventoryManager，背包打不开（先跑 Tools/背包/3. 场景挂载与连线）");
            return;
        }
        Open();
    }

    public void Open()
    {
        if (!_built) Build();
        if (_root == null) return;

        Subscribe();
        bool wasOpen = _isOpen;
        _isOpen = true;
        _selectedPartition = InventoryPartition.常规;
        _selectedIndex = -1;
        _root.gameObject.SetActive(true);
        SetModal(true);
        Refresh();
        PopupFX.PlayOpen(_root);                        // ★2026-09-12 统一入场手感
        if (!wasOpen) OnInventoryOpened?.Invoke();      // ★v2.3 教学钩子
    }

    public void Close()
    {
        if (!_isOpen) return;
        if (SoulLanternUI.IsOpen) SoulLanternUI.Close();
        _isOpen = false;
        _root.gameObject.SetActive(false);
        SetModal(false);
        OnInventoryClosed?.Invoke();                    // ★v2.3 教学钩子
    }

    // ------------------------------------------------------------------
    // ★2026-09-12 用户定稿「背包信息不延迟」：订阅模型变化，任何外部改动都当场刷新 ——
    //   魂灯子窗销毁灵魂 / 拾取入包 / 战后发奖物品落包，不再等到「下次打开背包」才看到。
    // Inventory 实例全程只创建一次（InventoryManager 内联 new 且从不替换），订阅一次即可。
    // ------------------------------------------------------------------
    void Subscribe()
    {
        InventoryManager mgr = InventoryManager.Instance;
        if (mgr == null || _subscribedInventory == mgr.Inventory) return;

        Unsubscribe();
        _subscribedInventory = mgr.Inventory;
        _subscribedInventory.OnChanged += OnInventoryChanged;
        _subscribedInventory.Lantern.OnChanged += OnInventoryChanged;
    }

    void Unsubscribe()
    {
        if (_subscribedInventory == null) return;
        _subscribedInventory.OnChanged -= OnInventoryChanged;
        _subscribedInventory.Lantern.OnChanged -= OnInventoryChanged;
        _subscribedInventory = null;
    }

    void OnInventoryChanged()
    {
        if (_isOpen) Refresh();
    }

    static void SetModal(bool on)
    {
        Interactions.ModalPopupActive = on;
        Interactions.RefreshEndTurnButton();
    }

    // ------------------------------------------------------------------
    // 标题栏拖拽（像 Windows 窗口一样按住顶部拖动）
    // ------------------------------------------------------------------
    void OnDragBegin(PointerEventData e)
    {
        if (_panelRt == null || _panelRt.parent == null) return;
        // 参考系必须与 OnDragMove 一致（父节点），否则偏移算错、窗口会跳一下
        RectTransformUtility.ScreenPointToLocalPointInRectangle(_panelRt.parent as RectTransform, e.position, e.pressEventCamera, out Vector2 local);
        _dragOffset = (Vector2)_panelRt.localPosition - local;
    }

    void OnDragMove(PointerEventData e)
    {
        if (_panelRt == null || _panelRt.parent == null) return;
        RectTransformUtility.ScreenPointToLocalPointInRectangle(_panelRt.parent as RectTransform, e.position, e.pressEventCamera, out Vector2 local);
        _panelRt.localPosition = local + _dragOffset;
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------
    void Build()
    {
        _root = InventoryUIKit.CreateOverlay("InventoryPanel");
        if (_root == null) return;

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, panelSize, Vector2.zero, InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        float halfW = panelSize.x * 0.5f;
        float halfH = panelSize.y * 0.5f;

        _panelRt = panel.rectTransform;

        // 标题栏拖拽区（顶部，透明可拖；关闭按钮后创建，覆盖在它之上可点击）
        RectTransform dragBar = InventoryUIKit.CreateRect("DragBar", panel.transform);
        InventoryUIKit.Place(dragBar, new Vector2(panelSize.x, 60f), new Vector2(0f, halfH - 30f));
        Image dragImg = dragBar.gameObject.AddComponent<Image>();
        dragImg.color = new Color(0f, 0f, 0f, 0f);
        dragImg.raycastTarget = true;
        InventoryUIKit.AddDragHandlers(dragBar.gameObject, OnDragBegin, OnDragMove, null);

        // 标题行（顶部）
        Text title = InventoryUIKit.CreateLabel("Title", panel.transform, "背包", 24, InventoryUIKit.Brass,
                                                TextAnchor.UpperLeft);
        InventoryUIKit.Place(title.rectTransform, new Vector2(panelSize.x - 60f, 32f),
                             new Vector2(0f, halfH - 28f));

        _summaryText = InventoryUIKit.CreateLabel("Summary", panel.transform, "", 13, InventoryUIKit.Muted,
                                                  TextAnchor.UpperLeft);
        InventoryUIKit.Place(_summaryText.rectTransform, new Vector2(panelSize.x - 60f, 22f),
                             new Vector2(0f, halfH - 56f));

        // ── 网格/卡片尺寸（统一常量，见文件头注释）──
        float gridPropW = 3 * cellSize.x + 2 * cellSpacing.x;   // 226
        float gridGenW  = 4 * cellSize.x + 3 * cellSpacing.x;   // 304
        float gridDiceW = 2 * cellSize.x + 1 * cellSpacing.x;   // 148
        float gridH1 = cellSize.y;                              // 70
        float gridH3 = 3 * cellSize.y + 2 * cellSpacing.y;      // 226

        float genCardW  = gridGenW + pad * 2f;                  // 328
        float diceCardW = gridDiceW + pad * 2f;                 // 172
        float propCardW = genCardW;                             // 对齐常规
        float safeCardW = cellSize.x + pad * 2f;                // 94（仅 1 格）

        float cardH1 = pad + headerH + pad + gridH1 + pad;      // 128
        float cardH3 = pad + headerH + pad + gridH3 + pad;      // 284

        float totalW = genCardW + cardGap + diceCardW;          // 516
        float contentLeft = -totalW * 0.5f;
        float contentTop = halfH - 76f;

        float leftX = contentLeft;
        float rightX = contentLeft + genCardW + cardGap;

        // 左列：道具（上，宽=常规）→ 常规（下）
        BuildCard(panel.transform, InventoryPartition.道具, 3, 1, cellSize, leftX, contentTop, propCardW);
        BuildCard(panel.transform, InventoryPartition.常规, 4, 3, cellSize, leftX,
                  contentTop - cardH1 - cardGap, genCardW);

        // 右列：骰子（上，2×3）→ 保险箱（下，左贴骰子 → 右下角缺角）
        BuildCard(panel.transform, InventoryPartition.骰子, 2, 3, cellSize, rightX, contentTop, diceCardW);
        BuildSafeCard(panel.transform, rightX, contentTop - cardH3 - cardGap, safeCardW);

        // 底部：提示（上方一行）+ 按钮行（整理 / 关闭 / 丢弃选中）
        _hintText = InventoryUIKit.CreateLabel("Hint", panel.transform, "", 13, InventoryUIKit.Muted,
                                               TextAnchor.MiddleLeft);
        InventoryUIKit.Place(_hintText.rectTransform, new Vector2(panelSize.x - 280f, 40f),
                             new Vector2(-120f, -halfH + 58f));

        // ★2026-09-11：关闭按钮下沉到底部，与卡包「装填 / 关闭」对齐；
        //   左侧新增预留的「整理」按钮（自动整理背包功能待实现，先只占位）。
        InventoryUIKit.CreateButton("OrganizeButton", panel.transform, "整理", new Vector2(110f, 34f),
                                    new Vector2(-90f, -halfH + 18f), OrganizeReserved);
        InventoryUIKit.CreateButton("CloseButton", panel.transform, "关闭", new Vector2(110f, 34f),
                                    new Vector2(60f, -halfH + 18f), Close);
        _discardButton = InventoryUIKit.CreateButton("DiscardButton", panel.transform, "丢弃选中",
                                                     new Vector2(110f, 34f),
                                                     new Vector2(halfW - 78f, -halfH + 18f), DiscardSelected);

        _built = true;
    }

    /// <summary>建一个分区卡。cardWidth 指定卡宽（道具对齐常规用），网格在卡内靠左。</summary>
    void BuildCard(Transform panelRoot, InventoryPartition p, int columns, int rows, Vector2 cell,
                   float left, float top, float cardWidth)
    {
        float gridW = columns * cell.x + (columns - 1) * cellSpacing.x;
        float gridH = rows * cell.y + (rows - 1) * cellSpacing.y;
        float cardH = pad + headerH + pad + gridH + pad;

        Image card = InventoryUIKit.CreatePanel($"Card_{p}", panelRoot, new Vector2(cardWidth, cardH),
                                                new Vector2(left + cardWidth * 0.5f, top - cardH * 0.5f),
                                                InventoryUIKit.SlotBg);
        Outline cardOl = card.gameObject.AddComponent<Outline>();
        cardOl.effectColor = new Color(InventoryUIKit.Gold.r, InventoryUIKit.Gold.g, InventoryUIKit.Gold.b, 0.6f);
        cardOl.effectDistance = new Vector2(2f, 2f);

        // 标题（卡片内顶部，靠左）
        Text header = InventoryUIKit.CreateLabel($"Header_{p}", card.transform, p.ToString(), 15,
                                                 InventoryUIKit.Brass, TextAnchor.UpperLeft);
        InventoryUIKit.Place(header.rectTransform, new Vector2(cardWidth - pad * 2f, headerH),
                             new Vector2(0f, cardH * 0.5f - pad - headerH * 0.5f));
        _headers[p] = header;

        // 网格容器（左对齐）
        RectTransform gridRT = InventoryUIKit.CreateRect($"Grid_{p}", card.transform);
        float gridCenterX = -cardWidth * 0.5f + pad + gridW * 0.5f;
        float gridCenterY = cardH * 0.5f - pad - headerH - pad - gridH * 0.5f;
        InventoryUIKit.Place(gridRT, new Vector2(gridW, gridH), new Vector2(gridCenterX, gridCenterY));

        // 格子（origin = 第一个格子左上角）
        Vector2 origin = new Vector2(-gridW * 0.5f, gridH * 0.5f);
        InventoryPartition captured = p;
        List<InventoryUIKit.SlotCell> builtCells = InventoryUIKit.CreateSlotGrid(
            gridRT, capacityOf(p), columns, cell, cellSpacing, origin, (idx) => OnCellClicked(captured, idx));
        _cells[p] = builtCells;
    }

    /// <summary>保险箱卡：右下 1 小格（柜子容器入口，占位），左贴骰子卡。</summary>
    void BuildSafeCard(Transform panelRoot, float left, float top, float cardWidth)
    {
        float gridW = cellSize.x;
        float gridH = cellSize.y;
        float cardH = pad + headerH + pad + gridH + pad;

        Image card = InventoryUIKit.CreatePanel("Card_保险箱", panelRoot, new Vector2(cardWidth, cardH),
                                                new Vector2(left + cardWidth * 0.5f, top - cardH * 0.5f),
                                                InventoryUIKit.SlotBg);
        Outline cardOl = card.gameObject.AddComponent<Outline>();
        cardOl.effectColor = new Color(0.30f, 0.55f, 0.85f, 0.8f);   // 保险箱蓝调边框
        cardOl.effectDistance = new Vector2(2f, 2f);

        Text header = InventoryUIKit.CreateLabel("Header_保险箱", card.transform, "保险箱", 15,
                                                 new Color(0.55f, 0.70f, 0.95f, 1f), TextAnchor.UpperLeft);
        InventoryUIKit.Place(header.rectTransform, new Vector2(cardWidth - pad * 2f, headerH),
                             new Vector2(0f, cardH * 0.5f - pad - headerH * 0.5f));

        RectTransform gridRT = InventoryUIKit.CreateRect("SafeSlot", card.transform);
        float gridCenterX = -cardWidth * 0.5f + pad + gridW * 0.5f;
        float gridCenterY = cardH * 0.5f - pad - headerH - pad - gridH * 0.5f;
        InventoryUIKit.Place(gridRT, new Vector2(gridW, gridH), new Vector2(gridCenterX, gridCenterY));

        InventoryUIKit.SlotCell cell = InventoryUIKit.CreateSlotCell(
            gridRT, cellSize, Vector2.zero, OnSafeClicked);
        cell.nameText.text = "开";
        cell.nameText.fontSize = 22;
        cell.background.color = new Color(0.30f, 0.40f, 0.60f, 0.5f);
        _safeButton = cell.button;
    }

    int capacityOf(InventoryPartition p)
    {
        switch (p)
        {
            case InventoryPartition.骰子: return Inventory.DiceCapacity;
            case InventoryPartition.道具: return Inventory.ConsumableCapacity;
            default: return Inventory.BaseGeneralCapacity;
        }
    }

    // ------------------------------------------------------------------
    // 刷新
    // ------------------------------------------------------------------
    void Refresh()
    {
        if (InventoryManager.Instance == null || !_built) return;

        Inventory inv = InventoryManager.Instance.Inventory;
        _summaryText.text = $"材料 {InventoryManager.Instance.MaterialCount}　·　力量 +{inv.StrengthBonus}";

        foreach (InventoryPartition p in new[] { InventoryPartition.道具, InventoryPartition.常规, InventoryPartition.骰子 })
        {
            List<InventorySlot> slots = inv.GetPartition(p);
            int capacity = inv.GetCapacity(p);
            if (_headers.TryGetValue(p, out Text header))
                header.text = $"{p}　{slots.Count}/{capacity}";

            PaintPartition(p, slots, capacity);
        }

        RefreshBottom();
    }

    void PaintPartition(InventoryPartition p, List<InventorySlot> slots, int capacity)
    {
        if (!_cells.TryGetValue(p, out List<InventoryUIKit.SlotCell> cells)) return;
        for (int i = 0; i < cells.Count; i++)
        {
            InventorySlot slot = i < slots.Count ? slots[i] : null;
            bool selected = (p == _selectedPartition && i == _selectedIndex);
            PaintCell(cells[i], slot, selected);
        }
    }

    void PaintCell(InventoryUIKit.SlotCell cell, InventorySlot slot, bool selected)
    {
        if (slot == null || slot.item == null)
        {
            cell.nameText.text = "";
            cell.countText.text = "";
            cell.background.color = new Color(InventoryUIKit.SlotBg.r, InventoryUIKit.SlotBg.g,
                                              InventoryUIKit.SlotBg.b, 0.35f);
            return;
        }

        cell.nameText.text = slot.item.itemName;

        // 魂灯（容器）：计数直接显示在物品格上（x/10），不占顶部 UI
        if (slot.item.type == ItemType.容器)
        {
            int soulCount = InventoryManager.Instance != null ? InventoryManager.Instance.Inventory.Lantern.Count : 0;
            cell.countText.text = $"{soulCount}/{SoulLantern.Capacity}";
        }
        else
        {
            cell.countText.text = slot.count > 1 ? $"×{slot.count}" : "";
        }
        cell.background.color = selected ? InventoryUIKit.SlotSel : InventoryUIKit.SlotBg;
    }

    void RefreshBottom()
    {
        InventorySlot slot = GetSelected();
        if (slot == null)
        {
            _hintText.text = "点消耗品直接使用；点魂灯打开魂灯界面；点其它格子选中后可丢弃。";
            _discardButton.interactable = false;
            return;
        }

        _hintText.text = $"{slot.item.itemName} ×{slot.count}\n{slot.item.description}";
        _discardButton.interactable = slot.item.type != ItemType.容器;   // 魂灯不可丢弃（spec §7）
    }

    InventorySlot GetSelected()
    {
        if (InventoryManager.Instance == null || _selectedIndex < 0) return null;
        List<InventorySlot> slots = InventoryManager.Instance.Inventory.GetPartition(_selectedPartition);
        return _selectedIndex < slots.Count ? slots[_selectedIndex] : null;
    }

    // ------------------------------------------------------------------
    // 交互
    // ------------------------------------------------------------------
    void OnSafeClicked()
    {
        Debug.Log("[InventoryUI] 保险箱（柜子容器）点击——柜子列表与拖拽系统待实现");
    }

    void OnCellClicked(InventoryPartition p, int index)
    {
        Inventory inv = InventoryManager.Instance.Inventory;
        List<InventorySlot> slots = inv.GetPartition(p);
        if (index < 0 || index >= slots.Count)
        {
            if (_selectedPartition == p && _selectedIndex == index) { _selectedIndex = -1; Refresh(); }
            return;
        }

        InventorySlot slot = slots[index];
        if (slot.item.type == ItemType.消耗品)
        {
            if (InventoryManager.Instance.TryUseConsumable(slot.item)) Refresh();
            return;
        }

        // ★2026-09-12 战利品卡牌物品：点格子 = 使用 → 三选一（选中进牌库，物品消耗）
        if (slot.item.type == ItemType.卡牌)
        {
            CardRewardPickUI.Show(slot.item);
            return;
        }

        if (slot.item.type == ItemType.容器)
        {
            SoulLanternUI.Open();
            return;
        }

        _selectedPartition = p;
        _selectedIndex = index;
        Refresh();
    }

    void DiscardSelected()
    {
        InventorySlot slot = GetSelected();
        if (slot == null) return;

        string itemName = slot.item.itemName;
        if (InventoryManager.Instance.Inventory.DiscardAt(_selectedPartition, _selectedIndex))
        {
            Debug.Log($"[InventoryUI] 丢弃 {itemName}（整格销毁）");
            _selectedIndex = -1;
            Refresh();
        }
    }

    /// <summary>★预留（2026-09-11）：自动整理背包功能待实现，先只占位按钮 + 提示。</summary>
    void OrganizeReserved()
    {
        if (_hintText != null) _hintText.text = "自动整理背包功能待实现。";
    }
}
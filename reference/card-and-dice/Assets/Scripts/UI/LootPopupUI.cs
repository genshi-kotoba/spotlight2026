// =============================================================================
// 模块：M8 战利品 - LootPopupUI 遗物袋搜刮弹窗（★2026-09-12 重构：搜打撤式迷你背包双栏）
// 用途：走到/停在遗物袋格时自动弹出（触发在 HexMover / CorpseSpawner）。
//       左栏 = 遗物袋内容（4×4 格子网格：物资条目 + 紧随其后一格放卡牌）；
//       右栏 = 玩家背包（常规 4×4 / 骰子 3×2 / 道具 3×1，**完整可操作**：用消耗品、开魂灯、丢弃）。
//       交互：点左侧一格 = 整堆移入背包（同物品叠加、放不下的留在袋里）；「一键全拿」清空所有物资；
//             卡牌格点开小弹窗（收下进当局牌库 / 销毁 / ESC 返回主弹窗）。
//       界面内拿东西 **不耗行动点**（★2026-09-12 定稿：成本 = 移动进格 2 AP，见 TerrainManager.GetActionCost）。
// 设计依据：spec §8（遗物袋）、§11（UI 结构 / ESC 全局规则）、§15.2（背包满拒绝并提示）
// 挂载：UICanvas（Tools/背包/4. 挂载 UI 组件到 UICanvas）
// 实现：零美术 / 零串行化引用，全部代码动态创建（InventoryUIKit）；右栏格子语义与 InventoryUI 一致。
// 模态：打开时 Interactions.ModalPopupActive = true（禁移动/禁拖牌/禁结束回合）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

public class LootPopupUI : MonoBehaviour
{
    static LootPopupUI _instance;

    /// <summary>当前实例（design 要求暴露）。</summary>
    public static LootPopupUI Instance => _instance;

    /// <summary>弹窗是否打开。</summary>
    public static bool IsOpen => _instance != null && _instance._isOpen;

    /// <summary>★2026-09-13 教学钩子：玩家从遗物袋拿走东西、并关掉了弹窗
    /// （对应 tutorial release = LootSelected）。零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnLootTaken;

    /// <summary>★v2.3（2026-09-13）教学钩子：搜刮窗被打开（对应 tutorial release = LootOpened）。
    /// 教程把「走到箱子格 → 窗口自动出现」这一下单独拍成一拍。</summary>
    public static event System.Action OnLootOpened;

    /// <summary>★v2.3.1（2026-09-13）教学钩子：玩家把这一袋**拿空**并关掉了弹窗
    /// （对应 tutorial release = LootEmptied）。与 OnLootTaken 的区别：这个是"拿空"，
    /// 那个是"拿过任意一件"。教学 S25 要玩家把箱子拿空（好让 S28 讲消耗品栏时药水一定在里面）。
    /// 注意：拿空时 FinishBag 会先 CorpseRegistry.Remove 再 Close，所以本事件也在那条路径上发。</summary>
    public static event System.Action OnLootEmptied;

    /// <summary>★v2.4（2026-09-13 用户需求）教学钩子：玩家**没把这一袋拿空就关了窗口**
    /// （含"拿了一半就走"和"什么都没拿就走"两种）。教学收到后把当前拍**回退到上一拍**
    /// （S25 拿取 → 退回 S24 打开箱子），重新高亮箱子格；玩家点击脚下箱子格由
    /// `HandleTileClickReopen` 重新开窗，避免了旧行为"必须走开再走回来才重新弹"。
    /// 零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnLootAbandoned;

    // 布局常量（非序列化，避免场景旧值污染；改此处即时生效）。算法与 InventoryUI 一致：
    // 卡片 = pad + headerH + pad + grid + pad，格子左上角为网格原点。
    static readonly Vector2 panelSize = new Vector2(848f, 468f);
    static readonly Vector2 cellSize = new Vector2(62f, 62f);          // 遗物袋 / 常规
    static readonly Vector2 cellSpacing = new Vector2(8f, 8f);
    static readonly Vector2 smallCell = new Vector2(52f, 52f);         // 骰子 / 道具
    static readonly Vector2 smallSpacing = new Vector2(6f, 6f);
    const float pad = 12f;
    const float headerH = 22f;
    const float cardGap = 12f;
    const int gridColumns = 4;                                        // 遗物袋 / 常规：4 列
    const int gridRows = 4;                                           // 4 行 = 16 格
    static readonly Vector2 cardPanelSize = new Vector2(440f, 280f);

    RectTransform _root;
    RectTransform _cardRoot;
    Text _titleText;
    Text _containerHeader;
    Text _hintText;
    Text _cardText;

    readonly List<InventoryUIKit.SlotCell> _containerCells = new List<InventoryUIKit.SlotCell>();
    readonly List<InventoryUIKit.SlotCell> _generalCells = new List<InventoryUIKit.SlotCell>();
    readonly List<InventoryUIKit.SlotCell> _diceCells = new List<InventoryUIKit.SlotCell>();
    readonly List<InventoryUIKit.SlotCell> _propCells = new List<InventoryUIKit.SlotCell>();
    readonly Dictionary<InventoryPartition, Text> _headers = new Dictionary<InventoryPartition, Text>();

    Button _allButton;
    Button _discardButton;

    CorpseContainer _corpse;
    bool _built;
    bool _isOpen;
    bool _tookSomething;                                              // ★本次打开期间是否拿过东西（教学钩子用）
    InventoryPartition _selPartition = InventoryPartition.常规;         // 右栏「丢弃选中」的目标
    int _selIndex = -1;

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void OnDestroy()
    {
        if (_instance != this) return;
        _instance = null;
        if (_isOpen) SetModal(false);
    }

    private void Update()
    {
        if (!_isOpen || !Input.GetKeyDown(KeyCode.Escape)) return;

        // spec §11：子界面 ESC 逐层返回 —— 魂灯 → 卡牌子窗 → 主弹窗
        if (SoulLanternUI.IsOpen) { SoulLanternUI.Close(); return; }
        if (_cardRoot != null && _cardRoot.gameObject.activeSelf) { CloseCardPanel(); return; }
        Close();
    }

    /// <summary>HexMover 走到遗物袋格时调用的唯一入口（触发接线在 HexMover / CorpseSpawner）。</summary>
    public static void OpenFor(CorpseContainer corpse)
    {
        if (corpse == null) return;

        LootPopupUI ui = _instance != null ? _instance : FindObjectOfType<LootPopupUI>();
        if (ui == null)
        {
            Debug.LogWarning("[LootPopupUI] UICanvas 上没有 LootPopupUI —— 跑 Tools/背包/4. 挂载 UI 组件到 UICanvas");
            return;
        }

        _instance = ui;      // 编辑态 Awake 不执行，这里补上，IsOpen / ESC 分支才能工作
        ui.Open(corpse);
    }

    /// <summary>
    /// ★v2.4（2026-09-13 用户需求）：点击**脚下**的箱子格 → 重新打开搜刮窗。
    /// 与 EventTile / BonfireTile 的 HandleTileClickReopen 同款（自包含射线，不动那两个模块）。
    /// 动机：遗物袋原本只在「移动落点停在格子」时弹窗，拿一半关掉后必须走开再走回来才重弹；
    /// 教学 S25 要求把箱子拿空，这个绕路会把教学卡在半空。篝火能点脚下格重开，箱子同理。
    /// 由 ExplorationTurnManager.Update 每帧调用。
    /// </summary>
    public static void HandleTileClickReopen()
    {
        if (IsOpen) return;
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring) return;
        if (Interactions.ModalPopupActive) return;                 // 已有别的模态窗（事件格 / 篝火）在走
        if (!Input.GetMouseButtonDown(0)) return;
        if (EventSystem.current != null && EventSystem.current.IsPointerOverGameObject()) return;

        Camera cam = Camera.main;
        if (cam == null) return;
        if (!Physics.Raycast(cam.ScreenPointToRay(Input.mousePosition), out RaycastHit hit)) return;
        if (hit.collider == null || !hit.collider.CompareTag("Ground") || !hit.collider.name.StartsWith("Hex_")) return;

        string[] parts = hit.collider.name.Split('_');
        if (parts.Length < 3 || !int.TryParse(parts[1], out int x) || !int.TryParse(parts[2], out int y)) return;
        Vector2Int clicked = new Vector2Int(x, y);

        HexMover mover = FindObjectOfType<HexMover>();
        if (mover == null || mover.CurrentCoord != clicked) return;  // 只认脚下那一格（与篝火一致）

        CorpseContainer corpse = CorpseRegistry.Get(clicked);
        if (corpse == null || corpse.IsEmpty) return;

        OpenFor(corpse);
    }

    public void Open(CorpseContainer corpse)
    {
        if (corpse == null) return;
        if (_isOpen && ReferenceEquals(_corpse, corpse)) return;      // 同一袋已开着，别重复建
        if (Inv() == null)
        {
            Debug.LogWarning("[LootPopupUI] 场景中没有 InventoryManager，搜刮弹窗打不开");
            return;
        }

        if (!_built) Build();
        if (_root == null) return;

        _corpse = corpse;
        _selIndex = -1;
        _selPartition = InventoryPartition.常规;
        _tookSomething = false;                                       // ★每次打开复位（教学钩子基准）
        _isOpen = true;
        _root.gameObject.SetActive(true);
        SetModal(true);
        Refresh();
        PopupFX.PlayOpen(_root);                        // ★2026-09-12 统一入场手感
        OnLootOpened?.Invoke();                         // ★v2.3 教学钩子：窗口已打开
    }

    public void Close()
    {
        if (!_isOpen) return;
        if (SoulLanternUI.IsOpen) SoulLanternUI.Close();
        CloseCardPanel();

        // ★2026-09-13 教学钩子（必须在 _corpse 置空之前取判据）：
        //   emptied = 这一袋被拿空了（物资 + 卡牌都空）；took = 本次开袋拿过任意一件。
        //   拿空时只发 emptied（更精确的那个），避免同一动作触发两拍。
        bool took = _tookSomething;
        bool emptied = _corpse != null && _corpse.IsEmpty;
        _tookSomething = false;

        _isOpen = false;
        _corpse = null;
        _selIndex = -1;
        _root.gameObject.SetActive(false);
        SetModal(false);

        if (emptied) OnLootEmptied?.Invoke();
        else
        {
            // ★v2.4：**没拿空就关窗**（含"什么都没拿就离开"）→ 发「中途放弃」，教学据此回退到上一拍
            //   （S25 拿取 → S24 打开箱子）并重新高亮箱子格，玩家点脚下箱子格即可重开。
            //   ⚠️ 必须是 else 而非 else if (took)：什么都不拿就走，那一拍同样会落空。
            OnLootAbandoned?.Invoke();
            if (took) OnLootTaken?.Invoke();   // 保留给 LootSelected 拍的将来用途
        }
    }

    static void SetModal(bool on)
    {
        Interactions.ModalPopupActive = on;
        Interactions.RefreshEndTurnButton();
    }

    /// <summary>编辑态 Awake 不执行、Instance 为 null，L2 断言要在编辑态跑通，所以统一走这里。</summary>
    static InventoryManager Inv()
    {
        return InventoryManager.Instance != null
            ? InventoryManager.Instance
            : FindObjectOfType<InventoryManager>();
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------
    void Build()
    {
        _root = InventoryUIKit.CreateOverlay("LootPopupPanel");
        if (_root == null) return;

        // 重入安全：格子列表只增不清的话，第二次 Build 会把已销毁的旧格子留在表头里
        _containerCells.Clear();
        _generalCells.Clear();
        _diceCells.Clear();
        _propCells.Clear();
        _headers.Clear();

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, panelSize, Vector2.zero, InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        float halfW = panelSize.x * 0.5f;
        float halfH = panelSize.y * 0.5f;

        _titleText = InventoryUIKit.CreateLabel("Title", panel.transform, "遗物袋", 22, InventoryUIKit.Brass,
                                                TextAnchor.UpperLeft);
        InventoryUIKit.Place(_titleText.rectTransform, new Vector2(panelSize.x - 60f, 30f),
                             new Vector2(0f, halfH - 27f));

        // ── 尺寸（与 InventoryUI 同一套算法）──
        float gridW = gridColumns * cellSize.x + (gridColumns - 1) * cellSpacing.x;     // 272
        float gridH = gridRows * cellSize.y + (gridRows - 1) * cellSpacing.y;           // 272
        float cardW = gridW + pad * 2f;                                                // 296
        float smallGridW = 3 * smallCell.x + 2 * smallSpacing.x;                       // 168
        float smallCardW = smallGridW + pad * 2f;                                      // 192
        float smallGridH2 = 2 * smallCell.y + smallSpacing.y;                          // 110
        float diceCardH = pad + headerH + pad + smallGridH2 + pad;                     // 168
        float propCardH = pad + headerH + pad + smallCell.y + pad;                     // 110

        float contentW = cardW + 16f + cardW + cardGap + smallCardW;                   // 812
        float contentLeft = -contentW * 0.5f;
        float contentTop = halfH - 46f;
        float invX = contentLeft + cardW + 16f;
        float subX = invX + cardW + cardGap;

        // 左栏：遗物袋（4×4；物资之后紧接着一格放卡牌）
        BuildGridCard(panel.transform, "袋内物资", gridColumns, gridRows, cellSize, cellSpacing,
                      contentLeft, contentTop, cardW, _containerCells, OnContainerCellClicked,
                      out _containerHeader);

        // ★v2.3 教学：给袋内格子起稳定名字，教学高亮才能按路径精确指向第 N 格
        //   （CreateSlotCell 建的节点一律叫 "Slot"，只靠名字/路径区分不出序号）
        for (int i = 0; i < _containerCells.Count; i++)
            if (_containerCells[i] != null && _containerCells[i].root != null)
                _containerCells[i].root.name = $"BagSlot_{i}";

        // 右栏：玩家背包（常规 4×4 / 骰子 3×2 / 道具 3×1）——与 InventoryUI 同一套操作语义
        BuildGridCard(panel.transform, InventoryPartition.常规.ToString(), gridColumns, gridRows,
                      cellSize, cellSpacing, invX, contentTop, cardW, _generalCells,
                      (i) => OnBackpackCellClicked(InventoryPartition.常规, i), out Text generalHeader);
        _headers[InventoryPartition.常规] = generalHeader;

        BuildGridCard(panel.transform, InventoryPartition.骰子.ToString(), 3, 2, smallCell, smallSpacing,
                      subX, contentTop, smallCardW, _diceCells,
                      (i) => OnBackpackCellClicked(InventoryPartition.骰子, i), out Text diceHeader);
        _headers[InventoryPartition.骰子] = diceHeader;

        BuildGridCard(panel.transform, InventoryPartition.道具.ToString(), 3, 1, smallCell, smallSpacing,
                      subX, contentTop - diceCardH - cardGap, smallCardW, _propCells,
                      (i) => OnBackpackCellClicked(InventoryPartition.道具, i), out Text propHeader);
        _headers[InventoryPartition.道具] = propHeader;

        _discardButton = InventoryUIKit.CreateButton("DiscardButton", panel.transform, "丢弃选中",
                                                     new Vector2(smallCardW, 34f),
                                                     new Vector2(subX + smallCardW * 0.5f,
                                                                 contentTop - diceCardH - cardGap - propCardH - 8f - 17f),
                                                     DiscardSelected);

        // 底部：单行反馈（默认留空，只在动作发生后显示一句短提示）+ 按钮行
        _hintText = InventoryUIKit.CreateLabel("Hint", panel.transform, "", 13, InventoryUIKit.Muted,
                                               TextAnchor.MiddleLeft);
        InventoryUIKit.Place(_hintText.rectTransform, new Vector2(panelSize.x - 80f, 24f),
                             new Vector2(0f, -halfH + 68f));
        _hintText.horizontalOverflow = HorizontalWrapMode.Wrap;
        _hintText.verticalOverflow = VerticalWrapMode.Truncate;

        _allButton = InventoryUIKit.CreateButton("AllButton", panel.transform, "一键全拿", new Vector2(180f, 40f),
                                                 new Vector2(contentLeft + cardW * 0.5f, -halfH + 28f),
                                                 TransferAll);
        InventoryUIKit.CreateButton("LeaveButton", panel.transform, "离开", new Vector2(120f, 40f),
                                    new Vector2(halfW - 76f, -halfH + 28f), Close);

        _built = true;
    }

    /// <summary>建一个分区卡（标题 + columns×rows 网格），格子追加进 into。</summary>
    void BuildGridCard(Transform panelRoot, string title, int columns, int rows, Vector2 cell, Vector2 spacing,
                       float left, float top, float cardWidth, List<InventoryUIKit.SlotCell> into,
                       Action<int> onClick, out Text header)
    {
        float gridW = columns * cell.x + (columns - 1) * spacing.x;
        float gridH = rows * cell.y + (rows - 1) * spacing.y;
        float cardH = pad + headerH + pad + gridH + pad;

        Image card = InventoryUIKit.CreatePanel($"Card_{title}", panelRoot, new Vector2(cardWidth, cardH),
                                                new Vector2(left + cardWidth * 0.5f, top - cardH * 0.5f),
                                                InventoryUIKit.SlotBg);
        Outline cardOl = card.gameObject.AddComponent<Outline>();
        cardOl.effectColor = new Color(InventoryUIKit.Gold.r, InventoryUIKit.Gold.g, InventoryUIKit.Gold.b, 0.6f);
        cardOl.effectDistance = new Vector2(2f, 2f);

        header = InventoryUIKit.CreateLabel($"Header_{title}", card.transform, title, 15, InventoryUIKit.Brass,
                                            TextAnchor.UpperLeft);
        InventoryUIKit.Place(header.rectTransform, new Vector2(cardWidth - pad * 2f, headerH),
                             new Vector2(0f, cardH * 0.5f - pad - headerH * 0.5f));

        RectTransform gridRT = InventoryUIKit.CreateRect($"Grid_{title}", card.transform);
        InventoryUIKit.Place(gridRT, new Vector2(gridW, gridH),
                             new Vector2(-cardWidth * 0.5f + pad + gridW * 0.5f,
                                         cardH * 0.5f - pad - headerH - pad - gridH * 0.5f));

        Vector2 origin = new Vector2(-gridW * 0.5f, gridH * 0.5f);
        into.AddRange(InventoryUIKit.CreateSlotGrid(gridRT, columns * rows, columns, cell, spacing, origin, onClick));
    }

    void BuildCardPanel()
    {
        _cardRoot = InventoryUIKit.CreateOverlay("LootCardPanel");
        if (_cardRoot == null) return;

        Image panel = InventoryUIKit.CreatePanel("Panel", _cardRoot, cardPanelSize, Vector2.zero,
                                                 InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Brass;
        outline.effectDistance = new Vector2(2f, 2f);

        InventoryUIKit.CreateLabel("CardTitle", panel.transform, "遗物袋里的卡牌", 18, InventoryUIKit.Brass,
                                   TextAnchor.MiddleCenter)
            .rectTransform.anchoredPosition = new Vector2(0f, cardPanelSize.y * 0.5f - 30f);

        _cardText = InventoryUIKit.CreateLabel("CardText", panel.transform, "", 15, InventoryUIKit.Cream,
                                               TextAnchor.UpperCenter);
        InventoryUIKit.Place(_cardText.rectTransform, new Vector2(cardPanelSize.x - 40f, 130f),
                             new Vector2(0f, -6f));
        _cardText.horizontalOverflow = HorizontalWrapMode.Wrap;
        _cardText.verticalOverflow = VerticalWrapMode.Truncate;

        InventoryUIKit.CreateButton("TakeButton", panel.transform, "收下", new Vector2(120f, 38f),
                                    new Vector2(-70f, -cardPanelSize.y * 0.5f + 36f), TakeCard);
        InventoryUIKit.CreateButton("DestroyButton", panel.transform, "销毁", new Vector2(120f, 38f),
                                    new Vector2(70f, -cardPanelSize.y * 0.5f + 36f), DestroyCard);
    }

    // ------------------------------------------------------------------
    // 刷新（全量重画，不重建节点）
    // ------------------------------------------------------------------
    void Refresh()
    {
        if (!_built || _corpse == null) return;

        InventoryManager mgr = Inv();
        if (mgr == null) return;

        _titleText.text = $"遗物袋 · {_corpse.EnemyName}";

        if (_containerHeader != null)
        {
            string cardPart = _corpse.CardDrop != null ? "　+ 卡牌 ×1" : "";
            _containerHeader.text = $"袋内物资　{_corpse.Items.Count} 格 / {_corpse.TotalItemCount} 件{cardPart}";
        }

        PaintContainer();
        PaintBackpack(mgr.Inventory);
        RefreshBottom();
        SetHint(DefaultHint(), InventoryUIKit.Muted);
    }

    void PaintContainer()
    {
        int itemCount = _corpse.Items.Count;
        CardData card = _corpse.CardDrop;

        for (int i = 0; i < _containerCells.Count; i++)
        {
            InventoryUIKit.SlotCell cell = _containerCells[i];

            if (i < itemCount)
            {
                PaintItemCell(cell, _corpse.Items[i], false);
                continue;
            }

            if (card != null && i == itemCount)                 // 卡牌永远紧跟在物资之后一格
            {
                cell.nameText.text = card.cardName;
                cell.nameText.color = new Color(0.13f, 0.10f, 0.05f, 1f);   // 金底上要深字才看得清
                cell.countText.text = "查看";
                cell.countText.color = new Color(0.13f, 0.10f, 0.05f, 1f);
                cell.background.color = InventoryUIKit.Gold;
                continue;
            }

            PaintEmptyCell(cell);
        }
    }

    void PaintBackpack(Inventory inv)
    {
        foreach (InventoryPartition p in new[] { InventoryPartition.常规, InventoryPartition.骰子, InventoryPartition.道具 })
        {
            List<InventorySlot> slots = inv.GetPartition(p);
            if (_headers.TryGetValue(p, out Text header))
                header.text = $"{p}　{slots.Count}/{inv.GetCapacity(p)}";

            List<InventoryUIKit.SlotCell> cells = CellsOf(p);
            if (cells == null) continue;
            for (int i = 0; i < cells.Count; i++)
            {
                InventorySlot slot = i < slots.Count ? slots[i] : null;
                PaintItemCell(cells[i], slot, p == _selPartition && i == _selIndex);
            }
        }
    }

    List<InventoryUIKit.SlotCell> CellsOf(InventoryPartition p)
    {
        switch (p)
        {
            case InventoryPartition.骰子: return _diceCells;
            case InventoryPartition.道具: return _propCells;
            case InventoryPartition.常规: return _generalCells;
            default: return null;
        }
    }

    void PaintItemCell(InventoryUIKit.SlotCell cell, InventorySlot slot, bool selected)
    {
        if (slot == null || slot.item == null) { PaintEmptyCell(cell); return; }

        cell.nameText.text = slot.item.itemName;
        cell.nameText.color = InventoryUIKit.Cream;
        cell.countText.color = InventoryUIKit.Brass;

        // 魂灯（容器）：计数直接显示在物品格上（x/10），不占顶部 UI
        if (slot.item.type == ItemType.容器)
        {
            InventoryManager mgr = Inv();
            int soulCount = mgr != null ? mgr.Inventory.Lantern.Count : 0;
            cell.countText.text = $"{soulCount}/{SoulLantern.Capacity}";
        }
        else
        {
            cell.countText.text = slot.count > 1 ? $"×{slot.count}" : "";
        }
        cell.background.color = selected ? InventoryUIKit.SlotSel : InventoryUIKit.SlotBg;
    }

    void PaintEmptyCell(InventoryUIKit.SlotCell cell)
    {
        cell.nameText.text = "";
        cell.countText.text = "";
        cell.background.color = new Color(InventoryUIKit.SlotBg.r, InventoryUIKit.SlotBg.g,
                                          InventoryUIKit.SlotBg.b, 0.35f);
    }

    void RefreshBottom()
    {
        bool hasItems = _corpse != null && _corpse.Items.Count > 0;
        if (_allButton != null) _allButton.interactable = hasItems;

        InventorySlot sel = GetSelectedSlot();
        if (_discardButton != null)
            _discardButton.interactable = sel != null && sel.item != null && sel.item.type != ItemType.容器;
    }

    string DefaultHint()
    {
        if (_corpse == null) return "";

        InventorySlot sel = GetSelectedSlot();
        if (sel != null && sel.item != null)
            return $"{sel.item.itemName} ×{sel.count}　{sel.item.description}";

        if (_corpse.Items.Count == 0 && _corpse.CardDrop != null)
            return "物资都拿完了，还剩一张卡牌：点金色那格决定收下或销毁。";

        return "";
    }

    // ------------------------------------------------------------------
    // 交互：左栏（遗物袋 → 背包）
    // ------------------------------------------------------------------
    void OnContainerCellClicked(int index)
    {
        if (_corpse == null) return;

        if (index == _corpse.Items.Count && _corpse.CardDrop != null) { OpenCardPanel(); return; }
        if (index < 0 || index >= _corpse.Items.Count) return;

        TransferStack(index);
    }

    void TransferStack(int index)
    {
        InventoryManager mgr = Inv();
        if (mgr == null || _corpse == null) return;
        if (index < 0 || index >= _corpse.Items.Count) return;

        InventorySlot slot = _corpse.Items[index];
        if (slot == null || slot.item == null) return;

        int want = slot.count;
        int got = _corpse.ReduceAt(index, want);
        if (got <= 0) return;

        mgr.AddItem(slot.item, got, out int added);
        int left = got - added;
        if (added > 0) _tookSomething = true;                   // ★教学钩子基准
        if (left > 0) _corpse.AddItem(slot.item, left);        // 放不下的部分塞回袋子（append 到末尾）

        if (_corpse.IsEmpty) { FinishBag(); return; }

        Refresh();
        SetHint(left > 0
            ? $"背包放不下：{slot.item.itemName} 只拿进 {added} 件，{left} 件留在遗物袋里。腾出格子再来。"
            : $"拿进 {slot.item.itemName} ×{added}。", left > 0 ? InventoryUIKit.Muted : InventoryUIKit.Cream);
    }

    /// <summary>一键全拿：把袋里所有物资条目移入背包（卡牌仍需点格处理——收下/销毁是二选一）。</summary>
    void TransferAll()
    {
        InventoryManager mgr = Inv();
        if (mgr == null || _corpse == null) return;

        int taken = 0;
        int overflow = 0;
        var leftovers = new List<InventorySlot>();

        // 倒序：ReduceAt 把格子降到 0 时会 RemoveAt，索引整体前移；倒序保证未处理的低索引不受影响。
        // 放不下的部分先攒在 leftovers，循环结束后再塞回袋子——循环内 append 会污染索引。
        for (int i = _corpse.Items.Count - 1; i >= 0; i--)
        {
            InventorySlot slot = _corpse.Items[i];
            if (slot == null || slot.item == null) continue;

            int want = slot.count;
            int got = _corpse.ReduceAt(i, want);
            if (got <= 0) continue;

            mgr.AddItem(slot.item, got, out int added);
            taken += added;
            if (added < got)
            {
                overflow += got - added;
                leftovers.Add(new InventorySlot(slot.item, got - added));
            }
        }

        foreach (InventorySlot left in leftovers) _corpse.AddItem(left.item, left.count);
        if (taken > 0) _tookSomething = true;                   // ★教学钩子基准

        if (taken <= 0)
        {
            Refresh();
            SetHint(_corpse.Items.Count == 0
                ? "袋里已经没有物资了（还剩一张卡牌要点它处理）。"
                : $"背包已满，一件都放不下（{overflow} 件仍留在遗物袋里）。腾出格子后再来。",
                InventoryUIKit.Muted);
            return;
        }

        if (_corpse.IsEmpty) { FinishBag(); return; }

        Refresh();
        if (overflow > 0)
        {
            SetHint($"拿进 {taken} 件，背包放不下 {overflow} 件，剩余留在遗物袋里。", InventoryUIKit.Cream);
            return;
        }
        SetHint(_corpse.Items.Count == 0
            ? $"拿进 {taken} 件，物资都拿完了 —— 只剩那张卡牌，点金色那格决定收下或销毁。"
            : $"拿进 {taken} 件，遗物袋里还剩 {_corpse.TotalItemCount} 件。", InventoryUIKit.Cream);
    }

    /// <summary>袋子清空（物资 + 卡牌都没了）→ 容器消失（spec §8）。</summary>
    void FinishBag()
    {
        CorpseContainer done = _corpse;
        CorpseRegistry.Remove(done);
        Close();
        Debug.Log($"[LootPopupUI] {done.EnemyName} 的遗物袋已搜刮干净，袋子消失");
    }

    // ------------------------------------------------------------------
    // 交互：右栏（玩家背包，语义与 InventoryUI 一致）
    // ------------------------------------------------------------------
    void OnBackpackCellClicked(InventoryPartition p, int index)
    {
        InventoryManager mgr = Inv();
        if (mgr == null) return;

        List<InventorySlot> slots = mgr.Inventory.GetPartition(p);
        if (index < 0 || index >= slots.Count)
        {
            if (_selPartition == p && _selIndex == index) { _selIndex = -1; Refresh(); }
            return;
        }

        InventorySlot slot = slots[index];
        if (slot.item == null) return;

        if (slot.item.type == ItemType.消耗品)
        {
            if (mgr.TryUseConsumable(slot.item))
            {
                Refresh();
                SetHint($"使用 {slot.item.itemName}。", InventoryUIKit.Cream);
            }
            return;
        }
        if (slot.item.type == ItemType.卡牌) { CardRewardPickUI.Show(slot.item); return; }
        if (slot.item.type == ItemType.容器) { SoulLanternUI.Open(); return; }

        _selPartition = p;
        _selIndex = index;
        Refresh();
    }

    void DiscardSelected()
    {
        InventoryManager mgr = Inv();
        if (mgr == null) return;

        InventorySlot slot = GetSelectedSlot();
        if (slot == null || slot.item == null) return;

        string itemName = slot.item.itemName;
        if (mgr.Inventory.DiscardAt(_selPartition, _selIndex))
        {
            Debug.Log($"[LootPopupUI] 丢弃 {itemName}（整格销毁）");
            _selIndex = -1;
            Refresh();
            SetHint($"丢弃 {itemName}。", InventoryUIKit.Cream);
        }
    }

    InventorySlot GetSelectedSlot()
    {
        InventoryManager mgr = Inv();
        if (mgr == null || _selIndex < 0) return null;

        List<InventorySlot> slots = mgr.Inventory.GetPartition(_selPartition);
        return _selIndex < slots.Count ? slots[_selIndex] : null;
    }

    // ------------------------------------------------------------------
    // 卡牌小弹窗（收下 / 销毁 / ESC 返回）
    // ------------------------------------------------------------------
    void OpenCardPanel()
    {
        if (_corpse == null || _corpse.CardDrop == null) return;

        if (_cardRoot == null) BuildCardPanel();
        if (_cardRoot == null) return;

        CardData card = _corpse.CardDrop;
        _cardText.text = $"{card.cardName}\n\n{card.description}";
        _cardRoot.gameObject.SetActive(true);
    }

    void CloseCardPanel()
    {
        if (_cardRoot == null) return;
        _cardRoot.gameObject.SetActive(false);
    }

    void TakeCard()
    {
        if (_corpse == null || _corpse.CardDrop == null) return;
        if (CardDeckManager.Instance == null)
        {
            Debug.LogWarning("[LootPopupUI] 场景中没有 CardDeckManager，卡牌收不进牌库");
            return;
        }

        CardData card = _corpse.CardDrop;
        CardDeckManager.Instance.AddCardAtRuntime(card);      // 直接进当局牌库（并立刻进抽牌堆），不占背包格（spec §8）
        _corpse.ResolveCard();
        CloseCardPanel();
        FinishCardAction($"收下「{card.cardName}」，已加入当局牌库（不占背包格）。");
    }

    void DestroyCard()
    {
        if (_corpse == null || _corpse.CardDrop == null) return;

        string cardName = _corpse.CardDrop.cardName;
        _corpse.ResolveCard();
        CloseCardPanel();
        FinishCardAction($"销毁「{cardName}」。");
    }

    void FinishCardAction(string message)
    {
        if (_corpse.IsEmpty) { FinishBag(); return; }
        Refresh();
        SetHint(message, InventoryUIKit.Cream);
    }

    void SetHint(string text, Color color)
    {
        if (_hintText == null) return;
        _hintText.text = text;
        _hintText.color = color;
    }
}

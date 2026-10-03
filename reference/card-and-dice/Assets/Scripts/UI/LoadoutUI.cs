// =============================================================================
// 模块：M7 背包系统 - LoadoutUI 装填视图
// 用途：spec §6 装填 = **纯配置**：点牌库卡牌 → 配置它 0–4 个骰子槽各用哪种骰子。
//       设置时不转移、不消耗骰子；真正扣骰发生在战斗抽牌（DicePayment，Task 8）。
//       槽数不可增减（CardLoadout.SlotCount 由 CardData 默认装填决定，Task 7 [规格解释]）；
//       「卸下」= 该槽留空，战斗时用临时骰子兜底（SetSlot 传 null）。
// 打开路径：卡包页（CardPackUI）「装填」按钮；ESC / 「返回卡包」回 CardPackUI。
// UI 惯例：零美术、全代码动态创建、legacy Text、InventoryUIKit 辅助
//
// ★2026-09-13 v2（用户需求）：左侧列表改为「大类行 + 同名卡子菜单」——
//   · 大类行 = 同一 CardData 的所有实例聚合（如「纵劈 ×3」），点它展开/收起子菜单；
//   · 选中大类时装填**作用于全部同名卡**；在子菜单里点某一张则**只装填那一张**；
//   · 覆盖表按 Card 实例存（CardLoadout v2），同名卡可以各装各的骰子。
//   教学钩子：OnOpened（S30）/ OnCardSelected（S31）/ OnConfigured（S32，已有）/ OnClosed。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

/// <summary>装填视图。挂 UICanvas，首次 Open 时构建。</summary>
public class LoadoutUI : MonoBehaviour
{
    [Header("布局（Screen Space Overlay 像素）")]
    [SerializeField] private Vector2 panelSize = new Vector2(1280f, 700f);   // 略大于卡包 1240×680
    [SerializeField] private float rowHeight = 34f;

    static LoadoutUI _instance;
    public static bool IsOpen => _instance != null && _instance._isOpen;

    /// <summary>★2026-09-13 教学钩子：玩家在装填界面完成一次装填（手动换骰 或 点「自动装填」）。
    /// 零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnConfigured;

    /// <summary>★v2.4 教学钩子：装填界面打开（S30 解除用）。</summary>
    public static event System.Action OnOpened;

    /// <summary>★v2.4 教学钩子：装填界面关闭（S33 之后玩家还要关卡包，卡包关闭才是终点）。</summary>
    public static event System.Action OnClosed;

    /// <summary>★v2.4 教学钩子：玩家点了左侧一张卡（大类行或子菜单实例行都算，S31 解除用）。</summary>
    public static event System.Action OnCardSelected;

    /// <summary>★v2.5 教学钩子：玩家点了一个骰子槽（S32「点右侧槽位」解除用）。
    /// 在 Refresh 之后触发——下一拍激活时要高亮的槽位刚被重建/激活，必须等 UI 刷新完。</summary>
    public static event System.Action OnSlotSelected;

    RectTransform _root;
    Text _hintText;
    RectTransform _cardContent;      // 左：牌库卡牌列表（大类 + 子菜单）
    RectTransform _diceContent;      // 右下：可选骰子列表
    readonly List<RectTransform> _cardRows = new List<RectTransform>();
    readonly List<RectTransform> _diceRows = new List<RectTransform>();
    readonly List<InventoryUIKit.SlotCell> _slotCells = new List<InventoryUIKit.SlotCell>(4);
    RectTransform _slotArea;
    Image _bigCardBg;                // 放大卡底板（未选卡 = 空占位框）
    RectTransform _bigCardRT;        // 放大卡容器（真实卡面挂这里）
    CardView _bigCardView;           // 放大卡：真实卡面（懒建；未选卡时隐藏）
    CardView _cardPrefab;            // CardView 预制体（卡包同款，懒解析）
    Vector2 _cardDesignSize = new Vector2(110f, 154f);   // 预制体卡面设计尺寸
    RectTransform _panelRT;          // 面板根（悬停小窗的父节点 + 夹紧边界）
    RectTransform _diceTip;          // 悬停小窗（懒建，默认隐藏）
    Text _diceTipName;               // 小窗左侧：骰名
    Text _diceTipValues;             // 小窗右侧：点数列表 [1,2,3,4]

    CardData _selectedTemplate;      // 当前展开/选中的大类（模板）
    Card _selectedCard;              // 当前选中的精确实例；null = 作用域 = 整个大类
    int _selectedSlot = -1;

    bool _built;
    bool _isOpen;

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
        if (!_isOpen) return;
        if (Input.GetKeyDown(KeyCode.Escape)) BackToDeck();     // spec §11：子界面 ESC 返回上一级
        UpdateDiceTipPosition();
    }

    // ------------------------------------------------------------------
    // 开关
    // ------------------------------------------------------------------
    public static void Open()
    {
        if (_instance == null)
        {
            Debug.LogWarning("[LoadoutUI] UICanvas 上没有 LoadoutUI 组件（先跑 Tools/背包/4. 挂载 UI 组件到 UICanvas）");
            return;
        }
        _instance.OpenInternal();
    }

    public static void Close()
    {
        if (_instance != null) _instance.CloseInternal();
    }

    void OpenInternal()
    {
        if (!_built) Build();
        if (_root == null) return;

        bool wasOpen = _isOpen;
        _isOpen = true;
        _root.gameObject.SetActive(true);
        SetModal(true);
        Refresh();
        if (!wasOpen) OnOpened?.Invoke();       // ★教学钩子：只在"关→开"的沿上广播
    }

    void CloseInternal()
    {
        if (!_isOpen) return;
        _isOpen = false;
        _root.gameObject.SetActive(false);
        HideDiceTip();
        SetModal(false);
        OnClosed?.Invoke();
    }

    void BackToDeck()
    {
        Close();            // 先释放模态锁
        if (CardPackUI.Instance != null) CardPackUI.Instance.Show();      // 再由卡包页接管（DeckUI 由 CardPackUI 承担）
    }

    static void SetModal(bool on)
    {
        Interactions.ModalPopupActive = on;
        Interactions.RefreshEndTurnButton();
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------
    void Build()
    {
        _root = InventoryUIKit.CreateOverlay("LoadoutPanel");
        if (_root == null) return;

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, panelSize, Vector2.zero, InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);
        _panelRT = panel.rectTransform;

        Text title = InventoryUIKit.CreateLabel("Title", panel.transform, "装填", 24, InventoryUIKit.Brass,
                                                TextAnchor.UpperLeft);
        InventoryUIKit.Place(title.rectTransform, new Vector2(panelSize.x - 40f, 34f),
                             new Vector2(0f, panelSize.y * 0.5f - 34f));

        // 左：牌库卡牌列表（大类行 + 展开的子菜单）
        Text cardLabel = InventoryUIKit.CreateLabel("CardLabel", panel.transform, "牌库卡牌", 16,
                                                    InventoryUIKit.Muted, TextAnchor.MiddleLeft);
        InventoryUIKit.Place(cardLabel.rectTransform, new Vector2(460f, 24f),
                             new Vector2(-panelSize.x * 0.5f + 250f, panelSize.y * 0.5f - 78f));

        InventoryUIKit.CreateScrollList("CardList", panel.transform, new Vector2(460f, 480f),
                                        new Vector2(-panelSize.x * 0.5f + 250f, -14f), out _cardContent);

        // 右上：放大卡（真实卡面填满整框；未选卡 = 空占位框）
        RectTransform bigCard = InventoryUIKit.CreateRect("BigCard", panel.transform);
        InventoryUIKit.Place(bigCard, new Vector2(264f, 360f), new Vector2(30f, 16f));
        _bigCardRT = bigCard;
        _bigCardBg = bigCard.gameObject.AddComponent<Image>();
        _bigCardBg.sprite = InventoryUIKit.WhitePixel;
        _bigCardBg.color = InventoryUIKit.SlotBg;
        Outline bigOutline = bigCard.gameObject.AddComponent<Outline>();
        bigOutline.effectColor = new Color(0.55f, 0.44f, 0.28f, 0.7f);
        bigOutline.effectDistance = new Vector2(1f, -1f);

        // 右：骰子槽（竖排一列，最多 4 格，超出按 SlotCount 隐藏）
        Text slotLabel = InventoryUIKit.CreateLabel("SlotLabel", panel.transform, "骰子槽", 16,
                                                    InventoryUIKit.Muted, TextAnchor.MiddleLeft);
        InventoryUIKit.Place(slotLabel.rectTransform, new Vector2(224f, 24f),
                             new Vector2(panelSize.x * 0.5f - 240f, panelSize.y * 0.5f - 78f));

        _slotArea = InventoryUIKit.CreateRect("SlotArea", panel.transform);
        InventoryUIKit.Place(_slotArea, new Vector2(224f, 284f), new Vector2(panelSize.x * 0.5f - 240f, 30f));

        for (int i = 0; i < 4; i++)
        {
            Vector2 pos = new Vector2(0f, 106f - i * 68f);
            InventoryUIKit.SlotCell cell = InventoryUIKit.CreateSlotCell(_slotArea, new Vector2(210f, 60f), pos, null);
            cell.root.name = $"DiceSlot_{i}";
            _slotCells.Add(cell);

            int index = i;
            if (cell.button != null) cell.button.onClick.AddListener(() => SelectSlot(index));
        }

        // 下：可选骰子（横跨右区）
        Text diceLabel = InventoryUIKit.CreateLabel("DiceLabel", panel.transform, "可选骰子", 16,
                                                    InventoryUIKit.Muted, TextAnchor.MiddleLeft);
        InventoryUIKit.Place(diceLabel.rectTransform, new Vector2(640f, 24f), new Vector2(220f, -180f));

        InventoryUIKit.CreateScrollList("DiceList", panel.transform, new Vector2(640f, 100f),
                                        new Vector2(220f, -235f), out _diceContent);

        // 底：提示（左）+ 自动装填 / 返回卡包（右下并排）
        _hintText = InventoryUIKit.CreateLabel("Hint", panel.transform, "", 15, InventoryUIKit.Muted,
                                               TextAnchor.MiddleLeft);
        InventoryUIKit.Place(_hintText.rectTransform, new Vector2(460f, 56f), new Vector2(-390f, -290f));
        _hintText.horizontalOverflow = HorizontalWrapMode.Wrap;      // 新宽度更窄，提示要折行

        InventoryUIKit.CreateButton("AutoLoadoutButton", panel.transform, "自动装填",
                                    new Vector2(150f, 40f), new Vector2(300f, -310f), AutoLoadout);
        InventoryUIKit.CreateButton("BackButton", panel.transform, "返回卡包", new Vector2(150f, 40f),
                                    new Vector2(460f, -310f), BackToDeck);

        BuildDiceTip();          // 悬停小窗挂最后 → 天生盖在其它元素上

        _built = true;
    }

    // ------------------------------------------------------------------
    // 作用域
    // ------------------------------------------------------------------
    /// <summary>牌库里该模板的所有实例（保持牌库顺序）。</summary>
    List<Card> TemplateCards(CardData data)
    {
        var result = new List<Card>();
        var lib = CardDeckManager.Instance != null ? CardDeckManager.Instance.Library : null;
        if (lib == null || data == null) return result;
        foreach (Card c in lib)
        {
            if (c != null && ReferenceEquals(c.Data, data)) result.Add(c);
        }
        return result;
    }

    /// <summary>当前装填作用域：选中实例 → 只它一张；否则 → 整个大类的所有同名卡。</summary>
    IEnumerable<Card> ScopeCards()
    {
        if (_selectedCard != null) return new Card[] { _selectedCard };
        return TemplateCards(_selectedTemplate);
    }

    /// <summary>槽区展示用的代表卡：精确实例优先，否则取大类第一张。</summary>
    Card RepresentativeCard()
    {
        if (_selectedCard != null) return _selectedCard;
        var cards = TemplateCards(_selectedTemplate);
        return cards.Count > 0 ? cards[0] : null;
    }

    // ------------------------------------------------------------------
    // 刷新
    // ------------------------------------------------------------------
    void Refresh()
    {
        if (!_built) return;

        Card rep = RepresentativeCard();
        int slotCount = rep != null ? CardLoadout.SlotCount(rep) : 0;

        RebuildCardRows();
        RebuildSlotCells(slotCount);
        UpdateBigCard();
        RebuildDiceRows();
        RefreshHint();
    }

    void RebuildCardRows()
    {
        HideDiceTip();      // 列表重建 → 悬停目标即将销毁，先收起小窗

        foreach (RectTransform row in _cardRows)
        {
            if (row != null) Destroy(row.gameObject);
        }
        _cardRows.Clear();

        CardDeckManager deckMgr = CardDeckManager.Instance;
        if (deckMgr == null) return;

        // 按模板聚合（保持首次出现顺序）
        var order = new List<CardData>();
        var groups = new Dictionary<CardData, List<Card>>();
        foreach (Card card in deckMgr.Library)
        {
            if (card == null || card.Data == null) continue;
            if (!groups.TryGetValue(card.Data, out List<Card> list))
            {
                list = new List<Card>();
                groups[card.Data] = list;
                order.Add(card.Data);
            }
            list.Add(card);
        }

        for (int g = 0; g < order.Count; g++)
        {
            CardData data = order[g];
            List<Card> cards = groups[data];
            bool expanded = ReferenceEquals(data, _selectedTemplate);
            Color bg = expanded ? InventoryUIKit.SlotSel : InventoryUIKit.SlotBg;

            CardData captured = data;
            RectTransform row = BuildGroupRow($"Group_{g}", data, cards, expanded, bg,
                                              () => SelectTemplate(captured));
            _cardRows.Add(row);

            if (!expanded) continue;

            // 子菜单：展开时列出每张实例（缩进 + #实例号 + 该实例装填提示）
            for (int k = 0; k < cards.Count; k++)
            {
                Card c = cards[k];
                Color subBg = ReferenceEquals(c, _selectedCard) ? InventoryUIKit.SlotSel : InventoryUIKit.SlotBg;
                Card capturedCard = c;
                RectTransform subRow = BuildSubRow($"Sub_{g}_{k}", c, subBg, () => SelectInstance(capturedCard));
                _cardRows.Add(subRow);
            }
        }
    }

    void RebuildSlotCells(int slotCount)
    {
        Card rep = RepresentativeCard();
        List<DiceData> effective = rep != null ? CardLoadout.GetEffective(rep) : null;

        for (int i = 0; i < _slotCells.Count; i++)
        {
            InventoryUIKit.SlotCell cell = _slotCells[i];
            if (cell == null) continue;

            if (i >= slotCount)
            {
                cell.root.SetActive(false);
                continue;
            }

            cell.root.SetActive(true);
            DiceData dice = effective != null && i < effective.Count ? effective[i] : null;
            var st = rep != null ? CardLoadout.StateOf(rep, i) : CardLoadout.SlotState.Default;

            string diceName = dice != null ? dice.diceName
                            : st == CardLoadout.SlotState.Unloaded ? "未装填"
                            : "默认骰缺失";
            cell.nameText.text = $"槽 {i + 1}　{diceName}";
            cell.countText.text = st == CardLoadout.SlotState.Override ? "●改"
                                : st == CardLoadout.SlotState.Unloaded ? "未装"
                                : "默认";
            cell.background.color = (i == _selectedSlot) ? InventoryUIKit.Gold : InventoryUIKit.SlotBg;
        }
    }

    void RebuildDiceRows()
    {
        foreach (RectTransform row in _diceRows)
        {
            if (row != null) Destroy(row.gameObject);
        }
        _diceRows.Clear();

        // 第一行固定是「卸下」= 该槽留空，战斗时用临时骰子
        RectTransform resetRow = InventoryUIKit.CreateRow("Dice_Default", _diceContent, rowHeight,
                                                          "卸下", InventoryUIKit.SlotSel,
                                                          () => AssignDice(null), out _);
        _diceRows.Add(resetRow);

        if (InventoryManager.Instance == null) return;

        IReadOnlyList<ItemData> diceItems = InventoryManager.Instance.AllDiceItems;
        for (int i = 0; i < diceItems.Count; i++)
        {
            ItemData item = diceItems[i];
            if (item == null || item.diceRef == null) continue;

            DiceData dice = item.diceRef;
            int owned = InventoryManager.Instance.CountDice(dice);
            string text = $"{dice.diceName}　[{CompactValues(dice.diceValues)}]　持有 {owned}";

            DiceData captured = dice;
            RectTransform row = InventoryUIKit.CreateRow($"Dice_{i}", _diceContent, rowHeight, text,
                                                         InventoryUIKit.SlotBg, () => AssignDice(captured), out _);
            _diceRows.Add(row);
        }
    }

    void RefreshHint()
    {
        if (_selectedTemplate == null)
        {
            _hintText.text = "先在左侧点一个大类展开同名卡子菜单。装填是纯配置：这里不消耗骰子，战斗中抽到该卡时才从骰子分区扣。";
            return;
        }

        var cards = TemplateCards(_selectedTemplate);
        if (_selectedCard == null)
        {
            _hintText.text = $"已选中大类「{_selectedTemplate.cardName}」共 {cards.Count} 张：现在装填会作用于所有同名卡。" +
                             "想只装其中一张，就在子菜单里点那张卡。";
            return;
        }

        int slotCount = CardLoadout.SlotCount(_selectedCard);
        if (slotCount <= 0)
        {
            _hintText.text = $"{_selectedCard.Data.cardName} 没有骰子槽，直接按基础数值结算。";
            return;
        }

        if (_selectedSlot < 0)
        {
            _hintText.text = "再点右侧一个骰子槽，共 " + slotCount + " 槽，然后从下方列表选骰子。";
            return;
        }

        _hintText.text = $"槽 {_selectedSlot + 1} 已选中：点下方任意骰子换装，只影响 #{_selectedCard.InstanceId} 这一张；" +
                         "点「卸下」则该槽留空，战斗时用临时骰子。\n改装填只影响之后抽到的牌。";
    }

    // ------------------------------------------------------------------
    // 交互
    // ------------------------------------------------------------------
    /// <summary>点大类行：展开/收起子菜单，作用域切回"整类"。</summary>
    void SelectTemplate(CardData data)
    {
        _selectedCard = null;
        _selectedSlot = -1;
        _selectedTemplate = ReferenceEquals(_selectedTemplate, data) ? null : data;
        Refresh();
        // ★教学钩子在 Refresh 之后发：下一拍（点骰子槽）激活时槽位节点刚被重建，焦点才找得到活节点
        OnCardSelected?.Invoke();
    }

    /// <summary>点子菜单实例行：作用域切到该单张。</summary>
    void SelectInstance(Card card)
    {
        if (card == null) return;
        _selectedCard = card;
        _selectedTemplate = card.Data;
        _selectedSlot = -1;
        Refresh();
        OnCardSelected?.Invoke();       // ★教学钩子：点卡即算（S31），同上在 Refresh 后发
    }

    void SelectSlot(int index)
    {
        Card rep = RepresentativeCard();
        if (rep == null)
        {
            Debug.Log("[LoadoutUI] 还没选卡，无法选骰子槽");
            return;
        }
        if (index >= CardLoadout.SlotCount(rep)) return;

        _selectedSlot = (_selectedSlot == index) ? -1 : index;
        Refresh();
        OnSlotSelected?.Invoke();       // ★v2.5 教学钩子（S32）
    }

    void AssignDice(DiceData dice)
    {
        if (_selectedTemplate == null)
        {
            _hintText.text = "先在左侧选一个大类（或子菜单里的一张卡）。";
            return;
        }
        if (_selectedSlot < 0)
        {
            _hintText.text = "先点右侧的一个骰子槽。";
            return;
        }

        // dice == null → 该槽回默认（spec §6「清空」的实现，见 Task 7 [规格解释]）
        bool any = false;
        foreach (Card c in ScopeCards())
        {
            if (CardLoadout.SetSlot(c, _selectedSlot, dice)) any = true;
        }
        if (any)
        {
            Debug.Log($"[LoadoutUI] 装填作用域：{(_selectedCard != null ? $"单张 #{_selectedCard.InstanceId}" : _selectedTemplate.cardName + " 整类")}" +
                      $" 槽 {_selectedSlot + 1} → {(dice != null ? dice.diceName : "默认")}");
            if (dice != null) OnConfigured?.Invoke();       // ★教学钩子：真正装上骰子才算一次装填
        }
        Refresh();
    }

    // ------------------------------------------------------------------
    // 自动装填（★2026-09-13：算法在 CardLoadout.AutoAssign，开局自动装填共用同一口径）
    //   点一下：遍历当局牌库，把**还没手动装填过**的卡，各骰槽统一装成
    //   「背包里拥有且最强」的战斗骰。已经手动配过骰子的卡保持不动。
    // ------------------------------------------------------------------
    void AutoLoadout()
    {
        CardDeckManager deckMgr = CardDeckManager.Instance;
        if (deckMgr == null)
        {
            _hintText.text = "牌库还没就绪。";
            return;
        }

        DiceData best = CardLoadout.FindBestOwnedBattleDice();
        if (best == null)
        {
            _hintText.text = "背包里没有可用的战斗骰子。先去搜刮一些吧。";
            return;
        }

        int cards = CardLoadout.AutoAssign(deckMgr.Library);

        _selectedSlot = -1;
        Debug.Log($"[LoadoutUI] 自动装填：{cards} 张卡 → {best.diceName}");
        // ★v2.5 教学钩子：点了按钮就广播（哪怕 0 张可装——教学拍认"玩家点了自动装填"这个动作，
        // 否则手动的卡已覆盖全部大类时会死锁在自动装填拍）。非教程侧无人订阅，无副作用。
        OnConfigured?.Invoke();
        Refresh();

        _hintText.text = cards > 0
            ? $"已自动装填 {cards} 张卡 → {best.diceName}（背包里最好的战斗骰）。"
            : "没有需要装填的卡（已手动装填的卡不会被覆盖）。";
    }

    // ------------------------------------------------------------------
    // 公式与提示（★2026-09-13 装填 UI 改版：静态纯函数，L2 编辑态断言目标）
    //   公式规则见 spec §5；提示聚合见 spec §4.2/§6。
    // ------------------------------------------------------------------
    const string BaseValueHex = "#000000";   // 卡面基础值数字 = 黑（卡面底色偏黄，黄字看不清）；骰子段蓝 = CardData.DiceValueBlueHex

    /// <summary>点数序列 → 紧凑串：升序后 ≥3 连续合并 a~b，其余逗号分隔。[1,2,3,4,9,10,11,20] → 1~4,9~11,20。</summary>
    static string CompactValues(int[] values)
    {
        if (values == null || values.Length == 0) return "?";
        int[] sorted = (int[])values.Clone();
        System.Array.Sort(sorted);
        var sb = new System.Text.StringBuilder(sorted.Length * 4);
        int i = 0;
        while (i < sorted.Length)
        {
            int j = i;
            while (j + 1 < sorted.Length && sorted[j + 1] == sorted[j] + 1) j++;
            if (j - i + 1 >= 3)
            {
                sb.Append(sorted[i]).Append('~').Append(sorted[j]);
            }
            else
            {
                for (int k = i; k <= j; k++)
                {
                    if (k > i) sb.Append(',');
                    sb.Append(sorted[k]);
                }
            }
            i = j + 1;
            if (i < sorted.Length) sb.Append(',');
        }
        return sb.ToString();
    }

    /// <summary>遍历描述的 [表达式] 段生成卡面配置态文本（富文本）：基础值数字包黄，骰子段含括号包蓝。
    /// 已装填槽 → [紧凑区间]；未装填/缺骰 → [战斗骰子N] 占位。effective 传 null = 全占位（左栏迷你卡恒用）。</summary>
    static string FaceDescription(CardData data, List<DiceData> effective)
    {
        if (data == null || string.IsNullOrEmpty(data.description)) return "";

        string desc = data.description;
        var exprRegex = new System.Text.RegularExpressions.Regex(@"\[(.*?)\]");
        var slotRegex = new System.Text.RegularExpressions.Regex("战斗骰子([1-4])");
        var numRegex = new System.Text.RegularExpressions.Regex(@"\d+");
        var builder = new System.Text.StringBuilder(desc.Length + 64);
        int copiedUpTo = 0;
        foreach (System.Text.RegularExpressions.Match m in exprRegex.Matches(desc))
        {
            builder.Append(desc, copiedUpTo, m.Index - copiedUpTo);
            copiedUpTo = m.Index + m.Length;

            string expr = m.Groups[1].Value;
            int pos = 0;
            foreach (System.Text.RegularExpressions.Match sm in slotRegex.Matches(expr))
            {
                builder.Append(ColorNumbers(expr, pos, sm.Index - pos, numRegex));

                DiceData dice = null;
                if (effective != null)
                {
                    int slot = int.Parse(sm.Groups[1].Value) - 1;
                    if (slot < effective.Count) dice = effective[slot];
                }
                string seg = (dice != null && dice.diceValues != null && dice.diceValues.Length > 0)
                           ? "[" + CompactValues(dice.diceValues) + "]"
                           : "[" + sm.Value + "]";
                builder.Append("<color=").Append(CardData.DiceValueBlueHex).Append('>').Append(seg).Append("</color>");
                pos = sm.Index + sm.Length;
            }
            builder.Append(ColorNumbers(expr, pos, expr.Length - pos, numRegex));
        }
        builder.Append(desc, copiedUpTo, desc.Length - copiedUpTo);
        return builder.ToString();
    }

    /// <summary>表达式里骰子占位之外的静态片段，其中数字包黄色。</summary>
    static string ColorNumbers(string text, int start, int length, System.Text.RegularExpressions.Regex numRegex)
    {
        if (length <= 0) return "";
        string part = text.Substring(start, length);
        return numRegex.Replace(part, mm => "<color=" + BaseValueHex + ">" + mm.Value + "</color>");
    }

    /// <summary>提示条目形态：Inconsistent=不一致（聚合传 null）；NoSlots=无骰槽；Unloaded=全未装填；DiceList=逐骰列出。</summary>
    enum HintKind { Inconsistent, NoSlots, Unloaded, DiceList }

    static HintKind KindOf(List<DiceData> entries)
    {
        if (entries == null) return HintKind.Inconsistent;
        if (entries.Count == 0) return HintKind.NoSlots;
        bool allNull = true;
        for (int i = 0; i < entries.Count; i++)
        {
            if (entries[i] != null) { allNull = false; break; }
        }
        return allNull ? HintKind.Unloaded : HintKind.DiceList;
    }

    /// <summary>「装填不一致」判据的核心：两条有效骰序列逐槽同引用才算一致。</summary>
    static bool SameEntries(List<DiceData> a, List<DiceData> b)
    {
        if (a == null || b == null) return false;
        if (a.Count != b.Count) return false;
        for (int i = 0; i < a.Count; i++)
        {
            if (!ReferenceEquals(a[i], b[i])) return false;
        }
        return true;
    }

    /// <summary>单张卡的提示条目：长度 = SlotCount，元素 null = 该槽未装填。</summary>
    static List<DiceData> HintEntriesOf(Card card)
    {
        return card != null ? CardLoadout.GetEffective(card) : null;
    }

    /// <summary>大类聚合：所有实例装填一致 → 代表序列；任一不同 → null（= 装填不一致）。</summary>
    static List<DiceData> ConsistentGroupEntries(List<Card> cards)
    {
        if (cards == null || cards.Count == 0) return null;
        List<DiceData> first = CardLoadout.GetEffective(cards[0]);
        for (int i = 1; i < cards.Count; i++)
        {
            if (!SameEntries(first, CardLoadout.GetEffective(cards[i]))) return null;
        }
        return first;
    }

    // ------------------------------------------------------------------
    // 悬停小窗（spec §4.3：悬停左栏骰名 → 跟随鼠标显示该骰点数；移出/重建/关闭时隐藏）
    // ------------------------------------------------------------------
    void BuildDiceTip()
    {
        if (_panelRT == null) return;

        _diceTip = InventoryUIKit.CreateRect("DiceTip", _panelRT);
        _diceTip.anchorMin = _diceTip.anchorMax = new Vector2(0.5f, 0.5f);
        _diceTip.pivot = new Vector2(0f, 1f);            // 左上角贴合鼠标 → 向右下展开
        _diceTip.sizeDelta = new Vector2(190f, 30f);

        Image bg = _diceTip.gameObject.AddComponent<Image>();
        bg.sprite = InventoryUIKit.WhitePixel;
        bg.color = new Color(0.05f, 0.03f, 0.01f, 0.95f);
        bg.raycastTarget = false;                        // 小窗不挡悬停（防自己触发 PointerExit）

        Outline ol = _diceTip.gameObject.AddComponent<Outline>();
        ol.effectColor = new Color(InventoryUIKit.Brass.r, InventoryUIKit.Brass.g, InventoryUIKit.Brass.b, 0.9f);
        ol.effectDistance = new Vector2(1f, -1f);

        _diceTipName = InventoryUIKit.CreateLabel("Name", _diceTip, "", 13, InventoryUIKit.Muted,
                                                  TextAnchor.MiddleLeft);
        _diceTipName.rectTransform.anchorMin = new Vector2(0f, 0f);
        _diceTipName.rectTransform.anchorMax = new Vector2(0f, 1f);
        _diceTipName.rectTransform.pivot = new Vector2(0f, 0.5f);
        _diceTipName.rectTransform.offsetMin = new Vector2(8f, 0f);
        _diceTipName.rectTransform.offsetMax = new Vector2(102f, 0f);

        _diceTipValues = InventoryUIKit.CreateLabel("Values", _diceTip, "", 15, InventoryUIKit.Brass,
                                                    TextAnchor.MiddleRight);
        _diceTipValues.fontStyle = FontStyle.Bold;
        _diceTipValues.rectTransform.anchorMin = Vector2.zero;
        _diceTipValues.rectTransform.anchorMax = Vector2.one;
        _diceTipValues.rectTransform.offsetMin = new Vector2(100f, 0f);
        _diceTipValues.rectTransform.offsetMax = new Vector2(-8f, 0f);

        _diceTip.gameObject.SetActive(false);
    }

    void ShowDiceTip(DiceData dice)
    {
        if (!_built || _diceTip == null || dice == null) return;

        _diceTipName.text = dice.diceName;
        _diceTipValues.text = (dice.diceValues != null && dice.diceValues.Length > 0)
            ? "[" + CompactValues(dice.diceValues) + "]"
            : "[?]";
        _diceTip.gameObject.SetActive(true);
        _diceTip.SetAsLastSibling();                     // 盖过面板内其它元素
        UpdateDiceTipPosition();
    }

    void HideDiceTip()
    {
        if (_diceTip != null && _diceTip.gameObject.activeSelf)
        {
            _diceTip.gameObject.SetActive(false);
        }
    }

    void UpdateDiceTipPosition()
    {
        if (_diceTip == null || !_diceTip.gameObject.activeSelf || _panelRT == null) return;

        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(
                _panelRT, Input.mousePosition, null, out Vector2 local))   // Overlay 画布 → 相机传 null
        {
            local += new Vector2(12f, -12f);             // 鼠标右下少量偏移，少挡光标

            float hw = _panelRT.rect.width * 0.5f;
            float hh = _panelRT.rect.height * 0.5f;
            float w = _diceTip.rect.width;
            float h = _diceTip.rect.height;
            local.x = Mathf.Clamp(local.x, -hw + 4f, hw - w - 4f);       // 夹紧在面板内
            local.y = Mathf.Clamp(local.y, -hh + h + 4f, hh - 4f);

            _diceTip.anchoredPosition = local;
        }
    }

    // ------------------------------------------------------------------
    // 左栏行渲染（spec §4.2：大类行 = 迷你卡面 + 卡名 ×N + 装填提示；子行 = · 卡名 #id + 提示）
    // ------------------------------------------------------------------
    const float GroupRowHeight = 132f;
    const float SubRowHeight = 32f;
    const float MiniCardHeight = 128f;   // 行高 132 - 上下各 2（真实卡面缩微的视觉高度）
    const float MiniCardLeft = 10f;      // 迷你卡距行左边距
    const float BigCardFaceHeight = 360f;   // 放大卡内真实卡面的视觉高度（填满 264×360 外框）
    static readonly Color HintDice = new Color(0.78f, 0.71f, 0.55f, 1f);   // 骰名 #C8B48D
    static readonly Color DimText = new Color(0.42f, 0.37f, 0.27f, 1f);    // 暗字 #6B5F45

    RectTransform BuildGroupRow(string name, CardData data, List<Card> cards, bool expanded, Color bg,
                                System.Action onClick)
    {
        RectTransform rt = InventoryUIKit.CreateRect(name, _cardContent);
        LayoutElement le = rt.gameObject.AddComponent<LayoutElement>();
        le.minHeight = le.preferredHeight = GroupRowHeight;

        Image img = rt.gameObject.AddComponent<Image>();
        img.sprite = InventoryUIKit.WhitePixel;
        img.color = bg;
        Button btn = rt.gameObject.AddComponent<Button>();
        btn.targetGraphic = img;
        btn.onClick.AddListener(() => onClick());

        // 左：迷你卡面（真实卡面缩微；悬停/点击穿透给行）
        ResolveCardPrefab();
        float cardVisW = MiniCardHeight * (_cardDesignSize.x / _cardDesignSize.y);
        float textLeft = MiniCardLeft + cardVisW + 8f;
        Card repCard = (_selectedCard != null && ReferenceEquals(_selectedCard.Data, data)) ? _selectedCard : cards[0];
        CardView mini = CreateDisplayCard(rt, MiniCardHeight, Vector2.zero, repCard);
        if (mini != null)
        {
            // 锚到行左侧（CreateDisplayCard 默认居中锚点，直接用会把卡放到行中间）
            RectTransform mrt = mini.transform as RectTransform;
            if (mrt != null)
            {
                mrt.anchorMin = new Vector2(0f, 0.5f);
                mrt.anchorMax = new Vector2(0f, 0.5f);
                mrt.anchoredPosition = new Vector2(MiniCardLeft + cardVisW * 0.5f, 0f);
            }
            // 配置态卡面：描述恒为占位式（基础值+[战斗骰子N]），不读该卡在手上时的实时骰值
            mini.SetStaticDisplay(FaceDescription(data, null), data.energyCost);
        }

        // 右上：卡名 ×N ▾/▸
        Text nameLabel = InventoryUIKit.CreateLabel("Name", rt,
            $"{data.cardName} ×{cards.Count}" + (expanded ? " ▾" : " ▸"),
            16, InventoryUIKit.Cream, TextAnchor.MiddleLeft);
        nameLabel.rectTransform.anchorMin = new Vector2(0f, 0.5f);
        nameLabel.rectTransform.anchorMax = new Vector2(1f, 1f);
        nameLabel.rectTransform.offsetMin = new Vector2(textLeft, 0f);
        nameLabel.rectTransform.offsetMax = new Vector2(-6f, -2f);

        // 右下：装填提示（逐骰条目，骰名可悬停）
        RectTransform hintRow = InventoryUIKit.CreateRect("HintRow", rt);
        hintRow.anchorMin = new Vector2(0f, 0f);
        hintRow.anchorMax = new Vector2(1f, 0.5f);
        hintRow.offsetMin = new Vector2(textLeft, 2f);
        hintRow.offsetMax = new Vector2(-6f, 0f);
        HorizontalLayoutGroup hl = hintRow.gameObject.AddComponent<HorizontalLayoutGroup>();
        hl.childControlWidth = true;
        hl.childControlHeight = true;
        hl.childForceExpandWidth = false;
        hl.childForceExpandHeight = false;
        hl.childAlignment = TextAnchor.MiddleLeft;
        hl.spacing = 6f;

        AddHintTo(hintRow, ConsistentGroupEntries(cards), onClick);
        return rt;
    }

    RectTransform BuildSubRow(string name, Card card, Color bg, System.Action onClick)
    {
        RectTransform rt = InventoryUIKit.CreateRect(name, _cardContent);
        LayoutElement le = rt.gameObject.AddComponent<LayoutElement>();
        le.minHeight = le.preferredHeight = SubRowHeight;

        Image img = rt.gameObject.AddComponent<Image>();
        img.sprite = InventoryUIKit.WhitePixel;
        img.color = bg;
        Button btn = rt.gameObject.AddComponent<Button>();
        btn.targetGraphic = img;
        btn.onClick.AddListener(() => onClick());

        RectTransform line = InventoryUIKit.CreateRect("Line", rt);
        InventoryUIKit.Stretch(line);
        line.offsetMin = new Vector2(16f, 0f);
        line.offsetMax = new Vector2(-6f, 0f);
        HorizontalLayoutGroup hl = line.gameObject.AddComponent<HorizontalLayoutGroup>();
        hl.childControlWidth = true;
        hl.childControlHeight = true;
        hl.childForceExpandWidth = false;
        hl.childForceExpandHeight = false;
        hl.childAlignment = TextAnchor.MiddleLeft;
        hl.spacing = 6f;

        InventoryUIKit.CreateLabel("Prefix", line, $"· {card.Data.cardName} #{card.InstanceId}", 14,
                                   InventoryUIKit.Cream, TextAnchor.MiddleLeft);
        AddHintTo(line, HintEntriesOf(card), onClick);
        return rt;
    }

    /// <summary>创建一张只读真实卡面（CardView 缩放件，卡包同款）：不挡射线、不接交互，悬停/点击穿透给下层。</summary>
    CardView CreateDisplayCard(RectTransform parent, float targetHeight, Vector2 anchoredPos, Card card)
    {
        ResolveCardPrefab();
        if (_cardPrefab == null || parent == null) return null;

        CardView cv = Instantiate(_cardPrefab, parent);
        cv.name = "CardFace";

        RectTransform rt = cv.transform as RectTransform;
        if (rt != null)
        {
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.sizeDelta = _cardDesignSize;              // 内部布局按设计尺寸；视觉尺寸由 localScale 决定
            rt.anchoredPosition = anchoredPos;
        }
        cv.transform.localScale = Vector3.one * (targetHeight / _cardDesignSize.y);

        CanvasGroup cg = cv.GetComponent<CanvasGroup>();
        if (cg == null) cg = cv.gameObject.AddComponent<CanvasGroup>();
        cg.blocksRaycasts = false;                        // 只读展示：指针事件全部穿透
        cv.InteractionLocked = true;

        if (card != null) cv.SetCard(card);
        cv.gameObject.SetActive(true);
        return cv;
    }

    void ResolveCardPrefab()
    {
        if (_cardPrefab == null && HandUIController.Instance != null)
            _cardPrefab = HandUIController.Instance.CardViewPrefab;
        if (_cardPrefab == null && CardViewCreator.Instance != null)
            _cardPrefab = CardViewCreator.Instance.CardViewPrefab;

        // 兜底：编辑态 HandUIController.CardViewPrefab 尚未被 Awake 填充（null），
        // 直扫「不在场景里」的 CardView Prefab 资产——与 HandUIController.AutoBindPrefab 同款逻辑。
        if (_cardPrefab == null)
        {
            CardView[] allCvs = Resources.FindObjectsOfTypeAll<CardView>();
            foreach (CardView cv in allCvs)
            {
                if (cv == null) continue;
                string sceneName = cv.gameObject.scene.name;
                if (string.IsNullOrEmpty(sceneName)) { _cardPrefab = cv; break; }
            }
        }

        if (_cardPrefab == null) return;

        RectTransform prt = _cardPrefab.transform as RectTransform;
        if (prt != null && prt.sizeDelta.x > 1f && prt.sizeDelta.y > 1f) _cardDesignSize = prt.sizeDelta;
    }

    /// <summary>把提示条目渲染进一行：不一致/无骰槽/未装填 → 单条暗字；否则逐骰（骰名可悬停、点击转发行选中）。</summary>
    void AddHintTo(RectTransform parent, List<DiceData> entries, System.Action rowClick)
    {
        HintKind kind = KindOf(entries);
        if (kind != HintKind.DiceList)
        {
            string text = kind == HintKind.Inconsistent ? "装填不一致"
                        : kind == HintKind.NoSlots ? "无骰槽" : "未装填";
            Color color = kind == HintKind.Inconsistent ? InventoryUIKit.Muted : DimText;
            AddHintEntry(parent, text, color, null, null);
            return;
        }

        for (int i = 0; i < entries.Count; i++)
        {
            DiceData d = entries[i];
            AddHintEntry(parent, d != null ? d.diceName : "未装填",
                         d != null ? HintDice : DimText, d, rowClick);
        }
    }

    void AddHintEntry(RectTransform parent, string text, Color color, DiceData dice, System.Action onClick)
    {
        Text t = InventoryUIKit.CreateLabel("Hint", parent, text, 13, color, TextAnchor.MiddleLeft);
        if (dice == null) return;                        // 纯文本条目：不挡点击、不悬停

        t.raycastTarget = true;                          // CreateLabel 默认 false，悬停必须开
        AddHintEntryHandlers(t.gameObject, () => ShowDiceTip(dice), HideDiceTip, onClick);
    }

    /// <summary>悬停 + 点击转发：EventTrigger 会截住 PointerClick，必须自己把行点击代跑（否则点不到行）。</summary>
    static void AddHintEntryHandlers(GameObject go, System.Action onEnter, System.Action onExit,
                                     System.Action onClick)
    {
        EventTrigger trigger = go.GetComponent<EventTrigger>();
        if (trigger == null) trigger = go.AddComponent<EventTrigger>();
        AddTriggerEntry(trigger, EventTriggerType.PointerEnter, _ => { if (onEnter != null) onEnter(); });
        AddTriggerEntry(trigger, EventTriggerType.PointerExit, _ => { if (onExit != null) onExit(); });
        if (onClick != null) AddTriggerEntry(trigger, EventTriggerType.PointerClick, _ => onClick());
    }

    static void AddTriggerEntry(EventTrigger trigger, EventTriggerType type,
                                UnityEngine.Events.UnityAction<BaseEventData> callback)
    {
        var entry = new EventTrigger.Entry { eventID = type };
        entry.callback.AddListener(callback);
        trigger.triggers.Add(entry);
    }

    // ------------------------------------------------------------------
    // 放大卡（spec §4.4：代表卡 → 真实卡面填满整框；未选卡 = 空占位框）
    // ------------------------------------------------------------------
    void EnsureBigCardView()
    {
        if (_bigCardView != null || _bigCardRT == null) return;
        _bigCardView = CreateDisplayCard(_bigCardRT, BigCardFaceHeight, Vector2.zero, null);
    }

    void UpdateBigCard()
    {
        Card rep = RepresentativeCard();
        if (rep == null || rep.Data == null)
        {
            if (_bigCardView != null) _bigCardView.gameObject.SetActive(false);
            return;
        }

        EnsureBigCardView();
        if (_bigCardView != null)
        {
            _bigCardView.gameObject.SetActive(true);
            _bigCardView.SetCard(rep);
            // 配置态卡面：基础值黄 + 骰子段蓝；已装填槽 [紧凑区间]，未装填槽 [战斗骰子N]
            _bigCardView.SetStaticDisplay(FaceDescription(rep.Data, CardLoadout.GetEffective(rep)),
                                          rep.Data.energyCost);
        }
    }
}

// =============================================================================
// 模块：UI - CardRewardPickUI 战利品卡牌三选一
// 用途：「战利品卡牌物品」（ItemType.卡牌，带 runtimeDropConfig 快照）被使用时弹出：
//       候选 3 张（敌人侧按稀有度/成员/权重抽 + 玩家牌库实时读），选一张 → AddCardAtRuntime 进本局牌库
//       （★并立刻进当前抽牌堆，抽牌堆计数即时刷新），物品本身随之消耗（从背包移除）。
// 设计依据：docs/2026-09-12_小队掉落编辑-design.md §5.3（名额「敌 1 + 玩家 1 + 补位」与
//           放弃/返回规则不变；敌人侧新增稀有度 → 成员 → 卡 的独立抽取与退化链）
// 模态：打开时 Interactions.ModalPopupActive = true；ESC = 返回（不消费物品）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class CardRewardPickUI : MonoBehaviour
{
    static CardRewardPickUI _instance;

    public static bool IsOpen => _instance != null && _instance._isOpen;

    [Header("布局（零美术，代码动态创建）")]
    public Vector2 panelSize = new Vector2(560f, 520f);
    public Vector2 rowSize = new Vector2(500f, 96f);
    public float rowSpacing = 8f;

    /// <summary>一次三选一给几张候选（spec §9:96）。不足就有几张给几张。</summary>
    const int CandidateCount = 3;

    RectTransform _root;
    RectTransform _panelRT;
    Text _titleText;
    Text _summaryText;
    Text _hintText;
    readonly List<GameObject> _rows = new List<GameObject>();
    readonly List<CardData> _candidates = new List<CardData>();
    /// <summary>★2026-09-12：与 _candidates 平行 —— 每张候选是否来自敌人侧（刷新时标【敌人卡】/【玩家卡】）。</summary>
    readonly List<bool> _candidateFromEnemy = new List<bool>();

    /// <summary>正在使用的卡牌物品。选中/放弃都会消耗它。</summary>
    ItemData _item;
    bool _built;
    bool _isOpen;

    // ------------------------------------------------------------------
    // 实例生命周期（懒创建：场景里没有也会自己挂到 UICanvas）
    // ------------------------------------------------------------------
    static CardRewardPickUI Ensure()
    {
        if (_instance != null) return _instance;
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            Debug.LogWarning("[三选一] 找不到 UICanvas，无法弹出");
            return null;
        }
        GameObject go = new GameObject("CardRewardPickUI");
        go.transform.SetParent(canvas.transform, false);
        _instance = go.AddComponent<CardRewardPickUI>();
        return _instance;
    }

    void OnDestroy()
    {
        if (_instance == this) _instance = null;
    }

    void Update()
    {
        // ESC = 返回：不消费物品（玩家之后可以再从背包点它）。旧子页同口径。
        if (_isOpen && Input.GetKeyDown(KeyCode.Escape)) Close();
    }

    // ------------------------------------------------------------------
    // 开 / 关
    // ------------------------------------------------------------------
    /// <summary>
    /// 对一个「战利品卡牌物品」开三选一。两个入口共用：
    /// ① 背包 InventoryUI 点「使用」；② 战后汇报条点那一条。
    /// </summary>
    public static void Show(ItemData cardItem)
    {
        CardRewardPickUI ui = Ensure();
        if (ui == null) return;
        ui.OpenFor(cardItem);
    }

    void OpenFor(ItemData cardItem)
    {
        if (cardItem == null || cardItem.type != ItemType.卡牌) return;
        if (_isOpen) return;

        // ★2026-09-12 用户定稿：稀有度权重全 0 = 该小队不出卡牌奖励。
        // 物品也许是在「权重还没调 0」之前发的，用的时候按同一口径作废 ——
        // 否则玩家把权重全调 0 之后仍能从旧物品里开出一堆玩家卡，看起来就是「全 0 照样出卡」。
        if (cardItem.runtimeDropConfig != null && !SquadDropConfig.HasRarityWeight(cardItem.runtimeDropConfig))
        {
            ConsumeItem(cardItem);
            Debug.Log($"[三选一] 「{cardItem.itemName}」的稀有度权重全为 0 → 不出卡牌，物品作废");
            return;
        }

        _candidates.Clear();
        _candidateFromEnemy.Clear();
        BuildCandidates(cardItem, _candidates, _candidateFromEnemy);

        if (_candidates.Count == 0)
        {
            // 两侧都空：当场作废物品，不留「点不掉」的死条目（旧逻辑要点 4）
            ConsumeItem(cardItem);
            Debug.Log($"[三选一] 「{cardItem.itemName}」没有候选（敌人侧与当局牌库都为空）→ 物品作废");
            return;
        }

        _item = cardItem;
        if (!_built) Build();
        if (_root == null) { _item = null; return; }

        _isOpen = true;
        _root.gameObject.SetActive(true);
        Interactions.ModalPopupActive = true;
        Interactions.RefreshEndTurnButton();
        Refresh();

        PopupFX.PlayOpen(_panelRT);              // 全局统一入场手感
    }

    void Close()
    {
        if (!_isOpen) return;
        _isOpen = false;
        _item = null;
        _candidates.Clear();
        _candidateFromEnemy.Clear();
        foreach (GameObject row in _rows) InventoryUIKit.Kill(row);
        _rows.Clear();
        if (_root != null) _root.gameObject.SetActive(false);
        Interactions.ModalPopupActive = false;
        Interactions.RefreshEndTurnButton();
    }

    // ------------------------------------------------------------------
    // 构建 / 刷新
    // ------------------------------------------------------------------
    void Build()
    {
        _root = InventoryUIKit.CreateOverlay("CardRewardPickPanel");
        if (_root == null) return;

        float half = panelSize.y * 0.5f;

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, panelSize, Vector2.zero, InventoryUIKit.PanelBg);
        _panelRT = panel.rectTransform;
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        _titleText = InventoryUIKit.CreateLabel("Title", panel.transform, "战利品卡牌", 20,
                                                InventoryUIKit.Brass, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(_titleText.rectTransform, new Vector2(panelSize.x - 40f, 30f),
                             new Vector2(0f, half - 30f));

        _summaryText = InventoryUIKit.CreateLabel("Summary", panel.transform, "", 14, InventoryUIKit.Muted,
                                                  TextAnchor.MiddleCenter);
        InventoryUIKit.Place(_summaryText.rectTransform, new Vector2(panelSize.x - 40f, 26f),
                             new Vector2(0f, half - 62f));

        _hintText = InventoryUIKit.CreateLabel("Hint", panel.transform, "", 14, InventoryUIKit.Cream,
                                               TextAnchor.MiddleCenter);
        InventoryUIKit.Place(_hintText.rectTransform, new Vector2(panelSize.x - 40f, 34f),
                             new Vector2(0f, -half + 96f));
        _hintText.horizontalOverflow = HorizontalWrapMode.Wrap;
        _hintText.verticalOverflow = VerticalWrapMode.Truncate;

        InventoryUIKit.CreateButton("ForfeitButton", panel.transform, "放弃（作废物品）", new Vector2(190f, 38f),
                                    new Vector2(-120f, -half + 40f), Forfeit);
        InventoryUIKit.CreateButton("BackButton", panel.transform, "返回", new Vector2(110f, 38f),
                                    new Vector2(120f, -half + 40f), Close);

        _built = true;
    }

    Vector2 RowPos(int row)
    {
        float top = panelSize.y * 0.5f - 92f;
        return new Vector2(0f, top - row * (rowSize.y + rowSpacing) - rowSize.y * 0.5f);
    }

    void Refresh()
    {
        if (!_built || _root == null || _item == null) return;

        _summaryText.text = $"物品「{_item.itemName}」　·　候选 {_candidates.Count} 张" +
                            "　·　选中即加入本局牌堆（物品随之消耗）";

        foreach (GameObject row in _rows) InventoryUIKit.Kill(row);
        _rows.Clear();

        for (int i = 0; i < _candidates.Count; i++)
        {
            CardData card = _candidates[i];
            int index = i;                                          // 闭包捕获：必须拷一份
            bool fromEnemy = i < _candidateFromEnemy.Count && _candidateFromEnemy[i];
            string text = $"{card.cardName}　费 {card.energyCost}　CD {card.cooldown}　{card.rarity}" +
                          $"　【{(fromEnemy ? "敌人卡" : "玩家卡")}】\n{card.description}";

            Button btn = InventoryUIKit.CreateButton($"Pick_{i}", _panelRT, text, rowSize, RowPos(i),
                                                     () => TakeCard(index));
            Text label = btn.GetComponentInChildren<Text>();
            if (label != null)
            {
                label.fontSize = 14;
                label.alignment = TextAnchor.MiddleLeft;
                label.horizontalOverflow = HorizontalWrapMode.Wrap;
                label.verticalOverflow = VerticalWrapMode.Truncate;
                label.rectTransform.offsetMin = new Vector2(12f, 4f);
                label.rectTransform.offsetMax = new Vector2(-12f, -4f);
            }
            _rows.Add(btn.gameObject);
        }

        _hintText.text = "点一张收下　·　「放弃」= 物品作废　·　ESC / 「返回」= 稍后再说（物品留在背包）";
    }

    // ------------------------------------------------------------------
    // 交互
    // ------------------------------------------------------------------
    void TakeCard(int candidateIndex)
    {
        if (candidateIndex < 0 || candidateIndex >= _candidates.Count || _item == null) return;

        CardDeckManager deck = CardDeckManager.Instance != null
            ? CardDeckManager.Instance
            : FindObjectOfType<CardDeckManager>();
        if (deck == null)
        {
            _hintText.text = "找不到 CardDeckManager，卡牌进不了牌堆。";
            return;
        }

        CardData card = _candidates[candidateIndex];
        ItemData used = _item;                 // Close 会置 null，先拷出来

        deck.AddCardAtRuntime(card);           // 一次性加入本局牌堆（内部顺带立刻进抽牌堆并刷新计数）
        ConsumeItem(used);                     // 物品用掉（从背包移除一格）
        Debug.Log($"[三选一] 选中「{card.cardName}」→ 加入本局牌堆；物品「{used.itemName}」已消耗");

        Close();
    }

    /// <summary>放弃：物品同样作废（否则可反复重开重掷候选，旧逻辑要点 1）。</summary>
    void Forfeit()
    {
        if (_item == null) return;
        ItemData used = _item;
        ConsumeItem(used);
        Debug.Log($"[三选一] 放弃「{used.itemName}」，物品作废");
        Close();
    }

    static void ConsumeItem(ItemData item)
    {
        InventoryManager mgr = InventoryManager.Instance != null
            ? InventoryManager.Instance
            : Object.FindObjectOfType<InventoryManager>();
        if (mgr != null) mgr.Inventory.Remove(item, 1);
    }

    // ------------------------------------------------------------------
    // 候选构建（沿用旧 BattleSettlementUI.BuildCandidates 的混池规则）
    // ------------------------------------------------------------------
    static CardDeckManager Deck()
    {
        return CardDeckManager.Instance != null
            ? CardDeckManager.Instance
            : Object.FindObjectOfType<CardDeckManager>();
    }

    /// <summary>
    /// 候选 = 敌人侧（按物品快照的稀有度/成员/池权重抽，每张候选独立滚）+ 玩家牌库，名额「敌 1 + 玩家 1 +
    /// 补位（先敌后玩）」；一侧为空则全取另一侧（规则未变，design §5.3）。结果**追加**进 result，
    /// fromEnemy 同步标来源；调用方先 Clear。
    /// </summary>
    static void BuildCandidates(ItemData item, List<CardData> result, List<bool> fromEnemy)
    {
        var shown = new HashSet<CardData>();

        // 玩家侧：本局牌库洗牌后按序取用（敌人侧已展示的引用在取用处跳过）
        var playerPool = new List<CardData>();
        CardDeckManager deck = Deck();
        if (deck != null)
        {
            foreach (Card card in deck.Library)
            {
                if (card == null || card.Data == null) continue;
                playerPool.Add(card.Data);
            }
        }
        Shuffle(playerPool);
        int playerCursor = 0;

        // ① 敌 1 + 玩家 1（某侧空 → 全取另一侧）
        CardData enemyPick = SquadDropConfig.DrawEnemyCard(item.runtimeDropConfig, shown);
        if (enemyPick != null)
        {
            shown.Add(enemyPick);
            result.Add(enemyPick);
            fromEnemy.Add(true);
        }

        CardData playerPick = NextPlayerCard(playerPool, ref playerCursor, shown);
        if (playerPick != null)
        {
            shown.Add(playerPick);
            result.Add(playerPick);
            fromEnemy.Add(false);
        }

        // ② 补位：先敌后玩（与原实现一致）
        while (result.Count < CandidateCount)
        {
            CardData moreEnemy = SquadDropConfig.DrawEnemyCard(item.runtimeDropConfig, shown);
            if (moreEnemy != null)
            {
                shown.Add(moreEnemy);
                result.Add(moreEnemy);
                fromEnemy.Add(true);
                continue;
            }

            CardData morePlayer = NextPlayerCard(playerPool, ref playerCursor, shown);
            if (morePlayer == null) break;

            shown.Add(morePlayer);
            result.Add(morePlayer);
            fromEnemy.Add(false);
        }
    }

    /// <summary>取玩家池里下一张未展示的卡（游标只前进；null = 取完）。</summary>
    static CardData NextPlayerCard(List<CardData> pool, ref int cursor, HashSet<CardData> shown)
    {
        while (cursor < pool.Count)
        {
            CardData card = pool[cursor];
            cursor++;
            if (card != null && !shown.Contains(card)) return card;
        }
        return null;
    }

    static void Shuffle(List<CardData> list)
    {
        for (int i = 0; i < list.Count - 1; i++)
        {
            int j = Random.Range(i, list.Count);        // 含 i：允许「原地不动」才是均匀洗牌
            CardData tmp = list[i];
            list[i] = list[j];
            list[j] = tmp;
        }
    }
}

using UnityEngine;
using UnityEngine.UI;
using TMPro;
using System;
using System.Collections.Generic;

#if UNITY_EDITOR
using UnityEditor;
#endif

/// <summary>
/// 卡组管理器 - 管理初始牌组配置与运行时实例化
/// 单例：开局时按 Inspector 配置的牌组组成加载卡牌，供 CardPileManager 初始化抽牌堆。
///
/// 使用方式：
///   1. 在 Unity Inspector 的 CardDeckManager 组件上，直接配置 Initial Deck Entries 数组
///      每个元素包含一张 CardData SO + 数量
///   2. 无需写代码就能在 Inspector 里调整初始牌组（增删卡牌、修改数量）
///   3. 运行时 GetDeckCopy() 返回 List<Card>（运行时实例），CardPileManager 直接使用
/// </summary>
public class CardDeckManager : MonoBehaviour
{
    // -------- 单例 --------
    public static CardDeckManager Instance { get; private set; }

    [Header("UI References（可选，编辑器模式用）")]
    [SerializeField] private Transform cardLibraryContent;
    [SerializeField] private Transform cardDeckContent;
    [SerializeField] private TMP_Text strengthText;
    [SerializeField] private TMP_Text agilityText;
    [SerializeField] private TMP_Text intelligenceText;
    [SerializeField] private TMP_Text constitutionText;
    [SerializeField] private TMP_Text cardCountText;
    [SerializeField] private GameObject cardUIPrefab;

    /// <summary>
    /// Inspector 可配置的初始牌组条目。
    /// 在 Inspector 里直接添加/删除 CardData + 设置 count，即可完成牌组构建。
    /// 例如：[防御, 4] + [直刺, 2] + [纵劈, 2] + [横斩, 1] + [断筋, 1]
    /// </summary>
    [Serializable]
    public class DeckEntry
    {
        [Tooltip("卡牌模板（SO 资源）")]
        public CardData cardData;

        [Tooltip("该卡牌在牌组中的数量")]
        [Range(1, 20)]
        public int count = 1;
    }

    [Header("初始牌组配置（Inspector 里直接编辑）")]
    [Tooltip("在这里配置初始牌组。运行时会为每个条目创建 count 份 Card 运行时实例。")]
    [SerializeField] private List<DeckEntry> initialDeckEntries = new List<DeckEntry>();

    /// <summary>
    /// ★2026-09-10 开局默认装入战术卡槽的卡（用户定稿：嗅盐）。
    /// 语义：这里的 CardData 必须**同时**出现在 initialDeckEntries 里（要先在牌库中，
    /// 才能按实例装入槽）。装入后因槽内卡不进抽牌堆（spec §5），它不会污染抽牌堆。
    /// 玩家在卡包页手动卸下后不会被自动装回——只在 BuildRuntimeDeck（开局）时执行一次。
    /// </summary>
    [Header("默认战术卡（开局自动装入战术卡槽）")]
    [Tooltip("开局自动装进战术卡槽的卡。必须已包含在初始牌组里。默认：嗅盐。")]
    [SerializeField] private List<CardData> defaultTacticCards = new List<CardData>();

    /// <summary>
    /// 运行时牌组缓存（由 initialDeckEntries 实例化而来，类型为 List<Card>）
    /// </summary>
    private List<Card> runtimeDeck = new List<Card>();

    /// <summary>
    /// ★当局唯一牌库（spec §4：一局远征只有一套牌库，探索/战斗共用）。
    /// 元素是稳定 Card 实例：战术槽按实例持有并记 CD，牌堆按实例过滤。
    /// 卡包界面（DeckUI）/ 装填界面（LoadoutUI）直接读这个列表——
    /// 不要调 GetDeckCopy()，那会返回一批新实例，与战术槽里的对不上号。
    /// </summary>
    public IReadOnlyList<Card> Library => runtimeDeck;

    /// <summary>牌库增删（战利品收卡 / 三选一入牌堆）后触发，DeckUI 订阅刷新。</summary>
    public event Action LibraryChanged;

    /// <summary>
    /// 获取牌组的运行时实例副本（M5a: CardPileManager 初始化抽牌堆时调用）。
    /// 每次调用都创建新的 Card 实例，确保同模板卡牌互不影响。
    /// ★本方法返回的是**新实例副本**，仅供需要「干净一份」的场合（如编辑器预览）。
    /// 牌堆初始化请改用 GetPlayableDeck()——战术槽按实例过滤，副本对不上号。
    /// </summary>
    public List<Card> GetDeckCopy()
    {
        // 如果还没初始化，先从 Inspector 配置构建
        if (runtimeDeck.Count == 0)
        {
            BuildRuntimeDeck();
        }

        // 返回深拷贝（每个条目重新实例化 Card）
        var copy = new List<Card>();
        foreach (var card in runtimeDeck)
        {
            copy.Add(new Card(card.Data));
        }
        return copy;
    }

    /// <summary>
    /// ★当局牌组（spec §4：牌组自动 = 牌库全部卡牌，除战术卡槽内卡牌）。
    /// 返回 Library 里的**同一批实例**（不拷贝），并对每张调 ResetForReshuffle()：
    /// 实例跨战斗复用，上一场残留的降费 / CD / 骰点必须先清干净。
    /// 调用方：CardPileManager.InitDrawPileFromDeck（TurnManager ×2、ExplorationTurnManager ×1）。
    /// </summary>
    public List<Card> GetPlayableDeck()
    {
        if (runtimeDeck.Count == 0)
        {
            BuildRuntimeDeck();
        }

        var deck = new List<Card>(runtimeDeck.Count);
        foreach (Card card in runtimeDeck)
        {
            if (card == null) continue;
            if (TacticSlotRuntime.Contains(card)) continue;   // 槽内卡不进抽牌堆（spec §5）

            card.ResetForReshuffle();
            deck.Add(card);
        }

        Debug.Log($"[CardDeckManager] 牌组构建：牌库 {runtimeDeck.Count} 张 − 战术槽 " +
                  $"{TacticSlotRuntime.OccupiedCount} 张 = {deck.Count} 张进抽牌堆");
        return deck;
    }

    /// <summary>
    /// ★当局内获得卡牌（spec §4 / §8 / §9：战利品收下、三选一选中 → 一次性加入本局牌堆）。
    /// 与编辑器专用的 AddCardToDeck 的区别：本方法运行时可用，且**不写 initialDeckEntries**
    /// ——当局获得的卡只属于这一局，重载场景即消失（roguelike 语义，符合 spec §9「加入本局牌堆」）。
    /// ★2026-09-12 用户定稿：同时立刻进**当前抽牌堆**（抽牌堆 UI 计数即时刷新）——
    ///   只写 runtimeDeck 的话数字要等下一回合 / 下一场战斗重建牌堆才动。
    /// </summary>
    public void AddCardAtRuntime(CardData cardData)
    {
        if (cardData == null) return;

        Card card = new Card(cardData);
        runtimeDeck.Add(card);
        Debug.Log($"[CardDeckManager] 当局牌库新增：{cardData.cardName}（牌库共 {runtimeDeck.Count} 张）");
        LibraryChanged?.Invoke();

        // ★2026-09-13 用户需求：非教程图拿到新卡立即自动装填 + 右下角提示。
        //   教程图不装——装填本身是 S29-S33 的教学内容，教学期玩家的卡要保持「未装填」。
        if (!MapLayoutBuilder.IsTutorial)
        {
            DiceData autoDice = CardLoadout.AutoAssignOne(card);
            if (autoDice != null)
                LoadoutToastUI.Show($"「{cardData.cardName}」已自动装填 {autoDice.diceName}");
        }

        if (CardPileManager.Instance != null) CardPileManager.Instance.AddCardToDrawPile(card);
    }

    /// <summary>
    /// ★当局内移除卡牌（design 荒野事件 §3.4 删牌）。
    /// 清理链顺序要紧：牌堆（抽/弃/手）→ 战术卡槽 → 装填记录 → 鉴定暂存 → 牌库本体 → 广播。
    /// 选牌界面已把「战术槽内卡 / 已装填卡」排除在候选外，这里仍做兜底清理。
    /// ★不退还骰子：装填是纯配置，骰子在抽牌那一刻才消耗（背包设计 §装填=纯配置）。
    /// </summary>
    public bool RemoveCardAtRuntime(Card card)
    {
        if (card == null) return false;
        if (!runtimeDeck.Remove(card)) return false;

        if (CardPileManager.Instance != null) CardPileManager.Instance.DetachCardFromPiles(card);

        int slot = TacticSlotRuntime.IndexOf(card);
        if (slot >= 0) TacticSlotRuntime.RemoveCardAt(slot);

        CardLoadout.ClearOverride(card);
        CharacterStats.PendingCards.Remove(card);

        string name = card.Data != null ? card.Data.cardName : "?";
        Debug.Log($"[CardDeckManager] 当局牌库移除：{name}（牌库共 {runtimeDeck.Count} 张）");
        LibraryChanged?.Invoke();
        return true;
    }

    // ------------------------------------------------------------------
    // ★2026-09-12 教学牌库接管（TutorialDirector 专用）
    // ------------------------------------------------------------------

    private List<Card> _tutorialSavedDeck;

    /// <summary>
    /// 教学用：把当局牌库临时换成「仅一张 cardName」（找不到该卡则清空并告警）。
    /// 原牌库被保存，用 TutorialRestoreDeck 恢复（伏击进战斗前调用）。
    /// </summary>
    public void TutorialSetDeckToSingleCard(string cardName)
    {
        if (runtimeDeck.Count == 0) BuildRuntimeDeck();
        if (_tutorialSavedDeck == null || _tutorialSavedDeck.Count == 0)
            _tutorialSavedDeck = new List<Card>(runtimeDeck);

        runtimeDeck.RemoveAll(c => c == null || c.Data == null || c.Data.cardName != cardName);
        while (runtimeDeck.Count > 1) runtimeDeck.RemoveAt(runtimeDeck.Count - 1);
        if (runtimeDeck.Count == 0)
            Debug.LogWarning($"[CardDeckManager] 教学：牌库里找不到「{cardName}」，教学手牌将为空");
        else
            Debug.Log($"[CardDeckManager] 教学：牌库临时替换为仅 1 张「{cardName}」（原 { _tutorialSavedDeck.Count} 张已保存）");
    }

    /// <summary>教学用：恢复被 TutorialSetDeckToSingleCard 保存的完整牌库。</summary>
    public void TutorialRestoreDeck()
    {
        if (_tutorialSavedDeck == null) return;
        runtimeDeck = new List<Card>(_tutorialSavedDeck);
        _tutorialSavedDeck = null;
        Debug.Log($"[CardDeckManager] 教学：牌库已恢复（{runtimeDeck.Count} 张）");
    }

    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;

        BuildRuntimeDeck();
    }

    /// <summary>
    /// 公开方法：刷新运行时牌组（编辑器工具在 Play 模式下调用）。
    /// 重新从 Inspector 配置构建 runtimeDeck，供下一次 GetDeckCopy() 使用。
    /// </summary>
    public void RefreshRuntimeDeck()
    {
        BuildRuntimeDeck();
    }

    /// <summary>
    /// 从配置构建运行时牌组。
    /// 每个条目生成 count 份 Card 运行时实例。
    /// ★2026-09-17 B4：固定初始卡组收口到 Resources/DefaultDeckCatalog（单一数据源）——
    ///   藏身处整装面板展示与开局构建读同一份；目录缺失退回 Inspector 配置（老链路）。
    /// </summary>
    private void BuildRuntimeDeck()
    {
        runtimeDeck.Clear();

        int total = 0;
        int skippedTactics = 0;

        // 单个条目入牌库（教程图跳过默认战术卡——战术卡槽未解锁，同 2026-09-12 规则）
        System.Action<CardData, int> add = (data, count) =>
        {
            if (data == null || count <= 0) return;
            if (MapLayoutBuilder.IsTutorial && IsDefaultTacticCard(data))
            {
                skippedTactics += count;
                Debug.Log($"[CardDeckManager] 教程图：{data.cardName} ×{count} 不进牌库（战术卡槽未解锁）");
                return;
            }
            for (int i = 0; i < count; i++) runtimeDeck.Add(new Card(data));
            total += count;
        };

        DefaultDeckCatalog catalog = DefaultDeckCatalog.Load();
        if (catalog != null && catalog.entries != null && catalog.entries.Count > 0)
        {
            foreach (DefaultDeckCatalog.Entry e in catalog.entries)
                if (e != null) add(e.card, e.count);
        }
        else if (initialDeckEntries != null && initialDeckEntries.Count > 0)
        {
            Debug.LogWarning("[CardDeckManager] 默认卡组目录缺失 → 退回 Inspector 配置（跑菜单 Tools/藏身处/3. 默认卡组目录）");
            foreach (DeckEntry entry in initialDeckEntries)
            {
                if (entry == null || entry.cardData == null)
                {
                    Debug.LogWarning("[CardDeckManager] 存在空的 DeckEntry 或 cardData 未配置，跳过");
                    continue;
                }
                add(entry.cardData, entry.count);
            }
        }
        else
        {
            Debug.LogWarning("[CardDeckManager] 初始牌组为空（目录与 Inspector 均无）！");
            return;
        }

        // ★2026-09-17 B4 T7：整装带出的自由卡合并进牌库（固定初始卡组之后）。
        // 卡牌消耗制：带出卡已在藏身处出击时扣过 MetaWallet 库存（TryCommitDeploy），
        // 此处只实例化。快照会在 InventoryManager.Start 的整装发放完成后 ClearLoadout
        // ——本方法（Awake）恒先于所有 Start 执行，读到的还是未清的快照。
        MetaWallet.LoadoutSnapshot loadout = MetaWallet.PeekLoadout();
        if (loadout != null && loadout.cards != null && loadout.cards.Count > 0)
        {
            WildernessCraftCatalog craftCat = WildernessCraftCatalog.Load();
            foreach (string cardID in loadout.cards)
            {
                CardData cd = craftCat != null ? craftCat.CardFor(cardID) : null;
                if (cd == null)
                {
                    Debug.LogWarning($"[CardDeckManager] 整装带出的卡查不到资产（{cardID}），跳过");
                    continue;
                }
                add(cd, 1);
                Debug.Log($"[CardDeckManager] 整装带出：{cd.cardName} 进牌库");
            }
        }

        Debug.Log($"[CardDeckManager] 初始牌组构建完成：共 {total} 张" +
                  (skippedTactics > 0 ? $"（教程图另跳过默认战术卡 {skippedTactics} 张）" : ""));

        // ★2026-09-10：开局默认战术卡装载（嗅盐）。必须在 runtimeDeck 建好之后——
        // 槽里装的是牌库的 Card 实例，不是 CardData。
        ApplyDefaultTacticLoadout();

        // ★2026-09-13 用户需求：非教程图开局自动装填（教程图不装，S29-S33 让玩家自己装一遍）。
        //   Awake 时背包/骰子管理器多半还没就绪 → 交给延迟协程等就绪后再装。
        if (Application.isPlaying && !MapLayoutBuilder.IsTutorial)
            StartCoroutine(DeferredAutoLoadout());

        // 更新编辑器 UI
#if UNITY_EDITOR
        UpdateAttributesDisplay();
        UpdateDeckDisplay();
#endif
    }

    /// <summary>★2026-09-13 非教程开局自动装填：等 InventoryManager 就绪后，把牌库里
    /// 还没手动装填的卡各槽装上背包里最好的战斗骰，右下角弹一条提示。装不上（没骰子）就静默跳过。</summary>
    private System.Collections.IEnumerator DeferredAutoLoadout()
    {
        // 最多等 3 秒（约 180 帧）：背包系统晚于本组件 Awake 是常态
        for (int i = 0; i < 180; i++)
        {
            yield return null;
            var items = InventoryManager.Instance != null ? InventoryManager.Instance.AllDiceItems : null;
            if (items != null && items.Count > 0) break;
        }
        if (MapLayoutBuilder.IsTutorial) yield break;   // 保险：等待期间切进教程图就不装

        int n = CardLoadout.AutoAssign(runtimeDeck);
        if (n > 0)
        {
            DiceData best = CardLoadout.FindBestOwnedBattleDice();
            LoadoutToastUI.Show($"开局自动装填：{n} 张卡 → {(best != null ? best.diceName : "—")}");
        }
    }

    /// <summary>
    /// 按 <see cref="defaultTacticCards"/> 应用默认战术卡装载（开局自动 / 编辑器工具重放用）。
    /// 幂等：已在槽内则跳过；玩家手动卸下后不会被自动装回（只在 BuildRuntimeDeck 时调用）。
    /// </summary>
    public void ApplyDefaultTacticLoadout()
    {
        TacticSlotRuntime.ApplyDefaultLoadout(runtimeDeck, defaultTacticCards);
    }

    /// <summary>
    /// 该卡是否属于「默认战术卡」配置。
    /// ★2026-09-12 教程图用它把嗅盐挡在牌库之外（战术卡槽未解锁时不发这张牌）。
    /// </summary>
    private bool IsDefaultTacticCard(CardData data)
    {
        if (data == null || defaultTacticCards == null) return false;
        for (int i = 0; i < defaultTacticCards.Count; i++)
        {
            if (defaultTacticCards[i] == data) return true;
        }
        return false;
    }

#if UNITY_EDITOR
    // -------- 以下方法仅在编辑器环境下运行（UI 显示/牌组编辑） --------

    public void AddCardToDeck(CardData cardData)
    {
        if (cardData == null) return;

        // 查找是否已有同卡条目
        var existing = initialDeckEntries.Find(e => e.cardData == cardData);
        if (existing != null)
        {
            existing.count++;
        }
        else
        {
            initialDeckEntries.Add(new DeckEntry { cardData = cardData, count = 1 });
        }

        // 重新构建
        runtimeDeck.Clear();
        BuildRuntimeDeck();
    }

    public void RemoveCardFromDeck(CardData cardData)
    {
        if (cardData == null) return;

        var existing = initialDeckEntries.Find(e => e.cardData == cardData);
        if (existing != null)
        {
            existing.count--;
            if (existing.count <= 0)
            {
                initialDeckEntries.Remove(existing);
            }
        }

        runtimeDeck.Clear();
        BuildRuntimeDeck();
    }

    private (int strength, int agility, int intelligence, int constitution) CalculateAttributes()
    {
        int strength = 0, agility = 0, intelligence = 0, constitution = 0;

        foreach (var entry in initialDeckEntries)
        {
            if (entry == null || entry.cardData == null) continue;
            var c = entry.cardData;
            int cnt = entry.count;

            if (c.suit1 == SuitOption.红色) strength += cnt;
            if (c.suit2 == SuitOption.红色) strength += cnt;
            if (c.suit3 == SuitOption.红色) strength += cnt;
            if (c.suit4 == SuitOption.红色) strength += cnt;

            if (c.suit1 == SuitOption.绿色) agility += cnt;
            if (c.suit2 == SuitOption.绿色) agility += cnt;
            if (c.suit3 == SuitOption.绿色) agility += cnt;
            if (c.suit4 == SuitOption.绿色) agility += cnt;

            if (c.suit1 == SuitOption.蓝色) intelligence += cnt;
            if (c.suit2 == SuitOption.蓝色) intelligence += cnt;
            if (c.suit3 == SuitOption.蓝色) intelligence += cnt;
            if (c.suit4 == SuitOption.蓝色) intelligence += cnt;

            if (c.suit1 == SuitOption.黄色) constitution += cnt;
            if (c.suit2 == SuitOption.黄色) constitution += cnt;
            if (c.suit3 == SuitOption.黄色) constitution += cnt;
            if (c.suit4 == SuitOption.黄色) constitution += cnt;
        }

        return (strength, agility, intelligence, constitution);
    }

    private void UpdateAttributesDisplay()
    {
        var a = CalculateAttributes();
        if (strengthText != null) strengthText.text = "力量: " + a.strength;
        if (agilityText != null) agilityText.text = "敏捷: " + a.agility;
        if (intelligenceText != null) intelligenceText.text = "智力: " + a.intelligence;
        if (constitutionText != null) constitutionText.text = "体质: " + a.constitution;
        if (cardCountText != null) cardCountText.text = "卡牌数量: " + runtimeDeck.Count;
    }

    private void UpdateDeckDisplay()
    {
        if (cardDeckContent == null || cardUIPrefab == null) return;

        foreach (Transform child in cardDeckContent)
        {
            Destroy(child.gameObject);
        }

        foreach (var entry in initialDeckEntries)
        {
            if (entry?.cardData == null) continue;
            GameObject cardUI = Instantiate(cardUIPrefab, cardDeckContent);
        }
    }
#endif
}

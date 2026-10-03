// =============================================================================
// 模块：M5a + Card 层 - 牌堆管理器 CardPileManager
// 用途：管理抽牌堆 / 弃牌堆 / 手牌三个 List<Card>，提供抽/弃/洗牌 API
// 设计依据：docs/superpowers/specs/2026-08-08-m5a-card-runtime-ui-design.md §2.1
//           + NSWells P3 Card 三层分离（Card 运行时实例层）
// 职责边界：纯数据逻辑，不直接操作 UI（UI 通过订阅事件响应）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 牌堆管理单例。
/// 管理 DrawPile / DiscardPile / Hand 三个 List<Card>（运行时实例）。
/// 每个 Card 实例持有唯一 InstanceId 和独立的可变状态（费用、CD 等）。
/// </summary>
public class CardPileManager : MonoBehaviour
{
    // -------- 单例 --------
    public static CardPileManager Instance { get; private set; }

    [Header("运行时数据（Inspector 调试查看）")]
    [Tooltip("抽牌堆：末尾 = 下一张抽的卡")]
    public List<Card> DrawPile = new List<Card>();

    [Tooltip("弃牌堆")]
    public List<Card> DiscardPile = new List<Card>();

    [Tooltip("当前手牌")]
    public List<Card> Hand = new List<Card>();

    [Tooltip("手牌上限")]
    public int HandLimit = 10;

    // -------- 事件（UI 订阅用，解耦逻辑与视图）--------
    /// <summary>每抽一张牌时触发。HandUIController 订阅 → 实例化 1 个 CardView。</summary>
    public event Action<Card> OnCardDrawn;

    /// <summary>每弃一张牌时触发。HandUIController 订阅 → 移除对应 CardView。</summary>
    public event Action<Card> OnCardDiscarded;

    /// <summary>整手弃完时触发（EndTurn 后）。</summary>
    public event Action OnHandCleared;

    /// <summary>任何 List 变化时触发。BattleHUDController 订阅 → 刷新抽/弃计数。</summary>
    public event Action OnPileRefreshed;

    // ------------------------------------------------------------------
    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    // ------------------------------------------------------------------
    // API
    // ------------------------------------------------------------------

    /// <summary>
    /// 用玩家牌组初始化抽牌堆并洗牌。
    /// 调用方：TurnManager 切换到 Battle 时。
    /// </summary>
    /// <param name="playerDeck">玩家牌组的运行时实例列表（由 CardDeckManager.GetDeckCopy() 返回）</param>
    public void InitDrawPileFromDeck(List<Card> playerDeck)
    {
        // ★装填兜底：旧「抽牌付款」账本的清账入口。付款时机移到打出后账本恒空，
        // 此调用为空操作，保留仅作兜底兼容（2026-09-09）。
        DicePayment.RefundAll();

        DrawPile.Clear();
        DiscardPile.Clear();
        Hand.Clear();

        if (playerDeck == null || playerDeck.Count == 0)
        {
            Debug.LogWarning("[CardPileManager] 初始化抽牌堆时牌组为空！");
            return;
        }

        DrawPile.AddRange(playerDeck);
        Shuffle(DrawPile);

        Debug.Log($"[CardPileManager] 抽牌堆初始化完成，共 {DrawPile.Count} 张牌");
        OnPileRefreshed?.Invoke();
    }

    /// <summary>
    /// ★2026-09-12 用户定稿：把一张**新获得的卡**直接放进当前抽牌堆，并立刻广播刷新
    /// （抽牌堆计数即时变化）。
    ///
    /// 为什么要这个方法：新卡原来只进 CardDeckManager.runtimeDeck，牌堆要等下一次
    /// InitDrawPileFromDeck（下一回合 / 下一场战斗）才重建 —— 玩家看到的是「卡到手了，
    /// 抽牌堆数字没动」。三个入口（三选一 / 遗物袋卡 / 事件奖励）都走
    /// CardDeckManager.AddCardAtRuntime → 这里，所以只需在那一处接线。
    ///
    /// 位置：插到 **堆底**（index 0）。DrawPile 末尾才是下一张抽的卡，插末尾等于白送
    /// 「刚拿的牌马上上手」的节奏；下一回合整堆会从 runtimeDeck 重洗，届时它自然混入。
    /// 实例口径：传进来的就是 runtimeDeck 里那一个（与其它卡一致：库里的实例进牌堆），
    /// 重建时整堆先 Clear 再重填，不会出现同一张两份并存。
    /// </summary>
    public void AddCardToDrawPile(Card card)
    {
        if (card == null) return;

        DrawPile.Insert(0, card);
        Debug.Log($"[CardPileManager] 抽牌堆加入新卡：{card.Data?.cardName} #{card.InstanceId}" +
                  $"（抽牌堆共 {DrawPile.Count} 张）");
        OnPileRefreshed?.Invoke();
    }

    /// <summary>
    /// 抽 count 张牌到手牌。自动处理空抽牌堆回洗。
    /// </summary>
    /// <param name="count">要抽的张数</param>
    /// <returns>本次实际抽到的卡牌列表</returns>
    public List<Card> DrawCards(int count = 5)
    {
        List<Card> drawn = new List<Card>();

        for (int i = 0; i < count; i++)
        {
            if (Hand.Count >= HandLimit)
            {
                Debug.Log($"[CardPileManager] 手牌已满（{HandLimit}），停止抽牌");
                break;
            }

            if (DrawPile.Count == 0)
            {
                if (DiscardPile.Count == 0)
                {
                    Debug.Log("[CardPileManager] 抽牌堆和弃牌堆都空了，无法继续抽牌");
                    break;
                }

                // ★生命周期规则（用户 2026-08-17）：弃牌堆洗回抽牌堆时重置卡牌——
                // 费用/CD 回模板值，骰子点数清回未投（下次抽到重新掷）。
                // 弃牌堆内的卡在此之前保留手牌期间的点数（如"回收弃牌"效果取回时数值不变）。
                foreach (Card recycled in DiscardPile)
                {
                    recycled.ResetForReshuffle();
                }

                DrawPile.AddRange(DiscardPile);
                DiscardPile.Clear();
                Shuffle(DrawPile);
                Debug.Log("[CardPileManager] 弃牌堆已洗回抽牌堆（卡牌数据已重置，骰子回到未投状态）");
            }

            Card card = DrawPile[DrawPile.Count - 1];
            DrawPile.RemoveAt(DrawPile.Count - 1);
            Hand.Add(card);

            // 总策划案 6.2.2：抽出卡牌后自动投出其绑定的战斗骰子。
            // ★2026-09-09 弹药可视化：抽牌不掷骰也不扣费，循环结束后统一 ReallocateHandDice
            //   按真实骰池分配槽位骰子（真实骰优先、不足用临时骰）并掷点数。

            OnCardDrawn?.Invoke(card);
            drawn.Add(card);
        }

        // ★2026-09-09 弹药可视化：抽完统一分配所有手牌的槽位骰子并掷点数
        DicePayment.ReallocateHandDice();

        OnPileRefreshed?.Invoke();
        return drawn;
    }

    /// <summary>
    /// 把一张手牌移入弃牌堆。
    /// </summary>
    public void DiscardHandCard(Card card)
    {
        if (card == null || !Hand.Contains(card)) return;

        Hand.Remove(card);
        DiscardPile.Add(card);

        RaiseCardDiscarded(card);
        OnPileRefreshed?.Invoke();

        // ★2026-09-09 弹药可视化：弃牌释放该卡占用的真实骰份额（打牌扣费后池已减），
        // 重新分配剩余手牌的槽位骰子，让显示随弹药实时退化/恢复。
        DicePayment.ReallocateHandDice();
    }

    /// <summary>
    /// 把一张指定卡牌从任意堆移回弃牌堆（用于卡牌被效果销毁等场景）。
    /// </summary>
    public void DiscardCard(Card card)
    {
        if (card == null) return;

        if (Hand.Contains(card))
        {
            Hand.Remove(card);
        }
        else if (DrawPile.Contains(card))
        {
            DrawPile.Remove(card);
        }
        else
        {
            return;
        }

        DiscardPile.Add(card);
        RaiseCardDiscarded(card);
        OnPileRefreshed?.Invoke();
    }

    /// <summary>
    /// ★2026-09-10：把一张**不属于任何牌堆**的卡直接放进弃牌堆。
    ///
    /// 与 <see cref="DiscardCard"/> 的区别：`DiscardCard` 要求卡必须先在 Hand / DrawPile 里，
    /// 找不到就 `else { return; }` **静默返回**。而战术槽卡飞出面板时已经从槽卸下、
    /// 不在任何堆里 —— 用 DiscardCard 会「看起来弃了，其实没弃」（卡凭空消失）。
    ///
    /// 调用方：EventPopupUI.CommitPanelCardsToDiscardPile（槽内卡的弃牌鉴定确认分支）。
    /// </summary>
    public void DiscardFromTacticSlot(Card card)
    {
        if (card == null) return;
        if (DiscardPile.Contains(card)) return;              // 已在弃牌堆 → 忽略（防重复）

        Hand.Remove(card);
        DrawPile.Remove(card);
        DiscardPile.Add(card);

        RaiseCardDiscarded(card);
        OnPileRefreshed?.Invoke();
        Debug.Log($"[CardPileManager] {card.Data?.cardName} #{card.InstanceId}（战术槽）已进弃牌堆");
    }

    /// <summary>
    /// ★2026-09-10 卡牌唯一性（用户定稿）：把一张卡从**所有牌堆**里摘掉，且**不进弃牌堆**。
    ///
    /// 用途：把一张牌装进战术卡槽时调用。
    /// 不摘会怎样：牌库（Library）持有全部 Card 实例，手牌里装的是同一批实例的引用 ——
    ///   玩家把一张**手牌**拖进战术槽后，手牌那份引用还在 → 屏幕上同时出现两张一样的卡
    ///   （其实是同一个实例的两个视图），而且这张卡下一回合还会被再抽一次。
    ///
    /// 全局口径（用户定稿）：**抽牌堆 / 弃牌堆 / 手牌 / 战术槽 —— 同一个 Card 实例只能存在于一个区。**
    /// 战术槽的"取出"不走这里（槽内卡本来就不在任何堆里，卸下即回牌库）。
    /// </summary>
    /// <returns>true = 确实从某个堆里摘掉了（调用方可据此决定要不要刷新 UI）</returns>
    public bool DetachCardFromPiles(Card card)
    {
        if (card == null) return false;

        bool removed = false;

        if (DrawPile.Remove(card)) removed = true;
        if (DiscardPile.Remove(card)) removed = true;

        if (Hand.Remove(card))
        {
            removed = true;
            // ★必须广播：HandUIController 靠 OnCardDiscarded 触发 DelayedRefreshHandLayout，
            //   不广播的话手牌区会留着一个指向已移走实例的幽灵卡面。
            //   RefundOnDiscard 在新付款时机（打出才付款）下是空操作，无害。
            RaiseCardDiscarded(card);
        }

        if (!removed) return false;

        OnPileRefreshed?.Invoke();
        // 手牌少一张 → 弹药水位模型重算（真实骰份额让给剩下的手牌）
        DicePayment.ReallocateHandDice();
        Debug.Log($"[CardPileManager] {card.Data?.cardName} #{card.InstanceId} 已从牌堆摘除（转入战术卡槽，不进弃牌堆）");
        return true;
    }

    /// <summary>
    /// 弃掉所有手牌（回合结束时调用）。
    /// </summary>
    public void DiscardAllHand()
    {
        for (int i = Hand.Count - 1; i >= 0; i--)
        {
            Card card = Hand[i];
            Hand.RemoveAt(i);
            DiscardPile.Add(card);
            RaiseCardDiscarded(card);
        }

        OnHandCleared?.Invoke();
        OnPileRefreshed?.Invoke();
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /// <summary>
    /// 弃牌统一出口：广播弃牌事件（★2026-09-09 付款时机移到打出后，抽牌未扣费，
    /// 此处 RefundOnDiscard 恒为空操作，保留调用仅作兜底兼容）。
    /// </summary>
    private void RaiseCardDiscarded(Card card)
    {
        DicePayment.RefundOnDiscard(card);
        OnCardDiscarded?.Invoke(card);
    }

    private void Shuffle(List<Card> pile)
    {
        for (int i = pile.Count - 1; i > 0; i--)
        {
            int j = UnityEngine.Random.Range(0, i + 1);
            (pile[i], pile[j]) = (pile[j], pile[i]);
        }
    }
}

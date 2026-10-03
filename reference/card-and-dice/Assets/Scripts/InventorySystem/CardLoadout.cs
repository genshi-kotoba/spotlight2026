// =============================================================================
// 模块：M7 背包系统 - CardLoadout 装填配置（纯静态）
// 用途：记录**每张卡实例**各骰子槽绑定的骰子 + 有效装填解析 + 一键自动装填
// 设计依据：spec §6（装填 = 纯配置，设置不消耗骰子；默认装填 = CardData.diceSlot）
//
// ★2026-09-13 v2（用户需求）：覆盖表由「按 CardData 模板」改为「按 Card 实例」。
//   同名卡在牌库里本就是各自独立的 Card 实例（CardDeckManager.BuildRuntimeDeck 对每个
//   DeckEntry 实例化 count 份）→ 现在既能「给 3 张纵劈分别装不同的骰子」，
//   也能「一键给整类同名卡装同一种」（大类操作由 LoadoutUI 遍历牌库完成，本类只管单卡）。
//
// ★三种状态，别搞混（本类唯一需要小心的地方）：
//   ① 无记录   → GetEffective 回落 CardData.diceSlot 模板默认（老玩家 / 教程前期战斗）
//   ② 未装填   → 显式标记 MarkUnloaded：每槽解析为 null，DicePayment 不为该槽付款、
//                卡面停在 [战斗骰子] 占位 —— 教程 S29 用它把玩家的卡清成「待装填」
//   ③ 已装填   → SetSlot 写入具体骰子；没写过的槽仍回落模板默认（①的语义不变）
//
// ★装填不搬动实体骰子：骰子始终留在背包骰子分区，抽到该卡时才由 DicePayment 扣除。
// ★槽数不可增减：Card.DiceValues 长度在构造时按 CardData.GetBoundDice().Count 定死
//   （Card.cs:68-69），效果按骰子序号解算（Card.ResolveValue），故覆盖表只换骰型。
// ★战斗外修改只影响之后抽到的牌：已抽手牌的骰子在抽到时已付款并掷定（DicePayment）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class CardLoadout
{
    /// <summary>单张卡的装填记录。</summary>
    private class Entry
    {
        /// <summary>每槽指定的骰子（null = 该槽未指定 → 回落模板默认）。长度 = 槽数。</summary>
        public DiceData[] slots;

        /// <summary>是否被显式标记为「未装填」：每槽都解析为 null，且**不**回落模板默认。</summary>
        public bool unloaded;
    }

    /// <summary>覆盖表：Card 实例 → 装填记录。</summary>
    static readonly Dictionary<Card, Entry> _table = new Dictionary<Card, Entry>();

    // ------------------------------------------------------------------
    // 槽数 / 状态查询
    // ------------------------------------------------------------------
    /// <summary>该卡模板的骰子槽数（= 默认装填的非空槽数，0–4）。</summary>
    public static int SlotCount(CardData card)
    {
        return card != null ? card.GetBoundDice().Count : 0;
    }

    /// <summary>该卡实例的骰子槽数（仍由模板决定）。</summary>
    public static int SlotCount(Card card)
    {
        return card != null ? SlotCount(card.Data) : 0;
    }

    /// <summary>该实例是否有装填记录（含「标记为未装填」的空记录）。</summary>
    public static bool HasOverride(Card card)
    {
        return card != null && _table.ContainsKey(card);
    }

    /// <summary>该实例该槽是否装了具体骰子。</summary>
    public static bool IsSlotOverridden(Card card, int index)
    {
        if (card == null || !_table.TryGetValue(card, out Entry e) || e == null || e.unloaded) return false;
        return e.slots != null && index >= 0 && index < e.slots.Length && e.slots[index] != null;
    }

    /// <summary>该实例是否处于「未装填」状态（被显式清空、等玩家装）。
    /// 与「无记录」区分：无记录 = 用模板默认骰（教程前期战斗靠它），未装填 = 真的没有骰子。</summary>
    public static bool IsUnloaded(Card card)
    {
        return card != null && _table.TryGetValue(card, out Entry e) && e != null && e.unloaded;
    }

    /// <summary>该实例是否有**任何**手动指定的骰槽（全空 = 视为还没手动装填过）。</summary>
    public static bool HasManualDice(Card card)
    {
        int n = SlotCount(card);
        for (int i = 0; i < n; i++)
        {
            if (IsSlotOverridden(card, i)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 写入
    // ------------------------------------------------------------------
    private static Entry EnsureEntry(Card card, int slots)
    {
        if (!_table.TryGetValue(card, out Entry e) || e == null)
        {
            e = new Entry();
            _table[card] = e;
        }
        if (e.slots == null || e.slots.Length != slots)
        {
            var arr = new DiceData[slots];
            // 保留旧值（槽数变化时按位拷贝，越界丢弃）
            if (e.slots != null)
            {
                for (int i = 0; i < slots && i < e.slots.Length; i++) arr[i] = e.slots[i];
            }
            e.slots = arr;
        }
        return e;
    }

    /// <summary>
    /// 设置某槽绑定的骰子（纯配置，不扣骰）。
    /// </summary>
    /// <param name="index">槽序号，0 起，必须 &lt; SlotCount(card)</param>
    /// <param name="dice">null = 该槽恢复默认骰子</param>
    /// <returns>true = 已写入</returns>
    public static bool SetSlot(Card card, int index, DiceData dice)
    {
        if (card == null) return false;

        int slots = SlotCount(card);
        if (slots == 0)
        {
            Debug.Log($"[CardLoadout] {NameOf(card)} 是 0 骰子槽卡，无需装填");
            return false;
        }
        if (index < 0 || index >= slots)
        {
            Debug.LogWarning($"[CardLoadout] {NameOf(card)} 槽位 {index} 越界（该卡只有 {slots} 槽）");
            return false;
        }

        Entry e = EnsureEntry(card, slots);
        e.unloaded = false;              // ★装了一颗就不再是"未装填"
        e.slots[index] = dice;
        Debug.Log($"[CardLoadout] {NameOf(card)} #{IdOf(card)} 槽 {index + 1} → " +
                  $"{(dice != null ? dice.diceName : "默认")}（纯配置，未扣骰子）");
        return true;
    }

    /// <summary>把该卡**所有**骰槽装成同一种骰子（大类行 / 自动装填用）。返回装上的槽数。</summary>
    public static int SetAllSlots(Card card, DiceData dice)
    {
        int slots = SlotCount(card);
        if (slots == 0) return 0;

        Entry e = EnsureEntry(card, slots);
        e.unloaded = false;
        for (int i = 0; i < slots; i++) e.slots[i] = dice;
        return slots;
    }

    /// <summary>★教程用：把该卡显式标记为「未装填」（清掉已有覆盖，且不回落模板默认）。</summary>
    public static void MarkUnloaded(Card card)
    {
        if (card == null || SlotCount(card) == 0) return;
        Entry e = EnsureEntry(card, SlotCount(card));
        for (int i = 0; i < e.slots.Length; i++) e.slots[i] = null;
        e.unloaded = true;
    }

    /// <summary>★教程用：批量标记未装填。返回被标记的卡数。</summary>
    public static int MarkAllUnloaded(IEnumerable<Card> cards)
    {
        if (cards == null) return 0;
        int n = 0;
        foreach (Card c in cards)
        {
            if (c == null || SlotCount(c) == 0) continue;
            MarkUnloaded(c);
            n++;
        }
        return n;
    }

    /// <summary>清掉该卡的手动装填（连带解除「未装填」标记）→ 回到模板默认。</summary>
    public static void ClearOverride(Card card)
    {
        if (card == null) return;
        if (_table.Remove(card)) Debug.Log($"[CardLoadout] {NameOf(card)} #{IdOf(card)} 恢复默认装填");
    }

    /// <summary>当局结束 / 重开远征时清空全部装填（ExpeditionLifecycle 调用）。</summary>
    public static void ClearAll()
    {
        if (_table.Count == 0) return;
        int n = _table.Count;
        _table.Clear();
        Debug.Log($"[CardLoadout] 已清空 {n} 张卡的装填记录");
    }

    // ------------------------------------------------------------------
    // 解析
    // ------------------------------------------------------------------
    /// <summary>
    /// 有效装填：手动覆盖优先、`CardData.diceSlot` 默认兜底；被标记未装填时每槽都是 null。
    /// 返回长度恒 = SlotCount(card)；元素可能为 null（未装填 / 未指定的空槽）。
    /// </summary>
    public static List<DiceData> GetEffective(Card card)
    {
        var result = new List<DiceData>();
        if (card == null || card.Data == null) return result;

        List<DiceData> defaults = card.Data.GetBoundDice();
        int slots = defaults.Count;

        // ② 未装填：每槽都是 null —— DicePayment 会跳过付款，卡面停在占位
        if (_table.TryGetValue(card, out Entry e) && e != null && e.unloaded)
        {
            for (int i = 0; i < slots; i++) result.Add(null);
            return result;
        }

        // ①/③ 覆盖优先、模板兜底
        DiceData[] arr = (e != null) ? e.slots : null;
        for (int i = 0; i < slots; i++)
        {
            DiceData dice = (arr != null && i < arr.Length && arr[i] != null) ? arr[i] : defaults[i];
            result.Add(dice);
        }
        return result;
    }

    /// <summary>装填界面显示用：该槽是「未装填 / 默认 / 改装」。</summary>
    public static SlotState StateOf(Card card, int index)
    {
        if (card != null && _table.TryGetValue(card, out Entry e) && e != null)
        {
            if (e.unloaded) return SlotState.Unloaded;
            if (e.slots != null && index >= 0 && index < e.slots.Length && e.slots[index] != null)
                return SlotState.Override;
        }
        return SlotState.Default;
    }

    public enum SlotState
    {
        Default,    // 模板默认骰
        Override,   // 手动改装
        Unloaded    // 未装填（显式清空）
    }

    /// <summary>整卡一句话状态：未装填 / 已装填 / 默认。</summary>
    public static SlotState StateOf(Card card)
    {
        if (IsUnloaded(card)) return SlotState.Unloaded;
        return HasManualDice(card) ? SlotState.Override : SlotState.Default;
    }

    // ------------------------------------------------------------------
    // 自动装填（★2026-09-13：从 LoadoutUI 上移到这里，UI 与「非教程开局自动装填」共用）
    // ------------------------------------------------------------------
    /// <summary>
    /// 自动装填：把 cards 里**还没手动装填过**的卡，各槽统一装成「背包里拥有且最强」的战斗骰。
    /// · 已手动配过骰子的卡保持不动 —— 自动装填只补空缺，不覆盖玩家的选择。
    /// · 临时劣质骰**不是物品**（DiceData 模板，无 ItemData、不进背包），是「玩家没有战斗骰子时的
    ///   补充替代」；候选来源 AllDiceItems 天然不含它，FindBestOwnedBattleDice 里的同引用判断
    ///   只是防御性兜底。
    /// · 装填是纯配置，不消耗任何实体骰子（spec §6）。
    /// </summary>
    /// <returns>实际被装上骰子的卡数（0 = 没有可装的卡 或 背包里没有战斗骰）</returns>
    public static int AutoAssign(IEnumerable<Card> cards)
    {
        if (cards == null) return 0;

        DiceData best = FindBestOwnedBattleDice();
        if (best == null) return 0;

        int n = 0;
        foreach (Card card in cards)
        {
            if (card == null || card.Data == null) continue;
            if (SlotCount(card) <= 0) continue;
            if (HasManualDice(card)) continue;      // 玩家已手动装填 → 不覆盖

            SetAllSlots(card, best);
            n++;
        }
        return n;
    }

    /// <summary>自动装填单张（拿到新卡时用）。</summary>
    /// <returns>装上的骰子；null = 没装（无槽 / 已手动装填 / 背包里没有战斗骰）</returns>
    public static DiceData AutoAssignOne(Card card)
    {
        if (card == null) return null;
        if (SlotCount(card) <= 0) return null;
        if (HasManualDice(card)) return null;

        DiceData best = FindBestOwnedBattleDice();
        if (best == null) return null;

        SetAllSlots(card, best);
        return best;
    }

    /// <summary>
    /// 背包里拥有且最强的战斗骰。比较口径：品质 → 骰值均值 → 面数，逐级取高者。
    /// 候选 = InventoryManager.AllDiceItems 里**真实战斗骰物品**中持有量 &gt; 0 者。
    /// 临时劣质骰不是物品（无 ItemData、不进背包），是「无战斗骰时的补充替代」，天然不参与。
    /// </summary>
    public static DiceData FindBestOwnedBattleDice()
    {
        if (InventoryManager.Instance == null) return null;

        DiceData fallback = DiceInventoryManager.Instance != null
            ? DiceInventoryManager.Instance.TempInferiorDice : null;

        IReadOnlyList<ItemData> items = InventoryManager.Instance.AllDiceItems;
        if (items == null) return null;

        DiceData best = null;
        for (int i = 0; i < items.Count; i++)
        {
            ItemData item = items[i];
            if (item == null || item.diceRef == null) continue;

            DiceData dice = item.diceRef;
            if (dice == fallback) continue;                                 // 防御性兜底（兜底骰不是物品，正常走不到这）
            if (InventoryManager.Instance.CountDice(dice) <= 0) continue;    // 背包里数量为 0

            if (best == null || IsStrongerDice(dice, best)) best = dice;
        }
        return best;
    }

    static bool IsStrongerDice(DiceData a, DiceData b)
    {
        if (a == null) return false;
        if (b == null) return true;
        if (a.quality != b.quality) return a.quality > b.quality;

        float av = AverageDiceValue(a);
        float bv = AverageDiceValue(b);
        if (!Mathf.Approximately(av, bv)) return av > bv;

        int af = a.diceValues != null ? a.diceValues.Length : 0;
        int bf = b.diceValues != null ? b.diceValues.Length : 0;
        return af > bf;
    }

    static float AverageDiceValue(DiceData dice)
    {
        if (dice == null || dice.diceValues == null || dice.diceValues.Length == 0) return 0f;
        int sum = 0;
        for (int i = 0; i < dice.diceValues.Length; i++) sum += dice.diceValues[i];
        return (float)sum / dice.diceValues.Length;
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------
    private static string NameOf(Card card)
    {
        return (card != null && card.Data != null) ? card.Data.cardName : "(空卡)";
    }

    private static int IdOf(Card card)
    {
        return card != null ? card.InstanceId : -1;
    }
}

// =============================================================================
// 模块：M7 背包系统 - DicePayment 骰子付款（纯静态）
// ★2026-09-09 用户定稿：付款时机从「抽牌」移到「打出」——
//   抽牌只掷装填骰点数（读骰值玩法）、不扣费；打出时 PayOnPlay 按有效装填逐颗扣真实骰，
//   不足的槽用临时劣质骰兜底（不扣真实骰）；未打出的牌弃置/回合结束无需返还（抽牌未扣费）。
// 设计依据：spec §6（装填=纯配置，不足用临时劣质骰兜底）+ 用户 2026-09-09 付款时机定稿
// 核心入口：PayOnPlay（打出/使用付款）。PayOnDraw / PayOnUse / MarkPlayed / RefundOnDiscard /
//   RefundAll 是旧「抽牌付款」账本机制的遗留，现已不被核心路径调用（账本恒空，返还方法空操作）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class DicePayment
{
    /// <summary>账本：卡实例 → 本次抽牌实付的**真实**骰子（临时劣质骰不入账、不返还）</summary>
    static readonly Dictionary<Card, List<DiceData>> _paid = new Dictionary<Card, List<DiceData>>();

    /// <summary>背包真实骰子总数（所有骰子物品的堆叠数之和）。</summary>
    public static int TotalRealDice()
    {
        InventoryManager im = InventoryManager.Instance;
        if (im == null) return 0;
        int total = 0;
        foreach (ItemData item in im.AllDiceItems)
        {
            if (item == null || item.diceRef == null) continue;
            total += im.CountDice(item.diceRef);
        }
        return total;
    }

    /// <summary>
    /// ★2026-09-09 弹药可视化：重新分配所有手牌的槽位骰子（槽位水位模型）并掷骰。
    /// 槽位序号 ≤ 真实骰总数 → 真实骰，否则临时骰（点数 1-2）；与手牌顺序/数量无关。
    /// 触发时机：抽牌后、弃牌（打出/手动）后。
    /// </summary>
    /// <param name="skipCard">跳过的卡（正在打出、尚未移出手牌的卡）</param>
    public static void ReallocateHandDice(Card skipCard = null)
    {
        CardPileManager pile = CardPileManager.Instance;
        if (pile == null) return;

        int pool = TotalRealDice();
        DiceData temp = DiceInventoryManager.Instance != null ? DiceInventoryManager.Instance.TempInferiorDice : null;

        foreach (Card card in pile.Hand)
        {
            if (card == null || card.Data == null || card == skipCard) continue;
            if (AssignCard(card, pool, temp))
                card.NotifyDiceChanged();
        }
    }

    /// <summary>分配单张卡（战术槽卡：不经过手牌，同样按槽位水位分配）。</summary>
    /// <param name="force">true = 骰型没变也重掷（战术槽卡每回合刷新用）</param>
    public static void AssignCardDice(Card card, bool force = false)
    {
        if (card == null || card.Data == null) return;
        int pool = TotalRealDice();
        DiceData temp = DiceInventoryManager.Instance != null ? DiceInventoryManager.Instance.TempInferiorDice : null;
        if (AssignCard(card, pool, temp, force))
            card.NotifyDiceChanged();
    }

    /// <summary>
    /// ★2026-09-10 战术槽卡骰值刷新：给**所有槽内卡**分配/重掷战斗骰子。
    /// 为什么需要它：槽内卡不经过抽牌（`ReallocateHandDice` 只遍历 Hand），
    /// 不给它分配就永远是 `DiceValues = -1` → 卡面描述停在 `[1+战斗骰子1]` 占位，
    /// 玩家看不到最终值，也看不到算式小窗。
    ///
    /// 调用时机：
    ///   ① 装入战术槽后（force=false：只补未掷的，保留已有骰点）
    ///   ② 每回合结束 / 新回合开始（force=true：**每回合刷新**，用户定稿）
    ///   ③ 面板 / 卡包展开时（force=false：兜底补漏，不扰动已有骰点）
    /// </summary>
    public static void RefreshSlotDice(bool force = false)
    {
        List<Card> slotted = TacticSlotRuntime.Cards();
        if (slotted.Count == 0) return;

        int pool = TotalRealDice();
        DiceData temp = DiceInventoryManager.Instance != null ? DiceInventoryManager.Instance.TempInferiorDice : null;

        int touched = 0;
        for (int i = 0; i < slotted.Count; i++)
        {
            Card card = slotted[i];
            if (card == null || card.Data == null) continue;
            if (AssignCard(card, pool, temp, force)) { card.NotifyDiceChanged(); touched++; }
        }

        if (force || touched > 0)
        {
            Debug.Log($"[DicePayment] 战术槽骰值刷新：{slotted.Count} 张槽内卡，{touched} 张重掷" +
                      (force ? "（每回合刷新）" : "（补未掷）"));
        }
    }

    /// <summary>单卡槽位分配核心：槽位序号 ≤ 真实骰总数 → 真实骰，否则临时骰。</summary>
    private static bool AssignCard(Card card, int pool, DiceData temp, bool force = false)
    {
        // ★2026-09-13 v2：装填按**卡实例**取（同名卡可各装各的），不再按 card.Data 模板取
        List<DiceData> loadout = CardLoadout.GetEffective(card);
        return card.AssignSlotDice(loadout, temp, pool, force);
    }

    /// <summary>
    /// ★2026-09-09 用户定稿：打出/使用时付款——付款时机从「抽牌」移到「打出」。
    /// 按卡牌每个槽位的实际骰子（SlotDice）扣费：真实骰槽位 TryConsume 扣背包真实骰，
    /// 临时骰槽位不扣真实骰（临时骰无限量、不占背包）。点数已由分配器掷好，只扣费不掷骰。
    /// 战术槽卡（不在手牌）扣费后触发整手重新分配；手牌卡由弃牌出口（DiscardHandCard）触发。
    /// 调用方：PlayCardSystem 步骤 2。
    /// </summary>
    public static void PayOnPlay(Card card)
    {
        if (card == null || card.Data == null) return;
        DiceInventoryManager diceMgr = DiceInventoryManager.Instance;
        DiceData temp = diceMgr != null ? diceMgr.TempInferiorDice : null;

        int real = 0, tempUsed = 0;
        foreach (DiceData dice in card.SlotDice)
        {
            if (dice == null || dice == temp) { tempUsed++; continue; }  // 临时骰不扣真实骰
            if (diceMgr != null && diceMgr.TryConsume(dice)) real++;
            else tempUsed++;
        }

        if (real > 0 || tempUsed > 0)
        {
            Debug.Log($"[DicePayment] {card.Data.cardName} #{card.InstanceId} 打出：扣 {real} 颗装填骰" +
                      (tempUsed > 0 ? $"，{tempUsed} 个槽位用临时劣质骰兜底" : ""));
        }

        // 战术槽卡不在手牌（弃牌出口不会触发），此处手动触发整手重新分配
        if (CardPileManager.Instance == null || !CardPileManager.Instance.Hand.Contains(card))
            ReallocateHandDice();
    }

    /// <summary>
    /// 抽到一张卡时付款：按有效装填逐颗扣背包骰子分区，不足的部分用临时劣质骰顶替。
    /// </summary>
    /// <returns>本卡这次要掷的骰子清单（长度 = 该卡槽数，可能混入临时劣质骰）；0 槽卡返回空表</returns>
    public static List<DiceData> PayOnDraw(Card card)
    {
        var rolled = new List<DiceData>();
        if (card == null || card.Data == null) return rolled;

        // ★2026-09-13 v2：按卡实例取有效装填；被标记「未装填」的卡这里每槽都是 null，
        //   下面的 null 判断会跳过付款（该卡本回合就靠临时劣质骰兜底，直到玩家装上真骰）
        List<DiceData> loadout = CardLoadout.GetEffective(card);
        if (loadout.Count == 0) return rolled;                 // 0 槽卡：不付不掷（Card.HasRolled 构造时已为 true）

        var refundable = new List<DiceData>(loadout.Count);
        DiceInventoryManager diceMgr = DiceInventoryManager.Instance;
        int tempUsed = 0;

        foreach (DiceData dice in loadout)
        {
            if (dice == null) continue;

            if (diceMgr != null && diceMgr.TryConsume(dice))
            {
                rolled.Add(dice);
                refundable.Add(dice);
                continue;
            }

            DiceData temp = diceMgr != null ? diceMgr.TempInferiorDice : null;
            if (temp == null)
            {
                Debug.LogError($"[DicePayment] {dice.diceName} 库存不足，且 DiceInventoryManager.tempInferiorDice 未连线——" +
                               "跑 Tools/背包/3. 场景挂载与连线（会建资产并连线）");
                rolled.Add(dice);                              // 没配保底骰也不能让卡掷不出点数（异常路径）
                continue;
            }

            rolled.Add(temp);
            tempUsed++;
        }

        _paid[card] = refundable;

        if (tempUsed > 0)
        {
            Debug.Log($"[DicePayment] {card.Data.cardName} #{card.InstanceId}：付 {refundable.Count} 颗真实骰 + " +
                      $"{tempUsed} 颗临时劣质骰（保底）");
        }
        return rolled;
    }

    /// <summary>
    /// ★战术卡使用付款（Task 11）：`PayOnDraw` 的语义别名，实现完全一致。
    /// 战术槽内的卡不经过抽牌，`DiceValues` 恒为 -1，而 `Card.ResolveValue` 把未投骰按 0 计
    /// → 使用前必须付骰 + 掷骰，否则效果凭空变弱。
    /// 账本口径与抽牌一致：打出时 `PlayCardSystem` 步骤 2 的 `MarkPlayed` 销账，骰子不返还。
    /// 单独起名的唯一理由是调用处可读性（"使用时付款" vs "抽到时付款"）。
    /// </summary>
    public static List<DiceData> PayOnUse(Card card)
    {
        return PayOnDraw(card);
    }

    /// <summary>打出该卡：销账（已付骰子不返还）。</summary>
    public static void MarkPlayed(Card card)
    {
        if (card == null) return;
        if (_paid.Remove(card))
        {
            Debug.Log($"[DicePayment] {card.Data.cardName} #{card.InstanceId} 已打出，骰子不返还");
        }
    }

    /// <summary>未打出就弃置：把实付的真实骰子逐颗返还骰子分区（spec §6）。</summary>
    public static void RefundOnDiscard(Card card)
    {
        if (card == null || !_paid.TryGetValue(card, out List<DiceData> refundable)) return;

        _paid.Remove(card);
        if (refundable.Count == 0) return;

        DiceInventoryManager diceMgr = DiceInventoryManager.Instance;
        if (diceMgr == null)
        {
            Debug.LogWarning($"[DicePayment] 场景中没有 DiceInventoryManager，{refundable.Count} 颗骰子无法返还");
            return;
        }

        foreach (DiceData dice in refundable) diceMgr.Return(dice);
        Debug.Log($"[DicePayment] {card.Data.cardName} #{card.InstanceId} 未打出即弃置，返还 {refundable.Count} 颗骰子");
    }

    /// <summary>把账本里所有未打出的付款全部返还并清空（重建抽牌堆 / 当局结束兜底）。</summary>
    /// <remarks>必须先拷清单再清空账本：清空后就拿不到要返还哪些骰型了。</remarks>
    public static void RefundAll()
    {
        if (_paid.Count == 0) return;

        var snapshot = new List<List<DiceData>>(_paid.Values);
        int entries = _paid.Count;
        _paid.Clear();

        DiceInventoryManager diceMgr = DiceInventoryManager.Instance;
        int dice = 0;
        foreach (List<DiceData> list in snapshot)
        {
            foreach (DiceData d in list)
            {
                diceMgr?.Return(d);
                dice++;
            }
        }

        if (diceMgr == null && dice > 0)
        {
            Debug.LogWarning($"[DicePayment] RefundAll：场景中没有 DiceInventoryManager，{dice} 颗骰子无法返还");
        }
        else if (dice > 0 || entries > 0)
        {
            Debug.Log($"[DicePayment] RefundAll：{entries} 张未打出的卡返还 {dice} 颗骰子");
        }
    }

    /// <summary>账本内该卡实付的真实骰子数（调试 / 编辑器断言用）。</summary>
    public static int PaidCountOf(Card card)
    {
        return (card != null && _paid.TryGetValue(card, out List<DiceData> list)) ? list.Count : 0;
    }

    /// <summary>账本条目数（调试 / 断言用）。</summary>
    public static int LedgerCount => _paid.Count;
}

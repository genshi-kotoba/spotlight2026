// =============================================================================
// 模块：Card 运行时实例层
// 用途：一张卡在运行时的"活"数据。与 CardData（SO 模板）分离，
//       确保同一张 SO 模板被多份引用时，互不影响。
// 示例：玩家牌组里有 4 张"防御"，都是同一个 CardData SO 引用。
//       其中一张"防御"被效果降费为 0，但其他 3 张仍保持原费 1。
//       没有 Card 层时，这做不到（修改 CardData 会影响所有引用）。
// 参考：NSWells P3 Card 三层分离架构
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 卡牌运行时实例。
/// 不可挂载到 GameObject 的纯 C# 类，生命周期由 CardPileManager 管理。
/// </summary>
[Serializable]
public class Card
{
    /// <summary>卡牌模板数据（ScriptableObject，只读）</summary>
    public CardData Data { get; }

    /// <summary>实例唯一 ID（用于调试和引用跟踪）</summary>
    public int InstanceId { get; }

    /// <summary>当前能量消耗（可被动态修改，如"降低 1 点费用"效果）</summary>
    public int CurrentCost { get; set; }

    /// <summary>当前 CD 回合（0 = 无 CD / 已就绪）</summary>
    public int CurrentCD { get; set; }

    /// <summary>是否已升级（M7 局外升级后标记）</summary>
    public bool IsUpgraded { get; set; }

    /// <summary>升级次数</summary>
    public int UpgradeLevel { get; set; }

    // ======== 战斗骰子运行时状态 ========
    // 设计依据：总策划案 6.2.2 —— 抽到卡牌后自动投出绑定骰子，点数跟随该卡实例。
    // 每张卡实例的点数独立（同 SO 模板的两张"直刺"掷出的点数不同）。

    /// <summary>本卡各绑定骰子的点数（-1 = 未投掷）。长度 = 绑定骰子数</summary>
    public int[] DiceValues { get; private set; }

    /// <summary>
    /// ★2026-09-09 弹药可视化：每个槽位当前实际使用的骰子（真实装填骰 或 临时劣质骰）。
    /// 长度 = DiceValues.Length。真实骰不足时，后面的槽位退化为临时骰（点数 1-2）。
    /// </summary>
    private DiceData[] _slotDice;

    /// <summary>每个槽位实际使用的骰子（供 DicePayment.PayOnPlay 按槽位扣费）。</summary>
    public DiceData[] SlotDice => _slotDice;

    /// <summary>是否已掷过骰（0 槽卡构造后即为 true，边缘情况 5.1：0 骰子槽直接结算基础数值）</summary>
    public bool HasRolled { get; private set; }

    /// <summary>
    /// 骰子点数变化事件（掷骰/重投后触发）。
    /// CardView 订阅 → 重新生成动态描述（最终值随点数变化）。
    /// </summary>
    public event Action OnDiceValuesChanged;

    /// <summary>
    /// ★2026-09-16 持卡人（掷骰主体）。骰面上下限修正挂在**人**身上（EffectManager 按 target 查），
    /// 掷骰时要先知道"谁在掷"才能取到修正。玩家卡 = 玩家根物体（HexMover 所在物体），
    /// 敌人卡 = EnemyController 所在物体。未设（预览卡/测试）时不吃修正，掷骰行为与改造前一致。
    /// 设定点：EnemyCardExecutor.ExecuteCard（敌人出牌）、EnemyController.RevealIntent（意图预掷）、
    /// CardDeckManager（玩家牌组）。
    /// </summary>
    public GameObject Owner { get; set; }

    // 自动递增 ID 计数器（调试用）
    private static int _nextId = 1;

    public Card(CardData data)
    {
        Data = data;
        InstanceId = _nextId++;
        CurrentCost = data != null ? data.energyCost : 0;
        CurrentCD = 0;
        IsUpgraded = false;
        UpgradeLevel = 0;

        // 初始化骰子状态：长度 = 绑定骰子数，全部标记未投掷
        int diceCount = data != null ? data.GetBoundDice().Count : 0;
        DiceValues = new int[diceCount];
        for (int i = 0; i < diceCount; i++) DiceValues[i] = -1;
        _slotDice = new DiceData[diceCount];
        // 边缘情况 5.1：0 骰子槽卡直接结算基础数值，无需掷骰
        HasRolled = diceCount == 0;
    }

    /// <summary>
    /// 重置为模板默认状态（洗牌/重新进入战斗时调用）
    /// 注意：骰子点数不在此重置——重掷时显式调 RollAllDice
    /// </summary>
    public void ResetToDefault()
    {
        CurrentCost = Data != null ? Data.energyCost : 0;
        CurrentCD = 0;
        IsUpgraded = false;
        UpgradeLevel = 0;
    }

    /// <summary>
    /// 弃牌堆洗回抽牌堆时的完整重置（★用户 2026-08-17 定义的生命周期）：
    ///   抽牌堆 = 数值未知（骰子未投）；手牌 = 抽到即掷、数值固定；
    ///   弃牌堆 = 保留手牌期间的点数；洗回抽牌堆 = 数据重置、骰子回未投状态。
    /// 费用/CD 回模板值 + 骰子点数清回 -1（下次抽到重新掷）。
    /// 注意：从弃牌堆直接回手牌的效果（如"回收"类卡）不经过此方法，点数保留。
    /// </summary>
    public void ResetForReshuffle()
    {
        ResetToDefault();

        for (int i = 0; i < DiceValues.Length; i++)
        {
            DiceValues[i] = -1;
            _slotDice[i] = null;   // ★弹药可视化：洗回后清槽位骰子类型，下次抽到重新分配
        }
        HasRolled = DiceValues.Length == 0; // 0 槽卡依旧视为"已就绪"（边缘情况 5.1）

        OnDiceValuesChanged?.Invoke(); // 通知视图（若有）回到占位显示
    }

    /// <summary>
    /// 掷出本卡所有绑定骰子（覆盖旧点数，可用于重投）。
    /// 设计依据：总策划案 6.2.2（抽牌自动掷）+ 边缘情况 5.1（打出兜底掷）。
    /// </summary>
    public void RollAllDice()
    {
        if (Data == null) return;

        GetFaceModifiers(out int floorBonus, out int ceilBonus);
        bool anyRolled = false;

        List<DiceData> boundDice = Data.GetBoundDice();
        for (int i = 0; i < boundDice.Count && i < DiceValues.Length; i++)
        {
            DiceData die = boundDice[i];
            if (die == null) continue;
            DiceValues[i] = ApplyFaceModifiers(die.Roll(), die, floorBonus, ceilBonus);
            anyRolled = true;
        }
        HasRolled = true;
        if (anyRolled) ConsumeFaceModifiers();

        Debug.Log($"[Card] 掷骰：{Data.cardName} #{InstanceId} 点数 [{string.Join(", ", DiceValues)}]");

        OnDiceValuesChanged?.Invoke();
    }

    /// <summary>
    /// ★装填（spec §6）：掷出**本次付款实际拿到的**骰子（可能含临时劣质骰）。
    /// 与 RollAllDice 的区别：RollAllDice 一律按 CardData 的 Inspector 默认骰子掷，
    /// 本方法按调用方给的清单掷——手动装填与保底骰都从这里体现。
    /// RollAllDice 原样保留：敌人卡链路、0 槽卡与探索态抽牌仍走它。
    /// </summary>
    /// <param name="dice">本次要掷的骰子（长度应 = DiceValues.Length；不一致时按较短一方）</param>
    public void RollDice(List<DiceData> dice)
    {
        if (Data == null || dice == null) return;

        GetFaceModifiers(out int floorBonus, out int ceilBonus);
        bool anyRolled = false;

        for (int i = 0; i < dice.Count && i < DiceValues.Length; i++)
        {
            if (dice[i] == null) continue;
            DiceValues[i] = ApplyFaceModifiers(dice[i].Roll(), dice[i], floorBonus, ceilBonus);
            anyRolled = true;
        }
        HasRolled = true;
        if (anyRolled) ConsumeFaceModifiers();

        Debug.Log($"[Card] 掷骰（装填）：{Data.cardName} #{InstanceId} 点数 [{string.Join(", ", DiceValues)}]");

        OnDiceValuesChanged?.Invoke();
    }

    /// <summary>
    /// ★2026-09-13 重投（基础重投）：把本卡**全部槽位**的骰子整体重掷。
    /// 逐槽取 _slotDice[i]（真实装填骰 / 临时劣质骰，水位模型分配结果）优先；
    /// 为 null（探索态抽牌、骰源未就绪）退回模板绑定骰 Data.GetBoundDice()[i]；仍无 → 跳过该槽。
    /// **不写回 _slotDice**：骰型与槽位分配原样不动，只变点数——保持 AssignSlotDice 的水位模型
    /// 与「拿出拿回不重掷」防刷判据不被扰动。重投不额外扣装填弹药（装填时已付过），只花那 1 枚探索骰。
    /// 设计依据：docs/2026-09-13_重投-design.md §3.1；F6.2 基础重投。
    /// </summary>
    /// <returns>是否至少重掷了一枚骰子</returns>
    public bool RerollAllDice()
    {
        if (Data == null || DiceValues == null || DiceValues.Length == 0) return false;

        GetFaceModifiers(out int floorBonus, out int ceilBonus);

        List<DiceData> bound = Data.GetBoundDice();
        bool any = false;
        for (int i = 0; i < DiceValues.Length; i++)
        {
            DiceData die = (_slotDice != null && i < _slotDice.Length) ? _slotDice[i] : null;
            if (die == null && bound != null && i < bound.Count) die = bound[i];
            if (die == null) continue;

            DiceValues[i] = ApplyFaceModifiers(die.Roll(), die, floorBonus, ceilBonus);
            any = true;
        }
        if (!any) return false;

        HasRolled = true;
        ConsumeFaceModifiers();
        Debug.Log($"[重投] {Data.cardName} #{InstanceId} 点数 [{string.Join(", ", DiceValues)}]");
        OnDiceValuesChanged?.Invoke();
        return true;
    }

    // ======== ★2026-09-16 骰面上下限修正（设计页 R1「骰面语言」六条铁律的引擎落点）========
    // 铁律① 一卡一轴：同一张卡只改一个轴（引擎不禁止同时拿两种，交给出卡设计约束）
    // 铁律② 对所有骰子生效：一次调用内对整批槽位逐颗应用 → 多骰卡是放大器
    // 铁律③ 力量不在此处参与（力量在伤害管线加，见 StrengthEffect）
    // 铁律④ 生效时点＝下一次掷骰，整批掷完即消耗一次性修正（持续版走回合衰减）
    // 铁律⑤ 下限钳到面值（d4 的 +3 → 必掷 4 = 必暴）；暴击判据 = 生效值 ≥ **原**面值最大值（阈值不随上限抬）
    // 铁律⑥ 三轴分工：上限＝抬暴击率／下限＝保底／力量＝稳定加伤

    /// <summary>
    /// 应用本次掷骰的骰面修正：
    ///   下限 → 先钳至面值顶（<c>Mathf.Min(面值min + 下限加成, 面值max)</c>），d4 的 +3 即必暴；
    ///   上限 → 后加，可超面值顶（d4 的 +1 → 值域 1~5，掷出 4 或 5 都 ≥ 4 → 暴击率 25%→50%）。
    /// 先钳后加的顺序不可换：若先加后钳，上限加成的超出部分会被下限钳位吃掉。
    /// </summary>
    private static int ApplyFaceModifiers(int raw, DiceData die, int floorBonus, int ceilBonus)
    {
        if (die == null || (floorBonus <= 0 && ceilBonus <= 0)) return raw;

        int faceMin = die.MinFace;
        int faceMax = die.MaxFace;

        int value = raw;
        if (floorBonus > 0) value = Mathf.Max(value, Mathf.Min(faceMin + floorBonus, faceMax));
        if (ceilBonus > 0) value += ceilBonus;
        return value;
    }

    /// <summary>取持卡人身上的骰面修正（无 Owner / 无效果管理器 → 全 0，零开销）。</summary>
    private void GetFaceModifiers(out int floorBonus, out int ceilBonus)
    {
        floorBonus = 0;
        ceilBonus = 0;
        if (Owner == null || EffectManager.Instance == null) return;
        EffectManager.Instance.GetDiceFaceModifiers(Owner, out floorBonus, out ceilBonus);
    }

    /// <summary>
    /// 整批掷骰结束后消耗一次性修正（<see cref="Effect.ConsumeOnRoll"/>；持续版不受影响）。
    /// 注意：<see cref="AssignSlotDice"/> 不吃修正也不消耗——装填/战术槽刷新是**整手批量重排**，
    /// 一张修正会被手牌顺序里靠前的那张随机吃掉，玩家无法预期；敌人链路（架弩/磨斧的真实用户）
    /// 走 RollAllDice 已覆盖。玩家侧若出骰面卡，落点应另设（「下一张打出的卡」），不走批量分配。
    /// </summary>
    private void ConsumeFaceModifiers()
    {
        if (Owner == null || EffectManager.Instance == null) return;
        EffectManager.Instance.ConsumeRollModifiers(Owner);
    }

    /// <summary>
    /// ★2026-09-09 弹药可视化：为每个槽位分配实际使用的骰子并（类型变化时）重掷点数。
    /// 槽位水位模型：槽位序号(i+1) ≤ 真实骰总数(pool) → 真实骰，否则临时骰（tempDice）。
    /// 与手牌顺序/数量无关——所有卡的第 k 槽共享同一「水位」判定（用户 2026-09-09 定稿）。
    /// 类型没变的槽位不重掷（保持点数稳定）。
    /// </summary>
    /// <param name="realDice">该卡的有效装填骰（真实骰，按槽位顺序）</param>
    /// <param name="tempDice">临时劣质骰（真实骰不足时兜底）</param>
    /// <param name="pool">背包真实骰总数</param>
    /// <returns>是否有槽位骰子类型变化（供调用方决定是否通知视图）</returns>
    public bool AssignSlotDice(List<DiceData> realDice, DiceData tempDice, int pool, bool force = false)
    {
        bool changed = false;
        for (int i = 0; i < DiceValues.Length; i++)
        {
            bool real = (i + 1) <= pool;
            DiceData target = real ? (i < realDice.Count ? realDice[i] : tempDice) : tempDice;

            // ★2026-09-10 战术槽卡「每回合刷新」（force=true）：骰型没变也重掷一次。
            //   反过来说，玩家把同一张卡**拿出再装回**战术槽走的是 force=false 这条路
            //   → 骰型没变就不重掷 → 骰点原样保留，堵掉「反复进出刷骰值」的漏洞。
            //
            // ★★2026-09-11 补：判据必须是「骰型没变 **且** 这个槽已经掷过」。
            //   只判骰型会漏掉一种死局——开局装槽时 DiceInventoryManager 可能还没就绪
            //   （pool=0 且 TempInferiorDice 未连线）→ target 算出来是 null，而 _slotDice[i]
            //   本来就是 null → null == null → 直接 continue，骰值永远停在初始的 -1；
            //   之后骰源就绪了再补，骰型还是没变 → 继续 continue → **卡面描述永远显示
            //   [战斗骰子] 占位**（用户报的 bug）。加上 hasRolled 判据后：
            //     · 从没掷过（-1）→ 无论如何都要掷一次  ← 修的就是这条
            //     · 已掷过且骰型没变 → 不重掷（拿出拿进保留骰点）← 用户要的这条
            bool hasRolled = DiceValues[i] >= 0;
            if (!force && hasRolled && _slotDice[i] == target) continue;   // 类型没变，不重掷，保持点数稳定
            _slotDice[i] = target;
            DiceValues[i] = target != null ? target.Roll() : -1;
            changed = true;
        }
        if (DiceValues.Length > 0) HasRolled = true;   // 已分配/已掷，避免 PlayCardSystem 兜底重掷覆盖弹药点数
        return changed;
    }

    /// <summary>触发骰子点数变化事件（分配器整手分配后调用，驱动 CardView 刷新描述）。</summary>
    public void NotifyDiceChanged()
    {
        OnDiceValuesChanged?.Invoke();
    }

    /// <summary>
    /// 获取指定序号（1 起）骰子的点数
    /// </summary>
    /// <param name="diceNumber">骰子序号（1 = 战斗骰子1）</param>
    /// <returns>点数；序号无效或未投掷返回 -1</returns>
    public int GetDiceValue(int diceNumber)
    {
        int index = diceNumber - 1;
        if (index < 0 || index >= DiceValues.Length) return -1;
        return DiceValues[index];
    }

    /// <summary>
    /// ★M5b-3（2026-08-18）：解析 ValueConfig 的最终值（公式 F5.2：基础值 + Σ骰子点数）。
    /// diceSelect 指向的骰子未投（-1）按 0 计（打出链路在 PlayCardSystem 有掷骰兜底，
    /// 此处防御覆盖异常路径）。
    /// 供 PlayCardSystem 效果分发解析 伤害值/防御值/效果层数。
    /// </summary>
    /// <param name="config">数值配置（baseValue + diceSelect）</param>
    /// <returns>最终值 = baseValue + 选中骰子点数</returns>
    public int ResolveValue(ValueConfig config)
    {
        if (config == null) return 0;

        int value = config.baseValue;

        if (config.diceSelect != DiceSelect.无)
        {
            int diceValue = GetDiceValue((int)config.diceSelect);
            if (diceValue > 0) value += diceValue; // -1（未投）按 0 计
        }
        return value;
    }

    public override string ToString()
    {
        string name = Data != null ? Data.cardName : "null";
        return $"[Card #{InstanceId}: {name} cost={CurrentCost}]";
    }
}

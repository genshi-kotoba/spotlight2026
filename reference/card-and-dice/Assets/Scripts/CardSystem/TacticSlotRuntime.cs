// =============================================================================
// 模块：战术卡槽运行时 TacticSlotRuntime（S12 模型层）
// 用途：战术槽 + 每槽冷却。槽内卡不进抽牌堆、不进手牌（spec §5）。
//       纯静态、不挂 GameObject：牌库过滤（CardDeckManager.GetPlayableDeck）、
//       卡包页边栏（CardPackUI）、战斗内战术面板（TacticSlotsPanel）共用同一份状态。
//       槽内元素是 CardDeckManager.Library 里的稳定 Card 实例（按实例过滤）。
// 设计依据：spec §5 战术卡槽（S12）/ §16 实际 CD = max(1, 基础CD − ⌊智力÷3⌋)
//           《设计增补_边缘情况与验收标准》§十：CD 中不可用 / 缩短至 0 立即可用 /
//           基础 CD=0 立即可用 / 智力加成后至少 1
//           ★2026-09-10 三次定稿（用户）：
//             ① 4 槽 → **2 槽**；② 装载入口移到卡包页边栏；开局按 defaultTacticCards 自动装载。
//             ③ **槽位不再设上限**——「战术卡槽 = 两竖排（2 列）布局的拓展手牌位，
//                竖着是一个无限背包，按卡牌数量无限下拉」。所以内部改成 List 容器：
//                容量按需增长，`SlotCount` 从「容量上限」变成「当前容器长度」。
//                两侧 UI（卡包边栏 / 战斗面板）都按 Columns(=2) 列铺格 + 竖向滚动。
//            spec: docs/superpowers/specs/2026-09-10-卡包装载与战术槽装帧-design.md
//                  docs/superpowers/specs/2026-09-10-战术卡槽交互-design.md
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 战术卡槽运行时（纯静态）。装备/卸下只允许探索态（Task 9 [规格解释]）。
///
/// 容器语义（★2026-09-10 三次定稿）：
///   - **无容量上限**（无限背包）：装到第 N 张就自动扩到第 N 个槽。
///   - <see cref="SlotCount"/> = 当前容器长度（已使用到的槽数 + 可能的中间空槽），
///     不再是「容量上限」；UI 要建多少个格子用 <see cref="DisplaySlotCount"/>。
///   - <see cref="Columns"/> 固定 2 —— 两竖排布局，两侧 UI 共用。
/// </summary>
public static class TacticSlotRuntime
{
    /// <summary>
    /// 战术卡槽的**列数**。卡包边栏与战斗面板都按这个列数铺格。
    /// ★v9（2026-09-11 用户定稿）**槽位先完全锁死为 1 个**：
    ///   原为「2 列无限行的拓展手牌位」，因「随意拿进拿出」带来的平衡问题
    ///   （牌库提纯 / 零成本装载 / 每回合白嫖一次战术效果），先锁成单槽。
    ///   将来要开多槽：把 Columns / MaxSlots / HardLimit / MinDisplaySlots 一起放开即可，
    ///   List 容器语义与「槽满拒绝」分支都还在，不需要改结构。
    /// </summary>
    public const int Columns = 1;

    /// <summary>
    /// 容量上限：**0 = 无限**（★2026-09-10 用户定稿「竖着是一个无限背包」）。
    /// 若哪天策划要给容量上枷锁，把这里改成正整数即可——「槽满拒绝」的分支已经写好。
    /// </summary>
    public const int MaxSlots = 1;

    /// <summary>
    /// 硬性安全上限（防拖拽落点异常算出个荒谬序号把容器撑爆）。
    /// 一局牌库也就十几张，正常玩法永远碰不到；它不是设计上的容量限制。
    /// </summary>
    public const int HardLimit = 1;

    /// <summary>空槽底板至少显示几格（保证总有一个空格可以拖进去）。</summary>
    public const int MinDisplaySlots = 1;

    private static readonly List<Card> _slots = new List<Card>();
    private static readonly List<int> _cooldowns = new List<int>();

    /// <summary>
    /// ★v9（2026-09-11 平衡性定稿）：**装载整备期** —— 刚装进槽的卡要等几个回合末才可用。
    /// 与 <see cref="_cooldowns"/> 平行，同步扩容/收缩（见 EnsureSize / TrimTail）。
    /// </summary>
    private static readonly List<int> _arming = new List<int>();

    /// <summary>槽位内容或 CD 变化（TacticSlotsPanel / CardPackUI 订阅刷新）</summary>
    public static event Action OnChanged;

    // ------------------------------------------------------------------
    // 读取
    // ------------------------------------------------------------------

    /// <summary>当前容器长度（含中间空槽）。UI 循环真实数据用它，建格用 DisplaySlotCount。</summary>
    public static int SlotCount => _slots.Count;

    /// <summary>行数 = ⌈列数分配后的行数⌉（2 列时 = ⌈槽数/2⌉）。</summary>
    public static int RowCount => Mathf.CeilToInt(SlotCount / (float)Columns);

    /// <summary>
    /// 两侧 UI 应该建多少个格子：**偶数、至少 2 格、且永远留一个空格**。
    ///   已装 0 → 2 格（全空）      已装 1 → 2 格（1 空）    已装 2 → 4 格（2 空）
    ///   已装 3 → 4 格（1 空）      已装 4 → 6 格（2 空）
    /// 这样「无限背包」始终有一个空位可以拖进去，且不会出现半排的残缺行。
    /// </summary>
    public static int DisplaySlotCount
    {
        get
        {
            // ★必须同时满足两件事：
            //   ① 永远留一个空格（拖拽要有落点）→ OccupiedCount + 1
            //   ② 覆盖所有「已经存在」的槽位序号 → SlotCount
            //   （② 是 L2 断言抓出来的坑：跳号装载出槽 10 时，只按占用数算会得出 6 格，
            //     槽 10 的卡就没有格子可显示，玩家会以为卡丢了）
            int need = OccupiedCount + 1;
            if (SlotCount > need) need = SlotCount;

            int rows = Mathf.CeilToInt(need / (float)Columns);
            int cells = rows * Columns;
            if (cells < MinDisplaySlots) cells = MinDisplaySlots;
            if (cells > HardLimit) cells = HardLimit;
            // ★v9：槽位锁死为 1 → 显示格数不得超过容量。否则「已装 1 张」还会再算出一个空格，
            //   UI 上出现第二个永远装不进去的格子。
            if (MaxSlots > 0 && cells > MaxSlots) cells = MaxSlots;
            return cells;
        }
    }

    public static Card Get(int index)
    {
        return InRange(index) ? _slots[index] : null;
    }

    public static int GetCooldown(int index)
    {
        return InRange(index) ? _cooldowns[index] : 0;
    }

    public static bool IsOccupied(int index)
    {
        return Get(index) != null;
    }

    /// <summary>可用 = 有卡且不在冷却（边缘情况 §十：CD 归零即可用）。</summary>
    public static bool IsReady(int index)
    {
        return IsOccupied(index) && _cooldowns[index] <= 0 && _arming[index] <= 0;
    }

    public static bool Contains(Card card)
    {
        return card != null && IndexOf(card) >= 0;
    }

    public static int IndexOf(Card card)
    {
        if (card == null) return -1;
        for (int i = 0; i < _slots.Count; i++)
        {
            if (ReferenceEquals(_slots[i], card)) return i;
        }
        return -1;
    }

    /// <summary>
    /// 第一个空槽序号。**无限容器下恒有解**：容器内没有空槽就返回末尾序号（= 追加）。
    /// 仅在配置了 <see cref="MaxSlots"/> 且已装满时返回 -1（spec §5「槽满无法放入」）。
    /// </summary>
    public static int FirstEmptyIndex()
    {
        for (int i = 0; i < _slots.Count; i++)
        {
            if (_slots[i] == null) return i;
        }
        if (IsFull || _slots.Count >= HardLimit) return -1;
        return _slots.Count;                 // 追加到末尾
    }

    /// <summary>是否已达容量上限（MaxSlots ≤ 0 表示无限 → 永远 false）。</summary>
    public static bool IsFull
    {
        get { return MaxSlots > 0 && OccupiedCount >= MaxSlots; }
    }

    public static int OccupiedCount
    {
        get
        {
            int n = 0;
            for (int i = 0; i < _slots.Count; i++) if (_slots[i] != null) n++;
            return n;
        }
    }

    /// <summary>槽内卡牌列表（CharacterStats 持有集合计数用：D9 + spec §5）。</summary>
    public static List<Card> Cards()
    {
        var list = new List<Card>(_slots.Count);
        for (int i = 0; i < _slots.Count; i++) if (_slots[i] != null) list.Add(_slots[i]);
        return list;
    }

    /// <summary>
    /// 实际 CD（spec §16）：基础 CD ≤ 0 → 0（边缘情况 §十：基础 CD=0 立即可用）；
    /// 否则 max(1, 基础CD − ⌊智力÷3⌋)（智力再高也至少冷却 1 回合）。
    /// </summary>
    public static int EffectiveCooldown(Card card)
    {
        if (card == null || card.Data == null) return 0;

        int baseCd = card.Data.cooldown;
        if (baseCd <= 0) return 0;

        int reduction = CharacterStats.智力 / CharacterStats.AttributeDivisor;
        return Mathf.Max(1, baseCd - reduction);
    }

    // ------------------------------------------------------------------
    // ★v9 平衡性（2026-09-11 用户定稿）
    //   E：槽位锁死为 1      B：装载延迟一回合生效
    //   + 补丁 1：打出后至少冷却 1 回合（堵「CD=0 的卡每回合都能用」）
    //   + 补丁 2：冷却中的卡锁在槽里（堵「用完 → 卸下洗 CD → 装下一张 → 下回合又有一张」）
    // ------------------------------------------------------------------

    /// <summary>装载后需要「整备」几个回合末才可用（B 方案）。0 = 关闭延迟。</summary>
    public const int EquipDelayTurns = 1;

    /// <summary>
    /// 战术槽内卡打出后的**最低冷却**。
    /// 堵住「基础 CD=0 的卡进槽后每回合都能用一次」—— 战术槽是稀缺位（v9 起只有 1 格），
    /// 每次使用都必须付出至少 1 回合的再装填时间，否则 B 的延迟对这类卡完全无效。
    /// </summary>
    public const int MinSlotCooldown = 1;

    /// <summary>战术槽专用 CD = max(<see cref="MinSlotCooldown"/>, spec §16 算出的实际 CD)。</summary>
    public static int SlotCooldownOf(Card card)
    {
        return Mathf.Max(MinSlotCooldown, EffectiveCooldown(card));
    }

    /// <summary>整备剩余回合（装载延迟）。0 = 已就绪。</summary>
    public static int GetArming(int index)
    {
        return InRange(index) ? _arming[index] : 0;
    }

    /// <summary>还要等几个回合才能用 = max(冷却, 整备)。UI 蒙版与「能不能打出」都看它。</summary>
    public static int GetBlockTurns(int index)
    {
        int a = GetArming(index);
        int c = GetCooldown(index);
        return a > c ? a : c;
    }

    /// <summary>是否处于**冷却**（区别于整备：冷却能用探索骰缩短，整备只能等回合）。</summary>
    public static bool IsCooling(int index)
    {
        return IsOccupied(index) && _cooldowns[index] > 0;
    }

    /// <summary>
    /// ★能否卸下：冷却中的卡被**锁在槽里**。
    /// 用户指出的洞：「这回合用完 → 卸下（旧代码会把 CD 清零！）→ 装另一张 → 下回合又有一张可用」，
    /// 两张卡轮流睡一回合就能每回合白嫖一次战术效果。锁住之后，换卡周期 = CD + 整备。
    /// </summary>
    public static bool CanUnequip(int index)
    {
        return IsOccupied(index) && _cooldowns[index] <= 0;
    }

    // ------------------------------------------------------------------
    // 装备 / 卸下
    // ------------------------------------------------------------------

    /// <summary>
    /// 把一张牌库卡装入第一个空槽（无限容器 → 没空槽就追加到末尾）。
    /// 拒绝：卡为空 / 已在槽内 / 战斗态 / 超出硬上限；失败原因写 reason（UI 直接显示）。
    /// </summary>
    public static bool TryEquip(Card card, out string reason)
    {
        return TryEquipAt(FirstEmptyIndex(), card, out reason);
    }

    /// <summary>
    /// 把一张牌库卡装入**指定槽**（卡包页边栏拖拽落点用：落哪格装哪格）。
    /// 序号超出容器 → 自动扩容到该序号（无限背包语义）。
    /// 拒绝：卡为空 / 已在槽内 / 战斗态 / 序号非法（负数或超硬上限）/ 该槽已被占（需先卸下）。
    /// </summary>
    public static bool TryEquipAt(int index, Card card, out string reason)
    {
        reason = null;

        if (card == null || card.Data == null)
        {
            reason = "卡牌为空";
            return false;
        }

        if (Contains(card))
        {
            reason = $"{card.Data.cardName} 已在战术槽内";
            return false;
        }

        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            reason = "战斗中无法调整战术卡槽";
            return false;
        }

        if (index < 0 || index >= HardLimit)
        {
            reason = IsFull
                ? $"战术卡槽已满（{MaxSlots}/{MaxSlots}）"
                : "无效的槽位";
            return false;
        }

        if (IsFull)
        {
            reason = $"战术卡槽已满（{MaxSlots}/{MaxSlots}）：先卸下一张";
            return false;
        }

        // ★无限容器：目标序号在容器外 → 先扩容（中间自动补空槽）
        EnsureSize(index + 1);

        // ★2026-09-10：目标槽已有卡 → 拒绝（不改写、不静默覆盖）。
        //   原先直接 _slots[index] = card 会把旧卡挤出去变成「未装但在牌库」，玩家看不到卸下动作。
        Card occupant = _slots[index];
        if (occupant != null)
        {
            reason = occupant.Data != null
                ? $"槽 {index + 1} 已被 {occupant.Data.cardName} 占用（先卸下）"
                : $"槽 {index + 1} 已被占用（先卸下）";
            return false;
        }

        _slots[index] = card;
        _cooldowns[index] = 0;
        // ★v9：装载有延迟（B 方案）—— 刚装进去的卡要整备，不能当回合临时应急。
        _arming[index] = EquipDelayTurns;

        // ★2026-09-10 卡牌唯一性（用户定稿）：装进战术槽 = 从牌堆里**取走**。
        //   牌库（Library）持有全部 Card 实例，手牌装的也是同一批实例的引用；
        //   不在这一步摘掉，把一张手牌拖进槽就会「同时存在两张」——手牌那份引用还在，
        //   而且这张卡下回合还会被再抽一次。全局口径：
        //   抽牌堆 / 弃牌堆 / 手牌 / 战术槽 —— 同一个 Card 实例只能在一个区。
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.DetachCardFromPiles(card);
        }

        // ★2026-09-10 槽内卡骰值：槽内卡不经过抽牌（ReallocateHandDice 只遍历 Hand），
        //   不在这里补一次分配，卡面描述会永远停在 [1+战斗骰子1] 占位（用户报的 bug）。
        //   force=false → 骰型没变就不重掷 → **同一张卡拿出再装回，骰点不变**。
        DicePayment.AssignCardDice(card, false);

        Debug.Log($"[TacticSlotRuntime] 装备：槽 {index + 1} ← {card.Data.cardName} #{card.InstanceId}" +
                  $"（基础 CD {card.Data.cooldown} → 实际 CD {EffectiveCooldown(card)}）");
        OnChanged?.Invoke();
        return true;
    }

    // ------------------------------------------------------------------
    // 开局默认装载（★2026-09-10 嗅盐）
    // ------------------------------------------------------------------

    /// <summary>
    /// 按配置的默认战术卡把牌库实例装进空槽。
    /// 调用方：<see cref="CardDeckManager.BuildRuntimeDeck"/>（开局 / 重开远征时一次）。
    ///
    /// 1. **失效重绑**：槽内 Card 实例若已不在 library（Library 重建后的幽灵引用）→ 清空该槽。
    ///    必要性：本类是静态类，跨场景重载存活，而 Library 由 Awake 重建。
    /// 2. **补默认**：按 defaults 顺序，跳过已在槽内的；在 library 里找第一个 Data 匹配
    ///    且未被占用的实例装入第一个空槽。
    /// 3. 战斗态跳过（不让默认装载在战斗中凭空补牌）。
    /// 4. **幂等**：已在槽内则跳过——玩家手动卸下后不会被再次自动装回。
    /// </summary>
    public static void ApplyDefaultLoadout(IReadOnlyList<Card> library, IReadOnlyList<CardData> defaults)
    {
        if (library == null) return;

        // ① 失效重绑：清掉指向已不在牌库里的卡（Library 重建 → 旧实例成幽灵引用）
        for (int i = 0; i < _slots.Count; i++)
        {
            Card held = _slots[i];
            if (held == null) continue;
            if (!LibraryContains(library, held))
            {
                Debug.Log($"[TacticSlotRuntime] 槽 {i + 1} 的 {held.Data?.cardName} 已不在牌库中，清空重绑");
                _slots[i] = null;
                _cooldowns[i] = 0;
            }
        }
        TrimTail();

        if (defaults == null || defaults.Count == 0) return;

        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            Debug.Log("[TacticSlotRuntime] 战斗中，跳过默认战术卡装载");
            return;
        }

        // ★2026-09-12 教程图：整套战术卡槽未解锁（按钮 / 面板 / 卡包边栏全隐藏）→
        //   跳过默认装载，否则「嗅盐」会被取进槽里、从抽牌堆消失，
        //   而玩家在教程里根本没有入口使用它（等于凭空少一张牌）。
        //   清空幽灵引用的第 ① 步已经在上面跑过，这里直接返回是安全的。
        if (MapLayoutBuilder.IsTutorial)
        {
            Debug.Log("[TacticSlotRuntime] 教程图：战术卡槽未解锁，跳过默认装载（卡牌全部留在牌库）");
            return;
        }

        bool changed = false;
        foreach (CardData data in defaults)
        {
            if (data == null) continue;

            // ② 已在槽内（同 CardData）→ 不重复装
            bool already = false;
            for (int i = 0; i < _slots.Count; i++)
            {
                if (_slots[i] != null && _slots[i].Data == data) { already = true; break; }
            }
            if (already) continue;

            int empty = FirstEmptyIndex();
            if (empty < 0) break;                        // 已达容量上限，剩下的默认卡无处可放

            Card found = FindUnslotted(library, data);
            if (found == null) continue;                 // 该卡不在本局牌库里（未配置进 initialDeckEntries）

            EnsureSize(empty + 1);
            _slots[empty] = found;
            _cooldowns[empty] = 0;
            // 开局就带在身上的装备不整备（否则玩家第一回合什么都干不了）
            _arming[empty] = 0;
            // 开局默认卡同样是槽内卡 → 不经过抽牌，这里补一次骰值分配（否则卡面是占位符）
            DicePayment.AssignCardDice(found, false);
            changed = true;
            Debug.Log($"[TacticSlotRuntime] 默认装载：槽 {empty + 1} ← {data.cardName}（开局自动）");
        }

        if (changed) OnChanged?.Invoke();
    }

    /// <summary>library 中是否存在该 Card 实例（引用相等）。</summary>
    private static bool LibraryContains(IReadOnlyList<Card> library, Card card)
    {
        for (int i = 0; i < library.Count; i++)
        {
            if (ReferenceEquals(library[i], card)) return true;
        }
        return false;
    }

    /// <summary>library 中第一个 Data 匹配、且尚未被任何槽占用的 Card 实例。</summary>
    private static Card FindUnslotted(IReadOnlyList<Card> library, CardData data)
    {
        for (int i = 0; i < library.Count; i++)
        {
            Card c = library[i];
            if (c == null || c.Data != data) continue;
            if (Contains(c)) continue;                  // 已被别的槽占用
            return c;
        }
        return null;
    }

    /// <summary>
    /// 卸下指定槽（卡留在牌库里，只是离开战术槽）。空槽 → false。
    /// ★不要在这里动卡牌的骰点：卸下 = 回牌库，玩家随时可能再装回来。
    ///   骰点会一直被保留到「这张卡被洗回抽牌堆（ResetForReshuffle）」或
    ///   「下一次回合刷新」为止 —— 这正是用户要的「拿出拿进随机数不变」。
    /// </summary>
    public static bool Unequip(int index)
    {
        if (!IsOccupied(index)) return false;

        // ★v9：冷却中的卡锁在槽里（见 CanUnequip 注释）。
        //   这条同时挡住事件弃牌鉴定 —— 正在冷却的卡取不出来，也就不会被塞进弃牌面板。
        if (_cooldowns[index] > 0)
        {
            Debug.Log($"[TacticSlotRuntime] 槽 {index + 1} 的 {_slots[index].Data?.cardName}"
                      + $" 冷却中（剩 {_cooldowns[index]}），无法卸下");
            return false;
        }

        Card card = _slots[index];
        _slots[index] = null;
        _cooldowns[index] = 0;
        _arming[index] = 0;
        TrimTail();                                     // 尾部的空槽收缩（中间空槽保留，序号不跳）
        Debug.Log($"[TacticSlotRuntime] 卸下：槽 {index + 1} → {card.Data.cardName}（回牌库）");
        OnChanged?.Invoke();
        return true;
    }

    /// <summary>按卡实例卸下（拖拽用）。</summary>
    public static bool Unequip(Card card)
    {
        return Unequip(IndexOf(card));
    }

    /// <summary>交换两槽（拖拽换格用）。任一槽越界/为空/同槽 → false。</summary>
    public static bool Swap(int a, int b)
    {
        if (a == b) return false;
        if (!InRange(a) || !InRange(b)) return false;
        if (_slots[a] == null || _slots[b] == null) return false;
        // ★v9：任一侧在冷却 → 不可换格（换格本质是卸下+装上，会洗掉冷却）
        if (_cooldowns[a] > 0 || _cooldowns[b] > 0) return false;

        Card ca = _slots[a];
        int cda = _cooldowns[a];
        _slots[a] = _slots[b];
        _cooldowns[a] = _cooldowns[b];
        _slots[b] = ca;
        _cooldowns[b] = cda;
        // 换过位置 = 重新安置 → 两格都要重新整备
        _arming[a] = EquipDelayTurns;
        _arming[b] = EquipDelayTurns;
        Debug.Log($"[TacticSlotRuntime] 换格：槽 {a + 1} ⇄ 槽 {b + 1}");
        OnChanged?.Invoke();
        return true;
    }

    // ------------------------------------------------------------------
    // 冷却
    // ------------------------------------------------------------------

    /// <summary>使用后立即进入冷却（TacticSlotsPanel 使用槽内卡时调用，Task 11）。</summary>
    public static void ApplyCooldown(int index)
    {
        Card card = Get(index);
        if (card == null) return;

        _cooldowns[index] = SlotCooldownOf(card);
        Debug.Log($"[TacticSlotRuntime] 槽 {index + 1} {card.Data.cardName} 进入冷却 {_cooldowns[index]} 回合");
        OnChanged?.Invoke();
    }

    /// <summary>
    /// 缩短 CD（不会降到负数；减到 0 即立即可用）。
    /// ★2026-09-10：面板上的「消耗 1 颗骰子缩短 1 点冷却」按钮已按用户要求删除，
    ///   本方法作为模型层原语保留（将来由遗物 / 道具 / 事件调用时不必重写）。
    /// </summary>
    public static void ShortenCooldown(int index, int amount)
    {
        if (!IsOccupied(index) || amount <= 0) return;

        int before = _cooldowns[index];
        _cooldowns[index] = Mathf.Max(0, before - amount);
        if (_cooldowns[index] != before)
        {
            Debug.Log($"[TacticSlotRuntime] 槽 {index + 1} CD {before} → {_cooldowns[index]}");
            OnChanged?.Invoke();
        }
    }

    /// <summary>回合结束递减全部 CD（TurnManager.EndPlayerTurn 调用，Task 11 接线）。</summary>
    public static void TickEndOfTurn()
    {
        bool changed = false;
        for (int i = 0; i < _slots.Count; i++)
        {
            if (_cooldowns[i] > 0)
            {
                _cooldowns[i]--;
                changed = true;
            }
            // ★v9：整备期与冷却共用同一个「回合末」tick
            if (i < _arming.Count && _arming[i] > 0)
            {
                _arming[i]--;
                changed = true;
            }
        }

        // ★2026-09-10 槽内卡「战术骰子每回合刷新」（用户定稿）。
        //   战斗回合末与探索回合末都走这个方法（TurnManager / ExplorationTurnManager 各调一次），
        //   所以两种状态下槽内卡都会在新回合看到新骰点。
        //   force=true —— 这正是「每回合刷新」与「拿出拿进不重掷」的分界线：
        //   回合刷新是设计给的，进出刷新是玩家想薅的，用一个开关把两者分开。
        DicePayment.RefreshSlotDice(true);

        if (changed) OnChanged?.Invoke();
    }

    /// <summary>当局结束清空（Task 23 生命周期收尾调用）：槽内卡实例回牌库。</summary>
    public static void ClearAll()
    {
        _slots.Clear();
        _cooldowns.Clear();
        _arming.Clear();
        OnChanged?.Invoke();
    }

    // ------------------------------------------------------------------
    // 容器内部
    // ------------------------------------------------------------------

    /// <summary>把容器扩到 n 长（中间补 null 空槽）；不缩容（缩短走 TrimTail）。</summary>
    private static void EnsureSize(int n)
    {
        if (n > HardLimit) n = HardLimit;
        while (_slots.Count < n)
        {
            _slots.Add(null);
            _cooldowns.Add(0);
            _arming.Add(0);
        }
    }

    /// <summary>裁掉尾部的空槽（中间空槽保留——槽序号是玩家的空间记忆）。</summary>
    private static void TrimTail()
    {
        while (_slots.Count > 0 && _slots[_slots.Count - 1] == null)
        {
            _slots.RemoveAt(_slots.Count - 1);
            _cooldowns.RemoveAt(_cooldowns.Count - 1);
            // ★v9：整备期列表与槽位同步收缩（三个列表长度必须始终一致）
            if (_arming.Count > 0) _arming.RemoveAt(_arming.Count - 1);
        }
    }

    private static bool InRange(int index)
    {
        return index >= 0 && index < _slots.Count;
    }

    // ============================================================================
    // ★2026-09-10 v8 —— 槽内卡骰值接缝、坐标取格、卸下卡（与牌库归属）、每回合刷新
    // ============================================================================

    /// <summary>
    /// 确保**指定一张**槽内卡已分配/补齐战斗骰子（解决占位符 [战斗骰子]1 显示）。
    /// 调 <see cref="DicePayment.AssignCardDice(card, force)"/>：
    ///   ① 装入战术槽后调用（force=false → 已有骰点保留）
    ///   ② 面板/卡包展开时调（兜底补漏）
    ///   ③ 每回合刷新（force=true → 强制重掷）
    /// </summary>
    public static void EnsureAssignedDiceForSlot(int index, bool force = false)
    {
        if (!InRange(index)) return;
        Card c = _slots[index];
        if (c == null || c.Data == null) return;
        DicePayment.AssignCardDice(c, force);
    }

    /// <summary>遍历**所有**槽内卡补齐/刷新骰值（每回合刷新、面板打开时兜底）。</summary>
    public static void EnsureAssignedDiceForAllSlots(bool force = false)
    {
        for (int i = 0; i < _slots.Count; i++)
        {
            if (_slots[i] == null) continue;
            EnsureAssignedDiceForSlot(i, force);
        }
    }

    /// <summary>
    /// ★v8 取槽格的世界坐标矩形（事件弹窗接弃牌面板用）：
    /// 槽内卡被指派进弃牌鉴定时，需要算出格子的「飞向哪」。
    /// 由 UI 层（TacticSlotsPanel / CardPackUI）实现取具体格子的 RectTransform。
    /// 这里只暴露 API 钩子；调用方先 SetCellTransformProvider 注入。
    /// </summary>
    private static System.Func<int, UnityEngine.RectTransform> _cellTransformProvider;

    public static void SetCellTransformProvider(System.Func<int, UnityEngine.RectTransform> provider)
    {
        _cellTransformProvider = provider;
    }

    public static UnityEngine.RectTransform GetSlotCardWorldRect(int index)
    {
        if (_cellTransformProvider == null) return null;
        return _cellTransformProvider(index);
    }

    /// <summary>
    /// 把指定槽位的卡从战术槽里**卸下并扔掉**（不进弃牌堆，因为事件弹窗里要的是「已经用掉」的语义）。
    /// 卸下即从 _slots 抹掉，冷却也清。
    /// </summary>
    public static bool RemoveCardAt(int index)
    {
        if (!InRange(index)) return false;
        Card c = _slots[index];
        if (c == null) return false;
        _slots[index] = null;
        _cooldowns[index] = 0;
        _arming[index] = 0;
        TrimTail();
        OnChanged?.Invoke();
        return true;
    }

    /// <summary>
    /// ★v8 每回合刷新：冷却 -1 + 槽内卡骰值强制重掷。
    /// 调时机：探索/战斗每回合结束 / 切换到对方回合。
    /// </summary>
    public static void OnTurnEnd()
    {
        // 1) 冷却 -1
        for (int i = 0; i < _cooldowns.Count; i++)
        {
            if (_cooldowns[i] > 0) _cooldowns[i]--;
        }
        // ★v9：整备期同步递减
        for (int i = 0; i < _arming.Count; i++)
        {
            if (_arming[i] > 0) _arming[i]--;
        }
        // 2) 槽内卡骰值重掷（force=true：每回合刷新）
        EnsureAssignedDiceForAllSlots(true);
        OnChanged?.Invoke();
    }

}

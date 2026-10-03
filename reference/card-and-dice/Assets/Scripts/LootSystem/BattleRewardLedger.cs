using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// ★2026-09-08 本场战斗的击杀账本（spec §9 战后结算的唯一数据源）。
/// 纯静态类：一场战斗 → 一次结算，用完即清（清理点见 <see cref="ClearAll"/>）。
/// 灵魂清单与「按小队独立判定」的卡牌奖励概率都在这里算，UI（Task 18/19）只读不写。
/// </summary>
public static class BattleRewardLedger
{
    /// <summary>一条待入魂灯的击杀灵魂（spec §9:94：每击杀一条，点击自动入魂灯）。</summary>
    public class SoulEntry
    {
        public ItemData soulItem;
        public string enemyName;
        /// <summary>已处理完（入灯成功，或灯满时在销毁选择里处理完）。跳过 = 未领取的直接作废。</summary>
        public bool claimed;
    }

    /// <summary>一支小队的击杀统计。散兵等价「1 人小队」（用自己的实例 ID 当 key）。</summary>
    public class SquadTally
    {
        public string squadName;
        public int kills;
        /// <summary>编制人数，取配置不取存活列表（见 <see cref="SquadSizeOf"/>）。</summary>
        public int squadSize;
        /// <summary>★2026-09-12 产出这张卡牌奖励的巡逻资产（掉落配置来源）；散兵/无巡逻 = null → 不产奖励。</summary>
        public SquadPatrolData sourcePatrol;
        public bool rolled;
        public bool granted;
    }

    static readonly List<SoulEntry> _souls = new List<SoulEntry>();
    static readonly Dictionary<int, SquadTally> _squads = new Dictionary<int, SquadTally>();
    /// <summary>★2026-09-12 封存：卡牌奖励改由 <see cref="_grantedCardItems"/> 承载（掷中即落背包物品），
    /// 本列表与 <see cref="CardRewards"/>/<see cref="ConsumeCardReward"/> 全程无写入方/调用方，按「封存旧流程」保留。</summary>
    static readonly List<SquadTally> _cardRewards = new List<SquadTally>();
    /// <summary>★2026-09-12 本场战斗掷出并已放进背包的「战利品卡牌物品」——汇报条据此列出可点条目。</summary>
    static readonly List<ItemData> _grantedCardItems = new List<ItemData>();
    static int _kills;

    public static IReadOnlyList<SoulEntry> Souls => _souls;

    /// <summary>本场已发出的卡牌奖励物品（汇报条点击 = 直接对它开三选一）。</summary>
    public static IReadOnlyList<ItemData> GrantedCardItems => _grantedCardItems;

    /// <summary>掷过之后待领取的卡牌奖励，每个条目 = 一次三选一。</summary>
    public static IReadOnlyList<SquadTally> CardRewards => _cardRewards;

    /// <summary>只读视图：结算窗口按小队显示「击杀 N/M」，L2 也靠它断言分母口径。</summary>
    public static IEnumerable<SquadTally> Squads => _squads.Values;

    public static int KillCount => _kills;

    /// <summary>spec §9:92「击杀 0 不弹」。</summary>
    public static bool HasPending => _kills > 0;

    public static int PendingSoulCount
    {
        get
        {
            int n = 0;
            foreach (SoulEntry e in _souls) if (e != null && !e.claimed) n++;
            return n;
        }
    }

    /// <summary>
    /// 敌人死亡时记账。调用点：<see cref="BattleResultHandler.HandleEnemyDied"/>（战斗态守卫之前）。
    /// </summary>
    public static void RecordKill(EnemyController enemy)
    {
        if (enemy == null || enemy.data == null) return;

        // ★2026-09-12 灵魂两条路互斥，别重复发：
        //   探索态击杀 → 走 CorpseSpawner（它调 SoulIntake 入灯），这里不记账
        //   （否则这笔要留到下一场战斗的汇报条才入灯 = 同一只怪发两个魂）。
        //   战斗态击杀 → 走本账本，击杀时即自动入灯（灯满则挂起）。
        // 判据用「死亡瞬间定格的状态」而不是现读：战斗最后一击的胜利结算会在同一次死亡事件链里
        // 先 SwitchToExploring，现读会漏掉这场战斗的最后一个人头（同时也是双魂根因的另一半）。
        if (enemy.StateAtDeath != GameState.Battle)
        {
            return;
        }

        _kills++;

        // ★2026-09-12 灵魂走成员配置三态（沿用预设/覆盖/关闭）；无巡逻配置 = 不产魂。
        ItemData soul = SquadDropConfig.ResolveSoul(SquadDropConfig.FindMember(enemy), enemy.data.soulItem);
        if (soul != null)
        {
            // ★2026-09-12 用户定稿：灵魂不再等玩家逐条点击 —— 击杀即自动入魂灯。
            //   灯满时 SoulIntake 会把它登记为「挂起」：战后汇报条把这条钉住不淡出，
            //   等玩家在魂灯界面处理（销毁灯内一条腾位 / 放弃这条）。
            bool claimed = SoulIntake.TryClaim(soul, enemy.data.enemyName);
            _souls.Add(new SoulEntry
            {
                soulItem = soul,
                enemyName = enemy.data.enemyName,
                claimed = claimed
            });
        }

        int key = SquadKeyOf(enemy);
        if (!_squads.TryGetValue(key, out SquadTally tally))
        {
            tally = new SquadTally
            {
                squadName = SquadNameOf(enemy),
                squadSize = SquadSizeOf(enemy),
                // ★2026-09-12：卡牌奖励的来源改为该小队的巡逻资产（掉落配置都在它身上）
                sourcePatrol = enemy.PatrolGroup != null ? enemy.PatrolGroup.SourcePatrol : null
            };
            _squads.Add(key, tally);
        }

        tally.kills++;
        // 兜底：SpawnResolver:260 会在「成员无预设」时跳过生成，实际到场数可能小于编制数。
        // 分子不许超过分母，否则把眼前能杀的全杀了也凑不到 p=1。
        if (tally.squadSize < tally.kills) tally.squadSize = tally.kills;
    }

    /// <summary>
    /// 掷卡牌奖励（spec §9:95）。**按小队独立判定**：两队交战至多产出两个条目。
    /// 完整击杀 = 100%；部分击杀 = 击杀数 / 编制人数。
    /// 调用点：Task 18 结算窗口打开时一次（`rolled` 守卫保证重复调用不会重掷）。
    /// </summary>
    public static void RollCardRewards()
    {
        foreach (SquadTally tally in _squads.Values)
        {
            if (tally.rolled) continue;
            tally.rolled = true;

            float p = tally.squadSize > 0 ? (float)tally.kills / tally.squadSize : 1f;
            if (p > 1f) p = 1f;
            tally.granted = p >= 1f || Random.value < p;

            Debug.Log($"[战利品账本] 小队「{tally.squadName}」击杀 {tally.kills}/{tally.squadSize} → " +
                      $"卡牌奖励概率 {p * 100f:0}% → {(tally.granted ? "获得" : "未获得")}");

            // ★2026-09-12 用户定稿：中奖不再当场开三选一，而是落成一个「卡牌物品」进背包，
            //   玩家之后在背包里点「使用」、或在汇报条上点那一条时才三选一。
            //   不按敌人侧是否为空过滤：候选 = 快照敌人侧 + 玩家牌库，一侧为空时全取另一侧。
            if (tally.granted) GrantCardRewardItem(tally);
        }
    }

    /// <summary>
    /// 把中奖的卡牌奖励落成背包物品。
    /// 物品用运行时实例（<see cref="ScriptableObject.CreateInstance"/>），因为它要**自带配置快照**
    /// （<see cref="ItemData.runtimeDropConfig"/>）——用物品时早已离开那场战斗。
    /// 实例归属：只在这里创建、**不在这里 Destroy**（否则「打赢一场 → 物品还没用 → 又进下一场战斗
    /// （BeginEncounter 会 ClearAll）」会把玩家的物品销毁）；随背包清（<c>InventoryManager.ClearForNewExpedition</c>）
    /// 一起被遗弃——本局对象每趟远征才产生少量几个，由 GC 在重载场景时收走。
    /// </summary>
    static void GrantCardRewardItem(SquadTally tally)
    {
        // 覆盖 → 继承：巡逻成员表非空用自己的，否则取小队模板的（与 FindMember/遗物袋同一口径）
        SquadDropConfig drop = SquadDropConfig.EffectiveConfig(tally.sourcePatrol);
        if (drop == null || drop.members == null || drop.members.Count == 0)
        {
            // 无巡逻（散兵、场景手摆怪）/ 无生效配置 → 不产卡牌奖励（design §9-6）
            Debug.LogWarning($"[战利品账本] 小队「{tally.squadName}」没有巡逻掉落配置 → 本次卡牌奖励作废");
            return;
        }

        // ★2026-09-12 用户定稿：三选一稀有度权重全 0 = 该小队不出卡牌奖励
        //（旧口径把全 0 当四档均匀 25%，玩家以为关掉了却照样掉「战利品卡牌」）。
        if (!SquadDropConfig.HasRarityWeight(drop))
        {
            Debug.Log($"[战利品账本] 小队「{tally.squadName}」三选一稀有度权重全为 0 → 不出卡牌奖励");
            return;
        }

        InventoryManager mgr = InventoryManager.Instance != null
            ? InventoryManager.Instance
            : Object.FindObjectOfType<InventoryManager>();
        if (mgr == null)
        {
            Debug.LogWarning("[战利品账本] 场景里没有 InventoryManager，卡牌奖励无处可放 → 本次作废");
            return;
        }

        ItemData item = ScriptableObject.CreateInstance<ItemData>();
        item.itemID = $"ITEM_CARDREWARD_{Time.frameCount}_{tally.GetHashCode()}";
        // ★2026-09-12 用户定稿：名字不带小队后缀（不分是谁掉的，不写「（哥布林）」）
        item.itemName = "战利品卡牌";
        item.description = "在背包里点「使用」（或点战后弹窗上那一条），选一张卡加入本局牌库。";
        item.type = ItemType.卡牌;
        item.stackLimit = 1;                                  // 每张各占一格（各自带配置快照）

        // 快照取「编制全体成员」（含未击杀成员，design §9-5）：按 squad.units 数裁剪成员块
        int limit = tally.sourcePatrol.squad != null && tally.sourcePatrol.squad.units != null
            ? tally.sourcePatrol.squad.units.Count
            : -1;
        item.runtimeDropConfig = SquadDropConfig.CloneForSnapshot(drop, limit);

        mgr.AddItem(item, 1, out int added);
        if (added > 0)
        {
            _grantedCardItems.Add(item);          // 战后操作弹窗据此列「点击使用」条目
            Debug.Log($"[战利品账本] 小队「{tally.squadName}」的卡牌奖励 → 背包物品「{item.itemName}」" +
                      $"（快照成员 {item.runtimeDropConfig.members.Count} 名）");
        }
        else
        {
            Debug.LogWarning("[战利品账本] 背包放不下卡牌奖励物品 → 本次作废");
            if (Application.isPlaying) Object.Destroy(item);
            else Object.DestroyImmediate(item);   // L2 编辑态探针可直接跑掷奖，避免 Destroy 报错
        }
    }

    /// <summary>灵魂处理完毕（入灯成功 / 灯满销毁选择走完）后由 UI 标记。</summary>
    public static void MarkSoulClaimed(SoulEntry entry)
    {
        if (entry == null) return;
        entry.claimed = true;
    }

    /// <summary>一次三选一做完（选中或放弃）后移除该条目。</summary>
    public static void ConsumeCardReward(int index)
    {
        if (index < 0 || index >= _cardRewards.Count) return;
        _cardRewards.RemoveAt(index);
    }

    /// <summary>
    /// 清空账本。三个调用点各管一件事，缺一不可：
    ///   ① <see cref="BattleResultHandler.BeginEncounter"/> —— 每场战斗从空账本起算；
    ///   ② Task 18 结算窗口关闭（含「跳过」）—— 未领取的直接作废（spec §9:97）；
    ///   ③ Task 23 ExpeditionLifecycle.EndExpedition —— ResolveDefeat:246-253 直接重载场景，
    ///      静态字段不被重置，当局结束必须显式清。
    /// </summary>
    public static void ClearAll()
    {
        _souls.Clear();
        _squads.Clear();
        _cardRewards.Clear();
        _grantedCardItems.Clear();
        _kills = 0;
    }

    /// <summary>
    /// 小队 key。散兵没有 PatrolGroup → 用自己，等价 1 人小队（杀了就是 1/1 = 100%）。
    /// 用 GetInstanceID() 而不是对象引用：UnityEngine.Object 重写了 Equals，
    /// 两个已销毁对象会互相判等，拿它当字典 key 会跨战斗串账；实例 ID 销毁后依然稳定。
    /// </summary>
    static int SquadKeyOf(EnemyController enemy)
    {
        return enemy.PatrolGroup != null ? enemy.PatrolGroup.GetInstanceID() : enemy.GetInstanceID();
    }

    /// <summary>
    /// 分母 = 编制人数，取配置 <see cref="EnemySquadData.units"/>。
    /// ★不能用 group.Members.Count：SquadPatrolGroup.PruneDead():847-857 会把已死成员 RemoveAt，
    ///   而 ExecutePatrolTurn:547 / BeginReturnRoute:190 都会调它；SpawnResolver:260 也会跳过无预设成员。
    ///   分母一缩，spec §9:95 的概率就不是设计里的那个了。
    /// </summary>
    static int SquadSizeOf(EnemyController enemy)
    {
        SquadPatrolGroup group = enemy.PatrolGroup;
        if (group == null) return 1;
        if (group.Source != null && group.Source.units != null && group.Source.units.Count > 0)
            return group.Source.units.Count;
        return Mathf.Max(1, group.Members.Count);
    }

    static string SquadNameOf(EnemyController enemy)
    {
        SquadPatrolGroup group = enemy.PatrolGroup;
        if (group != null && group.Source != null && !string.IsNullOrEmpty(group.Source.squadName))
            return group.Source.squadName;
        return enemy.data != null ? enemy.data.enemyName : "未知小队";
    }
}

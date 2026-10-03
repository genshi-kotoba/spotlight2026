// =============================================================================
// 模块：M7 战斗结算 BattleResultHandler
// 用途：参战名单、击杀掉落、清场胜利回探索、玩家死亡重载场景
// 设计依据：《设计增补_探索系统_v2.md》§9.3；《项目现状与后续规划.md》Sprint 1
// 挂载：MainScene SetUp/GameManager
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.SceneManagement;
using System.Collections;

/// <summary>
/// 战斗结算入口。进战登记参战敌人；全灭则 D5 洗回由探索回合启动完成，本类只切回 Exploring。
/// </summary>
public class BattleResultHandler : MonoBehaviour
{
    public static BattleResultHandler Instance { get; private set; }

    /// <summary>战斗胜利结算事件（教学 T8 触发用，零侵入钩子）。</summary>
    public static event System.Action OnBattleVictory;

    private readonly HashSet<EnemyController> _participants = new HashSet<EnemyController>();
    private readonly HashSet<int> _encounterSquadIds = new HashSet<int>();
    private bool _resolving;

    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(this);
            return;
        }
        Instance = this;
    }

    private void OnEnable()
    {
        EnemyController.EnemyDied += HandleEnemyDied;
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged += HandleGameStateChanged;
        }
    }

    private void Start()
    {
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged -= HandleGameStateChanged;
            GameStateManager.Instance.OnStateChanged += HandleGameStateChanged;
        }

        // 调试启动即战斗：没有探索进战登记时，把场上存活敌人当作本场参战者
        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState == GameState.Battle
            && _participants.Count == 0)
        {
            BeginEncounterFromCurrentField();
        }
    }

    private void OnDisable()
    {
        EnemyController.EnemyDied -= HandleEnemyDied;
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged -= HandleGameStateChanged;
        }
    }

    private void HandleGameStateChanged(GameState oldState, GameState newState)
    {
        if (newState == GameState.Exploring)
        {
            _participants.Clear();
            _encounterSquadIds.Clear();
            _resolving = false;
        }
    }

    private void OnDestroy()
    {
        if (Instance == this) Instance = null;
    }

    /// <summary>
    /// 进战登记：只收当前感叹号种子（同队问号延后入场，不在此时扩编整队）。
    /// 无种子时回退为场上全部合法存活敌人（调试启动即战斗）。
    /// </summary>
    public int BeginEncounter(IEnumerable<EnemyController> seeds)
    {
        _participants.Clear();
        _encounterSquadIds.Clear();
        _resolving = false;
        BattleRewardLedger.ClearAll();      // 每场战斗从空账本起算（另两个清理点见 BattleRewardLedger.ClearAll 注释）

        bool explicitSeeds = seeds != null;
        if (explicitSeeds)
        {
            foreach (EnemyController seed in seeds)
            {
                if (seed == null) continue;
                if (seed.SquadId >= 0) _encounterSquadIds.Add(seed.SquadId);
                if (IsEligibleCombatant(seed)) _participants.Add(seed);
            }
        }
        else
        {
            foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
            {
                if (IsEligibleCombatant(enemy)) _participants.Add(enemy);
            }
        }

        Debug.Log($"[结算] 本场参战 {_participants.Count} 名敌人（问号同队不在此刻入场）");
        return _participants.Count;
    }

    public bool IsParticipant(EnemyController enemy)
    {
        return enemy != null && _participants.Contains(enemy);
    }

    public void AddParticipant(EnemyController enemy)
    {
        if (!IsEligibleCombatant(enemy)) return;
        if (_participants.Add(enemy))
        {
            Debug.Log($"[结算] 同队补召入场：{enemy.gameObject.name}，参战 {_participants.Count}");
        }
    }

    /// <summary>
    /// ★2026-09-14 战斗中补召整队（§8：非参战小队看见玩家 → 整队参战）。
    /// 与 <see cref="BeginEncounter"/> 的关键差别：**不清参战名单、不清奖励账本**，只登记小队号 + 逐个补入。
    /// 修因：§8 入口原先调 <see cref="BeginEncounter"/>，会把正在交战的参战者整份挤出名单
    /// （战斗中已参战的怪随即掉回问号 / 红`!`，用户实测症状），并把本场奖励账本清零。
    /// </summary>
    public void JoinEncounterSquad(IEnumerable<EnemyController> members)
    {
        if (members == null) return;
        foreach (EnemyController m in members)
        {
            if (m == null) continue;
            if (m.SquadId >= 0) _encounterSquadIds.Add(m.SquadId);
            AddParticipant(m);
        }
    }

    public bool HasPendingSameSquad()
    {
        foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
        {
            if (!IsEligibleCombatant(enemy)) continue;
            if (_participants.Contains(enemy)) continue;
            if (enemy.SquadId < 0 || !_encounterSquadIds.Contains(enemy.SquadId)) continue;
            if (!enemy.IsCurious && !enemy.PromoteToAlertNextTurn && !enemy.IsAlerted) continue;
            return true;
        }
        return false;
    }

    /// <summary>无种子时登记场上全部合法存活敌人（调试启动即战斗）。</summary>
    public void BeginEncounterFromCurrentField()
    {
        BeginEncounter(null);
    }

    /// <summary>玩家死亡：Demo 重载当前场景。</summary>
    public void NotifyPlayerDied()
    {
        if (_resolving) return;
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            // 探索态死亡同样重开当局（鉴定扣血等）
        }
        ResolveDefeat();
    }

    /// <summary>敌人回合结束后的兜底：参战者已全灭则胜利。</summary>
    public bool TryResolveVictoryIfCleared()
    {
        if (!AllParticipantsDefeated()) return false;
        ResolveVictory();
        return true;
    }

    private void HandleEnemyDied(EnemyController enemy)
    {
        if (enemy == null) return;

        // 记账在战斗态守卫之前：守卫只该挡胜负判定，不该顺带挡掉击杀记录（要点 2）。
        BattleRewardLedger.RecordKill(enemy);

        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            return;
        }

        if (AllParticipantsDefeated())
        {
            ResolveVictory();
        }
    }

    private bool AllParticipantsDefeated()
    {
        if (_participants.Count == 0) return false;
        foreach (EnemyController enemy in _participants)
        {
            if (enemy != null && !enemy.IsDead) return false;
        }
        // 同队问号还没入场：先不当胜利，留给补召或脱战
        if (HasPendingSameSquad()) return false;
        return true;
    }

    private static bool IsEligibleCombatant(EnemyController enemy)
    {
        if (enemy == null || enemy.IsDead || enemy.data == null) return false;
        // 未绑格（地图外残留）不参战，避免挡住清场
        if (enemy.CurrentCoord.x < 0 || enemy.CurrentCoord.y < 0) return false;
        return true;
    }

    private void ResolveVictory()
    {
        if (_resolving) return;
        _resolving = true;

        OnBattleVictory?.Invoke(); // ★教学 T8：战斗胜利结算

        InventoryManager inv = InventoryManager.Instance;
        string bag = inv != null
            ? $"材料 {inv.MaterialCount} / 魂灯 {inv.Inventory.Lantern.Count}/{SoulLantern.Capacity}"
            : "—";
        Debug.Log($"[结算] 胜利：参战敌人全灭，回探索。背包 {bag}");

        _participants.Clear();

        // 先置位再切状态：同步触发的 OnStateChanged（BattleSettlementUI 适配器）看到它就不会重复弹
        BattleSettlementUI.VictoryReportScheduled = true;

        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            GameStateManager.Instance.SwitchToExploring();
        }

        // ★临时强化「战后即耗」（design §2 共同规则）：胜利 / 撤退都算消耗
        TempBuffRuntime.OnBattleEnd();

        // ★2026-09-12 战后反馈统一为「右下角从下往上堆叠列表」（LootClaimPopupUI）：
        //   魂灯已满→卡牌奖励→魂灯未满→材料 四条按序堆叠。
        //   延时 0.25s：等最后一击的特效/敌人消散先演完再弹（用户定稿「延后出现时机」）。
        StartCoroutine(DelayedVictoryReport());
    }

    IEnumerator DelayedVictoryReport()
    {
        yield return new WaitForSeconds(0.25f);
        LootClaimPopupUI.ShowAfterVictory();
    }

    private void ResolveDefeat()
    {
        if (_resolving) return;
        _resolving = true;
        Debug.Log("[结算] 失败：玩家死亡，回藏身处（材料丢尸 + 保留一半灵魂）");

        // 取数必须在 EndExpedition 之前（EndExpedition 会清空背包/遗物袋/交互锁）。
        Vector2Int coord = GetPlayerCoord();
        var materials = new List<MetaWallet.NamedStack>();
        if (InventoryManager.Instance != null)
            materials = MetaWallet.AggregateStacks(
                InventoryManager.Instance.Inventory.SlotsOfType(ItemType.材料));
        List<ItemData> keptSouls = KeptHalfSouls();   // 保留一半（向上取整），另一半丢失

        // 材料（按种类）丢进尸体（下次出击回收），保留一半灵魂入账（★2026-09-14 灵魂按种类入账）
        MetaWallet.RecordDeath(coord, materials, keptSouls);

        TempBuffRuntime.OnBattleEnd();   // ★临时强化「战后即耗」：败北分支同样消耗（阵亡后本局就结束了）

        ExpeditionLifecycle.EndExpedition("玩家死亡");   // 必须在 LoadScene 之前（静态清理器依赖存活的订阅者）
        SceneManager.LoadScene(MetaWallet.HIDEOUT_SCENE);
    }

    /// <summary>玩家当前格坐标（死亡时记录，用于尸体回收定位）。</summary>
    private static Vector2Int GetPlayerCoord()
    {
        HexMover mover = FindObjectOfType<HexMover>();
        return mover != null ? mover.CurrentCoord : new Vector2Int(-1, -1);
    }

    /// <summary>
    /// 魂灯内灵魂保留一半（按条数向上取整，取前 N 条），用于死亡入账。
    /// ★2026-09-14：灵魂改为按种类存储 → 传「保留的那些灵魂本体」而不是一个整数。
    /// </summary>
    private static List<ItemData> KeptHalfSouls()
    {
        var kept = new List<ItemData>();
        if (InventoryManager.Instance == null) return kept;
        List<ItemData> souls = InventoryManager.Instance.Inventory.Lantern.Souls;
        int keep = Mathf.CeilToInt(souls.Count / 2f);
        for (int i = 0; i < keep && i < souls.Count; i++) kept.Add(souls[i]);
        return kept;
    }
}

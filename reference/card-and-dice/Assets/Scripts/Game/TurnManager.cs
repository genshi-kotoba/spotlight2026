using UnityEngine;
using UnityEngine.UI;

public class TurnManager : MonoBehaviour
{
    public static TurnManager Instance;
    
    /// <summary>战斗玩家回合开始事件（意图揭示后触发；教学 Director 等可订阅）。</summary>
    public event System.Action OnPlayerTurnStarted;

    [Header("UI References")]
    public Button endTurnButton;
    
    [Header("Game Settings")]
    // F2.1 探索骰子获取：Demo 基础 4 枚/回合（★用户 2026-08-17：场景已加 Dice6Button4）。
    // 第 5 枚计划通过自定义被动或局外永久升级获得（成长系统接入时改此值或加被动加成）。
    public int baseDicePerTurn = 4;
    public int baseActionPointsPerTurn = 6;

    [Tooltip("战斗回合基础行动点（★用户 2026-09-05：与探索一致的基础值 2，+敏捷加值；骰→AP 补足）")]
    public int battleBaseActionPoints = 2;

    [Tooltip("战斗态每回合耗骰换行动点上限（★用户 2026-09-08：与探索态一致，最多 2 枚）")]
    public int battleDiceAPCapPerTurn = 2;

    // （2026-09-13 定稿：原 D11 pendingEnemyFirstAPBonus 字段已删——能量超3→行动点
    //  改为每个回合开始通用结算，见 StartNewTurn；不再需要进战时暂存。）

    // 游戏状态
    private int currentTurn = 0;
    private bool isPlayerTurn = true;
    private int playerDiceCount = 0;
    private int battleDiceToAPUsedThisTurn = 0; // 本回合已耗骰换行动点的枚数（上限 battleDiceAPCapPerTurn）
    private HexMover playerMover;
    private bool isEndTurnRequested = false; // 表示是否在移动过程中请求结束回合
    private bool _battleDeckInitialized = false; // 是否为当前战斗已初始化抽牌堆
    private bool _enemyTurnActive = false; // M6-5 敌人回合互斥锁：防止重复进入敌人回合
    
    private void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
        }
        else
        {
            Destroy(gameObject);
        }
    }

    // 订阅/退订游戏模式切换，用于在进入战斗时初始化抽牌堆
    // 注意：用 Start() 订阅而非 OnEnable()，确保 GameStateManager.Awake() 已执行完（Instance 已就绪），
    // 避免脚本执行顺序导致订阅失败（OnEnable 可能早于 GameStateManager.Awake）。
    private void StartTurnSubscription()
    {
        if (GameStateManager.Instance != null)
            GameStateManager.Instance.OnStateChanged += HandleGameStateChanged;
    }

    private void OnDisable()
    {
        if (GameStateManager.Instance != null)
            GameStateManager.Instance.OnStateChanged -= HandleGameStateChanged;
    }

    /// <summary>
    /// 响应游戏模式切换。
    /// 进入战斗：初始化抽牌堆（仅每场战斗一次）+ 抽首回合 5 张。
    /// 离开战斗：重置标记，使下一场战斗能重新初始化。
    /// </summary>
    private void HandleGameStateChanged(GameState oldState, GameState newState)
    {
        if (newState == GameState.Battle && !_battleDeckInitialized)
        {
            _battleDeckInitialized = true;

            if (CardPileManager.Instance != null && CardDeckManager.Instance != null)
            {
                // 用玩家牌组初始化抽牌堆并洗牌（标准杀戮尖塔：抽牌堆空时弃牌堆洗回）
                CardPileManager.Instance.InitDrawPileFromDeck(CardDeckManager.Instance.GetPlayableDeck());

                // F2.1 战斗首回合抽 5 张。
                // ★2026-08-19 恢复自动抽牌（用户需求）：手牌非空说明 StartNewTurn 已抽过
                // （启动即战斗的场景），此处跳过防止首回合双抽。
                if (CardPileManager.Instance.Hand.Count == 0)
                {
                    CardPileManager.Instance.DrawCards(5);
                }

                if (HandUIController.Instance != null)
                    HandUIController.Instance.RefreshHandLayout();
            }
        }
        else if (newState == GameState.Exploring)
        {
            // 离开战斗回到探索，重置标记以便下一场战斗重新初始化
            _battleDeckInitialized = false;
        }
    }

    // 缓存DiceArea对象
    private GameObject diceArea;
    
    private void Start()
    {
        // 订阅游戏模式切换（放在 Start 而非 OnEnable，确保 GameStateManager.Instance 已就绪）
        StartTurnSubscription();

        // 查找结束回合按钮
        GameObject endTurnButtonObj = GameObject.Find("UICanvas/EndTurnButton");
        if (endTurnButtonObj != null)
        {
            endTurnButton = endTurnButtonObj.GetComponent<Button>();
            if (endTurnButton != null)
            {
                endTurnButton.onClick.AddListener(EndPlayerTurn);
            }
            else
            {
                Debug.LogError("EndTurnButton GameObject found but no Button component attached");
            }
        }
        else
        {
            Debug.LogError("EndTurnButton not found");
        }
        
        // 缓存DiceArea对象
        diceArea = GameObject.Find("UICanvas/StatusBar/DiceArea");
        
        // 查找玩家移动脚本
        playerMover = FindObjectOfType<HexMover>();
        if (playerMover == null)
        {
            Debug.LogError("HexMover not found");
        }
        
        // 初始化回合
        StartNewTurn();
    }
    
    /// <summary>
    /// 开始新回合
    /// ★探索系统第一步（2026-08-25）：本管理器战斗回合专职化——仅 Battle 态执行，
    /// Exploring 态的回合循环由 ExplorationTurnManager 负责（共听 EndTurnButton 各自守卫）
    /// </summary>
    /// <param name="preservePlayerArmor">
    /// ★2026-09-14：true = 本回合不清玩家护甲。仅用于「探索 → 战斗的第一回合」
    /// （用户定稿：探索期打出的防御要能带进战斗第一回合继续挡；之后每回合照常清）。
    /// </param>
    public void StartNewTurn(bool preservePlayerArmor = false)
    {
        // 战斗态守卫：非 Battle 态不启动战斗回合（抽牌/意图揭示/AP 授予均不执行）
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            return;
        }

        // ★2026-09-14 护甲清零时机修正（用户定稿：谁的回合开始清谁的护甲）：
        //   玩家回合开始 → 清玩家护甲。这样玩家打出的防御能完整覆盖接下来的敌人回合；
        //   旧实现在「玩家回合结束（=敌人回合开头）」统一清零，护甲在第 0 步就被抹掉，
        //   玩家的防御永远挡不住敌人（用户实测「回合结束防御就没了」）。
        //   敌人一侧对称地在 EnemyTurn 开头清（见 EnemyTurn）。口径详见 ArmorEffect 类注释。
        //   ★唯一例外：探索→战斗的第一回合不清（preservePlayerArmor），探索期的甲带进来；
        //     探索态自身则在「探索回合开始」清（ExplorationTurnManager.StartNewExplorationTurn）。
        if (!preservePlayerArmor)
        {
            EffectManager.ClearPlayerArmor();
        }

        currentTurn++;
        isPlayerTurn = true;
        playerDiceCount = baseDicePerTurn;
        battleDiceToAPUsedThisTurn = 0; // 骰→AP 每回合重新计数
        isEndTurnRequested = false; // 重置结束回合请求标志
        
        // ★2026-09-05 战斗/探索移动区分（F3.2 战斗移动 = 3 + 敏捷加值，不投骰）：
        // 战斗回合开始直接授予固定行动点；骰子→AP 转换每回合上限 battleDiceAPCapPerTurn 枚
        //（★2026-09-08 用户定稿：与探索态一致，最多 2 枚——原「不限次逃跑支援」取消）。
        if (playerMover != null)
        {
            int agilityBonus = CharacterStats.敏捷 / CharacterStats.AgiMoveDivisor;
            playerMover.currentActionPoints = battleBaseActionPoints + agilityBonus + RunModifiers.MoveRangeBonus;

            // ★v3.1 通用规则（用户 2026-09-13 定稿）：每个战斗回合开始，能量超过 3 的部分
            //    1:1 追加为行动点，能量压回 3（取代原 D11「仅被动进战结算一次」；上限 9 由能量侧保证）
            EnergyPointDisplay energyAtTurnStart = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存
            if (energyAtTurnStart != null)
            {
                int excess = energyAtTurnStart.CurrentEnergy - 3;
                if (excess > 0)
                {
                    energyAtTurnStart.SetEnergy(3);
                    playerMover.currentActionPoints += excess;
                    Debug.Log($"[战斗] 回合开始能量转化：能量压回 3，+{excess} 行动点");
                }
            }

            playerMover.maxActionPoints = 999; // 战斗 AP 无硬顶（骰→AP 已限 battleDiceAPCapPerTurn 枚/回合）
        }
        
        // 重新激活所有骰子按钮，补满骰池
        ActivateDiceButtons();
        
        // 重置能量点显示的整备状态
        EnergyPointDisplay energyDisplay = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存
        if (energyDisplay != null)
        {
            energyDisplay.ResetPrepareStatus();
        }
        
        Debug.Log($"回合 {currentTurn} 开始：战斗 AP {playerMover.currentActionPoints}（F3.2 基础{battleBaseActionPoints}+敏加值+整装{RunModifiers.MoveRangeBonus}）+ 骰子 {playerDiceCount} 枚（骰→AP 上限 {battleDiceAPCapPerTurn} 枚）");
        
        // 启用结束回合按钮
        if (endTurnButton != null)
        {
            endTurnButton.interactable = true;
        }
        Interactions.RefreshEndTurnButton();

        // ===== M5a: 战斗模式回合开始抽牌 =====
        // F2.1 战斗每回合抽 5 张（★2026-08-19 恢复自动抽牌，用户需求）。
        // 回合结束已 DiscardAllHand 弃掉全部手牌，这里固定抽 5 张。
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            if (CardPileManager.Instance != null && CardDeckManager.Instance != null)
            {
                // 兜底：若抽牌堆尚未初始化（启动即战斗 / HandleGameStateChanged 未触发），先初始化
                if (!_battleDeckInitialized)
                {
                    _battleDeckInitialized = true;
                    CardPileManager.Instance.InitDrawPileFromDeck(CardDeckManager.Instance.GetPlayableDeck());
                }

                // ★「有数」（design §2.2）：下场战斗第 1 回合起始手牌 +1
                int handSize = 5 + TempBuffRuntime.HandSizeBonusForTurn(currentTurn);
                CardPileManager.Instance.DrawCards(handSize); // F2.1 战斗每回合抽 5 张
            }
            if (HandUIController.Instance != null)
            {
                HandUIController.Instance.RefreshHandLayout();
            }

            // ===== M6-4（2026-08-19）：玩家回合开始 → 揭示所有存活敌人的下回合意图 =====
            // 设计依据：v2 §3.3 —— 玩家回合开始投所有小意图骰子，数值锁死，全程可见可预判。
            RevealAllEnemyIntents();

            OnPlayerTurnStarted?.Invoke();
        }
    }

    /// <summary>
    /// 揭示所有存活敌人的下回合意图（掷骰锁死各小意图数值）。
    /// 设计依据：v2 §3.3「意图可见性黄金法则」。
    /// ★意图显示节奏（2026-08-21 用户确认）：敌人开始移动后指引隐藏，
    /// 到这里（下个玩家回合开始）全量重投才亮出新指引——新数值新虚线。
    /// 全量投骰会把上一回合已展示的数值重投，属设计预期（每回合开始投下回合意图）。
    /// </summary>
    private void RevealAllEnemyIntents()
    {
        // ★2026-09-16 性能二批补：战斗侧分段计时——本段含一次全场景 `FindObjectsOfType<EnemyController>()`
        //   ＋ 给每个参战者投骰锁值，是「怪物一多就卡」的主嫌疑之一（每战斗回合开始都跑）。
        System.Diagnostics.Stopwatch revealWatch = ExplorationPerf.StartBoundaryTimer();

        // ★2026-08-23 保险：玩家回合开始强制解除执行锁。锁本应只在敌人回合执行期间存在；
        // 若上回合执行被中断（UnlockExecution 未执行）导致锁残留，会让预览误返回冻结的过期计划。
        EnemyLandingPlanner.UnlockExecution();

        EnemyController[] enemies = FindObjectsOfType<EnemyController>();
        foreach (EnemyController enemy in enemies)
        {
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;

            // ★2026-09-10：意图揭示只针对「参战者」。非参战敌人（其他小队 / 旁观者）不展示战斗意图
            //   （设计增补_威胁预告与搜索 §8：未参战小队除非在附近目击战斗否则无任何意图、继续巡逻）。
            //   此前对所有敌人 RevealIntent 会导致全图敌人都冒出「追击」等战斗意图徽章。
            if (BattleResultHandler.Instance != null && !BattleResultHandler.Instance.IsParticipant(enemy))
            {
                continue;
            }

            // ★P1：玩家回合开始恢复敌人行动点（原本在敌人回合开始 EnemyTurnExecutor 里恢复，
            // 会把断筋的「减行动点」在敌人移动前抹掉 → 预览(减AP后)与执行(满AP)不一致）。
            // 移到玩家回合开始：断筋减 AP 效果持续到敌人本回合，下回合自动恢复。
            enemy.RestoreActionPoints();

            // ★2026-09-08 传导进战（§4/§5 两段式）：黄`?`/白`?`被视野连锁传导成红`!`者，
            // 上一敌人回合已原地冻结 → 现在从冻结处续接战斗意图（§11 不重掷）。
            // 必须放在 AdvanceDisengagePhase 之前：先清 SearchPhase，杜绝被传导当回合误推进/误回血。
            // 只晋升参战者：非参战的陷阱搜索队（同队连锁也可能红`!`）由 TryDisengageAfterEnemyTurn 整队参战接管。
            if (enemy.SearchPhase != EnemyController.DisengagePhase.None && enemy.IsAlerted
                && AlertPropagation.IsFighting(enemy))
            {
                enemy.EnterCombatDisplay();
                continue; // 冻结意图刚续上，本回合不参与全量重投（下个玩家回合照常重投）
            }

            // ★脱战六回合流程（威胁预告与搜索 §3）：上一回合问号阶段的移动已走完 → 推进阶段。
            //   黄`?`搜索 → 白`?`归队（回已损 75%）；白`?`归队 → 白`?`回巡逻（回剩余 25%）；
            //   白`?`回巡逻 → 复原（疾跑清零 + 意图重置 + 偷袭资格恢复）。
            enemy.AdvanceDisengagePhase();

            // ★黄`?`/白`?`期间意图循环暂停（§11）：不揭示新意图、不重掷骰，
            //   重新进战时由 ReEngageFromSearch 从冻结处续接。
            if (enemy.SearchPhase != EnemyController.DisengagePhase.None) continue;

            // ★被动遇袭发现者（§5 / §10.2）：展现战斗意图的同时直接获得疾跑 1。
            //   只有探索态敌人回合「移动落点看见玩家」的那一只被标记过；
            //   同队经传导警戒者没有标记 → 不额外获得。
            enemy.ConsumeSurpriseSprint();

            enemy.RevealIntent();
        }

        // ★P1：玩家回合开始强制重算一次全场计划（绕过签名缓存），确保常显预览
        // 一开始就是「敌人回合会执行的同一份计划」——修复「玩家回合预览 dumb / 敌人回合 smart」不一致。
        if (playerMover != null)
        {
            // ★2026-08-23 保险：清掉可能残留的移动锁/落点锁定值（中断移动），
            // 保证本回合的预览以玩家真实 CurrentCoord 为准（与执行器同源）。
            playerMover.ForceResetMoveForTurnStart();
            EnemyLandingPlanner.GetOrderedPlan(playerMover.CurrentCoord, forceRefresh: true);
        }

        ExplorationPerf.EndBoundaryScope(revealWatch, "战斗·意图揭示段");
    }
    
    /// <summary>
    /// 结束玩家回合
    /// ★探索系统第一步（2026-08-25）：仅 Battle 态生效；Exploring 态的结束回合
    /// 由 ExplorationTurnManager.EndExplorationTurn 处理（两管理器共听同一按钮）
    /// </summary>
    public void EndPlayerTurn()
    {
        // 战斗态守卫：非 Battle 态不执行战斗结束流程（弃牌/清骰池/敌人回合）
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            return;
        }
        if (!isPlayerTurn || _enemyTurnActive)
        {
            return;
        }

        // ★S12 战术卡槽（spec §5）：战斗回合末所有槽 CD −1。
        //   位置在两个守卫之后 → 非战斗态 / 敌人回合不会误 tick；
        //   OnMoveEnded 的延迟结束分支不重入本方法（TurnManager.cs:341-365）→ 无二次 tick。
        TacticSlotRuntime.TickEndOfTurn();

        // ===== M5a: 战斗模式结束回合弃牌 =====
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.DiscardAllHand();
        }
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.ClearSelection();
        }

        // ★2026-09-10 战斗回合结束：剩余探索骰子 1:1 转能量（与探索模式一致）。
        //   必须放在清空骰池之前——此时骰子按钮仍激活且可交互，RemainingExplorationDice 才能数到剩余。
        //   ★2026-09-14 修正：上限由写死的 3 改为 ExplorationTurnManager 的 `diceToEnergyCapPerTurn`
        //   （2026-09-14 定稿 = 9 = 能量上限）。旧的写死 3 会把「超 3 的部分」全部丢掉 →
        //   回合开始结算的能量超 3 → AP 永远拿不到（用户实测：多余骰子既没变能量也没变行动点）。
        if (ExplorationTurnManager.Instance != null)
        {
            ExplorationTurnManager.Instance.ConvertLeftoverExplorationDiceToEnergy(
                ExplorationTurnManager.Instance.DiceToEnergyCapPerTurn);
        }

        // 立即清空骰池，隐藏所有骰子按钮
        ClearDicePool();

        isPlayerTurn = false;
        Interactions.RefreshEndTurnButton();

        // 检查玩家是否正在移动
        if (playerMover != null && playerMover.IsMoving())
        {
            isEndTurnRequested = true;
            Debug.Log("结束回合请求已记录，将在移动结束后执行");
            return;
        }

        Debug.Log("玩家回合结束");
        if (playerMover != null)
        {
            playerMover.currentActionPoints = 0;
        }
        StartCoroutine(EnemyTurn());
    }
    
    /// <summary>
    /// 处理移动结束后的逻辑
    /// </summary>
    public void OnMoveEnded()
    {
        // ★2026-09-08 用户实测：黄`?`/白`?`（战斗态）期间玩家主动走进视野 → 立即战斗意图（§4「立即」）。
        // 探索态白`?`回巡逻的进视野由探索侧警戒检测处理
        //（ExplorationTurnManager.CheckAlertAtLanding → 红`!` → 回合末三结局）。
        CheckQuestionPhaseWalkIn();

        // 检查是否有结束回合请求
        if (isEndTurnRequested)
        {
            isEndTurnRequested = false;
            Debug.Log("移动结束，执行结束回合");
            
            // 清空玩家剩余行动点
            if (playerMover != null)
            {
                playerMover.currentActionPoints = 0;
            }
            
            // 进入敌人回合
            isPlayerTurn = false;
            Interactions.RefreshEndTurnButton();
            StartCoroutine(EnemyTurn());
        }
    }

    /// <summary>
    /// ★2026-09-12 用户需求：玩家移动途中每落一格的视野脉冲入口
    ///（HexMover.VisionPulseOnStep 战斗态分支调用）——与落点检测
    /// <see cref="CheckQuestionPhaseWalkIn"/> 同口径，但走一格就查：
    /// 踏进问号阶段参战者视野的瞬间立即 ReEngageOnSight（切战斗意图 + 同队视野连锁），
    /// 不等玩家停步。幂等：已切战斗意图者再调用直接早退。
    /// </summary>
    public void OnPlayerStepped()
    {
        CheckQuestionPhaseWalkIn();
    }

    /// <summary>
    /// ★2026-09-08：战斗态玩家移动落点检测——黄`?`/白`?`参战者视野覆盖玩家 → 立即切战斗意图（§4）。
    /// 只处理问号阶段参战者（SearchPhase/PendingTrapSearch 非空）；
    /// 常态战斗意图参战者与探索态敌人不需要这里。
    /// </summary>
    private void CheckQuestionPhaseWalkIn()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle) return;
        if (playerMover == null) return;

        Vector2Int playerCoord = playerMover.CurrentCoord;
        foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
        {
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;
            if (enemy.SearchPhase == EnemyController.DisengagePhase.None && !enemy.PendingTrapSearch) continue;
            if (VisionSystem.CanSee(enemy.CurrentCoord, playerCoord, enemy.data.visionRange, VisionSystem.EnemyGreenPenalty))
            {
                enemy.ReEngageOnSight();
            }
        }
    }
    
    /// <summary>
    /// ★2026-09-14 护甲清算辅助：清掉指定单位全部护甲并打日志（0 层不打，避免刷屏）。
    /// 时机口径见 ArmorEffect 类注释——「谁的回合开始，清谁的护甲」。
    /// </summary>
    private static void ClearArmorOn(GameObject unit, string side)
    {
        if (unit == null || EffectManager.Instance == null) return;

        int cleared = EffectManager.Instance.ClearArmor(unit);
        if (cleared > 0)
        {
            Debug.Log($"[护甲] {side}回合开始 → {unit.name} 护甲清零（-{cleared}）");
        }
    }

    /// <summary>
    /// 玩家护甲清算已移到 <see cref="EffectManager.ClearPlayerArmor"/>（战斗/探索共用）。
    /// </summary>

    /// <summary>
    /// 敌人护甲清算（敌人回合开始，所有存活敌人）。
    /// ★放在 EnemyTurn **最开头**（EnemyTurnExecutor.Run 之前）：敌人本回合新叠的甲不会被这一步抹掉，
    ///   能活过整个玩家回合——这正是「敌人在自己回合叠甲，玩家下回合要先打掉甲」的预期。
    /// </summary>
    private void ClearArmorOnEnemies()
    {
        // ★2026-09-16 性能二批补：本段同样是一次全场景扫（敌人回合最开头，每个战斗回合都跑）。
        System.Diagnostics.Stopwatch armorWatch = ExplorationPerf.StartBoundaryTimer();
        foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
        {
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;
            ClearArmorOn(enemy.gameObject, "敌人");
        }
        ExplorationPerf.EndBoundaryScope(armorWatch, "战斗·护甲清算段");
    }

    /// <summary>
    /// 敌人回合
    /// </summary>
    private System.Collections.IEnumerator EnemyTurn()
    {
        // ===== M6-5（2026-08-19）：敌人行动互斥锁 =====
        // 防重入：EndPlayerTurn 两条路径（正常结束/移动结束后）都汇聚到这里，
        // 若玩家快速连点结束回合，可能同时起两个 EnemyTurn 协程导致敌人动两次。
        if (_enemyTurnActive)
        {
            Debug.LogWarning("[TurnManager] 敌人回合已在进行中，忽略重复结束回合请求");
            yield break;
        }
        _enemyTurnActive = true;
        Interactions.RefreshEndTurnButton();

        Debug.Log("敌人回合开始");

        // ===== ★2026-09-14：敌人护甲在敌人回合开始清零 =====
        // 必须在 EnemyTurnExecutor.Run（敌人移动+出牌）之前——先清旧甲，本回合新叠的甲才能活过玩家回合。
        // 与玩家一侧对称：玩家护甲在 StartNewTurn（玩家回合开始）清。
        ClearArmorOnEnemies();

        // ===== M5b-3（2026-08-18）：玩家回合结束 → 状态效果衰减 =====
        // 放敌人回合开头：EndPlayerTurn 的两条路径（正常结束/移动结束后）都汇聚到这里。
        // 处理内容（EffectManager.OnTurnEnd）：虚弱/力量等每回合-1、到期效果移除。
        // ★2026-09-14：**护甲已不在此处清零**（ArmorEffect.OnTurnUpdate 改为不衰减，
        //   清零改由持有者回合开始的 ClearArmor 显式执行，见上方 ClearArmorOnEnemies）。
        // Demo 统一在玩家回合结束衰减一次 [待平衡]。
        if (EffectManager.Instance != null)
        {
            EffectManager.Instance.OnTurnEnd();
        }

        // ===== M6-5（2026-08-19）：遍历存活敌人执行「移动+出牌」 =====
        // 设计依据：《设计增补_敌人系统_v2.md》§14 M6-5 + §15.7 回合回调时机。
        // EnemyTurnExecutor.Run 返回 IEnumerator，直接 yield 让渡整个敌人回合。
        // TODO（被动子系统接入时补）：敌人回合开始/结束的被动钩子（+护甲等）。
        AlertPropagation.Refresh();
        AlertPropagation.PromoteDueSameSquad();
        yield return AlertPropagation.MoveCuriousNonCombatants();

        // ★2026-09-10 非参战小队继续巡逻（设计增补_威胁预告与搜索 §8：未参战小队除非在附近目击战斗
        //   否则无任何意图、继续巡逻）。参战者由上方 EnemyTurnExecutor 驱动，这里只驱动非参战者。
        yield return PatrolNonCombatants();

        yield return EnemyTurnExecutor.Run(0.6f);

        Debug.Log("敌人回合结束");

        // ★2026-09-05 脱战判定（用户定稿：追击范围 = 敌人移动力 + 视野的动态过程）：
        // 敌人回合移动完毕后，若所有存活敌人的视野（visionRange）都不再覆盖玩家
        // → 敌人放弃追击：战斗结束（无战利品）、回探索态（D4 简化实现）。
        // 相比旧的 visionRange+2 固定圈：敌人每回合全力移动仍看不见就放弃，
        // 玩家逃跑只需在敌人移完一回合后「保持视野外」即可，跑动效率账更直觉。
        if (TryDisengageAfterEnemyTurn())
        {
            _enemyTurnActive = false;
            yield break; // 已脱战回探索，不再开新战斗回合（迭代器内不能用 return，语义同）
        }

        // 释放互斥锁，再开启新玩家回合
        _enemyTurnActive = false;

        // 开始新的玩家回合
        StartNewTurn();
    }

    /// <summary>
    /// ★2026-09-10 战斗中驱动非参战者继续巡逻（设计增补_威胁预告与搜索 §8：未参战小队继续巡逻）。
    /// 与上方 EnemyTurnExecutor（只动参战者）互斥：本协程只动「非参战、非警戒/好奇/搜索/归队」的敌人。
    /// 参战小队仍由战斗执行器驱动并冻结其整队巡逻；好奇围观者由 MoveCuriousNonCombatants 驱动（上方已调用）。
    /// </summary>
    private System.Collections.IEnumerator PatrolNonCombatants()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle) yield break;
        if (BattleResultHandler.Instance == null) yield break;

        // ① 纯非参战小队：整队继续巡逻（SquadPatrolGroup 内已按 §8 跳过参战小队）
        // ★2026-09-16 性能二批补：先把小队列表扫出来单独计时——`FindObjectsOfType<SquadPatrolGroup>()`
        //   是这份工程里最贵的单点之一（万级对象 ≈3.5ms/次），此前只被记为「已知未做」。
        System.Diagnostics.Stopwatch scanWatch = ExplorationPerf.StartBoundaryTimer();
        System.Collections.Generic.List<SquadPatrolGroup> allGroups =
            new System.Collections.Generic.List<SquadPatrolGroup>(FindObjectsOfType<SquadPatrolGroup>());
        ExplorationPerf.EndBoundaryScope(scanWatch, "战斗·非参战小队扫描", allGroups.Count + " 队");

        foreach (SquadPatrolGroup group in allGroups)
        {
            if (group == null || group.HasAnyParticipant()) continue;
            yield return group.ExecutePatrolTurn();
        }

        // ② 无小队的散兵：单体继续巡逻（好奇/警戒/搜索/归队/追击/回巡逻者由别的机制处理，这里跳过）
        foreach (EnemyController e in AlertPropagation.LivingEnemies())
        {
            if (e == null || e.IsDead) continue;
            if (BattleResultHandler.Instance.IsParticipant(e)) continue;
            if (e.PatrolGroup != null) continue; // 已由其小队驱动
            if (e.IsCurious || e.IsAlerted || e.IsSearching || e.IsResting || e.IsChasing || e.IsReturningHome) continue;
            yield return e.PatrolTurn();
        }
    }

    /// <summary>
    /// ★脱战判定 → 六回合脱战流程（威胁预告与搜索 §3 / §8）。
    ///
    /// 敌人回合移动结束后，**全部**参战者都看不见玩家（§8：必须甩掉所有人）才推进流程：
    ///   回合2 追击结束仍未见 → 回合3 黄`?`散开搜索（**保持 Battle 态**，玩家打牌耗能量不耗探索骰）
    ///   回合3 搜索无果       → 回合4 白`?`归队 + 回已损 75%（阶段推进在 RevealAllEnemyIntents）
    ///   回合4 归队走完       → 回合5 切回探索态，敌人白`?`回巡逻 + 回剩余 25%（PatrolPhase 接手）
    ///   回合5 走完           → 回合6 复原（白`?`消失、疾跑清零、意图重置、偷袭资格恢复）
    /// 流程中任一参战者重新看见玩家或被攻击 → 中断，回到回合2 追击节奏（§4）。
    /// </summary>
    /// <returns>true = 已切回探索态（战斗结束，不再开新战斗回合）</returns>
    private bool TryDisengageAfterEnemyTurn()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle) return false;
        if (playerMover == null) return false;
        if (BattleResultHandler.Instance == null) return false;

        Vector2Int playerCoord = playerMover.CurrentCoord;

        // ★§8 非参战小队看见玩家 → 整队参战（无疾跑 1 加成，§5 专属探索态被动遇袭）；
        //   进战即消耗该小队本警戒周期的偷袭资格（§6.2）。脱战判定因此不成立。
        foreach (EnemyController watcher in AlertPropagation.LivingEnemies())
        {
            if (watcher.data == null) continue;
            if (BattleResultHandler.Instance.IsParticipant(watcher)) continue;
            if (!VisionSystem.CanSee(watcher.CurrentCoord, playerCoord, watcher.data.visionRange, VisionSystem.EnemyGreenPenalty)) continue;

            Debug.Log($"[战斗] 「{watcher.gameObject.name}」（非参战小队）视野覆盖玩家 → 整队参战（§8，无疾跑加成）");
            watcher.BecomeAlerted(isOrigin: true);
            watcher.LastSeenCoord = playerCoord;
            var joinSeeds = new System.Collections.Generic.List<EnemyController>();
            foreach (EnemyController mate in AlertPropagation.LivingEnemies())
            {
                if (AlertPropagation.SameSquad(watcher, mate)) joinSeeds.Add(mate);
            }
            if (joinSeeds.Count == 0) joinSeeds.Add(watcher);
            // ★2026-09-14 改为「补召」而非「重开一场」：BeginEncounter 会清空参战名单与奖励账本，
            //   把正在交战的参战者挤出名单（战斗中的怪掉回问号/红`!`）。JoinEncounterSquad 只增不清。
            BattleResultHandler.Instance.JoinEncounterSquad(joinSeeds);
            AlertPropagation.OnEnterCombat(joinSeeds);
            foreach (EnemyController seed in joinSeeds) SquadAlertCycle.MarkEnteredBattle(seed);
            return false;
        }

        bool anyAliveParticipant = false;
        EnemyController.DisengagePhase phase = EnemyController.DisengagePhase.None;
        var participants = new System.Collections.Generic.List<EnemyController>();

        foreach (EnemyController enemy in FindObjectsOfType<EnemyController>())
        {
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;
            if (!BattleResultHandler.Instance.IsParticipant(enemy)) continue;
            anyAliveParticipant = true;

            // 还有参战者看得见玩家 → 不脱战。
            // ★2026-09-08 修复：问号阶段参战者看见玩家必须**真的**转回战斗意图 + 同队传导（§4），
            // 不能只 return false——否则头顶问号不变、阶段照常推进，玩家贴脸仍是白`?`（用户实测）。
            // 敌人回合起点已兜底过一次（EnemyTurnExecutor），这里再兜移动落点新进视野的情况。
            if (VisionSystem.CanSee(enemy.CurrentCoord, playerCoord, enemy.data.visionRange, VisionSystem.EnemyGreenPenalty))
            {
                enemy.ReEngageOnSight();
                return false;
            }

            participants.Add(enemy);
            if (enemy.SearchPhase != EnemyController.DisengagePhase.None) phase = enemy.SearchPhase;
        }

        if (!anyAliveParticipant)
        {
            if (BattleResultHandler.Instance.TryResolveVictoryIfCleared())
            {
                return true;
            }
            return false;
        }

        // ---- 流程被打断过（§4：问号阶段重进战后又全员丢失视野）----
        // 发起者已切战斗意图（SearchPhase=None），被传导队友红`!`仍挂在问号阶段 →
        // 「phase==黄搜索」没有任何分支：红`!`永远不清、每回合按战斗行动点朝玩家真实坐标
        // 逼近（用户实测"到处乱跑"）；白`?`期间被打断甚至会误切探索态，红`!`队友被探索
        // 警戒结算跳过（IsResting）→ 红`!`永久残留。判定：存在红`!`参战者，或战斗意图者
        // 与问号者并存 = 流程被重进战打断过 → 全体统一重开黄`?`散开搜索（不推进白`?`、不切探索态）。
        bool anyAlerted = false, anyInQuestion = false, anyInCombat = false;
        foreach (EnemyController p in participants)
        {
            if (p.IsAlerted) anyAlerted = true;
            if (p.SearchPhase != EnemyController.DisengagePhase.None) anyInQuestion = true;
            else anyInCombat = true;
        }

        if (anyAlerted || (anyInQuestion && anyInCombat))
        {
            Debug.Log("[战斗] 问号阶段重进战后又丢失视野 → 全体重开黄`?`散开搜索（§4，红`!`清零）");
            foreach (EnemyController lost in participants)
            {
                lost.ClearAlertOrigin();
                if (ScatterLimitExhausted(lost))
                {
                    Debug.Log($"[战斗] 「{lost.name}」散开搜寻次数已用尽（上限 {lost.GetMaxSearchCount()} 次）→ 放弃回家：跳过散开，直接白`?`归队回血（§4）");
                    lost.GiveUpSearch();
                }
                else
                {
                    lost.BeginDisengageSearch();
                }
            }
            return false;
        }

        // ---- 回合4 白`?`归队已走完 → 回合5：玩家回探索态，敌人白`?`回巡逻（回剩余 25%）----
        if (phase == EnemyController.DisengagePhase.白归队)
        {
            Debug.Log("[战斗] 白`?`归队完成 → 回合5：玩家回探索态，敌人白`?`回巡逻（回剩余 25%）");
            GameStateManager.Instance.SwitchToExploring();
            return true;
        }

        // ---- 回合2 追击结束仍未见玩家 → 回合3：黄`?`散开搜索（保持 Battle 态）----
        // 已经在问号阶段（黄搜索）的敌人不重复进入——它们的阶段推进由 RevealAllEnemyIntents 负责。
        if (phase == EnemyController.DisengagePhase.None)
        {
            Debug.Log("[战斗] 全部参战者丢失视野 → 回合3：黄`?`散开搜索（保持战斗态，玩家仍耗能量）");
            foreach (EnemyController lost in participants)
            {
                lost.ClearAlertOrigin();
                if (ScatterLimitExhausted(lost))
                {
                    Debug.Log($"[战斗] 「{lost.name}」散开搜寻次数已用尽（上限 {lost.GetMaxSearchCount()} 次）→ 放弃回家：跳过散开，直接白`?`归队回血（§4）");
                    lost.GiveUpSearch();
                }
                else
                {
                    lost.BeginDisengageSearch();
                }
            }
        }

        return false;
    }

    /// <summary>
    /// §4 散开搜寻上限（2026-09-08 用户定稿）：一次意图循环内最多触发 maxSearchCount 次（默认 2，
    /// SquadPatrolData 选项）。计数在 EnemyController.ScatterSearchCount（BeginDisengageSearch 递增、
    /// FinishDisengage 清零）。用尽后再次丢视野 → 跳过散开直接放弃回家。
    /// </summary>
    static bool ScatterLimitExhausted(EnemyController p)
    {
        return p.ScatterSearchCount >= p.GetMaxSearchCount();
    }
    
    /// <summary>
    /// ★探索→战斗入场入口（探索系统 v2 §9.1 v3，2026-09-05 用户定稿：进战斗一律玩家先手）：
    /// 由 ExplorationTurnManager 在 SwitchToBattle 之后调用。
    /// - enemySurprise=true：被动遇袭（站着不动结束回合仍在视野 / 敌人巡逻撞见玩家）——
    ///   玩家先手照常，但参战敌人首回合 +enemySurpriseAPBonus 行动点（敌人先看见了玩家，§10.6.1）
    /// - enemySurprise=false：偷袭（警戒中攻击牌命中，§9.1.2）——无加成 + 免费整备（后续接入）
    /// 能量超 3 → 行动点：2026-09-13 定稿改为每个回合开始通用结算（StartNewTurn），入场时不再单独处理。
    /// </summary>
    public void BeginBattleFromExploring(bool enemySurprise)
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            return; // 守卫：仅战斗态（调用方负责先 SwitchToBattle）
        }

        isPlayerTurn = true;
        isEndTurnRequested = false;
        currentTurn = 0;

        // ★2026-09-05 探索手牌洗回：偷袭/被动进战发生在探索回合中途，手上还有探索抽的手牌
        //（未到回合结束的洗回点）。先清手牌回牌堆，StartNewTurn 再抽 5 张战斗手牌，
        // 避免探索手牌 + 战斗手牌叠加成 10 张。
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.DiscardAllHand();
        }

        Debug.Log(enemySurprise
            ? "[战斗] 被动遇袭进战斗：玩家先手，发现者本回合开始展现战斗意图并直接获得疾跑 1（§5）"
            : "[战斗] 偷袭进战斗：玩家先手（敌人无加成）");

        // ★2026-09-14（用户定稿）：探索期打出的防御**带进战斗第一回合**、这一回合不清零
        //   （preservePlayerArmor: true）——否则进战那一下甲就白叠了。
        //   战斗回合 2/3… 照常「玩家回合开始清零」。
        StartNewTurn(preservePlayerArmor: true); // 战斗回合 1 = 玩家回合

        // ★临时强化（design §3.5）：战斗开始应用。顺序要紧——
        //   「暖身」必须在 StartNewTurn 的「能量超 3 → 行动点」换算之后给，
        //   否则这 1 点能量会被折算成 AP 而不是本回合可用的能量。
        TempBuffRuntime.OnBattleBegin();
        int warm = TempBuffRuntime.FirstTurnEnergyBonus();
        if (warm > 0)
        {
            EnergyPointDisplay epd = ExplorationPerf.Energy;
            if (epd != null)
            {
                epd.AddEnergy(warm);
                Debug.Log($"[事件] 「暖身」生效：第 1 回合 +{warm} 能量");
            }
        }
    }

    /// <summary>
    /// 获取当前是否为玩家回合
    /// </summary>
    public bool IsPlayerTurn()
    {
        return isPlayerTurn;
    }

    /// <summary>
    /// 获取当前是否处于敌人回合（互斥锁状态）。
    /// M6-5 用：敌人行动期间禁止玩家交互（Interactions.PlayerCanInteract 消费）。
    /// </summary>
    public bool IsEnemyTurn()
    {
        return _enemyTurnActive;
    }
    
    /// <summary>
    /// 获取当前回合数
    /// </summary>
    public int GetCurrentTurn()
    {
        return currentTurn;
    }
    
    /// <summary>
    /// 获取玩家当前骰子数量
    /// </summary>
    public int GetPlayerDiceCount()
    {
        return playerDiceCount;
    }
    
    /// <summary>
    /// 消耗骰子
    /// </summary>
    public bool ConsumeDice(int amount)
    {
        if (playerDiceCount >= amount)
        {
            playerDiceCount -= amount;
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 战斗态骰子换行动点（★2026-09-08 用户定稿：与探索态一致，每回合上限 2 枚）
    // ------------------------------------------------------------------

    /// <summary>战斗态还能否耗骰换行动点（DiceDragHandler 战斗分支开头查询）。</summary>
    public bool CanSpendDiceForAP()
    {
        return battleDiceToAPUsedThisTurn < battleDiceAPCapPerTurn;
    }

    /// <summary>记账一次「耗 1 骰换行动点」（DiceDragHandler 战斗分支加 AP 前调用）。</summary>
    public void RecordDiceForAP()
    {
        if (battleDiceToAPUsedThisTurn < battleDiceAPCapPerTurn)
        {
            battleDiceToAPUsedThisTurn++;
        }
    }

    /// <summary>本回合已用于换行动点的骰子数（UI/调试用）。</summary>
    public int DiceToAPUsedThisTurn => battleDiceToAPUsedThisTurn;
    
    /// <summary>
    /// 重新激活所有骰子按钮，补满骰池
    /// </summary>
    private void ActivateDiceButtons()
    {
        if (diceArea != null)
        {
            // 遍历DiceArea的所有子对象
            foreach (Transform child in diceArea.transform)
            {
                // 检查子对象是否是骰子按钮
                if (child.name.StartsWith("Dice6Button"))
                {
                    // 激活按钮
                    child.gameObject.SetActive(true);
                    // 解除按钮上的锁，设置为可交互
                    Button button = child.GetComponent<Button>();
                    if (button != null)
                    {
                        button.interactable = true;
                    }
                    
                    // 清除按钮上现有的圆点
                    for (int i = child.childCount - 1; i >= 0; i--)
                    {
                        if (child.GetChild(i).name.StartsWith("Dot"))
                        {
                            Object.Destroy(child.GetChild(i).gameObject);
                        }
                    }
                    
                    // 恢复为6点状态
                    DiceDragHandler diceDragHandler = child.GetComponent<DiceDragHandler>();
                    if (diceDragHandler != null)
                    {
                        // 调用UpdateDiceButtonIcon方法，设置为6点
                        diceDragHandler.UpdateDiceButtonIcon(6);
                    }
                }
            }
            Debug.Log("骰子按钮已重新激活，骰池已补满");
        }
        else
        {
            Debug.LogError("DiceArea对象未找到");
        }
    }
    
    /// <summary>
    /// 清空骰池，隐藏所有骰子按钮
    /// </summary>
    private void ClearDicePool()
    {
        if (diceArea != null)
        {
            // 遍历DiceArea的所有子对象
            foreach (Transform child in diceArea.transform)
            {
                // 检查子对象是否是骰子按钮
                if (child.name.StartsWith("Dice6Button"))
                {
                    // 隐藏按钮
                    child.gameObject.SetActive(false);
                }
            }
            Debug.Log("骰池已清空");
        }
        else
        {
            Debug.LogError("DiceArea对象未找到");
        }
    }
}
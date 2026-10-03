// =============================================================================
// 模块：探索系统第一步 - 探索回合管理器 ExplorationTurnManager
// 用途：Exploring 态的回合循环管理（与战斗态的 TurnManager 对位）
// 设计依据：《设计增补_探索系统_v1.md》
//   §3 探索回合循环 / D1 移动固定行动点体系 / D4 探索牌复用（每回合随机抽5张）
//   ★2026-09-05 v3：§9.1 警戒模式 v3 + D13b 敌人巡逻（推翻 §4.1/总策划案 §10.4「敌人静止」）
// 职责边界：只管探索回合的开始/结束与骰子池；打牌/鉴定/事件/敌人属后续步骤
// 挂载位置：MainScene 的 SetUp/GameManager（与 TurnManager 同对象）
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 探索回合管理器（单例）。
/// 回合循环（探索系统 v1 §3）：
///   回合开始 → 补满探索骰子至 N + 从完整牌库随机抽 5 张 + 授予行动点（baseAP+敏捷）
///   玩家行动 → 移动（1 平地格=1AP，HexMover 按 TerrainManager.GetActionCost 扣）/ 耗骰换AP
///   回合结束 → 手牌洗回 + 清骰池 + AP 清零 → 直接下一回合（无敌人回合，敌人静止）
/// </summary>
public class ExplorationTurnManager : MonoBehaviour
{
    // -------- 单例 --------
    public static ExplorationTurnManager Instance { get; private set; }

    /// <summary>探索回合开始事件（教学 Director 等订阅，零侵入钩子）。</summary>
    public static event System.Action OnExplorationTurnStarted;

    /// <summary>偷袭入口成立事件（教学 T4 触发 / 解除用，零侵入钩子）。</summary>
    public static event System.Action OnAmbushLaunched;

    /// <summary>玩家消耗 1 枚探索骰事件（移动自动扣骰链路；教学 S3 解除用）。
    /// 点骰子按钮那条链路由 DiceDragHandler 调 RaiseDiceConsumed 补发同一事件。</summary>
    public static event System.Action OnExplorationDiceConsumed;

    /// <summary>外部链路（DiceDragHandler 骰子按钮）补发消耗事件（event 只允许声明类内触发）。</summary>
    public static void RaiseDiceConsumed() => OnExplorationDiceConsumed?.Invoke();

    [Header("探索回合设置（探索系统 v1 §11.1 调优旋钮，[待平衡]）")]
    [Tooltip("每回合探索骰子数 N（§2.1，统一决策备忘 2026-08-17 锁定 4）")]
    public int dicePerTurn = 4;

    [Tooltip("每回合基础行动点 baseAP（§4.1 D1：移动不投骰；敏捷加值待人物属性系统接入）")]
    public int baseActionPoints = 2;

    [Tooltip("耗 1 枚骰子换得的额外行动点 diceAP（§4.1）")]
    public int diceAPBonus = 2;

    [Tooltip("每回合耗骰换行动点的上限 diceAPCap（§4.1，防骰子全砸移动）")]
    public int diceAPCapPerTurn = 2;

    [Tooltip("探索回合每回合抽牌数（D4 探索牌复用：从完整牌库随机抽 5 张）")]
    public int cardsPerTurn = 5;

    // ⚠️★2026-09-14 用户纠偏：下面两个字段**不是能量上限**，只是「某一次剩骰→能量的单次转化上限」。
    //   真正的能量天花板只有一个 —— `EnergyPointDisplay.energyMax`（默认 9，F1.1 可成长）。
    //   之所以它们看起来像"上限"，是因为历史上 9 被错记成"剩骰转能量上限"。
    //   探索骰每回合只有 4 枚，这两个值实际上永远卡不住；能量能到 9 靠的是**跨回合累积**
    //   和**局内其它回能手段**（消耗品 / 事件），那些路径现在也统一受 energyMax 约束。
    [Tooltip("回合结束「剩余骰→能量」的单次转化上限——**不是能量上限**！" +
             "真正的天花板是 EnergyPointDisplay.energyMax（默认 9）。" +
             "转化后超出 3 的部分，在下个玩家回合开始 1:1 转为行动点。")]
    public int diceToEnergyCapPerTurn = 9;

    [Tooltip("偷袭/被动遇袭当场「剩余骰→能量」的单次转化上限——**不是能量上限**！" +
             "真正的天花板是 EnergyPointDisplay.energyMax（默认 9）。")]
    public int ambushLeftoverDiceEnergyCap = 9;

    /// <summary>★2026-09-14：回合结束「剩余骰→能量」单次转化上限的对外只读口径
    /// （TurnManager.EndPlayerTurn 战斗回合结束也用它，避免两处各写一个数）。
    /// 注意：这只是单次转化上限，最终仍会被 EnergyPointDisplay.energyMax 再夹一次。</summary>
    public int DiceToEnergyCapPerTurn => diceToEnergyCapPerTurn;

    // -------- 运行时状态 --------
    private int currentTurn = 0;

    /// <summary>本回合已用于换行动点的骰子数（DiceDragHandler 查询/记账）</summary>
    private int diceAPUsedThisTurn = 0;

    /// <summary>移动中请求结束回合（与 TurnManager 同款机制，HexMover 移动结束后补执行）</summary>
    private bool isEndTurnRequested = false;
    private bool _playerPhase = true;

    private HexMover playerMover;
    private Button endTurnButton;
    private GameObject diceArea;

    // ------------------------------------------------------------------
    // 生命周期
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

    private void Start()
    {
        // 订阅状态切换：进入探索态 → 启动探索回合（未来 M7 战斗胜利回探索的天然入口）
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged += HandleGameStateChanged;
        }

        // ★2026-09-05 订阅事件弹窗关闭：续跑被弹窗暂缓的落点结算（警戒检测/结束回合）
        EventTile.OnPopupClosed += OnEventPopupClosed;

        // 缓存引用（与 TurnManager 同源：EndTurnButton / DiceArea / 玩家）
        GameObject endTurnButtonObj = GameObject.Find("UICanvas/EndTurnButton");
        if (endTurnButtonObj != null)
        {
            endTurnButton = endTurnButtonObj.GetComponent<Button>();
            if (endTurnButton != null)
            {
                // ★与 TurnManager 共听同一按钮：点击时各自按状态守卫，仅一方真正执行
                endTurnButton.onClick.AddListener(EndExplorationTurn);
            }
        }

        diceArea = GameObject.Find("UICanvas/StatusBar/DiceArea");
        playerMover = FindObjectOfType<HexMover>();

        // 启动即探索（GameStateManager.startupState=Exploring）→ 开始首个探索回合。
        // 若启动即 Battle（调试战斗），此处不动作，等状态切换事件在进入探索态时启动。
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            StartNewExplorationTurn();
        }
    }

    private void OnDestroy()
    {
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged -= HandleGameStateChanged;
        }
        EventTile.OnPopupClosed -= OnEventPopupClosed;
    }

    private void Update()
    {
        // ★X 暂时关闭事件窗口后：点击脚下事件格地板 → 重新打开（EventTile 统一射线判定）
        EventTile.HandleTileClickReopen();
        // ★2026-09-11 篝火点：点击脚下篝火格 → 重开面板
        BonfireTile.HandleTileClickReopen();
        // ★2026-09-13 遗物袋/箱子：点击脚下箱子格 → 重开搜刮窗（拿一半关掉后不用走开再走回来）
        LootPopupUI.HandleTileClickReopen();
        // ★2026-09-13 藏身处入口：走到 'O' 格 → 结束当局进藏身处（教程 S43 走到才完成教学放行）
        HideoutEntrance.HandleArrival(playerMover);
        // ★2026-09-15 主动撤离：走回「家」格（＝出生格＝撤离点 'S'）→ 弹撤离确认 → 全额入账回藏身处
        ExtractionPoint.HandleArrival(playerMover);
    }

    /// <summary>
    /// 响应游戏模式切换：进入探索态 → 启动探索回合（M7 战斗结算回探索时走这里，D5）。
    /// </summary>
    private void HandleGameStateChanged(GameState oldState, GameState newState)
    {
        if (newState == GameState.Exploring && oldState != GameState.Exploring)
        {
            StartNewExplorationTurn();
        }
    }

    // ------------------------------------------------------------------
    // 探索回合循环（探索系统 v1 §3）
    // ------------------------------------------------------------------

    /// <summary>
    /// 探索回合开始（§3 第 1 步）：
    /// ① 补满探索骰子至 N ② 从完整牌库随机抽 5 张（D4 牌复用）③ 授予行动点（D1 固定值）
    /// </summary>
    public void StartNewExplorationTurn()
    {
        // ★2026-09-16 性能二批：回合开始段分段计时（护甲清零 → 骰池/抽牌/手牌重排 → AP/能量 → 敌人 AP 恢复）
        System.Diagnostics.Stopwatch turnStartWatch = ExplorationPerf.StartBoundaryTimer();

        // ★2026-09-14 护甲清零时机（用户定稿：谁的回合开始清谁的护甲）：
        //   探索回合 = 玩家回合 → 玩家护甲只能持续「当前这一回合」，新回合开始清零。
        //   唯一例外在战斗侧：探索→战斗的第一回合保留（TurnManager.BeginBattleFromExploring
        //   传 preservePlayerArmor: true），这样探索期打出的防御能带进战斗第一回合继续挡。
        EffectManager.ClearPlayerArmor();

        currentTurn++;
        diceAPUsedThisTurn = 0;
        isEndTurnRequested = false;
        _playerPhase = true;
        Interactions.RefreshEndTurnButton();

        AlertPropagation.PromoteDueSameSquad();
        AlertPropagation.Refresh();

        // ★v3 说明：不在此清警戒——正常路径到达本处时警戒已按三结局了结
        // （C 进战斗时清 / B 转追击巡逻时清）；巡逻中被动触发的警戒要跨入新回合生效。

        // ① 补满骰池（激活前 N 枚骰子按钮）
        ActivateDicePool();

        // ② 从完整牌库随机抽 5 张（D4：牌是可复用工具，每回合独立随机；
        //    战斗遗留的抽/弃牌堆在 InitDrawPileFromDeck 重建时天然洗回 = D5 牌库恢复完整）
        if (CardPileManager.Instance != null && CardDeckManager.Instance != null)
        {
            CardPileManager.Instance.InitDrawPileFromDeck(CardDeckManager.Instance.GetPlayableDeck());
            CardPileManager.Instance.DrawCards(cardsPerTurn);
            // 抽牌自动掷绑定骰子（CardPileManager 内置 RollAllDice），数值照常显示——
            // 探索态数值不影响任何逻辑（弃牌降难度只看花色不看数值，用户 2026-08-25 确认）
            if (HandUIController.Instance != null)
            {
                HandUIController.Instance.RefreshHandLayout();
            }
        }

        // ③ 授予行动点：baseAP + 敏捷加值（D1 §4.1 探索移动不投骰，1 平地格 = 1 AP）
        // F4.5 敏捷→移动 = ⌊敏捷 ÷ 3⌋（探索系统 v2 §4.1 用户定稿 3:1）
        if (playerMover != null)
        {
            int agilityBonus = CharacterStats.敏捷 / CharacterStats.AgiMoveDivisor;
            playerMover.currentActionPoints = baseActionPoints + agilityBonus + RunModifiers.MoveRangeBonus;

            // AP 上限 = 基础 + 骰换满额（实际约束靠骰换计数 diceAPCapPerTurn）
            playerMover.maxActionPoints = baseActionPoints + agilityBonus + RunModifiers.MoveRangeBonus + diceAPBonus * diceAPCapPerTurn;

            // ★v3.1 通用规则（用户 2026-09-13 定稿）：每个回合开始，能量超过 3 的部分
            //    1:1 转行动点，能量压回 3（探索/战斗两侧统一；F3.3 警戒即时转化保留）。
            EnergyPointDisplay energyAtTurnStart = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存
            if (energyAtTurnStart != null)
            {
                int excess = energyAtTurnStart.CurrentEnergy - 3;
                if (excess > 0)
                {
                    energyAtTurnStart.SetEnergy(3);
                    playerMover.currentActionPoints += excess;
                    Debug.Log($"[探索] 回合开始能量转化：能量压回 3，+{excess} 行动点");
                }
            }
        }

        // ④ 恢复敌人行动点（★2026-09-09 改：按当前活动状态设对应步数，徽章随状态显示正确 AP）。
        //    巡逻/追击 → patrolAP；搜索/归队 → 搜索步数（先锋+1）；警戒 → 战斗 AP。
        //    探索态移动（MoveToCoordSmooth 逐格 ConsumeMoveBudget）从这里设的步数递减到 0；
        //    断筋的减行动点要持续到敌人这一次巡逻移动之后、下回合才自动恢复（TurnManager ★P1 同款理由）。
        // ★2026-09-16 性能批：改走占位表注册表（原为每回合一次的全场景扫）
        foreach (EnemyController enemy in UnitOccupancy.LivingEnemies)
        {
            if (enemy == null || enemy.IsDead) continue;
            enemy.RestoreExplorationAP();
        }

        // 整备状态重置（D6：能量在探索态只积累不消耗；v3 警戒不禁整备——能量压 3 后整备天然无收益）
        EnergyPointDisplay energyDisplay = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存
        if (energyDisplay != null)
        {
            energyDisplay.ResetPrepareStatus();
        }

        Debug.Log($"[探索] 回合 {currentTurn} 开始：骰子 {dicePerTurn} 枚 / AP {baseActionPoints} / 手牌 {cardsPerTurn} 张");

        OnExplorationTurnStarted?.Invoke();

        ExplorationPerf.EndBoundaryScope(turnStartWatch, "回合开始段");
    }

    /// <summary>探索玩家行动阶段；巡逻/进战过程中为 false，结束回合按钮不可用。</summary>
    public bool IsPlayerPhase()
    {
        return _playerPhase;
    }

    /// <summary>
    /// 探索回合结束入口（EndTurnButton 触发，仅 Exploring 态生效）。
    /// 玩家移动中请求结束 → 记录请求，移动结束后由 OnMoveEnded 补执行。
    /// </summary>
    public void EndExplorationTurn()
    {
        // 状态守卫：Battle 态由 TurnManager 处理（两管理器共听同一按钮，各自守卫）
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring)
        {
            return;
        }

        // ★2026-09-11：探索回合结束入口——若战术卡包（卡包页）正打开，先关掉，
        //   避免卡包盖在结束回合流程（强制结束 / 巡逻结算）之上；不阻断结束回合本身。
        if (CardPackUI.Instance != null && CardPackUI.Instance.IsOpen) CardPackUI.Instance.Hide();

        if (!_playerPhase) return;

        _playerPhase = false;
        Interactions.RefreshEndTurnButton();

        // 玩家移动中：记录请求，等移动结束（HexMover.FinalizeMove 按状态分流转发 OnMoveEnded）
        if (playerMover != null && playerMover.IsMoving())
        {
            isEndTurnRequested = true;
            Debug.Log("[探索] 移动中请求结束回合，将在移动结束后执行");
            return;
        }

        FinishExplorationTurn();
    }

    /// <summary>
    /// 玩家移动结束回调（HexMover.FinalizeMove 按状态分流转发到这里）。
    /// ★2026-08-25 事件格触发（探索系统 v2 §7.5）：落点在事件格上 → 弹事件弹窗。
    /// ★2026-09-05 警戒检测（D13 §9.1.1）：落点进敌人视野 → 敌人警戒（"!" + 禁整备）。
    /// </summary>
    public void OnMoveEnded()
    {
        // ① 事件格检测：落点有未触发的事件 → 弹窗（模态），暂缓结束回合与警戒检测
        if (EventTile.TryTriggerAt(playerMover != null ? playerMover.CurrentCoord : Vector2Int.zero))
        {
            // 弹窗打开期间不结算；弹窗关闭后 EventTile.OnPopupClosed 会回调续跑
            return;
        }

        // ② 警戒检测：落点进入敌人视野 → 该敌人警戒（D13：锁定至回合结束、移出不解除）
        CheckAlertAtLanding();

        if (isEndTurnRequested)
        {
            isEndTurnRequested = false;
            FinishExplorationTurn();
        }
    }

    /// <summary>
    /// 弹窗关闭回调（EventTile.OnPopupClosed 订阅）：续跑被弹窗暂缓的落点结算。
    /// 只做警戒检测 + 结束回合补执行——不重查事件格（避免「X 关闭 → 立刻再弹」死循环，
    /// 想重开事件窗走「点击脚下格」入口）。
    /// </summary>
    private void OnEventPopupClosed()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring) return;

        CheckAlertAtLanding();

        if (isEndTurnRequested)
        {
            isEndTurnRequested = false;
            FinishExplorationTurn();
        }
    }

    /// <summary>
    /// ★2026-09-12 用户需求：玩家移动途中每落一格的视野脉冲入口
    ///（HexMover.VisionPulseOnStep 探索态分支调用）——与落点检测
    /// <see cref="CheckAlertAtLanding"/> 同口径，但走一格就查：
    /// 踏进某敌视野的瞬间该敌立即警戒（红`!`徽章），F3.3 能量转化也立即生效；
    /// 不等玩家停步。幂等：AlertPropagation.Refresh 只在有「新发起人」时返回 true。
    /// </summary>
    public void OnPlayerStepped()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring) return;
        CheckAlertAtLanding();
    }

    /// <summary>
    /// ★警戒检测 v3（探索系统 v2 §9.1.1 / D13，2026-09-05 重构）：
    /// 玩家落点进入存活敌人视野（HexDistance ≤ visionRange）→ 该敌人警戒（头顶"!"徽章）。
    /// 触发瞬间执行 F3.3 能量转化：能量 > 3 的部分立即 1:1 转行动点、能量压回 3。
    /// 警戒中的敌人原地不动；警戒只持续本回合剩余部分（回合结束时按 §9.1.3 三结局结算）。
    /// （敌人巡逻撞见玩家不走这里——巡逻落点直接被动遇袭进战斗，见 PatrolPhase）
    /// </summary>
    private void CheckAlertAtLanding()
    {
        if (playerMover == null) return;

        bool anyNewOrigin = AlertPropagation.Refresh();
        if (anyNewOrigin)
        {
            EnergyPointDisplay energyDisplay = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存（原 FindObjectOfType 全场景扫）
            if (energyDisplay != null)
            {
                int excess = energyDisplay.CurrentEnergy - 3;
                if (excess > 0)
                {
                    energyDisplay.SetEnergy(3);
                    playerMover.currentActionPoints += excess;
                    Debug.Log($"[探索] F3.3 警戒转化：能量压回 3，+{excess} 行动点（立即生效）");
                }
            }
        }
    }

    /// <summary>
    /// 真正结束探索回合（§3 第 3 步，顺序按总策划案 §12.6）：
    /// ① 手牌洗回（下回合开始重建完整牌库 = D4/D5）② 剩余骰子回能量（D17）
    /// ③ 清骰池 ④ AP 清零（不跨回合累积 §4.1）
    /// ⑤ 探索态敌人静止（总策划案 §10.4）→ 无敌人回合，直接开始下一回合
    /// </summary>
    private void FinishExplorationTurn()
    {
        _playerPhase = false;
        Interactions.RefreshEndTurnButton();

        // ★2026-09-16 性能二批：结束回合段分段计时（只算记账部分；不含紧随其后的
        //   StartCoroutine(PatrolPhase) 同步首段——那部分由阶段摘要的「首帧」体现）
        System.Diagnostics.Stopwatch turnEndWatch = ExplorationPerf.StartBoundaryTimer();

        // ① 未打出的手牌回牌库：D4「未打出的手牌回抽牌堆（不放弃牌堆）」——
        //    实现为 DiscardAllHand + 下回合 InitDrawPileFromDeck 重建，语义等价（每回合独立随机）
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.DiscardAllHand();
        }
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.ClearSelection();
        }

        // ② 剩余骰子回能量（★D17 补丁 2026-08-25，总策划案 §12.6 第 3 条）：
        //    回合结束时，剩余（未点击使用）的探索骰子 1:1 转能量，硬顶 diceToEnergyCapPerTurn
        //    （★2026-09-14 定稿 = 9 = 能量上限；超出 3 的部分在下个玩家回合开始 1:1 转行动点。
        //     旧值 3 把溢出全丢掉 → 回合开始「超 3 转 AP」恒为 0，用户报障）。
        //    战斗态同样走此逻辑（★2026-09-10：战斗回合结束也转化，见 TurnManager.EndPlayerTurn）。
        ConvertLeftoverExplorationDiceToEnergy(diceToEnergyCapPerTurn);

        // ③ 清空骰池
        ClearDicePool();

        // ④ 行动点清零（§4.1：不跨回合累积）
        if (playerMover != null)
        {
            playerMover.currentActionPoints = 0;
        }

        Debug.Log($"[探索] 回合 {currentTurn} 结束");

        // ⑤ 战术卡槽冷却 −1（★2026-09-10 新增：战术卡不再限战斗态，探索回合也必须 tick）
        //    旧设计只在 TurnManager.EndPlayerTurn（战斗回合末）调 TickEndOfTurn，
        //    前提是「战术卡仅战斗可用，探索回合不该消耗战斗 CD」——该前提已被用户废止
        //    （战术卡 = 拓展手牌位，探索态同样能用）。不在这里 tick 的话，
        //    探索态用掉的卡会永远停在冷却里再也出不来（表现为「用一次就废了」）。
        //    与战斗侧一致：放在本方法的「回合真正结束」段，且两态各自有状态守卫、不会重复 tick。
        TacticSlotRuntime.TickEndOfTurn();

        // ⑥ 警戒回合结束三结局（探索系统 v2 §9.1.3 / D13 v3，2026-09-05 用户定稿：进战斗一律玩家先手）：
        //    A 偷袭在打牌命中瞬间处理（§9.1.2，不走这里）
        //    C 仍在警戒敌人视野内 → 被动遇袭进战斗（玩家先手 + 敌人首回合 AP 加成）
        //    B 已逃出所有警戒敌人视野 → 解除警戒，警戒敌人转追击巡逻
        if (EnemyController.AnyAlertedEnemy())
        {
            bool stillInSight = false;
            Vector2Int playerPos = playerMover != null ? playerMover.CurrentCoord : Vector2Int.zero;

            // ★2026-09-16 性能批：改走占位表注册表（原为全场景扫）
            foreach (EnemyController enemy in UnitOccupancy.LivingEnemies)
            {
                if (enemy == null || enemy.IsDead || !enemy.IsAlerted) continue;
                if (VisionSystem.CanSee(enemy.CurrentCoord, playerPos, enemy.data.visionRange, VisionSystem.EnemyGreenPenalty))
                {
                    stillInSight = true;
                    break;
                }
            }

            if (stillInSight)
            {
                // 结局 C：被动遇袭——玩家先手进战斗，敌人首回合 AP 加成（BeginBattleFromExploring 内处理）
                // ★2026-09-16 性能二批补：这条 return 会跳过下面那行「结束回合段」——
                //   用户实测的「结束回合→被动遇袭」正好走这里，日志里就少了这一段数。这里补打。
                ExplorationPerf.EndBoundaryScope(turnEndWatch, "结束回合段");
                StartBattlePassively(null);
                return;
            }

            // 结局 B：逃出视野——解除警戒，警戒敌人转追击巡逻（朝最后目击点，D13b）
            // ★处于脱战问号阶段（黄`?`搜索 / 白`?`休整）或陷阱待搜索的敌人跳过：
            //   它们走独立的六回合状态机（威胁预告与搜索 §3 / §7.1），不能被覆盖成追击巡逻
            // ★2026-09-16 性能批：改走占位表注册表（原为全场景扫）
            foreach (EnemyController enemy in UnitOccupancy.LivingEnemies)
            {
                if (enemy == null || enemy.IsDead || !enemy.IsAlerted) continue;
                if (enemy.PendingTrapSearch || enemy.IsSearching || enemy.IsResting) continue;
                enemy.SetAlerted(false);
                enemy.ClearAlertOrigin();
                enemy.IsChasing = true;
                Debug.Log($"[探索] 「{enemy.gameObject.name}」丢失目标 → 转追击巡逻（朝目击点 {enemy.LastSeenCoord}）");
            }
        }

        // ⑥ 敌人巡逻阶段（D13b：常态巡逻 + 追击巡逻，每探索回合结束移动）
        ExplorationPerf.EndBoundaryScope(turnEndWatch, "结束回合段");
        StartCoroutine(PatrolPhase());
    }

    /// <summary>
    /// ★探索态敌人巡逻阶段（D13b）：所有存活敌人依次巡逻移动（协程，逐个动画）。
    /// - 警戒中的敌人原地不动（跳过）
    /// - 追击巡逻（IsChasing）朝最后目击点走 patrolAP 步；普通巡逻在出生点半径内随机游走
    /// - ★巡逻落点看见玩家 → 直接被动遇袭进战斗（2026-09-05 用户定稿：玩家先手 + 敌人首回合 AP 加成）
    /// 巡逻全部结束 → 开始下一探索回合。
    /// </summary>
    private IEnumerator PatrolPhase()
    {
        _playerPhase = false;
        Interactions.RefreshEndTurnButton();

        // ★2026-09-16 性能批：远场渲染裁剪 + 帧耗时采样（幂等；场景切换后旧实例被销毁 → 这里重建）。
        EnemyRenderLod.EnsureExists();
        ExplorationPerf.BeginEnemyPhase();

        // 快照（避免巡逻中敌人死亡/增员改变迭代集合）；★2026-09-16 性能批：走注册表拷贝，替代全场景扫
        List<EnemyController> enemies = new List<EnemyController>(UnitOccupancy.LivingEnemies);

        // ★回合开始（威胁预告与搜索 §3 / §7.1）：
        //   ① 陷阱红`!`冻结回合已过 → 转黄`?`散开搜索（参照点 = 陷阱格）
        //   ② 上一回合问号阶段的移动已走完 → 推进阶段（黄`?`→白`?`归队回已损75%、
        //      白`?`归队→白`?`回巡逻回剩余25%、白`?`回巡逻→复原：疾跑清零 + 意图重置 + 资格恢复）
        foreach (EnemyController enemy in enemies)
        {
            if (enemy == null || enemy.IsDead) continue;
            // 回合起点快照（任何移动之前），与 EnemyTurnExecutor 同一套不变量
            enemy.MarkTurnStart();
            if (enemy.PendingTrapSearch) enemy.ConvertTrapAlertToSearch();
            else enemy.AdvanceDisengagePhase();
        }

        // ★2026-09-05 清除上一轮的丢失目标"?"（用户定稿：敌人再动时问号消失，
        // 恢复正常巡逻表现）；若本次移动后仍没找到玩家，下方会重新设置。
        // 问号阶段（黄`?`/白`?`）的徽章由脱战状态机接管，这里不能清。
        foreach (EnemyController enemy in enemies)
        {
            if (enemy == null || enemy.IsDead || enemy.IsCurious) continue;
            if (enemy.SearchPhase != EnemyController.DisengagePhase.None) continue;
            enemy.ClearQuestionMark();
        }

        HashSet<EnemyController> handled = new HashSet<EnemyController>();
        HashSet<SquadPatrolGroup> groups = new HashSet<SquadPatrolGroup>();
        var searchers = new List<EnemyController>();
        var scatter = new List<EnemyController>();   // 黄`?`散开搜索：整批统一解算槽位（§12）

        foreach (EnemyController enemy in enemies)
        {
            if (enemy != null && enemy.PatrolGroup != null) groups.Add(enemy.PatrolGroup);
        }

        var jobs = new List<IEnumerator>();

        foreach (EnemyController enemy in enemies)
        {
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;
            if (enemy.IsSearching)
            {
                scatter.Add(enemy);
                handled.Add(enemy);
                continue;
            }
            if (enemy.PatrolGroup != null && enemy.PatrolGroup.IsIdleMember(enemy)) continue;

            if (enemy.IsChasing || enemy.IsResting || enemy.IsReturningHome)
            {
                searchers.Add(enemy);
            }
            jobs.Add(enemy.PatrolTurn());
            handled.Add(enemy);
        }

        foreach (SquadPatrolGroup group in groups)
        {
            if (group == null) continue;
            jobs.Add(group.ExecutePatrolTurn());
        }

        foreach (EnemyController enemy in enemies)
        {
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;
            if (handled.Contains(enemy)) continue;
            if (enemy.PatrolGroup != null) continue;
            if (enemy.IsChasing || enemy.IsResting || enemy.IsReturningHome)
            {
                searchers.Add(enemy);
            }
            jobs.Add(enemy.PatrolTurn());
        }

        UnitOccupancy.PatrolLandingClaims.Begin();
        try
        {
            yield return CoroutineBatch.WhenAll(this, jobs);

            // ★黄`?`散开搜索（威胁预告与搜索 §12）：批量移动、无落点预览（§9）。
            //   职责槽位扇形散开 + leash 裁剪 + 落点互斥，整批一次解算。
            if (scatter.Count > 0)
            {
                List<SearchScatterPlanner.SearchMove> moves = SearchScatterPlanner.Plan(scatter);
                yield return SearchScatterPlanner.RunMoves(this, moves);
            }
        }
        finally
        {
            UnitOccupancy.PatrolLandingClaims.End();
        }

        // 问号阶段的移动本回合已执行 → 下回合开始才推进阶段（§3：回血发生在该阶段的敌人回合内）
        foreach (EnemyController enemy in enemies)
        {
            if (enemy != null && !enemy.IsDead) enemy.MarkPhaseMoveDone();
        }

        AlertPropagation.Refresh();
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            ExplorationPerf.EndEnemyPhase();   // 进战提前退出：照样出一行摘要
            yield break;
        }

        foreach (EnemyController enemy in enemies)
        {
            if (CheckPatrolVisionPublic(enemy))
            {
                ExplorationPerf.EndEnemyPhase();   // 被动遇袭提前退出：照样出一行摘要
                yield break;
            }
        }

        foreach (EnemyController enemy in searchers)
        {
            if (enemy != null && !enemy.IsDead) enemy.SetLostTarget();
        }

        // 巡逻结束 → 下一探索回合
        ExplorationPerf.EndEnemyPhase();
        StartNewExplorationTurn();
    }

    /// <summary>巡逻落点是否看见玩家；看见则被动进战并返回 true（调用方应中止巡逻阶段）。</summary>
    public bool CheckPatrolVisionPublic(EnemyController enemy)
    {
        if (playerMover == null || enemy == null || enemy.IsDead || enemy.data == null) return false;
        if (!VisionSystem.CanSee(enemy.CurrentCoord, playerMover.CurrentCoord, enemy.data.visionRange, VisionSystem.EnemyGreenPenalty))
        {
            return false;
        }
        Debug.Log($"[探索] 巡逻撞见！「{enemy.gameObject.name}」看见玩家 → 被动遇袭进战斗");
        // ★发现者标记（§5）：进战后第一次揭示意图时直接获得疾跑 1；
        //   同队经传导警戒者不打标记 → 不额外获得（§10.2）
        enemy.MarkPassiveEncounterSpotter(playerMover.CurrentCoord);
        StartBattlePassively(enemy);
        return true;
    }
    /// <summary>
    /// ★事件失败进战入口（design §3.3）。顺序：事件弹窗已关 → 这里刷怪 + 全部置警戒 → 被动遇袭。
    /// 玩家先手走既有 <see cref="StartBattlePassively"/> 路径（含发现者标记 / 骰转能量 / 无免费整备）。
    /// </summary>
    public void StartEventCombat(int enemyCount)
    {
        if (playerMover == null) { Debug.LogWarning("[事件进战] 找不到玩家，忽略"); return; }

        List<EnemyController> spawned = EventCombatSpawner.SpawnAt(playerMover.CurrentCoord, enemyCount);
        if (spawned == null || spawned.Count == 0)
        {
            Debug.LogWarning("[事件进战] 没生成出敌人，跳过进战");
            return;
        }

        // 全部置警戒 → AlertPropagation.CollectAlertedSeeds 才会把他们算进参战范围
        foreach (EnemyController c in spawned)
        {
            if (c != null && !c.IsDead) c.BecomeAlerted(true);
        }

        // 以「离玩家最近的生成者」为发现者（自己生成的就是当前的发现者，标记本该归它）
        EnemyController trigger = spawned[0];
        int best = int.MaxValue;
        foreach (EnemyController c in spawned)
        {
            if (c == null || c.IsDead) continue;
            int d = CardExecutor.HexDistance(c.CurrentCoord, playerMover.CurrentCoord);
            if (d < best) { best = d; trigger = c; }
        }

        StartBattlePassively(trigger);
    }

    /// <summary>
    /// ★被动遇袭进战斗（探索系统 v2 §9.1.3 结局C / 巡逻撞见，2026-09-05 用户定稿：玩家先手）。
    /// 顺序：① 清全场警戒标记（意图徽章接管）② D11 能量转化——超过 3 的能量 1:1 转玩家首回合 AP
    /// （防囤能量）③ 切战斗态 → BeginBattleFromExploring(enemySurprise=true)：
    /// 玩家先手 + 参战敌人首回合 +enemySurpriseAPBonus 行动点（敌人先看见了玩家，总策划案 §10.6.1）。
    /// 参战范围：触发者 + 当前警戒中的敌人，再由结算器按同 SquadId 扩编。
    /// </summary>
    private void StartBattlePassively(EnemyController trigger)
    {
        Debug.Log("[探索] 被动遇袭 → 进战斗（玩家先手，敌人首回合 AP 加成）");

        AlertPropagation.Refresh();
        var seeds = AlertPropagation.CollectAlertedSeeds(trigger);
        int living = 0;
        if (BattleResultHandler.Instance != null)
        {
            living = BattleResultHandler.Instance.BeginEncounter(seeds);
        }
        if (living <= 0)
        {
            Debug.Log("[探索] 参战敌人已全灭，无需进战斗");
            return;
        }

        AlertPropagation.OnEnterCombat(seeds);

        // ★偷袭资格消耗（§6.2）：进入过战斗 = 该小队本警戒周期不再可被偷袭（与徽章颜色无关）
        foreach (EnemyController seed in seeds)
        {
            if (seed != null) SquadAlertCycle.MarkEnteredBattle(seed);
        }

        // ② 骰转能量照旧给（§5：永远有、硬顶 9=能量上限），但**无免费整备**——被动遇袭不是偷袭
        EnergyPointDisplay energyDisplay = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存
        if (energyDisplay != null)
        {
            // ★2026-09-13 定稿：被动遇袭首回合同样视为已整备（占位锁，不补能量），
            //   否则被动方能「打完 3 能量再整备拿 3」，反而比偷袭方多一轮能量。
            energyDisplay.MarkPrepareLockedNoGain();
            int remaining = RemainingExplorationDice();
            if (remaining > 0)
            {
                int gained = energyDisplay.AddEnergyTowardCap(remaining, ambushLeftoverDiceEnergyCap);
                Debug.Log($"[探索] 被动遇袭：剩余 {remaining} 枚骰转能量 +{gained}（硬顶 {ambushLeftoverDiceEnergyCap}），无免费整备");
            }
        }
        ClearDicePool();

        // ③（2026-09-13 定稿）原 D11 进战一次性转化已删：能量超 3 → 行动点改为
        //    「每个回合开始」通用结算（TurnManager.StartNewTurn / 探索回合开始），此处不再重复。

        // ④ 切战斗态 → 玩家先手（敌人首回合 AP 加成未实装，维持现状）
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.SwitchToBattle();
        }
        if (TurnManager.Instance != null)
        {
            TurnManager.Instance.BeginBattleFromExploring(enemySurprise: true);
        }
    }

    /// <summary>
    /// ★偷袭入口（威胁预告与搜索 §6.1 / §6.2，2026-09-07 定稿）：探索态玩家直接攻击任何敌人触发。
    /// 流程：强制结束当前探索回合 → 进战斗·新的玩家回合（玩家先手、敌人无首回合加成）。
    ///
    /// 奖励分档由**小队资格**决定（§6.2 单一判据）：一个警戒周期（意图开始 → 复原）内，
    /// 小队第一次受到探索态玩家直接攻击 = 全额偷袭（免费整备 + 骰转能量）；
    /// 此后资格耗尽——**消耗条件 = 进入过战斗**（偷袭 / 被动遇袭 / 传导参战都算），与徽章颜色无关。
    /// 资格耗尽后入口流程照走，只是**没有免费整备**；骰转能量永远给（硬顶 9=能量上限，
    /// 2026-09-13 定稿：超出 3 的部分在战斗回合开始统一转行动点，不再区分入场方式）。
    /// </summary>
    public void TriggerAmbush(List<EnemyController> hitEnemies = null)
    {
        OnAmbushLaunched?.Invoke(); // ★教学 T4：偷袭入口成立

        // ★教学接管 v2.2（2026-09-13）：整段偷袭流程（资格/好奇邻居/参战登记/免费整备/
        //   骰转能量/清骰池/进战斗）**全部**延迟给 TutorialDirector——教程要在打完牌后先讲
        //   「非战斗出牌消耗」（S9，此刻骰池与能量必须保持出牌前的原样），玩家确认后
        //   自动结束回合（S10 挂起式），最后 S13 才执行结算并进战斗。
        //   旧版只延迟「进战斗」半截：结算半截（免费整备+骰转能量+清骰池）在出牌瞬间就跑，
        //   导致 S9 展示的骰池/能量已是结算后的错误状态（用户实测：「打出纵劈后立即来到了下一回合」）。
        if (TutorialDeferAmbushBattle)
        {
            _pendingAmbushBattle = true;
            _pendingAmbushHitEnemies = hitEnemies;
            diceAPUsedThisTurn = 0;
            isEndTurnRequested = false;
            Debug.Log("[探索] 教学：偷袭整段结算已接管（延迟到 TutorialCompleteAmbushBattle）");
            return;
        }

        RunAmbushSettlement(hitEnemies);
    }

    /// <summary>偷袭结算主体（TriggerAmbush 原有流程；教学接管期间由 TutorialCompleteAmbushBattle 调用）。</summary>
    private void RunAmbushSettlement(List<EnemyController> hitEnemies)
    {
        // ⓪ 先结算偷袭资格（必须在进战标记之前问，否则会被自己刚打上的标记吃掉）
        //   多小队被同一张牌命中 → 只要有一支资格完整就算全额（各队独立记账，§6.2）
        bool fullAmbush = false;
        if (hitEnemies != null)
        {
            foreach (EnemyController hit in hitEnemies)
            {
                if (hit == null) continue;
                if (SquadAlertCycle.TryConsumeAmbush(hit)) fullAmbush = true;
            }
        }

        Debug.Log(fullAmbush
            ? "[探索] 偷袭成立（全额：本警戒周期首次）→ 强制结束探索回合 → 进战斗（玩家先手，免费整备 + 骰转能量）"
            : "[探索] 偷袭入口成立但该小队已进过战 → 资格已耗：无免费整备，骰转能量照旧（§6.2）");

        // ⓪' 强制结束当前探索回合：清每回合计账（骰换AP次数、结束回合请求位），
        //    本回合剩余流程（巡逻阶段等）不再执行——直接被战斗回合取代
        diceAPUsedThisTurn = 0;
        isEndTurnRequested = false;

        AlertPropagation.Refresh();
        if (hitEnemies != null)
        {
            foreach (EnemyController hit in hitEnemies)
            {
                if (hit == null || hit.SquadId < 0) continue;
                foreach (EnemyController e in AlertPropagation.LivingEnemies())
                {
                    if (e.SquadId != hit.SquadId || e == hit) continue;
                    if (e.IsAlerted || e.IsCurious) continue;
                    // ★2026-09-14 意图层级保护：已参战的队友不降级为问号（战斗意图 > 问号）。
                    //   实锤症状：战斗中同队怪被这条"围观"逻辑写成问号，战斗意图被覆盖。
                    if (BattleResultHandler.Instance != null
                        && BattleResultHandler.Instance.IsParticipant(e)) continue;
                    e.BecomeCurious(hit, promoteNextTurn: true);
                }
            }
        }
        var seeds = AlertPropagation.CollectAlertedSeeds(null);
        if (hitEnemies != null)
        {
            foreach (EnemyController hit in hitEnemies)
            {
                if (hit != null && !seeds.Contains(hit)) seeds.Add(hit);
            }
        }
        int living = 0;
        if (BattleResultHandler.Instance != null)
        {
            living = BattleResultHandler.Instance.BeginEncounter(seeds);
        }
        if (living <= 0 && (BattleResultHandler.Instance == null || !BattleResultHandler.Instance.HasPendingSameSquad()))
        {
            Debug.Log("[探索] 偷袭击杀后无存活参战者，保持探索");
            return;
        }

        AlertPropagation.OnEnterCombat(seeds);

        // ★资格消耗（§6.2）：进入过战斗的小队本警戒周期不再可被偷袭——
        //   经传导一起参战的其他小队同样消耗（各队独立记账）
        foreach (EnemyController seed in seeds)
        {
            if (seed != null) SquadAlertCycle.MarkEnteredBattle(seed);
        }

        EnergyPointDisplay energyDisplay = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存
        if (energyDisplay != null)
        {
            if (fullAmbush)
            {
                energyDisplay.ApplyFreePrepare();
            }
            else
            {
                // ★2026-09-13 定稿：偷袭资格耗尽=无免费整备 → 与被动遇袭同款首回合占位锁
                energyDisplay.MarkPrepareLockedNoGain();
            }
            int remaining = RemainingExplorationDice();
            int gained = energyDisplay.AddEnergyTowardCap(remaining, ambushLeftoverDiceEnergyCap);
            Debug.Log($"[探索] 偷袭奖励：{(fullAmbush ? "免费整备 + " : "无免费整备（资格已耗） + ")}剩余 {remaining} 枚骰转能量 +{gained}（硬顶 {ambushLeftoverDiceEnergyCap}，多余浪费）");
        }
        ClearDicePool();

        // ③ 切战斗态 → 玩家先手、敌人无加成
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.SwitchToBattle();
        }
        if (TurnManager.Instance != null)
        {
            TurnManager.Instance.BeginBattleFromExploring(enemySurprise: false);
        }
    }

    // ------------------------------------------------------------------
    // ★2026-09-12 教学接管 API（TutorialDirector 专用，正常流程不经过）
    // ------------------------------------------------------------------

    /// <summary>教学接管：偷袭整段结算（含进战斗）延迟给 TutorialDirector（正常流程不经过）。</summary>
    public static bool TutorialDeferAmbushBattle;
    private bool _pendingAmbushBattle;
    private List<EnemyController> _pendingAmbushHitEnemies;

    /// <summary>
    /// 教学用挂起式回合结束：与 FinishExplorationTurn 相同的清结算（手牌洗回 / 剩余骰转能量 /
    /// 清骰池 / AP 清零 / 战术卡 tick），但**跳过**警戒三结局、敌人巡逻与下一回合启动——
    /// 回合停在「等待」状态，由 TutorialDirector 决定何时 TutorialStartPlayerTurn。
    /// </summary>
    public void TutorialEndTurnHold()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring)
        {
            Debug.LogWarning("[探索] 教学：TutorialEndTurnHold 只在探索态有效");
            return;
        }
        if (CardPackUI.Instance != null && CardPackUI.Instance.IsOpen) CardPackUI.Instance.Hide();

        _playerPhase = false;
        Interactions.RefreshEndTurnButton();

        if (CardPileManager.Instance != null) CardPileManager.Instance.DiscardAllHand();
        if (HandUIController.Instance != null) HandUIController.Instance.ClearSelection();
        ConvertLeftoverExplorationDiceToEnergy(diceToEnergyCapPerTurn);
        ClearDicePool();
        if (playerMover != null) playerMover.currentActionPoints = 0;
        TacticSlotRuntime.TickEndOfTurn();
        Debug.Log("[探索] 教学：回合结束并挂起（等待 TutorialDirector 指令）");
    }

    /// <summary>教学用：从挂起中恢复，立即开始一个新的探索玩家回合。</summary>
    public void TutorialStartPlayerTurn()
    {
        Debug.Log("[探索] 教学：恢复玩家回合");
        StartNewExplorationTurn();
    }

    /// <summary>教学用：把当前骰池设为恰好 n 枚（不动 dicePerTurn，只改本轮显示与可用骰）。</summary>
    public void TutorialSetDicePool(int n)
    {
        if (diceArea == null) diceArea = GameObject.Find("UICanvas/StatusBar/DiceArea");
        if (diceArea == null) return;
        int activated = 0;
        foreach (Transform child in diceArea.transform)
        {
            if (!child.name.StartsWith("Dice6Button")) continue;
            bool active = activated < n;
            child.gameObject.SetActive(active);
            if (active)
            {
                Button b = child.GetComponent<Button>();
                if (b != null) b.interactable = true;
            }
            activated++;
        }
    }

    /// <summary>教学用：完成被接管的伏击——执行整段偷袭结算（免费整备/骰转能量/参战登记）并进入战斗（玩家先手、敌人无加成）。</summary>
    public void TutorialCompleteAmbushBattle()
    {
        if (!_pendingAmbushBattle)
        {
            Debug.LogWarning("[探索] 教学：没有待完成的伏击");
            return;
        }
        _pendingAmbushBattle = false;
        var hits = _pendingAmbushHitEnemies;
        _pendingAmbushHitEnemies = null;
        Debug.Log("[探索] 教学：伏击接管结束 → 执行偷袭结算 → 进入战斗（玩家先手）");
        RunAmbushSettlement(hits);
    }

    // ------------------------------------------------------------------
    // 骰子换行动点（D1 §4.1：耗 1 骰 → +diceAP 行动点，每回合上限 diceAPCap 枚）
    // ------------------------------------------------------------------

    /// <summary>
    /// 探索态还能否耗骰换行动点（DiceDragHandler.OnDiceButtonClicked 开头查询）。
    /// </summary>
    public bool CanSpendDiceForAP()
    {
        return diceAPUsedThisTurn < diceAPCapPerTurn;
    }

    /// <summary>
    /// 记账一次「耗 1 骰换行动点」（DiceDragHandler 掷骰结算加 AP 时调用）。
    /// </summary>
    public void RecordDiceForAP()
    {
        if (diceAPUsedThisTurn < diceAPCapPerTurn)
        {
            diceAPUsedThisTurn++;
        }
    }

    /// <summary>本回合已用于换行动点的骰子数（UI/调试用）</summary>
    public int DiceAPUsedThisTurn => diceAPUsedThisTurn;

    /// <summary>
    /// ★2026-08-25 探索骰子消耗公共 API（探索系统 v2 §2.2 / §7.3）：
    /// 鉴定投骰（④最终判定）、复杂行动等场景统一走这里扣 1 枚探索骰子。
    /// 扣法与整备一致：找第一个「激活且可交互」的骰子按钮 → 禁用并隐藏（OnPrepareDiceClicked）。
    /// </summary>
    /// <returns>true = 成功消耗一枚；false = 骰池已空</returns>
    public bool TryConsumeExplorationDice()
    {
        if (diceArea == null) return false;

        foreach (Transform child in diceArea.transform)
        {
            if (!child.name.StartsWith("Dice6Button")) continue;
            if (!child.gameObject.activeSelf) continue;

            Button diceButton = child.GetComponent<Button>();
            if (diceButton == null || !diceButton.interactable) continue;

            // 与整备同款消耗：禁用 + 隐藏（D17 回合结束转化判定会自动跳过它）
            child.GetComponent<DiceDragHandler>()?.OnPrepareDiceClicked();
            OnExplorationDiceConsumed?.Invoke();   // ★教学钩子：S3「消耗一枚探索骰」解除判定
            return true;
        }
        return false;
    }

    /// <summary>当前探索骰池剩余枚数（activeSelf 且 interactable 的骰子按钮数）</summary>
    public int RemainingExplorationDice()
    {
        if (diceArea == null) return 0;

        int count = 0;
        foreach (Transform child in diceArea.transform)
        {
            if (!child.name.StartsWith("Dice6Button")) continue;
            Button diceButton = child.GetComponent<Button>();
            if (child.gameObject.activeSelf && diceButton != null && diceButton.interactable)
            {
                count++;
            }
        }
        return count;
    }

    /// <summary>当前探索回合数</summary>
    public int GetCurrentTurn() => currentTurn;

    /// <summary>
    /// ★2026-09-10：把当前剩余（未投出）的探索骰子 1:1 转能量，硬顶 <paramref name="cap"/> 点（已高于 cap 则浪费）。
    /// 探索回合结束与战斗回合结束共用——战斗态结束回合也要转化（用户需求：与探索模式一致，最多回到 3 点）。
    /// 剩余判定 = 骰子按钮激活且可交互（点击/消耗过的骰子 interactable=false 不算剩余）。
    /// </summary>
    public void ConvertLeftoverExplorationDiceToEnergy(int cap)
    {
        EnergyPointDisplay energyDisplay = ExplorationPerf.Energy;   // ★2026-09-16 性能二批：缓存（回合结束热路径）
        if (energyDisplay == null || diceArea == null) return;

        int remainingDice = RemainingExplorationDice();
        if (remainingDice > 0)
        {
            int gained = energyDisplay.AddEnergyTowardCap(remainingDice, cap);
            Debug.Log($"[探索] 剩余 {remainingDice} 枚探索骰转能量 +{gained}（能量硬顶 {cap}，多余浪费）");
        }
    }

    // ------------------------------------------------------------------
    // 骰池 UI（与 TurnManager 同款逻辑的探索版：激活前 N 枚 / 清空全部）
    // ------------------------------------------------------------------

    /// <summary>补满骰池：激活前 dicePerTurn 枚骰子按钮并重置为 6 点图标</summary>
    private void ActivateDicePool()
    {
        if (diceArea == null)
        {
            Debug.LogError("[探索] DiceArea 对象未找到");
            return;
        }

        int activated = 0;
        foreach (Transform child in diceArea.transform)
        {
            if (!child.name.StartsWith("Dice6Button")) continue;

            // 只激活前 N 枚（探索骰子经济 §2.1：每回合 N 枚，枚数不足时多余按钮隐藏）
            bool active = activated < dicePerTurn;
            child.gameObject.SetActive(active);
            activated++;

            if (!active) continue;

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
                    Destroy(child.GetChild(i).gameObject);
                }
            }

            // 恢复为 6 点状态
            DiceDragHandler diceDragHandler = child.GetComponent<DiceDragHandler>();
            if (diceDragHandler != null)
            {
                diceDragHandler.UpdateDiceButtonIcon(6);
            }
        }
    }

    /// <summary>清空骰池：隐藏全部骰子按钮</summary>
    private void ClearDicePool()
    {
        if (diceArea == null) return;

        foreach (Transform child in diceArea.transform)
        {
            if (child.name.StartsWith("Dice6Button"))
            {
                child.gameObject.SetActive(false);
            }
        }
    }
}

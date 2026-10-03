// =============================================================================
// 模块：Tutorial - 教学编排器 TutorialDirector（v2 通用解释器，读 TutorialSteps 配置）
// 用途：读 TutorialSteps.asset，按每条拍的「触发/解除 + 激活动作」驱动全流程新手教学：
//       UI 显隐 / 骰子·能量设定 / 检查点截停 / 挂起回合 / 限定格·禁行格 /
//       相机运镜 / 出牌触发 / 教学牌库 / 伏击接管 / 操作锁。
// 设计依据：2026-09-12 用户口述全流程（S1–S20）+ 2026-09-13 口述 S21–S29 + docs/tutorial-design.md §5。
// 实现要点：
//   - [RuntimeInitializeOnLoadMethod] 在教程图(TutorialScene + IsTutorial)且未完成时自动挂载；
//     OnStart 拍在 Awake 立即激活 —— 保证 dicePerTurn=0 等「激活动作」先于各系统 Start。
//   - 顺序门控：frontier = steps[_doneCount]；激活 = 执行激活动作 + 弹提示卡；
//     解除 = 按拍配置（知道了/移动/到达/出牌/整备/镜头操作/开箱子/开背包/用消耗品…）→ 推进。
//   - 玩家操作锁统一写进 Interactions（TutorialLockInput / TutorialAllowedCell /
//     TutorialBlockedCells / TutorialCheckpointCells），HexMover·DiceDragHandler·MapHotkeys 消费。
//   - ★v2.3（2026-09-13）焦点改成**一条 FocusRing + 单蒙版多洞**：主焦点与第二焦点同时亮。
//     另外「要玩家点『知道了』又没有高亮目标」的拍整屏压暗（ShowDim），避免玩家误以为能操作。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

namespace Tutorial
{
    public class TutorialDirector : MonoBehaviour
    {
        private TutorialSteps _cfg;
        private int _doneCount = 0;

        /// <summary>★v2.6 重投教学门禁：教程期 CardView 默认不创建重投按钮；
        /// 激活动作 enableReroll 的拍（S41）激活时置 true，重投按钮才出现。
        /// 非教程图恒为 true 语义（CardView 侧用 IsTutorial 判定，不读此值）。</summary>
        public static bool RerollEnabled = false;
        private int _activeIndex = -1;          // 当前已激活的拍（= _doneCount）
        private int _armedIndex = -1;           // ★2026-09-14 门槛型触发（triggerEnergyBelow）：
                                                //   事件已到达但附加条件未满足时"武装"住这一拍，
                                                //   由 Update 每帧重试（只是状态不是事件——见 S18）
        private bool _releasePending = false;   // 解除延迟计时中（releaseDelay > 0 的拍）
        private Coroutine _releaseCo = null;    // ★v2.4 延迟解除协程引用（回退时要能掐掉，否则它会解除错拍）
        private bool _enemySeen = false;
        private int _redQuestionCount = 0;
        private Vector2Int _spawnCoord = new Vector2Int(int.MinValue, int.MinValue);

        private TutorialFocusRing _focusA;      // 唯一焦点环（主焦点 + 可选第二焦点，共用一张蒙版）
        private TutorialTipCardUI _tip;
        private HexMover _hexMover;
        private EnergyPointDisplay _energy;

        // 禁行格染色还原记录
        // ★2026-09-15 地图重构：格子不再自带渲染器 → 改用坐标做键
        private readonly Dictionary<Vector2Int, Color> _blockedOriginal = new Dictionary<Vector2Int, Color>();
        // ★2026-09-13：与不可通行格（Mountain 红墙）同色——单一数据源，用户要求视觉一致
        private static readonly Color BlockedRed = TerrainManager.DefaultColorFor(TerrainManager.TerrainType.Mountain);

        // 战斗胜利是否已结算过（S20 兜底：胜利早于 S20 成为 frontier 时，轮到它时立即激活）
        private bool _victoryFired = false;

        // ★v2.4 已生成过教学箱子的坐标——防止「拍回退后重新激活」时重复 AddItem 刷物品。
        //   （SpawnTutorialChest 本身不幂等：CorpseRegistry.Spawn 同坐标会返回已有袋子，
        //     紧接着的 AddItem 会把骰子/药水再加一遍。）
        private readonly HashSet<Vector2Int> _spawnedChests = new HashSet<Vector2Int>();

        // -------- 自动挂载（仅教程图 + 未完成） --------
        // ★2026-09-14 修复「进了教程图但教学卡不弹」：
        //   原实现用 [RuntimeInitializeOnLoadMethod] 直接挂载 —— 那是**应用启动回调**，
        //   只在「第一个场景加载完」时执行一次，不是「每次场景加载」。
        //   从藏身处经过开发者面板 / 启动路由 LoadScene 进 TutorialScene 时，回调早已跑过
        //   （而且当时还在藏身处、MapLayoutBuilder.IsTutorial == false），
        //   于是教程图里根本没有 Director → 画面进了教程图、提示卡一张不弹、Console 无日志。
        //   改为订阅 SceneManager.sceneLoaded + 幂等 TryMount：任何场景加载完都重试一次。
        //   ⚠️ sceneLoaded 在本场景对象的 Awake/OnEnable 之后、Start 之前触发，
        //     所以 dicePerTurn=0 这类「激活动作必须早于各系统 Start」的时序仍然成立。
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void AutoStart()
        {
            SceneManager.sceneLoaded -= OnSceneLoaded;   // 幂等：域重载后避免重复订阅
            SceneManager.sceneLoaded += OnSceneLoaded;
            TryMount();                                   // 覆盖「直接从教程图启动 Play」
        }

        private static void OnSceneLoaded(Scene scene, LoadSceneMode mode) => TryMount();

        /// <summary>满足「教学未完成 + 当前是教程图 + 本场景还没有 Director」才挂载。</summary>
        private static void TryMount()
        {
            if (!TutorialProgress.IsTutorialPending) return;
            if (!MapLayoutBuilder.IsTutorial) return;
            if (FindObjectOfType<TutorialDirector>() != null) return;   // 本场景已挂
            var go = new GameObject("TutorialDirector");
            go.AddComponent<TutorialDirector>();
            Debug.Log("[Tutorial] Director 已挂载（v2 全流程解释器）");
        }

        private void Awake()
        {
            _cfg = Resources.Load<TutorialSteps>("Tutorial/TutorialSteps");
            if (_cfg == null || _cfg.steps == null || _cfg.steps.Count == 0)
            {
                Debug.LogError("[Tutorial] 找不到 TutorialSteps 配置（Assets/Resources/Tutorial/TutorialSteps.asset）。教学未启动。");
                enabled = false;
                return;
            }

            _hexMover = FindObjectOfType<HexMover>();
            _energy = FindObjectOfType<EnergyPointDisplay>();   // 趁还没被 uiHide 隐藏时缓存
            _focusA = NewHolderChild<TutorialFocusRing>("FocusHolderA");
            _tip = NewHolderChild<TutorialTipCardUI>("TipHolder");

            if (GameStateManager.Instance != null)
                GameStateManager.Instance.OnStateChanged += OnStateChanged;
            ExplorationTurnManager.OnExplorationTurnStarted += OnExplorationTurnStarted;
            HexMover.OnPlayerArrived += OnPlayerArrived;
            EnemyIntentBadgeUI.OnRedQuestionStateChanged += OnRedQuestionStateChanged;
            BattleResultHandler.OnBattleVictory += OnBattleVictory;
            ExplorationTurnManager.OnAmbushLaunched += OnAmbushLaunched;
            PlayCardSystem.OnCardPlayed += OnCardPlayed;
            EnergyPointDisplay.OnPrepared += OnPrepared;
            CameraController.OnPlayerOperatedCamera += OnCameraOperated;
            ExplorationTurnManager.OnExplorationDiceConsumed += OnExplorationDiceConsumed;
            // ★v2.2（2026-09-13）篝火 / 遗物袋 / 装填 三条链路的解除钩子
            BonfireUI.OnBonfireOpened += OnBonfireOpened;
            BonfireUI.OnRested += OnBonfireRested;
            LootPopupUI.OnLootTaken += OnLootTaken;
            LoadoutUI.OnConfigured += OnLoadoutConfigured;
            // ★v2.3（2026-09-13）开箱 / 背包开关 / 用消耗品 三条链路的解除钩子
            LootPopupUI.OnLootOpened += OnLootOpened;
            LootPopupUI.OnLootEmptied += OnLootBagEmptied;      // ★v2.3.1 S25「拿空」判据
            LootPopupUI.OnLootAbandoned += OnLootBagAbandoned;  // ★v2.4 拿一半就走 → 回退一拍
            InventoryUI.OnInventoryOpened += OnInventoryOpened;
            InventoryUI.OnInventoryClosed += OnInventoryClosed;
            ConsumableBar.OnConsumableUsed += OnConsumableUsed;
            // ★v2.4（2026-09-13）卡包 / 装填界面 的解除钩子（S29-S33 装填教学）
            CardPackUI.OnCardPackOpened += OnCardPackOpened;
            CardPackUI.OnCardPackClosed += OnCardPackClosed;
            LoadoutUI.OnOpened += OnLoadoutOpened;
            LoadoutUI.OnClosed += OnLoadoutClosed;
            LoadoutUI.OnCardSelected += OnLoadoutCardSelected;
            LoadoutUI.OnSlotSelected += OnLoadoutSlotSelected;
            // ★v2.6 重投教学（S41）：玩家完成一次重投 → 推进（「知道了」兜底由 RequestRelease 天然支持）
            CardRerollButton.OnRerolled += OnRerollUsed;
            RerollEnabled = false;      // 教学启动时重置门禁（静态字段跨场景不自动清）
            // ★2026-09-14 同理重置「自动整备」开关的显示门禁：教程期 S19 之前整体隐藏，
            //   教学重新开始时（重看教程/删档）必须复位，否则会沿用上一局的「已点亮」。
            AutoPrepareToggle.SetTutorialRevealed(false);
            if (TurnManager.Instance != null)
                TurnManager.Instance.OnPlayerTurnStarted += OnPlayerTurnStarted;

            // 教程期间：伏击的「进战斗」半截交给本 Director 接管（S13 completeAmbush 时关闭）
            ExplorationTurnManager.TutorialDeferAmbushBattle = true;

            // OnStart 拍立即激活（先于各系统 Start：dicePerTurn=0 必须赶在首回合补骰前）
            TryActivateFrontier();
        }

        private void OnDestroy()
        {
            if (GameStateManager.Instance != null)
                GameStateManager.Instance.OnStateChanged -= OnStateChanged;
            ExplorationTurnManager.OnExplorationTurnStarted -= OnExplorationTurnStarted;
            HexMover.OnPlayerArrived -= OnPlayerArrived;
            EnemyIntentBadgeUI.OnRedQuestionStateChanged -= OnRedQuestionStateChanged;
            BattleResultHandler.OnBattleVictory -= OnBattleVictory;
            ExplorationTurnManager.OnAmbushLaunched -= OnAmbushLaunched;
            PlayCardSystem.OnCardPlayed -= OnCardPlayed;
            EnergyPointDisplay.OnPrepared -= OnPrepared;
            CameraController.OnPlayerOperatedCamera -= OnCameraOperated;
            ExplorationTurnManager.OnExplorationDiceConsumed -= OnExplorationDiceConsumed;
            BonfireUI.OnBonfireOpened -= OnBonfireOpened;
            BonfireUI.OnRested -= OnBonfireRested;
            LootPopupUI.OnLootTaken -= OnLootTaken;
            LoadoutUI.OnConfigured -= OnLoadoutConfigured;
            LootPopupUI.OnLootOpened -= OnLootOpened;
            LootPopupUI.OnLootEmptied -= OnLootBagEmptied;
            LootPopupUI.OnLootAbandoned -= OnLootBagAbandoned;
            InventoryUI.OnInventoryOpened -= OnInventoryOpened;
            InventoryUI.OnInventoryClosed -= OnInventoryClosed;
            ConsumableBar.OnConsumableUsed -= OnConsumableUsed;
            CardPackUI.OnCardPackOpened -= OnCardPackOpened;
            CardPackUI.OnCardPackClosed -= OnCardPackClosed;
            LoadoutUI.OnOpened -= OnLoadoutOpened;
            LoadoutUI.OnClosed -= OnLoadoutClosed;
            LoadoutUI.OnCardSelected -= OnLoadoutCardSelected;
            LoadoutUI.OnSlotSelected -= OnLoadoutSlotSelected;
            CardRerollButton.OnRerolled -= OnRerollUsed;
            if (TurnManager.Instance != null)
                TurnManager.Instance.OnPlayerTurnStarted -= OnPlayerTurnStarted;
            RestoreBlockedTiles();
        }

        private T NewHolderChild<T>(string name) where T : Component
        {
            var go = new GameObject(name, typeof(RectTransform));
            go.transform.SetParent(transform, false);
            return go.AddComponent<T>();
        }

        // ==================================================================
        // 门控核心
        // ==================================================================
        private void TryActivateFrontier()
        {
            if (_doneCount >= _cfg.steps.Count) return;
            var step = _cfg.steps[_doneCount];
            // ★2026-09-14 清场门槛（用户定稿 · S42 前往藏身处）：场上还有存活敌人 → 本拍暂不出现。
            //   配合 Update 的每帧重试：杀死最后一只怪的瞬间自动推进（不必等事件）。
            if (step.requireAllEnemiesDefeated && AnyLivingEnemy()) return;
            // ★2026-09-14 能量门槛（S18）：门槛未满足就不激活（TryTrigger 会武装，Update 每帧重试）
            if (!TriggerGateOpen(step)) return;
            if (step.trigger == TutorialTrigger.OnStart && _doneCount == 0)
                ActivateStep(_doneCount);
            else if (step.trigger == TutorialTrigger.OnPreviousReleased)
                ActivateStep(_doneCount);
            // ★胜利兜底：VictorySettled 事件在更早的拍激活期间已经广播过、轮到本拍时事件不会再发
            else if (step.trigger == TutorialTrigger.VictorySettled && _victoryFired)
                ActivateStep(_doneCount);
        }

        /// <summary>
        /// 场上是否还有存活敌人（S42「战胜两只怪才出现」门槛）。
        /// 只认绑了数据、未死亡的敌人；未绑格残留（data 为空）不算。
        /// </summary>
        private static bool AnyLivingEnemy()
        {
            foreach (var e in FindObjectsOfType<EnemyController>())
                if (e != null && !e.IsDead && e.data != null) return true;
            return false;
        }

        private void TryTrigger(TutorialTrigger type)
        {
            if (_doneCount >= _cfg.steps.Count) return;
            if (_activeIndex >= 0) return;                 // 已有激活拍，等它解除
            var step = _cfg.steps[_doneCount];
            if (step.trigger != type) return;
            // ★2026-09-14 门槛型触发（S18）：事件到了但条件未满足（如能量还 ≥3，整备不了）→
            //   先"武装"本拍，之后由 Update 每帧重试。期间不锁操作，玩家把能量花下去即可满足。
            if (!TriggerGateOpen(step)) { _armedIndex = _doneCount; return; }
            ActivateStep(_doneCount);
        }

        /// <summary>
        /// ★2026-09-14 拍级附加触发门槛（`triggerEnergyBelow`）。
        /// 事件型触发不够用的情况：S18 的触发事件是「玩家回合开始」，但那时能量可能还 ≥3（无法整备，
        /// `release=Prepared` 永远达不成 → 教学卡死）。这类条件只能轮询，不能只靠事件。
        /// </summary>
        private bool TriggerGateOpen(TutorialStepData step)
        {
            if (step.triggerEnergyBelow < 0) return true;
            if (_energy == null)
            {
                // uiHide 可能已把能量点整体隐藏 → FindObjectOfType 找不到 inactive 对象，用带 true 的重载
                var all = FindObjectsOfType<EnergyPointDisplay>(true);
                _energy = (all != null && all.Length > 0) ? all[0] : null;
            }
            return _energy != null && _energy.CurrentEnergy < step.triggerEnergyBelow;
        }

        /// <summary>激活 frontier：依次执行激活动作 → 弹提示卡（silent 拍不弹）。</summary>
        private void ActivateStep(int index)
        {
            _activeIndex = index;
            var step = _cfg.steps[index];

            // ★2026-09-13 加固：激活动作跨多个子系统，任一环抛异常都不能让教学永久卡死
            //   （实锤：CardView 已销毁仍收到 OnDiceValuesChanged → MissingReferenceException
            //    冲出本方法 → 卡片没弹出、doneCount 不前进 → S5 点确认后彻底卡住）。
            //   异常一律降级为「日志 + 纯文字卡」，保证玩家永远能推进。
            try
            {
                // ---- 1. UI 显隐 ----
                foreach (var n in step.uiHide) foreach (var t in FindUiNodes(n)) t.gameObject.SetActive(false);
                foreach (var n in step.uiShow) foreach (var t in FindUiNodes(n)) t.gameObject.SetActive(true);

                // ---- 2. 数值设定（顺序：骰上限 → 牌库 → 开回合 → 骰池 → 能量）----
                if (step.setDicePerTurn >= 0 && ExplorationTurnManager.Instance != null)
                    ExplorationTurnManager.Instance.dicePerTurn = step.setDicePerTurn;

                if (step.deckSingleCard)
                {
                    if (CardPileManager.Instance != null) CardPileManager.Instance.DiscardAllHand();
                    CardDeckManager.Instance?.TutorialSetDeckToSingleCard(step.cardName);
                    if (!step.startPlayerTurn && CardPileManager.Instance != null && CardDeckManager.Instance != null)
                    {
                        CardPileManager.Instance.InitDrawPileFromDeck(CardDeckManager.Instance.GetPlayableDeck());
                        CardPileManager.Instance.DrawCards(5);
                        HandUIController.Instance?.RefreshHandLayout();
                    }
                }
                if (step.restoreDeck) CardDeckManager.Instance?.TutorialRestoreDeck();

                if (step.startPlayerTurn && ExplorationTurnManager.Instance != null)
                    ExplorationTurnManager.Instance.TutorialStartPlayerTurn();

                if (step.setDice >= 0 && ExplorationTurnManager.Instance != null)
                    ExplorationTurnManager.Instance.TutorialSetDicePool(step.setDice);

                if (step.setEnergy >= 0)
                {
                    if (_energy == null) _energy = FindObjectOfType<EnergyPointDisplay>();
                    if (_energy != null) _energy.SetEnergy(step.setEnergy);
                }

                // ---- 2.5 生成教学箱子（★v2.2：复用遗物袋，玩家走到格上由 LootPopupUI 自动弹窗）----
                if (step.spawnChest) SpawnTutorialChest(step);

                // ---- 2.6 教学清装填（★v2.4 S29-S33：把玩家的卡全部标成「未装填」，
                //      装填教学从零开始；玩家在 S32 装上骰子后自动解除未装填标记）----
                if (step.unloadAllCards && CardDeckManager.Instance != null)
                    CardLoadout.MarkAllUnloaded(CardDeckManager.Instance.Library);

                // ---- 2.7 ★v2.6 解锁教程期重投屏蔽（S41 重投教学拍）----
                if (step.enableReroll) RerollEnabled = true;

                // ---- 2.8 ★2026-09-14 点亮「自动整备」开关（S19 教学拍）----
                //   教程图里该开关默认整体隐藏，只有本拍把它显示出来；
                //   非教程图由 AutoPrepareToggle 自身判定，恒显示。
                if (step.revealAutoPrepare) AutoPrepareToggle.SetTutorialRevealed(true);

                // ---- 3. 回合 / 战斗接管 ----
                if (step.autoEndTurn && ExplorationTurnManager.Instance != null)
                    ExplorationTurnManager.Instance.TutorialEndTurnHold();
                if (step.completeAmbush)
                {
                    // 伏击接管结束：关闭接管开关，之后的战斗/偷袭回归正常流程
                    ExplorationTurnManager.TutorialDeferAmbushBattle = false;
                    if (ExplorationTurnManager.Instance != null)
                        ExplorationTurnManager.Instance.TutorialCompleteAmbushBattle();
                }

                // ---- 4. 相机 ----
                if (step.cameraFly && CameraController.Instance != null)
                    CameraController.Instance.TutorialFlyTo(CellToWorld(step.focusCell));
                if (step.resumeFollow && CameraController.Instance != null)
                    CameraController.Instance.TutorialResumeFollow();

                // ---- 5. 操作门禁 ----
                Interactions.TutorialLockInput = step.lockInput;
                Interactions.TutorialAllowCards = (step.release == TutorialRelease.CardPlayed);
                Interactions.TutorialAllowedCell = step.restrictMove ? (Vector2Int?)step.allowedCell : null;
                Interactions.TutorialCheckpointCells.Clear();
                if (step.watchCheckpoints)
                    foreach (var c in step.cellList) Interactions.TutorialCheckpointCells.Add(c);
                ApplyBlockedTiles(step);
                // ★v2.8 S36 改版（2026-09-14 用户定稿）：指定拍激活时移除场景内全部篝火——
                //   巡逻教学段不再让玩家回头用篝火（配 20 列封锁一起把后方彻底关死）
                if (step.removeBonfire) RemoveTutorialBonfires();
                Interactions.RefreshEndTurnButton();

                // ---- 6. 焦点 + 提示卡 ----
                System.Func<Vector2?> focusGetter = ApplyFocus(step);
                if (!step.silent)
                {
                    System.Action onConfirm = step.showConfirm ? (System.Action)RequestRelease : null;
                    _tip.Show(step.title, step.body, step.showConfirm, onConfirm,
                              focusGetter, step.boxAnchor, step.boxOffset, step.drawLeader, MainFocusRect);
                }
                Debug.Log($"[Tutorial] 激活拍 #{index} [{step.id}] trigger={step.trigger} release={step.release}");
            }
            catch (System.Exception e)
            {
                Debug.LogError($"[Tutorial] 激活拍 #{index} [{step.id}] 激活动作异常（已降级为纯文字卡，教学继续）：{e}");
                try
                {
                    if (!step.silent)
                        _tip.Show(step.title, step.body, step.showConfirm,
                                  step.showConfirm ? (System.Action)RequestRelease : null,
                                  null, step.boxAnchor, step.boxOffset, false, null);
                }
                catch (System.Exception e2)
                {
                    Debug.LogError($"[Tutorial] 兜底弹卡亦失败 #{index}：{e2.Message}");
                }
            }

            // ---- 7. Instant：激活即解除（纯动作拍顺延下一拍）----
            if (step.release == TutorialRelease.Instant)
                RequestRelease();
        }

        /// <summary>
        /// 解除入口（所有外部触发统一走这里）：若当前拍配了 releaseDelay，
        /// 条件达成后先停留 N 秒再收卡推进（期间重复触发不叠加）。
        /// </summary>
        private void RequestRelease()
        {
            if (_activeIndex != _doneCount || _releasePending) return;
            float delay = Mathf.Max(0f, _cfg.steps[_doneCount].releaseDelay);
            if (delay <= 0f) { ReleaseActive(); return; }
            _releasePending = true;
            _releaseCo = StartCoroutine(ReleaseAfterDelay(delay));
        }

        private System.Collections.IEnumerator ReleaseAfterDelay(float delay)
        {
            yield return new WaitForSeconds(delay);
            _releasePending = false;
            _releaseCo = null;
            if (_activeIndex == _doneCount) ReleaseActive();
        }

        /// <summary>解除当前拍 → 推进 → 处理下一拍的 OnPreviousReleased。</summary>
        private void ReleaseActive()
        {
            if (_activeIndex != _doneCount) return;
            var step = _cfg.steps[_doneCount];
            // 镜头教学：在实际解除（含延迟）时才把镜头交还跟随玩家
            if (step.release == TutorialRelease.CameraOperated)
                CameraController.Instance?.TutorialResumeFollow();
            _doneCount++;
            _activeIndex = -1;
            if (!step.silent) _tip.Hide();
            if (_focusA != null) _focusA.Hide();
            if (step.completesTutorial) TutorialProgress.MarkComplete();

            // ★v2.2 禁行格延续判定：本拍封了格、而下一拍不再封（或本拍已是最后一拍）→ 在解除本拍时就恢复。
            //   否则要等下一拍「激活」才清 —— 教程 S21 封的 22 列需要锁到装填教学结束，差这一拍就不对。
            if (Interactions.TutorialBlockedCells.Count > 0)
            {
                bool keep = _doneCount < _cfg.steps.Count && _cfg.steps[_doneCount].blockCells;
                if (!keep)
                {
                    Interactions.TutorialBlockedCells.Clear();
                    RestoreBlockedTiles();
                }
            }

            // ★v2.7 挂起窗解锁：下一拍若不会自动激活（等触发，如 S37 的 ArriveAnyCell），
            //   必须解除上一拍遗留的输入锁/限定格/检查点，否则玩家被锁死、走不到触发格
            //   （实锤：S36 锁定运镜讲解 → 释放后 S37 挂起等移动，锁没清 → 永久卡死）。
            //   注意：禁行格不在这里动 —— 它有自己的延续判定（上面）。
            if (_doneCount < _cfg.steps.Count)
            {
                var frontier = _cfg.steps[_doneCount];
                bool autoActivates = frontier.trigger == TutorialTrigger.OnPreviousReleased
                                     || (frontier.trigger == TutorialTrigger.VictorySettled && _victoryFired);
                if (!autoActivates)
                {
                    Interactions.TutorialLockInput = false;
                    Interactions.TutorialAllowCards = (frontier.trigger == TutorialTrigger.CardPlayed);
                    Interactions.TutorialAllowedCell = null;
                    Interactions.TutorialCheckpointCells.Clear();
                }
            }

            Debug.Log($"[Tutorial] 解除拍 [{step.id}]，doneCount={_doneCount}");
            TryActivateFrontier();
        }

        // ==================================================================
        // 外部触发钩子
        // ==================================================================
        private void OnExplorationTurnStarted() => TryTrigger(TutorialTrigger.ExplorationTurnStarted);

        private void OnStateChanged(GameState oldState, GameState newState)
        {
            if (newState == GameState.Battle) TryTrigger(TutorialTrigger.EnterBattle);
            else if (newState == GameState.Exploring) TryTrigger(TutorialTrigger.EnterExploring);
        }

        private void OnPlayerTurnStarted() => TryTrigger(TutorialTrigger.PlayerTurnStarted);

        private void OnCardPlayed(Card card)
        {
            if (_doneCount >= _cfg.steps.Count) return;
            var step = _cfg.steps[_doneCount];
            bool nameOk = string.IsNullOrEmpty(step.cardName)
                          || (card != null && card.Data != null && card.Data.cardName == step.cardName);

            // 触发：frontier 等的就是出牌
            if (_activeIndex < 0 && step.trigger == TutorialTrigger.CardPlayed && nameOk)
                ActivateStep(_doneCount);
            // 解除：当前拍靠出牌收尾
            else if (_activeIndex == _doneCount && step.release == TutorialRelease.CardPlayed && nameOk)
                RequestRelease();
        }

        private void OnPrepared()
        {
            if (_doneCount >= _cfg.steps.Count) return;
            if (_activeIndex == _doneCount && _cfg.steps[_doneCount].release == TutorialRelease.Prepared)
                RequestRelease();
        }

        private void OnCameraOperated()
        {
            if (_doneCount >= _cfg.steps.Count) return;
            if (_activeIndex == _doneCount && _cfg.steps[_doneCount].release == TutorialRelease.CameraOperated)
                RequestRelease();   // 镜头交还跟随延到实际解除时（ReleaseActive 内）
        }

        /// <summary>S3 解除：玩家消耗了 1 枚探索骰（移动自动扣骰 / 点骰子按钮，两条链路都触发）。</summary>
        private void OnExplorationDiceConsumed()
        {
            if (_doneCount >= _cfg.steps.Count) return;
            if (_activeIndex == _doneCount && _cfg.steps[_doneCount].release == TutorialRelease.DiceConsumed)
                RequestRelease();
        }

        private void OnPlayerArrived(Vector2Int coord)
        {
            if (_doneCount >= _cfg.steps.Count) return;
            var active = _cfg.steps[_doneCount];

            // ① 解除判定（当前激活拍）
            if (_activeIndex == _doneCount)
            {
                if (active.release == TutorialRelease.PlayerMoved) { RequestRelease(); }
                else if (active.release == TutorialRelease.ArriveCell && coord == active.releaseCell) { RequestRelease(); }
                // ★检查点强制解除：激活拍带检查点且玩家被截停在其检查点上
                //   （如 S3 未耗骰就走到 9 列）→ 无视 release 类型强制推进，防卡死
                else if (active.watchCheckpoints && active.cellList.Contains(coord)) { RequestRelease(); }
            }

            // ② 触发判定（可能是刚推进上来的新 frontier）
            if (_doneCount >= _cfg.steps.Count) return;
            if (_activeIndex >= 0) return;
            var frontier = _cfg.steps[_doneCount];
            if (frontier.trigger == TutorialTrigger.ArriveCell && coord == frontier.triggerCell)
                ActivateStep(_doneCount);
            else if (frontier.trigger == TutorialTrigger.ArriveAnyCell && frontier.cellList.Contains(coord))
                ActivateStep(_doneCount);
        }

        private void OnRedQuestionStateChanged(bool shown)
        {
            _redQuestionCount = Mathf.Max(0, _redQuestionCount + (shown ? 1 : -1));
            if (shown) TryTrigger(TutorialTrigger.RedQuestionBadge);
            else if (_activeIndex == _doneCount && _redQuestionCount == 0
                     && _cfg.steps[_doneCount].release == TutorialRelease.RedQuestionGone)
                RequestRelease();
        }

        private void OnBattleVictory()
        {
            // ★教学兜底（2026-09-13）：战斗提前结束（如 S17 自由行动当回合就击杀）时，
            //   还在等「下个玩家回合」的战斗期拍（S18 整备 / S19 自动整备）永远等不到触发
            //   → 跳过它们，让 S20 正常收尾并完成教学
            if (_activeIndex < 0 && _doneCount < _cfg.steps.Count
                && (_cfg.steps[_doneCount].trigger == TutorialTrigger.PlayerTurnStarted
                    // ★v2.7 兜底：战斗在讲解拍（S39/S40）期间提前开打时，EnterBattle 事件已错过，
                    //   S41 这类等进战斗的拍会永久挂起 → 同样跳到胜利拍（_victoryFired 会接住 S42）
                    || _cfg.steps[_doneCount].trigger == TutorialTrigger.EnterBattle))
            {
                int skip = _doneCount;
                while (skip < _cfg.steps.Count)
                {
                    var s = _cfg.steps[skip];
                    if (skip > _doneCount && s.trigger != TutorialTrigger.OnPreviousReleased) break;
                    Debug.Log($"[Tutorial] 战斗提前结束，跳过未触发的战斗期拍 [{s.id}]");
                    skip++;
                }
                _doneCount = skip;
                _armedIndex = -1;   // ★2026-09-14 跳拍后清掉"武装"指针，避免陈旧指向已跳过的拍
            }

            _victoryFired = true;
            TryTrigger(TutorialTrigger.VictorySettled);
        }

        private void OnAmbushLaunched()
        {
            TryTrigger(TutorialTrigger.AmbushLaunched);
            if (_activeIndex == _doneCount && _cfg.steps[_doneCount].release == TutorialRelease.AmbushLaunched)
                RequestRelease();
        }

        // ---- ★v2.2（2026-09-13）篝火 / 遗物袋 / 装填 的解除钩子 ----

        /// <summary>★v2.2：在指定格生成一个教学箱子——复用遗物袋（CorpseRegistry + LootPopupUI）。
        /// 地图标记由 CorpseSpawner 订阅注册表变动自动补，这里只管数据。
        /// ★v2.3：支持箱内放两件东西（破旧骰子 + 回血药水）。</summary>
        private void SpawnTutorialChest(TutorialStepData step)
        {
            // ★v2.4 幂等：同一坐标只真正投一次物品。拍回退（S25 拿一半 → 退回 S24）会重新激活本拍，
            //   若不拦，AddItem 会在已有袋子上再叠一份骰子/药水。
            //   优先级：**不卡死 > 不重复给**。袋子还在（玩家拿了一半）→ 跳过投放；
            //   袋子已不存在（被拿空移除，理论上此时不会回退到本拍）→ 重建，避免这一拍点不到箱子。
            if (_spawnedChests.Contains(step.chestCell) && CorpseRegistry.Get(step.chestCell) != null)
            {
                Debug.Log($"[Tutorial] 教学箱子 @ Hex_{step.chestCell.x}_{step.chestCell.y} 仍在（已投放），跳过重复投放");
                return;
            }

            var chest = CorpseRegistry.Spawn(step.chestCell, "箱子");
            if (chest == null) return;
            _spawnedChests.Add(step.chestCell);

            if (step.chestDice != null && step.chestDiceCount > 0)
                chest.AddItem(step.chestDice, step.chestDiceCount);
            if (step.chestDice2 != null && step.chestDice2Count > 0)
                chest.AddItem(step.chestDice2, step.chestDice2Count);

            Debug.Log($"[Tutorial] 教学箱子已生成 @ Hex_{step.chestCell.x}_{step.chestCell.y}：" +
                      $"{(step.chestDice != null ? step.chestDice.itemName : "（空）")} ×{step.chestDiceCount}" +
                      (step.chestDice2 != null ? $" + {step.chestDice2.itemName} ×{step.chestDice2Count}" : ""));
        }

        /// <summary>通用解除：当前激活拍的 release 命中给定类型 → 推进下一拍。</summary>
        private void ReleaseIf(TutorialRelease type)
        {
            if (_doneCount >= _cfg.steps.Count) return;
            if (_activeIndex == _doneCount && _cfg.steps[_doneCount].release == type)
                RequestRelease();
        }

        private void OnBonfireOpened() => ReleaseIf(TutorialRelease.BonfireOpened);
        private void OnBonfireRested() => ReleaseIf(TutorialRelease.BonfireRested);
        private void OnLootTaken() => ReleaseIf(TutorialRelease.LootSelected);
        private void OnLoadoutConfigured() => ReleaseIf(TutorialRelease.LoadoutConfigured);
        // ★v2.3
        private void OnLootOpened() => ReleaseIf(TutorialRelease.LootOpened);
        private void OnLootBagEmptied() => ReleaseIf(TutorialRelease.LootEmptied);   // ★v2.3.1 S25「拿空」

        /// <summary>★v2.4（2026-09-13 用户需求）：玩家拿了一半就把箱子关了 → 退回上一拍
        /// （S25 拿取 → S24 打开箱子），重新高亮箱子格；玩家点一下脚下箱子格即可重新开窗。
        /// 旧行为下必须走开再走回来才重弹，会把这一拍卡在半空。</summary>
        private void OnLootBagAbandoned()
        {
            if (_cfg == null || _doneCount >= _cfg.steps.Count) return;
            if (_activeIndex != _doneCount) return;
            // 只对"要拿空才算过"的拍回退——其他拍的关窗不该触发重来
            if (_cfg.steps[_doneCount].release != TutorialRelease.LootEmptied) return;
            RewindTo(_doneCount - 1);
        }

        /// <summary>★v2.4 通用回退：把 frontier 退到 index 并重新激活它。
        /// 仅用于「条件没满足但玩家已离开现场」这类需要重来的拍（当前只有 S25 → S24）。
        /// ⚠️ 只退指针 + 重跑目标拍的激活动作，不撤销中间已完成拍的副作用；
        ///   因此目标拍必须是幂等的（S24 的箱子生成已加 _spawnedChests 保护、染色本身幂等）。</summary>
        private void RewindTo(int index)
        {
            if (_cfg == null || index < 0 || index >= _cfg.steps.Count) return;

            if (_releaseCo != null) { StopCoroutine(_releaseCo); _releaseCo = null; }
            _releasePending = false;
            if (_tip != null) _tip.Hide();
            if (_focusA != null) _focusA.Hide();

            _activeIndex = -1;
            _doneCount = index;
            Debug.Log($"[Tutorial] 回退一拍 → #{index} [{_cfg.steps[index].id}]");
            TryActivateFrontier();
        }
        private void OnInventoryOpened() => ReleaseIf(TutorialRelease.InventoryOpened);
        private void OnInventoryClosed() => ReleaseIf(TutorialRelease.InventoryClosed);
        private void OnConsumableUsed() => ReleaseIf(TutorialRelease.ConsumableUsed);

        // ---- ★v2.4（2026-09-13）卡包 / 装填 的解除钩子（S29-S33 装填教学）----
        private void OnCardPackOpened() => ReleaseIf(TutorialRelease.CardPackOpened);
        private void OnCardPackClosed() => ReleaseIf(TutorialRelease.CardPackClosed);
        private void OnLoadoutOpened() => ReleaseIf(TutorialRelease.LoadoutOpened);
        private void OnLoadoutCardSelected() => ReleaseIf(TutorialRelease.CardSelected);
        private void OnLoadoutSlotSelected() => ReleaseIf(TutorialRelease.SlotSelected);
        private void OnRerollUsed() => ReleaseIf(TutorialRelease.RerollUsed);

        /// <summary>装填界面关闭本身不是 S33 的解除条件（玩家还要关卡包），但可以顺带收掉延迟解除协程。
        /// 目前 S33 只认 CardPackClosed，这里保留以备后续拍需要。</summary>
        private void OnLoadoutClosed() { }

        // ==================================================================
        // 每帧：轮询型解除 / 触发
        // ==================================================================
        private void Update()
        {
            if (_doneCount >= _cfg.steps.Count) return;
            var step = _cfg.steps[_doneCount];

            // ★2026-09-14 清场门槛每帧重试：S42 的上一拍解除时若场上仍有敌人（战斗提前胜利），
            //   之后玩家把剩下的怪清掉，本拍也要能立刻出现——不能只靠事件驱动。
            if (_activeIndex < 0 && step.requireAllEnemiesDefeated) TryActivateFrontier();

            // ★2026-09-14 门槛型触发每帧重试（S18「进入新回合 + 能量<3」）：
            //   能量是玩家出牌后才降下来的，回合开始那一刻的事件往往还满足不了条件。
            if (_activeIndex < 0 && _armedIndex == _doneCount && TriggerGateOpen(step))
            {
                _armedIndex = -1;
                ActivateStep(_doneCount);
                return;     // 本帧已推进；下面的轮询再按旧 frontier 跑没有意义
            }

            if (_activeIndex == _doneCount)
            {
                if (step.release == TutorialRelease.LeaveSpawn)
                {
                    var hm = HexMoverInst();
                    if (hm != null)
                    {
                        if (_spawnCoord.x == int.MinValue) _spawnCoord = hm.CurrentCoord;
                        if (hm.CurrentCoord != _spawnCoord) RequestRelease();
                    }
                }
                else if (step.release == TutorialRelease.HoverPreviewHeld
                         && EnemyMovePreview.Instance != null
                         && EnemyMovePreview.Instance.LivePreviewCoord.HasValue)
                {
                    RequestRelease();
                }
            }

            if (!_enemySeen)
            {
                var enemies = FindObjectsOfType<EnemyController>();
                foreach (var e in enemies)
                {
                    if (e != null && !e.IsDead) { _enemySeen = true; TryTrigger(TutorialTrigger.EnemyEntersView); break; }
                }
            }
        }

        // ==================================================================
        // 禁行格染红 / 还原
        // ==================================================================
        private void ApplyBlockedTiles(TutorialStepData step)
        {
            if (step.blockCells)
            {
                // ★v2.8 替换语义：本拍封的格 = cellList 全集。激活时先还原上一拍的禁行格，
                //   再染红本拍列表——跨拍换封口（如 S35 封 20+22 → S36 只封 20）不再需要断链拍。
                Interactions.TutorialBlockedCells.Clear();
                RestoreBlockedTiles();
                foreach (var coord in step.cellList)
                {
                    // ★2026-09-15 地图重构：格子上已无渲染器，改为「存在性判定 + 按坐标染色」
                    if (FindTileGO(coord) == null) continue;
                    if (!_blockedOriginal.ContainsKey(coord)) _blockedOriginal[coord] = HexTileColorizer.GetColor(coord);
                    HexTileColorizer.SetColor(coord, BlockedRed);
                    Interactions.TutorialBlockedCells.Add(coord);
                }
            }
            else
            {
                Interactions.TutorialBlockedCells.Clear();
                RestoreBlockedTiles();
            }
        }

        private void RestoreBlockedTiles()
        {
            foreach (var kv in _blockedOriginal)
                HexTileColorizer.SetColor(kv.Key, kv.Value);
            _blockedOriginal.Clear();
        }

        // ★v2.8 移除场景内全部篝火：BonfireTile 组件挂在 Map1 地形格（Hex_x_y）上，
        //   只能拆组件和 "BonfireMarker" 视觉子物体，绝不能 Destroy 地形格本身。
        //   组件一拆，OnDisable 自动把它从静态注册表摘除，篝火交互（落点弹面板/点击重开）随之失效。
        private void RemoveTutorialBonfires()
        {
            foreach (var bt in Object.FindObjectsOfType<BonfireTile>())
            {
                if (bt == null) continue;
                var marker = bt.transform.Find("BonfireMarker");
                if (marker != null) Object.Destroy(marker.gameObject);
                Object.Destroy(bt);
            }
            Debug.Log("[Tutorial] 已按拍配置移除场景内全部篝火");
        }

        // ==================================================================
        // 焦点（FocusRing + 引线）：主焦点 + 可选第二焦点（同一张蒙版的两个洞）
        //   返回「每帧求值的焦点屏幕坐标 getter」——镜头/目标移动后引线实时跟随。
        // ==================================================================
        private System.Func<Vector2?> ApplyFocus(TutorialStepData step)
        {
            ApplySecondFocus(step);

            if (step.focus == TutorialFocus.None)
            {
                // ★2026-09-13 用户需求：本拍要玩家点「知道了」、而场上又没有高亮目标时，整屏压暗。
                //   画面全亮会让玩家误以为现在可以自由操作（其实还锁着）。
                //   ★v2.4 dimScreen=false 的拍例外：卡包/装填等模态界面开着的拍，压暗会把界面也盖住。
                if (step.showConfirm && !step.silent && step.dimScreen) { if (_focusA != null) _focusA.ShowDim(); }
                else if (_focusA != null) _focusA.Hide();
                return null;
            }

            switch (step.focus)
            {
                case TutorialFocus.HudDice: return FocusRect(FindUiRect("StatusBar/DiceArea"));
                case TutorialFocus.HudHand: return FocusRect(FindUiRect("HandView"));
                case TutorialFocus.HudEnergy: return FocusRect(FindUiRect("StatusBar/EnergyPointDisplay"));
                case TutorialFocus.HudEndTurn: return FocusRect(FindUiRect("EndTurnButton"));
                case TutorialFocus.HudPath: return FocusRect(FindUiRect(step.focusUiPath));
                case TutorialFocus.Player: return FocusWorld(PlayerWorldPos, 70f);
                case TutorialFocus.FirstEnemy: return FocusWorld(FirstEnemyWorldPos, 70f);
                case TutorialFocus.NamedEnemy: return FocusWorld(NamedEnemyWorldPos(step.focusEnemyName), 70f);
                case TutorialFocus.MapCell:
                {
                    var cell = step.focusCell;
                    return FocusWorld(() => CellToWorld(cell), 70f);
                }
                case TutorialFocus.ScreenRect:
                {
                    if (_focusA != null) _focusA.ShowRect(step.focusScreenRect);
                    Rect r = step.focusScreenRect;
                    return () => new Vector2(r.x + r.width * 0.5f, r.y + r.height * 0.5f);
                }
            }
            if (_focusA != null) _focusA.Hide();
            return null;
        }

        /// <summary>第二焦点（可选）：与主焦点同时亮（同一张蒙版挖两个洞，两处都不被压暗）。</summary>
        private void ApplySecondFocus(TutorialStepData step)
        {
            if (_focusA == null) return;

            switch (step.focus2)
            {
                case TutorialFocus.NamedEnemy:
                {
                    // ★v2.6 第二焦点用自己的名字（空 = 回落主焦点名字，兼容旧数据）
                    string name2 = string.IsNullOrEmpty(step.focus2EnemyName) ? step.focusEnemyName : step.focus2EnemyName;
                    _focusA.ShowSecondWorld(NamedEnemyWorldPos(name2), 70f);
                    return;
                }
                case TutorialFocus.FirstEnemy:
                    _focusA.ShowSecondWorld(FirstEnemyWorldPos, 70f);
                    return;
                case TutorialFocus.Player:
                    _focusA.ShowSecondWorld(PlayerWorldPos, 70f);
                    return;
                case TutorialFocus.MapCell:
                {
                    var cell = step.focus2Cell;
                    _focusA.ShowSecondWorld(() => CellToWorld(cell), 70f);
                    return;
                }
                case TutorialFocus.ScreenRect:
                    _focusA.ShowSecondRect(step.focusScreenRect);
                    return;
            }

            // focus2 未显式指定类型时，兼容 v2 旧数据：focus2UiPath 有值就按 UI 节点处理
            var rt = string.IsNullOrEmpty(step.focus2UiPath) ? null : FindUiRect(step.focus2UiPath);
            if (rt != null) _focusA.ShowSecond(rt);
            else _focusA.ClearSecond();
        }

        /// <summary>主焦点环的屏幕矩形 getter（供 TipCard 把引线端点截断在框边界，不穿框）。</summary>
        private System.Func<Rect?> MainFocusRect
        {
            get
            {
                var ring = _focusA;
                return () =>
                {
                    if (ring == null) return (Rect?)null;
                    Rect r = ring.CurrentRect;
                    return r.width > 1f ? (Rect?)r : null;
                };
            }
        }

        /// <summary>HUD 焦点：环每帧重算矩形；引线端点 = 节点中心每帧重投影。</summary>
        private System.Func<Vector2?> FocusRect(RectTransform rt)
        {
            if (rt == null) { if (_focusA != null) _focusA.Hide(); return null; }
            if (_focusA != null) _focusA.Show(rt);
            return () =>
            {
                if (rt == null) return (Vector2?)null;
                var corners = new Vector3[4];
                rt.GetWorldCorners(corners);
                return new Vector2((corners[0].x + corners[2].x) * 0.5f, (corners[0].y + corners[2].y) * 0.5f);
            };
        }

        /// <summary>世界焦点：环每帧重投影（FocusRing 内置 getter）；引线端点同步重投影。</summary>
        private System.Func<Vector2?> FocusWorld(System.Func<Vector3> getter, float halfPx)
        {
            if (_focusA != null) _focusA.ShowWorld(getter, halfPx);
            return () =>
            {
                Camera cam = Camera.main;
                return cam != null ? (Vector2?)cam.WorldToScreenPoint(getter()) : null;
            };
        }

        // ==================================================================
        // 坐标 / 查找工具
        // ==================================================================
        private HexMover HexMoverInst()
        {
            if (_hexMover == null) _hexMover = FindObjectOfType<HexMover>();
            return _hexMover;
        }

        private static Vector3 PlayerWorldPos()
        {
            var hm = FindObjectOfType<HexMover>();
            return hm != null ? hm.transform.position : Vector3.zero;
        }

        private static Vector3 FirstEnemyWorldPos()
        {
            foreach (var e in FindObjectsOfType<EnemyController>())
                if (e != null && !e.IsDead) return e.transform.position;
            return PlayerWorldPos();
        }

        /// <summary>NamedEnemy：名字包含关键字且存活的敌人中，取离玩家最近者。</summary>
        private System.Func<Vector3> NamedEnemyWorldPos(string keyword)
        {
            return () =>
            {
                EnemyController best = null;
                float bestDist = float.MaxValue;
                Vector3 p = PlayerWorldPos();
                foreach (var e in FindObjectsOfType<EnemyController>())
                {
                    if (e == null || e.IsDead) continue;
                    if (!string.IsNullOrEmpty(keyword) && !e.gameObject.name.Contains(keyword)) continue;
                    float d = (e.transform.position - p).sqrMagnitude;
                    if (d < bestDist) { bestDist = d; best = e; }
                }
                return best != null ? best.transform.position : FirstEnemyWorldPos();
            };
        }

        /// <summary>地图格 → 世界坐标（口径对齐 CorpseSpawner：Map/Hex_{x}_{y}）。</summary>
        private static Vector3 CellToWorld(Vector2Int coord)
        {
            var map = GameObject.Find("Map");
            if (map == null) return Vector3.zero;
            var tile = map.transform.Find($"Hex_{coord.x}_{coord.y}");
            return tile != null ? tile.position : Vector3.zero;
        }

        private static GameObject FindTileGO(Vector2Int coord)
        {
            var map = GameObject.Find("Map");
            if (map == null) return null;
            var tile = map.transform.Find($"Hex_{coord.x}_{coord.y}");
            return tile != null ? tile.gameObject : null;
        }

        // ---- UI 节点查找（UICanvas 下；支持路径或名字前缀，前缀可命中多个） ----
        private static Transform UICanvasRoot()
        {
            var c = GameObject.Find("UICanvas");
            return c != null ? c.transform : null;
        }

        private static List<Transform> FindUiNodes(string nameOrPath)
        {
            var result = new List<Transform>();
            var root = UICanvasRoot();
            if (root == null || string.IsNullOrEmpty(nameOrPath)) return result;
            if (nameOrPath.Contains("/"))
            {
                var t = root.Find(nameOrPath);
                if (t != null) result.Add(t);
                return result;
            }
            CollectMatches(root, nameOrPath, result);
            return result;
        }

        private static void CollectMatches(Transform parent, string name, List<Transform> result)
        {
            for (int i = 0; i < parent.childCount; i++)
            {
                var c = parent.GetChild(i);
                if (c.name == name || c.name.StartsWith(name)) result.Add(c);
                CollectMatches(c, name, result);
            }
        }

        private static RectTransform FindUiRect(string nameOrPath)
        {
            var list = FindUiNodes(nameOrPath);
            return (list != null && list.Count > 0) ? list[0] as RectTransform : null;
        }
    }
}

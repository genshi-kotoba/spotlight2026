// =============================================================================
// 模块：HandUIController 出牌交互状态机（partial 拆分 2026-08-18，纯机械搬运逻辑零修改）
// 原文件：HandUIController.cs（拆分后本文件只管"卡牌怎么被打出去/收回"——
//         拖动与点击统一入口、Follow 跟随、打出阈值检测、执行打出、收回）
// 设计依据：docs/superpowers/specs/2026-08-18-card-play-interaction-targeting-design.md
// =============================================================================
using UnityEngine;
using DG.Tweening;

public partial class HandUIController
{
    // ------------------------------------------------------------------
    // M5b-2 出牌交互状态机（2026-08-18 重构，设计文档 §二）
    //
    //   None ──拖动开始(NotifyCardDragStarted)/点击选中(OnCardViewClicked)──→ Follow（跟随鼠标）
    //   Follow ──有指向卡·鼠标过线──→ Arrow（箭头指向，不因回落解除）
    //   Follow ──无指向卡·松开且过线──→ 打出（PlayCardAction，Target=null）
    //   Follow ──松开未过线 / 右键──→ None（卡弹回，手牌展开）
    //   Arrow ──松开/点击 有效目标──→ 打出（PlayCardAction + Target）
    //   Arrow ──松开/点击 空目标或无效目标 / 右键──→ None（卡弹回，手牌展开）
    //
    // Follow 不区分按住拖动 / 点击跟随（两种入口进同一状态，行为一致）；
    // 位置管理仍归本类独管（CardView 只转发事件）。
    // ------------------------------------------------------------------

    /// <summary>交互流中的卡牌（null = 无流，None 态）</summary>
    private CardView _activeCard = null;

    /// <summary>true = 按住拖动进入 Follow；false = 左键点击跟随（松开按键仍跟随）</summary>
    private bool _activeFromDrag = false;

    /// <summary>箭头指向模式（有指向卡过线后；卡牌停泊，箭头指向鼠标，不因回落解除）</summary>
    private bool _arrowMode = false;

    /// <summary>帧守卫：UGUI OnPointerClick 与 Update 轮询同帧冲突防护</summary>
    private int _clickGuardFrame = -1;

    // ------------------------------------------------------------------
    // 拖动打出阈值（P7 细节：用户 2026-08-16 确认）
    // 卡牌拖出 PlayThresholdY（HandAreaRoot 局部 y）后：
    //   1. 其余手牌收拢成"少一张"的满员布局 → 玩家看到"松开 = 打出"的反馈
    //   2. 松开鼠标时才算打出（未超过 = 放回手牌）
    // 暂定 250（比回合结束按钮稍高），后续会反复调整 → Inspector 可改
    // ------------------------------------------------------------------
    [Header("拖动打出阈值")]
    [Tooltip("卡牌拖出此高度（HandAreaRoot 局部 y）才算打出，同时其余手牌收拢。暂定 250，后续调整")]
    [SerializeField] private float _playThresholdY = 250f;
    // 滞后防抖：超过阈值收拢后，退回阈值以下一定距离才展开（防止阈值附近来回抖动）
    // ★用户 2026-08-16 调优：阈值 125、滞后 15
    private const float ThresholdHysteresis = 15f;

    /// <summary>当前拖动是否已超过打出阈值（收拢状态标记）</summary>
    private bool _dragExceededThreshold = false;

    /// <summary>指定卡牌是否在交互流中（CardView.OnBeginDrag 判断"点击跟随转拖动"用）</summary>
    public bool IsCardInActiveFlow(CardView cv) => _activeCard == cv;

    /// <summary>
    /// M5b-2（2026-08-18 重构）：CardView 点击回调（统一交互状态机入口）。
    /// - 无交互流：能量检查通过 → 进入 Follow·点击跟随（卡牌像被拖动一样跟随鼠标）
    /// - 点击 armed 卡（跟随中再点自己）：按鼠标位置/箭头目标分治（打出/收回）
    /// - 点击其他卡：取消当前流 → 换新卡进入点击跟随
    /// 旧的"金框选中 → CardExecutor"链路由本交互取代（OnCardSelected 事件保留给 M5b-3 改造）。
    /// </summary>
    /// <param name="view">被点击的卡牌视图</param>
    public void OnCardViewClicked(CardView view)
    {
        if (view == null || view.CardData == null) return;

        // ★v2.12：飞出中的卡不可点击（已在飞往弃牌槽/弃牌堆，防双触发二次处理）
        if (view.IsFlyingOut) return;

        // ★2026-08-26 D19 v2.6：鉴定模式点击手牌 → 直接飞入 DISCARD 面板
        //（不走点击跟随流——用户要求"点击对应卡牌"即加入鉴定）
        if (TryRouteCheckAssistClick(view)) return;

        // ★D19 v2.11：鉴定模式下缩下的手牌完全不可交互——不进点击跟随流
        if (_checkAssistMode && !IsCheckAssistPopped(view)) return;

        // 非战斗模式不响应 —— 但鉴定辅助模式（弹窗打开）例外（探索里要弃牌）
        bool isBattle = GameStateManager.Instance == null
                        || GameStateManager.Instance.CurrentState == GameState.Battle;
        bool isCheckAssistOpen = _checkAssistMode
                                 || (FindObjectOfType<EventPopupUI>() != null
                                     && FindObjectOfType<EventPopupUI>().gameObject.activeSelf);
        if (!isBattle && !isCheckAssistOpen)
        {
            return;
        }

        // 帧守卫：本帧已处理过点击（防 UGUI 点击与 Update 轮询双触发）
        _clickGuardFrame = Time.frameCount;

        // 交互流中：点 armed 卡 = 确认分治；点其他卡 = 取消当前换新卡
        if (_activeCard != null)
        {
            if (view == _activeCard)
            {
                HandleArmedCardClick();
                return;
            }
            ReturnActiveCard();
            // fall through：尝试选中新卡
        }

        BeginClickFollow(view);
    }

    /// <summary>
    /// 点击跟随入口：交互/能量检查 → 开启交互流（Follow·点击驱动）。
    /// </summary>
    private void BeginClickFollow(CardView view)
    {
        // 动作执行中不可开始新交互
        if (!Interactions.PlayerCanInteract()) return;

        // 费用检查（只用门槛检查不扣费——扣费在 PlayCardAction 反应链按状态分流：
        // 战斗态扣能量 / ★警戒态扣 1 枚探索骰 §9.1.2）
        if (!Interactions.CanPayCardCost(view.Card))
        {
            Debug.Log($"[HandUIController] 费用不足，无法选中：{view.CardData.cardName}");
            return;
        }

        BeginFlow(view, fromDrag: false);
    }

    /// <summary>
    /// armed 卡被再次点击（点击跟随模式的确认点击）：
    ///   箭头模式 → 目标分治：有效目标=打出（带 Target），空/无效=收回
    ///   跟随模式 → 位置分治：线上=打出（无指向卡；有指向卡线上已进箭头模式），线下=收回
    /// </summary>
    private void HandleArmedCardClick()
    {
        var cv = _activeCard;
        if (cv == null) return;

        if (_arrowMode)
        {
            EnemyController enemy = RaycastEnemyUnderMouse();
            if (enemy != null && IsValidTarget(enemy, cv))
            {
                ExecutePlay(cv, enemy);
            }
            else
            {
                Debug.Log($"[HandUI] 点击空/无效目标，收回：{cv.CardData?.cardName}");
                ReturnActiveCard();
            }
            return;
        }

        if (_dragExceededThreshold)
        {
            ExecutePlay(cv, null);
        }
        else
        {
            // 线下再次点击 = 回到手牌，不算打出
            Debug.Log($"[HandUI] 线下再次点击，收回：{cv.CardData?.cardName}");
            ReturnActiveCard();
        }
    }

    /// <summary>
    /// 拖动开始（CardView.OnBeginDrag 转发）：开启交互流（Follow·拖动驱动）。
    /// ★M5b-2 用户需求：拖出即收拢——手牌不留空位（n-1 满员布局），松开才展开。
    /// 若点击跟随中的卡再被按住拖动，转为拖动驱动继续同一流程。
    /// </summary>
    public void NotifyCardDragStarted(CardView draggedCV)
    {
        if (draggedCV == null) return;

        // 其他卡在流中 → 先取消（点着一张拖另一张的场景）
        if (_activeCard != null && _activeCard != draggedCV)
        {
            ReturnActiveCard();
        }

        // 点击跟随后转拖动：同一流程，只切驱动方式
        if (_activeCard == draggedCV)
        {
            _activeFromDrag = true;
            return;
        }

        BeginFlow(draggedCV, fromDrag: true);
    }

    /// <summary>
    /// 开启交互流（Follow 模式入口，拖动/点击跟随共用）：
    /// 置全局拖动标记（屏蔽其他卡悬停）→ 姿态锁（保持抬高/放大/立正）→
    /// 手牌收拢成 n-1 布局 → 射程高亮 → 置顶。
    /// </summary>
    private void BeginFlow(CardView cv, bool fromDrag)
    {
        _activeCard = cv;
        _activeFromDrag = fromDrag;
        _arrowMode = false;
        _dragExceededThreshold = false;
        Interactions.PlayerIsDragging = true;
        cv.InteractionLocked = true;

        // ★D19 v2.11：鉴定模式悬停不立正——只有被拖出/点击跟随的卡才立正
        //（用户定稿），同时清掉悬停亮起金边，避免飞行中残留
        if (_checkAssistMode)
        {
            DOTween.Kill(cv);
            cv.transform.DOLocalRotateQuaternion(Quaternion.identity, 0.15f).SetEase(Ease.OutCubic);
            cv.SetPanelCardHover(false);
        }

        // ★2026-08-18：禁用移动交互（点击移动/路径预览/格子悬停高亮），
        // 并先彻底清掉移动高亮再显示射程高亮，防止两套染色互相覆盖残留
        Interactions.CardInteractionActive = true;
        GetPlayerMover()?.ClearAllMoveHighlights();

        // 隐藏悬停大图预览（对应视频"拖动开始隐藏悬停卡牌视图"）
        if (CardViewHoverSystem.Instance != null)
        {
            CardViewHoverSystem.Instance.Hide();
        }

        // ★用户 2026-08-18：拖住卡牌低于分界线，手牌也不留空位 → 一进流就收拢
        CollapseHandForPlay(cv);

        // 射程高亮（有射程的卡全程保持，流结束清除）
        // ★D19 v2.9：鉴定模式禁用射程高亮与打出效果（探索态没有目标格，
        // 拖动只为弃牌辅助，全部按"无指向"处理）
        if (!_checkAssistMode)
        {
            ShowRangeHighlightForCard(cv);
        }

        // 拖动卡置顶最上层（可遮挡其他卡）
        cv.transform.SetAsLastSibling();

        // 点击跟随：卡牌立即贴到鼠标当前位置
        if (!fromDrag)
        {
            UpdateActiveCardFollow(cv, Input.mousePosition);
        }

        bool targeted = cv.CardData != null && cv.CardData.RequiresManualTarget;
        Debug.Log($"[HandUI] 交互流开始：{cv.CardData?.cardName}（{(fromDrag ? "拖动" : "点击跟随")}，指向卡={targeted}）");
    }

    /// <summary>
    /// 拖动中（CardView.OnDrag 每帧转发）：把鼠标屏幕坐标换算成
    /// HandAreaRoot 本地坐标，直接赋值跟随鼠标（拖动不用 Tween）。
    /// 箭头模式下忽略（卡牌已停泊，箭头由 Update 驱动）。
    /// </summary>
    /// <param name="cv">被拖动的卡牌</param>
    /// <param name="screenPosition">鼠标屏幕坐标（eventData.position，左下角原点）</param>
    /// <param name="uiCamera">事件相机（Overlay 画布为 null，转换 API 兼容）</param>
    public void SetDraggedCardPosition(CardView cv, Vector2 screenPosition, Camera uiCamera)
    {
        if (cv == null || _activeCard != cv) return;
        if (_arrowMode) return;   // 箭头模式：卡牌停泊不跟随
        UpdateActiveCardFollow(cv, screenPosition, uiCamera);
    }

    /// <summary>
    /// Follow 模式核心：卡牌跟随鼠标 + 打出阈值检测（含滞后防抖）。
    /// 拖动驱动（OnDrag 转发）与点击跟随（Update 轮询）共用。
    ///   过线 + 有指向卡 → EnterArrowMode（不因回落解除）
    ///   过线 + 无指向卡 → 绿色描边打出预览（退回线内熄灭）
    /// </summary>
    private void UpdateActiveCardFollow(CardView cv, Vector2 screenPosition, Camera uiCamera = null)
    {
        var rt = cv.transform as RectTransform;
        var parentRT = cv.transform.parent as RectTransform;   // HandAreaRoot
        if (rt == null || parentRT == null) return;

        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(
                parentRT, screenPosition, uiCamera, out Vector2 localPoint))
        {
            // 用 localPosition 赋值（localPoint 语义即父空间坐标）；Z 保持原值避免裁剪
            cv.transform.localPosition = new Vector3(localPoint.x, localPoint.y, cv.transform.localPosition.z);

            // ★D19 v2.9：鉴定模式（弹窗打开）→ 所有卡一律按"无指向"处理：
            // 拖过线 = 松手飞入 DISCARD 面板（指向卡不再进箭头模式）
            bool targeted = !_checkAssistMode
                            && cv.CardData != null
                            && cv.CardData.RequiresManualTarget;

            // ---- 打出阈值检测（滞后防抖：越过阈值生效，退回阈值-滞后解除）----
            if (!_dragExceededThreshold && localPoint.y >= _playThresholdY)
            {
                _dragExceededThreshold = true;
                if (targeted)
                {
                    // 有指向卡：变箭头（此后不因鼠标回落解除）
                    Debug.Log($"[HandUI] 超过打出阈值（有指向卡→箭头模式）：y={localPoint.y:F0}");
                    EnterArrowMode(cv);
                }
                else
                {
                    // 无指向卡：绿色描边 = "松开即打出"的反馈
                    Debug.Log($"[HandUI] 超过打出阈值（无指向卡→绿色预览）：y={localPoint.y:F0}");
                    cv.SetPlayPreview(true);

                    // ★2026-08-17 双色语义：过线 = 即将生效 → 高亮从黄（可用）变红（生效）。
                    // 射程 0 的自身卡（防御/嗅盐）= 玩家脚底格变红；射程>0 的无指向卡 = 范围变红
                    // ★D19 v2.9：鉴定模式无射程高亮（探索态没有目标格）
                    if (!_checkAssistMode)
                    {
                        ShowRangeHighlightForCard(cv, active: true);
                    }
                }
            }
            else if (_dragExceededThreshold && !targeted && localPoint.y < _playThresholdY - ThresholdHysteresis)
            {
                // 无指向卡退回阈值内 → 解除打出预览（有指向卡进箭头模式后不走此分支）
                _dragExceededThreshold = false;
                cv.SetPlayPreview(false);

                // ★2026-08-17：退回线内 = 回到"可用预览"黄色高亮
                if (!_checkAssistMode)
                {
                    ShowRangeHighlightForCard(cv, active: false);
                }
            }
        }
    }

    /// <summary>拖动中的卡牌是否已超过打出阈值（CardView.OnEndDrag 读取作打出判定）</summary>
    public bool DragExceededPlayThreshold => _dragExceededThreshold;

    /// <summary>
    /// 拖动结束（CardView.OnEndDrag 转发）：交互流决策入口。
    ///   箭头模式 → 射线分治：有效目标=打出（带 Target），空/无效=收回
    ///   跟随模式超线（无指向卡）→ 打出
    ///   跟随模式未超线 → 收回
    /// 若流已被取消（右键），只把卡弹回基准位（防御路径）。
    /// </summary>
    public void NotifyCardDragEnded(CardView cv)
    {
        if (cv == null) return;

        // ★v2.12：飞出中的卡不处理拖拽结束——
        // 同帧点击已把它路由飞往弃牌槽时，这里若继续走收回/防御路径会
        // DOTween.Kill 杀死飞行动画 → 卡冻在半空
        if (cv.IsFlyingOut) return;

        // 流已结束（右键取消等）——只把卡弹回基准位
        if (_activeCard != cv)
        {
            ReturnCardToBasePosition(cv);
            return;
        }

        if (_arrowMode)
        {
            EnemyController enemy = RaycastEnemyUnderMouse();
            if (enemy != null && IsValidTarget(enemy, cv))
            {
                ExecutePlay(cv, enemy);
            }
            else
            {
                Debug.Log($"[HandUI] 箭头指向空/无效目标，收回：{cv.CardData?.cardName}");
                ReturnActiveCard();
            }
            return;
        }

        if (_dragExceededThreshold)
        {
            ExecutePlay(cv, null);
        }
        else
        {
            Debug.Log($"[HandUI] 未超过打出阈值，收回：{cv.CardData?.cardName}");
            ReturnActiveCard();
        }
    }

    // ------------------------------------------------------------------
    // 打出 / 收回（交互流出口）
    // ------------------------------------------------------------------

    /// <summary>
    /// 执行打出：能量兜底检查 → 清理流视觉 → 飞出动画 → PlayCardAction（带目标）。
    /// 目标 null = 无指向卡（自身/全体）；效果结算属 M5b-3。
    /// </summary>
    private void ExecutePlay(CardView cv, EnemyController target)
    {
        // ★2026-08-26 D19 鉴定辅助：弹窗打开 → 改飞 DISCARD 面板（不走战斗打牌）
        if (TryRouteCheckAssistPlay(cv)) return;

        // 费用兜底检查（交互过程中资源理论上不变，保险再查一次；战斗态=能量/警戒态=骰子）
        if (!Interactions.CanPayCardCost(cv.Card))
        {
            Debug.Log($"[HandUI] 费用不足，打出失败收回：{cv.CardData?.cardName}");
            ReturnActiveCard();
            return;
        }

        ClearFlowVisuals();
        _activeCard = null;
        cv.InteractionLocked = false;

        Debug.Log($"[HandUI] 打出：{cv.CardData?.cardName}，目标={(target != null ? target.gameObject.name : "无")}");

        // 飞出弃牌堆动画（摘除实例 + 缩小 + 抛物线飞行）
        NotifyCardPlayed(cv);

        // 执行出牌动作链：效果占位(M5b-3) → ConsumeEnergyAction → DiscardCardAction
        if (ActionSystem.Instance != null && cv.Card != null)
        {
            ActionSystem.Instance.Perform(new PlayCardAction(cv.Card, target));
        }
    }

    /// <summary>
    /// 收回卡牌（右键取消 / 线下松开 / 箭头指向无效目标）：
    /// 清理流视觉 → 手牌展开回 n 张布局 → 卡弹回基准位 → 强制收尾悬停姿态。
    /// </summary>
    private void ReturnActiveCard()
    {
        var cv = _activeCard;
        ClearFlowVisuals();
        _activeCard = null;
        if (cv == null) return;

        cv.InteractionLocked = false;
        cv.SetPlayPreview(false);

        // 手牌展开回原 n 张布局
        ExpandHandFromPlay(cv);

        // 卡牌快速弹回基准位 + 恢复层级
        ReturnCardToBasePosition(cv);

        // 恢复姿态（旋转/缩放）——流期间姿态被锁，鼠标离开不触发 OnPointerExit，需强制收尾
        cv.ForceEndHover();
    }

    /// <summary>
    /// 清理交互流的全部视觉状态：箭头、敌人高亮、打出预览标记、
    /// 全局拖动标记、射程高亮。
    /// </summary>
    private void ClearFlowVisuals()
    {
        if (_arrowMode)
        {
            _arrowMode = false;
            _arrowView.Hide();
        }
        if (_lastHighlightedEnemy != null)
        {
            _lastHighlightedEnemy.SetHighlighted(false);
            _lastHighlightedEnemy = null;
        }
        _dragExceededThreshold = false;
        Interactions.PlayerIsDragging = false;
        Interactions.CardInteractionActive = false;
        CardRangeHighlight.Clear(); // Clear 内部已含目标格红高亮的恢复
    }
}

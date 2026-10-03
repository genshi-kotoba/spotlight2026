using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using TMPro;
using DG.Tweening;
using System.Collections.Generic;

/// <summary>
/// 卡牌视图组件 - 管理卡牌UI显示、多花色支持和鼠标悬停事件
/// 支持两种渲染模式：
///   - SpriteRenderer：3D 世界空间卡牌（编辑器可视化预览用，见 CardEditor 场景）
///   - Image：UI 屏幕空间卡牌（战斗手牌 HUD 用，见 HandUIController）
///
/// 悬停逻辑（参考杀戮尖塔 P4 实际效果，非视频的复制方案）：
///   鼠标进入 → 原卡牌立正（旋转→0°）+ 上移 + 放大
///   鼠标离开 → 恢复原始姿态
///   卡牌不复制、不跟随鼠标，而是原地"抽出来"
///
/// 动态描述（战斗骰子掷骰 2026-08-17）：
///   描述显示计算后的最终值（如"5"），骰子重掷后自动刷新；
///   鼠标悬停在计算值上 → 弹小窗显示算式构成（"1+4"）。★用户需求
/// </summary>
public class CardView : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler, IPointerClickHandler,
    IPointerMoveHandler, IBeginDragHandler, IDragHandler, IEndDragHandler
{
    // 卡牌UI元素引用
    [Header("卡牌UI元素")]
    [SerializeField] private TMP_Text title;            // 卡牌标题
    [SerializeField] private TMP_Text description;      // 卡牌描述
    [SerializeField] private TMP_Text mana;             // 能量消耗
    [SerializeField] private Image image;               // 卡牌图片渲染器（UI 屏幕空间版）
    [SerializeField] private SpriteRenderer imageSR;    // 卡牌图片渲染器（3D 世界空间版，兼容编辑器预览）

    [Header("选中态")]
    [Tooltip("卡牌选中时的边框 Image（需在预制体上配置，指向卡牌边框子物体）。\n" +
             "选中时变金色 (#FFD700)，未选中时透明。")]
    [SerializeField] private Image selectionBorder;

    // ★2026-09-13 卡面战斗骰子槽（曾经实现，当日晚些时候**按用户要求移除**）
    //   原因：用户不要卡牌右上角那个骰值标。
    //   注意：只删了「显示层」——战斗骰兜底（临时劣质骰）机制本身不受影响，
    //   仍由 Card.AssignSlotDice + DicePayment 在数据层完成，只是不再画到卡面上。
    //   （相关字段/常量/方法 RefreshDiceSlots 等已一并删除）

    /// <summary>是否处于选中态（M5b-1 添加）</summary>
    public bool IsSelected { get; set; }

    /// <summary>
    /// P8：是否正在播放"打出飞出弃牌堆"动画。
    /// true 时屏蔽悬停/恢复/点击/拖动——否则飞行中经过鼠标会触发
    /// OnPointerExit 的恢复逻辑，把已缩小的卡牌又 tween 回原始大小。
    /// </summary>
    public bool IsFlyingOut { get; set; }

    /// <summary>
    /// M5b-2（2026-08-18）：交互流姿态锁。
    /// 拖动/点击跟随/箭头指向期间由 HandUIController 置 true——
    /// 屏蔽 OnPointerEnter/OnPointerExit 的姿态变化：
    ///   - 点击跟随时鼠标移开卡牌，卡要保持"抬高+放大+立正"继续跟随
    ///   - 箭头模式卡牌停泊在手牌中央，鼠标移开不能触发恢复
    /// 流结束（打出/收回）时置回 false 并由 ForceEndHover 统一收尾姿态。
    /// </summary>
    public bool InteractionLocked { get; set; }

    /// <summary>
    /// ★2026-09-10 战术卡槽：本 CardView 归属的战术面板。
    /// 非 null 时，点击 / 拖拽事件转发给 TacticSlotsPanel（不进手牌出牌流）——
    /// 与 EventPopupUI.IsPanelCard 的既有先例同一套路由思路，不影响手牌流程。
    /// </summary>
    [System.NonSerialized] public TacticSlotsPanel TacticHost;

    /// <summary>
    /// ★2026-09-10 卡包页：本 CardView 归属的卡包面板（卡面网格 / 边栏战术槽）。
    /// 非 null 时，点击 / 拖拽事件转发给 CardPackUI（拖到边栏 = 装载），
    /// 悬停也只亮金框——不走手牌那套"上移 + 放大"（那个位移是按手牌空间算的）。
    /// 与 <see cref="TacticHost"/> 同一套路由思路，两者互斥（同一张卡只会有一个宿主）。
    /// </summary>
    [System.NonSerialized] public CardPackUI PackHost;

    /// <summary>
    /// ★2026-09-17 展示用卡宿主（敌人意图卡/详情面板卡等非手牌卡）：
    /// 悬停只亮金框（不立正不放大）、点击回调宿主、拖拽不响应——全部不进手牌交互流。
    /// 置空恢复手牌行为。
    /// </summary>
    [System.NonSerialized] public System.Action<CardView> DisplayCardHost;

    [Header("悬停效果（杀戮尖塔式：原卡牌立正+上移+放大）")]
    [Tooltip("悬停时卡牌的统一 Y 高度（HandAreaRoot 空间的 anchoredPosition.y 绝对值）。\n" +
             "所有卡牌悬停后会对齐到同一高度，与弧线位置无关。\n" +
             "卡牌默认 scale=2，所以 100 ≈ 视觉上 50 像素高。")]
    public float HoverLift = 50f;

    [Tooltip("悬停时卡牌放大倍数（叠加在原有 scale 上）")]
    public float HoverScale = 1.5f;

    [Tooltip("悬停动画时长（秒）——鼠标进入时立正+放大的快速过渡")]
    public float HoverDuration = 0.01f;

    [Tooltip("恢复动画时长（秒）——鼠标离开时回正+缩放的慢速过渡（>HoverDuration 更柔和）")]
    public float ReturnDuration = 0.18f;

    // 原始姿态（悬停前保存，恢复时用）
    private Vector3 _origAnchoredPos;      // RectTransform.anchoredPosition3D
    private Quaternion _origLocalRot;
    private Vector3 _origLocalScale;
    private int _origSiblingIndex;
    private bool _hovered = false;
    private CardRerollButton _rerollButton;   // ★2026-09-13 重投：卡右下角 ↻ 按钮（懒创建，仅纯手牌上下文）
    private bool _isReturning = false;  // 是否正在执行恢复动画（防止恢复中覆盖原始姿态）

    // 记录当前 SetCard 的 Card 运行时实例
    public Card Card { get; private set; }

    /// <summary>获取底层 CardData 模板（便捷访问）</summary>
    public CardData CardData => Card != null ? Card.Data : null;

    /// <summary>便捷：作为 RectTransform 访问（D19 飞入 DISCARD 面板用）</summary>
    public RectTransform Rect
    {
        get
        {
            // ★2026-09-13：CardView 被 Destroy() 之后、OnDestroy 解绑事件之前的窗口期内，
            //   Card 上的 OnDiceValuesChanged 仍可能回调进来（洗牌 ResetForReshuffle）。
            //   此时访问 transform 会抛 MissingReferenceException，故先做假 null 判定。
            if (this == null) return null;
            if (_rect == null) _rect = transform as RectTransform;
            return _rect;
        }
    }
    private RectTransform _rect;

    /// <summary>便捷：透明调整（D19 鉴定模式：不匹配卡牌灰度缩下时 alpha=0.55）。
    /// 优先走 CanvasGroup，没有就改主 Image.color。</summary>
    public void SetCardAlpha(float a)
    {
        var cg = GetComponent<CanvasGroup>();
        if (cg != null) { cg.alpha = a; return; }
        if (image != null) { var c = image.color; c.a = a; image.color = c; }
    }

    // ======== 动态描述（战斗骰子掷骰） ========
    // 描述文本中各计算值的字符位置表（如"造成5伤害"中"5"的位置）
    // 鼠标悬停落在片段内 → 弹 tooltip 显示算式构成
    private List<ComputedValueSegment> _valueSegments;

    // tooltip 运行时对象（懒创建，挂在卡牌所属画布下，全程置顶）
    private RectTransform _tooltipRoot;
    private TMP_Text _tooltipText;

    // 花色显示相关
    [Header("花色设置")]
    [SerializeField] private CardColorChanger cardColorChanger;
    
    // 四个花色选项
    [Header("花色选项设置")]
    [SerializeField] private SuitOption suit1 = SuitOption.无;
    [SerializeField] private SuitOption suit2 = SuitOption.无;
    [SerializeField] private SuitOption suit3 = SuitOption.无;
    [SerializeField] private SuitOption suit4 = SuitOption.无;
    
    // 花色图标游戏对象引用
    [SerializeField] private Transform colorParent;
    
    private void Awake()
    {
        // ★最先跑：补上缺失的描边层（预制体里 selectionBorder 是 {fileID: 0}，
        //   不补的话下面所有 SetPlayPreview / SetSelectedOutline / SetDiscardSelected 全是空转）。
        EnsureSelectionBorder();

        // 如果没有指定花色管理器，尝试自动查找
        if (cardColorChanger == null)
        {
            cardColorChanger = GetComponent<CardColorChanger>();
            if (cardColorChanger == null)
            {
                cardColorChanger = GetComponentInChildren<CardColorChanger>();
            }
        }

        // 查找花色图标父物体（Color容器）
        if (colorParent == null)
        {
            Transform w = transform.Find("Wrapper");
            if (w != null)
            {
                colorParent = w.Find("Color");
            }
        }

        // 强制重置悬停参数（避免 Unity 序列化残留旧值，导致 Inspector 改了不生效）
        // 要改参数直接改这里的数字，编译后 Awake 强制覆盖。
        if (!Application.isEditor || Application.isPlaying)
        {
            HoverLift   = 50f;     // 统一悬停 Y 高度（HandAreaRoot 空间 anchored Y 绝对值）
            HoverScale  = 1.5f;    // 放大倍数
            HoverDuration  = 0.01f; // 悬停动画时长（快）
            ReturnDuration = 0.18f; // 恢复动画时长（慢）
        }

        // 保存原始姿态（悬停时会再用当时的值覆盖，这里只是保底）
        var rt = transform as RectTransform;
        if (rt != null) _origAnchoredPos = rt.anchoredPosition3D;
        _origLocalRot = transform.localRotation;
        _origLocalScale = transform.localScale;
    }
    
    private void OnValidate()
    {
        // 在Inspector中修改值时实时更新显示
        UpdateSuitDisplay();
    }

    // ------------------------------------------------------------------
    // 鼠标悬停（IPointerEnterHandler / IPointerExitHandler）
    // 杀戮尖塔式效果：原卡牌立正 + 上移 + 放大，不复制不跟随鼠标
    // 坐标体系：用 DOTween.To 泛型方法直接操作 anchoredPosition3D
    // 兜底策略：每个动画 OnComplete 时强制赋值，任何异常都不会卡住
    // ------------------------------------------------------------------

    /// <summary>
    /// 鼠标进入卡牌：立正 + 放大（位置上移和 Sibling 由 HandUIController 管理）
    /// 职责分离：CardView 只管旋转和缩放，位置/Sibling 全部由 HandUIController 管。
    /// 这样避免 CardView 和 HandUIController 互相 kill 对方的位置 Tween。
    /// </summary>
    public void OnPointerEnter(PointerEventData eventData)
    {
        if (_hovered) return;

        // P8：打出飞出动画中不响应悬停
        if (IsFlyingOut) return;

        // M5b-2：交互流姿态锁（拖动/点击跟随/箭头期间不改姿态）
        if (InteractionLocked) return;

        // ★2026-09-10 战术卡槽：面板内卡悬停只亮金色边框——不立正、不放大、
        // 不走手牌悬停流（HandUIController.NotifyCardHovered 的"上移"是按手牌空间算的，
        // 用在面板里会把卡顶乱）。与 D19 弃牌槽同一个套路。
        if (TacticHost != null)
        {
            _hovered = true;
            SetPanelCardHover(true);
            return;
        }

        // ★2026-09-10 卡包页：包内卡（网格卡面 / 边栏槽卡）悬停只亮金框，
        // 不立正、不放大、不走手牌悬停流——理由同战术卡槽。
        if (PackHost != null)
        {
            _hovered = true;
            SetPanelCardHover(true);
            PackHost.OnPackCardHovered(this, true);
            return;
        }

        // ★2026-09-17 展示卡：悬停只亮金框
        if (DisplayCardHost != null)
        {
            _hovered = true;
            SetPanelCardHover(true);
            return;
        }

        // P7 Interactions：拖动卡牌中禁止触发新的悬停（视频同款规则）
        if (!Interactions.PlayerCanHover()) return;

        EventPopupUI panelPopup = FindObjectOfType<EventPopupUI>();
        bool popupOpen = panelPopup != null && panelPopup.gameObject.activeSelf;

        // ★D19 v2.9：弃牌槽（DISCARD 面板）内的卡悬停只亮金色边框，
        // 不立正、不放大、不触发手牌悬停流
        if (popupOpen && panelPopup.IsPanelCard(this))
        {
            _hovered = true;
            SetPanelCardHover(true);
            return;
        }

        // ★D19 v2.11：鉴定辅助模式——只有"弹出"的手牌响应悬停，且只亮金色边框
        //（不立正、不放大、不扇开）；缩下的卡彻底无视鼠标（不置 _hovered）。
        // 用户定稿：手牌扫过不再立正，只有被拖出来的卡才立正（见 BeginFlow）。
        if (popupOpen && HandUIController.Instance != null
            && HandUIController.Instance.CheckAssistModeActive)
        {
            if (HandUIController.Instance.IsCheckAssistPopped(this))
            {
                _hovered = true;
                SetPanelCardHover(true);
            }
            return;
        }

        // ★2026-09-05 探索态打牌已解禁 → 悬停同步放行（战斗+探索都响应）。
        // 非战斗且非探索的中间态（如 Paused）不响应悬停。
        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState != GameState.Battle
            && GameStateManager.Instance.CurrentState != GameState.Exploring)
        {
            return;
        }

        _hovered = true;

        // ★2026-09-13 探索态打牌要花 1 枚探索骰：悬停即把这枚骰子预演成半透明
        UpdateExploreDicePreview(true);

        // ★2026-09-13 重投：悬停手牌 → 右下角出现 ↻ 按钮（0 槽卡同样出现，但常驻置灰）
        EnsureRerollButton();
        if (_rerollButton != null) _rerollButton.SetShown(true);

        // 1. 保存原始旋转和缩放（位置/Sibling 由 HandUIController 管，不需要保存）
        if (!_isReturning)
        {
            _origLocalRot = transform.localRotation;
            _origLocalScale = transform.localScale;
        }
        _isReturning = false;

        // 2. 通知 HandUIController（管位置上移 + Sibling + 扇开其他卡）
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.NotifyCardHovered(this);
        }

        // 3. 只 kill 旋转和缩放 Tween（target=this），不 kill 位置 Tween（HandUIController 管）
        DOTween.Kill(this);

        // 4. 立正：本地旋转→0
        transform.DOLocalRotateQuaternion(Quaternion.identity, HoverDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { if (_hovered) transform.localRotation = Quaternion.identity; });

        // 5. 放大
        Vector3 targetScale = _origLocalScale * HoverScale;
        transform.DOScale(targetScale, HoverDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { if (_hovered) transform.localScale = targetScale; });
    }

    /// <summary>
    /// 鼠标离开卡牌：恢复旋转和缩放（位置恢复和 Sibling 恢复由 HandUIController 管理）
    /// 职责分离：CardView 只 kill 和恢复旋转/缩放，绝不 kill 位置 Tween。
    /// 这样即使快速切换悬停目标，HandUIController 的位置 Tween 不会被 CardView 打断。
    /// </summary>
    public void OnPointerExit(PointerEventData eventData)
    {
        if (!_hovered) return;

        // M5b-2：交互流姿态锁——拖动/跟随/箭头期间鼠标离开不触发恢复
        // （跟随模式下卡牌贴着鼠标，箭头模式下卡牌停泊中央，姿态归 HandUIController 管）
        if (InteractionLocked) return;

        // ★2026-09-13 重投按钮：指针从卡面移到卡的 ↻ 上时，按钮成了新的射线目标，
        // UGUI 会给卡派发 Exit —— 不豁免的话按钮一出现悬停就断（卡缩回 + 按钮被收起）。
        if (_rerollButton != null && eventData != null
            && _rerollButton.ContainsPointerTarget(eventData.pointerCurrentRaycast.gameObject))
            return;

        _hovered = false;
        if (_rerollButton != null) _rerollButton.SetShown(false);

        // ★2026-09-13 悬停离开 → 收掉探索骰预演（若仍在拖动，OnBeginDrag/拖动流会重新点亮）
        UpdateExploreDicePreview(false);

        // ★2026-09-10 战术卡槽：面板内卡悬停离开 → 熄灭金框即可（无姿态/位置要恢复）
        if (TacticHost != null)
        {
            SetPanelCardHover(false);
            HideValueTooltip();
            return;
        }

        // ★2026-09-10 卡包页：悬停离开只熄灭金框（无姿态/位置要恢复）
        if (PackHost != null)
        {
            SetPanelCardHover(false);
            PackHost.OnPackCardHovered(this, false);
            HideValueTooltip();
            return;
        }

        // ★2026-09-17 展示卡：悬停离开只熄灭金框
        if (DisplayCardHost != null)
        {
            _hovered = false;
            SetPanelCardHover(false);
            return;
        }

        EventPopupUI panelPopup = FindObjectOfType<EventPopupUI>();
        bool popupOpen = panelPopup != null && panelPopup.gameObject.activeSelf;

        // ★D19 v2.9：面板卡悬停离开 → 熄灭金色边框即可（没有姿态要恢复）
        if (popupOpen && panelPopup.IsPanelCard(this))
        {
            SetPanelCardHover(false);
            return;
        }

        // ★D19 v2.11：鉴定辅助模式的手牌（弹出卡）悬停离开 → 熄灭边框即可
        //（悬停只有边框效果，无姿态/位置需要恢复）
        if (popupOpen && HandUIController.Instance != null
            && HandUIController.Instance.CheckAssistModeActive)
        {
            SetPanelCardHover(false);
            return;
        }

        // 离开卡牌即隐藏数值构成 tooltip
        HideValueTooltip();

        // P8：打出飞出动画中不触发恢复（否则会把缩小中的卡牌 tween 回原始大小）
        if (IsFlyingOut) return;

        // 1. 通知 HandUIController（管位置恢复 + Sibling 恢复 + 扇开恢复）
        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.NotifyCardUnhovered(this);
        }

        // 2. 只 kill 旋转和缩放 Tween（target=this），绝不 kill 位置 Tween
        DOTween.Kill(this);

        // 3. 标记正在恢复
        _isReturning = true;

        // 4. 启动旋转和缩放恢复 Tween（用 ReturnDuration，比 HoverDuration 慢，更柔和）
        Quaternion origRot = _origLocalRot;
        transform.DOLocalRotateQuaternion(origRot, ReturnDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { if (_isReturning) transform.localRotation = origRot; });

        Vector3 origScale = _origLocalScale;
        transform.DOScale(origScale, ReturnDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { if (_isReturning) transform.localScale = origScale; });

        // 5. DelayedCall 兜底只管旋转和缩放（位置由 HandUIController 管兜底）
        DOVirtual.DelayedCall(ReturnDuration + 0.02f, () =>
        {
            if (_isReturning)
            {
                transform.localRotation = _origLocalRot;
                transform.localScale = _origLocalScale;
                _isReturning = false;
            }
        }).SetTarget(gameObject);
    }

    /// <summary>
    /// 取消恢复态：HandUIController 接管该卡位置（扇开）时调用。
    /// 重置 _isReturning，防止 DelayedCall 兜底把卡牌硬复位到错误位置（覆盖扇开效果）。
    /// 注意：只重置标志，不 kill 旋转/缩放恢复动画（让它们自然跑完）。
    /// </summary>
    public void CancelReturn()
    {
        _isReturning = false;
    }

    // ------------------------------------------------------------------
    // 点击（M5b-2：统一路由到 HandUIController 交互状态机）
    // - 无交互流：左键点击 = 选中卡牌 → 进入"点击跟随"模式（像被拖动一样跟随鼠标）
    // - 点击跟随中点自己 = 按鼠标位置分治（线上打出 / 线下收回）
    // - 箭头模式点自己 = 按目标分治（有效目标打出 / 无效收回）
    // ------------------------------------------------------------------

    /// <summary>
    /// ★v2.12：上次 OnEndDrag 触发的帧号。
    /// UGUI 松手时同一帧可能同时派发 OnPointerClick 和 OnEndDrag（顺序不定）。
    /// 若不拦截：点击先触发 → 卡被路由飞出（_activeCard 清空）；
    /// 随后 OnEndDrag 发现 _activeCard != cv 走防御分支 → ReturnCardToBasePosition
    /// 会 DOTween.Kill 杀死飞行动画 → 卡冻在半空（修"拖出去卡在半空"bug）。
    /// </summary>
    private int _lastDragEndFrame = -1;

    /// <summary>
    /// 鼠标点击卡牌。仅在战斗模式下响应。
    /// 全部转发 HandUIController.OnCardViewClicked 做状态分治。
    /// </summary>
    public void OnPointerClick(PointerEventData eventData)
    {
        // P8：打出飞出动画中不响应点击
        if (IsFlyingOut) return;

        // ★v2.12：拖拽松手同帧的"双触发点击"防御——
        // 点击先于 OnEndDrag 派发时 _isDragging 仍为 true；后派发时等于 _lastDragEndFrame
        if (_isDragging) return;
        if (Time.frameCount == _lastDragEndFrame) return;

        // ★2026-09-10 战术卡槽：槽内卡点击 → 转发 TacticSlotsPanel（不进手牌出牌流）
        if (TacticHost != null)
        {
            TacticHost.OnSlotCardClicked(this);
            return;
        }

        // ★2026-09-10 卡包页：包内卡点击 → 转发 CardPackUI（点击 = 尝试装载 / 卸下）
        if (PackHost != null)
        {
            PackHost.OnPackCardClicked(this);
            return;
        }

        // ★2026-09-17 展示卡：点击回调宿主（详情面板做「迷你↔放大」切换），不进手牌出牌流
        if (DisplayCardHost != null)
        {
            DisplayCardHost(this);
            return;
        }

        // 非战斗模式不响应点击 —— ★鉴定辅助模式（事件弹窗打开）例外：
        // 点击手牌 = 飞入 DISCARD 弃牌辅助面板（D19），转发后由
        // HandUIController.OnCardViewClicked → TryRouteCheckAssistClick 路由。
        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            EventPopupUI popup = FindObjectOfType<EventPopupUI>();
            bool checkAssistOpen = popup != null && popup.gameObject.activeSelf;
            if (!checkAssistOpen) return;
        }

        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.OnCardViewClicked(this);
        }
    }

    // ------------------------------------------------------------------
    // 拖动（P7：杀戮尖塔式拖拽打出，参考 NSWells P7 Card Dragging）
    // 与视频的差异：视频用 OnMouseDown/OnMouseDrag/OnMouseUp（3D 物理）；
    // 本项目卡牌是 UGUI Image，改用 IBeginDragHandler/IDragHandler/IEndDragHandler。
    // 职责分离（本项目特有约定）：CardView 只接收事件，
    //   位置移动/归位全部转发 HandUIController（位置 Tween 唯一管理者）；
    //   旋转/缩放姿态由 CardView 自管（与悬停共用 _hovered 状态）。
    // ------------------------------------------------------------------

    /// <summary>本卡是否正在被拖动</summary>
    private bool _isDragging = false;

    /// <summary>本卡是否正在被拖动（★2026-09-13 重投按钮只读出口：拖拽中隐藏按钮）</summary>
    public bool IsDragging => _isDragging;

    /// <summary>
    /// 开始拖动：进入交互流（Follow 跟随模式）。
    /// 检查：战斗模式 + PlayerCanInteract（ActionSystem 空闲）+ 防重入 + 能量足够（P8）。
    /// ★M5b-2：若本卡已在交互流中（点击跟随后再按住拖动），转为拖动驱动继续同一流程。
    /// </summary>
    public void OnBeginDrag(PointerEventData eventData)
    {
        // ★2026-09-17 展示卡不可拖
        if (DisplayCardHost != null) return;

        // P8：打出飞出动画中不可再拖动
        if (IsFlyingOut) return;

        // ★2026-09-10 战术卡槽：槽内卡拖动 → 转发 TacticSlotsPanel（不进手牌出牌流）
        if (TacticHost != null)
        {
            _isDragging = true;
            TacticHost.OnSlotCardDragStarted(this);
            return;
        }

        // ★2026-09-10 卡包页：包内卡拖动 → 转发 CardPackUI（拖到边栏战术槽 = 装载）
        if (PackHost != null)
        {
            _isDragging = true;
            PackHost.OnPackCardDragStarted(this, eventData.position, eventData.pressEventCamera);
            return;
        }

        // ★D19 v2.6：鉴定面板内的卡 → 拖拽交给 EventPopupUI（拖离面板 = 回手牌）
        EventPopupUI popup = FindObjectOfType<EventPopupUI>();
        if (popup != null && popup.gameObject.activeSelf && popup.IsPanelCard(this))
        {
            popup.BeginPanelCardDrag(this);
            return;
        }

        // ★D19 v2.11：鉴定辅助模式——缩下的手牌完全不可拖动（无视鼠标）
        if (HandUIController.Instance != null
            && HandUIController.Instance.CheckAssistModeActive
            && !HandUIController.Instance.IsCheckAssistPopped(this))
        {
            return;
        }

        // 非战斗模式不响应拖动 —— 例外：鉴定辅助（弹窗打开）+ ★探索态（2026-09-05 全解禁，
        // 每张牌耗 1 枚探索骰子；警戒中打中警戒单位 → 偷袭进战斗 §9.1.2）
        bool isBattleCV = GameStateManager.Instance == null
                          || GameStateManager.Instance.CurrentState == GameState.Battle;
        bool isCheckAssistOpenCV = FindObjectOfType<EventPopupUI>() != null
                                   && FindObjectOfType<EventPopupUI>().gameObject.activeSelf;
        bool isExploringCV = GameStateManager.Instance != null
                             && GameStateManager.Instance.CurrentState == GameState.Exploring;
        if (!isBattleCV && !isCheckAssistOpenCV && !isExploringCV)
        {
            return;
        }

        var hui = HandUIController.Instance;

        // 已处于交互流的卡（点击跟随后按住拖动）：转拖动驱动，同一流程继续
        if (hui != null && hui.IsCardInActiveFlow(this))
        {
            _isDragging = true;
            return;
        }

        // 动作执行中不可交互 / 已有卡在交互流中（防重入）
        // ★鉴定辅助模式例外：弹窗打开时 PlayerCanInteract 可能误拦（ModalPopup 期间），
        //   探索态现已全解禁、PlayerCanInteract 直接放行，无需额外旁路
        bool checkAssistDrag = !isBattleCV && isCheckAssistOpenCV;
        if (!checkAssistDrag)
        {
            if (!Interactions.PlayerCanInteract()) return;
        }
        if (Interactions.PlayerIsDragging) return;

        // ★2026-09-05 费用门槛：战斗态查能量；探索警戒态查剩余探索骰（§9.1.2 扣骰不扣能量）
        if (!Interactions.CanPayCardCost(Card))
        {
            Debug.Log($"[CardView] 费用不足，无法拖动：{CardData?.cardName}");
            return;
        }

        _isDragging = true;

        // ★2026-09-13 拖到「待使用」状态 = 玩家正在考虑打出这张牌 → 点亮探索骰预演
        UpdateExploreDicePreview(true);

        // 隐藏悬停大图预览（对应视频"拖动开始隐藏悬停卡牌视图"）
        if (CardViewHoverSystem.Instance != null)
        {
            CardViewHoverSystem.Instance.Hide();
        }

        // 转发 HandUIController：开启交互流（置顶 + 手牌收拢 + 射程高亮）
        if (hui != null)
        {
            hui.NotifyCardDragStarted(this);
        }

        Debug.Log($"[CardView] 开始拖动：{CardData?.cardName}");
    }

    /// <summary>
    /// 拖动中：每帧把鼠标屏幕坐标转发给 HandUIController 移动卡牌。
    /// （箭头模式下 HandUIController 会忽略跟随——卡牌已停泊）
    /// </summary>
    public void OnDrag(PointerEventData eventData)
    {
        // ★2026-09-10 战术卡槽：槽内卡拖动中 → 转发 TacticSlotsPanel（跟随鼠标）
        if (TacticHost != null)
        {
            if (_isDragging) TacticHost.OnSlotCardDragged(this, eventData.position, eventData.pressEventCamera);
            return;
        }

        // ★2026-09-10 卡包页：包内卡拖动中 → 转发 CardPackUI（幽灵卡跟随鼠标）
        if (PackHost != null)
        {
            if (_isDragging) PackHost.OnPackCardDragged(this, eventData.position, eventData.pressEventCamera);
            return;
        }

        // ★D19 v2.6：面板卡拖拽中 → 转发 EventPopupUI（Canvas 空间跟随鼠标）
        EventPopupUI popup = FindObjectOfType<EventPopupUI>();
        if (popup != null && popup.gameObject.activeSelf && popup.IsPanelCard(this))
        {
            popup.DragPanelCard(this, eventData.position, eventData.pressEventCamera);
            return;
        }

        if (!_isDragging) return;

        if (HandUIController.Instance != null)
        {
            // pressEventCamera 在 Overlay 画布为 null（转换 API 兼容），Camera 画布为 UI 相机
            HandUIController.Instance.SetDraggedCardPosition(this, eventData.position, eventData.pressEventCamera);
        }
    }

    /// <summary>
    /// 结束拖动：全部决策交给 HandUIController 交互状态机——
    ///   箭头模式 → 松开在有效目标上=打出（带 Target），否则=收回
    ///   跟随模式超线（无指向卡）→ 打出（无 Target）
    ///   跟随模式未超线 → 收回（卡弹回基准位 + 手牌展开）
    /// 注意：卡牌效果执行（掷骰/伤害结算）属于 M5b-3，当前为占位。
    /// </summary>
    public void OnEndDrag(PointerEventData eventData)
    {
        // ★2026-09-10 战术卡槽：槽内卡拖动结束 → 转发 TacticSlotsPanel（面板内=取消 / 面板外=待定）
        if (TacticHost != null)
        {
            if (!_isDragging) return;
            _isDragging = false;
            _lastDragEndFrame = Time.frameCount;
            TacticHost.OnSlotCardDragEnded(this);
            return;
        }

        // ★2026-09-10 卡包页：包内卡拖动结束 → 转发 CardPackUI（落在边栏槽格内 = 装载）
        if (PackHost != null)
        {
            if (!_isDragging) return;
            _isDragging = false;
            _lastDragEndFrame = Time.frameCount;
            PackHost.OnPackCardDragEnded(this, eventData.position, eventData.pressEventCamera);
            return;
        }

        // ★D19 v2.6：面板卡拖拽结束 → 转发 EventPopupUI（面板外=回手牌 / 面板内=弹回槽位）
        EventPopupUI popup = FindObjectOfType<EventPopupUI>();
        if (popup != null && popup.gameObject.activeSelf && popup.IsPanelCard(this))
        {
            popup.EndPanelCardDrag(this, eventData.position, eventData.pressEventCamera);
            return;
        }

        if (!_isDragging) return;
        _isDragging = false;
        _lastDragEndFrame = Time.frameCount; // ★v2.12：供 OnPointerClick 双触发防御判定

        // ★2026-09-13 拖动结束 → 收起探索骰预演（若鼠标仍停在卡上，会由 OnPointerEnter 重新点亮）
        UpdateExploreDicePreview(false);

        if (HandUIController.Instance != null)
        {
            HandUIController.Instance.NotifyCardDragEnded(this);
        }
        else
        {
            // 兜底（正常不会发生）：解除全局拖动标记
            Interactions.PlayerIsDragging = false;
        }
    }

    /// <summary>
    /// ★2026-09-13 探索态「打这张牌要花 1 枚探索骰」的代价预告（用户定稿）：
    ///   鼠标悬停在手牌上、或把卡拖到待使用状态时，把骰子区一枚探索骰设成半透明
    ///   （DiceSpendPreview 来源②，与地图移动预览共用同一套半透明信号）。
    /// 战斗态打牌不花探索骰 → 不开预告；卡牌销毁 / 换绑 Card 时统一收掉，避免残留。
    /// </summary>
    private void UpdateExploreDicePreview(bool on)
    {
        bool exploring = GameStateManager.Instance != null
                         && GameStateManager.Instance.CurrentState == GameState.Exploring;
        DiceSpendPreview.SetCardSource(this, on && exploring);
    }

    /// <summary>★2026-09-13 重投：懒创建手牌右下角的 ↻ 按钮（仅纯手牌上下文调用，面板卡不创建）。
    /// ★教程图受教学门禁控制（v2.6）：S41 重投教学拍激活前无重投按钮（TutorialDirector.RerollEnabled）；
    /// 悬停处的 SetShown 本就有 != null 保护，不创建即全链路关闭。非教程图不受影响。</summary>
    private void EnsureRerollButton()
    {
        if (_rerollButton != null) return;
        if (MapLayoutBuilder.IsTutorial && !Tutorial.TutorialDirector.RerollEnabled) return;
        _rerollButton = CardRerollButton.Attach(this);
    }

    /// <summary>★2026-09-13 重投：指针从 ↻ 直接移出整张卡时（按钮独占了 Exit 派发，卡本体收不到
    /// OnPointerExit）由 CardRerollButton 反向调用，代跑卡的正常离开流程。
    /// 传 null 是安全的：OnPointerExit 只在开头用 eventData（豁免判定对 null 直接跳过），
    /// 后续流程与 eventData 无关。</summary>
    public void NotifyRerollButtonExited()
    {
        OnPointerExit(null);
    }

    /// <summary>
    /// 设置选中态边框颜色。
    /// 选中 = 金色 (#FFD700)，未选中 = 透明。
    /// </summary>
    public void SetSelected(bool selected)
    {
        IsSelected = selected;
        if (selectionBorder != null)
        {
            Color gold = new Color(1f, 215f / 255f, 0f, 1f);
            selectionBorder.color = selected ? gold : Color.clear;
        }
    }

    // -------- D19 鉴定辅助：标记（不真正改手牌交互行为，仅视觉） --------
    private bool _checkAssistMode = false;
    private HandUIController _checkAssistHost = null;

    /// <summary>D19 开启/关闭鉴定辅助：true = 拦截悬停放大/拖拽出牌，改为只允许点击加入弃牌辅助。</summary>
    public void SetCheckAssistMode(bool on, HandUIController host)
    {
        _checkAssistMode = on;
        _checkAssistHost = on ? host : null;
    }

    /// <summary>D19：选中态（已加入 DISCARD 面板）——在卡上显示"已选"徽（复用 selectionBorder 改为绿色）</summary>
    public void SetCheckAssistSelected(bool selected)
    {
        if (selectionBorder == null) return;
        Color green = new Color(0.18f, 0.80f, 0.44f, 1f);
        selectionBorder.color = selected ? green : Color.clear;
    }

    /// <summary>
    /// ★D19 v2.9：弃牌槽内卡牌的悬停态——只亮金色边框（不立正/不放大）。
    /// </summary>
    public void SetPanelCardHover(bool on)
    {
        if (selectionBorder == null) return;
        Color gold = new Color(1f, 215f / 255f, 0f, 1f);
        selectionBorder.color = on ? gold : Color.clear;
    }

    /// <summary>
    /// ★2026-09-10 战术卡槽：把卡从交互流收回槽位时复位悬停标记。
    /// 只清标记与金框，不碰姿态 Tween——避免走 ForceEndHover 时
    /// 用未初始化（Default = 0）的 _origLocalScale 把卡缩没。
    /// </summary>
    public void ResetTacticHoverState()
    {
        _hovered = false;
        _isReturning = false;   // 让 OnPointerExit 的 DelayedCall 兜底失效
        SetPanelCardHover(false);
    }

    /// <summary>
    /// M5b-2：超线打出预览——绿色描边（复用 selectionBorder）。
    /// 无指向卡拖过分界线时亮起，提示"松开 = 打出"；退回线内熄灭。
    /// </summary>
    /// <param name="on">true = 绿色描边 (#2ECC71)，false = 透明</param>
    public void SetPlayPreview(bool on)
    {
        if (selectionBorder != null)
        {
            selectionBorder.color = on ? new Color(0.18f, 0.80f, 0.44f, 1f) : Color.clear;
        }
    }

    /// <summary>
    /// 兜底补描边层（2026-09-10 L3 实机抓到的洞）。
    /// 预制体 <c>CardViewUI.prefab</c> 里 <c>selectionBorder: {fileID: 0}</c> —— 从来没连过线。
    /// 于是 <see cref="CardView.SetPlayPreview"/>、<c>SetSelectedOutline</c>、<c>SetDiscardSelected</c>、
    /// <c>SetSelected</c> 全部静默空转：**手牌拖过阈值的绿描边、退回线内的黄高亮、弃牌面板的「已选」徽
    /// 一直都没显示过**，而且不报错。这里按项目「UI 零美术、代码动态创建」的惯例运行时补一个：
    /// 网格描边图（<see cref="InventoryUIKit.HollowFrameSprite"/>）+ Sliced + fillCenter=false
    /// → 任意卡尺寸下描边恒为 3px，颜色仍由原调用点控制，调用点代码一行不用改。
    /// ★画在卡面之上：必须 SetAsLastSibling，否则被卡自身盖住。
    /// 已经连过线的预制体（美术接手后）直接 return，不插手。
    /// </summary>
    private void EnsureSelectionBorder()
    {
        if (selectionBorder != null) return;

        Sprite sp = InventoryUIKit.HollowFrameSprite;
        if (sp == null) return;

        Image img = InventoryUIKit.CreatePanel("SelectionBorder", transform, Vector2.zero, Vector2.zero,
                                               Color.clear);
        if (img == null) return;
        img.sprite = sp;
        img.type = Image.Type.Sliced;      // 九宫格：只拉边条，描边不跟着拉伸变形
        img.fillCenter = false;            // 中心不填 → 天然「描边」而不是「色块」
        img.raycastTarget = false;         // 不吃点击：它在卡的最上层，否则会把卡的点/拖全吃掉
        img.color = Color.clear;           // 默认不可见，等调用点染色

        // ★2026-09-11 修复：高亮框曾用 Stretch 拉满「根 RectTransform」，
        //   而根在卡包网格里会被 GridLayoutGroup 撑成「格子尺寸 = 卡面设计尺寸 × 卡面缩放(1.4)」，
        //   但真正可见的卡面图（CardArt 子节点）始终是设计尺寸、再随根缩放——
        //   于是高亮框比可见卡面大出整整一个缩放倍率。
        //   改为直接贴合 CardArt 的本地矩形：两者都随根 localScale 等比缩放，永远严丝合缝。
        RectTransform borderRT = img.rectTransform;
        borderRT.anchorMin = borderRT.anchorMax = new Vector2(0.5f, 0.5f);
        borderRT.pivot = new Vector2(0.5f, 0.5f);
        borderRT.anchoredPosition = Vector2.zero;
        Transform art = transform.Find("CardArt");
        RectTransform artRT = (art != null) ? art as RectTransform : null;
        if (artRT != null) borderRT.sizeDelta = artRT.sizeDelta;   // 与卡面图同尺寸 → 同比缩放后重合
        else InventoryUIKit.Stretch(borderRT);                     // 兜底：无 CardArt 时沿用旧行为

        img.transform.SetAsLastSibling();

        selectionBorder = img;
    }

    /// <summary>
    /// M5b-2 箭头停泊：缩放 tween 到 原始大小 × multiplier（解除悬停放大 HoverScale）。
    /// 由 HandUIController.EnterArrowMode 调用（姿态锁保护下）。
    /// ★用户 2026-08-18：箭头模式卡牌放大 1.1 倍（原为缩回 1.0）。
    /// </summary>
    /// <param name="duration">时长（秒）</param>
    /// <param name="multiplier">目标缩放倍率（默认 1 = 原始大小）</param>
    public void TweenScaleToOriginal(float duration, float multiplier = 1f)
    {
        DOTween.Kill(this);
        Vector3 target = _origLocalScale * multiplier;
        transform.DOScale(target, duration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { transform.localScale = target; });
    }

    /// <summary>
    /// M5b-2：强制结束悬停态并恢复姿态（旋转/缩放，与 OnPointerExit 恢复逻辑一致）。
    /// 交互流（拖动/点击跟随/箭头）期间姿态被锁，鼠标离开不触发 OnPointerExit，
    /// 流收回时由 HandUIController 调用此方法统一收尾。
    /// </summary>
    public void ForceEndHover()
    {
        // ★v2.11：去掉 _hovered 门槛——鉴定模式下拖出的卡收回时 _hovered
        // 可能为 false（悬停只亮边框不置姿态），立正姿态仍需统一恢复
        _hovered = false;
        if (_rerollButton != null) _rerollButton.SetShown(false);   // ★2026-09-13 重投：一并收起按钮

        // 离开卡牌即隐藏数值构成 tooltip
        HideValueTooltip();

        // 与 OnPointerExit 相同的恢复逻辑：kill 姿态 Tween → 慢速恢复旋转/缩放
        DOTween.Kill(this);
        _isReturning = true;

        Quaternion origRot = _origLocalRot;
        transform.DOLocalRotateQuaternion(origRot, ReturnDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { if (_isReturning) transform.localRotation = origRot; });

        Vector3 origScale = _origLocalScale;
        transform.DOScale(origScale, ReturnDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(this)
            .OnComplete(() => { if (_isReturning) transform.localScale = origScale; });
    }

    /// <summary>
    /// 安全恢复 Sibling Index。
    /// 越界保护 + 父节点检查，确保任何情况下都不抛异常。
    /// </summary>
    private void RestoreSiblingIndex(int targetIndex)
    {
        if (targetIndex < 0 || transform.parent == null) return;
        if (targetIndex >= transform.parent.childCount)
        {
            transform.SetAsLastSibling();
            return;
        }
        transform.SetSiblingIndex(targetIndex);
    }

    /// <summary>
    /// 安全网：卡牌被禁用/销毁时若还是悬停态，立即无动画强制复位旋转和缩放
    /// 位置/Sibling 由 HandUIController 管，这里不管（销毁时位置无意义）
    /// </summary>
    private void OnDisable()
    {
        if (_hovered || _isReturning)
        {
            _hovered = false;
            _isReturning = false;
            DOTween.Kill(this);        // kill 旋转和缩放
            DOTween.Kill(gameObject);  // kill DelayedCall

            transform.localRotation = _origLocalRot;
            transform.localScale = _origLocalScale;
        }

        // ★2026-09-13 重投：卡被禁用（回收 / 切场景）→ 一并收起按钮
        if (_rerollButton != null) _rerollButton.SetShown(false);

        // 禁用时确保 tooltip 隐藏
        HideValueTooltip();
    }

    // ------------------------------------------------------------------
    // 花色显示
    // ------------------------------------------------------------------
    
    /// <summary>
    /// 更新花色显示
    /// </summary>
    private void UpdateSuitDisplay()
    {
        // 更新四个花色位置的显示
        UpdateSuit(1, suit1);
        UpdateSuit(2, suit2);
        UpdateSuit(3, suit3);
        UpdateSuit(4, suit4);
    }
    
    /// <summary>
    /// 更新单个花色位置的显示
    /// 兼容两种渲染模式：CardColorChanger.SetIconByOption 会自动检测 Image/SpriteRenderer。
    /// </summary>
    /// <param name="positionIndex">位置索引（1-4）</param>
    /// <param name="option">花色选项</param>
    private void UpdateSuit(int positionIndex, SuitOption option)
    {
        // 查找对应的花色图标游戏对象
        Transform suitTransform = GetSuitTransform(positionIndex);
        if (suitTransform == null) return;
        if (cardColorChanger == null) return;

        // 使用 CardColorChanger 设置图标（UI Image 优先，3D SpriteRenderer 兼容）
        cardColorChanger.SetIconByOption(suitTransform.gameObject, option);
    }
    
    /// <summary>
    /// 获取指定位置的花色图标游戏对象
    /// </summary>
    private Transform GetSuitTransform(int positionIndex)
    {
        string objectName = "Color" + positionIndex;
        
        // 从colorParent查找
        if (colorParent != null)
        {
            return colorParent.Find(objectName);
        }
        
        // 尝试从Wrapper/Color路径查找
        Transform w = transform.Find("Wrapper");
        if (w != null)
        {
            Transform color = w.Find("Color");
            if (color != null)
            {
                return color.Find(objectName);
            }
        }
        
        return null;
    }
    
    // 属性访问器，允许外部修改花色选项
    public SuitOption Suit1
    {
        get { return suit1; }
        set 
        { 
            suit1 = value;
            UpdateSuit(1, suit1);
        }
    }
    
    public SuitOption Suit2
    {
        get { return suit2; }
        set 
        { 
            suit2 = value;
            UpdateSuit(2, suit2);
        }
    }
    
    public SuitOption Suit3
    {
        get { return suit3; }
        set 
        { 
            suit3 = value;
            UpdateSuit(3, suit3);
        }
    }
    
    public SuitOption Suit4
    {
        get { return suit4; }
        set 
        { 
            suit4 = value;
            UpdateSuit(4, suit4);
        }
    }
    
    /// <summary>
    /// P8：设置能量标识的可负担状态（能量不足时变红，提示玩家打不出这张牌）。
    /// 由 HandUIController 在能量变化/抽牌后批量刷新。
    /// </summary>
    /// <param name="affordable">true=正常白色，false=红色（能量不足）</param>
    public void SetEnergyAffordable(bool affordable)
    {
        if (mana == null) return;
        mana.color = affordable ? Color.white : new Color(0.85f, 0.15f, 0.15f);
    }

    /// <summary>★2026-09-17 能量角标显隐（敌人意图卡用：敌人无限能量，画出来会误导）。</summary>
    public void SetEnergyVisible(bool visible)
    {
        if (mana != null && mana.gameObject.activeSelf != visible)
            mana.gameObject.SetActive(visible);
    }

    /// <summary>
    /// 根据 Card 运行时实例设置卡牌显示
    /// </summary>
    /// <param name="card">卡牌运行时实例（持有 CardData 模板引用）</param>
    // 装填界面配置态展示：非 null 时卡面描述/耗能固定用这份文本，不读卡实例实时骰值
    string _staticDescription;
    int? _staticCost;

    /// <summary>配置态展示（装填界面专用）：固定描述与耗能显示。传 null 恢复实时行为。</summary>
    public void SetStaticDisplay(string staticText, int? energyCost)
    {
        _staticDescription = staticText;
        _staticCost = energyCost;
        if (description != null && !description.richText) description.richText = true;
        RefreshDescription();
        if (mana != null && _staticCost.HasValue) mana.text = _staticCost.Value.ToString();
    }

    public void SetCard(Card card)
    {
        // 解绑旧实例的骰子事件（卡牌视图会被 CardViewCreator 复用）
        if (Card != null)
        {
            Card.OnDiceValuesChanged -= RefreshDescription;
        }

        _staticDescription = null;
        _staticCost = null;

        Card = card;

        // 订阅骰子点数变化（抽牌自动掷/重投后刷新描述最终值）
        if (Card != null)
        {
            Card.OnDiceValuesChanged += RefreshDescription;
        }

        CardData cardData = card?.Data;
        if (cardData != null)
        {
            // 设置卡牌标题（使用 CardData 模板的卡名）
            if (title != null)
            {
                title.text = cardData.cardName;
            }

            // 设置卡牌描述（动态：占位 [1+战斗骰子1] → 最终值"5"，并缓存片段表供悬停）
            RefreshDescription();

            // 设置能量消耗（优先用 Card 实例的 CurrentCost，支持动态降费）
            if (mana != null)
            {
                int cost = card != null ? card.CurrentCost : cardData.energyCost;
                mana.text = cost.ToString();
            }

            // 设置卡牌图片（UI Image 优先，3D SpriteRenderer 兼容）
            if (cardData.cardImage != null)
            {
                if (image != null)
                    image.sprite = cardData.cardImage;
                if (imageSR != null)
                    imageSR.sprite = cardData.cardImage;
            }
            else
            {
                if (image != null)
                    image.color = Color.white;
            }

            // 从 CardData 设置花色选项
            suit1 = cardData.suit1;
            suit2 = cardData.suit2;
            suit3 = cardData.suit3;
            suit4 = cardData.suit4;

            UpdateSuitDisplay();
        }
    }

    // ------------------------------------------------------------------
    // 动态描述与数值悬停（战斗骰子掷骰 2026-08-17）
    // 玩家看到最终值"5"；悬停在"5"上弹小窗显示构成"1+4"。★用户需求
    // ------------------------------------------------------------------

    /// <summary>
    /// 重新生成动态描述（SetCard / 骰子点数变化时调用）。
    /// 未投掷的骰子（-1）不代入，描述保持 [原文] 占位。
    /// ★用户 2026-08-17：受骰子影响的最终值显示蓝色（固定数值保持原色）。
    /// 片段位置按纯文本记录 —— TMP 富文本标签不占可见字符位，
    /// FindIntersectingCharacter 返回的可见字符索引与纯文本索引一致，悬停检测不受影响。
    /// </summary>
    private void RefreshDescription()
    {
        if (Card == null || Card.Data == null || description == null) return;

        // 配置态展示（装填界面）：描述固定用外部给的文本，不代入实时骰值
        if (_staticDescription != null)
        {
            _valueSegments = null;
            description.text = _staticDescription;
            return;
        }

        // 骰子值蓝色标签依赖富文本（TMP 默认开启，此处保险）
        if (!description.richText) description.richText = true;

        _valueSegments = new List<ComputedValueSegment>();
        string plain = Card.Data.GenerateDynamicDescription(Card.DiceValues, _valueSegments);
        description.text = BuildColoredDescription(plain, _valueSegments);
    }

    /// <summary>
    /// 把纯文本描述中的计算值片段包上蓝色富文本标签。
    /// 固定数值（不在片段内）保持原色。
    /// </summary>
    private string BuildColoredDescription(string plain, List<ComputedValueSegment> segments)
    {
        if (segments == null || segments.Count == 0) return plain;

        var sb = new System.Text.StringBuilder(plain.Length + segments.Count * 32);
        int copiedUpTo = 0;

        // 片段按生成顺序记录，startIndex 递增
        foreach (ComputedValueSegment seg in segments)
        {
            if (seg.startIndex < copiedUpTo) continue; // 防御：片段异常重叠
            sb.Append(plain, copiedUpTo, seg.startIndex - copiedUpTo);
            sb.Append("<color=").Append(CardData.DiceValueBlueHex).Append('>');
            sb.Append(plain, seg.startIndex, seg.length);
            sb.Append("</color>");
            copiedUpTo = seg.startIndex + seg.length;
        }
        sb.Append(plain, copiedUpTo, plain.Length - copiedUpTo);

        return sb.ToString();
    }

    /// <summary>
    /// 鼠标在卡牌上移动：检测是否悬停在描述文本的计算值片段上。
    /// 用 TMP_TextUtilities.FindIntersectingCharacter 定位鼠标所在字符，
    /// 落在片段内 → 显示算式构成 tooltip（如 "5" ← "1+4"）。
    /// </summary>
    public void OnPointerMove(PointerEventData eventData)
    {
        if (IsFlyingOut || _isDragging || !Interactions.PlayerCanHover()
            || description == null || _valueSegments == null || _valueSegments.Count == 0)
        {
            HideValueTooltip();
            return;
        }

        // 定位鼠标下的字符索引（Overlay 画布 camera 传 null；false = 不限制可见行）
        int charIndex = TMP_TextUtilities.FindIntersectingCharacter(
            description, eventData.position, eventData.pressEventCamera, false);

        if (charIndex >= 0)
        {
            foreach (ComputedValueSegment seg in _valueSegments)
            {
                if (charIndex >= seg.startIndex && charIndex < seg.startIndex + seg.length)
                {
                    ShowValueTooltip(seg, eventData.position);
                    return;
                }
            }
        }

        HideValueTooltip();
    }

    // ------------------------------------------------------------------
    // ★2026-09-10 外部驱动算式小窗（战术卡槽面板用）
    // ------------------------------------------------------------------
    // 战术面板的输入是**自管轮询**（不吃 UGUI 射线）：卡面整棵子树 raycastTarget=false，
    // 所以 OnPointerMove 在这个面板里永远不会被调用 → 算式小窗自然也不会弹。
    // 这里把「按屏幕坐标算一次小窗」的逻辑单独开个口子，由面板每帧把指针位置喂进来，
    // 复用与手牌**完全相同**的一套 tooltip（同一个 _valueSegments、同一个 ShowValueTooltip），
    // 而不是在面板里另写一份 —— 两份实现迟早会长歪。
    // ------------------------------------------------------------------

    /// <summary>
    /// 由外部（战术面板轮询）驱动算式小窗。语义与 <see cref="OnPointerMove"/> 一致。
    /// 卡面无计算值片段（骰子未掷 / 描述里没有 [算式] 占位）时会自动收起小窗。
    /// </summary>
    public void DriveValueTooltip(Vector2 screenPosition)
    {
        if (IsFlyingOut || _isDragging || !Interactions.PlayerCanHover()
            || description == null || _valueSegments == null || _valueSegments.Count == 0)
        {
            HideValueTooltip();
            return;
        }

        int charIndex = TMP_TextUtilities.FindIntersectingCharacter(description, screenPosition, null, false);
        if (charIndex >= 0)
        {
            foreach (ComputedValueSegment seg in _valueSegments)
            {
                if (charIndex >= seg.startIndex && charIndex < seg.startIndex + seg.length)
                {
                    ShowValueTooltip(seg, screenPosition);
                    return;
                }
            }
        }

        HideValueTooltip();
    }

    /// <summary>外部请求收起算式小窗（指针离开卡格 / 面板收起 / 卡被摘走时调）。</summary>
    public void HideValueTooltipExternal()
    {
        HideValueTooltip();
    }

    /// <summary>
    /// 显示数值构成 tooltip（懒创建：半透明黑底 + 文本，挂卡牌画布顶层）。
    /// ★用户 2026-08-17：小窗缩小；内容用带颜色算式 —— 骰子值最大=绿/最小=红/其余=蓝，固定数值保持奶黄。
    /// </summary>
    private void ShowValueTooltip(ComputedValueSegment segment, Vector2 screenPos)
    {
        EnsureTooltipCreated();
        if (_tooltipRoot == null) return;

        _tooltipRoot.gameObject.SetActive(true);
        // 骰子值带颜色标签的算式（无可染色版本时回退纯文本）
        _tooltipText.text = segment.coloredExpression ?? segment.expression;
        _tooltipRoot.SetAsLastSibling(); // 确保盖过卡牌

        // tooltip 尺寸随文本自适应（紧凑内边距）
        Vector2 textSize = _tooltipText.GetPreferredValues(_tooltipText.text);
        _tooltipRoot.sizeDelta = textSize + new Vector2(10f, 6f);

        // 屏幕坐标 → 画布局部坐标，弹在鼠标右上方
        Canvas canvas = description.canvas;
        if (canvas != null
            && RectTransformUtility.ScreenPointToLocalPointInRectangle(
                canvas.transform as RectTransform, screenPos,
                canvas.renderMode == RenderMode.ScreenSpaceOverlay ? null : canvas.worldCamera,
                out Vector2 localPoint))
        {
            _tooltipRoot.anchoredPosition = localPoint + new Vector2(10f, 14f);
        }
    }

    /// <summary>隐藏数值 tooltip</summary>
    private void HideValueTooltip()
    {
        if (_tooltipRoot != null && _tooltipRoot.gameObject.activeSelf)
        {
            _tooltipRoot.gameObject.SetActive(false);
        }
    }

    /// <summary>
    /// 懒创建 tooltip 对象（代码构建，免改预制体）：
    /// 根节点 Image（半透明黑底）+ 子 TMP_Text，挂在卡牌所属画布下。
    /// ★用户 2026-08-17：缩小一号（字号 18 / 内边距 4,3），内容为带颜色算式需 richText。
    /// </summary>
    private void EnsureTooltipCreated()
    {
        if (_tooltipRoot != null || description == null) return;

        Canvas canvas = description.canvas;
        if (canvas == null) return;

        // 根节点：黑底小窗
        var rootGo = new GameObject("DiceValueTooltip", typeof(RectTransform), typeof(Image));
        _tooltipRoot = rootGo.GetComponent<RectTransform>();
        _tooltipRoot.SetParent(canvas.transform, false);
        _tooltipRoot.pivot = new Vector2(0f, 0.5f); // 左中对齐，向右展开
        var bg = rootGo.GetComponent<Image>();
        bg.color = new Color(0.08f, 0.08f, 0.08f, 0.92f);
        bg.raycastTarget = false; // 不挡鼠标事件

        // 子文本：复用描述的字体（保证数字渲染一致）
        var textGo = new GameObject("Text", typeof(RectTransform), typeof(TextMeshProUGUI));
        var textRect = textGo.GetComponent<RectTransform>();
        textRect.SetParent(_tooltipRoot, false);
        textRect.anchorMin = Vector2.zero;
        textRect.anchorMax = Vector2.one;
        textRect.offsetMin = new Vector2(5f, 3f);
        textRect.offsetMax = new Vector2(-5f, -3f);

        _tooltipText = textGo.GetComponent<TextMeshProUGUI>();
        _tooltipText.font = description.font;
        _tooltipText.fontSize = 18f; // ★缩小一号（原 24）
        _tooltipText.richText = true; // 骰子值颜色标签需要富文本
        _tooltipText.alignment = TextAlignmentOptions.Center;
        _tooltipText.color = new Color(0.96f, 0.89f, 0.77f); // 奶黄 #F6E4C4（美术基调）
        _tooltipText.raycastTarget = false;

        _tooltipRoot.gameObject.SetActive(false);
    }

    /// <summary>销毁时清理：解绑骰子事件 + 移除 tooltip + 收掉探索骰预演</summary>
    private void OnDestroy()
    {
        if (Card != null)
        {
            Card.OnDiceValuesChanged -= RefreshDescription;
        }
        // ★2026-09-13 卡牌被回收时收掉探索骰预演，避免「卡没了但骰子还半透明」的残留
        DiceSpendPreview.SetCardSource(this, false);
        if (_tooltipRoot != null)
        {
            Destroy(_tooltipRoot.gameObject);
        }
    }
}

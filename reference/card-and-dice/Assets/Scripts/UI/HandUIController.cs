// =============================================================================
// 模块：M5a 手牌 UI 控制器 HandUIController（主文件）
// 用途：沿弧线排布手牌、悬浮上浮缩放、选中高亮、探索/战斗模式切换
// 设计依据：docs/superpowers/specs/2026-08-08-m5a-card-runtime-ui-design.md §2.2
// 参考：NSWells《杀戮尖塔》P2 Curved Hand + P4 Hover System
// 职责边界：只管手牌视觉排布和交互响应，不管牌堆数据逻辑
//
// ★partial 拆分（2026-08-18，纯机械搬运逻辑零修改）——本类按职责拆成 6 个文件：
//   HandUIController.cs              主文件：单例/配置字段/生命周期/模式切换/清理
//   HandUIController.Layout.cs       弧线排布、收拢/展开、弃牌延迟重排、弹回基准位
//   HandUIController.Hover.cs        悬停扇开（参数 + 进出悬停）
//   HandUIController.Interaction.cs  出牌交互状态机（点击/拖动入口、Follow、打出/收回）
//   HandUIController.Arrow.cs        箭头模式、敌人射线检测、射程高亮
//   HandUIController.PlayAnimation.cs 打出飞出弃牌堆动画
// 拆分原则：还是同一个类（场景挂载/序列化字段/执行时序全部不变），
//           只是代码按职责分文件，便于分工阅读与维护。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Splines;
using DG.Tweening;

/// <summary>
/// M5a 手牌 UI 控制器。
/// 将 CardPileManager.Hand 中的卡牌沿弧线排布在屏幕底部。
/// 支持：悬浮上浮+缩放、选中高亮、探索模式灰显。
/// </summary>
public partial class HandUIController : MonoBehaviour
{
    // -------- 单例（方便 TurnManager 查找）--------
    public static HandUIController Instance { get; private set; }

    [Header("弧线排布设置")]
    [Tooltip("手牌父容器：所有 CardView 实例挂在这个节点下")]
    public Transform HandAreaRoot;

    [Tooltip("卡牌沿此样条曲线排布（优先于 ArcHeightCurve）。\n若为空则回退用 ArcHeightCurve 曲线。\n对应 HandView 下的 Spline 物体（SplineContainer 贝塞尔样条）")]
    public SplineContainer CardSpline;

    [Tooltip("弧线高度曲线：X=0~1（手牌左→右），Y=弧线深度（负值=下凹）\n在 Inspector 拖拽曲线点即可调手感，不用改代码。\n仅当 CardSpline 为空时生效")]
    public AnimationCurve ArcHeightCurve = AnimationCurve.EaseInOut(0, 0, 1, 0);

    [Tooltip("两端卡牌最大旋转角度（度）")]
    public float CardRotationMax = 16f;

    [Tooltip("卡牌水平间距（像素/世界单位，取决于渲染模式）")]
    public float CardSpacing = 100f;

    [Tooltip("Spline 模式下，按手牌数量配置的卡牌间距（样条归一化 0~1）。\n" +
             "数组索引 = 手牌数量（1~10），索引 0 弃用。\n" +
             "卡牌永远沿样条 0.5 中轴线左右对称排布。\n" +
             "数值越大 = 卡牌越分散；越小 = 越紧凑。\n" +
             "示例：0.1 = 10张刚好铺满弧线；0.08 = 10张占 0.72 宽度更紧凑")]
    public float[] SplineCardSpacingByCount = new float[11]
    {
        0f,     // [0] 弃用（手牌数不会为 0）
        0f,     // [1] 1张：居中，间距无意义
        0.10f,  // [2] 2张
        0.10f,  // [3] 3张
        0.10f,  // [4] 4张
        0.10f,  // [5] 5张
        0.10f,  // [6] 6张
        0.10f,  // [7] 7张
        0.10f,  // [8] 8张
        0.10f,  // [9] 9张
        0.10f,  // [10] 10张：0.1 刚好铺满弧线
    };

    [Header("预制体")]
    [Tooltip("卡牌视图预制体：优先使用 CardViewCreator 单例中配置的预制体；若 CardViewCreator 未就绪则回退用此字段")]
    public CardView CardViewPrefab;

    [Header("探索模式灰显")]
    [Tooltip("探索模式下卡牌透明度")]
    [Range(0.1f, 1f)]
    public float ExplorationAlpha = 0.5f;

    // -------- 事件（供 M5b 打牌执行器订阅）--------
    /// <summary>卡牌被点击选中时触发。参数：被点击的 CardView。</summary>
    public event Action<CardView> OnCardSelected;
    public event Action OnSelectionCleared;

    // -------- 运行时数据 --------
    private List<CardView> _cardViewInstances = new List<CardView>();
    private CardView _selectedCard = null;
    private CardView _hoveredCard = null;
    private bool _isBattleMode = false;

    // 排布后的基准位置（LayoutCardsInArc 末尾记录）
    // 扇开目标 = 基准位置 + 偏移；恢复目标 = 基准位置
    // 避免：动画中途切换悬停卡时，读到动画中途位置作为"原始值"导致累积错误
    private List<Vector3> _baseAnchoredPositions = new List<Vector3>();
    // 排布后的基准旋转（与 _baseAnchoredPositions 并行，拖动收拢/展开时恢复用）
    private List<Quaternion> _baseRotations = new List<Quaternion>();
    // P8：正在播放"飞出弃牌堆"动画的卡牌——从 _cardViewInstances 摘除，不受 ClearAllCardViews 影响
    private List<CardView> _playedCardAnimations = new List<CardView>();

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

        // ====================================================================
        // ★ 自动绑定引用（防止用户在 Inspector 点了 Reset 导致所有引用清空）
        // 策略：先找子物体，再找兄弟/父物体，最后全局查找
        // ====================================================================
        AutoBindReferences();
    }

    /// <summary>
    /// 编辑器右键菜单：把代码中的默认值同步到 Inspector（解决序列化旧值不更新问题）。
    /// 用法：Inspector 里右键 HandUIController 组件 → 选「同步代码默认值到 Inspector」
    /// 注意：只在编辑器非 Play 模式下有效，同步后值会永久保存到场景文件。
    /// </summary>
    [ContextMenu("同步代码默认值到 Inspector")]
    private void SyncCodeDefaultsToInspector()
    {
        // Long 基准 = 50px
        // Medium = Long × 0.7 = 35px
        // Short  = Long × 0.3 = 15px
        // 乘以 countFactor=0.6 后实际偏移：30px / 21px / 9px
        FanOffsetLong      = 50f;
        FanOffsetShort     = 15f;
        FanOffsetMedium    = 35f;
        HoverFanDuration   = 0.15f;
        ReturnFanDuration  = 0.18f;

        if (CountFactorByCount == null || CountFactorByCount.Length < 11)
            CountFactorByCount = new float[11];
        for (int i = 1; i <= 10; i++)
        {
            CountFactorByCount[i] = 0.6f;
        }
        CountFactorByCount[0] = 0f;

        Debug.Log($"[HandUIController] 代码默认值已同步到 Inspector：\n" +
                  $"  FanOffset: Long={FanOffsetLong}, Medium={FanOffsetMedium}, Short={FanOffsetShort}\n" +
                  $"  比例: Long=1, Medium={FanOffsetMedium/FanOffsetLong:0.00}, Short={FanOffsetShort/FanOffsetLong:0.00}\n" +
                  $"  CountFactor[1~10] = 0.6\n" +
                  $"  实际偏移(×0.6): Long={FanOffsetLong*0.6f}px, Medium={FanOffsetMedium*0.6f}px, Short={FanOffsetShort*0.6f}px", this);
    }

    // ====================================================================
    // 自动查找并绑定所有必须引用（Inspector Reset 安全网）
    // 调用时机：Awake，此时场景已加载但逻辑未跑
    // ====================================================================
    private void AutoBindReferences()
    {
        // ---- 1) HandAreaRoot：手牌父容器 ----
        // 优先：自己下面有没有直接叫 "HandAreaRoot" 的子物体
        if (HandAreaRoot == null)
        {
            Transform child = transform.Find("HandAreaRoot");
            if (child != null) HandAreaRoot = child;
        }
        // 次级：自己就是 HandAreaRoot（组件挂在容器本身）
        if (HandAreaRoot == null && name == "HandAreaRoot")
        {
            HandAreaRoot = transform;
        }
        // 兜底：全局找名字带 "HandAreaRoot" / "HandView" 的 Transform
        if (HandAreaRoot == null)
        {
            GameObject go = GameObject.Find("HandAreaRoot");
            if (go != null) HandAreaRoot = go.transform;
        }
        if (HandAreaRoot == null)
        {
            GameObject go = GameObject.Find("HandView");
            if (go != null) HandAreaRoot = go.transform;
        }

        // ---- 2) CardSpline：手牌弧线样条 ----
        if (CardSpline == null)
        {
            CardSpline = GetComponentInChildren<SplineContainer>();
        }
        if (CardSpline == null && HandAreaRoot != null)
        {
            CardSpline = HandAreaRoot.GetComponentInChildren<SplineContainer>();
        }
        if (CardSpline == null)
        {
            // 全局找第一个 SplineContainer（一般只有手牌这一条）
            SplineContainer[] all = FindObjectsOfType<SplineContainer>();
            if (all != null && all.Length > 0) CardSpline = all[0];
        }

        // ---- 3) CardViewPrefab：卡牌预制体 ----
        if (CardViewPrefab == null)
        {
            // 优先：用 CardViewCreator 单例中配置的预制体（CardViewCreator 也有 Awake 自动绑定）
            if (CardViewCreator.Instance != null && CardViewCreator.Instance.CardViewPrefab != null)
            {
                CardViewPrefab = CardViewCreator.Instance.CardViewPrefab;
            }
        }
        if (CardViewPrefab == null)
        {
            // 兜底：全局找 CardView Prefab Asset（不在场景中的 CardView 就是预制体引用）
            CardView[] cvs = Resources.FindObjectsOfTypeAll<CardView>();
            foreach (CardView cv in cvs)
            {
                if (cv == null) continue;
                if (cv.gameObject.scene.name == null || cv.gameObject.scene.name == "")
                {
                    CardViewPrefab = cv;
                    break;
                }
            }
        }

        // ---- 诊断日志：哪个还没绑上 ----
        if (HandAreaRoot == null) Debug.LogError("[HandUIController] AutoBind FAILED: HandAreaRoot 找不到！请在 Inspector 手动拖入。");
        if (CardSpline == null)   Debug.LogWarning("[HandUIController] AutoBind: CardSpline 为空，将回退用 ArcHeightCurve 弧线。");
        if (CardViewPrefab == null) Debug.LogError("[HandUIController] AutoBind FAILED: CardViewPrefab 找不到！请在 Inspector 手动拖入，或确保 CardViewCreator 已配置预制体。");
    }

    /// <summary>
    /// 编辑器右键菜单：一键自动绑定所有引用（不用进 Play 模式，Reset 后点这里即可）
    /// </summary>
    [ContextMenu("自动绑定所有引用（Reset修复）")]
    private void ContextMenuAutoBind()
    {
        AutoBindReferences();
        string msg = $"[HandUIController] 一键绑定完成：\n" +
                     $"  HandAreaRoot   = {(HandAreaRoot   != null ? HandAreaRoot.name   : "❌ 未找到")}\n" +
                     $"  CardSpline     = {(CardSpline     != null ? CardSpline.name     : "⚠️  空（回退用曲线）")}\n" +
                     $"  CardViewPrefab = {(CardViewPrefab != null ? CardViewPrefab.name : "❌ 未找到")}";
        Debug.Log(msg, this);
    }

    private void Start()
    {
        // 订阅 GameStateManager 的状态切换事件
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged += HandleGameStateChanged;
            // 初始化当前模式
            _isBattleMode = GameStateManager.Instance.CurrentState == GameState.Battle;
        }

        // P8：订阅能量变化（刷新手牌能量标识红/白）与单卡弃牌（打出后重排手牌）
        var epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd != null) epd.OnEnergyChanged += HandleEnergyChanged;
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.OnCardDiscarded += HandleCardDiscarded;
        }
    }

    private void Update()
    {
        // ---- 右键：取消当前卡牌动作（拖出/箭头指向）★用户 2026-08-18 ----
        if (Input.GetMouseButtonDown(1) && _activeCard != null)
        {
            Debug.Log("[HandUI] 右键取消卡牌动作");
            ReturnActiveCard();
            return;
        }

        if (_activeCard == null) return;

        // ---- 点击跟随模式：鼠标未按住，卡牌仍跟随鼠标 + 阈值/箭头检测 ----
        if (!_activeFromDrag && !_arrowMode)
        {
            UpdateActiveCardFollow(_activeCard, Input.mousePosition);
        }

        // ---- 箭头模式：每帧更新箭头、目标高亮 ----
        if (_arrowMode)
        {
            UpdateArrow();
        }
    }

    /// <summary>
    /// 点击兜底：确认点击没落在 armed 卡上（空目标/被其他 UI 挡住）。
    /// 放 LateUpdate 保证在 EventSystem.Update（UGUI 点击分发）之后执行——
    /// 若本帧 UGUI 已处理点击（OnCardViewClicked 已刷新 _clickGuardFrame）则跳过，
    /// 避免"线下点击收回"被同帧二次触发；点在卡牌以外则按箭头/位置分治。
    /// </summary>
    private void LateUpdate()
    {
        if (_activeCard == null || _activeFromDrag) return;

        if (Input.GetMouseButtonDown(0) && Time.frameCount != _clickGuardFrame)
        {
            HandleArmedCardClick();
        }
    }

    private void OnDestroy()
    {
        if (GameStateManager.Instance != null)
            GameStateManager.Instance.OnStateChanged -= HandleGameStateChanged;

        var epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd != null) epd.OnEnergyChanged -= HandleEnergyChanged;
        if (CardPileManager.Instance != null)
        {
            CardPileManager.Instance.OnCardDiscarded -= HandleCardDiscarded;
        }

        // M5b-2：清理交互流视觉残留
        _arrowView.Hide();
        CardRangeHighlight.Clear();
    }

    /// <summary>
    /// P8：能量变化回调——刷新所有手牌的能量标识（不足变红）。
    /// </summary>
    private void HandleEnergyChanged(int currentEnergy)
    {
        RefreshCardAffordability();
    }

    /// <summary>
    /// P8：遍历手牌，按当前能量刷新每张卡的费用可负担状态（红/白）。
    /// </summary>
    private void RefreshCardAffordability()
    {
        var epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd == null) return;

        foreach (var cv in _cardViewInstances)
        {
            if (cv == null || cv.Card == null) continue;
            cv.SetEnergyAffordable(epd.CanAfford(cv.Card.CurrentCost));
        }
    }

    // ------------------------------------------------------------------
    // 公开 API（模式与选中）
    // ------------------------------------------------------------------

    /// <summary>
    /// 切换战斗/探索模式。
    /// 探索模式：卡牌灰显 + 无法选中。
    /// 战斗模式：卡牌恢复正常 + 可交互。
    /// </summary>
    public void SetBattleMode(bool isBattle)
    {
        _isBattleMode = isBattle;
        ApplyModeVisuals();
    }

    /// <summary>
    /// 取消当前选中（M5b 打完牌 / 点空地 / ESC 调用）。
    /// </summary>
    public void ClearSelection()
    {
        if (_selectedCard != null)
        {
            _selectedCard.SetSelected(false);
            _selectedCard = null;
            OnSelectionCleared?.Invoke();
        }
    }

    // ------------------------------------------------------------------
    // 模式视觉
    // ------------------------------------------------------------------

    /// <summary>
    /// 响应 GameStateManager 状态切换
    /// </summary>
    private void HandleGameStateChanged(GameState oldState, GameState newState)
    {
        // M5b-2：离开战斗时强制收回交互流中的卡牌（防状态残留）
        if (newState != GameState.Battle && _activeCard != null)
        {
            ReturnActiveCard();
        }
        // ★防残留 2026-08-18：离开战斗时若正悬停有射程的卡（卡牌隐藏，
        // OnPointerExit 不触发），射程高亮会残留——防御性清除
        if (newState != GameState.Battle)
        {
            CardRangeHighlight.Clear();
        }
        SetBattleMode(newState == GameState.Battle);
    }

    /// <summary>
    /// 应用当前模式的视觉效果
    /// ★2026-08-26 用户反馈：探索态手牌不再灰显半透明——正常显示、可悬停可点击
    /// （打牌入口仍由 Interactions/GameState 守卫拦截，视觉与交互解锁不影响规则）
    /// </summary>
    private void ApplyModeVisuals()
    {
        foreach (CardView cardView in _cardViewInstances)
        {
            if (cardView == null) continue;

            // 尝试获取 CanvasGroup（如果卡牌上有）
            CanvasGroup cg = cardView.GetComponent<CanvasGroup>();
            if (cg == null)
            {
                cg = cardView.GetComponentInChildren<CanvasGroup>();
            }

            if (cg != null)
            {
                cg.alpha = 1f;
                cg.blocksRaycasts = true;
            }
            else
            {
                // 没有 CanvasGroup，用 SpriteRenderer 透明度代替
                SpriteRenderer[] renderers = cardView.GetComponentsInChildren<SpriteRenderer>();
                foreach (SpriteRenderer sr in renderers)
                {
                    Color c = sr.color;
                    c.a = 1f;
                    sr.color = c;
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // 清理
    // ------------------------------------------------------------------

    /// <summary>
    /// 销毁所有 CardView 实例
    /// </summary>
    private void ClearAllCardViews()
    {
        // M5b-2 防御：销毁前强制清理交互流状态（armed 卡即将被销毁）
        if (_activeCard != null)
        {
            if (_arrowMode) { _arrowMode = false; _arrowView.Hide(); }
            if (_lastHighlightedEnemy != null)
            {
                _lastHighlightedEnemy.SetHighlighted(false);
                _lastHighlightedEnemy = null;
            }
            Interactions.PlayerIsDragging = false;
            CardRangeHighlight.Clear();
            _activeCard = null;
        }

        // 销毁前立即清扇开状态（安全网）
        if (_fannedHoverCard != null)
        {
            _fannedHoverCard = null;
        }

        foreach (CardView cardView in _cardViewInstances)
        {
            if (cardView != null)
            {
                cardView.transform.DOKill();
                Destroy(cardView.gameObject);
            }
        }
        _cardViewInstances.Clear();
        _baseAnchoredPositions.Clear();
        _hoveredCard = null;
        _selectedCard = null;
    }
}

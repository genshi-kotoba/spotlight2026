// =============================================================================
// 模块：战术卡槽面板 TacticSlotsPanel（2026-09-10 六次重做 / 底部横向「拓展手牌位」）
// 用途：屏幕**底部**的横向面板（宽度与手牌区同量级、高度刚好放下一整张卡面），
//       点战术按钮 = 从屏下升起盖住手牌区，再点 = 落回屏下。
//       面板里是**一格一格的完整卡面**（不是手牌扇形），整块**居中**排布：
//         装 1 张 → 1 张居中；装 2 张 → 两张并排居中；装 3 张 → 上行 2 张、下行 1 张居中。
//       格子是「战术槽装帧 + 卡面」，格与格之间留 20px 空隙（装帧外扩 ±10 才不会打架）。
//
// ★★ 打出的分界线 = **面板顶边那条金线**（PlayLine）
//   非指向卡：按住起手 → 卡跟手 → 越过金线亮绿描边（= 松手即打出）→ **松手才结算**；
//             线内松手 = 收回槽位。
//             ★与普通手牌同口径（HandUIController：过阈值只做预览，OnEndDrag 才打出）。
//             旧版「越线即待定 + 0.6s 撤回窗口」= 拖出去就自动打出去，用户 2026-09-10 要求改掉 → 已删。
//   指向卡（CardData.RequiresManualTarget）：**按住卡直接在原地伸出箭头**（卡不跟手、
//   也不像手牌那样挪到屏幕正中）→ 移鼠标选目标、箭头绿=射程内 → 点目标结算；右键取消。
//   「什么时候算打出」不再看面板左右边界，只看那条线 —— 面板在底部，向上拖才是打出意图，
//   左右拖出面板不该误触发（旧版用矩形边界，在底部布局下会变成「往旁边一滑就打出」）。
//
// ★★ 面板上**没有任何文字提示**（用户 2026-09-10 明确要求删干净：提示行 / 金线说明 /
//   「消耗骰子缩短冷却」按钮全部删除）。玩家侧反馈只走视觉：
//     越线 = 卡面绿描边；指向射程内 = 箭头绿；冷却 = 卡面黑色蒙版 + 剩余回合数字。
//   需要排查时看 Console 日志（原来落在提示行上的信息改成 Debug.Log）。
//
// 设计依据：
//   docs/superpowers/specs/2026-09-10-战术卡槽交互-design.md（手势，★本次已同步改写）
//   docs/superpowers/specs/2026-09-10-卡包装载与战术槽装帧-design.md（装帧 / 2 列 / 装载）
// 模型层：TacticSlotRuntime（无限容器 + 每槽冷却；槽内卡不进抽牌堆/手牌，用后只进冷却不消失）
// 装载入口：**不在本面板**——装载在卡包页边栏（CardPackUI）。本面板只负责「使用」。
// 复用：CardView（完整卡面）、PlayCardAction（统一结算出口）、TacticSlotFrame（装帧）、
//       TacticTargetSelector（指向命中/射程）、TargetingArrowView（箭头）、DicePayment（骰子）
//
// -----------------------------------------------------------------------------
// ★ 本面板只显示「有卡的槽」（不像卡包页边栏那样铺空格）
// -----------------------------------------------------------------------------
// 依据用户规格：「目前战术卡槽只有两个格子，别的地方就留空，但是面板还得在」+
// 「装载一张就是一张牌居中，装载两张就是两张在中间」。
// 若按 DisplaySlotCount 铺格（永远留一个空格），装 1 张时会出现「左格有卡 + 右格空」，
// 视觉上是偏左的，与「一张居中」直接冲突。所以：
//   战斗面板 = 只铺占用的槽，按序号顺序排，整块居中（无空格、无残缺行）
//   卡包页边栏 = 照旧按 DisplaySlotCount 铺格（拖拽要有落点）——那是装载侧，语义不同
// 槽序号 → 格序号的映射存在 _cellSlot 里（卡片消失/装配变化时按签名重建）。
//
// -----------------------------------------------------------------------------
// ★ 面板几何全部由代码定位（场景里的旧值一律无效）
// -----------------------------------------------------------------------------
// 旧版面板是「屏幕右侧 300×600 竖条」（锚点右下、PanelOpenY=215）。这次整块换成底部横排，
// 场景里存着的 anchor(1,0)/pivot(1,0)/size(300,600)/pos(0,-600) 全部作废 →
// 统一在 Start 的 EnforcePanelGeometry() 里改写锚点、pivot、尺寸、位置，并且
// **SetAsLastSibling()**：同画布下 HandView 的 sibling 比本面板靠后（= 画在上面），
// 面板要「盖住手牌」就必须排到最后，否则卡面会被手牌盖住（旧版在右侧没暴露这个问题）。
//
// -----------------------------------------------------------------------------
// ★★ 「槽内卡打不出」的**最终**修法（保留自上一版，不要再犯）
// -----------------------------------------------------------------------------
// 症状：起手日志一条都没有 → 点击根本没进到面板。原因不是判定逻辑，而是**输入通道**：
//   卡面走 UGUI 射线，而战术面板与手牌/骰子列表同画布，任何压在上面的 Graphic
//   （遮罩 / 手牌区 / 运行时面板）都可能把点击截走 —— 面板现在**盖在手牌上**，
//   这个风险比旧版更大。所以本面板输入**完全自管**：
//     Update 轮询指针 → RectTransformUtility 命中格位；卡面 Graphic 一律
//     raycastTarget = false（InventoryUIKit.DisableRaycast）→ 谁在上面都拦不住。
//   手势：按住拖动 → 越过金线 = 绿描边预览 → **松手**打出；线内松手 = 收回。
//        单击起手 = 点击跟随（松手后卡继续跟手）→ 再点一下：线上 = 打出 / 线下 = 收回。
//
// ★★★ 战术卡不再限战斗态（用户 2026-09-10 纠正）：与手牌同口径，Battle / Exploring 都能用。
//   旧代码在 4 处硬编码 `!InBattle()`，来源是 09-08 背包 spec §5「战术卡槽仅战斗可用」，
//   而该前提已在 09-05「探索态全解禁打牌」被用户废止 → 那段门禁就是「打不出来」的元凶。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using DG.Tweening;

/// <summary>
/// 战术卡槽面板控制器（底部横向面板 + 居中格阵 + 金线分界 + 指向卡原地箭头）。
/// </summary>
public class TacticSlotsPanel : MonoBehaviour
{
    /// <summary>交互状态机。</summary>
    public enum Phase
    {
        Idle,       // 面板开着、没有卡被起手
        Armed,      // 非指向卡：卡已脱离槽位、跟随鼠标（★松手才判定打出）
        Aiming      // 指向卡：卡留在槽里，箭头从卡身伸出，等玩家点目标
    }

    [Header("UI 引用")]
    [Tooltip("战术卡包按钮（点击伸出/收起面板，Toggle）")]
    public Button OpenTacticButton;

    [Tooltip("底部面板根节点（★锚点/pivot/尺寸/位置在 Start 里全部由代码改写）")]
    public RectTransform PanelRoot;

    [Tooltip("面板关闭按钮（可选，点击同样收回面板）")]
    public Button CloseButton;

    [Tooltip("卡牌视图预制体（留空则运行时从 HandUIController / CardViewCreator 自动取）")]
    public CardView CardViewPrefab;

    // ------------------------------------------------------------------
    // 面板几何（★[PLACEHOLDER · 待手测微调]，全部有反推依据）
    // ------------------------------------------------------------------
    [Header("面板几何（★代码定位，场景旧值无效）")]
    [Tooltip("面板宽度。手牌区 1600 宽、左右两侧卡堆（抽牌堆 x≈110~260 / 弃牌堆 x≈1660~1810），\n" +
             "1300 居中后占 x≈310~1610 —— 刚好夹在两堆之间，也不会压住右上角战术按钮与结束回合按钮。")]
    public float PanelWidth = 1300f;

    [Tooltip("面板高度（★2026-09-10 用户要求「矮一点」：316 → 240，比原版矮 24%）。\n" +
             "卡面展示高 172.5（预制体 154 × scale 1.4 × CellScale 0.8）\n" +
             "＋ 装帧外扩 20 ＋ 悬停上移 10 ＝ 202.5 ≤ 格阵视口高 224（单边余量 25.75）。\n" +
             "★顶边 = 伸出后 y 240：压住 HandView 容器顶（实测 238）与手牌卡带上沿（实测 213）。")]
    public float PanelHeight = 240f;

    [Tooltip("伸出位置（面板**底边** Y，屏幕坐标）。0 = 底边贴屏幕下沿。\n" +
             "★必须满足「PanelOpenY + PanelHeight ≥ HandView 容器顶(实测 238)」，否则盖不住手牌。\n" +
             "★不要改成正值：底边一离开屏幕下沿，手牌卡面就会从那条缝里露出来。")]
    public float PanelOpenY = 0f;

    [Tooltip("收起位置（面板底边 Y）。必须 ≤ -(面板高度) 才算完全离屏；Start 里会按高度再兜一次。\n" +
             "★不要改回「从场景读初始位置」：面板一旦被留在屏幕内，收起位置就被读成屏幕内坐标，\n" +
             "「收起」和「伸出」变成同一个位置，面板永远关不掉（曾发生）。")]
    public float PanelHiddenY = -270f;

    [Tooltip("面板收弹动效时长（线性滑动）。\n" +
             "★2026-09-10 用户要求「收齐和弹出加速一点」：0.32 → 0.18（快了约 44%）。\n" +
             "场景里序列化着旧值 0.32 —— 改这里的默认值**不够**，必须靠 MigrateLayoutPreset 的 v3 迁移覆盖。")]
    public float PanelSlideDuration = 0.18f;

    [Header("布局契约迁移（★不要手改）")]
    [Tooltip("面板几何契约版本号。每次改动「面板尺寸 / 位置 / 槽内缩放」的**语义**都要 +1；\n" +
             "版本低于当前值 → 上面那组几何旋钮会被重置成代码默认值。\n" +
             "为什么需要这道闸：Unity 把 Inspector 里存过的值序列化进场景，**改代码默认值不会生效**。\n" +
             "本面板已被这个坑咬过两次 —— ① ExitMargin 静默覆盖；② 旧版是「右侧 300×600 竖条」，\n" +
             "场景里 PanelWidth=300 / PanelOpenY=215 会把新的底部横排面板挤成 300 宽的小方块\n" +
             "（L2 实测：面板只占 x 810~1110，完全盖不住手牌）。\n" +
             "③ 2026-09-10 面板「矮一点 + 卡面缩小 + 完全不透明」：高度 316→240、CellScale 1→0.8、\n" +
             "伸出位 -18→0。场景里存着旧值，不提版本号就会继续看到「旧高度 + 旧卡大小」。")]
    [SerializeField] private int LayoutPreset = 0;
    private const int CurrentLayoutPreset = 3;

    // ------------------------------------------------------------------
    // 槽内布局
    // ------------------------------------------------------------------
    [Header("槽内布局（★居中格阵）")]
    [Tooltip("卡面设计尺寸（0 则运行时按预制体自动取，避免写死 110×154）")]
    public Vector2 CardDesignSize = Vector2.zero;
    [Tooltip("卡面展示缩放（0 则运行时按预制体自动取）")]
    public float CardDisplayScale = 0f;
    [Tooltip("槽内卡面额外缩放（叠加在预制体 scale 之上）。1 = 与手牌同大（154×215.6）；\n" +
             "0.8 = 123×172.5（★用户 2026-09-10：卡牌小一点，面板才收得矮）")]
    public float CellScale = 0.8f;
    [Tooltip("格间距。★必须 > 装帧外扩的两倍（20），否则相邻槽的光晕/角标会叠在一起")]
    public Vector2 CellSpacing = new Vector2(20f, 20f);
    [Tooltip("悬停时卡格整体上移的像素（用户：悬停特效就是卡牌向上移动一点）。\n" +
             "★上移量 + 装帧外扩(10) ≤ 视口上下留白，否则光晕顶到视口边会被 RectMask2D 裁出硬边\n" +
             "（232 面板 = 格阵视口 216、格高 172.5 → 单边余量 21.75 ≥ 10+10 ✓）")]
    public float HoverLift = 10f;

    // ------------------------------------------------------------------
    // 手势（[PLACEHOLDER · 待调]）
    // ------------------------------------------------------------------
    [Header("手势（[PLACEHOLDER · 待调]）")]
    [Tooltip("金线再往上抬多少像素才算「越界」。0 = 分界线就是面板顶边那条线")]
    public float BeyondMargin = 0f;
    [Tooltip("按下后移动超过这么多像素算「拖拽」，否则算「点击起手」")]
    public float DragThreshold = 8f;

    // ------------------------------------------------------------------
    // 配色（[PLACEHOLDER]）
    // ------------------------------------------------------------------
    // ★面板底必须 **alpha = 1（完全不透明）**：面板的职责就是盖住手牌区，
    //   半透明会让下面的手牌透出来（用户 2026-09-10 明确要求「不要半透明，直接盖住基础手牌区」）。
    private static readonly Color PanelBg = new Color(0.10f, 0.08f, 0.055f, 1f);
    private static readonly Color PanelLine = new Color(0.89f, 0.71f, 0.40f, 1f);
    private static readonly Color BoardBg = new Color(0.06f, 0.05f, 0.035f, 0.9f);   // 格阵底（叠在不透明面板上）
    private static readonly Color CellBorder = new Color(0.55f, 0.44f, 0.28f, 0.7f);
    // 冷却蒙版：黑色半透明盖住整张卡（用户：冷却直接显示在对应卡牌上，一眼知道这张牌还要等多久）
    private static readonly Color CdMaskColor = new Color(0f, 0f, 0f, 0.78f);
    /// <summary>确认缩短态的蒙版底色：暖棕（区别于普通冷却的纯黑，一眼看出「这张在等你确认」）。</summary>
    private static readonly Color CdMaskColorLit = new Color(0.18f, 0.12f, 0.02f, 0.90f);

    /// <summary>蒙版小字的两种文案（★文字只出现在卡面蒙版上，面板级提示行依然是零）。</summary>
    private const string CdLabelNormal = "冷却";
    /// <summary>★v9：装载整备期蒙版小字。整备不能用探索骰缩短，只能等回合结束。</summary>
    private const string CdLabelArming = "整备";
    private const string CdLabelConfirm = "再点 1 骰";

    // ------------------------------------------------------------------
    // 输入采样（★可注入：真机走 Input，编辑器 L2 可驱动完整手势链）
    // ------------------------------------------------------------------
    // 面板自管输入之后，「起手 → 越界 → 待定 → 结算 / 指向 → 选目标」整条链依赖
    // Input.mousePosition 与 GetMouseButton*，这两者在编辑器里无法伪造 ——
    // 抽出 Pointer 采样后，L2 可以逐帧喂合成指针，把整条链跑通并逐步断言。
    // 真机路径完全不变（_injected 默认 false）。

    /// <summary>一帧指针采样。</summary>
    public struct PointerSample
    {
        public Vector2 Position;
        public bool Down;       // 本帧按下左键
        public bool Held;       // 左键持续按住
        public bool Up;         // 本帧抬起左键
        public bool RightDown;  // 本帧按下右键（取消）
    }

    private bool _injected;
    private PointerSample _injectSample;

    /// <summary>本帧指针状态（默认真实鼠标）。</summary>
    private PointerSample Pointer
    {
        get
        {
            if (_injected) return _injectSample;
            PointerSample s;
            s.Position = Input.mousePosition;
            s.Down = Input.GetMouseButtonDown(0);
            s.Held = Input.GetMouseButton(0);
            s.Up = Input.GetMouseButtonUp(0);
            s.RightDown = Input.GetMouseButtonDown(1);
            return s;
        }
    }

    /// <summary>
    /// 【编辑器自动化 / L2 专用】注入一帧指针状态（真机不调用）。
    /// ★右键取消也走这里：旧版 UpdateArmed 里裸读 Input.GetMouseButtonDown(1)，
    ///   注入模式下那条分支测不到（L2 覆盖率黑洞），一并收进采样。
    /// </summary>
    public void InjectPointer(Vector2 position, bool down, bool held, bool up)
    {
        InjectPointer(position, down, held, up, false);
    }

    /// <summary>【编辑器自动化 / L2 专用】带右键的注入。</summary>
    public void InjectPointer(Vector2 position, bool down, bool held, bool up, bool rightDown)
    {
        _injected = true;
        _injectSample.Position = position;
        _injectSample.Down = down;
        _injectSample.Held = held;
        _injectSample.Up = up;
        _injectSample.RightDown = rightDown;
    }

    /// <summary>交回真实鼠标。</summary>
    public void ResetPointerInjection() { _injected = false; }

    // ------------------------------------------------------------------
    // 运行时状态
    // ------------------------------------------------------------------

    private readonly List<RectTransform> _cells = new List<RectTransform>();
    private readonly List<CardView> _cards = new List<CardView>();        // 槽位卡面（null = 没建出来）
    private readonly List<int> _cellSlot = new List<int>();               // 格 → 槽序号
    private readonly List<Card> _shown = new List<Card>();                // 已 SetCard 的卡（避免重复刷新）
    private readonly List<Vector2> _cellBasePos = new List<Vector2>();    // 布局基准位（悬停上移的回归点）
    private readonly List<Image> _cdMasks = new List<Image>();    // 冷却蒙版（盖住整张卡）
    private readonly List<Text> _cdNums = new List<Text>();       // 蒙版上的剩余回合数
    private readonly List<Text> _cdLabels = new List<Text>();     // 蒙版上的小字（「冷却」/「再点 1 骰」）

    /// <summary>冷却缩短的**确认态**：等第二次点击的格序号（-1 = 无）。
    /// 用户 2026-09-10 定稿的交互是「点击两次」——第一次只是表态，第二次才真的花骰子。</summary>
    private int _cdConfirmCell = -1;
    private readonly List<TacticSlotFrame> _frames = new List<TacticSlotFrame>();
    private readonly List<Image> _bgs = new List<Image>();

    private RectTransform _gridArea;      // 滚动视口外框（命中判定 + 裁剪用）
    private RectTransform _content;       // 格子的父节点（自身居中，块大于视口时可滚）
    private EnergyPointDisplay _epd;
    private string _builtSignature = null;   // 已建格的「占用槽签名」，变了才重建

    // 卡面几何（自适配预制体，不写死 110×154 / 1.4）
    private Vector2 _designSize = new Vector2(110f, 154f);
    private float _displayScale = 1f;
    private Vector2 _cellSize = new Vector2(154f, 215.6f);

    private float _hiddenY;
    private bool _isOpen;

    /// <summary>★2026-09-12 教程图：整套战术卡槽未解锁 → 不建网格、不接输入、隐藏入口按钮。</summary>
    private bool _tutorialDisabled;

    // 手势状态机
    private Phase _phase = Phase.Idle;
    private int _armedCell = -1;        // 起手/指向中的**格**序号（-1 = 无）
    private Vector2 _pressPos;
    private bool _dragged;              // 本次按住是否已经算「拖拽」
    private bool _clickFollow;          // 点击起手后进入「点击跟随」模式（松手后卡继续跟手）
    private bool _dragExceeded;         // 当前已越过金线（绿描边预览 = 松手即打出）
    private int _hoverCellIndex = -1;

    // 指向（沿用）
    private int _aimSlot = -1;                       // 指向中的**槽**序号（-1 = 无）
    private EnemyController _lastHighlightedEnemy;
    private readonly TargetingArrowView _arrowView = new TargetingArrowView();

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    private void Start()
    {
        // ★2026-09-12 教程图：战术卡槽整套未解锁 —— 藏掉入口按钮 + 整块面板，
        //   并且**不订阅任何输入**（Update 直接返回），避免"看不见但能点"的幽灵交互。
        if (MapLayoutBuilder.IsTutorial)
        {
            _tutorialDisabled = true;
            if (OpenTacticButton != null) OpenTacticButton.gameObject.SetActive(false);
            if (PanelRoot != null) PanelRoot.gameObject.SetActive(false);
            Debug.Log("[TacticSlotsPanel] 教程图：战术卡槽整套隐藏（入口按钮 + 面板）");
            return;
        }

        MigrateLayoutPreset();        // ★必须最先跑：旧场景的几何值在这之后才可信
        EnforcePanelGeometry();       // ★锚点/pivot/尺寸/位置/sibling 全部代码定位
        ResolvePrefab();
        BuildGrid();                  // ★先建网格：网格自带 Image（滚轮要吃射线），
        BuildChrome();                //   提示行 / 缩短按钮 / 关闭按钮必须建在它**之后**才画得在上面、点得到
        TacticSlotRuntime.OnChanged += OnSlotsChanged;

        if (OpenTacticButton != null) OpenTacticButton.onClick.AddListener(TogglePanel);
        if (CloseButton != null) CloseButton.onClick.AddListener(ClosePanel);

        _epd = FindObjectOfType<EnergyPointDisplay>();
        RefreshAll();
    }

    /// <summary>
    /// 布局契约迁移：把旧场景残留的几何值重置为代码默认（详见 <see cref="LayoutPreset"/> 注释）。
    /// 只对「低版本场景」生效一次；之后玩家/策划在 Inspector 里调的值会被尊重。
    /// </summary>
    private void MigrateLayoutPreset()
    {
        if (LayoutPreset >= CurrentLayoutPreset) return;

        PanelWidth = 1300f;
        PanelHeight = 240f;
        PanelOpenY = 0f;
        PanelHiddenY = -270f;
        CellScale = 0.8f;
        // ★HoverLift 必须一起重置：它与面板高度是一对约束
        //   （悬停上移 + 装帧外扩 ≤ 格阵视口单边余量）。场景里存着旧值 12 会把代码默认 10
        //   静默覆盖 → 光晕被 RectMask2D 裁边（2026-09-10 L2 实测：改默认值后仍读到 12，
        //   本陷阱第 3 次发作）。
        HoverLift = 10f;
        // ★v3（2026-09-10）：面板收弹加速。动效时长也是**序列化字段**——
        //   场景里存着 0.32，不提版本号就会被静默覆盖，代码里的 0.18 白改。
        //   这是同一个坑第 4 次发作（ExitMargin / 面板尺寸 / HoverLift / 本次时长）。
        PanelSlideDuration = 0.18f;

        LayoutPreset = CurrentLayoutPreset;
        Debug.Log($"[TacticSlotsPanel] 布局契约升级 → v{CurrentLayoutPreset}：面板几何重置为底部横排 " +
                  $"{PanelWidth}×{PanelHeight}，伸出 Y={PanelOpenY}");
    }

    /// <summary>
    /// 底部横向面板的锚点/尺寸/sibling 纠偏（★踩坑防线）。
    /// 旧版是「右侧竖条 300×600」，场景里存着 anchor(1,0)/pivot(1,0)/size(300,600)/pos(0,-600)；
    /// 这些值和本版布局完全冲突，而面板内容全部是代码动态建的 —— 几何不该由陈旧场景值决定。
    /// </summary>
    private void EnforcePanelGeometry()
    {
        if (PanelRoot == null)
        {
            Debug.LogError("[TacticSlotsPanel] PanelRoot 未连线，面板无法定位");
            return;
        }

        PanelRoot.anchorMin = PanelRoot.anchorMax = new Vector2(0.5f, 0f);   // 底部居中
        PanelRoot.pivot = new Vector2(0.5f, 0f);                             // pivot 在底边中点
        PanelRoot.sizeDelta = new Vector2(PanelWidth, PanelHeight);

        // 收起位置：≤ -面板高 才算完全离屏（留 30px 余量）
        float minHidden = -(PanelHeight + 30f);
        if (PanelHiddenY > minHidden) PanelHiddenY = minHidden;
        _hiddenY = PanelHiddenY;

        PanelRoot.DOKill();
        PanelRoot.anchoredPosition = new Vector2(0f, _hiddenY);
        PanelRoot.localScale = Vector3.one;
        _isOpen = false;

        // ★必须排到最后：同画布下 HandView 的 sibling 更靠后 = 画在面板之上，
        //   「面板盖住手牌」就无从谈起（旧版在右侧，没暴露这个问题）。
        PanelRoot.SetAsLastSibling();

        Debug.Log($"[TacticSlotsPanel] 面板几何：{PanelWidth}×{PanelHeight} 底部居中，收起 Y={_hiddenY}");
    }

    private void OnDestroy()
    {
        TacticSlotRuntime.OnChanged -= OnSlotsChanged;

        // 不走 EndTargeting()：那会碰已销毁的 UI 对象。只复位标志与锁。
        _phase = Phase.Idle;
        _armedCell = -1;
        _dragExceeded = false;
        _aimSlot = -1;
        Interactions.CardInteractionActive = false;
        Interactions.PlayerIsDragging = false;
        TacticTargetSelector.End();
        _arrowView.Hide();
    }

    // ------------------------------------------------------------------
    // 面板开关
    // ------------------------------------------------------------------

    public void TogglePanel()
    {
        if (_tutorialDisabled) return;      // 教程图：整套战术卡槽未解锁
        if (_isOpen) ClosePanel();
        else OpenPanel();
    }

    public void OpenPanel()
    {
        if (_tutorialDisabled) return;      // 教程图：整套战术卡槽未解锁
        if (_isOpen) return;
        _isOpen = true;
        SetCdConfirm(-1);                    // 重新展开 → 丢掉上次残留的确认态
        SetCdConfirm(-1);                    // 重新展开 → 丢掉上次残留的确认态
        if (PanelRoot != null)
        {
            PanelRoot.DOKill();   // 防与「正在收回」的 Tween 打架（待定撤回时会在收回中途反向弹出）
            PanelRoot.DOAnchorPosY(PanelOpenY, PanelSlideDuration).SetEase(Ease.Linear);
        }

        // ★2026-09-10：槽内卡骰值兜底 —— 每次展开都补一次分配（force=false：已有骰点不动，
        //   只补「从没掷过」的）。没有这一步，槽内卡卡面会停在 [1+战斗骰子1] 占位（用户报的 bug）。
        DicePayment.RefreshSlotDice(false);
        RefreshAll();

        Debug.Log("[TacticSlotsPanel] 面板已伸出（底部升起，盖住手牌区）");
    }

    public void ClosePanel()
    {
        // 起手中途收起面板 → 先把卡收回槽位，避免卡留在跟随层
        if (_phase == Phase.Armed) CancelArm();
        if (_phase == Phase.Aiming) CancelAiming();

        if (!_isOpen) return;
        _isOpen = false;
        SetCdConfirm(-1);                    // 收起 → 确认态清零，算式小窗一并收起
        HideAllCellTooltips();
        SetCdConfirm(-1);                    // 收起 → 确认态清零，算式小窗一并收起
        HideAllCellTooltips();
        if (PanelRoot != null)
        {
            PanelRoot.DOKill();
            PanelRoot.DOAnchorPosY(_hiddenY, PanelSlideDuration).SetEase(Ease.Linear);
        }
        Debug.Log("[TacticSlotsPanel] 面板已收起（落回屏下）");
    }

    // ==================================================================
    // 构建
    // ==================================================================

    private void ResolvePrefab()
    {
        if (CardViewPrefab == null && HandUIController.Instance != null && HandUIController.Instance.CardViewPrefab != null)
        {
            CardViewPrefab = HandUIController.Instance.CardViewPrefab;
        }
        if (CardViewPrefab == null && CardViewCreator.Instance != null)
        {
            CardViewPrefab = CardViewCreator.Instance.CardViewPrefab;
        }
        if (CardViewPrefab == null)
        {
            Debug.LogError("[TacticSlotsPanel] CardViewPrefab 解析失败：请在 Inspector 手动拖入卡牌预制体");
            return;
        }

        // 卡面几何自适配：设计尺寸 = 预制体 rect，展示缩放 = 预制体 localScale。
        // 布局按矩形算、缩放只是视觉溢出 —— 所以格宽取「设计尺寸 × 缩放 × CellScale」。
        RectTransform prt = CardViewPrefab.transform as RectTransform;
        if (prt != null && prt.sizeDelta.x > 1f && prt.sizeDelta.y > 1f) _designSize = prt.sizeDelta;
        float s = CardViewPrefab.transform.localScale.x;
        _displayScale = (s > 0.01f) ? s : 1f;

        if (CardDesignSize.x > 1f && CardDesignSize.y > 1f) _designSize = CardDesignSize;
        if (CardDisplayScale > 0.01f) _displayScale = CardDisplayScale;

        _cellSize = new Vector2(_designSize.x * _displayScale * CellScale,
                                _designSize.y * _displayScale * CellScale);
    }

    /// <summary>面板底 / 金线 / 提示行 / 缩短按钮（面板常驻装饰，不随槽格重建）。</summary>
    private void BuildChrome()
    {
        if (PanelRoot == null) return;

        // 面板底：场景里那层 Image 是纯白（没有任何配色），运行时统一压成深色铜底，
        // 否则「盖住手牌」就变成盖了一张白纸。
        Image panelBg = PanelRoot.GetComponent<Image>();
        if (panelBg != null)
        {
            if (panelBg.sprite == null) panelBg.sprite = InventoryUIKit.WhitePixel;
            panelBg.color = PanelBg;
            panelBg.raycastTarget = true;      // 面板区域吞掉点击（盖住的手牌不该还能被点到）
        }

        // ★打出分界线：面板顶边那条金线。判定用的就是它的 Y —— 线在哪，规则就在哪，看得见。
        Transform oldLine = PanelRoot.Find("PlayLine");
        if (oldLine != null) Destroy(oldLine.gameObject);
        Image line = InventoryUIKit.CreatePanel("PlayLine", PanelRoot, new Vector2(PanelWidth, 3f),
                                                Vector2.zero, PanelLine);
        RectTransform lineRT = line.rectTransform;
        lineRT.anchorMin = lineRT.anchorMax = new Vector2(0.5f, 1f);
        lineRT.pivot = new Vector2(0.5f, 0.5f);
        lineRT.anchoredPosition = new Vector2(0f, -1.5f);   // 正压在上边缘
        line.raycastTarget = false;

        // ★用户 2026-09-10：面板上**不留任何文字提示**——提示行与「消耗骰子缩短冷却」按钮全部删除。
        //   旧场景可能还序列化着这两个节点，一并清掉，免得过期 UI 残留。
        Transform staleHint = PanelRoot.Find("Hint");
        if (staleHint != null) Destroy(staleHint.gameObject);
        Transform staleBtn = PanelRoot.Find("ShortenCdBtn");
        if (staleBtn != null) Destroy(staleBtn.gameObject);

        // 关闭按钮：场景对象是个纯白方块，压成深铜底 + 补一个 × 字（没有文字看起来像坏图）。
        // ★必须 SetAsLastSibling：它是场景里的老子节点（排在最前），而网格自带吃射线的 Image，
        //   不提到最后就会被网格压住 → 按钮下半截点不动。
        if (CloseButton != null)
        {
            Image cimg = CloseButton.GetComponent<Image>();
            if (cimg != null) cimg.color = new Color(0.16f, 0.12f, 0.07f, 0.92f);
            if (CloseButton.GetComponentInChildren<Text>() == null)
            {
                Text x = InventoryUIKit.CreateLabel("Label", CloseButton.transform, "×", 22, InventoryUIKit.Brass,
                                                    TextAnchor.MiddleCenter);
                InventoryUIKit.Stretch(x.rectTransform);
            }
            // ★面板几何全部代码定位 → 关闭按钮也钉在面板**右上角**：
            //   它原来是右侧竖条上的物件，留着场景坐标会飘到新面板之外。
            RectTransform crt = CloseButton.transform as RectTransform;
            if (crt != null)
            {
                crt.anchorMin = crt.anchorMax = new Vector2(1f, 1f);
                crt.pivot = new Vector2(1f, 1f);
                crt.sizeDelta = new Vector2(28f, 28f);
                crt.anchoredPosition = new Vector2(-6f, -6f);
            }
            CloseButton.transform.SetAsLastSibling();
        }
    }

    /// <summary>
    /// 建滚动容器 + 每个「有卡的槽」一个格。
    /// 槽位占用集合变化（装/卸/换格）→ 整体重建；只是 CD/内容变化 → RefreshAll，不重建。
    /// </summary>
    private void BuildGrid()
    {
        if (PanelRoot == null)
        {
            Debug.LogError("[TacticSlotsPanel] PanelRoot 未连线，卡面无法创建");
            return;
        }

        // 重复建格防御（占用变化重建 / 编辑器 L2 调用 / Play 未重载状态）
        Transform existing = PanelRoot.Find("TacticGrid");
        if (existing != null) Destroy(existing.gameObject);

        ClearCellLists();

        float halfH = PanelHeight * 0.5f;
        float boardH = PanelHeight - 16f;                        // = PanelHeight - 上下留白 8×2（★没有提示行了）
        Vector2 boardSize = new Vector2(PanelWidth - 24f, boardH);
        Vector2 boardPos = new Vector2(0f, 8f + boardH * 0.5f - halfH);

        _gridArea = InventoryUIKit.CreateRect("TacticGrid", PanelRoot);
        InventoryUIKit.Place(_gridArea, boardSize, boardPos);
        Image bg = _gridArea.gameObject.AddComponent<Image>();
        bg.sprite = InventoryUIKit.WhitePixel;
        bg.color = BoardBg;
        bg.raycastTarget = true;   // ★必须留一个能吃射线的 Graphic：滚轮滚动靠它落到本节点

        RectTransform viewport = InventoryUIKit.CreateRect("Viewport", _gridArea);
        InventoryUIKit.Stretch(viewport);
        viewport.gameObject.AddComponent<RectMask2D>();      // 裁掉滚动出界的卡面（不需要 Graphic）

        _content = InventoryUIKit.CreateRect("Content", viewport);
        _content.anchorMin = _content.anchorMax = new Vector2(0.5f, 0.5f);   // 居中锚：块小则居中、块大才滚
        _content.pivot = new Vector2(0.5f, 0.5f);
        _content.sizeDelta = Vector2.zero;
        _content.anchoredPosition = Vector2.zero;

        ScrollRect scroll = _gridArea.gameObject.AddComponent<ScrollRect>();
        scroll.horizontal = false;
        scroll.vertical = true;
        scroll.movementType = ScrollRect.MovementType.Clamped;
        scroll.scrollSensitivity = 26f;
        scroll.viewport = viewport;
        scroll.content = _content;

        List<int> slots = OccupiedSlotIndices();
        for (int i = 0; i < slots.Count; i++) CreateCell(i, slots[i]);
        LayoutCells();
        _builtSignature = SlotSignature();

        if (slots.Count == 0)
        {
            Debug.Log("[TacticSlotsPanel] 战术卡槽是空的 —— 去卡包页把卡拖进战术卡槽");
        }
        Debug.Log($"[TacticSlotsPanel] 战术槽格阵：{slots.Count} 张卡（只铺有卡的槽，整块居中）");
    }

    private void ClearCellLists()
    {
        _cells.Clear();
        _cards.Clear();
        _cellSlot.Clear();
        _shown.Clear();
        _cellBasePos.Clear();
        _cdMasks.Clear();
        _cdNums.Clear();
        _cdLabels.Clear();
        _cdConfirmCell = -1;          // 格阵重建 → 确认态必然失效（格序号已不再指向同一张卡）
        _frames.Clear();
        _bgs.Clear();
        _hoverCellIndex = -1;
    }

    private void CreateCell(int cellIndex, int slotIndex)
    {
        RectTransform cell = InventoryUIKit.CreateRect("TacticCell" + (slotIndex + 1), _content);
        InventoryUIKit.Place(cell, _cellSize, Vector2.zero);   // 位置随后由 LayoutCells 统一算

        // 空槽底板 + 细边框（格子与卡同色时看得清边界）
        Image bg = cell.gameObject.AddComponent<Image>();
        bg.sprite = InventoryUIKit.WhitePixel;
        bg.color = InventoryUIKit.SlotBg;
        bg.raycastTarget = false;                 // ★面板自己轮询鼠标，槽格不吃射线
        Outline ol = cell.gameObject.AddComponent<Outline>();
        ol.effectColor = CellBorder;
        ol.effectDistance = new Vector2(1f, -1f);

        // ★战术槽装帧：Attach 会把自己设成 cell 的第一个子节点 → 光晕画在卡面之后
        _frames.Add(TacticSlotFrame.Attach(cell, _cellSize));

        CardView cv = CreateCardView(cell);

        // ★冷却显示（用户 2026-09-10）：**黑色半透明蒙版盖住整张卡**，蒙版上直接写剩余回合。
        //   比原来底部一行小字「冷却 3」直观得多：玩家一眼看到「这张牌还要等几回合」。
        //   蒙版必须建在卡面**之后**（= 画在卡上面）；RebuildSlot 重建卡面后要把它重新置顶。
        Image cdMask = InventoryUIKit.CreatePanel("CdMask", cell, _cellSize, Vector2.zero, CdMaskColor);
        cdMask.raycastTarget = false;

        Text cdLbl = InventoryUIKit.CreateLabel("CdLabel", cdMask.transform, "冷却", 13,
                                                InventoryUIKit.Cream, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(cdLbl.rectTransform, new Vector2(_cellSize.x, 20f),
                             new Vector2(0f, _cellSize.y * 0.5f - 26f));
        Text cdNum = InventoryUIKit.CreateLabel("CdNum", cdMask.transform, "", 34,
                                                InventoryUIKit.Brass, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(cdNum.rectTransform, new Vector2(_cellSize.x, 44f), new Vector2(0f, -4f));

        cdMask.gameObject.SetActive(false);        // 默认没冷却 → 隐藏（显隐由 RefreshOne 决定）

        _cells.Add(cell);
        _bgs.Add(bg);
        _cards.Add(cv);
        _cellSlot.Add(slotIndex);
        _shown.Add(null);
        _cellBasePos.Add(Vector2.zero);
        _cdMasks.Add(cdMask);
        _cdNums.Add(cdNum);
        _cdLabels.Add(cdLbl);
    }

    private CardView CreateCardView(RectTransform cell)
    {
        if (CardViewPrefab == null || cell == null) return null;

        CardView cv = Instantiate(CardViewPrefab, cell);
        cv.name = "TacticCard";

        // ★本面板输入自管：卡面不吃射线，也不走 UGUI 事件（TacticHost 只作为「拦住手牌路由」的哨兵）
        cv.TacticHost = this;
        InventoryUIKit.DisableRaycast(cv.gameObject);

        cv.transform.localScale = Vector3.one * (_displayScale * CellScale);
        cv.transform.localRotation = Quaternion.identity;   // ★全部正着摆（不是手牌扇形）

        RectTransform rt = cv.transform as RectTransform;
        if (rt != null)
        {
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.sizeDelta = _designSize;
            rt.anchoredPosition = Vector2.zero;
        }
        return cv;
    }

    /// <summary>
    /// 格阵居中排布（本版核心布局规则）。
    ///   ① 每一行内部**居中**：2 格时左右对称跨在中轴上，末行只剩 1 格时该格落在正中。
    ///   ② 整块**竖向居中**：行数少 → 贴着视口中线；行数多 → 溢出视口，靠 ScrollRect 滚。
    /// 与 GridLayoutGroup 的差别就在这里：Grid 的末行单格永远靠左，做不出「一张居中」。
    /// </summary>
    private void LayoutCells()
    {
        int n = _cells.Count;
        if (_content != null)
        {
            if (n == 0)
            {
                _content.sizeDelta = Vector2.zero;
                return;
            }
            float cols2 = Mathf.Max(1, TacticSlotRuntime.Columns);
            int rows2 = Mathf.CeilToInt(n / (float)cols2);
            float blockH2 = rows2 * _cellSize.y + (rows2 - 1) * CellSpacing.y;
            float blockW2 = cols2 * _cellSize.x + (cols2 - 1) * CellSpacing.x;
            // 兜底视口必须与 BuildGrid 的 boardH 一致（PanelHeight - 上下留白 16）。// 46 是「提示行时代」的旧值，已随零文字改版废止。
            Vector2 vp = _gridArea != null ? _gridArea.sizeDelta : new Vector2(PanelWidth - 24f, PanelHeight - 16f);
            _content.sizeDelta = new Vector2(Mathf.Max(blockW2, vp.x), Mathf.Max(blockH2, vp.y));
        }

        for (int i = 0; i < n; i++)
        {
            Vector2 pos = CellPosInBlock(i, n, _cellSize, CellSpacing, Mathf.Max(1, TacticSlotRuntime.Columns));
            _cellBasePos[i] = pos;

            RectTransform cell = _cells[i];
            if (cell == null) continue;
            DOTween.Kill(cell);                 // 布局重算时掐掉在飞的悬停 Tween，否则会打架
            cell.anchoredPosition = pos;
            cell.localScale = Vector3.one;
        }
    }

    /// <summary>
    /// 单格在「居中块」里的位置（★纯函数，L2 直接断言，不依赖 UI 构建）。
    /// total=1 → (0,0)；total=2 → (-87,0)/(+87,0)；total=3（2 列）→ 上行 ±87、下行 0 居中。
    /// </summary>
    public static Vector2 CellPosInBlock(int index, int total, Vector2 cellSize, Vector2 spacing, int columns)
    {
        if (total <= 0 || index < 0 || index >= total) return Vector2.zero;

        int cols = Mathf.Max(1, columns);
        int rows = Mathf.CeilToInt(total / (float)cols);
        int row = index / cols;
        int col = index % cols;
        int inRow = Mathf.Min(cols, total - row * cols);       // ★本行实际格数（末行不足时按实际居中）

        float x = (col - (inRow - 1) * 0.5f) * (cellSize.x + spacing.x);
        float y = ((rows - 1) * 0.5f - row) * (cellSize.y + spacing.y);
        return new Vector2(x, y);
    }

    /// <summary>重建单个槽位的卡面（结算后卡仍留在槽里，只是刷新显示）。</summary>
    private void RebuildSlot(int slotIndex)
    {
        int ci = CellIndexForSlot(slotIndex);
        if (ci < 0) return;
        if (_cards[ci] != null) { Destroy(_cards[ci].gameObject); _cards[ci] = null; }
        _shown[ci] = null;
        _cards[ci] = CreateCardView(_cells[ci]);
        // ★冷却蒙版重新置顶：新卡面会顶到最上层，把蒙版盖住（蒙版必须永远在卡之上）
        if (ci < _cdMasks.Count && _cdMasks[ci] != null) _cdMasks[ci].transform.SetAsLastSibling();
        RefreshOne(ci);
    }

    // ==================================================================
    // 刷新
    // ==================================================================

    private void OnSlotsChanged()
    {
        // ★占用集合变了（装/卸/换格）才重建格阵：只按数量比对会在「换格」时漏判
        if (_builtSignature != SlotSignature()) BuildGrid();
        RefreshAll();
    }

    private void RefreshAll()
    {
        for (int i = 0; i < _cells.Count; i++) RefreshOne(i);
    }

    private void RefreshOne(int cellIndex)
    {
        if (cellIndex < 0 || cellIndex >= _cards.Count) return;
        CardView cv = _cards[cellIndex];
        int slot = _cellSlot[cellIndex];
        Card card = TacticSlotRuntime.Get(slot);
        int cd = TacticSlotRuntime.GetCooldown(slot);
        // ★v9：不可用 = 冷却 或 整备（装载延迟），两者共用同一块蒙版
        int arming = TacticSlotRuntime.GetArming(slot);
        int block = cd > arming ? cd : arming;

        // 空槽：隐藏卡面
        if (cv != null)
        {
            cv.gameObject.SetActive(card != null);
            if (card != null && !ReferenceEquals(_shown[cellIndex], card))
            {
                cv.SetCard(card);
                _shown[cellIndex] = card;
            }
            // 可负担（能量不足 → 费用位变红）
            if (card != null && _epd != null) cv.SetEnergyAffordable(_epd.CanAfford(card.CurrentCost));
        }

        // 冷却蒙版：盖住整张卡 + 显示剩余回合（cd <= 0 时整块隐藏）
        if (cellIndex < _cdMasks.Count && _cdMasks[cellIndex] != null)
        {
            // 冷却归零 → 确认态立刻作废（没有 CD 可缩了）
            if (block <= 0 && _cdConfirmCell == cellIndex) SetCdConfirm(-1);

            _cdMasks[cellIndex].gameObject.SetActive(block > 0);
            if (block > 0 && cellIndex < _cdNums.Count && _cdNums[cellIndex] != null)
            {
                _cdNums[cellIndex].text = block.ToString();

                // 小字回落普通态（这一格没处在「再点 1 骰」确认态时）
                if (cellIndex < _cdLabels.Count && _cdLabels[cellIndex] != null
                    && cellIndex != _cdConfirmCell)
                {
                    _cdLabels[cellIndex].text = cd > 0 ? CdLabelNormal : CdLabelArming;
                }
                // ★每次显形都重新置顶（同一格内卡面与蒙版是兄弟，靠 sibling 决定谁画在上面）。
                //   起手跟手时 Arm/FollowMouse 会把卡面 SetAsLastSibling() 顶到最上层，
                //   此时蒙版被压到卡下面；若玩家把卡「线内松手」放回槽里，就没有 RebuildSlot 来
                //   把蒙版重新置顶 → 冷却中的卡会显示成一张正常的卡、看不出还在冷却
                //   （2026-09-10 L3 实机抓到：层级成了 装帧/蒙版/卡面）。这里做唯一兜底。
                Transform mt = _cdMasks[cellIndex].transform;
                if (mt.GetSiblingIndex() != mt.parent.childCount - 1) mt.SetAsLastSibling();
            }
        }

        // 战术槽装帧：有卡才亮；起手（卡跟手飞出去了）/ 指向期间 → 装帧熄灭；冷却中 → 死灰
        if (cellIndex < _frames.Count && _frames[cellIndex] != null)
        {
            bool occupied = card != null && _armedCell != cellIndex;
            _frames[cellIndex].SetOccupied(occupied);
            if (occupied)
            {
                _frames[cellIndex].SetLit(block <= 0);
                _frames[cellIndex].SetHover(_hoverCellIndex == cellIndex);
            }
        }
    }

    // ==================================================================
    // 输入（★面板自管：Update 轮询指针，不经 UGUI）
    // ==================================================================

    private void Update()
    {
        if (_tutorialDisabled) return;      // 教程图：不接任何输入
        switch (_phase)
        {
            case Phase.Armed: UpdateArmed(); break;
            case Phase.Aiming: UpdateAiming(); break;
            default: UpdateIdle(); break;
        }
    }

    private void UpdateIdle()
    {
        UpdateHover();

        if (!Pointer.Down) return;
        if (!_isOpen) return;                        // 面板收起时不接输入（开关只认按钮）

        int ci = CellIndexUnderPointer();
        if (ci < 0) return;                          // 不在卡格上 → 交给 UGUI（关闭按钮 / 缩短按钮 / 滚动）

        int slot = _cellSlot[ci];
        Card card = TacticSlotRuntime.Get(slot);
        if (card == null) return;

        if (!CanUseCards())
        {
            Debug.Log("[TacticSlotsPanel] 当前无法使用战术卡（结算或暂停中）");
            return;
        }

        int cd = TacticSlotRuntime.GetCooldown(slot);
        int arming = TacticSlotRuntime.GetArming(slot);
        int block = cd > arming ? cd : arming;
        if (block > 0)
        {
            // ★v9：整备期（刚装载的那 1 回合）**不能用探索骰买** ——
            //   能买就等于「花钱即时换卡」，B 方案的规划性会被直接买穿，延迟白设。
            if (cd <= 0)
            {
                Debug.Log($"[TacticSlotsPanel] 槽 {slot + 1} 整备中（剩 {arming} 回合）："
                          + "刚装上的卡要等回合结束才就绪");
                return;
            }

            // ★2026-09-10 用户定稿：冷却缩短回来了，但机制换了 ——
            //   「点击两次后使用一枚探索骰子减少 1 CD」。没有按钮、没有提示行，
            //   全部反馈画在卡面那块冷却蒙版上（第一次点击 → 蒙版转暖底 + 小字变「再点 1 骰」）。
            //
            //   为什么这里**不做** PlayerCanInteract / CanPayCardCost 检查：
            //   那两道闸是「能不能打牌」的闸（敌人回合、结算中、能量、探索骰）；
            //   缩短冷却不是打牌 —— 它自己那道闸是「还有没有探索骰」，在
            //   TrySpendExplorationDiceForCooldown 里单独判，两道闸互不干涉。
            if (_cdConfirmCell == ci) TrySpendExplorationDiceForCooldown(ci, slot);
            else SetCdConfirm(ci);
            return;
        }
        SetCdConfirm(-1);                    // 这张能打 → 顺手清掉可能残留的确认态

        if (!Interactions.PlayerCanInteract())
        {
            Debug.Log("[TacticSlotsPanel] 结算中，指针输入被忽略");
            return;
        }
        if (!Interactions.CanPayCardCost(card))
        {
            // ★探索态有两种不同的失败原因，必须分开说：
            //   CanPayCardCost 在 Exploring 下 = 能量够 + 至少剩 1 枚探索骰。
            //   旧版一律提示「能量不足」，玩家会去查能量（查错方向）——真正原因常常是骰子打光了。
            if (GameStateManager.Instance != null
                && GameStateManager.Instance.CurrentState == GameState.Exploring
                && (ExplorationTurnManager.Instance == null
                    || ExplorationTurnManager.Instance.RemainingExplorationDice() <= 0))
            {
                Debug.Log("[TacticSlotsPanel] 探索骰子用完了——探索态每打一张牌需 1 枚，结束回合可补满");
            }
            else
            {
                Debug.Log($"[TacticSlotsPanel] 能量不足（需要 {card.CurrentCost}），无法打出");
            }
            return;
        }

        // ★指向卡 / 非指向卡在这里分流（用户规格）：
        //   指向卡 = 按住直接在**原地**伸出箭头（卡不跟手、不挪到屏幕中间）
        //   非指向卡 = 卡脱离槽位跟着鼠标走，越过金线松手 = 打出
        if (card.Data != null && card.Data.RequiresManualTarget) BeginAiming(ci);
        else BeginArm(ci, Pointer.Position);
    }

    /// <summary>鼠标落在哪个卡格上；不在滚动视口内（含被滚出视野的格）→ -1。</summary>
    private int CellIndexUnderPointer()
    {
        if (_gridArea == null) return -1;

        Vector2 p = Pointer.Position;
        if (!RectTransformUtility.RectangleContainsScreenPoint(_gridArea, p, null)) return -1;

        for (int i = 0; i < _cells.Count; i++)
        {
            if (_cells[i] == null) continue;
            if (RectTransformUtility.RectangleContainsScreenPoint(_cells[i], p, null)) return i;
        }
        return -1;
    }

    private void UpdateHover()
    {
        int ci = _isOpen ? CellIndexUnderPointer() : -1;

        // ★算式小窗：本面板输入自管、卡面整棵子树 raycastTarget=false →
        //   CardView.OnPointerMove 永远不会被触发，算式小窗自然也不会弹。
        //   这里每帧把指针位置喂给「悬停的那一格」的卡面，走的是与手牌**同一套** tooltip 代码
        //   （CardView.DriveValueTooltip），不另写一份。非悬停格收起小窗。
        DriveCellTooltip(ci);

        if (ci == _hoverCellIndex) return;

        SetHoverLook(_hoverCellIndex, false);
        _hoverCellIndex = ci;
        SetHoverLook(_hoverCellIndex, true);

        // 指针移到别的格（或移出格阵）→ 冷却缩短的确认态复位
        //（不复位的话玩家会「忘记自己点过哪张」，第二次点击落在别处却把骰子花了）
        if (_cdConfirmCell >= 0 && _cdConfirmCell != ci) SetCdConfirm(-1);

        // ★没有任何悬停文字提示（用户要求删干净）：悬停反馈 = 格子上移 + 装帧增亮 + 卡面金框
    }

    /// <summary>把指针位置喂给悬停格的卡面（算式小窗），其余格收起小窗。</summary>
    private void DriveCellTooltip(int cellIndex)
    {
        for (int i = 0; i < _cards.Count; i++)
        {
            CardView cv = _cards[i];
            if (cv == null || !cv.gameObject.activeSelf) continue;
            if (i == cellIndex) cv.DriveValueTooltip(Pointer.Position);
            else cv.HideValueTooltipExternal();
        }
    }

    /// <summary>收起所有卡面的算式小窗（面板收起 / 卡被摘走时调）。</summary>
    private void HideAllCellTooltips()
    {
        for (int i = 0; i < _cards.Count; i++)
        {
            if (_cards[i] != null) _cards[i].HideValueTooltipExternal();
        }
    }

    /// <summary>悬停视觉：整格**上移一点**（用户规格）+ 装帧增亮 + 卡面金框。</summary>
    private void SetHoverLook(int cellIndex, bool on)
    {
        if (cellIndex < 0) return;

        if (cellIndex < _cells.Count && _cells[cellIndex] != null)
        {
            RectTransform cell = _cells[cellIndex];
            Vector2 basePos = cellIndex < _cellBasePos.Count ? _cellBasePos[cellIndex] : cell.anchoredPosition;
            Vector2 target = on ? basePos + new Vector2(0f, HoverLift) : basePos;
            DOTween.Kill(cell);
            cell.DOAnchorPos(target, 0.12f).SetEase(Ease.OutQuad);
        }
        if (cellIndex < _frames.Count && _frames[cellIndex] != null) _frames[cellIndex].SetHover(on);
        if (cellIndex < _cards.Count && _cards[cellIndex] != null) _cards[cellIndex].SetPanelCardHover(on);
    }

    /// <summary>
    /// 切换/清除「冷却缩短确认态」。传 -1 = 清除。
    /// 视觉全部落在卡面那块冷却蒙版上（★面板级提示行保持零——用户明确要求过）：
    ///   普通冷却 = 纯黑蒙版 + 「冷却」+ 剩余回合
    ///   确认态   = 暖棕蒙版 + 「再点 1 骰」+ 剩余回合
    /// </summary>
    private void SetCdConfirm(int cellIndex)
    {
        if (cellIndex == _cdConfirmCell) return;

        if (_cdConfirmCell >= 0) ApplyCdConfirmLook(_cdConfirmCell, false);
        _cdConfirmCell = cellIndex;
        if (cellIndex >= 0) ApplyCdConfirmLook(cellIndex, true);
    }

    private void ApplyCdConfirmLook(int cellIndex, bool on)
    {
        if (cellIndex < 0 || cellIndex >= _cdMasks.Count) return;

        Image mask = _cdMasks[cellIndex];
        if (mask != null) mask.color = on ? CdMaskColorLit : CdMaskColor;

        if (cellIndex < _cdLabels.Count && _cdLabels[cellIndex] != null)
        {
            _cdLabels[cellIndex].text = on ? CdLabelConfirm : CdLabelNormal;
        }
    }

    /// <summary>
    /// 冷却缩短：**扣 1 枚探索骰子换 1 点冷却**（用户 2026-09-10 定稿）。
    ///
    /// 为什么是探索骰而不是战斗骰：战斗骰是「打牌的弹药」，冷却再从弹药池抽血，
    /// 两个系统会互相打架（弹药可见性设计本来就是为了让扣骰有痛感）；
    /// 探索骰是「节奏资源」，把它花在「提前解锁这张战术卡」上，是一道干净的取舍题。
    ///
    /// 失败（骰子用完 / 结算中）→ 直接退出确认态，不留一个点不动的死状态。
    /// </summary>
    private void TrySpendExplorationDiceForCooldown(int cellIndex, int slot)
    {
        SetCdConfirm(-1);                                   // 先复位：无论成败，确认态都到此为止

        if (!Interactions.PlayerCanInteract())
        {
            Debug.Log("[TacticSlotsPanel] 结算中，冷却缩短被忽略");
            return;
        }

        ExplorationTurnManager etm = ExplorationTurnManager.Instance;
        if (etm == null)
        {
            Debug.Log("[TacticSlotsPanel] 场景里没有 ExplorationTurnManager，冷却缩短不可用");
            return;
        }

        if (!etm.TryConsumeExplorationDice())
        {
            Debug.Log($"[TacticSlotsPanel] {CardName(slot)} 缩短冷却失败：探索骰子已用完（结束回合会补满）");
            return;
        }

        int before = TacticSlotRuntime.GetCooldown(slot);
        TacticSlotRuntime.ShortenCooldown(slot, 1);
        int after = TacticSlotRuntime.GetCooldown(slot);

        Debug.Log($"[TacticSlotsPanel] 消耗 1 枚探索骰子 → {CardName(slot)} 冷却 {before} → {after} 回合" +
                  (after <= 0 ? "（已可用）" : ""));
    }

    // ------------------------------------------------------------------
    // Armed：非指向卡跟手，松手 / 越线分治
    // ------------------------------------------------------------------

    private void BeginArm(int cellIndex, Vector2 screenPos)
    {
        CardView cv = cellIndex >= 0 && cellIndex < _cards.Count ? _cards[cellIndex] : null;
        if (cv == null) return;

        SetHoverLook(_hoverCellIndex, false);
        _hoverCellIndex = -1;

        _phase = Phase.Armed;
        _armedCell = cellIndex;
        _pressPos = screenPos;
        _dragged = false;
        _clickFollow = false;
        _dragExceeded = false;

        Interactions.CardInteractionActive = true;   // 锁移动
        Interactions.PlayerIsDragging = true;
        cv.InteractionLocked = true;
        cv.SetSelected(true);

        // 脱离槽位 → 挪到跟随层（UICanvas），不受面板滑动影响
        DOTween.Kill(cv.transform);
        RectTransform root = FollowRoot;
        if (root != null)
        {
            cv.transform.SetParent(root, true);
            cv.transform.SetAsLastSibling();
        }
        cv.transform.localScale = Vector3.one * (_displayScale * CellScale * 1.08f);
        cv.SetPlayPreview(false);       // 清掉上一轮可能残留的绿描边（越线预览）
        FollowMouse(cv, screenPos);

        // ★装帧熄灭：卡已离开槽格（光晕留在原地会穿帮）
        RefreshOne(cellIndex);

        Debug.Log($"[TacticSlotsPanel] 起手：槽 {_cellSlot[cellIndex] + 1} {CardName(_cellSlot[cellIndex])}" +
                  "（拖过金线亮绿描边 → 松手才打出）");
    }

    /// <summary>
    /// 非指向卡跟手中。★「什么时候算打出」与**普通手牌完全同口径**
    /// （对照 HandUIController.Interaction：过阈值只 SetPlayPreview 预览，OnEndDrag 才 ExecutePlay）：
    ///   按住期间 —— 越过金线只亮绿描边，**绝不**自动打出；
    ///   松手时   —— 指针在线上 = 打出；线下 = 收回槽位；
    ///   点击跟随 —— 再点一下时按同一把尺子分治（线上打出 / 线下收回）。
    /// 旧版「越线即进待定 + 0.6s 撤回窗口」= 拖出去就自动打出去，已按用户要求删除。
    /// </summary>
    private void UpdateArmed()
    {
        Interactions.CardInteractionActive = true;

        if (!CanUseCards()) { CancelArm(); return; }
        if (Pointer.RightDown) { CancelArm(); return; }   // ★走采样，注入模式下也测得到

        CardView cv = _armedCell >= 0 && _armedCell < _cards.Count ? _cards[_armedCell] : null;
        if (cv == null) { CancelArm(); return; }

        FollowMouse(cv, Pointer.Position);

        if (Pointer.Down)
        {
            _dragged = false;                        // 又按了一下：重新开始计「拖拽」
            _pressPos = Pointer.Position;
        }

        if (Pointer.Held)
        {
            if (!_dragged &&
                ((Vector2)Pointer.Position - _pressPos).sqrMagnitude > DragThreshold * DragThreshold)
            {
                _dragged = true;
            }
            // ★按住期间只做预览（线上一亮 = 松手即打出），不结算 —— 打出必须等松手
            SetDragExceededLook(MouseBeyondPlayLine(), cv);
            return;
        }

        if (!Pointer.Up) return;                     // 等松手（点击跟随下 = 等下一次点击的抬起）

        // ---- 松手 = 决策（与手牌 OnEndDrag 一致：越线打出 / 线内收回）----
        if (_clickFollow || _dragged)
        {
            if (MouseBeyondPlayLine()) PlaySlot(_armedCell);
            else CancelArm();
            return;
        }

        // 首次点击的抬起 → 转入「点击跟随」（卡继续跟手；再点一下 / 拖过线松手才结算）
        _clickFollow = true;
    }

    /// <summary>越线预览：卡面绿描边（与手牌 SetPlayPreview 同一语义）。只在状态翻转时写。</summary>
    private void SetDragExceededLook(bool on, CardView cv)
    {
        if (_dragExceeded == on) return;
        _dragExceeded = on;
        if (cv != null) cv.SetPlayPreview(on);
    }

    private void CancelArm()
    {
        int ci = _armedCell;
        _phase = Phase.Idle;
        _armedCell = -1;
        _clickFollow = false;
        _dragged = false;
        _dragExceeded = false;
        Interactions.CardInteractionActive = false;
        Interactions.PlayerIsDragging = false;

        if (ci < 0) return;
        CardView cv = ci < _cards.Count ? _cards[ci] : null;
        if (cv != null)
        {
            cv.SetPlayPreview(false);          // 清掉越线预览的绿描边
            ReturnCardToCell(cv, ci);
        }
        RefreshOne(ci);                        // 装帧随卡回槽一起复亮
        Debug.Log("[TacticSlotsPanel] 收回槽位（未越过金线 / 右键取消）");
    }

    /// <summary>把卡从跟随层收回原槽格。</summary>
    private void ReturnCardToCell(CardView cv, int cellIndex)
    {
        if (cv == null) return;
        cv.SetSelected(false);
        cv.ResetTacticHoverState();
        cv.InteractionLocked = false;

        DOTween.Kill(cv.transform);
        cv.transform.localScale = Vector3.one * (_displayScale * CellScale);
        cv.transform.localRotation = Quaternion.identity;

        if (cellIndex < 0 || cellIndex >= _cells.Count || _cells[cellIndex] == null) return;

        cv.transform.SetParent(_cells[cellIndex], true);
        RectTransform rt = cv.transform as RectTransform;
        if (rt != null)
        {
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.sizeDelta = _designSize;
            rt.DOAnchorPos(Vector2.zero, 0.15f).SetEase(Ease.OutQuad);
        }
        cv.transform.SetAsLastSibling();
    }

    private void FollowMouse(CardView cv, Vector2 screen)
    {
        RectTransform root = FollowRoot;
        if (root == null || cv == null) return;
        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(root, screen, null, out Vector2 local))
        {
            cv.transform.localPosition = new Vector3(local.x, local.y, 0f);
        }
    }

    // ------------------------------------------------------------------
    // 打出（★由 UpdateArmed 在「松手且越过金线」时调用）
    // ------------------------------------------------------------------

    /// <summary>
    /// 打出槽内非指向卡：上 CD → 分骰 → 走统一出牌链 → 重建该格卡面。
    /// ★槽内卡用后**不消失**（这是它区别于手牌的地方）：只进冷却，卡留在原槽。
    /// 因此这里把「跟着鼠标那张卡面」销毁，再由 RebuildSlot 在槽格里重建一张（盖着冷却蒙版）。
    /// </summary>
    private void PlaySlot(int cellIndex)
    {
        if (cellIndex < 0 || cellIndex >= _cells.Count) { CancelArm(); return; }

        int slot = _cellSlot[cellIndex];
        Card card = TacticSlotRuntime.Get(slot);

        _phase = Phase.Idle;
        _armedCell = -1;
        _clickFollow = false;
        _dragged = false;
        _dragExceeded = false;
        Interactions.CardInteractionActive = false;
        Interactions.PlayerIsDragging = false;

        CardView fly = cellIndex < _cards.Count ? _cards[cellIndex] : null;
        if (fly != null)
        {
            DOTween.Kill(fly.transform);
            Destroy(fly.gameObject);
            _cards[cellIndex] = null;
        }

        if (card == null || card.Data == null || !CanUseCards())
        {
            RebuildSlot(slot);
            return;
        }

        // 防御：指向卡本该走 BeginAiming，不该落到这条路径（真落到这里也按指向处理）
        if (card.Data.RequiresManualTarget)
        {
            RebuildSlot(slot);
            BeginAiming(cellIndex);
            return;
        }

        TacticSlotRuntime.ApplyCooldown(slot);
        DicePayment.AssignCardDice(card);
        Debug.Log($"[TacticSlotsPanel] 使用战术卡：槽 {slot + 1} {card.Data.cardName}（松手越过金线）");

        if (ActionSystem.Instance != null)
        {
            ActionSystem.Instance.Perform(new PlayCardAction(card, null));
        }

        RebuildSlot(slot);
    }

    // Aiming：指向卡原地伸箭头（★用户规格：卡不挪窝，箭头从卡身上伸出）
    // ------------------------------------------------------------------

    private void BeginAiming(int cellIndex)
    {
        int slot = _cellSlot[cellIndex];
        Card card = TacticSlotRuntime.Get(slot);
        if (card == null || card.Data == null) return;

        SetHoverLook(_hoverCellIndex, false);

        _phase = Phase.Aiming;
        _aimSlot = slot;
        _armedCell = -1;

        Interactions.CardInteractionActive = true;    // 锁移动，避免点到战场就走路
        Interactions.PlayerIsDragging = false;
        TacticTargetSelector.Begin(card);             // 刷敌人缓存 + 射程高亮

        // 卡留在槽里（区别于手牌：手牌是指向卡挪到弧线正中）。只把它抬亮成「正在指向」。
        _hoverCellIndex = cellIndex;
        SetHoverLook(cellIndex, true);
        if (cellIndex < _cards.Count && _cards[cellIndex] != null) _cards[cellIndex].SetSelected(true);

        Canvas canvas = GetCanvas();
        if (canvas != null) _arrowView.Show(canvas);   // 箭头挂画布顶层，盖在面板之上

        Debug.Log($"[TacticSlotsPanel] 指向：槽 {slot + 1} {card.Data.cardName}（箭头自卡身伸出）");
    }

    private void UpdateAiming()
    {
        Interactions.CardInteractionActive = true;    // 手牌交互流也写这个标记，指向期间每帧重新断言

        if (!CanUseCards())
        {
            CancelAiming();
            return;
        }
        if (Pointer.RightDown)
        {
            CancelAiming();
            return;
        }

        Card card = TacticSlotRuntime.Get(_aimSlot);
        if (card == null || card.Data == null) { CancelAiming(); return; }

        // ---- 每帧：目标判定 + 箭头两端 ----
        EnemyController enemy = TacticTargetSelector.EnemyUnderMouse();
        bool valid = enemy != null && TacticTargetSelector.InRange(enemy, card);

        if (_lastHighlightedEnemy != null && _lastHighlightedEnemy != enemy)
        {
            _lastHighlightedEnemy.SetHighlighted(false);
            _lastHighlightedEnemy = null;
        }
        if (valid && enemy != null)
        {
            enemy.SetHighlighted(true);
            _lastHighlightedEnemy = enemy;
        }
        CardRangeHighlight.HighlightTargetTile(valid && enemy != null ? (Vector2Int?)enemy.CurrentCoord : null);

        int ci = CellIndexForSlot(_aimSlot);
        CardView cv = (ci >= 0 && ci < _cards.Count) ? _cards[ci] : null;
        RectTransform cardRT = cv != null ? cv.transform as RectTransform : null;
        if (cardRT != null)
        {
            Vector2 start = RectTransformUtility.WorldToScreenPoint(null, cardRT.position);   // 起点 = 卡身中心
            _arrowView.SetEndpoints(start, Pointer.Position, valid);
        }

        // ---- 点击判定 ----
        // ★面板优先：面板盖在手牌/战场上，指针在面板矩形内时**一律不往下打**。
        //   否则「在面板上点一下想取消」会打到面板背后看不见的敌人（射线不看 UI 层级）。
        bool inPanel = PanelRoot != null
                       && RectTransformUtility.RectangleContainsScreenPoint(PanelRoot, Pointer.Position, null);
        if (inPanel)
        {
            if (Pointer.Down) { CancelAiming(); }
            return;
        }

        if (!Pointer.Down && !Pointer.Up) return;   // 按下 / 抬起都算选中（拖过去松手也顺手）

        if (enemy == null) return;                  // 点在战场空白处 = 保持指向（不惩罚手抖）

        if (!valid)
        {
            // 射程外不给文字提示（面板无提示）：箭头保持「无效」染色即为反馈，细节进 Console
            int dist = TacticTargetSelector.DistanceToPlayer(enemy);
            Debug.Log(dist < 0
                ? "[TacticSlotsPanel] 超出射程"
                : $"[TacticSlotsPanel] 超出射程（距离 {dist} > 射程 {card.Data.Range}）");
            return;
        }

        ExecuteUse(_aimSlot, enemy);
    }

    /// <summary>退出指向：清箭头 / 射程高亮 / 敌人高亮 / 姿态，卡一直在槽里不用搬。</summary>
    private void CancelAiming()
    {
        int ci = CellIndexForSlot(_aimSlot);
        _phase = Phase.Idle;
        _aimSlot = -1;
        Interactions.CardInteractionActive = false;
        Interactions.PlayerIsDragging = false;

        if (_lastHighlightedEnemy != null) { _lastHighlightedEnemy.SetHighlighted(false); _lastHighlightedEnemy = null; }
        CardRangeHighlight.HighlightTargetTile(null);
        TacticTargetSelector.End();               // 清射程高亮 + 清缓存
        _arrowView.Hide();

        // 卡一直没离开槽位，只需要把姿态复位
        if (ci >= 0)
        {
            _hoverCellIndex = -1;
            SetHoverLook(ci, false);
            if (ci < _cards.Count && _cards[ci] != null) _cards[ci].SetSelected(false);
            RefreshOne(ci);
        }
    }

    // ------------------------------------------------------------------
    // 几何判定
    // ------------------------------------------------------------------

    /// <summary>面板顶边（= 打出分界线）的屏幕 Y。</summary>
    private float PanelTopScreenY()
    {
        if (PanelRoot == null) return 0f;

        Vector3[] corners = new Vector3[4];
        PanelRoot.GetWorldCorners(corners);
        float maxY = float.MinValue;
        for (int i = 0; i < 4; i++)
        {
            Vector2 sp = RectTransformUtility.WorldToScreenPoint(null, corners[i]);
            if (sp.y > maxY) maxY = sp.y;
        }
        return maxY;
    }

    /// <summary>是否已经越过金线（打出意图确认）。</summary>
    private bool MouseBeyondPlayLine()
    {
        return Pointer.Position.y > PanelTopScreenY() + BeyondMargin;
    }

    private RectTransform FollowRoot
    {
        get
        {
            if (PanelRoot != null && PanelRoot.parent != null)
            {
                RectTransform rt = PanelRoot.parent as RectTransform;
                if (rt != null) return rt;
            }
            return PanelRoot;
        }
    }

    private Canvas GetCanvas()
    {
        if (PanelRoot == null) return null;
        return PanelRoot.GetComponentInParent<Canvas>();
    }

    // ==================================================================
    // 使用槽内卡（指向卡选定目标时调用）
    // ==================================================================

    /// <summary>
    /// 使用槽内卡：上 CD（防连点）→ 槽位骰子分配 → 退出指向 → 走既有出牌动作链。
    /// 动作链上的连锁效果：PlayCardSystem 步骤 1 因 HasRolled == true 跳过兜底掷骰；
    /// 步骤 2 PayOnPlay 扣费（统一出口）；步骤 4 扣能量。
    /// </summary>
    private void ExecuteUse(int slot, EnemyController target)
    {
        Card card = TacticSlotRuntime.Get(slot);
        if (card == null || card.Data == null)
        {
            CancelAiming();
            return;
        }

        TacticSlotRuntime.ApplyCooldown(slot);
        DicePayment.AssignCardDice(card);

        Debug.Log($"[TacticSlotsPanel] 使用战术卡：槽 {slot + 1} {card.Data.cardName} → " +
                  $"目标 {(target != null ? target.gameObject.name : "无")}，" +
                  $"进入冷却 {TacticSlotRuntime.GetCooldown(slot)} 回合");

        CancelAiming();                 // 清箭头 / 射程高亮 / 敌人高亮

        if (ActionSystem.Instance != null)
        {
            ActionSystem.Instance.Perform(new PlayCardAction(card, target));
        }
        RefreshAll();
    }

    // ==================================================================
    // CardView 路由入口（★哨兵：本面板输入自管，这些入口只为拦住 CardView 的手牌路由）
    // ==================================================================
    // 卡面 Graphic 已全部 raycastTarget = false，正常永远走不到这里；
    // 万一哪天有人给卡面开了射线，也不会掉进手牌出牌流（那才是真正难查的 bug）。
    public void OnSlotCardClicked(CardView cv) { Debug.LogWarning("[TacticSlotsPanel] 收到 UGUI 点击——本面板应自管输入，请检查卡面 raycastTarget"); }
    public void OnSlotCardDragStarted(CardView cv) { }
    public void OnSlotCardDragged(CardView cv, Vector2 screenPosition, Camera uiCamera) { }
    public void OnSlotCardDragEnded(CardView cv) { }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    /// <summary>
    /// 战术卡「现在能不能用」。
    /// ★用户 2026-09-10 纠正：**不再限定战斗态**，与手牌同口径（Battle / Exploring 都可起手）。
    ///
    /// 旧实现只认 GameState.Battle，依据是 `2026-09-08-背包系统-design.md` §5
    /// 「战术卡槽仅战斗可用；探索态不影响唯一牌堆」—— 但那句成立于「探索态不能打牌」的旧前提，
    /// 而该前提已在 2026-09-05 被用户废止（`Interactions.PlayerCanInteract` 注释：
    /// 「探索态全解禁，探索中随时可打牌」）。战术卡槽是「拓展的手牌位」，手牌能用的场合它就该能用。
    /// </summary>
    private static bool CanUseCards()
    {
        if (GameStateManager.Instance == null) return false;
        GameState s = GameStateManager.Instance.CurrentState;
        return s == GameState.Battle || s == GameState.Exploring;
    }

    /// <summary>当前有卡的槽序号（战斗面板只铺这些槽 → 才能做到「一张居中」）。</summary>
    private static List<int> OccupiedSlotIndices()
    {
        var list = new List<int>();
        for (int i = 0; i < TacticSlotRuntime.SlotCount; i++)
        {
            if (TacticSlotRuntime.IsOccupied(i)) list.Add(i);
        }
        return list;
    }

    /// <summary>占用槽签名（形如 "0,2,3"）：用于判断格阵要不要重建。</summary>
    private static string SlotSignature()
    {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < TacticSlotRuntime.SlotCount; i++)
        {
            if (!TacticSlotRuntime.IsOccupied(i)) continue;
            if (sb.Length > 0) sb.Append(',');
            sb.Append(i);
        }
        return sb.ToString();
    }

    private int CellIndexForSlot(int slot)
    {
        for (int i = 0; i < _cellSlot.Count; i++)
        {
            if (_cellSlot[i] == slot) return i;
        }
        return -1;
    }

    /// <summary>
    /// 取某槽对应格子的 RectTransform（外部飞行动画用）。
    /// 用途：鉴定事件里槽内卡被「取消弃牌」时要飞回原槽 —— EventPopupUI 靠它拿落点。
    /// 面板没铺格 / 该槽没有格（未占用且超出显示格数）→ null，调用方自行兜底落点。
    /// </summary>
    public RectTransform CellTransformForSlot(int slot)
    {
        int ci = CellIndexForSlot(slot);
        if (ci < 0 || ci >= _cells.Count) return null;
        return _cells[ci];
    }

    private string CardName(int slot)
    {
        Card card = TacticSlotRuntime.Get(slot);
        return card != null && card.Data != null ? card.Data.cardName : ("槽 " + (slot + 1));
    }
}

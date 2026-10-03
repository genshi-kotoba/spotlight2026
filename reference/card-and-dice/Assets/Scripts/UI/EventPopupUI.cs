// =============================================================================
// 模块：探索系统 - 通用事件弹窗 EventPopupUI
// 用途：单一弹窗复用「事件 / 鉴定 / 撤离确认」三类场景。
//       事件流程：标题+描述+选项 →（鉴定选项）鉴定板（骰子+单行公式+DISCARD面板）
//               → 三态交互（悬停→锁定→确认）→ 结果文案 → 关闭。
// 设计依据：《设计增补_探索系统_v2.md》§7.4 D19 v2.5
//
// ★重要：本脚本不构建任何 UI！所有节点（标题/文案/骰子/公式/弃牌槽/选项容器）
//   都来自预制体 Assets/Prefabs/UI/EventPopup.prefab，由用户在预制体里手动摆放位置。
//   代码只按固定名称绑定引用，动态内容（选项按钮/结果确认按钮）才在运行时生成。
//   ★唯一例外：选项区的滚动骨架 —— 行容器 OptionsContent / 细滚动条 OptionsScrollbar
//     由代码运行时补挂（预制体里已有同名节点则直接采用，节点内样式可自行改）。
//
// 预制体节点结构（名称固定，位置随便调）：
//   EventPopup            —— 全屏 RectTransform（拉伸铺满 Canvas），默认不激活
//   └─ Panel              —— 面板底图（深色 + 金描边）
//      ├─ Title           —— 标题文本
//      ├─ Desc            —— 描述文本（支持富文本首字下沉）
//      ├─ CheckBoard      —— 鉴定板容器（整体挪动用）
//      │  ├─ DiceImage    —— 骰子面图片（代码动态生成 Sprite）
//      │  └─ DiscardPanel —— 弃牌槽面板（Image 深色底 + Outline 金边）
//      │     └─ DiscardTitle —— “DISCARD · 弃牌辅助鉴定”标题
//      ├─ FormulaPanel    —— 公式面板（Image 深色底 + Outline 金边，同 DiscardPanel 样式）
//      │  └─ FormulaText  —— 单行公式文本
//      └─ OptionsRoot     —— 选项按钮容器（含 VerticalLayoutGroup，模板 OptionButtonTemplate）
//                            运行时被改造成滚动视口：内容节点与滚动条由代码补挂
//
// ★绑定规则：所有节点按【名称】深度查找（不限层级），预制体里节点放哪、怎么挪都行，
//   只要节点名不变就能绑上。
//
// ★选项区滚动 + 上方紧凑档（2026-09-17 用户二次定稿：「选项全部展示；压缩文字和鉴定区；
//   超出压缩能力才滚动」）：框高固定 620；描述/鉴定区按定稿压缩（描述 fs16、骰子 90×90、
//   弃牌面板高 100、鉴定区整体上移 36 —— 全部是预制体数值，代码不参与布局）；
//   选项区顶边 266、底边 12（视口 254 = 4 行整），4 行以内全部展示、不滚动，
//   第 5 行起被裁剪 → 滚轮/拖拽/拖滚动条兜底查看。
// 　结果阶段（摘要+确认按钮）顶边上移 _resultPhaseLiftY、视口加高到 314，不会裁到确认按钮。
// 　结果阶段描述框按文案实测高度向下长（顶边不动；鉴定区已隐藏、框下是空区），列表态复位。
//   ★改选项行高 / 行距请改 OptionsRoot 的 VerticalLayoutGroup 与模板行尺寸 ——
//     代码会把这组设置整体搬到行容器上执行（口径不变：childControlHeight=off → 行高取行自身）。
//   模板行 OptionButtonTemplate 留在 OptionsRoot 原处不搬（行照克隆进行容器）——
//     资产子节点搬不进运行时新增节点，编辑器静默拒绝 SetParent，搬了也是白搬。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using DG.Tweening;

// ===================== 颜色/属性 映射小工具 =====================
internal static class CheckUIMap
{
    public static string CharFor(CheckType t) => t switch
    {
        CheckType.力量 => "力",
        CheckType.敏捷 => "敏",
        CheckType.智力 => "智",
        CheckType.体质 => "体",
        CheckType.运气 => "运",
        _ => "·"
    };

    public static Color ColorFor(CheckType t) => t switch
    {
        CheckType.力量 => new Color(0.85f, 0.49f, 0.36f),   // 铜红
        CheckType.敏捷 => new Color(0.18f, 0.80f, 0.44f),   // 墨绿
        CheckType.智力 => new Color(0.40f, 0.65f, 0.95f),   // 蓝
        CheckType.体质 => new Color(0.89f, 0.71f, 0.40f),   // 黄铜
        CheckType.运气 => new Color(1.00f, 0.82f, 0.25f),   // 骰金（与事件格标记同色）
        _ => new Color(0.96f, 0.89f, 0.77f)                 // 奶黄
    };

    public static SuitOption SuitFor(CheckType t) => t switch
    {
        CheckType.力量 => SuitOption.红色,
        CheckType.敏捷 => SuitOption.绿色,
        CheckType.智力 => SuitOption.蓝色,
        CheckType.体质 => SuitOption.黄色,
        _ => SuitOption.无       // 含「运气」：无花色 → 基础分 0、弃牌加成 0
    };
}

/// <summary>
/// 通用事件弹窗（挂预制体根 EventPopup，单例）。
/// </summary>
public class EventPopupUI : MonoBehaviour
{
    // ====================================================================
    // 单例
    // ====================================================================
    private static EventPopupUI instance;

    /// <summary>单例兜底（编辑态 Awake 不执行、instance 可能为 null 时现找）。</summary>
    public static EventPopupUI Inv()
    {
        if (instance != null) return instance;
        instance = FindObjectOfType<EventPopupUI>();
        return instance;
    }

    /// <summary>弹窗当前是否打开（EventTile 点击本格重开时的守卫）</summary>
    public static bool IsOpen => instance != null && instance.gameObject.activeSelf;

    public bool IsCheckPanelOpen => gameObject.activeSelf && currentCheckOption != null;

    // ====================================================================
    // UI 引用（从预制体子节点按名称绑定，Inspector 不需要手动拖）
    // ====================================================================
    [Header("【基础区】标题 & 描述")]
    [SerializeField] private Text titleText;
    [SerializeField] private Text descText;

    [Header("【鉴定板】骰子 / 公式 / 弃牌槽")]
    [SerializeField] private Image diceImage;
    [SerializeField] private Sprite[] diceFaceSprites;
    [SerializeField] private Text diceFaceText;
    [SerializeField] private Text formulaText;
    [SerializeField] private RectTransform discardPanel;
    [SerializeField] private Text discardTitleText;
    [SerializeField] private float discardCardScale = 0.6f;

    [Header("【选项区】按钮容器（滚动骨架 OptionsContent/OptionsScrollbar 由代码运行时补挂）")]
    [SerializeField] private Transform optionButtonsRoot;

    [Header("【面板节点参照】Panel / CheckBoard / FormulaPanel（空白点击 & 显隐）")]
    [SerializeField] private RectTransform panelRT;
    [SerializeField] private RectTransform checkBoardRT;
    [SerializeField] private RectTransform formulaPanelRT;

    [Header("动画参数")]
    // ★v2.9 用户定稿：飞入/飞出弃牌槽 = 缩小+直线平移（弧线抛物线方案废弃）
    [SerializeField] private float flyDuration = 0.5f;
    [SerializeField] private float flyEndScaleFactor = 0.3f;

    // ====================================================================
    // 配色方案（深色+金色主题）
    // ====================================================================
    private static readonly Color Brass    = new Color(0.89f, 0.71f, 0.40f); // #E3B567 黄铜
    private static readonly Color Gold     = new Color(0.78f, 0.59f, 0.25f); // #C7973F 金色描边
    private static readonly Color GoldLight= new Color(0.95f, 0.83f, 0.55f); // 亮金
    private static readonly Color Cream    = new Color(0.96f, 0.89f, 0.77f); // #F6E4C4 奶黄
    private static readonly Color Copper   = new Color(0.85f, 0.49f, 0.36f); // #D97D5B 铜红
    private static readonly Color DarkBg   = new Color(0.10f, 0.06f, 0.02f); // 深棕黑

    // ====================================================================
    // 当前事件状态
    // ====================================================================
    private EventData currentEvent;
    private EventOption currentCheckOption;
    private int discardBonus;

    // ★荒野事件（design §3.3–§3.4）：结果里挂起的选牌 / 进战，等弹窗关闭时执行
    private int _pendingRemoveCards;
    private int _pendingDuplicateCards;
    private int _pendingCombatCount;

    private readonly Dictionary<Card, CardView> _panelCards = new Dictionary<Card, CardView>();

    /// <summary>
    /// ★2026-09-10 槽内卡参与弃牌鉴定：记录「从战术卡槽飞进 DISCARD 面板」的卡原属哪个槽。
    /// 取消弃牌时按这个序号装回原槽 —— 不记的话卡会凭空掉回牌库、玩家的槽位白丢一张。
    /// 手牌来的卡**不在**此表里（它们的归位逻辑仍然是「回手牌」，走 HandUIController）。
    /// </summary>
    private readonly Dictionary<Card, int> _slotCardOrigins = new Dictionary<Card, int>();
    private readonly HashSet<CardView> _flyingSet = new HashSet<CardView>();

    private CheckType? _hoveredCheck;
    private CheckType? _lockedCheck;

    /// <summary>
    /// 本事件所有鉴定选项对应的花色集合（v2.8）：
    /// 弹窗刚打开 / 悬停离开后 → 这些花色的手牌全部伸出（多解法全展开）。
    /// </summary>
    private List<SuitOption> _eventSuits = new List<SuitOption>();

    /// <summary>手牌过滤的锁定花色（点击第一次选项时设置）</summary>
    private CheckType? _handFilterLock;

    /// <summary>面板卡拖拽中的 CardView（D19 v2.6：拖离 DISCARD 面板 = 回手牌）</summary>
    private CardView _panelDragCV;

    private readonly List<OptionButtonUI> _optionUI = new List<OptionButtonUI>();

    // ====================================================================
    // 内嵌：单个选项按钮的 UI 句柄
    // ====================================================================
    private class OptionButtonUI
    {
        public CheckType CT;
        public GameObject Root;
        public Image RowBG;       // 行底图（三态背景 + 点击区）
        public Outline RowOutline;// 行边框（三态描边）
        public Image CircleBG;
        public Text CircleChar;
        public Text ActionText;
        public Image LockedGlow;
        public Button Btn;

        /// <summary>★代价门禁（design §3.2）：当前付不起 → 置灰、不可点</summary>
        public bool Unpayable;

        /// <summary>本按钮对应的选项（代价门禁直接用，不靠下标对齐）</summary>
        public EventOption Opt;
    }

    // ====================================================================
    // 生命周期 & 单例
    // ====================================================================
    public static void ShowEvent(EventData data)
    {
        if (data == null) return;
        EnsureInstance();
        instance?.OpenEvent(data);
    }

    private static void EnsureInstance()
    {
        if (instance != null) return;

        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas != null)
        {
            Transform t = canvas.transform.Find("EventPopup");
            if (t != null)
            {
                instance = t.GetComponent<EventPopupUI>();
                if (instance != null) return;
            }
        }

        Debug.LogWarning("[EventPopupUI] 场景 UICanvas/EventPopup 不存在，请在场景里放置 EventPopup 预制体");
    }

    private void Awake()
    {
        if (instance != null && instance != this) { Destroy(gameObject); return; }
        instance = this;
        BindReferences();
    }

    private void OnDestroy()
    {
        if (instance == this) instance = null;
    }

    /// <summary>
    /// 按【名称】深度查找绑定预制体子节点引用（不创建、不修改任何节点）。
    /// 不限制层级——预制体里节点挪到哪里都能绑上，只要名称不变。
    /// </summary>
    private void BindReferences()
    {
        titleText        = FindNode<Text>("Title");
        descText         = FindNode<Text>("Desc");
        diceImage        = FindNode<Image>("DiceImage");
        diceFaceText     = FindNode<Text>("DiceFaceText");
        formulaText      = FindNode<Text>("FormulaText");
        discardPanel     = FindNode<RectTransform>("DiscardPanel");
        discardTitleText = FindNode<Text>("DiscardTitle");
        optionButtonsRoot = FindNode<Transform>("OptionsRoot");
        panelRT          = FindNode<RectTransform>("Panel");
        checkBoardRT     = FindNode<RectTransform>("CheckBoard");
        formulaPanelRT   = FindNode<RectTransform>("FormulaPanel");
        EnsureOptionsScrollView();   // ★固定框高+滚动：把 OptionsRoot 改造成滚动视口（幂等）

        // 绑定失败提示（方便用户排查预制体缺节点）
        if (titleText == null) Debug.LogWarning("[EventPopupUI] 缺少节点 Title");
        if (descText == null) Debug.LogWarning("[EventPopupUI] 缺少节点 Desc");
        if (diceImage == null) Debug.LogWarning("[EventPopupUI] 缺少节点 DiceImage");
        if (formulaText == null) Debug.LogWarning("[EventPopupUI] 缺少节点 FormulaText");
        if (discardPanel == null) Debug.LogWarning("[EventPopupUI] 缺少节点 DiscardPanel");
        if (optionButtonsRoot == null) Debug.LogWarning("[EventPopupUI] 缺少节点 OptionsRoot");
        if (panelRT == null) Debug.LogWarning("[EventPopupUI] 缺少节点 Panel（点空白解除锁定失效）");

        // ★v2.11：面板底图点击 = "空白处"点击 → 解除选项锁定，回到初始状态。
        // 选项行/面板卡自带 Button 会截住点击（不冒泡），只有点到面板空区才触发。
        // BindReferences 每次 OpenEvent 都会执行，用 hasClick 防重复注册。
        if (panelRT != null)
        {
            EventTrigger panelET = panelRT.GetComponent<EventTrigger>();
            if (panelET == null) panelET = panelRT.gameObject.AddComponent<EventTrigger>();
            bool hasClick = false;
            foreach (EventTrigger.Entry t in panelET.triggers)
                if (t.eventID == EventTriggerType.PointerClick) hasClick = true;
            if (!hasClick)
                AddEvent(panelET, EventTriggerType.PointerClick, _ => ResetCheckLockState());
        }
    }

    /// <summary>按名称在所有后代中深度查找（BFS），返回第一个名称匹配的节点上的指定组件。</summary>
    private T FindNode<T>(string name) where T : Component
    {
        var queue = new Queue<Transform>();
        queue.Enqueue(transform);
        while (queue.Count > 0)
        {
            Transform t = queue.Dequeue();
            if (t.name == name)
            {
                T comp = t.GetComponent<T>();
                if (comp != null) return comp;
            }
            foreach (Transform child in t) queue.Enqueue(child);
        }
        return null;
    }

    // ====================================================================
    // 打开 / 关闭
    // ====================================================================
    private void OpenEvent(EventData data)
    {
        // ★修复：弹窗默认 inactive，首次打开时 Awake 尚未执行 → 引用全 null，
        // 标题/选项会被空引用守卫跳过，显示预制体占位文本（"默认模板"）。
        // BindReferences 是幂等的深度查找，这里补绑一次（此后 SetActive 才触发 Awake）。
        BindReferences();

        currentEvent = data;
        currentCheckOption = null;
        discardBonus = 0;
        _pendingRemoveCards = 0;
        _pendingDuplicateCards = 0;
        _pendingCombatCount = 0;
        _hoveredCheck = null;
        _lockedCheck = null;
        EnsureCloseButton(); // ★右上角 X 暂时关闭按钮（首次打开时创建一次）
        CharacterStats.PendingCards.Clear(); // ★v2.12：防御清空（上次弹窗异常关闭时防泄漏）
        ClearPanelCards();
        _optionUI.Clear();
        ShiftOptionsRootForResult(false); // ★复原选项区：撤销结果阶段上移，底边/顶边回列表态
        ResetDescBox();                   // ★复原描述框：撤销结果态的长高（回预制体尺寸/位置）

        // 标题
        if (titleText != null)
        {
            titleText.text = data.title;
        }

        // 描述首字下沉
        if (descText != null && !string.IsNullOrEmpty(data.description))
        {
            string firstChar = data.description.Substring(0, 1);
            string restDesc = data.description.Length > 1 ? data.description.Substring(1) : "";
            string firstColor = $"#{ColorUtility.ToHtmlStringRGB(GoldLight)}";
            string restColor = $"#{ColorUtility.ToHtmlStringRGB(Cream)}";
            descText.text = $"<size=38><color={firstColor}><b>{firstChar}</b></color></size><size=18><color={restColor}>{restDesc}</color></size>";
        }
        else if (descText != null)
        {
            descText.text = "";
        }

        // 弃牌槽标题
        if (discardTitleText != null && string.IsNullOrEmpty(discardTitleText.text))
        {
            discardTitleText.text = "DISCARD · 弃牌辅助鉴定";
        }

        // 构建选项按钮
        BuildOptionButtons();

        // ★即时性铁律：代价可用性挂在「背包变化那一刻」，不等悬停/重开
        InventoryManager invMgr = InventoryManager.Instance;
        if (invMgr != null && invMgr.Inventory != null)
        {
            invMgr.Inventory.OnChanged -= OnInventoryChangedWhileOpen;
            invMgr.Inventory.OnChanged += OnInventoryChangedWhileOpen;
        }

        // 鉴定面板始终存在：找到第一个鉴定选项，默认显示其骰面/公式（仅展示，不锁定）
        EventOption firstCheck = null;
        _eventSuits = new List<SuitOption>();
        foreach (var opt in data.options)
        {
            if (opt.checkType != CheckType.无)
            {
                if (firstCheck == null) firstCheck = opt;
                // ★v2.8：收集本事件所有鉴定选项的花色（力量+敏捷两种解法 → 红+绿都伸出）
                SuitOption s = CheckUIMap.SuitFor(opt.checkType);
                if (!_eventSuits.Contains(s)) _eventSuits.Add(s);
            }
        }
        if (firstCheck != null)
        {
            // ★v2.8 修复"点一次就确认"：打开时不预设锁定（_lockedCheck=null），
            // 骰面/公式默认展示第一个鉴定选项，但点它第一次 = 锁定，第二次才确认
            _lockedCheck = null;
            _handFilterLock = null;
            currentCheckOption = firstCheck;
            SetCheckBoardVisible(true);
            RefreshDiceAndFormula();
            // 刚打开 → 本事件所有相关花色手牌全部伸出（多解法），用不上的缩下
            EnterCheckAssistMode(_eventSuits);
            RefreshOptionButtonVisuals();
        }
        else
        {
            SetCheckBoardVisible(false);
        }

        // ★选项行数与鉴定板显隐都定了 → 激活后再量内容（滚动条显隐/回顶）
        gameObject.SetActive(true);
        RefreshOptionsScroll();
        Interactions.ModalPopupActive = true;
        PopupFX.PlayOpen(transform as RectTransform);   // ★2026-09-12 统一入场手感
    }

    private void ClosePopup()
    {
        ReturnAllPanelCardsImmediate();
        if (HandUIController.Instance != null) HandUIController.Instance.ExitCheckAssistMode();

        gameObject.SetActive(false);
        Interactions.ModalPopupActive = false;
        currentEvent = null;
        currentCheckOption = null;
        _hoveredCheck = null;
        _lockedCheck = null;
        _handFilterLock = null;
        _panelDragCV = null;

        InventoryManager invMgrClose = InventoryManager.Instance;
        if (invMgrClose != null && invMgrClose.Inventory != null)
            invMgrClose.Inventory.OnChanged -= OnInventoryChangedWhileOpen;

        EventTile.NotifyPopupClosed();

        // ★失败进战（design §3.3）：顺序 = 结果文案 → 关闭弹窗 → 进战
        if (_pendingCombatCount > 0)
        {
            int n = _pendingCombatCount;
            _pendingCombatCount = 0;
            if (ExplorationTurnManager.Instance != null)
                ExplorationTurnManager.Instance.StartEventCombat(n);
        }
    }

    // ====================================================================
    // ★右上角 X 暂时关闭按钮（用户 2026-09-05 需求）：
    // 点击 → 关闭弹窗但不判定事件结束——事件保留在格子上，
    // 玩家再次点击自己脚下这一格地板即可重新打开（EventTile.OnMouseUpAsButton）。
    // 按钮挂在 Panel 右上角，纯代码生成（预制体无需加节点）。
    // ====================================================================
    private Button _closeBtn;

    private void EnsureCloseButton()
    {
        if (_closeBtn != null) return;
        RectTransform panelRT = FindNode<RectTransform>("Panel");
        if (panelRT == null)
        {
            Debug.LogWarning("[EventPopupUI] 缺少节点 Panel，X 关闭按钮未创建");
            return;
        }

        GameObject btnGO = new GameObject("CloseBtn", typeof(RectTransform));
        btnGO.transform.SetParent(panelRT, false);
        RectTransform rt = (RectTransform)btnGO.transform;
        rt.anchorMin = rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(1f, 1f);
        rt.anchoredPosition = new Vector2(-16f, -16f);
        rt.sizeDelta = new Vector2(46f, 46f);

        Image bg = btnGO.AddComponent<Image>();
        bg.color = new Color(0.16f, 0.11f, 0.04f, 0.85f);

        Text t = CreateText(btnGO, "×", 26, Cream, TextAnchor.MiddleCenter);
        t.fontStyle = FontStyle.Bold;
        FitTextToParent(t);

        Button btn = btnGO.AddComponent<Button>();
        btn.targetGraphic = bg;
        btn.transition = Selectable.Transition.None;
        btn.onClick.AddListener(() =>
        {
            Debug.Log("[EventPopupUI] X 暂时关闭事件窗口（点击所在格地板可重新打开）");
            ClosePopup();
        });
        _closeBtn = btn;
    }

    // ====================================================================
    // 鉴定板显隐（整体开关 CheckBoard 容器，位置由预制体决定）
    // ====================================================================
    private void SetCheckBoardVisible(bool v)
    {
        // ★2026-09-17：改走 BindReferences 的按名深查找引用（原来写死 "Panel/CheckBoard" 路径，
        // 节点一挪就走空）；同时供框体自适应判断「上方内容」是鉴定板还是描述。
        if (checkBoardRT != null && checkBoardRT.gameObject.activeSelf != v)
        {
            checkBoardRT.gameObject.SetActive(v);
        }

        // ★v2.13：公式面板是 CheckBoard 的兄弟节点（Panel 直接子节点）——
        // 必须一起显隐，否则确认鉴定后公式面板残留（用户报 bug）
        if (formulaPanelRT != null && formulaPanelRT.gameObject.activeSelf != v)
        {
            formulaPanelRT.gameObject.SetActive(v);
        }
    }

    // ====================================================================
    // 构建选项按钮（★v2.7 模板克隆模式）
    // 预制体 OptionsRoot 下放一个 inactive 的 OptionButtonTemplate 节点，
    // 用户在 Prefab Mode 里微调模板布局（圆圈大小/字号/间距），代码克隆后填内容。
    // （★滚动改造后：行建在行容器 OptionsContent 里；模板留在 OptionsRoot 原地不搬——
    //   资产子节点搬不进运行时新增节点，编辑器会静默拒绝，详见 EnsureOptionsScrollView。）
    // 模板结构（名称固定）：
    //   OptionButtonTemplate（inactive）
    //   ├─ Circle      —— 圆形底 Image（sprite 由代码生成，用户调大小颜色）
    //   │   ├─ CircleChar  —— 属性单字 Text（内容颜色由代码刷）
    //   │   └─ LockedGlow  —— 锁定态发光 Image（默认 disabled）
    //   └─ ActionText  —— 动作文案 Text（内容颜色由代码刷）
    // 找不到模板时 fallback 到纯代码构建（保底可用）。
    // ====================================================================
    private Transform FindOptionTemplate()
    {
        // ★模板不搬（见 EnsureOptionsScrollView 里的说明），所以两个可能的位置都找：
        //   行容器优先（万一以后预制体把模板放进去了），再退回 OptionsRoot 直接子级。
        Transform t = FindDirectChild(_optionsContent, "OptionButtonTemplate");
        if (t == null) t = FindDirectChild(optionButtonsRoot, "OptionButtonTemplate");
        return (t != null && !t.gameObject.activeSelf) ? t : null;
    }

    private void BuildOptionButtons()
    {
        if (optionButtonsRoot == null) return;
        Transform rowsRoot = _optionsContent != null ? (Transform)_optionsContent : optionButtonsRoot;

        // 清空旧按钮（保留模板节点本身）
        for (int i = rowsRoot.childCount - 1; i >= 0; i--)
        {
            Transform child = rowsRoot.GetChild(i);
            if (child.name == "OptionButtonTemplate") continue;
            // Destroy 要到帧末才真删：先关掉，否则同帧内的量高/滚动刷新会把这些旧行也算进去
            child.gameObject.SetActive(false);
            Destroy(child.gameObject);
        }

        Transform template = FindOptionTemplate();
        foreach (EventOption opt in currentEvent.options)
        {
            EventOption captured = opt;
            CheckType ct = opt.checkType;

            GameObject row;
            Image circleBG; Text circleChar; Text actionText; Image glowImg;
            RectTransform circleRT;

            if (template != null)
            {
                // ★模板克隆：布局/大小/字号全部来自预制体模板，代码只填内容
                GameObject clone = Instantiate(template.gameObject, rowsRoot, false);
                clone.name = $"OptionRow_{ct}";
                clone.SetActive(true);

                row = clone;
                // 布局（anchor/尺寸/位置）完全继承模板——行容器的 VerticalLayoutGroup
                // （由 OptionsRoot 的设置自动搬迁）会自动排列，用户模板怎么设就怎么显示
                circleRT = FindDeepChildRectTransform(row.transform, "Circle");
                circleBG = circleRT != null ? circleRT.GetComponent<Image>() : null;
                circleChar = FindDeepChildComponent<Text>(row.transform, "CircleChar");
                actionText = FindDeepChildComponent<Text>(row.transform, "ActionText");
                glowImg = FindDeepChildComponent<Image>(row.transform, "LockedGlow");

                if (circleBG != null) { circleBG.sprite = MakeCircleSprite(); circleBG.color = Color.clear; }
                if (glowImg != null) { glowImg.sprite = MakeCircleSprite(); glowImg.enabled = false; }
            }
            else
            {
                Debug.LogWarning("[EventPopupUI] 预制体缺 OptionButtonTemplate，选项按钮退回纯代码布局");
                (row, circleBG, circleChar, actionText, glowImg, circleRT) = BuildOptionRowByCode(ct, captured);
            }

            // 内容填充（模板与代码构建共用）
            if (circleChar != null)
            {
                circleChar.text = CheckUIMap.CharFor(ct);
                circleChar.color = ct == CheckType.无 ? Brass : CheckUIMap.ColorFor(ct);
                circleChar.fontStyle = FontStyle.Bold;
            }
            if (actionText != null)
            {
                // ★代价文案（design §1.6：自带数量；批 3 约定 optionText 不写代价，一律这里渲染）
                string costSuffix = EventCostSystem.CostSuffix(captured);
                actionText.text = costSuffix.Length > 0
                    ? captured.optionText + "　" + costSuffix
                    : captured.optionText;
                Color actionColor = ct == CheckType.无 ? Cream : CheckUIMap.ColorFor(ct);
                actionText.color = actionColor;
            }

            // 行底图 + 边框（三态视觉载体 + 点击区；模板自带则复用）
            Image rowBG = row.GetComponent<Image>();
            if (rowBG == null)
            {
                rowBG = row.AddComponent<Image>();
                rowBG.color = new Color(0.08f, 0.05f, 0.01f, 0.35f);
            }
            Outline rowOutline = row.GetComponent<Outline>();
            if (rowOutline == null)
            {
                rowOutline = row.AddComponent<Outline>();
                rowOutline.effectColor = new Color(Gold.r, Gold.g, Gold.b, 0.45f);
                rowOutline.effectDistance = new Vector2(2.5f, 2.5f);
            }

            // Button（模板自带则复用，否则补）
            Button btn = row.GetComponent<Button>();
            if (btn == null)
            {
                btn = row.AddComponent<Button>();
                btn.transition = Selectable.Transition.None;
            }
            btn.targetGraphic = rowBG;

            var ui = new OptionButtonUI
            {
                CT = ct,
                Root = row,
                RowBG = rowBG,
                RowOutline = rowOutline,
                CircleBG = circleBG,
                CircleChar = circleChar,
                ActionText = actionText,
                LockedGlow = glowImg,
                Btn = btn,
                Opt = captured,
            };
            _optionUI.Add(ui); // ★v2.8 全部注册（含非鉴定选项——悬停也要有视觉）

            btn.onClick.AddListener(() => OnOptionButtonClicked(captured, ct));

            // 悬停事件（模板自带 EventTrigger 则复用）
            EventTrigger et = row.GetComponent<EventTrigger>();
            if (et == null) et = row.AddComponent<EventTrigger>();
            et.triggers.Clear();
            AddEvent(et, EventTriggerType.PointerEnter, _ => OnOptionHoverEnter(ct));
            AddEvent(et, EventTriggerType.PointerExit, _ => OnOptionHoverExit(ct));
        }

        RefreshCostGating();
    }

    /// <summary>深度查找指定名称的子节点 RectTransform</summary>
    private RectTransform FindDeepChildRectTransform(Transform root, string name)
    {
        var found = FindDeepChildComponent<RectTransform>(root, name);
        return found;
    }

    private T FindDeepChildComponent<T>(Transform root, string name) where T : Component
    {
        var queue = new Queue<Transform>();
        queue.Enqueue(root);
        while (queue.Count > 0)
        {
            Transform t = queue.Dequeue();
            if (t.name == name)
            {
                T comp = t.GetComponent<T>();
                if (comp != null) return comp;
            }
            foreach (Transform child in t) queue.Enqueue(child);
        }
        return null;
    }

    /// <summary>纯代码构建选项行（预制体无模板时的保底，与 v2.5 布局一致）</summary>
    private (GameObject, Image, Text, Text, Image, RectTransform) BuildOptionRowByCode(CheckType ct, EventOption captured)
    {
        GameObject row = new GameObject($"OptionRow_{ct}", typeof(RectTransform));
        row.transform.SetParent(_optionsContent != null ? (Transform)_optionsContent : optionButtonsRoot, false);
        // ★2026-09-17：行高显式给 56。行容器的 VerticalLayoutGroup 关着 childControlHeight，
        // 行高取「行自己的 rect」而不是 LayoutElement —— 不给就是新建 RectTransform 的默认 100，
        // 两三行就溢出框（模板行走不到这里，这是保底路径）。
        ((RectTransform)row.transform).sizeDelta = new Vector2(0f, 56f);
        LayoutElement rowLE = row.AddComponent<LayoutElement>();
        rowLE.minHeight = 56;
        rowLE.flexibleWidth = 1;

        HorizontalLayoutGroup rowHLG = row.AddComponent<HorizontalLayoutGroup>();
        rowHLG.spacing = 16;
        rowHLG.padding = new RectOffset(16, 10, 8, 8);
        rowHLG.childAlignment = TextAnchor.MiddleLeft;
        rowHLG.childControlWidth = false;
        rowHLG.childControlHeight = false;
        rowHLG.childForceExpandWidth = false;
        rowHLG.childForceExpandHeight = true;

        GameObject circleGO = new GameObject("Circle", typeof(RectTransform));
        circleGO.transform.SetParent(row.transform, false);
        RectTransform circleRT = (RectTransform)circleGO.transform;
        circleRT.sizeDelta = new Vector2(48, 48);
        LayoutElement circleLE = circleGO.AddComponent<LayoutElement>();
        circleLE.minWidth = 48;
        circleLE.minHeight = 48;

        Image circleBG = circleGO.AddComponent<Image>();
        circleBG.sprite = MakeCircleSprite();
        circleBG.color = Color.clear;

        Text circleChar = CreateText(circleGO, CheckUIMap.CharFor(ct), 22,
            ct == CheckType.无 ? Brass : CheckUIMap.ColorFor(ct), TextAnchor.MiddleCenter);
        FitTextToParent(circleChar);

        Text actionText = CreateText(row, captured.optionText, 18,
            ct == CheckType.无 ? Cream : CheckUIMap.ColorFor(ct), TextAnchor.MiddleLeft);
        LayoutElement actLE = actionText.gameObject.AddComponent<LayoutElement>();
        actLE.flexibleWidth = 1;
        actLE.minHeight = 36;

        GameObject glowGO = new GameObject("LockedGlow", typeof(RectTransform));
        glowGO.transform.SetParent(circleGO.transform, false);
        RectTransform glowRT = (RectTransform)glowGO.transform;
        glowRT.anchorMin = Vector2.zero;
        glowRT.anchorMax = Vector2.one;
        glowRT.offsetMin = new Vector2(-5, -5);
        glowRT.offsetMax = new Vector2(5, 5);
        Image glowImg = glowGO.AddComponent<Image>();
        glowImg.sprite = MakeCircleSprite();
        glowImg.color = CheckUIMap.ColorFor(ct) * 0.4f;
        glowImg.enabled = false;

        return (row, circleBG, circleChar, actionText, glowImg, circleRT);
    }

    private static void AddEvent(EventTrigger et, EventTriggerType type, System.Action<BaseEventData> cb)
    {
        var entry = new EventTrigger.Entry { eventID = type };
        entry.callback.AddListener(cb.Invoke);
        et.triggers.Add(entry);
    }

    // ====================================================================
    // 选项按钮交互：悬停/点击（二次确认）
    // ====================================================================
    private void OnOptionHoverEnter(CheckType ct)
    {
        _hoveredCheck = ct;
        RefreshHandFilterVisual();
        RefreshOptionButtonVisuals();
    }

    private void OnOptionHoverExit(CheckType ct)
    {
        if (_hoveredCheck == ct)
        {
            _hoveredCheck = null;
            RefreshHandFilterVisual();
            RefreshOptionButtonVisuals();
        }
    }

    private void OnOptionButtonClicked(EventOption opt, CheckType ct)
    {
        Inventory inv = InventoryManager.Instance != null ? InventoryManager.Instance.Inventory : null;

        // ★代价门禁兜底（按钮已置灰，这里防程序化调用）
        if (!EventCostSystem.CanPay(opt, inv))
        {
            SetHintForUnpayable(opt);
            return;
        }

        if (ct == CheckType.无)
        {
            // ★确认即扣（design §3.2）：无鉴定选项「点即确认」，代价在这里落袋
            if (!EventCostSystem.Pay(opt, inv)) { SetHintForUnpayable(opt); return; }
            ApplyResult(opt.success, true);
            return;
        }

        if (_lockedCheck == ct)
        {
            // 第二次点击同选项 → 确认鉴定（二次确认）
            TryRoll();
        }
        else
        {
            // 第一次点击 → 锁定该选项（手牌过滤收窄到该花色）
            _lockedCheck = ct;
            _handFilterLock = ct;
            currentCheckOption = opt;
            // ★v2.13 用户定稿：面板卡【不退回】——
            //   符合新选项属性的卡保持正常；不符合的变灰半透明（表示不会被使用）。
            //   弃牌加成按新选项花色重算（不符合的卡贡献 0）。
            //   （旧版退回全部卡是 v2.11 的丢卡修复，已被"确认时分流"取代）
            RecomputeDiscardBonus();
            RefreshPanelCardDimState();
            SetCheckBoardVisible(true);
            RefreshDiceAndFormula();
            RefreshHandFilterVisual();
            RefreshOptionButtonVisuals();
        }
    }

    /// <summary>付不起时的提示（design §1.6：写清缺什么、缺多少，不写说明书）。</summary>
    private void SetHintForUnpayable(EventOption opt)
    {
        if (formulaText != null) formulaText.DOColor(Copper, 0.2f).SetLoops(2, LoopType.Yoyo);
        Inventory inv = InventoryManager.Instance != null ? InventoryManager.Instance.Inventory : null;
        EventItemCost missing = EventCostSystem.FirstMissing(opt, inv);
        if (missing == null) return;
        string name = EventCostSystem.NameOf(missing);
        int have = EventCostSystem.Available(missing, inv);
        if (descText != null)
            descText.text = $"<color=#{ColorUtility.ToHtmlStringRGB(Copper)}>{name}不够：{have}/{missing.amount}</color>";
    }

    /// <summary>灰显透明度：锁定选项后不符合属性的面板卡半透明（表示不会被使用）</summary>
    private const float PanelCardDimAlpha = 0.4f;

    /// <summary>★v2.13：按当前鉴定选项重算弃牌加成（只计符合属性的卡，不符合的贡献 0）</summary>
    private void RecomputeDiscardBonus()
    {
        discardBonus = 0;
        if (currentCheckOption == null) return;
        foreach (var kv in _panelCards)
        {
            if (kv.Key?.Data != null)
                discardBonus += CheckSystem.GetDiscardBonus(kv.Key.Data, currentCheckOption.checkType);
        }
    }

    /// <summary>
    /// ★v2.13：面板卡灰显刷新——
    /// 符合当前鉴定选项属性的卡正常（alpha=1）；不符合的半透明（不会被使用）。
    /// 调用时机：锁定选项时 / 新卡飞入面板时。
    /// </summary>
    private void RefreshPanelCardDimState()
    {
        if (currentCheckOption == null) return;
        foreach (var kv in _panelCards)
        {
            if (kv.Value == null || kv.Key?.Data == null) continue;
            bool match = CheckSystem.GetDiscardBonus(kv.Key.Data, currentCheckOption.checkType) > 0;
            kv.Value.SetCardAlpha(match ? 1f : PanelCardDimAlpha);
        }
    }

    /// <summary>
    /// 选项三态视觉（v2.8）：
    ///   普通 = 暗底 + 弱金边；悬停 = 亮底 + 金边 + 文字加粗；
    ///   锁定 = 属性色底 + 属性色边 + 圆圈实心 + 静态发光（提示再点一次确认）。
    /// </summary>
    private void RefreshOptionButtonVisuals()
    {
        foreach (var ui in _optionUI)
        {
            CheckType ct = ui.CT;
            bool isLocked = _lockedCheck == ct;
            bool isHover = _hoveredCheck == ct;
            bool unpayable = ui.Unpayable;              // ★代价门禁（design §3.2）
            Color baseColor = CheckUIMap.ColorFor(ct); // 无 → 奶黄

            // ---- 行底图 + 边框（三态）----
            if (ui.RowBG != null)
            {
                if (isLocked)
                    ui.RowBG.color = new Color(baseColor.r, baseColor.g, baseColor.b, 0.22f);
                else if (unpayable)
                    ui.RowBG.color = new Color(0.05f, 0.04f, 0.02f, 0.25f);
                else if (isHover)
                    ui.RowBG.color = new Color(0.16f, 0.11f, 0.04f, 0.75f);
                else
                    ui.RowBG.color = new Color(0.08f, 0.05f, 0.01f, 0.35f);
            }
            if (ui.RowOutline != null)
            {
                if (isLocked)
                    ui.RowOutline.effectColor = new Color(baseColor.r, baseColor.g, baseColor.b, 0.95f);
                else if (unpayable)
                    ui.RowOutline.effectColor = new Color(Gold.r, Gold.g, Gold.b, 0.15f);
                else if (isHover)
                    ui.RowOutline.effectColor = new Color(GoldLight.r, GoldLight.g, GoldLight.b, 0.85f);
                else
                    ui.RowOutline.effectColor = new Color(Gold.r, Gold.g, Gold.b, 0.45f);
            }

            // ---- 圆圈 ----
            if (ui.CircleBG != null)
            {
                ui.CircleBG.color = isLocked ? baseColor : Color.clear;
            }
            if (ui.CircleChar != null)
            {
                ui.CircleChar.color = isLocked ? Cream : baseColor;
            }
            if (ui.LockedGlow != null)
            {
                // 锁定态静态发光（不脉冲闪烁）
                ui.LockedGlow.enabled = isLocked;
                ui.LockedGlow.DOKill();
                if (isLocked)
                {
                    ui.LockedGlow.color = baseColor * 0.55f;
                }
            }

            // ---- 动作文案 ----
            if (ui.ActionText != null)
            {
                ui.ActionText.fontStyle = (isLocked || isHover) ? FontStyle.Bold : FontStyle.Normal;
                ui.ActionText.color = (isLocked || isHover)
                    ? baseColor
                    : new Color(baseColor.r * 0.6f, baseColor.g * 0.6f, baseColor.b * 0.6f);
                if (unpayable)
                {
                    Color c = ui.ActionText.color;
                    ui.ActionText.color = new Color(c.r, c.g, c.b, 0.35f);
                }
            }
        }

        // ★门禁要在本轮视觉之后刷新：下一轮的底色/文字才用得上新的 Unpayable
        RefreshCostGating();
    }

    /// <summary>
    /// ★代价门禁（design §3.2/§1.6）：付不起的选项置灰不可点。
    /// 调用时机 = 构建选项后 / 背包变化 / 三态视觉刷新末尾。
    /// </summary>
    private void RefreshCostGating()
    {
        Inventory inv = InventoryManager.Instance != null ? InventoryManager.Instance.Inventory : null;
        for (int i = 0; i < _optionUI.Count; i++)
        {
            OptionButtonUI ui = _optionUI[i];
            if (ui == null || ui.Opt == null) continue;

            bool ok = EventCostSystem.CanPay(ui.Opt, inv);
            ui.Unpayable = !ok;
            if (ui.Btn != null) ui.Btn.interactable = ok;
        }
    }

    private void OnInventoryChangedWhileOpen()
    {
        if (currentEvent != null)
        {
            RefreshCostGating();
            RefreshOptionButtonVisuals();
        }
    }

    // ====================================================================
    // 手牌鉴定辅助模式
    // ====================================================================
    private void EnterCheckAssistMode(List<SuitOption> suits)
    {
        // ★v2.10：SendMessage 传 object[] 解包不可靠（Console 报 Failed to call function），
        // 方法已改 public，直接强类型调用。
        if (HandUIController.Instance != null) HandUIController.Instance.EnterCheckAssistMode(suits);
    }

    /// <summary>
    /// 手牌弹出花色过滤（v2.8 花色集合制）：
    ///   ★v2.11 用户定稿：已点击锁定选项（_handFilterLock）→ 锁定花色最高优先，
    ///     悬停其他选项不再改变弹出卡；只有再点别的选项（换锁）或点击空白
    ///     （解除锁定）才会变化。
    ///   未锁定时：悬停鉴定选项 → 只弹该花色；
    ///             悬停非鉴定选项（绕道离开等）→ 全部缩下；
    ///             未悬停 → 本事件全部相关花色（刚打开/悬停离开）。
    /// </summary>
    private void RefreshHandFilterVisual()
    {
        List<SuitOption> suits;
        if (_handFilterLock.HasValue)
        {
            suits = new List<SuitOption> { CheckUIMap.SuitFor(_handFilterLock.Value) };
        }
        else if (_hoveredCheck.HasValue)
        {
            if (_hoveredCheck.Value == CheckType.无)
                suits = new List<SuitOption>(); // 悬停非鉴定选项 → 所有卡缩下
            else
                suits = new List<SuitOption> { CheckUIMap.SuitFor(_hoveredCheck.Value) };
        }
        else
        {
            suits = _eventSuits; // 刚打开 / 悬停离开 → 本事件相关花色全伸出
        }
        if (HandUIController.Instance != null) HandUIController.Instance.SetCheckAssistSuits(suits);
    }

    // ====================================================================
    // ★D19 v2.11：点击空白处 → 解除选项锁定，回到初始状态（无锁定）
    // 触发途径：a) 点击面板底图（Panel，未被按钮/面板卡吃掉的点击向上冒泡）
    //           b) 点击弹窗外空白（Update 轮询：无任何 UI 命中）
    // ====================================================================
    private void ResetCheckLockState()
    {
        // 无鉴定板 / 结果阶段（选项已清空）不处理
        if (currentCheckOption == null || _optionUI.Count == 0) return;
        // 已是初始态（无锁定且面板无卡）不处理
        if (_lockedCheck == null && _handFilterLock == null && _panelCards.Count == 0) return;

        _lockedCheck = null;
        _handFilterLock = null;
        _hoveredCheck = null;

        // 已飞入面板的卡退回手牌（含能量退还）
        ReturnAllPanelCardsImmediate();

        // 检查板回到初始默认：展示第一个鉴定选项（仅展示，不锁定）
        currentCheckOption = GetFirstCheckOption();
        RefreshDiceAndFormula();
        RefreshHandFilterVisual();
        RefreshOptionButtonVisuals();
        Debug.Log("[EventPopupUI] 点击空白处 → 解除选项锁定，回到初始状态");
    }

    /// <summary>本事件第一个鉴定选项（初始默认展示用）</summary>
    private EventOption GetFirstCheckOption()
    {
        if (currentEvent == null) return null;
        foreach (EventOption opt in currentEvent.options)
            if (opt.checkType != CheckType.无) return opt;
        return null;
    }

    private void Update()
    {
        // 点击弹窗外空白（未命中任何 UI——手牌/选项/面板卡都是 UI，不会误触）
        // → 解除选项锁定回到初始状态
        if (currentCheckOption == null || _optionUI.Count == 0) return;
        if (Input.GetMouseButtonDown(0)
            && EventSystem.current != null
            && !EventSystem.current.IsPointerOverGameObject())
        {
            ResetCheckLockState();
        }
    }

    // ====================================================================
    // 鉴定板：骰子 + 公式
    // ====================================================================
    private void RefreshDiceAndFormula()
    {
        if (currentCheckOption == null) return;

        int attrBonus = CheckSystem.GetBaseScore(currentCheckOption.checkType);
        int tactical = CheckSystem.GetTacticalBonus(currentCheckOption.checkType);
        int totalBonus = attrBonus + tactical + discardBonus;
        int target = Mathf.Max(1, currentCheckOption.difficulty - totalBonus);

        ShowDiceFace(target);

        // ★v2.12 用户定稿公式格式："6-2(敏捷)-1(直刺) = 3"
        //   难度数字开头，减项紧跟减号；来源名放小一号括号里（汉字稍小）；
        //   结果数值放大铜色加粗。骰子面显示的就是结果目标值。
        string attrLabel = currentCheckOption.checkType.ToString();
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        sb.Append(currentCheckOption.difficulty);
        if (attrBonus > 0) sb.Append($"-{attrBonus}<size=13>({attrLabel})</size>");
        if (tactical > 0) sb.Append($"-{tactical}<size=13>(战术)</size>");
        if (discardBonus > 0)
        {
            foreach (var kv in _panelCards)
            {
                int pts = CheckSystem.GetDiscardBonus(kv.Key.Data, currentCheckOption.checkType);
                if (pts > 0) sb.Append($"-{pts}<size=13>({kv.Key.Data.cardName})</size>");
            }
        }
        sb.Append($" = <size=32><color=#{ColorUtility.ToHtmlStringRGB(Copper)}><b>{target}</b></color></size>");
        if (formulaText != null) formulaText.text = sb.ToString();
    }

    private void ShowDiceFace(int face1to6)
    {
        int idx = Mathf.Clamp(face1to6, 1, 6) - 1;

        // 动态生成骰子面 Sprite（如果为空）
        if (diceFaceSprites == null || diceFaceSprites.Length < 6 || diceFaceSprites[0] == null)
        {
            diceFaceSprites = GenerateDiceFaceSprites();
        }

        if (diceImage != null)
        {
            if (diceFaceSprites != null && diceFaceSprites.Length > idx && diceFaceSprites[idx] != null)
            {
                diceImage.sprite = diceFaceSprites[idx];
                diceImage.enabled = true;
                if (diceFaceText != null) diceFaceText.enabled = false;
                return;
            }
            diceImage.enabled = false;
        }
        if (diceFaceText != null)
        {
            diceFaceText.text = face1to6.ToString();
            diceFaceText.enabled = true;
        }
    }

    // ====================================================================
    // 投骰判定
    // ====================================================================
    private void TryRoll()
    {
        // ★确认即扣（design §3.2）：代价在「确认鉴定」这一刻扣，失败不退。
        // 放在消耗探索骰之前——付不起时不该白烧一颗骰子、也不该吞掉面板卡。
        Inventory invNow = InventoryManager.Instance != null ? InventoryManager.Instance.Inventory : null;
        if (!EventCostSystem.Pay(currentCheckOption, invNow))
        {
            SetHintForUnpayable(currentCheckOption);
            return;
        }

        if (ExplorationTurnManager.Instance == null || !ExplorationTurnManager.Instance.TryConsumeExplorationDice())
        {
            if (formulaText != null) formulaText.DOColor(Copper, 0.2f).SetLoops(2, LoopType.Yoyo);
            return;
        }

        // ★v2.14 修 bug：最终结算不包含弃牌减值——
        // CommitPanelCardsToDiscardPile 末尾会把 discardBonus 清零，
        // 旧代码先 commit 再读 discardBonus，判定永远只含 基础分+战术（减值为 0）。
        // 必须先快照弃牌减值，再提交弃牌，最后用快照判定。
        int discardBonusAtRoll = discardBonus;

        // ★v2.9 D19：确认鉴定 → DISCARD 面板里的卡真实弃牌（数据层已在飞入时
        // 从 Hand 移除，这里直接入弃牌堆 + 销毁面板视图；能量不退——飞入时已扣）
        CommitPanelCardsToDiscardPile();

        bool success = CheckSystem.Resolve(
            currentCheckOption.difficulty, currentCheckOption.checkType, discardBonusAtRoll,
            out int rolled, out int target);

        ShowDiceFace(rolled);

        EventResult result = success ? currentCheckOption.success : currentCheckOption.failure;
        ApplyResult(result, success, $"掷出 {rolled}（需 ≥ {target}）");
    }

    /// <summary>
    /// ★v2.13 用户定稿：确认鉴定时面板卡分流——
    ///   符合当前鉴定属性的卡 → 真实弃牌（算做使用，能量不退——飞入时已扣）；
    ///   不符合的卡 → 回手牌 + 返还对应能量（不算使用）。
    /// 飞入面板时已从 Hand 移除，弃牌这里先加回 Hand 再走 DiscardHandCard
    /// 公开方法（保证 OnCardDiscarded/OnPileRefreshed 事件正常触发）。
    /// </summary>
    private void CommitPanelCardsToDiscardPile()
    {
        if (CardPileManager.Instance == null) { ClearPanelCards(); return; }

        foreach (var kv in _panelCards)
        {
            Card c = kv.Key;
            if (c == null) continue;

            // 分流判定：该卡对当前鉴定属性是否有弃牌加成（对应花色点数 > 0）
            bool match = currentCheckOption != null && c.Data != null
                         && CheckSystem.GetDiscardBonus(c.Data, currentCheckOption.checkType) > 0;

            if (!match)
            {
                // 不符合 → 回手牌 + 返还能量（手牌打出放到弃牌槽时已消耗，此时退还）
                EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
                if (epd != null) epd.AddEnergy(c.CurrentCost); // ★2026-09-14：上限收到 energyMax
                CharacterStats.PendingCards.Remove(c); // 回手牌 → 退出暂存（Hand 重新计入）

                // ★2026-09-10：槽内卡不符合属性 → 装回原槽（它本来就不在手牌里，不能往 Hand 塞）
                if (_slotCardOrigins.TryGetValue(c, out int slotBack))
                {
                    _slotCardOrigins.Remove(c);
                    ReEquipSlotCard(c, slotBack);
                }
                else if (kv.Value != null)
                {
                    AttachBackToHand(kv.Value, true);
                }
                continue;
            }

            CharacterStats.PendingCards.Remove(c);         // ★v2.12：退出暂存（弃牌堆将计入）

            if (_slotCardOrigins.ContainsKey(c))
            {
                // ★2026-09-10：槽内卡弃牌 —— 卡本来就不在手牌里，**不能**往 Hand 塞
                //   （塞了就凭空多出一张手牌，正是用户报的「同时存在两张」）。
                //   走 DiscardFromTacticSlot 这条直投出口：同样进弃牌堆、同样广播事件。
                _slotCardOrigins.Remove(c);
                CardPileManager.Instance.DiscardFromTacticSlot(c);
            }
            else
            {
                CardPileManager.Instance.Hand.Add(c);      // 临时加回（DiscardHandCard 要求在手中）
                CardPileManager.Instance.DiscardHandCard(c);   // Hand→DiscardPile + 事件
            }
            if (kv.Value != null) Destroy(kv.Value.gameObject);
        }
        _panelCards.Clear();
        _slotCardOrigins.Clear();
        discardBonus = 0;
    }

    // ====================================================================
    // 结果结算
    // ====================================================================

    /// <summary>★v2.14：结果阶段选项区顶边上移量（确认按钮+变动提示往上挪，Inspector 可调）</summary>
    [Tooltip("结果阶段选项区顶边上移像素（列表态→结果态；视口会一并加高，不会裁到确认按钮）")]
    [SerializeField] private float _resultPhaseLiftY = 60f;

    /// <summary>OptionsRoot 预制体原始位置（首次访问时缓存）</summary>
    private Vector2? _optionsRootBasePos = null;
    /// <summary>OptionsRoot 预制体原始顶边（距框底；列表态顶边，结果态在此基础上 +lift）</summary>
    private float? _optionsRootTopY = null;

    /// <summary>
    /// ★选项区两种相位（都在 OpenEvent 复位）：
    ///   列表态 —— 顶边回到预制体原位、视口下探到留白线（OptionsBottomPad）；
    ///   结果态 —— 选项行已全部销毁，只剩摘要+确认按钮，顶边上移 _resultPhaseLiftY、
    ///             视口一并加高到顶边，保证 2 行结果内容整块可见（不触发滚动）。
    /// 底边恒在 OptionsBottomPad：行从顶边往下排 → 列表态前几行位置与改造前完全一致。
    /// </summary>
    private void ShiftOptionsRootForResult(bool resultPhase)
    {
        RectTransform rt = optionButtonsRoot as RectTransform;
        if (rt == null) return;
        if (!_optionsRootBasePos.HasValue) _optionsRootBasePos = rt.anchoredPosition;
        if (!_optionsRootTopY.HasValue)
            _optionsRootTopY = _optionsRootBasePos.Value.y + rt.sizeDelta.y * 0.5f;

        float top = _optionsRootTopY.Value + (resultPhase ? _resultPhaseLiftY : 0f);
        float h = Mathf.Max(60f, top - OptionsBottomPad);
        rt.sizeDelta = new Vector2(rt.sizeDelta.x, h);
        rt.anchoredPosition = new Vector2(_optionsRootBasePos.Value.x, OptionsBottomPad + h * 0.5f);
    }

    /// <summary>描述框原始尺寸/位置（首次访问时缓存；列表态复位用）</summary>
    private Vector2? _descBaseSize = null;
    private Vector2? _descBasePos = null;

    /// <summary>
    /// ★结果态描述防溢出（2026-09-17）：结果文案（成败抬头+掷骰+flavor）比列表描述长，
    ///   固定 110 高的框装不下就会越出框底。这里按实测文本高度把框【向下长、顶边不动】：
    ///   结果态鉴定区已隐藏、框下到弃牌面板之间是空区，长高不会盖到任何东西。
    ///   现库最长结果文案实测 90px &lt; 110 —— 平时完全不触发，纯兜底。
    ///   只在结果态用 preferredHeight：列表态文案带 &lt;size&gt; 标签，Text 的量高对标签不准
    ///   （实测 46 字带标签文案量出 35px、真实渲染 63px），列表态不参与自适应。
    /// </summary>
    private void FitDescBoxForResult()
    {
        RectTransform rt = descText != null ? descText.rectTransform : null;
        if (rt == null) return;
        if (!_descBaseSize.HasValue) { _descBaseSize = rt.sizeDelta; _descBasePos = rt.anchoredPosition; }

        float h = Mathf.Max(_descBaseSize.Value.y, descText.preferredHeight + 4f);
        rt.sizeDelta = new Vector2(_descBaseSize.Value.x, h);
        // 顶边固定：pivot 居中 → 高度长了 Δ，中心往下挪 Δ/2
        rt.anchoredPosition = new Vector2(_descBasePos.Value.x,
                                          _descBasePos.Value.y - (h - _descBaseSize.Value.y) * 0.5f);
    }

    /// <summary>列表态复位描述框（OpenEvent 调用）：回到预制体尺寸/位置。</summary>
    private void ResetDescBox()
    {
        RectTransform rt = descText != null ? descText.rectTransform : null;
        if (rt == null) return;
        if (!_descBaseSize.HasValue) { _descBaseSize = rt.sizeDelta; _descBasePos = rt.anchoredPosition; }
        rt.sizeDelta = _descBaseSize.Value;
        rt.anchoredPosition = _descBasePos.Value;
    }

    // ====================================================================
    // ★选项区滚动（用户 2026-09-17 改口径：「框固定长度，超出了就滚动」）
    // 框高固定＝沿用预制体（不再随内容长高）；选项区被改造成单节点 ScrollRect：
    //   OptionsRoot（ScrollRect + RectMask2D + 透明挡板：滚轮/拖拽，点击照旧冒泡到 Panel）
    //   ├─ OptionsContent（VerticalLayoutGroup + ContentSizeFitter：行容器）
    //   └─ OptionsScrollbar（细滚动条：只在装不下时显示，手柄可拖）
    // 3 行以内位置与改造前完全一致，第 4 行起被裁剪、可滚轮/拖拽查看。
    // ====================================================================

    /// <summary>选项堆叠区底边 ↔ 框底 的固定留白（沿用预制体 3 行时的块底边距）</summary>
    private const float OptionsBottomPad = 12f;

    private ScrollRect _optionsScroll;        // OptionsRoot 上（运行时补挂）
    private RectTransform _optionsContent;    // 行容器（运行时补挂）
    private GameObject _optionsScrollbar;     // 只在内容溢出时显示

    /// <summary>
    /// 把 OptionsRoot 改造成「固定视口 + 滚动内容」。幂等：重复调用直接返回。
    /// 预制体里若已有同名节点（OptionsContent / OptionsScrollbar）则直接采用，样式随便改。
    /// </summary>
    private void EnsureOptionsScrollView()
    {
        RectTransform optRT = optionButtonsRoot as RectTransform;
        if (optRT == null || _optionsContent != null) return;

        // ① 单节点 ScrollRect（viewport 留空＝用自身矩形），RectMask2D 负责裁剪
        _optionsScroll = optRT.GetComponent<ScrollRect>();
        if (_optionsScroll == null) _optionsScroll = optRT.gameObject.AddComponent<ScrollRect>();
        _optionsScroll.horizontal = false;
        _optionsScroll.vertical = true;
        _optionsScroll.movementType = ScrollRect.MovementType.Clamped;
        _optionsScroll.scrollSensitivity = 30f;
        if (optRT.GetComponent<RectMask2D>() == null && optRT.GetComponent<Mask>() == null)
            optRT.gameObject.AddComponent<RectMask2D>();
        if (optRT.GetComponent<Image>() == null)
        {
            // 透明挡板：空区也能接滚轮/拖拽；自身不处理点击 → 照旧冒泡到 Panel（点空白解除锁定）
            Image hit = optRT.gameObject.AddComponent<Image>();
            hit.color = Color.clear;
            hit.raycastTarget = true;
        }

        // ② 行容器：把 OptionsRoot 上的 VerticalLayoutGroup 设置整体搬过来执行
        Transform contentT = FindDirectChild(optRT, "OptionsContent");
        if (contentT == null)
        {
            GameObject contentGO = new GameObject("OptionsContent", typeof(RectTransform));
            contentT = contentGO.transform;
            contentT.SetParent(optRT, false);
        }
        _optionsContent = (RectTransform)contentT;
        _optionsContent.anchorMin = new Vector2(0f, 1f);
        _optionsContent.anchorMax = new Vector2(1f, 1f);
        _optionsContent.pivot = new Vector2(0.5f, 1f);
        _optionsContent.anchoredPosition = Vector2.zero;

        VerticalLayoutGroup source = optRT.GetComponent<VerticalLayoutGroup>();
        VerticalLayoutGroup vlg = _optionsContent.GetComponent<VerticalLayoutGroup>();
        if (vlg == null) vlg = _optionsContent.gameObject.AddComponent<VerticalLayoutGroup>();
        if (source != null)
        {
            vlg.padding = new RectOffset(source.padding.left, source.padding.right,
                                         source.padding.top, source.padding.bottom);
            vlg.spacing = source.spacing;
            vlg.childAlignment = source.childAlignment;
            vlg.childControlWidth = source.childControlWidth;
            vlg.childControlHeight = source.childControlHeight;
            vlg.childForceExpandWidth = source.childForceExpandWidth;
            vlg.childForceExpandHeight = source.childForceExpandHeight;
            vlg.childScaleWidth = source.childScaleWidth;
            vlg.childScaleHeight = source.childScaleHeight;
            vlg.reverseArrangement = source.reverseArrangement;
            source.enabled = false;   // 设置已被搬走，避免两个布局组抢着排
        }
        ContentSizeFitter fitter = _optionsContent.GetComponent<ContentSizeFitter>();
        if (fitter == null) fitter = _optionsContent.gameObject.AddComponent<ContentSizeFitter>();
        fitter.horizontalFit = ContentSizeFitter.FitMode.Unconstrained;
        fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;

        // ★模板行留在 OptionsRoot 原处、不搬进行容器：预制体资产子节点无法被移进运行时
        //   新增的 OptionsContent —— 编辑器会静默拒绝 SetParent / Undo.SetTransformParent
        //   （Unity 2022.3 实测，不报错也不生效）。行照样克隆进 _optionsContent（克隆时显式
        //   传父节点），FindOptionTemplate 两处都会找，模板在哪不影响克隆结果。
        _optionsScroll.content = _optionsContent;
        BuildOptionsScrollbar(optRT);
    }

    /// <summary>细滚动条：贴视口右缘、只画手柄（轨道不画不挡点击），溢出时才 SetActive。</summary>
    private void BuildOptionsScrollbar(RectTransform optRT)
    {
        Transform barT = FindDirectChild(optRT, "OptionsScrollbar");
        GameObject barGO = barT != null ? barT.gameObject : null;
        if (barGO == null)
        {
            barGO = new GameObject("OptionsScrollbar", typeof(RectTransform));
            barGO.transform.SetParent(optRT, false);
        }
        RectTransform barRT = (RectTransform)barGO.transform;
        barRT.anchorMin = new Vector2(1f, 0f);
        barRT.anchorMax = new Vector2(1f, 1f);
        barRT.pivot = new Vector2(1f, 0.5f);
        barRT.sizeDelta = new Vector2(10f, -16f);          // 上下各让 8
        barRT.anchoredPosition = new Vector2(-4f, 0f);

        Transform handleT = FindDirectChild(barRT, "Handle");
        if (handleT == null)
        {
            GameObject handleGO = new GameObject("Handle", typeof(RectTransform), typeof(Image));
            handleT = handleGO.transform;
            handleT.SetParent(barRT, false);
        }
        RectTransform handleRT = (RectTransform)handleT;
        handleRT.anchorMin = Vector2.zero;
        handleRT.anchorMax = Vector2.one;
        handleRT.pivot = new Vector2(0.5f, 0.5f);
        handleRT.sizeDelta = Vector2.zero;
        handleRT.anchoredPosition = Vector2.zero;
        Image handleImg = handleT.GetComponent<Image>();
        if (handleImg == null) handleImg = handleT.gameObject.AddComponent<Image>();
        handleImg.color = new Color(Cream.r, Cream.g, Cream.b, 0.55f);
        handleImg.raycastTarget = true;

        Scrollbar bar = barGO.GetComponent<Scrollbar>();
        if (bar == null) bar = barGO.AddComponent<Scrollbar>();
        bar.handleRect = handleRT;
        bar.targetGraphic = handleImg;
        bar.direction = Scrollbar.Direction.BottomToTop;

        _optionsScroll.verticalScrollbar = bar;
        _optionsScroll.verticalScrollbarVisibility = ScrollRect.ScrollbarVisibility.AutoHide;
        _optionsScrollbar = barGO;
    }

    /// <summary>
    /// 量内容、切滚动条显隐、把列表拉回顶部。在选项区内容变化的两处调用
    /// （打开事件 / 出结果）——这两处是本弹窗内容的唯一变化点。
    /// </summary>
    private void RefreshOptionsScroll()
    {
        if (_optionsScroll == null || _optionsContent == null) return;
        LayoutRebuilder.ForceRebuildLayoutImmediate(_optionsContent);

        RectTransform viewRT = _optionsScroll.transform as RectTransform;
        float contentH = _optionsContent.rect.height;
        float viewH = viewRT != null ? viewRT.rect.height : 0f;
        bool overflow = viewH > 1f && contentH > viewH + 0.5f;
        if (_optionsScrollbar != null) _optionsScrollbar.SetActive(overflow);
        _optionsContent.anchoredPosition = new Vector2(_optionsContent.anchoredPosition.x, 0f);
    }

    /// <summary>在指定父节点的【直接子级】里按名找节点（不深搜，避免误抓同名后代）。</summary>
    private static Transform FindDirectChild(Transform parent, string name)
    {
        if (parent == null) return null;
        foreach (Transform child in parent)
            if (child.name == name) return child;
        return null;
    }

    private void ApplyResult(EventResult result, bool success, string rollPrefix = "")
    {
        // ★endEvent（结果粒度，用户 2026-09-05 定稿）：该结果勾选了「结束事件」→
        //   事件解决：记录消耗 + 隐藏地图标记（宝箱消失），本局不再触发。
        //   成功/失败/无鉴定选项各自可配置（如：撬开成功=结束，撬失败=保留，绕开=保留）。
        if (result != null && result.endEvent && currentEvent != null)
        {
            EventTile.NotifyEventResolved(currentEvent);
        }

        // 清空选项按钮（★2026-09-17 修复：保留 OptionButtonTemplate——
        // 原来连模板一起 Destroy，导致第二场事件起找不到模板、退回纯代码行
        // （默认 100 高、两三行就溢出框），正是「选项超出事件框」的元凶之一）
        Transform rowsRoot = _optionsContent != null ? (Transform)_optionsContent : optionButtonsRoot;
        if (rowsRoot != null)
            for (int i = rowsRoot.childCount - 1; i >= 0; i--)
            {
                Transform child = rowsRoot.GetChild(i);
                if (child.name == "OptionButtonTemplate") continue;
                // 先关掉：Destroy 帧末才生效，否则误导同帧的滚动刷新
                child.gameObject.SetActive(false);
                Destroy(child.gameObject);
            }
        _optionUI.Clear();
        ShiftOptionsRootForResult(true); // ★v2.14：结果阶段 UI（摘要+确认按钮）整体上移

        // 更新描述为结果文本
        if (descText != null)
        {
            string statusText = success ? "—— 成功 ——" : "—— 失败 ——";
            string statusColor = success ? $"#{ColorUtility.ToHtmlStringRGB(Gold)}" : $"#{ColorUtility.ToHtmlStringRGB(Copper)}";
            descText.text = $"<color={statusColor}><b>{statusText}</b></color>\n\n"
                          + (string.IsNullOrEmpty(rollPrefix) ? "" : rollPrefix + "\n\n")
                          + (result != null ? result.flavorText : "……");
        }
        FitDescBoxForResult(); // ★结果文案比列表描述长：装不下就让框向下长（顶边不动）

        // 数值结算
        List<string> changes = new List<string>();
        if (result != null && result.hpChange != 0)
        {
            PlayerHealth hp = FindObjectOfType<PlayerHealth>();
            if (hp != null) { if (result.hpChange > 0) hp.Heal(result.hpChange); else hp.TakeDamage(-result.hpChange); }
            changes.Add($"HP {result.hpChange:+0;-0}");
        }
        if (result != null && result.energyChange != 0)
        {
            EnergyPointDisplay ep = FindObjectOfType<EnergyPointDisplay>();
            // ★2026-09-14：改由 SetEnergy 统一收敛到能量上限 energyMax（可正可负）
            if (ep != null) ep.SetEnergy(ep.CurrentEnergy + result.energyChange);
            changes.Add($"能量 {result.energyChange:+0;-0}");
        }
        if (result != null && result.diceChange != 0)
        {
            for (int i = 0; i < -result.diceChange; i++) ExplorationTurnManager.Instance?.TryConsumeExplorationDice();
            changes.Add($"骰子 {result.diceChange:+0;-0}");
        }
        // ★物资（design §3.6）：直入局外账，不进背包、不随阵亡丢失
        if (result != null && result.salvageChange != 0)
        {
            MetaWallet.AddSalvage(result.salvageChange);
            changes.Add($"物资 {result.salvageChange:+0;-0}");
        }
        if (result != null && result.addCards != null && result.addCards.Count > 0)
        {
            // ★修复「事件卡牌奖励空心」：原本只 Debug.Log，未真正入牌组。
            // 改用 CardDeckManager.AddCardAtRuntime——与战斗掉落（LootPopupUI）同一条路径，
            // 直接进当局 runtimeDeck，跨探索/战斗保留（GetPlayableDeck 每回合从 runtimeDeck 重建牌堆）。
            CardDeckManager deckMgr = CardDeckManager.Instance;
            int added = 0;
            foreach (CardData cd in result.addCards)
            {
                if (cd == null) continue;
                deckMgr?.AddCardAtRuntime(cd);
                added++;
            }
            if (added > 0) changes.Add($"获得卡牌 ×{added}");
        }
        string itemSummary = GrantItems(result);
        if (itemSummary != null) changes.Add(itemSummary);

        // ★临时强化（design §3.5）：入增益槽，下一场战斗开始应用、战后即耗
        if (result != null && result.grantBuff != null)
        {
            string why;
            if (TempBuffRuntime.Grant(result.grantBuff, out why)) changes.Add($"强化「{result.grantBuff.buffName}」");
            else changes.Add($"强化未生效：{why}");
        }

        // 结果阶段隐藏鉴定板
        SetCheckBoardVisible(false);

        // ★挂起选牌 / 进战（design §3.3/§3.4）：结果文案先出，选牌与进战等弹窗关闭链路
        _pendingRemoveCards = result != null ? Mathf.Max(0, result.removeCards) : 0;
        _pendingDuplicateCards = result != null ? Mathf.Max(0, result.duplicateCards) : 0;
        _pendingCombatCount = (result != null && result.triggerCombat)
            ? Mathf.Clamp(result.combatEnemyCount, 1, 2) : 0;

        // 显示结果摘要和确认按钮
        if (rowsRoot != null)
        {
            if (changes.Count > 0)
            {
                GameObject sumGO = new GameObject("Summary", typeof(RectTransform));
                sumGO.transform.SetParent(rowsRoot, false);
                LayoutElement sumLE = sumGO.AddComponent<LayoutElement>();
                sumLE.minHeight = 28;
                CreateText(sumGO, string.Join("  ", changes), 16, Cream, TextAnchor.MiddleCenter);
            }

            // 确认按钮
            GameObject confirmGO = new GameObject("ConfirmBtn", typeof(RectTransform), typeof(Image));
            confirmGO.transform.SetParent(rowsRoot, false);
            LayoutElement confirmLE = confirmGO.AddComponent<LayoutElement>();
            confirmLE.minHeight = 52;
            confirmLE.flexibleWidth = 1;

            Image confirmBg = confirmGO.GetComponent<Image>();
            confirmBg.color = Brass;

            Button confirmBtn = confirmGO.AddComponent<Button>();
            confirmBtn.targetGraphic = confirmBg;

            bool needsPicker = _pendingRemoveCards > 0 || _pendingDuplicateCards > 0;
            Text confirmText = CreateText(confirmGO, needsPicker ? "选 牌" : "确 认", 22, DarkBg, TextAnchor.MiddleCenter);
            confirmText.fontStyle = FontStyle.Bold;
            FitTextToParent(confirmText);
            if (needsPicker) confirmBtn.onClick.AddListener(OnConfirmWithPicker);
            else confirmBtn.onClick.AddListener(ClosePopup);
        }

        // ★结果 UI（摘要+确认按钮）已落位：量内容、切滚动条显隐、回顶
        RefreshOptionsScroll();
    }

    // ====================================================================
    // ★删牌 / 复制（design §3.4）：结果结算时先弹选牌界面，选完再关事件弹窗
    // ====================================================================

    private void OnConfirmWithPicker()
    {
        RunNextCardOp();
    }

    /// <summary>先做删牌、再做复制（一个结果的两种操作不同时出现；都做完 → 关弹窗）。</summary>
    private void RunNextCardOp()
    {
        CardPackUI pack = FindObjectOfType<CardPackUI>();

        if (_pendingRemoveCards > 0)
        {
            int n = _pendingRemoveCards;
            _pendingRemoveCards = 0;
            if (pack == null) { Debug.LogWarning("[事件] 场上没有 CardPackUI，删牌跳过"); RunNextCardOp(); return; }
            pack.OpenPickMode(n, "选牌删除", OnRemoveCardsPicked);
            return;
        }

        if (_pendingDuplicateCards > 0)
        {
            int n = _pendingDuplicateCards;
            _pendingDuplicateCards = 0;
            if (pack == null) { Debug.LogWarning("[事件] 场上没有 CardPackUI，复制跳过"); RunNextCardOp(); return; }
            pack.OpenPickMode(n, "选牌复制", OnDuplicateCardsPicked);
            return;
        }

        ClosePopup();
    }

    private void OnRemoveCardsPicked(List<Card> picked)
    {
        if (CardDeckManager.Instance != null)
        {
            foreach (Card c in picked)
            {
                if (c == null) continue;
                string name = c.Data != null ? c.Data.cardName : "?";
                if (CardDeckManager.Instance.RemoveCardAtRuntime(c))
                    Debug.Log($"[事件] 删牌：{name}");
            }
        }
        RunNextCardOp();
    }

    private void OnDuplicateCardsPicked(List<Card> picked)
    {
        if (CardDeckManager.Instance != null)
        {
            foreach (Card c in picked)
            {
                if (c == null || c.Data == null) continue;
                CardDeckManager.Instance.AddCardAtRuntime(c.Data);
                Debug.Log($"[事件] 复制：{c.Data.cardName}");
            }
        }
        RunNextCardOp();
    }

    // ------------------------------------------------------------------
    // 事件物品奖励（spec §10：鉴定成功入对应分区）
    // ------------------------------------------------------------------

    /// <summary>
    /// 发放 EventResult.addItems 物品奖励（成功鉴定 / 无鉴定直接命中时调用）。
    /// 灵魂自动进魂灯；灯满 → 该条灵魂消散（事件弹窗一次性，不挂销毁选择——
    /// 销毁子页只属于战后结算，那里有账本条目可挂起等玩家决定）。
    /// 返回结果摘要串（「获得物品 ×N」/「未收下 ×M」）；无奖励或背包未就绪 → null。
    /// </summary>
    private string GrantItems(EventResult result)
    {
        if (result == null || result.addItems == null || result.addItems.Count == 0) return null;

        InventoryManager inv = InventoryManager.Instance;
        if (inv == null) return null;

        int got = 0, lost = 0;
        foreach (EventItemReward reward in result.addItems)
        {
            if (reward.item == null || reward.amount <= 0) continue;

            inv.AddItem(reward.item, reward.amount, out int added);
            if (added > 0)
            {
                got += added;
                Debug.Log($"[探索] 事件奖励：{reward.item.itemName} ×{added} → 背包");
            }
            if (added < reward.amount)
            {
                lost += reward.amount - added;
                Debug.Log($"[探索] 事件奖励 {reward.item.itemName} 只收下 {added}/{reward.amount}" +
                          "（背包空间不足 / 魂灯已满，多余部分消散）");
            }
        }

        List<string> parts = new List<string>();
        if (got > 0) parts.Add($"获得物品 ×{got}");
        if (lost > 0) parts.Add($"未收下 ×{lost}");
        return parts.Count > 0 ? string.Join("  ", parts) : null;
    }

    // ====================================================================
    // 卡牌飞入/飞出 DISCARD 面板
    // ====================================================================
    public void FlyCardToDiscardPanel(CardView handCV)
    {
        if (handCV == null || handCV.Card == null) return;
        if (_flyingSet.Contains(handCV)) return;

        // ★v2.11：用动态费用 CurrentCost（与拖动入口的能量检查一致，支持 F1.x
        // 动态降费）——旧版用 Data.energyCost 静态值，费用不一致时飞行逻辑被
        // 跳过且无收回处理，卡牌滞留在松手处（"拖出来静止不动"bug）
        int cost = handCV.Card.CurrentCost;
        EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd != null && !epd.CanAfford(cost))
        {
            // 能量不足：强制收回（拖动路径中交互流已被清空，卡可能悬在松手处）
            if (HandUIController.Instance != null)
                HandUIController.Instance.AttachCardViewBackFromCheckAssist(handCV, true);
            return;
        }

        Card card = handCV.Card;
        if (_panelCards.ContainsKey(card)) return;

        epd?.TryConsumeEnergy(cost);

        _flyingSet.Add(handCV);
        handCV.IsFlyingOut = true;

        // ★v2.12：登记为"暂存卡"——已从手牌摘除但尚未弃牌，仍计入持有集合
        //（否则 CharacterStats 统计的手牌花色缩水 → 属性基础分跟着缩水）
        if (!CharacterStats.PendingCards.Contains(card)) CharacterStats.PendingCards.Add(card);

        DetachFromHand(handCV);

        Transform canvasTF = GetOrCreateUICanvas();
        handCV.transform.SetParent(canvasTF, true);
        handCV.transform.SetAsLastSibling();

        DOTween.Kill(handCV.transform);
        RectTransform rt = handCV.Rect;
        if (rt == null) return;

        // ★v2.9 用户定稿：不用弧线抛物线，直接【缩小 + 直线平移】到弃牌槽
        Vector2 p0 = rt.anchoredPosition;
        Vector2 p2 = GetDiscardPanelDropPoint();

        float prefabScale = 1.4f;
        handCV.transform.DOScale(prefabScale * flyEndScaleFactor, flyDuration).SetEase(Ease.OutQuad);

        // ★v2.11：飞行中立正（手牌弧度旋转 → 直立），配合缩小飞向弃牌槽
        handCV.transform.DOLocalRotateQuaternion(Quaternion.identity, flyDuration * 0.6f).SetEase(Ease.OutQuad);

        rt.DOAnchorPos(p2, flyDuration)
        .SetEase(Ease.InQuad)
        .OnUpdate(() => { if (handCV != null) handCV.transform.SetAsLastSibling(); })
        .OnComplete(() =>
        {
            _flyingSet.Remove(handCV);
            if (handCV == null) return;
            handCV.transform.SetParent(discardPanel != null ? discardPanel : canvasTF, false);
            // 面板内卡牌横排错开（第 n 张偏移 n*90）
            int slot = _panelCards.Count;
            handCV.transform.localPosition = new Vector3((slot - 1) * 90f, -10f, 0);
            handCV.transform.DOScale(discardCardScale, 0.12f).SetEase(Ease.OutQuad);
            handCV.IsFlyingOut = false;

            _panelCards[card] = handCV;
            RegisterPanelCardClick(handCV, card);

            if (currentCheckOption != null)
            {
                discardBonus += CheckSystem.GetDiscardBonus(card.Data, currentCheckOption.checkType);
                RefreshDiceAndFormula();
                // ★v2.13：已锁定选项时，新飞入的卡若不符合属性立即灰显
                if (_lockedCheck.HasValue) RefreshPanelCardDimState();
            }
        });
    }

    // ====================================================================
    // ★2026-09-10 槽内卡参与弃牌鉴定（用户定稿）
    // ====================================================================
    // 为什么要有这条路：战术槽曾经是弃牌鉴定的**安全区** —— 把好牌塞进槽里，
    // 事件要弃牌时它们不会出现在手牌、永远轮不到被弃，槽位就变成了免死金牌。
    // 玩家能靠「藏牌」逃掉整套弃牌鉴定的取舍，这不是设计张力，是漏洞。
    //
    // 与手牌路径的区别只在「收留方式」：
    //   手牌卡 = 从 Hand 摘除 → 面板；取消 → 回 Hand（HandUIController 那套）
    //   槽内卡 = 从槽卸下  → 面板；取消 → **装回原槽**（本文件自己管）
    // 共同点：两种都只是「暂存」，都算进 CharacterStats 持有集合，属性不会提前缩水。
    // ====================================================================

    /// <summary>
    /// 把战术卡槽里的卡送进 DISCARD 面板参与弃牌鉴定。
    /// 调用方：CardPackUI（鉴定事件开着时，点卡包边栏里的槽内卡）。
    /// </summary>
    /// <returns>true = 已接收（调用方不要再做卸下/回库动作）</returns>
    public bool FlySlotCardToDiscardPanel(Card card)
    {
        if (card == null || card.Data == null) return false;
        if (!IsCheckPanelOpen) return false;
        if (_panelCards.ContainsKey(card)) return false;

        int slot = TacticSlotRuntime.IndexOf(card);
        if (slot < 0) return false;                       // 不在槽里 → 不是本方法的活

        // ★v9：冷却中的卡锁在槽里 —— 取不出来，也就不能送进弃牌鉴定。
        //   Unequip 现在会拒绝冷却中的卡；这里必须提前返回，否则卡既留在槽里又飞进面板，
        //   又变回 v8 修过的「同一张卡同时存在两份」（四区互斥被破坏）。
        if (!TacticSlotRuntime.CanUnequip(slot)) return false;

        CardView cv = CreateSlotPanelCardView(card);
        if (cv == null) return false;

        // 数据层：立刻卸下（暂存进面板），并登记原槽序号供取消时归位
        TacticSlotRuntime.Unequip(slot);
        _slotCardOrigins[card] = slot;

        if (!CharacterStats.PendingCards.Contains(card)) CharacterStats.PendingCards.Add(card);

        // 飞行：与手牌卡同一套（缩小 + 直线平移到 DISCARD 面板），复用同一批常量
        _flyingSet.Add(cv);
        cv.IsFlyingOut = true;

        Transform canvasTF = GetOrCreateUICanvas();
        cv.transform.SetParent(canvasTF, true);
        cv.transform.SetAsLastSibling();

        DOTween.Kill(cv.transform);
        RectTransform rt = cv.Rect;
        if (rt == null) { CharacterStats.PendingCards.Remove(card); return false; }

        Vector2 p2 = GetDiscardPanelDropPoint();
        cv.transform.DOScale(discardCardScale, flyDuration).SetEase(Ease.OutQuad);
        cv.transform.DOLocalRotateQuaternion(Quaternion.identity, flyDuration * 0.6f).SetEase(Ease.OutQuad);

        rt.DOAnchorPos(p2, flyDuration)
          .SetEase(Ease.InQuad)
          .OnUpdate(() => { if (cv != null) cv.transform.SetAsLastSibling(); })
          .OnComplete(() =>
          {
              _flyingSet.Remove(cv);
              if (cv == null) return;
              cv.transform.SetParent(discardPanel != null ? discardPanel : canvasTF, false);
              int order = _panelCards.Count;
              cv.transform.localPosition = new Vector3((order - 1) * 90f, -10f, 0);
              cv.transform.DOScale(discardCardScale, 0.12f).SetEase(Ease.OutQuad);
              cv.IsFlyingOut = false;

              _panelCards[card] = cv;
              RegisterPanelCardClick(cv, card);

              if (currentCheckOption != null)
              {
                  discardBonus += CheckSystem.GetDiscardBonus(card.Data, currentCheckOption.checkType);
                  RefreshDiceAndFormula();
                  if (_lockedCheck.HasValue) RefreshPanelCardDimState();
              }

              Debug.Log($"[EventPopupUI] 战术槽 槽{slot + 1} 的 {card.Data.cardName} 已飞入弃牌鉴定面板");
          });

        return true;
    }

    /// <summary>为槽内卡造一张面板卡面（挂到弹窗画布；视觉与手牌飞进来的卡完全一致）。</summary>
    private CardView CreateSlotPanelCardView(Card card)
    {
        CardView prefab = HandUIController.Instance != null ? HandUIController.Instance.CardViewPrefab : null;
        if (prefab == null)
        {
            Debug.LogWarning("[EventPopupUI] 找不到 CardView 预制体，槽内卡无法进入弃牌面板");
            return null;
        }

        CardView cv = Instantiate(prefab, GetOrCreateUICanvas(), false);
        cv.name = "SlotDiscardCard";
        cv.InteractionLocked = false;
        cv.transform.localScale = Vector3.one * 1.4f;
        cv.transform.localRotation = Quaternion.identity;

        RectTransform rt = cv.Rect;
        if (rt != null)
        {
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
            rt.pivot = new Vector2(0.5f, 0.5f);
        }

        cv.SetCard(card);                 // 灌运行时实例 → 描述/花色/费用按槽内卡现状显示
        cv.gameObject.SetActive(true);
        return cv;
    }

    /// <summary>把从槽里飞出去的卡装回原槽（原槽被占 → 退到第一个空槽；都满 → 留牌库）。</summary>
    private void ReEquipSlotCard(Card card, int originSlot)
    {
        if (card == null) return;

        string reason;
        if (TacticSlotRuntime.TryEquipAt(originSlot, card, out reason)) return;

        int empty = TacticSlotRuntime.FirstEmptyIndex();
        if (empty >= 0 && TacticSlotRuntime.TryEquipAt(empty, card, out reason)) return;

        Debug.LogWarning($"[EventPopupUI] {card.Data?.cardName} 装回战术槽失败（{reason}）——留在牌库中");
    }

    /// <summary>槽内卡取消弃牌：飞出面板 → 装回原槽（**骰点与 CD 原样保留**，不进手牌）。</summary>
    private void FlySlotCardBackToSlot(CardView panelCV, Card card, int originSlot)
    {
        // 与手牌路径同一口径：取回 = 退还当时飞入面板扣的能量
        EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd != null && card.Data != null)
            epd.AddEnergy(card.CurrentCost); // ★2026-09-14：上限收到 energyMax

        _panelCards.Remove(card);
        _slotCardOrigins.Remove(card);
        _flyingSet.Add(panelCV);
        panelCV.IsFlyingOut = true;

        if (currentCheckOption != null)
        {
            discardBonus -= CheckSystem.GetDiscardBonus(card.Data, currentCheckOption.checkType);
            if (discardBonus < 0) discardBonus = 0;
            RefreshDiceAndFormula();
        }

        Transform canvasTF = GetOrCreateUICanvas();
        RectTransform rt = panelCV.Rect;
        panelCV.transform.SetParent(canvasTF, true);
        panelCV.transform.SetAsLastSibling();
        DOTween.Kill(panelCV.transform);

        Vector2 p2 = GetTacticSlotDropPoint(originSlot);

        panelCV.transform.DOScale(1.4f, flyDuration).SetEase(Ease.OutQuad);
        rt.DOAnchorPos(p2, flyDuration)
          .SetEase(Ease.OutQuad)
          .OnUpdate(() => { if (panelCV != null) panelCV.transform.SetAsLastSibling(); })
          .OnComplete(() =>
          {
              _flyingSet.Remove(panelCV);
              CharacterStats.PendingCards.Remove(card);
              ReEquipSlotCard(card, originSlot);
              if (panelCV != null) Destroy(panelCV.gameObject);
              Debug.Log($"[EventPopupUI] {card.Data?.cardName} 已装回战术槽 {originSlot + 1}（取消弃牌）");
          });
    }

    /// <summary>战术槽格的屏幕落点 → 画布局部坐标（取回时把卡飞回槽里用）。</summary>
    private Vector2 GetTacticSlotDropPoint(int slot)
    {
        Transform canvasTF = GetOrCreateUICanvas();
        RectTransform canvasRT = canvasTF as RectTransform;

        Vector2 screenPos;

        TacticSlotsPanel panel = FindObjectOfType<TacticSlotsPanel>();
        RectTransform cell = panel != null ? panel.CellTransformForSlot(slot) : null;

        if (cell != null)
        {
            Vector2 worldPos = cell.TransformPoint(cell.rect.center);
            screenPos = RectTransformUtility.WorldToScreenPoint(null, worldPos);
        }
        else if (HandUIController.Instance != null && HandUIController.Instance.HandAreaRoot != null)
        {
            // 面板没开（探索事件里的常态）→ 落到手牌区中央，视觉上「收起来了」
            RectTransform handRT = HandUIController.Instance.HandAreaRoot as RectTransform;
            Vector2 worldPos = handRT.TransformPoint(handRT.rect.center);
            screenPos = RectTransformUtility.WorldToScreenPoint(null, worldPos);
        }
        else
        {
            return Vector2.zero;
        }

        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(canvasRT, screenPos, null, out Vector2 local))
            return local;
        return Vector2.zero;
    }

    public void FlyCardBackToHand(Card card)
    {
        if (card == null || !_panelCards.TryGetValue(card, out CardView panelCV)) return;
        if (_flyingSet.Contains(panelCV)) return;

        // ★2026-09-10：槽内卡走「回原槽」而不是「回手牌」——
        //   两种收留方式的差别就藏在这个分支里（手牌靠 HandUIController，槽靠 TacticSlotRuntime）。
        if (_slotCardOrigins.TryGetValue(card, out int slotOrigin))
        {
            FlySlotCardBackToSlot(panelCV, card, slotOrigin);
            return;
        }

        // ★v2.6：取回卡 = 退还当时飞入面板扣的能量（点击面板卡/拖离面板共用此链路）
        EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd != null && card.Data != null)
            epd.AddEnergy(card.CurrentCost); // ★v2.11：按动态费用退还；★2026-09-14 上限收到 energyMax

        _panelCards.Remove(card);
        _flyingSet.Add(panelCV);
        panelCV.IsFlyingOut = true;

        if (currentCheckOption != null)
        {
            discardBonus -= CheckSystem.GetDiscardBonus(card.Data, currentCheckOption.checkType);
            if (discardBonus < 0) discardBonus = 0;
            RefreshDiceAndFormula();
        }

        Transform canvasTF = GetOrCreateUICanvas();
        RectTransform rt = panelCV.Rect;
        panelCV.transform.SetParent(canvasTF, true);
        panelCV.transform.SetAsLastSibling();
        DOTween.Kill(panelCV.transform);

        // ★v2.9 用户定稿：直接【放大 + 直线平移】飞回手牌（无弧线）
        Vector2 p2 = GetHandDropPoint();

        float prefabScale = 1.4f;
        panelCV.transform.DOScale(prefabScale, flyDuration).SetEase(Ease.OutQuad);

        rt.DOAnchorPos(p2, flyDuration)
        .SetEase(Ease.OutQuad)
        .OnUpdate(() => { if (panelCV != null) panelCV.transform.SetAsLastSibling(); })
        .OnComplete(() =>
        {
            _flyingSet.Remove(panelCV);
            if (panelCV == null) return;
            AttachBackToHand(panelCV);
            CharacterStats.PendingCards.Remove(card); // ★v2.12：回手牌 → 退出暂存（Hand 重新计入）
            panelCV.IsFlyingOut = false;
        });
    }

    // ====================================================================
    // 面板卡管理
    // ====================================================================

    /// <summary>这张 CardView 是否已在 DISCARD 面板中（点击路由防重入用）</summary>
    public bool IsPanelCard(CardView cv)
    {
        return cv != null && _panelCards.ContainsValue(cv);
    }

    // ------------------------------------------------------------------
    // ★D19 v2.6 面板卡拖拽：拖离 DISCARD 面板 = 飞回手牌；拖回面板内 = 弹回槽位
    //（CardView.OnBeginDrag/OnDrag/OnEndDrag 分流调用）
    // ------------------------------------------------------------------

    /// <summary>面板卡拖拽开始：摘到 Canvas 顶层跟随鼠标</summary>
    public void BeginPanelCardDrag(CardView cv)
    {
        if (cv == null || !_panelCards.ContainsValue(cv)) return;
        if (_flyingSet.Contains(cv)) return;

        _panelDragCV = cv;
        Transform canvasTF = GetOrCreateUICanvas();
        cv.transform.SetParent(canvasTF, true);
        cv.transform.SetAsLastSibling();
        DOTween.Kill(cv.transform);
        DOTween.Kill(cv.Rect);
    }

    /// <summary>面板卡拖拽中：跟随鼠标（Canvas 空间）</summary>
    public void DragPanelCard(CardView cv, Vector2 screenPosition, Camera uiCamera)
    {
        if (cv == null || _panelDragCV != cv) return;
        RectTransform canvasRT = GetOrCreateUICanvas() as RectTransform;
        if (canvasRT == null) return;
        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(canvasRT, screenPosition, uiCamera, out Vector2 local))
        {
            cv.Rect.anchoredPosition = local;
        }
    }

    /// <summary>
    /// 面板卡拖拽结束：鼠标在 DISCARD 面板矩形外 → 飞回手牌；面板内 → 弹回槽位。
    /// </summary>
    public void EndPanelCardDrag(CardView cv, Vector2 screenPosition, Camera uiCamera)
    {
        if (cv == null || _panelDragCV != cv) return;
        _panelDragCV = null;

        Card card = cv.Card;
        if (card == null) return;

        bool outsidePanel = discardPanel == null
            || !RectTransformUtility.RectangleContainsScreenPoint(discardPanel, screenPosition, uiCamera);

        if (outsidePanel)
        {
            // 拖离面板 = 回手牌（能量退还已并入 FlyCardBackToHand）
            FlyCardBackToHand(card);
        }
        else
        {
            // 拖回面板内：弹回面板槽位
            Transform canvasTF = GetOrCreateUICanvas();
            cv.transform.SetParent(discardPanel != null ? discardPanel : canvasTF, true);
            int idx = 0;
            foreach (var kv in _panelCards)
            {
                if (kv.Value == cv) break;
                idx++;
            }
            Vector3 slot = new Vector3((idx - 1) * 90f, -10f, 0);
            cv.transform.DOLocalMove(slot, 0.15f).SetEase(Ease.OutQuad);
        }
    }

    private void RegisterPanelCardClick(CardView cv, Card card)
    {
        Button btn = cv.GetComponent<Button>();
        if (btn == null) btn = cv.gameObject.AddComponent<Button>();
        btn.transition = Selectable.Transition.None;
        btn.onClick.RemoveAllListeners();
        btn.onClick.AddListener(() =>
        {
            if (_flyingSet.Contains(cv)) return;
            FlyCardBackToHand(card);
        });
    }

    private void ReturnAllPanelCardsImmediate()
    {
        List<Card> all = new List<Card>(_panelCards.Keys);
        foreach (Card c in all)
        {
            if (!_panelCards.TryGetValue(c, out CardView cv)) continue;
            int cost = c.CurrentCost; // ★v2.11：按动态费用退还
            EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
            if (epd != null) epd.AddEnergy(cost); // ★2026-09-14：上限收到 energyMax
            CharacterStats.PendingCards.Remove(c); // ★v2.12：回手牌 → 退出暂存

            // ★2026-09-10：槽内卡「立即归位」= 装回原槽 + 销毁面板视图，不走手牌
            if (_slotCardOrigins.TryGetValue(c, out int originBack))
            {
                _slotCardOrigins.Remove(c);
                ReEquipSlotCard(c, originBack);
                if (cv != null) Destroy(cv.gameObject);
                continue;
            }

            AttachBackToHand(cv, true);
        }
        _panelCards.Clear();
        _slotCardOrigins.Clear();
        discardBonus = 0; // ★v2.11：面板已清空，弃牌加成归零
    }

    private void ClearPanelCards()
    {
        foreach (var kv in _panelCards)
        {
            if (kv.Value != null) Destroy(kv.Value.gameObject);
            if (kv.Key != null)
            {
                CharacterStats.PendingCards.Remove(kv.Key); // ★v2.12：防泄漏

                // ★2026-09-10 兜底：槽内卡不能就这么蒸发 —— 装回原槽
                if (_slotCardOrigins.TryGetValue(kv.Key, out int bailSlot))
                {
                    ReEquipSlotCard(kv.Key, bailSlot);
                }
            }
        }
        _panelCards.Clear();
        _slotCardOrigins.Clear();
        discardBonus = 0;
    }

    // ====================================================================
    // 坐标辅助
    // ====================================================================
    private Transform GetOrCreateUICanvas()
    {
        GameObject go = GameObject.Find("UICanvas");
        if (go == null)
        {
            go = new GameObject("UICanvas", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
            go.GetComponent<Canvas>().renderMode = RenderMode.ScreenSpaceOverlay;
        }
        return go.transform;
    }

    private Vector2 GetDiscardPanelDropPoint()
    {
        Transform canvasTF = GetOrCreateUICanvas();
        RectTransform canvasRT = canvasTF as RectTransform;
        RectTransform panelRT = discardPanel != null ? discardPanel : canvasRT;
        Vector2 worldPos = panelRT.TransformPoint(panelRT.rect.center);
        Vector2 screenPos = RectTransformUtility.WorldToScreenPoint(null, worldPos);
        if (RectTransformUtility.ScreenPointToLocalPointInRectangle(canvasRT, screenPos, null, out Vector2 local))
            return local;
        return Vector2.zero;
    }

    private Vector2 GetHandDropPoint()
    {
        Transform canvasTF = GetOrCreateUICanvas();
        RectTransform canvasRT = canvasTF as RectTransform;
        if (HandUIController.Instance != null && HandUIController.Instance.HandAreaRoot != null)
        {
            RectTransform handRT = HandUIController.Instance.HandAreaRoot as RectTransform;
            Vector3 worldCenter = handRT.TransformPoint(handRT.rect.center);
            Vector2 sp = RectTransformUtility.WorldToScreenPoint(null, worldCenter);
            if (RectTransformUtility.ScreenPointToLocalPointInRectangle(canvasRT, sp, null, out Vector2 local))
                return local;
        }
        // ★2026-09-09 UI 自适应：兜底落点改用 canvas 的 rect 高度（参考分辨率单位），
        //   与 CanvasScaler 一致；原来 Screen.height 是物理像素，换分辨率后偏移量错。
        return new Vector2(0, -canvasRT.rect.height * 0.35f);
    }

    // ====================================================================
    // HandUIController 集成
    // ====================================================================
    private void DetachFromHand(CardView cv)
    {
        // ★v2.10：SendMessage → 直接调用（方法已 public）
        if (HandUIController.Instance != null) HandUIController.Instance.DetachCardViewForCheckAssist(cv);
    }

    private void AttachBackToHand(CardView cv, bool immediate = false)
    {
        // ★v2.13：离开面板回手牌时恢复正常透明度（可能处于锁定后的灰显态）
        if (cv != null) cv.SetCardAlpha(1f);
        if (HandUIController.Instance != null) HandUIController.Instance.AttachCardViewBackFromCheckAssist(cv, immediate);
    }

    // ====================================================================
    // UI 工具
    // ====================================================================
    private Font GetFont()
    {
        Font font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        if (font == null) font = Resources.GetBuiltinResource<Font>("Arial.ttf");
        return font;
    }

    private Text CreateText(GameObject parent, string content, int size, Color color, TextAnchor align)
    {
        GameObject obj = new GameObject("Text", typeof(RectTransform));
        obj.transform.SetParent(parent.transform, false);
        Text t = obj.AddComponent<Text>();
        t.font = GetFont();
        t.text = content;
        t.fontSize = size;
        t.color = color;
        t.alignment = align;
        t.supportRichText = true;
        t.horizontalOverflow = HorizontalWrapMode.Wrap;
        t.verticalOverflow = VerticalWrapMode.Overflow;
        t.raycastTarget = false;
        return t;
    }

    private static void FitTextToParent(Text t)
    {
        RectTransform rt = t.rectTransform;
        rt.anchorMin = Vector2.zero;
        rt.anchorMax = Vector2.one;
        rt.offsetMin = Vector2.zero;
        rt.offsetMax = Vector2.zero;
    }

    // ====================================================================
    // Sprite 生成工具（圆形按钮底 / 骰子面，纯代码生成无美术资源）
    // ====================================================================
    private static Sprite _circleSpriteCache;
    private static Sprite MakeCircleSprite()
    {
        if (_circleSpriteCache != null) return _circleSpriteCache;
        int size = 64;
        Texture2D tex = new Texture2D(size, size, TextureFormat.RGBA32, false);
        Vector2 c = new Vector2(size / 2f, size / 2f);
        float r = size / 2f - 1;
        for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
            {
                float d = Vector2.Distance(new Vector2(x, y), c);
                tex.SetPixel(x, y, d <= r ? Color.white : Color.clear);
            }
        tex.Apply();
        _circleSpriteCache = Sprite.Create(tex, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f));
        return _circleSpriteCache;
    }

    /// <summary>动态生成骰子面 Sprite（1~6 面）</summary>
    private Sprite[] GenerateDiceFaceSprites()
    {
        int size = 128;
        Sprite[] sprites = new Sprite[6];
        float margin = size * 0.25f;
        float center = size / 2f;
        float dotRadius = size * 0.08f;
        Color bgColor = new Color(0.95f, 0.93f, 0.88f);
        Color dotColor = new Color(0.15f, 0.1f, 0.05f);

        for (int face = 1; face <= 6; face++)
        {
            Texture2D tex = new Texture2D(size, size, TextureFormat.RGBA32, false);

            // ★v2.13 用户定稿：绘制方形骰子面（原来是圆形，用户觉得奇怪）。
            // 方形底 + 4px 深色描边。
            Color borderColor = new Color(bgColor.r * 0.75f, bgColor.g * 0.75f, bgColor.b * 0.75f);
            for (int y = 0; y < size; y++)
            {
                for (int x = 0; x < size; x++)
                {
                    int edge = Mathf.Min(x, y, size - 1 - x, size - 1 - y);
                    tex.SetPixel(x, y, edge < 4 ? borderColor : bgColor);
                }
            }

            // 绘制点数
            Vector2[] dots = GetDiceDotPositions(face, size, margin, center);
            foreach (var dot in dots)
            {
                for (int y = 0; y < size; y++)
                {
                    for (int x = 0; x < size; x++)
                    {
                        float dx = x - dot.x;
                        float dy = y - dot.y;
                        float dist = Mathf.Sqrt(dx * dx + dy * dy);
                        if (dist <= dotRadius)
                        {
                            float alpha = dist > dotRadius - 1f ? (dotRadius - dist) : 1f;
                            tex.SetPixel(x, y, new Color(dotColor.r, dotColor.g, dotColor.b, alpha));
                        }
                    }
                }
            }

            tex.Apply();
            sprites[face - 1] = Sprite.Create(tex, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f), 100);
        }

        return sprites;
    }

    /// <summary>获取骰子某个面的点数位置</summary>
    private Vector2[] GetDiceDotPositions(int face, int size, float margin, float center)
    {
        float s = size;
        switch (face)
        {
            case 1: return new Vector2[] { new Vector2(center, center) };
            case 2: return new Vector2[] { new Vector2(margin, margin), new Vector2(s - margin, s - margin) };
            case 3: return new Vector2[] { new Vector2(margin, margin), new Vector2(center, center), new Vector2(s - margin, s - margin) };
            case 4: return new Vector2[] { new Vector2(margin, margin), new Vector2(s - margin, margin), new Vector2(margin, s - margin), new Vector2(s - margin, s - margin) };
            case 5: return new Vector2[] { new Vector2(margin, margin), new Vector2(s - margin, margin), new Vector2(center, center), new Vector2(margin, s - margin), new Vector2(s - margin, s - margin) };
            case 6: return new Vector2[] { new Vector2(margin, margin), new Vector2(s - margin, margin), new Vector2(margin, center), new Vector2(s - margin, center), new Vector2(margin, s - margin), new Vector2(s - margin, s - margin) };
            default: return new Vector2[0];
        }
    }
}

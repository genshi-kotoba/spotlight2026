// =============================================================================
// 模块：UI - 自动整备开关（能量点正上方的「小字 + 勾选框」）
// 用途：勾选后实时盯着能量点：能量降到 0 时，自动消耗一枚探索骰子执行整备（补满至 3）。
//       位置：EnergyPointDisplay 正上方一点。
// 设计依据：用户 2026-09-12 指令（原话）——「就一行小字，放在能量点上方一点，然后旁边一个
//          可以打钩的方框，打开实时检测能量点，当能量为0时，会自动消耗一枚探索骰子进行整备」。
//          两处口径由用户拍板：① 战斗 + 探索都生效；② 勾选状态记住（PlayerPrefs）。
//          ★2026-09-14 追加：开局默认「关闭」（用户拍板）。
//          ★同日再追加（用户口径）：① **只要进了教程（教程图 + 教学未完成）一律从「关闭」开始**，
//            要玩家自己重新打开；教程期的勾选**不写 PlayerPrefs**（不带进正式局默认值）。
//            ② 教程图里本开关在 **S19 教学拍出现之前整体不显示**（可见性由 TutorialDirector
//            在 S19 激活动作里点亮，见 TutorialStepData.revealAutoPrepare）。
//          ★同日反馈：悬停提示小弹窗挡视线 → 已删除（本开关不再有任何悬停提示）。
// 实现要点：
//   - 规则不自建：能不能整备、怎么整备全部走 EnergyPointDisplay 的权威判定
//     CanPrepare() / PerformPrepare()（每回合限一次、能量 ≥3 不整备、骰子可用性全部沿用）。
//   - 运行时自建 UI 并挂在能量点 RectTransform 下：跟随其显隐/布局，不需要改场景。
//
// ★2026-09-14 修复「导出后看不见自动整备开关（Play 里正常）」：
//   原实现用 [RuntimeInitializeOnLoadMethod] 直接挂载 —— 那是**应用启动回调**，
//   只在「第一个场景加载完」时执行一次，不是「每次场景加载」。
//   正式构建的启动场景是 HideoutScene（Build Settings level0），那里没有能量点，
//   回调空跑 return；此后出击 LoadScene(TutorialScene / FogTownScene) 时回调早已跑过、不会重来，
//   于是开关从未被创建。Play 里正常，是因为编辑器直接以突袭场景为启动场景。
//   改为订阅 SceneManager.sceneLoaded + 幂等 TryMount：任何场景加载完都重试一次。
//   （同 TutorialDirector 2026-09-14 的修法，坑一样。）
// =============================================================================
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

/// <summary>
/// 自动整备开关：能量 = 0 时自动花一枚探索骰子整备（补满至 3）。
/// 挂在 EnergyPointDisplay 的子节点上（运行时自建），无需场景引用。
/// </summary>
public class AutoPrepareToggle : MonoBehaviour
{
    private const string PrefKey = "AutoPrepareToggle.On";

    // 视觉：沿用教学卡的「深棕 + 黄铜」一套
    private static readonly Color C_BROWN = new Color(0.106f, 0.067f, 0.024f, 0.88f);
    private static readonly Color C_BRASS = new Color(0.89f, 0.71f, 0.40f, 1f);

    private EnergyPointDisplay _display;
    private RectTransform _displayRT;
    private RectTransform _rt;
    private Toggle _toggle;
    private CanvasGroup _cg;
    private bool _persistPref = true;       // 教程期不落盘（见 BuildUI 注释）

    // ==================================================================
    // ★2026-09-14 教程显示门禁：教程图 + 教学未完成时，S19 教学拍之前整体不显示
    // ==================================================================
    /// <summary>由 TutorialDirector 在 S19 拍激活时置 true（见 TutorialStepData.revealAutoPrepare）。
    /// ⚠️ 静态字段跨场景不自动清 —— TutorialDirector.Awake 在教学启动时会复位为 false，
    ///    保证「每次进入教程都是重新教一遍」。</summary>
    public static bool TutorialRevealed = false;

    /// <summary>当前是否处于「教程局」（教程图 + 教学未完成）。只有这种局才吃显示门禁。</summary>
    private static bool TutorialRun => TutorialProgress.IsTutorialPending && MapLayoutBuilder.IsTutorial;

    /// <summary>显示门禁唯一入口（供 TutorialDirector 在 S19 拍调用）。非教程局恒显示。</summary>
    public static void SetTutorialRevealed(bool revealed)
    {
        TutorialRevealed = revealed;
        var all = FindObjectsOfType<AutoPrepareToggle>(true);
        if (all != null) foreach (var t in all) if (t != null) t.ApplyVisibility(true);
    }

    private bool _visInit;
    private bool _visShown;

    /// <summary>按门禁切换可见性。用 CanvasGroup 而不是 SetActive —— 隐藏期间本组件仍在
    /// 每帧跑（否则教学完成后没人把它恢复回来）。</summary>
    private void ApplyVisibility(bool force = false)
    {
        bool show = !TutorialRun || TutorialRevealed;
        if (!force && _visInit && show == _visShown) return;
        _visInit = true;
        _visShown = show;
        if (_cg != null)
        {
            _cg.alpha = show ? 1f : 0f;
            _cg.interactable = show;
            _cg.blocksRaycasts = show;
        }
    }

    // ==================================================================
    // 自动挂载：只在「有能量点」的界面出现（藏身处没有则不生成）
    // ==================================================================
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void AutoStart()
    {
        SceneManager.sceneLoaded -= OnSceneLoaded;   // 幂等：域重载后避免重复订阅
        SceneManager.sceneLoaded += OnSceneLoaded;
        TryMount();                                  // 覆盖「直接从有能量点的场景启动 Play」
    }

    private static void OnSceneLoaded(Scene scene, LoadSceneMode mode) => TryMount();

    private static void TryMount()
    {
        var displays = FindObjectsOfType<EnergyPointDisplay>(true);
        if (displays == null || displays.Length == 0) return;
        var display = displays[0];
        if (display == null) return;
        if (display.GetComponentInChildren<AutoPrepareToggle>(true) != null) return; // 防重复

        var go = new GameObject("AutoPrepareToggle", typeof(RectTransform));
        go.transform.SetParent(display.transform, false);
        go.AddComponent<AutoPrepareToggle>();
    }

    private void Awake()
    {
        _display = GetComponentInParent<EnergyPointDisplay>();
        if (_display == null) { enabled = false; return; }
        _displayRT = _display.GetComponent<RectTransform>();
        BuildUI();
    }

    private void Start()
    {
        // 放到能量点正上方（Start 取 rect 更稳：此时布局已就绪）
        float h = _displayRT != null ? _displayRT.rect.height : 0f;
        if (h < 1f) h = 50f; // 布局未就绪时的兜底（能量点现为 100x100）
        _rt.anchoredPosition = new Vector2(0f, h * 0.5f + 8f);
    }

    // ==================================================================
    // 实时检测：能量 = 0 → 自动整备（判定与操作全部复用能量点的权威入口）
    // ==================================================================
    private void Update()
    {
        ApplyVisibility();   // 每帧跟随门禁（教学完成 / S19 点亮后自动恢复显示）
        if (_toggle == null || _display == null || !_toggle.isOn) return;
        if (_display.CurrentEnergy != 0) return;
        if (!_display.CanPrepare()) return;
        if (_display.PerformPrepare())
            Debug.Log("[自动整备] 能量为 0 → 自动消耗 1 枚探索骰子整备（补满至 3）");
    }

    // ==================================================================
    // UI 构建
    // ==================================================================
    private void BuildUI()
    {
        _rt = GetComponent<RectTransform>();
        _rt.anchorMin = _rt.anchorMax = new Vector2(0.5f, 0.5f);
        _rt.pivot = new Vector2(0.5f, 0f);
        _rt.sizeDelta = new Vector2(92f, 22f);

        // 根上的透明图：接住整块的射线（点击），子元素一律不挡射线
        var hit = gameObject.AddComponent<Image>();
        hit.color = new Color(0f, 0f, 0f, 0f);
        hit.raycastTarget = true;

        // 可见性门禁载体（教程期 S19 前隐藏；用 alpha 而非 SetActive，保持本组件继续跑）
        _cg = gameObject.AddComponent<CanvasGroup>();

        // 小字
        var labelGO = new GameObject("Label", typeof(RectTransform));
        labelGO.transform.SetParent(transform, false);
        var label = labelGO.AddComponent<Text>();
        label.font = GetSafeFont();
        label.text = "自动整备";
        label.fontSize = 16;
        label.color = Color.black;
        label.alignment = TextAnchor.MiddleLeft;
        label.raycastTarget = false;
        var lrt = label.rectTransform;
        lrt.anchorMin = lrt.anchorMax = new Vector2(0f, 0.5f);
        lrt.pivot = new Vector2(0f, 0.5f);
        lrt.sizeDelta = new Vector2(66f, 22f);
        lrt.anchoredPosition = Vector2.zero;

        // 勾选框
        var boxGO = new GameObject("Box", typeof(RectTransform));
        boxGO.transform.SetParent(transform, false);
        var box = boxGO.AddComponent<Image>();
        box.color = C_BROWN;
        box.raycastTarget = false;
        var outline = boxGO.AddComponent<Outline>();
        outline.effectColor = C_BRASS;
        outline.effectDistance = new Vector2(1f, -1f);
        var brt = box.rectTransform;
        brt.anchorMin = brt.anchorMax = new Vector2(1f, 0.5f);
        brt.pivot = new Vector2(1f, 0.5f);
        brt.sizeDelta = new Vector2(18f, 18f);
        brt.anchoredPosition = Vector2.zero;

        // 勾（选中时显示，由 Toggle.graphic 控制显隐）
        var checkGO = new GameObject("Check", typeof(RectTransform));
        checkGO.transform.SetParent(boxGO.transform, false);
        var check = checkGO.AddComponent<Image>();
        check.color = C_BRASS;
        check.raycastTarget = false;
        var crt = check.rectTransform;
        crt.anchorMin = crt.anchorMax = new Vector2(0.5f, 0.5f);
        crt.pivot = new Vector2(0.5f, 0.5f);
        crt.sizeDelta = new Vector2(10f, 10f);
        crt.anchoredPosition = Vector2.zero;

        _toggle = gameObject.AddComponent<Toggle>();
        _toggle.targetGraphic = box;
        _toggle.graphic = check;
        _toggle.transition = Selectable.Transition.ColorTint;
        var colors = _toggle.colors;
        colors.normalColor = Color.white;
        colors.highlightedColor = new Color(0.85f, 0.85f, 0.85f, 1f);
        colors.pressedColor = new Color(0.7f, 0.7f, 0.7f, 1f);
        _toggle.colors = colors;
        // ★2026-09-14 用户拍板口径：
        //   ① 正式局开局默认「关闭」（PrefKey 缺省 0），勾选状态记进 PlayerPrefs；
        //   ② **只要进了教程（教程图 + 教学未完成）一律从「关闭」开始**，要玩家自己重新打开，
        //      并且教程期的勾选**不落盘** —— 否则教学里的临时操作会变成正式局的默认值，
        //      与「默认关闭」冲突。
        _persistPref = !TutorialRun;
        _toggle.isOn = _persistPref && PlayerPrefs.GetInt(PrefKey, 0) == 1;
        _toggle.onValueChanged.AddListener(OnToggleChanged);
        ApplyVisibility(true);      // 教程期 S19 之前整体不显示
    }

    private void OnToggleChanged(bool on)
    {
        if (!_persistPref) return;   // 教程期：只在本次游玩内生效，不写 PlayerPrefs
        PlayerPrefs.SetInt(PrefKey, on ? 1 : 0);
        PlayerPrefs.Save();
    }

    /// <summary>安全获取内置字体（跟随项目惯例：LegacyRuntime.ttf → Arial.ttf → 借用场景现有 Text）。</summary>
    private static Font _cachedFont;
    private static Font GetSafeFont()
    {
        if (_cachedFont != null) return _cachedFont;
        try { _cachedFont = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf"); } catch { }
        if (_cachedFont == null)
        {
            try { _cachedFont = Resources.GetBuiltinResource<Font>("Arial.ttf"); } catch { }
        }
        if (_cachedFont == null)
        {
            var anyText = FindObjectsOfType<Text>();
            if (anyText != null && anyText.Length > 0 && anyText[0] != null && anyText[0].font != null)
                _cachedFont = anyText[0].font;
        }
        return _cachedFont;
    }
}

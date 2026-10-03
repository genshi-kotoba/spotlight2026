// =============================================================================
// 模块：Dev - DevPanel 开发者面板（★2026-09-17 起编辑器与正式包双端生效）
// 用途：F9 开/关一个全屏 2D「彩蛋」菜单，用于在场景之间快速跳转测试 + 管理存档位；
//       F8 = 调试作弊：21 件族材 ＋ 15 件独特素材 ＋ 卡牌碎片 ＋ 物资全部补到 99（即时落档）。
//   · 开始游戏  → 正式游玩流程入口：按教学进度路由（教程未完成 → TutorialScene 教程图；已完成 → 藏身处）
//   · 测试区域  → MainScene（最早搭的主场景，旧链路）
//   · 教程区域1 → TutorialScene 教程图（重置教学进度，从 S1 重看）——★原 F9 的职责搬到这里
//   · 雾镇      → FogTownScene 雾镇正式图（★2026-09-15 已拆成独立场景，进图现烘 80×50）
//   · 右下角三个存档位 → 整行点击 = 设为当前并立刻保存 / 「清空」= 两段确认
// 设计依据：用户 2026-09-14 定稿「开发者面板，按 F9 进入，进入后是一个简单的 2D 彩蛋」；
//           「存档面板是在 f9 面板里的，并不是藏身处界面」；
//           F9 冲突处理——「有新的存档已经替代重置教学的功能了，直接删掉这个（TutorialDebugHotkeys）」；
//           ★2026-09-17 用户裁定「导出包里也要能用 F9」＋「按 F8 给我所有材料 99 个」。
//
// 实现要点：
//   - ★2026-09-17 摘掉原 #if UNITY_EDITOR 整包门槛 → 正式构建同样编译，F8/F9 双端可用。
//     材料口径：不足 99 的补到 99，已有且多于 99 的不动（MetaWallet.EnsureMaterials）。
//   - [RuntimeInitializeOnLoadMethod] 自动挂载 + DontDestroyOnLoad：所有场景都生效，
//     不需要往任何场景里挂东西（与 TutorialDirector 同风格）。
//   - 自建独立 Canvas（sortingOrder 32000），**不依赖场景里的 UICanvas** ——
//     MainScene 等旧场景未必有 UICanvas，不能像 SettingsUI 那样找它。
//   - 跳转前统一走 ExpeditionLifecycle.EndExpedition 清当局静态：静态字段不随 LoadScene 重置，
//     不清理会让击杀账本 / 装填 / 遗物袋污染新一局（与玩家死亡重载是同一条清理链路）。
//     包 try/catch：在藏身处 / MainScene 这类没有当局系统的场景里调用不应中断跳转。
//   - ★2026-09-14 打开期间置 Interactions.DevPanelOpen = true → **游戏输入全面让路**
//     （WASD/滚轮镜头、点击移动与悬停预览、空格结束回合、出牌、背包键）。
//     面板自己的按钮不受影响：它们走 UI 事件系统（独立 Canvas + EventSystem），不读裸 Input。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.UI;

/// <summary>开发者面板（编辑器与正式包双端生效）。F9 = 开/关全屏 2D 跳转菜单 + 存档位管理；F8 = 材料补到 99。</summary>
public class DevPanel : MonoBehaviour
{
    // 项目 UI 色板
    static readonly Color C_BG    = new Color(0.106f, 0.067f, 0.024f, 0.97f);  // #1b1106 深棕
    static readonly Color C_CARD  = new Color(0.165f, 0.115f, 0.050f, 1f);     // 卡片底
    static readonly Color C_BRASS = new Color(0.890f, 0.710f, 0.404f, 1f);     // #E3B567 黄铜
    static readonly Color C_CREAM = new Color(0.965f, 0.894f, 0.769f, 1f);     // #F6E4C4 奶黄
    static readonly Color C_MUTED = new Color(0.620f, 0.550f, 0.440f, 1f);
    static readonly Color C_GREEN = new Color(0.059f, 0.463f, 0.431f, 1f);     // #0F766E 墨绿
    static readonly Color C_SEL   = new Color(0.255f, 0.190f, 0.085f, 1f);     // 当前存档位高亮
    static readonly Color C_DANGER= new Color(0.420f, 0.120f, 0.080f, 1f);     // 清空按钮

    /// <summary>面板当前是否打开（其他全局快捷键可据此让路）。</summary>
    public static bool IsOpen { get; private set; }

    Canvas _canvas;
    Text _footNote;
    Canvas _toastCanvas;      // F8 等快捷键的短提示（独立小画布，不受面板开关影响）
    Text _toastText;
    float _toastUntil;

    // 存档位 UI
    class SlotUI
    {
        public Image background;
        public Text title;
        public Text status;
        public Text clearLabel;
        public bool clearArmed;
    }
    readonly SlotUI[] _slotUIs = new SlotUI[SaveSlots.Count];

    // ------------------------------------------------------------------
    // 自动挂载
    // ------------------------------------------------------------------

    [RuntimeInitializeOnLoadMethod]
    static void AutoStart()
    {
        var go = new GameObject("[DevPanel]");
        DontDestroyOnLoad(go);            // 跨场景存活，才能在任意场景按 F9
        go.AddComponent<DevPanel>();
    }

    void Awake()
    {
        Build();
        BuildToast();
        SetOpen(false);
        SceneManager.sceneLoaded += OnSceneLoaded;
    }

    void OnDestroy()
    {
        SceneManager.sceneLoaded -= OnSceneLoaded;
    }

    void OnSceneLoaded(Scene scene, LoadSceneMode mode)
    {
        // 切场景后自动收起（面板是跨场景常驻的，不主动关会一直挂在最上层）
        SetOpen(false);
    }

    void Update()
    {
        if (Input.GetKeyDown(KeyCode.F9)) SetOpen(!IsOpen);
        if (Input.GetKeyDown(KeyCode.F8)) GiveAllMaterials();
        if (_toastCanvas != null && _toastCanvas.gameObject.activeSelf && Time.unscaledTime >= _toastUntil)
            _toastCanvas.gameObject.SetActive(false);
    }

    // ------------------------------------------------------------------
    // F8 作弊：材料全 99（★2026-09-17 用户点名：导出包也要能用）
    // ------------------------------------------------------------------

    void GiveAllMaterials()
    {
        List<string> names = new List<string>();
        WildernessCraftCatalog cat = WildernessCraftCatalog.Load();
        if (cat != null)
        {
            if (cat.families != null)
                foreach (WildernessCraftCatalog.FamilyRow f in cat.families)
                {
                    if (f == null || f.materials == null) continue;
                    foreach (ItemData m in f.materials)
                        if (m != null && !string.IsNullOrEmpty(m.itemName)) names.Add(m.itemName);
                }
            if (cat.uniqueMaterials != null)
                foreach (ItemData m in cat.uniqueMaterials)
                    if (m != null && !string.IsNullOrEmpty(m.itemName)) names.Add(m.itemName);
        }
        else Debug.LogWarning("[DevPanel] F8：工坊素材目录缺失，只发碎片与物资");
        names.Add(MetaWallet.ShardMaterialName);
        names.Add(MetaWallet.SalvageName);

        const int Target = 99;
        int changed = MetaWallet.EnsureMaterials(names, Target);
        Debug.Log($"[DevPanel] F8：{names.Count} 种材料补到 {Target}，本次变动 {changed} 种");
        ShowToast("F8 · 材料已补到 99 · " + names.Count + " 种");
    }

    void BuildToast()
    {
        GameObject go = new GameObject("DevToastCanvas", typeof(Canvas));
        go.transform.SetParent(transform, false);
        _toastCanvas = go.GetComponent<Canvas>();
        _toastCanvas.renderMode = RenderMode.ScreenSpaceOverlay;
        _toastCanvas.sortingOrder = 32001;      // 压住游戏 HUD 与面板本体；无 Raycaster → 不吃点击
        _toastText = NewText(_toastCanvas.transform, "Msg", "", 22, TextAnchor.MiddleCenter, C_BRASS);
        PlaceAnchor(_toastText.rectTransform, new Vector2(0.5f, 0f), new Vector2(0f, 96f), new Vector2(900f, 34f));
        _toastCanvas.gameObject.SetActive(false);
    }

    void ShowToast(string msg)
    {
        if (_toastCanvas == null) return;
        _toastText.text = msg;
        _toastCanvas.gameObject.SetActive(true);
        _toastUntil = Time.unscaledTime + 1.6f;
    }

    // ------------------------------------------------------------------
    // 界面
    // ------------------------------------------------------------------

    void Build()
    {
        GameObject canvasGo = new GameObject("DevCanvas",
            typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
        canvasGo.transform.SetParent(transform, false);
        _canvas = canvasGo.GetComponent<Canvas>();
        _canvas.renderMode = RenderMode.ScreenSpaceOverlay;
        _canvas.sortingOrder = 32000;      // 盖住游戏内所有 HUD / 弹窗

        CanvasScaler scaler = canvasGo.GetComponent<CanvasScaler>();
        scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
        scaler.referenceResolution = new Vector2(1280f, 720f);
        scaler.matchWidthOrHeight = 0.5f;

        // 全屏底色（吞掉杂散点击，游戏内点击也被它挡住）
        Image bg = NewImage(_canvas.transform, "BG", C_BG);
        Stretch(bg.rectTransform);

        // 居中边框（★2026-09-14 加宽到 1080：右侧腾出存档位一列）
        Image frame = NewImage(_canvas.transform, "Frame", new Color(0f, 0f, 0f, 0f));
        Place(frame.rectTransform, new Vector2(1080f, 560f), Vector2.zero);
        Outline outline = frame.gameObject.AddComponent<Outline>();
        outline.effectColor = C_BRASS;
        outline.effectDistance = new Vector2(2f, 2f);

        Text title = NewText(frame.transform, "Title", "开 发 者 面 板", 40, TextAnchor.MiddleCenter, C_BRASS);
        Place(title.rectTransform, new Vector2(680f, 52f), new Vector2(0f, 232f));

        Text sub = NewText(frame.transform, "Sub", "DEV PANEL · F9 关闭 · F8 补满材料", 14, TextAnchor.MiddleCenter, C_MUTED);
        Place(sub.rectTransform, new Vector2(680f, 22f), new Vector2(0f, 196f));

        float y = 118f;
        AddEntry(frame.transform, "开始游戏", "正式流程：教程 → 藏身处 → 雾镇（按当前进度决定入口）", y, C_BRASS, OnStartGame); y -= 72f;
        AddEntry(frame.transform, "测试区域", "MainScene —— 最早搭的主场景（旧链路）", y, C_GREEN, OnTestArea); y -= 72f;
        AddEntry(frame.transform, "教程区域1", "TutorialScene·教程图 —— 重置教学进度，从 S1 重看", y, C_GREEN, OnTutorialArea); y -= 72f;
        AddEntry(frame.transform, "雾镇", "FogTownScene·正式图 —— 进图现烘 80×50", y, C_GREEN, OnFogTown);

        Text hint = NewText(frame.transform, "Hint", "跳转前会清空当局状态（等同局末清理），不会污染下一局", 12, TextAnchor.MiddleCenter, C_MUTED);
        Place(hint.rectTransform, new Vector2(760f, 20f), new Vector2(0f, -206f));

        _footNote = NewText(frame.transform, "Foot", "", 15, TextAnchor.MiddleCenter, C_CREAM);
        Place(_footNote.rectTransform, new Vector2(760f, 24f), new Vector2(0f, -236f));

        // ★2026-09-14 三个存档位（用户要求：存档面板放在本面板里，不是藏身处界面）
        BuildSaveSlots(frame.transform);
        RefreshFootnote();
    }

    void AddEntry(Transform parent, string title, string desc, float y, Color accent, Action onClick)
    {
        Image row = NewImage(parent, "Entry_" + title, C_CARD);
        Place(row.rectTransform, new Vector2(660f, 62f), new Vector2(-180f, y));   // 左列（右侧留给存档位）

        Button btn = row.gameObject.AddComponent<Button>();
        btn.targetGraphic = row;
        ColorBlock cb = btn.colors;
        cb.normalColor = Color.white;
        cb.highlightedColor = new Color(1f, 0.95f, 0.85f, 1f);
        cb.pressedColor = new Color(0.8f, 0.75f, 0.65f, 1f);
        btn.colors = cb;
        btn.onClick.AddListener(() => onClick?.Invoke());

        // 左侧强调竖条
        Image bar = NewImage(row.transform, "Bar", accent);
        bar.rectTransform.anchorMin = new Vector2(0f, 0f);
        bar.rectTransform.anchorMax = new Vector2(0f, 1f);
        bar.rectTransform.pivot = new Vector2(0f, 0.5f);
        bar.rectTransform.anchoredPosition = Vector2.zero;
        bar.rectTransform.sizeDelta = new Vector2(6f, 0f);

        Text t = NewText(row.transform, "T", title, 24, TextAnchor.MiddleLeft, C_BRASS);
        t.rectTransform.anchorMin = t.rectTransform.anchorMax = new Vector2(0f, 0.5f);
        t.rectTransform.pivot = new Vector2(0f, 0.5f);
        t.rectTransform.anchoredPosition = new Vector2(24f, 0f);
        t.rectTransform.sizeDelta = new Vector2(220f, 30f);

        Text d = NewText(row.transform, "D", desc, 13, TextAnchor.MiddleRight, C_MUTED);
        d.rectTransform.anchorMin = d.rectTransform.anchorMax = new Vector2(1f, 0.5f);
        d.rectTransform.pivot = new Vector2(1f, 0.5f);
        d.rectTransform.anchoredPosition = new Vector2(-16f, 0f);
        d.rectTransform.sizeDelta = new Vector2(420f, 24f);
    }

    // ------------------------------------------------------------------
    // ★存档位（右下角三个；对应 SaveSlots 的 3 个独立存档）
    // ------------------------------------------------------------------

    void BuildSaveSlots(Transform parent)
    {
        const float RowH = 66f, Gap = 8f, PadTop = 34f, PadBottom = 10f, PanelW = 372f;
        float panelH = PadTop + SaveSlots.Count * RowH + (SaveSlots.Count - 1) * Gap + PadBottom;

        Image panel = NewImage(parent, "SaveSlots", new Color(0.055f, 0.035f, 0.016f, 0.96f));
        Place(panel.rectTransform, new Vector2(PanelW, panelH), new Vector2(352f, 40f));
        Outline ol = panel.gameObject.AddComponent<Outline>();
        ol.effectColor = new Color(0.55f, 0.44f, 0.28f, 0.85f);
        ol.effectDistance = new Vector2(2f, 2f);

        Text cap = NewText(panel.transform, "Cap", "存档位（到藏身处自动保存）", 15, TextAnchor.MiddleLeft, C_BRASS);
        PlaceAnchor(cap.rectTransform, new Vector2(0f, 1f), new Vector2(14f, -8f), new Vector2(340f, 20f));

        for (int i = 0; i < SaveSlots.Count; i++)
        {
            int slot = i + 1;                                   // 闭包捕获：拷一份
            float y = -(PadTop + i * (RowH + Gap));

            Image row = NewImage(panel.transform, $"Slot{slot}", C_CARD);
            PlaceAnchor(row.rectTransform, new Vector2(0.5f, 1f), new Vector2(0f, y), new Vector2(PanelW - 24f, RowH));

            SlotUI ui = new SlotUI { background = row };

            // 整行 = 「使用」按钮（设为当前存档 + 立刻保存）
            Button useBtn = row.gameObject.AddComponent<Button>();
            useBtn.targetGraphic = row;
            ColorBlock cb = useBtn.colors;
            cb.normalColor = Color.white;
            cb.highlightedColor = new Color(1f, 0.95f, 0.85f, 1f);
            cb.pressedColor = new Color(0.8f, 0.75f, 0.65f, 1f);
            useBtn.colors = cb;
            useBtn.onClick.AddListener(() => OnSlotUse(slot));

            ui.title = NewText(row.transform, "T", $"存档 {slot}", 18, TextAnchor.MiddleLeft, C_BRASS);
            PlaceAnchor(ui.title.rectTransform, new Vector2(0f, 1f), new Vector2(14f, -8f), new Vector2(190f, 22f));

            ui.status = NewText(row.transform, "S", "", 12, TextAnchor.MiddleLeft, C_CREAM);
            PlaceAnchor(ui.status.rectTransform, new Vector2(0f, 1f), new Vector2(14f, -38f), new Vector2(230f, 20f));

            // 右上角「清空」（两段确认）
            Image clear = NewImage(row.transform, "Clear", C_DANGER);
            PlaceAnchor(clear.rectTransform, new Vector2(1f, 1f), new Vector2(-10f, -8f), new Vector2(66f, 26f));
            Button clearBtn = clear.gameObject.AddComponent<Button>();
            clearBtn.targetGraphic = clear;
            clearBtn.onClick.AddListener(() => OnSlotClear(slot));

            ui.clearLabel = NewText(clear.transform, "Label", "清空", 13, TextAnchor.MiddleCenter, C_CREAM);
            Stretch(ui.clearLabel.rectTransform);

            _slotUIs[i] = ui;
        }
    }

    void RefreshSaveSlots()
    {
        for (int i = 0; i < _slotUIs.Length; i++)
        {
            SlotUI ui = _slotUIs[i];
            if (ui == null) continue;
            int slot = i + 1;
            bool active = slot == SaveSlots.ActiveSlot;
            SaveSlots.TryRead(slot, out MetaWallet.SaveData d);
            bool empty = SaveSlots.IsEmpty(d);

            ui.background.color = active ? C_SEL : C_CARD;
            ui.title.text = active ? $"存档 {slot}  ● 当前" : $"存档 {slot}";
            ui.title.color = active ? C_BRASS : C_MUTED;
            ui.status.text = empty ? "（空）· 点击使用新建" : SaveSlots.Describe(slot);
        }
    }

    void OnSlotUse(int slot)
    {
        if (slot != SaveSlots.ActiveSlot) MetaWallet.SwitchSlot(slot);
        MetaWallet.Flush();                 // 设为当前 + 立刻存一次
        ArmClear(-1);                       // 关掉其它槽残留的「确认清空」态
        RefreshFootnote();
        RefreshSaveSlots();
    }

    void OnSlotClear(int slot)
    {
        SlotUI ui = _slotUIs[slot - 1];
        if (ui == null) return;

        if (!ui.clearArmed) { ArmClear(slot); return; }   // 第一下 = 进入确认态

        ArmClear(-1);
        SaveSlots.Clear(slot);
        if (slot == SaveSlots.ActiveSlot)
        {
            MetaWallet.ResetAll();          // 当前槽被清 → 内存回到全新档
        }
        RefreshFootnote();
        RefreshSaveSlots();
        Debug.Log($"[DevPanel] 存档 {slot} 已清空");
    }

    /// <summary>把「确认清空」态切给指定槽（slot &lt;= 0 = 全部取消）。带 3 秒自动复原。</summary>
    void ArmClear(int slot)
    {
        for (int i = 0; i < _slotUIs.Length; i++)
        {
            SlotUI ui = _slotUIs[i];
            if (ui == null) continue;
            ui.clearArmed = (i + 1) == slot;
            if (ui.clearLabel != null) ui.clearLabel.text = ui.clearArmed ? "确认清空?" : "清空";
        }
        CancelInvoke(nameof(DisarmClear));
        if (slot > 0) Invoke(nameof(DisarmClear), 3f);
    }

    void DisarmClear() { ArmClear(-1); }

    void RefreshFootnote()
    {
        if (_footNote == null) return;
        int slot = SaveSlots.ActiveSlot;
        _footNote.text = $"当前存档位 {slot}：{SaveSlots.Describe(slot)}";
    }

    // ------------------------------------------------------------------
    // 开关
    // ------------------------------------------------------------------

    void SetOpen(bool open)
    {
        IsOpen = open;
        Interactions.DevPanelOpen = open;   // ★面板打开 → 游戏输入全面让路
        if (_canvas != null) _canvas.gameObject.SetActive(open);
        if (open)
        {
            ArmClear(-1);
            RefreshFootnote();
            RefreshSaveSlots();
        }
    }

    // ------------------------------------------------------------------
    // 入口动作
    // ------------------------------------------------------------------

    /// <summary>开始游戏 = 正式游玩流程入口：按教学进度路由。</summary>
    void OnStartGame()
    {
        if (TutorialProgress.IsTutorialPending)
            Navigate(MetaWallet.TUTORIAL_SCENE, "开始游戏 → 教程图（教学未完成）");
        else
            Navigate(MetaWallet.HIDEOUT_SCENE, "开始游戏 → 藏身处（教学已完成）");
    }

    void OnTestArea()
    {
        Navigate("MainScene", "测试区域 → MainScene");
    }

    void OnTutorialArea()
    {
        TutorialProgress.Reset();          // ★原 F9 的职责
        ClearTutorialStatics();
        Navigate(MetaWallet.TUTORIAL_SCENE, "教程区域1 → TutorialScene（教程图，从 S1 重看）");
    }

    void OnFogTown()
    {
        // ★2026-09-15 雾镇已拆成独立场景：直接进 FogTownScene，进图时由 ExpeditionMapRouter
        //   从 raid_town.txt 现烘 80×50。先标记「已过教程」，否则路由会把玩家丢回教程图。
        MetaWallet.SetTutorialStage(1);
        Navigate(MetaWallet.FOGTOWN_SCENE, "雾镇 → FogTownScene（进图现烘 80×50）");
    }

    void Navigate(string sceneName, string label)
    {
        Debug.Log($"[DevPanel] 跳转：{label}（{sceneName}）");
        try
        {
            ExpeditionLifecycle.EndExpedition("开发者面板跳转");
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[DevPanel] 当局清理异常（已忽略，继续跳转）：{e.Message}");
        }
        SetOpen(false);
        SceneManager.LoadScene(sceneName);
    }

    /// <summary>清掉教程专属的静态门禁（EndExpedition 不负责这些，见 TutorialDirector）。</summary>
    static void ClearTutorialStatics()
    {
        Interactions.TutorialLockInput = false;
        Interactions.TutorialAllowCards = false;
        Interactions.TutorialAllowedCell = null;
        Interactions.TutorialBlockedCells.Clear();
        Interactions.TutorialCheckpointCells.Clear();
        Tutorial.TutorialDirector.RerollEnabled = false;
        ExplorationTurnManager.TutorialDeferAmbushBattle = false;
    }

    // ------------------------------------------------------------------
    // 建节点小工具
    // ------------------------------------------------------------------

    static Image NewImage(Transform parent, string name, Color color)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Image));
        go.transform.SetParent(parent, false);
        Image img = go.GetComponent<Image>();
        img.sprite = InventoryUIKit.WhitePixel;
        img.color = color;
        return img;
    }

    static Text NewText(Transform parent, string name, string text, int fontSize, TextAnchor align, Color color)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Text));
        go.transform.SetParent(parent, false);
        Text t = go.GetComponent<Text>();
        t.font = InventoryUIKit.SafeFont;
        t.text = text;
        t.fontSize = fontSize;
        t.alignment = align;
        t.color = color;
        t.horizontalOverflow = HorizontalWrapMode.Overflow;
        t.verticalOverflow = VerticalWrapMode.Overflow;
        t.raycastTarget = false;
        return t;
    }

    static void Stretch(RectTransform rt)
    {
        rt.anchorMin = Vector2.zero;
        rt.anchorMax = Vector2.one;
        rt.offsetMin = Vector2.zero;
        rt.offsetMax = Vector2.zero;
    }

    /// <summary>居中锚点摆放（面板主列用）。</summary>
    static void Place(RectTransform rt, Vector2 size, Vector2 anchoredPos)
    {
        rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
        rt.pivot = new Vector2(0.5f, 0.5f);
        rt.sizeDelta = size;
        rt.anchoredPosition = anchoredPos;
    }

    /// <summary>任意锚点摆放（anchor = pivot，存档位一列用）。</summary>
    static void PlaceAnchor(RectTransform rt, Vector2 anchor, Vector2 anchoredPos, Vector2 size)
    {
        rt.anchorMin = rt.anchorMax = anchor;
        rt.pivot = anchor;
        rt.anchoredPosition = anchoredPos;
        rt.sizeDelta = size;
    }
}

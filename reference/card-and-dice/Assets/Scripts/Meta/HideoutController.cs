// =============================================================================
// 模块：Meta - HideoutController 藏身处控制器（2D 局外场景）
// 用途：HideoutScene 的运行时 UI 构建与交互 —— **大厅 + 设施热点 + 出击门**。
// 设计依据：docs/2026-09-16_藏身处-design.md v2.3（§3 大厅 / §5 整装出击 / §8 装备区）
//   · 一屏藏身处大厅：4 个可点击设施热点 + 1 扇出击门 + 常驻资源条。
//   · 点热点 → 打开该设施面板；关闭 → 回大厅；同一时刻只开一个面板。
//   · 「出击」→ 载入突袭场景（教程图 / 雾镇图 由 ExpeditionMapRouter 运行时选）。
// 用户决策（2026-09-14）：
//   · 「那三个强化直接删了，做新的设施」→ 3 项数值强化（最大生命 / 起始战斗骰 /
//     起始牌库）连同 MetaWallet 里的整套实现已删除，改为下面这套设施。
//   · 每次来到藏身处自动保存（MetaWallet.Flush）；存档位界面在开发者面板（F9）里。
// 挂载：HideoutScene 的 Hideout 对象（场景里只有这一个对象；Camera / EventSystem /
//       Canvas 都缺，由 EnsureSceneBasics / EnsureCanvas 运行期补建）。
// 开机入口：编辑器 Play 由 PlayStartScene（Assets/Scripts/Editor）钉到本场景；
//       正式构建的 level0 也是本场景 —— 「打开游戏 → 藏身处」两处一致。
// UI 风格：暗底 + 墨绿/黄铜/奶黄（项目 UI 色板），运行时自建，无预制体。
//
// ⚠️ 后端现状：
//   · 灵魂提取装置 = ★已接入（B2；2026-09-17 改全屏三栏）：中=选魂 / 右=已选 /
//     左=卡池预览（全集 + 已抽出标记）＋批量提取（1 魂 = 1 抽、无放回）。
//   · 卡牌工坊 = ★已接入（B3，2026-09-17）：制卡 / 制骰 / 被动激活 ＋ 拆闲置卡 ＋
//     怪材兑物资（三页签；规则全在 Workshop，面板只显示与转发）。
//   · 仓库 = 七分区实数据（只读）。
//   · 装备区 = 只读查看：已激活被动 ＋ 全部配方（装配在整装面板）。
//   · 出击 = 打开整装面板（初始卡组 / 初始被动 / 背包 三页）→「保存」留档不扣库存，
//     「出击」二次确认后扣库存进图（★B4，2026-09-17）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.SceneManagement;

public class HideoutController : MonoBehaviour
{
    // 项目 UI 色板
    private static readonly Color C_BG = new Color(0.105f, 0.067f, 0.024f, 1f);      // #1b1106 深棕
    private static readonly Color C_PANEL = new Color(0.059f, 0.463f, 0.431f, 1f);    // #0F766E 墨绿
    private static readonly Color C_CARD = new Color(0.094f, 0.075f, 0.043f, 1f);     // 卡片底（比背景略亮）
    private static readonly Color C_BRASS = new Color(0.890f, 0.710f, 0.404f, 1f);    // #E3B567 黄铜
    private static readonly Color C_CREAM = new Color(0.965f, 0.894f, 0.769f, 1f);    // #F6E4C4 奶黄
    private static readonly Color C_DIM = new Color(0.78f, 0.74f, 0.68f, 1f);
    private static readonly Color C_SCREEN = new Color(0.055f, 0.043f, 0.024f, 1f);  // 全屏面板底
    private static readonly Color C_ERR = new Color(0.93f, 0.42f, 0.38f, 1f);       // 错误标红

    private Text _resourceText;
    private GameObject _panelRoot;
    private string _openFacility;   // null = 大厅

    // 灵魂提取装置（设施③）—— 全屏三栏：中选魂 / 右已选 / 左卡池
    private readonly System.Random _rng = new System.Random();
    private string _lastDrawText;       // 上一批提取结果（面板关闭不丢）
    private bool _lastDrawWasRecipe;    // 上一批抽出了配方（显示「去工坊制作」）
    private bool _lastDrawWasPassive;   // 上一批只抽到被动（直链落被动页；混出落制卡页）
    private readonly List<string> _soulSelOrder = new List<string>();                       // 选择顺序
    private readonly Dictionary<string, int> _soulSelCount = new Dictionary<string, int>(); // 灵魂名 → 已选个数

    // 卡牌工坊（设施②）
    private WildernessCraftCatalog _craftCat;
    private int _forgeTab;          // 0=制卡 1=制骰 2=被动激活
    private string _lastForgeText;  // 动作状态行（面板关闭不丢）

    // 整装面板（出击门）—— ★B4：三页工作快照只活在本控制器，保存/出击才落盘
    private MetaWallet.LoadoutSnapshot _work;   // 面板工作快照（打开时从 PeekLoadout 预填）
    private int _loadoutTab;                    // 0=初始卡组 1=初始被动 2=背包
    private string _loadoutStatus;              // 状态行文案（保存/出击反馈）
    private bool _loadoutStatusError;           // 状态行是否标红
    private bool _confirmDeployOpen;            // 出击二次确认弹窗是否打开

    private void Start()
    {
        EnsureSceneBasics();
        _craftCat = WildernessCraftCatalog.Load();
        BuildHall();
        Refresh();

        // ★2026-09-14 用户决策：每次来到藏身处 → 自动保存到「当前存档位」。
        //   存档位的选择 / 清空界面在开发者面板（F9）里，这里只负责落盘。
        MetaWallet.Flush();
    }

    // ------------------------------------------------------------------
    // 场景基础设施兜底（确保 2D 场景能跑）
    // ------------------------------------------------------------------

    private void EnsureSceneBasics()
    {
        if (Camera.main == null)
        {
            GameObject cam = new GameObject("Main Camera", typeof(Camera));
            cam.tag = "MainCamera";
            Camera c = cam.GetComponent<Camera>();
            c.clearFlags = CameraClearFlags.SolidColor;
            c.backgroundColor = C_BG;
            c.orthographic = true;
        }

        if (Object.FindObjectOfType<UnityEngine.EventSystems.EventSystem>() == null)
        {
            GameObject es = new GameObject("EventSystem",
                typeof(UnityEngine.EventSystems.EventSystem),
                typeof(UnityEngine.EventSystems.StandaloneInputModule));
        }
    }

    private Canvas EnsureCanvas()
    {
        Canvas canvas = Object.FindObjectOfType<Canvas>();
        if (canvas != null) return canvas;

        GameObject go = new GameObject("Canvas", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
        canvas = go.GetComponent<Canvas>();
        canvas.renderMode = RenderMode.ScreenSpaceOverlay;
        CanvasScaler scaler = go.GetComponent<CanvasScaler>();
        scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
        scaler.referenceResolution = new Vector2(1280, 720);
        scaler.matchWidthOrHeight = 0.5f;
        return canvas;
    }

    // ------------------------------------------------------------------
    // 大厅
    // ------------------------------------------------------------------

    private void BuildHall()
    {
        Canvas canvas = EnsureCanvas();
        Transform root = canvas.transform;

        // 背景
        NewImage(root, "BG", Vector2.zero, Vector2.one, Vector2.zero, C_BG);

        // 标题
        NewText(root, "Title", "藏 身 处", 38, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -48f), new Vector2(600f, 52f));
        // ---- 4 个设施热点（2×2）----
        const float cx = 180f, ry1 = 78f, ry2 = -72f;
        Vector2 cardSize = new Vector2(330f, 132f);

        MakeCard(root, "CardSoul", new Vector2(-cx, ry1), cardSize,
            "灵魂提取装置", C_BRASS, () => OpenFacility("soul"));
        MakeCard(root, "CardForge", new Vector2(cx, ry1), cardSize,
            "卡牌工坊", C_BRASS, () => OpenFacility("forge"));
        MakeCard(root, "CardEquip", new Vector2(-cx, ry2), cardSize,
            "装备区", C_BRASS, () => OpenFacility("equip"));
        MakeCard(root, "CardStore", new Vector2(cx, ry2), cardSize,
            "仓 库", C_BRASS, () => OpenFacility("store"));

        // ---- 出击门 ----
        MakeButton(root, "BtnDeploy", "出　击", new Vector2(0f, -212f),
            new Vector2(440f, 66f), C_BRASS, C_BG, OnDeploy, 26);
        // ---- 常驻资源条 ----
        GameObject resPanel = NewImage(root, "ResPanel",
            new Vector2(0.5f, 0f), new Vector2(0.5f, 0f), new Vector2(0f, 34f), C_PANEL,
            new Vector2(980f, 44f));
        _resourceText = NewText(resPanel.transform, "Res", "", 19, TextAnchor.MiddleCenter, C_CREAM,
            new Vector2(0.5f, 0.5f), Vector2.zero, new Vector2(950f, 34f));
    }

    private Button MakeCard(Transform parent, string name, Vector2 pos, Vector2 size,
        string title, Color accent, UnityEngine.Events.UnityAction onClick)
    {
        GameObject card = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button));
        card.transform.SetParent(parent, false);
        RectTransform rt = card.GetComponent<RectTransform>();
        rt.anchorMin = rt.anchorMax = rt.pivot = new Vector2(0.5f, 0.5f);
        rt.anchoredPosition = pos;
        rt.sizeDelta = size;

        Image img = card.GetComponent<Image>();
        img.color = C_CARD;
        Button btn = card.GetComponent<Button>();
        btn.targetGraphic = img;
        btn.transition = Selectable.Transition.ColorTint;
        btn.onClick.AddListener(onClick);

        // 顶部强调条（一眼区分"这是设施"）
        NewImage(card.transform, "Accent", new Vector2(0.5f, 1f), new Vector2(0.5f, 1f),
            new Vector2(0f, -8f), accent, new Vector2(size.x - 28f, 4f));

        NewText(card.transform, "Title", title, 23, TextAnchor.MiddleCenter, C_CREAM,
            new Vector2(0.5f, 0.5f), new Vector2(0f, 4f), new Vector2(size.x - 30f, 32f));

        NewText(card.transform, "Open", "点击打开 ›", 14, TextAnchor.LowerRight, accent,
            new Vector2(1f, 0f), new Vector2(-14f, 10f), new Vector2(140f, 22f));

        return btn;
    }

    private Button MakeButton(Transform parent, string name, string label, Vector2 pos,
        Vector2 size, Color bgColor, Color textColor, UnityEngine.Events.UnityAction action, int fontSize = 20)
    {
        GameObject b = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button));
        b.transform.SetParent(parent, false);
        RectTransform rt = b.GetComponent<RectTransform>();
        rt.anchorMin = rt.anchorMax = rt.pivot = new Vector2(0.5f, 0.5f);
        rt.anchoredPosition = pos;
        rt.sizeDelta = size;
        b.GetComponent<Image>().color = bgColor;
        Button btn = b.GetComponent<Button>();
        btn.targetGraphic = b.GetComponent<Image>();
        btn.transition = Selectable.Transition.ColorTint;
        btn.onClick.AddListener(action);

        GameObject txt = new GameObject("Label", typeof(RectTransform), typeof(Text));
        txt.transform.SetParent(b.transform, false);
        RectTransform trt = txt.GetComponent<RectTransform>();
        trt.anchorMin = Vector2.zero;
        trt.anchorMax = Vector2.one;
        trt.sizeDelta = Vector2.zero;
        Text t = txt.GetComponent<Text>();
        t.text = label;
        t.fontSize = fontSize;
        t.alignment = TextAnchor.MiddleCenter;
        t.color = textColor;
        if (t.font == null) t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");

        return btn;
    }

    private GameObject NewImage(Transform parent, string name, Vector2 anchor, Vector2 anchorMax,
        Vector2 pos, Color color, Vector2? size = null)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Image));
        go.transform.SetParent(parent, false);
        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = anchor;
        rt.anchorMax = anchorMax;
        rt.pivot = anchor;
        rt.anchoredPosition = pos;
        if (size.HasValue) rt.sizeDelta = size.Value;
        go.GetComponent<Image>().color = color;
        return go;
    }

    private Text NewText(Transform parent, string name, string text, int fontSize, TextAnchor align, Color color,
        Vector2 anchor, Vector2 pos, Vector2 size)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Text));
        go.transform.SetParent(parent, false);
        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = anchor;
        rt.anchorMax = anchor;
        rt.pivot = anchor;
        rt.anchoredPosition = pos;
        rt.sizeDelta = size;
        Text t = go.GetComponent<Text>();
        t.text = text;
        t.fontSize = fontSize;
        t.alignment = align;
        t.color = color;
        if (t.font == null) t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        return t;
    }

    /// <summary>面板正文：整块拉伸 + 自动换行 + 溢出可见（左对齐长文用）。</summary>
    private Text NewBodyText(Transform parent, string name, string text, float padTop, float padBottom, float padX, int fontSize = 17)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Text));
        go.transform.SetParent(parent, false);
        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = Vector2.zero;
        rt.anchorMax = Vector2.one;
        rt.pivot = new Vector2(0.5f, 0.5f);
        rt.offsetMin = new Vector2(padX, padBottom);
        rt.offsetMax = new Vector2(-padX, -padTop);
        Text t = go.GetComponent<Text>();
        t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        t.text = text;
        t.fontSize = fontSize;
        t.alignment = TextAnchor.UpperLeft;
        t.color = C_CREAM;
        t.horizontalOverflow = HorizontalWrapMode.Wrap;
        t.verticalOverflow = VerticalWrapMode.Overflow;
        t.lineSpacing = 1.25f;
        return t;
    }

    // ------------------------------------------------------------------
    // 灵魂提取装置（设施③）—— 滚动清单 + 抽取
    // ------------------------------------------------------------------

    /// <summary>滚动列表：返回 content（往它下面塞行）。行高固定 44，行自身按 sizeDelta 排版。</summary>
    private RectTransform MakeScrollList(Transform parent, Vector2 pos, Vector2 size)
    {
        // Viewport 带一张全透明 Image：行与行之间的空隙也能接滚轮 / 拖动
        GameObject vp = new GameObject("Viewport", typeof(RectTransform), typeof(Image), typeof(RectMask2D));
        vp.transform.SetParent(parent, false);
        RectTransform vrt = vp.GetComponent<RectTransform>();
        vrt.anchorMin = vrt.anchorMax = vrt.pivot = new Vector2(0.5f, 0.5f);
        vrt.anchoredPosition = pos;
        vrt.sizeDelta = size;
        vp.GetComponent<Image>().color = new Color(0f, 0f, 0f, 0f);

        GameObject content = new GameObject("Content", typeof(RectTransform), typeof(VerticalLayoutGroup), typeof(ContentSizeFitter));
        content.transform.SetParent(vp.transform, false);
        RectTransform crt = content.GetComponent<RectTransform>();
        crt.anchorMin = new Vector2(0f, 1f);
        crt.anchorMax = new Vector2(1f, 1f);
        crt.pivot = new Vector2(0.5f, 1f);
        crt.anchoredPosition = Vector2.zero;
        crt.sizeDelta = new Vector2(0f, 44f);

        VerticalLayoutGroup vlg = content.GetComponent<VerticalLayoutGroup>();
        vlg.childControlWidth = false;
        vlg.childControlHeight = false;
        vlg.childForceExpandWidth = false;
        vlg.childForceExpandHeight = false;
        vlg.spacing = 6f;
        vlg.padding = new RectOffset(0, 0, 0, 0);

        ContentSizeFitter fitter = content.GetComponent<ContentSizeFitter>();
        fitter.horizontalFit = ContentSizeFitter.FitMode.Unconstrained;
        fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;

        ScrollRect sr = vp.AddComponent<ScrollRect>();
        sr.horizontal = false;
        sr.vertical = true;
        sr.movementType = ScrollRect.MovementType.Clamped;
        sr.scrollSensitivity = 24f;
        sr.viewport = vrt;
        sr.content = crt;
        return crt;
    }

    /// <summary>中间栏灵魂行：点 = 选中 1 个；抽干的置灰不可点。</summary>
    private void MakeSoulRow(RectTransform content, EnemyData enemy, string soulName, int owned)
    {
        int remain = SoulExtraction.PoolRemaining(enemy);
        int total = SoulExtraction.PoolTotal(enemy);
        bool drained = remain <= 0;
        int sel = SoulSelCountOf(soulName);
        int cap = Mathf.Min(owned, remain);
        bool canAdd = !drained && sel < cap;

        GameObject row = new GameObject("Row_" + soulName, typeof(RectTransform), typeof(Image), typeof(Button));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.sizeDelta = new Vector2(0f, 44f);
        rt.anchoredPosition = Vector2.zero;
        Image img = row.GetComponent<Image>();
        img.color = drained ? new Color(0.13f, 0.11f, 0.08f, 1f)
                            : (sel > 0 ? new Color(0.11f, 0.20f, 0.18f, 1f) : C_CARD);

        Button btn = row.GetComponent<Button>();
        btn.targetGraphic = img;
        btn.transition = Selectable.Transition.ColorTint;
        btn.interactable = canAdd;
        if (canAdd)
        {
            EnemyData en = enemy;
            string sn = soulName;
            btn.onClick.AddListener(() => SelectSoul(en, sn));
        }

        if (sel > 0)
            NewImage(row.transform, "Sel", new Vector2(0f, 0.5f), new Vector2(0f, 0.5f),
                new Vector2(2f, 0f), C_BRASS, new Vector2(4f, 32f));

        NewText(row.transform, "Name", soulName + " ×" + owned, 17, TextAnchor.MiddleLeft,
            drained ? C_DIM : C_CREAM, new Vector2(0f, 0.5f), new Vector2(18f, 0f), new Vector2(200f, 30f));

        string right = drained ? "已抽干 · 纯资源"
            : ("池 " + remain + "/" + total + (sel > 0 ? " · 已选" + sel : " · 选择 ›") +
               (sel >= cap ? " · 已满" : ""));
        NewText(row.transform, "Right", right, 15, TextAnchor.MiddleRight, drained ? C_DIM : C_BRASS,
            new Vector2(1f, 0.5f), new Vector2(-18f, 0f), new Vector2(200f, 30f));
    }

    /// <summary>工坊/仓库通用清单行：点整行 = 动作；active=false 置灰不可点。</summary>
    private void MakeListRow(RectTransform content, string name, string right, bool active,
        UnityEngine.Events.UnityAction onClick)
    {
        GameObject row = new GameObject("Row", typeof(RectTransform), typeof(Image), typeof(Button));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.sizeDelta = new Vector2(0f, 44f);
        rt.anchoredPosition = Vector2.zero;
        Image img = row.GetComponent<Image>();
        img.color = active ? C_CARD : new Color(0.13f, 0.11f, 0.08f, 1f);
        Button btn = row.GetComponent<Button>();
        btn.targetGraphic = img;
        btn.transition = Selectable.Transition.ColorTint;
        btn.interactable = active && onClick != null;
        if (btn.interactable) btn.onClick.AddListener(onClick);

        Text lt = NewText(row.transform, "Name", name, 17, TextAnchor.MiddleLeft, active ? C_CREAM : C_DIM,
            new Vector2(0f, 0.5f), new Vector2(18f, 0f), new Vector2(400f, 30f));
        lt.horizontalOverflow = HorizontalWrapMode.Overflow;
        NewText(row.transform, "Right", right, 16, TextAnchor.MiddleRight, active ? C_BRASS : C_DIM,
            new Vector2(1f, 0.5f), new Vector2(-18f, 0f), new Vector2(320f, 30f));
    }

    /// <summary>清单里的小节标题行（不可点）。宽度默认给 740 宽列表用。</summary>
    private void MakeSectionRow(RectTransform content, string label, float width = 680f)
    {
        GameObject row = new GameObject("Section", typeof(RectTransform));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.sizeDelta = new Vector2(0f, 26f);
        rt.anchoredPosition = Vector2.zero;
        NewText(row.transform, "Label", label, 14, TextAnchor.MiddleLeft, C_DIM,
            new Vector2(0f, 0.5f), new Vector2(14f, 0f), new Vector2(width, 22f));
    }

    // ------------------------------------------------------------------
    // 卡牌工坊（设施②）—— 制卡 / 制骰 / 被动激活 三页签
    // ------------------------------------------------------------------

    private void BuildForgePanel(GameObject panel)
    {
        NewText(panel.transform, "Title", "卡牌工坊", 26, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -30f), new Vector2(740f, 36f));

        string[] tabs = { "制卡", "制骰", "被动激活" };
        for (int i = 0; i < tabs.Length; i++)
        {
            int idx = i;
            MakeButton(panel.transform, "Tab" + i, tabs[i],
                new Vector2(-250f + i * 172f, 158f), new Vector2(160f, 34f),
                _forgeTab == i ? C_BRASS : C_PANEL, _forgeTab == i ? C_BG : C_CREAM,
                () => { _forgeTab = idx; RebuildPanel(); }, 17);
        }

        NewText(panel.transform, "Status",
            string.IsNullOrEmpty(_lastForgeText) ? "" : _lastForgeText,
            15, TextAnchor.MiddleLeft, C_DIM, new Vector2(0.5f, 0.5f), new Vector2(0f, 120f), new Vector2(740f, 24f));

        RectTransform content = MakeScrollList(panel.transform, new Vector2(0f, -60f), new Vector2(740f, 256f));
        if (_forgeTab == 0) FillForgeCardTab(content);
        else if (_forgeTab == 1) FillForgeDiceTab(content);
        else FillForgePassiveTab(content);

        MakeButton(panel.transform, "BtnClose", "关闭", new Vector2(0f, -215f),
            new Vector2(200f, 50f), C_PANEL, C_CREAM, ClosePanel, 20);
        Debug.Log("[藏身处] 工坊面板：页签 " + _forgeTab + "（配方 " + MetaWallet.UnlockedRecipes.Count +
                  "｜卡存 " + MetaWallet.SumOf(MetaWallet.CraftedCards) + "｜激活 " + MetaWallet.ActivePassives.Count + "）");
    }

    private void FillForgeCardTab(RectTransform content)
    {
        WorkshopConfig cfg = WorkshopConfig.Load();
        int shown = 0;
        if (_craftCat != null)
        {
            foreach (string rid in MetaWallet.UnlockedRecipes)
            {
                CardData card = _craftCat.CardFor(rid);
                if (card == null) continue;                       // 被动配方 / 未知 → 跳过
                string family = _craftCat.FamilyOfCard(rid);
                System.Collections.Generic.List<string> mats = _craftCat.MaterialNamesOf(family);
                int shardNeed = Workshop.ShardCost(card, cfg);
                int matNeed = Workshop.MaterialCost(card, cfg);
                bool can = MetaWallet.MaterialCountOf(MetaWallet.ShardMaterialName) >= shardNeed
                        && MetaWallet.MaterialCountAnyOf(mats) >= matNeed;
                string right = "碎片×" + shardNeed + " " + family + "材×" + matNeed + (can ? "　制作 ›" : "　材料不足");
                string cardID = rid;
                MakeListRow(content, card.cardName + " · " + RarityText(card.rarity), right, can,
                    () => { _lastForgeText = DoCraftCard(cardID); Refresh(); });
                shown++;
            }
        }
        if (shown == 0)
        {
            MakeSectionRow(content, "还没有可制作的配方");
            return;
        }

        MakeSectionRow(content, "—— 卡牌库存 ——");
        bool any = false;
        foreach (MetaWallet.NamedStack s in MetaWallet.CraftedCards)
        {
            if (s == null || s.count <= 0) continue;
            CardData card = _craftCat != null ? _craftCat.CardFor(s.name) : null;
            string nm = card != null ? card.cardName : s.name;
            string cardID = s.name;
            bool canScrap = card != null;
            string right = canScrap ? ("拆解 +" + Workshop.ScrapShardsOf(card, cfg) + " 碎片 ›") : "目录缺行";
            MakeListRow(content, nm + " ×" + s.count, right, canScrap,
                () => { _lastForgeText = DoScrapCard(cardID); Refresh(); });
            any = true;
        }
        if (!any) MakeSectionRow(content, "暂无卡牌");
    }

    private void FillForgeDiceTab(RectTransform content)
    {
        WorkshopConfig cfg = WorkshopConfig.Load();
        int salvage = MetaWallet.MaterialCountOf(MetaWallet.SalvageName);

        MakeSectionRow(content, "—— 制骰 · 物资 " + salvage + " ——");
        bool anyRecipe = false;
        if (cfg.diceRecipes != null)
        {
            foreach (WorkshopConfig.DiceRecipe r in cfg.diceRecipes)
            {
                if (r == null || r.dice == null) continue;
                bool can = salvage >= r.salvageCost;
                string nm = r.dice.itemName;
                MakeListRow(content, nm, "物资×" + r.salvageCost + (can ? "　制作 ›" : "　材料不足"), can,
                    () => { _lastForgeText = DoCraftDice(nm); Refresh(); });
                anyRecipe = true;
            }
        }
        if (!anyRecipe) MakeSectionRow(content, "暂无制骰配方");

        MakeSectionRow(content, "—— 实物库 ——");
        bool anyStored = false;
        foreach (MetaWallet.NamedStack s in MetaWallet.StoredItems)
        {
            if (s == null || s.count <= 0) continue;
            MakeSectionRow(content, "　" + s.name + " ×" + s.count);
            anyStored = true;
        }
        if (!anyStored) MakeSectionRow(content, "　暂无");

        MakeSectionRow(content, "—— 怪材兑物资 · 族材 1 / 独特 " + cfg.uniqueMaterialToSalvage + " ——");
        bool anyMat = false;
        if (_craftCat != null)
        {
            foreach (MetaWallet.NamedStack s in MetaWallet.MaterialStacks)
            {
                if (s == null || s.count <= 0) continue;
                int rate = Workshop.SalvageRate(s.name, _craftCat, cfg);
                if (rate <= 0) continue;                       // 碎片/物资/未分类 → 不列
                string nm = s.name;
                MakeListRow(content, nm + " ×" + s.count, "兑 " + rate + " 物资 ›", true,
                    () => { _lastForgeText = DoExchange(nm); Refresh(); });
                anyMat = true;
            }
        }
        if (!anyMat) MakeSectionRow(content, "没有可兑的怪材");
    }

    private void FillForgePassiveTab(RectTransform content)
    {
        WorkshopConfig cfg = WorkshopConfig.Load();
        int shown = 0;
        if (_craftCat != null)
        {
            foreach (string rid in MetaWallet.UnlockedRecipes)
            {
                PassiveData p = _craftCat.PassiveFor(rid);
                if (p == null || MetaWallet.IsPassiveActive(rid)) continue;
                string family = _craftCat.FamilyOfPassive(rid);
                System.Collections.Generic.List<string> mats = _craftCat.MaterialNamesOf(family);
                int need = Workshop.ActivationCost(p, cfg);
                bool can = MetaWallet.MaterialCountAnyOf(mats) >= need;
                string right = family + "材×" + need + (can ? "　激活 ›" : "　材料不足");
                string pn = rid;
                MakeListRow(content, p.passiveName + " · 价值" + p.value + " · " + RarityText(p.rarity), right, can,
                    () => { _lastForgeText = DoActivatePassive(pn); Refresh(); });
                shown++;
            }
        }
        if (shown == 0)
            MakeSectionRow(content, "还没有待激活的被动配方");

        MakeSectionRow(content, "—— 已激活 ——");
        bool any = false;
        foreach (string name in MetaWallet.ActivePassives)
        {
            PassiveData p = _craftCat != null ? _craftCat.PassiveFor(name) : null;
            MakeSectionRow(content, "　" + name + (p != null ? " · 价值" + p.value : ""));
            any = true;
        }
        if (!any) MakeSectionRow(content, "　暂无");
    }

    private string DoCraftCard(string cardID)
    {
        Workshop.Result r = Workshop.TryCraftCard(cardID, _craftCat, WorkshopConfig.Load());
        if (!r.ok) return r.reason;
        Debug.Log("[藏身处] 制卡：" + r.label);
        return "制成「" + r.label + "」×1 · 库存 " + MetaWallet.CraftedCardCount(cardID);
    }

    private string DoScrapCard(string cardID)
    {
        Workshop.Result r = Workshop.TryScrapCard(cardID, _craftCat, WorkshopConfig.Load());
        if (!r.ok) return r.reason;
        Debug.Log("[藏身处] 拆解：" + r.label + " +" + r.amount + " 碎片");
        return "拆解「" + r.label + "」→ 碎片 +" + r.amount;
    }

    private string DoActivatePassive(string passiveName)
    {
        Workshop.Result r = Workshop.TryActivatePassive(passiveName, _craftCat, WorkshopConfig.Load());
        if (!r.ok) return r.reason;
        Debug.Log("[藏身处] 被动激活：" + r.label);
        return "激活「" + r.label + "」，永久生效";
    }

    private string DoCraftDice(string diceItemName)
    {
        Workshop.Result r = Workshop.TryCraftDice(diceItemName, WorkshopConfig.Load());
        if (!r.ok) return r.reason;
        Debug.Log("[藏身处] 制骰：" + r.label);
        return "制成骰子「" + r.label + "」×1 · 实物库 " + MetaWallet.StoredItemCount(diceItemName);
    }

    private string DoExchange(string materialName)
    {
        Workshop.Result r = Workshop.TryExchangeSalvage(materialName, _craftCat, WorkshopConfig.Load());
        if (!r.ok) return r.reason;
        Debug.Log("[藏身处] 兑物资：" + r.label + " +" + r.amount);
        return "「" + r.label + "」→ 物资 +" + r.amount;
    }

    // ------------------------------------------------------------------
    // 仓库（设施④）—— 七分区只读（设计稿 §4）
    // ------------------------------------------------------------------

    private void BuildStorePanel(GameObject panel)
    {
        NewText(panel.transform, "Title", "仓库 · 跨局库存", 26, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -30f), new Vector2(740f, 36f));

        RectTransform content = MakeScrollList(panel.transform, new Vector2(0f, 5f), new Vector2(740f, 380f));

        // ① 怪材（按家族）＋ ② 独特素材 ＋ ③ 通用资源 ＋ ④ 灵魂
        MakeSectionRow(content, "—— 怪材 ——");
        bool anyFam = false;
        if (_craftCat != null)
        {
            foreach (WildernessCraftCatalog.FamilyRow f in _craftCat.families)
            {
                if (f == null) continue;
                System.Text.StringBuilder sb = new System.Text.StringBuilder(f.family + "　");
                bool owned = false;
                foreach (ItemData m in f.materials)
                {
                    if (m == null) continue;
                    int c = MetaWallet.MaterialCountOf(m.itemName);
                    if (c <= 0) continue;
                    sb.Append(m.itemName).Append('×').Append(c).Append("　");
                    owned = true;
                }
                if (owned) { MakeSectionRow(content, "　" + sb.ToString().TrimEnd()); anyFam = true; }
            }
            if (!anyFam) MakeSectionRow(content, "　暂无");

            System.Text.StringBuilder uniq = new System.Text.StringBuilder();
            foreach (ItemData m in _craftCat.uniqueMaterials)
            {
                if (m == null) continue;
                int c = MetaWallet.MaterialCountOf(m.itemName);
                if (c > 0) uniq.Append(m.itemName).Append('×').Append(c).Append("　");
            }
            MakeSectionRow(content, "—— 独特素材 ——");
            MakeSectionRow(content, "　" + (uniq.Length > 0 ? uniq.ToString().TrimEnd() : "暂无"));
        }

        MakeSectionRow(content, "—— 通用资源 ——");
        MakeSectionRow(content, "　卡牌碎片 ×" + MetaWallet.MaterialCountOf(MetaWallet.ShardMaterialName) +
                                "　物资 ×" + MetaWallet.MaterialCountOf(MetaWallet.SalvageName));

        MakeSectionRow(content, "—— 灵魂 ——");
        bool anySoul = false;
        foreach (MetaWallet.NamedStack s in MetaWallet.SoulStacks)
        {
            if (s == null || s.count <= 0) continue;
            MakeSectionRow(content, "　" + s.name + " ×" + s.count);
            anySoul = true;
        }
        if (!anySoul) MakeSectionRow(content, "　暂无");

        // ⑤ 配方 ＋ ⑥ 卡牌库存 ＋ ⑦ 被动 ＋ ⑧ 实物
        MakeSectionRow(content, "—— 配方 · 已抽出 ——");
        bool anyR = false;
        foreach (string rid in MetaWallet.UnlockedRecipes)
        {
            CardData card = _craftCat != null ? _craftCat.CardFor(rid) : null;
            if (card != null)
            {
                MakeSectionRow(content, "　卡：" + card.cardName + " · " + (_craftCat.FamilyOfCard(rid) ?? "?") +
                                        " · 库存 " + MetaWallet.CraftedCardCount(rid) + "，可重复制作");
                anyR = true;
                continue;
            }
            PassiveData p = _craftCat != null ? _craftCat.PassiveFor(rid) : null;
            if (p != null)
            {
                MakeSectionRow(content, "　被动：" + p.passiveName + " · 价值" + p.value +
                                        (MetaWallet.IsPassiveActive(rid) ? " · 已激活" : " · 未激活"));
                anyR = true;
            }
        }
        if (!anyR) MakeSectionRow(content, "　暂无");

        System.Text.StringBuilder stockSb = new System.Text.StringBuilder();
        foreach (MetaWallet.NamedStack s in MetaWallet.CraftedCards)
        {
            if (s == null || s.count <= 0) continue;
            CardData card = _craftCat != null ? _craftCat.CardFor(s.name) : null;
            stockSb.Append(card != null ? card.cardName : s.name).Append('×').Append(s.count).Append("　");
        }
        MakeSectionRow(content, "—— 卡牌库存 ——");
        MakeSectionRow(content, "　" + (stockSb.Length > 0 ? stockSb.ToString().TrimEnd() : "暂无"));

        MakeSectionRow(content, "—— 被动 · 已激活 ——");
        MakeSectionRow(content, "　" + (MetaWallet.ActivePassives.Count > 0
            ? string.Join("　", System.Linq.Enumerable.ToArray(MetaWallet.ActivePassives)) : "暂无"));

        MakeSectionRow(content, "—— 实物 ——");
        MakeSectionRow(content, "　" + (MetaWallet.StoredItems.Count > 0 ? MetaWallet.SummaryOf(MetaWallet.StoredItems) : "暂无"));

        MakeButton(panel.transform, "BtnClose", "关闭", new Vector2(0f, -215f),
            new Vector2(200f, 50f), C_PANEL, C_CREAM, ClosePanel, 20);
        Debug.Log("[藏身处] 仓库面板：材料 " + MetaWallet.MaterialSummary() + "｜灵魂 " + MetaWallet.SoulSummary());
    }

    // ------------------------------------------------------------------
    // 装备区（设施⑤）—— 只读查看：已激活被动 ＋ 全部配方（2026-09-17 用户裁定，设计稿 §8）
    // ------------------------------------------------------------------

    private void BuildEquipPanel(GameObject panel)
    {
        NewText(panel.transform, "Title", "装备区", 26, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -30f), new Vector2(740f, 36f));

        RectTransform content = MakeScrollList(panel.transform, new Vector2(0f, 2f), new Vector2(740f, 356f));

        // ① 已激活被动（名称 / 价值点 / 完整描述）
        MakeSectionRow(content, "—— 被动 · 已激活 ——");
        bool anyP = false;
        if (_craftCat != null)
        {
            foreach (string pn in MetaWallet.ActivePassives)
            {
                PassiveData p = _craftCat.PassiveFor(pn);
                if (p == null) continue;
                MakePassiveInfoRow(content, p.passiveName + " · 价值" + p.value,
                    string.IsNullOrEmpty(p.description) ? "暂无描述" : p.description);
                anyP = true;
            }
        }
        if (!anyP) MakeSectionRow(content, "　暂无");

        // ② 全部配方（卡配方标 可制作/材料不足；被动配方标 已激活/未激活）
        MakeSectionRow(content, "—— 配方 · 已抽出 ——");
        bool anyR = false;
        if (_craftCat != null)
        {
            WorkshopConfig cfg = WorkshopConfig.Load();
            foreach (string rid in MetaWallet.UnlockedRecipes)
            {
                CardData card = _craftCat.CardFor(rid);
                if (card != null)
                {
                    string family = _craftCat.FamilyOfCard(rid);
                    var mats = _craftCat.MaterialNamesOf(family);
                    bool can = MetaWallet.MaterialCountOf(MetaWallet.ShardMaterialName) >= Workshop.ShardCost(card, cfg)
                            && MetaWallet.MaterialCountAnyOf(mats) >= Workshop.MaterialCost(card, cfg);
                    MakeSectionRow(content, "　卡：" + card.cardName + " · " + (can ? "可制作" : "材料不足"));
                    anyR = true;
                    continue;
                }
                PassiveData p = _craftCat.PassiveFor(rid);
                if (p != null)
                {
                    MakeSectionRow(content, "　被动：" + p.passiveName + " · " +
                                            (MetaWallet.IsPassiveActive(rid) ? "已激活" : "未激活"));
                    anyR = true;
                }
            }
        }
        if (!anyR) MakeSectionRow(content, "　暂无");

        MakeButton(panel.transform, "BtnClose", "关闭", new Vector2(0f, -215f),
            new Vector2(200f, 50f), C_PANEL, C_CREAM, ClosePanel, 20);
        Debug.Log("[藏身处] 装备区面板：已激活被动 " + MetaWallet.ActivePassives.Count +
                  " 条｜配方 " + MetaWallet.UnlockedRecipes.Count + " 条");
    }

    /// <summary>装备区被动行：上行名字+价值，下行完整描述（描述自动换行、行高自适应）。</summary>
    private void MakePassiveInfoRow(RectTransform content, string title, string desc)
    {
        GameObject row = new GameObject("PassiveRow", typeof(RectTransform), typeof(VerticalLayoutGroup), typeof(ContentSizeFitter));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.anchoredPosition = Vector2.zero;
        VerticalLayoutGroup vlg = row.GetComponent<VerticalLayoutGroup>();
        vlg.childForceExpandWidth = true;
        vlg.childForceExpandHeight = false;
        vlg.spacing = 0f;
        vlg.padding = new RectOffset(14, 8, 2, 4);
        ContentSizeFitter csf = row.GetComponent<ContentSizeFitter>();
        csf.verticalFit = ContentSizeFitter.FitMode.PreferredSize;
        csf.horizontalFit = ContentSizeFitter.FitMode.Unconstrained;

        NewText(row.transform, "Title", title, 14, TextAnchor.MiddleLeft, C_CREAM,
            new Vector2(0f, 1f), Vector2.zero, new Vector2(680f, 22f));

        Text t = NewText(row.transform, "Desc", desc, 12, TextAnchor.UpperLeft, C_DIM,
            new Vector2(0f, 1f), Vector2.zero, new Vector2(680f, 40f));
        t.horizontalOverflow = HorizontalWrapMode.Wrap;
        t.verticalOverflow = VerticalWrapMode.Overflow;
        ContentSizeFitter tfit = t.gameObject.AddComponent<ContentSizeFitter>();
        tfit.verticalFit = ContentSizeFitter.FitMode.PreferredSize;
        tfit.horizontalFit = ContentSizeFitter.FitMode.Unconstrained;
    }

    // ------------------------------------------------------------------
    // 整装面板（出击门）—— 三页：初始卡组 / 初始被动 / 背包（★B4，2026-09-17，设计稿 §5）
    // ------------------------------------------------------------------

    private void OpenLoadout()
    {
        _work = MetaWallet.PeekLoadout();
        _loadoutStatus = null;
        _loadoutStatusError = false;
        _confirmDeployOpen = false;
        _openFacility = "loadout";
        RebuildPanel();
    }

    private void BuildLoadoutPanel(GameObject panel)
    {
        NewText(panel.transform, "Title", "整 装", 28, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -30f), new Vector2(400f, 40f));

        // 三页签
        string[] tabs = { "初始卡组", "初始被动", "背　包" };
        for (int i = 0; i < tabs.Length; i++)
        {
            int idx = i;
            MakeButton(panel.transform, "Tab" + i, tabs[i],
                new Vector2(-330f + i * 330f, 245f), new Vector2(300f, 40f),
                _loadoutTab == i ? C_BRASS : C_PANEL, _loadoutTab == i ? C_BG : C_CREAM,
                () => { _loadoutTab = idx; _loadoutStatus = null; _loadoutStatusError = false; RebuildPanel(); }, 20);
        }

        // 状态行（保存/出击反馈）
        NewText(panel.transform, "Status",
            _loadoutStatus != null ? _loadoutStatus : "保存不扣库存 · 出击扣库存进图",
            15, TextAnchor.MiddleCenter, _loadoutStatusError ? C_ERR : C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(0f, 205f), new Vector2(1100f, 24f));

        // 内容区（三页切一）
        if (_loadoutTab == 0) FillLoadoutDeckPage(panel);
        else if (_loadoutTab == 1) FillLoadoutPassivePage(panel);
        else FillLoadoutBagPage(panel);

        // 底栏：返回 / 保存 / 出击
        MakeButton(panel.transform, "BtnBack", "返　回", new Vector2(-500f, -280f),
            new Vector2(200f, 56f), C_PANEL, C_CREAM, ClosePanel, 20);
        MakeButton(panel.transform, "BtnSave", "保　存", new Vector2(-150f, -280f),
            new Vector2(240f, 56f), C_PANEL, C_CREAM, OnSaveLoadout, 20);
        MakeButton(panel.transform, "BtnGo", "出　击", new Vector2(160f, -280f),
            new Vector2(240f, 56f), C_BRASS, C_BG, OnDeployClick, 22);

        if (_confirmDeployOpen) BuildDeployConfirm(panel);

        Debug.Log("[藏身处] 整装面板：页签 " + _loadoutTab +
                  "｜卡 " + (_work != null && _work.cards != null ? _work.cards.Count : 0) +
                  "｜被动 " + (_work != null && _work.passives != null ? _work.passives.Count : 0) +
                  "｜骰 " + StackTotal(_work != null ? _work.dice : null) +
                  "｜消耗 " + StackTotal(_work != null ? _work.consumables : null));
    }

    // ---- 页一：初始卡组 ----

    private void FillLoadoutDeckPage(GameObject panel)
    {
        if (_work == null) return;

        // 左：卡牌库存（点行带出 1 张）
        NewText(panel.transform, "HdrStock", "卡牌库存 · 点行带出 1 张", 18, TextAnchor.MiddleLeft, C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(-330f, 185f), new Vector2(560f, 26f));
        RectTransform stockList = MakeScrollList(panel.transform, new Vector2(-330f, 5f), new Vector2(560f, 340f));
        bool anyStock = false;
        foreach (MetaWallet.NamedStack s in MetaWallet.CraftedCards)
        {
            if (s == null || s.count <= 0) continue;
            CardData card = _craftCat != null ? _craftCat.CardFor(s.name) : null;
            MakeDeckStockRow(stockList, s, card);
            anyStock = true;
        }
        if (!anyStock) MakeSectionRow(stockList, "卡牌库存为空", 520f);

        // 右上：固定初始卡组（与开局构建同读 DefaultDeckCatalog）
        DefaultDeckCatalog deckCat = DefaultDeckCatalog.Load();
        int fixedTotal = 0;
        if (deckCat != null && deckCat.entries != null)
            foreach (DefaultDeckCatalog.Entry e in deckCat.entries)
                if (e != null && e.count > 0) fixedTotal += e.count;
        NewText(panel.transform, "HdrFixed", "初始卡组 · 固定 " + fixedTotal + " 张", 18, TextAnchor.MiddleLeft, C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(340f, 185f), new Vector2(500f, 26f));
        RectTransform fixedList = MakeScrollList(panel.transform, new Vector2(340f, 115f), new Vector2(500f, 140f));
        if (deckCat != null && deckCat.entries != null && deckCat.entries.Count > 0)
        {
            foreach (DefaultDeckCatalog.Entry e in deckCat.entries)
            {
                if (e == null || e.card == null) continue;
                MakeSectionRow(fixedList, "　" + e.card.cardName + " ×" + e.count, 460f);
            }
        }
        else MakeSectionRow(fixedList, "　目录缺失", 460f);

        // 右下：自由栏位（已带出，点行退回）
        int taken = _work.cards != null ? _work.cards.Count : 0;
        NewText(panel.transform, "HdrFree", "自由栏位 · 带出 " + taken + "/" + MetaWallet.FreeDeckSlots, 18,
            TextAnchor.MiddleLeft, taken >= MetaWallet.FreeDeckSlots ? C_ERR : C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(340f, 30f), new Vector2(500f, 26f));
        RectTransform freeList = MakeScrollList(panel.transform, new Vector2(340f, -45f), new Vector2(500f, 120f));
        if (_work.cards != null && _work.cards.Count > 0)
        {
            foreach (string id in _work.cards) MakeFreeCardRow(freeList, id);
        }
        else MakeSectionRow(freeList, "　未带出", 460f);
    }

    private void MakeDeckStockRow(RectTransform content, MetaWallet.NamedStack stock, CardData card)
    {
        string cardID = stock.name;
        int taken = CardTakenCount(cardID);
        int remain = stock.count - taken;
        bool canTake = _work != null && _work.cards != null
                    && _work.cards.Count < MetaWallet.FreeDeckSlots && remain > 0;
        string right;
        if (canTake) right = "带出 ×" + taken + "　＋1 ›";
        else if (remain <= 0) right = "带出 ×" + taken + " · 无余量";
        else right = "带出 ×" + taken + " · 栏位已满";
        string cap = cardID;
        MakeListRow(content, (card != null ? card.cardName : cardID) + " ×" + stock.count +
                             " · " + (card != null ? RarityText(card.rarity) : "?"),
            right, canTake, () => { _work.cards.Add(cap); RebuildPanel(); });
    }

    private void MakeFreeCardRow(RectTransform content, string cardID)
    {
        CardData card = _craftCat != null ? _craftCat.CardFor(cardID) : null;
        string cap = cardID;
        MakeListRow(content, card != null ? card.cardName : cardID, "退回 ›", true,
            () => { _work.cards.Remove(cap); RebuildPanel(); });
    }

    // ---- 页二：初始被动（Σ价值预算 ≤ 上限） ----

    private void FillLoadoutPassivePage(GameObject panel)
    {
        if (_work == null) return;

        // 左：已激活被动（点行编入）
        NewText(panel.transform, "HdrPool", "已激活被动 · 点行编入", 18, TextAnchor.MiddleLeft, C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(-330f, 185f), new Vector2(560f, 26f));
        RectTransform poolList = MakeScrollList(panel.transform, new Vector2(-330f, 5f), new Vector2(560f, 340f));
        bool any = false;
        if (_craftCat != null)
        {
            foreach (string pn in MetaWallet.ActivePassives)
            {
                PassiveData p = _craftCat.PassiveFor(pn);
                if (p == null) continue;
                MakePassivePickRow(poolList, pn, p);
                any = true;
            }
        }
        if (!any) MakeSectionRow(poolList, "没有已激活被动", 520f);

        // 右：编队（点行卸下）+ Σ价值
        int value = PassiveValueTotal();
        bool over = value > MetaWallet.PassValueCap;
        NewText(panel.transform, "HdrTeam", "编队 · Σ价值 " + value + "/" + MetaWallet.PassValueCap, 18,
            TextAnchor.MiddleLeft, over ? C_ERR : C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(340f, 185f), new Vector2(500f, 26f));
        RectTransform teamList = MakeScrollList(panel.transform, new Vector2(340f, 5f), new Vector2(500f, 340f));
        if (_work.passives != null && _work.passives.Count > 0)
        {
            foreach (string pn in _work.passives)
            {
                PassiveData p = _craftCat != null ? _craftCat.PassiveFor(pn) : null;
                string cap = pn;
                MakeListRow(teamList, (p != null ? p.passiveName : pn) + (p != null ? " · 价值" + p.value : ""),
                    "卸下 ›", true, () => { _work.passives.Remove(cap); RebuildPanel(); });
            }
        }
        else MakeSectionRow(teamList, "　未编入", 460f);
    }

    private void MakePassivePickRow(RectTransform content, string pn, PassiveData p)
    {
        bool inTeam = _work != null && _work.passives != null && _work.passives.Contains(pn);
        bool canAdd = !inTeam && PassiveValueTotal() + p.value <= MetaWallet.PassValueCap;
        string cap = pn;
        MakeListRow(content, p.passiveName + " · 价值" + p.value + " · " + RarityText(p.rarity),
            inTeam ? "已编入" : (canAdd ? "编入 ›" : "超出预算"), canAdd,
            () => { _work.passives.Add(cap); RebuildPanel(); });
    }

    // ---- 页三：背包（骰子 ≤6 / 消耗品 ≤3） ----

    private void FillLoadoutBagPage(GameObject panel)
    {
        if (_work == null) return;
        HashSet<string> diceNames = DiceItemNames();

        // 上区：骰子
        int diceTotal = StackTotal(_work.dice);
        NewText(panel.transform, "HdrDice", "骰子 · 带出 " + diceTotal + "/" + Inventory.DiceCapacity, 18,
            TextAnchor.MiddleLeft, diceTotal >= Inventory.DiceCapacity ? C_ERR : C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(0f, 185f), new Vector2(900f, 26f));
        RectTransform diceList = MakeScrollList(panel.transform, new Vector2(0f, 100f), new Vector2(900f, 170f));
        bool anyDice = false;
        foreach (string nm in BagKindNames(diceNames, _work.dice))
        {
            MakeBagStepperRow(diceList, nm, MetaWallet.StoredItemCount(nm), Inventory.DiceCapacity, _work.dice);
            anyDice = true;
        }
        if (!anyDice) MakeSectionRow(diceList, "实物库没有骰子", 860f);

        // 下区：消耗品
        int conTotal = StackTotal(_work.consumables);
        NewText(panel.transform, "HdrCon", "消耗品 · 带出 " + conTotal + "/" + Inventory.ConsumableCapacity, 18,
            TextAnchor.MiddleLeft, conTotal >= Inventory.ConsumableCapacity ? C_ERR : C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(0f, 0f), new Vector2(900f, 26f));
        RectTransform conList = MakeScrollList(panel.transform, new Vector2(0f, -75f), new Vector2(900f, 150f));
        bool anyCon = false;
        foreach (string nm in BagKindNames(DiceNamesExcept(diceNames), _work.consumables))
        {
            MakeBagStepperRow(conList, nm, MetaWallet.StoredItemCount(nm), Inventory.ConsumableCapacity, _work.consumables);
            anyCon = true;
        }
        if (!anyCon) MakeSectionRow(conList, "实物库没有消耗品", 860f);

        NewText(panel.transform, "BagNote", "魂灯出击自动随行，占背包 1 格", 15, TextAnchor.MiddleCenter, C_DIM,
            new Vector2(0.5f, 0.5f), new Vector2(0f, -185f), new Vector2(900f, 24f));
    }

    /// <summary>实物里「除骰子外」的种类名（消耗品 = 实物库 − 制骰配方名）。</summary>
    private HashSet<string> DiceNamesExcept(HashSet<string> diceNames)
    {
        var set = new HashSet<string>();
        foreach (MetaWallet.NamedStack s in MetaWallet.StoredItems)
        {
            if (s == null || s.count <= 0 || string.IsNullOrEmpty(s.name)) continue;
            if (!diceNames.Contains(s.name)) set.Add(s.name);
        }
        if (_work != null && _work.consumables != null)
            foreach (MetaWallet.NamedStack s in _work.consumables)
                if (s != null && s.count > 0 && !string.IsNullOrEmpty(s.name) && !diceNames.Contains(s.name))
                    set.Add(s.name);
        return set;
    }

    /// <summary>某分区行清单：实物库存种类在前，工作快照里残留的种类补在后（库存被外部扣掉时还能退带出数）。</summary>
    private List<string> BagKindNames(HashSet<string> kindNames, List<MetaWallet.NamedStack> workStacks)
    {
        var names = new List<string>();
        foreach (MetaWallet.NamedStack s in MetaWallet.StoredItems)
        {
            if (s == null || s.count <= 0 || string.IsNullOrEmpty(s.name)) continue;
            if (!kindNames.Contains(s.name)) continue;
            if (names.Contains(s.name)) continue;
            names.Add(s.name);
        }
        if (workStacks != null)
            foreach (MetaWallet.NamedStack s in workStacks)
                if (s != null && s.count > 0 && !string.IsNullOrEmpty(s.name) && !names.Contains(s.name))
                    names.Add(s.name);
        return names;
    }

    private void MakeBagStepperRow(RectTransform content, string name, int stock, int cap, List<MetaWallet.NamedStack> workStacks)
    {
        int cur = StackCountOf(workStacks, name);
        int total = StackTotal(workStacks);
        bool canPlus = cur < stock && total < cap;
        bool canMinus = cur > 0;

        GameObject row = new GameObject("Row_" + name, typeof(RectTransform), typeof(Image));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.sizeDelta = new Vector2(0f, 44f);
        rt.anchoredPosition = Vector2.zero;
        row.GetComponent<Image>().color = C_CARD;

        NewText(row.transform, "Name", name + " ×" + stock, 17, TextAnchor.MiddleLeft, C_CREAM,
            new Vector2(0f, 0.5f), new Vector2(18f, 0f), new Vector2(520f, 30f));

        Button minus = MakeButton(row.transform, "Minus", "－", new Vector2(290f, 0f), new Vector2(44f, 30f),
            C_PANEL, C_CREAM, () => { StackSet(workStacks, name, cur - 1); RebuildPanel(); }, 22);
        minus.interactable = canMinus;

        NewText(row.transform, "Count", cur.ToString(), 18, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 0.5f), new Vector2(340f, 0f), new Vector2(60f, 30f));

        Button plus = MakeButton(row.transform, "Plus", "＋", new Vector2(390f, 0f), new Vector2(44f, 30f),
            C_BRASS, C_BG, () => { StackSet(workStacks, name, cur + 1); RebuildPanel(); }, 22);
        plus.interactable = canPlus;
    }

    // ---- 底栏动作：保存 / 出击（二次确认） ----

    private void OnSaveLoadout()
    {
        string err;
        if (MetaWallet.SaveLoadout(_work, _craftCat, out err))
        {
            _loadoutStatus = "配置已保存，未扣库存";
            _loadoutStatusError = false;
        }
        else
        {
            _loadoutStatus = err;
            _loadoutStatusError = true;
        }
        RebuildPanel();
    }

    private void OnDeployClick()
    {
        string err;
        if (!MetaWallet.ValidateLoadout(_work, _craftCat, out err))
        {
            _loadoutStatus = err;
            _loadoutStatusError = true;
            RebuildPanel();
            return;
        }
        _confirmDeployOpen = true;
        RebuildPanel();
    }

    private void OnDeployCancel()
    {
        _confirmDeployOpen = false;
        RebuildPanel();
    }

    private void OnDeployConfirm()
    {
        string err;
        if (!MetaWallet.TryCommitDeploy(_work, _craftCat, out err))
        {
            _confirmDeployOpen = false;
            _loadoutStatus = err;
            _loadoutStatusError = true;
            RebuildPanel();
            return;
        }

        // 与旧「一键出击」同口径：先清当局静态，再切场景
        string scene = ExpeditionMapRouter.ResolveSceneName();
        Debug.Log("[藏身处] 整装出击 → " + scene + "（场景由 ExpeditionMapRouter.ResolveSceneName 选）");
        try { ExpeditionLifecycle.EndExpedition("藏身处出击"); }
        catch (System.Exception e) { Debug.LogWarning("[藏身处] EndExpedition 跳过：" + e.Message); }
        SceneManager.LoadScene(scene);
    }

    private void BuildDeployConfirm(GameObject panel)
    {
        // 挡板盖满面板：确认期间点不了页签/底栏
        NewImage(panel.transform, "ConfirmDim", new Vector2(0.5f, 0.5f), new Vector2(0.5f, 0.5f), Vector2.zero,
            new Color(0f, 0f, 0f, 0.55f), new Vector2(1280f, 700f));

        GameObject box = NewImage(panel.transform, "ConfirmBox",
            new Vector2(0.5f, 0.5f), new Vector2(0.5f, 0.5f), Vector2.zero, C_CARD,
            new Vector2(480f, 200f));
        NewImage(box.transform, "Accent", new Vector2(0.5f, 1f), new Vector2(0.5f, 1f),
            new Vector2(0f, -10f), C_BRASS, new Vector2(420f, 4f));
        NewText(box.transform, "Ask", "确认出击随机荒野？", 22, TextAnchor.MiddleCenter, C_CREAM,
            new Vector2(0.5f, 0.5f), new Vector2(0f, 30f), new Vector2(420f, 34f));
        MakeButton(box.transform, "Yes", "确　认", new Vector2(-90f, -50f),
            new Vector2(150f, 48f), C_BRASS, C_BG, OnDeployConfirm, 20);
        MakeButton(box.transform, "No", "取　消", new Vector2(90f, -50f),
            new Vector2(150f, 48f), C_PANEL, C_CREAM, OnDeployCancel, 20);
    }

    // ---- 整装工作快照工具（纯本控制器状态；不入存档） ----

    private int StackCountOf(List<MetaWallet.NamedStack> stacks, string name)
    {
        if (stacks == null || string.IsNullOrEmpty(name)) return 0;
        foreach (MetaWallet.NamedStack s in stacks)
            if (s != null && s.name == name && s.count > 0) return s.count;
        return 0;
    }

    private void StackSet(List<MetaWallet.NamedStack> stacks, string name, int count)
    {
        if (stacks == null || string.IsNullOrEmpty(name)) return;
        for (int i = stacks.Count - 1; i >= 0; i--)
            if (stacks[i] != null && stacks[i].name == name) stacks.RemoveAt(i);
        if (count > 0) stacks.Add(new MetaWallet.NamedStack { name = name, count = count });
    }

    private int StackTotal(List<MetaWallet.NamedStack> stacks)
    {
        if (stacks == null) return 0;
        int n = 0;
        foreach (MetaWallet.NamedStack s in stacks)
            if (s != null && s.count > 0) n += s.count;
        return n;
    }

    private int CardTakenCount(string cardID)
    {
        if (_work == null || _work.cards == null) return 0;
        int n = 0;
        foreach (string id in _work.cards) if (id == cardID) n++;
        return n;
    }

    private int PassiveValueTotal()
    {
        if (_work == null || _work.passives == null || _craftCat == null) return 0;
        int v = 0;
        foreach (string pn in _work.passives)
        {
            PassiveData p = _craftCat.PassiveFor(pn);
            if (p != null) v += p.value;
        }
        return v;
    }

    private HashSet<string> DiceItemNames()
    {
        var set = new HashSet<string>();
        WorkshopConfig cfg = WorkshopConfig.Load();
        if (cfg != null && cfg.diceRecipes != null)
            foreach (WorkshopConfig.DiceRecipe r in cfg.diceRecipes)
                if (r != null && r.dice != null && !string.IsNullOrEmpty(r.dice.itemName))
                    set.Add(r.dice.itemName);
        return set;
    }

    // ---- 选择状态（只活在本控制器；不入存档）----

    private int SelectedSoulTotal()
    {
        int n = 0;
        foreach (KeyValuePair<string, int> kv in _soulSelCount) n += kv.Value;
        return n;
    }

    private int SoulSelCountOf(string soulName)
    {
        int c;
        return _soulSelCount.TryGetValue(soulName, out c) ? c : 0;
    }

    private void ClearSoulSelection()
    {
        _soulSelOrder.Clear();
        _soulSelCount.Clear();
    }

    private void SelectSoul(EnemyData enemy, string soulName)
    {
        int cap = Mathf.Min(MetaWallet.SoulCountOf(soulName), SoulExtraction.PoolRemaining(enemy));
        int sel = SoulSelCountOf(soulName);
        if (sel >= cap) return;
        if (sel == 0) _soulSelOrder.Add(soulName);
        _soulSelCount[soulName] = sel + 1;
        RebuildPanel();
    }

    private void DeselectSoul(string soulName)
    {
        int sel = SoulSelCountOf(soulName);
        if (sel <= 1)
        {
            _soulSelCount.Remove(soulName);
            _soulSelOrder.Remove(soulName);
        }
        else _soulSelCount[soulName] = sel - 1;
        RebuildPanel();
    }

    /// <summary>批量提取：按选择顺序逐魂抽取（每魂 1 抽、无放回），结果汇总进顶部结果条。</summary>
    private void DoExtractAll()
    {
        if (_soulSelOrder.Count == 0) return;
        WildernessSoulCatalog cat = WildernessSoulCatalog.Load();
        if (cat == null) return;

        int okCount = 0;
        bool anyCard = false, anyPassive = false;
        string failReason = null;
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        foreach (string soulName in _soulSelOrder)
        {
            int count = SoulSelCountOf(soulName);
            EnemyData enemy = cat.EnemyFor(soulName);
            if (enemy == null || count <= 0) continue;
            foreach (SoulExtraction.DrawResult dr in SoulExtraction.DrawMany(enemy, soulName, count, _rng, null))
            {
                if (!dr.ok) { if (failReason == null) failReason = dr.reason; break; }
                okCount++;
                if (dr.card != null)
                {
                    anyCard = true;
                    sb.Append("「").Append(dr.card.cardName).Append(" · ").Append(RarityText(dr.rarity)).Append("」");
                }
                else
                {
                    anyPassive = true;
                    sb.Append("「").Append(dr.passive.passiveName).Append(" · ").Append(RarityText(dr.rarity)).Append("」");
                }
            }
        }

        ClearSoulSelection();
        if (okCount > 0)
        {
            _lastDrawWasRecipe = true;
            _lastDrawWasPassive = anyPassive && !anyCard;   // 混出 → 直链落制卡页
            _lastDrawText = "抽出 " + okCount + " 项：" + sb.ToString() +
                            (failReason != null ? "，中途停下：" + failReason : "");
        }
        else
        {
            _lastDrawWasRecipe = false;
            _lastDrawWasPassive = false;
            _lastDrawText = "什么也没抽出：" + (failReason != null ? failReason : "没有可抽取项");
        }
        Debug.Log("[藏身处] 装置批量提取：" + okCount + " 项（" + sb.ToString() + "）");
        Refresh();
    }

    private static string RarityText(CardRarity r)
    {
        switch (r)
        {
            case CardRarity.优秀: return "优秀";
            case CardRarity.稀有: return "稀有";
            case CardRarity.传说: return "传说";
            default: return "普通";
        }
    }

    // ------------------------------------------------------------------
    // 灵魂提取装置（设施③）—— 全屏三栏：中=选魂 / 右=已选 / 左=卡池预览
    // ------------------------------------------------------------------

    /// <summary>列标题（顶部锚，x = 列中心）。</summary>
    private void MakeColumnHeader(Transform parent, float x, string label)
    {
        NewText(parent, "Hdr_" + x, label, 18, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(x, -170f), new Vector2(320f, 26f));
    }

    /// <summary>稀有度色（卡池预览用；项目色板外的语义色）。</summary>
    private static Color RarityColorOf(CardRarity r)
    {
        switch (r)
        {
            case CardRarity.优秀: return new Color(0.55f, 0.85f, 0.50f, 1f);   // 绿
            case CardRarity.稀有: return new Color(0.50f, 0.68f, 0.98f, 1f);   // 蓝
            case CardRarity.传说: return new Color(0.95f, 0.70f, 0.30f, 1f);   // 金
            default: return C_CREAM;                                            // 普通
        }
    }

    /// <summary>设施③专用面板（全屏三栏）：中=灵魂选择 / 右=已选清单 / 左=卡池预览。</summary>
    private void BuildSoulPanel(GameObject panel)
    {
        NewText(panel.transform, "Title", "灵魂提取装置", 28, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -32f), new Vector2(600f, 40f));

        WildernessSoulCatalog cat = WildernessSoulCatalog.Load();
        if (cat == null)
        {
            NewBodyText(panel.transform, "Body", "灵魂池目录缺失", 78f, 84f, 40f);
            MakeButton(panel.transform, "BtnClose", "关闭", new Vector2(-520f, -322f),
                new Vector2(220f, 52f), C_PANEL, C_CREAM, ClosePanel, 20);
            return;
        }

        // ① 顶部结果条（常驻上一批结果；面板重开不丢；超长截断防压列）
        Text result = NewBodyText(panel.transform, "Result",
            string.IsNullOrEmpty(_lastDrawText) ? "选魂 → 看池 → 提取，1 魂 1 抽" : _lastDrawText,
            74f, 720f - 148f, 28f, 16);
        result.verticalOverflow = VerticalWrapMode.Truncate;

        // ② 三栏
        MakeColumnHeader(panel.transform, -370f, "卡　池");
        MakeColumnHeader(panel.transform, 120f, "灵　魂");
        MakeColumnHeader(panel.transform, 490f, "已选择 " + SelectedSoulTotal() + " 个");

        Button cancel = MakeButton(panel.transform, "BtnCancel", "取消选择",
            new Vector2(490f, 152f), new Vector2(200f, 30f), C_PANEL, C_CREAM,
            () => { ClearSoulSelection(); RebuildPanel(); }, 15);
        cancel.interactable = SelectedSoulTotal() > 0;

        RectTransform poolList = MakeScrollList(panel.transform, new Vector2(-370f, -53f), new Vector2(500f, 458f));
        RectTransform soulList = MakeScrollList(panel.transform, new Vector2(120f, -53f), new Vector2(440f, 458f));
        RectTransform selList = MakeScrollList(panel.transform, new Vector2(490f, -72f), new Vector2(260f, 404f));

        FillPoolColumn(poolList, cat);
        int shown = FillSoulColumn(soulList, cat);
        FillSelColumn(selList);

        // ③ 底部：关闭 / （去工坊）/ 提取
        MakeButton(panel.transform, "BtnClose", "关闭", new Vector2(-520f, -322f),
            new Vector2(220f, 52f), C_PANEL, C_CREAM, ClosePanel, 20);
        if (_lastDrawWasRecipe)
            MakeButton(panel.transform, "BtnGotoForge", "去工坊制作 ›", new Vector2(-240f, -322f),
                new Vector2(280f, 52f), C_BRASS, C_BG, () =>
                {
                    _forgeTab = _lastDrawWasPassive ? 2 : 0;
                    _lastForgeText = null;
                    OpenFacility("forge");
                }, 20);

        int total = SelectedSoulTotal();
        Button extract = MakeButton(panel.transform, "BtnExtract", "提　取 " + total + " 个",
            new Vector2(460f, -322f), new Vector2(320f, 56f), C_BRASS, C_BG, DoExtractAll, 24);
        extract.interactable = total > 0;

        Debug.Log("[藏身处] 灵魂提取面板：" + shown + " 种可提取｜已选 " + total +
                  "（灵魂 " + MetaWallet.SoulSummary() + "）");
    }

    /// <summary>左栏：所选魂的卡池预览（按选择顺序分组；全集列出，已抽出置灰）。</summary>
    private void FillPoolColumn(RectTransform content, WildernessSoulCatalog cat)
    {
        if (_soulSelOrder.Count == 0)
        {
            MakeSectionRow(content, "点击中间的灵魂查看卡池", 470f);
            return;
        }
        foreach (string soulName in _soulSelOrder)
        {
            EnemyData enemy = cat.EnemyFor(soulName);
            if (enemy == null) continue;
            MakeSectionRow(content, soulName + "　剩 " + SoulExtraction.PoolRemaining(enemy) + "/" +
                                    SoulExtraction.PoolTotal(enemy), 470f);
            foreach (SoulExtraction.PoolEntry e in SoulExtraction.PoolPreview(enemy))
            {
                string label = (e.isCard ? "〔卡〕" : "〔被动〕") + e.name;
                string right = RarityText(e.rarity) + (e.drawn ? " · 已抽出" : "");
                MakePoolRow(content, label, right,
                    e.drawn ? C_DIM : RarityColorOf(e.rarity), e.drawn ? C_DIM : C_BRASS);
            }
        }
    }

    /// <summary>中栏：灵魂清单（点 = 选中 1 个；上限 = 拥有数与池剩余取小）。返回可提取行数。</summary>
    private int FillSoulColumn(RectTransform content, WildernessSoulCatalog cat)
    {
        int shown = 0;
        foreach (MetaWallet.NamedStack s in MetaWallet.SoulStacks)
        {
            if (s == null || s.count <= 0) continue;
            EnemyData enemy = cat.EnemyFor(s.name);
            if (enemy == null) continue;                          // 目录不认识的灵魂 → 不出现
            if (SoulExtraction.PoolTotal(enemy) <= 0) continue;   // 无产出池的怪 → 不出现
            MakeSoulRow(content, enemy, s.name, s.count);
            shown++;
        }
        if (shown == 0) MakeSectionRow(content, "暂无", 420f);
        return shown;
    }

    /// <summary>右栏：已选清单（点一条退 1 个）。</summary>
    private void FillSelColumn(RectTransform content)
    {
        if (_soulSelOrder.Count == 0)
        {
            MakeSectionRow(content, "未选择", 230f);
            return;
        }
        foreach (string soulName in _soulSelOrder)
            MakeSelRow(content, soulName, SoulSelCountOf(soulName));
    }

    /// <summary>卡池预览行（不可点）：名称按稀有度上色，已抽出置灰。</summary>
    private void MakePoolRow(RectTransform content, string label, string right, Color nameColor, Color rightColor)
    {
        GameObject row = new GameObject("PoolRow", typeof(RectTransform), typeof(Image));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.sizeDelta = new Vector2(0f, 34f);
        rt.anchoredPosition = Vector2.zero;
        row.GetComponent<Image>().color = C_CARD;

        Text lt = NewText(row.transform, "Name", label, 16, TextAnchor.MiddleLeft, nameColor,
            new Vector2(0f, 0.5f), new Vector2(16f, 0f), new Vector2(300f, 26f));
        lt.horizontalOverflow = HorizontalWrapMode.Overflow;
        NewText(row.transform, "Right", right, 15, TextAnchor.MiddleRight, rightColor,
            new Vector2(1f, 0.5f), new Vector2(-16f, 0f), new Vector2(150f, 26f));
    }

    /// <summary>右栏「已选」行：点一条退 1 个。</summary>
    private void MakeSelRow(RectTransform content, string soulName, int count)
    {
        GameObject row = new GameObject("SelRow", typeof(RectTransform), typeof(Image), typeof(Button));
        row.transform.SetParent(content, false);
        RectTransform rt = row.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.sizeDelta = new Vector2(0f, 44f);
        rt.anchoredPosition = Vector2.zero;
        Image img = row.GetComponent<Image>();
        img.color = C_CARD;
        Button btn = row.GetComponent<Button>();
        btn.targetGraphic = img;
        btn.transition = Selectable.Transition.ColorTint;
        string cap = soulName;
        btn.onClick.AddListener(() => DeselectSoul(cap));

        NewText(row.transform, "Name", soulName + " ×" + count, 16, TextAnchor.MiddleLeft, C_CREAM,
            new Vector2(0f, 0.5f), new Vector2(14f, 0f), new Vector2(160f, 30f));
        NewText(row.transform, "Right", "退 1 ›", 15, TextAnchor.MiddleRight, C_BRASS,
            new Vector2(1f, 0.5f), new Vector2(-14f, 0f), new Vector2(70f, 30f));
    }

    // ------------------------------------------------------------------
    // 设施面板
    // ------------------------------------------------------------------

    private void OpenFacility(string key)
    {
        _openFacility = key;
        RebuildPanel();
    }

    private void ClosePanel()
    {
        _openFacility = null;
        if (_panelRoot != null) Destroy(_panelRoot);
        _panelRoot = null;
    }

    private void RebuildPanel()
    {
        if (_panelRoot != null) { Destroy(_panelRoot); _panelRoot = null; }
        if (string.IsNullOrEmpty(_openFacility)) return;

        Canvas canvas = EnsureCanvas();
        _panelRoot = new GameObject("FacilityPanel", typeof(RectTransform));
        _panelRoot.transform.SetParent(canvas.transform, false);
        RectTransform rootRt = _panelRoot.GetComponent<RectTransform>();
        rootRt.anchorMin = Vector2.zero;
        rootRt.anchorMax = Vector2.one;
        rootRt.offsetMin = Vector2.zero;
        rootRt.offsetMax = Vector2.zero;

        // 全屏压暗（Image 默认 raycastTarget=true → 顺便挡住大厅的卡片点击）
        NewImage(_panelRoot.transform, "Dim", Vector2.zero, Vector2.one, Vector2.zero,
            new Color(0f, 0f, 0f, 0.78f));

        // 面板本体：灵魂装置 = 全屏铺满；整装 = 居中 1280×700；其余 = 居中 820×520
        bool full = _openFacility == "soul";
        GameObject panel;
        if (full)
        {
            panel = NewImage(_panelRoot.transform, "Panel", Vector2.zero, Vector2.one, Vector2.zero, C_SCREEN);
        }
        else if (_openFacility == "loadout")
        {
            panel = NewImage(_panelRoot.transform, "Panel",
                new Vector2(0.5f, 0.5f), new Vector2(0.5f, 0.5f), Vector2.zero, C_CARD,
                new Vector2(1280f, 700f));
        }
        else
        {
            panel = NewImage(_panelRoot.transform, "Panel",
                new Vector2(0.5f, 0.5f), new Vector2(0.5f, 0.5f), Vector2.zero, C_CARD,
                new Vector2(820f, 520f));
        }
        if (!full)
            NewImage(panel.transform, "TopAccent", new Vector2(0.5f, 1f), new Vector2(0.5f, 1f),
                new Vector2(0f, -10f), C_BRASS, new Vector2(760f, 4f));

        // 设施③（灵魂提取装置）自带完整面板：全屏三栏（中=选魂 / 右=已选 / 左=卡池预览）
        if (_openFacility == "soul")
        {
            BuildSoulPanel(panel);
            return;
        }
        if (_openFacility == "forge")
        {
            BuildForgePanel(panel);
            return;
        }
        if (_openFacility == "store")
        {
            BuildStorePanel(panel);
            return;
        }
        if (_openFacility == "equip")
        {
            BuildEquipPanel(panel);
            return;
        }
        if (_openFacility == "loadout")
        {
            BuildLoadoutPanel(panel);
            return;
        }

        // 未知设施兜底
        NewText(panel.transform, "Title", "设施", 26, TextAnchor.MiddleCenter, C_BRASS,
            new Vector2(0.5f, 1f), new Vector2(0f, -30f), new Vector2(740f, 36f));
        NewBodyText(panel.transform, "Body", "未知设施", 78f, 84f, 40f);

        MakeButton(panel.transform, "BtnClose", "关闭", new Vector2(0f, -215f),
            new Vector2(200f, 50f), C_PANEL, C_CREAM, ClosePanel, 20);
    }

    // ------------------------------------------------------------------
    // 刷新
    // ------------------------------------------------------------------

    private void Refresh()
    {
        if (_resourceText != null)
        {
            int family = 0, unique = 0, shard = 0, salvage = 0, other = 0;
            foreach (MetaWallet.NamedStack s in MetaWallet.MaterialStacks)
            {
                if (s == null || s.count <= 0) continue;
                if (s.name == MetaWallet.ShardMaterialName) shard += s.count;
                else if (s.name == MetaWallet.SalvageName) salvage += s.count;
                else if (_craftCat != null && _craftCat.IsFamilyMaterial(s.name)) family += s.count;
                else if (_craftCat != null && _craftCat.IsUniqueMaterial(s.name)) unique += s.count;
                else other += s.count;
            }
            _resourceText.text = "怪材 " + (family + unique) +
                                 "　·　碎片 " + shard +
                                 "　·　物资 " + salvage +
                                 "　·　灵魂 " + MetaWallet.SoulCount +
                                 (other > 0 ? "　·　未分类 " + other : "") +
                                 "　·　实物 " + MetaWallet.SumOf(MetaWallet.StoredItems);
        }

        // 面板里展示的是实时库存 → 重开一次即可保证不陈旧
        if (!string.IsNullOrEmpty(_openFacility)) RebuildPanel();
    }

    // ------------------------------------------------------------------
    // 交互
    // ------------------------------------------------------------------

    private void OnDeploy()
    {
        // ★B4（2026-09-17）：出击门不再一键进图——先开整装面板（初始卡组 / 初始被动 / 背包
        //   三页 + 保存 / 出击底栏），出击在面板里二次确认后才扣库存进图。
        OpenLoadout();
    }
}

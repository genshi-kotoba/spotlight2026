// =============================================================================
// 编辑器工具：构建 EventPopup 预制体（一次性工具，菜单 Tools/EventPopup/Rebuild Prefab）
// 结构与 EventPopupUI.BindReferences() 的固定名称对应：
//   EventPopup ─ Panel ─ Title / Desc / CheckBoard(骰子/公式/弃牌槽) / OptionsRoot
// 生成后所有节点位置可在预制体里手动调整，脚本不会再改动。
// =============================================================================
#if UNITY_EDITOR
using UnityEngine;
using UnityEngine.UI;
using UnityEditor;

public static class EventPopupPrefabBuilder
{
    // 配色（与 EventPopupUI 一致）
    static readonly Color Gold   = new Color(0.78f, 0.59f, 0.25f);
    static readonly Color Cream  = new Color(0.96f, 0.89f, 0.77f);
    static readonly Color Brass  = new Color(0.89f, 0.71f, 0.40f);
    static readonly Color DarkBg = new Color(0.10f, 0.06f, 0.02f);

    [MenuItem("Tools/EventPopup/Rebuild Prefab")]
    public static void Rebuild()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null) { Debug.LogError("[EventPopupBuilder] 场景中找不到 UICanvas"); return; }

        // 删除旧的场景实例
        Transform old = canvas.transform.Find("EventPopup");
        if (old != null) Object.DestroyImmediate(old.gameObject);

        Font font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        if (font == null) font = Resources.GetBuiltinResource<Font>("Arial.ttf");

        // ===== 根节点：全屏遮罩（默认不激活） =====
        GameObject root = new GameObject("EventPopup", typeof(RectTransform), typeof(Image));
        root.transform.SetParent(canvas.transform, false);
        RectTransform rootRT = root.GetComponent<RectTransform>();
        rootRT.anchorMin = Vector2.zero;
        rootRT.anchorMax = Vector2.one;
        rootRT.offsetMin = Vector2.zero;
        rootRT.offsetMax = Vector2.zero;
        // 半透明黑色遮罩（视觉暗幕）
        // ★raycastTarget 必须关：全屏 Image 会挡住下方手牌的点击/拖拽射线
        //（D19 鉴定弃牌需要点/拖手牌，模态锁由 Interactions.ModalPopupActive 负责）
        Image dim = root.GetComponent<Image>();
        dim.color = new Color(0, 0, 0, 0.5f);
        dim.raycastTarget = false;

        // ===== Panel：面板底图 =====
        GameObject panel = CreateRect("Panel", root.transform);
        RectTransform panelRT = panel.GetComponent<RectTransform>();
        panelRT.anchorMin = panelRT.anchorMax = new Vector2(0.5f, 0.5f);
        panelRT.sizeDelta = new Vector2(820, 620);
        panelRT.anchoredPosition = Vector2.zero;
        Image panelImg = panel.AddComponent<Image>();
        panelImg.color = DarkBg;
        Outline panelOut = panel.AddComponent<Outline>();
        panelOut.effectColor = Gold;
        panelOut.effectDistance = new Vector2(4, 4);

        // ===== Title：标题（面板顶部居中） =====
        Text title = CreateText("Title", panel.transform, font, "事件标题", 32, Brass, TextAnchor.MiddleCenter);
        SetRect(title.rectTransform, new Vector2(0.5f, 1f), new Vector2(0.5f, 1f), new Vector2(0, -45), new Vector2(500, 50));
        title.fontStyle = FontStyle.Bold;

        // ===== Desc：描述（标题下方） =====
        Text desc = CreateText("Desc", panel.transform, font, "事件描述文案……", 18, Cream, TextAnchor.UpperLeft);
        SetRect(desc.rectTransform, new Vector2(0.5f, 1f), new Vector2(0.5f, 1f), new Vector2(0, -90), new Vector2(700, 110));
        desc.horizontalOverflow = HorizontalWrapMode.Wrap;
        desc.supportRichText = true;

        // ===== CheckBoard：鉴定板容器（面板中部） =====
        GameObject board = CreateRect("CheckBoard", panel.transform);
        RectTransform boardRT = board.GetComponent<RectTransform>();
        boardRT.anchorMin = new Vector2(0.5f, 0.5f);
        boardRT.anchorMax = new Vector2(0.5f, 0.5f);
        boardRT.sizeDelta = new Vector2(740, 250);
        boardRT.anchoredPosition = new Vector2(0, 20);

        // --- DiceImage：骰子面（鉴定板左） ---
        GameObject diceGO = CreateRect("DiceImage", board.transform);
        RectTransform diceRT = diceGO.GetComponent<RectTransform>();
        diceRT.anchorMin = diceRT.anchorMax = new Vector2(0, 0.5f);
        diceRT.sizeDelta = new Vector2(110, 110);
        diceRT.anchoredPosition = new Vector2(80, 30);
        Image diceImg = diceGO.AddComponent<Image>();
        diceImg.color = Color.white; // Sprite 由 EventPopupUI 运行时动态生成

        // --- DiceFaceText：骰子数字兜底 ---
        Text diceFace = CreateText("DiceFaceText", diceGO.transform, font, "", 48, DarkBg, TextAnchor.MiddleCenter);
        Stretch(diceFace.rectTransform);
        diceFace.enabled = false;

        // --- FormulaPanel：公式面板（深色底 + 金边框，同 DiscardPanel 样式） ---
        GameObject formulaPanel = CreateRect("FormulaPanel", board.transform);
        RectTransform formulaPanelRT = formulaPanel.GetComponent<RectTransform>();
        formulaPanelRT.anchorMin = new Vector2(0, 1f);
        formulaPanelRT.anchorMax = new Vector2(1f, 1f);
        formulaPanelRT.offsetMin = new Vector2(190, -90);
        formulaPanelRT.offsetMax = new Vector2(-30, -10);
        Image formulaBg = formulaPanel.AddComponent<Image>();
        formulaBg.color = new Color(0.08f, 0.05f, 0.01f, 0.9f);
        Outline formulaOut = formulaPanel.AddComponent<Outline>();
        formulaOut.effectColor = new Color(Gold.r, Gold.g, Gold.b, 0.6f);
        formulaOut.effectDistance = new Vector2(3, 3);

        // --- FormulaText：单行公式（FormulaPanel 内，四周留 10px 边距） ---
        Text formula = CreateText("FormulaText", formulaPanel.transform, font, "D6 − 2敏捷 = 4", 22, Cream, TextAnchor.MiddleLeft);
        formula.rectTransform.anchorMin = Vector2.zero;
        formula.rectTransform.anchorMax = Vector2.one;
        formula.rectTransform.offsetMin = new Vector2(10, 4);
        formula.rectTransform.offsetMax = new Vector2(-10, -4);
        formula.horizontalOverflow = HorizontalWrapMode.Overflow;
        formula.supportRichText = true;

        // --- DiscardPanel：弃牌槽（鉴定板右下） ---
        GameObject discard = CreateRect("DiscardPanel", board.transform);
        RectTransform discardRT = discard.GetComponent<RectTransform>();
        discardRT.anchorMin = new Vector2(0, 0);
        discardRT.anchorMax = new Vector2(1, 0);
        discardRT.offsetMin = new Vector2(190, 10);
        discardRT.offsetMax = new Vector2(-30, 150);
        Image discardBg = discard.AddComponent<Image>();
        discardBg.color = new Color(0.08f, 0.05f, 0.01f, 0.9f);
        Outline discardOut = discard.AddComponent<Outline>();
        discardOut.effectColor = new Color(Gold.r, Gold.g, Gold.b, 0.6f);
        discardOut.effectDistance = new Vector2(3, 3);

        Text discardTitle = CreateText("DiscardTitle", discard.transform, font, "DISCARD · 弃牌辅助鉴定", 14, Brass, TextAnchor.UpperCenter);
        SetRect(discardTitle.rectTransform, new Vector2(0.5f, 1f), new Vector2(0.5f, 1f), new Vector2(0, -16), new Vector2(400, 22));
        discardTitle.fontStyle = FontStyle.Bold;

        // ===== OptionsRoot：选项容器（面板底部） =====
        GameObject opts = CreateRect("OptionsRoot", panel.transform);
        RectTransform optsRT = opts.GetComponent<RectTransform>();
        optsRT.anchorMin = new Vector2(0.5f, 0);
        optsRT.anchorMax = new Vector2(0.5f, 0);
        optsRT.sizeDelta = new Vector2(700, 180);
        optsRT.anchoredPosition = new Vector2(0, 110);
        VerticalLayoutGroup vlg = opts.AddComponent<VerticalLayoutGroup>();
        vlg.spacing = 10;
        vlg.childAlignment = TextAnchor.UpperCenter;
        vlg.childControlWidth = true;
        vlg.childControlHeight = false;
        vlg.childForceExpandWidth = true;
        vlg.childForceExpandHeight = false;

        // ===== OptionButtonTemplate：选项按钮模板（★v2.7 默认不激活，代码克隆） =====
        // 用户在 Prefab Mode 里微调模板布局（圆圈大小/字号/间距），
        // EventPopupUI.BuildOptionButtons 克隆后只填文本/颜色/事件。
        GameObject tpl = CreateRect("OptionButtonTemplate", opts.transform);
        RectTransform tplRT = tpl.GetComponent<RectTransform>();
        tplRT.sizeDelta = new Vector2(420, 56);
        LayoutElement tplLE = tpl.AddComponent<LayoutElement>();
        tplLE.minHeight = 56;
        tplLE.flexibleWidth = 1;

        // ★v2.8 行底图 + 金色边框（点击范围可见；三态由运行时刷色）
        Image tplBG = tpl.AddComponent<Image>();
        tplBG.color = new Color(0.08f, 0.05f, 0.01f, 0.35f);
        Outline tplOutline = tpl.AddComponent<Outline>();
        tplOutline.effectColor = new Color(0.78f, 0.59f, 0.25f, 0.45f);
        tplOutline.effectDistance = new Vector2(2.5f, 2.5f);
        Button tplBtn = tpl.AddComponent<Button>();
        tplBtn.transition = Selectable.Transition.None;
        tplBtn.targetGraphic = tplBG;

        HorizontalLayoutGroup hlg = tpl.AddComponent<HorizontalLayoutGroup>();
        hlg.spacing = 16;
        hlg.padding = new RectOffset(16, 10, 8, 8);
        hlg.childAlignment = TextAnchor.MiddleLeft;
        hlg.childControlWidth = false;
        hlg.childControlHeight = false;
        hlg.childForceExpandWidth = false;
        hlg.childForceExpandHeight = true;

        // Circle：圆形底（sprite 运行时生成）
        GameObject circle = CreateRect("Circle", tpl.transform);
        ((RectTransform)circle.transform).sizeDelta = new Vector2(48, 48);
        LayoutElement cLE = circle.AddComponent<LayoutElement>();
        cLE.minWidth = 48; cLE.minHeight = 48;
        Image cImg = circle.AddComponent<Image>();
        cImg.color = Color.clear;

        Text circleChar = CreateText("CircleChar", circle.transform, font, "敏", 22, new Color(0.18f, 0.8f, 0.44f), TextAnchor.MiddleCenter);
        Stretch(circleChar.rectTransform);

        // LockedGlow：锁定态发光（拉伸填满 Circle 外扩 5px，默认禁用）
        GameObject glow = CreateRect("LockedGlow", circle.transform);
        RectTransform glowRT = glow.GetComponent<RectTransform>();
        glowRT.anchorMin = Vector2.zero; glowRT.anchorMax = Vector2.one;
        glowRT.offsetMin = new Vector2(-5, -5); glowRT.offsetMax = new Vector2(5, 5);
        Image gImg = glow.AddComponent<Image>();
        gImg.enabled = false;

        Text actionText = CreateText("ActionText", tpl.transform, font, "动作文案示例", 18, Cream, TextAnchor.MiddleLeft);
        actionText.rectTransform.sizeDelta = new Vector2(300, 36);
        LayoutElement aLE = actionText.gameObject.AddComponent<LayoutElement>();
        aLE.flexibleWidth = 1; aLE.minHeight = 36;

        tpl.SetActive(false);

        // ===== 挂脚本 + 默认不激活 =====
        root.AddComponent<EventPopupUI>();
        root.SetActive(false);

        // ===== 保存为预制体 =====
        string folder = "Assets/Prefabs/UI";
        if (!AssetDatabase.IsValidFolder(folder))
        {
            if (!AssetDatabase.IsValidFolder("Assets/Prefabs"))
                AssetDatabase.CreateFolder("Assets", "Prefabs");
            AssetDatabase.CreateFolder("Assets/Prefabs", "UI");
        }
        string path = folder + "/EventPopup.prefab";
        PrefabUtility.SaveAsPrefabAsset(root, path);
        Debug.Log($"[EventPopupBuilder] 预制体已保存：{path}（场景实例已保留且默认不激活，可进预制体手动微调位置）");

        EditorSceneManagerHelper.MarkSceneDirty();
    }

    // ---------- 小工具 ----------
    static GameObject CreateRect(string name, Transform parent)
    {
        GameObject go = new GameObject(name, typeof(RectTransform));
        go.transform.SetParent(parent, false);
        return go;
    }

    static Text CreateText(string name, Transform parent, Font font, string content, int size, Color color, TextAnchor align)
    {
        GameObject go = new GameObject(name, typeof(RectTransform));
        go.transform.SetParent(parent, false);
        Text t = go.AddComponent<Text>();
        t.font = font;
        t.text = content;
        t.fontSize = size;
        t.color = color;
        t.alignment = align;
        t.raycastTarget = false;
        t.horizontalOverflow = HorizontalWrapMode.Overflow;
        t.verticalOverflow = VerticalWrapMode.Overflow;
        return t;
    }

    static void SetRect(RectTransform rt, Vector2 anchorMin, Vector2 anchorMax, Vector2 anchoredPos, Vector2 size)
    {
        rt.anchorMin = anchorMin;
        rt.anchorMax = anchorMax;
        rt.anchoredPosition = anchoredPos;
        rt.sizeDelta = size;
    }

    static void Stretch(RectTransform rt)
    {
        rt.anchorMin = Vector2.zero;
        rt.anchorMax = Vector2.one;
        rt.offsetMin = Vector2.zero;
        rt.offsetMax = Vector2.zero;
    }
}

// 辅助：标记场景脏（保存用）
static class EditorSceneManagerHelper
{
    public static void MarkSceneDirty()
    {
        if (UnityEngine.SceneManagement.SceneManager.GetActiveScene().isDirty) return;
        UnityEditor.SceneManagement.EditorSceneManager.MarkSceneDirty(
            UnityEngine.SceneManagement.SceneManager.GetActiveScene());
    }
}
#endif

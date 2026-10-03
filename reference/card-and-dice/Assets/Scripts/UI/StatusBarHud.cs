// =============================================================================
// 模块：M7 背包系统 - StatusBarHud 顶栏 HUD 静态构建器
// 用途：把「背包/卡包/设置」三按钮 + 骰子计数列表建成 StatusBar/UICanvas 下的静态节点。
//       编辑态由 Tools/背包/5 调用并保存场景（不 Play 也可见）；
//       运行态由 TopRightButtonBar / DiceHud 复用节点、绑定事件、刷新数值。
// 设计依据：用户 HUD 需求（2026-09-09：三按钮移入 StatusBar 常态显示、骰子标注常态显示）。
// 幂等：节点已存在则只补齐组件，不重复创建。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

public static class StatusBarHud
{
    public const string ButtonBarName = "BagCardSettingsBar";
    public const string DiceListName = "DiceCountList";
    public static readonly string[] ButtonLabels = { "背包", "卡包", "设置" };

    // ------------------------------------------------------------------
    // 三按钮栏（挂在 StatusBar 下，右对齐；左→右 = 背包 / 卡包 / 设置）
    // ------------------------------------------------------------------
    /// <summary>在 StatusBar 下构建三按钮。返回按钮栏容器（逻辑分组）。幂等。</summary>
    public static RectTransform BuildButtonBar(Transform statusBar)
    {
        Transform bar = statusBar.Find(ButtonBarName);
        if (bar == null) bar = InventoryUIKit.CreateRect(ButtonBarName, statusBar);
        var barRt = (RectTransform)bar;
        InventoryUIKit.Stretch(barRt);                       // 拉满 StatusBar，仅作分组，不遮挡
        var barImg = barRt.GetComponent<Image>();
        if (barImg == null) barImg = barRt.gameObject.AddComponent<Image>();
        barImg.color = new Color(0f, 0f, 0f, 0f);
        barImg.raycastTarget = false;

        float w = 90f, gap = 6f, rightMargin = 16f;
        for (int i = 0; i < ButtonLabels.Length; i++)
        {
            string nodeName = $"HudBtn_{i}";
            Transform t = bar.Find(nodeName);
            RectTransform rt = t != null ? (RectTransform)t : InventoryUIKit.CreateRect(nodeName, bar);

            rt.anchorMin = rt.anchorMax = new Vector2(1f, 0.5f);
            rt.pivot = new Vector2(1f, 0.5f);
            rt.sizeDelta = new Vector2(w, 44f);
            // 左→右排布：i=0 背包最左，i=2 设置最右（右边缘 -rightMargin）
            rt.anchoredPosition = new Vector2(-(rightMargin + (2 - i) * (w + gap)), 0f);

            Image bg = rt.GetComponent<Image>();
            if (bg == null) bg = rt.gameObject.AddComponent<Image>();
            bg.sprite = InventoryUIKit.WhitePixel;
            bg.color = InventoryUIKit.SlotBg;

            Button btn = rt.GetComponent<Button>();
            if (btn == null) btn = rt.gameObject.AddComponent<Button>();
            btn.targetGraphic = bg;

            Transform labelTf = rt.Find("Label");
            Text label = labelTf != null ? labelTf.GetComponent<Text>() : null;
            if (label == null)
                label = InventoryUIKit.CreateLabel("Label", rt, ButtonLabels[i], 16, InventoryUIKit.Cream, TextAnchor.MiddleCenter);
            else
                label.text = ButtonLabels[i];
            InventoryUIKit.Stretch(label.rectTransform);
        }
        return barRt;
    }

    /// <summary>给三按钮绑定点击（运行态）。找不到节点返回 false。</summary>
    public static bool TryBindButtons(Transform statusBar, System.Action<int> onClick)
    {
        Transform bar = statusBar.Find(ButtonBarName);
        if (bar == null) return false;
        for (int i = 0; i < ButtonLabels.Length; i++)
        {
            Transform t = bar.Find($"HudBtn_{i}");
            if (t == null) continue;
            Button btn = t.GetComponent<Button>();
            if (btn == null) continue;
            btn.onClick.RemoveAllListeners();
            int idx = i;
            btn.onClick.AddListener(() => onClick?.Invoke(idx));
        }
        return true;
    }

    // ------------------------------------------------------------------
    // 骰子计数列表（挂在 UICanvas 下，锚定 EnergyPointDisplay 左侧）
    // ------------------------------------------------------------------
    /// <summary>在 canvas 下构建骰子列表容器（含一个占位行，编辑态可见）。返回容器。幂等。</summary>
    public static RectTransform BuildDiceList(Transform canvas)
    {
        Transform root = canvas.Find(DiceListName);
        if (root == null) root = InventoryUIKit.CreateRect(DiceListName, canvas);
        var rt = (RectTransform)root;
        InventoryUIKit.Stretch(rt);                          // 全屏容器：行用屏幕中心相对坐标
        var img = rt.GetComponent<Image>();
        if (img == null) img = rt.gameObject.AddComponent<Image>();
        img.color = new Color(0f, 0f, 0f, 0f);
        img.raycastTarget = false;

        if (rt.childCount == 0) BuildPlaceholderRow(rt);
        return rt;
    }

    /// <summary>占位首行（编辑态无运行时数据，给 Scene 视图看布局位置）。</summary>
    static void BuildPlaceholderRow(RectTransform root)
    {
        RectTransform row = InventoryUIKit.CreateRect("Row_Placeholder", root);
        row.anchorMin = row.anchorMax = new Vector2(1f, 0.5f);
        row.pivot = new Vector2(1f, 0.5f);
        row.sizeDelta = new Vector2(120f, 26f);
        row.anchoredPosition = new Vector2(120f, 180f);      // 运行时由 DiceHud 用 EnergyPointDisplay 覆盖

        Image icon = row.gameObject.AddComponent<Image>();
        icon.sprite = InventoryUIKit.D4Sprite;
        icon.color = InventoryUIKit.Brass;
        icon.raycastTarget = false;
        icon.rectTransform.anchorMin = icon.rectTransform.anchorMax = new Vector2(0f, 0.5f);
        icon.rectTransform.pivot = new Vector2(0f, 0.5f);
        icon.rectTransform.sizeDelta = new Vector2(20f, 20f);
        icon.rectTransform.anchoredPosition = new Vector2(10f, 0f);

        Text count = InventoryUIKit.CreateLabel("Count", row, "×0", 16, InventoryUIKit.Cream, TextAnchor.MiddleLeft);
        count.rectTransform.anchorMin = new Vector2(0f, 0.5f);
        count.rectTransform.anchorMax = new Vector2(0f, 0.5f);
        count.rectTransform.pivot = new Vector2(0f, 0.5f);
        count.rectTransform.sizeDelta = new Vector2(90f, 26f);
        count.rectTransform.anchoredPosition = new Vector2(24f, 0f);
    }
}

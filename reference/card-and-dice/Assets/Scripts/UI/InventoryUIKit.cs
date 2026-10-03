// =============================================================================
// 模块：M7 背包系统 - InventoryUIKit UI 构建辅助（纯静态）
// 用途：背包 / 魂灯 / 卡包 / 装填 / 搜刮 / 结算 六个界面共用的动态建 UI 工具
// 设计依据：spec §11（UI 结构）、§12（美术资产清单——本阶段零美术，色块 + 文本占位）
// 惯例参照：Assets/Scripts/UI/EnemyRosterPanel.cs:553-606（GetSafeFont / 白像素 / CreateLabel）
//          Assets/Scripts/Editor/EventPopupPrefabBuilder.cs（暗底黄铜配色）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public static class InventoryUIKit
{
    // 配色（与 EventPopupPrefabBuilder 同一套暗底黄铜风）
    public static readonly Color Dim      = new Color(0f, 0f, 0f, 0.55f);
    public static readonly Color PanelBg  = new Color(0.10f, 0.06f, 0.02f, 0.97f);
    public static readonly Color SlotBg   = new Color(0.22f, 0.16f, 0.08f, 1f);
    public static readonly Color SlotSel  = new Color(0.42f, 0.31f, 0.13f, 1f);
    public static readonly Color Gold     = new Color(0.78f, 0.59f, 0.25f, 1f);
    public static readonly Color Brass    = new Color(0.89f, 0.71f, 0.40f, 1f);
    public static readonly Color Cream    = new Color(0.96f, 0.89f, 0.77f, 1f);
    public static readonly Color Muted    = new Color(0.62f, 0.55f, 0.44f, 1f);

    static Font _font;
    static Sprite _white;

    /// <summary>安全字体：LegacyRuntime.ttf → Arial.ttf → 场景任一 Text 借用（照抄 EnemyRosterPanel:591-606）。</summary>
    public static Font SafeFont
    {
        get
        {
            if (_font != null) return _font;
            try { _font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf"); } catch { }
            if (_font == null) { try { _font = Resources.GetBuiltinResource<Font>("Arial.ttf"); } catch { } }
            if (_font == null)
            {
                Text[] any = UnityEngine.Object.FindObjectsOfType<Text>();
                if (any != null && any.Length > 0 && any[0] != null) _font = any[0].font;
            }
            return _font;
        }
    }

    /// <summary>1×1 白像素 Sprite（色块 / Image 填充共用）。</summary>
    public static Sprite WhitePixel
    {
        get
        {
            if (_white != null) return _white;
            var tex = new Texture2D(1, 1, TextureFormat.RGBA32, false);
            tex.SetPixel(0, 0, Color.white);
            tex.Apply();
            _white = Sprite.Create(tex, new Rect(0, 0, 1, 1), new Vector2(0.5f, 0.5f), 1f);
            return _white;
        }
    }

    static Sprite _d4;
    /// <summary>D4 金字塔骰子剪影（朝上三角，运行时绘制并静态缓存）。供骰子 HUD 列表编辑态/运行态共用。</summary>
    public static Sprite D4Sprite
    {
        get
        {
            if (_d4 != null) return _d4;
            int s = 32;
            var tex = new Texture2D(s, s, TextureFormat.RGBA32, false);
            Color transparent = new Color(0f, 0f, 0f, 0f);
            Color fill = Color.white;
            float cx = (s - 1) * 0.5f;
            for (int y = 0; y < s; y++)
            {
                float t = 1f - (float)y / (s - 1);      // t=1 底部（宽），t=0 顶部（尖）→ 朝上三角
                float halfW = t * 0.5f * (s - 1);
                for (int x = 0; x < s; x++)
                {
                    bool inside = Mathf.Abs(x - cx) <= halfW;
                    tex.SetPixel(x, y, inside ? fill : transparent);
                }
            }
            tex.Apply();
            _d4 = Sprite.Create(tex, new Rect(0, 0, s, s), new Vector2(0.5f, 0.5f), 1f);
            return _d4;
        }
    }

    static Sprite _softGlow;
    /// <summary>
    /// 柔光贴图（径向渐变：中心不透明白 → 边缘全透明），运行时绘制并静态缓存。
    /// 用途：战术槽装帧的呼吸光晕（TacticSlotFrame）——再大再模糊也只是把这张图放大 + 调色。
    /// </summary>
    public static Sprite SoftGlowSprite
    {
        get
        {
            if (_softGlow != null) return _softGlow;
            const int s = 64;
            var tex = new Texture2D(s, s, TextureFormat.RGBA32, false);
            float c = (s - 1) * 0.5f;
            float radius = c;
            for (int y = 0; y < s; y++)
            {
                for (int x = 0; x < s; x++)
                {
                    float d = Mathf.Clamp01(Mathf.Sqrt((x - c) * (x - c) + (y - c) * (y - c)) / radius);
                    float a = Mathf.Clamp01(1f - d);
                    a = a * a * (3f - 2f * a);          // smoothstep：中心实、边缘软
                    tex.SetPixel(x, y, new Color(1f, 1f, 1f, a));
                }
            }
            tex.Apply();
            _softGlow = Sprite.Create(tex, new Rect(0, 0, s, s), new Vector2(0.5f, 0.5f), 1f);
            return _softGlow;
        }
    }

    static Sprite _circle;
    /// <summary>
    /// 实心圆（边缘 1px 渐隐抗锯齿），运行时绘制并静态缓存。
    /// 用途：重投按钮的圆形底 / 环（<see cref="CardRerollButton"/>）——两层嵌套（外黄铜环 + 内深棕面）。
    /// </summary>
    public static Sprite CircleSprite
    {
        get
        {
            if (_circle != null) return _circle;
            const int s = 48;
            var tex = new Texture2D(s, s, TextureFormat.RGBA32, false);
            tex.filterMode = FilterMode.Bilinear;
            float c = (s - 1) * 0.5f;
            float r = c - 0.5f;
            for (int y = 0; y < s; y++)
            {
                for (int x = 0; x < s; x++)
                {
                    float d = Mathf.Sqrt((x - c) * (x - c) + (y - c) * (y - c));
                    float a = Mathf.Clamp01(r - d);
                    tex.SetPixel(x, y, new Color(1f, 1f, 1f, a));
                }
            }
            tex.Apply();
            _circle = Sprite.Create(tex, new Rect(0, 0, s, s), new Vector2(0.5f, 0.5f), 1f);
            return _circle;
        }
    }

    static Sprite _hollowFrame;
    /// <summary>
    /// 空心方框（九宫格描边）：运行时绘制并静态缓存。外圈 3px 实心、内部透明，带 3px Sprite 边框
    /// → 配 <c>Image.type = Sliced</c> + <c>fillCenter = false</c> 时，拉伸只拉边条、**描边粗细恒定 3px**，
    /// 不用任何美术资源就能画出任意尺寸的卡牌描边。
    /// 用途：<see cref="CardView"/> 的选中/打出预览描边（2026-09-10 修：预制体里
    /// <c>selectionBorder</c> 是 <c>{fileID: 0}</c>，导致全项目的描边调用都是静默空转）。
    /// </summary>
    public static Sprite HollowFrameSprite
    {
        get
        {
            if (_hollowFrame != null) return _hollowFrame;
            const int s = 12;        // 画布尺寸
            const int b = 3;         // 描边粗细（也是九宫格边框）
            var tex = new Texture2D(s, s, TextureFormat.RGBA32, false);
            tex.filterMode = FilterMode.Point;
            for (int y = 0; y < s; y++)
            {
                for (int x = 0; x < s; x++)
                {
                    bool ring = x < b || y < b || x >= s - b || y >= s - b;
                    tex.SetPixel(x, y, ring ? Color.white : new Color(1f, 1f, 1f, 0f));
                }
            }
            tex.Apply();
            _hollowFrame = Sprite.Create(tex, new Rect(0, 0, s, s), new Vector2(0.5f, 0.5f),
                                         100f, 0u, SpriteMeshType.FullRect, new Vector4(b, b, b, b));
            return _hollowFrame;
        }
    }

    // ------------------------------------------------------------------
    // 节点构建
    // ------------------------------------------------------------------
    public static RectTransform CreateRect(string name, Transform parent)
    {
        var go = new GameObject(name, typeof(RectTransform));
        go.transform.SetParent(parent, false);
        return go.GetComponent<RectTransform>();
    }

    /// <summary>把 RectTransform 拉满父节点（遮罩 / 按钮内文本用）。</summary>
    public static void Stretch(RectTransform rt)
    {
        rt.anchorMin = Vector2.zero;
        rt.anchorMax = Vector2.one;
        rt.offsetMin = Vector2.zero;
        rt.offsetMax = Vector2.zero;
    }

    /// <summary>居中定位 + 指定尺寸。</summary>
    public static void Place(RectTransform rt, Vector2 size, Vector2 anchoredPos)
    {
        rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0.5f);
        rt.pivot = new Vector2(0.5f, 0.5f);
        rt.sizeDelta = size;
        rt.anchoredPosition = anchoredPos;
    }

    public static Image CreatePanel(string name, Transform parent, Vector2 size, Vector2 anchoredPos, Color color)
    {
        RectTransform rt = CreateRect(name, parent);
        Place(rt, size, anchoredPos);
        Image img = rt.gameObject.AddComponent<Image>();
        img.sprite = WhitePixel;
        img.color = color;
        return img;
    }

    public static Text CreateLabel(string name, Transform parent, string text, int fontSize, Color color,
                                   TextAnchor anchor = TextAnchor.UpperLeft)
    {
        RectTransform rt = CreateRect(name, parent);
        Text label = rt.gameObject.AddComponent<Text>();
        label.font = SafeFont;
        label.fontSize = fontSize;
        label.alignment = anchor;
        label.color = color;
        label.horizontalOverflow = HorizontalWrapMode.Overflow;
        label.verticalOverflow = VerticalWrapMode.Overflow;
        label.raycastTarget = false;
        label.text = text;
        return label;
    }

    public static Button CreateButton(string name, Transform parent, string label, Vector2 size,
                                      Vector2 anchoredPos, Action onClick)
    {
        RectTransform rt = CreateRect(name, parent);
        Place(rt, size, anchoredPos);
        Image bg = rt.gameObject.AddComponent<Image>();
        bg.sprite = WhitePixel;
        bg.color = SlotBg;
        Button btn = rt.gameObject.AddComponent<Button>();
        btn.targetGraphic = bg;
        if (onClick != null) btn.onClick.AddListener(() => onClick());

        Text text = CreateLabel("Label", rt, label, 16, Cream, TextAnchor.MiddleCenter);
        Stretch(text.rectTransform);
        return btn;
    }

    /// <summary>
    /// 全屏遮罩根节点（挂 UICanvas 下，默认不激活）。
    /// raycastTarget = true：吞掉杂散点击（与 EventPopup 相反，理由见 Task 6 要点）。
    /// </summary>
    public static RectTransform CreateOverlay(string name)
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            Debug.LogError($"[InventoryUIKit] 场景中找不到 UICanvas，无法创建 {name}");
            return null;
        }

        RectTransform root = CreateRect(name, canvas.transform);
        Stretch(root);
        Image dim = root.gameObject.AddComponent<Image>();
        dim.sprite = WhitePixel;
        dim.color = Dim;
        dim.raycastTarget = true;
        root.gameObject.SetActive(false);
        return root;
    }

    // ------------------------------------------------------------------
    // 格子（背包 / 魂灯 / 遗物袋 / 结算共用的单元格）
    // ------------------------------------------------------------------
    /// <summary>一个可点击格子：底板 + 名称 + 数量。数量文本右下角，名称居中。</summary>
    public class SlotCell
    {
        public GameObject root;
        public Image background;
        public Text nameText;
        public Text countText;
        public Button button;
    }

    public static SlotCell CreateSlotCell(Transform parent, Vector2 size, Vector2 anchoredPos, Action onClick)
    {
        var cell = new SlotCell();
        RectTransform rt = CreateRect("Slot", parent);
        Place(rt, size, anchoredPos);
        cell.root = rt.gameObject;
        cell.background = rt.gameObject.AddComponent<Image>();
        cell.background.sprite = WhitePixel;
        cell.background.color = SlotBg;
        // 格子边框：让格子边界清晰可见（格子与卡片同色时看不出来）
        Outline ol = rt.gameObject.AddComponent<Outline>();
        ol.effectColor = new Color(0.55f, 0.44f, 0.28f, 0.7f);
        ol.effectDistance = new Vector2(1f, -1f);
        cell.button = rt.gameObject.AddComponent<Button>();
        cell.button.targetGraphic = cell.background;
        if (onClick != null) cell.button.onClick.AddListener(() => onClick());

        cell.nameText = CreateLabel("Name", rt, "", 14, Cream, TextAnchor.MiddleCenter);
        Stretch(cell.nameText.rectTransform);
        cell.nameText.rectTransform.offsetMin = new Vector2(4f, 4f);
        cell.nameText.rectTransform.offsetMax = new Vector2(-4f, -4f);

        RectTransform countRT = CreateRect("Count", rt);
        countRT.anchorMin = countRT.anchorMax = new Vector2(1f, 0f);
        countRT.pivot = new Vector2(1f, 0f);
        countRT.sizeDelta = new Vector2(60f, 20f);
        countRT.anchoredPosition = new Vector2(-4f, 2f);
        cell.countText = countRT.gameObject.AddComponent<Text>();
        cell.countText.font = SafeFont;
        cell.countText.fontSize = 14;
        cell.countText.alignment = TextAnchor.LowerRight;
        cell.countText.color = Brass;
        cell.countText.horizontalOverflow = HorizontalWrapMode.Overflow;
        cell.countText.raycastTarget = false;
        return cell;
    }

    /// <summary>
    /// 建 count 个格子，按 columns 列网格排布（左上角为起点，向右向下）。
    /// origin = 第一个格子的「左上角」相对 parent 中心的位置（内部 +半格得格子中心）。
    /// </summary>
    public static List<SlotCell> CreateSlotGrid(Transform parent, int count, int columns, Vector2 cellSize,
                                                Vector2 spacing, Vector2 origin, Action<int> onClick)
    {
        var cells = new List<SlotCell>(count);
        for (int i = 0; i < count; i++)
        {
            int col = i % columns;
            int row = i / columns;
            Vector2 pos = new Vector2(
                origin.x + col * (cellSize.x + spacing.x) + cellSize.x * 0.5f,
                origin.y - row * (cellSize.y + spacing.y) - cellSize.y * 0.5f);
            int index = i;                                  // 闭包捕获：必须拷一份
            cells.Add(CreateSlotCell(parent, cellSize, pos, () => onClick?.Invoke(index)));
        }
        return cells;
    }

    // ------------------------------------------------------------------
    // 滚动列表（牌库清单 / 装填清单 / 结算奖励列表共用）
    // ------------------------------------------------------------------
    /// <summary>
    /// 建一个竖向滚动列表。返回**外框** RectTransform（命中判定用），content 出参是往里加行的父节点。
    /// 行高由 LayoutElement 决定，Content 高度由 ContentSizeFitter 自撑。
    /// </summary>
    public static RectTransform CreateScrollList(string name, Transform parent, Vector2 size, Vector2 anchoredPos,
                                                 out RectTransform content)
    {
        RectTransform rt = CreateRect(name, parent);
        Place(rt, size, anchoredPos);
        Image bg = rt.gameObject.AddComponent<Image>();
        bg.sprite = WhitePixel;
        bg.color = new Color(0f, 0f, 0f, 0.28f);
        rt.gameObject.AddComponent<Mask>().showMaskGraphic = true;   // Mask 需要同节点有 Graphic

        RectTransform viewport = CreateRect("Viewport", rt);
        Stretch(viewport);

        content = CreateRect("Content", viewport);
        content.anchorMin = new Vector2(0f, 1f);
        content.anchorMax = new Vector2(1f, 1f);
        content.pivot = new Vector2(0.5f, 1f);
        content.offsetMin = Vector2.zero;
        content.offsetMax = Vector2.zero;
        content.sizeDelta = Vector2.zero;

        VerticalLayoutGroup layout = content.gameObject.AddComponent<VerticalLayoutGroup>();
        layout.childControlWidth = true;
        layout.childControlHeight = true;
        layout.childForceExpandWidth = true;
        layout.childForceExpandHeight = false;
        layout.spacing = 4f;
        layout.padding = new RectOffset(6, 6, 6, 6);

        ContentSizeFitter fitter = content.gameObject.AddComponent<ContentSizeFitter>();
        fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;

        ScrollRect scroll = rt.gameObject.AddComponent<ScrollRect>();
        scroll.horizontal = false;
        scroll.vertical = true;
        scroll.movementType = ScrollRect.MovementType.Clamped;
        scroll.scrollSensitivity = 26f;
        scroll.viewport = viewport;
        scroll.content = content;
        return rt;
    }

    /// <summary>
    /// 建一个**竖向滚动网格**（固定列数，格子尺寸固定，行数自适应内容）。
    /// 与 <see cref="CreateScrollList"/> 的区别：那边是「一行一行的列表」（VerticalLayoutGroup），
    /// 这边是「一格一格的卡片网格」（GridLayoutGroup）——卡包页的完整卡面用这个。
    /// 返回**外框** RectTransform（命中判定/滚动用），content 出参是往里加卡面的父节点。
    /// </summary>
    /// <param name="columns">固定列数（列宽由 cellSize 定，总宽不够时自行减少列数或缩小格）</param>
    public static RectTransform CreateScrollGrid(string name, Transform parent, Vector2 size, Vector2 anchoredPos,
                                                 Vector2 cellSize, Vector2 spacing, int columns,
                                                 out RectTransform content)
    {
        RectTransform rt = CreateRect(name, parent);
        Place(rt, size, anchoredPos);
        Image bg = rt.gameObject.AddComponent<Image>();
        bg.sprite = WhitePixel;
        bg.color = new Color(0f, 0f, 0f, 0.28f);
        rt.gameObject.AddComponent<Mask>().showMaskGraphic = true;   // Mask 需要同节点有 Graphic

        RectTransform viewport = CreateRect("Viewport", rt);
        Stretch(viewport);

        content = CreateRect("Content", viewport);
        content.anchorMin = new Vector2(0f, 1f);
        content.anchorMax = new Vector2(1f, 1f);
        content.pivot = new Vector2(0.5f, 1f);
        content.offsetMin = Vector2.zero;
        content.offsetMax = Vector2.zero;
        content.sizeDelta = Vector2.zero;

        GridLayoutGroup grid = content.gameObject.AddComponent<GridLayoutGroup>();
        grid.cellSize = cellSize;
        grid.spacing = spacing;
        grid.padding = new RectOffset(6, 6, 6, 6);
        grid.constraint = GridLayoutGroup.Constraint.FixedColumnCount;
        grid.constraintCount = Mathf.Max(1, columns);
        grid.childAlignment = TextAnchor.UpperCenter;

        ContentSizeFitter fitter = content.gameObject.AddComponent<ContentSizeFitter>();
        fitter.verticalFit = ContentSizeFitter.FitMode.PreferredSize;

        ScrollRect scroll = rt.gameObject.AddComponent<ScrollRect>();
        scroll.horizontal = false;
        scroll.vertical = true;
        scroll.movementType = ScrollRect.MovementType.Clamped;
        scroll.scrollSensitivity = 30f;
        scroll.viewport = viewport;
        scroll.content = content;
        return rt;
    }

    /// <summary>
    /// 列表里的一行：底板 + 左对齐文本。onClick 传 null 则不挂 Button（纯拖拽载体）。
    /// 返回行的 RectTransform。
    /// </summary>
    public static RectTransform CreateRow(string name, Transform content, float height, string text,
                                          Color bgColor, Action onClick, out Text label)
    {
        RectTransform rt = CreateRect(name, content);
        LayoutElement le = rt.gameObject.AddComponent<LayoutElement>();
        le.minHeight = le.preferredHeight = height;

        Image bg = rt.gameObject.AddComponent<Image>();
        bg.sprite = WhitePixel;
        bg.color = bgColor;

        if (onClick != null)
        {
            Button btn = rt.gameObject.AddComponent<Button>();
            btn.targetGraphic = bg;
            btn.onClick.AddListener(() => onClick());
        }

        label = CreateLabel("Label", rt, text, 15, Cream, TextAnchor.MiddleLeft);
        label.rectTransform.anchorMin = Vector2.zero;
        label.rectTransform.anchorMax = Vector2.one;
        label.rectTransform.offsetMin = new Vector2(10f, 0f);
        label.rectTransform.offsetMax = new Vector2(-10f, 0f);
        return rt;
    }

    /// <summary>
    /// 给节点挂 BeginDrag / Drag / EndDrag 三个 EventTrigger 回调（免写额外 MonoBehaviour 文件）。
    /// 与同节点的 Button 不冲突：点击走 Button，拖拽走 EventTrigger。
    /// </summary>
    public static void AddDragHandlers(GameObject go, Action<PointerEventData> onBegin,
                                       Action<PointerEventData> onDrag, Action<PointerEventData> onEnd)
    {
        EventTrigger trigger = go.GetComponent<EventTrigger>();
        if (trigger == null) trigger = go.AddComponent<EventTrigger>();
        AddTrigger(trigger, EventTriggerType.BeginDrag, onBegin);
        AddTrigger(trigger, EventTriggerType.Drag, onDrag);
        AddTrigger(trigger, EventTriggerType.EndDrag, onEnd);
    }

    static void AddTrigger(EventTrigger trigger, EventTriggerType type, Action<PointerEventData> handler)
    {
        var entry = new EventTrigger.Entry { eventID = type };
        entry.callback.AddListener((BaseEventData data) => handler(data as PointerEventData));
        trigger.triggers.Add(entry);
    }

    /// <summary>
    /// 关掉整棵子树的射线目标（Graphic.raycastTarget = false）。
    /// 用途：战术面板 / 卡包边栏里**自己轮询鼠标**的卡面——留着射线只会被上层 UI 或遮罩截走事件，
    /// 玩家看到的现象就是「点了没反应」。自己的输入自己做，别让 UGUI 抢。
    /// </summary>
    public static void DisableRaycast(GameObject go)
    {
        if (go == null) return;
        Graphic[] gs = go.GetComponentsInChildren<Graphic>(true);
        for (int i = 0; i < gs.Length; i++)
        {
            if (gs[i] != null) gs[i].raycastTarget = false;
        }
    }

    /// <summary>销毁一个 UI 节点（格子 / 行 / 弹窗子页统一出口，BattleSettlementUI 等复用）。</summary>
    public static void Kill(GameObject go)
    {
        if (go != null) UnityEngine.Object.Destroy(go);
    }
}

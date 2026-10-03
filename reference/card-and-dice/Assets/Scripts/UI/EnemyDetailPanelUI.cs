// =============================================================================
// 模块：敌人意图卡牌 - 左侧详情面板（★2026-09-17 怪物卡牌可见性轮）
// 用途：右侧敌人栏条目点击 → 左侧打开该敌完整信息，纵向三段：
//   数值 → 被动（图标＋名＋完整描述）→ 卡组按大意图分「回合 N」分组
//   （当前回合金框、往后逐级变淡）。
// 设计定稿：docs/2026-09-17_敌人意图卡牌-design.md。
// 要点：
//   ① 右栏条目整行可点：点=开、再点同一条=关、点别的=换怪（改动见 EnemyRosterPanel）；
//   ② 非常驻不阻塞：面板背景不接射线；视口只在指针悬于面板上时接射线（滚轮可用、其余照常穿透）；
//   ③ 同屏只看一只；该敌死亡 / 掉出右栏名单 / 离开战斗 → 自动关；
//   ④ 当前回合卡=已掷骰锁死的最终值（蓝骰段）；未来回合卡=未掷，显示原文占位不剧透点数；
//   ⑤ 迷你卡点击 → 面板内放大（装填界面迷你→放大同款思路），再点收起；
//   ⑥ 耗能角标藏掉；放大卡带「射程N」脚注。
// 实现：零美术动态创建；ScrollRect 手动布局（无 LayoutGroup，与 EnemyRosterPanel 一致）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class EnemyDetailPanelUI : MonoBehaviour
{
    const float PanelW = 440f;
    const float PanelH = 640f;
    const float MiniCardHeight = 128f;
    const float CardDesignHeight = 154f;   // CardView 预制体设计高（LoadoutUI 同口径）
    const float CardDesignWidth = 110f;
    const float MiniSpacing = 6f;
    const float ContentW = PanelW - 24f;   // 视口内宽

    static EnemyDetailPanelUI s_instance;

    public static EnemyDetailPanelUI Instance
    {
        get
        {
            if (s_instance == null) EnsureExists();
            return s_instance;
        }
    }

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    static void AutoBootstrap()
    {
        EnsureExists();
    }

    public static void EnsureExists()
    {
        if (s_instance != null) return;
        GameObject go = new GameObject("EnemyDetailPanelUI");
        s_instance = go.AddComponent<EnemyDetailPanelUI>();
    }

    /// <summary>名册行点击入口：点=开、再点同一条=关、点别的=换怪。</summary>
    public static void Toggle(EnemyController enemy)
    {
        EnemyDetailPanelUI inst = Instance;
        if (inst == null) return;
        inst.TogglePanel(enemy);
    }

    RectTransform _panelRT;
    RectTransform _viewportRT;
    RectTransform _contentRT;
    Image _viewportImg;
    ScrollRect _scroll;

    EnemyController _target;
    int _lastGen = -1;
    long _lastSignature = long.MinValue;
    int _lastHP = -1;
    Text _statsText;

    RectTransform _zoomRT;
    CardView _zoomCard;
    Text _zoomFootnote;

    static Font _cachedFont;
    static Sprite _whitePixel;

    void Awake()
    {
        Canvas canvas = FindOverlayCanvas();
        if (canvas == null)
        {
            Debug.LogWarning("[EnemyDetailPanelUI] 找不到 ScreenSpaceOverlay 画布，详情面板不工作");
            return;
        }
        BuildPanel(canvas);
        BuildZoom(canvas);
        _panelRT.gameObject.SetActive(false);
        _zoomRT.gameObject.SetActive(false);
    }

    void LateUpdate()
    {
        if (_panelRT == null) return;

        // 视口射线：只在指针悬于面板上时接（滚轮可滚、其余时刻点击照常穿透到地图）
        if (_viewportImg != null)
        {
            bool over = RectTransformUtility.RectangleContainsScreenPoint(_panelRT, Input.mousePosition, null);
            if (_viewportImg.raycastTarget != over) _viewportImg.raycastTarget = over;
        }

        if (!_panelRT.gameObject.activeSelf) return;

        bool inBattle = GameStateManager.Instance != null
                     && GameStateManager.Instance.CurrentState == GameState.Battle;
        // 自动关：离开战斗 / 目标死亡 / 掉出右栏名单（无意图）
        if (!inBattle || _target == null || _target.IsDead || !EnemyRosterPanel.HasVisibleIntent(_target))
        {
            Close();
            return;
        }

        // HP 即时刷新（棋盘签名不含 HP）
        if (_statsText != null)
        {
            int hp = _target.CurrentHP;
            if (hp != _lastHP)
            {
                _lastHP = hp;
                RefreshStatsText();
            }
        }

        // 内容同源刷新：揭示代数 / 棋盘签名变化 → 重建（揭示后当前回合卡要换成已掷骰版）
        long signature = EnemyLandingPlanner.CurrentSignature;
        if (_target.RevealGeneration != _lastGen || signature != _lastSignature)
        {
            _lastGen = _target.RevealGeneration;
            _lastSignature = signature;
            RebuildContent();
        }
    }

    void TogglePanel(EnemyController enemy)
    {
        if (enemy == null) return;
        if (_target == enemy && _panelRT.gameObject.activeSelf) { Close(); return; }
        _target = enemy;
        _lastGen = -1;
        _lastSignature = long.MinValue;
        _lastHP = -1;
        RebuildContent();
        _panelRT.gameObject.SetActive(true);
    }

    void Close()
    {
        _target = null;
        if (_panelRT != null && _panelRT.gameObject.activeSelf) _panelRT.gameObject.SetActive(false);
        if (_zoomRT != null && _zoomRT.gameObject.activeSelf) _zoomRT.gameObject.SetActive(false);
    }

    /// <summary>
    /// 卡组分组顺序：当前回合在前，往后循环直到一圈（已过去的回合不显示）。
    /// 纯函数（L2 断言用）。
    /// </summary>
    public static List<int> BuildRoundOrder(int loopCount, int currentIndex)
    {
        var order = new List<int>();
        if (loopCount <= 0) return order;
        for (int k = 0; k < loopCount; k++)
            order.Add((currentIndex + k) % loopCount);
        return order;
    }

    // ------------------------------------------------------------------
    // 内容重建
    // ------------------------------------------------------------------

    void RebuildContent()
    {
        if (_contentRT == null || _target == null) return;

        for (int i = _contentRT.childCount - 1; i >= 0; i--)
            Destroy(_contentRT.GetChild(i).gameObject);

        float y = 0f;
        y += BuildHeader(_contentRT, y);
        y += BuildStats(_contentRT, y);
        y += BuildPassives(_contentRT, y);
        y += BuildCardRounds(_contentRT, y);

        _contentRT.sizeDelta = new Vector2(0f, y + 12f);
        if (_scroll != null) _scroll.verticalNormalizedPosition = 1f;
    }

    RectTransform AddBlock(Transform parent, float y, float height, out GameObject root)
    {
        GameObject go = new GameObject("Block", typeof(RectTransform));
        go.transform.SetParent(parent, false);
        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(1f, 1f);
        rt.pivot = new Vector2(0f, 1f);
        rt.anchoredPosition = new Vector2(0f, -y);
        rt.sizeDelta = new Vector2(0f, height);
        root = go;
        return rt;
    }

    Text AddText(Transform parent, Vector2 pos, Vector2 size, string text, int fontSize, Color color, TextAnchor anchor)
    {
        GameObject go = new GameObject("Text", typeof(RectTransform));
        go.transform.SetParent(parent, false);
        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0f, 1f);
        rt.anchorMax = new Vector2(0f, 1f);
        rt.pivot = new Vector2(0f, 1f);
        rt.anchoredPosition = pos;
        rt.sizeDelta = size;
        Text label = go.AddComponent<Text>();
        label.font = GetSafeFont();
        label.fontSize = fontSize;
        label.alignment = anchor;
        label.color = color;
        label.horizontalOverflow = HorizontalWrapMode.Wrap;
        label.verticalOverflow = VerticalWrapMode.Overflow;
        label.raycastTarget = false;
        label.text = text;
        return label;
    }

    Color NameColor() { return new Color(0.965f, 0.894f, 0.769f, 1f); }
    Color IntentColor() { return new Color(0.89f, 0.71f, 0.40f, 1f); }
    Color SubColor() { return new Color(0.62f, 0.55f, 0.45f, 1f); }

    float BuildHeader(Transform parent, float y)
    {
        GameObject root;
        AddBlock(parent, y, 46f, out root);
        EnemyData d = _target.data;
        AddText(root.transform, new Vector2(0f, 0f), new Vector2(ContentW, 26f),
            d != null ? d.enemyName : "敌人", 18, NameColor(), TextAnchor.MiddleLeft);
        AddText(root.transform, new Vector2(0f, -26f), new Vector2(ContentW, 18f),
            "生命 " + _target.CurrentHP + "/" + _target.MaxHP, 14, IntentColor(), TextAnchor.MiddleLeft);
        return 46f + 8f;
    }

    float BuildStats(Transform parent, float y)
    {
        GameObject root;
        AddBlock(parent, y, 64f, out root);
        AddText(root.transform, new Vector2(0f, 0f), new Vector2(ContentW, 20f), "数值", 14, IntentColor(), TextAnchor.MiddleLeft);
        _statsText = AddText(root.transform, new Vector2(0f, -20f), new Vector2(ContentW, 40f), "", 13, SubColor(), TextAnchor.UpperLeft);
        RefreshStatsText();
        return 64f + 8f;
    }

    void RefreshStatsText()
    {
        if (_statsText == null || _target == null) return;
        EnemyData d = _target.data;
        if (d == null) { _statsText.text = ""; return; }
        string text = "移动 " + _target.MoveBudget + "    视距 " + d.visionRange;
        if (d.canSprint) text += "    疾跑 +" + d.sprintValue;
        _statsText.text = text;
    }

    float BuildPassives(Transform parent, float y)
    {
        if (_target.data == null || _target.data.passives == null || _target.data.passives.Count == 0) return y;

        float yCur = y + 28f;   // 标题行
        GameObject titleRoot;
        AddBlock(parent, y, 28f, out titleRoot);
        AddText(titleRoot.transform, new Vector2(0f, 0f), new Vector2(ContentW, 20f), "被动", 14, IntentColor(), TextAnchor.MiddleLeft);

        float total = 28f;
        for (int i = 0; i < _target.data.passives.Count; i++)
        {
            PassiveData p = _target.data.passives[i];
            if (p == null) continue;
            float descH = EstimateTextHeight(p.description, 12, ContentW - 34f);
            float rowH = 26f + descH + 8f;
            GameObject root;
            AddBlock(parent, yCur, rowH, out root);
            // 图标（有则显示，无则色块）
            GameObject iconGO = new GameObject("Icon", typeof(RectTransform));
            iconGO.transform.SetParent(root.transform, false);
            RectTransform irt = iconGO.GetComponent<RectTransform>();
            irt.anchorMin = irt.anchorMax = new Vector2(0f, 1f);
            irt.pivot = new Vector2(0f, 1f);
            irt.anchoredPosition = new Vector2(0f, -4f);
            irt.sizeDelta = new Vector2(26f, 26f);
            Image icon = iconGO.AddComponent<Image>();
            icon.sprite = p.icon != null ? p.icon : GetWhitePixel();
            icon.color = p.icon != null ? Color.white : IntentColor();
            icon.raycastTarget = false;
            // 名 + 完整描述
            AddText(root.transform, new Vector2(34f, -2f), new Vector2(ContentW - 34f, 20f),
                p.passiveName, 13, NameColor(), TextAnchor.UpperLeft);
            AddText(root.transform, new Vector2(34f, -26f), new Vector2(ContentW - 34f, descH),
                p.description, 12, SubColor(), TextAnchor.UpperLeft);
            yCur += rowH;
            total += rowH;
        }
        return y + total;
    }

    /// <summary>按宽度与字号估算 CJK 文本行数（uGUI Text 不自适应高度，手动布局需要）。</summary>
    static float EstimateTextHeight(string text, int fontSize, float width)
    {
        if (string.IsNullOrEmpty(text)) return fontSize * 1.4f;
        float charsPerLine = Mathf.Max(1f, width / fontSize);
        int lines = Mathf.CeilToInt(text.Length / charsPerLine);
        return lines * fontSize * 1.4f;
    }

    float BuildCardRounds(Transform parent, float y)
    {
        EnemyData d = _target.data;
        if (d == null || d.intentLoop == null || d.intentLoop.Count == 0) return y;

        float total = 28f;   // 标题
        GameObject titleRoot;
        AddBlock(parent, y, 28f, out titleRoot);
        AddText(titleRoot.transform, new Vector2(0f, 0f), new Vector2(ContentW, 20f), "卡组", 14, IntentColor(), TextAnchor.MiddleLeft);

        List<int> order = BuildRoundOrder(d.intentLoop.Count, _target.CurrentIntentIndex);
        float yCur = y + 28f;
        float miniW = MiniCardHeight * (CardDesignWidth / CardDesignHeight);
        int perRow = Mathf.Max(1, (int)(ContentW / (miniW + MiniSpacing)));

        for (int r = 0; r < order.Count; r++)
        {
            int idx = order[r];
            EnemyBigIntent big = d.intentLoop[idx];
            // 回合标签（当前回合金色，未来回合常态色）
            GameObject labelRoot;
            AddBlock(parent, yCur, 22f, out labelRoot);
            AddText(labelRoot.transform, new Vector2(0f, 0f), new Vector2(ContentW, 18f),
                "回合 " + (idx + 1), 13, r == 0 ? IntentColor() : SubColor(), TextAnchor.MiddleLeft);
            yCur += 22f;
            total += 22f;

            int placed = 0;
            int rows = 0;
            if (big != null && big.options != null)
            {
                for (int i = 0; i < big.options.Count; i++)
                {
                    EnemyIntentOption option = big.options[i];
                    if (option == null || option.card == null) continue;
                    Card card = r == 0 ? CurrentRoundCard(i) : new Card(option.card);
                    if (card == null) continue;
                    if (placed % perRow == 0) rows++;
                    int col = placed % perRow;
                    int row = placed / perRow;
                    Vector2 pos = new Vector2(col * (miniW + MiniSpacing), -yCur - row * (MiniCardHeight + 8f));
                    CreateMiniCard(parent, pos, card, r);
                    placed++;
                }
            }
            if (rows == 0) rows = 1;   // 空大意图占一行，保持布局稳定
            yCur += rows * (MiniCardHeight + 8f);
            total += rows * (MiniCardHeight + 8f) + 6f;
        }
        return y + total;
    }

    /// <summary>当前回合第 optionIndex 张小意图的卡：已揭示→掷骰版；未揭示→占位（未掷）。</summary>
    Card CurrentRoundCard(int optionIndex)
    {
        EnemyData d = _target.data;
        EnemyRevealedIntent revealed = _target.RevealedIntent;
        if (revealed != null && revealed.bigIntentIndex == _target.CurrentIntentIndex
            && optionIndex < revealed.options.Count)
        {
            Card rolled = revealed.options[optionIndex].rolledCard;
            if (rolled != null) return rolled;
        }
        if (d == null || d.intentLoop == null || d.intentLoop.Count == 0) return null;
        int idx = Mathf.Clamp(_target.CurrentIntentIndex, 0, d.intentLoop.Count - 1);
        EnemyBigIntent big = d.intentLoop[idx];
        if (big == null || big.options == null || optionIndex >= big.options.Count) return null;
        EnemyIntentOption option = big.options[optionIndex];
        return option != null && option.card != null ? new Card(option.card) : null;
    }

    void CreateMiniCard(Transform parent, Vector2 pos, Card card, int fadeStep)
    {
        CardViewCreator creator = CardViewCreator.Instance;
        if (creator == null) return;

        GameObject holder = new GameObject("Mini", typeof(RectTransform));
        holder.transform.SetParent(parent, false);
        RectTransform hrt = holder.GetComponent<RectTransform>();
        hrt.anchorMin = new Vector2(0f, 1f);
        hrt.anchorMax = new Vector2(0f, 1f);
        hrt.pivot = new Vector2(0f, 1f);
        hrt.anchoredPosition = pos;
        float w = MiniCardHeight * (CardDesignWidth / CardDesignHeight);
        hrt.sizeDelta = new Vector2(w, MiniCardHeight);

        CardView cv = creator.CreateCardView(holder.transform);
        if (cv == null) { Destroy(holder); return; }
        RectTransform crt = cv.GetComponent<RectTransform>();
        crt.anchorMin = crt.anchorMax = new Vector2(0.5f, 0.5f);
        crt.pivot = new Vector2(0.5f, 0.5f);
        crt.anchoredPosition = Vector2.zero;
        crt.localScale = Vector3.one * (MiniCardHeight / CardDesignHeight);
        cv.HoverScale = 1f;
        cv.HoverLift = 0f;
        cv.SetCard(card);
        cv.SetEnergyVisible(false);
        if (fadeStep == 0) cv.SetSelected(true);                 // 当前回合：金框
        else cv.SetCardAlpha(fadeStep == 1 ? 0.45f : fadeStep == 2 ? 0.3f : 0.2f);   // 往后逐级变淡
        cv.DisplayCardHost = clicked => ShowZoom(clicked);
    }

    // ------------------------------------------------------------------
    // 面板内原地放大
    // ------------------------------------------------------------------

    void BuildZoom(Canvas canvas)
    {
        GameObject zoomGO = new GameObject("ZoomCard", typeof(RectTransform));
        zoomGO.transform.SetParent(canvas.transform, false);
        _zoomRT = zoomGO.GetComponent<RectTransform>();
        _zoomRT.anchorMin = new Vector2(0f, 0.5f);
        _zoomRT.anchorMax = new Vector2(0f, 0.5f);
        _zoomRT.pivot = new Vector2(0f, 0.5f);
        _zoomRT.anchoredPosition = new Vector2(24f, 0f);
        _zoomRT.sizeDelta = new Vector2(PanelW, PanelH);

        Image bg = zoomGO.AddComponent<Image>();
        bg.sprite = GetWhitePixel();
        bg.color = new Color(0.11f, 0.07f, 0.02f, 0.92f);
        bg.raycastTarget = false;

        GameObject cardHolder = new GameObject("Card", typeof(RectTransform));
        cardHolder.transform.SetParent(zoomGO.transform, false);
        RectTransform chrt = cardHolder.GetComponent<RectTransform>();
        chrt.anchorMin = chrt.anchorMax = new Vector2(0.5f, 0.5f);
        chrt.pivot = new Vector2(0.5f, 0.5f);
        chrt.anchoredPosition = new Vector2(0f, 40f);
        chrt.sizeDelta = new Vector2(264f, 360f);

        CardViewCreator creator = CardViewCreator.Instance;
        if (creator != null)
        {
            _zoomCard = creator.CreateCardView(chrt);
            if (_zoomCard != null)
            {
                RectTransform crt = _zoomCard.GetComponent<RectTransform>();
                crt.anchorMin = crt.anchorMax = new Vector2(0.5f, 0.5f);
                crt.pivot = new Vector2(0.5f, 0.5f);
                crt.anchoredPosition = Vector2.zero;
                crt.localScale = Vector3.one * (360f / CardDesignHeight);
                _zoomCard.HoverScale = 1f;
                _zoomCard.HoverLift = 0f;
                _zoomCard.SetEnergyVisible(false);
                _zoomCard.DisplayCardHost = clicked => _zoomRT.gameObject.SetActive(false);   // 再点收起
            }
        }

        GameObject footGO = new GameObject("RangeFootnote", typeof(RectTransform));
        footGO.transform.SetParent(zoomGO.transform, false);
        RectTransform frt = footGO.GetComponent<RectTransform>();
        frt.anchorMin = frt.anchorMax = new Vector2(0.5f, 0.5f);
        frt.pivot = new Vector2(0.5f, 1f);
        frt.anchoredPosition = new Vector2(0f, -150f);
        frt.sizeDelta = new Vector2(240f, 22f);
        _zoomFootnote = footGO.AddComponent<Text>();
        _zoomFootnote.font = GetSafeFont();
        _zoomFootnote.fontSize = 16;
        _zoomFootnote.alignment = TextAnchor.MiddleCenter;
        _zoomFootnote.color = new Color(0.965f, 0.894f, 0.769f, 1f);
        _zoomFootnote.raycastTarget = false;
    }

    void ShowZoom(CardView mini)
    {
        if (_zoomRT == null || _zoomCard == null) return;
        if (_zoomRT.gameObject.activeSelf) { _zoomRT.gameObject.SetActive(false); return; }
        Card card = mini != null ? mini.Card : null;
        if (card == null) return;
        _zoomCard.SetCard(card);
        if (_zoomFootnote != null)
        {
            CardData data = card.Data;
            int range = data != null ? data.Range : 0;
            _zoomFootnote.text = range > 0 ? "射程" + range : "";
        }
        _zoomRT.gameObject.SetActive(true);
    }

    // ------------------------------------------------------------------
    // 面板骨架
    // ------------------------------------------------------------------

    void BuildPanel(Canvas canvas)
    {
        GameObject panelGO = new GameObject("EnemyDetailPanel", typeof(RectTransform));
        panelGO.transform.SetParent(canvas.transform, false);
        _panelRT = panelGO.GetComponent<RectTransform>();
        _panelRT.anchorMin = new Vector2(0f, 0.5f);
        _panelRT.anchorMax = new Vector2(0f, 0.5f);
        _panelRT.pivot = new Vector2(0f, 0.5f);
        _panelRT.anchoredPosition = new Vector2(24f, 0f);
        _panelRT.sizeDelta = new Vector2(PanelW, PanelH);

        Image bg = panelGO.AddComponent<Image>();
        bg.sprite = GetWhitePixel();
        bg.color = new Color(0.11f, 0.07f, 0.02f, 0.86f);
        bg.raycastTarget = false;   // 非常驻不阻塞：面板背景不接射线

        GameObject vpGO = new GameObject("Viewport", typeof(RectTransform));
        vpGO.transform.SetParent(panelGO.transform, false);
        _viewportRT = vpGO.GetComponent<RectTransform>();
        _viewportRT.anchorMin = Vector2.zero;
        _viewportRT.anchorMax = Vector2.one;
        _viewportRT.offsetMin = new Vector2(12f, 12f);
        _viewportRT.offsetMax = new Vector2(-12f, -12f);
        _viewportImg = vpGO.AddComponent<Image>();
        _viewportImg.color = new Color(0f, 0f, 0f, 0f);
        _viewportImg.raycastTarget = false;   // LateUpdate 里按指针是否在面板上切换
        vpGO.AddComponent<RectMask2D>();

        GameObject contentGO = new GameObject("Content", typeof(RectTransform));
        contentGO.transform.SetParent(vpGO.transform, false);
        _contentRT = contentGO.GetComponent<RectTransform>();
        _contentRT.anchorMin = new Vector2(0f, 1f);
        _contentRT.anchorMax = new Vector2(1f, 1f);
        _contentRT.pivot = new Vector2(0.5f, 1f);
        _contentRT.anchoredPosition = Vector2.zero;
        _contentRT.sizeDelta = new Vector2(0f, 0f);

        _scroll = panelGO.AddComponent<ScrollRect>();
        _scroll.viewport = _viewportRT;
        _scroll.content = _contentRT;
        _scroll.horizontal = false;
        _scroll.vertical = true;
        _scroll.scrollSensitivity = 30f;
        _scroll.movementType = ScrollRect.MovementType.Clamped;
    }

    static Canvas FindOverlayCanvas()
    {
        Canvas[] all = FindObjectsOfType<Canvas>();
        Canvas fallback = null;
        for (int i = 0; i < all.Length; i++)
        {
            if (all[i].renderMode != RenderMode.ScreenSpaceOverlay) continue;
            fallback = all[i];
            if (all[i].GetComponentInChildren<EnemyRosterPanel>() != null) return all[i];
        }
        return fallback;
    }

    static Sprite GetWhitePixel()
    {
        if (_whitePixel != null) return _whitePixel;
        var tex = new Texture2D(1, 1, TextureFormat.RGBA32, false);
        tex.SetPixel(0, 0, Color.white);
        tex.Apply();
        _whitePixel = Sprite.Create(tex, new Rect(0, 0, 1, 1), new Vector2(0.5f, 0.5f), 1f);
        return _whitePixel;
    }

    static Font GetSafeFont()
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

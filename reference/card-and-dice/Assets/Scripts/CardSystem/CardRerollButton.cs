// =============================================================================
// 模块：CardSystem - 重投按钮（手牌右下角 ↻）
// 用途：手牌悬停时在卡右下角出现「↻」圆形按钮；按下 + 松开都在按钮上
//       → 消耗 1 枚探索骰子 → 该卡全部槽位骰（真实装填骰 + 临时劣质骰）整体重掷。
// 设计依据：docs/2026-09-13_重投-design.md（用户 2026-09-13 逐条拍板）；
//           《设计增补_公式与调优旋钮》F6.2 基础重投、《设计增补_边缘情况与验收标准》§八。
// 实现要点：
//   · 代码建 UI，不动 prefab / 场景（同 AutoPrepareToggle 先例）；圆底 = InventoryUIKit.CircleSprite。
//   · 图标 = 程序化绘制的 96px 抗锯齿圆环箭头纹理（白色 + 覆盖度 alpha，Image.color 上色）。
//     原用 U+21BB（↻）字体字形，实测栅格化后被卡牌 1.4~2.1× 缩放放大严重模糊（2026-09-13
//     用户实测反馈），弃用；几何 = 环带 r∈[25,38]、正上方 60° 缺口、箭头在缺口逆时针端沿
//     顺时针切线伸出（3×3 超采样，mipmap + Trilinear）。
//   · 防误触在按钮内部闭环：自实现全部指针接口，按下吞掉卡牌的点击跟随 / 拖拽启动；
//     UGUI 只在「按下目标 == 松开目标」时派发 OnPointerClick → 按下后移出再松开天然不成立。
//   · 悬停预演：指针进入按钮 → DiceSpendPreview.SetCardSource(this, true)（按钮自身作 key，
//     与「手牌悬停」那条来源并存互不干扰）；置灰时不点亮。
//   · 与卡牌悬停的边界：指针在卡面 ↔ 按钮之间移动时 UGUI 会派发 Exit/Enter——
//     卡面→按钮由 CardView.OnPointerExit 白名单豁免；按钮→卡外由本类反向调用
//     CardView.NotifyRerollButtonExited() 代跑卡的离开流程（详见 CardView 注释）。
// =============================================================================
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

/// <summary>卡牌右下角的重投（基础重投）按钮。由 <see cref="CardView"/> 懒创建为卡的子对象。</summary>
public class CardRerollButton : MonoBehaviour,
    IPointerEnterHandler, IPointerExitHandler,
    IPointerDownHandler, IPointerUpHandler, IPointerClickHandler,
    IBeginDragHandler, IDragHandler, IEndDragHandler
{
    // ★2026-09-13 v2.6 教学钩子：任何一次重投成功（已扣 1 枚探索骰、已重掷）后广播。
    //   TutorialDirector 订阅（S41 重投教学拍解除用）；零侵入，非教程无人订阅。
    public static event System.Action OnRerolled;

    /// <summary>置灰态的整组透明度（探索骰池空 / 0 槽卡）。</summary>
    private const float GrayAlpha = 0.35f;

    private CardView _owner;
    private CanvasGroup _group;
    private bool _shownWanted;   // 卡牌悬停（CardView.SetShown 置位）
    private bool _visible;       // 合成后的可见态（含拖拽 / 飞出 / 姿态锁）
    private bool _available;     // 可点态（槽位 ≥1 且探索骰 ≥1）

    // ==================================================================
    // 创建（CardView.EnsureRerollButton 调用；构建全在 Attach 里，不依赖 Awake → 编辑态可测）
    // ==================================================================
    public static CardRerollButton Attach(CardView owner)
    {
        var go = new GameObject("RerollButton", typeof(RectTransform));
        go.transform.SetParent(owner.transform, false);
        go.transform.SetAsLastSibling();          // 画在卡面之上

        var btn = go.AddComponent<CardRerollButton>();
        btn._owner = owner;
        btn.BuildUI();
        return btn;
    }

    private void BuildUI()
    {
        var rt = (RectTransform)transform;
        rt.anchorMin = rt.anchorMax = new Vector2(1f, 0f);   // 锚在卡右下角
        rt.pivot = new Vector2(0.5f, 0.5f);
        rt.sizeDelta = new Vector2(20f, 20f);
        rt.anchoredPosition = new Vector2(-14f, 14f);        // 距两条边各 4（= 20/2 + 4）

        _group = gameObject.AddComponent<CanvasGroup>();

        // 底：黄铜圆环（根图比面图大 2px 形成描边）
        var ring = gameObject.AddComponent<Image>();
        ring.sprite = InventoryUIKit.CircleSprite;
        ring.color = InventoryUIKit.Brass;
        ring.raycastTarget = true;   // 按钮的唯一射线目标（子元素全部不挡）

        // 面：深棕圆（内缩 2px，露出 2px 黄铜环）
        RectTransform fillRT = InventoryUIKit.CreateRect("Fill", transform);
        InventoryUIKit.Stretch(fillRT);
        fillRT.offsetMin = new Vector2(2f, 2f);
        fillRT.offsetMax = new Vector2(-2f, -2f);
        var fill = fillRT.gameObject.AddComponent<Image>();
        fill.sprite = InventoryUIKit.CircleSprite;
        fill.color = new Color(0.106f, 0.067f, 0.024f, 1f);
        fill.raycastTarget = false;

        // 图标：程序化圆环箭头（96px 抗锯齿；白色贴图 × Image.color 上色）
        RectTransform iconRT = InventoryUIKit.CreateRect("Icon", transform);
        InventoryUIKit.Stretch(iconRT);
        iconRT.offsetMin = new Vector2(3f, 3f);
        iconRT.offsetMax = new Vector2(-3f, -3f);
        var icon = iconRT.gameObject.AddComponent<Image>();
        icon.sprite = GetIconSprite();
        icon.color = InventoryUIKit.Brass;
        icon.raycastTarget = false;

        _visible = false;
        _available = false;
        _group.alpha = 0f;
        _group.blocksRaycasts = false;
        _group.interactable = false;
    }

    // ==================================================================
    // 图标绘制：程序化 96px 抗锯齿圆环箭头（替代原 U+21BB 字体字形——
    // 字形栅格化后被卡牌缩放放大严重模糊，2026-09-13 用户实测反馈）。
    // 几何：中心 47.5，环带 r∈[25,38]，正上方 60° 缺口 [50°,110°]；
    // 箭头根部在缺口逆时针端（110°）的径向线上 r=31.5±8.5，沿顺时针切线伸出 30。
    // ==================================================================
    private const int IconSize = 96;
    private static Sprite _iconSprite;

    private static Sprite GetIconSprite()
    {
        if (_iconSprite != null) return _iconSprite;

        const float c = IconSize / 2f - 0.5f;      // 47.5
        const float rin = 25f, rout = 38f;
        const float rmid = (rin + rout) / 2f;      // 31.5
        const float thetaB = 110f * Mathf.Deg2Rad; // 缺口逆时针端 = 箭头根部中心角
        const float bh = 8.5f;                     // 箭头根部半高（径向）
        const float arrowLen = 30f;                // 箭头长度（顺时针切线向）

        float ux = Mathf.Cos(thetaB), uy = Mathf.Sin(thetaB);
        float vx = uy, vy = -ux;                   // 顺时针切线方向 v(θ) = (sinθ, −cosθ)
        var tri = new float[6];                    // b1（内角）、b2（外角）、tip
        tri[0] = c + (rmid - bh) * ux; tri[1] = c + (rmid - bh) * uy;
        tri[2] = c + (rmid + bh) * ux; tri[3] = c + (rmid + bh) * uy;
        tri[4] = c + rmid * ux + arrowLen * vx; tri[5] = c + rmid * uy + arrowLen * vy;

        var tex = new Texture2D(IconSize, IconSize, TextureFormat.RGBA32, true);
        var px = new Color32[IconSize * IconSize];
        for (int y = 0; y < IconSize; y++)
        {
            for (int x = 0; x < IconSize; x++)
            {
                float cov = 0f;
                for (int sy = 0; sy < 3; sy++)
                {
                    for (int sx = 0; sx < 3; sx++)
                    {
                        if (IsIconPixel(x + (sx + 0.5f) / 3f, y + (sy + 0.5f) / 3f, c, rin, rout, thetaB, tri))
                            cov += 1f / 9f;
                    }
                }
                px[y * IconSize + x] = new Color32(255, 255, 255, (byte)Mathf.RoundToInt(cov * 255f));
            }
        }
        tex.SetPixels32(px);
        tex.Apply(true);                        // 生成 mip
        tex.filterMode = FilterMode.Trilinear;  // 缩到 ~14px 显示时靠 mip 平滑（避免锯齿闪烁）
        tex.wrapMode = TextureWrapMode.Clamp;
        _iconSprite = Sprite.Create(tex, new Rect(0f, 0f, IconSize, IconSize), new Vector2(0.5f, 0.5f), 100f);
        return _iconSprite;
    }

    /// <summary>环带 ∪ 箭头三角的单点判定（3×3 超采样用）。</summary>
    private static bool IsIconPixel(float px, float py, float c, float rin, float rout, float thetaB, float[] tri)
    {
        float dx = px - c, dy = py - c;
        float r = Mathf.Sqrt(dx * dx + dy * dy);
        if (r >= rin && r <= rout)
        {
            float fromB = thetaB - Mathf.Atan2(dy, dx);   // 从箭头根部沿顺时针的角距
            while (fromB < 0f) fromB += 2f * Mathf.PI;
            while (fromB >= 2f * Mathf.PI) fromB -= 2f * Mathf.PI;
            if (fromB > Mathf.PI / 3f) return true;       // > 60°：缺口之外 → 属环带
        }

        float d1 = (px - tri[2]) * (tri[1] - tri[3]) - (tri[0] - tri[2]) * (py - tri[3]);
        float d2 = (px - tri[4]) * (tri[3] - tri[5]) - (tri[2] - tri[4]) * (py - tri[5]);
        float d3 = (px - tri[0]) * (tri[5] - tri[1]) - (tri[4] - tri[0]) * (py - tri[1]);
        bool hasNeg = d1 < 0f || d2 < 0f || d3 < 0f;
        bool hasPos = d1 > 0f || d2 > 0f || d3 > 0f;
        return !(hasNeg && hasPos);
    }

    // ==================================================================
    // 显隐 / 可用性（CardView 置 _shownWanted；其余每帧合成）
    // ==================================================================
    /// <summary>手牌悬停进入 / 离开（CardView 调用）。</summary>
    public void SetShown(bool on)
    {
        if (_shownWanted == on) return;
        _shownWanted = on;
        RefreshState();
    }

    private void Update()
    {
        RefreshState();
    }

    private void RefreshState()
    {
        bool visible = _shownWanted && _owner != null
                       && !_owner.IsFlyingOut && !_owner.InteractionLocked && !_owner.IsDragging;
        bool available = visible && ComputeAvailable();

        if (visible == _visible && available == _available) return;
        _visible = visible;
        _available = available;

        _group.alpha = visible ? (available ? 1f : GrayAlpha) : 0f;
        _group.blocksRaycasts = visible;   // 隐藏 = 不挡射线（点击落回卡面）；置灰 = 仍挡住（不落回卡面触发打牌）
        _group.interactable = visible;

        // 收起预演：隐藏 / 置灰时都不能残留半透明
        if (!visible || !available) DiceSpendPreview.SetCardSource(this, false);
    }

    /// <summary>可点 = 有骰子槽位 且 探索骰池剩余 ≥ 1（与 RemainingExplorationDice 同一口径）。</summary>
    private bool ComputeAvailable()
    {
        if (_owner == null || _owner.Card == null) return false;
        if (_owner.Card.DiceValues.Length == 0) return false;        // 0 槽卡：永久置灰
        ExplorationTurnManager etm = ExplorationTurnManager.Instance;
        return etm != null && etm.RemainingExplorationDice() > 0;    // 骰池空：暂时置灰
    }

    /// <summary>CardView 豁免判定用：这个射线目标是否就是按钮自己（或其子物体）。</summary>
    public bool ContainsPointerTarget(GameObject go)
    {
        if (go == null) return false;
        return go == gameObject || go.transform.IsChildOf(transform);
    }

    // ==================================================================
    // 指针（全部接口都实现：按钮吞掉一切，防误触在内部闭环）
    // ==================================================================
    public void OnPointerEnter(PointerEventData eventData)
    {
        if (_visible && _available) DiceSpendPreview.SetCardSource(this, true);
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        DiceSpendPreview.SetCardSource(this, false);

        // 指针只是移回了卡面 → 卡仍悬停，无需额外处理
        GameObject under = eventData != null ? eventData.pointerCurrentRaycast.gameObject : null;
        if (under != null && _owner != null
            && (under == _owner.gameObject || under.transform.IsChildOf(_owner.transform)))
            return;

        // 指针从按钮直接离开整张卡：Exit 被按钮接住、不再冒泡给卡 → 反向代跑卡的离开流程
        if (_owner != null) _owner.NotifyRerollButtonExited();
    }

    // 按下 / 松开 / 点击：吞掉（不冒泡给卡牌，避免触发点击跟随 / 打牌）
    public void OnPointerDown(PointerEventData eventData) { }
    public void OnPointerUp(PointerEventData eventData) { }

    public void OnPointerClick(PointerEventData eventData)
    {
        TryReroll();
    }

    // 拖拽三件套：空实现吞掉（在按钮上按住拖动不会启动出牌拖拽）
    public void OnBeginDrag(PointerEventData eventData) { }
    public void OnDrag(PointerEventData eventData) { }
    public void OnEndDrag(PointerEventData eventData) { }

    // ==================================================================
    // 执行：消耗 1 枚探索骰 → 全部槽位重掷
    // ==================================================================
    private void TryReroll()
    {
        if (!_visible || !ComputeAvailable()) return;   // 兜底：正常已被置灰挡住
        Card card = _owner != null ? _owner.Card : null;
        if (card == null) return;

        if (!ExplorationTurnManager.Instance.TryConsumeExplorationDice()) return;  // 兜底：骰池已空
        card.RerollAllDice();

        // ★2026-09-13 v2.6 教学钩子：完成一次重投（TutorialDirector S41 用；零侵入，非教程无人订阅）
        OnRerolled?.Invoke();

        // 指针仍在按钮上 → 重刷预演：半透明自动移到「下一枚」候选（明示再点花的是这枚）
        DiceSpendPreview.SetCardSource(this, true);
        Debug.Log($"[重投] 消耗 1 枚探索骰 → 重掷「{card.Data.cardName}」");
    }

    // ==================================================================
    // 清理（静态预演集合不能留死 key：卡被回收 / 销毁 / 隐藏时都要收）
    // ==================================================================
    private void OnDisable()
    {
        DiceSpendPreview.SetCardSource(this, false);
    }

    private void OnDestroy()
    {
        DiceSpendPreview.SetCardSource(this, false);
    }
}

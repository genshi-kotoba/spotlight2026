// =============================================================================
// 模块：战术槽装帧 TacticSlotFrame（2026-09-10 新增）
// 用途：给战术槽里的卡套一层「特殊牌装帧」——呼吸光晕 + 双环描边 + 四角 L 形角标。
//       目的是让战术槽里的卡一眼区别于普通手牌/牌库卡：紫+金异质配色 vs 普通卡的黄铜。
//       零美术：全部用 Image 色块 + InventoryUIKit.SoftGlowSprite（程序化径向渐变）拼装。
// 落点：卡包页边栏槽格（CardPackUI）/ 战斗内战术面板槽格（TacticSlotsPanel）——同一个组件。
// 设计依据：docs/superpowers/specs/2026-09-10-卡包装载与战术槽装帧-design.md §6
// ★2026-09-10 用户定稿：**不出现任何文字印记**（原先顶部有个装饰性铭牌，已删除）。
// 注意：所有装帧节点 raycastTarget = false——光晕比卡面大，开着会吃掉卡的点击/拖拽。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using DG.Tweening;

/// <summary>
/// 战术槽装帧：围绕一个槽格绘制光晕 + 双环 + 四角角标，并驱动呼吸光效。
/// 用 <see cref="Attach"/> 挂到槽格上；用 SetOccupied / SetLit / SetHover 切三态。
/// </summary>
public class TacticSlotFrame : MonoBehaviour
{
    [Header("配色（[PLACEHOLDER · 待调]）")]
    [Tooltip("光晕（紫）：普通态 / 悬停态")]
    public Color AuraColor = new Color(0.80f, 0.45f, 0.95f, 0.22f);
    public Color AuraColorHover = new Color(0.88f, 0.58f, 1.00f, 0.34f);
    [Tooltip("外环：亮铜金")]
    public Color OuterColor = new Color(0.95f, 0.78f, 0.38f, 1f);
    [Tooltip("内环：紫")]
    public Color InnerColor = new Color(0.72f, 0.40f, 0.92f, 0.90f);
    [Tooltip("冷却态（熄灭）：死灰")]
    public Color CoolingColor = new Color(0.45f, 0.42f, 0.38f, 0.50f);

    [Header("形态（[PLACEHOLDER · 待调]）")]
    [Tooltip("光晕相对槽格的放大倍数。★受滚动视口 Mask 裁剪：两列并排时左右余量只有十几像素，" +
             "1.55 会被切出硬边，故收到 1.18。")]
    public float AuraScale = 1.18f;
    [Tooltip("呼吸周期（秒）")]
    public float BreathPeriod = 1.6f;
    [Tooltip("悬停时整帧放大倍数")]
    public float HoverScale = 1.03f;

    // 运行时
    Image _aura;
    readonly List<Image> _outerRing = new List<Image>();
    readonly List<Image> _innerRing = new List<Image>();
    readonly List<Image> _corners = new List<Image>();

    bool _lit = true;
    bool _hovered;
    Vector2 _slotSize = new Vector2(150f, 210f);

    // ------------------------------------------------------------------
    // 挂载
    // ------------------------------------------------------------------

    /// <summary>
    /// 在槽格上挂一层装帧（重复调用会先清掉旧的）。
    /// 会把自己设成槽格的第一个子节点——保证光晕画在卡面**之后**（否则紫光会盖住卡面）。
    /// </summary>
    public static TacticSlotFrame Attach(RectTransform host, Vector2 slotSize)
    {
        if (host == null) return null;

        Transform old = host.Find("TacticSlotFrame");
        if (old != null) Destroy(old.gameObject);

        RectTransform root = InventoryUIKit.CreateRect("TacticSlotFrame", host);
        InventoryUIKit.Place(root, slotSize, Vector2.zero);
        root.SetAsFirstSibling();

        TacticSlotFrame frame = root.gameObject.AddComponent<TacticSlotFrame>();
        frame._slotSize = slotSize;
        frame.Build();
        frame.SetLit(true);
        frame.SetOccupied(false);
        return frame;
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------

    void Build()
    {
        RectTransform root = transform as RectTransform;
        if (root == null) return;

        float w = _slotSize.x;
        float h = _slotSize.y;

        // ① 呼吸光晕（最大、最底）
        _aura = Bar(root, "Aura", AuraColor, _slotSize * AuraScale, Vector2.zero);
        _aura.sprite = InventoryUIKit.SoftGlowSprite;
        _aura.transform.SetAsFirstSibling();

        // ② 内环：距卡边 +5px，细线
        BuildRing(root, "InnerRing", _innerRing, w + 10f, h + 10f, 1f, InnerColor);

        // ③ 外环：距卡边 +10px，粗线
        BuildRing(root, "OuterRing", _outerRing, w + 20f, h + 20f, 3f, OuterColor);

        // ④ 四角 L 形角标：压在外环四角上（两笔交叠成 L）
        float ow = w + 20f, oh = h + 20f;
        const float cl = 20f, ct = 4f;
        float hx = ow * 0.5f, hy = oh * 0.5f;
        for (int sx = -1; sx <= 1; sx += 2)
        {
            for (int sy = -1; sy <= 1; sy += 2)
            {
                _corners.Add(Bar(root, "CornerH", OuterColor, new Vector2(cl, ct),
                                 new Vector2(sx * (hx - cl * 0.5f), sy * hy)));
                _corners.Add(Bar(root, "CornerV", OuterColor, new Vector2(ct, cl),
                                 new Vector2(sx * hx, sy * (hy - cl * 0.5f))));
            }
        }
    }

    /// <summary>画一圈 4 根细棒围成的空心环（比用一张图更省事，无需环形贴图）。</summary>
    void BuildRing(RectTransform root, string name, List<Image> sink, float w, float h, float t, Color color)
    {
        RectTransform holder = InventoryUIKit.CreateRect(name, root);
        InventoryUIKit.Place(holder, new Vector2(w, h), Vector2.zero);

        sink.Add(Bar(holder, "Top", color, new Vector2(w, t), new Vector2(0f, h * 0.5f)));
        sink.Add(Bar(holder, "Bottom", color, new Vector2(w, t), new Vector2(0f, -h * 0.5f)));
        sink.Add(Bar(holder, "Left", color, new Vector2(t, h), new Vector2(-w * 0.5f, 0f)));
        sink.Add(Bar(holder, "Right", color, new Vector2(t, h), new Vector2(w * 0.5f, 0f)));
    }

    /// <summary>一根实心色条（装帧唯一图元）。raycastTarget 必须关：光晕比卡面大会吃掉点击。</summary>
    static Image Bar(Transform parent, string name, Color color, Vector2 size, Vector2 pos)
    {
        RectTransform rt = InventoryUIKit.CreateRect(name, parent);
        InventoryUIKit.Place(rt, size, pos);
        Image img = rt.gameObject.AddComponent<Image>();
        img.sprite = InventoryUIKit.WhitePixel;
        img.color = color;
        img.raycastTarget = false;
        return img;
    }

    // ------------------------------------------------------------------
    // 三态
    // ------------------------------------------------------------------

    /// <summary>槽里有没有卡：没卡 → 整帧隐藏（不打光、不显环，只剩槽底占位）。</summary>
    public void SetOccupied(bool on)
    {
        gameObject.SetActive(on);
        if (on) SetLit(_lit);
    }

    /// <summary>就绪（呼吸亮环）/ 冷却（熄灭死灰）。</summary>
    public void SetLit(bool lit)
    {
        _lit = lit;

        Color outer = lit ? OuterColor : CoolingColor;
        Color inner = lit ? InnerColor : CoolingColor;
        foreach (Image i in _outerRing) if (i != null) i.color = outer;
        foreach (Image i in _innerRing) if (i != null) i.color = inner;
        foreach (Image i in _corners) if (i != null) i.color = outer;

        if (lit) StartBreath();
        else StopBreath();
    }

    /// <summary>悬停：整帧微放大 + 光晕增亮。</summary>
    public void SetHover(bool on)
    {
        if (_hovered == on) return;
        _hovered = on;

        if (!gameObject.activeInHierarchy) return;

        DOTween.Kill(transform);
        transform.DOScale(on ? Vector3.one * HoverScale : Vector3.one, 0.12f).SetEase(Ease.OutQuad);

        if (_lit) StartBreath();          // 用悬停档的亮度重开呼吸
    }

    // ------------------------------------------------------------------
    // 呼吸
    // ------------------------------------------------------------------

    void StartBreath()
    {
        if (_aura == null) return;

        // 用 DOTween.To(getter, setter) 而不是 Image.DOFade：不依赖 DOTween 的 UI 快捷模块。
        DOTween.Kill(_aura);
        _aura.gameObject.SetActive(true);

        Color baseC = _hovered ? AuraColorHover : AuraColor;
        Color dim = new Color(baseC.r, baseC.g, baseC.b, baseC.a * 0.75f);
        Color bright = new Color(baseC.r, baseC.g, baseC.b, Mathf.Min(0.85f, baseC.a * 1.70f));

        _aura.color = dim;
        DOTween.To(() => _aura.color, c => { if (_aura != null) _aura.color = c; }, bright, BreathPeriod)
               .SetEase(Ease.InOutSine)
               .SetLoops(-1, LoopType.Yoyo);
    }

    void StopBreath()
    {
        if (_aura == null) return;
        DOTween.Kill(_aura);
        _aura.color = new Color(CoolingColor.r, CoolingColor.g, CoolingColor.b, 0.05f);
    }

    void OnDisable()
    {
        // 面板收起时不烧 CPU（tail tween 也要清，否则会打在已禁用对象上）
        if (_aura != null) DOTween.Kill(_aura);
        DOTween.Kill(transform);
    }

    void OnDestroy()
    {
        if (_aura != null) DOTween.Kill(_aura);
        DOTween.Kill(transform);
    }
}

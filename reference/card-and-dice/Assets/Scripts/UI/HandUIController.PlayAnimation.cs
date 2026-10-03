// =============================================================================
// 模块：HandUIController 打出飞出动画（partial 拆分 2026-08-18，纯机械搬运逻辑零修改）
// 原文件：HandUIController.cs（拆分后本文件只管"打出的卡飞向弃牌堆"的动画）
// 动画参数（★用户 2026-08-16 定稿 v6）：0.2s 缩小 + 0.5s 抛物线 arc=800 Ease.InQuad
// =============================================================================
using UnityEngine;
using DG.Tweening;

public partial class HandUIController
{
    // ------------------------------------------------------------------
    // 打出飞出动画（P8，★用户 2026-08-16 定稿：快速缩小 → 直线飞到弃牌堆数字 → 消失）
    // 目标点自动取场景 UICanvas/DiscardPileCountText 的位置（换算到 HandAreaRoot 局部坐标）
    // ------------------------------------------------------------------
    [Header("打出飞出动画")]
    [Tooltip("弃牌堆数字（场景 UICanvas/DiscardPileCountText）。留空则自动按名字查找。")]
    [SerializeField] private RectTransform _discardPileTarget;

    [Tooltip("找不到弃牌堆目标时的兜底位置（HandAreaRoot 局部 anchoredPosition）。实测正确值约 (775, -63)。")]
    [SerializeField] private Vector2 _discardPileAnchor = new Vector2(775f, -63f);

    [Tooltip("缩小时长（秒），与飞行并行。★用户指定 0.2s。")]
    [SerializeField] private float _shrinkDuration = 0.2f;

    [Tooltip("飞到弃牌堆总时长（秒）。★用户指定 0.5s（其中前 0.2s 同时在缩小）。")]
    [SerializeField] private float _flyDuration = 0.5f;

    [Tooltip("抛物线拱起高度（像素）：起点-终点连线中点向上抬这么多。调高=打出后往上飞更高。")]
    [SerializeField] private float _flyArcHeight = 800f;

    [Tooltip("飞行结束缩放 = 预制体缩放 × 此系数（如 1.4×0.3=0.42）。")]
    [SerializeField] private float _flyEndScaleFactor = 0.3f;

    /// <summary>
    /// P8：打出路径收尾（CardView.OnEndDrag 超阈值且能量足够时调用）。
    /// 动画（★用户 2026-08-16 定稿）：快速缩小 + 直线飞到弃牌堆 → 销毁。
    /// 其余手牌由 HandleCardDiscarded → RefreshHandLayout 全量重排。
    /// </summary>
    public void NotifyCardPlayed(CardView cv)
    {
        if (_activeCard == cv) _activeCard = null;
        _dragExceededThreshold = false;
        _fannedHoverCard = null;

        if (cv == null) return;

        // 0) 标记飞出中：屏蔽该卡的悬停/恢复/点击/拖动
        //    （否则飞行中经过鼠标触发 OnPointerExit 恢复逻辑，把缩小的卡又变回原大）
        cv.IsFlyingOut = true;

        // 1) 从手牌实例列表摘除（不被 RefreshHandLayout / ClearAllCardViews 销毁）
        if (_cardViewInstances.Contains(cv)) _cardViewInstances.Remove(cv);
        if (!_playedCardAnimations.Contains(cv)) _playedCardAnimations.Add(cv);

        // 2) 置顶 + 清理残留 Tween
        cv.transform.SetAsLastSibling();
        DOTween.Kill(cv.transform);
        var rt = cv.transform as RectTransform;
        if (rt == null) return;
        DOTween.Kill(rt);

        // 3) 0.1s 快速缩小（预制体缩放×系数）
        float prefabScale = CardViewPrefab != null ? CardViewPrefab.transform.localScale.x : 1.4f;
        cv.transform.DOScale(prefabScale * _flyEndScaleFactor, _shrinkDuration).SetEase(Ease.OutQuad);

        // 4) 0.5s 抛物线飞行（二次贝塞尔：P0 起点 → P1 中点上抬 _flyArcHeight → P2 弃牌堆）
        Vector2 p0 = rt.anchoredPosition;
        Vector2 p2 = GetDiscardPileAnchor();
        Vector2 p1 = (p0 + p2) * 0.5f + Vector2.up * _flyArcHeight;

        DOTween.To(() => 0f, t =>
        {
            // 二次贝塞尔插值：B(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
            float u = 1f - t;
            rt.anchoredPosition = u * u * p0 + 2f * u * t * p1 + t * t * p2;
        }, 1f, _flyDuration)
        .SetEase(Ease.InQuad) // ★用户要求：前半慢（爬升到顶点）、过顶点后加速俯冲
        .OnUpdate(() =>
        {
            // 每帧保持置顶：RefreshHandLayout 新建的手牌会插到后面，把飞行中的卡盖住造成"闪烁"
            if (cv != null) cv.transform.SetAsLastSibling();
        })
        .OnComplete(() =>
        {
            _playedCardAnimations.Remove(cv);
            if (cv != null) Destroy(cv.gameObject);
        });
    }

    /// <summary>
    /// 获取弃牌堆目标点（HandAreaRoot 局部 anchoredPosition）。
    /// 优先用 Inspector 指定的 _discardPileTarget（UICanvas/DiscardPileCountText），
    /// 运行时换算成 HandAreaRoot 局部坐标；找不到用兜底值 _discardPileAnchor。
    /// </summary>
    private Vector2 GetDiscardPileAnchor()
    {
        if (_discardPileTarget == null)
        {
            var go = GameObject.Find("DiscardPileCountText");
            if (go != null) _discardPileTarget = go.transform as RectTransform;
        }

        var rootRT = HandAreaRoot as RectTransform;
        if (_discardPileTarget != null && rootRT != null)
        {
            // 世界坐标 → 屏幕坐标（Overlay 画布 camera=null）→ HandAreaRoot 局部坐标
            Vector2 screenPos = RectTransformUtility.WorldToScreenPoint(null, _discardPileTarget.position);
            if (RectTransformUtility.ScreenPointToLocalPointInRectangle(rootRT, screenPos, null, out Vector2 local))
            {
                return local;
            }
        }
        return _discardPileAnchor;
    }
}

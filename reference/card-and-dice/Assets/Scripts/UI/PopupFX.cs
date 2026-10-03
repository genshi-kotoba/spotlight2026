// =============================================================================
// 模块：UI - PopupFX 弹窗入场动效（全局统一手感）
// 用途：任何「SetActive(true) 瞬开」的弹窗调 PopupFX.PlayOpen(根节点) 即可获得
//       淡入 + 轻微缩放进场；走路丝滑之后，弹窗也要同一套手感。
// 设计依据：docs/2026-09-12_战后结算改右侧汇报条-design.md §4（弹窗动画统一）
// 实现：DOTween（项目已集成）；不依赖 Animator / 序列化资源。
// =============================================================================
using UnityEngine;
using DG.Tweening;

/// <summary>
/// 弹窗动效统一入口。两处约定：
///  1. 传「面板 RectTransform」（能拿到缩放的那层），不是全屏遮罩层；
///  2. CanvasGroup 由本方法自动补，alpha 从 0 → 1，缩放从 0.94 → 原始。
/// 关闭时不需要配套动画（瞬关干脆，符合「进场有仪式、退场不拖沓」的手感定调）。
/// </summary>
public static class PopupFX
{
    /// <summary>入场时长（秒）。所有弹窗统一，改这里即全局生效。</summary>
    public const float OpenDuration = 0.15f;

    /// <summary>
    /// 便捷重载：从全屏遮罩根（InventoryUIKit.CreateOverlay 的产物）找名为 "Panel" 的子面板做动画。
    /// </summary>
    public static void PlayOpen(RectTransform overlayRoot, string panelName = "Panel")
    {
        if (overlayRoot == null) return;
        RectTransform panel = overlayRoot.transform.Find(panelName) as RectTransform;
        if (panel == null) panel = overlayRoot;                 // 没有子面板就对自己做
        PlayOpen(panel);
    }

    /// <summary>
    /// 播放入场动画。root 面板当前未激活时无效（先 SetActive(true) 再调）。
    /// 同一面板重复调用会先 Kill 上一次的 Tween，不会叠加。
    /// </summary>
    public static void PlayOpen(RectTransform panel)
    {
        if (panel == null || !panel.gameObject.activeInHierarchy) return;

        CanvasGroup cg = panel.GetComponent<CanvasGroup>();
        if (cg == null) cg = panel.gameObject.AddComponent<CanvasGroup>();

        Vector3 baseScale = panel.localScale;      // 每次以当前值为基准（场景序列化的面板可能非 1）
        DOTween.Kill(cg);
        DOTween.Kill(panel);

        cg.alpha = 0f;
        cg.interactable = false;                    // 动画期间不可点，防连点穿透

        cg.DOFade(1f, OpenDuration).SetEase(Ease.OutQuad)
          .OnComplete(() => cg.interactable = true);
        panel.localScale = baseScale * 0.94f;
        panel.DOScale(baseScale, OpenDuration).SetEase(Ease.OutQuad);
    }
}

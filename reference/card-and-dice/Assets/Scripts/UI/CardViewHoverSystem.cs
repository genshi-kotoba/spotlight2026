// =============================================================================
// 模块：M5a 卡牌视图悬停系统 CardViewHoverSystem
// 用途：鼠标悬停手牌时，在独立的放大卡牌视图上显示卡牌详情
// 参考：NSWells《杀戮尖塔》P4 Hover System
// 架构：单例 + 独立悬停 CardView 实例（不破坏手牌布局）
// 工作流：
//   1. 场景 UICanvas 下挂一个放大版 CardViewUI（默认 SetActive(false)）
//   2. 每张手牌的 CardView 实现 IPointerEnter/Exit
//   3. 进入时：手牌 wrapper 隐藏（视觉上"拿起"）→ 悬停视图显示并对齐
//   4. 离开时：悬停视图隐藏 → 手牌 wrapper 恢复
// =============================================================================
using UnityEngine;

/// <summary>
/// 卡牌悬停系统（单例）。
/// 持有一个场景中的独立放大卡牌视图，鼠标悬停手牌时启用显示。
/// </summary>
public class CardViewHoverSystem : SingletonBase
{
    [Header("悬停卡牌视图（场景中实例，不是预制体）")]
    [Tooltip("从 Hierarchy 拖场景 UICanvas 下的 HoverCardView 实例到这里。\n" +
             "要求：已放大、最上层、默认 SetActive(false)、无交互事件。")]
    public CardView HoverCardView;

    [Header("显示位置偏移")]
    [Tooltip("悬停卡牌相对鼠标位置的偏移（Canvas 屏幕空间像素）。\n" +
             "正值=右上，负值=左下，避免鼠标挡住卡牌正文")]
    public Vector2 HoverOffset = new Vector2(30f, 40f);

    [Header("调试")]
    [Tooltip("运行时查看：当前悬停的卡牌运行时实例")]
    public Card CurrentHoveredCard;

    // ------------------------------------------------------------------
    // 单例强类型访问器（SingletonBase 返回的是 SingletonBase，这里转成具体类型）
    // ------------------------------------------------------------------
    public static CardViewHoverSystem Instance
    {
        get
        {
            if (s_instance == null)
            {
                Debug.LogWarning("[CardViewHoverSystem] 场景里没有挂 CardViewHoverSystem 组件！");
                return null;
            }
            return s_instance as CardViewHoverSystem;
        }
    }

    // ------------------------------------------------------------------
    // 公开 API
    // ------------------------------------------------------------------

    /// <summary>
    /// 显示悬停卡牌。
    /// 调用方：CardView 实现的 IPointerEnter 回调。
    /// </summary>
    /// <param name="card">手牌对应的运行时卡牌实例</param>
    /// <param name="screenPosition">鼠标屏幕坐标（Input.mousePosition，左下角为原点）</param>
    public void Show(Card card, Vector2 screenPosition)
    {
        if (HoverCardView == null || card == null) return;

        CurrentHoveredCard = card;

        // 用 SetCard 把运行时实例灌到悬停卡牌视图上
        HoverCardView.SetCard(card);

        // 设置位置：鼠标坐标 + 偏移（Canvas 是 Screen Space Overlay，直接用屏幕坐标转 localPosition）
        RectTransform canvasRT = HoverCardView.GetComponentInParent<Canvas>()?.GetComponent<RectTransform>();
        if (canvasRT != null)
        {
            // Screen Space Overlay：屏幕像素 → 局部坐标，减去 Canvas 半尺寸
            Vector2 localPos;
            RectTransformUtility.ScreenPointToLocalPointInRectangle(
                canvasRT,
                screenPosition + HoverOffset,
                null,
                out localPos);
            HoverCardView.transform.localPosition = localPos;
        }
        else
        {
            // 兜底：直接屏幕坐标（World Space Canvas 时另处理）
            HoverCardView.transform.position = screenPosition + HoverOffset;
        }

        // 启用显示（最后一步，免得看到半初始化的卡）
        HoverCardView.gameObject.SetActive(true);
    }

    /// <summary>
    /// 隐藏悬停卡牌。
    /// 调用方：CardView 实现的 IPointerExit 回调。
    /// </summary>
    public void Hide()
    {
        CurrentHoveredCard = null;
        if (HoverCardView != null)
        {
            HoverCardView.gameObject.SetActive(false);
        }
    }
}

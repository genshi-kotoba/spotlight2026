// =============================================================================
// 模块：M7 装填 - LoadoutToastUI 右下角小提示条
// 用途：非教程期「拿到新卡 → 自动装填」时，右下角弹一条「xx 已自动装填」，2 秒后淡出。
// 设计依据：用户 2026-09-13 需求——自动装填要有可见反馈，但不能打断玩家操作。
// 实现要点：
//   · 静态入口 LoadoutToastUI.Show(msg)，首次调用时自建 ScreenSpaceOverlay 画布
//     （sortingOrder 900，低于教学提示卡的 1000）。
//   · **不挂 GraphicRaycaster**：整层完全不参与射线 → 连按钮都点不到它，纯视觉提示。
//   · 栈式堆叠：最新一条在最上面（贴近屏幕底），最多同时 3 条，超出挤掉最旧的。
//   · 场景重载后静态引用要能自愈：OnDestroy 里 `this == null` 判空，下次 Show 重建。
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class LoadoutToastUI : MonoBehaviour
{
    private const float W = 300f;
    private const float H = 36f;
    private const float GAP = 6f;
    private const float MARGIN = 24f;
    private const int MAX_ITEMS = 3;
    private const float HOLD = 2.0f;
    private const float FADE = 0.45f;

    private static readonly Color C_BROWN = new Color(0.106f, 0.067f, 0.024f, 0.94f);
    private static readonly Color C_BRASS = new Color(0.89f, 0.71f, 0.40f, 0.85f);
    private static readonly Color C_CREAM = new Color(0.965f, 0.894f, 0.769f, 1f);

    private static LoadoutToastUI _inst;

    private RectTransform _stack;                          // 右下角堆叠容器
    private readonly List<CanvasGroup> _items = new List<CanvasGroup>();

    // ------------------------------------------------------------------
    // 对外入口
    // ------------------------------------------------------------------
    /// <summary>右下角弹一条小提示。任何异常都不外抛——提示失败绝不能影响玩法主链路。</summary>
    public static void Show(string message)
    {
        if (string.IsNullOrEmpty(message)) return;
        try
        {
            if (_inst == null)
            {
                var go = new GameObject("LoadoutToastUI");
                _inst = go.AddComponent<LoadoutToastUI>();   // AddComponent 立即跑 Awake → _inst 赋值
            }
            if (_inst == null) return;
            _inst.Push(message);
        }
        catch (System.Exception e)
        {
            Debug.LogWarning($"[LoadoutToast] 提示条创建失败（忽略）：{e.Message}");
        }
    }

    private void Awake()
    {
        _inst = this;
        Build();
    }

    private void OnDestroy()
    {
        if (_inst == this) _inst = null;
    }

    // ------------------------------------------------------------------
    // 构建
    // ------------------------------------------------------------------
    private void Build()
    {
        var canvasGO = new GameObject("LoadoutToastCanvas");
        canvasGO.transform.SetParent(transform, false);
        var canvas = canvasGO.AddComponent<Canvas>();
        canvas.renderMode = RenderMode.ScreenSpaceOverlay;
        canvas.sortingOrder = 900;
        // ★刻意不加 GraphicRaycaster：这一层不参与任何点击，纯提示。

        _stack = new GameObject("Stack", typeof(RectTransform)).GetComponent<RectTransform>();
        _stack.SetParent(canvasGO.transform, false);
        _stack.anchorMin = new Vector2(1f, 0f);
        _stack.anchorMax = new Vector2(1f, 0f);
        _stack.pivot = new Vector2(1f, 0f);
        _stack.sizeDelta = Vector2.zero;
        _stack.anchoredPosition = new Vector2(-MARGIN, MARGIN);
    }

    // ------------------------------------------------------------------
    // 入栈 / 出栈
    // ------------------------------------------------------------------
    private void Push(string message)
    {
        if (_stack == null) return;

        while (_items.Count >= MAX_ITEMS) RemoveItem(_items[_items.Count - 1]);

        var itemGO = new GameObject("Toast", typeof(RectTransform));
        itemGO.transform.SetParent(_stack, false);
        var rt = itemGO.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(1f, 0f);
        rt.anchorMax = new Vector2(1f, 0f);
        rt.pivot = new Vector2(1f, 0f);
        rt.sizeDelta = new Vector2(W, H);

        var cg = itemGO.AddComponent<CanvasGroup>();
        cg.blocksRaycasts = false;
        cg.interactable = false;

        var bg = itemGO.AddComponent<Image>();
        bg.color = C_BROWN;
        bg.raycastTarget = false;
        var outline = itemGO.AddComponent<Outline>();
        outline.effectColor = C_BRASS;
        outline.effectDistance = new Vector2(2f, -2f);

        var txtGO = new GameObject("Txt", typeof(RectTransform));
        txtGO.transform.SetParent(itemGO.transform, false);
        var txt = txtGO.AddComponent<Text>();
        txt.font = InventoryUIKit.SafeFont;
        txt.text = message;
        txt.color = C_CREAM;
        txt.fontSize = 15;
        txt.alignment = TextAnchor.MiddleLeft;
        txt.horizontalOverflow = HorizontalWrapMode.Overflow;
        txt.verticalOverflow = VerticalWrapMode.Truncate;
        txt.raycastTarget = false;
        var trt = txt.rectTransform;
        trt.anchorMin = Vector2.zero;
        trt.anchorMax = Vector2.one;
        trt.offsetMin = new Vector2(12f, 0f);
        trt.offsetMax = new Vector2(-8f, 0f);

        _items.Insert(0, cg);      // 最新一条在最上（最靠近屏幕底部）
        Relayout();
        StartCoroutine(Lifetime(cg));
    }

    private void RemoveItem(CanvasGroup cg)
    {
        _items.Remove(cg);
        if (cg != null && cg.gameObject != null) Destroy(cg.gameObject);
        Relayout();
    }

    private void Relayout()
    {
        for (int i = 0; i < _items.Count; i++)
        {
            CanvasGroup cg = _items[i];
            if (cg == null) continue;
            var rt = cg.GetComponent<RectTransform>();
            if (rt != null) rt.anchoredPosition = new Vector2(0f, i * (H + GAP));
        }
    }

    private IEnumerator Lifetime(CanvasGroup cg)
    {
        yield return new WaitForSecondsRealtime(HOLD);

        float t = 0f;
        while (t < FADE)
        {
            t += Time.unscaledDeltaTime;
            if (cg == null) yield break;                 // 被挤掉 / 场景卸载
            cg.alpha = 1f - Mathf.Clamp01(t / FADE);
            yield return null;
        }
        RemoveItem(cg);
    }
}

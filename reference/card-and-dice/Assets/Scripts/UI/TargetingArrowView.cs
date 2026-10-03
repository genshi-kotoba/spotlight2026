// =============================================================================
// 模块：M5b-2 指向箭头视图 TargetingArrowView
// 用途：有指向卡牌拖过分界线后，从停泊卡牌到鼠标位置画一条"线 + 箭头头"，
//       玩家用它选定攻击目标（杀戮尖塔式指向）。
// 设计依据：docs/superpowers/specs/2026-08-18-card-play-interaction-targeting-design.md §四
// 参考教程：NSWells P17 Arrow View（视频用 SpriteRenderer + LineRenderer 的 2D 世界空间方案；
//           本项目卡牌在 UGUI Overlay 画布，改为纯 UI 实现——线=拉伸 Image，头=三角 Sprite）
// 实现说明：
//   - 纯 C# 类（非 MonoBehaviour），由 HandUIController 每帧驱动 SetEndpoints。
//   - 三角箭头 sprite 运行时生成（免美术资产/免改预制体），pivot 设在尖端（P17 同款处理）。
//   - 颜色：默认奶黄（美术基调 #F6E4C4），指向有效目标时整条变绿（#2ECC71）。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

public class TargetingArrowView
{
    /// <summary>箭头默认颜色（奶黄，美术基调）</summary>
    private static readonly Color NormalColor = new Color(0.96f, 0.89f, 0.77f);
    /// <summary>指向有效目标时的颜色（绿）</summary>
    private static readonly Color ValidColor = new Color(0.18f, 0.80f, 0.44f);

    private RectTransform _root;      // 箭头根节点（挂画布顶层）
    private RectTransform _line;       // 线段（拉伸 Image）
    private Image _lineImage;
    private RectTransform _head;       // 箭头头（三角 Sprite）
    private Image _headImage;
    private Canvas _canvas;            // 所属画布（Overlay）
    private bool _visible = false;

    /// <summary>三角箭头 sprite（懒生成，pivot 在尖端）</summary>
    private static Sprite _headSprite;

    /// <summary>
    /// 显示箭头：在指定画布下懒构建 UI 对象并激活。
    /// </summary>
    /// <param name="canvas">卡牌所在画布（一般 UICanvas，ScreenSpaceOverlay）</param>
    public void Show(Canvas canvas)
    {
        if (canvas == null) return;
        _canvas = canvas;

        if (_root == null)
        {
            BuildUI(canvas);
        }
        _root.gameObject.SetActive(true);
        _root.SetAsLastSibling(); // 始终盖在卡牌之上
        _visible = true;
    }

    /// <summary>隐藏箭头（对象保留，下次 Show 复用）</summary>
    public void Hide()
    {
        if (_root != null) _root.gameObject.SetActive(false);
        _visible = false;
    }

    /// <summary>是否正在显示</summary>
    public bool IsVisible => _visible;

    /// <summary>
    /// 每帧更新箭头两端与颜色。
    /// </summary>
    /// <param name="startScreen">起点屏幕坐标（停泊卡牌顶部，WorldToScreenPoint 换算）</param>
    /// <param name="endScreen">终点屏幕坐标（鼠标位置）</param>
    /// <param name="validTarget">鼠标下是否为有效目标（true=绿色）</param>
    public void SetEndpoints(Vector2 startScreen, Vector2 endScreen, bool validTarget)
    {
        if (!_visible || _canvas == null) return;

        // 两端统一：屏幕坐标 → 画布局部（Overlay 画布 camera=null）
        Vector2 startLocal, endLocal;
        if (!RectTransformUtility.ScreenPointToLocalPointInRectangle(
                _canvas.transform as RectTransform, startScreen, null, out startLocal))
        {
            return;
        }
        if (!RectTransformUtility.ScreenPointToLocalPointInRectangle(
                _canvas.transform as RectTransform, endScreen, null, out endLocal))
        {
            return;
        }

        Vector2 delta = endLocal - startLocal;
        float length = delta.magnitude;
        if (length < 1f) length = 1f;
        float angle = Mathf.Atan2(delta.y, delta.x) * Mathf.Rad2Deg;

        // ---- 线段：pivot 在左中（(0,0.5)），从起点沿角度拉伸 ----
        _line.anchoredPosition = startLocal;
        _line.sizeDelta = new Vector2(length, LineWidth);
        _line.localRotation = Quaternion.Euler(0f, 0f, angle);

        // ---- 箭头头：中心在鼠标位置，旋转对齐方向 ----
        _head.anchoredPosition = endLocal;
        _head.localRotation = Quaternion.Euler(0f, 0f, angle);

        // ---- 颜色：有效目标=绿 ----
        Color c = validTarget ? ValidColor : NormalColor;
        _lineImage.color = c;
        _headImage.color = c;

        _root.SetAsLastSibling();
    }

    /// <summary>箭头顶点相对鼠标的偏移（头中心对准鼠标即可， Demo 不做尖端修正）</summary>
    private const float LineWidth = 6f;
    private const float HeadSize = 30f;

    /// <summary>
    /// 构建箭头 UI 对象（代码构建，免改预制体）：
    ///   root（空 RectTransform，挂画布）
    ///   ├── Line（Image，无 sprite = 白色方块，pivot 左中）
    ///   └── Head（Image，三角 sprite，pivot 中心）
    /// </summary>
    private void BuildUI(Canvas canvas)
    {
        // 根节点
        var rootGo = new GameObject("TargetingArrow", typeof(RectTransform));
        _root = rootGo.GetComponent<RectTransform>();
        _root.SetParent(canvas.transform, false);
        _root.sizeDelta = Vector2.zero;

        // 线段
        var lineGo = new GameObject("Line", typeof(RectTransform), typeof(Image));
        _line = lineGo.GetComponent<RectTransform>();
        _line.SetParent(_root, false);
        _line.pivot = new Vector2(0f, 0.5f);   // 左中：anchoredPosition 即线起点
        _line.sizeDelta = new Vector2(100f, LineWidth);
        _lineImage = lineGo.GetComponent<Image>();
        _lineImage.color = NormalColor;
        _lineImage.raycastTarget = false;       // 不挡鼠标事件

        // 箭头头
        var headGo = new GameObject("Head", typeof(RectTransform), typeof(Image));
        _head = headGo.GetComponent<RectTransform>();
        _head.SetParent(_root, false);
        _head.sizeDelta = new Vector2(HeadSize * 1.4f, HeadSize);
        _headImage = headGo.GetComponent<Image>();
        _headImage.sprite = GetOrCreateHeadSprite();
        _headImage.color = NormalColor;
        _headImage.raycastTarget = false;
    }

    /// <summary>
    /// 生成三角箭头 sprite（36×24，向右的实心三角，pivot 在尖端 (0.95, 0.5)）。
    /// sprite 静态缓存，全场景共用一份。
    /// </summary>
    private static Sprite GetOrCreateHeadSprite()
    {
        if (_headSprite != null) return _headSprite;

        int w = 36, h = 24;
        var tex = new Texture2D(w, h, TextureFormat.RGBA32, false);
        tex.wrapMode = TextureWrapMode.Clamp;

        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                // 归一化到 [-0.5, 0.5]，判断是否在向右三角内：
                // 尖端在右 (0.5, 0)，底边在左 x=-0.5，上下斜边收拢
                float nx = x / (float)(w - 1) - 0.5f;
                float ny = y / (float)(h - 1) - 0.5f;
                // 三角内部条件：|ny| <= (0.5 - nx) * 半高比（nx=-0.5 底边最宽，nx=0.5 收为尖）
                bool inside = Mathf.Abs(ny) <= (0.5f - nx) * 0.98f;
                tex.SetPixel(x, y, inside ? Color.white : Color.clear);
            }
        }
        tex.Apply();

        _headSprite = Sprite.Create(tex, new Rect(0, 0, w, h), new Vector2(0.92f, 0.5f), 100f);
        return _headSprite;
    }
}

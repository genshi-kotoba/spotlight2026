// =============================================================================
// 模块：Tutorial - 情境提示卡 TipCard（主力教学 UI）
// 用途：屏幕角落弹出一张「深棕底 + 黄铜细边 + 星盘角标 + 知道了按钮 + 指向引线」的卡，
//       教完一条就淡出，不同时显示两张（由 TutorialDirector 串行控制）。
// 设计依据：docs/tutorial-design.md §3.A（深棕 #1b1106 / 黄铜 #E3B567 / 奶黄 #F6E4C4 / 铜红 #D97D5B）。
// 实现要点：
//   - 自带 ScreenSpaceOverlay 画布（sortOrder 1000，仅按钮吃射线，面板透明穿透 = 不挡棋盘）。
//     ★2026-09-17 起同带 CanvasScaler（1920×1080，与场景 HUD 一致）；整套尺寸同步放大 ×1.2。
//   - 自建组件，视觉语言与各系统统一，不依赖 InventoryUIKit 内部 API。
//   - 挂载到 TutorialDirector 的独立子 GameObject (TipHolder) 上，避免与承载 holder 互锁 SetActive。
//   - Awake/Show/Hide 通过 _canvasGO.SetActive 控制画布显隐（不动承载 holder）。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

namespace Tutorial
{
    public class TutorialTipCardUI : MonoBehaviour
    {
        // ======== 视觉常量（维多利亚 × 神秘学双分流） ========
        private static readonly Color C_BROWN = new Color(0.106f, 0.067f, 0.024f, 0.96f); // #1b1106
        private static readonly Color C_BRASS = new Color(0.89f, 0.71f, 0.40f, 1f);        // #E3B567
        private static readonly Color C_CREAM = new Color(0.965f, 0.894f, 0.769f, 1f);     // #F6E4C4
        private static readonly Color C_COPPER = new Color(0.851f, 0.490f, 0.357f, 1f);    // #D97D5B
        private static readonly Color C_MYSTIC = new Color(0.31f, 0.82f, 0.88f, 1f);       // 青蓝奥术

        // ★2026-09-17 整体 ×1.2（用户要求「框和字放大」）：卡 420×200 → 504×240、字 22/16 → 26/19。
        //   同日补上 CanvasScaler（1920×1080，与场景 HUD 一致）——此前本画布没有缩放基准，
        //   是全游戏唯一不随分辨率缩放的界面：屏越大它相对越小（导出包全屏时尤其明显）。
        private const float CARD_W = 504f;
        private const float CARD_H = 240f;
        private const float MARGIN = 28f;
        /// <summary>★2026-09-13 顶部额外下移量（px）。
        /// 原因：顶栏左侧的消耗品栏（StatusBar/ConsumableBar，3 格）占据屏幕上沿往下约 56px 的区间，
        /// 提示卡原来贴顶 24px 会把它的右半截盖住 —— 而 S28 起消耗品栏才显示，正是教学要指着它讲的那几拍。
        /// +60 后卡片上沿落在顶栏下方，留出约 28px 间隙；左右/底部边距不受影响。
        /// ★2026-09-17 随整体 ×1.2 调为 72（顶栏本身也按同一缩放基准，避让量同倍放大才保持恒定间隙）。</summary>
        private const float TOP_EXTRA = 72f;
        /// <summary>引线端点与高亮框边界的间隙（px）。</summary>
        private const float LeaderGap = 6f;

        private GameObject _canvasGO;
        private Canvas _canvas;   // ★2026-09-17 缓存：引线画线时读 scaleFactor（物理像素→局部单位）
        private RectTransform _panelRT;
        private Text _titleTxt, _bodyTxt;
        private Button _confirmBtn;
        private GameObject _leaderGO;
        private Image _leaderImg;

        private System.Action _onConfirm;
        /// <summary>焦点屏幕坐标 getter（每帧求值）：镜头动了 / 目标动了，引线跟着走。</summary>
        private System.Func<Vector2?> _focusGetter;
        /// <summary>焦点高亮框的屏幕矩形 getter（每帧求值）：引线端点截断在框边界，不穿进框里。</summary>
        private System.Func<Rect?> _focusRectGetter;

        private void Awake()
        {
            Build();
            // 只关自己的画布（不再用 gameObject.SetActive(false)，避免误关承载 holder / Director）
            if (_canvasGO != null) _canvasGO.SetActive(false);
        }

        private void Build()
        {
            _canvasGO = new GameObject("TutorialTipCanvas");
            _canvasGO.transform.SetParent(transform, false);
            // ★2026-09-17 补齐缩放基准：与 MainScene/TutorialScene 的 UICanvas 完全一致
            //（1920×1080, match 0.5）→ 教程卡在任何分辨率都与 HUD 同比例缩放。
            _canvas = _canvasGO.AddComponent<Canvas>();
            _canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            _canvas.sortingOrder = 1000;
            var scaler = _canvasGO.AddComponent<CanvasScaler>();
            scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
            scaler.referenceResolution = new Vector2(1920f, 1080f);
            scaler.matchWidthOrHeight = 0.5f;
            // 射线必须开启：卡片按钮需要点击；但面板本身 raycastTarget=false，不挡棋盘。
            _canvasGO.AddComponent<GraphicRaycaster>();

            // 面板：外黄铜框 + 内深棕底
            var frameGO = new GameObject("CardFrame");
            frameGO.transform.SetParent(_canvasGO.transform, false);
            var frame = frameGO.AddComponent<Image>();
            frame.color = C_BRASS;
            frame.raycastTarget = false;
            _panelRT = frame.rectTransform;
            _panelRT.anchorMin = new Vector2(0f, 1f); _panelRT.anchorMax = new Vector2(0f, 1f);
            _panelRT.pivot = new Vector2(0f, 1f);
            _panelRT.sizeDelta = new Vector2(CARD_W, CARD_H);

            var innerGO = new GameObject("CardInner");
            innerGO.transform.SetParent(frameGO.transform, false);
            var inner = innerGO.AddComponent<Image>();
            inner.color = C_BROWN; inner.raycastTarget = false;
            var irt = inner.rectTransform;
            irt.anchorMin = Vector2.zero; irt.anchorMax = Vector2.one;
            irt.offsetMin = new Vector2(5f, 5f); irt.offsetMax = new Vector2(-5f, -5f);

            // 星盘角标（左上）
            var starGO = new GameObject("Star");
            starGO.transform.SetParent(frameGO.transform, false);
            var star = starGO.AddComponent<Text>();
            star.font = GetSafeFont();
            star.text = "✶"; star.color = C_MYSTIC;
            star.fontSize = 26; star.alignment = TextAnchor.MiddleCenter;
            star.raycastTarget = false;
            var srt = star.rectTransform;
            srt.anchorMin = new Vector2(0f, 1f); srt.anchorMax = new Vector2(0f, 1f); srt.pivot = new Vector2(0.5f, 0.5f);
            srt.sizeDelta = new Vector2(34f, 34f); srt.anchoredPosition = new Vector2(22f, -22f);

            // 标题
            var titleGO = new GameObject("Title");
            titleGO.transform.SetParent(frameGO.transform, false);
            _titleTxt = titleGO.AddComponent<Text>();
            _titleTxt.font = GetSafeFont();
            _titleTxt.color = C_CREAM; _titleTxt.fontSize = 26; _titleTxt.fontStyle = FontStyle.Bold;
            _titleTxt.raycastTarget = false; _titleTxt.horizontalOverflow = HorizontalWrapMode.Wrap;
            var trt = _titleTxt.rectTransform;
            trt.anchorMin = new Vector2(0f, 1f); trt.anchorMax = new Vector2(1f, 1f); trt.pivot = new Vector2(0.5f, 1f);
            trt.offsetMin = new Vector2(48f, -65f); trt.offsetMax = new Vector2(-19f, -34f);

            // 标题下划线（铜红）
            var ulGO = new GameObject("Underline");
            ulGO.transform.SetParent(frameGO.transform, false);
            var ul = ulGO.AddComponent<Image>();
            ul.color = C_COPPER; ul.raycastTarget = false;
            var ulrt = ul.rectTransform;
            ulrt.anchorMin = new Vector2(0f, 1f); ulrt.anchorMax = new Vector2(0f, 1f); ulrt.pivot = new Vector2(0f, 1f);
            ulrt.sizeDelta = new Vector2(CARD_W - 67f, 3f); ulrt.anchoredPosition = new Vector2(48f, -70f);

            // 正文
            var bodyGO = new GameObject("Body");
            bodyGO.transform.SetParent(frameGO.transform, false);
            _bodyTxt = bodyGO.AddComponent<Text>();
            _bodyTxt.font = GetSafeFont();
            _bodyTxt.color = C_CREAM; _bodyTxt.fontSize = 19; _bodyTxt.raycastTarget = false;
            _bodyTxt.horizontalOverflow = HorizontalWrapMode.Wrap;
            _bodyTxt.verticalOverflow = VerticalWrapMode.Truncate;
            var brt = _bodyTxt.rectTransform;
            brt.anchorMin = new Vector2(0f, 1f); brt.anchorMax = new Vector2(1f, 1f); brt.pivot = new Vector2(0.5f, 1f);
            brt.offsetMin = new Vector2(48f, -204f); brt.offsetMax = new Vector2(-19f, -80f);

            // 「知道了」按钮（黄铜描边）
            var btnGO = new GameObject("ConfirmBtn");
            btnGO.transform.SetParent(frameGO.transform, false);
            _confirmBtn = btnGO.AddComponent<Button>();
            var btnImg = btnGO.AddComponent<Image>();
            btnImg.color = C_BROWN; btnImg.raycastTarget = true;
            var brtrt = _confirmBtn.GetComponent<RectTransform>();
            brtrt.anchorMin = new Vector2(1f, 0f); brtrt.anchorMax = new Vector2(1f, 0f); brtrt.pivot = new Vector2(1f, 0f);
            brtrt.sizeDelta = new Vector2(132f, 43f); brtrt.anchoredPosition = new Vector2(-19f, 14f);
            var btnTxtGO = new GameObject("Txt"); btnTxtGO.transform.SetParent(btnGO.transform, false);
            var btnTxt = btnTxtGO.AddComponent<Text>();
            btnTxt.font = GetSafeFont();
            btnTxt.text = "知道了"; btnTxt.color = C_BRASS; btnTxt.fontSize = 19;
            btnTxt.alignment = TextAnchor.MiddleCenter; btnTxt.raycastTarget = false;
            var btrt = btnTxt.rectTransform; btrt.anchorMin = Vector2.zero; btrt.anchorMax = Vector2.one;
            btrt.offsetMin = Vector2.zero; btrt.offsetMax = Vector2.zero;
            _confirmBtn.onClick.AddListener(() => OnConfirmClicked());

            // 引线（指向焦点，默认隐藏）
            _leaderGO = new GameObject("LeaderLine");
            _leaderGO.transform.SetParent(_canvasGO.transform, false);
            _leaderImg = _leaderGO.AddComponent<Image>();
            _leaderImg.color = C_BRASS; _leaderImg.raycastTarget = false;
            var lrt = _leaderImg.rectTransform;
            lrt.anchorMin = Vector2.zero; lrt.anchorMax = Vector2.zero; lrt.pivot = Vector2.zero;
            lrt.sizeDelta = new Vector2(0f, 2f); lrt.anchoredPosition = Vector2.zero;
            _leaderGO.SetActive(false);
        }

        private void OnConfirmClicked()
        {
            var cb = _onConfirm;
            _onConfirm = null;
            Hide();
            cb?.Invoke();
        }

        /// <summary>
        /// 显示一张提示卡。
        /// </summary>
        /// <param name="title">标题</param>
        /// <param name="body">正文（最多 3 行，超出截断）</param>
        /// <param name="showConfirm">是否显示「知道了」按钮（false=靠行为自动收起）</param>
        /// <param name="onConfirm">点「知道了」回调（点完自动 Hide）</param>
        /// <param name="focusScreenPoint">可选：从卡片拉一条引线指向该屏幕坐标（bottom-left 原点像素）</param>
        /// <summary>兼容旧调用：默认 Auto 角点、零偏移、画引线（静态焦点坐标）。</summary>
        public void Show(string title, string body, bool showConfirm, System.Action onConfirm, Vector2? focusScreenPoint = null)
            => Show(title, body, showConfirm, onConfirm, focusScreenPoint, TutorialBoxAnchor.Auto, Vector2.zero, true);

        /// <summary>兼容旧调用：静态焦点坐标版本（内部包成常量 getter）。</summary>
        public void Show(string title, string body, bool showConfirm, System.Action onConfirm, Vector2? focusScreenPoint,
                         TutorialBoxAnchor anchor, Vector2 offset, bool drawLeader)
            => Show(title, body, showConfirm, onConfirm,
                    focusScreenPoint.HasValue ? (System.Func<Vector2?>)(() => focusScreenPoint) : null,
                    anchor, offset, drawLeader);

        /// <summary>
        /// 显示一张提示卡（推荐版本：焦点坐标用 getter 每帧求值，引线实时刷新）。
        /// </summary>
        /// <param name="anchor">提示框固定角点；Auto = 原行为（焦点在左半屏→右上，否则左上）。</param>
        /// <param name="offset">相对角点的像素偏移（向右/下为正）。</param>
        /// <param name="drawLeader">是否从卡片拉引线指向焦点。</param>
        /// <param name="focusGetter">每帧求值的焦点屏幕坐标（bottom-left 原点像素）；null = 不画引线。</param>
        /// <param name="focusRectGetter">每帧求值的焦点高亮框屏幕矩形；提供时引线止步于框边界外 6px。</param>
        public void Show(string title, string body, bool showConfirm, System.Action onConfirm,
                         System.Func<Vector2?> focusGetter,
                         TutorialBoxAnchor anchor, Vector2 offset, bool drawLeader,
                         System.Func<Rect?> focusRectGetter = null)
        {
            _titleTxt.text = title;
            _bodyTxt.text = body;
            _onConfirm = onConfirm;
            _confirmBtn.gameObject.SetActive(showConfirm);
            _focusGetter = drawLeader ? focusGetter : null;
            _focusRectGetter = drawLeader ? focusRectGetter : null;

            Vector2? fp = _focusGetter != null ? _focusGetter() : null;
            ApplyAnchor(anchor, offset, fp);

            gameObject.SetActive(true);
            if (_canvasGO != null) _canvasGO.SetActive(true); // ★对应 Awake 的关闭：重新激活画布

            if (drawLeader && fp.HasValue) DrawLeaderLine(fp.Value);
            else _leaderGO.SetActive(false);
        }

        /// <summary>每帧重画引线：镜头 / 焦点目标移动后引线实时跟随（只重画线，卡片锚点不动）。</summary>
        private void LateUpdate()
        {
            if (_focusGetter == null || _canvasGO == null || !_canvasGO.activeSelf) return;
            Vector2? fp = _focusGetter();
            if (fp.HasValue) DrawLeaderLine(fp.Value);
            else _leaderGO.SetActive(false);
        }

        private void ApplyAnchor(TutorialBoxAnchor anchor, Vector2 offset, Vector2? focusScreenPoint)
        {
            // ★2026-09-13 用户定稿：所有教学提示框默认放于左上角（Auto 一律按 TopLeft 处理）
            if (anchor == TutorialBoxAnchor.Auto) anchor = TutorialBoxAnchor.TopLeft;

            float ax, ay; Vector2 pivot;
            if (anchor == TutorialBoxAnchor.TopLeft) { ax = 0f; ay = 1f; pivot = new Vector2(0f, 1f); }
            else if (anchor == TutorialBoxAnchor.TopRight) { ax = 1f; ay = 1f; pivot = new Vector2(1f, 1f); }
            else if (anchor == TutorialBoxAnchor.BottomLeft) { ax = 0f; ay = 0f; pivot = new Vector2(0f, 0f); }
            else if (anchor == TutorialBoxAnchor.BottomRight) { ax = 1f; ay = 0f; pivot = new Vector2(1f, 0f); }
            else { ax = 0.5f; ay = 0.5f; pivot = new Vector2(0.5f, 0.5f); }

            _panelRT.anchorMin = new Vector2(ax, ay); _panelRT.anchorMax = new Vector2(ax, ay); _panelRT.pivot = pivot;

            float ox = offset.x, oy = offset.y;
            if (ay == 1f) oy = -(MARGIN + TOP_EXTRA + offset.y);             // 上沿（额外避让顶栏消耗品栏）
            else if (ay == 0f) oy = (MARGIN + offset.y);                     // 下沿
            if (ax == 1f) ox = -(MARGIN + offset.x);                         // 右沿
            else if (ax == 0f) ox = (MARGIN + offset.x);                     // 左沿
            _panelRT.anchoredPosition = new Vector2(ox, oy);
        }

        /// <summary>画布缩放系数（CanvasScaler 1920×1080 驱动；未就绪时回退 1）。物理像素 ↔ 局部单位的换算因子。</summary>
        private float CanvasScale()
        {
            return _canvas != null && _canvas.scaleFactor > 0f ? _canvas.scaleFactor : 1f;
        }

        private void DrawLeaderLine(Vector2 focus)
        {
            // 端点：默认焦点中心；有高亮框时挂到「靠屏幕中心一侧」的边框上
            //（框在左半屏 → 从右边框伸出；框在右半屏 → 从左边框伸出），高度取焦点实际高度。
            Vector2 end = focus;
            Rect? bounds = _focusRectGetter != null ? _focusRectGetter() : null;
            if (bounds.HasValue && bounds.Value.width > 1f && bounds.Value.height > 1f)
            {
                Rect b = bounds.Value;
                bool boxLeftOfCenter = b.center.x < Screen.width * 0.5f;
                float ex = boxLeftOfCenter ? b.xMax + LeaderGap : b.xMin - LeaderGap;
                float ey = Mathf.Clamp(focus.y, b.yMin, b.yMax);
                end = new Vector2(ex, ey);
            }

            // 教程卡伸出侧：按卡片自身位置（靠屏幕中心一侧的边缘）
            // ★2026-09-17 接入 CanvasScaler 后：上面算出的 end 与这里取到的边缘都是**屏幕物理像素**，
            //   而引线是画布的子节点（局部单位）→ 除以 scaleFactor 换算后才能摆对位置。
            float sf = CanvasScale();
            Vector2 panelEdge = panelEdgeFor() / sf;
            Vector2 d2 = end / sf - panelEdge;
            float len = d2.magnitude;
            float ang = Mathf.Atan2(d2.y, d2.x) * Mathf.Rad2Deg;
            _leaderImg.rectTransform.anchoredPosition = panelEdge;
            _leaderImg.rectTransform.sizeDelta = new Vector2(len, 2f);
            _leaderImg.rectTransform.rotation = Quaternion.Euler(0f, 0f, ang);
            _leaderGO.SetActive(true);
        }

        /// <summary>引线从教程卡哪一侧伸出：按**卡片自身**位置定——
        /// 卡在左半屏 → 从右边缘（靠屏幕中心侧）伸出；卡在右半屏 → 从左边缘伸出。
        /// 不看焦点位置（手动设了 boxAnchor 后焦点在哪都得从卡片中心侧出）。</summary>
        private Vector2 panelEdgeFor()
        {
            var corners = new Vector3[4];
            _panelRT.GetWorldCorners(corners);
            bool cardLeftOfCenter = (corners[0].x + corners[2].x) * 0.5f < Screen.width * 0.5f;
            return cardLeftOfCenter
                ? new Vector2(corners[3].x, (corners[2].y + corners[3].y) * 0.5f)   // 右边缘中点
                : new Vector2(corners[0].x, (corners[0].y + corners[1].y) * 0.5f);  // 左边缘中点
        }

        public void Hide()
        {
            if (_canvasGO != null) _canvasGO.SetActive(false);
            _leaderGO?.SetActive(false);
            _focusGetter = null;
            _focusRectGetter = null;
            _onConfirm = null;
        }

        /// <summary>安全获取内置字体（跟随项目惯例：LegacyRuntime.ttf → Arial.ttf → 场景现有 Text 借用）。</summary>
        private static Font _cachedFont;
        private static Font GetSafeFont()
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
}
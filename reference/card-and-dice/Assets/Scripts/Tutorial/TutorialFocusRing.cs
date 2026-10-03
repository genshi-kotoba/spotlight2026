// =============================================================================
// 模块：Tutorial - 高亮圈 FocusRing（唯一新增 UI 组件）
// 用途：全屏暗化遮罩 + 在目标处「挖洞」+ 黄铜发光描边，把玩家注意力引到被教的对象。
// 设计依据：docs/tutorial-design.md §3.B（背景遮罩 #000 alpha0.45、描边处挖洞、1.2s 呼吸）。
// 实现要点：
//   - 自带一个 ScreenSpaceOverlay 画布（sortOrder 900，禁用射线 = 永不挡棋盘/HUD 点击）。
//   - 挖洞用自定义 Image 网格（矩形相减拼出「全屏 − N 个洞」的暗带），无需 shader。
//   - 支持三种目标：HUD 的 RectTransform / 世界坐标(敌人·格子) / 静态屏幕矩形。
//   - 目标可能移动（敌人·玩家），故每帧按 getter 重算洞与描边。
//   - mask 必须设白色 sprite，否则 CanvasRenderer 不会渲染重写 OnPopulateMesh 的 Image。
//
// ★2026-09-13 两处结构改动（用户需求）：
//   ① 单蒙版多洞：过去「主焦点 + 第二焦点」是**两个** FocusRing 实例，各自带一张全屏蒙版，
//      两处同时高亮时洞只挖了一个、另一处仍被压暗（S1 实锤的毛病）。现在第二焦点并入同一条
//      FocusRing 的同一张蒙版 → 一次挖多个洞，两处都是真亮。
//   ② Dim 模式（ShowDim）：整屏压暗、不挖洞不描边。用于「本拍要玩家点『知道了』、但场上没有
//      高亮目标」的拍 —— 画面全亮会让玩家误以为可以自由操作。
//
// ★2026-09-17：画布接入与场景 HUD 相同的 CanvasScaler（1920×1080, match 0.5）。
//   圈的语义不变 = 屏幕物理像素（世界目标 / HUD 节点都按物理像素投影）；
//   ComputeRect 统一除以 scaleFactor 输出画布局部单位（蒙版与描边用），
//   CurrentRect 对外仍换算回物理像素（提示卡引线截断用）。
//   World 模式的 halfPx 视作画布单位 → 渲染尺寸随分辨率与场景同比例（1080p 与旧值等价）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

namespace Tutorial
{
    /// <summary>带洞暗化遮罩：在本地像素空间画「整屏 − N 个洞」的暗带（矩形相减）。</summary>
    public class TutorialHoleMask : Image
    {
        /// <summary>要挖掉的洞（**画布局部单位**矩形，bottom-left 原点；由屏幕物理像素 ÷ scaleFactor 换算而来）。空表 = 整屏暗化。</summary>
        public readonly List<Rect> holes = new List<Rect>();

        protected override void OnPopulateMesh(VertexHelper vh)
        {
            vh.Clear();
            Rect r = rectTransform.rect;                 // 本地像素空间，=(0,0)-(w,h)
            Color c = color;

            // 从「整屏」出发，逐个减去洞 —— 剩下的矩形就是要画的暗带。
            // N=2 时最多产出几个矩形，开销可忽略。
            var regions = new List<Rect>(8) { r };
            for (int i = 0; i < holes.Count; i++)
            {
                Rect h = Clamp(holes[i], r);
                if (h.width <= 0.5f || h.height <= 0.5f) continue;
                var next = new List<Rect>(regions.Count + 3);
                for (int k = 0; k < regions.Count; k++) Subtract(regions[k], h, next);
                regions = next;
                if (regions.Count == 0) return;          // 整屏都被挖空 → 无需渲染
            }

            for (int i = 0; i < regions.Count; i++) AddQuad(vh, regions[i], c);
        }

        private static Rect Clamp(Rect h, Rect r)
        {
            float x0 = Mathf.Clamp(h.xMin, r.xMin, r.xMax);
            float y0 = Mathf.Clamp(h.yMin, r.yMin, r.yMax);
            float x1 = Mathf.Clamp(h.xMax, r.xMin, r.xMax);
            float y1 = Mathf.Clamp(h.yMax, r.yMin, r.yMax);
            return Rect.MinMaxRect(x0, y0, x1, y1);
        }

        /// <summary>a − b：无交集则原样保留 a，否则拆成最多 4 块（下 / 上 / 左 / 右）。</summary>
        private static void Subtract(Rect a, Rect b, List<Rect> outRects)
        {
            float x0 = Mathf.Max(a.xMin, b.xMin), x1 = Mathf.Min(a.xMax, b.xMax);
            float y0 = Mathf.Max(a.yMin, b.yMin), y1 = Mathf.Min(a.yMax, b.yMax);
            if (x1 - x0 <= 0.5f || y1 - y0 <= 0.5f) { outRects.Add(a); return; }

            if (y0 - a.yMin > 0.5f) outRects.Add(Rect.MinMaxRect(a.xMin, a.yMin, a.xMax, y0));   // 下
            if (a.yMax - y1 > 0.5f) outRects.Add(Rect.MinMaxRect(a.xMin, y1, a.xMax, a.yMax));   // 上
            if (x0 - a.xMin > 0.5f) outRects.Add(Rect.MinMaxRect(a.xMin, y0, x0, y1));           // 左
            if (a.xMax - x1 > 0.5f) outRects.Add(Rect.MinMaxRect(x1, y0, a.xMax, y1));           // 右
        }

        private void AddQuad(VertexHelper vh, Rect q, Color c)
        {
            if (q.width <= 0f || q.height <= 0f) return;
            int s = vh.currentVertCount;
            vh.AddVert(new Vector3(q.xMin, q.yMin), (Color32)c, new Vector2(0f, 0f));
            vh.AddVert(new Vector3(q.xMax, q.yMin), (Color32)c, new Vector2(1f, 0f));
            vh.AddVert(new Vector3(q.xMax, q.yMax), (Color32)c, new Vector2(1f, 1f));
            vh.AddVert(new Vector3(q.xMin, q.yMax), (Color32)c, new Vector2(0f, 1f));
            vh.AddTriangle(s, s + 1, s + 2);
            vh.AddTriangle(s, s + 2, s + 3);
        }
    }

    public class TutorialFocusRing : MonoBehaviour
    {
        // ======== 调优旋钮 ========
        [Header("视觉")]
        [SerializeField] private float borderThickness = 5f;   // ★2026-09-17 4→5（画布单位，随分辨率同比例）
        [SerializeField] private float breathePeriod = 1.2f;
        [SerializeField] private float breatheMin = 0.55f;
        [SerializeField] private float breatheMax = 1f;
        [SerializeField] private Color brass = new Color(0.89f, 0.71f, 0.40f, 1f); // 黄铜 #E3B567
        [SerializeField] private float dimAlpha = 0.5f;

        // ======== 运行时 ========
        private enum Mode { None, RectTransform, World, StaticRect, Dim }
        private Mode _mode = Mode.None;
        private RectTransform _rtTarget;
        private float _worldHalfPx = 70f;
        private System.Func<Vector3> _worldGetter;
        private Rect _staticRect;

        // ★2026-09-13 第二目标：与主目标共用同一张蒙版（各挖一个洞），各有自己的一套描边。
        private Mode _mode2 = Mode.None;
        private RectTransform _rtTarget2;
        private float _worldHalfPx2 = 70f;
        private System.Func<Vector3> _worldGetter2;
        private Rect _staticRect2;

        private readonly List<Rect> _holes = new List<Rect>(2);

        /// <summary>当前**主**高亮框的屏幕矩形（bottom-left 原点像素，每帧更新；隐藏时为 Rect.zero）。
        /// 引线等外部元素用它把端点截断在框边界上，而不是穿进框里。</summary>
        public Rect CurrentRect { get; private set; }

        private GameObject _canvasGO;
        private Canvas _canvas;   // ★2026-09-17 缓存：物理像素→画布局部单位换算读 scaleFactor
        private TutorialHoleMask _mask;
        private Image _bTop, _bBottom, _bLeft, _bRight;         // 主目标描边
        private Image _b2Top, _b2Bottom, _b2Left, _b2Right;     // 第二目标描边

        private void Awake()
        {
            Build();
            Hide();
        }

        private void Build()
        {
            _canvasGO = new GameObject("TutorialFocusCanvas");
            _canvasGO.transform.SetParent(transform, false);
            // ★2026-09-17 与场景 HUD 相同的缩放基准（1920×1080, match 0.5）——
            //   此前本画布没有 CanvasScaler，是全游戏唯一不随分辨率缩放的界面，屏越大圈越显小。
            _canvas = _canvasGO.AddComponent<Canvas>();
            _canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            _canvas.sortingOrder = 900;
            var cscaler = _canvasGO.AddComponent<CanvasScaler>();
            cscaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
            cscaler.referenceResolution = new Vector2(1920f, 1080f);
            cscaler.matchWidthOrHeight = 0.5f;
            // 禁用射线拦截：遮罩只负责视觉，绝不能挡住棋盘点击 / HUD 交互
            var ray = _canvasGO.GetComponent<GraphicRaycaster>();
            if (ray != null) ray.enabled = false;
            if (_canvasGO.GetComponent<GraphicRaycaster>() == null)
            {
                var r2 = _canvasGO.AddComponent<GraphicRaycaster>();
                r2.enabled = false;
            }

            // 暗化遮罩（带洞）
            var maskGO = new GameObject("HoleMask");
            maskGO.transform.SetParent(_canvasGO.transform, false);
            _mask = maskGO.AddComponent<TutorialHoleMask>();
            _mask.raycastTarget = false;
            // ★sprite=null 时 CanvasRenderer 不会渲染重写 OnPopulateMesh 的 Image（border 用默认实现所以没事）
            _mask.sprite = GetWhitePixel();
            _mask.color = new Color(0f, 0f, 0f, dimAlpha);
            _mask.type = Image.Type.Simple;
            var mrt = _mask.rectTransform;
            mrt.anchorMin = Vector2.zero; mrt.anchorMax = Vector2.one;
            mrt.pivot = Vector2.zero; mrt.offsetMin = Vector2.zero; mrt.offsetMax = Vector2.zero;

            // 四段黄铜描边（用默认 OnPopulateMesh，不需要 sprite 也能渲染；这里也加上保险）
            var wp = GetWhitePixel();
            _bTop = MakeBorder("BorderTop");
            _bBottom = MakeBorder("BorderBottom");
            _bLeft = MakeBorder("BorderLeft");
            _bRight = MakeBorder("BorderRight");
            _b2Top = MakeBorder("Border2Top");
            _b2Bottom = MakeBorder("Border2Bottom");
            _b2Left = MakeBorder("Border2Left");
            _b2Right = MakeBorder("Border2Right");
            foreach (var b in new[] { _bTop, _bBottom, _bLeft, _bRight, _b2Top, _b2Bottom, _b2Left, _b2Right })
                if (b != null) b.sprite = wp;
            SetBordersVisible(false, false);
        }

        private Image MakeBorder(string name)
        {
            var go = new GameObject(name);
            go.transform.SetParent(_canvasGO.transform, false);
            var img = go.AddComponent<Image>();
            img.raycastTarget = false;
            img.color = brass;
            var rt = img.rectTransform;
            rt.anchorMin = Vector2.zero; rt.anchorMax = Vector2.zero; rt.pivot = Vector2.zero;
            rt.anchoredPosition = Vector2.zero; rt.sizeDelta = Vector2.zero;
            return img;
        }

        // -------- 外部接口：主目标 --------
        public void Show(RectTransform target)
        {
            _mode = Mode.RectTransform;
            _rtTarget = target;
            _canvasGO.SetActive(true);
        }

        public void ShowWorld(System.Func<Vector3> worldGetter, float halfSizePx)
        {
            _mode = Mode.World;
            _worldGetter = worldGetter;
            _worldHalfPx = halfSizePx;
            _canvasGO.SetActive(true);
        }

        public void ShowRect(Rect screenRect)
        {
            _mode = Mode.StaticRect;
            _staticRect = screenRect;
            _canvasGO.SetActive(true);
        }

        /// <summary>★2026-09-13 Dim 模式：整屏压暗、不挖洞、不描边。
        /// 用于「要玩家点『知道了』、但场上没有高亮目标」的拍（画面全亮会让玩家误以为能自由操作）。</summary>
        public void ShowDim()
        {
            _mode = Mode.Dim;
            _canvasGO.SetActive(true);
        }

        // -------- 外部接口：第二目标（可选，与主目标同时亮） --------
        public void ShowSecond(RectTransform target)
        {
            _mode2 = Mode.RectTransform;
            _rtTarget2 = target;
            _canvasGO.SetActive(true);
        }

        public void ShowSecondWorld(System.Func<Vector3> worldGetter, float halfSizePx)
        {
            _mode2 = Mode.World;
            _worldGetter2 = worldGetter;
            _worldHalfPx2 = halfSizePx;
            _canvasGO.SetActive(true);
        }

        public void ShowSecondRect(Rect screenRect)
        {
            _mode2 = Mode.StaticRect;
            _staticRect2 = screenRect;
            _canvasGO.SetActive(true);
        }

        public void ClearSecond()
        {
            _mode2 = Mode.None;
            _worldGetter2 = null;
        }

        public void Hide()
        {
            _mode = Mode.None;
            _mode2 = Mode.None;
            _worldGetter = null;
            _worldGetter2 = null;
            CurrentRect = Rect.zero;
            if (_canvasGO != null) _canvasGO.SetActive(false);
        }

        // -------- 每帧 --------
        private void Update()
        {
            if (_mode == Mode.None || _canvasGO == null || !_canvasGO.activeSelf) return;

            // Dim：整屏压暗，无洞无描边（holes 清空 → TutorialHoleMask 画整屏）
            if (_mode == Mode.Dim)
            {
                CurrentRect = Rect.zero;
                _holes.Clear();
                _mask.holes.Clear();
                _mask.SetVerticesDirty();
                SetBordersVisible(false, false);
                return;
            }

            // ★2026-09-17 ComputeRect 输出**画布局部单位**（物理像素 ÷ scaleFactor）→ 蒙版与描边直接用；
            //   CurrentRect 对外换算回物理像素（提示卡引线按物理像素截断，语义与接入缩放前一致）。
            Rect r = ComputeRect(_mode, _rtTarget, _worldGetter, _worldHalfPx, _staticRect);
            Rect r2 = ComputeRect(_mode2, _rtTarget2, _worldGetter2, _worldHalfPx2, _staticRect2);

            float sf = CanvasScale();
            CurrentRect = new Rect(r.x * sf, r.y * sf, r.width * sf, r.height * sf);
            _holes.Clear();
            if (IsUsable(r)) _holes.Add(r);
            if (IsUsable(r2)) _holes.Add(r2);

            _mask.holes.Clear();
            _mask.holes.AddRange(_holes);
            _mask.SetVerticesDirty();

            SetBordersVisible(IsUsable(r), IsUsable(r2));
            if (IsUsable(r)) LayoutBorders(_bLeft, _bRight, _bBottom, _bTop, r);
            if (IsUsable(r2)) LayoutBorders(_b2Left, _b2Right, _b2Bottom, _b2Top, r2);
            Breathe();
        }

        private static bool IsUsable(Rect r) => r.width > 0.5f && r.height > 0.5f;

        /// <summary>返回**画布局部单位**的圈（物理像素 ÷ scaleFactor；蒙版与描边都吃局部单位）。
        /// World 模式的 halfPx 视作画布单位 → 渲染尺寸随分辨率与场景同比例（1080p 与旧物理值等价）。</summary>
        private Rect ComputeRect(Mode mode, RectTransform rtTarget, System.Func<Vector3> worldGetter,
                                 float worldHalfPx, Rect staticRect)
        {
            float sf = CanvasScale();
            switch (mode)
            {
                case Mode.RectTransform:
                    return ToLocal(rtTarget != null ? RectTransformToScreenRect(rtTarget) : Rect.zero, sf);
                case Mode.World:
                    Vector3 w = worldGetter != null ? worldGetter() : Vector3.zero;
                    Vector2 sp = WorldToScreen(w) / sf;
                    return new Rect(sp.x - worldHalfPx, sp.y - worldHalfPx, worldHalfPx * 2f, worldHalfPx * 2f);
                case Mode.StaticRect:
                    return ToLocal(staticRect, sf);
                default:
                    return Rect.zero;
            }
        }

        /// <summary>屏幕物理像素 → 画布局部单位（同基准画布下 scaleFactor 相同，可跨画布换算）。</summary>
        private static Rect ToLocal(Rect physical, float sf)
        {
            return new Rect(physical.x / sf, physical.y / sf, physical.width / sf, physical.height / sf);
        }

        /// <summary>画布缩放系数（CanvasScaler 1920×1080 驱动；未就绪时回退 1 = 物理像素直用）。</summary>
        private float CanvasScale()
        {
            return _canvas != null && _canvas.scaleFactor > 0f ? _canvas.scaleFactor : 1f;
        }

        private void SetBordersVisible(bool primary, bool second)
        {
            SetActive(_bTop, primary); SetActive(_bBottom, primary);
            SetActive(_bLeft, primary); SetActive(_bRight, primary);
            SetActive(_b2Top, second); SetActive(_b2Bottom, second);
            SetActive(_b2Left, second); SetActive(_b2Right, second);
        }

        private static void SetActive(Image img, bool on)
        {
            if (img == null) return;
            if (img.gameObject.activeSelf != on) img.gameObject.SetActive(on);
        }

        private void LayoutBorders(Image left, Image right, Image bottom, Image top, Rect r)
        {
            float t = borderThickness;
            SetBorder(left, r.xMin - t, r.yMin - t, t, r.height + 2f * t);
            SetBorder(right, r.xMax, r.yMin - t, t, r.height + 2f * t);
            SetBorder(bottom, r.xMin - t, r.yMin - t, r.width + 2f * t, t);
            SetBorder(top, r.xMin - t, r.yMax, r.width + 2f * t, t);
        }

        private void SetBorder(Image b, float x, float y, float w, float h)
        {
            b.rectTransform.anchoredPosition = new Vector2(x, y);
            b.rectTransform.sizeDelta = new Vector2(w, h);
        }

        private void Breathe()
        {
            float t = Mathf.Sin(Time.unscaledTime * Mathf.PI * 2f / breathePeriod) * 0.5f + 0.5f;
            float a = Mathf.Lerp(breatheMin, breatheMax, t);
            Color c = brass; c.a = a;
            _bTop.color = c; _bBottom.color = c; _bLeft.color = c; _bRight.color = c;
            _b2Top.color = c; _b2Bottom.color = c; _b2Left.color = c; _b2Right.color = c;
        }

        // -------- 坐标工具 --------
        private Rect RectTransformToScreenRect(RectTransform rt)
        {
            // 容器：并入所有可见子节点的实际屏幕范围（容器自身矩形可能与内容不重合，
            //   如 DiceArea 的按钮溢出容器 → 只框住一半；取并集才是真实可见范围）
            bool hasActiveChild = false;
            Rect union = Rect.zero;
            for (int i = 0; i < rt.childCount; i++)
            {
                if (!(rt.GetChild(i) is RectTransform child)) continue;
                if (!child.gameObject.activeInHierarchy) continue;
                Rect cr = CornersToScreenRect(child);
                if (cr.width <= 0.5f || cr.height <= 0.5f) continue;
                union = hasActiveChild ? Union(union, cr) : cr;
                hasActiveChild = true;
            }
            if (hasActiveChild) return Pad(union, 6f);

            // 叶子节点：Text 收紧到实际文字内容（拉伸矩形会带出大片空白，如 ActionPointsText）
            Rect self = CornersToScreenRect(rt);
            var tmp = rt.GetComponent<TMPro.TMP_Text>();
            if (tmp != null && !string.IsNullOrEmpty(tmp.text))
                self = TightenToTmpText(rt, tmp, self);
            else
            {
                var txt = rt.GetComponent<Text>();
                if (txt != null && !string.IsNullOrEmpty(txt.text))
                    self = TightenToText(rt, txt, self);
            }
            return self;
        }

        private static Rect CornersToScreenRect(RectTransform rt)
        {
            var corners = new Vector3[4];
            rt.GetWorldCorners(corners);          // overlay 画布下 = 屏幕像素（y 向上）
            return Rect.MinMaxRect(corners[0].x, corners[0].y, corners[2].x, corners[2].y);
        }

        private static Rect Union(Rect a, Rect b)
        {
            return Rect.MinMaxRect(Mathf.Min(a.xMin, b.xMin), Mathf.Min(a.yMin, b.yMin),
                                   Mathf.Max(a.xMax, b.xMax), Mathf.Max(a.yMax, b.yMax));
        }

        private static Rect Pad(Rect r, float p)
        {
            return new Rect(r.x - p, r.y - p, r.width + 2f * p, r.height + 2f * p);
        }

        /// <summary>把 TextMeshPro 的屏幕矩形收紧到实际渲染的文字（按对齐方式贴边）。</summary>
        private static Rect TightenToTmpText(RectTransform rt, TMPro.TMP_Text tmp, Rect screenRect)
        {
            // ★用 textBounds（真实渲染几何）：GetPreferredValues 会虚高数倍（实测 481 vs 101）
            var tb = tmp.textBounds;
            float tw = tb.size.x, th = tb.size.y;
            if (tw <= 1f || th <= 1f)
            {
                Vector2 pref = tmp.GetPreferredValues();   // 尚未渲染时的兜底
                tw = pref.x; th = pref.y;
            }
            if (tw <= 1f || th <= 1f) return screenRect;
            float w = Mathf.Min(tw + 6f, screenRect.width);
            float h = Mathf.Min(th + 6f, screenRect.height);
            // textBounds 在 rectTransform 本地空间，center 即文字实际落点 → 直接换算成屏幕位置
            float localMinX = -rt.pivot.x * rt.rect.width;
            float localMinY = -rt.pivot.y * rt.rect.height;
            float fx = Mathf.Clamp01((tb.center.x - localMinX) / Mathf.Max(1f, rt.rect.width));
            float fy = Mathf.Clamp01((tb.center.y - localMinY) / Mathf.Max(1f, rt.rect.height));
            float x = screenRect.x + fx * screenRect.width - w * 0.5f;
            float y = screenRect.y + fy * screenRect.height - h * 0.5f;
            return new Rect(x, y, w, h);
        }

        /// <summary>把 Text 的屏幕矩形收紧到实际渲染的文字（按对齐方式贴边），避免框住拉伸空白。</summary>
        private static Rect TightenToText(RectTransform rt, Text txt, Rect screenRect)
        {
            var gen = txt.cachedTextGeneratorForLayout;
            var settings = txt.GetGenerationSettings(new Vector2(rt.rect.width, Mathf.Max(1f, rt.rect.height)));
            float pw = gen.GetPreferredWidth(txt.text, settings);
            float ph = gen.GetPreferredHeight(txt.text, settings);
            if (pw <= 1f || ph <= 1f) return screenRect;
            float w = Mathf.Min(pw + 4f, screenRect.width);
            float h = Mathf.Min(ph + 4f, screenRect.height);
            int a = (int)txt.alignment;                 // TextAnchor: 0 LowerLeft … 8 UpperRight
            float ax = (a % 3) * 0.5f;                  // 0 左 / 0.5 中 / 1 右
            float ay = (a / 3) * 0.5f;                  // 0 下 / 0.5 中 / 1 上
            float x = screenRect.x + (screenRect.width - w) * ax;
            float y = screenRect.y + (screenRect.height - h) * ay;
            return new Rect(x, y, w, h);
        }

        private static Vector2 WorldToScreen(Vector3 world)
        {
            Camera cam = Camera.main;
            if (cam == null) return new Vector2(Screen.width * 0.5f, Screen.height * 0.5f);
            return cam.WorldToScreenPoint(world);
        }

        /// <summary>1×1 白色像素 Sprite（重写 OnPopulateMesh 的 Image 必须显式设 sprite 才会渲染）。</summary>
        private static Sprite _whitePixel;
        private static Sprite GetWhitePixel()
        {
            if (_whitePixel != null) return _whitePixel;
            var tex = new Texture2D(1, 1, TextureFormat.RGBA32, false);
            tex.SetPixel(0, 0, Color.white);
            tex.Apply();
            _whitePixel = Sprite.Create(tex, new Rect(0, 0, 1, 1), new Vector2(0.5f, 0.5f), 1f);
            return _whitePixel;
        }
    }
}

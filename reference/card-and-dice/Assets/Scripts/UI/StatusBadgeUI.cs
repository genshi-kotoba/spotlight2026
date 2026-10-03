// =============================================================================
// 模块：M5b-3 状态徽章 UI StatusBadgeUI
// 用途：单位脚下血条旁的两个圆点徽章（P22 StatusEffectUI 的简化版）：
//   - 血条左侧：蓝色圆点+数字 = 护甲层数（EffectManager，0 层隐藏）
//   - 血条右侧：绿色圆点+数字 = 当前行动点（★2026-08-19 敌人改读 MoveBudget=AP+疾跑值：
//     哥布林疾跑一次 3→4，成功打出非疾跑意图后回 3；断筋扣减生效。玩家读 HexMover）
// 挂载：敌人/玩家的 HPBarCanvas（World Space Canvas，与血条同画布）
// 实现：全部代码动态创建（圆点 Sprite 运行时生成，零美术依赖）；
//       LateUpdate 轮询刷新（值变才写 UI）；Graphic.raycastTarget=false 不挡格子射线
// （与 2026-08-18 血条挡射线修复同一原则）
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 单位状态徽章：护甲（左蓝点）+ 行动点（右绿点）。
/// 挂到 HPBarCanvas 上，自动定位血条两侧。
/// </summary>
public class StatusBadgeUI : MonoBehaviour
{
    [Header("布局（像素，相对血条中心）")]
    [Tooltip("护甲徽章相对血条中心的 X 偏移（负=左）")]
    [SerializeField] private float armorOffsetX = -141f;
    [Tooltip("AP 徽章相对血条中心的 X 偏移（正=右）")]
    [SerializeField] private float apOffsetX = 141f;
    [Tooltip("Y 偏移（正=上，让徽章浮在血条上方）")]
    [SerializeField] private float offsetY = 11f;
    [Tooltip("圆点直径（血条 Canvas 像素）")]
    [SerializeField] private float badgeSize = 14f;
    [Tooltip("徽章根物体缩放（1=原尺寸；4=放大 4 倍，与血条视觉匹配）")]
    [SerializeField] private Vector3 badgeScale = new Vector3(4f, 4f, 1f);
    [Tooltip("圆点子物体缩放（在 badgeScale 放大背景上再缩）。★用户 2026-08-18 指定=0.4（与数字子物体 textScale 相同，比例协调）")]
    [SerializeField] private Vector3 dotScale = new Vector3(0.4f, 0.4f, 1f);
    [Tooltip("数字子物体缩放（在 badgeScale 放大背景上再缩，避免数字过大）。★用户 2026-08-18 指定=0.4")]
    [SerializeField] private Vector3 textScale = new Vector3(0.4f, 0.4f, 1f);
    [Tooltip("数字字号（像素，30=大字号便于阅读；实际屏幕字号=fontSize * badgeScale.x * textScale.x；圆点实际屏幕直径=badgeSize * badgeScale.x * dotScale.x）")]
    [SerializeField] private int fontSize = 30;

    [Header("颜色")]
    [SerializeField] private Color armorColor = new Color(0.20f, 0.55f, 0.95f);   // 蓝
    [SerializeField] private Color apColor = new Color(0.25f, 0.80f, 0.40f);      // 绿

    /// <summary>护甲圆点+文字</summary>
    private Image _armorImage;
    private Text _armorText;
    /// <summary>AP 圆点+文字</summary>
    private Image _apImage;
    private Text _apText;

    /// <summary>单位根物体（EnemyController / PlayerHealth 所在物体，EffectManager 的 key）</summary>
    private GameObject _unitRoot;
    /// <summary>玩家 HexMover（玩家 AP 数据源）</summary>
    private HexMover _playerMover;
    /// <summary>敌人控制器（★2026-08-18 新增：敌人 AP 数据源，CurrentActionPoints）</summary>
    private EnemyController _enemyController;

    /// <summary>共享圆点 Sprite（所有徽章复用一张 32×32 实心圆纹理）</summary>
    private static Sprite _circleSprite;

    /// <summary>上次刷新值（值变才写 UI，省开销）</summary>
    private int _lastArmor = -1;
    private int _lastAP = -1;

    /// <summary>徽章根物体（显隐控制对象）★2026-08-18 修复：显隐必须操作 root——
    /// 之前 LateUpdate 激活的是子物体 Dot，而 CreateBadges 隐藏的是 root，
    /// root 永远 inactive → 徽章永远不可见</summary>
    private GameObject _armorRootGO;
    private GameObject _apRootGO;

    private void Start()
    {
        // 单位根：血条 Canvas 挂在单位层级下，向上找控制组件确定根物体
        var enemy = GetComponentInParent<EnemyController>();
        if (enemy != null)
        {
            _unitRoot = enemy.gameObject;
            _enemyController = enemy; // 敌人也显示 AP（上限=data.moveRange，断筋可扣）
        }
        else
        {
            var health = GetComponentInParent<PlayerHealth>();
            if (health != null)
            {
                _unitRoot = health.gameObject;
                _playerMover = _unitRoot.GetComponent<HexMover>(); // 玩家才显示 AP
            }
        }

        CreateBadges();
    }

    /// <summary>
    /// 轮询刷新：护甲层数 / 行动点。
    /// EffectManager 无变化事件，轮询是最省事的接入（值缓存避免每帧写字符串）。
    /// </summary>
    private void LateUpdate()
    {
        if (_armorImage == null) return;

        // 护甲（敌人+玩家通用）
        int armor = (_unitRoot != null && EffectManager.Instance != null)
            ? EffectManager.Instance.GetEffectStacks(_unitRoot, "ArmorEffect")
            : 0;
        if (armor != _lastArmor)
        {
            _lastArmor = armor;
            bool show = armor > 0;
            if (_armorRootGO != null) _armorRootGO.SetActive(show); // 显隐 root，不是 Dot
            if (show) _armorText.text = armor.ToString();
        }

        // 行动点（★2026-09-09 敌人改读 DisplayActionPoints：按状态返回战斗 AP+疾跑 / 巡逻步数 / 搜索步数）
        int ap = 0;
        if (_playerMover != null) ap = _playerMover.currentActionPoints;
        else if (_enemyController != null) ap = _enemyController.DisplayActionPoints;

        if (ap != _lastAP)
        {
            _lastAP = ap;
            // 有任一 AP 数据源即常显（含 0：敌人被断筋扣到 0 时绿点仍在，数字变 0）
            bool show = (_playerMover != null || _enemyController != null);
            if (_apRootGO != null) _apRootGO.SetActive(show); // 显隐 root，不是 Dot
            if (show) _apText.text = ap.ToString();
        }
    }

    // ------------------------------------------------------------------
    // 动态构建（零场景改动、零美术资源）
    // ------------------------------------------------------------------

    /// <summary>在血条 Canvas 下创建左右两组徽章（圆点 Image + 数字 Text）</summary>
    private void CreateBadges()
    {
        RectTransform armorRoot = CreateBadge("ArmorBadge", armorOffsetX, armorColor, out _armorImage, out _armorText);
        RectTransform apRoot = CreateBadge("APBadge", apOffsetX, apColor, out _apImage, out _apText);

        // 记录 root 引用（LateUpdate 显隐用同一对象，保证创建/刷新一致）
        _armorRootGO = armorRoot != null ? armorRoot.gameObject : null;
        _apRootGO = apRoot != null ? apRoot.gameObject : null;

        // 初始隐藏（无护甲/未确定 AP 时不显示空点）
        if (_armorRootGO != null) _armorRootGO.SetActive(false);
        if (_apRootGO != null) _apRootGO.SetActive(false);
    }

    /// <summary>
    /// 创建单个徽章：圆点（Image，数字垫底）+ 居中数字（Text）。
    /// raycastTarget=false——血条区域不参与 UGUI 射线，不挡格子高亮/移动点击。
    /// </summary>
    private RectTransform CreateBadge(string name, float offsetX, Color color, out Image image, out Text text)
    {
        image = null;
        text = null;

        RectTransform canvasRT = transform as RectTransform;
        if (canvasRT == null) return null;

        // 徽章根（定位到血条两侧，Y 偏移让徽章浮在血条上方）
        GameObject root = new GameObject(name, typeof(RectTransform));
        RectTransform rootRT = root.transform as RectTransform;
        rootRT.SetParent(transform, false);
        rootRT.anchorMin = rootRT.anchorMax = new Vector2(0.5f, 0.5f);
        rootRT.anchoredPosition = new Vector2(offsetX, offsetY);
        rootRT.sizeDelta = new Vector2(badgeSize, badgeSize);
        // ★2026-08-18 用户调优：放大 4 倍让徽章在 World Space Canvas 上可见
        rootRT.localScale = badgeScale;

        // 圆点底图
        GameObject dot = new GameObject("Dot", typeof(Image));
        RectTransform dotRT = dot.transform as RectTransform;
        dotRT.SetParent(rootRT, false);
        dotRT.anchorMin = dotRT.anchorMax = Vector2.zero;
        dotRT.anchorMax = Vector2.one;
        dotRT.offsetMin = Vector2.zero;
        dotRT.offsetMax = Vector2.zero;
        // ★2026-08-18 用户指定：Dot 圆点也单独缩放到 0.4（与 Count 保持一致，整体比例协调）
        dotRT.localScale = dotScale;

        // ★2026-08-18 修复：Dot 创建时已带 Image（typeof(Image)），
        // 再 AddComponent 会因重复组件被 Unity 拒绝返回 null → 后续 image.sprite 抛 NRE，
        // 导致 APBadge 未创建、护甲数字丢失。改用 GetComponent 取已有组件。
        image = dot.GetComponent<Image>();
        image.sprite = GetCircleSprite();
        image.color = color;
        image.raycastTarget = false;

        // 数字（叠在圆点上，居中）
        GameObject label = new GameObject("Count", typeof(Text));
        RectTransform labelRT = label.transform as RectTransform;
        labelRT.SetParent(rootRT, false);
        labelRT.anchorMin = labelRT.anchorMax = Vector2.zero;
        labelRT.anchorMax = Vector2.one;
        labelRT.offsetMin = Vector2.zero;
        labelRT.offsetMax = Vector2.zero;
        // ★2026-08-18 用户指定：Count 文字单独缩放到 0.4（圆点放大 4× 背景下，数字不显得过大）
        labelRT.localScale = textScale;

        // ★同上修复：Count 创建时已带 Text，GetComponent 取已有组件
        text = label.GetComponent<Text>();
        // ★2026-08-18 修复：Unity 2022.3 已移除 Arial.ttf，GetBuiltinResource 会抛异常，
        // 导致 CreateBadge 中途崩溃（ArmorBadge 半成品、APBadge 未创建、护甲数字丢失）。
        // 改用 LegacyRuntime.ttf（2022+ 的内置字体），失败时回退场景现有 Text 的字体。
        text.font = GetSafeFont();
        text.fontSize = fontSize;
        text.alignment = TextAnchor.MiddleCenter;
        text.color = Color.white;
        text.horizontalOverflow = HorizontalWrapMode.Overflow;
        text.verticalOverflow = VerticalWrapMode.Overflow;
        text.raycastTarget = false;
        text.text = "0";

        return rootRT;
    }

    /// <summary>
    /// 安全获取内置字体：LegacyRuntime.ttf（Unity 2022+）→ Arial.ttf（旧版回退）→ 场景现有 Text 借用。
    /// 任一环节失败不抛异常，最坏返回 null（数字不显示，圆点仍正常）。
    /// </summary>
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
            // 最后兜底：借用场景中任意现成 Text 的字体（如血条 HPText）
            var anyText = Object.FindObjectsOfType<Text>();
            if (anyText != null && anyText.Length > 0 && anyText[0] != null && anyText[0].font != null)
            {
                _cachedFont = anyText[0].font;
            }
        }
        return _cachedFont;
    }

    /// <summary>
    /// 懒生成共享圆点 Sprite（32×32 实心圆纹理）。
    /// 后期换正式图标：改此方法返回 AssetDatabase/Resources 加载的 Sprite 即可。
    /// </summary>
    private static Sprite GetCircleSprite()
    {
        if (_circleSprite != null) return _circleSprite;

        int size = 32;
        var tex = new Texture2D(size, size, TextureFormat.RGBA32, false);
        tex.wrapMode = TextureWrapMode.Clamp;

        float center = (size - 1) * 0.5f;
        float radius = center;
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                float dist = Vector2.Distance(new Vector2(x, y), new Vector2(center, center));
                // 1px 抗锯齿边缘
                float alpha = Mathf.Clamp01((radius + 0.5f - dist));
                tex.SetPixel(x, y, new Color(1f, 1f, 1f, alpha));
            }
        }
        tex.Apply();

        _circleSprite = Sprite.Create(tex, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f), size);
        return _circleSprite;
    }
}

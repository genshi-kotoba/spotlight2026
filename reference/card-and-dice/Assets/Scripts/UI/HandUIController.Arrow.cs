// =============================================================================
// 模块：HandUIController 箭头模式与目标检测（partial 拆分 2026-08-18，纯机械搬运逻辑零修改）
// 原文件：HandUIController.cs（拆分后本文件只管"指向卡过线后的箭头模式"——
//         卡牌停泊、箭头更新、敌人射线检测、目标有效性、射程高亮）
// =============================================================================
using UnityEngine;
using DG.Tweening;

public partial class HandUIController
{
    /// <summary>箭头模式下当前高亮的敌人（null = 无）</summary>
    private EnemyController _lastHighlightedEnemy = null;

    /// <summary>指向箭头视图（纯 C# 类，本类驱动）</summary>
    private TargetingArrowView _arrowView = new TargetingArrowView();

    /// <summary>玩家 HexMover 缓存（射程判定/射程高亮用）</summary>
    private HexMover _playerMover = null;

    /// <summary>场景敌人缓存（箭头指向"点格子找敌人"用，惰性查找一次；Demo 不动态刷怪）</summary>
    private EnemyController[] _enemiesCache = null;

    [Header("箭头模式（有指向卡，M5b-2）")]
    [Tooltip("停泊位高度（HandAreaRoot 局部 y）。★用户注：卡牌缩小后此高度可能偏高，后期可调")]
    [SerializeField] private float _arrowParkLiftY = 60f;

    [Tooltip("停泊过渡时长（秒）：移动到弧线正中 + 旋转立正 + 缩放过渡")]
    [SerializeField] private float _arrowParkDuration = 0.2f;

    [Tooltip("★用户 2026-08-18：箭头模式卡牌放大倍率（原为缩回 1.0，现改 1.1）")]
    [SerializeField] private float _arrowModeScale = 1.1f;

    // ------------------------------------------------------------------
    // 箭头模式（有指向卡过线后）
    // ------------------------------------------------------------------

    /// <summary>
    /// 进入箭头模式（★用户规格：一旦过线变箭头，不因鼠标回落解除）：
    /// 1. 卡牌停泊：移动到手牌弧线正中（样条 t=0.5 的 X + 抬高 Y），旋转立正，
    ///    过渡到 原始大小×_arrowModeScale（★用户 2026-08-18：放大 1.1 倍，原为缩回 1.0）；
    ///    保持置顶可遮挡其他卡
    /// 2. 显示指向箭头（起点=停泊卡中心，终点=鼠标，每帧更新）
    /// 3. 手牌已在进流时收拢（无需额外动作）
    /// </summary>
    private void EnterArrowMode(CardView cv)
    {
        _arrowMode = true;

        // ★2026-08-18 语义修订（用户澄清）：黄色=展示射程，红色=当前指向的目标格。
        // 单一指向卡（直刺/纵劈/断筋）进箭头模式后范围【保持黄色】——
        // 只有箭头指向的有效目标格由 UpdateArrow 每帧染红（HighlightTargetTile）。
        // （整片变红只属于无指向卡：横斩=指向范围内全体、防御=指向玩家自身）
        ShowRangeHighlightForCard(cv, active: false);

        var rt = cv.transform as RectTransform;
        var parentRT = cv.transform.parent as RectTransform;
        if (rt != null && CardSpline != null && parentRT != null)
        {
            // 停泊位：样条正中 t=0.5 的 X + 抬高 Y（用户注：缩小后此高度可能偏高，后期调）
            Vector3 worldPos = CardSpline.EvaluatePosition(0.5f);
            Vector3 localPos = parentRT.InverseTransformPoint(worldPos);
            Vector3 parkPos = new Vector3(localPos.x, _arrowParkLiftY, cv.transform.localPosition.z);

            DOTween.Kill(rt);
            DOTween.To(() => rt.anchoredPosition3D, x => rt.anchoredPosition3D = x, parkPos, _arrowParkDuration)
                .SetEase(Ease.OutCubic)
                .SetTarget(rt);
            rt.DOLocalRotate(Vector3.zero, _arrowParkDuration, RotateMode.Fast)
                .SetEase(Ease.OutCubic)
                .SetTarget(rt);
            cv.TweenScaleToOriginal(_arrowParkDuration, _arrowModeScale);
        }

        // 显示箭头（挂卡牌所在画布顶层）
        Canvas canvas = rt != null ? rt.GetComponentInParent<Canvas>() : null;
        if (canvas != null)
        {
            _arrowView.Show(canvas);
        }
    }

    /// <summary>
    /// 箭头模式每帧更新（Update 轮询）：
    /// 射线找鼠标下敌人（模型或所在地板格）→ 射程判定 → 敌人高亮 + 目标格红高亮 →
    /// 更新箭头两端与颜色。
    /// </summary>
    private void UpdateArrow()
    {
        var cv = _activeCard;
        if (cv == null)
        {
            _arrowMode = false;
            return;
        }

        // 目标射线 + 射程判定
        EnemyController enemy = RaycastEnemyUnderMouse();
        bool valid = enemy != null && IsValidTarget(enemy, cv);

        // 敌人高亮刷新（只在有效目标上染红）
        if (_lastHighlightedEnemy != null && _lastHighlightedEnemy != enemy)
        {
            _lastHighlightedEnemy.SetHighlighted(false);
            _lastHighlightedEnemy = null;
        }
        if (valid && enemy != null)
        {
            enemy.SetHighlighted(true);
            _lastHighlightedEnemy = enemy;
        }

        // ★用户 2026-08-18：指向有效目标时目标所在格子红高亮（叠加在射程黄之上）
        CardRangeHighlight.HighlightTargetTile(valid && enemy != null
            ? (Vector2Int?)enemy.CurrentCoord
            : null);

        // 箭头：起点 = 停泊卡中心（★用户 2026-08-18：从卡牌中间延伸，原为顶部偏移），终点 = 鼠标
        var rt = cv.transform as RectTransform;
        Canvas canvas = rt != null ? rt.GetComponentInParent<Canvas>() : null;
        if (rt == null || canvas == null) return;

        Vector2 screenStart = RectTransformUtility.WorldToScreenPoint(null, rt.position);
        _arrowView.SetEndpoints(screenStart, Input.mousePosition, valid);
    }

    /// <summary>
    /// 射线检测鼠标下的敌人（★用户 2026-08-18：不要求精准点击敌人模型）：
    /// 1. 直接命中敌人模型 → 返回该敌人
    /// 2. 命中 Hex_x_y 地板格 → 按坐标匹配站在该格上的存活敌人
    /// 敌人缓存惰性查找一次（Demo 不动态刷怪；死亡敌人由 IsDead 过滤）。
    /// </summary>
    private EnemyController RaycastEnemyUnderMouse()
    {
        Camera cam = Camera.main;
        if (cam == null) return null;

        RaycastHit[] hits = Physics.RaycastAll(cam.ScreenPointToRay(Input.mousePosition), 100f);
        foreach (RaycastHit hit in hits)
        {
            // 1) 直接命中敌人模型
            var enemy = hit.collider.GetComponentInParent<EnemyController>();
            if (enemy != null && !enemy.IsDead) return enemy;

            // 2) 命中敌人所在的地板格子（Hex_x_y）→ 坐标匹配敌人
            //    （敌人通过脚下射线绑定格子，CurrentCoord 即所站格坐标）
            string objName = hit.collider.gameObject.name;
            if (objName != null && objName.StartsWith("Hex_"))
            {
                string[] parts = objName.Split('_');
                if (parts.Length == 3 && int.TryParse(parts[1], out int x) && int.TryParse(parts[2], out int y))
                {
                    var coord = new Vector2Int(x, y);
                    if (_enemiesCache == null) _enemiesCache = FindObjectsOfType<EnemyController>();
                    foreach (var e in _enemiesCache)
                    {
                        if (e != null && !e.IsDead && e.CurrentCoord == coord) return e;
                    }
                }
            }
        }
        return null;
    }

    /// <summary>
    /// 目标有效性判定：敌人存活 + 六边形距离 ≤ 卡牌射程（★用户 2026-08-18 确认做射程判定）。
    /// 找不到玩家坐标时不做射程限制（防御，正常场景必有玩家）。
    /// </summary>
    private bool IsValidTarget(EnemyController enemy, CardView cv)
    {
        if (enemy == null || cv == null || cv.CardData == null) return false;
        var mover = GetPlayerMover();
        if (mover == null) return true;
        return CardExecutor.HexDistance(mover.CurrentCoord, enemy.CurrentCoord) <= cv.CardData.Range;
    }

    /// <summary>玩家 HexMover 缓存查找</summary>
    private HexMover GetPlayerMover()
    {
        if (_playerMover == null) _playerMover = FindObjectOfType<HexMover>();
        return _playerMover;
    }

    /// <summary>
    /// 显示卡牌射程高亮（悬停/交互流进入时调用）。
    /// ★2026-08-17 双色语义（用户拍板）：
    ///   active=false → 黄色 = 指示"可用范围和目标"（悬停 / 拖拽未过线）
    ///   active=true  → 红色 = 指示"打出去后生效的目标和格子"（拖拽过线 / 箭头模式）
    /// ★无指向自身卡（防御等 range=0）：悬停时也高亮玩家脚底格（原来 Clear 无反馈），
    ///   过线后同一格变红（"松开=给自己上护甲"）。
    /// </summary>
    private void ShowRangeHighlightForCard(CardView cv, bool active = false)
    {
        if (cv == null || cv.CardData == null) return;
        int range = cv.CardData.Range;
        var mover = GetPlayerMover();
        if (mover == null) return;

        if (range < 0)
        {
            CardRangeHighlight.Clear();
            return;
        }
        // range == 0 自身卡：只染玩家所在一格（黄=可用 / 红=生效）
        CardRangeHighlight.Show(mover.CurrentCoord, range, active);
    }
}

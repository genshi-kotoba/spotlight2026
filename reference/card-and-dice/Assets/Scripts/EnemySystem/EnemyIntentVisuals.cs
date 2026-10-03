// =============================================================================
// 模块：M6-4 敌人系统 - EnemyIntentVisuals 常显移动/攻击视觉
// 用途：玩家回合内，每只敌人「每时每刻」显示四样中的三样视觉层：
//        ① 攻击空中弧线（红，最醒目）② 移动落点虚影（半透明剪影标记）③ 移动虚线路线（琥珀短长方形串）
//        （④ 意图徽章由 EnemyIntentBadgeUI 负责，本类不碰）
// 设计依据：《设计增补_敌人系统_v2.md》§3.6「陷阵之志式完美信息」
// 视觉语言（与玩家「黄=射程 / 红=指向」严格区分，见 §3.6 铁律）：
//   - 敌人攻击 = 红色抛物线空中弧线（从落点划向玩家，废墟图书馆式）
//   - 敌人移动 = 琥珀虚线路线（★2026-08-19 实线→短长方形虚线串，当前格 → 落点，只给方向，不画完整 A* 折线）
//   - 敌人落点 = 半透明低饱和红色地面环标（Demo 以地面环标简化「剪影」，后续可换真剪影）
// 挂载：EnemyController.Awake 自动 AddComponent（无需手动挂预制体）。
// 实现：零美术/零串行化引用，全部代码动态创建（LineRenderer 弧线 + SpriteRenderer 虚影
//       + 长方形虚线段池 DashPool）。
//       造型对象挂在场景根「EnemyIntentVisualsRoot」下（不挂敌人子级），避免跟随敌人移动。
//       重算节流：仅当「揭示代数 / 玩家坐标 / 敌人坐标 / 棋盘签名」任一变化才重算（避免每帧 A*）。
// 一致性：★2026-08-22 与 EnemyTurnExecutor 统一改用 EnemyLandingPlanner 取「全场计划」，
//       落点互斥（先动者计划落点保留，后动者避让），保证「展示的落点/意图」与
//       「实际执行的」严格一致且多名敌人虚影环不重合（§3.6 实现要点）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人常显移动/攻击视觉。挂在敌人根物体上，自动在世界空间创建可视元素。
/// </summary>
public class EnemyIntentVisuals : MonoBehaviour
{
    // ------------------------------------------------------------------
    // 调优旋钮（Inspector 可调）
    // ------------------------------------------------------------------
    [Header("视觉颜色（敌人专属，区别于玩家高亮）")]
    [SerializeField] private Color airArcColor = new Color(1f, 0.35f, 0.30f, 0.90f);      // 攻击弧线：最醒目红
    [SerializeField] private Color groundArrowColor = new Color(1f, 0.78f, 0.25f, 0.85f); // 移动箭头：琥珀
    [SerializeField] private Color ghostColor = new Color(0.85f, 0.25f, 0.25f, 0.28f);   // 落点虚影：低饱和红

    // §3.8 移动预览两层视觉（区别于常显的红/琥珀）：
    // 「实时预览」= 青（玩家假设走到悬停格），「锁定快照」= 紫（Shift 锁定的对比参照）
    [SerializeField] private Color previewColor = new Color(0.20f, 0.90f, 1.00f, 0.85f);      // 实时预览弧线/箭头：青
    [SerializeField] private Color previewGhostColor = new Color(0.20f, 0.82f, 0.95f, 0.32f); // 实时预览虚影：半透明青
    [SerializeField] private Color lockedColor = new Color(0.90f, 0.32f, 1.00f, 0.85f);       // 锁定快照弧线/箭头：紫
    [SerializeField] private Color lockedGhostColor = new Color(0.85f, 0.30f, 1.00f, 0.32f);  // 锁定快照虚影：半透明紫

    [Header("几何参数")]
    [Tooltip("贴地箭头离地高度。★2026-08-19 修复不可见：六边形块顶面在 Y=0.25（mesh 厚 0.5），原 0.06 埋在地块内部被地形挡住（弧线起点 0.9 在空中所以一直可见）。抬到 0.28 = 顶面 + 0.03 间隙，防 z-fighting")]
    [SerializeField] private float groundY = 0.28f;
    [Tooltip("攻击空中弧线最高点（米）")]
    [SerializeField] private float arcHeight = 1.6f;
    [Tooltip("弧线分段数")]
    [SerializeField] private int arcSegments = 16;
    [Tooltip("落点虚影（地面环标）半径（米）")]
    [SerializeField] private float ghostRadius = 0.42f;

    [Header("★2026-08-19 虚线路线（实线 → 短长方形串）")]
    [Tooltip("每段长方形的长度（米，沿移动方向）")]
    [SerializeField] private float dashLength = 0.28f;
    [Tooltip("段与段的最大间隔（米）。实际间距随路线长短自适应收紧，保证虚线铺满全程")]
    [SerializeField] private float dashGap = 0.16f;
    [Tooltip("每段长方形的宽度（米，垂直移动方向）")]
    [SerializeField] private float dashWidth = 0.10f;

    // ------------------------------------------------------------------
    // 运行时状态
    // ------------------------------------------------------------------
    private EnemyController _enemy;

    private DashPool _groundDashes;   // 常显移动虚线路线（琥珀）
    private LineRenderer _airArc;
    private SpriteRenderer _ghost;

    // §3.8 移动预览两层（实时预览青 / 锁定快照紫），与常显三样各自独立
    private DashPool _previewDashes;  // 实时预览移动虚线（青）
    private LineRenderer _previewArc;
    private SpriteRenderer _previewGhost;
    private DashPool _lockedDashes;   // 锁定快照移动虚线（紫）
    private LineRenderer _lockedArc;
    private SpriteRenderer _lockedGhost;

    // 静态共享：造型容器 + 环标/长方形 sprite（全场景共用一份）
    private static Transform _visualRoot;
    private static Sprite _ghostSprite;
    private static Sprite _dashSprite;
    private static Transform _mapCache;
    // ★2026-09-15 性能：静态缓存玩家引用，避免战斗态每帧全场景扫描（同 EnemyIntentBadgeUI）
    private static HexMover _cachedPlayer;

    // 重算节流状态（★2026-08-22 加棋盘签名：任一敌人状态变化都会改变全场计划，
    // 别人动了我也要重取——否则虚影停留在按旧棋盘算出的过期落点上）
    private int _lastGen = -1;
    private Vector2Int _lastPlayerCoord = new Vector2Int(int.MinValue, int.MinValue);
    private Vector2Int _lastEnemyCoord = new Vector2Int(int.MinValue, int.MinValue);
    private long _lastSignature = long.MinValue;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Awake()
    {
        _enemy = GetComponent<EnemyController>();
        BuildVisuals();
    }

    private void LateUpdate()
    {
        if (_enemy == null) return;

        // 死亡 → 全部隐藏。
        // ★2026-09-08 放宽「未揭示 → 全隐藏」：被传导红`!`的问号单位已进落点计划
        //（RevealedIntent 仍冻结为空，但必须有逼近落点预览）→ 不再以 RevealedIntent 为门；
        // 其 chosen 恒 null → 攻击弧线天然不画；无计划条目者（黄`?`/白`?`批量移动者）
        // GetEntry=null → 各绘制函数自动隐藏（landing=原地 → willMove=false）。
        if (_enemy.IsDead)
        {
            SetAllVisible(false);
            return;
        }
        // ★2026-08-22 用户修订：删除「移动后 A* 折线虚线」。敌人意图被消费（开始行动）后：
        //   ① 移动开始前（本分支之外，IntentConsumed==false）：直线虚线 + 目的地虚影（走正常 RefreshVisuals）
        //   ② 开始移动（CurrentMovePath != null）：只显示目的地虚影，不画虚线
        //   ③ 移动结束（CurrentMovePath == null）：无任何标识（全隐藏）
        if (_enemy.IntentConsumed)
        {
            if (_groundDashes != null) _groundDashes.SetVisible(false); // 虚线隐藏
            if (_airArc != null) _airArc.enabled = false;              // 攻击弧线隐藏
            SetSetVisible(false, _previewDashes, _previewArc, _previewGhost);
            SetSetVisible(false, _lockedDashes, _lockedArc, _lockedGhost);

            if (_enemy.CurrentMovePath == null && _ghost != null)
            {
                _ghost.enabled = false; // 移动结束：目的地虚影也隐藏
            }
            // 移动中：_ghost 保留在 landing（RefreshVisuals 已画好）→ 只显示目的地
            return;
        }
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState != GameState.Battle)
        {
            SetAllVisible(false);
            return;
        }

        HexMover player = _cachedPlayer != null ? _cachedPlayer : (_cachedPlayer = FindObjectOfType<HexMover>());
        if (player == null)
        {
            SetAllVisible(false);
            return;
        }

        // ★2026-08-23 玩家移动期间视觉锁定：以「本次移动落点」为假设玩家坐标解算
        //（MovingDestCoord 移动开始时锁定、结束清空）——整段移动中敌方计划恒为落点版，
        // 不随中途经过的格子逐格刷新跳动；非移动时=真实 CurrentCoord。
        // ★P1 锁定恢复（加固）：仅当玩家「正在移动中」且落点有效时才锁定到落点；
        // 玩家静止时一律用 CurrentCoord（与执行器 EnemyTurnExecutor 同源）——
        // 即使 MovingDestCoord 因移动中断/时序残留，也不会污染静止时的预览，保证预览=执行。
        Vector2Int playerCoord = (player.IsMoving() && player.MovingDestCoord.HasValue)
            ? player.MovingDestCoord.Value
            : player.CurrentCoord;

        // 重算节流：揭示代数 / 玩家 / 敌人 任一坐标 / 棋盘签名 任一变化才重算
        long signature = EnemyLandingPlanner.CurrentSignature;
        bool changed = _enemy.RevealGeneration != _lastGen
                    || playerCoord != _lastPlayerCoord
                    || _enemy.CurrentCoord != _lastEnemyCoord
                    || signature != _lastSignature;
        if (changed)
        {
            _lastGen = _enemy.RevealGeneration;
            _lastPlayerCoord = playerCoord;
            _lastEnemyCoord = _enemy.CurrentCoord;
            _lastSignature = signature;

            RefreshVisuals(player, playerCoord);
        }

        // §3.8 移动预览：实时预览 / 锁定快照每帧读取 EnemyMovePreview，
        // 不参与上方常显节流（悬停/锁定坐标变化比「玩家真实坐标」频繁）。
        RefreshPreview();
    }

    /// <summary>敌人被禁用（死亡 SetActive(false)）时，立即隐藏残留视觉。</summary>
    private void OnDisable()
    {
        SetAllVisible(false);
    }

    /// <summary>敌人被真正销毁时，连带销毁造型对象（避免泄漏）。</summary>
    private void OnDestroy()
    {
        if (_groundDashes != null) _groundDashes.Destroy();
        if (_airArc != null) Destroy(_airArc.gameObject);
        if (_ghost != null) Destroy(_ghost.gameObject);
        if (_previewDashes != null) _previewDashes.Destroy();
        if (_previewArc != null) Destroy(_previewArc.gameObject);
        if (_previewGhost != null) Destroy(_previewGhost.gameObject);
        if (_lockedDashes != null) _lockedDashes.Destroy();
        if (_lockedArc != null) Destroy(_lockedArc.gameObject);
        if (_lockedGhost != null) Destroy(_lockedGhost.gameObject);
    }

    // ------------------------------------------------------------------
    // 核心：重算并刷新三样视觉
    // ------------------------------------------------------------------

    /// <summary>
    /// 重算本回合敌人的落点 + 攻击目标，刷新贴地箭头/落点虚影/空中弧线。
    /// ★2026-08-22 改从 EnemyLandingPlanner 取「全场计划」中本敌的条目（含先动者
    /// 落点保留避让），与执行器共用同一份计划，保证展示=执行、虚影互不重合。
    /// ★2026-08-19 移动与意图解耦（用户确认）：箭头/虚影=移动预设落点（无论出不出牌都画）；
    /// 弧线=移动后解析出的攻击意图；全失败（疾跑兜底）→ 只有移动视觉、无攻击弧线。
    /// </summary>
    private void RefreshVisuals(HexMover player, Vector2Int playerCoord)
    {
        EnemyLandingPlanner.PlanEntry entry = EnemyLandingPlanner.GetEntry(_enemy, playerCoord);
        RevealedIntentOption chosen = entry != null ? entry.chosen : null;
        Vector2Int landing = entry != null ? entry.landing : _enemy.CurrentCoord;

        // ★2026-08-23 攻击弧线终点=玩家坐标格的世界位置（玩家移动期间=落点格，
        // 固定不随玩家模型实时位置飘动；格子查不到时才兜底用模型位置）
        Vector3 endPos;
        if (!TryGetWorldPos(playerCoord, out endPos))
            endPos = player != null ? player.transform.position : Vector3.zero;

        bool willMove = landing != _enemy.CurrentCoord;
        DrawDashedPath(_groundDashes, _enemy.CurrentCoord, landing, willMove);       // ② 移动虚线路线（按预设，恒画）
        DrawGhost(_ghost, landing, willMove);                                        // ③ 落点虚影
        DrawAirArc(_airArc, chosen, landing, endPos);                                // ① 攻击弧线（无意图=隐藏）
    }

    /// <summary>
    /// §3.8 移动预览：读取 EnemyMovePreview 的「实时预览 / 锁定快照」假设玩家坐标，
    /// 各画一套独立的青 / 紫视觉。与常显（RefreshVisuals）并存，供玩家并排对比「走 A vs 走 B」。
    /// </summary>
    private void RefreshPreview()
    {
        EnemyMovePreview preview = EnemyMovePreview.Instance;
        if (preview == null)
        {
            SetSetVisible(false, _previewDashes, _previewArc, _previewGhost);
            SetSetVisible(false, _lockedDashes, _lockedArc, _lockedGhost);
            return;
        }

        if (preview.LivePreviewCoord.HasValue)
            DrawPreviewSet(_previewDashes, _previewArc, _previewGhost, preview.LivePreviewCoord.Value);
        else
            SetSetVisible(false, _previewDashes, _previewArc, _previewGhost);

        if (preview.LockedCoord.HasValue)
            DrawPreviewSet(_lockedDashes, _lockedArc, _lockedGhost, preview.LockedCoord.Value);
        else
            SetSetVisible(false, _lockedDashes, _lockedArc, _lockedGhost);
    }

    /// <summary>按「假设玩家坐标」重算敌人落点/攻击目标，画到给定的一套视觉上（青=实时 / 紫=锁定）。
    /// ★2026-08-22 改从 EnemyLandingPlanner 取「该假设坐标下的全场计划」中本敌条目——
    /// 预览虚影同样带先动者落点保留避让，多名敌人预览虚影互不重合。</summary>
    private void DrawPreviewSet(DashPool dashes, LineRenderer arc, SpriteRenderer ghost, Vector2Int playerCoord)
    {
        EnemyLandingPlanner.PlanEntry entry = EnemyLandingPlanner.GetEntry(_enemy, playerCoord);
        RevealedIntentOption chosen = entry != null ? entry.chosen : null;
        Vector2Int landing = entry != null ? entry.landing : _enemy.CurrentCoord;

        bool willMove = landing != _enemy.CurrentCoord;
        DrawDashedPath(dashes, _enemy.CurrentCoord, landing, willMove); // 移动虚线路线（按预设，恒画）
        DrawGhost(ghost, landing, willMove);

        if (chosen == null)
        {
            if (arc != null) arc.enabled = false; // 疾跑兜底 → 无攻击弧线
            return;
        }

        Vector3 end;
        if (TryGetWorldPos(playerCoord, out end))
            DrawAirArc(arc, chosen, landing, end);
        else if (arc != null)
            arc.enabled = false;
    }

    // ------------------------------------------------------------------
    // 三样视觉的绘制（参数化：常显 / 实时预览 / 锁定快照共用同一套绘制逻辑）
    // ------------------------------------------------------------------

    /// <summary>
    /// 移动虚线路线：当前格 → 落点，由一串平躺短长方形组成（★2026-08-19 实线→虚线，用户需求）。
    /// 只给方向，不画完整 A* 折线（§3.6）；段数/间距由 DashPool 按距离自适应。
    /// </summary>
    private void DrawDashedPath(DashPool dashes, Vector2Int from, Vector2Int to, bool visible)
    {
        if (dashes == null) return;
        if (!visible || from == to)
        {
            dashes.SetVisible(false);
            return;
        }

        Vector3 a, b;
        if (!TryGetWorldPos(from, out a) || !TryGetWorldPos(to, out b))
        {
            dashes.SetVisible(false);
            return;
        }
        dashes.Draw(a, b, groundY);
    }

    /// <summary>落点虚影：半透明地面环标（Demo 简化「剪影」为地面标记，落点即敌人本回合会走到哪一格）。</summary>
    private void DrawGhost(SpriteRenderer ghost, Vector2Int coord, bool visible)
    {
        if (ghost == null) return;
        if (!visible)
        {
            ghost.enabled = false;
            return;
        }

        Vector3 p;
        if (!TryGetWorldPos(coord, out p))
        {
            ghost.enabled = false;
            return;
        }
        p.y = groundY + 0.01f; // 略高于贴地箭头，避免重叠闪烁
        ghost.transform.position = p;
        ghost.enabled = true;
    }

    /// <summary>
    /// 攻击空中弧线：从落点划向玩家（真实或假设位置）的抛物线。
    /// 仅当所选小意图是「打玩家」的卡（存在非自己的目标效果）才绘制，自 buff 卡不画弧线。
    /// </summary>
    private void DrawAirArc(LineRenderer arc, RevealedIntentOption chosen, Vector2Int landing, Vector3 endPos)
    {
        if (arc == null) return;
        if (chosen == null || chosen.rolledCard == null || !AttacksPlayer(chosen.rolledCard))
        {
            arc.enabled = false;
            return;
        }

        Vector3 start;
        if (!TryGetWorldPos(landing, out start))
        {
            arc.enabled = false;
            return;
        }
        Vector3 end = endPos;
        if (Vector2.Distance(new Vector2(start.x, start.z), new Vector2(end.x, end.z)) < 0.01f)
        {
            arc.enabled = false;
            return;
        }

        start.y = 0.9f; // 敌人胸口高度
        end.y = 0.9f;

        Vector3 mid = (start + end) * 0.5f;
        mid.y += arcHeight;

        arc.positionCount = arcSegments + 1;
        for (int i = 0; i <= arcSegments; i++)
        {
            float t = i / (float)arcSegments;
            arc.SetPosition(i, QuadraticBezier(start, mid, end, t));
        }
        arc.enabled = true;
    }

    /// <summary>该卡是否「打玩家」：存在任意非「自己」目标的效果即为攻击玩家（敌人视角，敌方=玩家）。</summary>
    private static bool AttacksPlayer(Card card)
    {
        if (card == null || card.Data == null) return false;
        foreach (CardEffect e in card.Data.effects)
        {
            if (e == null) continue;
            if (e.targetType != CardTargetType.自己) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 动态构建（零美术资源）
    // ------------------------------------------------------------------

    private void BuildVisuals()
    {
        // 移动虚线路线（短长方形串，★2026-08-19 替代原 2 点实线 LineRenderer）
        _groundDashes = new DashPool("GroundArrowDashes", groundArrowColor, GetVisualRoot(), this);
        // 空中弧线（抛物线）
        _airArc = CreateLineRenderer("AirArc", airArcColor, arcSegments + 1, 0.10f);
        // 落点虚影（地面环标）
        _ghost = CreateGhost("LandingGhost", ghostColor);

        // §3.8 移动预览：实时预览（青）+ 锁定快照（紫）两套独立视觉
        _previewDashes = new DashPool("PreviewArrowDashes", previewColor, GetVisualRoot(), this);
        _previewArc = CreateLineRenderer("PreviewAirArc", previewColor, arcSegments + 1, 0.10f);
        _previewGhost = CreateGhost("PreviewLandingGhost", previewGhostColor);

        _lockedDashes = new DashPool("LockedArrowDashes", lockedColor, GetVisualRoot(), this);
        _lockedArc = CreateLineRenderer("LockedAirArc", lockedColor, arcSegments + 1, 0.10f);
        _lockedGhost = CreateGhost("LockedLandingGhost", lockedGhostColor);

        SetAllVisible(false);
    }

    private void SetAllVisible(bool visible)
    {
        SetSetVisible(visible, _groundDashes, _airArc, _ghost);
        SetSetVisible(visible, _previewDashes, _previewArc, _previewGhost);
        SetSetVisible(visible, _lockedDashes, _lockedArc, _lockedGhost);
    }

    /// <summary>统一开关一套（虚线路线 + 弧线 + 虚影）的可见性。</summary>
    private void SetSetVisible(bool visible, DashPool dashes, LineRenderer arc, SpriteRenderer ghost)
    {
        if (dashes != null) dashes.SetVisible(visible);
        if (arc != null) arc.enabled = visible;
        if (ghost != null) ghost.enabled = visible;
    }

    /// <summary>在共享造型容器下创建世界空间 LineRenderer（不自发光/不投影）。</summary>
    private LineRenderer CreateLineRenderer(string name, Color color, int positionCount, float width)
    {
        GameObject go = new GameObject(name);
        go.transform.SetParent(GetVisualRoot(), false);

        LineRenderer lr = go.AddComponent<LineRenderer>();
        lr.positionCount = positionCount;
        lr.startWidth = width;
        lr.endWidth = width;
        lr.useWorldSpace = true;                    // 世界坐标，不跟随任何父物体
        lr.material = new Material(Shader.Find("Sprites/Default")); // 无光照，时刻可见
        lr.startColor = color;
        lr.endColor = color;
        lr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        lr.receiveShadows = false;
        lr.enabled = false;
        return lr;
    }

    /// <summary>创建落点地面环标：SpriteRenderer + 运行时生成圆环 sprite，平躺在地面。</summary>
    private SpriteRenderer CreateGhost(string name, Color color)
    {
        GameObject go = new GameObject(name);
        go.transform.SetParent(GetVisualRoot(), false);

        SpriteRenderer sr = go.AddComponent<SpriteRenderer>();
        sr.sprite = GetOrCreateGhostSprite();
        sr.color = color;
        sr.sortingOrder = 5;                        // 盖在地面格之上、敌人之下
        sr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        sr.receiveShadows = false;

        // sprite 尺寸 = 1 世界单位（pixelsPerUnit=size），按 ghostRadius 缩放直径
        go.transform.localScale = Vector3.one * (ghostRadius * 2f);
        // 平躺在地面：sprite 法线（-Z）朝上（+Y）
        go.transform.localRotation = Quaternion.Euler(90f, 0f, 0f);
        sr.enabled = false;
        return sr;
    }

    /// <summary>运行时生成中心渐隐的圆形 sprite（全场景共用一份，免美术资产）。</summary>
    private static Sprite GetOrCreateGhostSprite()
    {
        if (_ghostSprite != null) return _ghostSprite;

        const int size = 64;
        var tex = new Texture2D(size, size, TextureFormat.RGBA32, false);
        tex.wrapMode = TextureWrapMode.Clamp;
        Vector2 c = new Vector2(size / 2f, size / 2f);
        float r = size / 2f;

        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                float d = Vector2.Distance(new Vector2(x, y), c);
                float a = Mathf.Clamp01((r - d) / 2f); // 软边渐隐
                tex.SetPixel(x, y, new Color(1f, 1f, 1f, a));
            }
        }
        tex.Apply();

        _ghostSprite = Sprite.Create(tex, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f), size);
        return _ghostSprite;
    }

    /// <summary>运行时生成 1×1 米白色实心方形 sprite（全场景共用一份；配合非等比缩放变成长方形虚线段）。</summary>
    private static Sprite GetOrCreateDashSprite()
    {
        if (_dashSprite != null) return _dashSprite;

        const int size = 16;
        var tex = new Texture2D(size, size, TextureFormat.RGBA32, false);
        var cols = new Color[size * size];
        for (int i = 0; i < cols.Length; i++) cols[i] = Color.white;
        tex.SetPixels(cols);
        tex.Apply();

        // pixelsPerUnit=size → sprite 世界尺寸恰为 1×1 米，localScale=(dashLength, dashWidth) 直接是米
        _dashSprite = Sprite.Create(tex, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f), size);
        return _dashSprite;
    }

    // ------------------------------------------------------------------
    // DashPool：长方形虚线段池（★2026-08-19 新增，替代贴地实线箭头）
    // ------------------------------------------------------------------

    /// <summary>
    /// 一条移动路线的虚线段集合（常显琥珀 / 预览青 / 锁定紫各一池）。
    /// 沿「起点→落点」直线摆放一串平躺的短长方形：长边朝向移动方向，
    /// 第一段贴起点、最后一段贴落点，中间等距（间距 ≤ dashGap 自适应收紧，保证铺满全程）。
    /// 段对象懒创建、跨帧复用，路线变短时多余段隐藏（不销毁，避免反复 GC）。
    /// </summary>
    private class DashPool
    {
        private readonly Transform _root;                                  // 池容器（挂共享造型根下）
        private readonly List<SpriteRenderer> _dashes = new List<SpriteRenderer>(); // 已创建的段（复用池）
        private readonly Color _color;                                     // 本池颜色（一套视觉一色）
        private readonly EnemyIntentVisuals _owner;                        // 读 dashLength/dashGap/dashWidth 几何参数

        public DashPool(string name, Color color, Transform parent, EnemyIntentVisuals owner)
        {
            GameObject go = new GameObject(name);
            _root = go.transform;
            _root.SetParent(parent, false);
            _color = color;
            _owner = owner;
            go.SetActive(false);
        }

        /// <summary>
        /// 沿 a→b（XZ 平面）摆放虚线段，统一离地高度 y。
        /// 距离过近（<0.3m，不足半格）→ 整池隐藏（无需指示）。
        /// </summary>
        public void Draw(Vector3 a, Vector3 b, float y)
        {
            Vector3 delta = b - a;
            delta.y = 0f;
            float dist = delta.magnitude;
            if (dist < 0.3f)
            {
                SetVisible(false);
                return;
            }

            Vector3 dir = delta / dist;
            // 平躺（法线朝上）+ 绕法线转到移动方向：local +X（长边）对齐 dir
            float angle = Mathf.Atan2(delta.z, delta.x) * Mathf.Rad2Deg;
            Quaternion rot = Quaternion.Euler(90f, 0f, 0f) * Quaternion.Euler(0f, 0f, angle);
            Vector3 scale = new Vector3(_owner.dashLength, _owner.dashWidth, 1f);

            // 段数：第一段中心距起点 len/2、最后一段中心距终点 len/2，可排布区间按 stride 估段数（最少 2 段）
            float usable = Mathf.Max(0f, dist - _owner.dashLength);
            int count = Mathf.Max(2, Mathf.FloorToInt(usable / (_owner.dashLength + _owner.dashGap)) + 1);
            float spacing = count > 1 ? usable / (count - 1) : 0f; // 实际间距自适应收紧（≤ dashGap+len）

            for (int i = 0; i < count; i++)
            {
                SpriteRenderer dash = GetDash(i);
                Vector3 pos = a + dir * (_owner.dashLength * 0.5f + spacing * i);
                pos.y = y;
                dash.transform.SetPositionAndRotation(pos, rot);
                dash.transform.localScale = scale;
            }

            // 路线变短 → 隐藏本次用不到的多余段
            for (int i = count; i < _dashes.Count; i++)
            {
                _dashes[i].enabled = false;
            }

            _root.gameObject.SetActive(true);
        }

        /// <summary>整池显隐（池容器 SetActive，一次性开关所有段）。</summary>
        public void SetVisible(bool visible)
        {
            // Play 退出销毁流程中池容器可能已销毁（OnDisable 时序），跳过避免 MissingReferenceException
            if (_root == null) return;
            _root.gameObject.SetActive(visible);
        }

        /// <summary>取第 index 段（不足则懒创建），并确保其处于启用状态。</summary>
        private SpriteRenderer GetDash(int index)
        {
            while (_dashes.Count <= index)
            {
                GameObject go = new GameObject($"Dash{_dashes.Count}");
                go.transform.SetParent(_root, false);

                SpriteRenderer sr = go.AddComponent<SpriteRenderer>();
                sr.sprite = GetOrCreateDashSprite();
                sr.color = _color;
                sr.sortingOrder = 4; // 盖在地面格之上、落点环标(sortingOrder=5)与敌人之下
                sr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
                sr.receiveShadows = false;
                _dashes.Add(sr);
            }
            _dashes[index].enabled = true;
            return _dashes[index];
        }

        /// <summary>销毁池容器及全部段（敌人 OnDestroy 时调用，防泄漏）。</summary>
        public void Destroy()
        {
            if (_root != null) Object.Destroy(_root.gameObject);
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /// <summary>共享造型容器（挂场景根，生命周期独立于敌人；组件销毁时子对象一并清理）。</summary>
    private static Transform GetVisualRoot()
    {
        if (_visualRoot == null)
        {
            _visualRoot = new GameObject("EnemyIntentVisualsRoot").transform;
        }
        return _visualRoot;
    }

    /// <summary>二次贝塞尔（起点→控制点→终点，用于攻击抛物线）。</summary>
    private static Vector3 QuadraticBezier(Vector3 a, Vector3 b, Vector3 c, float t)
    {
        float u = 1f - t;
        return u * u * a + 2f * u * t * b + t * t * c;
    }

    /// <summary>
    /// 取六边形格子世界坐标：优先在「Map」下找 Hex_{x}_{y} 子物体，失败则用 HexGridLayout 公式兜底。
    /// 与 EnemyController.MoveToCoord 的格子查找对齐。
    /// </summary>
    private static bool TryGetWorldPos(Vector2Int coord, out Vector3 world)
    {
        world = Vector3.zero;

        if (_mapCache == null) _mapCache = GameObject.Find("Map") != null ? GameObject.Find("Map").transform : null;

        if (_mapCache != null)
        {
            Transform tile = _mapCache.Find($"Hex_{coord.x}_{coord.y}");
            if (tile != null)
            {
                world = tile.position;
                return true;
            }
        }

        // 兜底：HexGridLayout.GetHexPos 公式（奇数列在 z 方向偏移 h/2，平顶）
        HexGridLayout grid = FindObjectOfType<HexGridLayout>();
        if (grid != null)
        {
            float s = grid.outerSize;
            float w = 2f * s * 0.75f;
            float h = Mathf.Sqrt(3f) * s;
            float offset = (coord.x % 2 != 0) ? h / 2f : 0f;
            Vector3 local = new Vector3(coord.x * w, 0f, -(coord.y * h + offset));
            world = grid.transform.TransformPoint(local);
            return true;
        }

        return false;
    }
}
// =============================================================================
// 模块：M6-4 敌人系统 - EnemyIntentBadgeUI 意图徽章
// 用途：在敌人头顶显示「下回合意图」——只显示「解析后」的单条意图（卡名+大数字）。
// 设计依据：《设计增补_敌人系统_v2.md》§3.3 揭示时机与数值固定 + §3.6 视觉层级。
// 信息分层（★2026-08-19 用户确认重构：不再显示完整 if-else 链）：
//   - 常态：只显示基于玩家真实位置解析出的第一条可行小意图（如「猛击5」）；
//   - 预览中（EnemyMovePreview 实时预览）：若假设位置解析出的意图与当前不同，
//     显示「当前意图→预览意图」（如「猛击5→直刺5」），箭头仅预览时存在；
//   - 玩家实际移动后：按新位置重新解析，回到单意图显示（箭头消失）；
//   - 无任何可行意图（打不到且无自卡）：敌人将追击移动不出牌 → 显示「追击」。
// 挂载：EnemyController.Awake 自动 AddComponent（无需手动挂预制体）。
// 实现：全部代码动态创建（World Space Canvas + Text + Outline），零美术/零串行化引用；
//       LateUpdate 轮询（揭示代数/玩家坐标/敌人坐标/预览坐标 任一变化才重建文本）；
//       raycastTarget=false 不挡格子射线。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 敌人意图徽章。挂在敌人根物体上，自动在头顶创建 World Space 画布显示意图文字。
/// </summary>
public class EnemyIntentBadgeUI : MonoBehaviour
{
    [Header("布局（相对敌人根物体的本地坐标）")]
    [Tooltip("徽章 Y 偏移（★2026-08-19 用户调优：0.3 = 血条上方一点，与血条倾斜面贴合）")]
    [SerializeField] private float offsetY = 0.3f;
    [Tooltip("徽章 Z 偏移（★2026-09-17 晚用户要求「相对 UI 抬高一点」：0.6→0.9）。立绘倾斜 70° 后 +Z 即屏幕上方，用来补偿 HeadAnchor 绝对高度下调（-0.22→-0.30）")]
    [SerializeField] private float offsetZ = 0.9f;
    [Tooltip("画布缩放（1 像素 = 该值单位；0.01 → 40px 字约 0.4m）")]
    [SerializeField] private float canvasScale = 0.01f;
    [Tooltip("字号（画布像素，实际屏幕尺寸 = fontSize * canvasScale）")]
    [SerializeField] private int fontSize = 40;
    [Tooltip("徽章文字颜色（奶黄，匹配美术色板 #F6E4C4）")]
    [SerializeField] private Color textColor = new Color(0.965f, 0.894f, 0.769f, 1f);
    [Tooltip("★2026-08-19 用户需求：徽章像血条一样倾斜面对摄像机（固定 70° 俯视角，与 HPBarCanvas 的 localEulerAngles 一致；不做每帧 Billboard）")]
    [SerializeField] private Vector3 canvasEuler = new Vector3(70f, 0f, 0f);

    private EnemyController _enemy;
    private Text _label;
    private Canvas _canvas;

    // ★2026-09-15 性能：LateUpdate 每帧 FindObjectOfType<HexMover>() 在雾镇 1.2 万对象下
    //   单这一处就吃掉 ~17ms/帧（3 个实例 ×3 次全场景扫描）——改为静态缓存，失配自动重找。
    private static HexMover _cachedPlayer;

    /// <summary>上次已渲染的揭示代数（值变才重建文本）</summary>
    private int _lastGeneration = -1;

    // ★2026-08-19 重算节流状态：解析结果随「玩家/敌人/预览」坐标变化，任一变化才重建
    private Vector2Int _lastPlayerCoord = new Vector2Int(int.MinValue, int.MinValue);
    private Vector2Int _lastEnemyCoord = new Vector2Int(int.MinValue, int.MinValue);
    private Vector2Int? _lastLivePreviewCoord;
    // ★2026-08-22 棋盘签名：任一敌人状态变化（含别人移动/死亡）都会改变全场计划与意图解析
    private long _lastSignature = long.MinValue;

    private void Awake()
    {
        _enemy = GetComponent<EnemyController>();
        CreateBadgeCanvas();
    }

    /// <summary>警戒态文本颜色（警示红，区别于常态奶黄意图文字）——红`!` 与红`?` 共用（字形已区分）</summary>
    private static readonly Color AlertColor = new Color(0.95f, 0.25f, 0.15f, 1f);

    /// <summary>黄`?`搜寻中（威胁预告与搜索 §1：黄=还在找你）</summary>
    private static readonly Color SearchColor = new Color(0.95f, 0.78f, 0.25f, 1f);

    /// <summary>白`?`脱战休整（威胁预告与搜索 §1：白=放弃不找了，正在归队/回巡逻 + 回血）</summary>
    private static readonly Color RestColor = new Color(0.92f, 0.92f, 0.92f, 1f);

    /// <summary>红`?`威胁预告的缓存结果（含 BFS，靠下方变化检测节流，不每帧预测，§2.1）</summary>
    private bool _threatPredicted;

    /// <summary>红`?`状态翻转时广播（true=某敌新出现红?，false=某敌红?消失）。教学 T3 用。</summary>
    public static event System.Action<bool> OnRedQuestionStateChanged;
    private bool _lastRedFired;

    /// <summary>
    /// ★2026-09-08 问号阶段「意图转换预览」文本（如「猛击5」/「追击」；空=无转换）。
    /// 悬停格在视野内时该敌将立即切战斗意图，箭头左侧仍是当前徽章（?/!）——
    /// 徽章显示「?→猛击5」，与战斗态「猛击5→追击」同机制。含 A*，随变化检测节流重算。
    /// </summary>
    private string _transitionText = "";

    /// <summary>
    /// 重算门（纯函数，编辑态 L2 断言用）：无变化 → 不重算；
    /// 战斗态非参战者 → 仅「自身/玩家坐标级变化」才重算（棋盘签名噪声不触发）；
    /// 其余（探索态全员 / 战斗态参战者）→ 任一变化一律重算。
    /// </summary>
    public static bool ShouldRunHeavyBadgeCompute(bool selfChanged, bool sigChanged, bool inBattle, bool isParticipant)
    {
        if (!selfChanged && !sigChanged) return false;
        if (inBattle && !isParticipant) return selfChanged;
        return true;
    }

    private void LateUpdate()
    {
        if (_enemy == null || _label == null) return;

        // ① 死亡隐藏（最高优先级）
        if (_enemy.IsDead)
        {
            if (_canvas.gameObject.activeSelf) _canvas.gameObject.SetActive(false);
            return;
        }

        // 解析意图依赖玩家真实位置；预览箭头依赖实时预览坐标 → 都纳入变化检测
        HexMover player = _cachedPlayer != null ? _cachedPlayer : (_cachedPlayer = FindObjectOfType<HexMover>());
        if (player == null) return;

        EnemyMovePreview preview = EnemyMovePreview.Instance;
        Vector2Int? liveCoord = preview != null ? preview.LivePreviewCoord : null;

        // ★2026-08-23 玩家移动期间视觉锁定：以「本次移动落点」为假设玩家坐标解析意图
        //（MovingDestCoord 移动开始锁定、结束清空）——移动中徽章恒为落点版不逐格跳动。
        // ★P1 锁定恢复（加固）：仅移动中锁定到落点，静止时用 CurrentCoord（与执行器同源），
        // 防 MovingDestCoord 残留污染静止预览。
        Vector2Int playerCoord = (player.IsMoving() && player.MovingDestCoord.HasValue)
            ? player.MovingDestCoord.Value
            : player.CurrentCoord;

        long signature = EnemyLandingPlanner.CurrentSignature;
        bool selfChanged = _enemy.RevealGeneration != _lastGeneration
                        || playerCoord != _lastPlayerCoord
                        || _enemy.CurrentCoord != _lastEnemyCoord
                        || liveCoord != _lastLivePreviewCoord;
        bool sigChanged = signature != _lastSignature;
        bool changed = selfChanged || sigChanged;

        if (changed)
        {
            _lastGeneration = _enemy.RevealGeneration;
            _lastPlayerCoord = playerCoord;
            _lastEnemyCoord = _enemy.CurrentCoord;
            _lastLivePreviewCoord = liveCoord;
            _lastSignature = signature;

            // ★2026-09-16 性能批：战斗中棋盘签名随参战者 AP/揭示逐帧变化 → 全体徽章逐帧重跑
            //   两处含 A* 的重算（威胁预告 + 问号转换）。战斗态非参战者只认自身/玩家坐标级变化：
            //   红`?`/转换预览只在真有动静时刷新，签名噪声帧零成本。
            //   参战者必须保留完整重算（含问号阶段参战者需要红`?`，见徽章显示逻辑注释）。
            bool inBattle = GameStateManager.Instance != null
                            && GameStateManager.Instance.CurrentState == GameState.Battle;
            bool isParticipant = inBattle && BattleResultHandler.Instance != null
                                 && BattleResultHandler.Instance.IsParticipant(_enemy);

            if (ShouldRunHeavyBadgeCompute(selfChanged, sigChanged, inBattle, isParticipant))
            {
                // ★2026-09-16 性能批：下面两次重算都含 A*，次数与耗时进敌人阶段摘要（[性能] 行）。
                System.Diagnostics.Stopwatch badgeWatch = ExplorationPerf.StartTimer();

                // ★红`?`威胁预告重算（§2.1 刷新时机 = 玩家移动落定 / 敌人状态变化）
                _threatPredicted = ThreatPredictor.WillSeePlayerNextMove(_enemy, playerCoord);

                // ★教学 T3：红`?`翻转时广播（仅 toggle，避免每帧刷）
                if (_threatPredicted != _lastRedFired)
                {
                    _lastRedFired = _threatPredicted;
                    OnRedQuestionStateChanged?.Invoke(_threatPredicted);
                }

                // ★2026-09-08 问号阶段意图转换预览（悬停进视野 → 「?→猛击5」）：同样只在此重算
                _transitionText = ComputeQuestionTransition(liveCoord);

                ExplorationPerf.EndBadgeScope(badgeWatch);
            }
            else
            {
                // 跳过重算的帧清空转换预览，防战斗前悬停残留箭头（战斗态无悬停预览）
                _transitionText = "";
            }
        }

        // ★2026-09-08 用户实测修正优先级（设计：死亡 > 战斗意图 > 红`!` > 红`?` > 黄`?` > 白`?`）：
        //   旧顺序让 IsSearching/IsResting 先返回 → 问号阶段的红`!`（被传导）与红`?`（威胁预告）
        //   永远不显示（用户实测：黄`?`接敌不变红、即将看到玩家的单位不变红`?`）。
        //   问号阶段参战者（IsFighting 但 SearchPhase != None）也需要红`!`/红`?`/黄`?`/白`?` → 不能整块跳过。
        //   ★2026-09-08 追加：状态徽章之上叠加「意图转换预览」——悬停进视野 → 「?→猛击5」。
        if (!AlertPropagation.IsFighting(_enemy) || _enemy.SearchPhase != EnemyController.DisengagePhase.None)
        {
            string mark = null;
            Color markColor = textColor;

            // 红`!` 警戒：看见玩家 / 同队传导确认 / 陷阱受击当回合（含问号阶段被传导者）
            if (_enemy.IsAlerted) { mark = "!"; markColor = AlertColor; }
            // 红`?` 威胁预告：下一次移动落点将看见玩家（纯预测，只服务批量移动者，§2.2；
            // 含问号阶段批量移动者——黄`?`散开 / 白`?`归队回巡逻）
            else if (_threatPredicted) { mark = "?"; markColor = AlertColor; }
            // 黄`?` 散开搜索：意图已冻结（§11），只显示状态徽章
            else if (_enemy.IsSearching) { mark = "?"; markColor = SearchColor; }
            // 白`?` 放弃不找了：脱战休整（归队 / 回巡逻 + 回血）。白`?`仅此状态有（§1）。
            else if (_enemy.IsResting) { mark = "?"; markColor = RestColor; }
            // 黄`?` 还在找你：好奇围观 / 追击丢失目标
            else if (_enemy.IsCurious || _enemy.ShowQuestionMark) { mark = "?"; markColor = SearchColor; }

            if (mark != null)
            {
                // 意图转换预览（问号阶段、悬停格在视野内、冻结意图可解析）
                if (_transitionText.Length > 0) mark = $"{mark}→{_transitionText}";
                ShowMark(mark, markColor);
                return;
            }
        }

        // 恢复常态颜色（警戒/问号状态解除后）
        if (_label.color != textColor) _label.color = textColor;

        // 无揭示 → 隐藏徽章
        if (_enemy.RevealedIntent == null)
        {
            if (_canvas.gameObject.activeSelf) _canvas.gameObject.SetActive(false);
            return;
        }

        if (!changed && _label.text.Length > 0 && _canvas.gameObject.activeSelf) return;

        _label.text = BuildBadgeText(playerCoord, liveCoord);
        // ★2026-08-19 用户需求：无可用意图不显示问号，什么都不显示——空文本直接隐藏画布
        _canvas.gameObject.SetActive(!string.IsNullOrEmpty(_label.text));
    }

    /// <summary>显示单字符状态徽章（红`!` / 红`?` / 黄`?` / 白`?`），文本与颜色都无变化时不写。</summary>
    private void ShowMark(string mark, Color color)
    {
        if (_label.text != mark) _label.text = mark;
        if (_label.color != color) _label.color = color;
        if (!_canvas.gameObject.activeSelf) _canvas.gameObject.SetActive(true);
    }

    /// <summary>
    /// ★2026-09-08 问号阶段「意图转换预览」：假设玩家走到悬停格（该格在视野内），
    /// 本敌将立即切换战斗意图——从冻结意图链（§11 不重掷）解析第一条可行小意图，
    /// 返回其徽章文本（「猛击5」；全失败 →「追击」；不能疾跑 → 空）。
    /// 解析口径与红`!`逼近落点一致：按冻结射程参数 EvaluateLanding 假设落点后走 if-else 链
    ///（与战斗态预览「猛击5→追击」同机制，保证问号阶段的预览也忠实于实际会发生什么）。
    /// 无冻结可续（陷阱流/围观者从未进过战）→ 返回空，保持原徽章不画箭头。
    /// </summary>
    private string ComputeQuestionTransition(Vector2Int? liveCoord)
    {
        if (!liveCoord.HasValue) return "";
        if (_enemy.SearchPhase == EnemyController.DisengagePhase.None) return "";
        if (_enemy.data == null) return "";
        // 悬停格在视野内 = 假设玩家走过去会被看见（与 CheckQuestionPhaseWalkIn 判定同口径）
        if (!VisionSystem.CanSee(_enemy.CurrentCoord, liveCoord.Value, _enemy.data.visionRange, VisionSystem.EnemyGreenPenalty)) return "";
        if (_enemy.FrozenIntent == null) return "";

        // ★2026-09-17 解析段抽到 IntentEvaluator.ResolveQuestionChosen（与意图卡面共用同一份结果）。
        // 前置守卫留在本处：这些情形徽章要显示「无转换」（空串），而卡面语义是「不出卡」（null），
        // 两者不能合并——守卫不过才进入共用解析。
        RevealedIntentOption chosen = IntentEvaluator.ResolveQuestionChosen(_enemy, liveCoord.Value);
        if (chosen != null)
        {
            return $"{chosen.option.card.cardName}{ComputeIntentNumber(chosen.rolledCard)}";
        }
        return _enemy.data.canSprint ? "追击" : "";
    }

    // ------------------------------------------------------------------
    // 徽章文本构建（★2026-08-19 重构：只显示解析后的单条意图）
    // ------------------------------------------------------------------

    /// <summary>
    /// 构建徽章文本。规则（用户 2026-08-19 确认）：
    ///   - 常态：只显示基于玩家真实位置解析出的第一条可行小意图（如「猛击5」）；
    ///   - 预览中：假设位置解析意图 ≠ 当前解析意图时，显示「当前→预览」（如「猛击5→直刺5」）；
    ///     中间不可行的选项直接跳过不显示（只显示两端解析结果）；
    ///   - 玩家实际移动后：按新位置重新解析，回到单意图显示；
    ///   - 无可用意图：能疾跑 → 「追击」；不能疾跑 → 空（什么都不显示，不显示问号）。
    /// </summary>
    /// <param name="playerCoord">玩家真实坐标（常态解析依据）</param>
    /// <param name="previewCoord">实时预览的假设坐标（null=无预览）</param>
    private string BuildBadgeText(Vector2Int playerCoord, Vector2Int? previewCoord)
    {
        // ★2026-08-19 用户需求：无意图可用/空意图链（如木桩）→ 什么都不显示（原「?」已删）
        if (_enemy.RevealedIntent == null || _enemy.RevealedIntent.options.Count == 0) return "";

        string current = ResolveIntentText(playerCoord);

        if (previewCoord.HasValue)
        {
            string preview = ResolveIntentText(previewCoord.Value);
            if (preview != current)
            {
                // 预览端为空（不能疾跑且打不到）时箭头悬空不好看，只显示当前意图
                return string.IsNullOrEmpty(preview) ? current : $"{current}→{preview}";
            }
        }
        return current;
    }

    /// <summary>
    /// 解析「该玩家位置下敌人会执行哪条小意图」并转为徽章文本（卡名+大数字）。
    /// ★2026-08-22 改从 EnemyLandingPlanner 取「全场计划」中本敌条目（与执行器共用同一份计划，
    /// 意图解析基于含保留避让的落点），保证展示=执行。
    /// 全部不可行 → canSprint 勾选显示「追击」（按预设移动+疾跑加成），未勾选返回空。
    /// </summary>
    private string ResolveIntentText(Vector2Int playerCoord)
    {
        EnemyLandingPlanner.PlanEntry entry = EnemyLandingPlanner.GetEntry(_enemy, playerCoord);
        if (entry != null && entry.chosen != null)
        {
            return $"{entry.chosen.option.card.cardName}{ComputeIntentNumber(entry.chosen.rolledCard)}";
        }
        // 全部不可行：能疾跑 →「追击」；不能疾跑 → 空文本（LateUpdate 据此隐藏画布）
        return (_enemy.data != null && _enemy.data.canSprint) ? "追击" : "";
    }

    /// <summary>
    /// 计算意图「大数字」：优先伤害总量 > 护甲总量 > 效果层数（取首个非零）。
    /// 公式依据：F5.2 finalValue = baseValue + Σ骰子点数（经 Card.ResolveValue）。
    /// </summary>
    private static int ComputeIntentNumber(Card card)
    {
        if (card == null || card.Data == null) return 0;

        int damage = 0, defense = 0, effectStacks = 0;
        foreach (CardEffect e in card.Data.effects)
        {
            if (e == null) continue;
            switch (e.effectType)
            {
                case CardEffectType.伤害:
                    damage += Mathf.Max(1, card.ResolveValue(e.attackCountConfig)) * card.ResolveValue(e.damageConfig);
                    break;
                case CardEffectType.防御:
                    defense += Mathf.Max(1, card.ResolveValue(e.defenseCountConfig)) * card.ResolveValue(e.defenseConfig);
                    break;
                case CardEffectType.效果:
                    effectStacks += Mathf.Max(1, card.ResolveValue(e.effectCountConfig)) * card.ResolveValue(e.effectStacksConfig);
                    break;
            }
        }

        if (damage > 0) return damage;
        if (defense > 0) return defense;
        return effectStacks;
    }

    // ------------------------------------------------------------------
    // 动态构建（零美术资源）
    // ------------------------------------------------------------------

    private void CreateBadgeCanvas()
    {
        // 世界空间画布根（挂在敌人根物体下，跟随移动）
        GameObject canvasGO = new GameObject("EnemyIntentBadge", typeof(RectTransform));
        canvasGO.transform.SetParent(transform, false);

        RectTransform rt = canvasGO.GetComponent<RectTransform>();
        // ★2026-09-17 贴图放大：锚点改随立绘高度等比（H=1.0→0.22，H=1.4→0.428）
        rt.localPosition = new Vector3(0f, _enemy != null ? _enemy.HeadAnchorLocalY : offsetY, offsetZ);
        rt.localEulerAngles = canvasEuler; // ★2026-08-19 与血条同角度倾斜面对摄像机（固定俯视角，非 Billboard）
        rt.sizeDelta = new Vector2(400f, 300f);
        rt.localScale = new Vector3(canvasScale, canvasScale, 1f);

        _canvas = canvasGO.AddComponent<Canvas>();
        _canvas.renderMode = RenderMode.WorldSpace;
        // ★2026-09-17 晚：徽章层必须高于立绘——BodySprite 的 SpriteRenderer sortingOrder=10，
        // 画布默认 0 会被立绘盖住（用户实测「模型挡住意图」）；12 = 高于立绘、低于血条（预制体 50）
        _canvas.sortingOrder = 12;

        // 文本（叠满画布，居中）
        GameObject textGO = new GameObject("Text", typeof(RectTransform));
        textGO.transform.SetParent(canvasGO.transform, false);
        RectTransform textRT = textGO.GetComponent<RectTransform>();
        textRT.anchorMin = Vector2.zero;
        textRT.anchorMax = Vector2.one;
        textRT.offsetMin = Vector2.zero;
        textRT.offsetMax = Vector2.zero;

        _label = textGO.AddComponent<Text>();
        _label.font = GetSafeFont();
        _label.fontSize = fontSize;
        _label.alignment = TextAnchor.MiddleCenter;
        _label.color = textColor;
        _label.horizontalOverflow = HorizontalWrapMode.Overflow;
        _label.verticalOverflow = VerticalWrapMode.Overflow;
        _label.raycastTarget = false;

        // 黑色描边提升可读性（浮在 3D 场景上不被亮背景吃掉）
        Outline outline = textGO.AddComponent<Outline>();
        outline.effectColor = new Color(0f, 0f, 0f, 0.9f);
        outline.effectDistance = new Vector2(2.5f, -2.5f);

        // 初始隐藏，等到首次揭示才显示
        canvasGO.SetActive(false);
    }

    /// <summary>安全获取内置字体（Unity 2022+ 用 LegacyRuntime.ttf，失败回退场景现有字体）。</summary>
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
            var anyText = Object.FindObjectsOfType<Text>();
            if (anyText != null && anyText.Length > 0 && anyText[0] != null && anyText[0].font != null)
                _cachedFont = anyText[0].font;
        }
        return _cachedFont;
    }
}
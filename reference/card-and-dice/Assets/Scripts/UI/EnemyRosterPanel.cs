// =============================================================================
// 模块：M6-4 敌人系统 - EnemyRosterPanel 右侧常驻敌人头像栏
// 用途：屏幕右侧常驻面板，列出当前战斗中有意图的敌人（头像 + 名字 + 血条 + 意图 + 状态）。
//   ★2026-09-12 用户定：只列「有意图的」（战斗意图 / 参战者 / 红`!`·黄`?`·白`?`状态），
//   照常巡逻、无意图的敌人不上栏。
//   价值（§3.7）：玩家「任何时刻」一眼掌握场上敌人有哪些、各自想干嘛、挂了什么状态，
//   不依赖敌人是否在屏幕内 / 是否被遮挡。
// 设计依据：《设计增补_敌人系统_v2.md》§3.7
// 挂载：挂在 UICanvas（Screen Space Overlay）上即可；Awake 自动在其下创建面板。
// 实现：零美术 / 零串行化引用，全部代码动态创建（沿用 EnemyIntentBadgeUI / StatusBadgeUI 模式）。
//       条目标题/名字/意图/状态/血条全部手动锚点定位，面板高度随敌人数显式计算（无 LayoutGroup）。
//       LateUpdate 轮询：仅当「存活敌人集合」变化才重建条目；否则只按值变刷新 HP/意图/移动点/状态文本。
//       ★2026-08-19 意图显示与头顶徽章同规则（解析后单意图 + 预览「当前→预览」箭头，
//       玩家/敌人/预览坐标任一变化即刷新）；条目名字行右侧显示移动点（MoveBudget=AP+疾跑值）。
//       射线：面板本体/文字/头像一律 raycastTarget=false，不挡右侧格子点击；
//       ★2026-09-17 起「条目底板」接射线（整行可点开左侧详情面板，用户已接受点击不再穿透到地图）。
// 说明：hover 展开完整 if-else 链 + 被动面板（§5.3 L2）属独立组件 EnemyPassivePanel，本类不做。
// ★2026-09-17 意图卡牌轮：条目整行可点 → EnemyDetailPanelUI.Toggle（左侧详情面板，独立组件）。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 右侧常驻敌人头像栏。挂在 UICanvas 上，自动创建面板并轮询刷新。
/// </summary>
public class EnemyRosterPanel : MonoBehaviour
{
    [Header("面板布局（Screen Space Overlay 像素）")]
    [Tooltip("面板右上角偏移（负=向内缩）")]
    [SerializeField] private Vector2 panelOffset = new Vector2(-20f, -120f);
    [Tooltip("单个敌人条目宽")]
    [SerializeField] private float entryWidth = 220f;
    [Tooltip("单个敌人条目标高")]
    [SerializeField] private float entryHeight = 70f;
    [Tooltip("条目间距")]
    [SerializeField] private float entrySpacing = 8f;

    [Header("配色（匹配美术色板）")]
    [SerializeField] private Color panelBgColor = new Color(0.11f, 0.07f, 0.02f, 0.72f);  // 深棕木底半透明
    [SerializeField] private Color nameColor = new Color(0.965f, 0.894f, 0.769f, 1f);    // 奶黄 #F6E4C4
    [SerializeField] private Color intentColor = new Color(0.89f, 0.71f, 0.40f, 1f);      // 黄铜 #E3B567
    [SerializeField] private Color hpFillColor = new Color(0.85f, 0.30f, 0.25f, 1f);      // 红
    [SerializeField] private Color hpBgColor = new Color(0f, 0f, 0f, 0.55f);
    [SerializeField] private Color statusColor = new Color(0.25f, 0.80f, 0.55f, 1f);      // 状态绿
    [SerializeField] private Color moveColor = new Color(0.25f, 0.80f, 0.40f, 1f);        // ★2026-08-19 移动点绿（与 AP 绿点同色系）
    [SerializeField] private Color entryBgColor = new Color(0f, 0f, 0f, 0.35f);

    // ------------------------------------------------------------------
    // 布局常量（本文件内局部，不入 Inspector，避免调乱）
    // ------------------------------------------------------------------
    private const float PADDING = 8f;        // 面板内边距
    private const float TITLE_H = 24f;        // 标题区高
    private const float AVATAR_SIZE = 44f;    // 头像边长
    private const float TEXT_X = AVATAR_SIZE + 8f; // 文本列起始 X（头像右侧）

    // ------------------------------------------------------------------
    // 运行时状态
    // ------------------------------------------------------------------
    private RectTransform _panelRT;
    private RectTransform _titleRT;

    /// <summary>存活敌人条目（与当前存活敌人集合一一对应）</summary>
    private class EnemyEntry
    {
        public EnemyController enemy;
        public GameObject root;
        public Image hpFill;
        public Text hpText;
        public Text intentText;
        public Text statusText;
        public Text moveText;

        public int lastHP = -1;
        public int lastGen = -1;
        public int lastStatusHash = -1;
        public int lastMove = -1;
        // ★2026-08-19 意图解析依赖玩家/敌人坐标（与头顶徽章同规则），纳入变化检测
        public Vector2Int lastEnemyCoord = new Vector2Int(int.MinValue, int.MinValue);
    }
    private readonly List<EnemyEntry> _entries = new List<EnemyEntry>();

    // 上次已渲染的存活敌人实例 ID 序列（用于判断集合是否变化 → 重建）
    private readonly List<int> _cachedIDs = new List<int>();

    // ★2026-08-19 面板级缓存：玩家坐标 / 实时预览坐标（全体条目共享，变化才重算意图文本）
    private Vector2Int _lastPlayerCoord = new Vector2Int(int.MinValue, int.MinValue);
    private Vector2Int? _lastPreviewCoord;
    // ★2026-08-22 棋盘签名：任一敌人状态变化（含别人移动/死亡）都会改变全场计划与意图解析
    private long _lastSignature = long.MinValue;

    // 共享资源
    private static Sprite _whitePixel;
    private static Font _cachedFont;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Awake()
    {
        CreatePanel();
    }

    private void LateUpdate()
    {
        if (_panelRT == null) return;

        // 非战斗状态 → 隐藏面板（§3.8「仅战斗模式」同源；头像栏只在战斗中常驻）
        bool inBattle = GameStateManager.Instance != null
                     && GameStateManager.Instance.CurrentState == GameState.Battle;
        if (_panelRT.gameObject.activeSelf != inBattle)
            _panelRT.gameObject.SetActive(inBattle);
        if (!inBattle) return;

        // 收集存活敌人（按实例 ID 稳定排序，避免每帧因 FindObjectsOfType 顺序抖动而误重建）
        List<EnemyController> alive = GetAliveEnemies();

        if (SetChanged(alive))
        {
            RebuildEntries(alive);
        }
        else
        {
            RefreshValues();
        }
    }

    private void OnDestroy()
    {
        if (_panelRT != null) Destroy(_panelRT.gameObject);
        _entries.Clear();
    }

    // ------------------------------------------------------------------
    // 轮询核心
    // ------------------------------------------------------------------

    /// <summary>
    /// 列出存活敌人中「有意图的」子集，并按实例 ID 排序（稳定顺序）。
    /// ★2026-09-12 用户定：右栏不再列全场景怪物——只有有意图的才上栏
    ///（战斗意图已揭示 / 本场参战者 / 问号·警戒状态），照常巡逻的路人不上栏。
    /// </summary>
    private static List<EnemyController> GetAliveEnemies()
    {
        List<EnemyController> alive = new List<EnemyController>();
        EnemyController[] all = FindObjectsOfType<EnemyController>();
        foreach (EnemyController e in all)
        {
            if (e != null && !e.IsDead && e.gameObject.activeInHierarchy && HasVisibleIntent(e))
                alive.Add(e);
        }
        alive.Sort((a, b) => a.GetInstanceID().CompareTo(b.GetInstanceID()));
        return alive;
    }

    /// <summary>
    /// ★2026-09-12「有意图」判据（口径对齐头顶徽章 EnemyIntentBadgeUI，徽章会显示内容 = 上栏）：
    ///   ① 战斗意图已揭示（RevealedIntent 有可选项）——正常参战者；
    ///   ② 本场参战者——意图文本偶空（如只能追击被截断）也不该从栏里消失；
    ///   ③ 问号/警戒状态（红`!` / 黄`?` / 白`?`：警戒 / 散开搜索 / 归队休整 / 围观 / 陷阱搜查）。
    /// 三者皆非（照常巡逻、无任何意图与状态）→ 不上右栏。
    /// ★2026-09-17 改 public：详情面板的「掉出名册自动关」判据复用本口径。
    /// </summary>
    public static bool HasVisibleIntent(EnemyController e)
    {
        if (e.RevealedIntent != null && e.RevealedIntent.options.Count > 0) return true;
        if (AlertPropagation.IsFighting(e)) return true;
        return e.IsAlerted || e.IsCurious || e.ShowQuestionMark
            || e.SearchPhase != EnemyController.DisengagePhase.None || e.PendingTrapSearch;
    }

    /// <summary>存活集合（实例 ID 序列）是否与上次不同。</summary>
    private bool SetChanged(List<EnemyController> alive)
    {
        if (alive.Count != _cachedIDs.Count) return true;
        for (int i = 0; i < alive.Count; i++)
        {
            if (alive[i].GetInstanceID() != _cachedIDs[i]) return true;
        }
        return false;
    }

    /// <summary>集合变化 → 清空并重建所有条目，面板高度随敌人数显式自适配。</summary>
    private void RebuildEntries(List<EnemyController> alive)
    {
        // 清旧
        foreach (EnemyEntry entry in _entries)
        {
            if (entry.root != null) Destroy(entry.root);
        }
        _entries.Clear();
        _cachedIDs.Clear();

        // 建新 + 手动定位
        float y = TITLE_H + PADDING;
        for (int i = 0; i < alive.Count; i++)
        {
            EnemyEntry entry = CreateEntry(alive[i]);
            RectTransform rt = entry.root.GetComponent<RectTransform>();
            rt.anchorMin = new Vector2(0f, 1f);
            rt.anchorMax = new Vector2(0f, 1f);
            rt.pivot = new Vector2(0f, 1f);
            rt.anchoredPosition = new Vector2(PADDING, -y);
            rt.sizeDelta = new Vector2(entryWidth, entryHeight);

            _entries.Add(entry);
            _cachedIDs.Add(alive[i].GetInstanceID());
            y += entryHeight + entrySpacing;
        }

        // 面板高度 = 标题 + 底部内边距 + Σ(条目+间距)
        float totalHeight = TITLE_H + PADDING + y - entrySpacing + PADDING;
        _panelRT.sizeDelta = new Vector2(entryWidth + PADDING * 2f, totalHeight);

        // 首帧填充文本（CreateEntry 里 lastGen=-1 会立即写意图文本，此处补 HP/状态）
        RefreshValues();
    }

    /// <summary>集合未变 → 只刷新每条的 HP / 意图 / 移动点 / 状态（值变才写，省开销）。</summary>
    private void RefreshValues()
    {
        // ★2026-08-19 意图解析依赖玩家真实位置 + 实时预览坐标（与头顶徽章同规则），
        // 任一变化才重算意图文本；玩家不存在（极端情况）则跳过意图刷新
        HexMover[] movers = FindObjectsOfType<HexMover>();
        HexMover player = movers.Length > 0 ? movers[0] : null;
        EnemyMovePreview preview = EnemyMovePreview.Instance;
        Vector2Int? previewCoord = preview != null ? preview.LivePreviewCoord : null;
        // ★P1 锁定恢复（加固）：仅移动中锁定到落点，静止时用 CurrentCoord（与执行器同源），
        // 防 MovingDestCoord 残留污染静止预览。
        Vector2Int playerCoord = player != null
            ? (player.IsMoving() && player.MovingDestCoord.HasValue
                ? player.MovingDestCoord.Value
                : player.CurrentCoord)
            : new Vector2Int(-1, -1);
        bool globalMoved = player != null
                        && (playerCoord != _lastPlayerCoord || previewCoord != _lastPreviewCoord);
        if (globalMoved)
        {
            _lastPlayerCoord = playerCoord;
            _lastPreviewCoord = previewCoord;
        }
        // ★2026-08-22 棋盘签名：任一敌人状态变化（含别人移动/死亡）→ 全场计划变 → 重算意图
        long signature = EnemyLandingPlanner.CurrentSignature;
        bool boardChanged = signature != _lastSignature;
        if (boardChanged) _lastSignature = signature;

        foreach (EnemyEntry entry in _entries)
        {
            if (entry == null || entry.enemy == null) continue;

            // HP
            int hp = entry.enemy.CurrentHP;
            int maxHp = entry.enemy.MaxHP;
            if (hp != entry.lastHP)
            {
                entry.lastHP = hp;
                float ratio = maxHp > 0 ? (float)hp / maxHp : 0f;
                if (entry.hpFill != null)
                {
                    RectTransform fillRT = entry.hpFill.rectTransform;
                    fillRT.anchorMax = new Vector2(Mathf.Clamp01(ratio), fillRT.anchorMax.y);
                }
                if (entry.hpText != null) entry.hpText.text = $"{hp}/{maxHp}";
            }

            // 意图：揭示代数 / 玩家坐标 / 敌人坐标 / 预览坐标 / 棋盘签名 任一变化才重建文本
            int gen = entry.enemy.RevealGeneration;
            bool enemyMoved = entry.enemy.CurrentCoord != entry.lastEnemyCoord;
            if (gen != entry.lastGen || enemyMoved || (globalMoved && player != null) || boardChanged)
            {
                entry.lastGen = gen;
                entry.lastEnemyCoord = entry.enemy.CurrentCoord;
                if (entry.intentText != null)
                    entry.intentText.text = player != null
                        ? BuildIntentText(entry.enemy, playerCoord, previewCoord)
                        : BuildIntentText(entry.enemy);
            }

            // ★2026-08-19 移动点（MoveBudget = 当前行动点 + 疾跑值，与脚下 AP 绿点同源）
            int move = entry.enemy.MoveBudget;
            if (move != entry.lastMove)
            {
                entry.lastMove = move;
                if (entry.moveText != null) entry.moveText.text = $"移动{move}";
            }

            // 状态效果（哈希变化才重建文本）
            int statusHash = ComputeStatusHash(entry.enemy);
            if (statusHash != entry.lastStatusHash)
            {
                entry.lastStatusHash = statusHash;
                if (entry.statusText != null)
                    entry.statusText.text = BuildStatusText(entry.enemy);
            }
        }
    }

    // ------------------------------------------------------------------
    // 文本构建
    // ------------------------------------------------------------------

    /// <summary>
    /// 意图文本（★2026-08-19 与头顶徽章同规则，用户确认）：只显示解析后的单条意图——
    ///   常态=基于玩家真实位置的第一条可行小意图（「猛击5」）；
    ///   预览中且假设位置解析意图≠当前 → 「当前→预览」（「猛击5→直刺5」）；
    ///   全部不可行 → canSprint 勾选显示「追击」，未勾选显示空。
    /// 解析共用 IntentEvaluator.ResolveTurn，保证与敌人实际执行严格一致。
    /// </summary>
    private static string BuildIntentText(EnemyController enemy, Vector2Int playerCoord, Vector2Int? previewCoord)
    {
        if (enemy == null || enemy.RevealedIntent == null || enemy.RevealedIntent.options.Count == 0) return "";

        string current = ResolveIntentText(enemy, playerCoord);
        if (previewCoord.HasValue)
        {
            string preview = ResolveIntentText(enemy, previewCoord.Value);
            if (preview != current && !string.IsNullOrEmpty(preview))
                return $"{current}→{preview}";
        }
        return current;
    }

    /// <summary>单条意图解析文本：卡名+大数字；全失败→canSprint?「追击」:空。
    /// ★2026-08-22 改从 EnemyLandingPlanner 取「全场计划」中该敌条目（与执行器共用同一份计划，
    /// 意图解析基于含保留避让的落点），保证与敌人实际执行严格一致。</summary>
    private static string ResolveIntentText(EnemyController enemy, Vector2Int playerCoord)
    {
        EnemyLandingPlanner.PlanEntry entry = EnemyLandingPlanner.GetEntry(enemy, playerCoord);
        if (entry != null && entry.chosen != null)
        {
            return $"{entry.chosen.option.card.cardName}{ComputeIntentNumber(entry.chosen.rolledCard)}";
        }
        return (enemy.data != null && enemy.data.canSprint) ? "追击" : "";
    }

    /// <summary>意图文本（无玩家坐标兜底：直接读已揭示意图，不解析射程）。</summary>
    private static string BuildIntentText(EnemyController enemy)
    {
        EnemyRevealedIntent revealed = enemy != null ? enemy.RevealedIntent : null;
        if (revealed == null || revealed.options.Count == 0) return "";

        RevealedIntentOption primary = revealed.Primary;
        if (primary == null || primary.option == null || primary.option.card == null) return "";
        return $"{primary.option.card.cardName}{ComputeIntentNumber(primary.rolledCard)}";
    }

    /// <summary>意图「大数字」：伤害 > 护甲 > 效果层数（取首个非零）。公式 F5.2。</summary>
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

    /// <summary>状态文本：敌人身上所有活跃效果的「名称 + 层数」列表。</summary>
    private static string BuildStatusText(EnemyController enemy)
    {
        if (enemy == null || EffectManager.Instance == null) return "";
        List<EffectInstance> effects = EffectManager.Instance.GetEffectsOnTarget(enemy.gameObject);
        if (effects == null || effects.Count == 0) return "";

        var parts = new List<string>();
        foreach (EffectInstance inst in effects)
        {
            if (inst == null || inst.Effect == null) continue;
            parts.Add(inst.Stacks > 1 ? $"{inst.Effect.Name} {inst.Stacks}" : inst.Effect.Name);
        }
        return parts.Count > 0 ? string.Join("  ", parts) : "";
    }

    /// <summary>状态集合的轻量哈希（效果名 + 层数），用于判断是否需重建状态文本。</summary>
    private static int ComputeStatusHash(EnemyController enemy)
    {
        if (enemy == null || EffectManager.Instance == null) return 0;
        List<EffectInstance> effects = EffectManager.Instance.GetEffectsOnTarget(enemy.gameObject);
        if (effects == null) return 0;
        int hash = effects.Count;
        foreach (EffectInstance inst in effects)
        {
            if (inst == null || inst.Effect == null) continue;
            hash = unchecked(hash * 31 + inst.Effect.GetType().Name.GetHashCode() + inst.Stacks);
        }
        return hash;
    }

    // ------------------------------------------------------------------
    // 动态构建（零美术资源）
    // ------------------------------------------------------------------

    private void CreatePanel()
    {
        Canvas canvas = GetComponentInParent<Canvas>();
        Transform parent = canvas != null ? canvas.transform : transform;

        // 面板根（右上角锚定）
        GameObject panelGO = new GameObject("EnemyRosterPanel", typeof(RectTransform));
        panelGO.transform.SetParent(parent, false);
        _panelRT = panelGO.GetComponent<RectTransform>();
        _panelRT.anchorMin = _panelRT.anchorMax = new Vector2(1f, 1f); // 右上角
        _panelRT.pivot = new Vector2(1f, 1f);
        _panelRT.anchoredPosition = panelOffset;

        // 背景（半透明深棕，铺满面板）
        Image bg = panelGO.AddComponent<Image>();
        bg.sprite = GetWhitePixel();
        bg.color = panelBgColor;
        bg.raycastTarget = false;

        // 顶部标题
        CreateLabel(panelGO.transform, "标题", "敌人", nameColor, 16, out _, out _titleRT);
        _titleRT.anchorMin = new Vector2(0f, 1f);
        _titleRT.anchorMax = new Vector2(1f, 1f);
        _titleRT.pivot = new Vector2(0.5f, 1f);
        _titleRT.anchoredPosition = new Vector2(0f, -2f);
        _titleRT.sizeDelta = new Vector2(0f, TITLE_H);

        // 面板初始尺寸（RebuildEntries 会按敌人数重算高度）
        _panelRT.sizeDelta = new Vector2(entryWidth + PADDING * 2f, TITLE_H + PADDING * 2f);

        // 面板初始隐藏（进战斗才显示）
        panelGO.SetActive(false);
    }

    /// <summary>为一名敌人创建条目：头像 +（名字/意图/状态）+ 血条。</summary>
    private EnemyEntry CreateEntry(EnemyController enemy)
    {
        EnemyEntry entry = new EnemyEntry { enemy = enemy };

        GameObject root = new GameObject(enemy.data != null ? enemy.data.enemyName : "敌人", typeof(RectTransform));
        RectTransform rt = root.GetComponent<RectTransform>();
        rt.SetParent(_panelRT, false);
        entry.root = root;

        // 背景底板（铺满条目）
        Image entryBg = root.AddComponent<Image>();
        entryBg.sprite = GetWhitePixel();
        entryBg.color = entryBgColor;
        entryBg.raycastTarget = false;

        // ---- 头像（左上方，方形）----
        Image avatar = CreateAvatar(root.transform);
        RectTransform avatarRT = avatar.rectTransform;
        avatarRT.anchorMin = avatarRT.anchorMax = new Vector2(0f, 1f);
        avatarRT.pivot = new Vector2(0f, 1f);
        avatarRT.anchoredPosition = new Vector2(4f, -4f);
        avatarRT.sizeDelta = new Vector2(AVATAR_SIZE, AVATAR_SIZE);

        // ---- 名字（头像右侧，第一行）----
        CreateLabel(root.transform, "Name", enemy.data != null ? enemy.data.enemyName : "敌人",
                    nameColor, 14, out Text nameText, out RectTransform nameRT);
        nameRT.anchorMin = new Vector2(0f, 1f);
        nameRT.anchorMax = new Vector2(1f, 1f);
        nameRT.pivot = new Vector2(0f, 1f);
        nameRT.anchoredPosition = new Vector2(TEXT_X, -2f);
        nameRT.sizeDelta = new Vector2(-TEXT_X - 4f, 18f);
        nameText.alignment = TextAnchor.UpperLeft;

        // ---- 移动点（名字行右侧，★2026-08-19 用户需求：显示怪物移动点 = MoveBudget）----
        CreateLabel(root.transform, "Move", "", moveColor, 12, out entry.moveText, out RectTransform moveRT);
        moveRT.anchorMin = new Vector2(1f, 1f);
        moveRT.anchorMax = new Vector2(1f, 1f);
        moveRT.pivot = new Vector2(1f, 1f);
        moveRT.anchoredPosition = new Vector2(-4f, -4f);
        moveRT.sizeDelta = new Vector2(52f, 16f);
        entry.moveText.alignment = TextAnchor.UpperRight;

        // ---- 意图（第二行）----
        CreateLabel(root.transform, "Intent", "", intentColor, 13, out entry.intentText, out RectTransform intentRT);
        intentRT.anchorMin = new Vector2(0f, 1f);
        intentRT.anchorMax = new Vector2(1f, 1f);
        intentRT.pivot = new Vector2(0f, 1f);
        intentRT.anchoredPosition = new Vector2(TEXT_X, -22f);
        intentRT.sizeDelta = new Vector2(-TEXT_X - 4f, 18f);
        entry.intentText.alignment = TextAnchor.UpperLeft;

        // ---- 状态（第三行，可空）----
        CreateLabel(root.transform, "Status", "", statusColor, 12, out entry.statusText, out RectTransform statusRT);
        statusRT.anchorMin = new Vector2(0f, 1f);
        statusRT.anchorMax = new Vector2(1f, 1f);
        statusRT.pivot = new Vector2(0f, 1f);
        statusRT.anchoredPosition = new Vector2(TEXT_X, -42f);
        statusRT.sizeDelta = new Vector2(-TEXT_X - 4f, 16f);
        entry.statusText.alignment = TextAnchor.UpperLeft;

        // ---- 血条（底部横条）+ 数值 ----
        CreateHPBar(root.transform, TEXT_X, out entry.hpFill, out entry.hpText);

        // 首帧填充由 RebuildEntries 末尾的 RefreshValues() 完成
        entry.lastHP = -1;
        entry.lastGen = -1;
        entry.lastStatusHash = -1;

        // ★2026-09-17 意图卡牌轮：整行可点 → 开/关左侧详情面板（设计轮规则④，用户已拍板接受
        // 「点击不再穿透到地图」）。★同轮修正：Graphic 是 DisallowMultipleComponent——同一 GO
        // 第二次 AddComponent<Image> 返回 null（曾致 CreateEntry 抛 NRE，右栏整栏建不出来），
        // 改为让条目底板直接接射线（底板本就铺满条目，视觉不变）。
        entryBg.raycastTarget = true;
        Button btn = root.AddComponent<Button>();
        btn.targetGraphic = entryBg;
        btn.transition = Selectable.Transition.None;
        EnemyController captured = enemy;
        btn.onClick.AddListener(() => EnemyDetailPanelUI.Toggle(captured));

        return entry;
    }

    private Image CreateAvatar(Transform parent)
    {
        GameObject go = new GameObject("Avatar", typeof(RectTransform));
        go.transform.SetParent(parent, false);
        Image avatar = go.AddComponent<Image>();
        // ★2026-09-17 晚四修：用户要求右栏不展示敌人肖像（战斗中右侧面板只留纯色块，原状）——
        // data.icon / Resources 立绘两条取图路径都已撤掉，不要再往这里接怪物图片。
        avatar.sprite = GetWhitePixel();
        avatar.color = intentColor;
        avatar.raycastTarget = false;
        return avatar;
    }

    /// <summary>创建血条：背景 + 锚点填充子图 + 数值文本（底部一行）。</summary>
    private void CreateHPBar(Transform parent, float x, out Image fill, out Text hpText)
    {
        const float barHeight = 8f;

        // 背景（底部，从 x 到右侧，右侧留数值宽度）
        GameObject bgGO = new GameObject("HPBar", typeof(RectTransform));
        bgGO.transform.SetParent(parent, false);
        Image bg = bgGO.AddComponent<Image>();
        bg.sprite = GetWhitePixel();
        bg.color = hpBgColor;
        bg.raycastTarget = false;
        RectTransform bgRT = bgGO.GetComponent<RectTransform>();
        bgRT.anchorMin = new Vector2(0f, 0f);
        bgRT.anchorMax = new Vector2(0f, 0f);
        bgRT.pivot = new Vector2(0f, 0f);
        bgRT.anchoredPosition = new Vector2(x, 6f);
        bgRT.sizeDelta = new Vector2(-x - 52f, barHeight); // 右侧留 52 for 数值文本

        // 填充（anchorMax.x 随比例变化，由 RefreshValues 更新）
        GameObject fillGO = new GameObject("Fill", typeof(RectTransform));
        fillGO.transform.SetParent(bgGO.transform, false);
        fill = fillGO.AddComponent<Image>();
        fill.sprite = GetWhitePixel();
        fill.color = hpFillColor;
        fill.raycastTarget = false;
        RectTransform fillRT = fillGO.GetComponent<RectTransform>();
        fillRT.anchorMin = new Vector2(0f, 0f);
        fillRT.anchorMax = new Vector2(1f, 1f);
        fillRT.offsetMin = Vector2.zero;
        fillRT.offsetMax = Vector2.zero;

        // 数值（血条右侧）
        GameObject textGO = new GameObject("HPText", typeof(RectTransform));
        textGO.transform.SetParent(parent, false);
        CreateLabelOn(textGO, "", Color.white, 11, out hpText);
        RectTransform textRT = textGO.GetComponent<RectTransform>();
        textRT.anchorMin = new Vector2(1f, 0f);
        textRT.anchorMax = new Vector2(1f, 0f);
        textRT.pivot = new Vector2(1f, 0f);
        textRT.anchoredPosition = new Vector2(-2f, 6f);
        textRT.sizeDelta = new Vector2(48f, 12f);
        hpText.alignment = TextAnchor.UpperRight;
    }

    // ------------------------------------------------------------------
    // UI 构造小工具
    // ------------------------------------------------------------------

    private void CreateLabel(Transform parent, string name, string text, Color color, int fontSize, out Text label)
    {
        CreateLabel(parent, name, text, color, fontSize, out label, out _);
    }

    private void CreateLabel(Transform parent, string name, string text, Color color, int fontSize, out Text label, out RectTransform rt)
    {
        GameObject go = new GameObject(name, typeof(RectTransform));
        go.transform.SetParent(parent, false);
        rt = go.GetComponent<RectTransform>();
        CreateLabelOn(go, text, color, fontSize, out label);
    }

    private void CreateLabelOn(GameObject go, string text, Color color, int fontSize, out Text label)
    {
        label = go.AddComponent<Text>();
        label.font = GetSafeFont();
        label.fontSize = fontSize;
        label.alignment = TextAnchor.UpperLeft;
        label.color = color;
        label.horizontalOverflow = HorizontalWrapMode.Overflow;
        label.verticalOverflow = VerticalWrapMode.Overflow;
        label.raycastTarget = false;
        label.text = text;
    }

    /// <summary>1×1 白色像素 Sprite（Image 填充/色块共用的最小纹理）。</summary>
    private static Sprite GetWhitePixel()
    {
        if (_whitePixel != null) return _whitePixel;
        var tex = new Texture2D(1, 1, TextureFormat.RGBA32, false);
        tex.SetPixel(0, 0, Color.white);
        tex.Apply();
        _whitePixel = Sprite.Create(tex, new Rect(0, 0, 1, 1), new Vector2(0.5f, 0.5f), 1f);
        return _whitePixel;
    }

    /// <summary>安全获取内置字体：LegacyRuntime.ttf（Unity 2022+）→ 场景现有 Text 借用。</summary>
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
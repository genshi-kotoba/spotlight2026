// =============================================================================
// 模块：敌人意图卡牌 - 头顶悬停卡面（★2026-09-17 怪物卡牌可见性轮）
// 用途：鼠标悬停敌人所在格 → 在该敌头顶展开「当前解析出的那一条小意图」的真实卡面
//       （屏幕 UI 层、正立、跟随移动）。
// 设计定稿：docs/2026-09-17_敌人意图卡牌-design.md（已拍三条 + 默认六条开合规则）。
// 要点：
//   ① 触发=悬停非点击；指针离开敌人格且离开卡面矩形 → 收起（0.15s 宽限防断链闪烁）；
//   ② 卡面锚在该敌头顶世界坐标的屏幕投影，跟随移动；
//   ③ 与头顶徽章同源：战斗态=EnemyLandingPlanner.GetEntry 解析；问号态=IntentEvaluator.ResolveQuestionChosen；
//   ④ 只展开当前解析出的那一条小意图；解析全失败（追击/无卡）→ 不出卡；
//   ⑤ 玩家看不见的敌人不出卡（玩家视野 10 格、只吃红格，与 EnemyRenderLod 同源）；
//   ⑥ 当前回合卡已掷骰锁死 → 显示最终值（蓝骰段）；耗能角标藏掉；射程小字脚注。
// 实现：零美术动态创建（EnemyRosterPanel 模式）；AfterSceneLoad 自动引导；
//       LateUpdate 轮询 HexMover.CurrentHoverCoord + UnitOccupancy.LivingEnemies 查敌人。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class EnemyIntentCardUI : MonoBehaviour
{
    const float CardVisualHeight = 360f;   // 卡面视觉高度（264×360，与装填放大卡同款）
    const float CardDesignHeight = 154f;   // CardView 预制体设计高（LoadoutUI 同口径）
    const float CardDesignWidth = 110f;
    const float GraceSeconds = 0.15f;      // 鼠标从敌人格挪到卡面的断链宽限

    static EnemyIntentCardUI s_instance;

    RectTransform _canvasRT;
    RectTransform _containerRT;            // 卡面容器（264×360，未缩放 → 矩形判定用）
    CardView _cardView;
    Text _rangeFootnote;

    EnemyController _target;
    RevealedIntentOption _shownOption;
    float _graceUntil;

    // 内容同源变化检测（与头顶徽章同规则）
    int _lastGen = -1;
    Vector2Int _lastPlayerCoord = new Vector2Int(int.MinValue, int.MinValue);
    Vector2Int _lastEnemyCoord = new Vector2Int(int.MinValue, int.MinValue);
    Vector2Int? _lastPreviewCoord;
    long _lastSignature = long.MinValue;

    static HexMover _cachedPlayer;
    static Font _cachedFont;
    static Sprite _whitePixel;

    /// <summary>场景加载后自动引导（探索态问号阶段也要用，不能只挂战斗引导）。</summary>
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    static void AutoBootstrap()
    {
        EnsureExists();
    }

    public static void EnsureExists()
    {
        if (s_instance != null) return;
        GameObject go = new GameObject("EnemyIntentCardUI");
        s_instance = go.AddComponent<EnemyIntentCardUI>();
    }

    void Awake()
    {
        Canvas canvas = FindOverlayCanvas();
        if (canvas == null)
        {
            Debug.LogWarning("[EnemyIntentCardUI] 找不到 ScreenSpaceOverlay 画布，悬停卡面不工作");
            return;
        }
        _canvasRT = canvas.GetComponent<RectTransform>();

        GameObject bgGO = new GameObject("HoverCard", typeof(RectTransform));
        bgGO.transform.SetParent(canvas.transform, false);
        _containerRT = bgGO.GetComponent<RectTransform>();
        _containerRT.sizeDelta = new Vector2(264f, CardVisualHeight);

        // 底板：遮住卡下地图的悬停判读；CardView 的指针交互已由 DisplayCardHost 全部接管
        Image bg = bgGO.AddComponent<Image>();
        bg.sprite = GetWhitePixel();
        bg.color = new Color(0f, 0f, 0f, 0.55f);
        bg.raycastTarget = true;

        CardViewCreator creator = CardViewCreator.Instance;
        if (creator != null)
        {
            _cardView = creator.CreateCardView(_containerRT);
            if (_cardView != null)
            {
                RectTransform crt = _cardView.GetComponent<RectTransform>();
                crt.anchorMin = crt.anchorMax = new Vector2(0.5f, 0.5f);
                crt.pivot = new Vector2(0.5f, 0.5f);
                crt.anchoredPosition = Vector2.zero;
                crt.localScale = Vector3.one * (CardVisualHeight / CardDesignHeight);
                _cardView.HoverScale = 1f;      // 展示卡：悬停不立正不放大
                _cardView.HoverLift = 0f;
                _cardView.DisplayCardHost = cv => { };   // 点击/拖拽全部吞掉
            }
        }

        // 射程脚注（卡下小字；无射程的卡留空）
        GameObject footGO = new GameObject("RangeFootnote", typeof(RectTransform));
        footGO.transform.SetParent(_containerRT, false);
        RectTransform frt = footGO.GetComponent<RectTransform>();
        frt.anchorMin = frt.anchorMax = new Vector2(0.5f, 0f);
        frt.pivot = new Vector2(0.5f, 1f);
        frt.anchoredPosition = new Vector2(0f, -6f);
        frt.sizeDelta = new Vector2(240f, 22f);
        _rangeFootnote = footGO.AddComponent<Text>();
        _rangeFootnote.font = GetSafeFont();
        _rangeFootnote.fontSize = 16;
        _rangeFootnote.alignment = TextAnchor.MiddleCenter;
        _rangeFootnote.color = new Color(0.965f, 0.894f, 0.769f, 1f);
        _rangeFootnote.raycastTarget = false;

        _containerRT.gameObject.SetActive(false);
    }

    void LateUpdate()
    {
        if (_containerRT == null) return;

        // 模态 / 卡牌交互流期间让路（与 HexMover 悬停同规则）
        if (Interactions.DevPanelOpen || Interactions.CardInteractionActive || Interactions.ModalPopupActive)
        {
            Hide();
            return;
        }

        HexMover player = _cachedPlayer != null ? _cachedPlayer : (_cachedPlayer = FindObjectOfType<HexMover>());
        if (player == null) { Hide(); return; }

        // ★2026-08-23 与徽章同源：移动中用锁定落点，静止用真实坐标
        Vector2Int playerCoord = (player.IsMoving() && player.MovingDestCoord.HasValue)
            ? player.MovingDestCoord.Value
            : player.CurrentCoord;

        EnemyController hovered = EnemyAt(player.CurrentHoverCoord);
        if (hovered != null)
        {
            RevealedIntentOption option = ResolveDisplayOption(hovered, playerCoord, player.CurrentHoverCoord);
            if (option != null)
            {
                _target = hovered;
                _shownOption = option;
                _graceUntil = Time.unscaledTime + GraceSeconds;
                ApplyContent();
            }
        }

        // 收起判据：指针既不在敌人格、也不在卡面矩形，且宽限已过
        bool pointerOver = PointerOverCard();
        if (!pointerOver && Time.unscaledTime > _graceUntil) { Hide(); return; }
        if (_target == null || _shownOption == null) { Hide(); return; }

        // 目标失效（死亡 / 玩家看不见了）→ 收
        if (_target.IsDead || !VisionSystem.CanSee(playerCoord, _target.CurrentCoord,
                VisionSystem.PlayerVisionRange, false))
        {
            Hide();
            return;
        }

        // 内容同源刷新：揭示代数 / 玩家 / 敌人 / 预览 / 棋盘签名任一变化 → 重新解析
        EnemyMovePreview preview = EnemyMovePreview.Instance;
        Vector2Int? previewCoord = preview != null ? preview.LivePreviewCoord : null;
        long signature = EnemyLandingPlanner.CurrentSignature;
        bool changed = _target.RevealGeneration != _lastGen
                    || playerCoord != _lastPlayerCoord
                    || _target.CurrentCoord != _lastEnemyCoord
                    || previewCoord != _lastPreviewCoord
                    || signature != _lastSignature;
        if (changed)
        {
            _lastGen = _target.RevealGeneration;
            _lastPlayerCoord = playerCoord;
            _lastEnemyCoord = _target.CurrentCoord;
            _lastPreviewCoord = previewCoord;
            _lastSignature = signature;

            RevealedIntentOption option = ResolveDisplayOption(_target, playerCoord, _target.CurrentCoord);
            if (option == null) { Hide(); return; }
            _shownOption = option;
            ApplyContent();
        }

        PositionCard(_target);
        if (!_containerRT.gameObject.activeSelf) _containerRT.gameObject.SetActive(true);
    }

    /// <summary>
    /// 与徽章同源的展示解析：已揭示 → 全场计划（GetEntry，与执行器同源）；
    /// 问号阶段 → 冻结链假设解析（ResolveQuestionChosen）。全失败 → null（不出卡）。
    /// </summary>
    public static RevealedIntentOption ResolveDisplayOption(EnemyController enemy, Vector2Int playerCoord, Vector2Int hoverCoord)
    {
        if (enemy == null || enemy.IsDead || enemy.data == null) return null;
        if (enemy.RevealedIntent != null && enemy.RevealedIntent.options.Count > 0)
        {
            EnemyLandingPlanner.PlanEntry entry = EnemyLandingPlanner.GetEntry(enemy, playerCoord);
            return entry != null ? entry.chosen : null;
        }
        return IntentEvaluator.ResolveQuestionChosen(enemy, hoverCoord);
    }

    static EnemyController EnemyAt(Vector2Int coord)
    {
        IReadOnlyList<EnemyController> enemies = UnitOccupancy.LivingEnemies;
        for (int i = 0; i < enemies.Count; i++)
        {
            EnemyController e = enemies[i];
            if (e != null && !e.IsDead && e.CurrentCoord == coord) return e;
        }
        return null;
    }

    bool PointerOverCard()
    {
        if (!_containerRT.gameObject.activeSelf) return false;
        return RectTransformUtility.RectangleContainsScreenPoint(_containerRT, Input.mousePosition, null);
    }

    void ApplyContent()
    {
        Card card = _shownOption.rolledCard;
        if (_cardView != null && card != null)
        {
            _cardView.SetCard(card);
            _cardView.SetEnergyVisible(false);
        }
        if (_rangeFootnote != null)
        {
            CardData data = card != null ? card.Data : null;
            int range = data != null ? data.Range : 0;
            _rangeFootnote.text = range > 0 ? "射程" + range : "";
        }
    }

    void PositionCard(EnemyController enemy)
    {
        // ★2026-09-17 贴图放大：锚点随立绘高度等比上移（与徽章同锚点，卡面仍悬在头顶）
        Vector3 head = enemy.transform.position + new Vector3(0f, enemy.HeadAnchorLocalY, 0.6f);
        Vector3 sp = Camera.main.WorldToScreenPoint(head);
        if (sp.z < 0f) { Hide(); return; }   // 在相机背后
        Vector2 lp;
        RectTransformUtility.ScreenPointToLocalPointInRectangle(_canvasRT, sp, null, out lp);

        Vector2 size = _containerRT.sizeDelta;
        Vector2 pos = lp + new Vector2(0f, 20f);
        // 夹在屏幕内
        float canvasW = _canvasRT.rect.width;
        float canvasH = _canvasRT.rect.height;
        float minX = -canvasW * 0.5f + size.x * 0.5f;
        float maxX = canvasW * 0.5f - size.x * 0.5f;
        float minY = -canvasH * 0.5f + size.y;
        float maxY = canvasH * 0.5f;
        pos.x = Mathf.Clamp(pos.x, minX, maxX);
        pos.y = Mathf.Clamp(pos.y, minY, maxY);
        _containerRT.anchoredPosition = pos;
    }

    void Hide()
    {
        _target = null;
        _shownOption = null;
        if (_containerRT != null && _containerRT.gameObject.activeSelf)
            _containerRT.gameObject.SetActive(false);
    }

    /// <summary>找 Screen Space Overlay 画布（优先挂在名册所在画布；徽章等世界空间画布要排除）。</summary>
    static Canvas FindOverlayCanvas()
    {
        Canvas[] all = FindObjectsOfType<Canvas>();
        Canvas fallback = null;
        for (int i = 0; i < all.Length; i++)
        {
            if (all[i].renderMode != RenderMode.ScreenSpaceOverlay) continue;
            fallback = all[i];
            if (all[i].GetComponentInChildren<EnemyRosterPanel>() != null) return all[i];
        }
        return fallback;
    }

    static Sprite GetWhitePixel()
    {
        if (_whitePixel != null) return _whitePixel;
        var tex = new Texture2D(1, 1, TextureFormat.RGBA32, false);
        tex.SetPixel(0, 0, Color.white);
        tex.Apply();
        _whitePixel = Sprite.Create(tex, new Rect(0, 0, 1, 1), new Vector2(0.5f, 0.5f), 1f);
        return _whitePixel;
    }

    static Font GetSafeFont()
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

// =============================================================================
// 模块：探索系统 - 事件格 EventTile
// 用途：挂在地图格子 GameObject 上（Hex_x_y），引用一个 EventData 资产；
//       玩家移动落点 == 本格坐标 → 弹事件弹窗（探索系统 v2 §7.5）。
// 设计依据：《设计增补_探索系统_v2.md》§7.5 放置与触发 / D15 通用弹窗
// 使用方式：选中格子 GameObject → Add Component → EventTile → 拖入 EventData 资产
//           （坐标自动取同对象上的 HexTile.coordinates，无需手填）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

/// <summary>
/// 事件格组件 + 全局注册表（静态）。
/// ExplorationTurnManager.OnMoveEnded → TryTriggerAt(落点坐标) 统一查询触发。
/// </summary>
public class EventTile : MonoBehaviour
{
    [Header("事件配置")]
    [Tooltip("本格触发的事件模板（EventData SO 资产）")]
    public EventData eventData;

    [Tooltip("事件格坐标。留 (0,0) 时自动取同对象 HexTile.coordinates")]
    public Vector2Int coord;

    [Header("视觉标记（Demo 简化）")]
    [Tooltip("触发过（一次性事件已消耗）后是否变暗标记")]
    public bool dimAfterConsumed = true;

    [Tooltip("问号贴地高度（世界单位）：格子数据节点 Y=0、格顶面 Y=0.25，0.27 恰好压在格面上不打架")]
    public float markerHeight = 0.27f;

    // -------- 静态注册表：所有场景内事件格 --------
    private static readonly List<EventTile> activeTiles = new List<EventTile>();

    /// <summary>一次性事件的本局消耗记录（eventId 集合，运行时静态）</summary>
    private static readonly HashSet<string> consumedEventIds = new HashSet<string>();

    /// <summary>弹窗关闭回调（ExplorationTurnManager 订阅：续跑被暂缓的结束回合）</summary>
    public static System.Action OnPopupClosed;

    private bool started = false;

    /// <summary>事件格悬浮标记（玩家可见的「这里有事件」提示，运行时自建零美术资源）</summary>
    private GameObject _marker;

    // ------------------------------------------------------------------
    // 注册表生命周期
    // ------------------------------------------------------------------

    private void Awake()
    {
        // 坐标自动取 HexTile（地图格子标准组件）
        if (coord == Vector2Int.zero)
        {
            HexTile tile = GetComponent<HexTile>();
            if (tile != null)
            {
                coord = tile.coordinates;
            }
        }
    }

    private void OnEnable()
    {
        if (!activeTiles.Contains(this)) activeTiles.Add(this);
    }

    private void OnDisable()
    {
        activeTiles.Remove(this);
    }

    private void Start()
    {
        started = true;
        CreateMarker();
    }

    /// <summary>
    /// 在事件格上方创建悬浮「?」标记，让玩家一眼看出该格可触发事件。
    /// 世界空间画布 + 描边文本（零美术资源），朝向沿用敌人血条同一套约定（相机固定 70° 俯视）；
    /// 一次性事件触发后 Destroy 隐藏。
    /// </summary>
    private void CreateMarker()
    {
        if (eventData == null || _marker != null) return;

        // 已消耗的事件不再显示标记（重开局需 ResetConsumed 才恢复）
        if (consumedEventIds.Contains(eventData.eventId)) return;

        _marker = new GameObject("EventMarker", typeof(RectTransform));
        _marker.transform.SetParent(transform, false);

        RectTransform rt = _marker.GetComponent<RectTransform>();
        rt.localPosition = new Vector3(0f, markerHeight, 0f);
        rt.localEulerAngles = new Vector3(90f, 0f, 0f); // ★2026-09-16 用户定：跟地面同一个角度平躺（字形朝 +Z＝上屏），不再正对镜头
        rt.sizeDelta = new Vector2(160f, 160f);
        rt.localScale = new Vector3(0.0056f, 0.0056f, 1f); // 160 × 0.0056 ≈ 0.9 世界单位

        Canvas canvas = _marker.AddComponent<Canvas>();
        canvas.renderMode = RenderMode.WorldSpace;
        canvas.sortingOrder = 6; // 贴地标记：压过地面装饰(4/5)，但在角色立绘(10)之下——站在格上的怪不该被问号盖住

        GameObject textGO = new GameObject("Text", typeof(RectTransform));
        textGO.transform.SetParent(_marker.transform, false);
        RectTransform textRT = textGO.GetComponent<RectTransform>();
        textRT.anchorMin = Vector2.zero;
        textRT.anchorMax = Vector2.one;
        textRT.offsetMin = Vector2.zero;
        textRT.offsetMax = Vector2.zero;

        Text text = textGO.AddComponent<Text>();
        text.font = GetSafeFont();
        text.text = "?";
        text.fontSize = 120;
        text.fontStyle = FontStyle.Bold;
        text.alignment = TextAnchor.MiddleCenter;
        text.color = new Color(0.89f, 0.71f, 0.40f, 1f); // 黄铜 #E3B567
        text.horizontalOverflow = HorizontalWrapMode.Overflow;
        text.verticalOverflow = VerticalWrapMode.Overflow;
        text.raycastTarget = false; // 关键：否则会被 EventSystem 判成"鼠标在 UI 上"，挡住格子的悬停高亮与点击移动

        Outline outline = textGO.AddComponent<Outline>();
        outline.effectColor = new Color(0.11f, 0.07f, 0.02f, 0.95f); // 深棕描边，压在任何地形色上都能认出来
        outline.effectDistance = new Vector2(3f, -3f);
    }

    /// <summary>安全获取内置字体（Unity 2022+ 用 LegacyRuntime.ttf，沿用项目惯例）。</summary>
    private static Font _cachedFont;

    private static Font GetSafeFont()
    {
        if (_cachedFont != null) return _cachedFont;
        try { _cachedFont = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf"); } catch { }
        if (_cachedFont == null)
        {
            try { _cachedFont = Resources.GetBuiltinResource<Font>("Arial.ttf"); } catch { }
        }
        return _cachedFont;
    }

    // ------------------------------------------------------------------
    // 触发（ExplorationTurnManager.OnMoveEnded 调用）
    // ------------------------------------------------------------------

    /// <summary>
    /// 落点坐标是否命中某个事件格 → 弹事件弹窗。
    /// </summary>
    /// <returns>true = 弹窗已打开（调用方暂缓其他结算）</returns>
    public static bool TryTriggerAt(Vector2Int playerCoord)
    {
        foreach (EventTile tile in activeTiles)
        {
            if (tile == null || !tile.started) continue;
            if (tile.coord != playerCoord) continue;
            if (!tile.CanTrigger()) continue;

            tile.Trigger();
            return true; // 一次只弹一个（同格多事件 Demo 不支持）
        }
        return false;
    }

    /// <summary>本格事件当前能否触发（配置齐全 + 未消耗）。
    /// 进消耗记录即不可再触发：once（触发即消耗）或某结果 endEvent（结束后消耗）。</summary>
    private bool CanTrigger()
    {
        if (eventData == null) return false;
        if (consumedEventIds.Contains(eventData.eventId)) return false;
        return true;
    }

    /// <summary>触发：标记消耗（一次性）→ 弹通用弹窗</summary>
    private void Trigger()
    {
        if (eventData.once)
        {
            consumedEventIds.Add(eventData.eventId);
            HideMarker(); // 事件已解决（触发即消耗）→ 隐藏悬浮标记
            if (dimAfterConsumed)
            {
                // 简单视觉标记：整体变暗一半（不另做美术资源）
                foreach (Renderer r in GetComponentsInChildren<Renderer>())
                {
                    r.material.color = new Color(0.5f, 0.5f, 0.5f, 1f);
                }
            }
        }

        Debug.Log($"[探索] 触发事件格 {coord}：「{eventData.title}」");
        EventPopupUI.ShowEvent(eventData);
    }

    /// <summary>
    /// ★事件解决回调（EventPopupUI 结算 endEvent 结果时调用，结果粒度）：
    /// 记录消耗（本局不再触发）+ 隐藏所有引用该事件的格子上的悬浮标记（宝箱消失）。
    /// </summary>
    public static void NotifyEventResolved(EventData data)
    {
        if (data == null) return;
        consumedEventIds.Add(data.eventId);
        foreach (EventTile tile in activeTiles)
        {
            if (tile != null && tile.eventData == data)
            {
                tile.HideMarker();
            }
        }
        Debug.Log($"[探索] 事件「{data.title}」已成功完成，标记隐藏、本局不再触发");
    }

    /// <summary>隐藏本格悬浮标记（事件已解决）</summary>
    private void HideMarker()
    {
        if (_marker != null)
        {
            Destroy(_marker);
            _marker = null;
        }
    }

    /// <summary>
    /// ★点击脚下地板重开事件窗口（用户 2026-09-05 需求，X 暂时关闭后的再入口）。
    /// 由 ExplorationTurnManager.Update 每帧调用——
    /// 不用 OnMouseUpAsButton：它依赖格子碰撞体（Map1 高亮层碰撞体被
    /// DisableMap1Colliders 禁用 + 玩家模型可能遮挡），不可靠；
    /// 这里走与 HexMover 点击移动完全同款的物理射线，移动能点到哪、重开就能在哪生效。
    /// 条件：探索态 + 弹窗已关 + 未点在 UI 上 + 命中格 == 玩家所站格 + 事件未消耗。
    /// </summary>
    public static void HandleTileClickReopen()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring) return;
        if (EventPopupUI.IsOpen) return; // 弹窗已打开不重复弹
        if (!Input.GetMouseButtonDown(0)) return;
        if (EventSystem.current != null && EventSystem.current.IsPointerOverGameObject()) return; // 点在 UI 上不触发

        Camera cam = Camera.main;
        if (cam == null) return;
        if (!Physics.Raycast(cam.ScreenPointToRay(Input.mousePosition), out RaycastHit hit)) return;
        if (hit.collider == null || !hit.collider.CompareTag("Ground") || !hit.collider.name.StartsWith("Hex_")) return;

        // 从命中格子名解析坐标（与 HexMover.HandleMouseClick 同款）
        string[] parts = hit.collider.name.Split('_');
        if (parts.Length < 3 || !int.TryParse(parts[1], out int x) || !int.TryParse(parts[2], out int y)) return;
        Vector2Int clicked = new Vector2Int(x, y);

        // 必须点的是玩家脚下这一格（点别的格子是移动指令）
        HexMover mover = Object.FindObjectOfType<HexMover>();
        if (mover == null || mover.CurrentCoord != clicked) return;

        foreach (EventTile tile in activeTiles)
        {
            if (tile == null || !tile.started) continue;
            if (tile.coord != clicked) continue;
            if (!tile.CanTrigger()) continue;

            tile.Trigger();
            return;
        }
    }

    /// <summary>
    /// 弹窗关闭通知：ExplorationTurnManager 订阅后续跑被暂缓的结束回合。
    /// 由 EventPopupUI 在关闭时调用（模态结束的唯一出口）。
    /// </summary>
    public static void NotifyPopupClosed()
    {
        OnPopupClosed?.Invoke();
    }

    /// <summary>清空一次性事件消耗记录（重开局/测试用）</summary>
    public static void ResetConsumed()
    {
        consumedEventIds.Clear();
    }
}

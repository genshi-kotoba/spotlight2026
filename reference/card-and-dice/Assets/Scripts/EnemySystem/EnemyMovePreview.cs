// =============================================================================
// 模块：M6-4 敌人系统 - EnemyMovePreview 移动预览交互
// 用途：玩家回合内，把鼠标停在某个「当前行动点内可达」的格子上 ≥ 0.5 秒，
//       就替所有敌人重算「玩家假设走到这里后，敌人会怎么做」，并以
//       EnemyIntentVisuals 的「实时预览（青）/ 锁定快照（紫）」两层视觉呈现。
//       让玩家在正式移动前，对比「我走 A vs 走 B，敌人分别怎么反应」。
// 设计依据：《设计增补_敌人系统_v2.md》§3.8（延迟悬停 + 只算可达格 + 仅战斗模式 + Shift 锁定对比）
// 职责边界：
//   - 本类只「算状态」（悬停计时 / 可达判定 / 锁定开关），不自己画任何视觉；
//   - 视觉交给 EnemyIntentVisuals 读取 LivePreviewCoord / LockedCoord 来画。
// 挂载：MainScene 的 GameManager（与 CardExecutor/TurnManager 共存）。
// =============================================================================
using UnityEngine;

/// <summary>
/// 移动预览交互协调器（单例）。
/// 三个公开坐标状态供 EnemyIntentVisuals 每帧读取：
///   - LivePreviewCoord：当前正在展示的「实时预览」假设玩家坐标（null=无）
///   - LockedCoord：被 Shift 锁定的快照假设玩家坐标（null=未锁定）
/// </summary>
public class EnemyMovePreview : MonoBehaviour
{
    // ======== 单例 ========
    public static EnemyMovePreview Instance { get; private set; }

    // ======== 调优旋钮（§3.8 悬停延迟） ========
    [Header("调优旋钮")]
    [Tooltip("鼠标在某格停留多久才触发虚影预览（秒），防虚影乱飘。对应旋钮 hoverDelayMs = 0.5s")]
    [SerializeField] private float hoverDelayMs = 0.5f;

    // ======== 运行时状态 ========
    private Vector2Int _hoverCoord = new Vector2Int(-999, -999); // 当前悬停格（-999,-999=无）
    private float _hoverStartTime = -1f;                          // 进入当前格的时刻（-1=未在计时）

    private bool _liveActive = false;    // 是否正展示「实时预览」
    private Vector2Int? _liveCoord;      // 实时预览对应的假设玩家坐标
    private Vector2Int? _lockedCoord;    // 被 Shift 锁定的快照坐标

    private bool _shiftWasDown = false;  // 上一帧 Shift 是否按下（沿检测用）

    private HexMover _hexMover;

    // ======== 对外公开状态（供 EnemyIntentVisuals 读取） ========
    /// <summary>当前实时预览的假设玩家坐标（null = 无实时预览）。</summary>
    public Vector2Int? LivePreviewCoord => _liveActive ? _liveCoord : null;

    /// <summary>被锁定快照的假设玩家坐标（null = 未锁定）。</summary>
    public Vector2Int? LockedCoord => _lockedCoord;

    /// <summary>是否处于锁定态。</summary>
    public bool IsLocked => _lockedCoord.HasValue;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    private void Start()
    {
        _hexMover = FindObjectOfType<HexMover>();
    }

    private void Update()
    {
        if (_hexMover == null) _hexMover = FindObjectOfType<HexMover>();
        if (_hexMover == null) return;

        // 仅战斗模式；非战斗 / 卡牌交互中 / 玩家正在移动 → 清空一切预览与锁定（§3.8）
        bool battle = GameStateManager.Instance != null
                   && GameStateManager.Instance.CurrentState == GameState.Battle;
        // ★2026-09-14 开发者面板打开：Shift 锁定 / 右键取消 与预览全部让路
        if (!battle || Interactions.DevPanelOpen || Interactions.CardInteractionActive || _hexMover.IsMoving())
        {
            ClearAll();
            return;
        }

        HandleShiftLock();
        HandleHoverPreview();
    }

    // ------------------------------------------------------------------
    // Shift 锁定 / 右键取消（§3.8「锁定对比」）
    // ------------------------------------------------------------------
    private void HandleShiftLock()
    {
        bool shiftDown = Input.GetKey(KeyCode.LeftShift) || Input.GetKey(KeyCode.RightShift);
        bool shiftPressed = shiftDown && !_shiftWasDown;
        _shiftWasDown = shiftDown;

        if (shiftPressed)
        {
            if (IsLocked)
            {
                _lockedCoord = null;              // 已锁定 → 再按 Shift 取消锁定
                Debug.Log("[EnemyMovePreview] 取消锁定");
            }
            else if (_liveActive)
            {
                _lockedCoord = _liveCoord;        // 未锁定且有实时预览 → 锁定当前快照
                Debug.Log($"[EnemyMovePreview] 锁定快照：玩家假设移动到 {_lockedCoord}");
            }
        }

        // 右键取消锁定（仅锁定态；此时无卡牌动作在瞄准，语义从「取消卡牌」改为「取消锁定」§3.8）
        if (Input.GetMouseButtonDown(1) && IsLocked)
        {
            _lockedCoord = null;
            Debug.Log("[EnemyMovePreview] 右键取消锁定");
        }
    }

    // ------------------------------------------------------------------
    // 延迟悬停 + 可达格判定（§3.8「延迟悬停」「只算可达格」）
    // ------------------------------------------------------------------
    private void HandleHoverPreview()
    {
        Vector2Int hover = _hexMover.CurrentHoverCoord;

        // 无悬停（HexMover 返回 -999,-999）→ 清计时 + 清实时预览（锁定快照保留）
        if (hover.x < 0 || hover.y < 0)
        {
            ResetHover();
            SetLiveActive(false, null);
            return;
        }

        // 悬停格发生变化 → 重开 0.5s 计时，并先清掉上一个格的实时预览
        if (hover != _hoverCoord)
        {
            _hoverCoord = hover;
            _hoverStartTime = Time.time;
            SetLiveActive(false, null);
            return;
        }

        // 同一格持续悬停：到延迟阈值后，仅当该格「行动点内可达」才触发预览
        if (_hoverStartTime >= 0f && (Time.time - _hoverStartTime) >= hoverDelayMs)
        {
            if (!_liveActive && _hexMover.IsReachable(hover))
            {
                SetLiveActive(true, hover);
            }
        }
    }

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------
    private void SetLiveActive(bool active, Vector2Int? coord)
    {
        _liveActive = active;
        _liveCoord = coord;
    }

    private void ResetHover()
    {
        _hoverCoord = new Vector2Int(-999, -999);
        _hoverStartTime = -1f;
    }

    private void ClearAll()
    {
        ResetHover();
        SetLiveActive(false, null);
        _lockedCoord = null;
        _shiftWasDown = false;
    }

    private void OnDestroy()
    {
        if (Instance == this) Instance = null;
    }
}
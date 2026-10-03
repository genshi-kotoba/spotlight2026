// =============================================================================
// 模块：M1 游戏状态机 GameStateManager
// 用途：在 MainScene 中管理「探索 / 战斗 / 暂停」三种全局模式的切换
// 设计依据：《开发计划_核心循环闭合与编辑器.md》M1 任务清单
// 职责边界：仅负责状态切换与事件广播，不直接控制 UI（UI 由各自系统订阅响应）
// 与 TurnManager 的区别：TurnManager 管理回合（玩家回合/敌人回合），
//                        GameStateManager 管理游戏整体模式（探索/战斗/暂停）
// =============================================================================
using System;
using UnityEngine;

/// <summary>
/// 游戏全局模式枚举。对应 M1 任务清单第 2 项。
/// </summary>
public enum GameState
{
    /// <summary>探索模式：玩家在大地图上移动、遭遇敌人、捡取物资</summary>
    Exploring,
    /// <summary>战斗模式：进入回合制战斗场景（同一场景内切换分支）</summary>
    Battle,
    /// <summary>暂停模式：编辑器打开或系统菜单弹出时使用</summary>
    Paused
}

/// <summary>
/// M1：游戏状态机单例。挂载于 MainScene 的 GameManager 空对象。
/// 其他系统通过订阅 <see cref="OnStateChanged"/> 事件响应模式切换。
/// </summary>
public class GameStateManager : MonoBehaviour
{
    // -------- 单例 --------
    public static GameStateManager Instance { get; private set; }

    // -------- 状态 --------
    /// <summary>当前游戏模式。由 Awake 按 startupState 初始化（探索系统第一步起默认 Exploring）。</summary>
    public GameState CurrentState { get; private set; }

    // -------- Demo 启动设置 --------
    [Header("Demo 启动设置")]
    [Tooltip("启动时进入的游戏模式。默认 Exploring（探索系统第一步，2026-08-25）；调试战斗时可改为 Battle")]
    [SerializeField]
    private GameState startupState = GameState.Exploring;

    // -------- 事件 --------
    /// <summary>
    /// 状态切换事件。参数顺序：旧状态 → 新状态（对应任务清单第 4 项）。
    /// 订阅示例：GameStateManager.Instance.OnStateChanged += (old, cur) => { ... };
    /// </summary>
    public event Action<GameState, GameState> OnStateChanged;

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Awake()
    {
        // 单例设置：与 TurnManager 共存于同一 GameManager 对象，各自独立单例
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;

        // ★探索系统第一步（2026-08-25）：启动模式改为 Inspector 可配置，默认 Exploring。
        // 新增序列化字段无旧序列化数据，代码默认值对已有场景对象生效（陷阱清单：改默认值才不生效）。
        CurrentState = startupState;

        // 不 DontDestroyOnLoad：Demo 阶段单场景即可，避免引入跨场景生命周期复杂度
    }

    private void Start()
    {
        // 启动时广播一次初始状态，方便订阅系统在 Start 后能收到初始化信号
        // （注意：此时旧状态设为 Exploring，新状态也是 Exploring，表示「进入探索模式」）
        Debug.Log($"[GameStateManager] 初始化完成，当前模式：{CurrentState}");
    }

    // ------------------------------------------------------------------
    // 切换方法（任务清单第 6 项）
    // ------------------------------------------------------------------

    /// <summary>切换到战斗模式。常用于：遭遇敌人、偷袭成功。</summary>
    public void SwitchToBattle()
    {
        SwitchTo(GameState.Battle);
    }

    /// <summary>切换到探索模式。常用于：战斗结束、回到大地图。</summary>
    public void SwitchToExploring()
    {
        SwitchTo(GameState.Exploring);
    }

    /// <summary>切换到暂停模式。常用于：编辑器打开、系统菜单弹出。</summary>
    public void Pause()
    {
        SwitchTo(GameState.Paused);
    }

    // ------------------------------------------------------------------
    // 内部切换逻辑（任务清单第 7 项：切换时发布事件）
    // ------------------------------------------------------------------

    /// <summary>
    /// 统一的切换实现：先做状态校验，避免重复切换；再更新状态并广播事件。
    /// </summary>
    /// <param name="newState">目标状态</param>
    private void SwitchTo(GameState newState)
    {
        if (newState == CurrentState)
        {
            // 重复切换视为无效，跳过（避免误触发事件）
            Debug.Log($"[GameStateManager] 状态未变化（{newState}），跳过切换");
            return;
        }

        GameState oldState = CurrentState;
        CurrentState = newState;

        // ★2026-09-16 性能二批补：战斗态也要有帧采样器。
        //   探索侧只在巡逻阶段（PatrolPhase）引导它，而「结束回合 → 被动遇袭」这条路径
        //   根本走不到巡逻阶段 → 整场战斗没有任何帧打点（用户实测「怪物一多很卡」时
        //   日志里一行 [性能] 都没有，就是这里漏的）。
        if (newState == GameState.Battle) EnemyRenderLod.EnsureExists();

        Debug.Log($"[GameStateManager] 状态切换：{oldState} → {newState}");

        // 广播事件：所有订阅系统（UI/玩家/敌人/回合管理器等）自行响应
        OnStateChanged?.Invoke(oldState, newState);
    }
}

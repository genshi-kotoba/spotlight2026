// =============================================================================
// 模块：P4.5 动作系统 - ActionSystem 动作调度器（单例）
// 用途：统一调度所有游戏动作及其连锁反应，保证执行顺序清晰：
//       Pre 反应 → 执行者 → Performer 反应 → Post 反应 → 递归执行反应链
// 参考教程：NSWells P4.5 Action & Reaction System
// 设计文档：docs/superpowers/refs/action-reaction-system.md §2.2
// 核心机制（与视频一致）：
//   1. 三个静态注册表：Pre 订阅者 / Post 订阅者 / 执行者（Performer）
//   2. "当前反应列表引用"：流程每进入一个阶段，就把 _currentReactions 指向
//      该阶段对应的列表，订阅者/执行者调用 AddReaction 时自动加到正确阶段
//   3. 反应本身也是 GameAction，递归走完整流程 → 天然支持连锁触发
// 使用约定（视频原话）：
//   - 反应方法里【只创建新动作 + AddReaction】，不直接执行逻辑
//   - 在执行者内部要执行新动作，必须用 AddReaction 而非 Perform
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 动作与反应系统调度器（单例）。
/// 完成后基本不再修改，各游戏系统只通过 AttachPerformer / SubscribeReaction 接入。
/// </summary>
public class ActionSystem : MonoBehaviour
{
    // ======== 单例 ========
    public static ActionSystem Instance { get; private set; }

    /// <summary>
    /// 是否正在执行动作链。
    /// true 时拒绝新的顶层 Perform 请求（防止动画/结算期间玩家再次出牌）。
    /// </summary>
    public bool IsPerforming { get; private set; }

    /// <summary>
    /// 当前阶段的反应列表引用（阶段感知）。
    /// 流程进入 Pre 阶段时指向 action.PreReactions，
    /// 进入 Performer 阶段时指向 action.PerformerReactions，
    /// 进入 Post 阶段时指向 action.PostReactions。
    /// AddReaction 总是往这个引用里加 → 反应自动进入正确阶段。
    /// </summary>
    private List<GameAction> _currentReactions;

    // ======== 静态注册表 ========

    /// <summary>执行者注册表：动作类型 → 执行协程（每种动作类型只有一个执行者）</summary>
    private static readonly Dictionary<Type, Func<GameAction, IEnumerator>> Performers = new();

    /// <summary>Pre 反应订阅表：动作类型 → 订阅回调列表（同类型可有多个订阅者）</summary>
    private static readonly Dictionary<Type, List<Action<GameAction>>> PreSubscribers = new();

    /// <summary>Post 反应订阅表：动作类型 → 订阅回调列表</summary>
    private static readonly Dictionary<Type, List<Action<GameAction>>> PostSubscribers = new();

    /// <summary>
    /// 逆映射：原始泛型委托 → 包装后的委托。
    /// 用于 UnsubscribeReaction 时按原始委托移除包装委托（保证取消订阅可靠）。
    /// </summary>
    private static readonly Dictionary<Delegate, Action<GameAction>> ReactionWrapperMap = new();

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

    // ------------------------------------------------------------------
    // 注册/注销 执行者（Performer）
    // ------------------------------------------------------------------

    /// <summary>
    /// 注册某种动作类型的执行者。执行者负责真正执行动作逻辑（扣血/抽牌/扣能量）。
    /// 每种动作类型只能有一个执行者（后注册覆盖先注册）。
    /// </summary>
    /// <typeparam name="T">动作类型</typeparam>
    /// <param name="performer">执行协程，参数是该动作实例（协程内可等待动画）</param>
    public static void AttachPerformer<T>(Func<T, IEnumerator> performer) where T : GameAction
    {
        Performers[typeof(T)] = action => performer((T)action);
    }

    /// <summary>注销某种动作类型的执行者。</summary>
    public static void DetachPerformer<T>() where T : GameAction
    {
        Performers.Remove(typeof(T));
    }

    // ------------------------------------------------------------------
    // 订阅/取消订阅 反应（Reaction）
    // ------------------------------------------------------------------

    /// <summary>
    /// 订阅某种动作类型的反应。
    /// 反应回调里只应：读取动作数据 + 创建新动作 + AddReaction（不要直接执行逻辑）。
    /// </summary>
    /// <typeparam name="T">动作类型</typeparam>
    /// <param name="reaction">反应回调</param>
    /// <param name="timing">触发时机：Pre（前，可修改数据）/ Post（后，可连锁）</param>
    public static void SubscribeReaction<T>(Action<T> reaction, ReactionTiming timing) where T : GameAction
    {
        var subs = timing == ReactionTiming.Pre ? PreSubscribers : PostSubscribers;
        Type type = typeof(T);

        // 包装成 Action<GameAction> 存入注册表，同时记录逆映射便于取消订阅
        Action<GameAction> wrapped = action => reaction((T)action);
        ReactionWrapperMap[reaction] = wrapped;

        if (!subs.TryGetValue(type, out var list))
        {
            list = new List<Action<GameAction>>();
            subs[type] = list;
        }
        list.Add(wrapped);
    }

    /// <summary>取消订阅某种动作类型的反应（必须传入与订阅时相同的委托）。</summary>
    public static void UnsubscribeReaction<T>(Action<T> reaction, ReactionTiming timing) where T : GameAction
    {
        var subs = timing == ReactionTiming.Pre ? PreSubscribers : PostSubscribers;
        if (!subs.TryGetValue(typeof(T), out var list)) return;

        if (ReactionWrapperMap.Remove(reaction, out var wrapped))
        {
            list.Remove(wrapped);
        }
    }

    // ------------------------------------------------------------------
    // 添加反应（订阅者 / 执行者内部调用）
    // ------------------------------------------------------------------

    /// <summary>
    /// 把一个新动作作为反应添加到【当前阶段】的列表。
    /// 在 Reaction 回调或 Performer 协程内调用。
    /// 系统会在当前阶段收集完毕后统一按顺序执行这些反应（每个反应走完整流程）。
    /// </summary>
    public void AddReaction(GameAction action)
    {
        if (_currentReactions == null)
        {
            Debug.LogWarning("[ActionSystem] 当前不在任何执行阶段，无法添加反应（应在 Reaction/Performer 中调用）");
            return;
        }
        _currentReactions.Add(action);
    }

    // ------------------------------------------------------------------
    // 执行入口
    // ------------------------------------------------------------------

    /// <summary>
    /// 执行一个顶层游戏动作（玩家出牌 / 回合切换等入口调用）。
    /// 内部自动完成 Pre → Performer → Post 全阶段及所有连锁反应。
    /// 动作链执行期间 IsPerforming = true，拒绝新的顶层请求。
    /// </summary>
    /// <param name="action">要执行的动作</param>
    /// <param name="onFinished">整条动作链（含所有连锁）完成后的回调</param>
    public void Perform(GameAction action, Action onFinished = null)
    {
        if (action == null) return;

        if (IsPerforming)
        {
            Debug.LogWarning("[ActionSystem] 动作链执行中，拒绝新的顶层请求");
            return;
        }

        IsPerforming = true;
        StartCoroutine(Process(action, () =>
        {
            IsPerforming = false;
            onFinished?.Invoke();
        }));
    }

    // ------------------------------------------------------------------
    // 递归流程：Pre → Performer → Post（系统核心，完成后不再修改）
    // ------------------------------------------------------------------

    /// <summary>
    /// 处理单个动作的完整流程。
    /// 每个阶段先把 _currentReactions 指向对应列表 → 通知订阅者（收集反应）→ 逐个执行反应（递归）。
    /// </summary>
    private IEnumerator Process(GameAction action, Action callback = null)
    {
        // ===== 阶段 1：Pre（动作执行前，订阅者可修改/取消动作数据）=====
        _currentReactions = action.PreReactions;
        NotifySubscribers(action, PreSubscribers);
        yield return RunReactions(action.PreReactions);

        // ===== 阶段 2：Performer（执行动作本体逻辑）=====
        _currentReactions = action.PerformerReactions;
        if (Performers.TryGetValue(action.GetType(), out var performer))
        {
            yield return performer(action);
        }
        else
        {
            // 未注册执行者：动作数据无副作用，仅警告（反应仍会执行，便于调试链路）
            Debug.LogWarning($"[ActionSystem] {action.GetType().Name} 未注册执行者，跳过主逻辑");
        }
        // 执行者内部 AddReaction 的副反应（如打出卡牌 → 各效果生成的动作）
        yield return RunReactions(action.PerformerReactions);

        // ===== 阶段 3：Post（动作执行后，订阅者可连锁新动作）=====
        _currentReactions = action.PostReactions;
        NotifySubscribers(action, PostSubscribers);
        yield return RunReactions(action.PostReactions);

        _currentReactions = null;
        callback?.Invoke();
    }

    /// <summary>
    /// 通知某种动作类型的所有订阅者（Pre 或 Post）。
    /// 订阅者在回调里调用 AddReaction 把反应加入当前阶段列表。
    /// </summary>
    private void NotifySubscribers(GameAction action, Dictionary<Type, List<Action<GameAction>>> subscribers)
    {
        if (!subscribers.TryGetValue(action.GetType(), out var list)) return;

        // 快照遍历：通知期间订阅者只应 AddReaction，不应增删订阅
        var snapshot = new List<Action<GameAction>>(list);
        foreach (var subscriber in snapshot)
        {
            subscriber?.Invoke(action);
        }
    }

    /// <summary>
    /// 按顺序执行反应列表（每个反应递归走完整 Process，直到无更多连锁）。
    /// 注：动作对象视为一次性使用，执行后列表保留记录便于调试查看链路。
    /// </summary>
    private IEnumerator RunReactions(List<GameAction> reactions)
    {
        if (reactions == null || reactions.Count == 0) yield break;

        // 用索引遍历而非 foreach：递归执行中列表可能继续增长（链式反应）
        for (int i = 0; i < reactions.Count; i++)
        {
            yield return StartCoroutine(Process(reactions[i]));
        }
    }
}

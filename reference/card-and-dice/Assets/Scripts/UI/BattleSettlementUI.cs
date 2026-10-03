// =============================================================================
// 模块：M7 背包系统 - BattleSettlementUI（已于 2026-09-12 退役为适配器）
// 用途：原「战后结算整屏弹窗」（Task 18/19/20）被右下角堆叠列表取代——
//       战后反馈统一走 LootClaimPopupUI（魂灯已满→卡牌→魂灯未满→材料 从下往上堆）；
//       三选一 → CardRewardPickUI（由「战利品卡牌物品」驱动）；
//       灯满子页 → LootClaimPopupUI 内的魂灯处理子窗。
// 本类只剩一件事：它已挂在 UICanvas 上（场景序列化），保留壳避免 Missing Script，
// 并把「Battle→Exploring 状态跳变」（含脱战路径，旧代码同样弹）转发给新 UI。
// 设计依据：docs/2026-09-12_战后结算改右侧汇报条-design.md
// =============================================================================
using UnityEngine;

public class BattleSettlementUI : MonoBehaviour
{
    static BattleSettlementUI _instance;

    /// <summary>兼容旧引用：始终 false（整屏结算窗不存在了）。</summary>
    public static bool IsOpen => false;

    /// <summary>旧引用兼容（BattleResultHandler 已改调新 UI，此属性保留防编译断）。</summary>
    public static BattleSettlementUI Instance => _instance;

    /// <summary>
    /// 胜利路径去重：BattleResultHandler.ResolveVictory 在切状态**之前**置 true，
    /// 本适配器看到它就不再转发（延时 0.25s 的弹窗已由 DelayedVictoryReport 排定）；
    /// 消费后立即复位。脱战路径不设它，照常走适配器。
    /// </summary>
    public static bool VictoryReportScheduled { get; set; }

    bool _hooked;

    void Awake()
    {
        if (_instance != null && _instance != this)
        {
            Destroy(this);              // 宿主是 UICanvas，不能 Destroy(gameObject)
            return;
        }
        _instance = this;
    }

    void Start()
    {
        Hook();
    }

    void OnDestroy()
    {
        if (_instance == this) _instance = null;
        Unhook();
    }

    // ------------------------------------------------------------------
    // 状态跳变转发：Battle→Exploring（胜利 + 脱战两条路）
    // ------------------------------------------------------------------
    void Hook()
    {
        if (_hooked) return;
        if (GameStateManager.Instance == null) return;
        GameStateManager.Instance.OnStateChanged += OnGameStateChanged;
        _hooked = true;
    }

    void Unhook()
    {
        if (!_hooked) return;
        if (GameStateManager.Instance != null) GameStateManager.Instance.OnStateChanged -= OnGameStateChanged;
        _hooked = false;
    }

    void OnGameStateChanged(GameState oldState, GameState newState)
    {
        if (oldState != GameState.Battle || newState != GameState.Exploring) return;

        // 胜利路径已排定延时弹窗（ResolveVictory 置位）→ 这里是重复触发，跳过
        if (VictoryReportScheduled)
        {
            VictoryReportScheduled = false;
            return;
        }

        // 击杀 0 不弹（沿用 spec §9:92 判据）。这里只兜**脱战**（不经 ResolveVictory）。
        if (!BattleRewardLedger.HasPending) return;

        Debug.Log("[结算适配器] 脱战回探索：转发掉落反馈到右下角堆叠列表");
        LootClaimPopupUI.ShowAfterVictory();
    }
}

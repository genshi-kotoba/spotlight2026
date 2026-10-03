// =============================================================================
// 模块：Game - ExpeditionLifecycle 当局生命周期统一清理
// 用途：当局结束（玩家死亡重载）前清空全部跨场景静态状态。
// 背景：ResolveDefeat 直接 SceneManager.LoadScene 重载 MainScene——静态字段不被
//       LoadScene 重置，残留会把下一局污染（账本、付款、装填、交互锁、事件消耗、占位）。
// 调用方：BattleResultHandler.ResolveDefeat（必须在 LoadScene 之前——清理器依赖
//         存活订阅者：CorpseRegistry 广播 OnChanged 要 CorpseSpawner 还活着才能同步地图标记）。
// 设计依据：docs/superpowers/specs/2026-09-08-背包系统-design.md §15 验收条款 9
// =============================================================================
using UnityEngine;

public static class ExpeditionLifecycle
{
    /// <summary>
    /// 当局结束统一清理。顺序敏感：
    /// 1. 遗物袋注册表最先清（广播 OnChanged → CorpseSpawner.SyncMarkers 销毁地图标记，依赖存活订阅者）；
    /// 2. 卡牌装填 / 战术卡槽 / 击杀账本 / 骰子付款账本（纯静态，无依赖）；
    /// 3. 交互锁、事件消耗、单位占位（纯静态，无依赖）；
    /// 4. 背包最后清（ClearForNewExpedition 重放魂灯容器，会吸收前面清理器的归还副作用）。
    /// </summary>
    public static void EndExpedition(string reason)
    {
        CorpseRegistry.ClearAll();
        CardLoadout.ClearAll();
        TacticSlotRuntime.ClearAll();
        BattleRewardLedger.ClearAll();
        SoulIntake.ClearAll();     // ★2026-09-12 挂起灵魂：离开本局自动销毁（用户定稿）
        DicePayment.RefundAll();   // 作用 = 清付款账本；归还动作随后被背包清空抹掉

        Interactions.PlayerIsDragging = false;
        Interactions.CardInteractionActive = false;
        Interactions.ModalPopupActive = false;
        EventTile.ResetConsumed();
        UnitOccupancy.SimulatedPlayerCoord = null;
        UnitOccupancy.PatrolLandingClaims.End();
        WastelandRunContext.Clear();   // ★2026-09-16 荒野上下文（群系图/巡逻锚点）随本局销毁
        TempBuffRuntime.ClearAll();    // ★2026-09-16 临时强化：撤离/阵亡都随本局销毁
        RunModifiers.Reset();          // ★2026-09-17 整装被动属性加值（移动/视野）：随本局销毁

        InventoryManager inv = Object.FindObjectOfType<InventoryManager>();
        if (inv != null) inv.ClearForNewExpedition();

        Debug.Log($"[当局] 结束（{reason}）：遗物袋/装填/卡槽/击杀账本/骰子付款/交互锁/事件消耗/占位/背包已全部清空");
    }
}

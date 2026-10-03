// =============================================================================
// 模块：Meta - RunModifiers 当局开局属性加值
// 用途：整装被动（AttributeModifier 型）的当局加值层。开局发放（LoadoutDistribution）
//       写入，ExpeditionLifecycle.EndExpedition 归零——不落盘、不跨局。
// 读取点：TurnManager / ExplorationTurnManager 的移动预算、VisionSystem 玩家视野。
// 设计依据：docs/superpowers/plans/2026-09-17-藏身处B4-整装出击.md T7
// =============================================================================

public static class RunModifiers
{
    /// <summary>移动力加值（战斗/探索回合 AP 授予时叠加）。</summary>
    public static int MoveRangeBonus;

    /// <summary>视野加值（玩家侧视野 = 基础 10 + 本值）。</summary>
    public static int VisionRangeBonus;

    public static void Reset()
    {
        MoveRangeBonus = 0;
        VisionRangeBonus = 0;
    }
}

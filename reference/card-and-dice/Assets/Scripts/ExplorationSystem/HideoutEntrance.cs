// =============================================================================
// 模块：ExplorationSystem - 藏身处入口
// 用途：地形字符 'O'（MapLayoutBuilder 解析为 homebaseEntranceCoord，绿色地面标记）。
//       玩家走到此格 → 结束当局远征（清静态）→ 加载 HideoutScene。
//       教程图上的门禁：教学未完成（S43「前往藏身处」走到才 completesTutorial）不放行，
//       防止玩家开局直奔入口跳过教程；非教程图直接放行（O = 常规撤离点）。
// 挂载：无组件——ExplorationTurnManager.Update 每帧调 HandleArrival(playerMover)。
// 设计依据：docs/2026-09-12_教程图v4_线性窄巷-design.md（段⑤ 小走廊 → O 藏身处入口）
// =============================================================================
using UnityEngine;
using UnityEngine.SceneManagement;

public static class HideoutEntrance
{
    private static bool _entering;          // 同一局防重入（LoadScene 延迟到帧末，期间 Update 还会跑）
    private static MapLayoutBuilder _builder;

    static HideoutEntrance()
    {
        // 静态字段跨 LoadScene 不清（同 ExpeditionLifecycle 注释）——新场景加载完复位防重入锁
        SceneManager.sceneLoaded += (_, __) => _entering = false;
    }

    /// <summary>每帧检查：玩家站在藏身处入口格 → 进藏身处。</summary>
    public static void HandleArrival(HexMover playerMover)
    {
        if (_entering || playerMover == null) return;

        if (_builder == null) _builder = Object.FindObjectOfType<MapLayoutBuilder>();
        if (_builder == null || !_builder.hasHomebaseEntrance) return;

        // 教程图：S43 走到入口才 MarkComplete（tutorialStage→1），此前不放行
        if (MapLayoutBuilder.IsTutorial && !TutorialProgress.IsComplete) return;

        if (playerMover.CurrentCoord != _builder.homebaseEntranceCoord) return;

        _entering = true;
        Debug.Log("[HideoutEntrance] 玩家走到藏身处入口 → 结束当局远征，进入藏身处");
        // 必须先 EndExpedition 再 LoadScene（静态清理器依赖存活的订阅者，见 BattleResultHandler 先例）
        ExpeditionLifecycle.EndExpedition("走进藏身处入口");
        SceneManager.LoadScene(MetaWallet.HIDEOUT_SCENE);
    }
}

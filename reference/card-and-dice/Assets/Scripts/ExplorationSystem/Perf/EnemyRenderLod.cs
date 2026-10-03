// =============================================================================
// 模块：敌人渲染裁剪（★2026-09-16 荒野大地图性能批）
// 用途：荒野图 120×75 + 几十只敌人时，把「离玩家很远」的敌人的模型 / 血条 / 意图徽章
//       关掉（只关渲染与徽章组件，**逻辑照跑**：巡逻、警戒、遭遇全不受影响）。
// 口径：距离取自 ExplorationPerf.RenderLodRadius（必须小于 PatrolLodRadius —— 看得见的
//       小队永远走完整解算，玩家不会看到瞬移造成的「预览≠执行」）。
// 顺带：本组件每帧喂一次卡顿采样（ExplorationPerf.SampleFrame），提供实机性能证据。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public class EnemyRenderLod : MonoBehaviour
{
    const int PassEveryNFrames = 3;      // 每 3 帧重算一次（距离检测本身很便宜）
    const float RebuildInterval = 2f;    // 徽章是懒创建的 → 定期重建缓存（否则新徽章管不到）

    static EnemyRenderLod s_instance;

    class Entry
    {
        public EnemyController enemy;
        public Renderer[] renderers;
        public Canvas[] canvases;
        public EnemyIntentBadgeUI badge;
        public EnemyIntentVisuals visuals;
        public bool hidden;
        public bool applied;
    }

    readonly List<Entry> _entries = new List<Entry>();
    int _lastRegistryCount = -1;
    float _nextRebuild;

    /// <summary>幂等引导：探索回合开始处调用（场景切换后旧实例随场景销毁 → 这里会重建）。</summary>
    public static void EnsureExists()
    {
        if (s_instance != null) return;
        GameObject go = new GameObject("EnemyRenderLod");
        s_instance = go.AddComponent<EnemyRenderLod>();
    }

    void LateUpdate()
    {
        ExplorationPerf.SampleFrame(Time.unscaledDeltaTime, DescribeContext());

        if (Time.frameCount % PassEveryNFrames != 0) return;
        Apply();
    }

    /// <summary>
    /// 裁剪判定（纯函数，编辑态 L2 断言用）：玩家存在 & 敌人存活 & 非「战斗态参战者」
    /// & （玩家看不见 或 距玩家超过渲染半径）→ 裁剪。
    /// ★2026-09-16 视野系统：visible=false（玩家视野外，尸体除外）直接裁——玩家不能隔墙有眼；
    ///   尸体（isDead）永远可见，是搜刮锚点。探索态口径（inBattle=false 时第三项恒真）。
    /// </summary>
    public static bool ShouldHideEnemy(bool inBattle, bool isParticipant, bool isDead, bool hasPlayer, bool visible, bool far)
    {
        return hasPlayer && !isDead && !(inBattle && isParticipant) && (!visible || far);
    }

    void Apply()
    {
        IReadOnlyList<EnemyController> enemies = UnitOccupancy.LivingEnemies;
        if (enemies.Count != _lastRegistryCount || Time.unscaledTime >= _nextRebuild)
        {
            Rebuild(enemies);
        }

        // ★2026-09-16 修订：战斗态不再一刀不裁。参战者永不裁（结算/点名/血条要用）；
        // 非参战者照常按距离裁——旧口径让全图 76 只徽章在战斗中全开，
        // 徽章 LateUpdate 的 A* 重算随棋盘签名逐帧触发，是战斗卡顿主源。
        bool inBattle = GameStateManager.Instance != null
                        && GameStateManager.Instance.CurrentState == GameState.Battle;
        bool hasPlayer = ExplorationPerf.Player != null;

        for (int i = 0; i < _entries.Count; i++)
        {
            Entry e = _entries[i];
            if (e.enemy == null) continue;

            bool isParticipant = inBattle && BattleResultHandler.Instance != null
                                 && BattleResultHandler.Instance.IsParticipant(e.enemy);
            bool far = ExplorationPerf.IsFarFromPlayer(e.enemy.CurrentCoord, ExplorationPerf.RenderLodRadius);
            // ★2026-09-16 玩家视野：看不见的敌人直接裁（红格挡视线、绿格扣射程见 VisionSystem；
            //   玩家视野只吃红格、不扣绿格）。无玩家（极端兜底）时按可见处理。
            bool visible = !hasPlayer || VisionSystem.CanSee(
                ExplorationPerf.Player.CurrentCoord, e.enemy.CurrentCoord,
                VisionSystem.PlayerVisionRange, false);
            bool hide = ShouldHideEnemy(inBattle, isParticipant, e.enemy.IsDead, hasPlayer, visible, far);

            if (e.applied && hide == e.hidden) continue;
            e.applied = true;
            e.hidden = hide;

            for (int r = 0; r < e.renderers.Length; r++)
            {
                if (e.renderers[r] != null) e.renderers[r].enabled = !hide;
            }
            for (int c = 0; c < e.canvases.Length; c++)
            {
                if (e.canvases[c] != null) e.canvases[c].enabled = !hide;
            }
            // 徽章组件整个关掉：它的 LateUpdate 里含 A* 级重算（ThreatPredictor / 问号转换预览），
            // 远场徽章既看不见又算得贵，是最划算的一刀。
            if (e.badge != null) e.badge.enabled = !hide;
            // 意图视觉组件（移动虚线/弧线/虚影）只在战斗态干活：远场非参战者连它一起关，
            // 免掉每帧 LateUpdate 的签名检查与预览刷新（OnDisable 会顺手清残留视觉）。
            if (e.visuals != null) e.visuals.enabled = !hide;
        }
    }

    void Rebuild(IReadOnlyList<EnemyController> enemies)
    {
        _lastRegistryCount = enemies.Count;
        _nextRebuild = Time.unscaledTime + RebuildInterval;

        _entries.Clear();
        for (int i = 0; i < enemies.Count; i++)
        {
            EnemyController e = enemies[i];
            if (e == null) continue;

            _entries.Add(new Entry
            {
                enemy = e,
                renderers = e.GetComponentsInChildren<Renderer>(true),
                canvases = e.GetComponentsInChildren<Canvas>(true),
                badge = e.GetComponentInChildren<EnemyIntentBadgeUI>(true),
                visuals = e.GetComponentInChildren<EnemyIntentVisuals>(true),
                applied = false,     // 重建后第一遍必须无条件应用（否则远场敌人会闪一下可见）
                hidden = false
            });
        }
    }

    static string DescribeContext()
    {
        GameStateManager gs = GameStateManager.Instance;
        if (gs == null) return "未知";

        if (gs.CurrentState == GameState.Battle) return "战斗";

        HexMover p = ExplorationPerf.Player;
        if (p != null && p.IsMoving()) return "探索/移动中";
        return "探索";
    }
}

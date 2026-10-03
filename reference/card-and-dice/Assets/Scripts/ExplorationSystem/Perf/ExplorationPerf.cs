// =============================================================================
// 模块：探索性能口径与打点（★2026-09-16 荒野大地图性能批）
// 用途：
//   ① LOD 两个半径的唯一口径（逻辑远场降级 / 渲染裁剪）
//   ② 常用单例的缓存查找（FindObjectOfType 在万对象的大地图上是全场景扫，不能每次解算都调）
//   ③ 每帧卡顿采样 + 敌人阶段耗时摘要（控制台一行，方便实机验证与后续定位）
// 设计依据：用户报「移动和结束回合很卡」；荒野图 120×75 ≈ 9000 格，
//   原小图上的低效实现被放大 —— 详见 `docs/` 规划文档与 PROJECT_INDEX §20.7。
// =============================================================================
using System.Diagnostics;
using UnityEngine;

public static class ExplorationPerf
{
    // ------------------------------------------------------------------
    // ① LOD 半径（六边格距离）
    // ------------------------------------------------------------------

    /// <summary>
    /// 逻辑远场半径：小队锚点离玩家**超过**它 → 只走「廉价推进」（不算 A* / 不做落点避让 /
    /// 不播逐格动画，整队直接对齐编队槽位）。
    /// ★必须明显大于 <see cref="RenderLodRadius"/>：确保「玩家看得见的小队永远走完整解算」，
    ///   否则玩家会看到远处小队的移动是瞬移（预览≠执行感）。
    /// </summary>
    public const int PatrolLodRadius = 30;

    /// <summary>
    /// 渲染裁剪半径：敌人离玩家**超过**它 → 关掉模型 / 血条 / 意图徽章的渲染与组件（逻辑照跑）。
    /// 取值要大于「玩家需要看见远处巡逻队」的实际需求（看得见巡逻路线是本作有意设计的情报层）。
    /// </summary>
    public const int RenderLodRadius = 26;

    /// <summary>打点总开关（关掉 = 零开销，只留 LOD 生效）。</summary>
    public static bool TimingEnabled = true;

    // ------------------------------------------------------------------
    // ② 单例缓存（Unity 的 fake-null：对象被销毁后 == null 成立 → 自动重新查找）
    // ------------------------------------------------------------------

    static HexMover s_player;
    static HexGridLayout s_grid;
    static TerrainManager s_terrain;

    public static HexMover Player
    {
        get
        {
            if (s_player == null) s_player = Object.FindObjectOfType<HexMover>();
            return s_player;
        }
    }

    public static HexGridLayout Grid
    {
        get
        {
            if (s_grid == null) s_grid = Object.FindObjectOfType<HexGridLayout>();
            return s_grid;
        }
    }

    public static TerrainManager Terrain
    {
        get
        {
            if (s_terrain == null) s_terrain = Object.FindObjectOfType<TerrainManager>();
            return s_terrain;
        }
    }

    static EnergyPointDisplay s_energy;

    /// <summary>
    /// 能量点显示（★2026-09-16 性能二批）：回合边界有多处 FindObjectOfType&lt;EnergyPointDisplay&gt;，
    /// 每次全场景扫 ≈3–4ms。缓存口径与 FindObjectOfType 一致——对象被隐藏时返回 null（不返回 inactive 实例）。
    /// </summary>
    public static EnergyPointDisplay Energy
    {
        get
        {
            if (s_energy == null || !s_energy.gameObject.activeInHierarchy)
            {
                s_energy = Object.FindObjectOfType<EnergyPointDisplay>();
            }
            return s_energy;
        }
    }

    /// <summary>玩家当前坐标；玩家不存在时返回 int.MinValue（调用方按「不在场」处理）。</summary>
    public static Vector2Int PlayerCoord
    {
        get
        {
            HexMover p = Player;
            return p != null ? p.CurrentCoord : new Vector2Int(int.MinValue, int.MinValue);
        }
    }

    /// <summary>该格离玩家是否超过半径（玩家不存在 → false，按「不裁剪」保守处理）。</summary>
    public static bool IsFarFromPlayer(Vector2Int coord, int radius)
    {
        HexMover p = Player;
        if (p == null) return false;
        return CardExecutor.HexDistance(p.CurrentCoord, coord) > radius;
    }

    // ------------------------------------------------------------------
    // ③ 打点：计时作用域 + 每帧采样 + 一行摘要
    // ------------------------------------------------------------------

    static readonly Stopwatch s_watch = new Stopwatch();
    static bool s_phaseActive;
    static int s_frameCount;
    static double s_frameSumMs, s_frameWorstMs;
    static string s_worstWhat = "";

    // ★2026-09-16 二批：阶段首帧（= 点「结束回合」那一帧，协程第一段与 CoroutineBatch 全部
    //   任务的首段都在这一帧同步跑）单独报，方便和阶段内的卡帧区分开。
    static int s_frameIndex;
    static double s_firstFrameMs;

    // ★2026-09-16 二批：卡帧行的堆增量（GC 线索：卡帧帧若伴随堆大幅变动 → 多半是分配/回收，不是脚本逻辑）
    static long s_lastHeapKb;

    // ★2026-09-16 二批：非敌人阶段（玩家回合 / 移动 / 战斗）滚动窗口，每约 3 秒一行
    static int s_idleFrames;
    static double s_idleSumMs, s_idleWorstMs;
    static float s_idleWindowStart;
    const float IdleWindowSeconds = 3f;

    static double s_planMs, s_farMs, s_badgeMs;
    static int s_fullSolves, s_farTurns, s_badgeSolves;

    static float s_nextHitchReport;

    /// <summary>计时开始（关闭打点返回 null，调用方直接把它交给 EndScope 即可）。</summary>
    public static Stopwatch StartTimer()
    {
        if (!TimingEnabled) return null;
        s_watch.Restart();
        return s_watch;
    }

    /// <summary>
    /// 回合边界分段用独立秒表（可以嵌套在外层分段里用，不共用共享秒表；打点关闭返回 null）。
    /// 用于「结束回合段 / 回合开始段 / 手牌重排」这类一次性成本的分段计时。
    /// </summary>
    public static Stopwatch StartBoundaryTimer()
    {
        if (!TimingEnabled) return null;
        Stopwatch sw = new Stopwatch();
        sw.Start();
        return sw;
    }

    /// <summary>回合边界分段结束：单独打一行（label 例：「结束回合段」「回合开始段」「手牌重排」）。</summary>
    public static void EndBoundaryScope(Stopwatch sw, string label, string detail = null)
    {
        if (sw == null) return;
        sw.Stop();
        UnityEngine.Debug.Log(string.Format("[性能] {0}：{1:F1}ms{2}",
            label, sw.Elapsed.TotalMilliseconds,
            string.IsNullOrEmpty(detail) ? "" : "（" + detail + "）"));
    }

    /// <summary>完整解算（ComputeTurnPlan）一次结束。</summary>
    public static void EndPlanScope(Stopwatch sw)
    {
        if (sw == null) return;
        sw.Stop();
        s_planMs += sw.Elapsed.TotalMilliseconds;
        s_fullSolves++;
    }

    /// <summary>远场推进一次结束。</summary>
    public static void EndFarScope(Stopwatch sw)
    {
        if (sw == null) return;
        sw.Stop();
        s_farMs += sw.Elapsed.TotalMilliseconds;
        s_farTurns++;
    }

    /// <summary>徽章一次重算结束（ThreatPredictor / 问号转换预览等）。</summary>
    public static void EndBadgeScope(Stopwatch sw)
    {
        if (sw == null) return;
        sw.Stop();
        s_badgeMs += sw.Elapsed.TotalMilliseconds;
        s_badgeSolves++;
    }

    /// <summary>敌人阶段开始：清累计 + 开帧采样窗口。</summary>
    public static void BeginEnemyPhase()
    {
        if (!TimingEnabled) return;
        s_planMs = s_farMs = s_badgeMs = 0.0;
        s_fullSolves = s_farTurns = s_badgeSolves = 0;
        s_frameCount = 0;
        s_frameSumMs = s_frameWorstMs = 0.0;
        s_worstWhat = "";
        s_frameIndex = 0;
        s_firstFrameMs = 0.0;
        // 玩家阶段窗口从本阶段结束后重新起算（避免把阶段前的帧算进「近 3 秒」）
        s_idleFrames = 0;
        s_idleSumMs = s_idleWorstMs = 0.0;
        s_phaseActive = true;
    }

    /// <summary>敌人阶段结束：打印一行摘要。</summary>
    public static void EndEnemyPhase()
    {
        if (!TimingEnabled || !s_phaseActive) return;
        s_phaseActive = false;

        double avg = s_frameCount > 0 ? s_frameSumMs / s_frameCount : 0.0;
        UnityEngine.Debug.Log(string.Format(
            "[性能] 敌人阶段：首帧 {0:F1}ms｜帧 {1:F1}ms 均值 / {2:F1}ms 最差（{3} 帧{4}）｜解算 {5:F1}ms（完整 {6} 队）｜远场 {7:F1}ms（{8} 队）｜徽章 {9:F1}ms（{10} 次）",
            s_firstFrameMs,
            avg, s_frameWorstMs, s_frameCount,
            string.IsNullOrEmpty(s_worstWhat) ? "" : "／" + s_worstWhat,
            s_planMs, s_fullSolves, s_farMs, s_farTurns, s_badgeMs, s_badgeSolves));
    }

    /// <summary>每帧采样（由 EnemyRenderLod 的 LateUpdate 调用）。</summary>
    public static void SampleFrame(float unscaledDt, string what)
    {
        if (!TimingEnabled) return;

        double ms = unscaledDt * 1000.0;

        long heapKb = System.GC.GetTotalMemory(false) / 1024;

        if (s_phaseActive)
        {
            s_frameCount++;
            s_frameIndex++;
            s_frameSumMs += ms;
            if (s_frameIndex == 1) s_firstFrameMs = ms;
            if (ms > s_frameWorstMs) { s_frameWorstMs = ms; s_worstWhat = what; }
        }
        else
        {
            if (s_idleFrames == 0) s_idleWindowStart = Time.unscaledTime;
            s_idleFrames++;
            s_idleSumMs += ms;
            if (ms > s_idleWorstMs) s_idleWorstMs = ms;
            if (Time.unscaledTime - s_idleWindowStart >= IdleWindowSeconds)
            {
                UnityEngine.Debug.Log(string.Format(
                    "[性能] 玩家阶段：帧 {0:F1}ms 均值 / {1:F1}ms 最差（{2:F0} 秒 {3} 帧／{4}）",
                    s_idleSumMs / s_idleFrames, s_idleWorstMs,
                    Time.unscaledTime - s_idleWindowStart, s_idleFrames, what));
                s_idleFrames = 0;
                s_idleSumMs = s_idleWorstMs = 0.0;
            }
        }

        // 卡帧也报（移动/悬停/回合切换等），限流 1.5 秒一条，避免刷屏
        if (ms > 40.0 && Time.unscaledTime >= s_nextHitchReport)
        {
            s_nextHitchReport = Time.unscaledTime + 1.5f;
            string where = s_phaseActive
                ? (s_frameIndex == 1 ? "阶段首帧" : "阶段内第 " + s_frameIndex + " 帧")
                : "阶段外";
            long heapDelta = s_lastHeapKb == 0 ? 0 : heapKb - s_lastHeapKb;
            UnityEngine.Debug.Log(string.Format("[性能] 卡帧 {0:F1}ms（{1}／{2}）｜堆 {3:+0;-0;0}KB",
                ms, what, where, heapDelta));
        }

        s_lastHeapKb = heapKb;
    }
}

// =============================================================================
// 模块：M6-6 敌人系统 - SpawnResolver 小队生成解算
// 用途：把 EnemySquadData 落地到地图——锚点 + hexOffset + 螺旋 BFS 避让，
//        保证永不重叠、永不出界、不踩障碍（设计验收：无重叠无出界）。
// 设计依据：《设计增补_敌人系统_v2.md》§6.2 锚点 / §6.3 编队模板 / §6.4 生成解算
// 职责边界：
//   - 本类只管「小队落地」：解算格子 + 克隆数据（应用覆盖）+ 实例化单位 + 摆位
//   - 不做战斗触发（M3）、不做回合逻辑（EnemyTurnExecutor 动态发现新生成敌人，天然接入）
// 落地流程（§6.4）：
//   1. 目标格 = 锚点格 + 成员 hexOffset（奇偶 q/r 偏移直接相加）
//   2. 目标格空闲合法（界内+非障碍+无单位）→ 直接放
//   3. 否则螺旋 BFS 向外找最近空闲合法格（角色感知评分：先锋/近卫偏向玩家一侧、狙击/术士/辅助靠后）
//   4. 全图塞满 → 跳过该成员并记 warning
// 角色优先级（§6.4）：落地顺序 先锋 → 近卫 → 狙击 → 术士 → 辅助（与行动顺序一致）。
//   设计原文「Melee 被挤到 Ranged 后面则整队重排」在 Demo 阶段由角色感知避让评分
//   等效实现（近卫避让时优先选离玩家更近的格），满足验收「无重叠无出界」。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 敌人小队生成解算器（纯静态工具）。
/// 用法：<see cref="Spawn(EnemySquadData, Vector2Int)"/> 传入小队 SO + 锚点格坐标。
/// </summary>
public static class SpawnResolver
{
    /// <summary>螺旋避让最大搜索环数（8 环 ≈ 半径 8 格，37+ 检查范围，Demo 地图足够）</summary>
    private const int MaxSearchRings = 8;

    /// <summary>
    /// 小队行动顺序基数（静态递增：每次 Spawn +100）。
    /// 先遇到（先生成）的小队 base 小 → 敌人回合先动；成员 = base + 配置下标。
    /// </summary>
    private static int _squadTurnBase = 0;

    // ==================================================================
    // 编队模板自动摆位（§6.3，编辑器按钮 + 运行时共用）
    // ==================================================================

    /// <summary>
    /// 按小队编队模板自动填各成员 hexOffset（一键摆位）。
    /// 模板内部约定：前排 = y 小（近战前排 / 远程·辅助后排）；「面向玩家」的方向调整
    /// 不在模板做（资产无玩家概念），由生成解算的角色感知避让评分负责（§6.4）。
    /// 模板已避让冲突（同格自动顺延到最近未用环位），保证模板结果自身不重叠。
    /// </summary>
    public static void ApplyFormation(EnemySquadData squad)
    {
        if (squad == null || squad.units == null || squad.units.Count == 0) return;

        // 环位表：rings[0]=环1（6格）rings[1]=环2（12格）... 以 (0,0) 为中心 BFS 分层
        List<List<Vector2Int>> rings = BfsLayers(Vector2Int.zero, 4);
        var used = new HashSet<Vector2Int>();

        // 按生效角色分桶（保持列表原顺序，稳定）
        var melee = new List<int>();   // 先锋 / 近卫（前排）
        var ranged = new List<int>();  // 狙击（后排远程）
        var back = new List<int>();    // 术士 / 辅助（后排/内圈）
        for (int i = 0; i < squad.units.Count; i++)
        {
            switch (squad.units[i].EffectiveRole)
            {
                case CombatRole.先锋:
                case CombatRole.近卫: melee.Add(i); break;
                case CombatRole.狙击: ranged.Add(i); break;
                default: back.Add(i); break; // 术士 / 辅助
            }
        }

        switch (squad.formation)
        {
            case FormationType.聚拢:
                // 全挤在锚点周围：锚点 → 环1 → 环2 ... 顺序填
                AssignSequential(AllOffsets(rings), squad, melee, ranged, back, used);
                break;

            case FormationType.横排:
                // 横向一字：近卫/先锋前排（y=0），狙击/术士/辅助后排（y=1，多则 y=2）
                for (int i = 0; i < melee.Count; i++)
                    TryAssign(squad, melee[i], new Vector2Int(i - melee.Count / 2, 0), used, rings);
                for (int j = 0; j < ranged.Count; j++)
                    TryAssign(squad, ranged[j], new Vector2Int(j - ranged.Count / 2, 1), used, rings);
                for (int k = 0; k < back.Count; k++)
                    TryAssign(squad, back[k], new Vector2Int(k - back.Count / 2, 2), used, rings);
                break;

            case FormationType.楔形:
                // V 字尖头朝前排：近卫/先锋[0] 是尖 (0,0)，其余近卫左右臂张开，狙击/术士/辅助躲 V 内侧
                if (melee.Count > 0) TryAssign(squad, melee[0], Vector2Int.zero, used, rings);
                for (int i = 1; i < melee.Count; i++)
                {
                    int k = (i + 1) / 2;                        // 臂展开步数
                    int side = (i % 2 == 1) ? 1 : -1;           // 左右臂交替
                    TryAssign(squad, melee[i], new Vector2Int(side * k, k), used, rings);
                }
                for (int j = 0; j < ranged.Count; j++)
                    TryAssign(squad, ranged[j], new Vector2Int(0, j + 1), used, rings); // 尖正后方（V 内侧）
                for (int k = 0; k < back.Count; k++)
                    TryAssign(squad, back[k], new Vector2Int(0, ranged.Count + k + 1), used, rings);
                break;

            case FormationType.方阵:
                // 圈：近卫/先锋外圈（环1，溢出进环2），狙击/术士/辅助内圈（中心 → 环2 剩余位）
                for (int i = 0; i < melee.Count; i++)
                {
                    Vector2Int preferred = RingCell(rings, 0, i, RingCell(rings, 1, i - 6));
                    TryAssign(squad, melee[i], preferred, used, rings);
                }
                var inner = new List<int>();
                inner.AddRange(ranged); inner.AddRange(back); // 内圈统一处理（狙击/术士/辅助）
                for (int j = 0; j < inner.Count; j++)
                {
                    // j=0 占中心；之后吃环2、环3（TryAssign 自动跳过已被近卫/先锋溢出占用的格）
                    Vector2Int preferred = j == 0 ? Vector2Int.zero
                        : RingCell(rings, 1, j - 1, RingCell(rings, 2, j - 13));
                    TryAssign(squad, inner[j], preferred, used, rings);
                }
                break;

            case FormationType.散开:
                // 确定性伪随机扩散：环1/环2/环3 隔一取一（视觉上分散不抱团）
                var spread = new List<Vector2Int>();
                for (int r = 0; r < rings.Count; r++)
                    for (int c = 0; c < rings[r].Count; c += 2)
                        spread.Add(rings[r][c]);
                AssignSequential(spread, squad, melee, ranged, back, used);
                break;
        }
    }

    /// <summary>顺序分配：按 先锋/近卫→狙击→术士/辅助 的桶顺序依次占用位置列表。</summary>
    private static void AssignSequential(List<Vector2Int> offsets, EnemySquadData squad,
        List<int> melee, List<int> ranged, List<int> back, HashSet<Vector2Int> used)
    {
        var order = new List<int>();
        order.AddRange(melee); order.AddRange(ranged); order.AddRange(back);
        for (int i = 0; i < order.Count; i++)
        {
            Vector2Int preferred = i < offsets.Count ? offsets[i] : Vector2Int.zero;
            TryAssign(squad, order[i], preferred, used, null);
        }
    }

    /// <summary>
    /// 尝试把成员放到首选格；被占则顺延到最近未用环位（编辑期保证模板自身不重叠）。
    /// </summary>
    private static void TryAssign(EnemySquadData squad, int unitIndex, Vector2Int preferred,
        HashSet<Vector2Int> used, List<List<Vector2Int>> rings)
    {
        if (used.Add(preferred)) { squad.units[unitIndex].hexOffset = preferred; return; }

        // 首选被占：从环1向外找第一个未用格（编辑期兜底，正常模板不会走到这）
        if (rings != null)
        {
            foreach (var ring in rings)
                foreach (var cell in ring)
                    if (used.Add(cell)) { squad.units[unitIndex].hexOffset = cell; return; }
        }
        // 环位也全满（成员数 > 54 的极端情况）：放弃去重，保留首选（运行期螺旋避让兜底）
        squad.units[unitIndex].hexOffset = preferred;
    }

    /// <summary>取环位表第 ring 环第 index 格；越界返回 fallback（默认 (0,0)）。</summary>
    private static Vector2Int RingCell(List<List<Vector2Int>> rings, int ring, int index, Vector2Int fallback = default)
    {
        if (rings == null || ring >= rings.Count || index < 0 || index >= rings[ring].Count) return fallback;
        return rings[ring][index];
    }

    /// <summary>环位表展平（锚点 (0,0) 不含）：环1 → 环2 → ...</summary>
    private static List<Vector2Int> AllOffsets(List<List<Vector2Int>> rings)
    {
        var all = new List<Vector2Int> { Vector2Int.zero };
        foreach (var ring in rings) all.AddRange(ring);
        return all;
    }

    // ==================================================================
    // 生成解算（§6.4，运行时落地）
    // ==================================================================

    /// <summary>用地图上的巡逻布局生成：出生=第一路径点，并挂上整队路径巡逻。</summary>
    /// <param name="waypointsOverride">
    /// ★2026-09-12 每局随机落位：<see cref="SquadSpawnPlacer"/> 解算出的「平移后路线」。
    /// 传了就以它为准（出生锚点与朝向都按它算），不再读 patrol.patrolWaypoints。
    /// </param>
    public static List<EnemyController> Spawn(SquadPatrolData patrol, Transform parent = null,
        IList<Vector2Int> waypointsOverride = null)
    {
        if (patrol == null || patrol.squad == null)
        {
            Debug.LogWarning("[SpawnResolver] 巡逻资产未指定小队模板，跳过生成");
            return new List<EnemyController>();
        }
        Vector2Int anchor = ResolveAnchor(patrol, waypointsOverride);
        return Spawn(patrol.squad, anchor, parent, patrol, waypointsOverride);
    }

    /// <summary>出生锚点：有「本局实际路线」用它的第一个点，否则退回资产里的第一个路径点。</summary>
    private static Vector2Int ResolveAnchor(SquadPatrolData patrol, IList<Vector2Int> waypointsOverride)
    {
        if (waypointsOverride != null && waypointsOverride.Count > 0) return waypointsOverride[0];
        return patrol.HasPatrolPath ? patrol.patrolWaypoints[0] : Vector2Int.zero;
    }

    /// <summary>
    /// 把小队落到地图：锚点对齐 anchor 格，逐成员解算实际格并实例化。
    /// 落地顺序按角色：先锋 → 近卫 → 狙击 → 术士 → 辅助（§6.4 角色优先级，与行动顺序一致）。
    /// patrol 为空时只按锚点摆位，闲时随机游走；有巡逻资产则按路径排头尾并整队巡逻。
    /// </summary>
    public static List<EnemyController> Spawn(EnemySquadData squad, Vector2Int anchor, Transform parent = null)
    {
        return Spawn(squad, anchor, parent, null);
    }

    public static List<EnemyController> Spawn(EnemySquadData squad, Vector2Int anchor, Transform parent,
        SquadPatrolData patrol, IList<Vector2Int> waypointsOverride = null, int maxUnits = int.MaxValue)
    {
        var result = new List<EnemyController>();
        if (squad == null || squad.units == null || squad.units.Count == 0)
        {
            Debug.LogWarning("[SpawnResolver] 小队为空，跳过生成");
            return result;
        }

        HexGridLayout grid = UnityEngine.Object.FindObjectOfType<HexGridLayout>();
        if (grid == null)
        {
            Debug.LogError("[SpawnResolver] 场景无 HexGridLayout，无法生成小队");
            return result;
        }
        TerrainManager terrain = UnityEngine.Object.FindObjectOfType<TerrainManager>();

        // ★2026-09-12 每局随机落位：路线可能是 SquadSpawnPlacer 平移过的，有覆盖一律以覆盖为准。
        IList<Vector2Int> route = waypointsOverride != null && waypointsOverride.Count > 0
            ? waypointsOverride
            : (patrol != null ? (IList<Vector2Int>)patrol.patrolWaypoints : null);

        Vector2Int spawnAnchor = anchor;
        int faceSteps = 0;
        if (patrol != null && route != null && route.Count > 0)
        {
            spawnAnchor = route[0];
            if (route.Count >= 2)
            {
                faceSteps = HexCoord.FacingSteps(route[0], route[1]);
            }
        }

        SquadPatrolGroup patrolGroup = patrol != null && route != null && route.Count > 0
            ? SquadPatrolGroup.Create(patrol, spawnAnchor, parent, route)
            : null;

        // 玩家坐标（角色感知避让评分用；无玩家时退化为「离目标格最近」）
        HexMover player = UnityEngine.Object.FindObjectOfType<HexMover>();
        Vector2Int playerCoord = player != null ? player.CurrentCoord : new Vector2Int(-1, -1);

        // 已落格集合（本批生成内部防重叠；UnitOccupancy 看不到「尚未 Start 射线绑定」的单位）
        var placed = new HashSet<Vector2Int>();

        // 角色优先级排序（稳定：同角色保持配置顺序）
        var order = new List<int>();
        for (int i = 0; i < squad.units.Count; i++) order.Add(i);
        order.Sort((a, b) => RolePriority(squad.units[a].EffectiveRole).CompareTo(RolePriority(squad.units[b].EffectiveRole)));

        // ★2026-08-21 全局行动顺序（用户需求：先遇到的小队先动，队内按配置顺序先动）：
        // 每次 Spawn 调用分配一个 base（静态计数器 +100，先生成的小队 base 小），
        // 成员 TurnOrder = base + units 配置列表下标（与落地顺序无关，落地按角色优先级）。
        _squadTurnBase += 100;
        int squadId = _squadTurnBase; // ★D14 参战范围：同批成员共享小队 ID（警戒/偷袭拉同队参战）

        int spawnedIndex = 0;
        foreach (int i in order)
        {
            if (result.Count >= maxUnits) break;    // ★事件进战（design §3.3）：只要 1~2 只

            EnemyUnitConfig unit = squad.units[i];
            if (unit == null || unit.preset == null)
            {
                Debug.LogWarning($"[SpawnResolver] 小队「{squad.squadName}」成员 {i} 无预设，跳过");
                continue;
            }

            // ① 解算实际格：目标格 = 锚点 + hexOffset（§6.4-1），被占则螺旋避让（§6.4-3）
            Vector2Int target = HexCoord.FormationSlot(spawnAnchor, unit.hexOffset, faceSteps);
            Vector2Int? cell = ResolveCell(target, unit.EffectiveRole, grid, terrain, placed, playerCoord);
            if (!cell.HasValue)
            {
                Debug.LogWarning($"[SpawnResolver] 小队「{squad.squadName}」成员 {i}（{unit.preset.enemyName}）" +
                                 $"目标格 {target} 附近 {MaxSearchRings} 环内无空闲合法格，跳过（地图被塞满？）");
                continue;
            }

            // ② 克隆预设并应用小队覆盖（运行时内存副本，不落盘）
            EnemyData clone = CloneWithOverrides(unit);
            if (patrol != null && patrol.squadPatrolAP > 0) clone.patrolAP = patrol.squadPatrolAP;

            // ③ 实例化：有预制体用预制体，没有则标准 Cube 兜底（无血条 UI，提示补预制体）
            GameObject go;
            EnemyController ctrl;
            if (unit.preset.prefab != null)
            {
                go = UnityEngine.Object.Instantiate(unit.preset.prefab, parent);
                // 根 Y 规范为 0.5（敌人结构约定：Cube 在 Model 子对象、根 Y=0.5）。
                // 预制体资产根 Y 存的是 0，不修正会导致单位半埋进地里 +
                // Start 射线贴地发射打不中 Hex_ 格子（CurrentCoord 绑定警告）。
                Vector3 pos = go.transform.position;
                go.transform.position = new Vector3(pos.x, 0.5f, pos.z);
                go.name = $"{unit.preset.enemyName}_{spawnedIndex + 1}";
                ctrl = go.GetComponent<EnemyController>();
                if (ctrl == null)
                {
                    Debug.LogError($"[SpawnResolver] 预制体 {unit.preset.prefab.name} 缺 EnemyController，跳过");
                    UnityEngine.Object.Destroy(go);
                    continue;
                }
                ctrl.Initialize(clone); // 用覆盖克隆重新初始化（覆盖 Awake 用预设原值滚的 HP）
            }
            else
            {
                ctrl = CreateFallbackCube($"{unit.preset.enemyName}_{spawnedIndex + 1}_兜底", parent, clone);
                go = ctrl.gameObject;
                Debug.LogWarning($"[SpawnResolver] 预设「{unit.preset.enemyName}」未配 prefab，" +
                                 "已用标准 Cube 兜底生成（无血条 UI，建议在 EnemyData.prefab 补预制体）");
            }

            // ④ 摆位：直接落到解算格（不走射线，生成期确定性绑定坐标）
            ctrl.MoveToCoord(cell.Value);
            ctrl.SetPatrolHome();
            if (patrolGroup != null)
            {
                patrolGroup.Register(ctrl, unit.hexOffset);
            }
            // 全局行动顺序：按 units 配置列表下标赋值（i = 配置序，非落地序）
            ctrl.TurnOrder = _squadTurnBase + i;
            ctrl.SquadId = squadId; // ★D14：同小队成员共享 ID（警戒/偷袭参战范围判定）
            ctrl.UnitIndex = i;     // ★2026-09-12 掉落配置查表下标（members[i]）
            placed.Add(cell.Value);
            result.Add(ctrl);
            spawnedIndex++;

            // ⑤ 战斗中生成 → 立即揭示意图（★2026-08-21 用户需求：生成的小队当场亮出
            //    意图徽章 + 移动虚线/攻击弧线，不等下个玩家回合开始）。
            //    徽章（EnemyIntentBadgeUI）与视觉（EnemyIntentVisuals）均依赖
            //    RevealedIntent != null 才显示；不揭示则生成后一直空窗。
            //    G 键测试生成 / 未来 M3 视野触发都走这里，天然带意图。
            if (Application.isPlaying
                && GameStateManager.Instance != null
                && GameStateManager.Instance.CurrentState == GameState.Battle)
            {
                ctrl.RevealIntent();
            }

            Debug.Log($"[SpawnResolver] 小队「{squad.squadName}」成员 {i}（{unit.preset.enemyName}）" +
                      $"落格 Hex_{cell.Value.x}_{cell.Value.y}（目标 {target}，角色 {unit.EffectiveRole}）");
        }

        Debug.Log($"[SpawnResolver] 小队「{squad.squadName}」生成完毕：{result.Count}/{squad.units.Count} 名成员落位锚点 Hex_{spawnAnchor.x}_{spawnAnchor.y}"
                  + (patrol != null && patrol.HasPatrolPath ? $"，路径 {patrol.patrolWaypoints.Count} 点（{patrol.patrolLoopMode}）" : "（无路径，闲时随机游走）"));
        return result;
    }

    /// <summary>
    /// 解算一个成员的实际落格（§6.4）：
    /// 目标格空闲合法直接用；否则从目标格螺旋 BFS 向外，取第一个有空闲格的环，
    /// 环内按角色感知评分选最优（先锋/近卫偏向玩家一侧 / 狙击·术士·辅助靠后）。
    /// </summary>
    private static Vector2Int? ResolveCell(Vector2Int target, CombatRole role,
        HexGridLayout grid, TerrainManager terrain, HashSet<Vector2Int> placed, Vector2Int playerCoord)
    {
        if (IsFreeAndValid(target, grid, terrain, placed)) return target;

        var layers = BfsLayers(target, MaxSearchRings);
        foreach (var layer in layers)
        {
            // 收集本环空闲合法格
            var candidates = new List<Vector2Int>();
            foreach (var c in layer)
                if (IsFreeAndValid(c, grid, terrain, placed)) candidates.Add(c);
            if (candidates.Count == 0) continue;

            // 角色感知评分（§6.4-3「Melee 尽量落在更靠近玩家的一侧、Ranged 靠后」）
            Vector2Int best = candidates[0];
            int bestScore = int.MinValue;
            foreach (var c in candidates)
            {
                int score;
                bool hasPlayer = playerCoord.x >= 0 && playerCoord.y >= 0;
                switch (role)
                {
                    case CombatRole.先锋:
                    case CombatRole.近卫:
                        // 前排：离玩家越近越好；无玩家退化贴目标格
                        score = hasPlayer ? -CardExecutor.HexDistance(c, playerCoord)
                                           : -CardExecutor.HexDistance(c, target);
                        break;
                    case CombatRole.狙击:
                    case CombatRole.术士:
                    case CombatRole.辅助:
                        // 后排：离玩家越远越好（靠后），平手取离目标格近（保持编队紧凑）
                        score = hasPlayer ? CardExecutor.HexDistance(c, playerCoord) * 10
                                             - CardExecutor.HexDistance(c, target)
                                           : -CardExecutor.HexDistance(c, target);
                        break;
                    default: // 未知角色：贴着目标格（保持编队紧凑）
                        score = -CardExecutor.HexDistance(c, target);
                        break;
                }
                if (score > bestScore) { bestScore = score; best = c; }
            }
            return best;
        }
        return null; // MaxSearchRings 环内全满（§6.4-4）
    }

    /// <summary>格子空闲且合法：界内 + 地形可通行 + 无单位占位 + 本批未落（与 MoveAIController.IsWalkableCell 同规则）。</summary>
    private static bool IsFreeAndValid(Vector2Int c, HexGridLayout grid, TerrainManager terrain, HashSet<Vector2Int> placed)
    {
        if (c.x < 0 || c.y < 0 || c.x >= grid.gridSize.x || c.y >= grid.gridSize.y) return false;
        if (terrain != null && !terrain.IsPassable(c)) return false;
        if (UnitOccupancy.IsOccupied(c)) return false;
        if (placed.Contains(c)) return false;
        return true;
    }

    /// <summary>角色落地优先级：先锋 0 → 近卫 1 → 狙击 2 → 术士 3 → 辅助 4（§6.4）。
    /// 与 EnemyLandingPlanner.RolePriority（行动顺序）数值完全一致——前排先落地、后排后落地，
    /// 与行动顺序天然对齐，全项目统一。</summary>
    private static int RolePriority(CombatRole role)
    {
        switch (role)
        {
            case CombatRole.先锋: return 0;
            case CombatRole.近卫: return 1;
            case CombatRole.狙击: return 2;
            case CombatRole.术士: return 3;
            default: return 4; // 辅助/未知
        }
    }

    // ==================================================================
    // 覆盖克隆 + 兜底单位
    // ==================================================================

    /// <summary>
    /// 克隆预设并应用小队成员覆盖（勾选=覆盖，不勾=沿用预设）。
    /// Object.Instantiate(SO) 生成内存副本，不写盘、不影响原资产。
    /// </summary>
    private static EnemyData CloneWithOverrides(EnemyUnitConfig unit)
    {
        EnemyData d = UnityEngine.Object.Instantiate(unit.preset);
        d.name = unit.preset.name + "_小队克隆";

        if (unit.hpMinOverride.on) d.hpMin = Mathf.Max(1, unit.hpMinOverride.value);
        if (unit.hpMaxOverride.on) d.hpMax = Mathf.Max(1, unit.hpMaxOverride.value);
        if (d.hpMax < d.hpMin) d.hpMax = d.hpMin; // 覆盖后维持区间合法

        if (unit.moveRangeOverride.on) d.moveRange = Mathf.Max(0, unit.moveRangeOverride.value);
        if (unit.visionRangeOverride.on) d.visionRange = Mathf.Max(0, unit.visionRangeOverride.value);

        if (unit.overrideCombatRole) d.combatRole = unit.combatRole;
        if (unit.overrideIntentLoop && unit.intentLoop != null && unit.intentLoop.Count > 0) d.intentLoop = unit.intentLoop;
        if (unit.overrideMovePreset) d.movePreset = unit.movePreset;
        if (unit.overrideMoveParams && unit.moveParams != null) d.moveParams = unit.moveParams;
        if (unit.overridePassives && unit.passives != null && unit.passives.Count > 0) d.passives = unit.passives;

        return d;
    }

    /// <summary>
    /// 预制体缺失时的标准 Cube 兜底单位（与现有敌人结构对齐：根 Y=0.5、Model 子对象、
    /// BoxCollider 在根上供点击射线）。无血条 UI——正式做法是给 EnemyData 配 prefab。
    /// 先建非激活对象再挂组件，避免 EnemyController.Awake 在 data 注入前报空数据错误。
    /// </summary>
    private static EnemyController CreateFallbackCube(string name, Transform parent, EnemyData data)
    {
        var root = new GameObject(name);
        root.SetActive(false); // 暂不激活：AddComponent 时 Awake 延迟到激活后
        root.transform.position = new Vector3(0f, 0.5f, 0f); // 标准结构：根 Y=0.5（Cube 中心 Y=0.5）
        root.AddComponent<BoxCollider>(); // 与预制体结构对齐：根上 BoxCollider 供点击射线（原先只有注释、没有实现）

        var model = GameObject.CreatePrimitive(PrimitiveType.Cube);
        model.name = "Model";
        UnityEngine.Object.Destroy(model.GetComponent<BoxCollider>()); // 根上已有碰撞体，避免双射线目标
        model.transform.SetParent(root.transform, false);              // localPos=(0,0,0)

        if (parent != null) root.transform.SetParent(parent, false);

        var ctrl = root.AddComponent<EnemyController>(); // 非激活态 Awake 延迟
        ctrl.Initialize(data);                            // 先注入数据
        root.SetActive(true);                             // 激活后 Awake 用已注入的 data 初始化
        return ctrl;
    }

    // ==================================================================
    // 六边形工具
    // ==================================================================

    /// <summary>
    /// 以 center 为中心 BFS 分层：layers[0] = 环1（距离1），layers[1] = 环2 …
    /// 层内顺序 = 邻居枚举顺序（确定性）。不判断格子合法性（避让时才过滤）。
    /// </summary>
    private static List<List<Vector2Int>> BfsLayers(Vector2Int center, int maxDepth)
    {
        var layers = new List<List<Vector2Int>>();
        var visited = new HashSet<Vector2Int> { center };
        var current = new List<Vector2Int> { center };

        for (int d = 0; d < maxDepth; d++)
        {
            var next = new List<Vector2Int>();
            foreach (var c in current)
                foreach (var n in Neighbors(c))
                    if (visited.Add(n)) next.Add(n);
            layers.Add(next);
            current = next;
        }
        return layers;
    }

    /// <summary>奇偶 q（odd-q）平顶六边形邻居枚举，与 AStarPathfinding.GetFlatTopNeighbors / MoveAIController.GetNeighbors 对齐。</summary>
    private static List<Vector2Int> Neighbors(Vector2Int p)
    {
        var result = new List<Vector2Int>(6);
        int[][] odd = { new int[] { 1, 0 }, new int[] { 1, 1 }, new int[] { 0, 1 }, new int[] { -1, 1 }, new int[] { -1, 0 }, new int[] { 0, -1 } };
        int[][] even = { new int[] { 1, -1 }, new int[] { 1, 0 }, new int[] { 0, 1 }, new int[] { -1, 0 }, new int[] { -1, -1 }, new int[] { 0, -1 } };
        int[][] offsets = (p.x % 2 != 0) ? odd : even;
        foreach (var o in offsets) result.Add(new Vector2Int(p.x + o[0], p.y + o[1]));
        return result;
    }
}

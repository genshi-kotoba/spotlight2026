// =============================================================================
// 模块：M2 敌人系统 - EnemyController（Demo 简化版：靶子）
// 用途：挂载于敌人预制体，持有运行时 HP 状态，提供受伤/死亡接口
// 设计依据：
//   - 《开发计划_核心循环闭合与编辑器.md》M2 任务清单（订阅 GameStateManager）
//   - 用户决策：Demo 阶段敌人仅作"靶子"，不实现攻击/移动 AI（留待 M3/M6）
// 职责边界：
//   - 本脚本只管"被打 - 扣血 - 死亡"三件事
//   - 不做视野检测（M3）、不做意图/行动（M6）、不做战利品掉落（M7）
//   - 通过 OnEnemyDied 事件通知外部系统，解耦后续逻辑
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;

/// <summary>
/// 敌人运行时控制器（Demo 靶子版）。
/// </summary>
public class EnemyController : MonoBehaviour, IPointerClickHandler
{
    // -------- 数据源 --------
    [Header("数据")]
    [Tooltip("敌人静态数据 SO（必填，启动时读取 RollHP/moveRange 等）")]
    public EnemyData data;

    // -------- ★美术接入：地图立绘 --------
    [Tooltip("地图上立绘的世界高度（格顶面到头顶）。超过 2.0 会盖住相邻格（邻格间距仅 1.73）。脚底贴格顶面落位；改完直接 Play 看效果")]
    public float bodyWorldHeight = 1.4f;

    /// <summary>
    /// 头顶 UI（意图徽章 / 悬停卡面）在敌人本地空间的锚点高度——绝对高度基准；
    /// 屏幕上再抬高由徽章自身的 UI 平面偏移（offsetZ）负责，见 EnemyIntentBadgeUI。
    /// 与 bodyWorldHeight 线性联动，改身高不用另外调徽章（H=1.0→0.22，H=1.4→0.428）。
    /// ★2026-09-17 晚用户口径：绝对坐标放低一点（-0.22→-0.30）、相对 UI 抬高一点。
    /// </summary>
    public float HeadAnchorLocalY => 0.52f * bodyWorldHeight - 0.30f;

    /// <summary>
    /// 血条 Canvas 在敌人本地空间的锚点高度。与 bodyWorldHeight 等比，常数含整体下移量：
    /// H=1.0→-0.08，H=1.4→0.008（★2026-09-17 晚随贴图一起下移，常数 -0.22→-0.30）。
    /// EnemyHPBar 启动时用它覆盖预制体位置。
    /// </summary>
    public float BarAnchorLocalY => 0.22f * bodyWorldHeight - 0.30f;

    // -------- 运行时状态 --------
    [Header("运行时状态")]
    [Tooltip("当前 HP（运行时由 maxHP 初始化）")]
    [SerializeField] private int currentHP;

    [Tooltip("本实例最大 HP（运行时由 data.RollHP() 随机生成，v2 血量区间）")]
    [SerializeField] private int maxHP;

    /// <summary>当前 HP（只读外部访问）</summary>
    public int CurrentHP => currentHP;

    /// <summary>最大 HP（运行时随机生成，无有效值时返回 1 兜底）</summary>
    public int MaxHP => maxHP > 0 ? maxHP : 1;

    // -------- 行动点（★2026-08-18 新增：提前从 M6 拆出最小实现）--------
    [Tooltip("当前行动点（运行时由 moveRange 初始化。绿点徽章显示 / 断筋扣减 / M6 移动消耗）")]
    [SerializeField] private int currentActionPoints;

    /// <summary>当前行动点（只读外部访问，StatusBadgeUI 轮询）</summary>
    public int CurrentActionPoints => currentActionPoints;

    /// <summary>
    /// 行动点上限 = data.moveRange（哥布林 3 / 史莱姆 2）。
    /// Demo 简化：敌人 AP 与移动范围同源，M6 移动 AI 接入时消耗此值移动。
    /// </summary>
    public int MaxActionPoints => data != null ? data.moveRange : 0;

    // -------- 疾跑 / 意图循环运行时状态（★2026-08-19 M6-3 新增） --------

    /// <summary>当前追击值（疾跑累积，封顶 data.sprintMax）。够不到玩家时累积，命中后归零。</summary>
    [SerializeField] private int sprintAccumulated;

    /// <summary>
    /// ★2026-09-09 下回合生效的追击值缓冲：AddSprint/被动遇袭先把疾跑存入此字段，
    /// 下一敌人回合开始时经 <see cref="FoldSprintPending"/> 并入 sprintAccumulated。
    /// 目的：本回合移动预算（MoveBudget）不含「本回合刚加的疾跑」，追击移动时
    /// AP 徽章能正常降到 0（修复"追击 AP 最低停 1"），疾跑下回合才抬升移动力。
    /// </summary>
    [SerializeField] private int sprintPending;

    /// <summary>当前大意图下标（指向 data.intentLoop 中本回合要执行的大意图）。</summary>
    [SerializeField] private int currentIntentIndex;

    /// <summary>当前追击值（只读）</summary>
    public int SprintAccumulated => sprintAccumulated;

    /// <summary>当前大意图下标（只读）</summary>
    public int CurrentIntentIndex => currentIntentIndex;

    // -------- ★2026-09-16 姿态打断（架弩：挨打 → 意图回退重放） --------

    /// <summary>
    /// 最近一次「架起姿态」时所在的大意图下标（-1 = 从没架过）。
    /// 由 EnemyCardExecutor 在给自己挂 BreaksOnDamage 效果时记下，打断后回退到这里重放。
    /// </summary>
    private int _stanceIntentIndex = -1;

    /// <summary>
    /// 姿态是否在本玩家回合被打断（true = 下个敌人回合不出手，回退大意图重放「架弩」）。
    /// 由 TakeDamage 置位、EnemyTurnExecutor.ConsumeStanceBroken 消费并清零。
    /// </summary>
    private bool _stanceBroken;

    /// <summary>记录「本大意图架起了姿态」——打断后要回退到这一步重放。</summary>
    public void MarkStanceIntent()
    {
        _stanceIntentIndex = currentIntentIndex;
        Debug.Log($"[姿态] {gameObject.name} 架起姿态于大意图下标 {_stanceIntentIndex}（打断则回退到此重放）");
    }

    /// <summary>
    /// 消费「姿态被打断」标记：置位则回退大意图下标到架姿态那一步并返回 true。
    /// 调用方（EnemyTurnExecutor）据此跳过本回合出牌——玩家把架势打散，它得回头重新架。
    /// </summary>
    /// <returns>true = 本回合被打断（已回退，调用方应跳过出牌）</returns>
    public bool ConsumeStanceBroken()
    {
        if (!_stanceBroken) return false;

        _stanceBroken = false;
        if (_stanceIntentIndex >= 0 && data != null && data.intentLoop != null && data.intentLoop.Count > 0)
        {
            currentIntentIndex = Mathf.Clamp(_stanceIntentIndex, 0, data.intentLoop.Count - 1);
        }
        _stanceIntentIndex = -1;
        Debug.Log($"[姿态] {gameObject.name} 被打断 → 本回合不出手，大意图回退到下标 {currentIntentIndex} 重新释放");
        return true;
    }


    // -------- 行动顺序 / 移动路径（★2026-08-21 全局移动解算；★2026-08-22 预解算冻结路径） --------

    /// <summary>
    /// 全局行动顺序号（小 = 先动）。敌人回合不再各自为政，按此排序逐只执行。
    /// SpawnResolver 生成小队时赋值：先遇到（先生成）的小队 base 小、队内按 units 配置顺序 +1。
    /// 场景摆放的敌人保持默认 int.MaxValue（最后动，同序按 InstanceID 稳定排序）。
    /// </summary>
    public int TurnOrder { get; set; } = int.MaxValue;

    /// <summary>
    /// 移动进行中标志（★2026-08-22 语义收敛）：非 null = 敌人正在沿预解算路径移动。
    /// EnemyIntentVisuals 据此区分「移动中（只显示目的地虚影）」vs「移动结束（全隐藏）」。
    /// 列表内容（剩余路径）已不再用于绘图，仅作状态标记保留。
    /// </summary>
    public List<Vector2Int> CurrentMovePath { get; private set; }

    /// <summary>
    /// 本回合可用移动力预算 = 当前行动点 + 追击值（疾跑）。
    /// ★2026-08-19 用户确认：行动点 = data.moveRange 起步（回合开始恢复），断筋扣减会实时压低；
    /// 疾跑一次 +sprintValue（哥布林 3→4），成功打出非疾跑意图后 ResetSprint 归零（回 3）。
    /// 设计依据：v2 §3.2 / §4.3 —— 疾跑后下回合移动力增加追击值。
    /// </summary>
    public int MoveBudget => data != null ? currentActionPoints + sprintAccumulated : 0;

    /// <summary>
    /// ★2026-09-09 血条旁 AP 徽章显示值：按敌人当前活动状态返回对应 AP。
    /// 战斗态 / 警戒（红`!`即将进战）→ MoveBudget（战斗 AP + 疾跑）；
    /// 探索态搜索（黄`?`/白`?`）→ currentActionPoints（移动前已设为搜索步数）；
    /// 探索态巡逻/追击 → currentActionPoints（移动前已设为 patrolAP）。
    /// 探索态读 currentActionPoints（移动中逐格递减到 0），状态切换（如搜索→战斗）时
    /// LateUpdate 每帧重读本属性，立即刷新为战斗 AP，无需额外通知。
    /// </summary>
    public int DisplayActionPoints
    {
        get
        {
            bool battleCtx = (GameStateManager.Instance != null
                              && GameStateManager.Instance.CurrentState == GameState.Battle)
                             || IsAlerted;
            return battleCtx ? MoveBudget : currentActionPoints;
        }
    }

    // -------- 意图揭示（★2026-08-19 M6-4 新增） --------

    /// <summary>
    /// 本玩家回合已揭示的敌人意图（含已掷骰锁死的各小意图卡牌）。
    /// 玩家回合开始由 TurnManager 调用 <see cref="RevealIntent"/> 生成；null = 尚未揭示。
    /// </summary>
    private EnemyRevealedIntent _revealedIntent;

    /// <summary>当前已揭示意图（只读，供 EnemyIntentBadgeUI / EnemyIntentVisuals 读取）</summary>
    public EnemyRevealedIntent RevealedIntent => _revealedIntent;

    /// <summary>
    /// 脱战瞬间冻结的已揭示意图（含已掷骰，§11）。问号阶段 <see cref="RevealedIntent"/> 已冻结清空，
    /// 红`!`逼近落点（EnemyLandingPlanner）与「?→猛击5」悬停预览（EnemyIntentBadgeUI）从这里读。
    /// </summary>
    public EnemyRevealedIntent FrozenIntent => _frozenIntent;

    // -------- ★丢失目标「?」状态（2026-09-05 用户定稿）--------
    /// <summary>
    /// 丢失目标（脱战/追击搜查无果）：意图徽章显示灰色"?"（敌人在原地困惑寻找）。
    /// 持续到下一次巡逻阶段开始（敌人再动）或进战斗重新揭示意图。
    /// </summary>
    public bool ShowQuestionMark { get; private set; } = false;

    /// <summary>
    /// 进入「丢失目标」状态：清空残留的战斗意图（如"追击"），徽章显示"?"。
    /// 调用时机：① 战斗脱战（敌人移毕未见玩家）② 探索中追击/搜查移动后仍未发现玩家。
    /// </summary>
    public void SetLostTarget()
    {
        // ★2026-09-14 意图层级保护：战斗中（战斗意图）的单位不显示"?"——它在战斗里，没有"丢失目标"。
        if (IsBattleIntentActive) return;
        _revealedIntent = null; // 清掉战斗残留意图（"追击"等文字不再显示）
        ShowQuestionMark = true;
    }

    /// <summary>清除"?"（下一次巡逻阶段开始时统一调用）</summary>
    public void ClearQuestionMark()
    {
        ShowQuestionMark = false;
    }

    /// <summary>揭示代数（每次 RevealIntent +1，供 UI 检测「数值已更新」避免每帧重建文本）</summary>
    public int RevealGeneration { get; private set; } = 0;

    /// <summary>是否已死亡</summary>
    public bool IsDead { get; private set; } = false;

    /// <summary>
    /// 死亡瞬间的游戏状态（★2026-09-12：掉落归属的唯一判据 —— 灵魂/击杀记账都看它）。
    /// 不能在事件回调里现读 GameStateManager：战斗最后一击的胜利结算会把状态切回 Exploring，
    /// 同一次死亡事件链上的后续订阅方就会把战斗击杀误判成探索击杀 → 同一只怪发两个魂。
    /// 默认 Exploring = 枚举零值（只在「从未死亡」时可见，正常流程永远先被 Die 赋值）。
    /// </summary>
    public GameState StateAtDeath { get; private set; } = GameState.Exploring;

    // -------- 警戒态 v3 + 探索巡逻（探索系统 v2 §9.1 / D13/D13b，2026-09-05 重构）--------
    /// <summary>
    /// 是否处于警戒状态（感叹号）。看见玩家，或看见同队感叹号/正在打架的队友。
    /// 警戒中的敌人原地不动；下回合进入战斗（已在打的当场参战）。
    /// </summary>
    public bool IsAlerted { get; private set; } = false;

    /// <summary>警戒发起人：本人视野盖到玩家。只有发起人能把问号传给外队。</summary>
    public bool IsAlertOrigin { get; private set; }

    /// <summary>问号：外队看热闹，或同队落单正在靠近队友。</summary>
    public bool IsCurious { get; private set; }

    /// <summary>同队落单问号：下回合强制升感叹号。</summary>
    public bool PromoteToAlertNextTurn { get; set; }

    /// <summary>问号单位靠近的目标（外队发起人或同队感叹号/参战队友）。</summary>
    public EnemyController CuriousAnchor { get; private set; }

    /// <summary>
    /// 所属小队 ID（D14 参战范围：被攻击/触发警戒的敌人 + 其小队参战）。
    /// SpawnResolver 每次 Spawn 为整批成员注入同一值；场景手动摆放敌人 = -1（独立，无小队联动）。
    /// </summary>
    public int SquadId { get; set; } = -1;

    /// <summary>★2026-09-12 在本小队 units 配置里的下标（SpawnResolver 注入；-1 = 场景手摆/无小队）。</summary>
    public int UnitIndex { get; set; } = -1;

    /// <summary>所属路径巡逻组（有则闲时沿小队路径走，不再随机游走）。</summary>
    public SquadPatrolGroup PatrolGroup { get; set; }

    /// <summary>相对小队锚点的编队模板偏移（生成时按行进方向再旋转）。</summary>
    public Vector2Int PatrolFormationOffset { get; set; }

    /// <summary>巡逻出生点（普通巡逻在此半径内随机游走，D13b）</summary>
    public Vector2Int PatrolHomeCoord { get; private set; }

    // ------------------------------------------------------------------
    // ★点对点巡逻路线（D13b 扩展，2026-09-05 用户测试用例：哥布林 11_14 ↔ 21_14 往返）
    // 设置两个路点后启用：朝当前目标路点走 patrolAP 步/回合，到达后折返另一个路点（乒乓）。
    // 未设置（(0,0) 默认值或两点相同）→ 退回随机游走巡逻。
    // ------------------------------------------------------------------
    [Header("巡逻路线（可选：设置两个路点 = 点对点往返巡逻；不设 = 出生点随机游走）")]
    [Tooltip("巡逻路点 A（格坐标，如 11,14）")]
    public Vector2Int patrolPointA;
    [Tooltip("巡逻路点 B（格坐标，如 21,14）")]
    public Vector2Int patrolPointB;

    /// <summary>当前巡逻目标路点（true=B；往返折返）</summary>
    private bool _patrolHeadingToB = true;

    /// <summary>是否配置了有效巡逻路线</summary>
    public bool HasPatrolRoute => patrolPointA != patrolPointB && patrolPointA != Vector2Int.zero && patrolPointB != Vector2Int.zero;

    /// <summary>最后目击点（警戒时记录玩家位置；追击巡逻朝此移动）</summary>
    public Vector2Int LastSeenCoord { get; set; } = new Vector2Int(int.MinValue, int.MinValue);

    /// <summary>追击巡逻中（警戒解除（逃出视野）后转入：朝 LastSeenCoord 走 patrolAP 步，D13 结局B）</summary>
    public bool IsChasing { get; set; } = false;

    // -------- ★脱战六回合流程 · 问号阶段（2026-09-07 定稿：威胁预告与搜索 §3/§4/§10/§11）--------
    // 原「搜查」流程（BeginInvestigation）已删除：探索态攻击任何敌人一律走偷袭入口（§19-4），
    // 不存在"搜查中再被打"这一分支。

    /// <summary>脱战流程中的问号阶段（§3 六回合表）。None = 不在脱战流程里。</summary>
    public enum DisengagePhase { None, 黄搜索, 白归队, 白回巡逻 }

    /// <summary>当前问号阶段。</summary>
    public DisengagePhase SearchPhase { get; private set; } = DisengagePhase.None;

    /// <summary>黄`?`散开搜索中（脱战搜捕 / 陷阱搜索）。徽章画黄`?`。</summary>
    public bool IsSearching => SearchPhase == DisengagePhase.黄搜索;

    /// <summary>白`?`脱战休整中（归队 / 回巡逻）。徽章画白`?`——白`?`仅此状态有（§1）。</summary>
    public bool IsResting => SearchPhase == DisengagePhase.白归队 || SearchPhase == DisengagePhase.白回巡逻;

    /// <summary>
    /// 本回合待转黄`?`搜索：陷阱当回合整队红`!`冻结、放弃巡逻移动，**次**敌人回合才散开搜索（§7.1）。
    /// </summary>
    public bool PendingTrapSearch { get; private set; }

    /// <summary>进入脱战流程时记录的已损 HP（75%/25% 回血的计算基数，§10.3）。</summary>
    int _lostHPAtDisengage;

    /// <summary>本轮已回血量（保证 75% + 25% 合计恰好回满，不因取整重复回）。</summary>
    int _healedThisCycle;

    /// <summary>脱战瞬间冻结的大意图下标（§11 续接用；-1 = 无冻结可续）。</summary>
    int _frozenIntentIndex = -1;

    /// <summary>脱战瞬间冻结的已揭示意图（含已掷骰结果，续接时**不重掷**，§11）。</summary>
    EnemyRevealedIntent _frozenIntent;

    /// <summary>
    /// 被动遇袭发现者标记（§5）：探索态敌人回合移动落点看见玩家的**那一只**。
    /// 下一回合开始展现战斗意图时直接获得疾跑 1；同队经传导警戒者不额外获得。
    /// </summary>
    public bool PendingSurpriseSprint { get; private set; }

    /// <summary>
    /// 白`?`回巡逻阶段（回合5）归线途中：目标是巡逻折线上离自己最近的**垂足**，
    /// 不是出生点（§4b）。到点后恢复普通巡逻；随机游走的敌人没有折线，退化为回出生点。
    /// </summary>
    public bool IsReturningHome { get; private set; } = false;

    /// <summary>
    /// 白`?`归队阶段（回合4）的编队锚点 = 进入该阶段瞬间冻结的小队共享参照点
    /// （散开搜索的参照点，也就是「散开搜索的位置」，§4b）。独立敌人 = 自己的 <see cref="LastSeenCoord"/>。
    /// 冻结而不每回合现算：白`?`期间 <see cref="AlertPropagation"/> 仍可能改写 LastSeenCoord，
    /// 队形会跟着漂。
    /// </summary>
    public Vector2Int RegroupCoord { get; private set; } = new Vector2Int(int.MinValue, int.MinValue);

    /// <summary>
    /// 本轮警戒周期开始时自己站的格子 = 散开搜索「来时路」的起点（§12 主轴）。
    /// 进入黄`?`前的上一阶段（追击）一定是朝参照点**直着走**的，所以
    /// 「警戒起点队心 → 当前队心」就是队伍的来时路，其反方向 = 扇形主轴 d，来时路本身 = 后方 d+3（永不分配）。
    /// ★不能用「队心 → 参照点」当主轴：追击经常把整队**冲过**参照点，那时这个方向指向身后，
    /// 扇形会朝玩家逃跑的反方向展开。一个周期只写一次（<see cref="BecomeAlerted"/>），复原时清零。
    /// </summary>
    public Vector2Int AlertStartCoord { get; private set; } = new Vector2Int(int.MinValue, int.MinValue);

    /// <summary>
    /// 本回合开始时自己站的格子，由敌人回合驱动方在**任何移动之前**调用 <see cref="MarkTurnStart"/> 打上。
    /// 存在的唯一理由：`BeginDisengageSearch` 是在追击回合**结束**时才被调用的，那一刻坐标已经是追击后的了，
    /// 没法再倒推出「上一个阶段直着走」的起点——必须提前存一份。
    /// </summary>
    public Vector2Int TurnStartCoord { get; private set; } = new Vector2Int(int.MinValue, int.MinValue);

    /// <summary>敌人回合开始、任何移动之前打一次坐标快照。</summary>
    public void MarkTurnStart()
    {
        TurnStartCoord = CurrentCoord;
    }

    // ------------------------------------------------------------------
    // 脱战六回合流程：状态迁移（威胁预告与搜索 §3 / §10 / §11）
    // ------------------------------------------------------------------

    /// <summary>
    /// 一次意图循环（意图开始 → 复原）内散开搜寻已触发次数。BeginDisengageSearch 递增，FinishDisengage 清零。
    /// </summary>
    public int ScatterSearchCount { get; private set; }

    /// <summary>散开搜寻上限：小队读 SquadPatrolData.maxSearchCount（默认 2），独立敌人默认 2。</summary>
    public int GetMaxSearchCount()
    {
        return PatrolGroup != null ? PatrolGroup.MaxSearchCount : 2;
    }

    /// <summary>
    /// 回合3：脱战瞬间 → 黄`?`散开搜索。冻结意图（§11）+ 累积一次疾跑（§10.2：黄`?`搜捕回合也积攒）。
    /// 搜索参照点 = <see cref="LastSeenCoord"/>（玩家最后消失格）。
    /// </summary>
    public void BeginDisengageSearch()
    {
        if (IsDead) return;
        ScatterSearchCount++;

        // 冻结「来时路」起点：本回合 = 追击回合，回合开始时的坐标就是追击前的位置。
        // ★必须在这里覆盖而不是只靠 BecomeAlerted——战斗态脱战流程压根不经过 BecomeAlerted，
        // 不覆盖的话 AlertStartCoord 一直是空的，散开主轴就会退回「队心 → 参照点」那条错规则。
        if (TurnStartCoord.x != int.MinValue) AlertStartCoord = TurnStartCoord;

        FreezeIntent();
        SearchPhase = DisengagePhase.黄搜索;
        _phaseMoveDone = false;
        ShowQuestionMark = true;
        IsAlerted = false;
        ClearCurious();
        IsChasing = false;
        IsReturningHome = false;
        // ★2026-09-08 重开散开（§4 打断后再丢视野）：若本队还挂着白`?`回巡逻的临时归线，拆掉——
        // 无临时归线时是空操作（ReEngageFromSearch/FinishDisengage 同样无条件调用，幂等）。
        if (PatrolGroup != null) PatrolGroup.EndReturnRoute();
        _lostHPAtDisengage = Mathf.Max(0, MaxHP - currentHP);
        _healedThisCycle = 0;
        AddSprint();

        Debug.Log($"[搜索] 「{gameObject.name}」丢失目标 → 黄`?`散开搜索（参照 {LastSeenCoord}，已损 {_lostHPAtDisengage}，疾跑 {sprintAccumulated}）");
    }

    /// <summary>
    /// 陷阱响应（§7.1 / §7.5）：非玩家造成的直接伤害 → 整队红`!`、放弃本回合巡逻移动、原地警戒。
    /// 陷阱格顶替 <see cref="LastSeenCoord"/> 作次回合搜索主方向；白`?`休整中踩陷阱 → 回血中断。
    /// </summary>
    public void BeginTrapAlert(Vector2Int trapCoord)
    {
        if (IsDead) return;

        InterruptHeal();                    // 剩余 25% 不回（§10.3 中断）
        SearchPhase = DisengagePhase.None;  // 黄`?`/白`?` 一律按探索态规则重来一遍
        _phaseMoveDone = false;
        LastSeenCoord = trapCoord;
        PendingTrapSearch = true;
        BecomeAlerted(isOrigin: false);

        Debug.Log($"[陷阱] 「{gameObject.name}」踩中陷阱 {trapCoord} → 整队红`!`冻结本回合，次回合转黄`?`搜索");
    }

    /// <summary>回合 N+1：把陷阱红`!`转成黄`?`散开搜索（§7.1）。参照点已是陷阱格。</summary>
    public void ConvertTrapAlertToSearch()
    {
        if (IsDead || !PendingTrapSearch) return;

        PendingTrapSearch = false;
        SearchPhase = DisengagePhase.黄搜索;
        _phaseMoveDone = false;
        ShowQuestionMark = true;
        IsAlerted = false;
        _lostHPAtDisengage = Mathf.Max(0, MaxHP - currentHP);
        _healedThisCycle = 0;
        AddSprint();
    }

    /// <summary>
    /// 回合4：搜索无果 → 白`?`归队，回**已损 75%**（§3 / §10.3）。
    /// 白`?`阶段保留疾跑但**不累积**（§10.2）。
    /// ★归队 = 在散开搜索的位置**原地重整**成巡逻阵型，不是走回小队锚点/出生点（§4b）。
    /// 编队锚点在此刻冻结，避免白`?`期间 AlertPropagation 改写 LastSeenCoord 导致队形漂移。
    /// </summary>
    public void AdvanceToRegroup()
    {
        if (IsDead || SearchPhase != DisengagePhase.黄搜索) return;

        SearchPhase = DisengagePhase.白归队;
        RegroupCoord = PatrolGroup != null
            ? SearchScatterPlanner.SquadReference(PatrolGroup.Members)
            : LastSeenCoord;
        if (RegroupCoord.x == int.MinValue) RegroupCoord = CurrentCoord;
        HealLostFraction(0.75f);
        Debug.Log($"[搜索] 「{gameObject.name}」搜索无果 → 白`?`原地重整（锚点 {HexCoord.FormatCell(RegroupCoord)}，回已损 75%，HP {currentHP}/{MaxHP}）");
    }

    /// <summary>
    /// 散开搜寻次数用尽 → 跳过散开，直接放弃回家（2026-09-08 用户定稿：第三次丢视野 = 放弃）。
    /// 归一化到黄`?`搜索态后复用 AdvanceToRegroup：白`?`原地重整 → 回巡逻 → 复原，回血照常（§10.3）。
    /// </summary>
    public void GiveUpSearch()
    {
        if (IsDead) return;

        SearchPhase = DisengagePhase.黄搜索;
        _phaseMoveDone = false;
        ShowQuestionMark = true;
        IsAlerted = false;
        IsChasing = false;
        IsReturningHome = false;
        ClearCurious();
        AdvanceToRegroup();
    }

    /// <summary>
    /// 回合5：白`?`回巡逻路线，回**剩余 25%**（§3 / §10.3，合计回满）。
    /// ★小队：装一条 <c>[当前队心, 巡逻折线垂足]</c> 的临时两点路线，本回合整队移动交给巡逻代码
    /// （<see cref="SquadPatrolGroup.BeginReturnRoute"/>）——它自己的头尾翻转与阵型旋转才会生效，
    /// 不用再多花一回合原地掉头。非小队沿用 <see cref="PatrolTurn"/> 里的单人归线兜底。
    /// </summary>
    public void AdvanceToReturnPatrol()
    {
        if (IsDead || SearchPhase != DisengagePhase.白归队) return;

        SearchPhase = DisengagePhase.白回巡逻;
        IsReturningHome = true;
        if (PatrolGroup != null) PatrolGroup.BeginReturnRoute();
        HealLostFraction(1f);
        Debug.Log($"[搜索] 「{gameObject.name}」白`?`回巡逻（回剩余 25%，HP {currentHP}/{MaxHP}）");
    }

    /// <summary>
    /// 回合6：复原（§3）——白`?`消失、疾跑清零、意图列表重置、偷袭资格恢复（§6.2）。
    /// 陷阱流程走完全程同样调这里。
    /// </summary>
    public void FinishDisengage()
    {
        SearchPhase = DisengagePhase.None;
        PendingTrapSearch = false;
        PendingSurpriseSprint = false;
        _lostHPAtDisengage = 0;
        _healedThisCycle = 0;
        _frozenIntentIndex = -1;
        _frozenIntent = null;
        ShowQuestionMark = false;
        IsAlerted = false;
        IsAlertOrigin = false;
        ClearCurious();
        IsChasing = false;
        if (PatrolGroup != null) PatrolGroup.EndReturnRoute();   // 拆掉回合5 的临时两点路线，还原真实巡逻路点
        IsReturningHome = false;
        RegroupCoord = new Vector2Int(int.MinValue, int.MinValue);
        AlertStartCoord = new Vector2Int(int.MinValue, int.MinValue);
        LastSeenCoord = new Vector2Int(int.MinValue, int.MinValue);
        ResetSprint();
        SquadAlertCycle.Clear(this);
        ScatterSearchCount = 0;

        Debug.Log($"[搜索] 「{gameObject.name}」复原：白`?`消失、疾跑清零、意图重置、偷袭资格恢复");
    }

    /// <summary>
    /// 重新进战（任何入口：视野 / 受击 / 白`?`偷袭入口）：中断脱战流程，
    /// 从冻结处**续接意图不重掷**（§11），已积攒疾跑全额带入战斗（§10.2）。
    /// </summary>
    public void ReEngageFromSearch()
    {
        if (IsDead) return;

        SearchPhase = DisengagePhase.None;
        PendingTrapSearch = false;
        PendingSurpriseSprint = false;
        _phaseMoveDone = false;
        _lostHPAtDisengage = 0;   // 回血中断（§10.3）
        _healedThisCycle = 0;
        if (PatrolGroup != null) PatrolGroup.EndReturnRoute();   // 归线中断 → 还原真实巡逻路点
        ResumeFrozenIntent();
    }

    /// <summary>
    /// 标记被动遇袭发现者（§5）：探索态敌人回合移动落点看见玩家的那一只。
    /// 同队经传导警戒者**不**调用本方法 → 不额外获得疾跑 1。
    /// </summary>
    public void MarkPassiveEncounterSpotter(Vector2Int playerCoord)
    {
        if (IsDead) return;
        BecomeAlerted(isOrigin: true);
        LastSeenCoord = playerCoord;
        PendingSurpriseSprint = true;
    }

    /// <summary>
    /// 结算被动遇袭的疾跑 1（§5：下回合开始展现战斗意图时直接获得）。
    /// 返回是否真的结算过，供调用方清标记。
    /// </summary>
    public bool ConsumeSurpriseSprint()
    {
        if (!PendingSurpriseSprint) return false;
        PendingSurpriseSprint = false;
        if (IsDead || data == null) return false;
        sprintPending = Mathf.Min(sprintPending + 1, data.sprintMax);   // ★2026-09-09 待生效（下敌回合折入）
        Debug.Log($"[搜索] 「{gameObject.name}」被动遇袭发现者 → 直接获得疾跑 1（待生效 {sprintPending}）");
        return true;
    }

    /// <summary>
    /// 当前问号阶段的移动是否已执行完毕。回合开始时由 <see cref="AdvanceDisengagePhase"/> 消费：
    /// 走完一回合才推进阶段，保证回血发生在「该阶段的敌人回合」内（§3 六回合表）。
    /// </summary>
    bool _phaseMoveDone;

    /// <summary>本回合该敌人已完成问号阶段的移动（散开搜索 / 归队 / 回巡逻），由驱动方在移动后调用。</summary>
    public void MarkPhaseMoveDone()
    {
        // ★2026-09-08 传导冻结：红`!`冻结期间没执行问号移动，不标记——否则下回合会误推进阶段/误回血
        if (SearchPhase != DisengagePhase.None && !IsAlerted) _phaseMoveDone = true;
    }

    /// <summary>
    /// 回合开始推进脱战阶段（战斗态与探索态共用）：
    /// 黄`?`搜索走完 → 白`?`归队（回已损 75%）；白`?`归队走完 → 白`?`回巡逻（回剩余 25%）；
    /// 白`?`回巡逻走完 → 复原（§3 回合4/5/6）。上一阶段没走完则不动。
    /// </summary>
    public void AdvanceDisengagePhase()
    {
        if (IsDead || !_phaseMoveDone) return;
        // ★2026-09-08 传导冻结：红`!`的问号单位本回合原地冻结，
        // 阶段推进等它切换战斗意图时由 ReEngageFromSearch 一并清掉（防误推进/误回血）。
        if (IsAlerted && SearchPhase != DisengagePhase.None) return;
        _phaseMoveDone = false;

        switch (SearchPhase)
        {
            case DisengagePhase.黄搜索: AdvanceToRegroup(); break;
            case DisengagePhase.白归队: AdvanceToReturnPatrol(); break;
            case DisengagePhase.白回巡逻: FinishDisengage(); break;
        }
    }

    /// <summary>回血中断（受击 / 进战 / 踩陷阱）：剩余部分不回（§10.3）。</summary>
    void InterruptHeal()
    {
        _lostHPAtDisengage = 0;
        _healedThisCycle = 0;
    }

    /// <summary>按累计比例回血：0.75 → 回已损 75%；1.0 → 补足剩余 25%（合计恰好回满）。</summary>
    void HealLostFraction(float fraction)
    {
        if (IsDead || _lostHPAtDisengage <= 0) return;

        int target = Mathf.RoundToInt(_lostHPAtDisengage * fraction);
        int amount = target - _healedThisCycle;
        if (amount <= 0) return;

        _healedThisCycle = target;
        Heal(amount);
    }

    /// <summary>冻结当前意图（脱战瞬间，§11）：黄`?`/白`?`期间意图循环暂停、头顶不显示战斗意图。</summary>
    void FreezeIntent()
    {
        // ★2026-09-08 幂等：问号阶段红`!`传导者再次散开时意图已冻结，不覆写——
        // 否则 _frozenIntent 被 null 清空，重新进战无法「不重掷续接」（§11）。
        if (_frozenIntent == null)
        {
            _frozenIntent = _revealedIntent;
            _frozenIntentIndex = currentIntentIndex;
        }
        _revealedIntent = null;
    }

    /// <summary>
    /// 续接冻结的意图（重新进战，§11）：**不重掷骰**。
    /// 无冻结可续 = 全新意图循环（陷阱流程首次进战，§11 末条）。
    /// </summary>
    void ResumeFrozenIntent()
    {
        if (_frozenIntent == null && _frozenIntentIndex < 0) return;

        if (_frozenIntentIndex >= 0) currentIntentIndex = _frozenIntentIndex;
        if (_frozenIntent != null)
        {
            _revealedIntent = _frozenIntent;
            RevealGeneration++;
            IntentConsumed = false;
        }
        _frozenIntent = null;
        _frozenIntentIndex = -1;
    }

    /// <summary>
    /// 白`?`归队（回合4）的移动目标（§4b）。**首要目的是聚到一起**，队形只是顺带：
    /// 离参照点还有一回合走不到 → 直奔参照点（保证一定在靠拢，不会站着不动）；
    /// 已经够近 → 才去自己的巡逻阵型槽位，把队形稍微理一理。
    /// </summary>
    /// <remarks>
    /// ★不能一律瞄阵型槽位：散开后成员离参照点 3-5 格，搜索步距只有 2-3，一回合根本到不了，
    /// 每个人就停在自己那条射线的半路上，看着还是一盘散沙（用户实测 2026-09-08「整理的很乱」）。
    /// 先收拢，正式列队交给回合5 在巡逻路径上做。
    /// 执行（<see cref="PatrolTurn"/>）与红`?`预告（<see cref="ThreatPredictor"/>）共用此方法——预览 = 执行。
    /// </remarks>
    public Vector2Int GetRegroupTarget()
    {
        Vector2Int regroup = RegroupCoord.x != int.MinValue ? RegroupCoord : LastSeenCoord;
        if (regroup.x == int.MinValue) regroup = CurrentCoord;

        int ap = Mathf.Max(1, SearchScatterPlanner.GetSearchAP(this));
        if (CardExecutor.HexDistance(CurrentCoord, regroup) > ap) return regroup;

        if (PatrolGroup != null && PatrolGroup.TryGetRegroupSlot(this, regroup, out Vector2Int slot)) return slot;
        return regroup;
    }

    /// <summary>
    /// 白`?`回巡逻（回合5）的移动目标（§4b）：巡逻折线上的**垂足** + 绕垂足的巡逻阵型槽位。
    /// 小队 = 路点折线；点对点路线 = A—B 单段；随机游走没有折线 → 退化为出生点。
    /// </summary>
    /// <remarks>
    /// ★垂足按**队心**求、全队共用一个归线点：逐人投影会把成员撒在折线的不同位置上，
    /// 归线后根本不成队形，回合6 复原也就接不回原来的巡逻阵型
    /// （用户定稿 2026-09-08「回到巡逻路径并且尽可能的重整队形，确保第三回合可以恢复原来的队形」）。
    /// 共用垂足后再套 <see cref="SquadPatrolGroup.TryGetRegroupSlot"/>：朝向 = 垂足→下一路点 = 路线前进方向，
    /// 槽位 = 各人的巡逻阵型偏移，落地即成队。
    /// 执行（<see cref="PatrolTurn"/>）与红`?`预告（<see cref="ThreatPredictor"/>）共用此方法——预览 = 执行。
    /// </remarks>
    /// <param name="resumeIndex">
    /// 归线后巡逻续接的路点下标；<c>-1</c> = 没有折线可续（随机游走），调用方不要改巡逻状态。
    /// </param>
    public Vector2Int GetReturnTarget(out int resumeIndex)
    {
        resumeIndex = -1;

        if (PatrolGroup != null)
        {
            Vector2Int from = SearchScatterPlanner.Centroid(PatrolGroup.Members);
            if (PatrolGroup.TryGetRouteProjection(from, out Vector2Int foot, out int nextWp))
            {
                resumeIndex = nextWp;
                return PatrolGroup.TryGetRegroupSlot(this, foot, out Vector2Int slot) ? slot : foot;
            }
        }

        if (HasPatrolRoute)
        {
            TerrainManager terrain = FindObjectOfType<TerrainManager>();
            if (HexCoord.TrySegmentFoot(CurrentCoord, patrolPointA, patrolPointB,
                    cell => terrain == null || terrain.IsPassable(cell), out Vector2Int segFoot))
            {
                return segFoot;
            }
        }

        return PatrolHomeCoord;
    }

    /// <summary>记录巡逻出生点（MoveToCoord 落位后由 SpawnResolver/自检调用）</summary>
    public void SetPatrolHome()
    {
        PatrolHomeCoord = CurrentCoord;
    }

    /// <summary>
    /// ★2026-09-14 意图层级（用户定稿：<b>战斗 &gt; 红`!` &gt; 问号</b>）——高级意图不被低级意图传导覆盖。
    /// 3 = 战斗意图（已参战且不在脱战搜索阶段）、2 = 红`!`（警戒）、1 = 问号（好奇/搜索/丢失目标）、0 = 无。
    /// 「正在战斗」的判据与徽章显示同源（EnemyIntentBadgeUI 的 IsFighting + SearchPhase 门控），
    /// 保证「显示什么」与「能被写什么」一致。
    /// </summary>
    public int IntentPriority
    {
        get
        {
            if (IsDead) return -1;
            if (IsBattleIntentActive) return 3;
            if (IsAlerted) return 2;
            if (IsCurious || ShowQuestionMark || SearchPhase != DisengagePhase.None) return 1;
            return 0;
        }
    }

    /// <summary>
    /// 是否处于「战斗意图」：已参战（BattleResultHandler 参与者）且不在脱战搜索阶段。
    /// 参战者若进入黄`?`/白`?`脱战搜索，按设计显示搜索阶段徽章——那不算战斗意图，可被正常改写。
    /// </summary>
    public bool IsBattleIntentActive
    {
        get
        {
            if (IsDead) return false;
            if (SearchPhase != DisengagePhase.None) return false;
            return AlertPropagation.IsFighting(this);
        }
    }

    /// <summary>
    /// 设置/清除警戒状态（§9.1.1）。
    /// ★2026-09-05 用户需求：不单独建「!」标记——由 EnemyIntentBadgeUI 复用意图徽章画布显示红色"!"
    ///（本方法只改状态，显示交给徽章的 LateUpdate 轮询）。
    /// ★2026-09-14：置位时受意图层级保护（战斗意图中的单位不回退到红`!`）。
    /// </summary>
    public void SetAlerted(bool on)
    {
        if (on && IsBattleIntentActive) return;
        IsAlerted = on;
        if (!on) return;
        IsCurious = false;
        ShowQuestionMark = false;
    }

    /// <summary>升为感叹号。发起人仅在本人看见玩家时标记。</summary>
    public void BecomeAlerted(bool isOrigin)
    {
        if (IsDead) return;
        // ★2026-09-14 意图层级不变量（用户定稿：战斗 > 红`!` > 问号）：
        //   已在「战斗意图」中的单位不接受任何低级意图写入——否则战斗中的怪会掉回红`!`/问号。
        if (IsBattleIntentActive) return;
        IsAlerted = true;
        IsCurious = false;
        ShowQuestionMark = false;
        if (isOrigin) IsAlertOrigin = true;
        IsChasing = false;
        // ★2026-09-08 修复：红`!`逼近落点预览会被残留的「意图已消费」flag 挡住（问号阶段
        // 敌人从 T2 最后一次行动后 IntentConsumed 一直为 true，脱战/传导都不重置）→ 进红`!`即复位。
        IntentConsumed = false;
        // 来时路起点：一个周期只记一次。传导 / 重复警戒都不能覆盖，否则位移被抹平成 0、主轴退化。
        if (AlertStartCoord.x == int.MinValue) AlertStartCoord = CurrentCoord;
    }

    public void BecomeCurious(EnemyController anchor, bool promoteNextTurn)
    {
        if (IsDead || IsAlerted) return;
        // ★2026-09-14 意图层级保护：战斗中（战斗意图）的单位不接受问号级写入——
        //   实锤症状：战斗中同队队友被"围观"逻辑写成问号，战斗意图被低级意图覆盖。
        if (IsBattleIntentActive) return;
        IsCurious = true;
        ShowQuestionMark = true;
        CuriousAnchor = anchor;
        if (anchor != null) LastSeenCoord = anchor.CurrentCoord;
        if (promoteNextTurn) PromoteToAlertNextTurn = true;
    }

    public void ClearCurious()
    {
        IsCurious = false;
        PromoteToAlertNextTurn = false;
        CuriousAnchor = null;
        ShowQuestionMark = false;
    }

    /// <summary>参战后头顶改显示战斗意图，保留发起人标记供外队问号判定。</summary>
    public void EnterCombatDisplay()
    {
        IsAlerted = false;
        IsCurious = false;
        ShowQuestionMark = false;
        PromoteToAlertNextTurn = false;

        // ★意图继承（威胁预告与搜索 §11）：从脱战冻结处续接，**不重掷骰**；
        // 无冻结可续（纯陷阱流首次进战）= 全新意图循环，正常揭示一次。
        ReEngageFromSearch();
        if (_revealedIntent == null) RevealIntent();
    }

    /// <summary>
    /// ★受击 = 被看见（威胁预告与搜索 §4 / §5）：黄`?`/白`?`阶段的敌人挨打
    /// 立即中断脱战流程、切回战斗意图（<see cref="EnterCombatDisplay"/> 内部从冻结意图续接、**不重掷**），
    /// 同队问号阶段队友按视野连锁传导（红`!`，见 <see cref="ReEngageWithSquad"/>）。
    /// 常态敌人（不在问号阶段）直接返回——探索态主动攻击由偷袭入口处理（PlayCardSystem）。
    /// </summary>
    public void ReEngageOnHit()
    {
        if (IsDead) return;
        if (SearchPhase == DisengagePhase.None && !PendingTrapSearch) return;

        RefreshLastSeenToPlayer();
        Debug.Log($"[搜索] 「{gameObject.name}」问号阶段受击 = 被看见 → 立即战斗意图 + 同队视野连锁传导（§4）");
        ReEngageWithSquad();
    }

    /// <summary>
    /// ★问号阶段「看见玩家」的重进战入口（§4：回合3/4 任一参战者重新看见玩家 → 战斗意图 + 传导，
    /// 脱战流程中断，回到回合2 节奏）。非问号阶段直接返回（常态战斗意图者本来就该继续作战）。
    /// 由敌方回合起点（<see cref="EnemyTurnExecutor.Run"/>）、脱战判定（<see cref="TurnManager"/>）
    /// 与玩家移动落点（TurnManager.OnMoveEnded，★2026-09-08 补：玩家主动走进视野「立即」生效）三处调用。
    /// </summary>
    public void ReEngageOnSight()
    {
        if (IsDead) return;
        if (SearchPhase == DisengagePhase.None && !PendingTrapSearch) return;

        RefreshLastSeenToPlayer();
        Debug.Log($"[搜索] 「{gameObject.name}」问号阶段看见玩家 → 立即战斗意图 + 同队视野连锁传导（§4）");
        ReEngageWithSquad();
    }

    /// <summary>重新看见玩家 → 刷新最后目击点（§12 散开参照点按最新目击算，不再朝旧位置散开）。</summary>
    void RefreshLastSeenToPlayer()
    {
        HexMover player = FindObjectOfType<HexMover>();
        if (player != null) LastSeenCoord = player.CurrentCoord;
    }

    /// <summary>
    /// ★2026-09-08 用户实测修正：不再无条件整队切战斗意图——视野之外的同队单位也被传导了
    /// （用户实测「黄`?`阶段接敌警戒传导给了视野之外的单位」）。改为与探索态
    /// <see cref="AlertPropagation.Refresh"/> 同口径的**视野连锁**（§4/§5 两段式）：
    ///   发起者（看见玩家/受击）→ 立即战斗意图（本方法开头已 EnterCombatDisplay）；
    ///   同队问号单位看得见任一已接敌队友（战斗意图/红`!`）→ 红`!`（本回合原地冻结，
    ///     下回合由 TurnManager.RevealAllEnemyIntents 从冻结处切战斗意图）；
    ///   看不见 → 保持问号（黄`?`合流），不传导。
    /// </summary>
    void ReEngageWithSquad()
    {
        EnterCombatDisplay();

        // 传导源 = 本敌（已战斗意图）+ 同队已红`!`/已战斗意图者（与 Refresh 连锁口径一致）
        var sources = new List<EnemyController> { this };
        foreach (EnemyController mate in AlertPropagation.LivingEnemies())
        {
            if (mate == this || mate.IsDead) continue;
            if (!AlertPropagation.SameSquad(this, mate)) continue;
            if (mate.IsAlerted || AlertPropagation.IsFighting(mate)) sources.Add(mate);
        }

        bool changed = true;
        int guard = 0;
        while (changed && guard++ < 32)
        {
            changed = false;
            foreach (EnemyController mate in AlertPropagation.LivingEnemies())
            {
                if (mate == this || mate.IsDead) continue;
                if (mate.SearchPhase == DisengagePhase.None && !mate.PendingTrapSearch) continue;
                if (mate.IsAlerted) continue;
                if (!AlertPropagation.SameSquad(this, mate)) continue;

                EnemyController seenSource = null;
                foreach (EnemyController src in sources)
                {
                    if (AlertPropagation.Sees(mate, src)) { seenSource = src; break; }
                }
                if (seenSource == null) continue;

                mate.BecomeAlerted(isOrigin: false);
                if (seenSource.LastSeenCoord.x != int.MinValue) mate.LastSeenCoord = seenSource.LastSeenCoord;
                sources.Add(mate);
                changed = true;
            }
        }
    }

    public void ClearAlertOrigin()
    {
        IsAlertOrigin = false;
    }

    public void ResetSearchStatesPublic()
    {
        ResetSearchStates();
    }

    /// <summary>场上是否存在警戒中的敌人（探索回合结束判定三结局，D13）</summary>
    public static bool AnyAlertedEnemy()
    {
        // ★2026-09-16 性能二批：改走占位表注册表（原 FindObjectsOfType 全场景扫，每回合结束都调）
        foreach (EnemyController e in UnitOccupancy.LivingEnemies)
        {
            if (e != null && !e.IsDead && e.IsAlerted) return true;
        }
        return false;
    }

    /// <summary>
    /// 清除全场警戒状态（进战斗时统一调用：警戒标记让位于意图徽章）。
    /// ★2026-09-05 同时重置探索期附属状态（搜查/追击/返程）——战斗中这些移动逻辑不再生效。
    /// </summary>
    public static void ClearAllAlerted()
    {
        foreach (EnemyController e in FindObjectsOfType<EnemyController>())
        {
            if (e == null) continue;
            if (e.IsAlerted) e.SetAlerted(false);
            e.IsChasing = false;
            e.ResetSearchStates();
            e.ClearCurious();
            e.ClearAlertOrigin();
            e.ClearQuestionMark();
        }
    }

    /// <summary>重置脱战/搜索状态（进战斗时由 ClearAllAlerted 统一调用）。回血按 §10.3 中断。</summary>
    private void ResetSearchStates()
    {
        SearchPhase = DisengagePhase.None;
        PendingTrapSearch = false;
        PendingSurpriseSprint = false;
        _phaseMoveDone = false;
        IsReturningHome = false;
        InterruptHeal();
    }

    /// <summary>
    /// ★探索态巡逻回合（D13b）：本敌人的一次巡逻移动（协程，ExplorationTurnManager 依次驱动）。
    /// - 警戒中 → 原地不动（等玩家反应）
    /// - 追击巡逻（IsChasing）→ 朝 LastSeenCoord 走 patrolAP 步（A* 截断）；到达目击点 → 停止追击原地待命
    /// - 普通巡逻 → 出生点 patrolRadius 半径内随机游走 patrolAP 步
    /// 移动落点是否覆盖玩家（被动发现/直接进战斗）由调用方（PatrolPhase）在巡逻后检测。
    /// 优先级：追击巡逻 > 路线巡逻（patrolPointA/B 点对点往返）> 随机游走。
    /// </summary>
    public IEnumerator PatrolTurn()
    {
        if (IsDead || data == null) yield break;

        // ★黄`?`散开搜索：整队扇形槽位必须由 SearchScatterPlanner 统一解算（槽位互斥 + leash 裁剪），
        // 各走各的会撞槽位，所以这里直接让出，由 ExplorationTurnManager.PatrolPhase 整批驱动。
        if (IsSearching) yield break;

        // ★白`?`归队（回合4）：在**散开搜索的位置原地重整**成巡逻阵型（§4b）。
        // 编队锚点 = AdvanceToRegroup 冻结的 RegroupCoord（散开参照点），槽位 = 巡逻阵型 TemplateOffset。
        // 不再走回小队锚点/出生点——那会让敌人原路返回接敌地点（用户实测「有点笨」）。
        if (SearchPhase == DisengagePhase.白归队)
        {
            Vector2Int regroup = GetRegroupTarget();
            if (CurrentCoord != regroup)
            {
                List<Vector2Int> back = FindPatrolPath(CurrentCoord, regroup);
                if (back != null && back.Count > 1)
                {
                    int searchAP = Mathf.Max(1, SearchScatterPlanner.GetSearchAP(this));
                    int steps = Mathf.Min(searchAP, back.Count - 1);
                    yield return MoveToCoordSmooth(back[steps], back.GetRange(0, steps + 1));
                }
            }
            yield break;
        }

        if (IsCurious)
        {
            Vector2Int dest = CuriousAnchor != null && !CuriousAnchor.IsDead
                ? CuriousAnchor.CurrentCoord
                : LastSeenCoord;
            if (dest.x != int.MinValue && CurrentCoord != dest)
            {
                List<Vector2Int> curiousPath = FindPatrolPath(CurrentCoord, dest);
                if (curiousPath != null && curiousPath.Count > 1)
                {
                    int steps = Mathf.Min(Mathf.Max(data.patrolAP, 1), curiousPath.Count - 1);
                    yield return MoveToCoordSmooth(curiousPath[steps], curiousPath.GetRange(0, steps + 1));
                }
            }
            yield break;
        }

        if (IsAlerted) yield break; // 警戒中（红`!`）：原地不动

        // ★归线中（白`?`回巡逻 / 回合5）：走到巡逻折线上离自己最近的**垂足**（§4b），不是出生点。
        // 小队 = 路点折线；点对点路线 = A—B 单段；随机游走没有折线 → 退化为回出生点。
        // leash 在此不生效：它是在回家，不是在搜索。回合5 只有一回合，走不到垂足也照旧交回巡逻，
        // 回合6 复原后按新位置重新编队（不强制走完全程）。
        if (IsReturningHome)
        {
            // ★小队装了临时两点路线 → 本回合整队移动由 SquadPatrolGroup.ExecutePatrolTurn 驱动
            //   （它自己的头尾翻转 + 阵型旋转才会生效）。这里再走一遍单人归线就是重复驱动。
            //   IsReturningHome 由回合6 的 FinishDisengage 统一清掉，不在这里清。
            if (PatrolGroup != null && PatrolGroup.IsOnReturnRoute) yield break;

            Vector2Int dest = GetReturnTarget(out int resumeIndex);

            if (CurrentCoord != dest)
            {
                List<Vector2Int> home = FindPatrolPath(CurrentCoord, dest);
                if (home != null && home.Count > 1)
                {
                    int steps = Mathf.Min(Mathf.Max(data.patrolAP, 1), home.Count - 1);
                    yield return MoveToCoordSmooth(home[steps], home.GetRange(0, steps + 1));
                }
            }

            if (resumeIndex >= 0) PatrolGroup.ResumeRouteAt(dest, resumeIndex);
            IsReturningHome = false;
            yield break;
        }

        if (IsChasing)
        {
            // 追击巡逻：朝最后目击点走 patrolAP 步（发现异常未确认目标，非战斗全力追击）
            if (CardExecutor.HexDistance(CurrentCoord, LastSeenCoord) <= 1)
            {
                // 已到目击点仍未发现玩家 → 停止追击，原地待命（Demo 不做失去兴趣回巢）
                IsChasing = false;
                yield break;
            }

            List<Vector2Int> path = FindPatrolPath(CurrentCoord, LastSeenCoord);
            if (path == null || path.Count <= 1) { IsChasing = false; yield break; }

            // 截断到 patrolAP 步
            int steps = Mathf.Min(data.patrolAP, path.Count - 1);
            Vector2Int target = path[steps];
            yield return MoveToCoordSmooth(target, path.GetRange(0, steps + 1));

            // 到达目击点 → 结束追击状态
            if (CurrentCoord == LastSeenCoord) IsChasing = false;
        }
        else if (PatrolGroup != null)
        {
            yield break;
        }
        else if (HasPatrolRoute)
        {
            // ★路线巡逻：朝当前目标路点走 patrolAP 步，到达后折返（乒乓）
            Vector2Int destination = _patrolHeadingToB ? patrolPointB : patrolPointA;
            if (CurrentCoord == destination)
            {
                // 已在目标路点上 → 折返，本回合朝另一个路点走
                _patrolHeadingToB = !_patrolHeadingToB;
                destination = _patrolHeadingToB ? patrolPointB : patrolPointA;
            }

            List<Vector2Int> route = FindPatrolPath(CurrentCoord, destination);
            if (route == null || route.Count <= 1) yield break; // 寻路失败：本回合原地

            int routeSteps = Mathf.Min(data.patrolAP, route.Count - 1);
            Vector2Int routeTarget = route[routeSteps];
            yield return MoveToCoordSmooth(routeTarget, route.GetRange(0, routeSteps + 1));

            // 到达目标路点 → 记住折返方向（下回合生效）
            if (CurrentCoord == patrolPointB) _patrolHeadingToB = false;
            else if (CurrentCoord == patrolPointA) _patrolHeadingToB = true;
        }
        else
        {
            // 普通巡逻：patrolRadius 半径内随机游走 patrolAP 步
            for (int i = 0; i < data.patrolAP; i++)
            {
                Vector2Int next = RandomPatrolNeighbor();
                if (next == CurrentCoord) break; // 没有可走的相邻格
                List<Vector2Int> step = FindPatrolPath(CurrentCoord, next);
                if (step == null || step.Count <= 1) break;
                yield return MoveToCoordSmooth(next, step);
            }
        }
    }

    /// <summary>巡逻用 A* 寻路（终点可达即可，允许占位豁免由寻路器内部处理）</summary>
    public List<Vector2Int> FindPatrolPath(Vector2Int start, Vector2Int target)
    {
        HexGridLayout grid = FindObjectOfType<HexGridLayout>();
        if (grid == null) return null;
        return new AStarPathfinding(grid).FindPath(start, target, allowOccupiedTarget: true, enemyRequester: this);
    }

    /// <summary>
    /// 普通巡逻随机步：从相邻格中随机挑一个（界内 + 不出出生点半径 + 不与其他单位重叠），
    /// 挑不到（被围死/半径满）返回当前格（原地）。
    /// </summary>
    private Vector2Int RandomPatrolNeighbor()
    {
        List<Vector2Int> candidates = new List<Vector2Int>();
        HexGridLayout grid = FindObjectOfType<HexGridLayout>();
        TerrainManager terrain = FindObjectOfType<TerrainManager>();
        foreach (Vector2Int n in MoveAIController.GetNeighbors(CurrentCoord))
        {
            // 界内 + 地形可通行
            if (grid != null && (n.x < 0 || n.y < 0 || n.x >= grid.gridSize.x || n.y >= grid.gridSize.y)) continue;
            if (terrain != null && !terrain.IsPassable(n)) continue;
            // 不游出巡逻半径
            if (CardExecutor.HexDistance(n, PatrolHomeCoord) > data.patrolRadius) continue;
            // 不与其他单位重叠（真实场景扫描：玩家 + 其他敌人）
            if (UnitOccupancy.PatrolLandingClaims.IsActive
                ? !UnitOccupancy.PatrolLandingClaims.CanStop(n)
                : UnitOccupancy.IsOccupied(n)) continue;
            candidates.Add(n);
        }
        if (candidates.Count == 0) return CurrentCoord;
        return candidates[UnityEngine.Random.Range(0, candidates.Count)];
    }

    // -------- 事件 --------
    /// <summary>
    /// 敌人死亡事件。参数：本控制器引用（供 M7 战利品系统订阅）
    /// </summary>
    public event Action<EnemyController> OnEnemyDied;

    /// <summary>全场死亡广播，供 BattleResultHandler 单点订阅。</summary>
    public static event Action<EnemyController> EnemyDied;

    /// <summary>
    /// 敌人受伤事件。参数：(当前 HP, 实际造成伤害, 原始伤害)
    /// 供 EnemyHPBar / 浮动伤害数字 UI 订阅
    /// </summary>
    public event Action<int, int, int> OnHPChanged;

    // -------- 所在格子坐标 --------
    /// <summary>
    /// 敌人当前所在格子的逻辑坐标 (x, y)，命名规则与玩家一致：Hex_{x}_{y}
    /// 启动时通过向下射线命中 Hex_ 格子确定（与 HexMover.UpdateCurrentPosFromPhysics 对齐）
    /// </summary>
    public Vector2Int CurrentCoord { get; private set; } = new Vector2Int(-1, -1);

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------
    private void Awake()
    {
        // 从 SO 初始化 HP
        if (data == null)
        {
            Debug.LogError($"[EnemyController] {gameObject.name} 未指定 EnemyData！无法初始化 HP");
            currentHP = 1; // 兜底，避免 NRE 后续逻辑崩溃
            return;
        }
        maxHP = data.RollHP();
        currentHP = maxHP;
        // 行动点由移动范围初始化（哥布林 3 / 史莱姆 2）
        currentActionPoints = data.moveRange;

        // ===== M6-4（2026-08-19）：意图 UI 组件自动挂载 =====
        // 意图徽章 + 常显移动/攻击视觉组件在此自动附加，避免给每个敌人预制体手动加组件。
        // 二者均「零美术/零串行化引用」动态自建 UI，见 EnemyIntentBadgeUI / EnemyIntentVisuals。
        if (GetComponent<EnemyIntentBadgeUI>() == null) gameObject.AddComponent<EnemyIntentBadgeUI>();
        if (GetComponent<EnemyIntentVisuals>() == null) gameObject.AddComponent<EnemyIntentVisuals>();

        // ===== M5b-3（★2026-08-23 恢复被误删功能）：状态徽章自动挂载 =====
        // 护甲（左蓝点）+ 移动点（右绿点）徽章挂到血条 Canvas 上（与玩家同款，见 StatusBadgeUI）。
        // 早期版本曾把 StatusBadgeUI 手动挂到敌人 HPBarCanvas（PROJECT_INDEX v2.x 有记录），
        // 某次更新场景丢失（MCP 实测敌人 HPBarCanvas 无该组件）→ 改为此处自动挂载，
        // 场景摆放 / 小队运行时生成的敌人一律覆盖，且 AddComponent 不破坏序列化。
        Transform hpBarCanvas = transform.Find("HPBarCanvas");
        if (hpBarCanvas != null && hpBarCanvas.GetComponent<StatusBadgeUI>() == null)
        {
            hpBarCanvas.gameObject.AddComponent<StatusBadgeUI>();
        }
    }

    private void Start()
    {
        // 启动时通过向下射线确定所在格子（与 HexMover 一致）
        // 这样放置敌人时只需把它放到目标格子上方，运行时会自动绑定坐标
        UpdateCurrentCoordFromPhysics();

        // ★D13b 巡逻出生点 = 初始落位格（场景手动摆放敌人；SpawnResolver 生成的会在落位后覆盖一次）
        SetPatrolHome();

        // ★美术接入：占位红方块 → EnemyData.icon 精灵（SpawnResolver 路径已在 Initialize 里做过，这里兜底）
        ApplyBodySprite();
    }

    /// <summary>
    /// 从自身位置向下射线，命中 Hex_{x}_{y} 格子则记录坐标。
    /// 与 HexMover.UpdateCurrentPosFromPhysics 实现对齐。
    /// </summary>
    private void UpdateCurrentCoordFromPhysics()
    {
        if (Physics.Raycast(transform.position, Vector3.down, out RaycastHit hit))
        {
            if (hit.collider.name.StartsWith("Hex_"))
            {
                string[] parts = hit.collider.name.Split('_');
                if (parts.Length >= 3 && int.TryParse(parts[1], out int x) && int.TryParse(parts[2], out int y))
                {
                    CurrentCoord = new Vector2Int(x, y);
                    Debug.Log($"[EnemyController] {gameObject.name} 绑定到格子 Hex_{x}_{y}");
                    return;
                }
            }
        }
        Debug.LogWarning($"[EnemyController] {gameObject.name} 未射线命中 Hex_ 格子，CurrentCoord 未初始化！pos={transform.position}");
    }

    private void OnEnable()
    {
        // ★2026-09-15 性能：把本敌注册进 UnitOccupancy 单位表。
        //   原实现每次占位查询都 FindObjectsOfType<EnemyController>()（12k 对象场景 ≈6.5ms），
        //   现在查询只遍历这张表。启停即入表/出表，语义与「activeInHierarchy」判据一致。
        UnitOccupancy.RegisterEnemy(this);

        // 订阅 GameStateManager 状态切换（M2 任务清单要求）
        // Demo 阶段行为空实现：探索/战斗切换不改变靶子行为，留待 M3（视野触发）/M6（战斗 AI）接入
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged += HandleStateChanged;
        }
    }

    private void OnDisable()
    {
        // ★2026-09-15 性能：出表（见 OnEnable）
        UnitOccupancy.UnregisterEnemy(this);

        // 取消订阅，避免对象销毁后事件回调到已销毁实例抛 MissingReferenceException
        if (GameStateManager.Instance != null)
        {
            GameStateManager.Instance.OnStateChanged -= HandleStateChanged;
        }
    }

    // ------------------------------------------------------------------
    // 战斗接口（核心：被打 - 扣血 - 死亡）
    // ------------------------------------------------------------------

    /// <summary>
    /// 敌人受伤。
    /// 减伤顺序（M5b-3 / P23 对齐）：先扣护甲（1层挡1点，EffectManager 管理），
    /// 再走防御减伤：finalDamage = max(0, remaining - defense)
    /// 注：《公式文档》未明确给出减伤公式，此处为 Demo 简化实现，待 Game Studio 确认。
    /// </summary>
    /// <param name="rawDamage">原始伤害（未减防）</param>
    /// <returns>实际造成的伤害（扣血量）</returns>
    public int TakeDamage(int rawDamage)
    {
        if (IsDead)
        {
            Debug.Log($"[EnemyController] {gameObject.name} 已死亡，忽略攻击");
            return 0;
        }
        if (rawDamage <= 0)
        {
            Debug.Log($"[EnemyController] {gameObject.name} 受到非正伤害 {rawDamage}，忽略");
            return 0;
        }

        // ===== 1. 护甲扣减（1 层护甲挡 1 点伤害，按吸收量减层）=====
        int remaining = rawDamage;
        if (EffectManager.Instance != null)
        {
            int armor = EffectManager.Instance.GetEffectStacks(gameObject, "ArmorEffect");
            if (armor > 0)
            {
                int absorbed = EffectManager.Instance.ReduceEffectStacks(gameObject, "ArmorEffect", remaining);
                remaining -= absorbed;
                Debug.Log($"[EnemyController] {gameObject.name} 护甲吸收 {absorbed} 点，剩余伤害 {remaining}");
            }
        }
        if (remaining <= 0) return 0; // 全被护甲吸收，不掉血

        // ===== 2. 直接扣血（v2 已砍掉防御力，伤害/护甲住在意图卡牌里，无攻防减伤）=====
        // ★受击 = 回血中断（威胁预告与搜索 §10.3）：白`?`期间挨打，剩余未回的 25% 作废
        InterruptHeal();
        int finalDamage = remaining;

        int oldHP = currentHP;
        currentHP = Mathf.Max(0, currentHP - finalDamage);

        Debug.Log($"[EnemyController] {gameObject.name} 受击：rawDamage={rawDamage}, finalDamage={finalDamage}, HP {oldHP}→{currentHP}");

        // 广播 HP 变化（供血条 UI 更新）
        OnHPChanged?.Invoke(currentHP, finalDamage, rawDamage);

        // ★2026-09-16 掉血 = 姿态被打断（架弩）：护甲吸收掉的不算（上面已提前 return）。
        // 置位后由 EnemyTurnExecutor 在敌人回合消费 → 跳过出手 + 回退大意图重放「架弩」。
        if (EffectManager.Instance != null && EffectManager.Instance.ClearStances(gameObject, "受击") > 0)
        {
            _stanceBroken = true;
        }

        // 死亡判定
        if (currentHP <= 0 && !IsDead)
        {
            Die();
        }

        // ===== 3. ★受击 = 被看见（威胁预告与搜索 §4 / §5 / §7.2）=====
        //   黄`?`/白`?`阶段挨打 → 立即战斗意图 + 同队传导（回血已在上方 InterruptHeal 中断）。
        //   放在死亡判定之后：致死一击不必再唤醒。
        ReEngageOnHit();

        return finalDamage;
    }

    /// <summary>
    /// 治疗敌人（Demo 阶段未使用，预留接口便于扩展）
    /// </summary>
    public void Heal(int amount)
    {
        if (IsDead || amount <= 0 || data == null) return;
        int oldHP = currentHP;
        currentHP = Mathf.Min(maxHP, currentHP + amount);
        Debug.Log($"[EnemyController] {gameObject.name} 治疗 {amount}，HP {oldHP}→{currentHP}");
        OnHPChanged?.Invoke(currentHP, currentHP - oldHP, 0);
    }

    // ------------------------------------------------------------------
    // 陷阱响应链（威胁预告与搜索 §7.5）：非玩家造成的直接伤害
    // ------------------------------------------------------------------

    /// <summary>
    /// 敌人受到**非玩家造成的直接伤害**（陷阱）后的状态分流（§7.5）。
    /// 分流只看敌人当前状态，不看伤害来源细节。
    ///
    /// 伤害本身必须先走现有伤害链（<see cref="TakeDamage"/> 由卡牌/效果系统调用），
    /// 护甲吸收、回血中断才会自动生效；本方法**不再扣第二次血**，只改状态。
    ///
    /// ★本期留桩：陷阱本体（陷阱卡、放置物、踩格触发判定）待卡牌设计阶段实现，
    /// 届时在触发点「先结算伤害 → 再调本方法」即可，响应链照 §7.5 表走。
    /// </summary>
    /// <param name="trapCoord">陷阱所在格（顶替 <see cref="LastSeenCoord"/> 作次回合搜索主方向）</param>
    public void OnNonPlayerDamage(Vector2Int trapCoord)
    {
        if (IsDead) return;

        // 战斗态（参战者，任何徽章）：= 受击 = 被看见（§5）→ 立即战斗意图 + 警戒传导，不走搜索流程
        if (BattleResultHandler.Instance != null && BattleResultHandler.Instance.IsParticipant(this))
        {
            LastSeenCoord = trapCoord;
            BecomeAlerted(isOrigin: false);
            ReEngageOnHit();   // 问号阶段踩陷阱也要当场恢复战斗意图（幂等，非问号阶段直接早退）
            AlertPropagation.Refresh();
            Debug.Log($"[陷阱] 「{gameObject.name}」战斗态踩陷阱 = 受击 = 被看见 → 战斗意图 + 警戒传导");
            return;
        }

        // 探索态（常态巡逻 / 红`!`警戒 / 黄`?`搜索 / 白`?`休整）：
        // 整队红`!`冻结当回合 → 次敌人回合黄`?`散开搜索 → 无果走白`?` 75%/25% → 复原（§7.1）
        // 整队同时红`!`，不要求视野连锁；白`?`休整中踩陷阱 → 回血中断（BeginTrapAlert 内处理）
        BeginTrapAlert(trapCoord);
        foreach (EnemyController mate in AlertPropagation.LivingEnemies())
        {
            if (mate == this || !AlertPropagation.SameSquad(this, mate)) continue;
            mate.BeginTrapAlert(trapCoord);
        }
    }

    // ------------------------------------------------------------------
    // 行动点接口（★2026-08-18 新增）
    // ------------------------------------------------------------------

    /// <summary>
    /// 增减行动点（delta 负数=扣减），夹在 0~MaxActionPoints。
    /// 断筋卡（MovePointReductionEffect）调用扣减；M6 敌人移动 AI 消耗。
    /// </summary>
    public void ModifyActionPoints(int delta)
    {
        int oldAP = currentActionPoints;
        currentActionPoints = Mathf.Clamp(currentActionPoints + delta, 0, MaxActionPoints);
        if (oldAP != currentActionPoints)
        {
            Debug.Log($"[EnemyController] {gameObject.name} 行动点 {oldAP}→{currentActionPoints}（delta={delta}）");
        }
    }

    /// <summary>
    /// ★2026-08-23 用户需求：敌人移动点像玩家一样「走一格扣一点」——
    /// 从移动预算（MoveBudget = 当前行动点 + 疾跑值）里按地形消耗扣减。
    /// 先扣行动点，扣光再扣疾跑值（追击加成）——绿点徽章 / 右侧面板「移动N」随之逐格减少。
    /// 与计划阶段 MoveAIController 的移动消耗口径一致（TerrainManager.GetActionCost）。
    /// </summary>
    /// <param name="cost">本格移动消耗（地形花费，≥1）</param>
    public void ConsumeMoveBudget(int cost)
    {
        if (cost <= 0) return;
        int oldAP = currentActionPoints;
        int oldSprint = sprintAccumulated;

        int remaining = cost;
        int apDrain = Mathf.Min(remaining, currentActionPoints);
        currentActionPoints -= apDrain;
        remaining -= apDrain;
        sprintAccumulated = Mathf.Max(0, sprintAccumulated - remaining);

        if (oldAP != currentActionPoints || oldSprint != sprintAccumulated)
        {
            Debug.Log($"[EnemyController] {gameObject.name} 移动消耗 {cost}：行动点 {oldAP}→{currentActionPoints}" +
                      (oldSprint != sprintAccumulated ? $"，疾跑值 {oldSprint}→{sprintAccumulated}" : "") +
                      $"（剩余移动预算 {MoveBudget}）");
        }
    }

    /// <summary>
    /// 恢复行动点至上限（M6 敌人回合开始时调用；Demo 阶段无敌人回合，暂不触发）
    /// </summary>
    public void RestoreActionPoints()
    {
        currentActionPoints = MaxActionPoints;
    }

    /// <summary>
    /// ★2026-09-09 恢复探索态 AP：按敌人当前活动状态设对应步数（供探索回合开始调用）。
    /// 巡逻/追击 → data.patrolAP；搜索/归队（黄`?`/白`?`）→ 搜索步数（先锋+1，GetSearchAP）；
    /// 警戒（红`!`即将进战）→ 战斗 AP（moveRange）。徽章 DisplayActionPoints 探索态读
    /// currentActionPoints，移动中经 MoveToCoordSmooth 逐格递减到 0。
    /// </summary>
    public void RestoreExplorationAP()
    {
        if (IsAlerted)
        {
            currentActionPoints = MaxActionPoints;
        }
        else if (IsSearching || SearchPhase != DisengagePhase.None)
        {
            currentActionPoints = SearchScatterPlanner.GetSearchAP(this);
        }
        else
        {
            currentActionPoints = data != null ? data.patrolAP : 0;
        }
    }

    /// <summary>
    /// ★2026-09-09 Bug1 修复：探索态巡逻/搜索移动的「本金」= 本轮移动步数。
    /// MoveToCoordSmooth 每格 ConsumeMoveBudget 从 MoveBudget 扣，若 currentActionPoints 仍是
    /// 战斗 AP（moveRange），徽章就会从战斗 AP 扣、减不到 0。此方法把 AP 设为本轮步数，
    /// 并把已生效的战斗疾跑转回待生效缓冲（探索态移动不消耗疾跑，进战斗再经 FoldSprintPending 折入）。
    /// </summary>
    /// <param name="steps">本轮巡逻/搜索步数（patrolAP 或 searchAP）</param>
    public void PrepareExplorationMove(int steps)
    {
        currentActionPoints = Mathf.Max(1, steps);
        if (sprintAccumulated > 0)
        {
            sprintPending = Mathf.Min(sprintPending + sprintAccumulated,
                data != null ? data.sprintMax : sprintAccumulated);
            sprintAccumulated = 0;
        }
    }

    // ------------------------------------------------------------------
    // 小队生成入口（★2026-08-19 M6-6 新增）
    // ------------------------------------------------------------------

    /// <summary>
    /// 用指定数据源重新初始化运行时状态（小队生成用）。
    /// SpawnResolver 生成小队成员时：Instantiate 预制体（或 Cube 兜底）→ 本方法注入
    /// 「预设 + 小队覆盖」的运行时克隆数据 → MoveToCoord 摆到解算格。
    /// data 为 null 时仅重置运行时状态（HP 兜底 1，供无数据兜底单位使用）。
    /// </summary>
    /// <param name="source">数据源（通常是 SpawnResolver 克隆并应用覆盖后的 EnemyData）</param>
    public void Initialize(EnemyData source)
    {
        data = source;
        maxHP = source != null ? source.RollHP() : 1;
        currentHP = maxHP;
        currentActionPoints = source != null ? source.moveRange : 0;
        currentIntentIndex = 0;
        sprintAccumulated = 0;
        IsDead = false;

        // ★2026-09-09 探索态生成（巡逻小队/遭遇床）时，徽章应按巡逻步数显示而非战斗 moveRange：
        // 首回合敌人生成晚于 StartNewExplorationTurn 的 RestoreExplorationAP 调用，故生成时补一次。
        if (GameStateManager.Instance != null
            && GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            RestoreExplorationAP();
        }

        // ★美术接入：用 EnemyData.icon 替换「Model」子对象上的占位红方块（icon 为空则保持方块，安全回退）
        ApplyBodySprite();
    }

    /// <summary>
    /// ★美术接入：把占位红方块（MeshRenderer）换成 EnemyData.icon 精灵。
    /// data.icon 为空时直接返回（保留红方块，绝不报错）。仅视觉层替换，战斗/巡逻逻辑完全不变。
    /// 结构约定与 SpawnResolver 一致：根 Y=0.5、方块在「Model」子对象 ⇒ 方块底边 = 格子顶面。
    /// </summary>
    private void ApplyBodySprite()
    {
        if (data == null) return;

        // 优先用已绑定的 icon；未绑定时按 enemyName 从 Resources 兜底加载
        Sprite sprite = data.icon;
        if (sprite == null) sprite = Resources.Load<Sprite>("EnemyPortraits/" + data.enemyName);
        if (sprite == null) return;

        float spriteWorldH = sprite.rect.height / sprite.pixelsPerUnit;
        if (spriteWorldH < 1e-4f) return;

        Transform model = transform.Find("Model");
        if (model == null) return;

        // 关掉占位方块（不删：保留结构，方便随时回退）。
        // forceRenderingOff 是必需的：EnemyRenderLod 远近裁剪时会把缓存过的 Renderer
        // 统一 enabled = true，只关 enabled 的话方块会在敌人重新进入视野时复活。
        MeshRenderer block = model.GetComponent<MeshRenderer>();
        if (block != null)
        {
            block.enabled = false;
            block.forceRenderingOff = true;
        }

        // 精灵另起一个子物体：同一个 GameObject 上放不下两个 Renderer
        // （实测对带 MeshRenderer 的对象 AddComponent<SpriteRenderer> 会返回 null）
        Transform spriteT = transform.Find("BodySprite");
        if (spriteT == null)
        {
            spriteT = new GameObject("BodySprite").transform;
            spriteT.SetParent(transform, false);
        }

        SpriteRenderer sr = spriteT.GetComponent<SpriteRenderer>();
        if (sr == null) sr = spriteT.gameObject.AddComponent<SpriteRenderer>();
        sr.sprite = sprite;
        sr.enabled = true;
        sr.sortingOrder = 10;

        // 立绘正对镜头：相机是固定 70° 俯视，不跟着俯就要被压扁成 34% 高（与 EnemyHPBar 同一套约定）
        Quaternion face = Quaternion.Euler(CameraPitch(), 0f, 0f);
        spriteT.localRotation = face;

        // 高度按世界单位算，要除以父级缩放（根节点缩放不一定是 1）
        float parentScale = transform.lossyScale.y;
        if (parentScale < 1e-4f) parentScale = 1f;
        spriteT.localScale = Vector3.one * (bodyWorldHeight / spriteWorldH / parentScale);

        // 脚底锚点：根 Y=0.5、方块中心在根上 ⇒ 底面 0.25。
        // ★2026-09-17 晚三修：只沿立绘平面下滑，底边会掉到格面（世界 Y=0.25）以下被裁脚（用户实测
        // 「脚又杵地里了」）。解法：先把立绘沿固定俯视视线朝镜头平移 BodyPullTowardCamera——
        // 屏幕位置几乎不动，但世界 Y 抬高 +0.628/单位，换出下滑余量；再沿 UI 平面下滑 BodyUiSlide。
        // 拉靠方向取常数（不用逐敌真射线）：真射线的 Y 分量随格子远近变 ±38%，
        // 会让远处敌人又栽回格面、近处悬空；常数保证全场脚底净高度一致（B_y≈0.256）。
        Vector3 feet = new Vector3(transform.position.x, transform.position.y - 0.25f + 0.03f, transform.position.z)
                       - face * Vector3.up * BodyUiSlide
                       + BodyPullTowardCamera;
        spriteT.position = feet + (face * Vector3.up) * (bodyWorldHeight * 0.5f);
    }

    /// <summary>★2026-09-17 晚三修：立绘沿 UI 平面（屏幕正下方）的下滑量（世界单位；本场景 1≈58.6px）。</summary>
    private const float BodyUiSlide = 0.18f;

    /// <summary>★2026-09-17 晚三修：立绘朝镜头贴靠量——沿固定俯视视线反方向平移（屏幕位置几乎不动、
    /// 世界高度 +0.628/单位），换出下滑不被格面裁脚的余量。与 BodyUiSlide 配合决定脚底落点。</summary>
    private static readonly Vector3 BodyPullTowardCamera = new Vector3(0f, 0.62822f, -0.77802f) * 0.06f;

    private static float cameraPitchCache = -1f;

    /// <summary>相机俯角（固定 70°，只平移缩放不转向）。取一次缓存，避免每只敌人每次换装都查 Camera.main。</summary>
    private static float CameraPitch()
    {
        if (cameraPitchCache < 0f)
        {
            Camera cam = Camera.main;
            cameraPitchCache = cam != null ? cam.transform.eulerAngles.x : 70f;
        }
        return cameraPitchCache;
    }

    // ------------------------------------------------------------------
    // 疾跑 / 意图推进 / 移动（M6-3 敌人移动 AI 接口）
    // ------------------------------------------------------------------

    /// <summary>
    /// 疾跑：把追击值存入 <see cref="sprintPending"/>（★2026-09-09 延迟生效），
    /// 下一敌人回合开始经 <see cref="FoldSprintPending"/> 并入 sprintAccumulated。
    /// ★2026-08-19 开关守卫：data.canSprint=false 的怪（站桩/BOSS 等）不累积——
    /// 无可用意图时只按预设移动、什么都不做（用户确认「选上了疾跑才是通用兜底」）。
    /// 设计依据：v2 §4.3 —— 当前大意图所有小意图都无法完成时的统一兜底；疾跑下回合生效。
    /// </summary>
    public void AddSprint()
    {
        if (data == null || !data.canSprint) return;
        int old = sprintPending;
        sprintPending = Mathf.Min(sprintPending + data.sprintValue, data.sprintMax);
        Debug.Log($"[EnemyController] {gameObject.name} 疾跑：待生效追击值 {old}→{sprintPending}（封顶 {data.sprintMax}，下回合并入）");
    }

    /// <summary>把待生效追击值并入当前追击值并清缓冲（战斗敌人回合开始调用）。</summary>
    public void FoldSprintPending()
    {
        if (sprintPending <= 0) return;
        int old = sprintAccumulated;
        sprintAccumulated = Mathf.Min(sprintAccumulated + sprintPending, data != null ? data.sprintMax : sprintPending);
        sprintPending = 0;
        Debug.Log($"[EnemyController] {gameObject.name} 疾跑生效：追击值 {old}→{sprintAccumulated}");
    }

    /// <summary>追击值归零（复原/任一非疾跑小意图成功打出时调用）。设计依据：v2 §4.3。</summary>
    public void ResetSprint()
    {
        sprintAccumulated = 0;
        sprintPending = 0;
    }

    /// <summary>
    /// 推进到下一个大意图（末位回 0 循环）。设计依据：v2 §3.2「大意图循环推进」。
    /// </summary>
    public void AdvanceIntent()
    {
        if (data == null || data.intentLoop == null || data.intentLoop.Count == 0) return;
        currentIntentIndex = (currentIntentIndex + 1) % data.intentLoop.Count;
        Debug.Log($"[EnemyController] {gameObject.name} 推进大意图 → 下标 {currentIntentIndex}");
    }

    /// <summary>
    /// 揭示本回合意图：读取当前大意图，为其中所有小意图各创建一张运行时卡牌并掷骰锁死。
    /// 设计依据：v2 §3.3 —— 玩家回合开始投所有小意图骰子，数值固定，敌人回合不再重投。
    /// 揭示结果存到 <see cref="RevealedIntent"/>，并递增 <see cref="RevealGeneration"/> 通知 UI 刷新。
    /// </summary>
    public void RevealIntent()
    {
        _revealedIntent = new EnemyRevealedIntent { bigIntentIndex = currentIntentIndex };

        if (data != null && data.intentLoop != null && data.intentLoop.Count > 0)
        {
            int idx = Mathf.Clamp(currentIntentIndex, 0, data.intentLoop.Count - 1);
            EnemyBigIntent big = data.intentLoop[idx];
            if (big != null && big.options != null)
            {
                foreach (EnemyIntentOption option in big.options)
                {
                    if (option == null || option.card == null) continue;

                    // 为每个小意图生成一张运行时卡牌并掷骰锁死（复用敌人自带骰子；
                    // option.diceSlot1-4 的「以不同骰子复用同一卡」为后续扩展，暂不覆盖）。
                    // ★2026-09-16 Owner = 自己：架弩/磨斧这类「自身骰面修正」在这里落地——
                    //   上一个意图预掷时若身上有修正，本意图的点数就能吃到（跨意图的铺垫→兑现节奏）。
                    Card card = new Card(option.card);
                    card.Owner = gameObject;
                    card.RollAllDice();
                    _revealedIntent.options.Add(new RevealedIntentOption { option = option, rolledCard = card });
                }
            }
        }

        RevealGeneration++;
        IntentConsumed = false; // 新揭示 → 意图未消费，视觉层恢复显示
        Debug.Log($"[EnemyController] {gameObject.name} 揭示意图：大意图下标 {currentIntentIndex}，" +
                  $"共 {(_revealedIntent != null ? _revealedIntent.options.Count : 0)} 条小意图（数值已锁定）");
    }

    /// <summary>
    /// 意图是否已被本回合敌人行动消费（true = 行动已开始/完毕，视觉层应隐藏指引）。
    /// ★2026-08-21 用户需求：怪物开始移动（行动）后移动指引（虚线/虚影/弧线）隐藏，
    /// 直到下个玩家回合开始 RevealIntent 揭示新意图才恢复显示。
    /// EnemyTurnExecutor.ExecuteAction 开头标记；RevealIntent 重置。
    /// </summary>
    public bool IntentConsumed { get; private set; }

    /// <summary>标记当前已揭示意图已被敌人行动消费（视觉层将隐藏移动指引）。</summary>
    public void MarkIntentConsumed()
    {
        IntentConsumed = true;
    }

    /// <summary>
    /// 移动敌人到指定六边形格子（瞬时位移 + 更新逻辑坐标）。
    /// 保留为「无路可达 / 兜底」的瞬移接口；正常敌人回合走 <see cref="MoveToCoordSmooth"/>。
    /// </summary>
    public void MoveToCoord(Vector2Int coord)
    {
        GameObject tile = FindHexTile(coord);
        if (tile != null)
        {
            Vector3 tilePos = tile.transform.position;
            transform.position = new Vector3(tilePos.x, transform.position.y, tilePos.z);
        }
        CurrentCoord = coord;
    }

    /// <summary>
    /// 沿 A* 路径逐格平滑移动到目标格子，速度与玩家 HexMover 完全一致。
    /// 用户需求（2026-08-19）：敌人回合移动与玩家相同——按格子一格一格平移，移动速度也一样。
    /// 速度直接复用 <see cref="HexMover.moveSpeed"/>（找不到 HexMover 时兜底 5f），保证「一模一样」。
    /// </summary>
    /// <param name="targetCoord">目标逻辑坐标</param>
    /// <param name="precomputedPath">
    /// ★2026-08-22 预解算路径（全局计划阶段冻结，含起点）。传入后直接走这条路径，不再现场寻路；
    /// null 或与当前格不符（极端/直接调试调用）→ 回退现场 A* 寻路（原行为）。
    /// </param>
    public IEnumerator MoveToCoordSmooth(Vector2Int targetCoord, List<Vector2Int> precomputedPath = null)
    {
        if (targetCoord == CurrentCoord) yield break;

        // ★2026-08-22 优先走预解算路径：别人先动后我的路不再重新规划，避免走穿别人新占据的
        // 格子（用户报告的「移动路径混乱」）。路径[0] 必须等于当前格，否则视为无效回退现场寻路。
        List<Vector2Int> path = precomputedPath;
        if (path == null || path.Count <= 1 || path[0] != CurrentCoord)
        {
            HexGridLayout grid = FindObjectOfType<HexGridLayout>();
            path = (grid != null) ? new AStarPathfinding(grid).FindPath(CurrentCoord, targetCoord, enemyRequester: this) : null;
        }

        if (path == null || path.Count <= 1)
        {
            // ★2026-08-21 零碰撞下中途友军不阻挡，无路只能是地形障碍封死（极端情况）。
            // 落点在计划时已验证可达；原地等待，下回合重新规划。
            CurrentMovePath = null;
            Debug.LogWarning($"[EnemyController] {gameObject.name} 无路可达（地形封死），本回合原地等待");
            yield break;
        }

        // 落点互斥：中途可穿过友军，但不能停在同一格。
        // 齐步走时用本波预约格（别人即将离开的格子可以停）；否则查当前真实占位。
        int end = path.Count - 1;
        bool parallel = UnitOccupancy.PatrolLandingClaims.IsActive;
        if (parallel) UnitOccupancy.PatrolLandingClaims.Release(CurrentCoord);
        while (end > 0 && (parallel
            ? !UnitOccupancy.PatrolLandingClaims.CanStop(path[end])
            : UnitOccupancy.IsOccupied(path[end])))
        {
            end--;
        }
        if (end < 1)
        {
            if (parallel) UnitOccupancy.PatrolLandingClaims.Claim(CurrentCoord);
            CurrentMovePath = null;
            yield break; // 路径上除起点外全被占（极端拥挤）：原地等待
        }
        if (end < path.Count - 1)
        {
            path.RemoveRange(end + 1, path.Count - 1 - end); // 截断被占尾段
        }
        if (parallel) UnitOccupancy.PatrolLandingClaims.Claim(path[end]);

        // ★2026-08-22 移动中标志：CurrentMovePath 非空 = 正在移动（视觉层据此「只显示目的地」）。
        // 内容（剩余路径）已不再用于绘图，仅作状态标记保留。
        CurrentMovePath = new List<Vector2Int>(path);
        CurrentMovePath.RemoveAt(0);

        // 移动速度与玩家一致（读 HexMover.moveSpeed）
        // ★2026-09-16 性能二批：改走缓存引用——本方法的 yield 前段在小队齐步走时**全部成员同帧执行**
        //   （ExecutePatrolTurn 无 yield 直达 CoroutineBatch.WhenAll），原两次 FindObjectOfType
        //   在「结束回合」那一帧叠成 ~6ms×成员数，是阶段首帧卡顿的最大头。
        float speed = 5f;
        HexMover player = ExplorationPerf.Player;
        if (player != null) speed = player.moveSpeed;

        // ★2026-08-23 逐格扣移动点：与计划阶段 MoveAIController 同源（TerrainManager.GetActionCost），
        // 走一格扣一格，绿点徽章 / 右侧面板「移动N」随之逐格减少（参考玩家 HexMover.MoveSequence）。
        TerrainManager terrain = ExplorationPerf.Terrain;

        for (int i = 1; i < path.Count; i++)
        {
            Vector2Int coord = path[i];
            GameObject tile = FindHexTile(coord);
            if (tile == null)
            {
                // 找不到格子物体（极端兜底）：直接推进逻辑坐标跳过该格
                CurrentCoord = coord;
                if (CurrentMovePath != null && CurrentMovePath.Count > 0) CurrentMovePath.RemoveAt(0);
                ConsumeMoveBudget(1); // 兜底格也按 1 格消耗，保持绿点逐格递减
                continue;
            }

            // 保持敌人当前高度，只在 X/Z 轴平移（与 HexMover.SmoothMoveTo 对齐）
            Vector3 dest = new Vector3(tile.transform.position.x, transform.position.y, tile.transform.position.z);
            while (Vector3.Distance(transform.position, dest) > 0.01f)
            {
                transform.position = Vector3.MoveTowards(transform.position, dest, speed * Time.deltaTime);
                yield return null;
            }
            transform.position = dest;
            CurrentCoord = coord; // 到达一格后立即更新逻辑坐标
            if (CurrentMovePath != null && CurrentMovePath.Count > 0) CurrentMovePath.RemoveAt(0);

            // ★2026-08-23 到达一格即扣对应地形移动消耗（与玩家走格扣行动点同理）
            int moveCost = terrain != null ? terrain.GetActionCost(coord) : 1;
            if (moveCost <= 0) moveCost = 1;
            ConsumeMoveBudget(moveCost);
        }

        CurrentMovePath = null; // 移动结束：清除移动中标志（视觉层隐藏目的地虚影）
    }

    /// <summary>按逻辑坐标查找「Map」下的 Hex_{x}_{y} 格子物体（找不到返回 null）。</summary>
    // ★P2：FindHexTile 在 MoveToCoordSmooth 逐格移动循环里每格都调 GameObject.Find("Map")（全场景遍历）
    // + 遍历 Map 全部子物体（~150 个），是「敌人移动卡顿」的主要元凶。改为一次性建字典缓存。
    private static GameObject _mapRoot;
    private static Dictionary<Vector2Int, GameObject> _hexTileCache;

    private GameObject FindHexTile(Vector2Int coord)
    {
        if (_hexTileCache == null || _mapRoot == null)
        {
            _mapRoot = GameObject.Find("Map");
            _hexTileCache = new Dictionary<Vector2Int, GameObject>();
            if (_mapRoot != null)
            {
                foreach (Transform child in _mapRoot.transform)
                {
                    string n = child.name;
                    if (n.StartsWith("Hex_"))
                    {
                        string[] parts = n.Split('_');
                        if (parts.Length >= 3 && int.TryParse(parts[1], out int x) && int.TryParse(parts[2], out int y))
                        {
                            _hexTileCache[new Vector2Int(x, y)] = child.gameObject;
                        }
                    }
                }
            }
        }
        return _hexTileCache.TryGetValue(coord, out GameObject tile) ? tile : null;
    }

    // ------------------------------------------------------------------
    // 箭头指向悬停高亮（2026-08-18 出牌交互重构）
    // ------------------------------------------------------------------

    /// <summary>模型渲染器缓存（懒查找）</summary>
    private Renderer _modelRenderer;
    /// <summary>模型原色（第一次高亮时记录，取消时恢复）</summary>
    private Color _modelBaseColor = Color.white;
    private bool _modelColorSaved = false;

    /// <summary>
    /// 设置指向悬停高亮：箭头模式下鼠标悬停在有效目标敌人上时染红，
    /// 离开/打出/取消时恢复原色。由 HandUIController 每帧刷新调用。
    /// </summary>
    /// <param name="on">true = 染红（向红偏移 50%），false = 恢复原色</param>
    public void SetHighlighted(bool on)
    {
        if (_modelRenderer == null)
        {
            _modelRenderer = GetComponentInChildren<Renderer>();
            if (_modelRenderer == null) return;
        }

        if (!_modelColorSaved)
        {
            _modelBaseColor = _modelRenderer.material.color;
            _modelColorSaved = true;
        }

        // 向红色偏移 50% 作为"被指向"提示（死亡/重置后由 SetHighlighted(false) 复原）
        _modelRenderer.material.color = on
            ? Color.Lerp(_modelBaseColor, new Color(1f, 0.25f, 0.15f), 0.5f)
            : _modelBaseColor;
    }

    /// <summary>
    /// 死亡处理：标记死亡 + 广播事件 + 隐藏/销毁对象
    /// </summary>
    private void Die()
    {
        IsDead = true;

        // ★2026-09-12 死亡瞬间定格状态：订阅方（CorpseSpawner / BattleRewardLedger）靠它判灵魂归属。
        //   本次事件链里 BattleResultHandler 会同步走完胜利结算并 SwitchToExploring，
        //   事后重读 CurrentState 会把这场战斗的最后一击当成探索击杀（单杀双魂的根因）。
        StateAtDeath = GameStateManager.Instance != null
            ? GameStateManager.Instance.CurrentState
            : GameState.Battle;

        Debug.Log($"[EnemyController] {gameObject.name} 死亡！掉落由 SquadPatrolData.dropConfig 配置");

        // 广播死亡事件（M7 战利品系统会订阅此事件生成掉落）
        OnEnemyDied?.Invoke(this);
        EnemyDied?.Invoke(this);

        // ★2026-08-19 效果清理：移除身上所有持续效果（护甲/虚弱等）——
        // 不清理会残留在 EffectManager.activeEffects（Target 指向已隐藏对象，
        // OnTurnEnd 持续空衰减且永不移除，属泄漏）
        if (EffectManager.Instance != null)
        {
            EffectManager.Instance.RemoveAllEffectsFromTarget(gameObject);
        }

        // Demo 简化：直接隐藏对象（保留实例便于调试，完整版应走对象池/销毁）
        // 注：不立即 Destroy，避免 OnEnemyDied 订阅方访问已销毁对象
        gameObject.SetActive(false);
    }

    // ------------------------------------------------------------------
    // 状态切换处理（Demo 空实现，预留 M3/M6 接入点）
    // ------------------------------------------------------------------
    private void HandleStateChanged(GameState oldState, GameState newState)
    {
        // Demo 阶段：靶子不响应状态切换
        // M3 接入：Exploring→Battle 时启动视野检测停止
        // M6 接入：Battle 时执行意图/行动
        Debug.Log($"[EnemyController] {gameObject.name} 收到状态切换 {oldState}→{newState}（Demo 阶段无行为）");
    }

    // ------------------------------------------------------------------
    // M5b-2 目标选择：点击敌人（CardExecutor 处于 CardSelected 状态时）
    // ------------------------------------------------------------------

    /// <summary>
    /// 鼠标点击敌人。仅在 CardExecutor 状态为 CardSelected 时响应。
    /// 通知 CardExecutor 尝试将此敌人作为目标。
    /// </summary>
    public void OnPointerClick(PointerEventData eventData)
    {
        if (CardExecutor.Instance != null
            && CardExecutor.Instance.State == CardExecutionState.CardSelected)
        {
            CardExecutor.Instance.TrySelectTarget(this);
        }
    }

    // ------------------------------------------------------------------
    // 调试辅助（Inspector 右键可调，便于验收）
    // ------------------------------------------------------------------
    /// <summary>调试：模拟受 5 点伤害</summary>
    [ContextMenu("调试：受 5 点伤害")]
    private void Debug_TakeDamage5()
    {
        TakeDamage(5);
    }

    /// <summary>调试：满血复活</summary>
    [ContextMenu("调试：满血复活")]
    private void Debug_Revive()
    {
        if (data == null) return;
        IsDead = false;
        currentHP = maxHP;
        if (!gameObject.activeSelf) gameObject.SetActive(true);
        OnHPChanged?.Invoke(currentHP, currentHP, 0);
        Debug.Log($"[EnemyController] {gameObject.name} 满血复活");
    }
}

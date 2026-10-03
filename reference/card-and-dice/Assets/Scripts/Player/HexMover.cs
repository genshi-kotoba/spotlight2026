using UnityEngine;
using System.Collections;
using System.Collections.Generic;
using UnityEngine.EventSystems;

public class HexMover : MonoBehaviour
{
    [Header("配置")]
    public HexGridLayout gridLayout;
    public float moveSpeed = 5f;
    public int maxActionPoints = 999; // 最大行动点
    public int currentActionPoints = 0; // 当前行动点
    public Color pathColor = new Color(1f, 1f, 0f, 0.5f); // 路径颜色（半透明黄色）
    [Tooltip("★2026-08-19 单位占位规则：有单位（敌我不论）站的格子不可到达，悬停时显示红色")]
    public Color occupiedTileColor = new Color(1f, 0f, 0f, 0.5f); // 占位格颜色（半透明红色）
    [Tooltip("出生格是否自动生成篝火（战术卡槽调整入口）。\n" +
             "★2026-09-11：教学篇定稿「篝火 ≠ 撤离点 ≠ 藏身处」——出生格=家=撤离点，" +
             "故突袭场景关闭此项；MainScene 等旧场景保持开启以维持原行为")]
    public bool createBonfireAtSpawn = true;

    [Header("★2026-09-12 探索骰买路程（超出行动点的部分自动扣探索骰）")]
    [Tooltip("开启后：点击超出行动点的格子会自动消耗探索骰补足路程。\n" +
             "★探索态与战斗态**共用同一批探索骰**（DiceArea），本机制两态都生效，只有参数不同：\n" +
             "  探索 = diceAPCapPerTurn 枚 / 每枚 diceAPBonus 格；\n" +
             "  战斗 = battleDiceAPCapPerTurn 枚 / 每枚 DiceDragHandler.battleDiceAPBonus 格。")]
    public bool diceForMoveEnabled = true;

    private Vector2Int currentCoord; // 玩家当前的逻辑坐标 (x, y)

    /// <summary>
    /// ★2026-09-12 教学钩子：玩家移动落点广播（探索/战斗都广播，由订阅方按状态过滤）。
    /// 静态事件（与 <c>ExplorationTurnManager.OnExplorationTurnStarted</c> 同款），
    /// <c>FinalizeMove</c> 触发一次，参数 = 落点坐标；订阅方 <c>TutorialDirector</c>。
    /// </summary>
    public static event System.Action<Vector2Int> OnPlayerArrived;

    /// <summary>M5b-1：玩家当前所在格子的逻辑坐标（公开只读，供 CardExecutor 射程计算用）</summary>
    public Vector2Int CurrentCoord => currentCoord;

    /// <summary>
    /// ★2026-08-23 移动期间的「视觉锁定落点」：从移动开始到结束，敌方意图视觉
    /// （虚线/虚影/攻击弧线/意图徽章/右侧栏）统一以该落点为假设玩家坐标解算并保持不变，
    /// 不再随中途经过的格子逐格刷新跳动（用户需求：我方移动期间，敌方预览=落点版）。
    /// 移动开始时由 ComputeMoveDestination 预算锁定（与执行判定一致），FinalizeMove 清空。
    /// null = 未在移动（调用方回落 CurrentCoord）。
    /// </summary>
    public Vector2Int? MovingDestCoord { get; private set; }

    private bool isMoving = false; // 移动锁
    private AStarPathfinding pathfinding; // A*寻路实例

    /// <summary>
    /// 寻路实例惰性兜底（★2026-09-15 NRE 修复）：
    /// Play 中途一旦发生域重载（改脚本触发重编译等），非序列化字段会被清空、Start 不会重跑
    /// → pathfinding 变 null → 悬停路径预览每帧抛 NullReferenceException 刷屏 Console
    /// （编辑器里每帧捕获堆栈+刷新 Console，实测把 80×50 雾镇拖到 ~20 FPS）。
    /// 改为用到时自动重建，三个调用点统一走本属性。
    /// </summary>
    private AStarPathfinding Pathfinding
    {
        get
        {
            if (pathfinding == null)
                pathfinding = new AStarPathfinding(gridLayout != null ? gridLayout : FindObjectOfType<HexGridLayout>());
            return pathfinding;
        }
    }

    /// <summary>TerrainManager 静态缓存（悬停路径预览/落点预演每次重算都扫全场景，雾镇下无谓）。</summary>
    private static TerrainManager _cachedTerrain;
    private static TerrainManager CachedTerrain
    {
        get { return _cachedTerrain != null ? _cachedTerrain : (_cachedTerrain = Object.FindObjectOfType<TerrainManager>()); }
    }
    private List<GameObject> pathTiles = new List<GameObject>(); // 路径上的格子
    private List<Color> pathOriginalColors = new List<Color>(); // 路径格子的原始颜色
    private Dictionary<GameObject, GameObject> tileToTextMap = new Dictionary<GameObject, GameObject>(); // 格子到行动点文本的映射
    private Vector2Int lastHoverCoord = new Vector2Int(-999, -999); // 上一帧的悬停坐标
    private int lastActionPoints = -1; // 上一次的行动点数量，用于检测行动点变化
    private GameObject hoveredTile; // 鼠标悬停的格子
    
    // 缓存对象
    private GameObject mapObject;
    private GameObject map1Object;

    private DiceDragHandler _diceHandler;                 // 取战斗态「每骰换几格」的配置源

    [Header("★2026-09-12 敌人视野高亮（移动前预警）")]
    [Tooltip("鼠标停在敌人视野内的格子时，把「看得见这一格」的敌人视野范围染成此颜色，\n" +
             "让玩家在点下去之前就能看见「再走一步会触发战斗」。\n" +
             "与移动路径预览共用 Map1 高光层：**路径优先**，视野只染路径没盖到的格。\n" +
             "禁用条件：① 玩家已在该敌视野内（它已经看见你了）；② 该敌有红!（警戒/战斗意图——\n" +
             "探索态发现玩家、追击、陷阱整队警戒，或战斗态被同队意图传导的红!）；③ 战斗意图参战者。\n" +
             "以上即使中途跑出视野也保持禁用，只有没有红!的搜寻/休整阶段（黄?/白?/陷阱搜查）才重新启用。")]
    public Color enemyVisionColor = new Color(1f, 0.22f, 0.18f, 0.5f);   // 半透明红

    private readonly List<GameObject> visionTiles = new List<GameObject>();   // 本帧被视野染色的格（清除用）
    /// <summary>★2026-09-15：视野去重集合，与 visionTiles 同生同灭（把 O(n) 的 List.Contains 换成 O(1)）。</summary>
    private readonly HashSet<GameObject> visionTileSet = new HashSet<GameObject>();
    private readonly Dictionary<Vector2Int, GameObject> map1TileLookup = new Dictionary<Vector2Int, GameObject>(); // Map1 坐标索引
    /// <summary>
    /// ★2026-09-15 地图重构：Map1 索引的应有条数（InitializeMap1Colors 建立索引时统计）。
    /// 用途见 FindTileByCoordInMap1 的「索引完整性快路径」——不能用 transform.childCount 判，
    /// 因为合并网格容器 _HexBatch 也是 Map1 的子节点。
    /// </summary>
    private int map1ExpectedCount;

    // ------------------------------------------------------------------
    // ★2026-09-12 移动预算 = 行动点 + 探索骰能买的路程
    // ------------------------------------------------------------------

    /// <summary>一枚探索骰能买几格路程（探索 diceAPBonus / 战斗 DiceDragHandler.battleDiceAPBonus）。</summary>
    int GridsPerDie
    {
        get
        {
            if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
            {
                if (_diceHandler == null) _diceHandler = Object.FindObjectOfType<DiceDragHandler>();
                return _diceHandler != null ? _diceHandler.battleDiceAPBonus : 2;
            }
            ExplorationTurnManager etm = ExplorationTurnManager.Instance;
            return etm != null ? etm.diceAPBonus : 2;
        }
    }

    /// <summary>
    /// 本回合还能拿几枚探索骰买路程 = min(骰池剩余, 每回合规定的上限 - 已用)。
    /// ★两态共用同一批 DiceArea 骰子（战斗回合开始时 TurnManager 补满），扣骰入口也同一个。
    /// </summary>
    int DiceBudgetCount()
    {
        if (!diceForMoveEnabled) return 0;

        ExplorationTurnManager etm = ExplorationTurnManager.Instance;
        if (etm == null) return 0;

        int left = etm.RemainingExplorationDice();
        if (left <= 0) return 0;

        int capLeft;
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            TurnManager tm = TurnManager.Instance;
            if (tm == null) return 0;
            capLeft = tm.battleDiceAPCapPerTurn - tm.DiceToAPUsedThisTurn;
        }
        else
        {
            capLeft = etm.diceAPCapPerTurn - etm.DiceAPUsedThisTurn;
        }

        return Mathf.Max(0, Mathf.Min(left, capLeft));
    }

    /// <summary>本次移动的总预算（格成本口径）：行动点 + 骰子能买的路程格数。</summary>
    public int MoveBudget
    {
        get { return currentActionPoints + DiceBudgetCount() * GridsPerDie; }
    }

    /// <summary>
    /// 走完 path（预算 budget）实际要花几枚探索骰 = ⌈(总成本 − 行动点) / 每骰格数⌉。
    /// 参数为 null 时用当前预算。
    /// </summary>
    public int DiceNeededFor(int totalCost)
    {
        if (!diceForMoveEnabled) return 0;
        int extra = totalCost - currentActionPoints;
        if (extra <= 0) return 0;
        int per = Mathf.Max(1, GridsPerDie);
        return Mathf.CeilToInt(extra / (float)per);
    }

    /// <summary>
    /// 花 n 枚探索骰买路程：扣骰 → 记账 → 转成行动点（与点骰子按钮 / 右键完全同口径）。
    /// 转成行动点而不是另起一套预算变量，是为了让移动执行循环、AP 显示、警戒/事件结算零改动。
    /// </summary>
    bool PayDiceForMove(int n)
    {
        if (n <= 0) return true;

        ExplorationTurnManager etm = ExplorationTurnManager.Instance;
        if (etm == null) return false;

        bool inBattle = GameStateManager.Instance != null
                        && GameStateManager.Instance.CurrentState == GameState.Battle;
        TurnManager tm = inBattle ? TurnManager.Instance : null;

        for (int i = 0; i < n; i++)
        {
            if (!etm.TryConsumeExplorationDice()) return false;
            if (inBattle && tm != null) tm.RecordDiceForAP();
            else etm.RecordDiceForAP();
        }

        int gained = n * GridsPerDie;
        currentActionPoints += gained;
        Debug.Log($"[移动] 超出行动点 → 自动消耗 {n} 枚探索骰买路程 +{gained} 行动点（当前 {currentActionPoints}）");
        return true;
    }

    private void OnEnable()
    {
        // ★2026-09-15 性能：玩家注册进 UnitOccupancy 单位表（见 UnitOccupancy 头注释）。
        //   原实现每次占位查询都全场景 FindObjectOfType<HexMover>()。
        UnitOccupancy.RegisterPlayer(this);
    }

    private void OnDisable()
    {
        UnitOccupancy.UnregisterPlayer(this);
    }

    void Start()
    {
        // 检查gridLayout是否为null，如果是则尝试从场景中查找
        if (gridLayout == null)
        {
            gridLayout = FindObjectOfType<HexGridLayout>();
        }
        
        // 初始化A*寻路实例
        pathfinding = new AStarPathfinding(gridLayout);
        
        // 缓存Map和Map1对象
        mapObject = GameObject.Find("Map");
        map1Object = GameObject.Find("Map1");
        
        // 游戏开始时，通过射线向下探测，确定初始位置在哪一格
        UpdateCurrentPosFromPhysics();

        // ★2026-09-11 篝火点：玩家初始位置生成篝火（战术卡槽调整入口）
        //   但「出生格=家=撤离点」的图（雾镇）里这是错的——家格不该兼作篝火，
        //   由 createBonfireAtSpawn 开关关闭（教学篇 §2：篝火 ≠ 撤离点 ≠ 藏身处）。
        if (createBonfireAtSpawn)
        {
            BonfireTile.CreateAtStart(currentCoord);
        }

        // 初始化Map1格子的颜色为黑色
        InitializeMap1Colors();
        
        // 初始化状态
        ClearPathDisplay();
    }
    
    /// <summary>
    /// 初始化Map1格子的颜色为黑色，同时建一份「坐标 → 格子」索引。
    /// ★2026-09-12：敌人视野高亮要一次取几十格，原 FindTileByCoordInMap1 是
    ///   「逐子物体字符串比较」的全表扫（200+ 格 × 几十次），鼠标移动会顿；
    ///   这里开局一次性建索引，之后 O(1) 命中。
    /// </summary>
    private void InitializeMap1Colors()
    {
        map1TileLookup.Clear();
        if (map1Object == null) return;

        // ★2026-09-15 地图重构：不再逐格"染黑"。
        //   Map1 合并网格的底色就是材质本色（黑），整层恢复一次即可；
        //   旧实现给 4000 格各塞一个 MaterialPropertyBlock，正是破坏合批、
        //   把这一层拖成 4000 条独立 draw call 的元凶。
        HexTileColorizer.ResetAll();

        foreach (Transform child in map1Object.transform)
        {
            if (!child.name.StartsWith("Hex_")) continue;

            // 名字格式固定 Hex_x_y；解析失败只跳过索引，不影响染色
            string[] parts = child.name.Split('_');
            if (parts.Length == 3 && int.TryParse(parts[1], out int cx) && int.TryParse(parts[2], out int cy))
            {
                map1TileLookup[new Vector2Int(cx, cy)] = child.gameObject;
            }
        }

        // ★2026-09-15：记录索引应有条数（见 map1ExpectedCount 声明处的说明）
        map1ExpectedCount = map1TileLookup.Count;
    }

    void Update()
    {
        // ★2026-09-14 开发者面板（F9）打开期间：地图鼠标交互全部让路——
        // 悬停预览、路径高亮、点击移动、行动点刷新后重画预览一个都不做。
        if (Interactions.DevPanelOpen)
            return;

        // ★2026-08-18：卡牌交互流期间（拖动/点击跟随/箭头指向）禁用全部移动交互——
        // 点击移动、移动路径预览高亮、鼠标指向格子高亮全不响应。
        // 修"出牌时移动功能仍生效"系列 bug；进流时已由 HandUIController
        // 调 ClearAllMoveHighlights() 彻底清过旧高亮，此处直接返回即可。
        if (Interactions.CardInteractionActive)
            return;

        // ★探索事件弹窗模态锁（2026-08-25）：弹窗期间禁用全部移动交互
        if (Interactions.ModalPopupActive)
            return;

        // 如果正在移动，不处理鼠标操作
        if (isMoving)
            return;

        // 检查行动点是否变化，如果变化则刷新路径预览
        if (currentActionPoints != lastActionPoints)
        {
            lastActionPoints = currentActionPoints;
            // 如果鼠标悬停在格子上，刷新路径预览
            if (lastHoverCoord != new Vector2Int(-999, -999))
            {
                UpdateHoverEffect(lastHoverCoord);
            }
        }

        // 处理鼠标悬停检测
        HandleMouseHover();

        // 处理点击移动
        HandleMouseClick();
    }

    void HandleMouseHover()
    {
        if (isMoving) return; // 移动时锁死悬停

        // 检查是否悬停在UI元素上
        if (EventSystem.current.IsPointerOverGameObject())
        {
            // 清除路径高亮、视野高亮和悬停高亮
            ClearPathDisplay();
            ClearVisionHighlight();
            ClearHoverHighlight();
            lastHoverCoord = new Vector2Int(-999, -999);
            return;
        }
        
        Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
        if (Physics.Raycast(ray, out RaycastHit hit))
        {
            if (hit.collider.CompareTag("Ground") && hit.collider.name.StartsWith("Hex_"))
            {
                GameObject tile = hit.collider.gameObject;
                // 检查格子是否属于Map
                if (!IsTileInMap(tile))
                    return;
                
                // 提取坐标
                string[] parts = tile.name.Split('_');
                Vector2Int hoverCoord = new Vector2Int(int.Parse(parts[1]), int.Parse(parts[2]));

                // 【关键点】：坐标变了才刷新，否则不执行
                if (hoverCoord != lastHoverCoord)
                {
                    lastHoverCoord = hoverCoord;
                    UpdateHoverEffect(hoverCoord);
                }
            }
        }
        else
        {
            // 没射中任何格子，清理路径高亮、视野高亮和悬停高亮
            ClearPathDisplay();
            ClearVisionHighlight();
            ClearHoverHighlight();
            lastHoverCoord = new Vector2Int(-999, -999);
        }
    }

    void UpdateHoverEffect(Vector2Int targetCoord)
    {
        // 1. 获取Map1层对应的渲染格子
        GameObject targetTile = FindTileByCoordInMap1(targetCoord);
        
        // 如果获取不到格子，直接退出
        if (targetTile == null)
        {
            // 没射中任何格子，清理路径高亮、视野高亮和悬停高亮
            ClearPathDisplay();
            ClearVisionHighlight();
            ClearHoverHighlight();
            return;
        }

        // 2. 清除旧的路径高亮、视野高亮和悬停高亮
        ClearPathDisplay();
        ClearVisionHighlight();
        ClearHoverHighlight();

        // ★2026-08-19 单位占位：有单位（敌我不论）的格子不可到达——
        // 悬停显示红色提示，不画路径预览（点击移动也会被 HandleMouseClick 拒绝）
        if (UnitOccupancy.IsOccupied(targetCoord))
        {
            // ★2026-09-12：悬停到敌人自己那格时，它当然「看得见自己」→ 顺带标出它的视野
            HighlightEnemyVision(targetCoord);
            hoveredTile = targetTile;
            HighlightTile(targetTile, occupiedTileColor);
            return;
        }

        // 3. 执行路径预览
        RefreshPathPreview(targetCoord);

        // 3.5 ★2026-09-12 敌人视野高亮：只染「路径没盖到」的格，避免与路径黄互相覆盖
        HighlightEnemyVision(targetCoord);

        // 4. 高亮鼠标悬停的格子
        hoveredTile = targetTile;
        HighlightTile(hoveredTile);
    }


    void HandleMouseClick()
    {
        if (Input.GetMouseButtonDown(0))
        {
            // 检查是否点击了UI元素
            if (EventSystem.current.IsPointerOverGameObject())
                return;
                
            // ★2026-09-12：光是行动点为 0 不代表走不动了——探索骰还能买路程。
            //   用总预算判断（= 行动点 + 本回合还能拿的骰子 × 每骰格数）。
            if (MoveBudget <= 0)
                return;
                
            Ray ray = Camera.main.ScreenPointToRay(Input.mousePosition);
            if (Physics.Raycast(ray, out RaycastHit hit))
            {
                if (hit.collider.CompareTag("Ground") && hit.collider.name.StartsWith("Hex_"))
                {
                    GameObject tile = hit.collider.gameObject;
                    // 检查格子是否属于Map
                    if (!IsTileInMap(tile))
                        return;
                    
                    string[] parts = tile.name.Split('_');
                    Vector2Int targetCoord = new Vector2Int(int.Parse(parts[1]), int.Parse(parts[2]));
                    
                    // 不能点击自己所在的格子
                    if (targetCoord == currentCoord)
                        return;

                    // ★2026-09-12 教学门禁：教程锁 / 限定格 / 禁行格（TutorialDirector 维护）
                    //   锁输入但配了限定格时，仍放行「到限定格」的移动
                    //   （S6 靠近敌人：锁出牌/结束回合/耗骰，但允许玩家走到 allowedCell）
                    if (Interactions.TutorialLockInput
                        && !(Interactions.TutorialAllowedCell.HasValue && targetCoord == Interactions.TutorialAllowedCell.Value))
                        return;
                    if (Interactions.TutorialAllowedCell.HasValue && targetCoord != Interactions.TutorialAllowedCell.Value)
                        return;
                    if (Interactions.TutorialBlockedCells.Contains(targetCoord))
                        return;

                    // ★2026-08-19 单位占位：有其他单位（敌我不论）的格子不可到达，点击无效
                    if (UnitOccupancy.IsOccupied(targetCoord))
                        return;
                    
                    // 使用A*寻路
                    List<Vector2Int> path = Pathfinding.FindPath(currentCoord, targetCoord);
                    if (path != null && path.Count > 0)
                    {
                        // 立即设置移动锁，防止在协程启动前再次触发
                        isMoving = true;
                        StartCoroutine(MoveSequence(path));
                    }
                }
            }
        }
    }

    void RefreshPathPreview(Vector2Int targetCoord)
    {
        // ★2026-09-12 教学门禁：限定格外不画路径预览（只允许走向教程指定格）
        if (Interactions.TutorialAllowedCell.HasValue && targetCoord != Interactions.TutorialAllowedCell.Value)
            return;

        // 使用A*寻路
        List<Vector2Int> path = Pathfinding.FindPath(currentCoord, targetCoord);
        if (path == null || path.Count == 0) return;

        TerrainManager terrainManager = CachedTerrain;
        // ★2026-09-12：预算 = 行动点 + 探索骰能买的路程（两态同规则，参数分流）
        int budget = MoveBudget;
        int remaining = budget;

        for (int i = 0; i < path.Count; i++)
        {
            Vector2Int coord = path[i];
            
            int moveCost = terrainManager?.GetActionCost(coord) ?? 1;
            if (remaining < moveCost && i > 0) break; // 跳过起点的移动成本检查

            // 起点不消耗行动点
            if (i > 0)
            {
                remaining -= moveCost;
            }

            GameObject tile = FindTileByCoordInMap1(coord);
            if (tile != null)
            {
                // 先追踪格子，保存原始颜色
                TrackTile(tile);
                // 高亮格子：整条路径统一用原来的黄（★用户 2026-09-12 定稿：
                //   不做「超支段」的颜色区分——要花几枚骰子由右下角骰子自己显示，路径保持干净）
                HighlightTile(tile, pathColor);

                // 起点不显示文字，其余格子显示「走到这里后还剩多少行动力」
                if (i > 0)
                {
                    ShowAPText(tile, remaining.ToString(), pathColor);
                }
            }
        }

        // ★悬停预览：把「这一步要吃掉几枚骰」同步到右下角骰子 UI（半透明）
        DiceSpendPreview.Show(DiceNeededFor(budget - remaining));
    }

    void HighlightTile(GameObject tile, Color? colorOverride = null)
    {
        if (tile == null) return;

        // ★2026-09-15 地图重构：格子不再自带渲染器 → 解析坐标后交给层渲染器
        //   默认路径黄；占位格等特殊语义由调用方传 colorOverride（★2026-08-19）
        HexTileColorizer.SetColor(HexTile.CoordOf(tile), colorOverride ?? pathColor);
    }

    void ShowAPText(GameObject tile, string text, Color color)
    {
        if (tile != null)
        {
            Vector3 textPosition = new Vector3(tile.transform.position.x, 0.251f, tile.transform.position.z);
            GameObject textObj = CreateActionPointText(textPosition, text, color);
            tileToTextMap.Add(tile, textObj);
        }
    }

    void TrackTile(GameObject tile)
    {
        if (tile != null)
        {
            // 保存格子的默认颜色（黑色），而不是当前颜色
            pathOriginalColors.Add(Color.black);
            pathTiles.Add(tile);
        }
    }

    // ------------------------------------------------------------------
    // ★2026-09-12 敌人视野高亮（移动前预警）
    // ------------------------------------------------------------------

    /// <summary>
    /// 把「看得见 <paramref name="hoverCoord"/> 这一格」的敌人的视野范围染成
    /// <see cref="enemyVisionColor"/>，让玩家在点下去之前就能看出「这一步会不会踩进视野」。
    ///
    /// 规则：
    ///   ① 只显示「看得见鼠标格」的敌人视野（鼠标格不在任何视野内 → 一格都不染，保持画面干净）；
    ///   ② **禁用条件**（★2026-09-12 用户定，见 <see cref="IsVisionHintDisabled"/>）：
    ///      玩家已在该敌视野内 / 该敌有红`!`（警戒·战斗意图，含被同队传导的）/ 该敌处于战斗意图 → 不显示；
    ///      只有没有红`!`的搜寻·休整阶段（黄`?`/白`?`/陷阱搜查）才恢复显示；
    ///   ③ **路径优先**：已在移动路径预览里染过黄的格子跳过，两套染色不互相覆盖；
    ///   ④ 视野判定与警戒触发同源（<see cref="VisionSystem.CanSee"/> 直线判定，不拐弯），
    ///      保证「看到的红区」与「实际会触发战斗的范围」严格一致；
    ///   ⑤ ★2026-09-17 **玩家视角门禁**：鼠标格与敌人本人都必须在玩家自己视野内
    ///      （玩家视野只吃红格、10 格），墙后 / 视野外的敌人不显示视野。
    /// </summary>
    void HighlightEnemyVision(Vector2Int hoverCoord)
    {
        // ★2026-09-16 玩家视野门禁（用户反馈：视野外的格子依旧能悬停查看敌人视野）。
        //   鼠标格本身必须在玩家自己看得见的地方 —— EnemyRenderLod 已经把玩家视野外的敌人
        //   整体裁掉了，这里若还画出它的视野范围（连它人在哪都暴露了），两处口径就打架。
        //   同源判定：PlayerVisionRange + 只吃红格（玩家视野不扣绿格），与 EnemyRenderLod 一致。
        if (!VisionSystem.CanSee(currentCoord, hoverCoord, VisionSystem.PlayerVisionRange, false)) return;

        // ★2026-09-15 性能：改用 UnitOccupancy 的存活单位注册表。
        //   原实现每次悬停都 Object.FindObjectsOfType<EnemyController>()：雾镇图
        //   1.2 万对象实测 3.47ms/次，而鼠标每滑过一格就会调一次本方法。
        IReadOnlyList<EnemyController> enemies = UnitOccupancy.LivingEnemies;
        int enemyCount = enemies.Count;
        if (enemyCount == 0) return;

        for (int i = 0; i < enemyCount; i++)
        {
            EnemyController enemy = enemies[i];
            if (enemy == null || enemy.IsDead || enemy.data == null) continue;

            int range = enemy.data.visionRange;
            if (range <= 0) continue;

            Vector2Int center = enemy.CurrentCoord;

            // ★2026-09-17 玩家视角门禁（用户实测反馈）：不在玩家视野内的敌人（红墙后 / 10 格外）
            //   不显示其视野——看不见它人，就不该看到它的视野范围。
            if (!VisionSystem.CanSee(currentCoord, center, VisionSystem.PlayerVisionRange, false)) continue;

            // ① 该敌人看不见鼠标格（红/绿直线判定同源）→ 不显示它的视野
            if (!VisionSystem.CanSee(center, hoverCoord, range, VisionSystem.EnemyGreenPenalty)) continue;

            // ② 禁用条件：玩家已在它视野内 / 该敌处于战斗意图（含追击）
            if (IsVisionHintDisabled(enemy, range)) continue;

            // 染它整个视野（可见集 = 红/绿阻挡后的真实视野形状，与警戒触发同源）
            foreach (Vector2Int coord in VisionSystem.GetVisibleSet(center, range, VisionSystem.EnemyGreenPenalty))
            {
                GameObject tile = FindTileByCoordInMap1(coord);
                if (tile == null) continue;
                if (pathTiles.Contains(tile)) continue;          // 路径优先：与移动路径预览不互相覆盖
                if (!visionTileSet.Add(tile)) continue;          // 多敌人视野重叠：同一格只染一次（O(1) 去重）

                // ★2026-09-15 地图重构：解析坐标 → 层渲染器染色（不再要求格子自带渲染器）
                HexTileColorizer.SetColor(HexTile.CoordOf(tile), enemyVisionColor);
                visionTiles.Add(tile);
            }
        }
    }

    /// <summary>
    /// ★2026-09-12 用户定：该敌人的视野提示是否禁用。
    ///   ① 玩家已经在它视野内 —— 它已经看见你了，再画红区没有预警意义（提示"消失"）；
    ///   ② **红`!`**（警戒 / 战斗意图）—— 不论是探索态巡逻中发现玩家（含陷阱整队红`!`、
    ///      探索态追击），还是战斗态散开搜寻期间被同小队意图传导的红`!`：都已锁定玩家，
    ///      即使中途跑出它的视野也保持禁用；
    ///   ③ 战斗意图中的参战者（战斗态、非问号/搜寻阶段，含意图文本「追击」）—— 同上。
    ///   只有**没有红`!`的搜寻/休整阶段**（黄`?`、白`?` 归队回血、陷阱搜查）才重新启用。
    /// </summary>
    bool IsVisionHintDisabled(EnemyController enemy, int range)
    {
        // ① 玩家已在它视野内（与警戒触发同源判定，红/绿阻挡）
        if (VisionSystem.CanSee(enemy.CurrentCoord, currentCoord, range, VisionSystem.EnemyGreenPenalty)) return true;

        // ② 红`!`：所有红`!`入口都过 BecomeAlerted（探索态发现玩家 / 同队意图传导 / 陷阱整队警戒）
        if (enemy.IsAlerted) return true;

        // ③ 战斗意图（战斗态参战者，且不在问号/搜寻阶段）
        return AlertPropagation.IsFighting(enemy)
            && enemy.SearchPhase == EnemyController.DisengagePhase.None
            && !enemy.PendingTrapSearch;
    }

    /// <summary>清除视野高亮（恢复黑色底色，与 <see cref="ClearPathDisplay"/> 同源：Map1 层默认黑）。</summary>
    void ClearVisionHighlight()
    {
        for (int i = 0; i < visionTiles.Count; i++)
        {
            if (visionTiles[i] == null) continue;
            HexTileColorizer.SetColor(HexTile.CoordOf(visionTiles[i]), Color.black);
        }
        visionTiles.Clear();
        visionTileSet.Clear();   // ★2026-09-15：去重集合与列表同生同灭
    }

    IEnumerator MoveSequence(List<Vector2Int> path)
    {
        // ★2026-08-23 防御：移动一开始先清掉可能残留的旧落点锁定值，
        // 空路径 / 中断都能保证 MovingDestCoord 不残留，随后再按本次移动重新锁定。
        MovingDestCoord = null;

        if (path == null || path.Count == 0) { isMoving = false; yield break; }

        // 找到TerrainManager实例（预演落点与下方执行循环共用）
        TerrainManager terrainManager = CachedTerrain;

        // ★2026-08-23 移动开始：锁定本次移动的预计最终落点（预演判定与下方执行循环
        // 完全一致——地形不可通行跳过 / 行动点不足截断 / 行动点耗尽即停）。
        // 整段移动期间敌方意图视觉统一按该落点解算，结束时 CurrentCoord 恰好=落点，无缝衔接。
        //
        // ★2026-09-12：预算里含「探索骰能买的路程」，所以落点可能超出当前行动点。
        //   先按预算算落点与总成本 → 立刻把要花的骰子扣掉并转成行动点 →
        //   下面的执行循环（以及 AP 显示 / 警戒 / 事件结算）完全不用改。
        int totalCost;
        MovingDestCoord = ComputeMoveDestination(path, terrainManager, out totalCost);

        int diceNeed = DiceNeededFor(totalCost);
        if (diceNeed > 0 && !PayDiceForMove(diceNeed))
        {
            // 骰池比预览时少了（同一帧内的极端并发）→ 按缩水后的预算重算落点，别走出免费额度
            Debug.LogWarning($"[移动] 探索骰不足（需要 {diceNeed} 枚），按实际余额重算落点");
            MovingDestCoord = ComputeMoveDestination(path, terrainManager, out totalCost);
        }

        // 准备起点
        PrepareStartTile();

        // 通知相机开始跟随玩家
        CameraController.Instance?.StartFollowingPlayer();
        
        // 按照路径移动
        for (int i = 0; i < path.Count; i++)
        {
            Vector2Int coord = path[i];
            
            // 跳过起点
            if (i == 0)
            {
                continue;
            }
            
            // 检查地形是否可通行
            if (terrainManager != null && !terrainManager.IsPassable(coord))
            {
                continue;
            }
            
            // 计算移动成本
            int moveCost = terrainManager?.GetActionCost(coord) ?? 1;
            
            // 检查行动点是否足够
            if (currentActionPoints < moveCost)
            {
                // 行动点不足，停止移动
                break;
            }
            
            // 消耗行动点
            currentActionPoints = Mathf.Max(0, currentActionPoints - moveCost);
            
            // 找到对应的格子物体
            GameObject tile = FindTileByCoord(coord);
            if (tile != null)
            {
                yield return StartCoroutine(SmoothMoveTo(tile));
                // 更新当前坐标
                currentCoord = coord;

                // ★2026-09-12 移动中视野脉冲（用户定）：每踏进一格立即查「是否进入敌方视野」——
                // 踏进瞬间该敌立即出感叹号/问号并刷新意图，不等玩家停步（旧行为只在移动结束查落点）。
                VisionPulseOnStep();
                
                // 清理当前步骤（到达一格删一格）
                CleanupStep(coord);

                // ★2026-09-12 教学检查点：踏入检查点格 → 立即中断后续移动
                //（FinalizeMove 正常收尾 → OnPlayerArrived 交给 TutorialDirector 挂起回合）
                if (Interactions.TutorialCheckpointCells.Contains(coord))
                {
                    Debug.Log($"[移动] 教学检查点命中 {coord}，中断剩余路径");
                    break;
                }
                
                // 如果行动点耗尽，停止移动
                if (currentActionPoints <= 0)
                {
                    break;
                }
            }
        }
        
        // 完成移动
        FinalizeMove();
    }

    void PrepareStartTile()
    {
        // 清除起点的高亮，将其设置为原有颜色
        // 找到玩家当前所在的格子
        GameObject startTile = FindTileByCoordInMap1(currentCoord);
        if (startTile != null)
        {
            // 清除高亮（★2026-09-15 地图重构：改传坐标，格子已无渲染器）
            HexTileColorizer.SetColor(currentCoord, Color.black); // 恢复为黑色底色
            
            // 从路径列表中移除
            if (pathTiles.Contains(startTile))
            {
                int idx = pathTiles.IndexOf(startTile);
                pathTiles.RemoveAt(idx);
                if (idx < pathOriginalColors.Count) pathOriginalColors.RemoveAt(idx);
            }
            
            // 清除行动点文本
            if (tileToTextMap.ContainsKey(startTile))
            {
                Destroy(tileToTextMap[startTile]);
                tileToTextMap.Remove(startTile);
            }
        }
    }

    IEnumerator SmoothMoveTo(GameObject targetTile)
    {
        // 获取格子物体的中心点世界坐标
        Vector3 targetCenter = targetTile.transform.position;
        // 保持玩家当前的高度，只在 X 和 Z 轴平移
        Vector3 destination = new Vector3(targetCenter.x, transform.position.y, targetCenter.z);

        while (Vector3.Distance(transform.position, destination) > 0.01f)
        {
            transform.position = Vector3.MoveTowards(transform.position, destination, moveSpeed * Time.deltaTime);
            yield return null;
        }
        transform.position = destination;
    }

    void CleanupStep(Vector2Int coord)
    {
        // 找到Map1中对应的格子
        GameObject map1Tile = FindTileByCoordInMap1(coord);
        if (map1Tile != null)
        {
            // 清除高亮（★2026-09-15 地图重构：改传坐标，格子已无渲染器）
            HexTileColorizer.SetColor(coord, Color.black);
            
            // 清除行动点文本
            if (tileToTextMap.ContainsKey(map1Tile))
            {
                Destroy(tileToTextMap[map1Tile]);
                tileToTextMap.Remove(map1Tile);
            }
            
            // 从路径列表中移除
            if (pathTiles.Contains(map1Tile))
            {
                int idx = pathTiles.IndexOf(map1Tile);
                pathTiles.RemoveAt(idx);
                if (idx < pathOriginalColors.Count) pathOriginalColors.RemoveAt(idx);
            }
        }
    }

    /// <summary>
    /// ★2026-08-23 预演本次移动的最终落点（判定与 MoveSequence 执行循环逐步一致：
    /// 地形不可通行的格子跳过 / 行动点不足即截断 / 行动点耗尽即停）。
    /// 供 MovingDestCoord 在移动开始时锁定，敌方意图视觉整段移动期间按此落点解算不跳动。
    /// </summary>
    private Vector2Int ComputeMoveDestination(List<Vector2Int> path, TerrainManager terrainManager, out int totalCost)
    {
        totalCost = 0;
        Vector2Int dest = path[0]; // 起点（一格都走不动时=原地）
        // ★2026-09-12：与 RefreshPathPreview 同一口径 —— 预算 = 行动点 + 探索骰能买的路程
        int left = MoveBudget;
        for (int i = 1; i < path.Count; i++)
        {
            Vector2Int coord = path[i];
            if (terrainManager != null && !terrainManager.IsPassable(coord)) continue;
            // ★P1 修复：与 MoveSequence 执行循环严格一致——实际移动只在
            // FindTileByCoord(coord) 非空时才推进 currentCoord，找不到 Hex_ 格子的坐标会被跳过。
            // 之前预演漏掉此判断 → MovingDestCoord(预演落点) 与 CurrentCoord(真实落点) 分叉，
            // 造成移动期间预览按错误落点解算（dumb）。补上后两者恒等，锁可安全启用。
            if (FindTileByCoord(coord) == null) continue;
            int moveCost = terrainManager?.GetActionCost(coord) ?? 1;
            if (left < moveCost) break;
            left = Mathf.Max(0, left - moveCost);
            totalCost += moveCost;
            dest = coord;
            if (left <= 0) break;
        }
        return dest;
    }

    /// <summary>
    /// ★2026-09-12 用户需求：移动途中每落一格的视野脉冲（不等移动结束）——
    /// 玩家只要在移动中踏进某敌视野，该敌立即显示感叹号/问号并按规则刷新意图：
    ///   探索态 → ExplorationTurnManager（AlertPropagation.Refresh + F3.3 能量转化立即生效）；
    ///   战斗态 → AlertPropagation.Refresh + TurnManager（问号阶段参战者立即 ReEngageOnSight 切战斗意图）。
    /// 与 FinalizeMove 的落点检测同口径、同顺序——幂等，重复触发不会二次生效。
    /// </summary>
    void VisionPulseOnStep()
    {
        if (GameStateManager.Instance == null) return;

        if (GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            ExplorationTurnManager.Instance?.OnPlayerStepped();
        }
        else
        {
            AlertPropagation.Refresh();
            TurnManager.Instance?.OnPlayerStepped();
        }
    }

    void FinalizeMove()
    {
        // ★2026-08-23 移动结束：解除视觉锁定，恢复正常「按玩家真实坐标」解算。
        // 此时 CurrentCoord 已=落点（预演与执行判定一致），视觉无缝衔接不跳变。
        MovingDestCoord = null;

        // 彻底清理
        ClearAllMoveHighlights();

        // ★2026-09-12 教学钩子：广播落点坐标（探索/战斗都广播，由订阅方自行按状态过滤）
        OnPlayerArrived?.Invoke(currentCoord);

        // 解除移动锁
        isMoving = false;

        // 通知相机停止跟随玩家
        CameraController.Instance?.StopFollowingPlayer();

        // 通知回合管理器移动已结束
        // ★探索系统第一步（2026-08-25）：按游戏模式分流——
        // 探索态 → ExplorationTurnManager（移动中请求结束回合的补执行）；
        // 战斗态 → TurnManager（原有逻辑不变）
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            ExplorationTurnManager.Instance?.OnMoveEnded();
        }
        else
        {
            AlertPropagation.Refresh();
            TurnManager.Instance?.OnMoveEnded();
        }

        // ★遗物袋（用户定 2026-09-09：停留弹、路过不停）：移动彻底结束后，以最终站位查落点格开搜刮窗。
        // 此时 currentCoord 已是最终站位、isMoving 已解锁，模态锁不会和移动锁互相踩。
        OpenPendingLoot();
    }

    /// <summary>
    /// 落点停在遗物袋格时开搜刮窗（路过不停，spec §8 用户定 2026-09-09）。
    /// 落点上若已经有别的模态窗（事件格弹窗），让事件窗先走：ModalPopupActive 是单个 bool、
    /// 没有引用计数，两个窗都置 true 时先关的那个会提前放锁，另一个窗还开着但玩家已经能移动。
    /// 遗物袋留在地上不会丢——走开再走回来（落点再次停在该格）会重新触发。
    /// </summary>
    void OpenPendingLoot()
    {
        if (!LootAllowed()) return;

        CorpseContainer corpse = CorpseRegistry.Get(currentCoord);
        if (corpse == null) return;

        if (Interactions.ModalPopupActive)
        {
            Debug.Log($"[HexMover] Hex_{corpse.Coord.x}_{corpse.Coord.y} 的遗物袋暂不搜刮：落点已有模态弹窗");
            return;
        }

        LootPopupUI.OpenFor(corpse);
    }

    /// <summary>遗物袋只在探索态搜刮：战斗中停在尸体格不打断战斗节奏，袋子留着战后拿。</summary>
    static bool LootAllowed()
    {
        return GameStateManager.Instance != null &&
               GameStateManager.Instance.CurrentState == GameState.Exploring;
    }

    /// <summary>
    /// ★2026-08-23 玩家回合开始安全重置：强制清掉可能残留的落点锁定值与移动锁，
    /// 覆盖「移动被中断（StopCoroutine 等）导致 FinalizeMove 未执行」的极端情况——
    /// 否则 isMoving 卡在 true / MovingDestCoord 残留，会让静止时的敌方预览
    /// 误用旧坐标，造成预览≠执行。由 TurnManager 在玩家回合开始调用。
    /// </summary>
    public void ForceResetMoveForTurnStart()
    {
        MovingDestCoord = null;
        isMoving = false;
    }

    /// <summary>
    /// ★2026-08-18：彻底清除全部移动相关高亮（路径预览 + 悬停格 + Map1 全图保险）。
    /// 公开方法：HandUIController 进卡牌交互流时调用——
    /// 先清移动高亮再显示射程高亮，避免两套染色互相覆盖/残留
    /// （ClearHoverHighlight/ClearMap1Highlights 恢复的是硬编码黑色，
    ///  若不清就叠射程染色，Clear 时会把格子恢复成"移动黄"导致残留）。
    /// </summary>
    public void ClearAllMoveHighlights()
    {
        // ★2026-08-17 性能：悬停卡牌（NotifyCardHovered）每次都会调本方法，
        // 全图 ~200 格逐个 SetColor 会造成轻微卡顿。没有任何移动高亮痕迹时
        // 直接跳过（pathTiles/hoveredTile/visionTiles 是本类全部染色记录，空=无残留）。
        if (pathTiles.Count == 0 && hoveredTile == null && visionTiles.Count == 0) return;

        ClearPathDisplay();
        ClearVisionHighlight();
        ClearHoverHighlight();
        ClearMap1Highlights();
    }
    
    /// <summary>
    /// 清除Map1层所有格子的高亮
    /// </summary>
    private void ClearMap1Highlights()
    {
        // ★2026-09-15 地图重构：整层恢复一次即可（旧实现遍历 4000 格逐个恢复）
        HexTileColorizer.ResetAll();
    }

    // 清除路径显示
    void ClearPathDisplay()
    {
        // 恢复路径格子的原始颜色
        for (int i = 0; i < pathTiles.Count; i++)
        {
            if (pathTiles[i] != null && i < pathOriginalColors.Count)
            {
                // ★2026-09-15 地图重构：改传坐标，格子已无渲染器
                HexTileColorizer.SetColor(HexTile.CoordOf(pathTiles[i]), pathOriginalColors[i]);
            }
        }
        // 清空列表
        pathTiles.Clear();
        pathOriginalColors.Clear();
        
        // 清理行动点文本
        foreach (GameObject textObj in tileToTextMap.Values)
        {
            if (textObj != null)
            {
                Destroy(textObj);
            }
        }
        tileToTextMap.Clear();

        // ★2026-09-12：路径没了 → 骰子「即将被消耗」的预览也要一起撤（否则半透明会残留）
        DiceSpendPreview.Clear();
    }
    
    /// <summary>
    /// 清除鼠标悬停的高亮
    /// </summary>
    void ClearHoverHighlight()
    {
        if (hoveredTile != null)
        {
            // ★2026-09-15 地图重构：改传坐标，格子已无渲染器
            HexTileColorizer.SetColor(HexTile.CoordOf(hoveredTile), Color.black); // 恢复为黑色底色
            hoveredTile = null;
        }
    }

    // 创建行动点文本
    GameObject CreateActionPointText(Vector3 position, string text, Color color)
    {
        // 创建文本对象
        GameObject textObj = new GameObject("ActionPointText");
        textObj.transform.position = position;
        
        // 添加TextMesh组件
        TextMesh textMesh = textObj.AddComponent<TextMesh>();
        textMesh.text = text;
        textMesh.color = color;
        textMesh.fontSize = 80; // 增大字体大小
        textMesh.characterSize = 0.1f; // 增大字符大小，放大文本
        textMesh.anchor = TextAnchor.MiddleCenter;
        textMesh.alignment = TextAlignment.Center;
        textMesh.fontStyle = FontStyle.Bold; // 使用粗体提高清晰度
        
        // 固定文本旋转角度，确保数字正确显示
        textObj.transform.rotation = Quaternion.Euler(90, 0, 0);
        
        return textObj;
    }

    bool IsTileInMap(GameObject tile)
    {
        // 检查单元格的父对象是否是map
        Transform parent = tile.transform.parent;
        while (parent != null)
        {
            if (parent.name == "Map")
            {
                return true;
            }
            parent = parent.parent;
        }
        return false;
    }
    
    GameObject FindTileByCoord(Vector2Int coord)
    {
        if (mapObject != null)
        {
            foreach (Transform child in mapObject.transform)
            {
                if (child.name == $"Hex_{coord.x}_{coord.y}")
                {
                    return child.gameObject;
                }
            }
        }
        return null;
    }
    
    GameObject FindTileByCoordInMap1(Vector2Int coord)
    {
        // ★2026-09-12：优先走开局建好的坐标索引（O(1)）；未命中再回退全表扫
        //   （索引尚未建立、或地图烘焙后新增的格子走这条）。
        if (map1TileLookup.TryGetValue(coord, out GameObject cached))
        {
            // ★2026-09-15：不再 Remove 掉已销毁的条目——字典条数本身就是
            //   「索引是否完整」的判据（见下方快路径），删条目会让判据失效。
            if (cached != null) return cached;
        }

        // ★2026-09-15 性能：索引「完整」时未命中 ⇒ 该坐标真的没有格子，直接返回 null。
        //   敌人视野按六边形包围盒枚举，贴边的怪会算出地图外坐标（例：怪在 x=78、视野 3
        //   会枚举到 x=81 > 右边界 79）；旧实现对这些坐标逐个回退扫 Map1 的 4000 个子物体
        //   ——实测 2.63ms/次。东边一只怪一次悬停要付 18 次 ≈ 47ms，就是
        //   「鼠标扫进敌人视野就卡」的真身。
        //   判据「索引条数 ≥ Map1 子物体数」＝ 每个子物体都已入索引；地图烘焙后新增了
        //   格子时条数会小于子物体数 → 自动退回下面的扫描，行为保持保守。
        //   ★2026-09-15 地图重构后的判据修正：原用 transform.childCount，但合并网格容器
        //   _HexBatch 也是 Map1 的子节点，会让 childCount 永远比索引条数多 1、快路径永远不生效。
        //   改用 InitializeMap1Colors 统计的「应有条数」。
        if (map1ExpectedCount > 0 && map1TileLookup.Count >= map1ExpectedCount)
        {
            return null;
        }

        if (map1Object != null)
        {
            foreach (Transform child in map1Object.transform)
            {
                if (child.name == $"Hex_{coord.x}_{coord.y}")
                {
                    // ★2026-09-15：扫描命中回填索引——地图重烘后只扫一次，不退回「每次全表扫」
                    map1TileLookup[coord] = child.gameObject;
                    return child.gameObject;
                }
            }
        }
        return null;
    }

    void UpdateCurrentPosFromPhysics()
    {
        if (Physics.Raycast(transform.position, Vector3.down, out RaycastHit hit))
        {
            if (hit.collider.name.StartsWith("Hex_"))
            {
                // 检查格子是否属于Map
                if (IsTileInMap(hit.collider.gameObject))
                {
                    string[] parts = hit.collider.name.Split('_');
                    currentCoord = new Vector2Int(int.Parse(parts[1]), int.Parse(parts[2]));
                }
            }
        }
    }
    
    /// <summary>
    /// 获取玩家是否正在移动
    /// </summary>
    public bool IsMoving()
    {
        return isMoving;
    }

    /// <summary>
    /// 设置当前行动点
    /// </summary>
    /// <param name="ap">行动点数量</param>
    public void SetActionPoints(int ap)
    {
        currentActionPoints = ap;
    }

    /// <summary>
    /// 当前鼠标悬停的格子坐标（无悬停时返回 (-999,-999)）。
    /// 供 §3.8 移动预览系统（EnemyMovePreview）复用，避免重复做射线检测。
    /// </summary>
    public Vector2Int CurrentHoverCoord => lastHoverCoord;

    /// <summary>
    /// 判断某格是否为「当前行动点内可达」的格子（玩家可实际走到）。
    /// §3.8 移动预览「只算可达格」复用；成本口径与 <see cref="RefreshPathPreview"/>/<see cref="MoveSequence"/> 一致：
    /// 起点不耗 AP，路径每格消耗 TerrainManager.GetActionCost，任一格消耗超过剩余 AP 即不可达。
    /// </summary>
    /// <param name="targetCoord">目标格坐标</param>
    public bool IsReachable(Vector2Int targetCoord)
    {
        // 自己所在格不是「可达候选格」（无需移动）
        if (targetCoord == currentCoord) return false;

        // ★2026-08-19 单位占位：有单位（敌我不论）的格子不可到达
        if (UnitOccupancy.IsOccupied(targetCoord)) return false;

        List<Vector2Int> path = Pathfinding.FindPath(currentCoord, targetCoord);
        if (path == null || path.Count == 0) return false;

        TerrainManager terrainManager = CachedTerrain;
        // ★2026-09-12：与 RefreshPathPreview / ComputeMoveDestination 同口径（含探索骰买的路程）
        int remaining = MoveBudget;
        for (int i = 1; i < path.Count; i++) // 起点 i=0 不消耗
        {
            int cost = terrainManager?.GetActionCost(path[i]) ?? 1;
            if (remaining < cost) return false;
            remaining -= cost;
        }
        return true;
    }
}

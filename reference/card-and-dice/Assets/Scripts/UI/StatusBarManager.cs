using UnityEngine;
using TMPro;

public class StatusBarManager : MonoBehaviour
{
    [Header("UI References")]
    public TextMeshProUGUI turnText;
    public TextMeshProUGUI actionPointsText;
    public TextMeshProUGUI diceText;

    [Header("M5a 玩家血量（左上角 x/x）")]
    [Tooltip("血量文本，显示 血量 x/x。位于 StatusBar 左侧。")]
    public TextMeshProUGUI hpText;

    [Header("M5a 消耗品栏（Inspector 选填，不碰现有 DiceArea/ActionPointsText）")]
    [Tooltip("消耗品栏组件，挂在 StatusBar 下。Demo 阶段仅 UI 占位。")]
    public ConsumableBar consumableBar;
    
    private TurnManager turnManager;
    private HexMover playerMover;
    private PlayerHealth playerHealth;
    
    private void Start()
    {
        // 查找TurnManager和HexMover实例
        turnManager = FindObjectOfType<TurnManager>();
        playerMover = FindObjectOfType<HexMover>();
        playerHealth = FindObjectOfType<PlayerHealth>();
        
        // 查找UI文本对象
        GameObject statusBar = GameObject.Find("UICanvas/StatusBar");
        if (statusBar != null)
        {
            // 查找血量文本（左上角 x/x，M5a 新增）
            Transform hpTextTransform = statusBar.transform.Find("HPText");
            if (hpTextTransform != null)
            {
                hpText = hpTextTransform.GetComponent<TextMeshProUGUI>();
            }
            
            // 查找回合文本
            GameObject turnTextObj = statusBar.transform.Find("TurnText").gameObject;
            if (turnTextObj != null)
            {
                turnText = turnTextObj.GetComponent<TextMeshProUGUI>();
            }
            
            // 查找行动点文本
            GameObject actionPointsTextObj = statusBar.transform.Find("ActionPointsText").gameObject;
            if (actionPointsTextObj != null)
            {
                actionPointsText = actionPointsTextObj.GetComponent<TextMeshProUGUI>();
            }
            
            // 查找骰子文本（场景中可能不存在 DiceText 子对象，需先判空避免 .gameObject 抛 NRE）
            Transform diceTextTransform = statusBar.transform.Find("DiceText");
            if (diceTextTransform != null)
            {
                diceText = diceTextTransform.GetComponent<TextMeshProUGUI>();
            }
        }
        
        // 初始更新状态栏
        UpdateStatusBar();
    }
    
    private void Update()
    {
        // 每帧更新状态栏
        UpdateStatusBar();
    }
    
    /// <summary>
    /// 更新状态栏显示
    /// </summary>
    private void UpdateStatusBar()
    {
        // 只在需要时查找引用
        if (turnManager == null)
        {
            turnManager = FindObjectOfType<TurnManager>();
        }
        
        if (playerMover == null)
        {
            playerMover = FindObjectOfType<HexMover>();
        }
        
        if (playerHealth == null)
        {
            playerHealth = FindObjectOfType<PlayerHealth>();
        }
        
        if (turnText == null || actionPointsText == null || diceText == null || hpText == null)
        {
            FindUITextObjects();
        }
        
        // 更新玩家血量（左上角 x/x，F4.3）
        if (playerHealth != null && hpText != null)
        {
            hpText.text = $"血量 {playerHealth.CurrentHP}/{playerHealth.MaxHP}";
        }
        
        // 更新回合数（★2026-09-09 修复：按当前状态取对应回合数）。
        //    原实现只读 TurnManager（战斗回合）；战斗结束回到探索后战斗回合停更，
        //    顶栏数字就冻结在战斗结束那一回合不再变化（用户实测「回合数到了 3 后面就不走了」）。
        //    探索态 → ExplorationTurnManager；战斗态 → TurnManager。
        if (turnText != null)
        {
            GameState state = GameStateManager.Instance != null
                ? GameStateManager.Instance.CurrentState
                : GameState.Battle;

            int turnNumber = 0;
            if (state == GameState.Exploring)
            {
                ExplorationTurnManager exploreTurn = ExplorationTurnManager.Instance;
                if (exploreTurn == null) exploreTurn = FindObjectOfType<ExplorationTurnManager>();
                if (exploreTurn != null) turnNumber = exploreTurn.GetCurrentTurn();
            }
            else if (turnManager != null)
            {
                turnNumber = turnManager.GetCurrentTurn();
            }
            turnText.text = "回合 " + turnNumber;
        }

        // 骰子数同款口径：探索态显示本回合剩余探索骰，战斗态显示战斗骰池
        if (diceText != null)
        {
            GameState state = GameStateManager.Instance != null
                ? GameStateManager.Instance.CurrentState
                : GameState.Battle;

            if (state == GameState.Exploring)
            {
                ExplorationTurnManager exploreTurn = ExplorationTurnManager.Instance;
                if (exploreTurn == null) exploreTurn = FindObjectOfType<ExplorationTurnManager>();
                if (exploreTurn != null) diceText.text = "探索骰: " + exploreTurn.RemainingExplorationDice();
            }
            else if (turnManager != null)
            {
                diceText.text = "骰子: " + turnManager.GetPlayerDiceCount();
            }
        }
        
        // 更新行动点
        if (playerMover != null && actionPointsText != null)
        {
            actionPointsText.text = "行动点: " + playerMover.currentActionPoints;
        }

        // 远征材料：改读背包（spec §13：ExpeditionWallet 退役第一步）
        // 仅在场景已有 MaterialText 时写入，不改顶栏布局
        if (InventoryManager.Instance != null)
        {
            GameObject bar = GameObject.Find("UICanvas/StatusBar");
            Transform materialTf = bar != null ? bar.transform.Find("MaterialText") : null;
            if (materialTf != null)
            {
                TextMeshProUGUI materialText = materialTf.GetComponent<TextMeshProUGUI>();
                if (materialText != null)
                {
                    materialText.text = $"材料 {InventoryManager.Instance.MaterialCount}";
                }
            }
        }
    }
    
    /// <summary>
    /// 查找UI文本对象
    /// </summary>
    private void FindUITextObjects()
    {
        // 先查找StatusBar对象
        GameObject statusBar = GameObject.Find("UICanvas/StatusBar");
        if (statusBar != null)
        {
            // 从StatusBar中查找子对象
            Transform hpTextTransform = statusBar.transform.Find("HPText");
            if (hpTextTransform != null)
            {
                hpText = hpTextTransform.GetComponent<TextMeshProUGUI>();
            }
            
            Transform turnTextTransform = statusBar.transform.Find("TurnText");
            if (turnTextTransform != null)
            {
                turnText = turnTextTransform.GetComponent<TextMeshProUGUI>();
            }
            
            Transform actionPointsTextTransform = statusBar.transform.Find("ActionPointsText");
            if (actionPointsTextTransform != null)
            {
                actionPointsText = actionPointsTextTransform.GetComponent<TextMeshProUGUI>();
            }
            
            Transform diceTextTransform = statusBar.transform.Find("DiceText");
            if (diceTextTransform != null)
            {
                diceText = diceTextTransform.GetComponent<TextMeshProUGUI>();
            }
        }
    }
}
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using System.Collections.Generic;

public class EnergyPointDisplay : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    private Text energyText;
    private Button button;
    private int currentEnergy = 3;

    /// <summary>M5b-1：当前能量（公开只读，供 CardExecutor 检查/消耗）</summary>
    public int CurrentEnergy { get; private set; } = 3;

    /// <summary>
    /// ★2026-09-14 用户定稿：**能量上限**（公式文档 F1.1：energyMax = 9 + passiveBonus）。
    /// 这是全工程唯一的能量天花板——剩骰转能量、事件回能、消耗品回能、警戒即时转化、
    /// 教学赋值全部受它约束。
    ///
    /// 起因（用户纠偏）：此前把 9 记成「剩余骰子转能量上限」，写成两个场景字段
    /// （`diceToEnergyCapPerTurn` / `ambushLeftoverDiceEnergyCap`）各自写死；
    /// 而真正会给能量的消耗品（回能量药水 +2）与事件（energyChange）反而**没有上限**，
    /// 事件面板退款还在代码里硬编码 `Clamp(..., 0, 9)`。三处各写一个 9，语义还是错的。
    /// 现在收敛：能量上限只此一处，其余路径一律经过 <see cref="SetEnergy"/> 收敛。
    /// </summary>
    [Tooltip("能量上限（F1.1：9 + 被动加值）。所有能量获取途径的共同天花板。")]
    public int energyMax = 9;

    /// <summary>对外只读口径（公式文档称 energyMax）。</summary>
    public int EnergyMax => energyMax;

    /// <summary>
    /// P8：能量变化事件（参数 = 变化后的当前能量）。
    /// 触发时机：SetEnergy / PerformPrepare / TryConsumeEnergy。
    /// 订阅方：HandUIController（刷新手牌能量标识红/白）。
    /// </summary>
    public event System.Action<int> OnEnergyChanged;

    /// <summary>★2026-09-12 教学：任意一次整备（含自动整备）成功执行后广播。</summary>
    public static event System.Action OnPrepared;

    private int prepareGainEnergy = 3; // 每次整备获得的能量，默认为3
    private bool hasPreparedThisTurn = false;
    private string originalText;
    private GameObject diceAreaObj;

    void Awake()
    {
        // 同步 CurrentEnergy 初始值（同样受能量上限约束）
        currentEnergy = Mathf.Clamp(currentEnergy, 0, energyMax);
        CurrentEnergy = currentEnergy;

        // 缓存DiceArea对象
        diceAreaObj = GameObject.Find("UICanvas/StatusBar/DiceArea");
        
        // 自动查找子对象中的Text组件
        energyText = transform.Find("EnergyText").GetComponent<Text>();
        // 设置字体颜色为黑色
        energyText.color = Color.black;
        // 设置初始字体大小
        energyText.fontSize = 40;
        // 获取Button组件
        button = GetComponent<Button>();
        // 添加按钮点击事件
        button.onClick.AddListener(OnPrepareClick);
        UpdateEnergyDisplay();
        UpdateButtonInteractivity();
    }

    void Update()
    {
        // 实时更新按钮状态
        UpdateButtonInteractivity();
    }

    public void SetEnergy(int energy)
    {
        // ★2026-09-14：统一按**能量上限**收敛。所有回能路径最终都走这里
        // （剩骰转能量 / 事件 energyChange / 消耗品回能 / 警戒即时转化 / 教学赋值），
        // 天花板只有一个来源 energyMax。旧实现完全不设限：
        // 消耗品的「回能量2」能把能量顶到 9 以上（InventoryManager 注释原话「现有能量无上限实现」）。
        energy = Mathf.Clamp(energy, 0, energyMax);
        currentEnergy = energy;
        CurrentEnergy = energy;
        UpdateEnergyDisplay();
        OnEnergyChanged?.Invoke(CurrentEnergy);
    }

    /// <summary>
    /// ★2026-09-14：通用「获得能量」入口（受 <see cref="energyMax"/> 限制），返回实际增加量。
    /// 剩骰转能量走 <see cref="AddEnergyTowardCap"/>（额外带本次转化枚数上限），
    /// 其余来源（消耗品 / 事件 / 调试快捷键）一律走这里。
    /// </summary>
    public int AddEnergy(int amount)
    {
        if (amount <= 0) return 0;
        int before = CurrentEnergy;
        SetEnergy(before + amount);
        return CurrentEnergy - before;
    }

    /// <summary>
    /// 设置整备获得的能量值
    /// </summary>
    /// <param name="energy">整备获得的能量值</param>
    public void SetPrepareGainEnergy(int energy)
    {
        prepareGainEnergy = energy;
        UpdateEnergyDisplay();
    }

    /// <summary>
    /// ★2026-09-09 免费整备占位锁：偷袭赠送的整备也算「已经整备过一次」，
    /// 下一回合不能再用一次。由 <see cref="ApplyFreePrepare"/> 置位，
    /// 下一次 <see cref="ResetPrepareStatus"/>（回合开始）消费掉本次占位后自动解锁。
    /// </summary>
    private bool prepareLockedNextTurn = false;

    /// <summary>
    /// 回合开始重置整备状态。
    /// ★免费整备占位：偷袭赠送整备后紧接着的那一回合（战斗首回合 / 下一个探索回合）
    /// 视为已经整备过，按钮不可用；再下一回合自动恢复。
    /// </summary>
    public void ResetPrepareStatus()
    {
        if (prepareLockedNextTurn)
        {
            // 占位锁只吃一个回合：本回合保持「已整备」，锁自己清掉，下回合恢复正常
            prepareLockedNextTurn = false;
            hasPreparedThisTurn = true;
        }
        else
        {
            hasPreparedThisTurn = false;
        }
        UpdateButtonInteractivity();
    }

    private void OnPrepareClick()
    {
        // 执行整备操作
        PerformPrepare();
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (button.interactable)
        {
            ShowPrepareText();
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (button.interactable)
        {
            UpdateEnergyDisplay();
        }
    }

    /// <summary>
    /// 显示整备文字
    /// </summary>
    private void ShowPrepareText()
    {
        originalText = energyText.text;
        energyText.text = "整备";
        energyText.fontSize = 30; // 设置整备文字大小
    }

    /// <summary>
    /// 显示能量数字
    /// </summary>
    private void UpdateEnergyDisplay()
    {
        energyText.text = $"{currentEnergy}/{prepareGainEnergy}";
        energyText.fontSize = 40; // 恢复数字文字大小
    }

    /// <summary>
    /// 检查是否可以整备
    /// ★2026-08-18 防误触：能量已 ≥ 整备值（prepareGainEnergy）时不可整备——
    /// 整备是"补满语义"（低于整备值才补到整备值），能量已达标时点击只会
    /// 白耗一颗探索骰子。判定用 prepareGainEnergy 字段而非写死 3，
    /// 未来整备改 4/4（SetPrepareGainEnergy(4)）时本条件自动跟随。
    /// 本方法是按钮可交互性（UpdateButtonInteractivity 每帧刷新）与
    /// PerformPrepare 入口校验的单一事实来源。
    /// </summary>
    /// <returns>是否可以整备</returns>
    public bool CanPrepare()
    {
        // 防误触：能量已达标（≥ 整备目标值）→ 整备无收益，禁止。
        // ★v3 警戒不禁整备：F3.3 警戒触发瞬间能量已压回 3，本条天然挡住整备按钮，无需额外锁
        if (currentEnergy >= prepareGainEnergy)
        {
            return false;
        }

        // 检查是否有探索骰子
        bool hasDice = diceAreaObj != null && diceAreaObj.transform.childCount > 0;

        // 检查骰子是否都已被投出（只有当骰子按钮既激活又可交互时，才认为是可用的骰子）
        if (hasDice)
        {
            bool hasAvailableDice = false;
            foreach (Transform child in diceAreaObj.transform)
            {
                if (child.gameObject.activeSelf)
                {
                    Button diceButton = child.GetComponent<Button>();
                    if (diceButton != null && diceButton.interactable)
                    {
                        hasAvailableDice = true;
                        break;
                    }
                }
            }
            hasDice = hasAvailableDice;
        }

        // 检查是否已经整备过
        bool canPrepare = hasDice && !hasPreparedThisTurn;

        return canPrepare;
    }

    /// <summary>
    /// 执行整备操作
    /// </summary>
    /// <returns>是否整备成功</returns>
    public bool PerformPrepare()
    {
        if (!CanPrepare())
        {
            return false;
        }
        
        // 找到第一个激活且可交互的骰子按钮
        Transform availableDice = null;
        foreach (Transform child in diceAreaObj.transform)
        {
            if (child.gameObject.activeSelf)
            {
                Button diceButton = child.GetComponent<Button>();
                if (diceButton != null && diceButton.interactable)
                {
                    availableDice = child;
                    break;
                }
            }
        }
        
        if (availableDice != null)
        {
            DiceDragHandler diceDragHandler = availableDice.GetComponent<DiceDragHandler>();
            if (diceDragHandler != null)
            {
                // 调用整备专用的骰子投掷方法（不生成实际骰子模型）
                diceDragHandler.OnPrepareDiceClicked();
                
                // 消耗TurnManager中的骰子计数
                if (TurnManager.Instance != null)
                {
                    TurnManager.Instance.ConsumeDice(1);
                }
                // 能量补满至 prepareGainEnergy（F1.2 整备回复 = 补满至 3）
                // ★用户 2026-08-17 修正：原为 += 3 累加（能量会越积越多）。
                // 改为补满语义：低于 3 → 回到 3；已高于 3（如过载后）→ 保持不降。
                // 回合开始不重置能量，能量跨回合保留，只有整备能回复。
                currentEnergy = Mathf.Max(currentEnergy, prepareGainEnergy);
                CurrentEnergy = currentEnergy;
                UpdateEnergyDisplay();
                OnEnergyChanged?.Invoke(CurrentEnergy);
                // 标记已整备
                hasPreparedThisTurn = true;
                UpdateButtonInteractivity();
                OnPrepared?.Invoke();   // ★教学钩子：TutorialDirector 用它解除「使用整备」拍
                return true;
            }
        }
        
        return false;
    }

    /// <summary>
    /// 免费整备（偷袭奖励）：能量补满至 prepareGainEnergy（默认 3），已高于则不降。不耗骰。
    /// ★2026-09-09 用户定稿：赠送的整备同样算「已经整备过一次」——
    ///   置 hasPreparedThisTurn + 占位锁，紧接着的下一回合不能再整备（否则偷袭等于白送两次整备）。
    /// </summary>
    public void ApplyFreePrepare()
    {
        currentEnergy = Mathf.Max(currentEnergy, prepareGainEnergy);
        CurrentEnergy = currentEnergy;
        UpdateEnergyDisplay();
        OnEnergyChanged?.Invoke(CurrentEnergy);

        hasPreparedThisTurn = true;
        prepareLockedNextTurn = true;
        UpdateButtonInteractivity();
    }

    /// <summary>
    /// ★被动遇袭进战占位（2026-09-13 用户定稿）：无免费整备的进战（被动遇袭/偷袭资格耗尽），
    /// 首回合一律视为已整备——只置占位锁（战斗首回合整备按钮不可用，再下回合自动恢复），不补能量。
    /// 与偷袭方对称：首回合大家都只有进战时的能量，整备都要等下一回合。
    /// </summary>
    public void MarkPrepareLockedNoGain()
    {
        hasPreparedThisTurn = true;
        prepareLockedNextTurn = true;
        UpdateButtonInteractivity();
    }

    /// <summary>
    /// 剩余骰转化：最多加 amount 点，结果不超过 cap（已高于 cap 则浪费）。
    /// ★2026-09-14：cap 只是**本次转化的枚数上限**（防某次转化一口气灌太多），
    /// 真正的天花板永远是**能量上限 energyMax**——上限取两者较小值。
    /// （探索骰每回合只有 4 枚，所以 cap 实际很少真的卡住；能量能到 9 靠的是跨回合累积
    ///   和局内其它回能手段，而不是这一处转化。）
    /// </summary>
    public int AddEnergyTowardCap(int amount, int cap)
    {
        if (amount <= 0) return 0;
        cap = Mathf.Clamp(cap, 0, energyMax);
        int room = Mathf.Max(0, cap - CurrentEnergy);
        int gained = Mathf.Min(amount, room);
        if (gained > 0) SetEnergy(CurrentEnergy + gained);
        return gained;
    }
    private void UpdateButtonInteractivity()
    {
        // 设置按钮交互性
        button.interactable = CanPrepare();
    }

    // ====================================================================
    // M5b-1 能量消耗 API（供 CardExecutor 调用）
    // ====================================================================

    /// <summary>
    /// 只检查能量是否足够，不扣除。
    /// 用于选中卡牌阶段（不打牌不扣能量）。
    /// </summary>
    /// <param name="cost">要检查的能量消耗</param>
    /// <returns>能量是否足够</returns>
    public bool CanAfford(int cost)
    {
        return CurrentEnergy >= cost;
    }

    /// <summary>
    /// 尝试消耗能量。仅在打牌执行成功时调用。
    /// 如果能量足够：扣除并更新 UI，返回 true。
    /// 如果能量不足：不扣，返回 false。
    /// </summary>
    /// <param name="cost">要消耗的能量</param>
    /// <returns>是否消耗成功</returns>
    public bool TryConsumeEnergy(int cost)
    {
        if (CurrentEnergy < cost) return false;

        currentEnergy -= cost;
        CurrentEnergy = currentEnergy;
        UpdateEnergyDisplay();
        OnEnergyChanged?.Invoke(CurrentEnergy);
        Debug.Log($"[EnergyPointDisplay] 消耗能量 {cost}，剩余 {CurrentEnergy}");
        return true;
    }
}
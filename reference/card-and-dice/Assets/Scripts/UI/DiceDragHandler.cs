using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

public class DiceDragHandler : MonoBehaviour
{
    [Header("骰子设置")]
    public GameObject dicePrefab; // 骰子预制体
    public float minForce = 5f; // 最小力
    public float maxForce = 15f; // 最大力
    public float minTorque = 2f; // 最小扭矩
    public float maxTorque = 8f; // 最大扭矩
    public float spawnDistance = 1f; // 生成距离
    
    private Button button;
    private HexMover playerMover;
    
    private void Start()
    {
        // 缓存按钮组件并添加点击事件
        button = GetComponent<Button>();
        if (button != null)
        {
            button.onClick.AddListener(OnDiceButtonClicked);
        }
        
        // 缓存玩家移动组件
        playerMover = FindObjectOfType<HexMover>();
        
        // 缓存结束回合按钮
        GameObject endTurnButtonObj = GameObject.Find("UICanvas/EndTurnButton");
        if (endTurnButtonObj != null)
        {
            endTurnButton = endTurnButtonObj.GetComponent<Button>();
        }
    }
    
    /// <summary>
    /// 骰子按钮点击事件
    /// ★2026-09-05 即时骰子（用户定稿）：点击 → 图标立即消失 + 立即增加行动点。
    /// 无点数滚动动画、无物理投掷（旧版流程封存在 useLegacyPhysicsRoll 开关后，随时可恢复）。
    /// 模式分流：
    ///   探索态：耗 1 骰 → +diceAP（2）行动点，每回合上限 diceAPCap（2）枚（D1 §4.1 不变）
    ///   战斗态：耗 1 骰 → +2 行动点，每回合上限 battleDiceAPCapPerTurn（2）枚（★2026-09-08 用户定稿：与探索态一致——原「不限次逃跑支援」取消）
    /// </summary>
    public void OnDiceButtonClicked()
    {
        // ★2026-09-12 教学锁：提示确认链期间禁止耗骰换行动点
        if (Interactions.TutorialLockInput)
        {
            Debug.Log("[骰子] 教学锁：耗骰换行动点暂不可用");
            return;
        }

        // ---- 封存的旧版物理投掷流程（滚动动画 + 场上投骰 + 读点数）----
        if (useLegacyPhysicsRoll)
        {
            OnDiceButtonClicked_Legacy();
            return;
        }

        if (playerMover == null) playerMover = FindObjectOfType<HexMover>();
        if (playerMover == null) return;

        GameState state = (GameStateManager.Instance != null)
            ? GameStateManager.Instance.CurrentState
            : GameState.Battle;

        if (state == GameState.Exploring)
        {
            // 探索态：上限 2 枚/回合（D1 §4.1），超限拒绝、按钮保留
            if (ExplorationTurnManager.Instance == null || !ExplorationTurnManager.Instance.CanSpendDiceForAP())
            {
                Debug.Log("[骰子] 本回合耗骰换行动点已达上限（D1 §4.1 diceAPCap），该骰子保留");
                return;
            }
            ExplorationTurnManager.Instance.RecordDiceForAP();
            int diceAP = (ExplorationTurnManager.Instance != null)
                ? ExplorationTurnManager.Instance.diceAPBonus
                : 2;
            playerMover.currentActionPoints += diceAP;
            Debug.Log($"[探索] 耗 1 骰立即 +{diceAP} 行动点（D1），当前行动点: {playerMover.currentActionPoints}");
        }
        else
        {
            // 战斗态：上限 battleDiceAPCapPerTurn 枚/回合（★2026-09-08 用户定稿：与探索态一致），超限拒绝、骰子保留
            if (TurnManager.Instance == null || !TurnManager.Instance.CanSpendDiceForAP())
            {
                Debug.Log("[骰子] 本回合耗骰换行动点已达上限（战斗 2 枚/回合），该骰子保留");
                return;
            }
            TurnManager.Instance.RecordDiceForAP();
            playerMover.currentActionPoints += battleDiceAPBonus;
            Debug.Log($"[战斗] 耗 1 骰立即 +{battleDiceAPBonus} 行动点，当前行动点: {playerMover.currentActionPoints}");
        }

        // 图标立即消失（无动画、无场上骰子）
        gameObject.SetActive(false);
        ExplorationTurnManager.RaiseDiceConsumed();   // ★教学钩子：与移动扣骰同事件（S3 解除）
    }

    // ====================================================================
    // ★封存区（2026-09-05）：以下为旧版「物理投骰 + 滚动动画」流程，
    //   由 useLegacyPhysicsRoll = true 恢复。Demo 阶段默认关闭。
    // ====================================================================
    [Header("封存：旧版物理投骰（默认关闭）")]
    [Tooltip("true = 恢复旧版物理投骰+滚动动画；false = 点击立即消失并+行动点")]
    public bool useLegacyPhysicsRoll = false;

    [Tooltip("战斗态即时转化：每枚骰子转化的行动点数（探索态用 ExplorationTurnManager.diceAPBonus）")]
    public int battleDiceAPBonus = 2;

    /// <summary>旧版点击流程（物理投骰），封存保留</summary>
    private void OnDiceButtonClicked_Legacy()
    {
        // ★探索系统第一步（2026-08-25）：探索态点骰子 = 耗 1 骰换行动点（D1 §4.1）。
        // 每回合上限 diceAPCap 枚（默认 2）：超限拒绝掷骰，按钮保留不消耗。
        // 记账放在点击时（而非骰子结算时），防多枚骰子同时滚动时超限。
        if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Exploring)
        {
            if (ExplorationTurnManager.Instance == null || !ExplorationTurnManager.Instance.CanSpendDiceForAP())
            {
                Debug.Log("[骰子] 本回合耗骰换行动点已达上限（D1 §4.1 diceAPCap），该骰子保留");
                return;
            }
            ExplorationTurnManager.Instance.RecordDiceForAP();
        }

        // 禁用按钮，防止重复投掷，但不立即隐藏
        if (button != null)
        {
            button.interactable = false;
        }
        
        // 禁用结束回合按钮，直到行动点增加完成
        SetEndTurnButtonInteractable(false);
        
        // 开始骰子投掷动画（缩小并随机切换图标）
        rollingAnimationCoroutine = DiceRollingAnimation();
        StartCoroutine(rollingAnimationCoroutine);
        
        // 在玩家周围生成骰子
        SpawnDiceNearPlayer();
    }
    
    /// <summary>
    /// 整备时的骰子投掷（不生成实际骰子模型）
    /// </summary>
    public void OnPrepareDiceClicked()
    {
        // 禁用按钮，防止重复投掷
        if (button != null)
        {
            button.interactable = false;
        }
        
        // 不需要禁用结束回合按钮，因为整备操作很快完成
        
        // 不需要动画，直接隐藏按钮
        gameObject.SetActive(false);
    }
    
    // 记录原始大小
    private Vector3 originalScale;
    
    /// <summary>
    /// 骰子投掷动画
    /// </summary>
    private System.Collections.IEnumerator DiceRollingAnimation()
    {
        // 记录原始大小
        originalScale = transform.localScale;
        
        // 缩小图标
        transform.localScale = originalScale * 0.8f;
        
        // 随机切换图标，速度逐渐减慢
        float startTime = Time.time;
        float currentDelay = 0.1f; // 初始速度很快
        float maxDelay = 0.5f; // 最终速度
        float slowdownDuration = 2f; // 减速持续时间
        
        while (true)
        {
            // 随机生成1-6的数字
            int randomValue = Random.Range(1, 7);
            // 更新图标
            UpdateDiceButtonIcon(randomValue);
            // 等待当前延迟时间
            yield return new WaitForSeconds(currentDelay);
            // 逐渐增加延迟时间，减慢速度
            float elapsedTime = Time.time - startTime;
            currentDelay = Mathf.Lerp(0.1f, maxDelay, elapsedTime / slowdownDuration);
        }
    }
    
    /// <summary>
    /// 在玩家周围生成骰子
    /// </summary>
    private void SpawnDiceNearPlayer()
    {
        // 检查玩家移动组件是否存在
        if (playerMover == null)
        {
            Debug.LogError("HexPlayerMover not found");
            return;
        }
        
        // 计算生成位置：在玩家周围随机位置
        Vector3 playerPosition = playerMover.transform.position;
        
        // 确保生成位置在玩家周围，不受摄影机影响
        Vector3 randomDirection = new Vector3(
            Random.Range(-1f, 1f),
            0,
            Random.Range(-1f, 1f)
        ).normalized;
        
        // 确保生成位置在玩家附近
        Vector3 spawnPosition = playerPosition + randomDirection * spawnDistance + new Vector3(0, 1f, 0);
        
        // 限制生成位置范围，确保骰子不会离玩家太远
        float maxDistanceFromPlayer = 3f;
        if (Vector3.Distance(spawnPosition, playerPosition) > maxDistanceFromPlayer)
        {
            spawnPosition = playerPosition + (spawnPosition - playerPosition).normalized * maxDistanceFromPlayer;
            spawnPosition.y = 1f; // 保持一定高度
        }
        
        // 确保骰子在地图边界内生成
        // 根据实际地图范围设置边界
        float minX = 0f;
        float maxX = 43.5f;
        float minZ = -33.77499f;
        float maxZ = 0f;
        
        spawnPosition.x = Mathf.Clamp(spawnPosition.x, minX, maxX);
        spawnPosition.z = Mathf.Clamp(spawnPosition.z, minZ, maxZ);
        
        // 实例化骰子
        GameObject dice = Instantiate(dicePrefab, spawnPosition, Quaternion.identity);
        
        // 获取骰子组件
        D6Dice d6Dice = dice.GetComponent<D6Dice>();
        
        // 向随机方向施加力和扭矩
        Rigidbody rb = dice.GetComponent<Rigidbody>();
        if (rb != null)
        {
            // 检查玩家是否接近边界
            float boundaryMargin = 2f; // 边界边缘的安全距离
            Vector3 forceDirection = randomDirection;
            
            // 如果玩家接近左边界，向右侧投出
            if (playerPosition.x < minX + boundaryMargin)
            {
                forceDirection.x = Mathf.Abs(forceDirection.x); // 确保向右
            }
            // 如果玩家接近右边界，向左侧投出
            else if (playerPosition.x > maxX - boundaryMargin)
            {
                forceDirection.x = -Mathf.Abs(forceDirection.x); // 确保向左
            }
            
            // 如果玩家接近上边界（Z轴正方向），向下方投出
            if (playerPosition.z > maxZ - boundaryMargin)
            {
                forceDirection.z = -Mathf.Abs(forceDirection.z); // 确保向下
            }
            // 如果玩家接近下边界（Z轴负方向），向上方投出
            else if (playerPosition.z < minZ + boundaryMargin)
            {
                forceDirection.z = Mathf.Abs(forceDirection.z); // 确保向上
            }
            
            // 确保力方向是归一化的
            forceDirection = forceDirection.normalized;
            
            // 调整力方向，稍微向下
            forceDirection.y = Random.Range(-0.3f, 0f);
            forceDirection = forceDirection.normalized;
            
            // 随机力大小
            float forceMagnitude = Random.Range(minForce, maxForce);
            
            // 随机扭矩（减小扭矩，使骰子旋转更温和）
            Vector3 torque = new Vector3(
                Random.Range(minTorque * 0.5f, maxTorque * 0.5f),
                Random.Range(minTorque * 0.5f, maxTorque * 0.5f),
                Random.Range(minTorque * 0.5f, maxTorque * 0.5f)
            );
            
            // 施加力和扭矩
            rb.AddForce(forceDirection * forceMagnitude, ForceMode.Impulse);
            rb.AddTorque(torque, ForceMode.Impulse);
            
            // 设置骰子为滚动状态
            d6Dice.SetRolling(true);
        }
        
        // 等待骰子稳定后获取点数
        if (d6Dice != null)
        {
            StartCoroutine(WaitForDiceToSettle(d6Dice, playerMover));
        }
    }
    
    // 存储动画协程的引用
    private System.Collections.IEnumerator rollingAnimationCoroutine;
    
    /// <summary>
    /// 等待骰子稳定后获取点数
    /// </summary>
    private System.Collections.IEnumerator WaitForDiceToSettle(D6Dice dice, HexMover playerMover)
    {
        // 等待骰子停止滚动
        while (dice != null && dice.IsRolling())
        {
            yield return null;
        }
        
        // 等待一小段时间确保骰子完全稳定并且已经确定点数
        yield return new WaitForSeconds(1f);
        
        // 检查骰子是否仍然存在
        if (dice != null)
        {
            // 获取骰子点数
            int diceValue = dice.GetValue();
            
            // 显示掷出的点数
            Debug.Log("掷出的点数: " + diceValue);
            
            // 将点数加到行动点上
            // ★探索系统第一步（2026-08-25）：按游戏模式分流——
            // 探索态：D1 固定行动点体系——耗 1 骰换 diceAP（+2）行动点；
            //         掷骰动画与点数仅作视觉反馈，不影响 AP 数值（记账已在点击时完成）
            // 战斗态：维持原逻辑（掷出点数 = 增加的行动点）
            if (GameStateManager.Instance != null && GameStateManager.Instance.CurrentState == GameState.Exploring)
            {
                if (playerMover != null)
                {
                    int diceAP = (ExplorationTurnManager.Instance != null)
                        ? ExplorationTurnManager.Instance.diceAPBonus
                        : 2;
                    playerMover.currentActionPoints += diceAP;
                    Debug.Log($"[探索] 耗 1 骰换 {diceAP} 行动点（D1），掷出点数 {diceValue} 仅作视觉反馈，当前行动点: {playerMover.currentActionPoints}");
                }
            }
            else if (playerMover != null)
            {
                playerMover.currentActionPoints += diceValue;
                Debug.Log("行动点已增加 " + diceValue + " 点，当前行动点: " + playerMover.currentActionPoints);
            }
            
            // 停止动画协程
            if (rollingAnimationCoroutine != null)
            {
                StopCoroutine(rollingAnimationCoroutine);
                rollingAnimationCoroutine = null;
            }
            
            // 恢复图标的原始大小
            if (originalScale != Vector3.zero)
            {
                transform.localScale = originalScale;
            }
            
            // 最后一次切换到对应点数
            UpdateDiceButtonIcon(diceValue);
        }
        else
        {
            Debug.LogError("骰子已被销毁，无法获取点数");
        }
        
        // 等待2秒后隐藏按钮
        yield return new WaitForSeconds(2f);
        
        // 重新启用结束回合按钮
        SetEndTurnButtonInteractable(true);
        
        // 隐藏按钮，完成投掷流程
        gameObject.SetActive(false);
    }
    
    /// <summary>
    /// 更新骰子按钮的图标为对应点数
    /// </summary>
    public void UpdateDiceButtonIcon(int diceValue)
    {
        // 清除按钮上现有的圆点
        ClearDiceDots();
        
        // 根据骰子点数创建对应的圆点
        switch (diceValue)
        {
            case 1:
                CreateDiceDotsForOne();
                break;
            case 2:
                CreateDiceDotsForTwo();
                break;
            case 3:
                CreateDiceDotsForThree();
                break;
            case 4:
                CreateDiceDotsForFour();
                break;
            case 5:
                CreateDiceDotsForFive();
                break;
            case 6:
                CreateDiceDotsForSix();
                break;
        }
        
        Debug.Log("骰子按钮图标已更新为点数: " + diceValue);
    }
    
    /// <summary>
    /// 清除按钮上现有的圆点
    /// </summary>
    private void ClearDiceDots()
    {
        // 遍历所有子对象，删除圆点
        for (int i = transform.childCount - 1; i >= 0; i--)
        {
            if (transform.GetChild(i).name.StartsWith("Dot"))
            {
                Destroy(transform.GetChild(i).gameObject);
            }
        }
    }
    
    /// <summary>
    /// 创建1点的圆点（红色，稍大）
    /// </summary>
    private void CreateDiceDotsForOne()
    {
        // 创建一个红色的圆点，位置在中心，稍大
        CreateDot(new Vector2(0, 0), Color.red, 50f);
    }
    
    /// <summary>
    /// 创建2点的圆点（黑色）
    /// </summary>
    private void CreateDiceDotsForTwo()
    {
        // 创建两个黑色的圆点，位置在左上角和右下角，更靠近中心
        CreateDot(new Vector2(-25, 25), Color.black, 45f);
        CreateDot(new Vector2(25, -25), Color.black, 45f);
    }
    
    /// <summary>
    /// 创建3点的圆点（黑色）
    /// </summary>
    private void CreateDiceDotsForThree()
    {
        // 创建三个黑色的圆点，位置在左上角、中心和右下角，更靠近中心
        CreateDot(new Vector2(-25, 25), Color.black, 45f);
        CreateDot(new Vector2(0, 0), Color.black, 45f);
        CreateDot(new Vector2(25, -25), Color.black, 45f);
    }
    
    /// <summary>
    /// 创建4点的圆点（黑色）
    /// </summary>
    private void CreateDiceDotsForFour()
    {
        // 创建四个黑色的圆点，位置在四个角落，更靠近中心
        CreateDot(new Vector2(-25, 25), Color.black, 45f);
        CreateDot(new Vector2(25, 25), Color.black, 45f);
        CreateDot(new Vector2(-25, -25), Color.black, 45f);
        CreateDot(new Vector2(25, -25), Color.black, 45f);
    }
    
    /// <summary>
    /// 创建5点的圆点（黑色）
    /// </summary>
    private void CreateDiceDotsForFive()
    {
        // 创建五个黑色的圆点，位置在四个角落和中心，更靠近中心
        CreateDot(new Vector2(-25, 25), Color.black, 45f);
        CreateDot(new Vector2(25, 25), Color.black, 45f);
        CreateDot(new Vector2(0, 0), Color.black, 45f);
        CreateDot(new Vector2(-25, -25), Color.black, 45f);
        CreateDot(new Vector2(25, -25), Color.black, 45f);
    }
    
    /// <summary>
    /// 创建6点的圆点（黑色）
    /// </summary>
    private void CreateDiceDotsForSix()
    {
        // 创建六个黑色的圆点，位置在左右两列，每列三个，更靠近中心
        CreateDot(new Vector2(-20, 25), Color.black, 45f);
        CreateDot(new Vector2(-20, 0), Color.black, 45f);
        CreateDot(new Vector2(-20, -25), Color.black, 45f);
        CreateDot(new Vector2(20, 25), Color.black, 45f);
        CreateDot(new Vector2(20, 0), Color.black, 45f);
        CreateDot(new Vector2(20, -25), Color.black, 45f);
    }
    
    /// <summary>
    /// 创建一个圆点
    /// </summary>
    /// <param name="position">圆点位置</param>
    /// <param name="color">圆点颜色</param>
    /// <param name="size">圆点大小</param>
    private void CreateDot(Vector2 position, Color color, float size)
    {
        // 创建一个新的GameObject作为圆点
        GameObject dot = new GameObject("Dot");
        dot.transform.SetParent(transform);
        dot.transform.localPosition = new Vector3(position.x, position.y, 0);
        dot.transform.localScale = Vector3.one;
        
        // 添加Image组件
        Image dotImage = dot.AddComponent<Image>();
        dotImage.color = color;
        
        // 设置RectTransform
        RectTransform rectTransform = dot.GetComponent<RectTransform>();
        rectTransform.sizeDelta = new Vector2(size, size);
        rectTransform.anchoredPosition = position;
        rectTransform.anchorMin = new Vector2(0.5f, 0.5f);
        rectTransform.anchorMax = new Vector2(0.5f, 0.5f);
        rectTransform.pivot = new Vector2(0.5f, 0.5f);
        
        // 确保圆点是圆形的
        // 创建一个圆形的精灵
        dotImage.sprite = CreateCircleSprite(size, color);
    }
    
    /// <summary>
    /// 创建一个圆形的精灵
    /// </summary>
    /// <param name="size">圆形大小</param>
    /// <param name="color">圆形颜色</param>
    /// <returns>圆形精灵</returns>
    private Sprite CreateCircleSprite(float size, Color color)
    {
        // 创建一个临时的纹理
        int textureSize = (int)size * 2;
        Texture2D texture = new Texture2D(textureSize, textureSize);
        
        // 填充纹理为透明
        Color[] pixels = new Color[textureSize * textureSize];
        for (int i = 0; i < pixels.Length; i++)
        {
            pixels[i] = Color.clear;
        }
        texture.SetPixels(pixels);
        
        // 绘制圆形
        int centerX = textureSize / 2;
        int centerY = textureSize / 2;
        int radius = (int)(size / 2);
        
        for (int x = 0; x < textureSize; x++)
        {
            for (int y = 0; y < textureSize; y++)
            {
                int dx = x - centerX;
                int dy = y - centerY;
                if (dx * dx + dy * dy <= radius * radius)
                {
                    texture.SetPixel(x, y, color);
                }
            }
        }
        
        texture.Apply();
        
        // 创建精灵
        Sprite sprite = Sprite.Create(texture, new Rect(0, 0, textureSize, textureSize), new Vector2(0.5f, 0.5f));
        return sprite;
    }
    
    // 缓存结束回合按钮
    private Button endTurnButton;
    
    /// <summary>
    /// 设置结束回合按钮的交互状态
    /// </summary>
    /// <param name="interactable">是否可交互</param>
    private void SetEndTurnButtonInteractable(bool interactable)
    {
        // 检查结束回合按钮是否存在
        if (interactable)
        {
            Interactions.RefreshEndTurnButton();
            return;
        }
        if (endTurnButton != null)
        {
            endTurnButton.interactable = false;
        }
    }
}

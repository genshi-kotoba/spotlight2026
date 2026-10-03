using UnityEngine;
using TMPro;
using System.Collections;

public class ActionPointNotifier : MonoBehaviour
{
    [Header("UI References")]
    public TextMeshProUGUI actionPointText; // 行动点文本
    public TextMeshProUGUI gainText; // 增加提示文本
    
    [Header("Animation Settings")]
    public float animationDuration = 2f; // 动画持续时间
    public float scaleMultiplier = 1.5f; // 放大倍数
    
    private int lastActionPoints = 0;
    private Coroutine currentAnimationCoroutine;
    
    private void Start()
    {
        // 查找行动点文本
        GameObject statusBar = GameObject.Find("UICanvas/StatusBar");
        if (statusBar != null)
        {
            Transform actionPointsTextTransform = statusBar.transform.Find("ActionPointsText");
            if (actionPointsTextTransform != null)
            {
                actionPointText = actionPointsTextTransform.GetComponent<TextMeshProUGUI>();
            }
        }
        
        // 初始化增益文本
        if (gainText != null)
        {
            gainText.gameObject.SetActive(false);
        }
    }
    
    private void Update()
    {
        // 检查行动点是否变化
        CheckActionPointChange();
    }
    
    /// <summary>
    /// 检查行动点是否变化
    /// </summary>
    private void CheckActionPointChange()
    {
        HexMover playerMover = FindObjectOfType<HexMover>();
        if (playerMover != null)
        {
            int currentActionPoints = playerMover.currentActionPoints;
            
            // 检查行动点是否增加
            if (currentActionPoints > lastActionPoints)
            {
                int gainAmount = currentActionPoints - lastActionPoints;
                ShowGainNotification(gainAmount);
            }
            
            lastActionPoints = currentActionPoints;
        }
    }
    
    /// <summary>
    /// 显示行动点增加通知
    /// </summary>
    /// <param name="amount">增加的行动点数量</param>
    public void ShowGainNotification(int amount)
    {
        if (gainText != null)
        {
            // 停止当前动画（如果有）
            if (currentAnimationCoroutine != null)
            {
                StopCoroutine(currentAnimationCoroutine);
            }
            
            // 显示增益文本
            gainText.text = "+" + amount;
            gainText.gameObject.SetActive(true);
            
            // 开始动画
            currentAnimationCoroutine = StartCoroutine(GainAnimation());
        }
    }
    
    /// <summary>
    /// 增益动画
    /// </summary>
    private IEnumerator GainAnimation()
    {
        if (gainText == null)
            yield break;
        
        float elapsedTime = 0f;
        Color originalColor = gainText.color;
        
        // 确保文本在动画开始时是不透明的
        gainText.color = originalColor;
        
        while (elapsedTime < animationDuration)
        {
            elapsedTime += Time.deltaTime;
            float t = elapsedTime / animationDuration;
            
            // 只保留透明度动画，不缩放
            Color newColor = originalColor;
            newColor.a = Mathf.Lerp(1f, 0f, t);
            gainText.color = newColor;
            
            yield return null;
        }
        
        // 重置状态
        gainText.color = originalColor;
        gainText.gameObject.SetActive(false);
        currentAnimationCoroutine = null;
    }
}
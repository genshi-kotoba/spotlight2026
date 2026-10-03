using UnityEngine;
using UnityEngine.UI;
using TMPro;

/// <summary>
/// 卡牌UI管理器 - 用于管理卡牌UI的显示和交互
/// </summary>
public class CardUIManager : MonoBehaviour
{
    [Header("UI Elements")]
    [SerializeField] private TMP_Text cardNameText;
    [SerializeField] private TMP_Text cardDescriptionText;
    [SerializeField] private TMP_Text cardCostText;
    [SerializeField] private Image[] suitImages;
    
    [Header("References")]
    [SerializeField] private CardData cardData;
    [SerializeField] private CardDeckManager deckManager;
    
    /// <summary>
    /// 设置卡牌数据
    /// </summary>
    /// <param name="data">卡牌数据</param>
    public void SetCardData(CardData data)
    {
        cardData = data;
        UpdateCardDisplay();
    }
    
    /// <summary>
    /// 设置卡组管理器
    /// </summary>
    /// <param name="manager">卡组管理器</param>
    public void SetDeckManager(CardDeckManager manager)
    {
        deckManager = manager;
    }
    
    /// <summary>
    /// 更新卡牌显示
    /// </summary>
    private void UpdateCardDisplay()
    {
        if (cardData == null) return;
        
        // 设置卡牌名称
        if (cardNameText != null)
            cardNameText.text = cardData.cardName;
        
        // 设置卡牌描述
        if (cardDescriptionText != null)
            cardDescriptionText.text = cardData.description;
        
        // 设置卡牌消耗
        if (cardCostText != null)
            cardCostText.text = "Cost: " + cardData.energyCost;
        
        // 设置花色显示
        UpdateSuitDisplay();
    }
    
    /// <summary>
    /// 更新花色显示
    /// </summary>
    private void UpdateSuitDisplay()
    {
        if (suitImages == null || suitImages.Length < 4) return;
        
        // 设置第一个花色
        if (suitImages[0] != null)
        {
            suitImages[0].gameObject.SetActive(cardData.suit1 != SuitOption.无);
            // 实际项目中需要根据花色设置不同的颜色或图标
        }
        
        // 设置第二个花色
        if (suitImages[1] != null)
        {
            suitImages[1].gameObject.SetActive(cardData.suit2 != SuitOption.无);
            // 实际项目中需要根据花色设置不同的颜色或图标
        }
        
        // 设置第三个花色
        if (suitImages[2] != null)
        {
            suitImages[2].gameObject.SetActive(cardData.suit3 != SuitOption.无);
            // 实际项目中需要根据花色设置不同的颜色或图标
        }
        
        // 设置第四个花色
        if (suitImages[3] != null)
        {
            suitImages[3].gameObject.SetActive(cardData.suit4 != SuitOption.无);
            // 实际项目中需要根据花色设置不同的颜色或图标
        }
    }
    
// ★2026-09-09：这两个按钮回调写的是 CardDeckManager.initialDeckEntries（Inspector 里的初始牌组配置），
//   对应方法在 CardDeckManager 里包在 #if UNITY_EDITOR 内——Player 构建时不存在，
//   不一起包起来会让导出游戏编译失败（CS1061）。运行时加卡走 AddCardAtRuntime（当局牌库）。
#if UNITY_EDITOR
    /// <summary>
    /// 添加卡牌到卡组（编辑器牌组编辑用）
    /// </summary>
    public void AddToDeck()
    {
        if (deckManager != null && cardData != null)
        {
            deckManager.AddCardToDeck(cardData);
        }
    }
    
    /// <summary>
    /// 从卡组中移除卡牌（编辑器牌组编辑用）
    /// </summary>
    public void RemoveFromDeck()
    {
        if (deckManager != null && cardData != null)
        {
            deckManager.RemoveCardFromDeck(cardData);
        }
    }
#endif
}
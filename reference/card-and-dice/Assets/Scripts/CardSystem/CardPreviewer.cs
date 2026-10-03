using UnityEngine;
// ★2026-09-09：UnityEditor 只在编辑器存在——顶层 using 会让 Player 构建直接编不过（CS0246）。
#if UNITY_EDITOR
using UnityEditor;
#endif

/// <summary>
/// 卡牌预览器 - 简单的卡牌效果预览工具
/// 用于快速预览创建的卡牌在游戏中的显示效果
/// </summary>
public class CardPreviewer : MonoBehaviour
{
    [Header("卡牌预览设置")]
[SerializeField] private CardView cardView; // 卡牌视图组件引用
[SerializeField] public CardData cardData; // 要预览的卡牌数据
    
    /// <summary>
    /// 初始化时更新卡牌显示
    /// </summary>
    private void Start()
    {
        UpdateCardDisplay();
    }
    
    /// <summary>
    /// 在Inspector中修改时更新显示（仅在编辑器模式下有效）
    /// </summary>
    private void OnValidate()
    {
        // 自动查找CardView组件
        if (cardView == null)
        {
            cardView = GetComponent<CardView>();
            if (cardView == null)
            {
                cardView = GetComponentInChildren<CardView>();
            }
        }
        
        // 在编辑器模式下实时更新预览
        #if UNITY_EDITOR
        if (!Application.isPlaying && cardView != null)
        {
            UpdateCardDisplay();
        }
        #endif
    }
    
    /// <summary>
    /// 更新卡牌显示
    /// 将CardData应用到CardView
    /// </summary>
    public void UpdateCardDisplay()
    {
        if (cardView != null && cardData != null)
        {
            // 编辑器预览用：创建临时 Card 运行时实例（不加入任何牌堆）
            var runtimeCard = new Card(cardData);
            cardView.SetCard(runtimeCard);
        }
    }
    
    /// <summary>
    /// 设置要预览的卡牌数据
    /// </summary>
    /// <param name="newCardData">新的卡牌数据</param>
    public void SetCardData(CardData newCardData)
    {
        cardData = newCardData;
        UpdateCardDisplay();
    }
}

#if UNITY_EDITOR
/// <summary>
/// CardPreviewer的编辑器扩展
/// 提供更便捷的预览功能
/// </summary>
[CustomEditor(typeof(CardPreviewer))]
public class CardPreviewerEditor : Editor
{
    private CardData lastCardData;
    private float lastUpdateTime;
    private const float UpdateInterval = 0.5f; // 每0.5秒检查一次
    
    public override void OnInspectorGUI()
    {
        base.OnInspectorGUI();
        
        CardPreviewer previewer = (CardPreviewer)target;
        
        // 添加刷新预览按钮
        if (GUILayout.Button("刷新预览"))
        {
            previewer.UpdateCardDisplay();
        }
        
        // 添加便捷按钮：从项目中选择卡牌
        if (GUILayout.Button("选择卡牌文件"))
        {
            string path = EditorUtility.OpenFilePanel("选择卡牌数据文件", "Assets/Data/Cards", "asset");
            if (!string.IsNullOrEmpty(path))
            {
                // 将绝对路径转换为Unity资源路径
                string assetPath = path.Replace(Application.dataPath, "Assets");
                CardData cardData = AssetDatabase.LoadAssetAtPath<CardData>(assetPath);
                if (cardData != null)
                {
                    previewer.SetCardData(cardData);
                    EditorUtility.SetDirty(previewer);
                }
            }
        }
    }
    
    private void OnEnable()
    {
        // 注册更新事件
        EditorApplication.update += OnEditorUpdate;
    }
    
    private void OnDisable()
    {
        // 取消注册更新事件
        EditorApplication.update -= OnEditorUpdate;
    }
    
    private void OnEditorUpdate()
    {
        // 定期检查卡牌数据是否变化
        CardPreviewer previewer = (CardPreviewer)target;
        if (previewer == null || previewer.cardData == null)
            return;
        
        // 每0.5秒检查一次
        if (Time.realtimeSinceStartup - lastUpdateTime < UpdateInterval)
            return;
        
        lastUpdateTime = Time.realtimeSinceStartup;
        
        // 检查卡牌数据是否发生变化
        if (previewer.cardData != lastCardData)
        {
            lastCardData = previewer.cardData;
            previewer.UpdateCardDisplay();
        }
        else
        {
            // 检查卡牌数据的属性是否发生变化
            // 这里通过比较文件修改时间来检测变化
            string assetPath = AssetDatabase.GetAssetPath(previewer.cardData);
            System.IO.FileInfo fileInfo = new System.IO.FileInfo(assetPath);
            System.DateTime lastWriteTime = fileInfo.LastWriteTime;
            
            // 存储上次修改时间的键
            string key = "CardPreviewer_LastWriteTime_" + previewer.cardData.GetInstanceID();
            System.DateTime? storedTime = EditorPrefs.HasKey(key) ? (System.DateTime?)System.DateTime.Parse(EditorPrefs.GetString(key)) : null;
            
            if (!storedTime.HasValue || lastWriteTime > storedTime.Value)
            {
                // 文件已修改，更新预览
                previewer.UpdateCardDisplay();
                EditorPrefs.SetString(key, lastWriteTime.ToString());
            }
        }
    }
}
#endif
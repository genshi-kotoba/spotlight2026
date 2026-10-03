using UnityEngine;

/// <summary>
/// M5a 卡牌视图创建器（单例）。统一负责 CardView 的实例化。
/// 参考：NSWells《杀戮尖塔》P2 CardViewCreator 实现。
/// </summary>
public class CardViewCreator : MonoBehaviour
{
    private static CardViewCreator _instance;
    public static CardViewCreator Instance
    {
        get
        {
            if (_instance == null)
                _instance = FindObjectOfType<CardViewCreator>();
            return _instance;
        }
    }

    [SerializeField] private CardView cardViewPrefab;

    // 暴露一个只读属性，让 HandUIController 不用反射也能拿到预制体
    public CardView CardViewPrefab => cardViewPrefab;

    private void Awake()
    {
        // ★ Reset 安全网：Inspector 被 Reset 后自动找预制体
        if (cardViewPrefab == null)
        {
            AutoBindPrefab();
        }
    }

    /// <summary>
    /// 编辑器右键菜单：一键自动绑定预制体（不用 Play 模式也能执行）
    /// </summary>
    [ContextMenu("自动绑定 CardView 预制体")]
    private void AutoBindPrefab()
    {
        if (cardViewPrefab != null) return;

        // 全局搜索所有已加载的 CardView（包含 Prefab Asset）
        CardView[] allCvs = Resources.FindObjectsOfTypeAll<CardView>();
        foreach (CardView cv in allCvs)
        {
            // Prefab Asset 特征：不在任何场景里（scene.name 为空）
            if (cv != null && (cv.gameObject.scene.name == null || cv.gameObject.scene.name == ""))
            {
                cardViewPrefab = cv;
                Debug.Log($"[CardViewCreator] 自动绑定预制体成功：{cv.name}", this);
                return;
            }
        }

        Debug.LogError("[CardViewCreator] 自动绑定失败：在项目中找不到 CardView 预制体！请手动把 CardView Prefab 拖到 Inspector。", this);
    }

    /// <summary>
    /// 创建一张卡牌视图。
    /// </summary>
    /// <param name="parent">卡牌父节点</param>
    /// <returns>创建好的 CardView 实例</returns>
    public CardView CreateCardView(Transform parent)
    {
        if (cardViewPrefab == null)
        {
            AutoBindPrefab(); // 再最后试一次兜底
        }
        if (cardViewPrefab == null)
        {
            Debug.LogError("[CardViewCreator] cardViewPrefab 未赋值！", this);
            return null;
        }

        CardView cardView = Instantiate(cardViewPrefab, parent);
        cardView.transform.localScale = Vector3.zero;
        return cardView;
    }
}

using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 卡牌花色管理器
/// 功能：挂载在CardView上，根据花色选项修改对应位置的图标显示。
/// 支持两种渲染模式：
///   - SpriteRenderer：3D 世界空间卡牌（编辑器可视化预览用，见 CardEditor 场景）
///   - Image：UI 屏幕空间卡牌（战斗手牌 HUD 用，见 HandUIController）
/// 通过检测目标上的组件类型自动选择，两套互不干扰。
/// </summary>
public class CardColorChanger : MonoBehaviour
{
    // 五种颜色选项对应的精灵
    [Header("颜色选项对应的图标精灵")]
    [SerializeField] private Sprite redIcon;      // 红色图标
    [SerializeField] private Sprite greenIcon;    // 绿色图标
    [SerializeField] private Sprite blueIcon;     // 蓝色图标
    [SerializeField] private Sprite yellowIcon;   // 黄色图标
    
    /// <summary>
    /// 根据花色选项获取对应的图标精灵
    /// </summary>
    /// <param name="option">花色选项</param>
    /// <returns>对应的图标精灵，无花色时返回null</returns>
    public Sprite GetIconByOption(SuitOption option)
    {
        switch (option)
        {
            case SuitOption.红色:
                return redIcon;
            case SuitOption.绿色:
                return greenIcon;
            case SuitOption.蓝色:
                return blueIcon;
            case SuitOption.黄色:
                return yellowIcon;
            default: // 无
                return null;
        }
    }
    
    /// <summary>
    /// 根据花色选项自动设置目标上的图标显示。
    /// 优先使用 UI Image，其次使用 SpriteRenderer（兼容两种渲染模式）。
    /// </summary>
    /// <param name="target">要设置的花色图标 GameObject（含 Image 或 SpriteRenderer）</param>
    /// <param name="option">花色选项</param>
    public void SetIconByOption(GameObject target, SuitOption option)
    {
        if (target == null)
            return;

        Sprite sprite = GetIconByOption(option);

        // 优先尝试 UI Image（屏幕空间手牌）
        Image image = target.GetComponent<Image>();
        if (image != null)
        {
            image.sprite = sprite;
            image.enabled = sprite != null;
            target.SetActive(true);
            return;
        }

        // 回退到 SpriteRenderer（3D 世界空间预览）
        SpriteRenderer sr = target.GetComponent<SpriteRenderer>();
        if (sr != null)
        {
            sr.sprite = sprite;
            sr.enabled = sprite != null;
            target.SetActive(true);
        }
    }
    
    /// <summary>
    /// 根据花色选项设置指定位置的精灵显示（保留原 3D 接口，供旧代码调用）
    /// </summary>
    /// <param name="spriteRenderer">要设置的SpriteRenderer组件</param>
    /// <param name="option">花色选项</param>
    public void SetSpriteByOption(SpriteRenderer spriteRenderer, SuitOption option)
    {
        if (spriteRenderer == null)
            return;
            
        Sprite sprite = GetIconByOption(option);
        spriteRenderer.sprite = sprite;
        spriteRenderer.gameObject.SetActive(sprite != null);
    }
}
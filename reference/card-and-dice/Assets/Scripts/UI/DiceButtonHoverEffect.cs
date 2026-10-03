using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class DiceButtonHoverEffect : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    private Outline outline;

    private void Start()
    {
        // 获取Outline组件
        outline = GetComponent<Outline>();
        // 初始时隐藏轮廓
        if (outline != null)
        {
            outline.enabled = false;
        }
    }

    // 鼠标进入时显示轮廓
    public void OnPointerEnter(PointerEventData eventData)
    {
        if (outline != null)
        {
            outline.enabled = true;
        }
    }

    // 鼠标离开时隐藏轮廓
    public void OnPointerExit(PointerEventData eventData)
    {
        if (outline != null)
        {
            outline.enabled = false;
        }
    }
}

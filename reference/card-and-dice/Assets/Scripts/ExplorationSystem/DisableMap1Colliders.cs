using UnityEngine;

public class DisableMap1Colliders : MonoBehaviour
{
    private void Start()
    {
        // 查找Map1对象
        GameObject map1 = GameObject.Find("Map1");
        if (map1 != null)
        {
            // 遍历Map1的所有子对象
            foreach (Transform child in map1.transform)
            {
                // 检查子对象是否是格子
                if (child.name.StartsWith("Hex_"))
                {
                    // 获取子对象的碰撞器
                    Collider collider = child.GetComponent<Collider>();
                    if (collider != null)
                    {
                        // 禁用碰撞器
                        collider.enabled = false;
                    }
                }
            }
            Debug.Log("Map1的格子碰撞器已禁用");
        }
        else
        {
            Debug.LogError("Map1对象未找到");
        }
    }
}

using UnityEngine;

/// <summary>
/// 通用单例基类（非泛型版，支持 Unity AddComponent）。
/// 参考：NSWells《杀戮尖塔》P2 Singleton 实现。
/// </summary>
public abstract class SingletonBase : MonoBehaviour
{
    protected static SingletonBase s_instance;

    protected virtual void Awake()
    {
        if (s_instance != null && s_instance != this)
        {
            Destroy(gameObject);
            return;
        }
        s_instance = this;
    }

    protected virtual void OnApplicationQuit()
    {
        s_instance = null;
    }
}

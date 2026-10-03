// 一次性安装器：把 TempBuffHud 挂到 UICanvas（与「Tools/背包/4. 挂载 UI 组件」同风格）
#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;

public static class TempBuffHudInstaller
{
    [MenuItem("Tools/荒野事件/挂载临时强化 HUD 到 UICanvas")]
    public static void Install()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            Debug.LogError("[TempBuffHudInstaller] 场景里找不到 UICanvas");
            return;
        }
        if (canvas.GetComponentInChildren<TempBuffHud>(true) != null)
        {
            Debug.Log("[TempBuffHudInstaller] TempBuffHud 已存在，跳过");
            return;
        }
        TempBuffHud hud = canvas.AddComponent<TempBuffHud>();
        EditorUtility.SetDirty(hud);
        Debug.Log("[TempBuffHudInstaller] 已挂载 TempBuffHud（记得保存场景）");
    }
}
#endif

// =============================================================================
// 模块：M7 背包系统 - TopRightButtonBar 顶栏三按钮（背包/卡包/设置）
// 用途：三个按钮挂在 StatusBar 下（右对齐），常态显示。编辑态由 Tools/背包/5
//       构建静态节点；运行态本组件绑定点击。左→右 = 背包 / 卡包 / 设置。
// 点击：背包→InventoryUI.TryOpen；卡包→CardPackUI.Toggle；设置→SettingsUI.Toggle。
// 设计依据：用户 HUD 需求（2026-09-09：三按钮移入 StatusBar、不 Play 也显示）。
// =============================================================================
using UnityEngine;

public class TopRightButtonBar : MonoBehaviour
{
    static TopRightButtonBar _instance;
    public static TopRightButtonBar Instance => _instance;

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void Start()
    {
        BindOrBuild();
    }

    private void OnDestroy()
    {
        if (_instance == this) _instance = null;
    }

    /// <summary>绑定 StatusBar 下的静态按钮；场景未预建（未跑菜单 5）时兜底构建。</summary>
    void BindOrBuild()
    {
        GameObject statusBar = GameObject.Find("UICanvas/StatusBar");
        if (statusBar == null)
        {
            Debug.LogError("[TopRightButtonBar] 找不到 UICanvas/StatusBar，三按钮无法挂载");
            return;
        }

        Transform bar = statusBar.transform.Find(StatusBarHud.ButtonBarName);
        if (bar == null)
        {
            // 运行态兜底：场景没保存过预建节点，现场构建（不影响编辑态，Play 结束后销毁）
            StatusBarHud.BuildButtonBar(statusBar.transform);
        }

        if (!StatusBarHud.TryBindButtons(statusBar.transform, OnClick))
        {
            Debug.LogWarning("[TopRightButtonBar] 三按钮节点缺失，绑定失败");
        }
    }

    void OnClick(int idx)
    {
        switch (idx)
        {
            case 0: // 背包
                var inv = InventoryUI.Instance ?? FindObjectOfType<InventoryUI>();
                inv?.TryOpen();
                break;
            case 1: // 卡包
                CardPackUI.Instance?.Toggle();
                break;
            case 2: // 设置
                SettingsUI.Instance?.Toggle();
                break;
        }
    }
}

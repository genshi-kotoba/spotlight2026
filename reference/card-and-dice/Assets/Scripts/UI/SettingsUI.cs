// =============================================================================
// 模块：M7 背包系统 - SettingsUI 设置界面（HUD）
// 用途：设置面板。含三个按钮：重置游戏（清空当局 → 重载场景回到最开始）、
//       退出游戏（Application.Quit；编辑器内 = 退出 Play）、关闭。
// 重置设计依据：与玩家死亡重载同管线（BattleResultHandler.ResolveDefeat）——
//       ExpeditionLifecycle.EndExpedition（清静态）+ SceneManager.LoadScene。
//       场景物体随重载重建，静态字段由 EndExpedition 清理，杜绝残留污染下一局。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.SceneManagement;

public class SettingsUI : MonoBehaviour
{
    static SettingsUI _instance;
    public static SettingsUI Instance => _instance;

    /// <summary>设置面板是否打开（★2026-09-12：全局快捷键要据此让路）。</summary>
    public static bool IsOpen => _instance != null && _instance._isOpen;

    RectTransform _root;
    Text _resetLabel;
    bool _resetArmed;      // 重置防误触：第一次点击进入「确认」态，3 秒内再点才执行
    bool _built;
    bool _isOpen;

    const float ConfirmWindow = 3f;

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void Start()
    {
        if (!_built) Build();
    }

    private void OnDestroy()
    {
        if (_instance == this) _instance = null;
        _built = false;
    }

    void Build()
    {
        _root = InventoryUIKit.CreateOverlay("SettingsPanel");
        if (_root == null) return;

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, new Vector2(440f, 420f), Vector2.zero, InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        Text title = InventoryUIKit.CreateLabel("Title", panel.transform, "设置", 24, InventoryUIKit.Brass, TextAnchor.UpperLeft);
        InventoryUIKit.Place(title.rectTransform, new Vector2(400f, 34f), new Vector2(0f, 210f - 17f));

        // 重置游戏（防误触两段确认）
        Button resetBtn = InventoryUIKit.CreateButton("ResetButton", panel.transform, "重置游戏", new Vector2(260f, 56f),
                                                      new Vector2(0f, 58f), OnResetClicked);
        resetBtn.image.color = InventoryUIKit.SlotSel;
        _resetLabel = resetBtn.transform.Find("Label")?.GetComponent<Text>();

        // 退出游戏
        Button quitBtn = InventoryUIKit.CreateButton("QuitButton", panel.transform, "退出游戏", new Vector2(260f, 56f),
                                                     new Vector2(0f, -12f), QuitGame);
        quitBtn.image.color = new Color(0.42f, 0.12f, 0.08f, 1f);

        // 说明
        Text hint = InventoryUIKit.CreateLabel("Hint", panel.transform,
                                               "重置会清空本局进度并回到最开始（与死亡重载同效果）",
                                               13, InventoryUIKit.Muted, TextAnchor.MiddleCenter);
        InventoryUIKit.Place(hint.rectTransform, new Vector2(400f, 20f), new Vector2(0f, -88f));

        Button closeBtn = InventoryUIKit.CreateButton("CloseButton", panel.transform, "关闭", new Vector2(120f, 42f),
                                                      new Vector2(440f * 0.5f - 75f, -210f + 25f), Hide);

        _built = true;
    }

    // ------------------------------------------------------------------
    // 动作：重置 / 退出
    // ------------------------------------------------------------------
    void OnResetClicked()
    {
        if (!_resetArmed)
        {
            // 防误触：第一次点击进入确认态（给个宽限窗口，超时自动复原）
            _resetArmed = true;
            if (_resetLabel != null) _resetLabel.text = "再点一次确认重置？";
            CancelInvoke(nameof(DisarmReset));
            Invoke(nameof(DisarmReset), ConfirmWindow);
            return;
        }
        CancelInvoke(nameof(DisarmReset));
        _resetArmed = false;
        DoReset();
    }

    void DisarmReset()
    {
        _resetArmed = false;
        if (_resetLabel != null) _resetLabel.text = "重置游戏";
    }

    /// <summary>
    /// 重置到最开始：与玩家死亡重载同管线。必须先 EndExpedition 再 LoadScene
    /// （EndExpedition 依赖存活的订阅者：CorpseRegistry 广播 → CorpseSpawner 清地图标记）。
    /// </summary>
    void DoReset()
    {
        Debug.Log("[设置] 重置游戏：清空当局静态状态 → 重载场景到初始状态");
        ExpeditionLifecycle.EndExpedition("设置-重置");
        Scene scene = SceneManager.GetActiveScene();
        SceneManager.LoadScene(scene.name);
    }

    static void QuitGame()
    {
        Debug.Log("[设置] 退出游戏");
#if UNITY_EDITOR
        // 编辑器里 Application.Quit 无效，改为退出 Play 模式（功能等价）
        UnityEditor.EditorApplication.isPlaying = false;
#else
        Application.Quit();
#endif
    }

    // ------------------------------------------------------------------
    // 面板开关
    // ------------------------------------------------------------------
    public void Show()
    {
        if (!_built) Build();
        if (_root == null) return;
        DisarmReset();
        _isOpen = true;
        _root.gameObject.SetActive(true);
    }

    public void Hide()
    {
        if (!_isOpen) return;
        CancelInvoke(nameof(DisarmReset));
        DisarmReset();
        _isOpen = false;
        if (_root != null) _root.gameObject.SetActive(false);
    }

    public void Toggle()
    {
        if (_isOpen) Hide();
        else Show();
    }
}

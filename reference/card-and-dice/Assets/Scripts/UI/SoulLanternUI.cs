// =============================================================================
// 模块：M7 背包系统 - SoulLanternUI 魂灯界面（背包子窗口）
// 用途：显示魂灯内 10 格灵魂，选中可销毁（腾空间 / 主动清理）
// 设计依据：spec §7（灵魂与魂灯）、§11（魂灯界面：10 个灵魂格；满时强制销毁选择）
// 挂载：UICanvas（与 InventoryUI 同处，由构建器菜单项 4 添加）
// 归属：只从背包的魂灯格打开（InventoryUI 路由 ESC）；模态锁由 InventoryUI 持有，本类不碰。
//       结算窗口的「灯满销毁选择」是另一套流程（Task 20），不复用本窗口。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class SoulLanternUI : MonoBehaviour
{
    [Header("布局")]
    [SerializeField] private Vector2 panelSize = new Vector2(520f, 420f);
    [SerializeField] private int columns = 5;
    [SerializeField] private Vector2 cellSize = new Vector2(88f, 88f);
    [SerializeField] private Vector2 cellSpacing = new Vector2(8f, 8f);

    static SoulLanternUI _instance;
    public static bool IsOpen => _instance != null && _instance._isOpen;

    RectTransform _root;
    Text _titleText;
    Text _hintText;
    readonly List<InventoryUIKit.SlotCell> _cells = new List<InventoryUIKit.SlotCell>();

    bool _built;
    bool _isOpen;
    int _selectedIndex = -1;

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void OnDestroy()
    {
        if (_instance == this) _instance = null;
    }

    public static void Open()
    {
        if (_instance == null)
        {
            Debug.LogWarning("[SoulLanternUI] 场景中没有 SoulLanternUI（先跑 Tools/背包/4. 挂载 UI 组件到 UICanvas）");
            return;
        }
        _instance.OpenSelf();
    }

    public static void Close()
    {
        if (_instance != null) _instance.CloseSelf();
    }

    void OpenSelf()
    {
        if (!_built) Build();
        if (_root == null) return;
        _isOpen = true;
        _selectedIndex = -1;
        _root.gameObject.SetActive(true);
        Refresh();
        PopupFX.PlayOpen(_root);                        // ★2026-09-12 统一入场手感
    }

    void CloseSelf()
    {
        if (!_isOpen) return;
        _isOpen = false;
        _root.gameObject.SetActive(false);
    }

    void Build()
    {
        _root = InventoryUIKit.CreateOverlay("SoulLanternPanel");
        if (_root == null) return;

        Image panel = InventoryUIKit.CreatePanel("Panel", _root, panelSize, Vector2.zero, InventoryUIKit.PanelBg);
        Outline outline = panel.gameObject.AddComponent<Outline>();
        outline.effectColor = InventoryUIKit.Gold;
        outline.effectDistance = new Vector2(3f, 3f);

        _titleText = InventoryUIKit.CreateLabel("Title", panel.transform, "魂灯", 22, InventoryUIKit.Brass,
                                                TextAnchor.UpperLeft);
        InventoryUIKit.Place(_titleText.rectTransform, new Vector2(panelSize.x - 40f, 30f),
                             new Vector2(0f, panelSize.y * 0.5f - 30f));

        RectTransform gridRT = InventoryUIKit.CreateRect("Grid", panel.transform);
        InventoryUIKit.Place(gridRT, new Vector2(panelSize.x - 40f, panelSize.y - 150f), new Vector2(0f, -10f));
        _cells.AddRange(InventoryUIKit.CreateSlotGrid(gridRT, SoulLantern.Capacity, columns, cellSize, cellSpacing,
                                                      new Vector2(-(panelSize.x - 40f) * 0.5f, (panelSize.y - 150f) * 0.5f),
                                                      OnCellClicked));

        _hintText = InventoryUIKit.CreateLabel("Hint", panel.transform, "", 14, InventoryUIKit.Muted,
                                               TextAnchor.MiddleLeft);
        InventoryUIKit.Place(_hintText.rectTransform, new Vector2(panelSize.x - 200f, 40f),
                             new Vector2(-80f, -panelSize.y * 0.5f + 44f));

        InventoryUIKit.CreateButton("DestroyButton", panel.transform, "销毁选中", new Vector2(130f, 38f),
                                    new Vector2(panelSize.x * 0.5f - 80f, -panelSize.y * 0.5f + 76f),
                                    DestroySelected);
        InventoryUIKit.CreateButton("CloseButton", panel.transform, "返回背包", new Vector2(130f, 38f),
                                    new Vector2(panelSize.x * 0.5f - 80f, -panelSize.y * 0.5f + 32f),
                                    CloseSelf);

        _built = true;
    }

    void Refresh()
    {
        if (InventoryManager.Instance == null || !_built) return;

        SoulLantern lantern = InventoryManager.Instance.Inventory.Lantern;
        _titleText.text = $"魂灯　{lantern.Count}/{SoulLantern.Capacity}";

        for (int i = 0; i < _cells.Count; i++)
        {
            ItemData soul = i < lantern.Souls.Count ? lantern.Souls[i] : null;
            _cells[i].nameText.text = soul != null ? soul.itemName : "";
            _cells[i].countText.text = "";
            _cells[i].background.color = (i == _selectedIndex) ? InventoryUIKit.SlotSel
                                         : (soul != null ? InventoryUIKit.SlotBg
                                         : new Color(InventoryUIKit.SlotBg.r, InventoryUIKit.SlotBg.g,
                                                     InventoryUIKit.SlotBg.b, 0.35f));
        }

        ItemData selected = (_selectedIndex >= 0 && _selectedIndex < lantern.Souls.Count)
                            ? lantern.Souls[_selectedIndex] : null;
        _hintText.text = selected != null ? $"{selected.itemName}\n{selected.description}"
                                          : "点灵魂选中，再点「销毁选中」腾出灯位。ESC 返回背包。";
    }

    void OnCellClicked(int index)
    {
        if (InventoryManager.Instance == null) return;
        if (index >= InventoryManager.Instance.Inventory.Lantern.Souls.Count) { _selectedIndex = -1; Refresh(); return; }
        _selectedIndex = index;
        Refresh();
    }

    void DestroySelected()
    {
        if (InventoryManager.Instance == null || _selectedIndex < 0) return;
        SoulLantern lantern = InventoryManager.Instance.Inventory.Lantern;
        if (_selectedIndex >= lantern.Souls.Count) return;

        string soulName = lantern.Souls[_selectedIndex].itemName;
        if (lantern.RemoveAt(_selectedIndex))
        {
            Debug.Log($"[SoulLanternUI] 销毁灵魂 {soulName}，魂灯 {lantern.Count}/{SoulLantern.Capacity}");
            _selectedIndex = -1;
            Refresh();
        }
    }
}

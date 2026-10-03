// =============================================================================
// 模块：M7 背包系统 - DiceHud 骰子计数列表（HUD）
// 用途：常态显示背包里每种战斗骰的数量（图标 ×N），挂在 UICanvas 下。
//       首行垂直中心对齐 EnergyPointDisplay，水平贴其左侧；
//       骰子种类增多先向下依次排列，触底后改为仅向上延伸。
// 常态显示：编辑态由 Tools/背包/5 预建容器（含占位行，不 Play 也可见），
//           运行态本组件清空占位行、按背包数据重建行并刷新数量。
// 实现：零美术，D4 三角图标由 InventoryUIKit.D4Sprite 提供。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class DiceHud : MonoBehaviour
{
    static DiceHud _instance;
    public static DiceHud Instance => _instance;

    RectTransform _root;
    readonly List<RectTransform> _rows = new List<RectTransform>();
    readonly List<Text> _countTexts = new List<Text>();
    readonly List<ItemData> _shownDiceItems = new List<ItemData>();

    bool _built;
    float _rowHeight = 26f;
    float _anchorX = 120f;     // 首行右边缘 x（对齐 EnergyPointDisplay 左边缘 - 间距）
    float _anchorY = 180f;     // 首行垂直中心 y（对齐 EnergyPointDisplay）
    float _gapFromEP = 16f;    // 与 EnergyPointDisplay 左边缘的间距

    private void Awake()
    {
        if (_instance != null && _instance != this) { Destroy(this); return; }
        _instance = this;
    }

    private void Start()
    {
        BindOrBuild();
        if (InventoryManager.Instance != null)
            InventoryManager.Instance.OnInventoryChanged += OnInventoryChanged;
    }

    private void OnDestroy()
    {
        if (_instance == this) _instance = null;
        if (InventoryManager.Instance != null)
            InventoryManager.Instance.OnInventoryChanged -= OnInventoryChanged;
        _built = false;
    }

    void BindOrBuild()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null) { Debug.LogError("[DiceHud] 找不到 UICanvas，骰子 HUD 无法构建"); return; }

        Transform rootTf = canvas.transform.Find(StatusBarHud.DiceListName);
        if (rootTf == null)
        {
            StatusBarHud.BuildDiceList(canvas.transform);
            rootTf = canvas.transform.Find(StatusBarHud.DiceListName);
        }
        _root = (RectTransform)rootTf;

        ResolveAnchor();
        BuildRows();
        _built = true;
    }

    /// <summary>首行锚点：垂直中心对齐 EnergyPointDisplay 中心，水平贴其左边缘。
    /// 用 position（世界=屏幕像素）+ sizeDelta 计算，忽略 rotation（EP 是 45° 菱形图标）。</summary>
    void ResolveAnchor()
    {
        var ep = FindObjectOfType<EnergyPointDisplay>();
        if (ep != null)
        {
            RectTransform epRt = ep.GetComponent<RectTransform>();
            Vector2 centerLocal = _root.InverseTransformPoint(epRt.position);
            float halfW = epRt.sizeDelta.x * epRt.pivot.x;   // 左半边宽（未旋转布局尺寸）
            _anchorX = centerLocal.x - halfW - _gapFromEP;   // 贴 EP 左边缘，留间距
            _anchorY = centerLocal.y;
        }
        else
        {
            Debug.LogWarning("[DiceHud] 找不到 EnergyPointDisplay，骰子列表锚点回退 (120, 180)");
            _anchorX = 120f;
            _anchorY = 180f;
        }
    }

    void OnInventoryChanged()
    {
        if (InventoryManager.Instance == null) return;

        // ★2026-09-13 用户定稿：只显示背包里真正拥有的战斗骰（数量 > 0）——
        //   数量归零的种类要整行消失，所以可见集合变了就得重建行，不能只刷数字。
        List<ItemData> visible = CollectVisibleDice();
        bool changed = visible.Count != _shownDiceItems.Count;
        if (!changed)
        {
            for (int i = 0; i < visible.Count; i++)
                if (!ReferenceEquals(visible[i], _shownDiceItems[i])) { changed = true; break; }
        }
        if (changed) BuildRows();
        else RefreshCounts();
    }

    /// <summary>
    /// ★2026-09-13 用户定稿：左侧计数器只列「背包内拥有」的战斗骰，
    /// 数量为 0 的种类不显示（全部为 0 时整块列表为空）。
    /// 口径 = InventoryManager.CountDice；临时劣质骰不入背包，永远不会出现在这里。
    /// </summary>
    List<ItemData> CollectVisibleDice()
    {
        var visible = new List<ItemData>();
        if (InventoryManager.Instance == null) return visible;

        IReadOnlyList<ItemData> diceItems = InventoryManager.Instance.AllDiceItems;
        if (diceItems == null) return visible;

        for (int i = 0; i < diceItems.Count; i++)
        {
            ItemData item = diceItems[i];
            if (item == null || item.diceRef == null) continue;
            if (InventoryManager.Instance.CountDice(item.diceRef) <= 0) continue;   // 数量为 0 → 不显示
            visible.Add(item);
        }
        return visible;
    }

    void BuildRows()
    {
        if (_root == null) return;
        // 清空旧行 + 编辑态占位行（倒序销毁避免遍历中改子节点）
        for (int i = _root.childCount - 1; i >= 0; i--)
            Destroy(_root.GetChild(i).gameObject);
        _rows.Clear(); _countTexts.Clear(); _shownDiceItems.Clear();

        if (InventoryManager.Instance == null) return;

        // ★2026-09-13：只建「拥有数量 > 0」的骰子行（与 OnInventoryChanged 同一口径）
        List<ItemData> diceItems = CollectVisibleDice();
        if (diceItems.Count == 0) return;

        // ★2026-09-09 UI 自适应：触底阈值改用 _root（全屏拉伸容器）的 rect 高度，
        //   与 CanvasScaler 的参考分辨率一致。原来用 Screen.height（物理像素），
        //   换了分辨率/缩放后阈值错位，骰子列表会跑到屏幕外。
        float bottomMargin = -_root.rect.height * 0.5f + 60f;
        int below = 0, above = 0;
        for (int i = 0; i < diceItems.Count; i++)
        {
            float y;
            if (i == 0) y = _anchorY;
            else
            {
                float downY = _anchorY - (below + 1) * _rowHeight;   // 先向下
                if (downY >= bottomMargin) { below++; y = downY; }
                else { above++; y = _anchorY + above * _rowHeight; } // 触底后仅向上
            }

            RectTransform row = InventoryUIKit.CreateRect($"DiceRow_{i}", _root);
            row.anchorMin = row.anchorMax = new Vector2(1f, 0.5f);
            row.pivot = new Vector2(1f, 0.5f);
            row.sizeDelta = new Vector2(120f, _rowHeight);
            row.anchoredPosition = new Vector2(_anchorX, y);

            // D4 三角图标（靠左）
            Image icon = row.gameObject.AddComponent<Image>();
            icon.sprite = InventoryUIKit.D4Sprite;
            icon.color = InventoryUIKit.Brass;
            icon.raycastTarget = false;
            float iconSize = _rowHeight - 6f;
            icon.rectTransform.anchorMin = icon.rectTransform.anchorMax = new Vector2(0f, 0.5f);
            icon.rectTransform.pivot = new Vector2(0f, 0.5f);
            icon.rectTransform.sizeDelta = new Vector2(iconSize, iconSize);
            icon.rectTransform.anchoredPosition = new Vector2(iconSize * 0.5f, 0f);

            // ×N 文本（图标右侧，左对齐小字）
            Text count = InventoryUIKit.CreateLabel($"Count_{i}", row, "", 16, InventoryUIKit.Cream, TextAnchor.MiddleLeft);
            count.rectTransform.anchorMin = new Vector2(0f, 0.5f);
            count.rectTransform.anchorMax = new Vector2(0f, 0.5f);
            count.rectTransform.pivot = new Vector2(0f, 0.5f);
            count.rectTransform.sizeDelta = new Vector2(90f, _rowHeight);
            count.rectTransform.anchoredPosition = new Vector2(iconSize + 6f, 0f);

            _rows.Add(row);
            _countTexts.Add(count);
            _shownDiceItems.Add(diceItems[i]);
        }

        RefreshCounts();
    }

    void RefreshCounts()
    {
        if (InventoryManager.Instance == null) return;
        for (int i = 0; i < _shownDiceItems.Count; i++)
        {
            int n = InventoryManager.Instance.CountDice(_shownDiceItems[i].diceRef);
            if (_countTexts[i] != null) _countTexts[i].text = $"×{n}";
        }
    }
}

// =============================================================================
// 模块：UI - 临时强化顶栏 TempBuffHud
// 用途：显示当局持有的临时强化（design §3.5「顶栏一行图标位」）。
// 纯代码构建（仿 DiceHud）：订阅 TempBuffRuntime.OnChanged 即时刷新。
// 挂载：编辑器菜单 Tools/荒野事件/挂载临时强化 HUD 到 UICanvas
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public class TempBuffHud : MonoBehaviour
{
    const float CellW = 76f;
    const float CellH = 26f;

    RectTransform _root;
    readonly List<GameObject> _cells = new List<GameObject>();

    void Awake()
    {
        Build();
    }

    void OnEnable()
    {
        TempBuffRuntime.OnChanged -= Refresh;
        TempBuffRuntime.OnChanged += Refresh;
        Refresh();
    }

    void OnDisable()
    {
        TempBuffRuntime.OnChanged -= Refresh;
    }

    void Build()
    {
        _root = InventoryUIKit.CreateRect("TempBuffRow", transform);
        _root.anchorMin = _root.anchorMax = new Vector2(0f, 1f);
        _root.pivot = new Vector2(0f, 1f);
        _root.anchoredPosition = new Vector2(12f, -52f);
        _root.sizeDelta = new Vector2(400f, CellH);
    }

    void Refresh()
    {
        if (_root == null) return;

        foreach (GameObject go in _cells) if (go != null) Destroy(go);
        _cells.Clear();

        IList<TempBuffData> held = TempBuffRuntime.Held;
        for (int i = 0; i < held.Count; i++)
        {
            TempBuffData b = held[i];
            if (b == null) continue;

            RectTransform cell = InventoryUIKit.CreateRect("Buff_" + b.kind, _root);
            cell.anchorMin = cell.anchorMax = new Vector2(0f, 1f);
            cell.pivot = new Vector2(0f, 1f);
            cell.sizeDelta = new Vector2(CellW, CellH);
            cell.anchoredPosition = new Vector2(i * (CellW + 6f), 0f);

            Image bg = cell.gameObject.AddComponent<Image>();
            bg.sprite = InventoryUIKit.WhitePixel;
            bg.color = new Color(0.10f, 0.06f, 0.02f, 0.85f);
            bg.raycastTarget = false;

            Outline oln = cell.gameObject.AddComponent<Outline>();
            oln.effectColor = InventoryUIKit.Gold;
            oln.effectDistance = new Vector2(1f, -1f);

            string label = string.IsNullOrEmpty(b.buffName) ? b.kind.ToString() : b.buffName;
            Text t = InventoryUIKit.CreateLabel("Label", cell, label, 14, InventoryUIKit.Brass,
                                                TextAnchor.MiddleCenter);
            InventoryUIKit.Stretch(t.rectTransform);

            _cells.Add(cell.gameObject);
        }
    }
}

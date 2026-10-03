// =============================================================================
// 模块：M5a 消耗品栏 ConsumableBar
// 用途：顶栏 3 格消耗品栏 = 背包道具分区（消耗品）镜像，点击直接使用（spec §13:136）
// 设计依据：docs/superpowers/specs/2026-09-08-背包系统-design.md §11（UI）/§13（衔接）
// 更新：M7 从 Demo 占位实装——格子按顺序绑定 Inventory.Consumables 前 3 格，
//       点击走 InventoryManager.TryUseConsumable（效果无法结算则不扣）。
// 注意：只加行为、不改顶栏布局（PROJECT_INDEX §18「顶栏布局为用户成品」，
//       本改动由 spec §13:136 授权）。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 消耗品栏：3 个格子，镜像背包道具分区。
/// 挂载位置：UICanvas/StatusBar 下的子物体（HP/材料/回合 左侧），不碰其他已有对象。
/// 挂接是懒的：Update 首帧起等 InventoryManager.Instance 就绪后订阅 OnInventoryChanged；
/// 编辑态 Awake/Update 都不跑，L2 直接调 Refresh 手动刷。
/// </summary>
public class ConsumableBar : MonoBehaviour
{
    [Header("消耗品格子（Inspector 绑定 3 个格子）")]
    [Tooltip("第 1 格药水位")]
    public GameObject PotionSlot1;

    [Tooltip("第 2 格药水位")]
    public GameObject PotionSlot2;

    [Tooltip("第 3 格药水位")]
    public GameObject PotionSlot3;

    [Header("格子配色（按消耗品效果分类）")]
    [SerializeField] private Color emptyColor = new Color(1f, 1f, 1f, 0.15f);
    [SerializeField] private Color healColor = new Color(0.85f, 0.35f, 0.30f, 0.9f);
    [SerializeField] private Color energyColor = new Color(0.30f, 0.55f, 0.85f, 0.9f);
    [SerializeField] private Color otherColor = new Color(0.89f, 0.71f, 0.40f, 0.9f);

    /// <summary>★v2.3（2026-09-13）教学钩子：玩家用掉了一件消耗品（结算成功才广播）。
    /// 对应 tutorial release = ConsumableUsed。零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnConsumableUsed;

    private static ConsumableBar _instance;

    /// <summary>单例兜底（编辑态 Awake 不执行时现找）。</summary>
    public static ConsumableBar Inv()
    {
        if (_instance != null) return _instance;
        _instance = FindObjectOfType<ConsumableBar>();
        return _instance;
    }

    private Button[] _buttons = new Button[3];
    private Image[] _images = new Image[3];
    private Text[] _labels = new Text[3];
    private bool _bound;

    /// <summary>已订阅的 InventoryManager 实例（退订时按同一实例，防串）。</summary>
    private InventoryManager _subscribed;

    private void Awake()
    {
        _instance = this;
        Bind();
        Refresh();
    }

    private void OnDestroy()
    {
        if (_instance == this) _instance = null;
        Unsubscribe();
    }

    private void OnDisable()
    {
        Unsubscribe();
    }

    private void Update()
    {
        // 懒挂接：背包管理器晚于本组件 Awake 时，下帧再试；挂上后改走事件刷新
        if (_subscribed != null) return;
        InventoryManager inv = InventoryManager.Instance;
        if (inv == null) return;
        _subscribed = inv;
        inv.OnInventoryChanged += Refresh;
        Refresh();
    }

    private void Unsubscribe()
    {
        if (_subscribed == null) return;
        _subscribed.OnInventoryChanged -= Refresh;
        _subscribed = null;
    }

    /// <summary>
    /// 幂等绑定：给 3 个格子补 Button/Image，Label 改居中拉伸并关射线
    /// （场景既有 Label 是 200×40 且吃射线，会挡住格子的点击——顺手修，不动布局）。
    /// </summary>
    private void Bind()
    {
        if (_bound) return;

        GameObject[] slots = { PotionSlot1, PotionSlot2, PotionSlot3 };
        for (int i = 0; i < 3; i++)
        {
            if (slots[i] == null) continue;

            Image img = slots[i].GetComponent<Image>();
            if (img == null) img = slots[i].AddComponent<Image>();
            img.raycastTarget = true;

            Button btn = slots[i].GetComponent<Button>();
            if (btn == null) btn = slots[i].AddComponent<Button>();
            btn.targetGraphic = img;
            btn.onClick.RemoveAllListeners();
            int index = i;   // 闭包捕获拷贝，循环变量会漂移
            btn.onClick.AddListener(() => UseSlot(index));

            Transform labelTf = slots[i].transform.Find("Label");
            Text label = labelTf != null ? labelTf.GetComponent<Text>() : null;
            if (label != null)
            {
                label.raycastTarget = false;
                InventoryUIKit.Stretch(label.rectTransform);
                label.alignment = TextAnchor.MiddleCenter;
            }

            _images[i] = img;
            _buttons[i] = btn;
            _labels[i] = label;
        }
        _bound = true;
    }

    /// <summary>刷新 3 格：底色按效果分类，文字用单字标记（空 = 无）。</summary>
    public void Refresh()
    {
        Bind();
        Inventory inv = InventoryManager.Instance != null ? InventoryManager.Instance.Inventory : null;
        for (int i = 0; i < 3; i++)
        {
            ItemData item = null;
            if (inv != null && i < inv.Consumables.Count) item = inv.Consumables[i].item;
            if (_images[i] != null) _images[i].color = ColorOf(item);
            if (_labels[i] != null) _labels[i].text = MarkOf(item);
        }
    }

    /// <summary>点第 index 格：使用该格消耗品（空格子/效果无法结算 → 无操作）。</summary>
    public void UseSlot(int index)
    {
        Bind();
        InventoryManager inv = InventoryManager.Instance;
        if (inv == null || index < 0 || index > 2) return;
        if (index >= inv.Inventory.Consumables.Count) return;

        ItemData item = inv.Inventory.Consumables[index].item;
        if (inv.TryUseConsumable(item)) OnConsumableUsed?.Invoke();   // ★v2.3 教学钩子：结算成功才算
        Refresh();
    }

    private Color ColorOf(ItemData item)
    {
        if (item == null) return emptyColor;
        switch (item.useEffect)
        {
            case ConsumableEffect.回血5: return healColor;
            case ConsumableEffect.回能量2: return energyColor;
            default: return otherColor;
        }
    }

    private string MarkOf(ItemData item)
    {
        if (item == null) return "";
        switch (item.useEffect)
        {
            case ConsumableEffect.回血5: return "血";
            case ConsumableEffect.回能量2: return "能";
            default:
                return string.IsNullOrEmpty(item.itemName) ? "?" : item.itemName.Substring(0, 1);
        }
    }

    /// <summary>获取指定索引的格子（0-based，保留 M5a 既有接口）。</summary>
    public GameObject GetSlot(int index)
    {
        return index switch
        {
            0 => PotionSlot1,
            1 => PotionSlot2,
            2 => PotionSlot3,
            _ => null
        };
    }
}

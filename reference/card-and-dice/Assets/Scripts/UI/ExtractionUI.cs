// =============================================================================
// 模块：主动撤离确认弹窗 ExtractionUI
// 用途：玩家走回撤离点（＝家＝出生格 'S'）时弹出的模态面板，两个行动——
//   ① 撤离（回藏身处）：把当局材料与灵魂**全额**入账，结束本局 → 加载 HideoutScene
//   ② 再留一会儿：关掉面板继续远征（走开再回来才会再弹）
//
// 面板无预制体，运行时在 UICanvas 下自建（与 BonfireUI 同一范式）。
// 为什么不用 EventPopupUI：那套弹窗吃 EventData + 鉴定/弃牌链路，且依赖场景里的
// 预制体实例；撤离确认只是一句摘要 + 两个按钮，自建更稳、零预制体依赖。
//
// 设计依据：docs/2026-09-15_委托随机远征-design.md §8「第 0 步：补主动撤离」；
//           结算口径见 ExtractionPoint.ConfirmExtraction（全额入账 vs 死亡保留一半）。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

public class ExtractionUI : MonoBehaviour
{
    private static ExtractionUI _instance;
    private Text _bodyText;

    public static bool IsOpen => _instance != null && _instance.gameObject.activeSelf;

    // ------------------------------------------------------------------
    // 显隐
    // ------------------------------------------------------------------

    public static void Show()
    {
        if (_instance == null) Create();
        _instance.RefreshBody();
        _instance.gameObject.SetActive(true);
        Interactions.ModalPopupActive = true;          // 锁移动 / 锁结束回合
        Interactions.RefreshEndTurnButton();
        PopupFX.PlayOpen(_instance.transform as RectTransform);
    }

    /// <summary>外部关闭入口（与实例方法 Hide 区分：实例方法给按钮用，这个是给调用方用的）。</summary>
    public static void ClosePopup()
    {
        if (_instance != null) _instance.Hide();
    }

    private static void Create()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            canvas = new GameObject("UICanvas", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
        }
        GameObject go = new GameObject("ExtractionUI", typeof(RectTransform));
        go.transform.SetParent(canvas.transform, false);
        _instance = go.AddComponent<ExtractionUI>();
        _instance.Build();
        go.SetActive(false);
    }

    private void Hide()
    {
        gameObject.SetActive(false);
        Interactions.ModalPopupActive = false;
        Interactions.RefreshEndTurnButton();
    }

    // ------------------------------------------------------------------
    // 便携内容
    // ------------------------------------------------------------------

    private void RefreshBody()
    {
        if (_bodyText == null) return;

        int materials = 0;
        string materialNames = "无";
        int souls = 0;
        int capacity = SoulLantern.Capacity;
        string soulNames = "无";

        InventoryManager inv = InventoryManager.Instance;
        if (inv != null)
        {
            // ★v2.1：材料按种类归并（与撤离入账同一份口径）
            var matStacks = MetaWallet.AggregateStacks(inv.Inventory.SlotsOfType(ItemType.材料));
            materials = MetaWallet.SumOf(matStacks);
            materialNames = MetaWallet.SummaryOf(matStacks);

            souls = inv.Inventory.Lantern.Count;
            // 按种类归并一句话摘要（魂灯里同种灵魂会有多条）
            var counts = new System.Collections.Generic.Dictionary<string, int>();
            foreach (ItemData s in inv.Inventory.Lantern.Souls)
            {
                if (s == null) continue;
                string n = string.IsNullOrEmpty(s.itemName) ? MetaWallet.LegacySoulName : s.itemName;
                counts.TryGetValue(n, out int c);
                counts[n] = c + 1;
            }
            if (counts.Count > 0)
            {
                var sb = new System.Text.StringBuilder();
                foreach (var kv in counts)
                {
                    if (sb.Length > 0) sb.Append(' ');
                    sb.Append(kv.Key).Append('×').Append(kv.Value);
                }
                soulNames = sb.ToString();
            }
        }

        _bodyText.text =
            "走回「家」格。撤离后本局结束。\n\n" +
            "<b>随身携带</b>\n" +
            $"　　材料　　{materials}　{materialNames}\n" +
            $"　　灵魂　　{souls}/{capacity}　{soulNames}\n\n" +
            "<color=#5FE08C>撤离：材料与灵魂全额入账。</color>\n" +
            "<color=#D97D5B>阵亡：材料留在尸体上（下次出击可回收），灵魂只留一半。</color>";
    }

    // ------------------------------------------------------------------
    // 构建面板（结构与 BonfireUI 保持一致：半透明背景 + 深色面板 + 按钮列）
    // ------------------------------------------------------------------

    private void Build()
    {
        // 半透明背景（点背景 = 留下）
        GameObject backdrop = new GameObject("Backdrop", typeof(RectTransform), typeof(Image));
        backdrop.transform.SetParent(transform, false);
        RectTransform brt = backdrop.GetComponent<RectTransform>();
        brt.anchorMin = Vector2.zero;
        brt.anchorMax = Vector2.one;
        brt.sizeDelta = Vector2.zero;
        Image bimg = backdrop.GetComponent<Image>();
        bimg.color = new Color(0f, 0f, 0f, 0.55f);
        Button bbtn = backdrop.AddComponent<Button>();
        bbtn.transition = Selectable.Transition.None;
        bbtn.onClick.AddListener(Hide);

        // 主面板
        GameObject panel = new GameObject("Panel", typeof(RectTransform), typeof(Image));
        panel.transform.SetParent(transform, false);
        RectTransform prt = panel.GetComponent<RectTransform>();
        prt.anchorMin = new Vector2(0.5f, 0.5f);
        prt.anchorMax = new Vector2(0.5f, 0.5f);
        prt.pivot = new Vector2(0.5f, 0.5f);
        prt.sizeDelta = new Vector2(480f, 400f);
        Image pimg = panel.GetComponent<Image>();
        pimg.color = new Color(0.09f, 0.11f, 0.10f, 0.98f);

        AddText(panel, "Title", "撤 离", 26, TextAnchor.MiddleCenter, new Color(0.37f, 0.88f, 0.55f),
                new Vector2(0.5f, 1f), new Vector2(0f, -22f), new Vector2(420f, 42f));

        _bodyText = AddText(panel, "Body", "", 16, TextAnchor.UpperLeft, new Color(0.90f, 0.90f, 0.88f),
                new Vector2(0.5f, 1f), new Vector2(0f, -76f), new Vector2(420f, 200f));

        MakeButton(panel, "BtnConfirm", "撤 离（回藏身处）", new Vector2(0f, -150f), OnConfirm);
        MakeButton(panel, "BtnStay", "再留一会儿", new Vector2(0f, -210f), Hide);
    }

    private Text AddText(GameObject parent, string name, string text, int fontSize, TextAnchor align, Color color,
        Vector2 anchor, Vector2 pos, Vector2 size)
    {
        GameObject go = new GameObject(name, typeof(RectTransform), typeof(Text));
        go.transform.SetParent(parent.transform, false);
        RectTransform rt = go.GetComponent<RectTransform>();
        rt.anchorMin = anchor;
        rt.anchorMax = anchor;
        rt.pivot = anchor;
        rt.anchoredPosition = pos;
        rt.sizeDelta = size;
        Text t = go.GetComponent<Text>();
        t.text = text;
        t.fontSize = fontSize;
        t.alignment = align;
        t.color = color;
        t.supportRichText = true;
        t.horizontalOverflow = HorizontalWrapMode.Wrap;
        if (t.font == null) t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        return t;
    }

    private void MakeButton(GameObject parent, string name, string label, Vector2 pos, UnityEngine.Events.UnityAction action)
    {
        GameObject b = new GameObject(name, typeof(RectTransform), typeof(Image), typeof(Button));
        b.transform.SetParent(parent.transform, false);
        RectTransform rt = b.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0.5f, 1f);
        rt.anchorMax = new Vector2(0.5f, 1f);
        rt.pivot = new Vector2(0.5f, 1f);
        rt.anchoredPosition = pos;
        rt.sizeDelta = new Vector2(400f, 46f);
        Image img = b.GetComponent<Image>();
        img.color = new Color(0.14f, 0.30f, 0.22f, 1f);
        Button btn = b.GetComponent<Button>();
        btn.transition = Selectable.Transition.ColorTint;
        btn.onClick.AddListener(action);

        GameObject txt = new GameObject("Label", typeof(RectTransform), typeof(Text));
        txt.transform.SetParent(b.transform, false);
        RectTransform trt = txt.GetComponent<RectTransform>();
        trt.anchorMin = Vector2.zero;
        trt.anchorMax = Vector2.one;
        trt.sizeDelta = Vector2.zero;
        Text t = txt.GetComponent<Text>();
        t.text = label;
        t.fontSize = 17;
        t.alignment = TextAnchor.MiddleCenter;
        t.color = Color.white;
        if (t.font == null) t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
    }

    // ------------------------------------------------------------------
    // 行动
    // ------------------------------------------------------------------

    private void OnConfirm()
    {
        // 先关面板再走结算：ConfirmExtraction 会 EndExpedition + LoadScene，
        // 面板留在 ModalPopupActive=true 会污染下一局（EndExpedition 也会清，双保险）。
        Hide();
        ExtractionPoint.ConfirmExtraction();
    }
}

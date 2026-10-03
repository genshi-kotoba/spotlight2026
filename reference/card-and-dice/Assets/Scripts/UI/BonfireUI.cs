// =============================================================================
// 模块：篝火面板 BonfireUI
// 用途：玩家站在篝火格上时弹出的模态面板，提供两个行动——
//   ① 休息：消耗当前所有探索骰回血（基础 30% 最大HP + 每枚探索骰 5%）+ 强制结束当前回合
//   ② 调整战术卡槽：不消耗骰/行动，打开卡包页（玩家仍在篝火格 → 战术槽处于可调整状态）
// 设计依据：用户 2026-09-11 篝火点需求。面板无预制体，运行时在 UICanvas 下自建。
//
// ★2026-09-12 用户定调（两处删减）：
//   ① **删掉「撤离（回藏身处）」** —— 撤离点是「家」（MapLayoutBuilder.spawnCoord），
//      不是篝火；篝火出现撤离按钮与总策划案 §2「篝火 ≠ 撤离点 ≠ 藏身处」直接冲突。
//   ② **教程图不显示「调整战术卡槽」** —— 教程只教「移动 / 打牌 / 篝火 / 装填」，
//      战术卡槽整套（按钮 / 面板 / 卡包边栏）在教程里都是隐藏的，篝火自然不该留这个入口。
//      判定走 MapLayoutBuilder.IsTutorial。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class BonfireUI : MonoBehaviour
{
    private static BonfireUI _instance;
    private Text _hintText;
    private GameObject _restTooltip;
    private Text _restTooltipText;

    public static bool IsOpen => _instance != null && _instance.gameObject.activeSelf;

    /// <summary>★2026-09-13 教学钩子：篝火面板被打开。零侵入——UI 不反向依赖教学。</summary>
    public static event System.Action OnBonfireOpened;

    /// <summary>★2026-09-13 教学钩子：玩家在篝火完成一次休息（回血 + 强制结束回合已执行完）。</summary>
    public static event System.Action OnRested;

    // ------------------------------------------------------------------
    // 生命周期 / 显隐
    // ------------------------------------------------------------------

    public static void ShowBonfire()
    {
        if (_instance == null) Create();
        _instance.gameObject.SetActive(true);
        Interactions.ModalPopupActive = true;          // 锁移动 / 锁结束回合
        Interactions.RefreshEndTurnButton();           // 同步禁用结束回合按钮
        if (_instance._hintText != null) _instance._hintText.text = "";
        if (_instance._restTooltip != null) _instance._restTooltip.SetActive(false);
        PopupFX.PlayOpen(_instance.transform as RectTransform);   // ★2026-09-12 统一入场手感
        OnBonfireOpened?.Invoke();                                // ★教学钩子（教程 S22 用）
    }

    public static void HideBonfire()
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
        GameObject go = new GameObject("BonfireUI", typeof(RectTransform));
        go.transform.SetParent(canvas.transform, false);
        _instance = go.AddComponent<BonfireUI>();
        _instance.Build();
        go.SetActive(false);
    }

    private void Hide()
    {
        if (_restTooltip != null) _restTooltip.SetActive(false);
        gameObject.SetActive(false);
        Interactions.ModalPopupActive = false;
        Interactions.RefreshEndTurnButton();
    }

    // ------------------------------------------------------------------
    // 休息按钮悬停小窗（替代原括号提示）
    // ------------------------------------------------------------------

    /// <summary>在休息按钮上方建一个悬停小窗，并接上 PointerEnter/Exit 事件。</summary>
    private void BuildRestTooltip(GameObject restBtn)
    {
        if (restBtn == null) return;

        _restTooltip = new GameObject("RestTooltip", typeof(RectTransform), typeof(Image));
        _restTooltip.transform.SetParent(restBtn.transform, false);
        RectTransform rt = _restTooltip.GetComponent<RectTransform>();
        rt.anchorMin = new Vector2(0.5f, 1f);
        rt.anchorMax = new Vector2(0.5f, 1f);
        rt.pivot = new Vector2(0.5f, 0f);                   // 底部 pivot → 向上展开，贴在按钮上方（不盖住按钮）
        rt.anchoredPosition = new Vector2(0f, 8f);
        rt.sizeDelta = new Vector2(380f, 46f);
        Image img = _restTooltip.GetComponent<Image>();
        img.color = new Color(0.06f, 0.05f, 0.04f, 0.95f);
        _restTooltip.SetActive(false);

        GameObject tipText = new GameObject("Text", typeof(RectTransform), typeof(Text));
        _restTooltipText = tipText.GetComponent<Text>();
        _restTooltipText.transform.SetParent(rt, false);
        RectTransform trt = _restTooltipText.GetComponent<RectTransform>();
        trt.anchorMin = Vector2.zero;
        trt.anchorMax = Vector2.one;
        trt.sizeDelta = Vector2.zero;
        Text t = _restTooltipText.GetComponent<Text>();
        t.fontSize = 14;
        t.alignment = TextAnchor.MiddleCenter;
        t.color = new Color(1f, 0.9f, 0.8f);
        if (t.font == null) t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");

        EventTrigger trig = restBtn.AddComponent<EventTrigger>();
        EventTrigger.Entry enter = new EventTrigger.Entry { eventID = EventTriggerType.PointerEnter };
        enter.callback.AddListener((UnityEngine.EventSystems.BaseEventData data) =>
        {
            UpdateRestTooltip();
            _restTooltip.SetActive(true);
        });
        trig.triggers.Add(enter);
        EventTrigger.Entry exit = new EventTrigger.Entry { eventID = EventTriggerType.PointerExit };
        exit.callback.AddListener((UnityEngine.EventSystems.BaseEventData data) => { _restTooltip.SetActive(false); });
        trig.triggers.Add(exit);
    }

    /// <summary>按当前探索骰数与最大生命，算出悬停小窗文案：结束回合，消耗 x 枚探索骰子，回复 x%（具体数字）点生命值。</summary>
    private void UpdateRestTooltip()
    {
        if (_restTooltipText == null) return;
        int dice = ExplorationTurnManager.Instance != null
            ? ExplorationTurnManager.Instance.RemainingExplorationDice()
            : 0;
        PlayerHealth ph = Object.FindObjectOfType<PlayerHealth>();
        int maxHp = ph != null ? ph.MaxHP : 0;
        int rate = 30 + 5 * dice;                                  // 基础 30% + 每骰 5%
        int heal = Mathf.FloorToInt(maxHp * (0.30f + 0.05f * dice));
        _restTooltipText.text = $"结束回合，消耗{dice}枚探索骰子，回复{rate}%（{heal}）点生命值。";
    }

    // ------------------------------------------------------------------
    // 构建面板
    // ------------------------------------------------------------------

    private void Build()
    {
        // 半透明背景（点背景 = 离开）
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
        prt.sizeDelta = new Vector2(440f, 440f);
        Image pimg = panel.GetComponent<Image>();
        pimg.color = new Color(0.12f, 0.10f, 0.08f, 0.98f);

        AddText(panel, "Title", "篝火", 26, TextAnchor.MiddleCenter, new Color(1f, 0.7f, 0.3f),
                new Vector2(0.5f, 1f), new Vector2(0f, -22f), new Vector2(380f, 42f));

        _hintText = AddText(panel, "Hint", "", 15, TextAnchor.UpperCenter, new Color(0.85f, 0.85f, 0.85f),
                new Vector2(0.5f, 1f), new Vector2(0f, -68f), new Vector2(400f, 56f));

        MakeButton(panel, "BtnRest", "休息", new Vector2(0f, -140f), OnRest);

        // ★2026-09-12：教程图隐藏「调整战术卡槽」（战术卡槽整套在教程里未解锁）。
        //   按钮纵向位置按实际建了几个按钮往下排，非教程图观感与旧版一致。
        float nextY = -200f;
        if (!MapLayoutBuilder.IsTutorial)
        {
            MakeButton(panel, "BtnAdjust", "调整战术卡槽", new Vector2(0f, nextY), OnAdjust);
            nextY -= 60f;
        }

        // ★2026-09-12：原「撤离（回藏身处）」按钮已删除——撤离点是「家」，不是篝火。
        MakeButton(panel, "BtnLeave", "离开", new Vector2(0f, nextY), Hide);

        // 休息按钮悬停小窗（替代原括号提示）：鼠标悬停显示消耗与回血数值
        GameObject restBtn = panel.transform.Find("BtnRest")?.gameObject;
        BuildRestTooltip(restBtn);
    }

    private Text AddText(GameObject parent, string name, string text, int fontSize, TextAnchor align, Color color, Vector2 anchor, Vector2 pos, Vector2 size)
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
        rt.sizeDelta = new Vector2(360f, 44f);
        Image img = b.GetComponent<Image>();
        img.color = new Color(0.25f, 0.18f, 0.12f, 1f);
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
        t.fontSize = 16;
        t.alignment = TextAnchor.MiddleCenter;
        t.color = Color.white;
        if (t.font == null) t.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
    }

    // ------------------------------------------------------------------
    // 行动
    // ------------------------------------------------------------------

    private void OnRest()
    {
        int dice = ExplorationTurnManager.Instance != null
            ? ExplorationTurnManager.Instance.RemainingExplorationDice()
            : 0;

        // 消耗全部探索骰（每调用一次消耗一枚，直到池空）
        if (ExplorationTurnManager.Instance != null)
        {
            while (ExplorationTurnManager.Instance.TryConsumeExplorationDice()) { }
        }

        PlayerHealth ph = Object.FindObjectOfType<PlayerHealth>();
        if (ph != null)
        {
            int before = ph.CurrentHP;
            int heal = Mathf.FloorToInt(ph.MaxHP * (0.30f + 0.05f * dice));
            ph.Heal(heal);
            Debug.Log($"[篝火] 休息：消耗 {dice} 枚探索骰，回复 {ph.CurrentHP - before} 点生命（{ph.CurrentHP}/{ph.MaxHP}）");
        }

        // 强制结束当前回合（探索剩余骰已清零 → 不会转能量）
        if (ExplorationTurnManager.Instance != null)
        {
            ExplorationTurnManager.Instance.EndExplorationTurn();
        }

        OnRested?.Invoke();                                     // ★教学钩子（教程 S23 用）
        Hide();
    }

    private void OnAdjust()
    {
        // 关闭篝火面板；玩家仍站在篝火格上 → CardPackUI 门禁为开 → 战术槽可调整
        Hide();
        if (CardPackUI.Instance != null) CardPackUI.Instance.Show();
    }
}

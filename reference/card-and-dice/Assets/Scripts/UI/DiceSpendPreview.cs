// =============================================================================
// 模块：探索骰「即将被消耗」预览 DiceSpendPreview
// 用途：鼠标在地图上悬停时，把「这一步走过去要吃掉几枚探索骰」立刻反馈到右下角
//       骰子 UI 上（被吃掉的那几枚变半透明），**不等玩家点下去**。
//
// 为什么需要它（2026-09-12 用户定稿）：
//   移动改成「点远处 → 自动扣探索骰」之后，骰子是被系统悄悄花掉的。而探索骰
//   **一骰两吃**——既是移动费，也是打牌费（CanPayCardCost：探索态每张牌扣 1 枚）。
//   不在悬停阶段就把代价摆出来，玩家会莫名其妙「骰子怎么没了 / 怎么打不出牌」。
//
// ★2026-09-12 用户二次定稿：**不要任何文字**。
//   骰面上不叠「+N」、不加角标、不浮 tooltip —— 只用「半透明」这一个视觉信号，
//   表示「这几枚马上要被系统收走」。文字说明另想办法，骰面保持干净。
//
// ★2026-09-13 用户三次定稿：**两个来源合并**（此前只有地图移动一个来源）
//   ① 地图移动悬停（HexMover）  ：预扣 N 枚 → Show(n)
//   ② 手牌悬停 / 拖到待使用状态：预扣 1 枚 → SetCardSource(this, true)
//   两者取较大值决定「前几枚变半透明」；两套来源互不干扰——
//   地图 Clear() 只清地图那一路，不会把正在拖牌的手牌提示一起清掉。
//
// 实现要点：
//   · 只改 CanvasGroup.alpha，不动 Button 的 Image/Dots 子物体 —— 影响面最小、易复原。
//   · 只作用于「激活且可交互」的骰子（与 RemainingExplorationDice 同一口径）：
//     已经被花掉/隐藏的骰子不在候选里。
//   · 幂等：同一来源重复请求不会叠加；来源清空即恢复 alpha=1。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

public static class DiceSpendPreview
{
    const string DiceAreaPath = "UICanvas/StatusBar/DiceArea";
    const string DiceButtonPrefix = "Dice6Button";

    /// <summary>被预扣的骰子的透明度。半透明 = 唯一视觉信号，不配任何文字。</summary>
    const float PreviewAlpha = 0.3f;

    /// <summary>打一张牌要花的探索骰枚数（探索态 CanPayCardCost 口径：每张牌 1 枚）。</summary>
    const int CardCost = 1;

    static GameObject _diceArea;

    /// <summary>来源①：地图移动的预扣枚数（HexMover 每帧刷新）。</summary>
    static int _mapCount;

    /// <summary>来源②：正在「悬停待使用」的卡牌（CardView 实例作 key，天然防重复/防串台）。</summary>
    static readonly HashSet<object> _cardSources = new HashSet<object>();

    static GameObject DiceArea
    {
        get
        {
            if (_diceArea == null) _diceArea = GameObject.Find(DiceAreaPath);
            return _diceArea;
        }
    }

    // ------------------------------------------------------------------
    // 来源①：地图移动
    // ------------------------------------------------------------------

    /// <summary>
    /// 把接下来会被消耗的**前 count 枚**骰子设为半透明（纯视觉提示，无文字）。
    /// count ≤ 0 等价于 <see cref="Clear"/>。
    /// </summary>
    public static void Show(int count)
    {
        _mapCount = Mathf.Max(0, count);
        Apply();
    }

    /// <summary>地图预览收起：来源①清零（**不动**卡牌来源）。</summary>
    public static void Clear()
    {
        _mapCount = 0;
        Apply();
    }

    // ------------------------------------------------------------------
    // 来源②：手牌悬停 / 拖到待使用状态（★2026-09-13 新增）
    // ------------------------------------------------------------------

    /// <summary>
    /// 某张卡牌进入 / 离开「即将打出」的观察状态（探索态打牌要花 1 枚探索骰）。
    /// 用卡牌实例作 key —— 多张卡各自进出互不影响，也不需要配对的计数。
    /// </summary>
    /// <param name="source">请求方（CardView 实例）</param>
    /// <param name="on">true = 进入（悬停 / 拖动中），false = 离开</param>
    public static void SetCardSource(object source, bool on)
    {
        if (source == null) return;

        if (on) _cardSources.Add(source);
        else _cardSources.Remove(source);

        Apply();
    }

    /// <summary>清空全部来源（场景切换 / 教学重置兜底）。</summary>
    public static void ClearAll()
    {
        _mapCount = 0;
        _cardSources.Clear();
        Apply();
    }

    // ------------------------------------------------------------------
    // 汇总 → 落色
    // ------------------------------------------------------------------

    static void Apply()
    {
        int count = _mapCount;
        if (_cardSources.Count > 0) count = Mathf.Max(count, CardCost);
        ApplyAlpha(count);
    }

    /// <summary>把「激活且可交互」的骰子按顺序标成半透明 / 恢复不透明。</summary>
    static void ApplyAlpha(int count)
    {
        GameObject area = DiceArea;
        if (area == null) return;

        int index = 0;
        foreach (Transform child in area.transform)
        {
            if (!child.name.StartsWith(DiceButtonPrefix)) continue;
            if (!child.gameObject.activeSelf) continue;

            Button btn = child.GetComponent<Button>();
            if (btn == null || !btn.interactable) continue;

            bool willSpend = count > 0 && index < count;
            SetAlpha(child.gameObject, willSpend ? PreviewAlpha : 1f);
            index++;
        }
    }

    static void SetAlpha(GameObject go, float alpha)
    {
        CanvasGroup cg = go.GetComponent<CanvasGroup>();
        if (cg == null)
        {
            // 只在真的要改透明度时才挂组件，避免给每颗骰子平白加一个组件
            if (alpha >= 1f) return;
            cg = go.AddComponent<CanvasGroup>();
        }
        cg.alpha = alpha;
        // 半透明时依然可点（玩家仍可主动点骰子换行动点，这是既有能力，不因为预览而失效）
        cg.blocksRaycasts = true;
        cg.interactable = true;
    }
}

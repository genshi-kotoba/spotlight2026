// =============================================================================
// 模块：HandUIController —— 探索鉴定辅助模式集成（D19 v2.5 配套）
// 职责：
//   1. EnterCheckAssistMode / ExitCheckAssistMode：进入/退出鉴定辅助视觉（伸牌/缩牌）
//   2. SetCheckAssistSuitFilter：悬停/锁定属性变化 → 只伸对应花色手牌
//   3. DetachCardViewForCheckAssist：被弃的卡从手牌UI摘除（收拢）
//   4. AttachCardViewBackFromCheckAssist：取消弃的卡回手牌UI（展开）
//   5. 打牌流拦截：ExecutePlay 前若弹窗打开 → 改飞 DISCARD 面板（而非战斗打牌）
//   6. TryRouteCheckAssistClick：鉴定模式点击手牌 → 直接飞入 DISCARD 面板
//
// ★2026-08-26 用户口述效果（v2.6）：
//   - 匹配卡从手牌堆"伸出"：类似悬停但【不立正、不放大】——保持原有弧度
//     （rotation 不变）、x 不变，只沿 y 向上抬 AssistLiftY
//   - 不匹配卡向下缩 AssistShrinkY + 半透明
//   - 多解法事件打开时全部对应花色伸出；悬停选项后只伸该花色
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using DG.Tweening;

public partial class HandUIController
{
    // ===== 鉴定辅助模式运行时 =====
    private bool _checkAssistMode = false;

    /// <summary>★v2.11：鉴定辅助模式是否激活（CardView 悬停/拖动入口的交互判定用）</summary>
    public bool CheckAssistModeActive => _checkAssistMode;

    /// <summary>当前弹起的手牌花色集合（空集合 = 全部缩下）★v2.8 花色集合制</summary>
    private HashSet<SuitOption> _popupSuits = new HashSet<SuitOption>();

    // 防重复应用：记录上次已应用的集合（悬停进出频繁触发，集合没变就不重刷）
    private HashSet<SuitOption> _appliedPopupSuits = null;

    // ===== 伸出/缩下动画参数（用户 2026-08-26 定稿，同日反馈调整） =====
    private const float AssistLiftY     = 22f;   // 匹配卡向上伸出量（保持弧度不立正不放大）
    private const float AssistShrinkY   = 18f;   // 不匹配卡向下缩量
    private const float AssistTweenDur  = 0.18f;

    // ====================================================================
    // 1. 进入 / 退出 鉴定辅助模式（EventPopupUI.SendMessage 调用）
    // ====================================================================

    /// <summary>
    /// 进入鉴定辅助模式（弹窗打开时调用）。
    /// ★v2.8 参数改为花色集合：传入本事件所有鉴定选项对应的花色
    /// （如事件有力量+敏捷两种解法 → 红色+绿色手牌全部伸出，其余缩下）。
    /// </summary>
    public void EnterCheckAssistMode(List<SuitOption> suits)
    {
        _checkAssistMode = true;
        _popupSuits = suits != null ? new HashSet<SuitOption>(suits) : new HashSet<SuitOption>();
        Debug.Log("[HandUI] 进入鉴定辅助模式：弹出花色=[" + string.Join(",", _popupSuits) + "]");

        // 探索模式 CanvasGroup 可能关着射线——鉴定模式要能点/拖卡牌
        foreach (var cv in _cardViewInstances)
        {
            if (cv == null) continue;
            CanvasGroup cg = cv.GetComponent<CanvasGroup>();
            if (cg != null) cg.blocksRaycasts = true;
        }

        ApplyCheckAssistVisuals();
    }

    /// <summary>
    /// 更新弹出花色集合（悬停/锁定变化时调用）。
    /// 传入集合 = 只有这些花色的手牌伸出；空集合 = 全部缩下
    /// （悬停"绕道离开"等非鉴定选项时传空）。
    /// </summary>
    public void SetCheckAssistSuits(List<SuitOption> suits)
    {
        if (!_checkAssistMode) _checkAssistMode = true; // 兜底：弹窗开着就算进模式
        _popupSuits = suits != null ? new HashSet<SuitOption>(suits) : new HashSet<SuitOption>();
        ApplyCheckAssistVisuals();
    }

    public void ExitCheckAssistMode()
    {
        _checkAssistMode = false;
        _popupSuits = new HashSet<SuitOption>();
        _appliedPopupSuits = null;
        Debug.Log("[HandUI] 退出鉴定辅助模式");

        // 所有手牌动画回基准位 + 恢复探索默认视觉
        for (int i = 0; i < _cardViewInstances.Count; i++)
        {
            CardView cv = _cardViewInstances[i];
            if (cv == null || cv.IsFlyingOut) continue;

            // 回基准位（伸出/缩下的位置动画收尾）
            if (i < _baseAnchoredPositions.Count)
            {
                var rt = cv.Rect;
                if (rt != null)
                {
                    DOTween.Kill(rt);
                    rt.DOAnchorPos3D(_baseAnchoredPositions[i], AssistTweenDur)
                        .SetEase(Ease.OutCubic).SetTarget(rt);
                }
            }

            cv.SetCheckAssistSelected(false);
            if (cv.InteractionLocked == false)
                cv.ForceEndHover();
        }

        // 恢复探索/战斗各自的默认 alpha 与射线开关
        ApplyModeVisuals();
    }

    /// <summary>
    /// 应用鉴定辅助视觉（v2.8 花色集合制）：
    ///   卡的花色 ∈ _popupSuits = 沿 y 向上伸出（保持弧度 rotation、不放大、alpha 不动）
    ///   否则 = 向下缩 AssistShrinkY
    /// ★与悬停的区别：悬停会立正+放大+抬到统一高度；这里只平移 y，姿态全保留。
    /// </summary>
    private void ApplyCheckAssistVisuals()
    {
        // 集合没变化就不重刷（悬停进出频繁触发）
        if (_appliedPopupSuits != null && _appliedPopupSuits.SetEquals(_popupSuits)) return;
        _appliedPopupSuits = new HashSet<SuitOption>(_popupSuits);

        for (int i = 0; i < _cardViewInstances.Count; i++)
        {
            CardView cv = _cardViewInstances[i];
            if (cv == null || cv.IsFlyingOut || cv.InteractionLocked) continue;
            if (i >= _baseAnchoredPositions.Count) continue;

            // 匹配判定：卡的任一花色槽位命中弹出集合
            CardData data = cv.CardData;
            bool match = false;
            if (data != null)
            {
                foreach (SuitOption s in _popupSuits)
                {
                    if (data.GetSuitCount(s) > 0) { match = true; break; }
                }
            }

            Vector3 basePos = _baseAnchoredPositions[i];
            var rt = cv.Rect;
            if (rt == null) continue;

            // 位置动画：伸出 / 缩下（rotation、scale、alpha 一律不动 = 保持弧度不放大不透明）
            DOTween.Kill(rt);
            Vector3 target = match
                ? basePos + Vector3.up * AssistLiftY
                : basePos + Vector3.down * AssistShrinkY;
            rt.DOAnchorPos3D(target, AssistTweenDur).SetEase(Ease.OutCubic).SetTarget(rt);
        }
    }

    /// <summary>
    /// ★D19 v2.11：这张手牌当前是否处于"弹出"（伸出）状态。
    /// 鉴定模式下只有弹出的卡（花色命中 _popupSuits）响应鼠标——
    /// 悬停高亮边框 / 点击 / 拖动；缩下的卡完全无视鼠标（用户定稿）。
    /// </summary>
    public bool IsCheckAssistPopped(CardView cv)
    {
        if (!_checkAssistMode || cv == null || cv.CardData == null) return false;
        if (_popupSuits == null || _popupSuits.Count == 0) return false;
        foreach (SuitOption s in _popupSuits)
        {
            if (cv.CardData.GetSuitCount(s) > 0) return true;
        }
        return false;
    }

    // ====================================================================
    // 6. 点击路由：鉴定模式点击手牌 → 直接飞入 DISCARD 面板（不走点击跟随流）
    //    用户 2026-08-26："选择想要加入鉴定的卡牌是点击对应卡牌，或者是打出对应卡牌"
    // ====================================================================
    /// <summary>
    /// 尝试把"点击手牌"路由到「鉴定弃牌飞入面板」。
    /// 返回 true = 已路由（OnCardViewClicked 必须 return，不进点击跟随流）；
    /// 返回 false = 正常点击流程。
    /// </summary>
    private bool TryRouteCheckAssistClick(CardView cv)
    {
        if (cv == null || cv.Card == null) return false;
        if (!_checkAssistMode) return false;

        EventPopupUI popup = FindObjectOfType<EventPopupUI>();
        if (popup == null || !popup.gameObject.activeSelf) return false;
        if (!popup.IsCheckPanelOpen) return false;

        // 面板里已有的卡不可重复点（飞回由面板内点击处理）
        if (popup.IsPanelCard(cv)) return false;

        // ★v2.11：缩下的卡（花色不匹配当前弹出集合）完全不可交互——不响应点击
        if (!IsCheckAssistPopped(cv)) return false;

        Debug.Log($"[HandUI] 点击路由到鉴定弃牌：{cv.CardData.cardName}");
        popup.FlyCardToDiscardPanel(cv);
        return true;
    }

    // ====================================================================
    // 2. 从手牌摘除 / 回收 CardView（EventPopupUI.FlyCardTo/Back 调用）
    // ====================================================================
    /// <summary>
    /// 被鉴定弃牌飞出去前：从 _cardViewInstances 摘除、收拢手牌、取消悬停/扇开状态、
    /// Kill 掉 cv 上所有 Tween（防飞行中被布局改位置）。
    /// ★v2.9 核心 bug 修复：同时把 Card 从 CardPileManager.Hand（数据层）移除——
    ///   旧版只摘视图不删数据，RefreshHandLayout 从 Hand 重建时又把这张卡
    ///   原样建回手牌（用户报"打出后卡还在手牌里"）。数据层移除后重建 = n-1 张，正确。
    /// </summary>
    public void DetachCardViewForCheckAssist(CardView cv)
    {
        if (cv == null) return;
        Debug.Log($"[HandUI] 摘除手牌用于鉴定弃牌：{cv.CardData?.cardName}");

        // 如果卡在交互流中 → 先清流（不弹回，直接摘）
        if (_activeCard == cv)
        {
            ClearFlowVisuals();
            _activeCard = null;
            cv.InteractionLocked = false;
            cv.SetPlayPreview(false);
        }
        if (_fannedHoverCard == cv) _fannedHoverCard = null;
        if (_hoveredCard == cv) _hoveredCard = null;
        if (_selectedCard == cv) _selectedCard = null;

        // 清理该卡上的 Tween（位置/旋转/缩放——避免布局动画中把它拉回去）
        cv.transform.DOKill();
        var rt = cv.transform as RectTransform;
        if (rt != null) DOTween.Kill(rt);

        // ★v2.9：数据层同步——从手牌数据移除（视图由 FlyCardToDiscardPanel 接管，
        // 飞入面板即"承诺弃牌"状态；取回时 AttachCardViewBackFromCheckAssist 加回）
        if (cv.Card != null && CardPileManager.Instance != null
            && CardPileManager.Instance.Hand.Contains(cv.Card))
        {
            CardPileManager.Instance.Hand.Remove(cv.Card);
        }

        // 从手牌实例列表摘除
        if (_cardViewInstances.Contains(cv))
            _cardViewInstances.Remove(cv);

        // 收拢手牌（从 Hand 数据重建 n-1 张，数据层已删故不会把飞走的卡建回来）
        RefreshHandLayout();

        // ★v2.9：重建产生全新 CardView 实例 → 强制重刷伸出/缩下视觉
        _appliedPopupSuits = null;
        ApplyCheckAssistVisuals();
    }

    /// <summary>
    /// 取消弃牌飞回时：把 Card 加回数据层手牌 + CardView 归位重排。
    /// ★v2.9：数据层同步（Hand.Add）——配合 Detach 的 Hand.Remove 成对；
    ///   布局用 LayoutCardsInArc 直接重排（不销毁重建，避免把飞回的卡 Destroy）。
    /// immediate=true 时不播动画直接就位，false 时播动画。
    /// ★签名必须是 (CardView, bool) 两参数：EventPopupUI.SendMessage 传 object[]{cv,immediate}
    ///   会被 Unity 解包成多参数调用，单 object[] 参数的签名匹配不上（静默失败）。
    /// </summary>
    public void AttachCardViewBackFromCheckAssist(CardView cv, bool immediate)
    {
        if (cv == null) return;

        Debug.Log($"[HandUI] 回收取消弃牌的卡：{cv.CardData?.cardName}，immediate={immediate}");

        // 如果 cv 被 Destroy 了就跳过（ReturnAllPanelCardsImmediate 里被兜底 Destroy 的情况）
        if (cv.gameObject == null) return;

        // ★v2.9：数据层加回手牌（与 Detach 的 Remove 成对）
        if (cv.Card != null && CardPileManager.Instance != null
            && !CardPileManager.Instance.Hand.Contains(cv.Card))
        {
            CardPileManager.Instance.Hand.Add(cv.Card);
        }

        // 挂回 HandAreaRoot + 加回实例列表
        if (cv.transform.parent != HandAreaRoot)
        {
            cv.transform.SetParent(HandAreaRoot, false);
        }
        if (!_cardViewInstances.Contains(cv))
            _cardViewInstances.Add(cv);

        cv.SetCheckAssistSelected(false);
        cv.transform.DOKill();

        // 记录飞回落点（用于动画起点）
        Vector3 fromPos = cv.Rect != null ? cv.Rect.anchoredPosition3D : Vector3.zero;

        // 直接重排全部手牌到 n 张弧线布局（snap 到位并记录基准位）
        LayoutCardsInArc();

        if (!immediate)
        {
            // 从落点动画滑到基准位（LayoutCardsInArc 已 snap，先放回起点再 tween）
            int idx = _cardViewInstances.IndexOf(cv);
            if (idx >= 0 && idx < _baseAnchoredPositions.Count)
            {
                Vector3 target = _baseAnchoredPositions[idx];
                Quaternion rot = idx < _baseRotations.Count ? _baseRotations[idx] : Quaternion.identity;
                var rt = cv.Rect;
                rt.anchoredPosition3D = fromPos;
                rt.DOAnchorPos3D(target, 0.18f).SetEase(Ease.OutQuad);
                cv.transform.DORotateQuaternion(rot, 0.18f).SetEase(Ease.OutQuad);
                float prefabScale = CardViewPrefab != null ? CardViewPrefab.transform.localScale.x : 1.4f;
                cv.transform.DOScale(prefabScale, 0.18f).SetEase(Ease.OutQuad);
            }
        }
        else
        {
            float prefabScale = CardViewPrefab != null ? CardViewPrefab.transform.localScale.x : 1.4f;
            cv.transform.localScale = Vector3.one * prefabScale;
        }

        // 重刷伸出/缩下视觉（新布局的基准位变了）
        _appliedPopupSuits = null;
        ApplyCheckAssistVisuals();
    }

    // ====================================================================
    // 3. 打牌流拦截：ExecutePlay 前先判断——
    //    如果 EventPopup 打开 → 不走战斗打牌，走 FlyCardToDiscardPanel。
    // ====================================================================
    //
    // 拦截入口：在 Interaction.cs ExecutePlay 开头插一个路由调用，
    // 这样不管是"点击过线"还是"拖动过阈值"最终都会进同一个路由判断。
    //
    // 用法：在 ExecutePlay 开头第一行写：
    //   if (TryRouteCheckAssistPlay(cv)) return;
    //
    // 我们这里提供方法，然后通过 Edit 工具改 Interaction.cs。

    /// <summary>
    /// 尝试把"打出"路由到「鉴定弃牌飞入面板」。
    /// 返回 true = 已路由（ExecutePlay 必须 return，不走战斗）；
    /// 返回 false = 正常战斗打牌流程。
    /// </summary>
    private bool TryRouteCheckAssistPlay(CardView cv)
    {
        if (cv == null || cv.Card == null) return false;

        // ★v2.12：已在飞往弃牌槽（同帧点击+拖拽结束双触发防御）——直接视为已路由
        if (cv.IsFlyingOut) return true;

        // ★v2.9：弹窗打开期间一律禁止真正的"打出"（含纯叙事事件——无鉴定板时
        // 拖过线不能走战斗打牌流，直接收回）
        EventPopupUI popup = FindObjectOfType<EventPopupUI>();
        if (popup == null || !popup.gameObject.activeSelf) return false;
        if (!popup.IsCheckPanelOpen)
        {
            Debug.Log("[HandUI] 事件弹窗打开但无鉴定板 → 禁止打牌，收回");
            ReturnActiveCard();
            return true;
        }

        // ★v2.11：能量预检（动态费用 CurrentCost，与拖动入口检查一致）——
        // 不足则正常收回。旧版在 FlyCardToDiscardPanel 内用 Data.energyCost
        // 静态费用检查失败后直接 return，此时交互流已被清空、无收回逻辑，
        // 卡牌滞留在松手处（用户报"拖出来后静止不动在原地"）。
        EnergyPointDisplay epd = FindObjectOfType<EnergyPointDisplay>();
        if (epd != null && cv.Card != null && !epd.CanAfford(cv.Card.CurrentCost))
        {
            Debug.Log($"[HandUI] 能量不足，鉴定弃牌收回：{cv.CardData?.cardName}");
            ReturnActiveCard();
            return true;
        }

        // 不做花色过滤——用户如果愿意把一张力量牌扔进智力鉴定，那就是"浪费"，
        // 只要他想扔就允许扔（最终弃牌加成为 0，公式里不显示，但能量照扣）。
        // 更友好的做法是加个提示，但用户没要求，我们简单化。

        Debug.Log($"[HandUI] 路由到鉴定弃牌飞入面板：{cv.CardData.cardName}");
        ClearFlowVisuals();
        _activeCard = null;
        cv.InteractionLocked = false;
        cv.SetPlayPreview(false);

        // 调 EventPopupUI.FlyCardToDiscardPanel(cv)
        // EventPopupUI 内部会 DetachFromHand → 飞行 → 注册面板卡
        // ★v2.10：SendMessage → 直接强类型调用（public 方法）
        popup.FlyCardToDiscardPanel(cv);
        return true;
    }
}

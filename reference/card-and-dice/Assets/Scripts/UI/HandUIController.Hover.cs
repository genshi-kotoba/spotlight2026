// =============================================================================
// 模块：HandUIController 悬停扇开（partial 拆分 2026-08-18，纯机械搬运逻辑零修改）
// 原文件：HandUIController.cs（拆分后本文件只管"鼠标悬停手牌时的扇开与恢复"）
// 参考：NSWells《杀戮尖塔》P4 Hover System
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using DG.Tweening;

public partial class HandUIController
{
    [Header("悬停扇开（杀戮尖塔式：选中卡两侧卡牌向左右让开）")]
    [Tooltip("选中卡旁第 1 张（紧挨着）的外移基准距离 = 大距离。\n" +
             "距离规则：1=大(Long), 2=中(Medium), 3=小(Short)，4及以外不动。\n" +
             "手牌越多缩放越小：10张→10%，5张→60%。")]
    public float FanOffsetLong = 50f;
    [Tooltip("选中卡旁第 3 张的外移基准距离 = 小距离")]
    public float FanOffsetShort = 15f;
    [Tooltip("选中卡旁第 2 张的外移基准距离 = 中距离")]
    public float FanOffsetMedium = 35f;
    [Tooltip("扇开进入动画时长（秒）——其他卡牌扇开让位的过渡（比 hovered 卡上移慢，优雅展开）")]
    public float HoverFanDuration = 0.15f;
    [Tooltip("扇开恢复动画时长（秒）——鼠标离开时卡牌收拢/下移的慢速过渡")]
    public float ReturnFanDuration = 0.18f;

    [Tooltip("按手牌数量配置的扇开缩放系数（0~1）。\n" +
             "数组索引 = 手牌数量（1~10），索引 0 弃用。\n" +
             "值越大 = 扇开幅度越大；值越小 = 越紧凑。\n" +
             "示例：0.55 = 基准偏移量（FanOffsetLong/Medium/Short）的 55%")]
    public float[] CountFactorByCount = new float[11]
    {
        0f,     // [0] 弃用
        0.6f,   // [1] 1张（无扇开意义）
        0.6f,   // [2]
        0.6f,   // [3]
        0.6f,   // [4]
        0.6f,   // [5]
        0.6f,   // [6]
        0.6f,   // [7]
        0.6f,   // [8]
        0.6f,   // [9]
        0.6f,   // [10]
    };

    // 悬停扇开运行时数据
    private CardView _fannedHoverCard = null;      // 当前触发扇开的悬停卡牌

    // ------------------------------------------------------------------
    // 悬停扇开（杀戮尖塔式：两侧卡牌向左右让开，突出选中卡）
    //
    // 距离规则（以选中卡为中心，左右对称）：
    //   distance 1（紧挨着选中卡） → 大距离 向外
    //   distance 2                   → 中距离 向外
    //   distance 3                   → 小距离 向外
    //   distance >= 4                → 不动
    //   示例（7 张牌，第 5 张选中）：1不动 2左小 3左中 4左大 5选中 6右大 7右中
    //
    // 缩放规则（2~5 张固定，6~10 张线性递减）：
    //   2~5 张 → countFactor=0.6（固定，避免 2-4 张扇得太大）
    //   6 张 → 0.5，7 张 → 0.4，8 张 → 0.3，9 张 → 0.2，10 张 → 0.1
    //
    // 位置基准：扇开/恢复目标都基于 _baseAnchoredPositions（排布时记录），
    //           不依赖当前动画状态，避免动画中途切换导致累积错误。
    // ------------------------------------------------------------------

    /// <summary>
    /// CardView 悬停进入时调用。
    /// 管理所有卡牌的位置：
    ///   - hovered 卡：上移到 HoverLift + SetAsLastSibling
    ///   - 距离 1/2/3 的卡：扇开（基准位置 + 偏移）
    ///   - 其他卡：回基准位置
    ///
    /// 平滑切换：A→B 不做硬复位，直接从当前位置 Tween 到新目标。
    /// 职责：HandUIController 管所有位置和 Sibling，CardView 只管旋转和缩放。
    /// </summary>
    public void NotifyCardHovered(CardView hoveredCV)
    {
        if (hoveredCV == null) return;

        // P7 Interactions：拖动中禁止新的悬停扇开（防御性，CardView 已先检查）
        if (!Interactions.PlayerCanHover()) return;

        // ★2026-08-17 修"高亮重合处不显示"bug：
        // 同帧内 UI OnPointerEnter（画射程高亮）与 HexMover.Update（清移动路径高亮）
        // 的执行顺序不确定——若 HexMover 后执行，它的 ClearPathDisplay 会把
        // 刚染的射程黄当"旧路径格"恢复黑色，重合的格子高亮被吃掉。
        // 先主动清掉移动高亮（同 BeginFlow 的做法），HexMover 随后的清理即为空操作。
        GetPlayerMover()?.ClearAllMoveHighlights();

        // M5b-2：有射程的卡悬停时高亮射程格子（无射程卡清掉旧高亮=悬停切换刷新）
        ShowRangeHighlightForCard(hoveredCV);

        int count = _cardViewInstances.Count;
        int hoveredIdx = _cardViewInstances.IndexOf(hoveredCV);
        if (hoveredIdx < 0) return;

        if (count <= 1)
        {
            // 单张牌：只上移 + SetAsLastSibling
            // ★ 必须设置 _fannedHoverCard，否则 NotifyCardUnhovered 会 early return，
            //   导致单张牌悬停后移开鼠标不归位
            if (_fannedHoverCard != null && _fannedHoverCard != hoveredCV)
            {
                UnfanAllForDestroy();
            }
            _fannedHoverCard = hoveredCV;

            if (hoveredIdx < _baseAnchoredPositions.Count)
            {
                hoveredCV.transform.SetAsLastSibling();
                var rt = hoveredCV.transform as RectTransform;
                if (rt != null)
                {
                    Vector3 basePos = _baseAnchoredPositions[hoveredIdx];
                    Vector3 target = new Vector3(basePos.x, hoveredCV.HoverLift, basePos.z);
                    hoveredCV.CancelReturn();
                    hoveredCV.transform.DOKill();
                    DOTween.To(() => rt.anchoredPosition3D, x => rt.anchoredPosition3D = x, target, hoveredCV.HoverDuration)
                        .SetEase(Ease.OutCubic).SetTarget(rt);
                }
            }
            return;
        }

        // 如果已经是这张卡在扇开状态，不重复处理
        if (_fannedHoverCard == hoveredCV) return;
        // 到这里说明是新的悬停卡（或第一次悬停），打印诊断日志
        bool debugLog = true;
        _fannedHoverCard = hoveredCV;

        // 从数组按手牌数量读取 countFactor（可在 Inspector 直接调）
        // 数组越界保护：count 超过数组长度时用最后一个值
        float countFactor;
        if (CountFactorByCount != null && count < CountFactorByCount.Length)
        {
            countFactor = CountFactorByCount[count];
        }
        else
        {
            countFactor = 0.1f; // 兜底
        }

        // hovered 卡 SetAsLastSibling（提到最上层）
        hoveredCV.transform.SetAsLastSibling();

        // 非 hovered 卡立即恢复 Sibling Index（每张卡独立，不等所有悬停结束）
        // 这样鼠标在卡之间快速切换时，刚离开的卡能立即恢复到正确层级
        for (int i = 0; i < count; i++)
        {
            if (i == hoveredIdx) continue;
            var cv = _cardViewInstances[i];
            if (cv == null) continue;
            var t = cv.transform;
            if (t.parent != null && i < t.parent.childCount)
            {
                t.SetSiblingIndex(i);
            }
        }

        // 遍历所有卡，计算目标位置并 Tween
        // ★ 诊断日志：每次切换悬停卡时打印关键参数（帮助排查"调整无效"问题）
        if (debugLog)
        {
            Debug.Log($"[HandUIController] 扇开诊断: count={count}, hoveredIdx={hoveredIdx}, " +
                      $"countFactor={countFactor}, " +
                      $"FanOffset: L={FanOffsetLong}, M={FanOffsetMedium}, S={FanOffsetShort}, " +
                      $"basePosCount={_baseAnchoredPositions.Count}");
        }

        for (int i = 0; i < count; i++)
        {
            if (i >= _baseAnchoredPositions.Count) continue;

            var cv = _cardViewInstances[i];
            if (cv == null) continue;
            var rt = cv.transform as RectTransform;
            if (rt == null) continue;

            Vector3 basePos = _baseAnchoredPositions[i];
            Vector3 target;

            if (i == hoveredIdx)
            {
                // hovered 卡：上移到 HoverLift（X/Z 保持基准）
                target = new Vector3(basePos.x, cv.HoverLift, basePos.z);
            }
            else
            {
                int distance = Mathf.Abs(i - hoveredIdx);
                if (distance >= 4)
                {
                    target = basePos;
                }
                else
                {
                    float baseOffset = 0f;
                    if (distance == 1) baseOffset = FanOffsetLong;
                    else if (distance == 2) baseOffset = FanOffsetMedium;
                    else if (distance == 3) baseOffset = FanOffsetShort;
                    float offset = baseOffset * countFactor;
                    float sign = i < hoveredIdx ? -1f : 1f;
                    target = basePos + new Vector3(sign * offset, 0, 0);

                    if (debugLog)
                    {
                        Debug.Log($"[HandUIController]   卡[{i}] dist={distance}, " +
                                  $"baseOffset={baseOffset}, offset={offset}, sign={sign}, " +
                                  $"basePos={basePos}, target={target}");
                    }
                }
            }

            cv.CancelReturn();
            cv.transform.DOKill();

            // 时长选择：
            //   - hovered 卡上移用 cv.HoverDuration（快，与立正+放大同步完成，反应灵敏）
            //   - 其他卡扇开用 HoverFanDuration（慢一点，优雅展开）
            float duration = (i == hoveredIdx) ? cv.HoverDuration : HoverFanDuration;

            Vector3 targetLocal = target;
            RectTransform rtLocal = rt;
            CardView expectedCard = hoveredCV;
            DOTween.To(() => rtLocal.anchoredPosition3D, x => rtLocal.anchoredPosition3D = x, targetLocal, duration)
                .SetEase(Ease.OutCubic)
                .SetTarget(rtLocal)
                .OnComplete(() =>
                {
                    if (_fannedHoverCard == expectedCard && rtLocal != null)
                        rtLocal.anchoredPosition3D = targetLocal;
                });
        }
    }

    /// <summary>
    /// CardView 悬停离开时调用。
    /// 平滑动画恢复所有卡牌（包括 hovered 卡）到基准位置 + 恢复 Sibling Index。
    ///
    /// 职责：HandUIController 管所有位置和 Sibling 恢复，CardView 只管旋转和缩放恢复。
    /// 不再跳过 hovered 卡——hovered 卡的位置也由这里恢复。
    ///
    /// 恢复策略（全程动画，无硬跳）：
    ///   - 对所有卡启动 ReturnFanDuration 恢复动画（从当前位置→基准位置）
    ///   - OnComplete 恢复 Sibling Index
    ///   - DelayedCall 兜底用极短 Tween(0.03s) 对齐 + 恢复 Sibling
    /// </summary>
    public void NotifyCardUnhovered(CardView hoveredCV)
    {
        if (_fannedHoverCard == null || _fannedHoverCard != hoveredCV) return;
        _fannedHoverCard = null;

        // M5b-2：清除射程高亮（交互流进行中除外——流结束时自己清理）
        if (_activeCard == null)
        {
            CardRangeHighlight.Clear();
        }

        int count = Mathf.Min(_cardViewInstances.Count, _baseAnchoredPositions.Count);

        // 立即恢复所有卡的 Sibling Index（不等动画完成，每张卡独立）
        // 这样鼠标从 A 移开后，A 立即从最上层回到原层级，不会等其他卡
        for (int i = 0; i < count; i++)
        {
            var cv = _cardViewInstances[i];
            if (cv == null) continue;
            var t = cv.transform;
            if (t.parent != null && i < t.parent.childCount)
            {
                t.SetSiblingIndex(i);
            }
        }

        // 记录所有被恢复的 RT，用 DelayedCall 兜底
        List<RectTransform> pendingRTs = new List<RectTransform>();
        List<Vector3> pendingTargets = new List<Vector3>();

        for (int i = 0; i < count; i++)
        {
            var cv = _cardViewInstances[i];
            if (cv == null) continue;
            var rt = cv.transform as RectTransform;
            if (rt == null) continue;

            Vector3 orig = _baseAnchoredPositions[i];
            pendingRTs.Add(rt);
            pendingTargets.Add(orig);

            cv.CancelReturn();
            cv.transform.DOKill();

            Vector3 origLocal = orig;
            RectTransform rtLocal = rt;
            DOTween.To(() => rtLocal.anchoredPosition3D, x => rtLocal.anchoredPosition3D = x, origLocal, ReturnFanDuration)
                .SetEase(Ease.OutCubic)
                .SetTarget(rtLocal)
                .OnComplete(() =>
                {
                    if (_fannedHoverCard == null && rtLocal != null)
                        rtLocal.anchoredPosition3D = origLocal;
                });
        }

        // 兜底：ReturnFanDuration+20ms 后，对还没完全对齐的卡用 0.03s 极短 Tween 平滑补齐
        DOVirtual.DelayedCall(ReturnFanDuration + 0.02f, () =>
        {
            if (_fannedHoverCard != null) return;

            for (int k = 0; k < pendingRTs.Count; k++)
            {
                var rt = pendingRTs[k];
                if (rt == null) continue;
                Vector3 target = pendingTargets[k];
                DOTween.To(() => rt.anchoredPosition3D, x => rt.anchoredPosition3D = x, target, 0.03f)
                    .SetEase(Ease.OutCubic)
                    .SetTarget(rt);
            }
        }).SetTarget(this.gameObject);
    }
}

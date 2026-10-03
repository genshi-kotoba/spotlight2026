// =============================================================================
// 模块：HandUIController 手牌布局（partial 拆分 2026-08-18，纯机械搬运逻辑零修改）
// 原文件：HandUIController.cs（拆分后本文件只管"手牌怎么摆"——弧线排布、
//         收拢/展开、弃牌延迟重排、卡牌弹回基准位）
// 参考：NSWells《杀戮尖塔》P2 Curved Hand
// =============================================================================
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Splines;
using DG.Tweening;

public partial class HandUIController
{
    // ------------------------------------------------------------------
    // 公开 API（布局）
    // ------------------------------------------------------------------

    /// <summary>
    /// 刷新手牌布局：销毁旧 CardView → 遍历 Hand 重新实例化 → 按弧线排布。
    /// 调用方：TurnManager.StartNewTurn() 抽牌后、EndPlayerTurn() 弃牌后。
    /// </summary>
    public void RefreshHandLayout()
    {
        // ★2026-09-16 性能二批：手牌重排分段计时（回合开始重建 / 回合结束后 0.25s 延迟重建都走这里，
        //   后者正是「敌人阶段窗口内那条 47–81ms 卡帧」的头号嫌疑）
        System.Diagnostics.Stopwatch perfWatch = ExplorationPerf.StartBoundaryTimer();
        int oldViews = _cardViewInstances.Count;

        if (CardPileManager.Instance == null)
        {
            ExplorationPerf.EndBoundaryScope(perfWatch, "手牌重排", "无牌堆管理器");
            return;
        }

        // 销毁前先立即恢复扇开状态（否则选中卡的扇开 Tween 会操作被销毁的对象）
        if (_fannedHoverCard != null)
        {
            UnfanAllForDestroy();
        }

        // ★防残留 2026-08-18：本方法销毁全部 CardView——悬停中的卡被销毁时
        // OnPointerExit 不会触发，射程高亮会永久残留。无交互流时防御性清除
        // （交互流进行中不在此清，流结束 ClearFlowVisuals 自己收尾）。
        if (_activeCard == null)
        {
            CardRangeHighlight.Clear();
        }

        // 销毁旧的 CardView 实例
        ClearAllCardViews();

        List<Card> hand = CardPileManager.Instance.Hand;
        if (hand.Count == 0 || CardViewPrefab == null || HandAreaRoot == null)
        {
            ExplorationPerf.EndBoundaryScope(perfWatch, "手牌重排", $"销毁 {oldViews}／新建 0（空手牌或缺引用）");
            return;
        }

        // 实例化新的 CardView
        for (int i = 0; i < hand.Count; i++)
        {
            CardView cardView = Instantiate(CardViewPrefab, HandAreaRoot);
            cardView.SetCard(hand[i]);
            _cardViewInstances.Add(cardView);
        }

        // 按弧线排布
        LayoutCardsInArc();

        // 应用当前模式（灰显/正常）
        ApplyModeVisuals();

        // P8：刷新能量标识（新牌进场/手牌变化后重算红白）
        RefreshCardAffordability();

        ExplorationPerf.EndBoundaryScope(perfWatch, "手牌重排", $"销毁 {oldViews}／新建 {_cardViewInstances.Count}");
    }

    /// <summary>
    /// P8：单卡弃牌回调（打出/效果弃牌）——延迟一拍重排手牌。
    /// 弃牌触发 OnCardDiscarded → 延迟后刷新布局，手牌自动变成"少一张"的满员排布
    /// （与拖动打出前的收拢预览一致，视觉衔接自然）。
    /// ★2026-08-17 性能修复（用户反馈"松手卡一下才飞牌"）：
    /// 原来弃牌当帧同步 RefreshHandLayout——销毁+重建全部手牌卡（Instantiate 开销大），
    /// 与飞向弃牌堆动画挤在同一帧，动画第一帧被吞。现在等飞牌动画起飞后
    /// 延迟 _discardReLayoutDelay 秒再重排（飞行途中），松手帧不再卡顿。
    /// 同帧多张弃牌（回合结束弃整手）合并为一次重排（原来每张全量重建 N 次）。
    /// </summary>
    [Tooltip("打出弃牌后延迟多少秒重排手牌（等飞牌动画起飞，避免松手当帧卡顿）")]
    [SerializeField] private float _discardReLayoutDelay = 0.25f;

    /// <summary>延迟重排是否已在等待中（同帧/等待期内的后续弃牌合并，只重排一次）</summary>
    private bool _layoutRefreshPending = false;

    private void HandleCardDiscarded(Card card)
    {
        if (_layoutRefreshPending) return;
        _layoutRefreshPending = true;
        StartCoroutine(DelayedRefreshHandLayout());
    }

    /// <summary>
    /// 延迟重排协程：等 1 帧让打出帧的结算先跑完 → 延迟期让飞牌动画起飞 →
    /// 若玩家恰好开始了新的交互流（拖拽/点击跟随），等流结束再重排
    /// （避免销毁正在交互中的卡牌导致状态错乱）。
    /// </summary>
    private IEnumerator DelayedRefreshHandLayout()
    {
        yield return null; // 等 1 帧：飞牌动画已启动、动作链结算推进

        float waited = 0f;
        while (waited < _discardReLayoutDelay)
        {
            waited += Time.deltaTime;
            yield return null;
        }

        // 等待期有新交互流 → 等它结束（流中的卡不销毁）
        while (_activeCard != null) yield return null;

        _layoutRefreshPending = false;
        RefreshHandLayout();
    }

    // ------------------------------------------------------------------
    // 弧线排布算法（AnimationCurve 采样）
    // ------------------------------------------------------------------

    /// <summary>
    /// 将 _cardViewInstances 中的卡牌沿弧线排布。
    /// 优先使用 CardSpline（SplineContainer 贝塞尔样条）驱动，让卡牌精确贴合样条；
    /// 若未指定 CardSpline，则回退用 ArcHeightCurve 曲线。
    /// CardSpline 排布算法：
    ///   N 张卡，i = 0..N-1
    ///   t = i / (N-1)                    // 0~1 归一化
    ///   pos = CardSpline.EvaluatePosition(t)      // 采样样条上的世界坐标
    ///   rot = -90° - 切线俯仰角          // 让卡牌顶边垂直于样条切线，贴合弧面
    /// </summary>
    private void LayoutCardsInArc()
    {
        int count = _cardViewInstances.Count;
        if (count == 0) return;

        // 优先：用 SplineContainer 驱动（精确贴合样条）
        // 参考：NSWells P2 HandView.UpdateCardPositions + 杀戮尖塔/黑夜轮回实际表现
        //
        // 排布策略（对齐 STS / Re:Night 的"固定间距优先"）：
        //   - 手牌上限 = 10（CardPileManager.HandLimit），不会超过
        //   - 固定间距 = 1/10 = 0.1（10张牌刚好铺满弧线时的间距）
        //   - 手牌少时：用固定间距，卡牌集中在弧线中央，不铺满整条线
        //     （STS 里 2-3 张牌紧凑地挤在屏幕中间，而不是分散到两端）
        //   - 10张牌时：刚好铺满 [0.05, 0.95]，两端留 5% 边距
        //
        // 旋转 = 切线垂直方向 - 90°（卡牌顶边贴合弧面）
        if (CardSpline != null)
        {
            // 从数组按手牌数量取间距（卡牌永远沿 0.5 中轴线左右对称）
            // 数组越界保护：count 超过数组长度时用最后一个值
            float s;
            if (SplineCardSpacingByCount != null && count < SplineCardSpacingByCount.Length)
            {
                s = SplineCardSpacingByCount[count];
            }
            else
            {
                s = 0.1f; // 兜底
            }

            // 居中排布：起始 t = 0.5 - 总宽度/2
            float startT = 0.5f - (count - 1) * s / 2f;

            for (int i = 0; i < count; i++)
            {
                // 在样条线上的归一化位置（居中排布，左右对称）
                float t = startT + i * s;

                // 采样样条上的世界坐标
                Vector3 pos = CardSpline.EvaluatePosition(t);
                // 样条切线方向
                Vector3 forward = CardSpline.EvaluateTangent(t);

                // 卡牌顶边垂直于切线，顺时针偏移90°让卡牌正立
                float zRot = Mathf.Atan2(forward.x, -forward.y) * Mathf.Rad2Deg - 90f;

                _cardViewInstances[i].transform.position = pos;
                _cardViewInstances[i].transform.localRotation = Quaternion.Euler(0, 0, zRot);
            }
            // 排布完成后记录基准位置（Spline 分支）
            RecordBasePositions();
            return;
        }

        // 回退：用 ArcHeightCurve 曲线排布
        for (int i = 0; i < count; i++)
        {
            // 归一化位置：0~1（单张牌时 t=0.5 居中）
            float t = count == 1 ? 0.5f : (float)i / (count - 1);

            // 水平位置：以 HandAreaRoot 中心为原点
            float x = (t - 0.5f) * CardSpacing * (count - 1);

            // 弧线深度：用 AnimationCurve 采样
            // 默认曲线在 Inspector 设置为：两端 y=-40，中间 y=0（形成下凹弧）
            float y = ArcHeightCurve.Evaluate(t);

            // 旋转角度：两端 -16° ~ +16°
            float rot = (t - 0.5f) * 2f * CardRotationMax;

            // 设置位置和旋转
            _cardViewInstances[i].transform.localPosition = new Vector3(x, y, 0);
            _cardViewInstances[i].transform.localRotation = Quaternion.Euler(0, 0, rot);
        }

        // 排布完成后，记录每张卡的基准 anchoredPosition3D
        // 用于扇开/恢复时计算目标位置（避免动画中途状态污染）
        RecordBasePositions();
    }

    /// <summary>
    /// 记录所有卡牌当前的 anchoredPosition3D 作为基准位置。
    /// 扇开目标 = 基准 + 偏移；恢复目标 = 基准。
    /// </summary>
    private void RecordBasePositions()
    {
        _baseAnchoredPositions.Clear();
        _baseRotations.Clear();
        for (int i = 0; i < _cardViewInstances.Count; i++)
        {
            var rt = _cardViewInstances[i].transform as RectTransform;
            _baseAnchoredPositions.Add(rt != null ? rt.anchoredPosition3D : Vector3.zero);
            _baseRotations.Add(_cardViewInstances[i].transform.localRotation);
        }
    }

    /// <summary>
    /// 收拢：拖出的卡超过打出阈值后，其余手牌按"少一张"的满员布局重排
    /// （例：4 张手牌拖出 1 张 → 剩余 3 张摆成 3 张手牌的布局）。
    /// 复用 LayoutCardsInArc 的 Spline 间距规则（SplineCardSpacingByCount[count-1]），
    /// 跳过拖动卡、其余卡索引重映射后居中采样样条。
    /// </summary>
    private void CollapseHandForPlay(CardView draggedCV)
    {
        if (CardSpline == null) return;   // 无 Spline 时跳过收拢（项目在用 Spline，回退分支不需要）

        int draggedIdx = _cardViewInstances.IndexOf(draggedCV);
        int totalCount = _cardViewInstances.Count;
        int remainCount = totalCount - 1;
        if (draggedIdx < 0 || remainCount <= 0) return;

        var parentRT = draggedCV.transform.parent as RectTransform;
        if (parentRT == null) return;

        // 与 LayoutCardsInArc 相同的间距规则，但数量用 remainCount
        float s;
        if (SplineCardSpacingByCount != null && remainCount < SplineCardSpacingByCount.Length)
            s = SplineCardSpacingByCount[remainCount];
        else
            s = 0.1f;

        float startT = 0.5f - (remainCount - 1) * s / 2f;

        int j = 0;   // 剩余卡的重映射索引（0..remainCount-1）
        for (int i = 0; i < totalCount; i++)
        {
            if (i == draggedIdx) continue;
            var cv = _cardViewInstances[i];
            if (cv == null) { j++; continue; }
            var cvRT = cv.transform as RectTransform;
            if (cvRT == null) { j++; continue; }

            float t = startT + j * s;
            Vector3 worldPos = CardSpline.EvaluatePosition(t);
            Vector3 localPos = parentRT.InverseTransformPoint(worldPos);   // 样条采样是世界坐标 → 转父空间
            Vector3 forward = CardSpline.EvaluateTangent(t);
            float zRot = Mathf.Atan2(forward.x, -forward.y) * Mathf.Rad2Deg - 90f;

            cv.CancelReturn();
            cv.transform.DOKill();
            DOTween.Kill(cvRT);
            DOTween.To(() => cvRT.anchoredPosition3D, x => cvRT.anchoredPosition3D = x, localPos, ReturnFanDuration)
                .SetEase(Ease.OutCubic)
                .SetTarget(cvRT);
            cvRT.DOLocalRotate(new Vector3(0, 0, zRot), ReturnFanDuration, RotateMode.Fast)
                .SetEase(Ease.OutCubic)
                .SetTarget(cvRT);
            j++;
        }
    }

    /// <summary>
    /// 展开：拖出的卡退回阈值内后，其余手牌回到各自基准位/基准旋转（原 n 张布局）。
    /// </summary>
    private void ExpandHandFromPlay(CardView draggedCV)
    {
        int draggedIdx = _cardViewInstances.IndexOf(draggedCV);
        int count = Mathf.Min(_cardViewInstances.Count, _baseAnchoredPositions.Count);
        for (int i = 0; i < count; i++)
        {
            if (i == draggedIdx) continue;
            var cv = _cardViewInstances[i];
            if (cv == null) continue;
            var cvRT = cv.transform as RectTransform;
            if (cvRT == null) continue;

            cv.CancelReturn();
            cv.transform.DOKill();
            DOTween.Kill(cvRT);
            DOTween.To(() => cvRT.anchoredPosition3D, x => cvRT.anchoredPosition3D = x, _baseAnchoredPositions[i], ReturnFanDuration)
                .SetEase(Ease.OutCubic)
                .SetTarget(cvRT);
            if (i < _baseRotations.Count)
            {
                cvRT.DOLocalRotate(_baseRotations[i].eulerAngles, ReturnFanDuration, RotateMode.Fast)
                    .SetEase(Ease.OutCubic)
                    .SetTarget(cvRT);
            }
        }
    }

    /// <summary>
    /// 卡牌平滑弹回基准位 + 恢复 Sibling Index（复用 ReturnFanDuration）。
    /// </summary>
    private void ReturnCardToBasePosition(CardView cv)
    {
        var rt = cv.transform as RectTransform;
        if (rt == null) return;

        int idx = _cardViewInstances.IndexOf(cv);
        Vector3 target = (idx >= 0 && idx < _baseAnchoredPositions.Count)
            ? _baseAnchoredPositions[idx]
            : rt.anchoredPosition3D;

        DOTween.Kill(rt);
        DOTween.To(() => rt.anchoredPosition3D, x => rt.anchoredPosition3D = x, target, ReturnFanDuration)
            .SetEase(Ease.OutCubic)
            .SetTarget(rt);

        if (idx >= 0 && cv.transform.parent != null && idx < cv.transform.parent.childCount)
        {
            cv.transform.SetSiblingIndex(idx);
        }
    }

    /// <summary>
    /// 【仅销毁前调用】立即无动画硬复位所有扇开位置。
    /// 仅限 RefreshHandLayout 销毁旧卡牌前使用——之后马上被 Destroy，看不到"硬跳"。
    /// 正常的悬停切换（A→B）走 NotifyCardHovered 的平滑过渡，绝不调用此方法。
    /// </summary>
    private void UnfanAllForDestroy()
    {
        int fannedIdx = _fannedHoverCard != null ? _cardViewInstances.IndexOf(_fannedHoverCard) : -1;
        int count = Mathf.Min(_cardViewInstances.Count, _baseAnchoredPositions.Count);
        for (int i = 0; i < count; i++)
        {
            if (i == fannedIdx) continue;
            var cv = _cardViewInstances[i];
            if (cv == null) continue;
            var rt = cv.transform as RectTransform;
            if (rt == null) continue;
            cv.CancelReturn();
            cv.transform.DOKill();
            DOTween.Kill(rt);      // 彻底 kill 所有该 RT 的位置 Tween
            rt.anchoredPosition3D = _baseAnchoredPositions[i];
        }
        _fannedHoverCard = null;
    }
}

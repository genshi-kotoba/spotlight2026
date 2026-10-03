// =============================================================================
// 模块：Tutorial - 教学进度（跨局持久化封装）
// 用途：教学系统的「是否已完成」单一真相源，读写 MetaWallet.tutorialStage。
// 设计依据：用户 2026-09-12 决策——教程完成判定 = 抵达藏身处入口(39,6)；
//           教程未完成(tutorialStage==0)→ 启动走教程图(TutorialScene)。
// 范围：垂直切片只用到 0 / 1 两档；int 类型预留后续「两次循环」stage(0/1/2/3) 扩展。
// =============================================================================
using UnityEngine;

/// <summary>
/// 教学进度静态封装。所有教学相关「该不该教 / 教完了没」都问这里，不要散落读 MetaWallet。
/// </summary>
public static class TutorialProgress
{
    /// <summary>当前教学进度档位（0=未完成，>=1=完成）。</summary>
    public static int CurrentStage => MetaWallet.TutorialStage;

    /// <summary>教程是否还未完成（首通玩家）。Director 只在 true 时激活。</summary>
    public static bool IsTutorialPending => CurrentStage == 0;

    /// <summary>教程是否已通关（抵达藏身处入口）。</summary>
    public static bool IsComplete => CurrentStage >= 1;

    /// <summary>标记教程完成（抵达藏身处入口时调用）。</summary>
    public static void MarkComplete()
    {
        if (IsComplete) return;
        MetaWallet.SetTutorialStage(1);
        Debug.Log("[Tutorial] 教学完成：tutorialStage → 1（下次启动进藏身处）");
    }

    /// <summary>调试/重置：清空教学进度（设置页「重看教程」或 ResetAll 时调用）。</summary>
    public static void Reset()
    {
        MetaWallet.SetTutorialStage(0);
        Debug.Log("[Tutorial] 教学进度已重置为 0");
    }
}

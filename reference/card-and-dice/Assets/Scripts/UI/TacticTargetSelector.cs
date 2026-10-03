// =============================================================================
// 模块：M7 战术卡槽 - TacticTargetSelector 指向辅助（纯静态）
// 用途：战术卡中"目标敌人"类效果（CardData.RequiresManualTarget）的指向模式支持——
//       鼠标下的敌人识别、六边形射程校验、射程高亮显示/清除。
// 设计依据：背包与战利品系统 spec §5（战术卡槽仅战斗可用）
//           +《设计增补_边缘情况与验收标准》§十（战术卡槽边缘情况）
// 实现说明：命中与射程口径逐行复刻 HandUIController.Arrow.cs:132-174（射线打敌人模型 +
//       打 Hex_x_y 地板格按坐标匹配 + HexDistance ≤ CardData.Range）。
//       不复用 HandUIController 的方法：它们是 private 且耦合 _activeCard 交互流。
// =============================================================================
using UnityEngine;

/// <summary>
/// 战术卡指向模式的命中 / 射程 / 高亮辅助（纯静态）。
/// 生命周期由 TacticSlotsPanel 驱动：Begin（进指向）→ EnemyUnderMouse / InRange（每帧点击判定）→ End（退出）。
/// </summary>
public static class TacticTargetSelector
{
    static Card _card;
    static EnemyController[] _enemies;
    static HexMover _mover;

    /// <summary>
    /// 进入指向模式：记住这张卡、刷新敌人与玩家缓存、显示红色射程高亮。
    /// 敌人缓存**每次进入都重建**：战斗中可能有召唤物加入或敌人死亡，长期缓存会漏判/误判。
    /// </summary>
    public static void Begin(Card card)
    {
        _card = card;
        _enemies = Object.FindObjectsOfType<EnemyController>();
        _mover = Object.FindObjectOfType<HexMover>();
        ShowRangeHighlight();
    }

    /// <summary>退出指向模式：清高亮 + 清缓存（避免持有已销毁对象的引用）。</summary>
    public static void End()
    {
        CardRangeHighlight.Clear();
        _card = null;
        _enemies = null;
        _mover = null;
    }

    /// <summary>
    /// 鼠标下的存活敌人（★用户 2026-08-18：不要求精准点击敌人模型）：
    ///   ① 直接命中敌人模型 → 返回该敌人
    ///   ② 命中 Hex_x_y 地板格 → 按坐标匹配站在该格上的存活敌人
    /// </summary>
    public static EnemyController EnemyUnderMouse()
    {
        Camera cam = Camera.main;
        if (cam == null) return null;

        RaycastHit[] hits = Physics.RaycastAll(cam.ScreenPointToRay(Input.mousePosition), 100f);
        foreach (RaycastHit hit in hits)
        {
            var enemy = hit.collider.GetComponentInParent<EnemyController>();
            if (enemy != null && !enemy.IsDead) return enemy;

            string objName = hit.collider.gameObject.name;
            if (objName != null && objName.StartsWith("Hex_"))
            {
                string[] parts = objName.Split('_');
                if (parts.Length == 3 && int.TryParse(parts[1], out int x) && int.TryParse(parts[2], out int y))
                {
                    var coord = new Vector2Int(x, y);
                    if (_enemies == null) _enemies = Object.FindObjectsOfType<EnemyController>();
                    foreach (var e in _enemies)
                    {
                        if (e != null && !e.IsDead && e.CurrentCoord == coord) return e;
                    }
                }
            }
        }
        return null;
    }

    /// <summary>
    /// 射程校验：六边形距离 ≤ 卡牌射程。
    /// 找不到玩家时不做射程限制（防御，正常战斗场景必有玩家）。
    /// </summary>
    public static bool InRange(EnemyController enemy, Card card)
    {
        if (enemy == null || card == null || card.Data == null) return false;
        if (_mover == null) _mover = Object.FindObjectOfType<HexMover>();
        if (_mover == null) return true;
        return CardExecutor.HexDistance(_mover.CurrentCoord, enemy.CurrentCoord) <= card.Data.Range;
    }

    /// <summary>玩家到目标的六边形距离；拿不到任一方返回 -1（只给提示文本用）。</summary>
    public static int DistanceToPlayer(EnemyController enemy)
    {
        if (enemy == null) return -1;
        if (_mover == null) _mover = Object.FindObjectOfType<HexMover>();
        if (_mover == null) return -1;
        return CardExecutor.HexDistance(_mover.CurrentCoord, enemy.CurrentCoord);
    }

    /// <summary>
    /// 显示射程高亮（红色 = "打出去后生效的目标和格子"，★2026-08-17 双色语义）。
    /// range &lt; 0 → 无射程概念，清高亮；range == 0 → 只染玩家脚下一格。
    /// </summary>
    static void ShowRangeHighlight()
    {
        if (_card == null || _card.Data == null) return;
        if (_mover == null) _mover = Object.FindObjectOfType<HexMover>();
        if (_mover == null) return;

        int range = _card.Data.Range;
        if (range < 0)
        {
            CardRangeHighlight.Clear();
            return;
        }
        CardRangeHighlight.Show(_mover.CurrentCoord, range, true);
    }
}

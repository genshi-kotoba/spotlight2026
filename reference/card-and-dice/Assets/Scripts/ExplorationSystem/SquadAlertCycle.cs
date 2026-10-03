// =============================================================================
// 小队警戒周期 · 偷袭资格登记（《设计增补_威胁预告与搜索阶段.md》§6.2）
// =============================================================================
// 核心一句话：一个警戒周期（意图开始 → 复原）内，小队第一次受到探索态玩家直接攻击即触发
// 偷袭，之后资格耗尽；**消耗条件 = 进入过战斗**（偷袭 / 被动遇袭 / 传导参战都算），
// **与徽章颜色无关**——纯陷阱流小队从未进战，打它的红`!`/黄`?`/白`?` 照样全额偷袭。
//
// 为什么住在这里而不是 EnemyController：资格是**按小队**的，不是按个体的；项目里小队没有
// 实体对象（只有 EnemyController.SquadId 这个 int），所以用一张静态表按 SquadId 记账。
// 独立敌人（SquadId = -1）各自成账，互不影响（§6.2「小队独立」）。
// =============================================================================
using System.Collections.Generic;

/// <summary>
/// 按小队记录「本警戒周期是否已进入过战斗」，据此判定探索态攻击能否拿到全额偷袭奖励。
/// </summary>
public static class SquadAlertCycle
{
    /// <summary>key = 小队账目键；value = 本周期是否已进入过战斗（= 资格已耗）。</summary>
    static readonly Dictionary<int, bool> _enteredBattle = new Dictionary<int, bool>();

    /// <summary>
    /// 小队账目键：有小队 = SquadId；独立敌人（SquadId &lt; 0）= 按实例各记一笔，
    /// 用负数键避免与真实 SquadId 撞号。
    /// </summary>
    public static int KeyOf(EnemyController e)
    {
        if (e == null) return 0;
        if (e.SquadId >= 0) return e.SquadId;
        return -1000000 - e.GetInstanceID();
    }

    /// <summary>本周期该小队是否已进入过战斗（true = 偷袭资格已耗）。</summary>
    public static bool HasEnteredBattle(EnemyController e)
    {
        return _enteredBattle.TryGetValue(KeyOf(e), out bool entered) && entered;
    }

    /// <summary>
    /// 标记进入战斗 → 本周期偷袭资格耗尽（§6.2 消耗条件）。
    /// 偷袭进战 / 被动遇袭进战 / 视野覆盖整队参战，三种入口都调这一个方法。
    /// </summary>
    public static void MarkEnteredBattle(EnemyController e)
    {
        if (e == null) return;
        _enteredBattle[KeyOf(e)] = true;
    }

    /// <summary>
    /// 探索态玩家直接攻击时结算资格：true = 本周期首次（全额偷袭，含免费整备）；
    /// false = 已进过战（入口流程照走，但无免费整备，骰转能量照旧）。
    /// 无论真假都随即标记为已耗——一个警戒周期只给一次。
    /// </summary>
    public static bool TryConsumeAmbush(EnemyController e)
    {
        if (e == null) return false;
        int key = KeyOf(e);
        bool full = !(_enteredBattle.TryGetValue(key, out bool entered) && entered);
        _enteredBattle[key] = true;
        return full;
    }

    /// <summary>复原（回合6 / 陷阱流程复原）：清账，资格恢复（§6.2 / §11）。</summary>
    public static void Clear(EnemyController e)
    {
        if (e == null) return;
        _enteredBattle.Remove(KeyOf(e));
    }

    /// <summary>全场清账（战斗结束 / 场景重载 / 测试重开时调用，避免跨局残留）。</summary>
    public static void ClearAll()
    {
        _enteredBattle.Clear();
    }
}

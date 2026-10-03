// =============================================================================
// 模块：M7 战利品 - CorpseRegistry 遗物袋注册表（纯静态）
// 用途：按格坐标增删查遗物袋；当局（本次探索）结束全部消散。
// 设计依据：背包与战利品系统 spec §8（存续：清空后消失 / 当局结束即消散）
// ★为什么是静态：产出方（CorpseSpawner 订阅 EnemyDied）、查询方（HexMover 踩格）、
//   展示方（LootPopupUI）分属三处且没有共同的 MonoBehaviour 宿主；与 TacticSlotRuntime /
//   CardLoadout / DicePayment 同一口径。
// ⚠ 静态字段**不会**被 SceneManager.LoadScene 重置（BattleResultHandler.ResolveDefeat
//   就是直接重载场景）→ 当局结束必须调 ClearAll，接线在 Task 23。
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>遗物袋注册表（纯静态）。</summary>
public static class CorpseRegistry
{
    static readonly Dictionary<Vector2Int, CorpseContainer> _corpses =
        new Dictionary<Vector2Int, CorpseContainer>();

    /// <summary>遗物袋增删（CorpseSpawner 的地图标记同步、LootPopupUI 的刷新订阅它）</summary>
    public static event Action OnChanged;

    /// <summary>按格查询；该格没有遗物袋返回 null。</summary>
    public static CorpseContainer Get(Vector2Int coord)
    {
        _corpses.TryGetValue(coord, out CorpseContainer corpse);
        return corpse;
    }

    public static bool Has(Vector2Int coord)
    {
        return Get(coord) != null;
    }

    public static int Count => _corpses.Count;

    /// <summary>遍历用（标记同步）。**不要在遍历中增删**——先收集再改。</summary>
    public static IEnumerable<CorpseContainer> All() => _corpses.Values;

    /// <summary>
    /// 在指定格生成遗物袋。同格已有 → **返回既有袋**（内容合并，不覆盖：
    /// 战斗中敌人会被推挤/换位，同格死亡不是异常，覆盖会让先死那个的掉落凭空消失）。
    /// 坐标非法（EnemyController.CurrentCoord 未绑格时是 (-1,-1)）→ 返回 null 且不注册。
    /// </summary>
    public static CorpseContainer Spawn(Vector2Int coord, string enemyName)
    {
        if (coord.x < 0 || coord.y < 0)
        {
            Debug.LogWarning($"[CorpseRegistry] 坐标非法 {coord}（敌人未绑格？），不生成遗物袋：{enemyName}");
            return null;
        }

        CorpseContainer existing = Get(coord);
        if (existing != null)
        {
            Debug.Log($"[CorpseRegistry] Hex_{coord.x}_{coord.y} 已有遗物袋（{existing.EnemyName}），" +
                      $"{enemyName} 的掉落并入同一袋");
            OnChanged?.Invoke();
            return existing;
        }

        var corpse = new CorpseContainer(coord, enemyName);
        _corpses[coord] = corpse;
        Debug.Log($"[CorpseRegistry] 生成遗物袋：{corpse.EnemyName} @ Hex_{coord.x}_{coord.y}");
        OnChanged?.Invoke();
        return corpse;
    }

    /// <summary>袋子清空后移除（spec §8「清空后消失」）。传入的袋与注册表里的不是同一个则不动。</summary>
    public static void Remove(CorpseContainer corpse)
    {
        if (corpse == null) return;
        if (!_corpses.TryGetValue(corpse.Coord, out CorpseContainer registered)) return;
        if (!ReferenceEquals(registered, corpse)) return;

        _corpses.Remove(corpse.Coord);
        Debug.Log($"[CorpseRegistry] 遗物袋已清空消失：{corpse.EnemyName} @ Hex_{corpse.Coord.x}_{corpse.Coord.y}");
        OnChanged?.Invoke();
    }

    /// <summary>
    /// 当局（本次探索）结束：全部消散（spec §8）。
    /// Task 23 的 ExpeditionLifecycle.EndExpedition 调用；玩家死亡重载场景前也走那里。
    /// </summary>
    public static void ClearAll()
    {
        if (_corpses.Count == 0) return;

        Debug.Log($"[CorpseRegistry] 当局结束，{Count} 个遗物袋消散");
        _corpses.Clear();
        OnChanged?.Invoke();
    }
}

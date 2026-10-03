// =============================================================================
// 模块：探索系统 - EncounterZone 遭遇区（地图布局字符 x）
// 用途：在地图上圈出一片「这一带会刷怪」的区域，**不指定具体是哪只怪**——
//       每局由 EncounterDirector 在区内掷点决定：刷几支小队、什么类型、走什么巡逻路线。
//
// 为什么用字符连片而不是画矩形：
//   布局文本是地图的唯一载体（可 diff / 可回滚）。在房间里刷一片 xxx 就是一块遭遇区，
//   贴合房间形状（房间不是规整矩形时矩形会圈到墙里）。
//   同一片连通 x = 同一个遭遇区；被墙隔开的另一片 x = 另一个遭遇区。
//
// 与 SquadPatrolData 的分工：
//   · SquadPatrolData  = 固定巡逻（教程 / 剧情 / 手工精摆，可带 ±N 小随机）
//   · EncounterZone    = 随机遭遇（正式图主力：数量 / 类型 / 路径每局都不一样）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

[System.Serializable]
public class EncounterZone
{
    /// <summary>本区包含的全部格子（布局里连成一片的 x）。</summary>
    public List<Vector2Int> cells = new List<Vector2Int>();

    /// <summary>包围盒（odd-q 偏移空间；仅用于调试显示与快速筛选）。</summary>
    public Vector2Int min;
    public Vector2Int max;

    /// <summary>离几何中心最近的实格——日志与「区域中心」类逻辑用。</summary>
    public Vector2Int center;

    /// <summary>本区在整张图里的序号（0 起，按扫描顺序）。</summary>
    public int index;

    public int CellCount => cells != null ? cells.Count : 0;

    public EncounterZone() { }

    public EncounterZone(List<Vector2Int> cells, int index)
    {
        this.cells = cells;
        this.index = index;
        Rebuild();
    }

    /// <summary>重算包围盒与中心格。</summary>
    public void Rebuild()
    {
        if (cells == null || cells.Count == 0)
        {
            min = max = center = Vector2Int.zero;
            return;
        }

        int minX = int.MaxValue, minY = int.MaxValue, maxX = int.MinValue, maxY = int.MinValue;
        long sumX = 0, sumY = 0;
        foreach (Vector2Int c in cells)
        {
            if (c.x < minX) minX = c.x;
            if (c.y < minY) minY = c.y;
            if (c.x > maxX) maxX = c.x;
            if (c.y > maxY) maxY = c.y;
            sumX += c.x;
            sumY += c.y;
        }
        min = new Vector2Int(minX, minY);
        max = new Vector2Int(maxX, maxY);

        // 中心格：离算术均值最近的实格（保证中心一定落在区内的可站格上）
        var mean = new Vector2((float)sumX / cells.Count, (float)sumY / cells.Count);
        float best = float.MaxValue;
        center = cells[0];
        foreach (Vector2Int c in cells)
        {
            float dx = c.x - mean.x;
            float dy = c.y - mean.y;
            float d = dx * dx + dy * dy;
            if (d < best)
            {
                best = d;
                center = c;
            }
        }
    }

    /// <summary>把 <paramref name="all"/> 里的格子按六边连通性切成若干遭遇区。</summary>
    public static List<EncounterZone> GroupConnected(List<Vector2Int> all)
    {
        var zones = new List<EncounterZone>();
        if (all == null || all.Count == 0) return zones;

        var remaining = new HashSet<Vector2Int>(all);
        var stack = new Stack<Vector2Int>();
        int index = 0;

        while (remaining.Count > 0)
        {
            var blob = new List<Vector2Int>();
            Vector2Int seed = default;
            foreach (Vector2Int c in remaining) { seed = c; break; }

            remaining.Remove(seed);
            stack.Push(seed);

            while (stack.Count > 0)
            {
                Vector2Int cur = stack.Pop();
                blob.Add(cur);
                foreach (Vector2Int n in MoveAIController.GetNeighbors(cur))
                {
                    if (remaining.Remove(n)) stack.Push(n);
                }
            }

            blob.Sort((a, b) => a.x != b.x ? a.x.CompareTo(b.x) : a.y.CompareTo(b.y));
            zones.Add(new EncounterZone(blob, index++));
        }
        return zones;
    }
}

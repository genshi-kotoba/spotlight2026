// =============================================================================
// odd-q 平顶六边形坐标工具（与 CardExecutor.HexDistance / SpawnResolver 邻居一致）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public static class HexCoord
{
    public struct Cube
    {
        public int x, y, z;
        public Cube(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }
        public static Cube operator -(Cube a, Cube b) => new Cube(a.x - b.x, a.y - b.y, a.z - b.z);
        public static Cube operator +(Cube a, Cube b) => new Cube(a.x + b.x, a.y + b.y, a.z + b.z);
    }

    // 立方体六邻：从「模板前方」(0,-1) offset 对应的 (0,1,-1) 起，逆时针每 60°
    public static readonly Cube[] Directions =
    {
        new Cube(0, 1, -1),
        new Cube(-1, 1, 0),
        new Cube(-1, 0, 1),
        new Cube(0, -1, 1),
        new Cube(1, -1, 0),
        new Cube(1, 0, -1)
    };

    public static Cube ToCube(Vector2Int offset)
    {
        int col = offset.x;
        int row = offset.y;
        int cx = col;
        int cz = row - (col - (col & 1)) / 2;
        int cy = -cx - cz;
        return new Cube(cx, cy, cz);
    }

    public static Vector2Int FromCube(Cube c)
    {
        int col = c.x;
        int row = c.z + (c.x - (c.x & 1)) / 2;
        return new Vector2Int(col, row);
    }

    /// <summary>cube 线性插值 + 标准立方体取整（保证 x+y+z=0，落点严格贴线段）。</summary>
    public static Cube CubeLerp(Cube a, Cube b, float t)
    {
        float fx = Mathf.Lerp(a.x, b.x, t);
        float fy = Mathf.Lerp(a.y, b.y, t);
        float fz = Mathf.Lerp(a.z, b.z, t);
        int rx = Mathf.RoundToInt(fx);
        int ry = Mathf.RoundToInt(fy);
        int rz = Mathf.RoundToInt(fz);
        float dx = Mathf.Abs(rx - fx), dy = Mathf.Abs(ry - fy), dz = Mathf.Abs(rz - fz);
        if (dx > dy && dx > dz) rx = -ry - rz;
        else if (dy > dz) ry = -rx - rz;
        else rz = -rx - ry;
        return new Cube(rx, ry, rz);
    }

    /// <summary>
    /// 线段 a—b 上离 <paramref name="from"/> 最近的格 = 六边格版的**垂足**。
    /// 六边格没有解析垂直投影，用「cube 空间线性插值采样 → 取六边距离最近者」近似，
    /// 采样密度 = 段长 × 4，误差在半格以内。
    /// </summary>
    /// <param name="accept">落点过滤（可站格判定）；null = 不过滤。</param>
    /// <returns>线段上一个可接受的格都没有 → false（调用方自行退化，例如改取端点）。</returns>
    public static bool TrySegmentFoot(Vector2Int from, Vector2Int a, Vector2Int b,
        System.Func<Vector2Int, bool> accept, out Vector2Int foot)
    {
        foot = a;
        Cube ca = ToCube(a);
        Cube cb = ToCube(b);
        int samples = Mathf.Max(1, CardExecutor.HexDistance(a, b)) * 4;
        var seen = new HashSet<Vector2Int>();

        int best = int.MaxValue;
        bool found = false;
        for (int s = 0; s <= samples; s++)
        {
            Vector2Int cell = FromCube(CubeLerp(ca, cb, (float)s / samples));
            if (!seen.Add(cell)) continue;
            if (accept != null && !accept(cell)) continue;

            int d = CardExecutor.HexDistance(from, cell);
            if (d < best)
            {
                best = d;
                foot = cell;
                found = true;
            }
        }
        return found;
    }

    public static Cube RotateCcW60(Cube c)
    {
        return new Cube(-c.z, -c.x, -c.y);
    }

    public static Cube RotateSteps(Cube c, int steps)
    {
        steps = ((steps % 6) + 6) % 6;
        for (int i = 0; i < steps; i++) c = RotateCcW60(c);
        return c;
    }

    /// <summary>把相对锚点的 hexOffset 绕原点旋转 steps×60°（逆时针）。</summary>
    public static Vector2Int RotateOffset(Vector2Int offset, int steps)
    {
        if (offset == Vector2Int.zero || steps % 6 == 0) return offset;
        return FromCube(RotateSteps(ToCube(offset), steps));
    }

    /// <summary>锚点 + 模板偏移按朝向旋转后的世界格（立方体加法，与 odd-q 直接相加不同）。</summary>
    public static Vector2Int FormationSlot(Vector2Int anchor, Vector2Int templateOffset, int faceSteps)
    {
        Cube rel = RotateSteps(ToCube(templateOffset), faceSteps);
        return FromCube(ToCube(anchor) + rel);
    }

    public static int NearestDirIndex(Cube delta)
    {
        int best = 0;
        int bestDot = int.MinValue;
        for (int i = 0; i < 6; i++)
        {
            Cube d = Directions[i];
            int dot = delta.x * d.x + delta.y * d.y + delta.z * d.z;
            if (dot > bestDot)
            {
                bestDot = dot;
                best = i;
            }
        }
        return best;
    }

    /// <summary>
    /// 编队模板前方 = offset (0,-1)（y 小为前排）。
    /// 返回把模板前方转到 from→to 需要的旋转步数（与 <see cref="RotateSteps"/> 同向）。
    /// 平顶格子的纯上下邻向（同列 ±y）与左右相反：不额外转 180° 时，
    /// 先锋在 (0,1) 的小队横走队头正确、竖走队头会反。
    /// </summary>
    public static int FacingSteps(Vector2Int from, Vector2Int to)
    {
        if (from == to) return 0;
        int travel = NearestDirIndex(ToCube(to) - ToCube(from));
        const int templateFront = 0; // Directions[0] = (0,1,-1) = offset (0,-1)
        int steps = (travel - templateFront + 6) % 6;
        if (travel == 0 || travel == 3) steps = (steps + 3) % 6;
        return steps;
    }

    public static int DirDelta(int fromIndex, int toIndex)
    {
        int d = ((toIndex - fromIndex) % 6 + 6) % 6;
        if (d > 3) d -= 6;
        return d; // -3..3，正=逆时针拐
    }

    /// <summary>格子编号 12_16 / 12,16 / 12 16 → 坐标。失败返回 false。</summary>
    public static bool TryParseCell(string text, out Vector2Int cell)
    {
        cell = Vector2Int.zero;
        if (string.IsNullOrWhiteSpace(text)) return false;
        string t = text.Trim().Replace("Hex_", "").Replace("hex_", "");
        char sep = t.Contains("_") ? '_' : (t.Contains(",") ? ',' : ' ');
        string[] parts = t.Split(sep);
        if (parts.Length < 2) return false;
        if (!int.TryParse(parts[0].Trim(), out int x)) return false;
        if (!int.TryParse(parts[1].Trim(), out int y)) return false;
        cell = new Vector2Int(x, y);
        return true;
    }

    public static string FormatCell(Vector2Int cell)
    {
        return cell.x + "_" + cell.y;
    }
}

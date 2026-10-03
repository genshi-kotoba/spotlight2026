// =============================================================================
// 模块：探索系统 - 篝火点 BonfireTile
// 用途：玩家初始位置（及后续可放置的篝火点）的交互入口。
//       玩家站在篝火格上 → 可打开篝火面板，选择「休息」或「调整战术卡槽」。
// 设计依据：用户 2026-09-11 决策——战术卡槽只能在篝火等特殊情况下调整；
//           篝火点建在玩家初始位置，提供休息（耗骰回血+强制结束回合）与战术槽调整。
// 交互模型：与 EventTile 同款——
//   · 移动落点命中篝火格 → 弹面板（ExplorationTurnManager.OnMoveEnded 调 TryOpenAt）
//   · 已关闭后点击脚下篝火格 → 重开面板（HandleTileClickReopen）
// =============================================================================
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.EventSystems;

/// <summary>
/// 篝火点组件 + 全局注册表（静态）。
/// 玩家脚下坐标 == 某篝火格坐标时，战术卡槽调整门禁开启（见 CardPackUI）。
/// </summary>
public class BonfireTile : MonoBehaviour
{
    [Header("篝火配置")]
    [Tooltip("篝火格坐标。留 (0,0) 时自动取同对象 HexTile.coordinates")]
    public Vector2Int coord;

    // -------- 静态注册表：所有场景内篝火点 --------
    private static readonly List<BonfireTile> activeBonfires = new List<BonfireTile>();

    private GameObject _marker;
    private bool started = false;

    private void Awake()
    {
        if (coord == Vector2Int.zero)
        {
            HexTile tile = GetComponent<HexTile>();
            if (tile != null) coord = tile.coordinates;
        }
    }

    private void OnEnable()
    {
        if (!activeBonfires.Contains(this)) activeBonfires.Add(this);
    }

    private void OnDisable()
    {
        activeBonfires.Remove(this);
    }

    private void Start()
    {
        started = true;
        CreateMarker();
    }

    // ------------------------------------------------------------------
    // 运行时在玩家初始坐标生成篝火点（避免手动摆场景）
    // ------------------------------------------------------------------

    /// <summary>
    /// 在玩家初始坐标建一个篝火点（若同坐标已存在则跳过）。
    /// 由 HexMover.Start 在坐标解析完成后调用——这里是初始位置的唯一权威来源。
    /// </summary>
    public static void CreateAtStart(Vector2Int startCoord)
    {
        foreach (BonfireTile b in activeBonfires)
        {
            if (b != null && b.coord == startCoord) return; // 已存在，不重复建
        }

        GameObject tile = FindMap1Tile(startCoord);
        GameObject go = new GameObject("BonfireTile_" + startCoord.x + "_" + startCoord.y);
        if (tile != null)
        {
            go.transform.position = tile.transform.position;
            go.transform.SetParent(tile.transform, true);
        }
        else
        {
            Debug.LogWarning($"[篝火] 未找到初始格 {startCoord} 的 Map1 格子，篝火标记退化为原点");
        }

        BonfireTile bt = go.AddComponent<BonfireTile>();
        bt.coord = startCoord;
        bt.started = true;
        bt.CreateMarker();

        Debug.Log($"[篝火] 已在玩家初始坐标 {startCoord} 生成篝火点");
    }

    private static GameObject FindMap1Tile(Vector2Int coord)
    {
        GameObject map1 = GameObject.Find("Map1");
        if (map1 == null) return null;
        foreach (Transform child in map1.transform)
        {
            if (child.name == $"Hex_{coord.x}_{coord.y}") return child.gameObject;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // 视觉标记：木柴 + 火焰（无美术资源，运行时自建）
    // ------------------------------------------------------------------

    private void CreateMarker()
    {
        if (_marker != null) return;

        Vector3 basePos = transform.position;
        _marker = new GameObject("BonfireMarker");
        _marker.transform.SetParent(transform, true);
        _marker.transform.position = new Vector3(basePos.x, basePos.y + 0.25f, basePos.z);

        // 木柴（横躺圆柱）
        GameObject logs = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
        logs.name = "Logs";
        logs.transform.SetParent(_marker.transform, true);
        logs.transform.localPosition = new Vector3(0f, 0.06f, 0f);
        logs.transform.localRotation = Quaternion.Euler(90f, 0f, 0f);
        logs.transform.localScale = new Vector3(0.55f, 0.18f, 0.55f);
        Renderer lr = logs.GetComponent<Renderer>();
        if (lr != null)
        {
            Material m = new Material(Shader.Find("Standard"));
            m.color = new Color(0.40f, 0.25f, 0.12f);
            lr.sharedMaterial = m;
        }
        Collider lc = logs.GetComponent<Collider>();
        if (lc != null) Destroy(lc);

        // 火焰（上小下大的圆锥）
        GameObject flame = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
        flame.name = "Flame";
        flame.transform.SetParent(_marker.transform, true);
        flame.transform.localPosition = new Vector3(0f, 0.42f, 0f);
        flame.transform.localScale = new Vector3(0.30f, 0.55f, 0.30f);
        Renderer fr = flame.GetComponent<Renderer>();
        if (fr != null)
        {
            Material m = new Material(Shader.Find("Standard"));
            m.color = new Color(1f, 0.45f, 0.08f);
            m.EnableKeyword("_EMISSION");
            m.SetColor("_EmissionColor", new Color(1f, 0.4f, 0.05f));
            fr.sharedMaterial = m;
        }
        Collider fc = flame.GetComponent<Collider>();
        if (fc != null) Destroy(fc);
    }

    // ------------------------------------------------------------------
    // 门禁 + 触发
    // ------------------------------------------------------------------

    /// <summary>玩家当前是否站在某个篝火格上（战术卡槽调整门禁的真值来源）。</summary>
    public static bool IsPlayerOnBonfire()
    {
        // ★2026-09-11：战斗模式完全无法与篝火交互（既是触发门禁，也是卡包战术槽调整门禁的真相来源）
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring)
            return false;
        HexMover mover = Object.FindObjectOfType<HexMover>();
        if (mover == null) return false;
        Vector2Int pc = mover.CurrentCoord;
        foreach (BonfireTile b in activeBonfires)
        {
            if (b != null && b.coord == pc) return true;
        }
        return false;
    }

    /// <summary>
    /// 玩家落点坐标是否命中篝火格 → 打开篝火面板。
    /// 由 ExplorationTurnManager.OnMoveEnded 在事件格检查之后调用。
    /// </summary>
    /// <returns>true = 已打开面板</returns>
    public static bool TryOpenAt(Vector2Int playerCoord)
    {
        // ★2026-09-11：仅探索模式可触发篝火点，战斗模式无法交互
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring)
            return false;

        // ★2026-09-13 用户需求：教程期**不自动弹面板**——教程要教玩家「点击脚下篝火格」
        //   这个交互（走 HandleTileClickReopen 那条链路），自动弹会把这一步教没了。
        //   正式图保持原行为（走到就弹，更顺手）。
        if (MapLayoutBuilder.IsTutorial) return false;
        foreach (BonfireTile b in activeBonfires)
        {
            if (b == null || !b.started) continue;
            if (b.coord == playerCoord)
            {
                BonfireUI.ShowBonfire();
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// 点击脚下篝火格重开面板（与 EventTile.HandleTileClickReopen 同款物理射线逻辑）。
    /// 由 ExplorationTurnManager.Update 每帧调用。
    /// </summary>
    public static void HandleTileClickReopen()
    {
        if (GameStateManager.Instance == null || GameStateManager.Instance.CurrentState != GameState.Exploring) return;
        if (BonfireUI.IsOpen) return;
        if (!Input.GetMouseButtonDown(0)) return;
        if (EventSystem.current != null && EventSystem.current.IsPointerOverGameObject()) return;

        Camera cam = Camera.main;
        if (cam == null) return;
        if (!Physics.Raycast(cam.ScreenPointToRay(Input.mousePosition), out RaycastHit hit)) return;
        if (hit.collider == null || !hit.collider.CompareTag("Ground") || !hit.collider.name.StartsWith("Hex_")) return;

        string[] parts = hit.collider.name.Split('_');
        if (parts.Length < 3 || !int.TryParse(parts[1], out int x) || !int.TryParse(parts[2], out int y)) return;
        Vector2Int clicked = new Vector2Int(x, y);

        HexMover mover = Object.FindObjectOfType<HexMover>();
        if (mover == null || mover.CurrentCoord != clicked) return;

        foreach (BonfireTile b in activeBonfires)
        {
            if (b != null && b.started && b.coord == clicked)
            {
                BonfireUI.ShowBonfire();
                return;
            }
        }
    }
}

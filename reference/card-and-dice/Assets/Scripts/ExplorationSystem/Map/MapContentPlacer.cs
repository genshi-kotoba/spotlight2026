// =============================================================================
// 模块：探索系统 - 地图内容摆放骨架（re-bake safe）
// 用途：把"事件 / 精英 / Boss / 撤离点 / 藏身处"的内容摆放做成数据驱动，
//       并且不被 HexGridLayout 的 "Generate Grid" 冲掉。
//       · 事件格：加在 Map1 的 Hex_x_y 子物体上（Generate Grid 会清空 Map1 子物体，
//         因此每次重烘焙后重跑本菜单即可重新挂上）。
//       · 精英/Boss/撤离点/藏身处：用彩色标记立方挂在本组件所在对象下，
//         与 Map1 平级，Generate Grid 只清 Map1，不影响这些标记。
//
// 使用（Unity 编辑器内）：
//   1. 在 MainScene 建一个空物体，命名为 "MapContent"，挂本组件。
//   2. 按《地图蓝图_新场景.md》填 events / eliteSpots / bossSpot / extractionSpot / hideoutSpot。
//   3. 右键本组件 → "Place Map Content (re-bake safe)"。
//   4. 敌人小队不用这里摆：建 SquadPatrolData 资产（含巡逻路径点）放到
//      Assets/Data/SquadPatrols，ExpeditionEncounterBootstrap 会自动按首路径点生成。
//
// 设计依据：2026-09-11 决策——新场景"加大六边格 + 只搭骨架"；
//           撤离点 D12 / 藏身处属 P0 单独做，本骨架仅预留坐标 + 占位标记。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public class MapContentPlacer : MonoBehaviour
{
    [System.Serializable]
    public class EventPlacement
    {
        public Vector2Int coord;
        public EventData eventData;
    }

    [Header("事件格（加在 Map1 的 Hex_x_y 上，烘焙后重跑即可重新挂）")]
    public List<EventPlacement> events = new List<EventPlacement>();

    [Header("预留位置（彩色标记立方，挂在本对象下，烘焙安全）")]
    public List<Vector2Int> eliteSpots = new List<Vector2Int>();
    public Vector2Int bossSpot;
    public Vector2Int extractionSpot;
    public Vector2Int hideoutSpot;

    private const string MarkerParentName = "MapContentMarkers";

    [ContextMenu("Place Map Content (re-bake safe)")]
    public void Place()
    {
        ClearMarkers();
        PlaceEvents();
        PlaceMarker(eliteSpots, "Elite", new Color(0.85f, 0.15f, 0.15f));
        PlaceMarker(new List<Vector2Int> { bossSpot }, "Boss", new Color(0.60f, 0.20f, 0.90f));
        PlaceMarker(new List<Vector2Int> { extractionSpot }, "Extraction", new Color(0.15f, 0.80f, 0.30f));
        PlaceMarker(new List<Vector2Int> { hideoutSpot }, "Hideout", new Color(1f, 0.82f, 0.25f));
        Debug.Log("[MapContentPlacer] 内容已摆放：事件已挂格，精英/Boss/撤离点/藏身处为占位标记。" +
                  "撤离点/Boss/藏身处 系统尚未实现，目前仅做位置预留。");
    }

    [ContextMenu("Clear Map Content Markers")]
    public void ClearMarkers()
    {
        Transform mp = transform.Find(MarkerParentName);
        if (mp != null) DestroyImmediate(mp.gameObject);
    }

    private void PlaceEvents()
    {
        GameObject map1 = GameObject.Find("Map1");
        if (map1 == null)
        {
            Debug.LogWarning("[MapContentPlacer] 未找到 Map1，事件未摆放。请先确认 Map1 容器存在。");
            return;
        }
        foreach (var e in events)
        {
            if (e.eventData == null) continue;
            GameObject tile = FindTile(map1, e.coord);
            if (tile == null)
            {
                Debug.LogWarning($"[MapContentPlacer] 未找到 Hex_{e.coord.x}_{e.coord.y}，跳过事件「{e.eventData.title}」");
                continue;
            }
            EventTile et = tile.GetComponent<EventTile>();
            if (et == null) et = tile.AddComponent<EventTile>();
            et.eventData = e.eventData;
            et.coord = e.coord;
            Debug.Log($"[MapContentPlacer] 事件「{e.eventData.title}」已挂到 Hex_{e.coord.x}_{e.coord.y}");
        }
    }

    private void PlaceMarker(List<Vector2Int> spots, string label, Color color)
    {
        if (spots == null || spots.Count == 0) return;
        GameObject map1 = GameObject.Find("Map1");
        if (map1 == null) return;

        Transform mp = transform.Find(MarkerParentName);
        if (mp == null)
        {
            mp = new GameObject(MarkerParentName).transform;
            mp.SetParent(transform, false);
        }

        foreach (var c in spots)
        {
            GameObject tile = FindTile(map1, c);
            Vector3 pos = tile != null ? tile.transform.position : Vector3.zero;
            GameObject m = GameObject.CreatePrimitive(PrimitiveType.Cube);
            m.name = label + "_" + c.x + "_" + c.y;
            m.transform.position = new Vector3(pos.x, pos.y + 0.6f, pos.z);
            m.transform.localScale = new Vector3(0.6f, 0.25f, 0.6f);
            m.transform.SetParent(mp, true);

            Collider col = m.GetComponent<Collider>();
            if (col != null) DestroyImmediate(col);

            Renderer r = m.GetComponent<Renderer>();
            if (r != null)
            {
                Material mat = new Material(Shader.Find("Standard"));
                mat.color = color;
                mat.EnableKeyword("_EMISSION");
                mat.SetColor("_EmissionColor", color);
                r.sharedMaterial = mat;
            }
        }
    }

    private static GameObject FindTile(GameObject map1, Vector2Int coord)
    {
        foreach (Transform child in map1.transform)
        {
            if (child.name == $"Hex_{coord.x}_{coord.y}") return child.gameObject;
        }
        return null;
    }
}

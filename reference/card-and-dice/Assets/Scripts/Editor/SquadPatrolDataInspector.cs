// =============================================================================
// 小队巡逻 Inspector：拖入小队模板 + 路径点（格子编号 12_16）+ 队速/往返循环
// ★2026-09-12 掉落配置：本巡逻成员表非空 = 覆盖模板；空 = 继承小队模板（design §3/§4）
// =============================================================================
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;

[CustomEditor(typeof(SquadPatrolData))]
public class SquadPatrolDataInspector : Editor
{
    public override void OnInspectorGUI()
    {
        serializedObject.Update();
        DrawPropertiesExcluding(serializedObject, "patrolWaypoints", "dropConfig");
        serializedObject.ApplyModifiedProperties();

        var patrol = (SquadPatrolData)target;
        DrawWaypointList(patrol);

        if (patrol.squad != null && patrol.squad.units != null)
        {
            EditorGUILayout.LabelField($"模板成员 {patrol.squad.units.Count} 名 · 编队 {patrol.squad.formation}");
        }

        EditorGUILayout.HelpBox(
            "请把本资产保存在 Assets/Data/SquadPatrols。开局会扫描该文件夹，按第一路径点自动生成，不必在场景里挂东西。\n" +
            "同一小队模板可复制多份巡逻、改路径，就会在地图多处出现。\n" +
            "掉落配置：默认继承小队模板（正式图随机遭遇也走模板）；本巡逻想不同就在下方「开始覆盖」。",
            MessageType.Info);

        DrawDropSection(patrol);
    }

    // ------------------------------------------------------------------
    // 掉落配置（design 2026-09-12 §3/§4）
    // ------------------------------------------------------------------
    static void DrawDropSection(SquadPatrolData patrol)
    {
        if (patrol.dropConfig == null) patrol.dropConfig = new SquadDropConfig();
        bool hasOwn = patrol.dropConfig.members != null && patrol.dropConfig.members.Count > 0;
        EnemySquadData squad = patrol.squad;
        SquadDropConfig template = squad != null ? squad.dropConfig : null;

        if (!hasOwn)
        {
            EditorGUILayout.Space(10);
            EditorGUILayout.LabelField("掉落配置（继承小队模板）", EditorStyles.boldLabel);

            if (squad == null)
            {
                EditorGUILayout.HelpBox("未拖入小队模板 → 没有可继承的掉落配置（先在上方拖入模板）。", MessageType.Warning);
                return;
            }

            EditorGUILayout.HelpBox(
                $"本巡逻未覆盖 → 当前生效 = 小队模板「{squad.squadName}」的掉落配置（正式图随机遭遇也用它）。",
                MessageType.Info);
            SquadDropConfigDrawer.DrawReadOnlySummary(template, squad);

            EditorGUILayout.BeginHorizontal();
            if (GUILayout.Button("复制模板配置到本巡逻（开始覆盖）", GUILayout.Height(24)))
            {
                Undo.RecordObject(patrol, "复制模板掉落配置");
                patrol.dropConfig = SquadDropConfig.CloneForSnapshot(template, -1);
                if (patrol.dropConfig == null) patrol.dropConfig = new SquadDropConfig();
                SquadDropConfig.SyncMembers(patrol.dropConfig, squad);
                EditorUtility.SetDirty(patrol);
            }
            if (GUILayout.Button("选中小队模板资产", GUILayout.Width(140), GUILayout.Height(24)))
            {
                EditorGUIUtility.PingObject(squad);
            }
            EditorGUILayout.EndHorizontal();
            return;
        }

        SquadDropConfigDrawer.Draw(patrol, patrol.dropConfig, squad, "掉落配置（本巡逻覆盖模板）");

        if (GUILayout.Button("清空成员表（回到继承模板）", GUILayout.Height(22)))
        {
            Undo.RecordObject(patrol, "清空巡逻掉落覆盖");
            patrol.dropConfig.members.Clear();
            EditorUtility.SetDirty(patrol);
        }
    }

    // ------------------------------------------------------------------
    // 路径点（原有逻辑，不动）
    // ------------------------------------------------------------------
    static void DrawWaypointList(SquadPatrolData patrol)
    {
        EditorGUILayout.Space(8);
        EditorGUILayout.LabelField("巡逻路径点", EditorStyles.boldLabel);

        if (patrol.patrolWaypoints == null) patrol.patrolWaypoints = new List<Vector2Int>();

        for (int i = 0; i < patrol.patrolWaypoints.Count; i++)
        {
            EditorGUILayout.BeginHorizontal();
            EditorGUILayout.LabelField(i == 0 ? "出生" : $"点 {i + 1}", GUILayout.Width(40));
            string edit = EditorGUILayout.TextField(HexCoord.FormatCell(patrol.patrolWaypoints[i]));
            if (HexCoord.TryParseCell(edit, out Vector2Int parsed) && parsed != patrol.patrolWaypoints[i])
            {
                Undo.RecordObject(patrol, "改路径点");
                patrol.patrolWaypoints[i] = parsed;
                EditorUtility.SetDirty(patrol);
            }
            if (GUILayout.Button("上", GUILayout.Width(28)) && i > 0)
            {
                Undo.RecordObject(patrol, "移动路径点");
                Vector2Int tmp = patrol.patrolWaypoints[i - 1];
                patrol.patrolWaypoints[i - 1] = patrol.patrolWaypoints[i];
                patrol.patrolWaypoints[i] = tmp;
                EditorUtility.SetDirty(patrol);
            }
            if (GUILayout.Button("下", GUILayout.Width(28)) && i < patrol.patrolWaypoints.Count - 1)
            {
                Undo.RecordObject(patrol, "移动路径点");
                Vector2Int tmp = patrol.patrolWaypoints[i + 1];
                patrol.patrolWaypoints[i + 1] = patrol.patrolWaypoints[i];
                patrol.patrolWaypoints[i] = tmp;
                EditorUtility.SetDirty(patrol);
            }
            if (GUILayout.Button("删", GUILayout.Width(28)))
            {
                Undo.RecordObject(patrol, "删除路径点");
                patrol.patrolWaypoints.RemoveAt(i);
                EditorUtility.SetDirty(patrol);
                EditorGUILayout.EndHorizontal();
                break;
            }
            EditorGUILayout.EndHorizontal();
        }

        if (GUILayout.Button("新建路径点", GUILayout.Height(24)))
        {
            Undo.RecordObject(patrol, "新建路径点");
            Vector2Int copy = patrol.patrolWaypoints.Count > 0
                ? patrol.patrolWaypoints[patrol.patrolWaypoints.Count - 1]
                : new Vector2Int(12, 16);
            patrol.patrolWaypoints.Add(copy);
            EditorUtility.SetDirty(patrol);
        }
    }
}

// =============================================================================
// 小队 Inspector：编成员/覆盖/站位 + ★2026-09-12 掉落配置（模板默认值）
// =============================================================================
using UnityEditor;
using UnityEngine;

[CustomEditor(typeof(EnemySquadData))]
public class EnemySquadDataInspector : Editor
{
    private const float PreviewSize = 240f;
    private const float CellSize = 26f;
    private const int PreviewRange = 4;

    public override void OnInspectorGUI()
    {
        serializedObject.Update();
        DrawPropertiesExcluding(serializedObject, "dropConfig");
        serializedObject.ApplyModifiedProperties();

        var squad = (EnemySquadData)target;

        EditorGUILayout.Space(8);
        EditorGUILayout.LabelField("编队摆位", EditorStyles.boldLabel);

        if (GUILayout.Button("按编队模板自动填 hexOffset", GUILayout.Height(28)))
        {
            Undo.RecordObject(squad, "应用编队模板");
            SpawnResolver.ApplyFormation(squad);
            EditorUtility.SetDirty(squad);
            Debug.Log($"[EnemySquadDataInspector] 小队「{squad.squadName}」已按 {squad.formation} 模板自动摆位");
        }

        EditorGUILayout.HelpBox(
            "这里只配置小队成员和相对站位。\n" +
            "要在地图上出生并巡逻：Create → 卡牌与骰子/小队巡逻，存到 Assets/Data/SquadPatrols，把本小队拖进去再填路径点。同一小队可以拖进多条巡逻。\n" +
            "掉落配置：本面板是**默认值**（正式图随机遭遇用它）；某条巡逻想不同，在巡逻面板「开始覆盖」。",
            MessageType.Info);

        if (squad.dropConfig == null) squad.dropConfig = new SquadDropConfig();
        SquadDropConfigDrawer.Draw(squad, squad.dropConfig, squad,
            "掉落配置（本小队默认；正式图随机遭遇用它，巡逻可覆盖）");

        DrawHexPreview(squad);
    }

    private void DrawHexPreview(EnemySquadData squad)
    {
        Rect rect = GUILayoutUtility.GetRect(PreviewSize, PreviewSize, GUILayout.ExpandWidth(true));
        EditorGUI.DrawRect(rect, new Color(0.13f, 0.13f, 0.15f));

        Vector2 center = rect.center;

        for (int x = -PreviewRange; x <= PreviewRange; x++)
        {
            for (int y = -PreviewRange; y <= PreviewRange; y++)
            {
                Vector2 pos = HexToPixel(center, new Vector2Int(x, y));
                if (IsInRect(pos, rect))
                {
                    EditorGUI.DrawRect(new Rect(pos.x - 1.5f, pos.y - 1.5f, 3f, 3f), new Color(0.35f, 0.35f, 0.4f));
                }
            }
        }

        EditorGUI.DrawRect(new Rect(center.x - 7, center.y - 1, 14, 2), new Color(1f, 0.9f, 0.3f));
        EditorGUI.DrawRect(new Rect(center.x - 1, center.y - 7, 2, 14), new Color(1f, 0.9f, 0.3f));

        if (squad.units != null)
        {
            for (int i = 0; i < squad.units.Count; i++)
            {
                var unit = squad.units[i];
                if (unit == null) continue;

                Vector2 pos = HexToPixel(center, unit.hexOffset);
                if (!IsInRect(pos, rect)) continue;

                Color color = RoleColor(unit.EffectiveRole);
                Rect cellRect = new Rect(pos.x - 9, pos.y - 9, 18, 18);
                EditorGUI.DrawRect(cellRect, color);

                var oldBg = GUI.backgroundColor;
                GUI.backgroundColor = color * 0.55f;
                GUI.Label(cellRect, (i + 1).ToString(), new GUIStyle(EditorStyles.miniLabel)
                {
                    alignment = TextAnchor.MiddleCenter,
                    normal = { textColor = Color.white }
                });
                GUI.backgroundColor = oldBg;
            }
        }

        var legend = new Rect(rect.x + 6, rect.y + 4, rect.width - 12, 16);
        GUI.Label(legend,
            "◆ 锚点    ■ 先锋(紫) 近卫(红) 狙击(蓝) 术士(粉) 辅助(绿)    数字 = 成员序号",
            new GUIStyle(EditorStyles.miniLabel) { normal = { textColor = new Color(0.8f, 0.8f, 0.8f) } });
    }

    private Vector2 HexToPixel(Vector2 center, Vector2Int offset)
    {
        float px = center.x + offset.x * CellSize * 0.87f;
        float py = center.y - (offset.y + ((offset.x & 1) == 1 ? 0.5f : 0f)) * CellSize;
        return new Vector2(px, py);
    }

    private bool IsInRect(Vector2 pos, Rect rect)
    {
        return pos.x > rect.xMin + 12 && pos.x < rect.xMax - 12 &&
               pos.y > rect.yMin + 12 && pos.y < rect.yMax - 12;
    }

    private Color RoleColor(CombatRole role)
    {
        switch (role)
        {
            case CombatRole.先锋: return new Color(0.75f, 0.30f, 0.90f);
            case CombatRole.近卫: return new Color(0.85f, 0.30f, 0.28f);
            case CombatRole.狙击: return new Color(0.30f, 0.55f, 0.90f);
            case CombatRole.术士: return new Color(0.90f, 0.35f, 0.65f);
            case CombatRole.辅助: return new Color(0.35f, 0.75f, 0.40f);
            default: return new Color(0.60f, 0.60f, 0.60f);
        }
    }
}

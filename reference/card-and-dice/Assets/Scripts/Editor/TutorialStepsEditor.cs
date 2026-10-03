// =============================================================================
// 模块：Tutorial - TutorialSteps 自定义 Inspector（策划/本人手填教学拍的「通用编辑器」v2）
// 用途：在 Inspector 里逐条展开教学拍，填 文案/触发/解除/焦点/框位置 + v2 激活动作
//      （UI 显隐、骰子·能量、挂起回合、限定格、禁行格、运镜、出牌、伏击接管、操作锁、检查点）。
//       含「载入当前教程（42 拍）」/「清空全部」按钮，以及创建资产的菜单项。
// ★2026-09-14 用户要求：删掉旧口径按钮——「载入新手教程全流程（20 拍）」（文案过时，
//   方法体其实早已是 S1–S42 的 42 拍）与「旧版 7 拍」（废弃的 7 拍垂直切片，已随之删除）。
// =============================================================================
using UnityEngine;
using UnityEditor;
using Tutorial;

[CustomEditor(typeof(TutorialSteps))]
public class TutorialStepsEditor : Editor
{
    private Vector2 _scroll;
    private bool[] _folds;

    public override void OnInspectorGUI()
    {
        var cfg = (TutorialSteps)target;
        serializedObject.Update();

        EditorGUILayout.HelpBox(
            "教学拍配置：每条 = 一个提示卡 + 一组激活动作。\n" +
            "· 触发条件 = 何时出现　· 解除条件 = 何时收起并推进下一拍\n" +
            "· 焦点 = 黄铜圈指向哪（可用 UICanvas 节点路径圈任意 UI）\n" +
            "· 激活动作 = 激活本拍时执行：UI 显隐 / 骰子·能量 / 挂起回合 / 限定格·禁行格 / 运镜 / 牌库 / 操作锁 / 检查点\n" +
            "运行时由 TutorialDirector 读取本配置驱动，改完即生效（停掉再 Play 生效）。",
            MessageType.Info);

        EditorGUILayout.BeginHorizontal();
        if (GUILayout.Button("载入当前教程（42拍）")) { cfg.LoadDefaultsTutorial(); EditorUtility.SetDirty(cfg); }
        if (GUILayout.Button("清空全部")) { cfg.steps.Clear(); EditorUtility.SetDirty(cfg); }
        EditorGUILayout.EndHorizontal();

        var stepsProp = serializedObject.FindProperty("steps");
        EditorGUILayout.LabelField($"拍数量：{stepsProp.arraySize}", EditorStyles.boldLabel);

        if (_folds == null || _folds.Length != stepsProp.arraySize)
            _folds = new bool[stepsProp.arraySize];

        _scroll = EditorGUILayout.BeginScrollView(_scroll);
        for (int i = 0; i < stepsProp.arraySize; i++)
        {
            var el = stepsProp.GetArrayElementAtIndex(i);
            DrawStep(i, el, stepsProp);
        }
        EditorGUILayout.EndScrollView();

        if (GUILayout.Button("＋ 新增一条拍"))
        {
            stepsProp.InsertArrayElementAtIndex(stepsProp.arraySize);
            var neu = stepsProp.GetArrayElementAtIndex(stepsProp.arraySize - 1);
            neu.FindPropertyRelative("title").stringValue = "标题";
            EditorUtility.SetDirty(cfg);
        }

        serializedObject.ApplyModifiedProperties();
    }

    private void DrawStep(int index, SerializedProperty el, SerializedProperty stepsProp)
    {
        var idProp = el.FindPropertyRelative("id");
        string id = idProp.stringValue;
        if (index >= _folds.Length) return;
        _folds[index] = EditorGUILayout.Foldout(_folds[index], $"#{index}  {id}", true);
        if (!_folds[index]) return;

        EditorGUI.indentLevel++;

        EditorGUILayout.PropertyField(idProp, new GUIContent("id（调试用）"));

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("触发 / 解除", EditorStyles.miniBoldLabel);
        EditorGUILayout.PropertyField(el.FindPropertyRelative("trigger"), new GUIContent("触发条件"));
        var trigger = (TutorialTrigger)el.FindPropertyRelative("trigger").enumValueIndex;
        if (trigger == TutorialTrigger.ArriveCell)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("triggerCell"), new GUIContent("触发格 (x,y)"));
        if (trigger == TutorialTrigger.ArriveAnyCell || trigger == TutorialTrigger.CardPlayed || trigger == TutorialTrigger.PlayerTurnStarted)
        {
            if (trigger == TutorialTrigger.ArriveAnyCell)
                DrawCellList(el.FindPropertyRelative("cellList"), "触发格列表（任一）");
            EditorGUILayout.PropertyField(el.FindPropertyRelative("cardName"), new GUIContent("卡名过滤（空=任意）"));
        }

        EditorGUILayout.PropertyField(el.FindPropertyRelative("release"), new GUIContent("解除条件"));
        var release = (TutorialRelease)el.FindPropertyRelative("release").enumValueIndex;
        if (release == TutorialRelease.ArriveCell)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("releaseCell"), new GUIContent("解除格 (x,y)"));
        if (release == TutorialRelease.CardPlayed)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("cardName"), new GUIContent("卡名过滤（空=任意）"));

        EditorGUILayout.PropertyField(el.FindPropertyRelative("showConfirm"), new GUIContent("显示「知道了」按钮"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("completesTutorial"), new GUIContent("解除时标记教学完成"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("silent"), new GUIContent("纯动作拍（不弹卡）"));

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("文案", EditorStyles.miniBoldLabel);
        EditorGUILayout.PropertyField(el.FindPropertyRelative("title"), new GUIContent("标题"));
        var bodyProp = el.FindPropertyRelative("body");
        // 只画一个正文输入框：多行 TextArea 本身支持回车换行（之前误加了一个 PropertyField，导致正文出现两个框）
        EditorGUILayout.LabelField(new GUIContent("正文（可直接回车换行）"), EditorStyles.miniLabel);
        bodyProp.stringValue = EditorGUILayout.TextArea(bodyProp.stringValue, GUILayout.MinHeight(48f));

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("焦点 / 框位置", EditorStyles.miniBoldLabel);
        EditorGUILayout.PropertyField(el.FindPropertyRelative("focus"), new GUIContent("高亮焦点"));
        var focus = (TutorialFocus)el.FindPropertyRelative("focus").enumValueIndex;
        if (focus == TutorialFocus.MapCell)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("focusCell"), new GUIContent("焦点格 (x,y)"));
        if (focus == TutorialFocus.ScreenRect)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("focusScreenRect"), new GUIContent("屏幕矩形 (x,y,w,h)"));
        if (focus == TutorialFocus.HudPath)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("focusUiPath"), new GUIContent("UI 路径（UICanvas 下）"));
        if (focus == TutorialFocus.NamedEnemy)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("focusEnemyName"), new GUIContent("敌人名字包含"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("focus2UiPath"), new GUIContent("第二焦点 UI 路径（可选）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("focus2EnemyName"), new GUIContent("第二焦点：敌人名字包含（空=回落主焦点）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("drawLeader"), new GUIContent("画引线指向焦点"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("boxAnchor"), new GUIContent("提示框角点"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("boxOffset"), new GUIContent("提示框偏移 (px)"));

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("激活动作（激活本拍时依次执行）", EditorStyles.miniBoldLabel);
        DrawStringList(el.FindPropertyRelative("uiHide"), "隐藏 UI（名字/前缀/路径）");
        DrawStringList(el.FindPropertyRelative("uiShow"), "显示 UI（名字/前缀/路径）");
        EditorGUILayout.PropertyField(el.FindPropertyRelative("setDice"), new GUIContent("骰池设为 N（-1=不改）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("setDicePerTurn"), new GUIContent("每回合骰数设为 N（-1=不改）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("setEnergy"), new GUIContent("能量设为 N（-1=不改）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("startPlayerTurn"), new GUIContent("开始新玩家回合（解除挂起）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("autoEndTurn"), new GUIContent("自动结束回合（挂起式）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("cameraFly"), new GUIContent("运镜到焦点格+恢复缩放"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("deckSingleCard"), new GUIContent("牌库换成仅一张卡"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("restoreDeck"), new GUIContent("恢复完整牌库"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("completeAmbush"), new GUIContent("完成接管伏击→进战斗"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("lockInput"), new GUIContent("锁操作（移动/出牌/结束回合）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("restrictMove"), new GUIContent("限定只能移动到某格"));
        if (el.FindPropertyRelative("restrictMove").boolValue)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("allowedCell"), new GUIContent("允许格 (x,y)"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("blockCells"), new GUIContent("把下方格列表染红禁行"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("watchCheckpoints"), new GUIContent("本拍监听检查点（踏入截停）"));
        if (trigger == TutorialTrigger.ArriveAnyCell || el.FindPropertyRelative("blockCells").boolValue
            || el.FindPropertyRelative("watchCheckpoints").boolValue)
            DrawCellList(el.FindPropertyRelative("cellList"), "格列表");
        if (trigger == TutorialTrigger.CardPlayed || release == TutorialRelease.CardPlayed)
            EditorGUILayout.PropertyField(el.FindPropertyRelative("cardName"), new GUIContent("卡名过滤（空=任意）"));

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("展示与门禁（★2026-09-14 补齐控件）", EditorStyles.miniBoldLabel);
        EditorGUILayout.PropertyField(el.FindPropertyRelative("dimScreen"), new GUIContent("压暗屏幕（模态界面拍设 false）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("unloadAllCards"), new GUIContent("激活时卸空所有卡（装填教学）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("enableReroll"), new GUIContent("解锁重投（教程期门禁开关）"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("removeBonfire"), new GUIContent("激活时移除全部篝火"));
        EditorGUILayout.PropertyField(el.FindPropertyRelative("requireAllEnemiesDefeated"), new GUIContent("门槛：场上无存活敌人才出现（S42）"));

        EditorGUI.indentLevel--;

        EditorGUILayout.BeginHorizontal();
        if (GUILayout.Button("↑")) { if (index > 0) { stepsProp.MoveArrayElement(index, index - 1); } }
        if (GUILayout.Button("↓")) { if (index < stepsProp.arraySize - 1) { stepsProp.MoveArrayElement(index, index + 1); } }
        if (GUILayout.Button("删除")) { stepsProp.DeleteArrayElementAtIndex(index); }
        EditorGUILayout.EndHorizontal();
        EditorGUILayout.Space();
    }

    private static void DrawCellList(SerializedProperty listProp, string label)
    {
        EditorGUILayout.PropertyField(listProp, new GUIContent(label), true);
    }

    private static void DrawStringList(SerializedProperty listProp, string label)
    {
        EditorGUILayout.PropertyField(listProp, new GUIContent(label), true);
    }

    // -------- 菜单：创建并填充新手教程全流程的资产配置 --------
    [MenuItem("Tools/教程/创建 TutorialSteps 配置")]
    public static void CreateTutorialStepsAsset()
    {
        var dir = "Assets/Resources/Tutorial";
        if (!AssetDatabase.IsValidFolder(dir)) AssetDatabase.CreateFolder("Assets/Resources", "Tutorial");

        var path = $"{dir}/TutorialSteps.asset";
        var existing = AssetDatabase.LoadAssetAtPath<TutorialSteps>(path);
        TutorialSteps cfg;
        if (existing != null)
        {
            cfg = existing;
            cfg.LoadDefaultsTutorial();
        }
        else
        {
            cfg = ScriptableObject.CreateInstance<TutorialSteps>();
            cfg.LoadDefaultsTutorial();
            AssetDatabase.CreateAsset(cfg, path);
        }
        AssetDatabase.SaveAssets();
        EditorUtility.FocusProjectWindow();
        Selection.activeObject = cfg;
        Debug.Log($"[Tutorial] 已创建/刷新配置：{path}（新手教程全流程 S1–S42 共 42 拍）");
    }
}

// =============================================================================
// 编辑器工具：CardDeckManager 自定义编辑器
// 用途：在 Inspector 中可视化配置初始牌组，无需写代码。
//       支持：拖入 CardData SO、调整数量、一键加载默认牌组、查看花色统计。
// 使用：选中挂有 CardDeckManager 的 GameObject，Inspector 自动显示自定义面板。
// =============================================================================
using UnityEngine;
using UnityEditor;
using System.Collections.Generic;
using TMPro;

[CustomEditor(typeof(CardDeckManager))]
public class CardDeckManagerEditor : Editor
{
    private CardDeckManager _manager;
    private SerializedProperty _entriesProp;
    private bool _showStats = true;

    private void OnEnable()
    {
        _manager = (CardDeckManager)target;
        _entriesProp = serializedObject.FindProperty("initialDeckEntries");
    }

    public override void OnInspectorGUI()
    {
        serializedObject.Update();

        EditorGUILayout.Space(8);
        EditorGUILayout.LabelField("《代号：卡牌与骰子》牌组配置", EditorStyles.boldLabel);
        EditorGUILayout.HelpBox(
            "在下方列表中配置初始牌组：\n" +
            "1. 点击「+」添加空条目\n" +
            "2. 将 CardData SO 拖入「Card Data」槽\n" +
            "3. 调整数量（1~20）\n" +
            "运行时 CardDeckManager 会自动实例化 Card 运行时实例。",
            MessageType.Info);

        EditorGUILayout.Space(4);

        // ---- 牌组列表 ----
        DrawDeckEntriesList();

        EditorGUILayout.Space(8);

        // ---- 快捷操作 ----
        DrawQuickActions();

        EditorGUILayout.Space(8);

        // ---- 统计信息 ----
        if (_showStats)
        {
            DrawDeckStats();
        }

        serializedObject.ApplyModifiedProperties();
    }

    private void DrawDeckEntriesList()
    {
        EditorGUILayout.LabelField("初始牌组（点击条目展开编辑）", EditorStyles.boldLabel);
        EditorGUI.indentLevel++;

        if (_entriesProp.arraySize == 0)
        {
            EditorGUILayout.HelpBox("牌组为空！点击下方「+ 添加卡牌」或「一键加载 M5a 默认牌组」", MessageType.Warning);
        }

        for (int i = 0; i < _entriesProp.arraySize; i++)
        {
            DrawDeckEntry(i);
        }

        EditorGUI.indentLevel--;

        EditorGUILayout.Space(4);

        // 添加按钮
        EditorGUILayout.BeginHorizontal();
        if (GUILayout.Button("+ 添加卡牌", GUILayout.Height(28)))
        {
            _entriesProp.InsertArrayElementAtIndex(_entriesProp.arraySize);
            serializedObject.ApplyModifiedProperties();
        }

        // 清空按钮
        if (GUILayout.Button("清空牌组", GUILayout.Height(28)))
        {
            if (EditorUtility.DisplayDialog("确认", "确定要清空整个牌组吗？", "清空", "取消"))
            {
                _entriesProp.ClearArray();
                serializedObject.ApplyModifiedProperties();
            }
        }
        EditorGUILayout.EndHorizontal();
    }

    private void DrawDeckEntry(int index)
    {
        SerializedProperty entry = _entriesProp.GetArrayElementAtIndex(index);
        SerializedProperty cardDataProp = entry.FindPropertyRelative("cardData");
        SerializedProperty countProp = entry.FindPropertyRelative("count");

        EditorGUILayout.BeginVertical(EditorStyles.helpBox);

        // 标题行：卡牌名 + 删除按钮
        EditorGUILayout.BeginHorizontal();
        CardData cardData = (CardData)cardDataProp.objectReferenceValue;
        string cardName = cardData != null ? cardData.cardName : "(未设置)";
        EditorGUILayout.LabelField($"[{index + 1}] {cardName}", EditorStyles.boldLabel, GUILayout.MinWidth(200));

        GUILayout.FlexibleSpace();

        if (GUILayout.Button("×", GUILayout.Width(24), GUILayout.Height(20)))
        {
            _entriesProp.DeleteArrayElementAtIndex(index);
            serializedObject.ApplyModifiedProperties();
            return;
        }
        EditorGUILayout.EndHorizontal();

        // CardData 引用槽
        EditorGUILayout.PropertyField(cardDataProp, new GUIContent("Card Data"));

        // 数量
        EditorGUILayout.PropertyField(countProp, new GUIContent("数量"));

        // 如果已配置卡牌，显示预览信息
        if (cardData != null)
        {
            EditorGUILayout.LabelField($"  能量: {cardData.energyCost}  |  射程: {cardData.rangeConfig.baseValue}  |  稀有度: {cardData.rarity}",
                EditorStyles.miniLabel);

            // 花色预览
            string suits = GetSuitPreview(cardData);
            if (!string.IsNullOrEmpty(suits))
            {
                EditorGUILayout.LabelField($"  花色: {suits}", EditorStyles.miniLabel);
            }
        }

        EditorGUILayout.EndVertical();
        EditorGUILayout.Space(2);
    }

    private void DrawQuickActions()
    {
        EditorGUILayout.LabelField("快捷操作", EditorStyles.boldLabel);
        EditorGUILayout.BeginHorizontal();

        if (GUILayout.Button("🎯 加载 M5a 默认牌组 (10张)", GUILayout.Height(32)))
        {
            LoadM5aDefaultDeck();
        }

        if (GUILayout.Button("🔄 刷新运行时牌组", GUILayout.Height(32)))
        {
            RefreshRuntimeDeck();
        }

        EditorGUILayout.EndHorizontal();
    }

    private void DrawDeckStats()
    {
        EditorGUILayout.LabelField("牌组统计", EditorStyles.boldLabel);

        var entries = GetEntries();
        int totalCards = 0;
        int strength = 0, agility = 0, intelligence = 0, constitution = 0;

        foreach (var entry in entries)
        {
            if (entry == null || entry.cardData == null) continue;
            int cnt = entry.count;
            totalCards += cnt;

            if (entry.cardData.suit1 == SuitOption.红色) strength += cnt;
            if (entry.cardData.suit2 == SuitOption.红色) strength += cnt;
            if (entry.cardData.suit3 == SuitOption.红色) strength += cnt;
            if (entry.cardData.suit4 == SuitOption.红色) strength += cnt;

            if (entry.cardData.suit1 == SuitOption.绿色) agility += cnt;
            if (entry.cardData.suit2 == SuitOption.绿色) agility += cnt;
            if (entry.cardData.suit3 == SuitOption.绿色) agility += cnt;
            if (entry.cardData.suit4 == SuitOption.绿色) agility += cnt;

            if (entry.cardData.suit1 == SuitOption.蓝色) intelligence += cnt;
            if (entry.cardData.suit2 == SuitOption.蓝色) intelligence += cnt;
            if (entry.cardData.suit3 == SuitOption.蓝色) intelligence += cnt;
            if (entry.cardData.suit4 == SuitOption.蓝色) intelligence += cnt;

            if (entry.cardData.suit1 == SuitOption.黄色) constitution += cnt;
            if (entry.cardData.suit2 == SuitOption.黄色) constitution += cnt;
            if (entry.cardData.suit3 == SuitOption.黄色) constitution += cnt;
            if (entry.cardData.suit4 == SuitOption.黄色) constitution += cnt;
        }

        EditorGUILayout.BeginVertical(EditorStyles.helpBox);
        EditorGUILayout.LabelField($"总卡牌数: {totalCards} 张  |  种类: {entries.Count}", EditorStyles.boldLabel);
        EditorGUILayout.LabelField($"力量(红): {strength}  |  敏捷(绿): {agility}  |  智力(蓝): {intelligence}  |  体质(黄): {constitution}");
        EditorGUILayout.EndVertical();
    }

    private string GetSuitPreview(CardData data)
    {
        var suits = new List<string>();
        if (data.suit1 != SuitOption.无) suits.Add(data.suit1.ToString());
        if (data.suit2 != SuitOption.无) suits.Add(data.suit2.ToString());
        if (data.suit3 != SuitOption.无) suits.Add(data.suit3.ToString());
        if (data.suit4 != SuitOption.无) suits.Add(data.suit4.ToString());
        return string.Join(", ", suits);
    }

    private List<CardDeckManager.DeckEntry> GetEntries()
    {
        var result = new List<CardDeckManager.DeckEntry>();
        for (int i = 0; i < _entriesProp.arraySize; i++)
        {
            var entry = _entriesProp.GetArrayElementAtIndex(i);
            var cardData = (CardData)entry.FindPropertyRelative("cardData").objectReferenceValue;
            int count = entry.FindPropertyRelative("count").intValue;
            result.Add(new CardDeckManager.DeckEntry { cardData = cardData, count = count });
        }
        return result;
    }

    private void LoadM5aDefaultDeck()
    {
        string[] defaultCardNames = { "防御", "直刺", "纵劈", "横斩", "断筋" };
        int[] defaultCounts = { 4, 2, 2, 1, 1 };

        _entriesProp.ClearArray();

        // 尝试从 Resources 或 Assets/Data/Cards 加载 CardData
        for (int i = 0; i < defaultCardNames.Length; i++)
        {
            string cardName = defaultCardNames[i];
            CardData cardData = FindCardData(cardName);

            int idx = _entriesProp.arraySize;
            _entriesProp.InsertArrayElementAtIndex(idx);
            var entry = _entriesProp.GetArrayElementAtIndex(idx);
            entry.FindPropertyRelative("cardData").objectReferenceValue = cardData;
            entry.FindPropertyRelative("count").intValue = defaultCounts[i];
        }

        serializedObject.ApplyModifiedProperties();

        // 验证
        int total = 0;
        for (int i = 0; i < _entriesProp.arraySize; i++)
        {
            var entry = _entriesProp.GetArrayElementAtIndex(i);
            var cd = (CardData)entry.FindPropertyRelative("cardData").objectReferenceValue;
            int cnt = entry.FindPropertyRelative("count").intValue;
            total += cnt;

            if (cd == null)
            {
                Debug.LogWarning($"[CardDeckManagerEditor] 卡牌「{defaultCardNames[i]}」的 CardData 未找到，请先在 Assets/Data/Cards/ 创建对应的 .asset 文件");
            }
        }

        Debug.Log($"[CardDeckManagerEditor] M5a 默认牌组已加载：{total} 张卡牌", _manager);
    }

    private CardData FindCardData(string cardName)
    {
        // 方式1: 从 Resources.Load
        CardData data = Resources.Load<CardData>("Data/Cards/" + cardName);
        if (data != null) return data;

        // 方式2: 从 AssetDatabase 查找
        string[] guids = AssetDatabase.FindAssets(cardName + " t:CardData");
        foreach (string guid in guids)
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            data = AssetDatabase.LoadAssetAtPath<CardData>(path);
            if (data != null && data.cardName == cardName)
                return data;
        }

        // 方式3: 模糊匹配（以防 cardName 包含在路径中）
        guids = AssetDatabase.FindAssets("t:CardData");
        foreach (string guid in guids)
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            data = AssetDatabase.LoadAssetAtPath<CardData>(path);
            if (data != null && data.cardName.Contains(cardName))
                return data;
        }

        return null;
    }

    private void RefreshRuntimeDeck()
    {
        if (Application.isPlaying)
        {
            _manager.RefreshRuntimeDeck();
            Debug.Log("[CardDeckManagerEditor] 运行时牌组已刷新", _manager);
        }
        else
        {
            Debug.LogWarning("[CardDeckManagerEditor] 仅在 Play 模式下可刷新运行时牌组");
        }
    }
}

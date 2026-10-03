// =============================================================================
// 模块：探索系统 - 事件编辑器 EventEditorWindow（完整版）
// 用途：Unity EditorWindow 可视化创建/编辑/删除 EventData 资产，
//       并支持一键把事件放置到场景地图格子（自动挂 EventTile 组件）。
//       类比卡牌（CardDeckManagerEditor）/敌人（EnemySquadDataInspector）的编辑模式。
// 设计依据：《设计增补_探索系统_v2.md》§7.5 事件模板 / D15 通用弹窗
// 打开方式：菜单 CardDice → 事件编辑器
// 资产位置：Assets/Data/Events/（不存在时自动创建）
//
// 功能一览（v2 完整版，2026-08-26）：
//   1. 左侧事件列表：新建 / 删除（带确认）/ 点击选择
//   2. 右侧编辑：基本信息（ID/标题/描述/一次性）+ 选项列表（正序显示、上下移、安全删除）
//   3. 放置到地图：选中场景格子 → 一键挂 EventTile 并赋值；列出已放置格子，点击定位
//   4. 编辑即 SetDirty，保存按钮统一写入磁盘
// =============================================================================
#if UNITY_EDITOR
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

public class EventEditorWindow : EditorWindow
{
    private const string AssetFolder = "Assets/Data/Events";

    private List<EventData> events = new List<EventData>();
    private EventData selected;
    private Vector2 leftScroll;
    private Vector2 rightScroll;

    // 选项列表的待执行操作（IMGUI 循环中不能直接增删，先记录循环后执行）
    private int pendingRemoveOption = -1;
    private int pendingMoveOption = -1;
    private int pendingMoveDir = 0;

    [MenuItem("CardDice/事件编辑器")]
    public static void Open()
    {
        GetWindow<EventEditorWindow>("事件编辑器");
    }

    private void OnEnable()
    {
        RefreshList();
    }

    /// <summary>场景里选中对象变化时重绘（放置区需要反映当前选中格子）</summary>
    private void OnSelectionChange()
    {
        Repaint();
    }

    /// <summary>扫描事件资产目录，刷新左侧列表</summary>
    private void RefreshList()
    {
        events.Clear();
        if (!Directory.Exists(AssetFolder)) return;

        string[] guids = AssetDatabase.FindAssets("t:EventData", new[] { AssetFolder });
        foreach (string guid in guids)
        {
            EventData data = AssetDatabase.LoadAssetAtPath<EventData>(AssetDatabase.GUIDToAssetPath(guid));
            if (data != null) events.Add(data);
        }
        events = events.OrderBy(e => e.title).ToList();
    }

    private void OnGUI()
    {
        EditorGUILayout.BeginHorizontal();

        DrawLeftPanel();
        DrawRightPanel();

        EditorGUILayout.EndHorizontal();

        // 循环外执行选项的删除/移动（避免破坏 IMGUI 布局）
        if (pendingRemoveOption >= 0)
        {
            if (selected != null && selected.options.Count > 1)
                selected.options.RemoveAt(pendingRemoveOption);
            EditorUtility.SetDirty(selected);
            pendingRemoveOption = -1;
        }
        if (pendingMoveOption >= 0 && selected != null)
        {
            int target = pendingMoveOption + pendingMoveDir;
            if (target >= 0 && target < selected.options.Count)
            {
                EventOption opt = selected.options[pendingMoveOption];
                selected.options.RemoveAt(pendingMoveOption);
                selected.options.Insert(target, opt);
                EditorUtility.SetDirty(selected);
            }
            pendingMoveOption = -1;
        }
    }

    // ------------------------------------------------------------------
    // 左侧：事件列表 + 新建 + 删除
    // ------------------------------------------------------------------

    private void DrawLeftPanel()
    {
        EditorGUILayout.BeginVertical(GUILayout.Width(240));

        EditorGUILayout.LabelField("事件列表（点击选择）", EditorStyles.boldLabel);

        if (GUILayout.Button("＋ 新建事件", GUILayout.Height(28)))
        {
            CreateNewEvent();
        }

        leftScroll = EditorGUILayout.BeginScrollView(leftScroll);
        foreach (EventData data in events)
        {
            EditorGUILayout.BeginHorizontal();

            GUIStyle style = new GUIStyle("Button");
            if (data == selected) style.fontStyle = FontStyle.Bold;

            string label = string.IsNullOrEmpty(data.title) ? data.name : data.title;
            if (!data.once) label += "（可重复）";

            if (GUILayout.Button(label, style, GUILayout.Height(24)))
            {
                selected = data;
                GUI.FocusControl(null); // 切换选择时提交未失焦的输入框
            }
            if (GUILayout.Button("×", GUILayout.Width(22)))
            {
                DeleteEvent(data);
            }

            EditorGUILayout.EndHorizontal();
        }
        EditorGUILayout.EndScrollView();

        EditorGUILayout.EndVertical();
    }

    /// <summary>新建事件资产（自动命名：事件_序号）</summary>
    private void CreateNewEvent()
    {
        if (!Directory.Exists(AssetFolder))
        {
            Directory.CreateDirectory(AssetFolder);
            AssetDatabase.Refresh();
        }

        string path = AssetDatabase.GenerateUniqueAssetPath($"{AssetFolder}/事件_{events.Count + 1}.asset");
        EventData data = CreateInstance<EventData>();
        data.eventId = Path.GetFileNameWithoutExtension(path);
        data.options = new List<EventOption> { new EventOption() };
        AssetDatabase.CreateAsset(data, path);

        RefreshList();
        selected = data;
        EditorUtility.SetDirty(data);
        AssetDatabase.SaveAssets();
    }

    /// <summary>删除事件资产（带确认；若场景里有格子引用会一并提示数量）</summary>
    private void DeleteEvent(EventData data)
    {
        // 统计场景中引用此事件的格子数，删除前提醒
        EventTile[] tiles = Object.FindObjectsOfType<EventTile>(true);
        int refCount = tiles.Count(t => t.eventData == data);

        string msg = $"确定删除事件「{data.title}」？\n资产文件将被移除，不可撤销。";
        if (refCount > 0)
            msg += $"\n\n注意：当前场景有 {refCount} 个格子的 EventTile 正在引用它（组件会残留，需手动移除）。";

        if (!EditorUtility.DisplayDialog("删除事件", msg, "删除", "取消")) return;

        string path = AssetDatabase.GetAssetPath(data);
        if (selected == data) selected = null;
        AssetDatabase.DeleteAsset(path);
        RefreshList();
        Debug.Log($"[事件编辑器] 已删除事件资产：{path}");
    }

    // ------------------------------------------------------------------
    // 右侧：选中事件编辑
    // ------------------------------------------------------------------

    private void DrawRightPanel()
    {
        EditorGUILayout.BeginVertical();
        EditorGUILayout.Space(4);

        if (selected == null)
        {
            EditorGUILayout.HelpBox("← 左侧选择或新建一个事件", MessageType.Info);
            EditorGUILayout.EndVertical();
            return;
        }

        rightScroll = EditorGUILayout.BeginScrollView(rightScroll);

        // -------- 基本信息（改动即标脏） --------
        EditorGUI.BeginChangeCheck();

        EditorGUILayout.LabelField("基本信息", EditorStyles.boldLabel);
        selected.eventId = EditorGUILayout.TextField("事件 ID", selected.eventId);
        selected.title = EditorGUILayout.TextField("标题", selected.title);
        EditorGUILayout.LabelField("描述（多行）");
        selected.description = EditorGUILayout.TextArea(selected.description, GUILayout.Height(70));
        selected.once = EditorGUILayout.Toggle("一次性事件", selected.once);
        selected.biomeTag = (BiomeTag)EditorGUILayout.EnumPopup(
            new GUIContent("群系标签", "投放分池用（design §3.1）：通用 = 草坡人味池；群系 = 本群系专属池"),
            selected.biomeTag);

        EditorGUILayout.Space(8);

        // -------- 选项列表（正序显示） --------
        EditorGUILayout.LabelField($"选项（{selected.options.Count} 个，按钮自上而下排列）", EditorStyles.boldLabel);
        for (int i = 0; i < selected.options.Count; i++)
        {
            DrawOption(i);
        }
        if (GUILayout.Button("＋ 添加选项"))
        {
            selected.options.Add(new EventOption());
            EditorUtility.SetDirty(selected);
        }

        if (EditorGUI.EndChangeCheck())
        {
            EditorUtility.SetDirty(selected);
        }

        EditorGUILayout.Space(12);

        // -------- 放置到地图 --------
        DrawPlacementSection();

        EditorGUILayout.Space(12);

        // -------- 保存 --------
        if (GUILayout.Button("保存（写入资产）", GUILayout.Height(32)))
        {
            EditorUtility.SetDirty(selected);
            AssetDatabase.SaveAssets();
            RefreshList();
            Debug.Log($"[事件编辑器] 已保存「{selected.title}」");
        }

        EditorGUILayout.EndScrollView();
        EditorGUILayout.EndVertical();
    }

    /// <summary>单个选项的编辑块（正序索引）</summary>
    private void DrawOption(int index)
    {
        EventOption option = selected.options[index];

        EditorGUILayout.BeginVertical("HelpBox");
        EditorGUILayout.BeginHorizontal();
        EditorGUILayout.LabelField($"选项 {index + 1}", EditorStyles.boldLabel, GUILayout.Width(60));

        // 上移/下移（记录待执行，循环外统一处理）
        GUI.enabled = index > 0;
        if (GUILayout.Button("↑", GUILayout.Width(24))) { pendingMoveOption = index; pendingMoveDir = -1; }
        GUI.enabled = index < selected.options.Count - 1;
        if (GUILayout.Button("↓", GUILayout.Width(24))) { pendingMoveOption = index; pendingMoveDir = 1; }
        GUI.enabled = true;

        GUILayout.FlexibleSpace();
        if (GUILayout.Button("删除", GUILayout.Width(44)) && selected.options.Count > 1)
        {
            pendingRemoveOption = index;
        }
        EditorGUILayout.EndHorizontal();

        option.optionText = EditorGUILayout.TextField("按钮文案", option.optionText);
        option.checkType = (CheckType)EditorGUILayout.EnumPopup("鉴定类型", option.checkType);

        if (option.checkType != CheckType.无)
        {
            option.difficulty = EditorGUILayout.IntField("目标难度 D", option.difficulty);
        }

        // -------- 代价（design §3.2：付物换利；确认的那一刻扣，鉴定失败不退） --------
        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField($"代价（{option.costs.Count} 条，不足时按钮置灰）");
        for (int c = option.costs.Count - 1; c >= 0; c--)
        {
            EventItemCost cost = option.costs[c];
            EditorGUILayout.BeginVertical("HelpBox");

            EditorGUILayout.BeginHorizontal();
            cost.anyOfType = EditorGUILayout.Toggle("按类型计", cost.anyOfType, GUILayout.Width(110));
            if (cost.anyOfType)
            {
                cost.type = (ItemType)EditorGUILayout.EnumPopup(cost.type, GUILayout.Width(90));
                cost.item = null; // 二选一：按类型时清掉指定物品，避免口径歧义
            }
            cost.amount = EditorGUILayout.IntField(cost.amount, GUILayout.Width(50));
            GUILayout.Label("个", GUILayout.Width(18));
            if (GUILayout.Button("×", GUILayout.Width(24)))
            {
                option.costs.RemoveAt(c);
                EditorGUILayout.EndHorizontal();
                EditorGUILayout.EndVertical();
                continue;
            }
            EditorGUILayout.EndHorizontal();

            if (!cost.anyOfType)
            {
                cost.item = (ItemData)EditorGUILayout.ObjectField("指定物品", cost.item, typeof(ItemData), false);
            }

            EditorGUILayout.EndVertical();
        }
        if (GUILayout.Button("＋ 添加代价"))
        {
            option.costs.Add(new EventItemCost { anyOfType = true, type = ItemType.材料, amount = 1 });
        }

        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField("成功结果");
        DrawResult(option.success);
        EditorGUILayout.Space(4);

        if (option.checkType != CheckType.无)
        {
            EditorGUILayout.LabelField("失败结果");
            DrawResult(option.failure);
        }

        EditorGUILayout.EndVertical();
        EditorGUILayout.Space(4);
    }

    /// <summary>单个结果（成功/失败）的编辑块</summary>
    private void DrawResult(EventResult result)
    {
        if (result == null) return;

        result.flavorText = EditorGUILayout.TextArea(result.flavorText, GUILayout.Height(40));
        EditorGUILayout.LabelField("结果文案");
        result.endEvent = EditorGUILayout.Toggle(
            new GUIContent("结束后移除事件", "此结果结算后隐藏地图标记、本局不再触发（宝箱消失）；不勾则事件保留可再次尝试"),
            result.endEvent);

        result.hpChange = EditorGUILayout.IntField("HP 变化", result.hpChange);
        result.energyChange = EditorGUILayout.IntField("能量变化", result.energyChange);
        result.diceChange = EditorGUILayout.IntField("骰子变化", result.diceChange);

        // 获得卡牌：简易列表（ObjectField 逐张添加/删除）
        EditorGUILayout.LabelField($"获得卡牌（{result.addCards.Count}）");
        for (int i = result.addCards.Count - 1; i >= 0; i--)
        {
            EditorGUILayout.BeginHorizontal();
            result.addCards[i] = (CardData)EditorGUILayout.ObjectField(result.addCards[i], typeof(CardData), false);
            if (GUILayout.Button("×", GUILayout.Width(24)))
            {
                result.addCards.RemoveAt(i);
            }
            EditorGUILayout.EndHorizontal();
        }
        CardData newCard = (CardData)EditorGUILayout.ObjectField("添加卡牌→", null, typeof(CardData), false);
        if (newCard != null) result.addCards.Add(newCard);

        // 获得物品：简易列表（ObjectField 逐条添加/删除/改数量；灵魂/容器数量保持 1）
        EditorGUILayout.LabelField($"获得物品（{result.addItems.Count}）");
        for (int i = result.addItems.Count - 1; i >= 0; i--)
        {
            EditorGUILayout.BeginHorizontal();
            result.addItems[i].item = (ItemData)EditorGUILayout.ObjectField(result.addItems[i].item, typeof(ItemData), false);
            result.addItems[i].amount = EditorGUILayout.IntField(result.addItems[i].amount, GUILayout.Width(40));
            if (GUILayout.Button("×", GUILayout.Width(24)))
            {
                result.addItems.RemoveAt(i);
            }
            EditorGUILayout.EndHorizontal();
        }
        ItemData newItem = (ItemData)EditorGUILayout.ObjectField("添加物品→", null, typeof(ItemData), false);
        if (newItem != null) result.addItems.Add(new EventItemReward { item = newItem, amount = 1 });

        // -------- 荒野事件扩展（design §3.3–§3.6） --------
        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField("扩展", EditorStyles.miniBoldLabel);

        result.salvageChange = EditorGUILayout.IntField(
            new GUIContent("物资变化", "直入局外账 MetaWallet（正加负扣），不走背包"),
            result.salvageChange);

        result.triggerCombat = EditorGUILayout.Toggle(
            new GUIContent("进战", "本结果结算后进战（失败遇袭，design §3.3）；进战结果按防刷铁律②一律结束事件"),
            result.triggerCombat);
        if (result.triggerCombat)
        {
            EditorGUI.indentLevel++;
            result.combatEnemyCount = EditorGUILayout.IntSlider(
                new GUIContent("敌人只数", "按玩家所在地格群系抽普通成员"),
                result.combatEnemyCount, 1, 2);
            EditorGUI.indentLevel--;
        }

        result.removeCards = EditorGUILayout.IntField(
            new GUIContent("删牌数", "结算后需玩家选 N 张牌删除（0 = 不触发）。候选 = 完整牌库，战术槽内的卡也能删"),
            result.removeCards);
        result.duplicateCards = EditorGUILayout.IntField(
            new GUIContent("复制牌数", "结算后需玩家选 N 张牌复制（0 = 不触发）"),
            result.duplicateCards);

        result.grantBuff = (TempBuffData)EditorGUILayout.ObjectField(
            new GUIContent("授予临时强化", "下场战斗生效、战后即耗（design §3.5）"),
            result.grantBuff, typeof(TempBuffData), false);
    }

    // ------------------------------------------------------------------
    // 放置到地图：选中场景格子 → 挂 EventTile；列出已放置格子
    // ------------------------------------------------------------------

    private void DrawPlacementSection()
    {
        EditorGUILayout.LabelField("放置到地图", EditorStyles.boldLabel);

        // 当前场景中引用此事件的格子列表
        EventTile[] tiles = Object.FindObjectsOfType<EventTile>(true);
        List<EventTile> placed = tiles.Where(t => t.eventData == selected).ToList();

        EditorGUILayout.HelpBox(
            placed.Count > 0
                ? $"当前场景已放置 {placed.Count} 个格子触发本事件。"
                : "在场景中选中一个地图格子（含 HexTile），点下方按钮放置本事件。",
            MessageType.None);

        foreach (EventTile tile in placed)
        {
            EditorGUILayout.BeginHorizontal("HelpBox");

            string coordLabel = tile.coord != Vector2Int.zero ? $"({tile.coord.x},{tile.coord.y})" : "(坐标运行时自动)";
            if (GUILayout.Button($"{tile.gameObject.name} {coordLabel}", "MiniButton"))
            {
                // 点击定位：Hierarchy 高亮选中该格子
                Selection.activeGameObject = tile.gameObject;
                EditorGUIUtility.PingObject(tile.gameObject);
            }
            if (GUILayout.Button("移除", GUILayout.Width(44)))
            {
                Undo.DestroyObjectImmediate(tile);
                EditorSceneManagerMarkDirty();
            }
            EditorGUILayout.EndHorizontal();
        }

        // 放置：当前 Hierarchy 选中的对象
        GameObject target = Selection.activeGameObject;
        if (target == null)
        {
            EditorGUILayout.HelpBox("请先在 Hierarchy / Scene 视图中选中一个地图格子。", MessageType.Info);
            return;
        }

        HexTile hex = target.GetComponent<HexTile>();
        if (hex == null)
        {
            EditorGUILayout.HelpBox($"「{target.name}」没有 HexTile 组件，不是地图格子。\n请选中 Hex_x_y 命名的格子对象。", MessageType.Warning);
            return;
        }

        EventTile existing = target.GetComponent<EventTile>();
        string btnLabel = existing == null
            ? $"放置到「{target.name}」"
            : existing.eventData == selected
                ? $"「{target.name}」已放置本事件（重复点击无操作）"
                : $"替换「{target.name}」上的事件（当前：{existing.eventData?.title ?? "空"}）";

        GUI.enabled = !(existing != null && existing.eventData == selected);
        if (GUILayout.Button(btnLabel, GUILayout.Height(26)))
        {
            if (existing == null)
            {
                existing = Undo.AddComponent<EventTile>(target);
            }
            else
            {
                Undo.RecordObject(existing, "替换事件");
            }
            existing.eventData = selected;
            existing.coord = hex.coordinates; // 编辑期直接写入坐标（运行时 Awake 也会兜底自动取）
            EditorUtility.SetDirty(existing);
            EditorSceneManagerMarkDirty();
            Debug.Log($"[事件编辑器] 事件「{selected.title}」已放置到 {target.name} {existing.coord}");
        }
        GUI.enabled = true;
    }

    /// <summary>标记当前场景为已修改（保存场景时提示）</summary>
    private void EditorSceneManagerMarkDirty()
    {
        if (Selection.activeGameObject != null)
            UnityEditor.SceneManagement.EditorSceneManager.MarkSceneDirty(
                Selection.activeGameObject.scene);
        Repaint();
    }
}
#endif

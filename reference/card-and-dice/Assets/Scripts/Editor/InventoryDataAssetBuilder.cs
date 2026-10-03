// =============================================================================
// 编辑器工具：背包系统数据资产构建器（一次性工具，菜单 Tools/背包/1|2|3）
// 用途：三步建齐背包系统的数据资产与场景连线，避免逐个手点 Inspector
//   1. 创建物品资产（Assets/Data/Items/）+ 临时劣质骰（Assets/Data/Dice/）
//   2. 给哥布林/史莱姆填默认灵魂（掉落明细改在 SquadPatrolData 面板配置）
//   3. 场景挂载 InventoryManager 并连线，关闭 DiceInventoryManager 的 Demo 无限库存
// 惯例参照：Assets/Scripts/Editor/EventPopupPrefabBuilder.cs
// 幂等：已存在的资产只更新字段、不重复创建（可反复执行）
// =============================================================================
#if UNITY_EDITOR
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class InventoryDataAssetBuilder
{
    const string ItemDir  = "Assets/Data/Items";
    const string DiceDir  = "Assets/Data/Dice";
    const string EnemyDir = "Assets/Data/Enemies";

    const string TempDiceName = "临时劣质骰";

    /// <summary>批量创建时 HHmmss 会撞号，加批次内序号保证唯一（项目 ID 惯例：前缀_时间戳）</summary>
    static int _idCounter;

    // ------------------------------------------------------------------
    // 步骤 1：物品资产
    // ------------------------------------------------------------------
    [MenuItem("Tools/背包/1. 创建物品资产")]
    public static void BuildItemAssets()
    {
        EnsureFolder(ItemDir);
        _idCounter = 0;

        // ★2026-09-16 族材三件套：铁屑/兽骨 的 desc 与 WildernessContent.json 的 materials 表逐字对齐
        //   （两处都写、必须同步，否则重跑本菜单会把荒野构建器写的 desc 盖回旧文案）。
        //   黏液已不是任何族的族材，只留给教程史莱姆。
        CreateMaterial("铁屑",   "从刀口箭头上崩下来的金属碎屑。");
        CreateMaterial("兽骨",   "狼窝里啃剩的骨头，能做骰子坯料。");
        CreateMaterial("黏液",   "史莱姆的凝胶，药水基底。");

        CreateConsumable("回血药水",   "喝下恢复 5 点生命。", ConsumableEffect.回血5);
        CreateConsumable("回能量药水", "喝下恢复 2 点能量。", ConsumableEffect.回能量2);

        int diceItemCount = CreateDiceItems();

        CreateSoul("哥布林的灵魂", "哥布林死后残留在魂灯里的绿焰。");
        CreateSoul("史莱姆的灵魂", "史莱姆死后残留在魂灯里的蓝焰。");

        CreateContainer("魂灯", "装着灵魂的提灯。最多容纳 10 条灵魂。");

        CreateTempInferiorDice();

        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log($"[InventoryBuilder] 步骤 1 完成：{ItemDir} 下物品资产就绪（骰子物品 {diceItemCount} 个），" +
                  $"{DiceDir}/{TempDiceName}.asset 已建");
    }

    static ItemData CreateMaterial(string itemName, string desc)
    {
        ItemData item = LoadOrCreate<ItemData>($"{ItemDir}/{itemName}.asset");
        Touch(item, itemName, desc, ItemType.材料, 20);
        return item;
    }

    static ItemData CreateConsumable(string itemName, string desc, ConsumableEffect effect)
    {
        ItemData item = LoadOrCreate<ItemData>($"{ItemDir}/{itemName}.asset");
        Touch(item, itemName, desc, ItemType.消耗品, 1);
        item.useEffect = effect;
        EditorUtility.SetDirty(item);
        return item;
    }

    static ItemData CreateSoul(string itemName, string desc)
    {
        ItemData item = LoadOrCreate<ItemData>($"{ItemDir}/{itemName}.asset");
        Touch(item, itemName, desc, ItemType.灵魂, 1);
        return item;
    }

    static ItemData CreateContainer(string itemName, string desc)
    {
        ItemData item = LoadOrCreate<ItemData>($"{ItemDir}/{itemName}.asset");
        Touch(item, itemName, desc, ItemType.容器, 1);
        return item;
    }

    static void Touch(ItemData item, string itemName, string desc, ItemType type, int stackLimit)
    {
        if (string.IsNullOrEmpty(item.itemID)) item.itemID = NewID("ITEM");
        item.itemName = itemName;
        item.description = desc;
        item.type = type;
        item.stackLimit = stackLimit;
        EditorUtility.SetDirty(item);
    }

    /// <summary>
    /// 为 Assets/Data/Dice/ 下每个 DiceData 建一个对应物品（spec §2 diceRef）。
    /// 临时劣质骰跳过——它是保底骰，不可搜刮/带回，永远不入背包（策划案 §138）。
    /// </summary>
    static int CreateDiceItems()
    {
        int created = 0;
        foreach (string guid in AssetDatabase.FindAssets("t:DiceData", new[] { DiceDir }))
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            DiceData dice = AssetDatabase.LoadAssetAtPath<DiceData>(path);
            if (dice == null || dice.diceName == TempDiceName) continue;

            ItemData item = LoadOrCreate<ItemData>($"{ItemDir}/{dice.diceName}.asset");
            Touch(item, dice.diceName, "战斗骰子，装填卡牌时从骰子分区扣除。", ItemType.骰子, 100);
            item.diceRef = dice;
            EditorUtility.SetDirty(item);
            created++;
        }
        return created;
    }

    /// <summary>保底骰：破旧骰子是 d4{1,2,3,4}（均值 2.5），保底骰取 d4{1,1,2,2}（均值 1.5）。</summary>
    static void CreateTempInferiorDice()
    {
        DiceData dice = LoadOrCreate<DiceData>($"{DiceDir}/{TempDiceName}.asset");
        if (string.IsNullOrEmpty(dice.diceID)) dice.diceID = "DICE_TEMP_INFERIOR";
        dice.diceName = TempDiceName;
        dice.description = "战斗骰子耗尽时的保底骰：性能明显较差，不可搜刮、不可带回、不可成长。";
        dice.quality = DiceQuality.普通;
        dice.diceValues = new[] { 1, 1, 2, 2 };
        EditorUtility.SetDirty(dice);
    }

    // ------------------------------------------------------------------
    // 步骤 2：敌人默认灵魂引用（掉落明细在巡逻资产面板配置）
    // ------------------------------------------------------------------
    [MenuItem("Tools/背包/2. 填敌人默认灵魂")]
    public static void WireEnemyDrops()
    {
        ItemData goblinSoul = AssetDatabase.LoadAssetAtPath<ItemData>($"{ItemDir}/哥布林的灵魂.asset");
        ItemData slimeSoul  = AssetDatabase.LoadAssetAtPath<ItemData>($"{ItemDir}/史莱姆的灵魂.asset");

        if (goblinSoul == null)
        {
            Debug.LogError("[InventoryBuilder] 物品资产缺失，请先执行 Tools/背包/1. 创建物品资产");
            return;
        }

        WireEnemy("哥布林", goblinSoul);
        WireEnemy("史莱姆", slimeSoul);

        AssetDatabase.SaveAssets();
    }

    static void WireEnemy(string enemyName, ItemData soul)
    {
        string path = $"{EnemyDir}/{enemyName}.asset";
        EnemyData enemy = AssetDatabase.LoadAssetAtPath<EnemyData>(path);
        if (enemy == null)
        {
            Debug.LogWarning($"[InventoryBuilder] 找不到敌人资产：{path}（跳过）");
            return;
        }

        // 「沿用预设」的默认魂；掉落明细已迁到 SquadPatrolData.dropConfig（spec 2026-09-12）
        enemy.soulItem = soul;

        EditorUtility.SetDirty(enemy);
        Debug.Log($"[InventoryBuilder] {enemyName}：默认灵魂 {(soul != null ? soul.itemName : "无")}" +
                  "（掉落明细在巡逻资产面板配置）");
    }

    // ------------------------------------------------------------------
    // 步骤 3：场景挂载与连线
    // ------------------------------------------------------------------
    [MenuItem("Tools/背包/3. 场景挂载与连线")]
    public static void WireScene()
    {
        DiceInventoryManager diceMgr = Object.FindObjectOfType<DiceInventoryManager>();
        if (diceMgr == null)
        {
            Debug.LogError("[InventoryBuilder] 当前场景找不到 DiceInventoryManager —— 请先打开 Assets/Scenes/MainScene.unity");
            return;
        }

        GameObject host = diceMgr.gameObject;              // 与 DiceInventoryManager 同处（SetUp/GameManager）
        InventoryManager mgr = host.GetComponent<InventoryManager>();
        if (mgr == null) mgr = host.AddComponent<InventoryManager>();

        var so = new SerializedObject(mgr);
        so.FindProperty("soulLanternItem").objectReferenceValue =
            AssetDatabase.LoadAssetAtPath<ItemData>($"{ItemDir}/魂灯.asset");

        SerializedProperty diceItemsProp = so.FindProperty("diceItems");
        diceItemsProp.ClearArray();
        int diceIndex = 0;
        foreach (ItemData item in LoadAllItems())
        {
            if (item.type != ItemType.骰子) continue;
            diceItemsProp.GetArrayElementAtIndex(diceItemsProp.arraySize++).objectReferenceValue = item;
            if (diceIndex == 0) _firstDiceItem = item;
            diceIndex++;
        }

        // 初始物资 [已配平 2026-09-09 · Monte Carlo 20,000 局]：给 120 颗战斗骰 + 1 瓶回血药水。
        // 口径：每回合净耗 4–5 枚（用户定），单场战斗净耗均值 23.1 枚（P10=14 / P90=32）。
        // 120 枚 = 约 5 场标准战斗的量 + 缓冲；骰子补充改由 SquadPatrolData 的掉落配置控制（2026-09-12）。
        // 对齐搜打撤弹药范式（Tarkov：带 4–6 个 30 发弹匣 = 120–180 发进 raid，正常 raid 打不完）：
        //   弹药的张力不在「够不够打死眼前这个敌人」，而在「够不够我打到撤离点」。
        // 曲线：前 3 场 0% 耗尽 / 第 5 场 4.1% / 第 8 场 95% / 中位耗尽场次 7。
        // 若实测远征典型 3–4 场 → 降到 90；若 8 场以上 → 升到 150。
        // 骰子给 0 也不会瘫痪——有无限临时劣质骰兜底（策划案 §126/§176）。
        SerializedProperty startProp = so.FindProperty("startingItems");
        startProp.ClearArray();
        AddStarting(startProp, _firstDiceItem, 120);
        AddStarting(startProp, AssetDatabase.LoadAssetAtPath<ItemData>($"{ItemDir}/回血药水.asset"), 1);
        so.ApplyModifiedPropertiesWithoutUndo();

        // 关闭 Demo 无限库存（三个方法的实装在 Task 7；实装前行为与 true 时一致）
        var diceSo = new SerializedObject(diceMgr);
        SerializedProperty unlimited = diceSo.FindProperty("_unlimitedForDemo");
        if (unlimited != null)
        {
            unlimited.boolValue = false;
            diceSo.ApplyModifiedPropertiesWithoutUndo();
        }

        // ★2026-09-13 补漏：保底骰（临时劣质骰）连线。
        //   此前这一步只关了无限库存、**没连 tempInferiorDice** → 战斗骰耗尽时兜底骰为 null，
        //   卡牌骰槽算出来是空（DiceValues 恒为 -1），"自动装填临时劣质骰"整条链路是断的。
        SerializedProperty tempProp = diceSo.FindProperty("tempInferiorDice");
        if (tempProp != null)
        {
            tempProp.objectReferenceValue = AssetDatabase.LoadAssetAtPath<DiceData>($"{DiceDir}/{TempDiceName}.asset");
            diceSo.ApplyModifiedPropertiesWithoutUndo();
            EditorUtility.SetDirty(diceMgr);
            Debug.Log($"[InventoryBuilder] 保底骰已连线：{TempDiceName}");
        }
        else
        {
            Debug.LogWarning("[InventoryBuilder] 找不到 tempInferiorDice 字段，保底骰未连线");
        }

        // 遗物袋生成器：与 InventoryManager 同宿主（Task 13）
        CorpseSpawner spawner = host.GetComponent<CorpseSpawner>();
        if (spawner == null) spawner = host.AddComponent<CorpseSpawner>();

        var spawnerSo = new SerializedObject(spawner);
        SerializedProperty fallbackProp = spawnerSo.FindProperty("fallbackMaterialItem");
        if (fallbackProp != null)
        {
            fallbackProp.objectReferenceValue = AssetDatabase.LoadAssetAtPath<ItemData>($"{ItemDir}/铁屑.asset");
        }
        spawnerSo.ApplyModifiedPropertiesWithoutUndo();
        EditorUtility.SetDirty(spawner);

        EditorUtility.SetDirty(mgr);
        EditorSceneManager.MarkSceneDirty(host.scene);
        EditorSceneManager.SaveOpenScenes();

        Debug.Log($"[InventoryBuilder] 步骤 3 完成：InventoryManager + CorpseSpawner 挂在 {GetPath(host.transform)}，" +
                  $"骰子物品 {diceIndex} 个、初始物资 {startProp.arraySize} 条、_unlimitedForDemo=false、" +
                  $"阵亡回收材料={(spawner.fallbackMaterialItem != null ? spawner.fallbackMaterialItem.itemName : "null")}");
    }

    // ------------------------------------------------------------------
    // 步骤 4：挂载 UI 组件到 UICanvas
    // ------------------------------------------------------------------
    /// <summary>
    /// 背包系列 UI 组件一律挂 UICanvas（惯例同 EnemyRosterPanel：「挂在 UICanvas 上即可，Awake 自动建面板」）。
    /// 后续任务在此追加一行：Task 10 DeckUI / LoadoutUI、Task 16 LootPopupUI、Task 18 BattleSettlementUI。
    /// </summary>
    [MenuItem("Tools/背包/4. 挂载 UI 组件到 UICanvas")]
    public static void MountUIComponents()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            Debug.LogError("[InventoryBuilder] 当前场景找不到 UICanvas（请先打开 Assets/Scenes/MainScene.unity）");
            return;
        }

        Mount<InventoryUI>(canvas);
        Mount<SoulLanternUI>(canvas);
        Mount<DiceHud>(canvas);
        Mount<TopRightButtonBar>(canvas);
        Mount<CardPackUI>(canvas);
        Mount<SettingsUI>(canvas);
        Mount<LoadoutUI>(canvas);     // Task 10/11 装填视图（运行期 Awake 自挂载，此处编辑态也挂上）
        Mount<LootPopupUI>(canvas);   // Task 14 遗物袋搜刮弹窗
        Mount<BattleSettlementUI>(canvas); // Task 18/19/20 战后结算主弹窗

        EditorSceneManager.MarkSceneDirty(canvas.scene);
        EditorSceneManager.SaveOpenScenes();
        Debug.Log("[InventoryBuilder] 步骤 4 完成：背包 UI 组件已挂到 UICanvas（含 背包/魂灯/骰子HUD/右上栏/卡包/设置）");
    }

    static void Mount<T>(GameObject canvas) where T : Component
    {
        if (canvas.GetComponent<T>() != null) return;      // 幂等：已挂过就跳过
        canvas.AddComponent<T>();
        Debug.Log($"[InventoryBuilder] 已挂载 {typeof(T).Name} → UICanvas");
    }

    // ------------------------------------------------------------------
    // 步骤 5：构建 StatusBar HUD（三按钮 + 骰子计数列表）—— 编辑态落节点，不 Play 也可见
    // ------------------------------------------------------------------
    [MenuItem("Tools/背包/5. 构建 StatusBar HUD（按钮+骰子列表）")]
    public static void BuildStatusBarHud()
    {
        GameObject canvas = GameObject.Find("UICanvas");
        if (canvas == null)
        {
            Debug.LogError("[InventoryBuilder] 当前场景找不到 UICanvas（请先打开 Assets/Scenes/MainScene.unity）");
            return;
        }
        GameObject statusBar = GameObject.Find("UICanvas/StatusBar");
        if (statusBar == null)
        {
            Debug.LogError("[InventoryBuilder] 当前场景找不到 UICanvas/StatusBar");
            return;
        }

        // 三按钮挂 StatusBar 下（右对齐）
        StatusBarHud.BuildButtonBar(statusBar.transform);
        // 骰子计数列表挂 UICanvas 下（锚定 EnergyPointDisplay 左侧）
        StatusBarHud.BuildDiceList(canvas.transform);

        EditorSceneManager.MarkSceneDirty(canvas.scene);
        EditorSceneManager.SaveOpenScenes();
        Debug.Log("[InventoryBuilder] 步骤 5 完成：StatusBar HUD 已落节点（三按钮 → StatusBar 右侧；骰子列表 → EnergyPointDisplay 左侧）");
    }

    static ItemData _firstDiceItem;

    static void AddStarting(SerializedProperty array, ItemData item, int amount)
    {
        if (item == null || amount <= 0) return;
        SerializedProperty e = array.GetArrayElementAtIndex(array.arraySize++);
        e.FindPropertyRelative("item").objectReferenceValue = item;
        e.FindPropertyRelative("amount").intValue = amount;
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------
    static IEnumerable<ItemData> LoadAllItems()
    {
        foreach (string guid in AssetDatabase.FindAssets("t:ItemData", new[] { ItemDir }))
        {
            ItemData item = AssetDatabase.LoadAssetAtPath<ItemData>(AssetDatabase.GUIDToAssetPath(guid));
            if (item != null) yield return item;
        }
    }

    static T LoadOrCreate<T>(string path) where T : ScriptableObject
    {
        T asset = AssetDatabase.LoadAssetAtPath<T>(path);
        if (asset != null) return asset;
        asset = ScriptableObject.CreateInstance<T>();
        AssetDatabase.CreateAsset(asset, path);
        return asset;
    }

    static void EnsureFolder(string folder)
    {
        if (AssetDatabase.IsValidFolder(folder)) return;
        string parent = Path.GetDirectoryName(folder).Replace('\\', '/');
        string leaf = Path.GetFileName(folder);
        if (!AssetDatabase.IsValidFolder(parent)) EnsureFolder(parent);
        AssetDatabase.CreateFolder(parent, leaf);
    }

    static string NewID(string prefix)
    {
        return $"{prefix}_{System.DateTime.Now:HHmmss}_{++_idCounter}";
    }

    static string GetPath(Transform t)
    {
        string path = t.name;
        while (t.parent != null) { t = t.parent; path = t.name + "/" + path; }
        return path;
    }
}
#endif

// =============================================================================
// 编辑器工具：构建 UI 版手牌卡预制体（CardViewUI.prefab）
// 用途：手牌 HUD 需要屏幕空间（Canvas）的卡牌，而现有 CardView.prefab 是 3D 世界空间对象。
//       本脚本程序化生成一个 UI 版卡牌预制体，结构与 CardView.cs 的字段一一对应。
// 使用：菜单 Tools > Build Hand Card UI Prefab，生成到 Assets/Prefabs/CardViewUI.prefab
// 说明：CardEditor 场景继续用 3D 版 CardView.prefab，两套预制体互不干扰。
// =============================================================================
using UnityEngine;
using UnityEngine.UI;
using UnityEditor;
using TMPro;

public static class BuildHandCardUIPrefab
{
    private const string PrefabPath = "Assets/Prefabs/CardViewUI.prefab";

    [MenuItem("Tools/Build Hand Card UI Prefab")]
    public static void Build()
    {
        // ---------- 根节点 ----------
        GameObject root = new GameObject("CardViewUI");
        root.transform.SetParent(null, false);

        // RectTransform（UI 卡根节点）
        RectTransform rootRT = root.AddComponent<RectTransform>();
        rootRT.sizeDelta = new Vector2(110, 154);      // 手牌卡尺寸（竖版）

        // 卡面背景 Image（若无具体卡面图，则作为占位底色）
        Image face = root.AddComponent<Image>();
        face.sprite = LoadSprite("Assets/Materials/Battle/Cards/CardsBackground/card.png");
        face.color = new Color(1f, 1f, 1f, 1f);

        // 供 HandUIController 灰显用的 CanvasGroup
        CanvasGroup cg = root.AddComponent<CanvasGroup>();
        cg.alpha = 1f;
        cg.blocksRaycasts = true;

        // 花色管理器（与 CardView 同根，Awake 会自动 GetComponent 找到）
        CardColorChanger colorChanger = root.AddComponent<CardColorChanger>();
        SetColorIcons(colorChanger);

        // CardView 主脚本
        CardView cardView = root.AddComponent<CardView>();

        // ---------- 花色容器（Color1~4 放这里）----------
        GameObject color = new GameObject("Color");
        color.transform.SetParent(root.transform, false);
        RectTransform colorRT = color.AddComponent<RectTransform>();
        colorRT.anchoredPosition = Vector2.zero;

        // 四个花色图标（默认隐藏，SetCardData 后按花色显示）
        CreateSuitIcon(color.transform, "Color1", new Vector2(-34, 62), colorChanger);
        CreateSuitIcon(color.transform, "Color2", new Vector2(-16, 62), colorChanger);
        CreateSuitIcon(color.transform, "Color3", new Vector2(16, 62), colorChanger);
        CreateSuitIcon(color.transform, "Color4", new Vector2(34, 62), colorChanger);

        // ---------- 标题 ----------
        TextMeshProUGUI title = CreateText(root.transform, "Tittle", "名称", new Vector2(0, 52),
            new Vector2(90, 20), 18, LoadFont("Assets/TextMesh Pro/Fonts/msyhbd SDF.asset"),
            new Color(0.9f, 0.9f, 0.9f, 1f));

        // ---------- 描述 ----------
        TextMeshProUGUI desc = CreateText(root.transform, "Description", "描述", new Vector2(0, 0),
            new Vector2(92, 70), 12, LoadFont("Assets/TextMesh Pro/Fonts/msyh SDF.asset"),
            new Color(0.9f, 0.9f, 0.9f, 1f));

        // ---------- 能量消耗 ----------
        TextMeshProUGUI cost = CreateText(root.transform, "Cost", "1", new Vector2(-40, -62),
            new Vector2(24, 24), 20, LoadFont("Assets/TextMesh Pro/Resources/Fonts & Materials/LiberationSans SDF.asset"),
            new Color(1f, 0.85f, 0.4f, 1f));

        // ---------- 反序列化 CardView 的私有字段 ----------
        SerializedObject so = new SerializedObject(cardView);
        so.FindProperty("title").objectReferenceValue = title;
        so.FindProperty("description").objectReferenceValue = desc;
        so.FindProperty("mana").objectReferenceValue = cost;
        so.FindProperty("image").objectReferenceValue = face;
        so.FindProperty("imageSR").objectReferenceValue = null;
        so.FindProperty("cardColorChanger").objectReferenceValue = colorChanger;
        so.FindProperty("colorParent").objectReferenceValue = colorRT;
        so.ApplyModifiedPropertiesWithoutUndo();

        // ---------- 保存为预制体 ----------
        // 若已存在先删除旧文件，避免 guid 残留
        if (AssetDatabase.LoadAssetAtPath<GameObject>(PrefabPath) != null)
            AssetDatabase.DeleteAsset(PrefabPath);

        PrefabUtility.SaveAsPrefabAsset(root, PrefabPath);
        Object.DestroyImmediate(root);

        Debug.Log($"[BuildHandCardUI] 已生成 UI 手牌卡预制体: {PrefabPath}");
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
    }

    /// <summary>创建花色图标（Image）</summary>
    private static void CreateSuitIcon(Transform parent, string name, Vector2 pos, CardColorChanger colorChanger)
    {
        GameObject go = new GameObject(name);
        go.transform.SetParent(parent, false);
        RectTransform rt = go.AddComponent<RectTransform>();
        rt.sizeDelta = new Vector2(18, 18);
        rt.anchoredPosition = pos;
        Image img = go.AddComponent<Image>();
        img.color = Color.white;
        go.SetActive(false); // 默认隐藏，CardView.SetCardData 后按花色显示
    }

    /// <summary>设置 CardColorChanger 的四种花色图标精灵</summary>
    private static void SetColorIcons(CardColorChanger colorChanger)
    {
        SerializedObject so = new SerializedObject(colorChanger);
        so.FindProperty("redIcon").objectReferenceValue = LoadSprite("Assets/Materials/Battle/Cards/CardsBackground/red.png");
        so.FindProperty("greenIcon").objectReferenceValue = LoadSprite("Assets/Materials/Battle/Cards/CardsBackground/green.png");
        so.FindProperty("blueIcon").objectReferenceValue = LoadSprite("Assets/Materials/Battle/Cards/CardsBackground/blue.png");
        so.FindProperty("yellowIcon").objectReferenceValue = LoadSprite("Assets/Materials/Battle/Cards/CardsBackground/yellow.png");
        so.ApplyModifiedPropertiesWithoutUndo();
    }

    /// <summary>创建 UI 文本（TextMeshProUGUI）</summary>
    private static TextMeshProUGUI CreateText(Transform parent, string name, string text,
        Vector2 pos, Vector2 size, float fontSize, TMP_FontAsset font, Color color)
    {
        GameObject go = new GameObject(name);
        go.transform.SetParent(parent, false);
        RectTransform rt = go.AddComponent<RectTransform>();
        rt.sizeDelta = size;
        rt.anchoredPosition = pos;
        TextMeshProUGUI tmp = go.AddComponent<TextMeshProUGUI>();
        tmp.text = text;
        tmp.fontSize = fontSize;
        tmp.color = color;
        tmp.alignment = TextAlignmentOptions.Center;
        if (font != null) tmp.font = font;
        return tmp;
    }

    private static Sprite LoadSprite(string path)
    {
        return AssetDatabase.LoadAssetAtPath<Sprite>(path);
    }

    private static TMP_FontAsset LoadFont(string path)
    {
        return AssetDatabase.LoadAssetAtPath<TMP_FontAsset>(path);
    }
}
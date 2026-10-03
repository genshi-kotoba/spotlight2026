// =============================================================================
// 模块：Editor - PlayStartScene 编辑器按 Play 的启动场景
// 用途：把「按 Play 从哪张场景开始」钉死在藏身处 —— 和正式构建口径一致
//       （Build Settings level0 = HideoutScene）。
//
// 为什么需要：Unity 的 Play 按钮播的是**当前打开的场景**。在突袭场景（Tutorial /
//   FogTown）里改完东西直接按 Play 时，ExpeditionMapRouter.Route() 会照常烘图
//   （FogTownScene + useRandomWasteland → 当场生成一张随机荒野），体感就是
//   「打开游戏不在藏身处，直接进了地图」。本脚本把 Play 的起点固定到藏身处，
//   想测哪张图走藏身处「出击」或开发者面板（F9）跳转。
//
// 生效范围：仅编辑器 Play；构建不受影响（构建的 level0 本来就是 HideoutScene）。
// 想临时改成「从当前打开的场景直接 Play」：注释掉下面 SetScene 里那一行。
// =============================================================================
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

[InitializeOnLoad]
public static class PlayStartScene
{
    private const string HIDEOUT_SCENE_PATH = "Assets/Scenes/HideoutScene.unity";

    static PlayStartScene()
    {
        SceneAsset hideout = AssetDatabase.LoadAssetAtPath<SceneAsset>(HIDEOUT_SCENE_PATH);
        if (hideout == null)
        {
            Debug.LogWarning("[开机路由] 找不到 " + HIDEOUT_SCENE_PATH + "，Play 仍从当前打开的场景启动。");
            return;
        }

        // 每次域重载（进 Play / 脚本重编译）都重设一遍 —— 该值不随工程走，靠本行复现。
        EditorSceneManager.playModeStartScene = hideout;
    }
}

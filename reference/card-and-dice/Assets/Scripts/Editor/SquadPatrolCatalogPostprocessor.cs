// =============================================================================
// 往 Assets/Data/SquadPatrols 增删巡逻资产时，同步 Resources 目录供真机加载。
// =============================================================================
using UnityEditor;

public class SquadPatrolCatalogPostprocessor : AssetPostprocessor
{
    static void OnPostprocessAllAssets(
        string[] imported, string[] deleted, string[] moved, string[] movedFrom)
    {
        if (!TouchesPatrolFolder(imported) && !TouchesPatrolFolder(deleted)
            && !TouchesPatrolFolder(moved) && !TouchesPatrolFolder(movedFrom))
        {
            return;
        }
        SquadPatrolLoader.WriteResourcesCatalog();
    }

    static bool TouchesPatrolFolder(string[] paths)
    {
        if (paths == null) return false;
        foreach (string p in paths)
        {
            if (string.IsNullOrEmpty(p)) continue;
            if (p.Replace('\\', '/').StartsWith(SquadPatrolLoader.Folder)) return true;
        }
        return false;
    }
}

public static class SquadPatrolCatalogMenu
{
    [MenuItem("卡牌与骰子/刷新小队巡逻目录")]
    public static void Refresh()
    {
        SquadPatrolLoader.WriteResourcesCatalog();
        EditorUtility.DisplayDialog("小队巡逻", "已扫描 " + SquadPatrolLoader.Folder + " 并写入 Resources/SquadPatrolCatalog。", "确定");
    }
}

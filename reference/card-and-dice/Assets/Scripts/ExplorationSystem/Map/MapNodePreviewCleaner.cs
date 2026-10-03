// =============================================================================
// 模块：探索系统 - 节点预览标记清理器 MapNodePreviewCleaner
// 用途：MapLayoutBuilder 在编辑期会在地图上撒彩色方块（宝箱/篝火/事件位/敌人位），
//       纯粹是为了在编辑器里一眼看到节点分布。这些方块会随场景一起保存，
//       若不清理，玩家在游戏里也会看到一地彩色方块。
//       本组件在运行期最早期把它们删掉。
//
// 为什么不在 BuildPreviewMarkers 里用 #if UNITY_EDITOR 拦住：
//   拦的是「生成」，拦不住「已经存进场景文件的对象」。运行时清理才是可靠的。
// =============================================================================
using UnityEngine;

public class MapNodePreviewCleaner : MonoBehaviour
{
    private const string PreviewRootName = "NodePreviewMarkers";

    private void Awake()
    {
        int removed = 0;

        foreach (MapLayoutBuilder builder in FindObjectsOfType<MapLayoutBuilder>())
        {
            if (builder == null) continue;
            Transform root = builder.transform.Find(PreviewRootName);
            if (root == null) continue;
            Destroy(root.gameObject);
            removed++;
        }

        if (removed > 0)
        {
            Debug.Log($"[地图预览] 已清理 {removed} 组编辑期节点预览标记（它们只用于编辑器里看节点分布）");
        }
    }
}

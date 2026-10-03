// =============================================================================
// 模块：Meta - PendingCorpseSpawner 阵亡尸体回收器
// 用途：突袭场景开局时，把上一局玩家阵亡遗留的「尸体」在死亡格重新生成遗物袋，
//       玩家走到那格可搜刮回材料（参考逃离塔科夫的尸体回收循环）。
// 记录：MetaWallet 现在按种类存尸体材料（corpseMaterialStacks），但回收落地仍统一以
//       CorpseSpawner.fallbackMaterialItem 生成——按名字找回原 ItemData 需要物品目录，留待后续
//       （锅里的「哪种材料」不丢：钱包与日志都保留明细）。
// 挂载：突袭场景（TutorialScene / FogTownScene）的 SetUp/GameManager
//       （与 CorpseSpawner 同宿主，保证订阅顺序）。
// =============================================================================
using UnityEngine;

public class PendingCorpseSpawner : MonoBehaviour
{
    private void Start()
    {
        if (!MetaWallet.HasPendingCorpse) return;

        Vector2Int coord = MetaWallet.PendingCorpseCoord;
        int mats = MetaWallet.PendingCorpseMaterialCount;
        string breakdown = MetaWallet.SummaryOf(MetaWallet.PendingCorpseMaterialStacks);

        ItemData matItem = CorpseSpawner.Instance != null
            ? CorpseSpawner.Instance.fallbackMaterialItem
            : null;

        // ★2026-09-12 用户定稿：空袋不产 —— 没有可回收的材料就不摆一个永远清不掉的空袋。
        if (mats <= 0 || matItem == null)
        {
            Debug.LogWarning($"[回收] 没有可回收的材料（数量 {mats}，材料物品" +
                             $"{(matItem == null ? "未配置" : "已配置")}）→ 不生成尸体遗物袋");
            MetaWallet.ClearPendingCorpse();
            return;
        }

        CorpseContainer corpse = CorpseRegistry.Spawn(coord, "命运猎人（阵亡）");
        if (corpse != null)
        {
            corpse.AddItem(matItem, mats);
            Debug.Log($"[回收] 在 Hex_{coord.x}_{coord.y} 生成阵亡尸体，含材料 {matItem.itemName}×{mats}" +
                      $"（尸体记录：{breakdown}）");
        }

        MetaWallet.ClearPendingCorpse();
    }
}
